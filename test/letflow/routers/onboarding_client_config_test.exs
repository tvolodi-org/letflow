defmodule Letflow.Routers.OnboardingClientConfigTest do
  @moduledoc """
  ISS-1088 / GH #2450 -- `POST /api/v1/onboarding` must not drop `client_config` and
  `realm_config` silently. The wizard sends both (web/src/api/onboarding.ts); main keeps
  only `slug` and `display_name` (`Map.take`, lib/letflow/routers/onboarding.ex) and the
  response says nothing about either key.

  The assertions here are design-neutral: whatever the decision (store and apply, store
  without applying, or stop sending), the 201 response must say, for each key, where it
  went. The decision itself is recorded in the spec before the disposition values are
  pinned; these tests check the shape only.

  `async: false`: tenant provisioning flips the SQL sandbox to `:auto`, and the platform
  tenant pin is VM-global.
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
        "display_name" => "ISS-1088 Tenant",
        "hostname" => "iss1088-#{Ecto.UUID.generate()}.example.com"
      },
      extra
    )
  end

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

  # The request's tenant is removed at exit, whatever the assertions do.
  defp post_onboarding(ctx, extra) do
    body = new_body(extra)
    conn = call(ctx, :post, "/api/v1/onboarding", body)

    if tenant = Repo.get_by(Tenant, slug: body["slug"]), do: cleanup_onboarded_tenant!(tenant.id)

    conn
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
        "realm_config" => %{"realm_display_name" => "ISS-1088 realm"}
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

  test "POST /onboarding echoes the key names of client_config and realm_config in ignored_fields, never their values",
       ctx do
    conn =
      post_onboarding(ctx, %{
        "client_config" => %{
          "redirect_uris" => ["https://zz-iss1088-sentinel.example.test/cb"],
          "service_account_enabled" => true
        },
        "realm_config" => %{"realm_display_name" => "ZZ-ISS1088-SENTINEL"}
      })

    assert conn.status == 201, conn.resp_body
    refute conn.resp_body =~ "zz-iss1088-sentinel"
    refute conn.resp_body =~ "ZZ-ISS1088-SENTINEL"

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
