defmodule Letflow.Routers.TenantConfigTenantTypeTest do
  @moduledoc """
  REQ-472 (GH #2477): `GET /api/tenant-config` carries `tenant_type`, non-null only
  on the branch that resolved a real realm. Assertions on the anti-oracle and
  no-leak properties run on the raw `conn.resp_body`, not on decoded maps.

  Global `tenants` table only, so the sandboxed `Letflow.DataCase` is enough.
  """

  use Letflow.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Plug.Test

  alias Letflow.Identity.Tenant
  alias Letflow.TenantSlugFixture

  @router_opts Letflow.Router.init([])

  defp raw(path) do
    conn = Letflow.Router.call(conn(:get, path), @router_opts)
    assert conn.status == 200
    conn.resp_body
  end

  defp by_slug(slug), do: raw("/api/tenant-config?realm=#{URI.encode_www_form(slug)}")

  defp insert_tenant!(attrs) do
    n = System.unique_integer([:positive, :monotonic])

    base = %{
      slug: TenantSlugFixture.unique_slug("tt"),
      display_name: "zq-leak-name-#{n}",
      idp_realm_id: "zq-realm-#{n}",
      tenant_type: "test"
    }

    %Tenant{}
    |> Tenant.create_changeset(Map.merge(base, attrs), :disabled)
    |> Repo.insert!()
  end

  defp set_realm!(%Tenant{id: id} = tenant, realm) do
    Repo.update_all(from(t in Tenant, where: t.id == ^id), set: [idp_realm_id: realm])
    tenant
  end

  defp set_default_tenant_type!(type) do
    {1, _} =
      Repo.update_all(from(t in Tenant, where: t.slug == "bpm-default"), set: [tenant_type: type])
  end

  defp type_of(body), do: Jason.decode!(body)["tenant_type"]

  test "T1: a production tenant with a bound realm returns production" do
    t = insert_tenant!(%{tenant_type: "production"})
    assert type_of(by_slug(t.slug)) == "production"
  end

  test "T2: a test tenant with a bound realm returns test" do
    t = insert_tenant!(%{tenant_type: "test"})
    assert t.idp_realm_id != t.slug and t.idp_realm_id != t.display_name
    assert type_of(by_slug(t.slug)) == "test"
  end

  describe "T3: anti-oracle byte equality" do
    test "nil realm, empty realm, unknown slug and lookup failure share one body" do
      nil_realm = insert_tenant!(%{tenant_type: "production"}) |> set_realm!(nil)
      empty_realm = insert_tenant!(%{tenant_type: "production"}) |> set_realm!("")

      unknown = by_slug(TenantSlugFixture.unique_slug("tt-unknown"))

      assert by_slug(nil_realm.slug) == unknown
      assert by_slug(empty_realm.slug) == unknown
      assert by_slug(<<0>>) == unknown
      assert unknown =~ ~s("tenant_type":null)
    end

    test "?host=, no parameter and unknown slug share one body, even if bpm-default is production" do
      set_default_tenant_type!("production")

      host = raw("/api/tenant-config?host=qa.example.invalid")
      none = raw("/api/tenant-config")
      unknown = by_slug(TenantSlugFixture.unique_slug("tt-unknown"))

      assert host == none
      assert none == unknown
      assert none =~ ~s("tenant_type":null)
    end
  end

  test "T4: no tenant name, slug or id appears in any response body" do
    prod = insert_tenant!(%{tenant_type: "production"})
    test_t = insert_tenant!(%{tenant_type: "test"})
    nil_realm = insert_tenant!(%{tenant_type: "production"}) |> set_realm!(nil)

    bodies = [
      by_slug(prod.slug),
      by_slug(test_t.slug),
      by_slug(nil_realm.slug),
      by_slug(TenantSlugFixture.unique_slug("tt-unknown")),
      by_slug(<<0>>),
      raw("/api/tenant-config?host=qa.example.invalid"),
      raw("/api/tenant-config")
    ]

    for body <- bodies,
        t <- [prod, test_t, nil_realm],
        needle <- [t.display_name, t.slug, to_string(t.id)] do
      refute body =~ needle
    end
  end

  test "T5: exactly four top-level keys and three branding sub-keys" do
    t = insert_tenant!(%{tenant_type: "production"})

    for body <- [by_slug(t.slug), raw("/api/tenant-config")] do
      decoded = Jason.decode!(body)

      assert decoded |> Map.keys() |> Enum.sort() ==
               ["branding", "client_id", "oidc_authority", "tenant_type"]

      assert decoded["branding"] |> Map.keys() |> Enum.sort() ==
               ["app_name", "brand_colors", "logo_url"]
    end
  end
end
