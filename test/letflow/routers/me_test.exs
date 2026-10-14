defmodule Letflow.Routers.MeTest do
  @moduledoc """
  Light route-behavior coverage for `Letflow.Routers.Me`'s
  `GET /me/memberships` handler (REQ-384 Part A) and `GET /me/modules`
  handler (REQ-403). ELIXIR-DEV inline coverage only -- full TEST-DESIGNER
  coverage is a later pipeline step. Mirrors
  `test/letflow/routers/help_test.exs`'s dispatch mechanism: direct
  `Letflow.Routers.Me.call/2` invocation with `conn.assigns.auth_context` set
  by hand, running the router's own real `:match` -> `Letflow.Plugs.Authorize`
  -> `:dispatch` chain (so `conn.assigns.scoped_opts` is computed for real,
  not stubbed).

  `async: false`: tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)` (`TenantFixture.provisioned_tenant!/1`'s
  own requirement).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantMembership
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Me.init([])

  defp build_conn(user_id, tenant_id, roles) do
    conn(:get, "/memberships")
    |> assign(:auth_context, %{user_id: user_id, tenant_id: tenant_id, roles: roles})
    |> assign(:trace_id, "req384-me-router-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Me.call(conn, @opts)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # ── REQ-403 helpers ──────────────────────────────────────────────────────

  defp build_modules_conn(user_id, tenant_id, roles, opts) do
    query_string = Keyword.get(opts, :query_string, "")
    path = if query_string == "", do: "/modules", else: "/modules?" <> query_string

    conn = conn(:get, path)

    conn =
      case Keyword.get(opts, :x_tenant_id_header) do
        nil -> conn
        header_value -> put_req_header(conn, "x-tenant-id", header_value)
      end

    conn
    |> assign(:auth_context, %{user_id: user_id, tenant_id: tenant_id, roles: roles})
    |> assign(:trace_id, "req403-me-modules-test-trace-id")
  end

  defp list_modules(user_id, tenant_id, roles, opts \\ []) do
    build_modules_conn(user_id, tenant_id, roles, opts)
    |> dispatch()
  end

  defp insert_tenant!(slug) do
    %Tenant{}
    |> Tenant.create_changeset(%{slug: slug, display_name: String.capitalize(slug)}, :disabled)
    |> Repo.insert!()
  end

  describe "GET /memberships" do
    test "200 includes the caller's own home tenant, even with zero tenant_memberships rows" do
      suffix = System.unique_integer([:positive])

      %{tenant_id: tenant_id, schema_name: schema_name, tenant: tenant} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req384-me-home-#{suffix}")

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => "req384-user-#{suffix}",
                   "display_name" => "REQ-384 User",
                   "email" => "req384-user-#{suffix}@example.com"
                 },
                 prefix: schema_name,
                 tenant_id: tenant_id
               )

      conn =
        build_conn(user.id, tenant_id, ["PROCESS_OPERATOR"])
        |> dispatch()

      assert conn.status == 200
      assert %{"memberships" => [entry]} = json(conn)
      assert entry["tenant_id"] == tenant.id
      assert entry["tenant_slug"] == tenant.slug
      assert entry["tenant_display_name"] == tenant.display_name
      assert entry["display_label"] == nil
    end

    test "200 includes admin-granted memberships alongside the home tenant" do
      suffix = System.unique_integer([:positive])

      %{tenant_id: tenant_id, schema_name: schema_name, tenant: tenant} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req384-me-multi-#{suffix}")

      email = "req384-multi-#{suffix}@example.com"

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => "req384-multi-user-#{suffix}",
                   "display_name" => "Multi",
                   "email" => email
                 },
                 prefix: schema_name,
                 tenant_id: tenant_id
               )

      other_tenant = insert_tenant!("req384-me-other-#{suffix}")

      %TenantMembership{}
      |> TenantMembership.create_changeset(%{
        subject_key: email,
        tenant_id: other_tenant.id,
        display_label: "Other Co"
      })
      |> Repo.insert!()

      conn =
        build_conn(user.id, tenant_id, ["PROCESS_OPERATOR"])
        |> dispatch()

      assert conn.status == 200
      assert %{"memberships" => memberships} = json(conn)
      assert length(memberships) == 2

      tenant_ids = Enum.map(memberships, & &1["tenant_id"])
      assert tenant.id in tenant_ids
      assert other_tenant.id in tenant_ids

      other_entry = Enum.find(memberships, &(&1["tenant_id"] == other_tenant.id))
      assert other_entry["display_label"] == "Other Co"
    end

    test "CANDIDATE is denied (ISS-0646 closed permission set, see Letflow.Api.Authorization moduledoc)" do
      suffix = System.unique_integer([:positive])

      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req384-me-candidate-#{suffix}")

      conn =
        build_conn(Ecto.UUID.generate(), tenant_id, ["CANDIDATE"])
        |> dispatch()

      assert conn.status == 403
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # REQ-403 AC4 — GET /me/modules, all six roles, before/after install,
  # exactly module_id+version keys
  # ═══════════════════════════════════════════════════════════════════════

  describe "GET /modules (REQ-403 AC4)" do
    test "returns installed_modules correctly for all six roles, before and after install, with exactly module_id+version keys" do
      suffix = System.unique_integer([:positive])

      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac4-#{suffix}")

      # REQ-447 PR 2: an ordinary tenant's PLATFORM_ADMIN holds nothing (legacy removed), so it is
      # outside the 200 matrix (asserted 403 below); TENANT_ADMIN stays in it.
      for role <- Authorization.roles(), role != :PLATFORM_ADMIN do
        conn = list_modules(Ecto.UUID.generate(), tenant_id, [Atom.to_string(role)])

        assert conn.status == 200,
               "expected 200 for role #{inspect(role)}, got #{conn.status}"

        assert json(conn) == %{"installed_modules" => []}
      end

      assert list_modules(Ecto.UUID.generate(), tenant_id, ["PLATFORM_ADMIN"]).status == 403

      assert {:ok, _tenant_module} =
               Installs.install("fixture", Ecto.UUID.generate(),
                 prefix: prefix,
                 rationale: "test: module install"
               )

      for role <- Authorization.roles(), role != :PLATFORM_ADMIN do
        conn = list_modules(Ecto.UUID.generate(), tenant_id, [Atom.to_string(role)])

        assert conn.status == 200
        assert %{"installed_modules" => [entry]} = json(conn)
        assert Map.keys(entry) |> Enum.sort() == ["module_id", "version"]
        assert entry["module_id"] == "fixture"
        assert entry["version"] == "0.1.0"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # REQ-403 AC8 — two-tenant isolation, including tenant_id query param and
  # x-tenant-id header spoofing attempts (INV-1)
  # ═══════════════════════════════════════════════════════════════════════

  describe "GET /modules (REQ-403 AC8) -- tenant isolation" do
    test "a token minted for tenant B always sees tenant B's (empty) list, even when spoofing tenant A via query/header" do
      suffix = System.unique_integer([:positive])

      %{tenant_id: tenant_id_a, schema_name: prefix_a} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac8-a-#{suffix}")

      %{tenant_id: tenant_id_b} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac8-b-#{suffix}")

      assert {:ok, _tenant_module} =
               Installs.install("fixture", Ecto.UUID.generate(),
                 prefix: prefix_a,
                 rationale: "test: module install"
               )

      # Plain request, no spoofing attempt.
      conn = list_modules(Ecto.UUID.generate(), tenant_id_b, ["TENANT_ADMIN"])
      assert conn.status == 200
      assert json(conn) == %{"installed_modules" => []}

      # Spoofing attempt via a tenant_id query parameter naming tenant A.
      conn =
        list_modules(Ecto.UUID.generate(), tenant_id_b, ["TENANT_ADMIN"],
          query_string: "tenant_id=#{tenant_id_a}"
        )

      assert conn.status == 200
      assert json(conn) == %{"installed_modules" => []}

      # Spoofing attempt via an x-tenant-id header naming tenant A.
      conn =
        list_modules(Ecto.UUID.generate(), tenant_id_b, ["TENANT_ADMIN"],
          x_tenant_id_header: tenant_id_a
        )

      assert conn.status == 200
      assert json(conn) == %{"installed_modules" => []}

      # Spoofing attempt via both at once.
      conn =
        list_modules(Ecto.UUID.generate(), tenant_id_b, ["TENANT_ADMIN"],
          query_string: "tenant_id=#{tenant_id_a}",
          x_tenant_id_header: tenant_id_a
        )

      assert conn.status == 200
      assert json(conn) == %{"installed_modules" => []}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # REQ-403 AC9 — no GET /api/v1/me root route added
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-403 AC9 -- no root route (grep contract)" do
    test "lib/letflow/routers/me.ex declares no authz_get \"/\" root route" do
      source = File.read!(Path.join([File.cwd!(), "lib", "letflow", "routers", "me.ex"]))

      refute source =~ ~r/authz_get\s+"\/"/,
             "expected no `authz_get \"/\"` root route in lib/letflow/routers/me.ex (REQ-403 AC9)"
    end
  end
end
