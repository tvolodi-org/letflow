defmodule Letflow.RecordTriggers.OutboxStepWritesTest do
  @moduledoc """
  REQ-606 / GH #3411 part 1, criterion 6 (decision 0067 D4): lineage cannot be forged through a
  process-step write. G5 is a module-handler write (`HandlerWrites`, through the real
  `Engine.complete_task/3`), G6 a declarative `entity_writes` line (`StepWrites`). Both carry the
  keys `trigger_lineage`, `depth` and `chain` as values that would suppress the trigger; the
  record is written and the outbox row still has depth 0 and an empty chain.

  `async: false`: module installs, tenant provisioning and the flag are global state.
  """

  use Letflow.DataCase, async: false

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.RecordTriggersFixture, as: RF

  setup do
    previous = Application.fetch_env(:letflow, :record_triggers_enabled)
    Application.put_env(:letflow, :record_triggers_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end
    end)

    :ok
  end

  # HandlerWrites can only write module-managed types, and a binding on a managed type is refused
  # (REQ-570, `:entity_type_managed`), so a handler write can never match a binding: there is no
  # lineage to forge. The test pins both halves: the refusal and the row-free handler write.
  test "G5 a module-handler write (HandlerWrites) cannot match a binding and inserts no row" do
    ctx = Mw.case!("r606-g5", :module)
    rule = RF.script!(ctx.schema, "entity_event", :published)

    pin = %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

    actor = %{user_id: Ecto.UUID.generate(), credential: :oidc, trace_id: "r606-g5"}

    assert {:error, :entity_type_managed} =
             Letflow.RecordTriggers.bind(ctx.schema, "fxl_ledger", "created", pin, actor)

    assert {:ok, _} =
             Fx.complete(ctx, %{
               "label" => "L1",
               "trigger_lineage" => "x",
               "depth" => 3,
               "chain" => ["any"]
             })

    assert [_ledger, _balance] = Fx.all_records(ctx.schema)
    assert RF.outbox_rows(ctx.schema) == []
  end

  test "G6 a declarative entity_writes line (StepWrites) with lineage-named fields keeps depth 0" do
    base = Fx.tenant_case!("r606-g6")

    Fx.define_type!(base.schema, "stock_move", %{
      fields:
        for(
          f <- ~w(label trigger_lineage depth chain),
          do: %{name: f, type: :string, required: f == "label"}
        )
    })

    binding = RF.bind!(base.schema, "stock_move", "created")

    lines = [
      Fx.line("stock_move", %{
        "label" => %{"const" => "a"},
        "trigger_lineage" => %{"const" => "x"},
        "depth" => %{"const" => "3"},
        "chain" => %{"const" => binding.id}
      })
    ]

    ctx = Fx.attach!(base, lines)
    assert {:ok, _} = Fx.complete(ctx, %{})

    assert [_record] = Fx.all_records(ctx.schema)
    assert [%{event: :created, depth: 0, chain: []}] = RF.outbox_rows(ctx.schema)
  end
end
