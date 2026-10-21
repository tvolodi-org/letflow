defmodule Letflow.SchedulerFireContentionTest do
  @moduledoc """
  GH #2707 / PR-3 (design `lib/letflow/design/gh2707-timer-fire-and-cold-appenders-lock-order.md`
  sections 8.4 and 9): `Scheduler.fire_timer/2` bounds EVERY lock wait of the fire with a
  transaction-local, per-wait `lock_timeout`; a lock timeout (55P03) is `{:error, :contention}`,
  an UNCOUNTED outcome of the poll (`contended`), and the route answers 503.

    * C-L1: a real holder of `P_x`, of the timer row and of `S_x`: the typed error within the
      override, nothing committed, the timer still pending, no failure counted;
    * C-L2: `poll_and_fire/1` reports `contended: 1`, emits the telemetry event and a warning with
      no exception text, and the timer fires on the next poll after the release;
    * C-L3: three lock-timeout polls do not exhaust the timer;
    * C-L4: a deadlock victim (40P01, raised by a trigger) and a non-contention error stay COUNTED;
    * C-L5: statement trace (bound `set_config`, first statement, no value in SQL text),
      transaction-local, skipped when nested;
    * C-L6: the `advance-timer` route answers 503 with a constant body (200 unaffected);
    * C-L7: after a contended timer the instance's remaining timers of the cycle are skipped;
    * C-L8: the cycle start gate (budget forced to 0 ms): the first fire runs, the rest wait;
    * C-L9: the first-poll settle burst emits one `timers_settled` event per settled instance.

  The lock timeout and the cycle budget are lowered through the process-local overrides of the
  `:engine_test_seams` build. Forced holders: `Letflow.LockOrderHelpers`. Sandbox `:auto`, hence
  `async: false`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.Event
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  @timeout_ms 300
  @constant_detail "the instance is being modified concurrently; retry"

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    base = Fx.committed_tenant_case!("gh2707-contention")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)

    Process.put(:timer_fire_lock_timeout_ms_override, @timeout_ms)
    %{base: base}
  end

  # ---- fixtures ---------------------------------------------------------------------------------

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  # START -> tmr (TIMER) -> h1 (HUMAN) -> END
  defp timer_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "PT1H"}
        },
        %{"id" => "h1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "tmr"), edge("e2", "tmr", "h1"), edge("e3", "h1", "end")]
    }
  end

  # START -> orig (HUMAN with a reminder AND an escalation timer) -> esc-task (HUMAN) -> END
  defp two_timer_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "orig",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{
            "role" => "approver",
            "reminder_timer_duration" => "PT1H",
            "reminder_role" => "r-remind",
            "escalation_timer_duration" => "PT4H",
            "escalation_role" => "r-esc"
          }
        },
        %{
          "id" => "esc-task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "r-esc"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        edge("e1", "start", "orig"),
        edge("e2", "orig", "esc-task"),
        edge("e3", "esc-task", "end")
      ]
    }
  end

  defp instance!(base, graph) do
    definition = Fx.legacy_activate!(base.schema, base.user, graph, [])

    {:ok, %{instance_id: id}} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("contention-start")
        },
        prefix: base.schema
      )

    id
  end

  defp timers_of(base, instance_id) do
    Repo.all(from(t in Timer, where: t.instance_id == ^instance_id, order_by: t.created_at),
      prefix: base.schema
    )
  end

  defp timer!(base, instance_id, type) do
    [timer] = Enum.filter(timers_of(base, instance_id), &(&1.timer_type == type))
    timer
  end

  defp reload(base, timer), do: Repo.get!(Timer, timer.id, prefix: base.schema)

  # force-due: `seconds_ago` older means claimed earlier
  defp make_due!(base, timer, seconds_ago) do
    fire_at =
      DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(from(t in Timer, where: t.id == ^timer.id), [set: [fire_at: fire_at]],
      prefix: base.schema
    )

    timer
  end

  defp timer_fired_events(base, instance_id) do
    Repo.all(
      from(e in Event, where: e.instance_id == ^instance_id and e.event_type == "TIMER_FIRED"),
      prefix: base.schema
    )
  end

  defp dlq_timer_rows(base),
    do: Repo.all(from(d in Dlq.Entry, where: d.entry_type == "timer"), prefix: base.schema)

  defp assert_nothing_committed!(base, x, timer) do
    reloaded = reload(base, timer)
    assert reloaded.status == "pending"
    assert reloaded.fire_error_count == 0
    assert timer_fired_events(base, x) == []
  end

  defp release!(holder) do
    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, H.await_ms())
  end

  defp timed(fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - t0}
  end

  defp attach_telemetry(event) do
    id = {__MODULE__, event, make_ref()}
    test_pid = self()

    :telemetry.attach(
      id,
      event,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  # GH #2864: these tests re-poll the same contended timer and expect it to be re-claimed at
  # once, which is the behaviour with the postponement off.
  defp no_contended_backoff(_context) do
    previous = Application.get_env(:letflow, :scheduler)

    Application.put_env(
      :letflow,
      :scheduler,
      Keyword.put(previous || [], :contended_backoff_ms, 0)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, :scheduler, previous),
        else: Application.delete_env(:letflow, :scheduler)
    end)

    :ok
  end

  # ---- C-L1 -------------------------------------------------------------------------------------

  describe "C-L1: a fire blocked on a held row times out as {:error, :contention}" do
    test "the instance projection P_x", %{base: base} do
      x = instance!(base, timer_graph())
      timer = hd(timers_of(base, x))
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      {result, elapsed} = timed(fn -> Scheduler.fire_timer(timer.id, base.schema) end)

      assert result == {:error, :contention}

      assert elapsed >= @timeout_ms - 50 and elapsed < @timeout_ms + 3_000,
             "returned after #{elapsed} ms"

      assert_nothing_committed!(base, x, timer)
      release!(holder)

      # the retry succeeds once the holder is gone
      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, base.schema)
    end

    test "the timer row itself (taken after P_x)", %{base: base} do
      x = instance!(base, timer_graph())
      timer = hd(timers_of(base, x))
      {holder, _} = H.hold_row(base.schema, {:timer, timer.id})

      {result, elapsed} = timed(fn -> Scheduler.fire_timer(timer.id, base.schema) end)

      assert result == {:error, :contention}

      assert elapsed >= @timeout_ms - 50 and elapsed < @timeout_ms + 3_000,
             "returned after #{elapsed} ms"

      assert_nothing_committed!(base, x, timer)
      release!(holder)
      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, base.schema)
    end

    test "the instance sequence row S_x (a later wait of the same fire)", %{base: base} do
      x = instance!(base, timer_graph())
      timer = hd(timers_of(base, x))
      {holder, _} = H.hold_row(base.schema, {:sequence, x})

      {result, elapsed} = timed(fn -> Scheduler.fire_timer(timer.id, base.schema) end)

      assert result == {:error, :contention}

      assert elapsed >= @timeout_ms - 50 and elapsed < @timeout_ms + 3_000,
             "returned after #{elapsed} ms"

      assert_nothing_committed!(base, x, timer)
      release!(holder)
      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, base.schema)
    end
  end

  # ---- C-L2 / C-L3 ------------------------------------------------------------------------------

  describe "C-L2: poll_and_fire reports contended" do
    setup :no_contended_backoff

    test "counter, telemetry, warning without exception text, fires after the release", %{
      base: base
    } do
      x = instance!(base, timer_graph())
      timer = make_due!(base, hd(timers_of(base, x)), 10)
      attach_telemetry([:letflow, :scheduler, :timer_contended])
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      log =
        capture_log([level: :warning], fn ->
          send(self(), {:poll, Scheduler.poll_and_fire(base.schema)})
        end)

      assert_received {:poll, result}

      assert result == %{
               tenant_schema: base.schema,
               claimed: 1,
               fired: 0,
               errored: 0,
               exhausted: 0,
               contended: 1
             }

      schema = base.schema

      assert_received {:telemetry, [:letflow, :scheduler, :timer_contended], %{count: 1},
                       %{
                         tenant_schema: ^schema,
                         timer_type: "deadline",
                         code: :lock_not_available
                       }}

      refute_received {:telemetry, [:letflow, :scheduler, :timer_contended], _, _}

      assert log =~ "timer fire contended (lock_not_available)"
      refute log =~ "Postgrex"
      refute log =~ "canceling statement"
      refute log =~ "lock timeout"

      assert_nothing_committed!(base, x, timer)
      release!(holder)

      assert %{claimed: 1, fired: 1, errored: 0, contended: 0} =
               Scheduler.poll_and_fire(base.schema)

      assert reload(base, timer).status == "fired"
    end
  end

  describe "C-L3: repeated lock timeouts never exhaust the timer" do
    setup :no_contended_backoff

    test "three polls, then the timer is still pending and no DLQ row exists", %{base: base} do
      x = instance!(base, timer_graph())
      timer = make_due!(base, hd(timers_of(base, x)), 10)
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      for _ <- 1..3 do
        assert %{claimed: 1, contended: 1, errored: 0, exhausted: 0} =
                 Scheduler.poll_and_fire(base.schema)
      end

      assert_nothing_committed!(base, x, timer)
      assert dlq_timer_rows(base) == []
      release!(holder)
    end
  end

  # ---- C-L4 -------------------------------------------------------------------------------------

  describe "C-L4: the classifier" do
    defp raise_on_fire_trigger!(base, sqlstate) do
      fun = ~s("#{base.schema}"."raise_on_fire_#{sqlstate}")

      Repo.query!("""
      CREATE FUNCTION #{fun}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'injected' USING ERRCODE = '#{sqlstate}'; END $$
      """)

      Repo.query!("""
      CREATE TRIGGER raise_on_fire BEFORE UPDATE ON "#{base.schema}"."timers"
      FOR EACH ROW WHEN (NEW.status = 'fired') EXECUTE FUNCTION #{fun}()
      """)
    end

    test "55P03 is the uncounted :contended" do
      assert {:ok, :lock_not_available} =
               Letflow.Engine.Contention.contention_code(%Postgrex.Error{
                 postgres: %{code: :lock_not_available}
               })

      assert {:ok, :deadlock_detected} =
               Letflow.Engine.Contention.contention_code(%Postgrex.Error{
                 postgres: %{code: :deadlock_detected}
               })

      assert :error = Letflow.Engine.Contention.contention_code(%RuntimeError{message: "x"})
    end

    test "a 55P03 raised by the fire's own UPDATE is contended, nothing counted", %{base: base} do
      x = instance!(base, timer_graph())
      timer = make_due!(base, hd(timers_of(base, x)), 10)
      raise_on_fire_trigger!(base, "55P03")

      assert :contended = Scheduler.attempt_fire(timer.id, base.schema)
      assert reload(base, timer).fire_error_count == 0
    end

    test "a deadlock victim (40P01) stays a COUNTED failure: three polls land failed + DLQ", %{
      base: base
    } do
      x = instance!(base, timer_graph())
      timer = make_due!(base, hd(timers_of(base, x)), 10)
      raise_on_fire_trigger!(base, "40P01")

      log =
        capture_log(fn ->
          assert %{errored: 1, contended: 0} = Scheduler.poll_and_fire(base.schema)
          assert reload(base, timer).fire_error_count == 1
          assert %{errored: 1, contended: 0} = Scheduler.poll_and_fire(base.schema)
          assert %{exhausted: 1, contended: 0} = Scheduler.poll_and_fire(base.schema)
        end)

      assert is_binary(log)
      assert reload(base, timer).status == "failed"
      assert [_one] = dlq_timer_rows(base)
    end

    test "a non-contention error is counted as before", %{base: base} do
      x = instance!(base, timer_graph())
      timer = make_due!(base, hd(timers_of(base, x)), 10)
      raise_on_fire_trigger!(base, "23514")

      capture_log(fn ->
        assert %{errored: 1, contended: 0} = Scheduler.poll_and_fire(base.schema)
      end)

      assert reload(base, timer).fire_error_count == 1
    end
  end

  # ---- C-L5 -------------------------------------------------------------------------------------

  describe "C-L5: the timeout is a bound, transaction-local, first-statement setting" do
    test "statement trace: set_config first, value only as a parameter", %{base: base} do
      x = instance!(base, timer_graph())
      timer = hd(timers_of(base, x))

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Scheduler.fire_timer(timer.id, base.schema)
        end)

      assert {:ok, :fired} = result
      sql = Enum.map(queries, & &1.query)

      first_data =
        Enum.find(sql, fn q -> not (q =~ ~r/^(begin|commit|rollback)$/i) end)

      assert first_data =~ "set_config('lock_timeout', $1, true)"
      assert %{params: ["300ms"]} = Enum.find(queries, &(&1.query =~ "set_config"))

      assert Enum.count(sql, &(&1 =~ "set_config")) == 1
      refute Enum.any?(sql, &(&1 =~ ~r/lock_timeout.*\d+\s*ms/i))
      refute Enum.any?(sql, &(&1 =~ ~r/\b300\b/))
    end

    test "transaction-local: the connection is back to its default afterwards", %{base: base} do
      x = instance!(base, timer_graph())
      timer = hd(timers_of(base, x))

      Repo.checkout(fn ->
        %{rows: [[before]]} = Repo.query!("SHOW lock_timeout")
        assert {:ok, :fired} = Scheduler.fire_timer(timer.id, base.schema)
        assert %{rows: [[^before]]} = Repo.query!("SHOW lock_timeout")
      end)
    end

    test "nested in the caller's transaction the setting is skipped", %{base: base} do
      x = instance!(base, timer_graph())
      timer = hd(timers_of(base, x))

      {{:ok, result}, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Repo.transaction(fn -> Scheduler.fire_timer(timer.id, base.schema) end)
        end)

      assert result == {:ok, :fired}
      refute Enum.any?(queries, &(&1.query =~ "set_config"))
    end

    test "the default is 2 s when no override is set" do
      Process.delete(:timer_fire_lock_timeout_ms_override)
      assert Engine.Contention.timer_fire_lock_timeout_ms() == 2_000
      assert Engine.Contention.timer_fire_lock_timeout_setting() == "2000ms"
    end
  end

  # ---- C-L6 -------------------------------------------------------------------------------------

  describe "C-L6: the advance-timer route" do
    defp advance_timer(base, x, timer_id) do
      conn("POST", "/#{x}/advance-timer")
      |> Map.put(:body_params, %{"timer_id" => timer_id})
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: base.user.id,
        tenant_id: base.tenant.tenant_id,
        roles: ["PROCESS_OPERATOR"]
      })
      |> assign(:trace_id, "fixed-test-trace-id")
      |> Letflow.Routers.Instances.call(Letflow.Routers.Instances.init([]))
    end

    test "503 with the constant body on a real lock timeout; the retry is 200", %{base: base} do
      x = instance!(base, timer_graph())
      timer = hd(timers_of(base, x))
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      conn = advance_timer(base, x, timer.id)

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 503
      assert body["detail"] == @constant_detail
      refute conn.resp_body =~ "Postgrex"
      refute conn.resp_body =~ "55P03"
      refute conn.resp_body =~ timer.id <> "\""
      assert get_resp_header(conn, "retry-after") == []
      assert_nothing_committed!(base, x, timer)

      release!(holder)
      conn = advance_timer(base, x, timer.id)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["timer_status"] == "fired"
    end

    test "already_final is unaffected (200)", %{base: base} do
      x = instance!(base, timer_graph())
      timer = hd(timers_of(base, x))

      {:ok, _} =
        Engine.cancel_instance(
          x,
          %{actor_id: base.user.id, idempotency_key: Fx.unique("contention-cancel")},
          prefix: base.schema
        )

      {:ok, ghost} =
        Scheduler.create(
          Repo,
          %{
            instance_id: x,
            timer_type: "deadline",
            node_id: "ghost",
            fire_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
          },
          prefix: base.schema
        )

      conn = advance_timer(base, x, ghost.id)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["timer_status"] == "already_final"
      assert reload(base, timer).status == "cancelled"
    end
  end

  # ---- C-L7 -------------------------------------------------------------------------------------

  describe "C-L7: same-instance skip" do
    test "after the first contended timer the instance's others are not attempted", %{base: base} do
      x = instance!(base, two_timer_graph())
      y = instance!(base, timer_graph())
      reminder = make_due!(base, timer!(base, x, "reminder"), 30)
      escalation = make_due!(base, timer!(base, x, "escalation"), 20)
      y_timer = make_due!(base, hd(timers_of(base, y)), 10)
      attach_telemetry([:letflow, :scheduler, :timer_contended])
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      result = Scheduler.poll_and_fire(base.schema)

      assert %{claimed: 3, contended: 1, fired: 1, errored: 0, exhausted: 0} = result
      assert_received {:telemetry, _, %{count: 1}, %{timer_type: "reminder"}}
      refute_received {:telemetry, _, _, _}

      assert reload(base, reminder).status == "pending"
      assert reload(base, escalation).status == "pending"
      assert reload(base, y_timer).status == "fired"
      release!(holder)
    end
  end

  # ---- C-L8 -------------------------------------------------------------------------------------

  describe "C-L8: the cycle start gate" do
    test "budget 0 ms: the first fire runs, the rest stay pending and fire next poll", %{
      base: base
    } do
      x = instance!(base, timer_graph())
      y = instance!(base, timer_graph())
      first = make_due!(base, hd(timers_of(base, x)), 20)
      second = make_due!(base, hd(timers_of(base, y)), 10)

      Process.put(:timer_cycle_budget_ms_override, 0)
      assert %{claimed: 2, fired: 1, contended: 0} = Scheduler.poll_and_fire(base.schema)
      assert reload(base, first).status == "fired"
      assert reload(base, second).status == "pending"

      Process.delete(:timer_cycle_budget_ms_override)
      assert %{claimed: 1, fired: 1} = Scheduler.poll_and_fire(base.schema)
      assert reload(base, second).status == "fired"
    end
  end

  # ---- C-L9 -------------------------------------------------------------------------------------

  describe "C-L9: the first-poll settle burst" do
    test "one timers_settled event per settled instance", %{base: base} do
      attach_telemetry([:letflow, :scheduler, :timers_settled])

      # instance one has TWO pending ghost timers (count 2), instance two has one (count 1)
      settled =
        for ghosts <- [2, 1] do
          x = instance!(base, timer_graph())

          {:ok, _} =
            Engine.cancel_instance(
              x,
              %{actor_id: base.user.id, idempotency_key: Fx.unique("contention-cancel")},
              prefix: base.schema
            )

          for n <- 1..ghosts do
            {:ok, timer} =
              Scheduler.create(
                Repo,
                %{
                  instance_id: x,
                  timer_type: "deadline",
                  node_id: "ghost-#{n}",
                  fire_at:
                    DateTime.utc_now()
                    |> DateTime.add(-30, :second)
                    |> DateTime.truncate(:microsecond)
                },
                prefix: base.schema
              )

            timer
          end
        end
        |> List.flatten()

      assert %{claimed: 3, errored: 0, contended: 0} = Scheduler.poll_and_fire(base.schema)

      schema = base.schema

      counts =
        for _ <- 1..2 do
          assert_received {:telemetry, [:letflow, :scheduler, :timers_settled], %{count: count},
                           %{tenant_schema: ^schema, reason: "instance_cancelled"}}

          count
        end

      assert Enum.sort(counts) == [1, 2]
      refute_received {:telemetry, [:letflow, :scheduler, :timers_settled], _, _}
      assert Enum.all?(settled, &(reload(base, &1).status == "cancelled"))
    end
  end

  # ---- cycle budget default, peek failure ---------------------------------------------------------

  describe "the cycle budget default and the sweep budget" do
    test "the default is 5 s and at most half the sweep task timeout" do
      assert Scheduler.default_cycle_budget_ms() == 5_000
      assert Scheduler.sweep_task_timeout_ms() >= 2 * Scheduler.default_cycle_budget_ms()
    end
  end

  describe "a failing post-fire peek" do
    test "contended is still counted, the type is nil, nothing is skipped, nothing crashes", %{
      base: base
    } do
      x = instance!(base, two_timer_graph())
      reminder = make_due!(base, timer!(base, x, "reminder"), 30)
      escalation = make_due!(base, timer!(base, x, "escalation"), 20)
      attach_telemetry([:letflow, :scheduler, :timer_contended])
      {holder, _} = H.hold_row(base.schema, {:projection, x})
      Process.put(:timer_peek_failure, true)

      result = Scheduler.poll_and_fire(base.schema)

      # no instance id is known, so the second timer is attempted too and contends as well
      assert %{claimed: 2, contended: 2, errored: 0, fired: 0} = result
      assert_received {:telemetry, _, %{count: 1}, %{timer_type: nil}}
      assert_received {:telemetry, _, %{count: 1}, %{timer_type: nil}}
      assert reload(base, reminder).status == "pending"
      assert reload(base, escalation).status == "pending"
      release!(holder)
    end
  end
end
