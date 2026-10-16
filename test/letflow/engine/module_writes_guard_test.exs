defmodule Letflow.Engine.ModuleWritesGuardTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R3 (design 6.3, F-3, section 11 row "Interim guard"): a graph with
  `module_writes` can already ACTIVATE, but nothing executes a handler until R4b, so a
  completion of a node declaring a non-empty `module_writes` is refused fail-closed, whether
  or not the node also declares `entity_writes` (a MIXED node HAS a plan, which the existing
  `entity_writes_not_planned` guard accepts). Nothing is committed and the task stays pending.

  A node without `module_writes` is unchanged. R4b deletes this guard together with these
  refusal assertions.

  `async: false`: the module install and tenant provisioning run DDL.
  """

  use Letflow.DataCase, async: false

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  defp written(ctx) do
    %{
      records: length(Fx.all_records(ctx.schema)),
      entity_events: length(Fx.entity_events(ctx.schema)),
      step_keys: Fx.step_idempotency_count(ctx.schema),
      line_audit: length(Fx.audit_rows(ctx.schema, "entity_write.process_step")),
      applied:
        length(Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")),
      instance_events: Fx.all_instance_event_count(ctx.schema, ctx.instance_id)
    }
  end

  defp assert_refused_and_nothing_written(ctx) do
    before = written(ctx)

    assert {:error, {:entity_write_failed, 0, :module_writes_not_enabled}} =
             Fx.complete(ctx, %{"label" => "L1"})

    assert written(ctx) == before
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
  end

  test "a module-only node: the completion is refused, nothing committed" do
    ctx = Mw.case!("gh2590-r3-guard-m", :module)
    assert_refused_and_nothing_written(ctx)
  end

  test "a MIXED node: the declarative record is NOT written either" do
    ctx = Mw.case!("gh2590-r3-guard-x", :mixed)

    assert_refused_and_nothing_written(ctx)
    assert Fx.records(ctx.schema, "stock_move") == []
    assert Fx.entity_events(ctx.schema) == []
  end

  test "the refusal is repeatable: a second attempt is refused the same way" do
    ctx = Mw.case!("gh2590-r3-guard-r", :module)
    assert_refused_and_nothing_written(ctx)
    assert_refused_and_nothing_written(ctx)
  end

  test "a node without module_writes (absent, nil, []) completes exactly as before" do
    for attrs <- [%{}, %{"module_writes" => nil}, %{"module_writes" => []}] do
      base = Fx.tenant_case!("gh2590-r3-guard-n")

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
    base = Fx.case!("gh2590-r3-guard-e", [Fx.line("stock_move", %{"label" => %{"const" => "v"}})])
    result = Fx.complete_with_lines!(base, %{})
    assert result.instance_status == :completed
    assert [_one] = Fx.records(base.schema, "stock_move")
  end
end
