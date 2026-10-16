defmodule Letflow.Engine.ModuleWriteDeletedDefinitionTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R3 (design OQ-R9, 6.3, section 11 row "Deleted stamped definition"):
  the tenant owns the lifecycle of a module-shipped definition, so its row can disappear while
  instances pinned to it are running. Those instances must fail CLOSED: a completion of a node
  declaring `module_writes` is refused, never executed without a readable stamp. Nothing is
  committed and the task stays pending.

  The pinned snapshot carries the graph, so the refusal does not depend on the (gone) row. The
  foreign key from the snapshot to the definition is dropped inside the test's own throwaway
  tenant schema to make the row removable; the schema is dropped at teardown.

  `async: false`: the module install and tenant provisioning run DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  defp delete_definition_row!(ctx) do
    Repo.query!(
      ~s(ALTER TABLE "#{ctx.schema}"."instance_definition_snapshots" ) <>
        "DROP CONSTRAINT instance_definition_snapshots_definition_id_fkey"
    )

    assert {1, _} =
             Repo.delete_all(from(d in ProcessDefinition, where: d.id == ^ctx.definition.id),
               prefix: ctx.schema
             )

    refute Repo.get(ProcessDefinition, ctx.definition.id, prefix: ctx.schema)
  end

  defp written(ctx) do
    %{
      records: length(Fx.all_records(ctx.schema)),
      entity_events: length(Fx.entity_events(ctx.schema)),
      step_keys: Fx.step_idempotency_count(ctx.schema),
      instance_events: Fx.all_instance_event_count(ctx.schema, ctx.instance_id)
    }
  end

  test "a module-only node of a deleted stamped definition: refused, nothing committed" do
    ctx = Mw.case!("gh2590-r3-del-m", :module)
    delete_definition_row!(ctx)
    before = written(ctx)

    assert {:error, {:entity_write_failed, 0, :module_writes_not_enabled}} =
             Fx.complete(ctx, %{"label" => "L1"})

    assert written(ctx) == before
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
  end

  test "a MIXED node of a deleted stamped definition: refused, the declarative record is not written" do
    ctx = Mw.case!("gh2590-r3-del-x", :mixed)

    delete_definition_row!(ctx)
    before = written(ctx)

    # no readable row, so no plan: refused by the existing "lines but no plan" guard
    assert {:error, {:entity_write_failed, 0, :not_planned}} =
             Fx.complete(ctx, %{"label" => "L1"})

    assert written(ctx) == before
    assert Fx.records(ctx.schema, "stock_move") == []
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
  end
end
