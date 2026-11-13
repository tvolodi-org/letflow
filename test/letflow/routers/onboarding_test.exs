defmodule Letflow.Routers.OnboardingTest do
  @moduledoc """
  End-to-end HTTP-level tests for `Letflow.Routers.Onboarding` (REQ-076 AC7/AC8).
  See `test/specs/REQ-076.md` for the full AC-to-test mapping, and
  `lib/letflow/design/req076-identity-tokens-roles-onboarding.md` §7.5/§7.6/§8.4
  for the design rationale each test below implements directly.

  Dispatches through the **real** `Letflow.Router.call/2` (the full
  `AuthPipeline` -> `TenantStatus` -> `Letflow.Routers.Onboarding` chain), using
  a real API token (REQ-076's own `X-Tenant-Slug`-header mechanism, design §3.5)
  rather than an OIDC bearer token or a direct `Letflow.Routers.Onboarding.call/2`
  dispatch — required here because AC7's indistinguishability claim depends on
  the real `Letflow.Api.Authorization.evaluate_access/2` decision actually
  running inside the real plug chain, and AC8's claim depends on the real
  `Letflow.TenantProvisioning` side effect actually firing for a real HTTP
  request, not a synthetic `conn.assigns[:auth_context]`.

  Uses `Letflow.TenantFixture.provisioned_tenant!/1` for the tenant that hosts
  each test's own API-token-authenticated caller (a caller's own tenant is
  irrelevant to `Letflow.Routers.Onboarding`'s routes — that router has no
  tenant-scoped `:prefix` preamble at all, design §8.3/§8's own moduledoc).
  `async: false` for the whole module, same reasoning as every other module in
  this suite that provisions a real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  import Ecto.Query, only: [from: 2]

  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  defp insert_user!(tenant, attrs \\ []) do
    default = %{
      username: "onboarding-caller-#{Ecto.UUID.generate()}",
      display_name: "Onboarding Test Caller",
      email: "onboarding-caller-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # Mints a real API token for a fresh tenant/user pair holding exactly `roles`,
  # returning {plaintext, tenant_slug} -- everything a caller needs to
  # authenticate through the real AuthPipeline API-token branch.
  defp mint_caller!(slug_prefix, roles) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    user = insert_user!(tenant)

    # ISS-0993 (A2): onboarding is PLATFORM scope. A caller minted here with PLATFORM_ADMIN is
    # the platform operator, so its tenant is pinned as THE platform tenant (restored on exit).
    if "PLATFORM_ADMIN" in roles, do: PlatformTenantFixture.pin!(tenant.tenant_id)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    {plaintext, tenant.tenant.slug}
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp authed_request(method, path, plaintext, tenant_slug, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant_slug)
  end

  # Ecto.UUID.generate/0-derived, NOT System.unique_integer/1 -- the latter is
  # only unique within a single BEAM VM run, and this module leaves real,
  # non-rolled-back committed rows behind (Sandbox :auto mode, per
  # TenantFixture.provisioned_tenant!/1's own moduledoc) that a later `mix test`
  # invocation's freshly-restarted counter could collide with, exactly the
  # ISS-0059 failure mode test/support/tenant_slug.ex's own moduledoc documents.
  defp unique_hostname(prefix) do
    "#{prefix}-#{Ecto.UUID.generate()}.example.com"
  end

  defp unique_onboarding_slug(prefix) do
    Letflow.TenantSlugFixture.unique_slug(prefix)
  end

  # Full teardown for a tenant created via a real POST /onboarding (NOT via
  # TenantFixture, so it gets none of that module's own on_exit/1 cleanup):
  # drops the real schema, then deletes the onboarding_registry row, the
  # TenantProvisioning.Registration row, and the tenants row itself, in FK
  # dependency order -- onboarding_registry.tenant_id has a real FK to tenants,
  # so skipping that delete first raises foreign_key_violation (an actual bug
  # this test file hit and fixed during drafting; kept here as the reason, not
  # asserted).
  defp cleanup_onboarded_tenant!(tenant_id) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant_id))
      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)
  end

  describe "REQ-076 AC8: onboarding creates a tenant via Letflow.TenantProvisioning, no second path" do
    test "POST /api/v1/onboarding refuses the reserved slug pwa with 422 and writes nothing (T-1861)" do
      {admin_plaintext, admin_slug} = mint_caller!("t1861-caller", ["PLATFORM_ADMIN"])

      for slug <- ["pwa", "PWA"] do
        conn =
          authed_request(:post, "/api/v1/onboarding", admin_plaintext, admin_slug, %{
            "slug" => slug,
            "display_name" => "Reserved",
            "hostname" => unique_hostname("t1861")
          })
          |> dispatch()

        assert conn.status == 422
      end

      assert {:error, :not_found} = Letflow.Identity.get_tenant_by_slug("pwa")
    end

    test "POST /api/v1/onboarding provisions a real, queryable Postgres schema for the new tenant" do
      {admin_plaintext, admin_slug} = mint_caller!("req076-ac8-caller", ["PLATFORM_ADMIN"])

      slug = unique_onboarding_slug("req076-ac8-new")
      hostname = unique_hostname("ac8")

      body = %{
        "slug" => slug,
        "display_name" => "AC8 New Tenant",
        "hostname" => hostname
      }

      conn =
        authed_request(:post, "/api/v1/onboarding", admin_plaintext, admin_slug, body)
        |> dispatch()

      assert conn.status == 201
      resp = Jason.decode!(conn.resp_body)
      assert resp["hostname"] == hostname
      assert resp["slug"] == slug
      assert is_binary(resp["tenant_id"])

      cleanup_onboarded_tenant!(resp["tenant_id"])

      # Proof the schema/migration side effect actually happened via the SAME
      # shared TenantProvisioning path (not merely that a `tenants` row was
      # inserted) -- same information_schema proof pattern REQ-075 §7.1 AC4
      # already established for POST /tenants.
      assert {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(resp["tenant_id"])

      %{rows: rows} =
        Repo.query!(
          "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'users'",
          [schema_name]
        )

      assert rows != [], "expected a real users table under #{schema_name}, found none"
    end
  end

  describe "REQ-076 AC7/INV-5: GET /onboarding?hostname= indistinguishability for a caller lacking :TenantsManage" do
    test "a never-bound hostname and a hostname bound to a real other tenant both produce byte-identical 403s" do
      {designer_plaintext, designer_slug} =
        mint_caller!("req076-ac7-caller", ["PROCESS_DESIGNER"])

      {admin_plaintext, admin_slug} = mint_caller!("req076-ac7-admin", ["PLATFORM_ADMIN"])

      # A real, bound-elsewhere onboarding record -- created via a genuine
      # admin-authenticated POST /onboarding, not a bypassed direct Identity
      # call, so this test exercises the exact same code path a real prober
      # would probe against.
      bound_hostname = unique_hostname("ac7-bound")

      create_conn =
        authed_request(:post, "/api/v1/onboarding", admin_plaintext, admin_slug, %{
          "slug" => unique_onboarding_slug("req076-ac7-bound"),
          "display_name" => "AC7 Bound Elsewhere",
          "hostname" => bound_hostname
        })
        |> dispatch()

      assert create_conn.status == 201
      bound_resp = Jason.decode!(create_conn.resp_body)

      cleanup_onboarded_tenant!(bound_resp["tenant_id"])

      never_bound_hostname = unique_hostname("ac7-never-bound")

      conn_unbound =
        authed_request(
          :get,
          "/api/v1/onboarding?hostname=#{never_bound_hostname}",
          designer_plaintext,
          designer_slug
        )
        |> dispatch()

      conn_bound_elsewhere =
        authed_request(
          :get,
          "/api/v1/onboarding?hostname=#{bound_hostname}",
          designer_plaintext,
          designer_slug
        )
        |> dispatch()

      assert conn_unbound.status == 403
      assert conn_bound_elsewhere.status == 403
      assert conn_unbound.status == conn_bound_elsewhere.status

      # Compared with `trace_id` excluded: `Letflow.Plugs.ApiPipeline` mounts
      # `assign_trace_id/2` (REQ-072) on the REAL pipeline this test dispatches
      # through, which mints a genuinely random per-request trace_id -- an
      # inherent, expected difference between any two separate requests, not a
      # content difference INV-5 cares about (it is a correlation id, not
      # response content an unauthorized prober could learn anything from). Every
      # OTHER field must still be byte-identical.
      unbound_body = Jason.decode!(conn_unbound.resp_body)
      bound_elsewhere_body = Jason.decode!(conn_bound_elsewhere.resp_body)

      assert Map.delete(unbound_body, "trace_id") == Map.delete(bound_elsewhere_body, "trace_id")
    end

    test "a PLATFORM_ADMIN caller (who DOES hold :TenantsManage) sees 404 for a never-bound hostname -- not itself required to be indistinguishable (design §8.4)" do
      {admin_plaintext, admin_slug} = mint_caller!("req076-ac7-admin-view", ["PLATFORM_ADMIN"])

      conn =
        authed_request(
          :get,
          "/api/v1/onboarding?hostname=#{unique_hostname("admin-never-bound")}",
          admin_plaintext,
          admin_slug
        )
        |> dispatch()

      assert conn.status == 404
    end
  end
end
