defmodule Letflow.Routers.OnboardingClientConfigTest do
  @moduledoc """
  REQ-468 (supersedes Q-1088 / GH #2450's disposition) -- `POST /api/v1/onboarding` ignores `client_config`
  and `realm_config` BY NAME: they are ordinary undeclared body keys (like `redirect_uris`), listed in
  `ignored_fields` and answered with nothing else. The web wizard no longer sends them (PR #2467). No value
  is read, stored or echoed, and the tenant and onboarding record are created exactly as without the keys.

  `async: false`: tenant provisioning flips the SQL sandbox to `:auto`, and the platform tenant pin is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.TenantSlugFixture

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "q1088-plat")
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
        "slug" => TenantSlugFixture.unique_slug("q1088"),
        "display_name" => "Q-1088 Tenant",
        "hostname" => "q1088-#{Ecto.UUID.generate()}.example.com"
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

  test "client_config and realm_config in the body: 201, no top-level key for them, both named in ignored_fields, tenant and record created as without them",
       ctx do
    with_keys =
      post_onboarding(ctx, %{
        "client_config" => %{
          "redirect_uris" => ["https://app.example.test/callback"],
          "service_account_enabled" => false
        },
        "realm_config" => %{"realm_display_name" => "REQ-468 realm"}
      })

    assert with_keys.status == 201, with_keys.resp_body
    body = json(with_keys)
    refute Map.has_key?(body, "client_config")
    refute Map.has_key?(body, "realm_config")
    assert "client_config" in body["ignored_fields"]
    assert "realm_config" in body["ignored_fields"]

    # the same request without the keys answers the same body shape (apart from ids and the ignored names)
    without = post_onboarding(ctx, %{})
    assert without.status == 201, without.resp_body
    plain = json(without)
    assert Enum.sort(Map.keys(plain)) == Enum.sort(Map.keys(body))
    assert plain["ignored_fields"] == []
    assert plain["administrator"] == body["administrator"]
    assert plain["login"] == body["login"]

    tenant = Repo.get_by!(Tenant, slug: body["slug"])
    assert Repo.get_by(OnboardingRecord, tenant_id: tenant.id)
    assert Repo.get_by(Registration, tenant_id: tenant.id)
  end

  test "only client_config sent: no disposition key at all, named in ignored_fields only", ctx do
    conn =
      post_onboarding(ctx, %{
        "client_config" => %{"redirect_uris" => ["https://app.example.test/callback"]}
      })

    assert conn.status == 201, conn.resp_body
    body = json(conn)
    refute Map.has_key?(body, "client_config")
    refute Map.has_key?(body, "realm_config")
    assert body["ignored_fields"] == ["client_config"]
  end

  test "no value is echoed: sentinels (also inside client_config.redirect_uris) appear nowhere in the body or headers",
       ctx do
    conn =
      post_onboarding(ctx, %{
        "client_config" => %{
          "redirect_uris" => ["https://zz-req468-sentinel.example.test/cb"],
          "service_account_enabled" => true
        },
        "realm_config" => %{"realm_display_name" => "ZZ-REQ468-SENTINEL"}
      })

    assert conn.status == 201, conn.resp_body

    # Case-insensitive, and the response headers too: an echo in any case or any header is a leak.
    refute String.downcase(conn.resp_body) =~ "zz-req468-sentinel"

    refute Enum.any?(conn.resp_headers, fn {_name, value} ->
             String.downcase(value) =~ "zz-req468-sentinel"
           end)

    body = json(conn)
    assert "client_config" in body["ignored_fields"]
    assert "realm_config" in body["ignored_fields"]
  end

  test "a request without the keys is unchanged: no client_config or realm_config key, empty ignored_fields",
       ctx do
    conn = post_onboarding(ctx, %{})

    assert conn.status == 201, conn.resp_body
    body = json(conn)
    refute Map.has_key?(body, "client_config")
    refute Map.has_key?(body, "realm_config")
    assert body["ignored_fields"] == []
  end

  test "the per-key disposition is gone from the router source" do
    source = File.read!("lib/letflow/routers/onboarding.ex")

    for gone <- ["@not_stored_keys", "@not_stored_next", "dispositions(", ~s("disposition" =>)] do
      refute source =~ gone, "lib/letflow/routers/onboarding.ex still contains #{inspect(gone)}"
    end
  end
end
