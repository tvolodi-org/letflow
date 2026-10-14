defmodule Letflow.Engine.ScriptTaskDispatcherTest do
  @moduledoc """
  GH 2534 PR 7c-1 (design `lib/letflow/design/gh2534-7c-script-handler.md` sections 5, 9, 15):
  claim, run, apply, busy retry, terminal outcomes, kill switch, tenant status, killed
  dispatcher / watchdog, cancellation, the round-robin tick, the lease sweep and the test-seam
  gate. Real scripts drive every outcome; the runner seam only counts calls. The poller is off
  in test: everything goes through `run_tick/2`, `claim_next/1` and `run_claimed/2`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Scripts.ScriptPolicy
  alias Letflow.Support.ScriptPolicyFixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  @slow_loop "while true do local s = string.rep('x', 1000000) end"

  setup do
    %{t: F.tenant!("gh2534-7c-disp")}
  end

  defp bound(t, source), do: F.bound!(t, source, F.closed_manifest(), %{"amount" => 21})

  defp bound(t, source, limits),
    do: F.bound!(t, source, F.manifest_with_limits(limits), %{"amount" => 21})

  defp cancel!(schema, instance_id) do
    Engine.cancel_instance(
      instance_id,
      %{
        actor_id: Ecto.UUID.generate(),
        idempotency_key: "c-#{System.unique_integer([:positive])}"
      },
      prefix: schema
    )
  end

  defp find_child_called_by(pid, tries) do
    found =
      Letflow.Engine.Lua.TaskSupervisor
      |> Task.Supervisor.children()
      |> Enum.find(fn child ->
        case Process.info(child, :dictionary) do
          {:dictionary, dict} -> List.first(Keyword.get(dict, :"$callers", [])) == pid
          nil -> false
        end
      end)

    cond do
      found -> found
      tries == 0 -> nil
      true -> Process.sleep(20) && find_child_called_by(pid, tries - 1)
    end
  end

  # ── AC5 ─────────────────────────────────────────────────────────────────────

  describe "AC5" do
    test "claim then apply one tx", %{t: t} do
      F.count_runner_calls!()
      ScriptPolicyFixture.attach_probe!()
      b = bound(t, F.doubling_source())
      assert b.row.status == "pending" and b.row.attempt == 0
      assert b.row.triggering_user_id == b.actor_id

      assert {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
      assert row.id == b.row.id
      assert row.status == "running" and row.attempt == 1

      assert DateTime.diff(row.lease_expires_at, row.claimed_at, :millisecond) ==
               ScriptTaskDispatcher.lease_ms()

      assert ScriptTaskDispatcher.lease_ms() == 30_000

      # Pause the apply at its terminal row write: nothing of the instance effect may be
      # visible from another connection until the ONE transaction commits.
      test_pid = self()

      runner =
        spawn(fn ->
          ScriptPolicyFixture.arm_probe(test_pid, fn sql ->
            sql =~ "script_task_dispatches" and sql =~ "UPDATE" and sql =~ "\"status\" = $"
          end)

          send(test_pid, {:done, ScriptTaskDispatcher.run_claimed(row, t.schema_name)})
        end)

      assert_receive {:script_runner_called, ^runner, false}, 5_000
      assert_receive {:probe_hit, ^runner}, 10_000

      assert F.payloads(t.schema_name, b.instance_id, "SCRIPT_TASK_COMPLETED") == []
      assert F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED") == []
      assert F.projection(t.schema_name, b.instance_id).status == :active
      assert F.reload(t.schema_name, row).status == "running"

      send(runner, :probe_continue)
      assert_receive {:done, {:ok, :applied}}, 10_000

      done = F.reload(t.schema_name, row)
      assert done.status == "applied" and done.outcome == "ok" and done.finished_at
      projection = F.projection(t.schema_name, b.instance_id)
      assert projection.variables["total"] == 42
      assert projection.status == :completed

      assert [%{"output" => %{"total" => 42}, "attempt" => 1}] =
               F.payloads(t.schema_name, b.instance_id, "SCRIPT_TASK_COMPLETED")

      assert [%{"outcome" => "ok", "phase" => "ran"}] =
               F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")
    end
  end

  # ── AC7a / AC7b ─────────────────────────────────────────────────────────────

  describe "AC7 (F-E)" do
    test "T-kill-dispatcher: the row stays running, the sweep makes it an incident, never re-run",
         %{t: t} do
      F.count_runner_calls!()
      b = bound(t, @slow_loop, %{"instructions" => 10_000_000, "timeout_ms" => 5_000})
      dlq_before = F.dlq_count(t.schema_name)
      assert {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
      test_pid = self()

      dispatcher =
        spawn(fn ->
          send(test_pid, {:done, ScriptTaskDispatcher.run_claimed(row, t.schema_name)})
        end)

      assert_receive {:script_runner_called, ^dispatcher, false}, 5_000
      watchdog = find_child_called_by(dispatcher, 100)
      worker = watchdog && find_child_called_by(watchdog, 100)
      assert is_pid(watchdog) and is_pid(worker)
      assert F.slots_in_use(t.schema_name) == 1

      ref = Process.monitor(dispatcher)
      Process.exit(dispatcher, :kill)
      assert_receive {:DOWN, ^ref, :process, ^dispatcher, :killed}, 5_000

      assert F.eventually(
               fn -> not Process.alive?(worker) and not Process.alive?(watchdog) end,
               200
             )

      assert F.eventually(fn -> F.slots_in_use(t.schema_name) == 0 end, 200)
      refute_received {:done, _}

      # no apply happened
      assert F.reload(t.schema_name, row).status == "running"
      assert F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED") == []

      F.expire_lease!(t.schema_name, row)
      assert %{swept: 1, failed: 0} = ScriptTaskDispatcher.sweep_expired_leases(t.schema_name, 64)

      swept = F.reload(t.schema_name, row)

      assert {swept.status, swept.outcome, swept.outcome_detail} ==
               {"failed", "timeout", "lease_expired"}

      assert F.projection(t.schema_name, b.instance_id).status == :error
      assert F.dlq_count(t.schema_name) == dlq_before + 1

      assert [%{"phase" => "lease_expired", "outcome" => "timeout", "input_hmac" => nil}] =
               F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")

      # never claimed or run again
      assert ScriptTaskDispatcher.claim_next(t.schema_name) == :none
      assert %{swept: 0} = ScriptTaskDispatcher.sweep_expired_leases(t.schema_name, 64)
      refute_received {:script_runner_called, _, _}
    end

    test "T-kill-watchdog: script_error applied immediately, no lease wait, never re-run", %{t: t} do
      F.count_runner_calls!()
      b = bound(t, @slow_loop, %{"instructions" => 10_000_000, "timeout_ms" => 5_000})
      assert {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
      test_pid = self()

      dispatcher =
        spawn(fn ->
          send(test_pid, {:done, ScriptTaskDispatcher.run_claimed(row, t.schema_name)})
        end)

      assert_receive {:script_runner_called, ^dispatcher, false}, 5_000
      watchdog = find_child_called_by(dispatcher, 100)
      worker = watchdog && find_child_called_by(watchdog, 100)
      assert is_pid(watchdog) and is_pid(worker)

      started = System.monotonic_time(:millisecond)
      Process.exit(watchdog, :kill)
      assert_receive {:done, {:ok, :failed}}, 5_000
      assert System.monotonic_time(:millisecond) - started < 4_000

      assert F.eventually(fn -> not Process.alive?(worker) end, 100)
      assert F.eventually(fn -> F.slots_in_use(t.schema_name) == 0 end, 100)

      done = F.reload(t.schema_name, row)
      assert {done.status, done.outcome} == {"failed", "script_error"}

      assert [%{"phase" => "ran", "outcome" => "script_error"}] =
               F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")

      assert ScriptTaskDispatcher.claim_next(t.schema_name) == :none
      refute_received {:script_runner_called, _, _}
    end
  end

  # ── AC8 ─────────────────────────────────────────────────────────────────────

  describe "AC8: only script_busy is retried" do
    test "T-busy-reschedule", %{t: t} do
      b = bound(t, F.doubling_source())
      holders = F.hold_all_slots!(t.schema_name)
      assert holders != []

      {row, result} = F.run_next!(t.schema_name)
      assert result == {:ok, :rescheduled}

      pending = F.reload(t.schema_name, row)
      assert pending.status == "pending" and pending.busy_retries == 1
      assert pending.lease_expires_at == nil
      assert DateTime.diff(pending.next_attempt_at, pending.updated_at, :millisecond) == 500
      assert F.event_types(t.schema_name, b.instance_id) == ["INSTANCE_STARTED"]

      Enum.each(holders, &Process.exit(&1, :kill))
      assert F.eventually(fn -> F.slots_in_use(t.schema_name) == 0 end, 100)
      F.make_due!(t.schema_name, pending)

      {row2, result2} = F.run_next!(t.schema_name)
      assert row2.id == row.id and row2.attempt == 2
      assert result2 == {:ok, :applied}
    end

    test "T-busy-exhausted", %{t: t} do
      F.put_dispatcher_config!(:busy_retry_limit, 1)
      b = bound(t, F.doubling_source())
      holders = F.hold_all_slots!(t.schema_name)

      {row, {:ok, :rescheduled}} = F.run_next!(t.schema_name)
      F.make_due!(t.schema_name, F.reload(t.schema_name, row))
      {_row, result} = F.run_next!(t.schema_name)
      Enum.each(holders, &Process.exit(&1, :kill))

      assert result == {:ok, :failed}
      done = F.reload(t.schema_name, row)

      assert {done.status, done.outcome, done.outcome_detail} ==
               {"failed", "script_busy", "busy_retries_exhausted"}

      assert F.projection(t.schema_name, b.instance_id).status == :error
      assert ScriptTaskDispatcher.claim_next(t.schema_name) == :none
    end

    for {code, source, limits} <- [
          {"script_error", "error('boom')", %{}},
          {"budget_exceeded", "while true do end", %{"instructions" => 10_000}},
          {"memory_limit_exceeded",
           "local t = {} for i = 1, 400 do t[i] = string.rep('S', 1000000) .. i end return {}",
           %{"heap_words" => 1_000_000, "instructions" => 10_000_000, "timeout_ms" => 5_000}},
          {"timeout",
           "while true do pcall(function() local s = string.rep('x', 1000000) end) end",
           %{"instructions" => 10_000_000, "timeout_ms" => 100}},
          {"script_failed", "fail('too_big')", %{}},
          {"output_invalid", "return { total = 'not an integer' }", %{}}
        ] do
      test "T-terminal-#{code}: failed after exactly ONE run, never claimed again", %{t: t} do
        F.count_runner_calls!()

        b =
          bound(
            t,
            unquote(source),
            Map.merge(%{"timeout_ms" => 1_000}, unquote(Macro.escape(limits)))
          )

        {row, result} = F.run_next!(t.schema_name)

        assert result == {:ok, :failed}
        assert_received {:script_runner_called, _, false}
        refute_received {:script_runner_called, _, _}

        done = F.reload(t.schema_name, row)
        assert {done.status, done.outcome} == {"failed", unquote(code)}
        assert F.projection(t.schema_name, b.instance_id).status == :error

        assert ["EXECUTION_ERROR"] =
                 F.event_types(t.schema_name, b.instance_id) --
                   ["INSTANCE_STARTED", "SCRIPT_RUN_RECORDED"]

        assert ScriptTaskDispatcher.claim_next(t.schema_name) == :none
      end
    end

    test "T-rejected-zero-runs: a script_rejected row (kill switch) ran zero times", %{t: t} do
      F.count_runner_calls!()
      b = bound(t, F.doubling_source())
      ScriptPolicyFixture.kill_switch!(t.schema_name, true)

      {row, result} = F.run_next!(t.schema_name)
      assert result == {:ok, :failed}
      refute_received {:script_runner_called, _, _}

      done = F.reload(t.schema_name, row)

      assert {done.status, done.outcome, done.outcome_detail} ==
               {"failed", "script_rejected", "scripts_disabled"}

      assert F.projection(t.schema_name, b.instance_id).status == :error
      assert ScriptTaskDispatcher.claim_next(t.schema_name) == :none
    end
  end

  defp assert_rejected_without_run(t, detail, flip) do
    F.count_runner_calls!()
    b = bound(t, F.doubling_source())
    dlq_before = F.dlq_count(t.schema_name)
    flip.()
    # every slot held: an admission attempt would be script_busy -> rescheduled
    holders = F.hold_all_slots!(t.schema_name)

    {row, result} = F.run_next!(t.schema_name)
    Enum.each(holders, &Process.exit(&1, :kill))

    assert result == {:ok, :failed}
    refute_received {:script_runner_called, _, _}
    done = F.reload(t.schema_name, row)

    assert {done.status, done.outcome, done.outcome_detail} ==
             {"failed", "script_rejected", detail}

    assert F.projection(t.schema_name, b.instance_id).status == :error
    assert F.dlq_count(t.schema_name) == dlq_before + 1

    assert [%{"phase" => "rejected", "detail" => ^detail, "input_hmac" => nil}] =
             F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")

    assert ScriptTaskDispatcher.claim_next(t.schema_name) == :none
  end

  # ── AC11 ────────────────────────────────────────────────────────────────────

  describe "AC11: kill switch and tenant status fail closed before admission" do
    test "kill switch tenant latch", %{t: t} do
      assert_rejected_without_run(t, "scripts_disabled", fn ->
        ScriptPolicyFixture.kill_switch!(t.schema_name, true)
      end)
    end

    test "kill switch platform latch", %{t: t} do
      assert_rejected_without_run(t, "scripts_disabled", fn ->
        {1, _} =
          Repo.update_all(
            from(p in ScriptPolicy, where: p.id == 1),
            [set: [platform_kill_switch: true]],
            prefix: t.schema_name
          )
      end)
    end

    for status <- [:inactive, :migrating] do
      test "tenant #{status}", %{t: t} do
        assert_rejected_without_run(t, "tenant_inactive", fn ->
          {1, _} =
            Repo.update_all(from(x in Letflow.Identity.Tenant, where: x.id == ^t.tenant_id),
              set: [status: unquote(status)]
            )
        end)
      end
    end
  end

  # ── AC18 ────────────────────────────────────────────────────────────────────

  describe "AC18" do
    test "cancel pending and running", %{t: t} do
      pending = bound(t, F.doubling_source())
      running = bound(t, F.doubling_source())

      {:ok, claimed} = ScriptTaskDispatcher.claim_next(t.schema_name)
      claimed_instance = claimed.instance_id
      other = if claimed_instance == running.instance_id, do: pending, else: running

      assert {:ok, _} = cancel!(t.schema_name, claimed_instance)
      assert {:ok, _} = cancel!(t.schema_name, other.instance_id)

      for instance_id <- [claimed_instance, other.instance_id] do
        row = F.row!(t.schema_name, instance_id)
        assert {row.status, row.outcome_detail} == {"cancelled", "instance_cancelled"}
        assert row.finished_at
      end
    end

    test "apply after cancel stale", %{t: t} do
      b = bound(t, F.doubling_source())
      {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
      assert {:ok, _} = cancel!(t.schema_name, b.instance_id)
      events_before = F.event_types(t.schema_name, b.instance_id)

      assert ScriptTaskDispatcher.run_claimed(row, t.schema_name) == {:ok, :stale}
      assert F.event_types(t.schema_name, b.instance_id) == events_before
      assert F.reload(t.schema_name, row).status == "cancelled"
      refute Map.has_key?(F.projection(t.schema_name, b.instance_id).variables, "total")
    end
  end

  # ── AC29 ────────────────────────────────────────────────────────────────────

  describe "AC29 (SEC S2): fairness" do
    test "T-fair-round-robin: B's row is claimed before A's second", %{t: a} do
      b_tenant = F.tenant!("gh2534-7c-fair-b")
      a_rows = for _ <- 1..6, do: bound(a, F.doubling_source()).row.id
      b_row = bound(b_tenant, F.doubling_source()).row.id

      {summary, next} = ScriptTaskDispatcher.run_tick([a.schema_name, b_tenant.schema_name], 0)
      assert next == 1
      assert summary.ran == 7 and summary.applied == 7
      refute summary.budget_exhausted

      claimed_at = fn schema, id ->
        Repo.one!(
          from(d in Letflow.Engine.ScriptTaskDispatcher.ScriptTaskDispatch,
            where: d.id == ^id,
            select: d.claimed_at
          ),
          prefix: schema
        )
      end

      a_times = a_rows |> Enum.map(&claimed_at.(a.schema_name, &1)) |> Enum.sort(DateTime)
      b_time = claimed_at.(b_tenant.schema_name, b_row)
      assert DateTime.compare(b_time, Enum.at(a_times, 1)) == :lt
    end

    test "T-tick-budget: the tick stops at the deadline, at most one row past it", %{t: a} do
      b_tenant = F.tenant!("gh2534-7c-budget-b")
      slow = "while true do pcall(function() local s = string.rep('x', 1000000) end) end"
      limits = %{"instructions" => 10_000_000, "timeout_ms" => 100}
      for _ <- 1..4, do: bound(a, slow, limits)
      for _ <- 1..4, do: bound(b_tenant, slow, limits)
      F.put_dispatcher_config!(:tick_budget_ms, 250)

      started = System.monotonic_time(:millisecond)
      {summary, _next} = ScriptTaskDispatcher.run_tick([a.schema_name, b_tenant.schema_name], 0)
      elapsed = System.monotonic_time(:millisecond) - started

      assert summary.budget_exhausted
      assert summary.ran >= 2 and summary.ran < 8
      # the deadline is checked between rows: at most one row (~100 ms + apply) past it
      assert elapsed < 250 + 2_000
    end

    test "T-rotating-offset: the next tick starts one tenant later", %{t: a} do
      b_tenant = F.tenant!("gh2534-7c-rot-b")
      F.put_dispatcher_config!(:max_dispatches_per_cycle, 1)
      a_ids = for _ <- 1..2, do: bound(a, F.doubling_source()).row.id
      b_ids = for _ <- 1..2, do: bound(b_tenant, F.doubling_source()).row.id
      schemas = [a.schema_name, b_tenant.schema_name]

      {s1, offset} = ScriptTaskDispatcher.run_tick(schemas, 0)
      assert s1.ran == 2
      {s2, _} = ScriptTaskDispatcher.run_tick(schemas, offset)
      assert s2.ran == 2

      second = fn schema, ids ->
        ids
        |> Enum.map(
          &Repo.get!(Letflow.Engine.ScriptTaskDispatcher.ScriptTaskDispatch, &1, prefix: schema)
        )
        |> Enum.map(& &1.claimed_at)
        |> Enum.max(DateTime)
      end

      # tick 2 started at B (offset 1): B's second row was claimed before A's second row
      assert DateTime.compare(second.(b_tenant.schema_name, b_ids), second.(a.schema_name, a_ids)) ==
               :lt
    end
  end

  # ── AC30 ────────────────────────────────────────────────────────────────────

  describe "AC30 (CDV C9): a failing sweep apply is bounded" do
    test "T-sweep-stuck", %{t: t} do
      F.put_dispatcher_config!(:sweep_failure_limit, 3)
      F.put_env!(:script_task_sweep_fault, fn _id -> :fail end)
      b = bound(t, F.doubling_source())
      {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
      F.expire_lease!(t.schema_name, row)
      handler = {__MODULE__, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler,
        [:letflow, :script_task, :sweep_stuck],
        fn _e, m, meta, _ ->
          send(test_pid, {:stuck, m, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      logs =
        for _ <- 1..4 do
          capture_log([level: :warning], fn ->
            ScriptTaskDispatcher.sweep_expired_leases(t.schema_name, 64)
          end)
        end

      stuck_lines = logs |> Enum.join() |> String.split("script task sweep stuck") |> length()
      assert stuck_lines - 1 == 1
      assert_received {:stuck, %{count: 1}, %{dispatch_id: id}} when id == row.id
      refute_received {:stuck, _, _}
      # the 4th call no longer selects the row: nothing logged
      assert Enum.at(logs, 3) == ""
      assert Enum.at(logs, 0) =~ "script task sweep failures"

      left = F.reload(t.schema_name, row)
      assert {left.status, left.sweep_failures} == {"running", 3}
      assert F.projection(t.schema_name, b.instance_id).status == :active
    end

    test "T-sweep-aggregated-log: one warning per tenant per tick", %{t: t} do
      F.put_env!(:script_task_sweep_fault, fn _id -> :fail end)
      for _ <- 1..3, do: bound(t, F.doubling_source())

      for _ <- 1..3 do
        {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
        F.expire_lease!(t.schema_name, row)
      end

      log =
        capture_log([level: :warning], fn ->
          assert %{swept: 0, failed: 3} =
                   ScriptTaskDispatcher.sweep_expired_leases(t.schema_name, 64)
        end)

      assert log |> String.split("script task sweep failures") |> length() == 2
    end
  end

  # ── seams ───────────────────────────────────────────────────────────────────

  describe "test seams honour :scripts_test_hooks only" do
    test "every 7c seam is ignored when the flag is false", %{t: t} do
      F.put_env!(:script_task_runner, F.RaisingRunner)
      F.put_env!(:script_task_sweep_fault, fn _id -> :fail end)
      F.put_env!(:script_task_apply_pause, fn _ -> raise "apply pause must not run" end)
      F.put_env!(:script_task_cancel_pause, fn _ -> raise "cancel pause must not run" end)
      F.put_env!(:script_task_hmac_fun_override, fn _ -> {:error, :missing} end)
      F.put_env!(:scripts_test_hooks, false)

      b = bound(t, F.doubling_source())
      assert {_row, {:ok, :applied}} = F.run_next!(t.schema_name)
      assert F.projection(t.schema_name, b.instance_id).variables["total"] == 42

      # sweep fault ignored: an expired lease is swept normally
      c = bound(t, F.doubling_source())
      {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
      assert row.instance_id == c.instance_id
      F.expire_lease!(t.schema_name, row)
      assert %{swept: 1} = ScriptTaskDispatcher.sweep_expired_leases(t.schema_name, 64)

      # cancel pause ignored
      d = bound(t, F.doubling_source())
      assert {:ok, _} = cancel!(t.schema_name, d.instance_id)
    end
  end
end
