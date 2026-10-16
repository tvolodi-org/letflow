defmodule Letflow.Engine.ModuleWritesGuardTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4b (design 6.1, 6.3, section 11 rows "Handler runs inside the step Multi"
  and "Interim guard"): R3's interim guard (`check_module_writes_unsupported/2`, which refused
  every completion of a node declaring `module_writes`) is DELETED, and these tests flipped with
  it. A module-only node now WRITES the handler's records; a MIXED node writes the declarative
  record first and then the handler's; a node without `module_writes` is unchanged.

  The refusal paths (stamp, hash, event schema, argument failures) are in
  `module_write_runtime_stamp_test.exs` and `module_write_failure_codes_test.exs`; the
  deleted-definition fail-closed case in `module_write_deleted_definition_test.exs`.

  `async: false`: the module install and tenant provisioning run DDL.
  """

  use Letflow.DataCase, async: false

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  test "a module-only node: the completion writes the handler's two records and completes" do
    ctx = Mw.case!("gh2590-r4b-guard-m", :module)

    assert {:ok, result} = Fx.complete(ctx, %{"label" => "L1"})
    assert result.instance_status == :completed

    assert [%{field_values: %{"item" => "L1", "quantity" => 1}}] =
             Fx.records(ctx.schema, "fxl_ledger")

    assert [%{field_values: %{"item" => "L1", "quantity" => 1}}] =
             Fx.records(ctx.schema, "fxl_balance")

    assert Fx.task!(ctx.schema, ctx.task.id).status == :completed
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :completed
  end

  test "a MIXED node: the declarative record is written, then the handler's records" do
    ctx = Mw.case!("gh2590-r4b-guard-x", :mixed)

    assert {:ok, _result} = Fx.complete(ctx, %{"label" => "L1"})

    assert [_declared] = Fx.records(ctx.schema, "stock_move")
    assert [_ledger] = Fx.records(ctx.schema, "fxl_ledger")
    assert [_balance] = Fx.records(ctx.schema, "fxl_balance")

    # declarative line first (index 0), then the handler call (declared index 1)
    assert [stock, ledger, balance] = Fx.entity_events(ctx.schema)
    assert stock.global_seq < ledger.global_seq
    assert ledger.global_seq < balance.global_seq
  end

  test "a node without module_writes (absent, nil, []) completes exactly as before" do
    for attrs <- [%{}, %{"module_writes" => nil}, %{"module_writes" => []}] do
      base = Fx.tenant_case!("gh2590-r4b-guard-n")

      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "ht",
            "node_type" => "HUMAN_TASK",
            "attributes" => Map.put(attrs, "role", "REVIEWER")
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "ht"},
          %{"id" => "e2", "source" => "ht", "target" => "end"}
        ]
      }

      definition = Fx.activate!(base.schema, base.user, graph)
      {instance_id, task} = Fx.start!(base.schema, definition)
      ctx = Map.merge(base, %{instance_id: instance_id, task: task})

      assert {:ok, _result} = Fx.complete(ctx, %{})
      assert Fx.task!(ctx.schema, task.id).status == :completed
    end
  end

  test "a node with only declarative entity_writes still writes its records" do
    base =
      Fx.case!("gh2590-r4b-guard-e", [Fx.line("stock_move", %{"label" => %{"const" => "v"}})])

    result = Fx.complete_with_lines!(base, %{})
    assert result.instance_status == :completed
    assert [_one] = Fx.records(base.schema, "stock_move")
  end

  test "a malformed module_writes value in the pinned snapshot is refused, nothing committed" do
    ctx = Mw.case!("gh2590-r4b-guard-b", :module)

    Mw.tamper_snapshot!(ctx, fn graph ->
      update_in(graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "ht"} = node -> put_in(node, ["attributes", "module_writes"], "not-a-list")
          node -> node
        end)
      end)
    end)

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(ctx, %{"label" => "L1"})

    assert Fx.all_records(ctx.schema) == []
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
  end
end
