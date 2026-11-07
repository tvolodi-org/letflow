Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CardScopeTest do
  @moduledoc """
  GH #3894 / REQ-748 criteria 5 and 6 (tests A-SCP-1..4; INV-1, INV-5, INV-6, INV-10): the scope
  declaration `{:column, "org_unit_id"}` resolves after install, cannot be replaced by a tenant, a
  scoped reader sees only the cards of its org unit through the real `POST /query` route, and the
  admin of another tenant sees none of them.

  `async: false`: real committed tenants.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Entities.ScopeDeclarations
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.TokenMintFixture

  @router Letflow.Routers.Entities
  @role "TASK_WORKER"

  setup do
    fx = Fx.installed_tenant!("gh3894-scp")
    schema = fx.schema_name
    u1 = Ecto.UUID.generate()
    u2 = Ecto.UUID.generate()
    for id <- [u1, u2], do: {:ok, _} = ScopeNodePaths.write({:insert, id, nil}, schema)
    c1 = Fx.card!(schema, "INV-1", %{"org_unit_id" => u1})
    c2 = Fx.card!(schema, "INV-2", %{"org_unit_id" => u2})
    {:ok, fx: fx, schema: schema, u1: u1, u2: u2, c1: c1, c2: c2}
  end

  defp holder!(schema, node_id) do
    group = RSG.group_of!(schema, @role)
    _removed = RSG.raw_delete_rows!(schema, group, @role)
    user = TokenMintFixture.role_holder!(schema, [@role])
    :ok = RSG.raw_user_row!(schema, user.id, @role, node_id)
    user
  end

  defp query(fx, user, body),
    do: On.call(@router, :post, "/query", fx, user.id, [@role], :on, body)

  defp numbers(conn) do
    assert conn.status == 200, conn.resp_body

    conn.resp_body
    |> Jason.decode!()
    |> Map.fetch!("items")
    |> Enum.map(&get_in(&1, ["field_values", "inventory_number"]))
    |> Enum.sort()
  end

  test "A-SCP-1: the declaration is the column after install", %{schema: schema} do
    assert ScopeDeclaration.for_type("assets_card", schema) == {:column, "org_unit_id"}
  end

  test "A-SCP-2: a tenant cannot replace the declaration of the managed type", %{
    schema: schema
  } do
    assert {:error, :entity_type_managed} =
             ScopeDeclarations.put_audited(
               %{"entity_type" => "assets_card", "kind" => "tenant_wide"},
               %{user_id: Ecto.UUID.generate(), trace_id: "t"},
               schema
             )

    assert {:error, :entity_type_managed} =
             ScopeDeclarations.put_audited(
               %{"entity_type" => "assets_card", "kind" => "column", "field" => "name"},
               %{user_id: Ecto.UUID.generate(), trace_id: "t"},
               schema
             )

    # a raw planted row for the managed name is ignored (decision 0051 M4)
    {1, _} =
      Repo.insert_all(
        "entity_scope_declarations",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: "assets_card",
            set_by: Ecto.UUID.bingenerate(),
            kind: "tenant_wide",
            field: nil,
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ],
        prefix: schema
      )

    assert ScopeDeclaration.for_type("assets_card", schema) == {:column, "org_unit_id"}
  end

  test "A-SCP-3: a reader scoped to U1 sees the U1 card only, also when filtering on the U2 card",
       %{fx: fx, schema: schema, u1: u1} do
    scoped = holder!(schema, u1)
    body = %{"entity_type" => "assets_card"}

    assert numbers(query(fx, scoped, body)) == ["INV-1"]

    by_org =
      Map.put(body, "filters", [
        %{"field" => "inventory_number", "op" => "eq", "value" => "INV-2"}
      ])

    assert numbers(query(fx, scoped, by_org)) == []

    # a tenant-wide holder sees both
    wide = holder!(schema, nil)
    assert numbers(query(fx, wide, body)) == ["INV-1", "INV-2"]
  end

  test "A-SCP-4: the admin of another tenant sees no card of this tenant (INV-10)", %{c1: c1} do
    other = Fx.installed_tenant!("gh3894-oth")
    Fx.card!(other.schema_name, "OTHER-1")

    conn =
      On.call(@router, :post, "/query", other, other.admin.id, ["TENANT_ADMIN"], :off, %{
        "entity_type" => "assets_card"
      })

    assert numbers(conn) == ["OTHER-1"]

    filtered =
      On.call(@router, :post, "/query", other, other.admin.id, ["TENANT_ADMIN"], :off, %{
        "entity_type" => "assets_card",
        "filters" => [%{"field" => "inventory_number", "op" => "eq", "value" => "INV-1"}]
      })

    assert numbers(filtered) == []

    # a direct read of the other tenant's record id is the uniform not found
    hist =
      On.call(
        @router,
        :get,
        "/records/assets_card/#{c1.record_id}/history",
        other,
        other.admin.id,
        ["TENANT_ADMIN"],
        :off,
        nil
      )

    assert hist.status == 404, hist.resp_body
  end
end
