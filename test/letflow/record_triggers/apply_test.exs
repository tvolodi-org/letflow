defmodule Letflow.RecordTriggers.ApplyTest do
  @moduledoc """
  REQ-628 slice T-4 part A / GH #3507 (decision 0067 D2/D3/D7): `Letflow.RecordTriggers.Apply` and
  the worker's `run_row/2`. Test ids follow the design: A1 (end to end through a tick), D1 (result
  transaction and keys), D5 (CAS), D6 (lock order), D7 (smoke of the failure paths), D8 (retry cap).
  `async: false` (tenant provisioning, application env).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Records
  alias Letflow.RecordTriggers.Apply
  alias Letflow.RecordTriggers.Worker
  alias Letflow.RecordTriggerRunFixture, as: R
  alias Letflow.Support.PlatformTenantFixture

  setup do
    schema = R.tenant!("r628a")
    previous = Application.fetch_env(:letflow, :record_triggers_enabled)
    Application.put_env(:letflow, :record_triggers_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end

      Application.delete_env(:letflow, :record_trigger_worker)
    end)

    id = R.record!(schema, R.type_a(), %{"label" => "L1", "note" => "N1", "cid" => "c1"})
    rule = R.publish!(schema)
    {:ok, schema: schema, id: id, rule: rule}
  end

  defp update_line(index, note),
    do: %{
      index: index,
      entity_type: R.type_a(),
      mode: "update_self",
      fields: %{"note" => note},
      external_ref: nil
    }

  defp create_line(index, label),
    do: %{
      index: index,
      entity_type: R.type_b(),
      mode: "create",
      fields: %{"label" => label},
      external_ref: nil
    }

  defp lineage(row), do: %{depth: row.depth, chain: row.chain ++ [row.binding_id]}

  describe "A1: a tick runs the row end to end" do
    test "the stub runner's lines are applied and the row is done", %{
      schema: s,
      id: id,
      rule: rule
    } do
      R.reply(
        R.ok(%{
          "writes" => [
            %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => %{"note" => "N2"}}
          ]
        })
      )

      row = R.claimed_row!(s, rule, id)
      # put the claimed row back to pending so the tick claims it itself
      Repo.update_all(
        from(r in Letflow.RecordTriggers.OutboxRow, where: r.id == ^row.id),
        [set: [status: :pending, attempt: 0]],
        prefix: s
      )

      {summary, _} = Worker.run_tick([s], 0)

      assert summary.claimed == 1 and summary.done == 1
      assert R.fetch(s, row.id).status == :done
      assert R.fields(s, R.type_a(), id) == %{"label" => "L1", "note" => "N2", "cid" => "c1"}
    end
  end

  describe "D1: the result transaction" do
    test "two lines apply together; keys are record_trigger:<row id>:<index>", %{
      schema: s,
      id: id,
      rule: rule
    } do
      row = R.claimed_row!(s, rule, id)

      assert Apply.apply_result(row, [update_line(0, "N2"), create_line(1, "child")], s) == :done

      assert R.fetch(s, row.id).status == :done
      assert R.fetch(s, row.id).done_at != nil
      # the stored document keeps every key the line did not set
      assert R.fields(s, R.type_a(), id) == %{"label" => "L1", "note" => "N2", "cid" => "c1"}
      assert R.count(s, R.type_b()) == 1

      # the keys are stored: a replay under the same key (with the lineage) is a duplicate
      assert {:ok, %{is_duplicate: true}} =
               Records.create_record(
                 %{
                   entity_type: R.type_b(),
                   field_values: %{"label" => "child"},
                   actor_id: row.actor_id,
                   idempotency_key: "record_trigger:#{row.id}:1"
                 },
                 s,
                 :tenant,
                 trigger_lineage: lineage(row)
               )

      assert R.count(s, R.type_b()) == 1
    end

    test "D1b command_multi/3 is not used" do
      refute File.read!("lib/letflow/record_triggers/apply.ex") =~ "command_multi("
    end

    test "D1c zero lines only flips the row to done", %{schema: s, id: id, rule: rule} do
      row = R.claimed_row!(s, rule, id)
      assert Apply.apply_result(row, [], s) == :done
      assert R.fields(s, R.type_a(), id)["note"] == "N1"
    end
  end

  describe "D5: compare and set" do
    test "a row that is no longer this claim writes nothing", %{schema: s, id: id, rule: rule} do
      row = R.claimed_row!(s, rule, id)

      assert Apply.apply_result(%{row | attempt: row.attempt + 1}, [create_line(0, "x")], s) ==
               :stale

      assert R.count(s, R.type_b()) == 0
      assert Apply.finish(%{row | attempt: 9}, s, {:dead, "x"}) == :stale
      assert R.fetch(s, row.id).status == :running

      assert Apply.apply_result(row, [], s) == :done
      assert Apply.apply_result(row, [create_line(0, "x")], s) == :stale
      assert R.count(s, R.type_b()) == 0
    end
  end

  describe "D6: lock order" do
    test "the outbox row is locked first, then the type sequence rows ascending", %{
      schema: s,
      id: id,
      rule: rule
    } do
      row = R.claimed_row!(s, rule, id)
      # create the second type's sequence row first, so both registry rows exist
      R.record!(s, R.type_b(), %{"label" => "seed"})

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Apply.apply_result(row, [create_line(0, "z"), update_line(1, "N2")], s)
        end)

      assert result == :done
      locks = queries |> Enum.map(& &1.query) |> Enum.filter(&(&1 =~ "FOR UPDATE"))

      assert Enum.at(locks, 0) =~ "record_trigger_outbox"
      assert Enum.at(locks, 1) =~ "instance_sequence"
      assert Enum.at(locks, 2) =~ "instance_sequence"
    end
  end

  describe "D7: failure paths" do
    test "a refused line rolls the whole transaction back", %{schema: s, id: id, rule: rule} do
      row = R.claimed_row!(s, rule, id)
      bad = %{create_line(1, "x") | fields: %{"no_such_field" => "x"}}

      assert Apply.apply_result(row, [update_line(0, "N2"), bad], s) ==
               {:dead, "trigger_write_refused"}

      assert R.fields(s, R.type_a(), id)["note"] == "N1"
      assert R.fetch(s, row.id).status == :running
      assert Apply.finish(row, s, {:dead, "trigger_write_refused"}) == :dead
      assert R.fetch(s, row.id).last_code == "trigger_write_refused"
    end

    test "update_self on a deleted source record is refused", %{schema: s, id: id, rule: rule} do
      row = R.claimed_row!(s, rule, id)

      {:ok, _} =
        Records.delete_record(
          %{
            entity_type: R.type_a(),
            record_id: id,
            actor_id: row.actor_id,
            idempotency_key: "d1"
          },
          s,
          :tenant
        )

      assert Apply.apply_result(row, [update_line(0, "N2")], s) ==
               {:dead, "trigger_write_refused"}
    end
  end

  describe "D8: retry cap" do
    test "a retry below the cap goes back to pending with the backoff", %{
      schema: s,
      id: id,
      rule: rule
    } do
      row = R.claimed_row!(s, rule, id)
      before = DateTime.utc_now()

      assert Apply.finish(row, s, {:retry, "script_busy"}) == :retry
      stored = R.fetch(s, row.id)

      assert stored.status == :pending and stored.last_code == "script_busy"
      wait = DateTime.diff(stored.next_attempt_at, before, :millisecond)
      assert wait >= Worker.backoff_ms(row.attempt) - 1_000
      assert wait <= Worker.backoff_ms(row.attempt) + 5_000
    end

    test "a retry at max_attempts is dead with retries_exhausted", %{
      schema: s,
      id: id,
      rule: rule
    } do
      Application.put_env(:letflow, :record_trigger_worker, max_attempts: 1)
      row = R.claimed_row!(s, rule, id)

      assert row.attempt == 1
      assert Apply.finish(row, s, {:retry, "script_busy"}) == :dead
      stored = R.fetch(s, row.id)
      assert stored.status == :dead and stored.last_code == "retries_exhausted"
    end
  end
end
