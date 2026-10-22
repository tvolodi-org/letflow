defmodule Letflow.Engine.ModuleWritePrivilegeTest do
  @moduledoc """
  GH #2725 gap 4 / REQ-501 design section 11 row "A handler cannot widen privilege": the
  `writable_by_process` flag (decision 0054 D4a.2) belongs to DECLARATIVE `entity_writes` lines on
  unmanaged types; it neither gates nor is widened by a module handler.

    * a module-managed type never carries the flag (`ProcessWritable.writable?/1` is false for a
      `managed_by` row) and the handler still writes it: the handler's authority is the module's
      registration, not the flag;
    * the flag is not a back door for the handler path: a MIXED node whose declarative line names
      an UNMANAGED type that is not (or no longer) `writable_by_process` is refused as
      `write_not_permitted` (audit detail `not_writable`) and the handler's records roll back
      with it;
    * an unmanaged type is no handler target at all, flag or not (`:target_not_registered`,
      `module_write_owner_path_test.exs`).

  `async: false`: the module install and tenant provisioning run DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ProcessWritable
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  test "a managed type is not writable_by_process, and the handler writes it all the same" do
    ctx = Mw.case!("gh2725-priv-managed", :module)

    for name <- ["fxl_ledger", "fxl_balance"] do
      row =
        Repo.one!(from(d in EntityDefinition, where: d.name == ^name and d.status == :active),
          prefix: ctx.schema
        )

      assert row.managed_by == "fixture_ledger"
      refute ProcessWritable.writable?(row)
      refute row.definition_json["writable_by_process"] == true
    end

    assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
    assert [_] = Fx.records(ctx.schema, "fxl_ledger")
    assert [_] = Fx.records(ctx.schema, "fxl_balance")
  end

  test "an unmanaged type without writable_by_process refuses a MIXED node and rolls the handler back" do
    ctx = Mw.case!("gh2725-priv-unflagged", :mixed)
    # the declarative line's type loses the flag (a new active version) after activation
    Fx.define_type!(ctx.schema, "stock_move", %{writable_by_process: false})

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(ctx, %{"label" => "L1"})

    assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
    assert entry.after_state["detail"] == "not_writable"
    assert Fx.all_records(ctx.schema) == []
    assert Fx.entity_events(ctx.schema) == []
    assert Fx.step_idempotency_count(ctx.schema) == 0
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
  end
end
