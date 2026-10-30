defmodule Letflow.RecordTriggers.WorkerTest do
  @moduledoc """
  REQ-615 part A / GH #3434 (decision 0067 D2/D6, slice T-3): the record-trigger worker's claim,
  per-record order, fairness and no double claim. Test ids follow the design: C1 (flag), C2 (claim),
  C3 (order), C4 (fairness, budget), C5 (concurrency).

  Rows are inserted directly into `record_trigger_outbox`. `async: false`: tenant provisioning
  switches the sandbox to `:auto` (real parallel connections, which C2e and C5 need), and the flag
  and worker settings are application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.RecordTriggers.OutboxRow
  alias Letflow.RecordTriggers.Worker
  alias Letflow.Repo
  alias Letflow.Support.ScriptTaskFixture

  setup do
    previous = Application.fetch_env(:letflow, :record_triggers_enabled)
    Application.put_env(:letflow, :record_triggers_enabled, true)

    # The T-3 tests exercise claim, order and lease, not the script run (REQ-628 replaced the stub).
    Application.put_env(:letflow, :record_trigger_run_fun, &done_fun/2)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end

      Application.delete_env(:letflow, :record_trigger_worker)
      Application.delete_env(:letflow, :record_trigger_run_fun)
    end)

    {:ok, schema: ScriptTaskFixture.tenant!("r615a").schema_name}
  end

  defp insert_row(schema, attrs \\ []) do
    now = DateTime.utc_now()

    base = %OutboxRow{
      id: Ecto.UUID.generate(),
      binding_id: Ecto.UUID.generate(),
      entity_type: "r615_item",
      record_id: Ecto.UUID.generate(),
      event: :created,
      source_seq: 1,
      occurred_at: DateTime.add(now, -60, :second),
      script_key: "k",
      script_version: 1,
      script_sha256: String.duplicate("a", 64),
      next_attempt_at: DateTime.add(now, -60, :second)
    }

    Repo.insert!(struct(base, attrs), prefix: schema)
  end

  # What the T-3 stub did: mark the claimed row done, checked on id, attempt and status.
  def done_fun(row, prefix) do
    {count, _} =
      from(r in OutboxRow,
        where: r.id == ^row.id and r.attempt == ^row.attempt and r.status == :running
      )
      |> Repo.update_all([set: [status: :done, done_at: DateTime.utc_now()]], prefix: prefix)

    if count == 1, do: :done, else: :stale
  end

  defp fetch(schema, id), do: Repo.get!(OutboxRow, id, prefix: schema)

  defp statuses(schema, ids),
    do: Map.new(ids, fn id -> {id, fetch(schema, id).status} end)

  describe "C1: flag" do
    test "C1c: flag off, run_tick claims nothing and reads no schema", %{schema: schema} do
      Application.put_env(:letflow, :record_triggers_enabled, false)
      row = insert_row(schema)

      {summary, 1} = Worker.run_tick([schema, "no_such_schema_r615"], 0)

      assert summary.claimed == 0 and summary.skipped == 0
      assert fetch(schema, row.id).status == :pending
    end
  end

  describe "C2: claim" do
    test "C2a: claim sets running, attempt 1, claimed_at and a 30 s lease", %{schema: schema} do
      row = insert_row(schema)

      assert {:ok, claimed} = Worker.claim_next(schema)
      assert claimed.id == row.id
      assert claimed.status == :running
      assert claimed.attempt == 1
      assert %DateTime{} = claimed.claimed_at
      assert DateTime.diff(claimed.lease_expires_at, claimed.claimed_at, :millisecond) == 30_000
      assert Worker.lease_ms() == 30_000
      assert Worker.claim_next(schema) == :none
    end

    test "C2b: a row due at occurred_at is claimed on the first tick; NULL next_attempt_at is refused by the database",
         %{schema: schema} do
      row = insert_row(schema)
      {summary, _} = Worker.run_tick([schema], 0)
      assert summary.claimed == 1
      assert fetch(schema, row.id).status == :done

      assert_raise Postgrex.Error, ~r/not_null_violation|null value/, fn ->
        insert_row(schema, next_attempt_at: nil)
      end
    end

    test "C2c: a future next_attempt_at is not claimed", %{schema: schema} do
      row = insert_row(schema, next_attempt_at: DateTime.add(DateTime.utc_now(), 3600, :second))

      assert Worker.claim_next(schema) == :none
      assert fetch(schema, row.id).status == :pending
    end

    test "C2d: the claim locks only the outbox row, FOR UPDATE SKIP LOCKED", %{schema: schema} do
      insert_row(schema)
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        {__MODULE__, ref},
        [:letflow, :repo, :query],
        fn _event, _measure, %{query: query}, _config -> send(test_pid, {ref, query}) end,
        nil
      )

      assert {:ok, _} = Worker.claim_next(schema)
      :telemetry.detach({__MODULE__, ref})

      queries = collect(ref, [])
      locking = Enum.filter(queries, &String.contains?(&1, "FOR UPDATE"))
      assert [lock_query] = locking
      assert lock_query =~ "FOR UPDATE SKIP LOCKED"
      assert lock_query =~ "record_trigger_outbox"
    end

    test "C2e: a held lock on a sequence row does not block the claim", %{schema: schema} do
      insert_row(schema)
      seq_id = Ecto.UUID.generate()

      Repo.query!(
        ~s|INSERT INTO "#{schema}".instance_sequence (instance_id, next_seq) VALUES ($1, 1)|,
        [Ecto.UUID.dump!(seq_id)]
      )

      test_pid = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              ~s|SELECT 1 FROM "#{schema}".instance_sequence WHERE instance_id = $1 FOR UPDATE|,
              [Ecto.UUID.dump!(seq_id)]
            )

            send(test_pid, :locked)

            receive do
              :release -> :ok
            after
              5_000 -> :ok
            end
          end)
        end)

      assert_receive :locked, 5_000
      started = System.monotonic_time(:millisecond)
      assert {:ok, _} = Worker.claim_next(schema)
      assert System.monotonic_time(:millisecond) - started < 2_000
      send(holder.pid, :release)
      Task.await(holder)
    end
  end

  describe "C3: per-record order" do
    test "C3a/C3b: the later row waits until the earlier one is done", %{schema: schema} do
      record = Ecto.UUID.generate()
      r1 = insert_row(schema, record_id: record, source_seq: 5)
      r2 = insert_row(schema, record_id: record, source_seq: 6)

      assert {:ok, %{id: id1}} = Worker.claim_next(schema)
      assert id1 == r1.id
      # R1 is running: R2 is still not claimable.
      assert Worker.claim_next(schema) == :none

      Repo.update_all(from(r in OutboxRow, where: r.id == ^r1.id), [set: [status: :done]],
        prefix: schema
      )

      assert {:ok, %{id: id2}} = Worker.claim_next(schema)
      assert id2 == r2.id
    end

    test "C3a2: one tick finishes both rows of a record in source_seq order", %{schema: schema} do
      record = Ecto.UUID.generate()
      r2 = insert_row(schema, record_id: record, source_seq: 6)
      r1 = insert_row(schema, record_id: record, source_seq: 5)

      {summary, _} = Worker.run_tick([schema], 0)

      assert summary.claimed == 2 and summary.done == 2
      assert fetch(schema, r1.id).done_at <= fetch(schema, r2.id).done_at
      assert fetch(schema, r1.id).claimed_at <= fetch(schema, r2.id).claimed_at
    end

    test "C3c: a dead earlier row does not block the later one", %{schema: schema} do
      record = Ecto.UUID.generate()
      insert_row(schema, record_id: record, source_seq: 5, status: :dead)
      r2 = insert_row(schema, record_id: record, source_seq: 6)

      assert {:ok, %{id: id}} = Worker.claim_next(schema)
      assert id == r2.id
    end

    test "C3d: other records and other types with the same record id are claimable together",
         %{schema: schema} do
      record = Ecto.UUID.generate()
      a = insert_row(schema, record_id: record, entity_type: "r615_a", source_seq: 5)
      b = insert_row(schema, record_id: record, entity_type: "r615_b", source_seq: 6)
      c = insert_row(schema, source_seq: 7)

      {summary, _} = Worker.run_tick([schema], 0)

      assert summary.claimed == 3
      assert Enum.all?(statuses(schema, [a.id, b.id, c.id]), fn {_, s} -> s == :done end)
    end
  end

  describe "C4: fairness and budget" do
    setup do
      other = ScriptTaskFixture.tenant!("r615b").schema_name
      third = ScriptTaskFixture.tenant!("r615c").schema_name
      {:ok, other: other, third: third}
    end

    test "C4a: B and C are served in pass 1, not after A's backlog", ctx do
      %{schema: a, other: b, third: c} = ctx
      a_rows = for _ <- 1..20, do: insert_row(a)
      b_row = insert_row(b)
      c_row = insert_row(c)

      {summary, _} = Worker.run_tick([a, b, c], 0)

      assert summary.claimed == 18
      a_claimed = for r <- a_rows, fetch(a, r.id).claimed_at != nil, do: fetch(a, r.id).claimed_at
      assert length(a_claimed) == 16
      second_a = a_claimed |> Enum.sort(DateTime) |> Enum.at(1)
      assert DateTime.compare(fetch(b, b_row.id).claimed_at, second_a) == :lt
      assert DateTime.compare(fetch(c, c_row.id).claimed_at, second_a) == :lt

      pending = Enum.count(a_rows, &(fetch(a, &1.id).status == :pending))
      assert pending == 4
    end

    test "C4a2: the per-tenant cap bounds one tick", ctx do
      %{schema: a, other: b} = ctx
      Application.put_env(:letflow, :record_trigger_worker, max_claims_per_cycle: 1)
      for _ <- 1..3, do: insert_row(a)
      insert_row(b)

      {summary, _} = Worker.run_tick([a, b], 0)

      assert summary.claimed == 2

      assert Repo.aggregate(from(r in OutboxRow, where: r.status == :pending), :count, prefix: a) ==
               2
    end

    test "C4b: the offset rotates the first-served tenant", ctx do
      %{schema: a, other: b} = ctx
      Application.put_env(:letflow, :record_trigger_worker, max_claims_per_cycle: 1)
      ra = insert_row(a)
      rb = insert_row(b)

      {_, 2} = Worker.run_tick([a, b], 1)

      assert fetch(b, rb.id).claimed_at <= fetch(a, ra.id).claimed_at
    end

    test "C4c: a zero tick budget claims nothing", %{schema: schema} do
      Application.put_env(:letflow, :record_trigger_worker, tick_budget_ms: 0)
      row = insert_row(schema)

      {summary, _} = Worker.run_tick([schema], 0)

      assert summary.budget_exhausted
      assert summary.claimed == 0
      assert fetch(schema, row.id).status == :pending
    end

    test "C4d: a missing schema is skipped, the others are served and the process lives", ctx do
      %{schema: a} = ctx
      row = insert_row(a)
      Application.put_env(:letflow, :record_trigger_worker, poll_interval_ms: 60_000)

      {summary, _} = Worker.run_tick(["no_such_schema_r615", a], 0)

      assert summary.skipped == 1
      assert summary.claimed == 1
      assert fetch(a, row.id).status == :done

      pid = start_supervised!(Worker)
      Process.sleep(200)
      assert Process.alive?(pid)
    end
  end

  describe "C5: no double claim" do
    test "C5a: four concurrent claimers claim every row exactly once", %{schema: schema} do
      rows = for _ <- 1..12, do: insert_row(schema)
      parent = self()

      tasks =
        for _ <- 1..4 do
          Task.async(fn ->
            receive do
              :go -> claim_all(schema, [])
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      claimed = tasks |> Task.await_many(30_000) |> List.flatten()
      send(parent, :done)

      assert length(claimed) == 12
      assert Enum.sort(Enum.map(claimed, & &1.id)) == Enum.sort(Enum.map(rows, & &1.id))
      assert Enum.all?(claimed, &(&1.attempt == 1))
    end

    test "C5b: a row locked by another transaction is skipped, not waited on", %{schema: schema} do
      locked =
        insert_row(schema, next_attempt_at: DateTime.add(DateTime.utc_now(), -120, :second))

      free = insert_row(schema)
      test_pid = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.one(
              from(r in OutboxRow, where: r.id == ^locked.id, lock: "FOR UPDATE", select: r.id),
              prefix: schema
            )

            send(test_pid, :locked)

            receive do
              :release -> :ok
            after
              5_000 -> :ok
            end
          end)
        end)

      assert_receive :locked, 5_000
      started = System.monotonic_time(:millisecond)
      assert {:ok, %{id: id}} = Worker.claim_next(schema)
      assert System.monotonic_time(:millisecond) - started < 1_000
      assert id == free.id
      send(holder.pid, :release)
      Task.await(holder)
    end
  end

  describe "D6: crash, restart, lease expiry" do
    test "D6a: a restarted worker claims and finishes a due row with a 30 s lease", %{
      schema: schema
    } do
      row = insert_row(schema)

      start_supervised!(Worker)
      done = await_status(schema, row.id, :done, 100)

      assert done.attempt == 1
      assert DateTime.diff(done.lease_expires_at, done.claimed_at, :millisecond) == 30_000
      # next_attempt_at is NOT NULL in the table (C2b); the row keeps its due time.
      assert %DateTime{} = done.next_attempt_at
    end

    test "D6b: a claimer killed mid-run leaves a running row; the sweep re-queues it with backoff",
         %{schema: schema} do
      row = insert_row(schema)
      parent = self()

      pid =
        spawn(fn ->
          {:ok, _} = Worker.claim_next(schema)
          send(parent, :claimed)
          Process.sleep(:infinity)
        end)

      assert_receive :claimed, 5_000
      Process.exit(pid, :kill)
      assert fetch(schema, row.id).status == :running
      assert fetch(schema, row.id).attempt == 1

      ref = make_ref()

      :telemetry.attach(
        {__MODULE__, ref},
        [:letflow, :record_trigger, :lease_expired],
        fn _event, measure, meta, _config -> send(parent, {ref, measure, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      # Lease still valid: nothing is swept or claimed.
      {summary, _} = Worker.run_tick([schema], 0)
      assert summary.swept == 0 and summary.claimed == 0
      assert fetch(schema, row.id).status == :running

      expire(schema, row.id)
      {summary, _} = Worker.run_tick([schema], 0)

      assert summary.swept == 1 and summary.dead == 0 and summary.claimed == 0
      assert_receive {^ref, %{count: 1}, %{tenant_schema: ^schema}}

      swept = fetch(schema, row.id)
      assert swept.status == :pending
      assert swept.last_code == "lease_expired"
      wait = DateTime.diff(swept.next_attempt_at, DateTime.utc_now(), :millisecond)
      assert wait > -1_000 and wait <= 1_500

      due(schema, row.id)
      {summary, _} = Worker.run_tick([schema], 0)
      assert summary.claimed == 1 and summary.done == 1
      done = fetch(schema, row.id)
      assert done.status == :done
      assert done.attempt == 2
    end

    test "D6c: the first claim's stub run after the sweep and re-claim is stale", %{
      schema: schema
    } do
      row = insert_row(schema)
      {:ok, first} = Worker.claim_next(schema)
      expire(schema, row.id)
      assert %{swept: 1} = Worker.sweep_expired_leases(schema, 64)
      due(schema, row.id)
      {:ok, second} = Worker.claim_next(schema)
      assert second.attempt == 2

      before = fetch(schema, row.id)
      assert done_fun(first, schema) == :stale
      assert fetch(schema, row.id) == before
      assert done_fun(second, schema) == :done
    end
  end

  describe "D7: tenant isolation of claim and sweep" do
    setup do
      {:ok,
       b: ScriptTaskFixture.tenant!("r615d").schema_name,
       c: ScriptTaskFixture.tenant!("r615e").schema_name}
    end

    test "D7a: B's pass never counts or returns A's row", %{schema: a, b: b, c: c} do
      row = insert_row(a)

      assert Worker.claim_next(b) == :none
      {summary_b, _} = Worker.run_tick([b], 0)
      {summary_c, _} = Worker.run_tick([c], 0)

      assert summary_b == summary_c
      assert summary_b.claimed == 0 and summary_b.swept == 0
      assert fetch(a, row.id).status == :pending

      {summary_a, _} = Worker.run_tick([a], 0)
      assert summary_a.claimed == 1
    end

    test "D7b: an expired lease of A is swept only through A's schema", %{schema: a, b: b} do
      row = insert_row(a)
      other = insert_row(b)
      {:ok, _} = Worker.claim_next(a)
      expire(a, row.id)
      b_before = fetch(b, other.id)

      assert Worker.sweep_expired_leases(b, 64) == %{swept: 0, dead: 0, failed: 0}
      assert fetch(a, row.id).status == :running
      assert fetch(b, other.id) == b_before

      assert Worker.sweep_expired_leases(a, 64) == %{swept: 1, dead: 0, failed: 0}
      assert fetch(a, row.id).status == :pending
      assert fetch(b, other.id) == b_before
    end
  end

  describe "D8: backoff and retry cap" do
    test "D8a: backoff doubles from 500 ms and is capped at 30 s" do
      assert Worker.backoff_ms(1) == 500
      assert Worker.backoff_ms(2) == 1_000
      assert Worker.backoff_ms(3) == 2_000
      assert Worker.backoff_ms(6) == 16_000
      assert Worker.backoff_ms(12) == 30_000
      assert Worker.backoff_ms(500) == 30_000

      Application.put_env(:letflow, :record_trigger_worker,
        backoff_base_ms: 100,
        backoff_cap_ms: 250
      )

      assert Worker.backoff_ms(1) == 100
      assert Worker.backoff_ms(2) == 200
      assert Worker.backoff_ms(3) == 250
    end

    test "D8b: attempt 9 expired goes back to pending and is claimed as attempt 10", %{
      schema: schema
    } do
      row = insert_row(schema, status: :running, attempt: 9, lease_expires_at: ago(60))

      assert %{swept: 1, dead: 0} = Worker.sweep_expired_leases(schema, 64)
      swept = fetch(schema, row.id)
      assert swept.status == :pending and swept.last_code == "lease_expired"
      wait = DateTime.diff(swept.next_attempt_at, DateTime.utc_now(), :millisecond)
      assert wait > 29_000 and wait <= 30_500

      due(schema, row.id)
      assert {:ok, %{attempt: 10}} = Worker.claim_next(schema)
    end

    test "D8c: attempt 10 expired is dead and is never claimed again", %{schema: schema} do
      record = Ecto.UUID.generate()

      row =
        insert_row(schema,
          record_id: record,
          source_seq: 1,
          status: :running,
          attempt: 10,
          lease_expires_at: ago(60)
        )

      later = insert_row(schema, record_id: record, source_seq: 2)

      {summary, _} = Worker.run_tick([schema], 0)

      assert summary.swept == 1 and summary.dead == 1
      dead = fetch(schema, row.id)
      assert dead.status == :dead
      assert dead.last_code == "retries_exhausted"
      assert dead.done_at == nil
      # A dead row does not block the later row of the same record (C3c).
      assert fetch(schema, later.id).status == :done

      due(schema, row.id)
      assert Worker.claim_next(schema) == :none
      assert fetch(schema, row.id).status == :dead
    end

    test "D8d: the sweep limit bounds one call", %{schema: schema} do
      for _ <- 1..3,
          do: insert_row(schema, status: :running, attempt: 1, lease_expires_at: ago(60))

      assert %{swept: 2} = Worker.sweep_expired_leases(schema, 2)
      assert %{swept: 1} = Worker.sweep_expired_leases(schema, 2)
    end

    test "D8e: unexpired running rows and done rows are ignored", %{schema: schema} do
      live = insert_row(schema, status: :running, attempt: 1, lease_expires_at: future(60))
      done = insert_row(schema, status: :done, attempt: 1, lease_expires_at: ago(60))

      assert Worker.sweep_expired_leases(schema, 64) == %{swept: 0, dead: 0, failed: 0}
      assert fetch(schema, live.id).status == :running
      assert fetch(schema, done.id).status == :done
    end
  end

  describe "D9: the stub run" do
    test "D9a: marks done under CAS and writes nothing but the outbox row", %{schema: schema} do
      row = insert_row(schema)
      {:ok, claimed} = Worker.claim_next(schema)
      before = fetch(schema, row.id)
      counts_before = side_effect_counts(schema)

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:letflow, :repo, :query],
        fn _event, _measure, %{query: query}, _config -> send(parent, {ref, query}) end,
        nil
      )

      assert done_fun(claimed, schema) == :done
      :telemetry.detach({__MODULE__, ref})

      queries = collect(ref, [])
      assert queries != []
      assert Enum.all?(queries, &(&1 =~ "record_trigger_outbox"))
      assert Enum.all?(queries, &(&1 =~ "UPDATE"))

      done = fetch(schema, row.id)
      assert done.status == :done and done.done_at != nil and done.last_code == nil

      for field <-
            ~w(binding_id entity_type record_id event source_seq occurred_at script_key script_version script_sha256 depth chain actor_id)a do
        assert Map.fetch!(done, field) == Map.fetch!(before, field)
      end

      assert side_effect_counts(schema) == counts_before
    end

    test "D9b: a failing database write is caught: tick returns, worker lives, row stays running",
         %{schema: schema} do
      row = insert_row(schema)

      Repo.query!(
        ~s|ALTER TABLE "#{schema}".record_trigger_outbox ADD CONSTRAINT no_done CHECK (status <> 'done') NOT VALID|
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {summary, _} = Worker.run_tick([schema], 0)
          assert summary.claimed == 1 and summary.skipped == 1 and summary.done == 0
        end)

      assert fetch(schema, row.id).status == :running
      assert length(Regex.scan(~r/record trigger step caught/, log)) == 1
      refute log =~ "Postgrex"
      refute log =~ "** ("
      refute log =~ "stacktrace"

      Application.put_env(:letflow, :record_trigger_worker, poll_interval_ms: 60_000)
      pid = start_supervised!(Worker)
      send(pid, :tick)
      Process.sleep(100)
      assert Process.alive?(pid)

      expire(schema, row.id)
      assert %{swept: 1} = Worker.sweep_expired_leases(schema, 64)
      assert fetch(schema, row.id).status == :pending
    end

    test "D9c: an exception inside the run function is caught and its text is not logged",
         %{schema: schema} do
      row = insert_row(schema)
      previous = Application.fetch_env(:letflow, :scripts_test_hooks)
      Application.put_env(:letflow, :scripts_test_hooks, true)

      Application.put_env(:letflow, :record_trigger_run_fun, fn _row, _prefix ->
        raise "SECRET-MARKER-615"
      end)

      on_exit(fn ->
        Application.delete_env(:letflow, :record_trigger_run_fun)

        case previous do
          {:ok, old} -> Application.put_env(:letflow, :scripts_test_hooks, old)
          :error -> Application.delete_env(:letflow, :scripts_test_hooks)
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {summary, _} = Worker.run_tick([schema], 0)
          assert summary.claimed == 1 and summary.skipped == 1
        end)

      assert fetch(schema, row.id).status == :running
      assert length(Regex.scan(~r/record trigger step caught/, log)) == 1
      assert log =~ schema
      refute log =~ "SECRET-MARKER-615"
    end
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
  defp future(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp expire(schema, id), do: set_columns(schema, id, lease_expires_at: ago(60))
  defp due(schema, id), do: set_columns(schema, id, next_attempt_at: ago(60))

  defp set_columns(schema, id, set) do
    {1, _} = Repo.update_all(from(r in OutboxRow, where: r.id == ^id), [set: set], prefix: schema)
    :ok
  end

  defp await_status(schema, id, status, tries) do
    row = fetch(schema, id)

    cond do
      row.status == status ->
        row

      tries == 0 ->
        flunk("row stayed #{row.status}, wanted #{status}")

      true ->
        Process.sleep(50)
        await_status(schema, id, status, tries - 1)
    end
  end

  defp side_effect_counts(schema) do
    for table <- ~w(entity_record_latest audit_entries events dlq_entries event_idempotency),
        into: %{} do
      %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}"."#{table}"|)
      {table, n}
    end
  end

  defp claim_all(schema, acc) do
    case Worker.claim_next(schema) do
      {:ok, row} -> claim_all(schema, [row | acc])
      :none -> acc
    end
  end

  defp collect(ref, acc) do
    receive do
      {^ref, query} -> collect(ref, [query | acc])
    after
      0 -> acc
    end
  end
end
