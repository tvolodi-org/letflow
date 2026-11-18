defmodule Letflow.Routers.TenantsHostnameTest do
  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query
  alias Letflow.{Repo, TenantFixture, TenantHosts}
  alias Letflow.Identity.{OnboardingRecord, Tenant}
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  setup do
    platform = tenant!()
    target = tenant!()
    Fixture.pin!(platform.tenant_id)
    previous = Application.fetch_env(:letflow, Letflow.TenantProvisioner)

    Application.put_env(:letflow, Letflow.TenantProvisioner,
      allowed_hostname_suffixes: ["qa.example"]
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, Letflow.TenantProvisioner, value)
        :error -> Application.delete_env(:letflow, Letflow.TenantProvisioner)
      end
    end)

    auth = %{
      user_id: Ecto.UUID.generate(),
      tenant_id: platform.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    }

    %{platform: platform, target: target, auth: auth}
  end

  defp tenant! do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "host-route")

    on_exit(fn ->
      Repo.delete_all(from(r in OnboardingRecord, where: r.tenant_id == ^t.tenant_id))
    end)

    t
  end

  defp host, do: "h#{System.unique_integer([:positive])}.qa.example"

  defp call(method, slug, auth, body \\ %{}) do
    %{conn(method, "/#{slug}/hostname") | body_params: body}
    |> assign(:auth_context, auth)
    |> assign(:trace_id, "host-route-trace")
    |> Letflow.Routers.Tenants.call(Letflow.Routers.Tenants.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp config(host) do
    conn(:get, "/api/tenant-config" <> if(host, do: "?host=" <> host, else: ""))
    |> Letflow.Router.call(Letflow.Router.init([]))
    |> json()
  end

  defp rows(t), do: Repo.all(from(r in OnboardingRecord, where: r.tenant_id == ^t.tenant_id))

  defp entries(t),
    do:
      Repo.all(from(e in Letflow.Audit.Entry, where: like(e.action, "%hostname%")),
        prefix: t.schema_name
      )

  test "R1 R2 R3 register, repeat, replace and remove drive tenant-config", c do
    h = host()
    realm = "host-realm-#{System.unique_integer([:positive])}"

    Repo.update_all(from(t in Tenant, where: t.id == ^c.target.tenant_id),
      set: [idp_realm_id: realm]
    )

    response = call(:put, c.target.tenant.slug, c.auth, %{"hostname" => h})
    assert response.status == 200
    first = json(response)
    assert Enum.sort(Map.keys(first)) == ~w(changed hostname onboarding_id slug tenant_id)
    assert first["hostname"] == h
    assert first["tenant_id"] == c.target.tenant_id
    assert first["slug"] == c.target.tenant.slug
    assert first["changed"]
    assert config(h)["oidc_authority"] =~ "/realms/#{realm}"
    repeated = call(:put, c.target.tenant.slug, c.auth, %{"hostname" => h})
    assert repeated.status == 200
    refute json(repeated)["changed"]
    next = host()
    changed = call(:put, c.target.tenant.slug, c.auth, %{"hostname" => next})
    assert changed.status == 200
    assert json(changed)["changed"]
    assert json(changed)["onboarding_id"] == first["onboarding_id"]
    assert config(h) == config(nil)
    assert config(next)["oidc_authority"] =~ "/realms/#{realm}"
    removed = call(:delete, c.target.tenant.slug, c.auth)
    assert removed.status == 200
    assert json(removed)["changed"]
    assert json(removed)["hostname"] == nil
    assert json(removed)["onboarding_id"] == nil
    assert config(next) == config(nil)
    again = call(:delete, c.target.tenant.slug, c.auth)
    assert again.status == 200
    refute json(again)["changed"]
  end

  test "R4 malformed bodies and hosts produce field errors without echo", c do
    for {body, constraint, submitted} <- [
          {%{}, "required", nil},
          {%{"hostname" => 5}, "required", nil},
          {nil, "required", nil},
          {"body", "required", nil},
          {%{"hostname" => "private.other.test"}, "format", "private.other.test"},
          {%{"hostname" => "api.qa.example"}, "reserved", "api.qa.example"},
          {%{"hostname" => "*.qa.example"}, "format", "*.qa.example"}
        ] do
      response = call(:put, c.target.tenant.slug, c.auth, body)
      assert response.status == 422
      assert [%{"field" => "hostname", "constraint" => ^constraint}] = json(response)["errors"]
      if submitted, do: refute(response.resp_body =~ submitted)
    end

    assert rows(c.target) == []
    assert entries(c.target) == []
  end

  test "R1 token authenticated request reaches the real API pipeline", c do
    token = Fixture.mint_token!(c.platform, ["PLATFORM_ADMIN"])
    h = host()

    response =
      Fixture.api_conn(
        :put,
        "/api/v1/tenants/#{c.target.tenant.slug}/hostname",
        token,
        c.platform.tenant.slug,
        %{"hostname" => h}
      )
      |> Fixture.dispatch_api()

    assert response.status == 200, response.resp_body
    assert json(response)["hostname"] == h
    assert length(entries(c.target)) == 1
  end

  test "R5 host conflict and purged tenant return 409", c do
    h = host()
    opts = [actor_id: c.auth.user_id, platform_prefix: c.platform.schema_name]
    assert {:ok, :created, _} = TenantHosts.set_host(c.platform.tenant_id, h, opts)
    conflict = call(:put, c.target.tenant.slug, c.auth, %{"hostname" => h})
    assert conflict.status == 409
    assert json(conflict)["detail"] == "hostname already bound"
    now = DateTime.utc_now()

    Repo.insert!(
      struct(Letflow.TenantProvisioner.Lifecycle, %{
        tenant_id: c.target.tenant_id,
        lifecycle: "deleted",
        tier: "demo",
        language: "en",
        expires_at: now,
        purged_at: now
      })
    )

    on_exit(fn ->
      Repo.delete_all(
        from(l in Letflow.TenantProvisioner.Lifecycle, where: l.tenant_id == ^c.target.tenant_id)
      )
    end)

    for verb <- [:put, :delete] do
      response = call(verb, c.target.tenant.slug, c.auth, %{"hostname" => host()})
      assert response.status == 409
      assert json(response)["detail"] == "tenant was purged"
    end

    assert rows(c.target) == []
    assert entries(c.target) == []
  end

  test "R6 unknown slug answers 404 for both verbs", c do
    for verb <- [:put, :delete] do
      assert call(verb, "absent", c.auth, %{"hostname" => host()}).status == 404
    end

    assert rows(c.target) == []
  end

  test "R7 non-platform callers cannot probe own, other or unknown tenants", c do
    a = tenant!()

    for {tenant_id, roles} <- [
          {a.tenant_id, ["PLATFORM_ADMIN"]},
          {a.tenant_id, ["TENANT_ADMIN"]},
          {c.platform.tenant_id, ["TENANT_ADMIN"]}
        ],
        verb <- [:put, :delete] do
      auth = %{c.auth | tenant_id: tenant_id, roles: roles}

      responses =
        for slug <- [a.tenant.slug, c.target.tenant.slug, "absent"] do
          {response, events} =
            Fixture.capture_repo_queries(fn ->
              call(verb, slug, auth, %{"hostname" => host()})
            end)

          assert response.status == 403
          refute Enum.any?(events, &Fixture.touches_tenant?(&1, c.target))
          response.resp_body
        end

      assert length(Enum.uniq(responses)) == 1
    end

    assert rows(a) == []
    assert rows(c.target) == []
    assert entries(a) == []
    assert entries(c.target) == []
  end

  test "R8 an unregistered platform schema fails closed", c do
    {:ok, bare} =
      Letflow.Identity.create_tenant(%{
        slug: "bare-#{System.unique_integer([:positive])}",
        display_name: "Bare"
      })

    on_exit(fn -> Repo.delete!(bare) end)
    auth = Fixture.operator_auth_context(c.auth.user_id, bare.id, ["PLATFORM_ADMIN"])

    for verb <- [:put, :delete] do
      response = call(verb, c.target.tenant.slug, auth, %{"hostname" => host()})
      assert response.status == 500
    end

    assert rows(c.target) == []
    assert entries(c.target) == []
  end
end
