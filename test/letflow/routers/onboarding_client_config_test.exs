defmodule Letflow.Routers.OnboardingClientConfigTest do
  @moduledoc """
  Q-1088 / GH #2450 -- `POST /api/v1/onboarding` must not drop `client_config` and `realm_config` silently.
  The wizard sends both (web/src/api/onboarding.ts). On main, `ignored_fields` names both keys, but the
  response says nothing about where they went: `Map.take` keeps only `slug` and `display_name`
  (lib/letflow/routers/onboarding.ex).

  Tests 1 and 2 pin the decision recorded in test/specs/Q-1088-prefix-run.txt (option A): each key the
  request carries gets a disposition, and nothing is stored or applied. Tests 3 and 4 are design-neutral:
  they hold for any decision that keeps `ignored_fields` and echoes no client value.

  `async: false`: tenant provisioning flips the SQL sandbox to `:auto`, and the platform tenant pin is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test

  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.TenantSlugFixture

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "iss1088-plat")
    Fixture.pin!(platform.tenant_id)
    token = Fixture.mint_token!(platform, ["PLATFORM_ADMIN"])
    %{platform: platform, token: token}
  end

  defp call(ctx, method, path, body) do
    method
    |> Fixture.api_conn(path, ctx.token, ctx.platform.tenant.slug, body)
    |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp new_body(extra) do
    Map.merge(
      %{
        "slug" => TenantSlugFixture.unique_slug("iss1088"),
        "display_name" => "Q-1088 Tenant",
        "hostname" => "iss1088-#{Ecto.UUID.generate()}.example.com"
      },
      extra
    )
  end

  # The tenant for the slug is looked up at exit, so a request that raises before it returns an id still
  # leaves nothing behind. The onboarding record goes first (its foreign key points at the tenant).
  defp cleanup_slug_on_exit(slug) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      case Repo.get_by(Tenant, slug: slug) do
        %Tenant{id: tenant_id} -> drop_tenant_rows!(tenant_id)
        nil -> :ok
      end
    end)
  end

  defp drop_tenant_rows!(tenant_id) do
    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
      {:error, :invalid_tenant_id} -> :ok
    end

    Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant_id))
    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
  end

  defp post_onboarding(ctx, extra) do
    body = new_body(extra)
    cleanup_slug_on_exit(body["slug"])
    call(ctx, :post, "/api/v1/onboarding", body)
  end

  # Pinned to the production text (lib/letflow/routers/onboarding.ex, @not_stored_next). A change to the wording
  # is a deliberate edit here too.
  @not_stored_next "Not stored or applied by the platform. Set up this tenant's client and realm by hand, as the onboarding runbook describes (docs/runbooks/onboarding-new-tenant-realm.md, ADR 0044 Phase 1)."

  test "POST /onboarding answers each of client_config and realm_config with disposition not_stored and the next step",
       ctx do
    conn =
      post_onboarding(ctx, %{
        "client_config" => %{
          "redirect_uris" => ["https://app.example.test/callback"],
          "service_account_enabled" => false
        },
        "realm_config" => %{"realm_display_name" => "Q-1088 realm"}
      })

    assert conn.status == 201, conn.resp_body
    body = json(conn)
    assert body["client_config"] == %{"disposition" => "not_stored", "next" => @not_stored_next}
    assert body["realm_config"] == %{"disposition" => "not_stored", "next" => @not_stored_next}
  end

  test "POST /onboarding with only client_config answers a disposition for client_config and none for realm_config",
       ctx do
    conn =
      post_onboarding(ctx, %{
        "client_config" => %{"redirect_uris" => ["https://app.example.test/callback"]}
      })

    assert conn.status == 201, conn.resp_body
    body = json(conn)
    assert body["client_config"] == %{"disposition" => "not_stored", "next" => @not_stored_next}
    refute Map.has_key?(body, "realm_config")
  end

  test "POST /onboarding names the keys of client_config and realm_config in ignored_fields and echoes no client value",
       ctx do
    conn =
      post_onboarding(ctx, %{
        "client_config" => %{
          "redirect_uris" => ["https://zz-q1088-sentinel.example.test/cb"],
          "service_account_enabled" => true
        },
        "realm_config" => %{"realm_display_name" => "ZZ-Q1088-SENTINEL"}
      })

    assert conn.status == 201, conn.resp_body

    # Case-insensitive, and the response headers too: an echo in any case or any header is a leak.
    refute String.downcase(conn.resp_body) =~ "zz-q1088-sentinel"

    refute Enum.any?(conn.resp_headers, fn {_name, value} ->
             String.downcase(value) =~ "zz-q1088-sentinel"
           end)

    body = json(conn)
    assert "client_config" in body["ignored_fields"]
    assert "realm_config" in body["ignored_fields"]
  end

  test "POST /onboarding without client_config or realm_config answers no disposition for them (existing callers unchanged)",
       ctx do
    conn = post_onboarding(ctx, %{})

    assert conn.status == 201, conn.resp_body
    body = json(conn)
    refute Map.has_key?(body, "client_config")
    refute Map.has_key?(body, "realm_config")
  end
end
