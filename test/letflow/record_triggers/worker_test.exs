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

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end

      Application.delete_env(:letflow, :record_trigger_worker)
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
