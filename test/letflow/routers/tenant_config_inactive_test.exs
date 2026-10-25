defmodule Letflow.Routers.TenantConfigInactiveTest do
  @moduledoc """
  GH #3252 / REQ-572: `GET /api/tenant-config?realm=<slug>` must not return the realm of a
  deactivated tenant (it falls through to the default config, byte-identical to an unknown
  slug, INV-5), while an active tenant still gets its own realm.
  """

  use Letflow.DataCase, async: true

  import Plug.Test

  alias Letflow.Identity.Tenant
  alias Letflow.TenantSlugFixture

  @router_opts Letflow.Router.init([])

  defp by_slug(slug) do
    conn = Letflow.Router.call(conn(:get, "/api/tenant-config?realm=#{slug}"), @router_opts)
    assert conn.status == 200
    conn.resp_body
  end

  defp insert_tenant!(status) do
    n = System.unique_integer([:positive, :monotonic])

    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: TenantSlugFixture.unique_slug("g3252"),
        display_name: "gh3252 tenant #{n}",
        idp_realm_id: "zq-g3252-realm-#{n}",
        tenant_type: "test"
      },
      :disabled
    )
    |> Ecto.Changeset.change(status: status)
    |> Repo.insert!()
  end

  test "an active tenant's realm is returned" do
    t = insert_tenant!(:active)
    assert by_slug(t.slug) =~ "/realms/" <> t.idp_realm_id
  end

  test "a deactivated tenant's realm is not returned and the body equals an unknown slug's" do
    t = insert_tenant!(:inactive)
    body = by_slug(t.slug)

    refute body =~ t.idp_realm_id
    assert body == by_slug(TenantSlugFixture.unique_slug("g3252-unknown"))
  end
end
