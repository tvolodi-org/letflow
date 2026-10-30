defmodule Letflow.RecordTriggers.TerminalTest do
  @moduledoc """
  REQ-628 slice T-4 part B / GH #3507 (decision 0067 D7, criteria 7, 9, 10): the second terminal
  transaction and the refusals that reach `Apply`. T1-T3: a refused later line rolls back the earlier
  one, the matching reason is emitted, a worker that dies before `finish/3` is swept and never writes
  twice. D1-D2: a forced duplicate apply and key reuse. C1-C3: stale claims, retriable causes and the
  cap, a raised/thrown script leaves no text. `async: false` (tenant provisioning, application env).

  The refusal used by T1/T3/D2 is one the manifest ALLOWS and `Records` refuses inside `Apply`: the
  manifest declares a field (`ghost`) that the active definition lacks, so the Runner accepts the
  line (a manifest check only) and the write answers `record_payload_invalid` (reason `validation`).
  A replayed key inside the outer result transaction poisons it (the inner `Records` transaction rolls
  back to report the duplicate), so D1 calls `apply_lines/3` outside a transaction and D2 changes line 0.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.RecordTriggers.Apply
  alias Letflow.RecordTriggers.OutboxRow
  alias Letflow.RecordTriggers.Runner
  alias Letflow.RecordTriggers.Worker
  alias Letflow.RecordTriggerRunFixture, as: R

  setup do
    schema = R.tenant!("r628t")
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
    {:ok, schema: schema, id: id}
  end

  # ── manifests and replies ────────────────────────────────────────────────────

  defp refusing_manifest(second_type \\ R.type_b()) do
    R.manifest(%{}, [
      %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => ["note"]},
      %{"entity_type" => second_type, "mode" => "create", "fields" => ["label", "ghost"]}
    ])
  end

  defp refusing_reply(second_type \\ R.type_b()) do
    R.reply(
      R.ok(%{
        "writes" => [
          %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => %{"note" => "N2"}},
          %{
            "entity_type" => second_type,
            "mode" => "create",
            "fields" => %{"label" => "x", "ghost" => "y"}
          }
        ]
      })
    )
  end

  defp good_reply do
    R.reply(
      R.ok(%{
        "writes" => [
          %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => %{"note" => "N2"}},
          %{"entity_type" => R.type_b(), "mode" => "create", "fields" => %{"label" => "kid"}}
        ]
      })
    )
  end

  defp line(index, type, mode, fields),
    do: %{index: index, entity_type: type, mode: mode, fields: fields, external_ref: nil}

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp set_columns(schema, id, set) do
    {1, _} = Repo.update_all(from(r in OutboxRow, where: r.id == ^id), [set: set], prefix: schema)
    :ok
  end

  defp telemetry_reasons(event) do
    receive do
      {:telemetry, ^event, meta} -> [Map.get(meta, :reason) | telemetry_reasons(event)]
    after
      0 -> []
    end
  end

  # ── T: the second terminal transaction ───────────────────────────────────────

  describe "T: a refused later line" do
    test "T1 line 1 refused rolls line 0 back; dead with the reason emitted", %{
      schema: s,
      id: id
    } do
      rule = R.publish!(s, refusing_manifest())
      refusing_reply()
      row = R.claimed_row!(s, rule, id)
      R.forward([:letflow, :record_trigger, :write_refused])
      events = R.event_count(s)

      # the Runner accepts the lines: the refusal is made by Records inside Apply
      assert {:ok, [_, _] = lines} = Runner.run(row, s)
      assert_received {:stub_run, _, _, _, _}

      assert Apply.apply_result(row, lines, s) == {:dead, "trigger_write_refused"}
      assert R.fetch(s, row.id).status == :running
      assert R.fields(s, R.type_a(), id)["note"] == "N1"
      assert R.event_count(s) == events

      # the whole path: the terminal transaction makes it dead with the closed code
      assert Worker.run_row(row, s) == :dead
      stored = R.fetch(s, row.id)
      assert stored.status == :dead and stored.last_code == "trigger_write_refused"
      assert R.fields(s, R.type_a(), id)["note"] == "N1"
      assert R.event_count(s) == events
      assert R.count(s, R.type_b()) == 0

      assert telemetry_reasons([:letflow, :record_trigger, :write_refused]) ==
               ["validation", "validation"]
    end

    test "T2 a line on a managed type is refused as entity_type_managed", %{schema: s, id: id} do
      Fx.install_managed_fixture!(s)

      rule = R.publish!(s, refusing_manifest("fxm_ledger"))
      refusing_reply("fxm_ledger")
      row = R.claimed_row!(s, rule, id)
      R.forward([:letflow, :record_trigger, :write_refused])

      assert Worker.run_row(row, s) == :dead
      assert R.fetch(s, row.id).last_code == "trigger_write_refused"
      assert R.fields(s, R.type_a(), id)["note"] == "N1"

      assert telemetry_reasons([:letflow, :record_trigger, :write_refused]) == [
               "entity_type_managed"
             ]
    end

    test "T3 a worker killed before finish is swept; the retry writes nothing twice", %{
      schema: s,
      id: id
    } do
      rule = R.publish!(s, refusing_manifest())
      refusing_reply()
      row = R.claimed_row!(s, rule, id)
      events = R.event_count(s)

      {pid, ref} =
        spawn_monitor(fn ->
          {:ok, lines} = Runner.run(row, s)
          {:dead, "trigger_write_refused"} = Apply.apply_result(row, lines, s)
          Process.exit(self(), :kill)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 10_000

      stored = R.fetch(s, row.id)
      assert stored.status == :running and stored.attempt == 1
      assert R.event_count(s) == events

      :ok = set_columns(s, row.id, lease_expires_at: ago(60))
      assert %{swept: 1} = Worker.sweep_expired_leases(s, 64)
      swept = R.fetch(s, row.id)
      assert swept.status == :pending and swept.last_code == "lease_expired"

      :ok = set_columns(s, row.id, next_attempt_at: ago(60))
      assert {:ok, %OutboxRow{attempt: 2} = second} = Worker.claim_next(s)
      assert second.id == row.id

      assert Worker.run_row(second, s) == :dead
      final = R.fetch(s, row.id)
      assert final.status == :dead and final.attempt == 2
      assert final.last_code == "trigger_write_refused"
      assert R.event_count(s) == events
      assert R.fields(s, R.type_a(), id)["note"] == "N1"
    end
  end

  # ── D: duplicate apply and key reuse ─────────────────────────────────────────

  describe "D: forced duplicate apply" do
    test "D1 a second apply of the same lines is all duplicates; nothing is written", %{
      schema: s,
      id: id
    } do
      rule = R.publish!(s)
      row = R.claimed_row!(s, rule, id)

      lines = [
        line(0, R.type_a(), "update_self", %{"note" => "N2"}),
        line(1, R.type_b(), "create", %{"label" => "kid"})
      ]

      assert Apply.apply_result(row, lines, s) == :done
      events = R.event_count(s)

      # outside a transaction: a replayed key inside one would poison the caller (see the moduledoc)
      results = Apply.apply_lines(row, lines, s)
      assert [%{is_duplicate: true}, %{is_duplicate: true}] = results
      assert R.event_count(s) == events
      assert R.count(s, R.type_b()) == 1
      assert R.fetch(s, row.id).status == :done
    end

    test "D2 the same key with different fields is refused as idempotency_conflict", %{
      schema: s,
      id: id
    } do
      rule = R.publish!(s)
      row = R.claimed_row!(s, rule, id)

      first = [
        line(0, R.type_a(), "update_self", %{"note" => "N2"}),
        line(1, R.type_b(), "create", %{"label" => "kid"})
      ]

      assert Apply.apply_result(row, first, s) == :done
      events = R.event_count(s)

      changed = [
        line(0, R.type_a(), "update_self", %{"note" => "N3"}),
        line(1, R.type_b(), "create", %{"label" => "other"})
      ]

      assert {:error, {:line, :idempotency_key_reuse}} =
               Repo.transaction(fn -> Apply.apply_lines(row, changed, s) end)

      # the SAME row id (a key never repeats for a new row id): the done row goes back to running
      :ok = set_columns(s, row.id, status: :running, attempt: 2, done_at: nil)
      again = R.fetch(s, row.id)
      R.forward([:letflow, :record_trigger, :write_refused])

      assert Apply.apply_result(again, changed, s) == {:dead, "trigger_write_refused"}
      assert Apply.finish(again, s, {:dead, "trigger_write_refused"}) == :dead

      assert telemetry_reasons([:letflow, :record_trigger, :write_refused]) ==
               ["idempotency_conflict"]

      assert R.event_count(s) == events
      assert R.count(s, R.type_b()) == 1
    end
  end

  # ── C: CAS and retriable causes ──────────────────────────────────────────────

  describe "C: compare and set, retriable causes" do
    test "C1 a stale claim writes nothing and is counted once, without a log line", %{
      schema: s,
      id: id
    } do
      good_reply()
      rule = R.publish!(s)
      first = R.claimed_row!(s, rule, id)
      R.forward([:letflow, :record_trigger, :stale])
      events = R.event_count(s)

      # (b) swept: the row is pending again, the late worker of attempt 1 is stale
      :ok = set_columns(s, first.id, lease_expires_at: ago(60))
      assert %{swept: 1} = Worker.sweep_expired_leases(s, 64)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert Worker.run_row(first, s) == :stale
        end)

      assert log == ""
      assert [nil] == telemetry_reasons([:letflow, :record_trigger, :stale])

      # (a) re-claimed as attempt 2: attempt 1 is still stale
      :ok = set_columns(s, first.id, next_attempt_at: ago(60))
      assert {:ok, %OutboxRow{attempt: 2} = second} = Worker.claim_next(s)
      assert Worker.run_row(first, s) == :stale
      assert [nil] == telemetry_reasons([:letflow, :record_trigger, :stale])

      assert Apply.apply_result(first, [line(0, R.type_b(), "create", %{"label" => "x"})], s) ==
               :stale

      # (c) done: a replayed claim of the finished attempt is stale too
      assert Worker.run_row(second, s) == :done
      assert Worker.run_row(second, s) == :stale
      assert [nil] == telemetry_reasons([:letflow, :record_trigger, :stale])

      assert R.count(s, R.type_b()) == 1
      assert R.event_count(s) > events
    end

    test "C2 script_busy goes back to pending with the backoff and counts toward the cap", %{
      schema: s,
      id: id
    } do
      assert Worker.config(:max_attempts) == 10
      assert Enum.map([1, 2, 6, 8], &Worker.backoff_ms/1) == [500, 1_000, 16_000, 30_000]
      assert Worker.backoff_ms(7) == 30_000 and Worker.backoff_ms(30) == 30_000

      Application.put_env(:letflow, :record_trigger_worker, max_attempts: 2)
      R.reply({:error, :script_busy, %{}})
      rule = R.publish!(s)
      row = R.claimed_row!(s, rule, id)
      before = DateTime.utc_now()

      assert Worker.run_row(row, s) == :retry
      stored = R.fetch(s, row.id)
      assert stored.status == :pending and stored.last_code == "script_busy"
      wait = DateTime.diff(stored.next_attempt_at, before, :millisecond)
      assert wait >= Worker.backoff_ms(1) - 1_000 and wait <= Worker.backoff_ms(1) + 5_000

      :ok = set_columns(s, row.id, next_attempt_at: ago(60))
      assert {:ok, %OutboxRow{attempt: 2} = second} = Worker.claim_next(s)
      assert Worker.run_row(second, s) == :dead
      final = R.fetch(s, row.id)
      assert final.status == :dead and final.last_code == "retries_exhausted"
    end

    test "C2c every contention reason maps to the retriable code, others to dead" do
      for reason <- [:record_version_conflict, :external_ref_contention, :entity_write_contention] do
        assert Apply.line_failure_class(reason) == {:retry, "entity_write_contention"}
      end

      for reason <- [:entity_type_managed, :idempotency_key_reuse, {:record_payload_invalid, []}] do
        assert Apply.line_failure_class(reason) == {:dead, "trigger_write_refused"}
      end
    end

    test "C3 a raised or thrown script leaves a closed code and no text in the log", %{
      schema: s,
      id: id
    } do
      rule = R.publish!(s)

      for failure <- [fn _ -> raise "secret-in-text" end, fn _ -> throw(:secret_in_text) end] do
        R.reply(failure)
        row = R.claimed_row!(s, rule, id)
        :ok = set_columns(s, row.id, status: :pending, attempt: 0, lease_expires_at: nil)

        log =
          ExUnit.CaptureLog.capture_log([level: :warning], fn ->
            {summary, _} = Worker.run_tick([s], 0)
            assert summary.claimed == 1 and summary.dead == 1
          end)

        stored = R.fetch(s, row.id)
        assert stored.status == :dead and stored.last_code == "script_error"
        refute log =~ "secret"
        refute log =~ "stacktrace"
      end
    end
  end
end
