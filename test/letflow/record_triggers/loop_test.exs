defmodule Letflow.RecordTriggers.LoopTest do
  @moduledoc """
  REQ-628 slice T-4 part B / GH #3507 (decision 0067 D4, criterion 6): loop suppression end to end
  through `Worker.run_tick/2`. L1: a binding whose script writes its own type is suppressed
  (`in_chain`). L2: a chain A -> B -> C -> D -> E stops at the depth cap (`depth_cap`) and the write
  that is suppressed still lands. `async: false` (tenant provisioning, application env).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Entities.Records
  alias Letflow.RecordTriggerRunFixture, as: R
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

  defp audits(schema, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema)

  defp create!(schema, type, fields) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: type,
          field_values: fields,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema,
        :tenant
      )

    record
  end

  test "L1 a binding on X whose script writes X is suppressed after the first run" do
    schema = R.tenant!("r628l1")
    id = R.record!(schema, R.type_a(), %{"label" => "L1", "note" => "N1", "cid" => "c1"})

    manifest =
      R.manifest(%{}, [
        %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => ["note"]}
      ])

    rule = R.publish!(schema, manifest)
    binding = RF.bind_script!(schema, R.type_a(), "updated", rule)

    R.reply(
      R.ok(%{
        "writes" => [
          %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => %{"note" => "N2"}}
        ]
      })
    )

    R.forward([:letflow, :record_triggers, :loop_suppressed])

    {:ok, _} =
      Records.update_record(
        %{
          entity_type: R.type_a(),
          record_id: id,
          field_values: %{"note" => "N0"},
          preserve_keys: MapSet.new(["label", "cid"]),
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema,
        :tenant
      )

    assert [%{status: :pending, depth: 0}] = RF.outbox_rows(schema)
    R.drain!(schema)

    # the script ran and wrote ...
    assert R.fields(schema, R.type_a(), id)["note"] == "N2"
    # ... but its write raised no second row for the same binding
    assert [%{status: :done}] = RF.outbox_rows(schema)

    assert_received {:telemetry, [:letflow, :record_triggers, :loop_suppressed],
                     %{reason: "in_chain"}}

    assert [%{resource_id: bid}] = audits(schema, "trigger_loop_suppressed")
    assert bid == binding.id
  end

  test "L2 a chain of four runs stops at the depth cap; the capped write still lands" do
    schema = R.chain_tenant!("r628l2")
    R.reply(R.chain_reply())
    [_ba, _bb, _bc, _bd, _be] = R.bind_chain!(schema)
    R.forward([:letflow, :record_triggers, :loop_suppressed])

    create!(schema, "r628_a", %{"label" => "x", "cid" => "a"})
    R.drain!(schema)

    rows = R.rows(schema)
    assert Enum.map(rows, & &1.depth) == [0, 1, 2, 3]
    assert Enum.map(rows, & &1.entity_type) == ~w(r628_a r628_b r628_c r628_d)
    assert Enum.all?(rows, &(&1.status == :done))

    # D's write to E would be depth 4: no row, a suppression with reason depth_cap
    assert_received {:telemetry, [:letflow, :record_triggers, :loop_suppressed],
                     %{reason: "depth_cap"}}

    assert [%{after_state: %{"depth" => 4, "reason" => "depth_cap"}}] =
             audits(schema, "trigger_loop_suppressed")

    # suppression stops the trigger, not the write
    assert R.count(schema, "r628_e") == 1
  end
end
