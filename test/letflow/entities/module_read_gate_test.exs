Code.require_file("../modules/assets/register_fixture.exs", __DIR__)

defmodule Letflow.Entities.ModuleReadGateTest do
  @moduledoc """
  T-1864 (INV-2, INV-5): with the storekeeper assets switch OFF a storekeeper (no `AssetsRead`, but
  `EntitiesQuery`) reads no `assets_*` record through `POST /entities/query`, the aggregate, the
  export or `GET /entity-views`; with the switch ON the same calls answer; the tenant administrator
  is unchanged and a type of another module stays readable. Full `Letflow.Router`, real OIDC tokens,
  committed tenants (Sandbox `:auto`).
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Entities.Views
  alias Letflow.Modules.Assets.Cards
  alias Letflow.Modules.TenantModule

  setup do
    ctx = S.setup_oidc!([:a, :b])
    a = S.tenant!("mrg-a", ctx.names.a)
    b = S.tenant!("mrg-b", ctx.names.b)

    {:ok, _card} =
      Cards.create_card(
        a.schema_name,
        %{"inventory_number" => "INV-1", "name" => "Laptop", "kind" => "fixed"},
        %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
      )

    # the install ships the "Asset list" saved view of assets_card
    {:ok, views} = Views.list(a.schema_name, Ecto.UUID.generate(), "assets_card")
    view = hd(views)

    Map.merge(ctx, %{
      a: a,
      b: b,
      view: view,
      sk: S.token(ctx, :a, ["STOREKEEPER"], sub: "mrg-sk"),
      admin: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "mrg-admin"),
      auditor: S.token(ctx, :a, ["TENANT_AUDITOR"], sub: "mrg-auditor"),
      admin_b: S.token(ctx, :b, ["TENANT_ADMIN"], sub: "mrg-admin-b")
    })
  end

  defp api(method, path, token, body \\ nil) do
    Plug.Test.conn(method, "/api/v1" <> path, if(body, do: Jason.encode!(body), else: nil))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp off!(schema) do
    row = Letflow.Repo.get_by!(TenantModule, [module_id: "assets"], prefix: schema)

    row
    |> TenantModule.settings_changeset(%{
      settings: Map.delete(row.settings, "storekeeper_grants")
    })
    |> Letflow.Repo.update!(prefix: schema)
  end

  defp items(conn) do
    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)["items"]
  end

  defp query(token, type), do: api(:post, "/entities/query", token, %{"entity_type" => type})

  test "M1 switch OFF: the storekeeper reads no assets_card through the query", ctx do
    off!(ctx.a.schema_name)
    assert items(query(ctx.sk, "assets_card")) == []
    # the same envelope as an absent type (no oracle)
    assert items(query(ctx.sk, "no_such_type")) == []
  end

  test "M2 the storekeeper holds no aggregate or export route (403), the admin reads", ctx do
    off!(ctx.a.schema_name)

    assert api(:post, "/entities/query/aggregate", ctx.sk, %{
             "entity_type" => "assets_card",
             "aggregates" => [%{"fn" => "count"}]
           }).status == 403

    assert api(:post, "/entities/records/assets_card/export", ctx.sk, %{
             "entity_type" => "assets_card"
           }).status == 403

    assert api(:post, "/entities/query/aggregate", ctx.admin, %{
             "entity_type" => "assets_card",
             "aggregates" => [%{"fn" => "count"}]
           }).status == 200
  end

  test "M3 switch OFF: the saved view of an assets type is hidden from list and get", ctx do
    off!(ctx.a.schema_name)

    list = api(:get, "/entity-views?entity_type=assets_card", ctx.sk)
    assert items(list) == []
    assert api(:get, "/entity-views/#{ctx.view.id}", ctx.sk).status == 404
    all = items(api(:get, "/entity-views", ctx.sk))
    refute Enum.any?(all, &(&1["entity_type"] == "assets_card"))
  end

  test "M4 switch ON (default install): the storekeeper reads the card and the view", ctx do
    assert [%{} = card] = items(query(ctx.sk, "assets_card"))
    assert card["field_values"]["inventory_number"] == "INV-1" or inspect(card) =~ "INV-1"

    assert [%{}] = items(api(:get, "/entity-views?entity_type=assets_card", ctx.sk))
    assert api(:get, "/entity-views/#{ctx.view.id}", ctx.sk).status == 200
  end

  test "M5 switch OFF then ON through the administrator route flips the query", ctx do
    off!(ctx.a.schema_name)
    assert items(query(ctx.sk, "assets_card")) == []

    on = api(:put, "/tenant/role-grants", ctx.admin, %{"storekeeper" => ["AssetsRead"]})
    assert on.status == 200, on.resp_body
    assert [_] = items(query(ctx.sk, "assets_card"))
  end

  test "M6 the administrator and the auditor are unchanged with the switch off", ctx do
    off!(ctx.a.schema_name)
    assert [_] = items(query(ctx.admin, "assets_card"))
    assert [_] = items(query(ctx.auditor, "assets_card"))
    assert api(:get, "/entity-views/#{ctx.view.id}", ctx.admin).status == 200
  end

  test "M7 the admin of another tenant sees nothing of this tenant (INV-10)", ctx do
    assert items(query(ctx.admin_b, "assets_card")) == []
  end
end
