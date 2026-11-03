Code.require_file("codes_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)
Code.require_file("../locations/locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.WritesLifecycleTest do
  @moduledoc """
  GH #3615 / REQ-663 criteria 3 to 7 (tests L1, L2, T1, V1, A2..A5, X1): assign, release, retire and
  change value on real provisioned tenants with `codes`, `locations` and `catalog_items` installed.
  `async: false`: provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.CodesFixture, as: Fx
  alias Letflow.Entities.Record.Latest
  alias Letflow.LocationsFixture, as: Loc
  alias Letflow.Modules.Codes

  setup do
    ctx = Fx.installed_tenant!("gh3615-lc")
    Fx.install_module!(ctx.tenant_id, "org")
    Fx.install_module!(ctx.tenant_id, "locations")
    Fx.install_module!(ctx.tenant_id, "catalog_items")
    uom = Cat.uom!(ctx.schema, "U1")
    item = Cat.item!(ctx.schema, "I1", uom.record_id)
    node = Loc.node!(ctx.schema, "N1")
    {:ok, Map.merge(ctx, %{item: item, node: node, uom: uom})}
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  defp new_code!(schema, value \\ "C1") do
    {:ok, [c]} = Codes.receive_codes(schema, [%{"value" => value, "kind" => "barcode"}], opts())
    c["code_id"]
  end

  defp audit_rows(schema) do
    Letflow.Repo.all(
      from(e in Audit.Entry, where: like(e.action, "code.%"), order_by: e.timestamp),
      prefix: schema
    )
  end

  defp count(schema, type) do
    Letflow.Repo.aggregate(from(l in Latest, where: l.entity_type == ^type), :count,
      prefix: schema
    )
  end

  test "L1, A2: the full lifecycle with history and one audit entry per change", ctx do
    s = ctx.schema
    id = new_code!(s)

    assert {:ok, %{"status" => "assigned", "target_type" => "location_node"}} =
             Codes.assign_code(s, id, "location_node", ctx.node.record_id, opts())

    assert Codes.assign_code(s, id, "catalog_item", ctx.item.record_id, opts()) ==
             {:error, :code_assigned}

    assert {:ok, %{"status" => "not_assigned", "target_id" => nil}} =
             Codes.release_code(s, id, opts())

    assert Codes.release_code(s, id, opts()) == {:error, :code_not_assigned}

    assert {:ok, %{"status" => "assigned", "target_type" => "catalog_item"}} =
             Codes.assign_code(s, id, "catalog_item", ctx.item.record_id, opts())

    assert {:ok, %{"status" => "retired", "target_id" => nil}} = Codes.retire_code(s, id, opts())

    assert [
             %{"target_type" => "location_node", "released_at" => r1},
             %{"target_type" => "catalog_item", "released_at" => r2}
           ] =
             Codes.assignment_history(s, id)

    assert r1 && r2

    assert Codes.assign_code(s, id, "location_node", ctx.node.record_id, opts()) ==
             {:error, :code_retired}

    assert Codes.release_code(s, id, opts()) == {:error, :code_not_assigned}

    assert Enum.map(audit_rows(s), & &1.action) ==
             ["code.received", "code.assigned", "code.released", "code.assigned", "code.retired"]

    assert Enum.all?(audit_rows(s), &(&1.resource_id == id and &1.resource_type == "code_tag"))
  end

  test "A5: retiring a retired code is a no-op", ctx do
    s = ctx.schema
    id = new_code!(s)
    assert {:ok, %{"status" => "retired"}} = Codes.retire_code(s, id, opts())
    before = length(audit_rows(s))
    assert {:ok, %{"status" => "retired"}} = Codes.retire_code(s, id, opts())
    assert length(audit_rows(s)) == before
  end

  test "T1: target refusals leave no assignment", ctx do
    s = ctx.schema
    id = new_code!(s)
    other_type_id = ctx.item.record_id
    dead = Loc.node!(s, "N-dead")
    Loc.delete!(s, dead)
    off = Loc.node!(s, "N-off", "site", %{"active" => false})

    assert Codes.assign_code(s, id, "org_unit", ctx.node.record_id, opts()) ==
             {:error, :target_type_not_allowed}

    assert Codes.assign_code(s, id, nil, ctx.node.record_id, opts()) ==
             {:error, :target_type_not_allowed}

    for bad <- ["x", nil, 5, Ecto.UUID.generate(), dead.record_id, other_type_id] do
      assert Codes.assign_code(s, id, "location_node", bad, opts()) == {:error, :target_not_found}
    end

    assert Codes.assign_code(s, id, "location_node", off.record_id, opts()) ==
             {:error, :target_inactive}

    assert count(s, "code_assignment") == 0
    assert {:ok, %{"status" => "not_assigned"}} = Codes.resolve(s, "C1")
  end

  test "T2: the module stays free of dependencies" do
    assert Codes.manifest().depends_on == []
  end

  test "V1: change value keeps the record id and the history", ctx do
    s = ctx.schema
    id = new_code!(s)
    {:ok, _} = Codes.assign_code(s, id, "location_node", ctx.node.record_id, opts())

    assert {:ok, %{"code_id" => ^id, "value" => "C2", "status" => "assigned"}} =
             Codes.change_code_value(s, id, "C2", opts())

    assert {:ok, %{"code_id" => ^id}} = Codes.resolve(s, "C2")
    assert Codes.resolve(s, "C1") == {:error, :not_found}
    assert [%{"old_value" => "C1", "new_value" => "C2"}] = Codes.value_history(s, id)
    assert [%{"released_at" => nil}] = Codes.assignment_history(s, id)

    other = new_code!(s, "C9")
    assert Codes.change_code_value(s, other, "C2", opts()) == {:error, :value_taken}
    assert Codes.change_code_value(s, other, "", opts()) == {:error, :value_invalid}
    assert Codes.change_code_value(s, other, nil, opts()) == {:error, :value_invalid}
    assert {:ok, %{"value" => "C9"}} = Codes.change_code_value(s, other, "C9", opts())
    assert length(Codes.value_history(s, other)) == 0

    {:ok, _} = Codes.retire_code(s, other, opts())
    assert Codes.change_code_value(s, other, "C10", opts()) == {:error, :code_retired}
    # a retired code keeps its value reserved
    assert Codes.change_code_value(s, id, "C9", opts()) == {:error, :value_taken}
  end

  test "A3: refusals write no record and no audit entry", ctx do
    s = ctx.schema
    id = new_code!(s)
    audit = length(audit_rows(s))
    tags = count(s, "code_tag")

    assert Codes.release_code(s, id, opts()) == {:error, :code_not_assigned}
    assert Codes.assign_code(s, id, "org_unit", "x", opts()) == {:error, :target_type_not_allowed}
    assert Codes.change_code_value(s, id, "", opts()) == {:error, :value_invalid}
    assert length(audit_rows(s)) == audit
    assert count(s, "code_tag") == tags
    assert count(s, "code_assignment") == 0
    assert count(s, "code_value_change") == 0
  end

  test "A4: a repeated key writes nothing new for each function", ctx do
    s = ctx.schema
    id = new_code!(s)
    keyed = fn -> %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()} end

    o1 = keyed.()
    {:ok, first} = Codes.assign_code(s, id, "location_node", ctx.node.record_id, o1)
    snap = {length(audit_rows(s)), count(s, "code_assignment")}
    assert Codes.assign_code(s, id, "location_node", ctx.node.record_id, o1) == {:ok, first}
    assert {length(audit_rows(s)), count(s, "code_assignment")} == snap

    o2 = keyed.()
    {:ok, rel} = Codes.release_code(s, id, o2)
    n = length(audit_rows(s))
    assert Codes.release_code(s, id, o2) == {:ok, rel}
    assert length(audit_rows(s)) == n

    o3 = keyed.()
    {:ok, chg} = Codes.change_code_value(s, id, "NEW", o3)
    n = length(audit_rows(s))
    assert Codes.change_code_value(s, id, "NEW", o3) == {:ok, chg}
    assert length(audit_rows(s)) == n
    assert count(s, "code_value_change") == 1

    o4 = keyed.()
    {:ok, ret} = Codes.retire_code(s, id, o4)
    n = length(audit_rows(s))
    assert Codes.retire_code(s, id, o4) == {:ok, ret}
    assert length(audit_rows(s)) == n
  end

  test "L2: a damaged state of two open assignments is refused and nothing is written", ctx do
    s = ctx.schema
    id = new_code!(s)
    tag = Letflow.Repo.one(from(l in Latest, where: l.record_id == ^id), prefix: s)
    Fx.assign!(s, tag, "location_node", ctx.node.record_id)
    Fx.assign!(s, tag, "location_node", ctx.node.record_id)
    audit = length(audit_rows(s))

    assert Codes.assign_code(s, id, "location_node", ctx.node.record_id, opts()) ==
             {:error, :assignment_conflict}

    Fx.set_status!(
      s,
      Letflow.Repo.one(from(l in Latest, where: l.record_id == ^id), prefix: s),
      "assigned"
    )

    assert Codes.release_code(s, id, opts()) == {:error, :assignment_conflict}
    assert length(audit_rows(s)) == audit
    assert count(s, "code_assignment") == 2
    assert Enum.all?(Codes.assignment_history(s, id), &is_nil(&1["released_at"]))
  end

  test "X1: another tenant's code id is code_not_found, a foreign target is target_not_found",
       ctx do
    s = ctx.schema
    id = new_code!(s)
    other = Fx.installed_tenant!("gh3615-lc2")
    Fx.install_module!(other.tenant_id, "org")
    Fx.install_module!(other.tenant_id, "locations")
    foreign_node = Loc.node!(other.schema, "FN")
    unknown = Ecto.UUID.generate()

    for fun <- [
          &Codes.assign_code(other.schema, &1, "location_node", ctx.node.record_id, opts()),
          &Codes.release_code(other.schema, &1, opts()),
          &Codes.retire_code(other.schema, &1, opts()),
          &Codes.change_code_value(other.schema, &1, "Z", opts())
        ] do
      assert fun.(id) == {:error, :code_not_found}
      assert fun.(id) == fun.(unknown)
    end

    assert Codes.assign_code(s, id, "location_node", foreign_node.record_id, opts()) ==
             {:error, :target_not_found}

    assert count(other.schema, "code_tag") == 0
    assert count(other.schema, "code_assignment") == 0
    assert {:ok, %{"status" => "not_assigned"}} = Codes.resolve(s, "C1")
  end
end
