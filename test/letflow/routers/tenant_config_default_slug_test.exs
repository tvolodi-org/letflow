defmodule Letflow.Routers.TenantConfigDefaultSlugTest do
  @moduledoc """
  T-1481: `LETFLOW_DEFAULT_TENANT_SLUG` names the tenant that `GET /api/tenant-config`
  answers with when there is no usable `?realm=`. The env var is global, so this file
  is not async and restores it after each test.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test

  alias Letflow.Identity.Tenant
  alias Letflow.TenantSlugFixture

  @router_opts Letflow.Router.init([])
  @var "LETFLOW_DEFAULT_TENANT_SLUG"

  setup do
    previous = System.get_env(@var)

    on_exit(fn ->
      if previous, do: System.put_env(@var, previous), else: System.delete_env(@var)
    end)

    System.delete_env(@var)
    :ok
  end

  defp raw(path) do
    conn = Letflow.Router.call(conn(:get, path), @router_opts)
    assert conn.status == 200
    conn.resp_body
  end

  defp insert_tenant!(attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    base = %{
      slug: TenantSlugFixture.unique_slug("ds"),
      display_name: "ds-name-#{n}",
      idp_realm_id: "ds-realm-#{n}",
      tenant_type: "test"
    }

    %Tenant{}
    |> Tenant.create_changeset(Map.merge(base, attrs), :disabled)
    |> Repo.insert!()
  end

  test "D1: the configured slug answers the no-parameter and ?host= calls" do
    t = insert_tenant!()
    System.put_env(@var, t.slug)

    for path <- ["/api/tenant-config", "/api/tenant-config?host=demo.example.org"] do
      body = Jason.decode!(raw(path))
      assert body["oidc_authority"] =~ "/realms/#{t.idp_realm_id}"
      assert body["tenant_type"] == nil

      assert Enum.sort(Map.keys(body)) == [
               "branding",
               "client_id",
               "oidc_authority",
               "tenant_type"
             ]
    end
  end

  test "D2: an explicit ?realm= still wins over the configured default" do
    default = insert_tenant!()
    other = insert_tenant!()
    System.put_env(@var, default.slug)

    body = Jason.decode!(raw("/api/tenant-config?realm=#{other.slug}"))
    assert body["oidc_authority"] =~ "/realms/#{other.idp_realm_id}"
  end

  test "D3: unset or empty keeps bpm-default" do
    assert Jason.decode!(raw("/api/tenant-config"))["oidc_authority"] =~ "/realms/bpm-default"
    System.put_env(@var, "")
    assert Jason.decode!(raw("/api/tenant-config"))["oidc_authority"] =~ "/realms/bpm-default"
  end

  test "D4: unknown, inactive or realm-less configured tenant falls back to bpm-default" do
    inactive = insert_tenant!()
    Repo.update_all(from(t in Tenant, where: t.id == ^inactive.id), set: [status: :inactive])
    norealm = insert_tenant!()
    Repo.update_all(from(t in Tenant, where: t.id == ^norealm.id), set: [idp_realm_id: nil])

    for slug <- ["no-such-tenant-zz", inactive.slug, norealm.slug] do
      System.put_env(@var, slug)
      assert Jason.decode!(raw("/api/tenant-config"))["oidc_authority"] =~ "/realms/bpm-default"
    end
  end

  test "D5: an unknown ?realm= is byte-identical to the no-parameter answer" do
    t = insert_tenant!()
    System.put_env(@var, t.slug)

    assert raw("/api/tenant-config?realm=no-such-tenant-zz") == raw("/api/tenant-config")
  end
end
