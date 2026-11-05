Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.AssetListReportTest do
  @moduledoc """
  Plan key E2b (`docs/assets/government-lists.md` section 3): install of module `assets` ships the
  saved report "Asset list". Tests R-1..R-4, R-6, R-7 (R-5, a valid body, is covered by R-1: the
  install succeeds only when `Views.create/3` accepts the body).

  `async: false`: real committed tenants.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Entities.Views
  alias Letflow.Entities.Views.View
  alias Letflow.Modules.Assets.Reports
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.TokenMintFixture

  @role "TASK_WORKER"

  setup do
    fx = Fx.installed_tenant!("e2b-rep")
    {:ok, fx: fx, schema: fx.schema_name}
  end

  defp rows(schema),
    do: Repo.all(from(v in View, where: v.entity_type == "assets_card"), prefix: schema)

  defp holder!(schema, node_id) do
    group = RSG.group_of!(schema, @role)
    _removed = RSG.raw_delete_rows!(schema, group, @role)
    user = TokenMintFixture.role_holder!(schema, [@role])
    :ok = RSG.raw_user_row!(schema, user.id, @role, node_id)
    user
  end

  defp restrict!(schema) do
    Repo.insert_all(
      "entity_type_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: "assets_card",
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  test "R-1: install ships the Asset list report", %{schema: schema} do
    assert [view] = rows(schema)
    body = Reports.asset_list_body()
    assert view.kind == "report"
    assert view.name == "Asset list"
    assert view.filter in [[], nil]
    assert view.columns == body["columns"]
    assert [%{"field" => "inventory_number", "dir" => "asc"}] = view.sort
    assert [%{"fn" => "count"}] = view.aggregates
  end

  test "R-2: readable by a caller who may read the type, hidden from one denied it",
       %{fx: fx, schema: schema} do
    reader = TokenMintFixture.role_holder!(schema, [@role])
    conn = On.call(Letflow.Routers.EntityViews, :get, "/", fx, reader.id, [@role], :off, nil)
    assert conn.status == 200, conn.resp_body

    assert [%{"name" => "Asset list"}] =
             Jason.decode!(conn.resp_body)["items"]
             |> Enum.filter(&(&1["entity_type"] == "assets_card"))

    [view] = rows(schema)
    restrict!(schema)

    conn = On.call(Letflow.Routers.EntityViews, :get, "/", fx, reader.id, [@role], :off, nil)
    assert conn.status == 200, conn.resp_body

    refute Enum.any?(
             Jason.decode!(conn.resp_body)["items"],
             &(&1["entity_type"] == "assets_card")
           )

    conn =
      On.call(Letflow.Routers.EntityViews, :get, "/#{view.id}", fx, reader.id, [@role], :off, nil)

    assert conn.status == 404
  end

  test "R-3: a scoped reader replaying the report sees its units only", %{fx: fx, schema: schema} do
    u1 = Ecto.UUID.generate()
    u2 = Ecto.UUID.generate()
    for id <- [u1, u2], do: {:ok, _} = ScopeNodePaths.write({:insert, id, nil}, schema)
    Fx.card!(schema, "INV-2", %{"org_unit_id" => u2})
    Fx.card!(schema, "INV-1", %{"org_unit_id" => u1})

    [view] = rows(schema)
    body = %{"entity_type" => "assets_card", "sort" => view.sort}

    numbers = fn conn ->
      assert conn.status == 200, conn.resp_body

      conn.resp_body
      |> Jason.decode!()
      |> Map.fetch!("items")
      |> Enum.map(&get_in(&1, ["field_values", "inventory_number"]))
    end

    scoped = holder!(schema, u1)

    assert numbers.(
             On.call(Letflow.Routers.Entities, :post, "/query", fx, scoped.id, [@role], :on, body)
           ) ==
             ["INV-1"]

    wide = TokenMintFixture.role_holder!(schema, ["TENANT_ADMIN"])

    assert numbers.(
             On.call(
               Letflow.Routers.Entities,
               :post,
               "/query",
               fx,
               wide.id,
               ["TENANT_ADMIN"],
               :on,
               body
             )
           ) ==
             ["INV-1", "INV-2"]
  end

  test "R-4: ensure_asset_list is idempotent inside a transaction and keeps edits",
       %{schema: schema} do
    actor = Ecto.UUID.generate()

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               :ok = Reports.ensure_asset_list(schema, actor)
               Reports.ensure_asset_list(schema, actor)
             end)

    assert [view] = rows(schema)

    assert {:ok, _} =
             Views.update(schema, actor, view.id, %{
               "name" => "Asset list",
               "columns" => ["inventory_number"],
               "sort" => view.sort,
               "aggregates" => view.aggregates
             })

    assert {:ok, :ok} = Repo.transaction(fn -> Reports.ensure_asset_list(schema, actor) end)
    assert [%{columns: ["inventory_number"]}] = rows(schema)
  end

  test "R-6: another tenant's report is a different row and unreadable here", %{fx: fx} do
    other = Fx.installed_tenant!("e2b-rep2")
    [mine] = rows(fx.schema_name)
    [theirs] = rows(other.schema_name)
    refute mine.id == theirs.id

    admin = TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"])

    conn =
      On.call(
        Letflow.Routers.EntityViews,
        :get,
        "/#{theirs.id}",
        fx,
        admin.id,
        ["TENANT_ADMIN"],
        :off,
        nil
      )

    assert conn.status == 404
  end

  test "R-7: a restricted installer fails the seed and writes no row", %{schema: schema} do
    [view] = rows(schema)
    Repo.delete!(view, prefix: schema)
    restrict!(schema)

    assert {:ok, {:error, {:report_seed_failed, :not_found}}} =
             Repo.transaction(fn ->
               Reports.ensure_asset_list(schema, Ecto.UUID.generate())
             end)

    assert rows(schema) == []
  end
end
