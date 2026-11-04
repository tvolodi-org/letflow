defmodule Letflow.RecordTriggers.DeadLetterTest do
  @moduledoc """
  REQ-638 slice T-5 part A / GH #3561 (decision 0067 D2/D7/D8, criteria 1-6 and 8): a dead
  `record_trigger_outbox` row is visible to the tenant. R: every closed dead code of the D7 table
  gives a dead row with one DLQ entry; Q: the DLQ entry shape, a failing enqueue and a lost
  compare-and-set; N: a second death; A: the metadata-only audit record; K: the tenant kill switch;
  L: the edge-triggered `record_trigger_dead` alert; W: no text leaks; X: two tenants.
  `async: false` (tenant provisioning, application env, log capture).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry, as: AuditEntry
  alias Letflow.Dlq.Entry, as: DlqEntry
  alias Letflow.Obs.AlertTriggerState
  alias Letflow.Obs.Alerts
  alias Letflow.RecordTriggers.Apply
  alias Letflow.RecordTriggers.OutboxRow
  alias Letflow.RecordTriggers.Worker
  alias Letflow.RecordTriggerRunFixture, as: R
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @base_keys ~w(attempt last_code outbox_id outcome principal script_key script_sha256 script_version)

  setup do
    schema = R.tenant!("r638d")
    id = R.record!(schema, R.type_a(), %{"label" => "L1", "note" => "N1", "cid" => "c1"})
    {:ok, schema: schema, id: id, rule: R.publish!(schema)}
  end

  defp dlq(schema),
    do: Letflow.Repo.all(from(e in DlqEntry, order_by: e.created_at), prefix: schema)

  defp audits(schema),
    do:
      Letflow.Repo.all(from(e in AuditEntry, where: e.action == "record_trigger_dead"),
        prefix: schema
      )

  defp set_columns(schema, id, set) do
    {1, _} =
      Letflow.Repo.update_all(from(r in OutboxRow, where: r.id == ^id), [set: set],
        prefix: schema
      )

    :ok
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp alert_state(schema),
    do: Letflow.Repo.get(AlertTriggerState, "record_trigger_dead", prefix: schema)

  defp alert_lines(log), do: length(String.split(log, "record trigger dead", trim: false)) - 1

  # runs one claimed row to its end with a runner reply
  defp run_dead(schema, rule, id, reply) do
    R.reply(reply)
    row = R.claimed_row!(schema, rule, id)
    {row, Worker.run_row(row, schema)}
  end

  describe "R/Q: every dead row has exactly one DLQ entry" do
    test "R1-R6 each sandbox failure code is dead with its closed code", %{
      schema: s,
      id: id,
      rule: rule
    } do
      cases = [
        {{:error, :script_failed, %{}}, "script_failed"},
        {{:error, :script_error, %{}}, "script_error"},
        {{:error, :budget_exceeded, %{}}, "budget_exceeded"},
        {{:error, :memory_limit_exceeded, %{}}, "memory_limit_exceeded"},
        {{:error, :timeout, %{}}, "timeout"},
        {{:error, :output_invalid, %{}}, "output_invalid"},
        {R.ok(%{"nope" => 1}), "output_invalid"}
      ]

      for {{reply, code}, n} <- Enum.with_index(cases, 1) do
        {row, :dead} = run_dead(s, rule, id, reply)
        assert R.fetch(s, row.id).status == :dead
        assert R.fetch(s, row.id).last_code == code
        assert length(dlq(s)) == n
        assert length(audits(s)) == n
      end

      assert Enum.all?(dlq(s), &(&1.entry_type == "record_trigger"))
    end

    test "R7 a busy sandbox is a retry: pending, attempt kept, no DLQ entry", %{
      schema: s,
      id: id,
      rule: rule
    } do
      {row, :retry} = run_dead(s, rule, id, {:error, :script_busy, %{}})
      stored = R.fetch(s, row.id)
      assert stored.status == :pending and stored.last_code == "script_busy"
      assert stored.attempt == 1
      assert dlq(s) == [] and audits(s) == []
    end

    test "R8 a raised, thrown or exited runner is dead script_error", %{
      schema: s,
      id: id,
      rule: rule
    } do
      for failure <- [fn _ -> raise "x" end, fn _ -> throw(:x) end, fn _ -> exit(:x) end] do
        {row, :dead} = run_dead(s, rule, id, failure)
        assert R.fetch(s, row.id).last_code == "script_error"
      end

      assert length(dlq(s)) == 3
    end

    test "R10 unavailable, revoked and pin-mismatch pins are dead and visible", %{
      schema: s,
      id: id,
      rule: rule
    } do
      R.reply(R.ok(%{"writes" => []}))
      absent = R.claimed_row!(s, rule, id, script_version: 99)
      assert Worker.run_row(absent, s) == :dead
      assert R.fetch(s, absent.id).last_code == "script_unavailable"

      wrong = R.claimed_row!(s, rule, id, script_sha256: String.duplicate("b", 64))
      assert Worker.run_row(wrong, s) == :dead
      assert R.fetch(s, wrong.id).last_code == "pin_mismatch"

      revoked = R.publish!(s)
      F.revoke_raw!(s, revoked)
      row = R.claimed_row!(s, revoked, id)
      assert Worker.run_row(row, s) == :dead
      assert R.fetch(s, row.id).last_code == "script_revoked"

      assert Enum.sort(Enum.map(dlq(s), & &1.reason)) ==
               ["pin_mismatch", "script_revoked", "script_unavailable"]
    end

    test "R13 a refused write is dead trigger_write_refused with one entry", %{
      schema: s,
      id: id
    } do
      manifest =
        R.manifest(%{}, [
          %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => ["note"]},
          %{"entity_type" => R.type_b(), "mode" => "create", "fields" => ["label", "ghost"]}
        ])

      rule = R.publish!(s, manifest)

      reply =
        R.ok(%{
          "writes" => [
            %{"entity_type" => R.type_b(), "mode" => "create", "fields" => %{"ghost" => "x"}}
          ]
        })

      {row, :dead} = run_dead(s, rule, id, reply)
      assert R.fetch(s, row.id).last_code == "trigger_write_refused"
      assert [%{reason: "trigger_write_refused", reference_id: ref}] = dlq(s)
      assert ref == row.id
    end

    test "R12 a lease that expired at the cap is dead with one entry; below it, pending", %{
      schema: s,
      id: id,
      rule: rule
    } do
      R.reply(R.ok(%{"writes" => []}))
      low = R.claimed_row!(s, rule, id)
      :ok = set_columns(s, low.id, lease_expires_at: ago(60))
      assert %{swept: 1, dead: 0} = Worker.sweep_expired_leases(s, 64)
      assert R.fetch(s, low.id).last_code == "lease_expired"
      assert dlq(s) == []

      other_id = R.record!(s, R.type_a(), %{"label" => "L2", "note" => "N2", "cid" => "c2"})
      capped = R.claimed_row!(s, rule, other_id)
      :ok = set_columns(s, capped.id, lease_expires_at: ago(60), attempt: 10)
      assert %{swept: 1, dead: 1, failed: 0} = Worker.sweep_expired_leases(s, 64)
      assert R.fetch(s, capped.id).last_code == "retries_exhausted"
      assert [%{reason: "retries_exhausted", reference_id: ref}] = dlq(s)
      assert ref == capped.id
      assert [%{after_state: %{"last_code" => "retries_exhausted"} = state}] = audits(s)
      assert state["script_key"] == rule.key
    end

    test "Q4 a retry at the cap through finish/4 is dead retries_exhausted with one entry", %{
      schema: s,
      id: id,
      rule: rule
    } do
      R.reply(R.ok(%{"writes" => []}))
      row = R.claimed_row!(s, rule, id)
      :ok = set_columns(s, row.id, attempt: 10)
      capped = %{row | attempt: 10}
      assert Apply.finish(capped, s, {:retry, "entity_write_contention"}) == :dead
      assert [%{reason: "retries_exhausted"}] = dlq(s)
    end

    test "Q1 the entry holds ids and the closed code only, never a record value", %{
      schema: s,
      id: id,
      rule: rule
    } do
      {row, :dead} = run_dead(s, rule, id, {:error, :script_error, %{}})
      assert [entry] = dlq(s)

      assert %{
               entry_type: "record_trigger",
               instance_id: nil,
               reference_id: ref,
               status: :pending,
               reason: "script_error"
             } = entry

      assert ref == row.id

      assert [
               entry.full_reason,
               entry.error_detail,
               entry.error_chain,
               entry.source_payload,
               entry.context_json
             ] ==
               [nil, nil, nil, nil, nil]

      refute inspect(entry) =~ "N1"
    end

    test "Q2 a failing DLQ insert rolls the status back; the sweep returns the row", %{
      schema: s,
      id: id,
      rule: rule
    } do
      R.reply({:error, :script_error, %{}})
      row = R.claimed_row!(s, rule, id)
      R.put_env(:record_trigger_dlq_enqueue, fn _attrs, _opts -> {:error, :boom} end)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert Worker.run_row(row, s) == :retry
        end)

      stored = R.fetch(s, row.id)
      assert stored.status == :running and stored.last_code == nil
      assert dlq(s) == [] and audits(s) == []
      assert log =~ "dead-letter entry failed"
      refute log =~ "boom"
      assert alert_state(s) == nil or alert_state(s).is_armed

      :ok = set_columns(s, row.id, lease_expires_at: ago(60))
      assert %{swept: 1, dead: 0} = Worker.sweep_expired_leases(s, 64)
      assert R.fetch(s, row.id).status == :pending
    end

    test "Q2b the sweep at the cap with a failing insert counts failed and leaves the row", %{
      schema: s,
      id: id,
      rule: rule
    } do
      R.reply(R.ok(%{"writes" => []}))
      row = R.claimed_row!(s, rule, id)
      :ok = set_columns(s, row.id, lease_expires_at: ago(60), attempt: 10)
      R.put_env(:record_trigger_dlq_enqueue, fn _attrs, _opts -> {:error, :boom} end)

      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        assert %{swept: 0, dead: 0, failed: 1} = Worker.sweep_expired_leases(s, 64)
      end)

      assert R.fetch(s, row.id).status == :running

      # the insert works again: the next sweep ends the row dead, with its entry
      Application.delete_env(:letflow, :record_trigger_dlq_enqueue)
      assert %{swept: 1, dead: 1, failed: 0} = Worker.sweep_expired_leases(s, 64)
      assert R.fetch(s, row.id).last_code == "retries_exhausted"
      assert length(dlq(s)) == 1
    end

    test "Q2c a raising DLQ insert never raises out of run_row", %{
      schema: s,
      id: id,
      rule: rule
    } do
      R.reply({:error, :script_error, %{}})
      row = R.claimed_row!(s, rule, id)
      R.put_env(:record_trigger_dlq_enqueue, fn _attrs, _opts -> raise "secret-in-text" end)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert Worker.run_row(row, s) == :retry
        end)

      refute log =~ "secret-in-text"
      assert R.fetch(s, row.id).status == :running
    end

    test "Q3 a lost compare-and-set enqueues nothing and appends no audit record", %{
      schema: s,
      id: id,
      rule: rule
    } do
      R.reply({:error, :script_error, %{}})
      row = R.claimed_row!(s, rule, id)
      :ok = set_columns(s, row.id, lease_expires_at: ago(60))
      assert %{swept: 1} = Worker.sweep_expired_leases(s, 64)

      assert Worker.run_row(row, s) == :stale
      assert Apply.finish(row, s, {:dead, "script_error"}) == :stale
      assert dlq(s) == [] and audits(s) == []
      assert alert_state(s) == nil
    end
  end

  describe "N: a second death" do
    test "N1 a forced second dead write of the same attempt makes one entry", %{
      schema: s,
      id: id,
      rule: rule
    } do
      {row, :dead} = run_dead(s, rule, id, {:error, :script_error, %{}})
      assert Apply.finish(row, s, {:dead, "script_error"}) == :stale
      assert length(dlq(s)) == 1
    end

    test "N2 a row reset by SQL and dead again has two entries; the first is untouched", %{
      schema: s,
      id: id,
      rule: rule
    } do
      {row, :dead} = run_dead(s, rule, id, {:error, :script_error, %{}})
      [first] = dlq(s)

      :ok = set_columns(s, row.id, status: :running, attempt: row.attempt + 1)
      again = %{R.fetch(s, row.id) | attempt: row.attempt + 1}
      assert Apply.finish(again, s, {:dead, "timeout"}) == :dead

      assert [a, b] = dlq(s)
      assert Enum.sort([a.reason, b.reason]) == ["script_error", "timeout"]
      assert Enum.find([a, b], &(&1.id == first.id)) == first
    end
  end

  describe "A: the audit record" do
    test "A1 a run that reached the sandbox carries hmac and duration; stats when given", %{
      schema: s,
      id: id,
      rule: rule
    } do
      {row, :dead} = run_dead(s, rule, id, {:error, :script_error, %{}})
      assert [%{after_state: state, resource_id: rid, actor_id: nil}] = audits(s)
      assert rid == row.id
      assert Enum.sort(Map.keys(state)) == Enum.sort(@base_keys ++ ~w(duration_us hmac))
      assert state["last_code"] == "script_error" and state["outcome"] == "script_error"
      assert state["principal"] == row.actor_id
      assert state["script_key"] == rule.key and state["script_sha256"] == rule.sha256
      assert is_binary(state["hmac"]) and is_integer(state["duration_us"])

      stats = %{instructions_used: 5, heap_words_at_end: 9}
      {_row2, :dead} = run_dead(s, rule, id, {:ok, %{output: %{"nope" => 1}, stats: stats}})
      [_, %{after_state: with_stats}] = Enum.sort_by(audits(s), & &1.timestamp)
      assert with_stats["instructions"] == 5 and with_stats["heap_words"] == 9
    end

    test "A2 a kill-switch row carries the base keys only and no record value", %{
      schema: s,
      id: id,
      rule: rule
    } do
      P.kill_switch!(s, true)
      {_row, :dead} = run_dead(s, rule, id, R.ok(%{"writes" => []}))
      assert [%{after_state: state}] = audits(s)
      assert Enum.sort(Map.keys(state)) == Enum.sort(@base_keys)
      refute inspect(state) =~ "N1"
      refute inspect(state) =~ id
    end

    test "A3 a failing audit append leaves the row dead, the entry present and the worker alive",
         %{schema: s, id: id, rule: rule} do
      Letflow.Repo.query!(~s(DROP TABLE "#{s}".audit_entries CASCADE))

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          {row, :dead} = run_dead(s, rule, id, {:error, :script_error, %{}})
          assert R.fetch(s, row.id).status == :dead
        end)

      assert length(dlq(s)) == 1
      assert log =~ "audit failed"
    end
  end

  describe "K: the tenant kill switch" do
    test "K1-K3 dead script_rejected, other tenants unaffected, a new row runs when switched off",
         %{schema: s, id: id, rule: rule} do
      other = R.tenant!("r638k")
      other_id = R.record!(other, R.type_a(), %{"label" => "L", "note" => "N", "cid" => "c"})
      other_rule = R.publish!(other)

      P.kill_switch!(s, true)
      R.reply(R.ok(%{"writes" => []}))
      row = R.claimed_row!(s, rule, id)
      assert Worker.run_row(row, s) == :dead
      refute_received {:stub_run, _, _, _, _}
      assert R.fetch(s, row.id).last_code == "script_rejected"
      assert [%{reason: "script_rejected"}] = dlq(s)
      assert length(audits(s)) == 1

      other_row = R.claimed_row!(other, other_rule, other_id)
      assert Worker.run_row(other_row, other) == :done
      assert_received {:stub_run, _, _, _, _}

      P.kill_switch!(s, false)
      fresh = R.claimed_row!(s, rule, id, source_seq: 9)
      assert Worker.run_row(fresh, s) == :done
      assert R.fetch(s, row.id).status == :dead
    end
  end

  describe "L: the edge-triggered alert" do
    test "L1-L3 fires once, stays quiet while disarmed, fires again after a re-arm", %{
      schema: s,
      id: id,
      rule: rule
    } do
      log1 =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          run_dead(s, rule, id, {:error, :script_error, %{}})
        end)

      assert alert_lines(log1) == 1
      refute alert_state(s).is_armed

      log2 =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          run_dead(s, rule, id, {:error, :script_error, %{}})
        end)

      assert alert_lines(log2) == 0

      assert Alerts.clear_record_trigger_dead(s) == :ok
      assert alert_state(s).is_armed

      log3 =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          run_dead(s, rule, id, {:error, :script_error, %{}})
        end)

      assert alert_lines(log3) == 1
    end

    test "L4 the log line is the closed message and the state row is per schema", %{schema: s} do
      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          Alerts.notify_record_trigger_dead(s)
        end)

      assert log =~ "record trigger dead"
      assert alert_state(s).trigger_key == "record_trigger_dead"
    end

    test "L5 notify and clear never raise on a schema that does not exist" do
      assert Alerts.notify_record_trigger_dead("no_such_schema_r638") == :ok
      assert Alerts.clear_record_trigger_dead("no_such_schema_r638") == :ok
    end

    test "L7 two tenants have independent state", %{schema: s} do
      other = R.tenant!("r638l")

      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        Alerts.notify_record_trigger_dead(s)
      end)

      refute alert_state(s).is_armed
      assert alert_state(other) == nil
    end
  end

  describe "W/X: no text leaks, tenants stay apart" do
    test "W1 a marker in a runner failure appears in no code, entry, audit record or log", %{
      schema: s,
      id: id,
      rule: rule
    } do
      for failure <- [
            fn _ -> raise "marker-638" end,
            fn _ -> throw(:marker_638) end,
            fn _ -> exit(:marker_638) end
          ] do
        log =
          ExUnit.CaptureLog.capture_log([level: :debug], fn ->
            {row, :dead} = run_dead(s, rule, id, failure)
            assert R.fetch(s, row.id).last_code == "script_error"
          end)

        refute log =~ "marker-638"
        refute log =~ "marker_638"
      end

      everything = inspect({dlq(s), audits(s)})
      refute everything =~ "marker"
    end

    test "X1 each tenant has exactly its own entry and audit record", %{
      schema: a,
      id: id,
      rule: rule
    } do
      b = R.tenant!("r638x")
      b_id = R.record!(b, R.type_a(), %{"label" => "L", "note" => "N", "cid" => "c"})
      b_rule = R.publish!(b)

      {row_a, :dead} = run_dead(a, rule, id, {:error, :script_error, %{}})
      {row_b, :dead} = run_dead(b, b_rule, b_id, {:error, :timeout, %{}})

      assert [%{reference_id: ra}] = dlq(a)
      assert [%{reference_id: rb}] = dlq(b)
      assert {ra, rb} == {row_a.id, row_b.id}
      assert [%{resource_id: aa}] = audits(a)
      assert [%{resource_id: ab}] = audits(b)
      assert {aa, ab} == {row_a.id, row_b.id}
    end
  end
end
