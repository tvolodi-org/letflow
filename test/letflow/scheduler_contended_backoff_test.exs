defmodule Letflow.SchedulerContendedBackoffTest do
  @moduledoc """
  GH #2864 (T-0043): a timer fire that hits a lock timeout is `contended` (GH #2707 / PR-3); the
  contended timer's `fire_at`, and that of its instance's other due timers, is pushed back by
  `Scheduler.contended_backoff_ms/0` so a stuck timer cannot keep claim slots on every cycle.

    * B-1: reproduction -- with `max_timers_per_cycle` contended timers (some on one instance) a
      later-due timer of another instance is claimed and fired by the next cycle;
    * B-2: retry-then-what -- retried once per backoff interval, never counted, never DLQ'd;
    * B-3: telemetry keeps its event and gains `postponed` / `backoff_ms`; the log has no exception text;
    * B-4: isolation -- another tenant's and another instance's timers are not postponed;
    * B-5: a held timer row is skipped, not waited on; a failed peek postpones nothing;
    * B-6: config accessor; backoff 0 runs no statement;
    * B-7: recurring timer after a postponement (REQ-188 anchor, `scheduled_fire_at`).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.Event
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.Test.SandboxAutoMode

  @timeout_ms 300
  @backoff_ms 60_000

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    base = Fx.committed_tenant_case!("gh2864-backoff")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)

    Process.put(:timer_fire_lock_timeout_ms_override, @timeout_ms)

    previous = Application.get_env(:letflow, :scheduler)
    configure!(max_timers_per_cycle: 3, contended_backoff_ms: @backoff_ms)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, :scheduler, previous),
        else: Application.delete_env(:letflow, :scheduler)
    end)

    %{base: base}
  end

  # ---- fixtures ---------------------------------------------------------------------------------

  defp configure!(opts), do: Application.put_env(:letflow, :scheduler, opts)

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

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

  # one instance with TWO due timers (reminder + escalation)
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
        %{"id" => "esc-task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "r-esc"}},
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
          idempotency_key: Fx.unique("backoff-start")
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

  defp reload(base, timer), do: Repo.get!(Timer, timer.id, prefix: base.schema)

  defp make_due!(base, timer, seconds_ago) do
    fire_at =
      DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(from(t in Timer, where: t.id == ^timer.id), [set: [fire_at: fire_at]],
      prefix: base.schema
    )

    reload(base, timer)
  end

  # A due instance, its timers `seconds_ago` overdue.
  defp due_instance!(base, seconds_ago, graph \\ timer_graph()) do
    x = instance!(base, graph)
    timers = Enum.map(timers_of(base, x), &make_due!(base, &1, seconds_ago))
    {x, timers}
  end

  defp dlq_timer_rows(base),
    do: Repo.all(from(d in Dlq.Entry, where: d.entry_type == "timer"), prefix: base.schema)

  defp release!(holder) do
    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, H.await_ms())
  end

  # waits (derived from the stored value, no fixed sleep) until the timer's fire_at has passed
  defp wait_until_due!(base, timer) do
    ms = DateTime.diff(reload(base, timer).fire_at, DateTime.utc_now(), :millisecond)
    if ms > 0, do: Process.sleep(ms + 25)
    :ok
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

  # ---- B-1 --------------------------------------------------------------------------------------

  describe "B-1: contended timers do not starve a later-due timer" do
    test "limit 3 filled by held timers (one instance with two, one with one); B fires on cycle 2",
         %{base: base} do
      {a, [a1, a2]} = due_instance!(base, 30, two_timer_graph())
      {c, [c1]} = due_instance!(base, 20)
      {_b, [b1]} = due_instance!(base, 5)

      {holder_a, _} = H.hold_row(base.schema, {:projection, a})
      {holder_c, _} = H.hold_row(base.schema, {:projection, c})

      # cycle 1: the window is exactly the three held timers
      assert %{claimed: 3, fired: 0, errored: 0, exhausted: 0, contended: 2} =
               Scheduler.poll_and_fire(base.schema)

      # cycle 2 (the very next one): B's timer is claimed and fired
      assert %{claimed: 1, fired: 1, contended: 0} = Scheduler.poll_and_fire(base.schema)

      assert reload(base, b1).status == "fired"

      for timer <- [a1, a2, c1] do
        postponed = reload(base, timer)
        assert postponed.status == "pending"
        assert postponed.fire_error_count == 0

        assert DateTime.diff(postponed.fire_at, DateTime.utc_now(), :millisecond) >
                 @backoff_ms - 5_000
      end

      # the holders stayed alive across all cycles
      assert Process.alive?(holder_a.pid)
      assert Process.alive?(holder_c.pid)
      release!(holder_a)
      release!(holder_c)
    end

    test "limit 3 filled by three held instances (non-same-instance fill)", %{base: base} do
      held =
        for secs <- [30, 20, 10] do
          {x, [_t]} = due_instance!(base, secs)
          {holder, _} = H.hold_row(base.schema, {:projection, x})
          holder
        end

      {_b, [b1]} = due_instance!(base, 1)

      assert %{claimed: 3, contended: 3} = Scheduler.poll_and_fire(base.schema)
      assert %{claimed: 1, fired: 1} = Scheduler.poll_and_fire(base.schema)
      assert reload(base, b1).status == "fired"

      for holder <- held, do: release!(holder)
    end
  end

  # ---- B-2 --------------------------------------------------------------------------------------

  describe "B-2: retried once per backoff interval, never counted" do
    test "not re-claimed before the backoff, retried and postponed again after, fires on release",
         %{base: base} do
      configure!(max_timers_per_cycle: 3, contended_backoff_ms: 150)
      {x, [t]} = due_instance!(base, 10)
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      assert %{claimed: 1, contended: 1} = Scheduler.poll_and_fire(base.schema)
      first = reload(base, t).fire_at

      for _ <- 1..3 do
        wait_until_due!(base, t)

        assert %{claimed: 1, contended: 1, errored: 0, exhausted: 0} =
                 Scheduler.poll_and_fire(base.schema)
      end

      after_retries = reload(base, t)
      assert DateTime.compare(after_retries.fire_at, first) == :gt
      assert after_retries.status == "pending"
      assert after_retries.fire_error_count == 0
      assert dlq_timer_rows(base) == []

      release!(holder)
      wait_until_due!(base, t)
      assert %{claimed: 1, fired: 1, contended: 0} = Scheduler.poll_and_fire(base.schema)
      assert reload(base, t).status == "fired"
    end

    test "inside the backoff window the timer is not claimed", %{base: base} do
      {x, [_t]} = due_instance!(base, 10)
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      assert %{claimed: 1, contended: 1} = Scheduler.poll_and_fire(base.schema)
      assert %{claimed: 0, contended: 0} = Scheduler.poll_and_fire(base.schema)
      release!(holder)
    end
  end

  # ---- B-3 --------------------------------------------------------------------------------------

  describe "B-3: telemetry and log" do
    test "timer_contended keeps its metadata and gains postponed / backoff_ms", %{base: base} do
      {a, [_, _]} = due_instance!(base, 10, two_timer_graph())
      attach_telemetry([:letflow, :scheduler, :timer_contended])
      {holder, _} = H.hold_row(base.schema, {:projection, a})

      log =
        capture_log([level: :warning], fn ->
          send(self(), {:poll, Scheduler.poll_and_fire(base.schema)})
        end)

      assert_received {:poll, %{contended: 1}}
      schema = base.schema

      assert_received {:telemetry, [:letflow, :scheduler, :timer_contended], %{count: 1},
                       %{
                         tenant_schema: ^schema,
                         code: :lock_not_available,
                         postponed: 2,
                         backoff_ms: @backoff_ms
                       }}

      refute_received {:telemetry, [:letflow, :scheduler, :timer_contended], _, _}
      assert log =~ "timer fire contended (lock_not_available)"
      refute log =~ "Postgrex"
      refute log =~ "canceling statement"
      release!(holder)
    end
  end

  # ---- B-4 --------------------------------------------------------------------------------------

  describe "B-4: isolation" do
    test "another instance of the tenant and another tenant are not postponed", %{base: base} do
      other = Fx.committed_tenant_case!("gh2864-other")
      on_exit(fn -> Fx.drop_committed_tenant!(other.tenant.tenant_id) end)

      {a, [a1]} = due_instance!(base, 30)
      {_b, [b1]} = due_instance!(base, 20)
      {_o, [o1]} = due_instance!(other, 30)

      {holder, _} = H.hold_row(base.schema, {:projection, a})
      assert %{claimed: 2, contended: 1, fired: 1} = Scheduler.poll_and_fire(base.schema)
      release!(holder)

      assert DateTime.compare(reload(base, a1).fire_at, a1.fire_at) == :gt
      assert reload(other, o1).fire_at == o1.fire_at
      assert reload(other, o1).status == "pending"
      assert reload(base, b1).status == "fired"
      assert %{fired: 1} = Scheduler.poll_and_fire(other.schema)
    end
  end

  # ---- B-5 --------------------------------------------------------------------------------------

  describe "B-5: the postponement never waits, never raises" do
    test "a timer row held by another transaction is skipped", %{base: base} do
      {a, [a1, a2]} = due_instance!(base, 10, two_timer_graph())
      {proj_holder, _} = H.hold_row(base.schema, {:projection, a})
      {row_holder, _} = H.hold_row(base.schema, {:timer, a2.id})

      t0 = System.monotonic_time(:millisecond)
      result = Scheduler.poll_and_fire(base.schema)
      elapsed = System.monotonic_time(:millisecond) - t0

      # a2 is locked, hence invisible to the claim query: only a1 is claimed and postponed
      assert %{claimed: 1, contended: 1} = result
      assert elapsed < @timeout_ms + 3_000
      assert DateTime.compare(reload(base, a1).fire_at, a1.fire_at) == :gt
      assert reload(base, a2).fire_at == a2.fire_at

      release!(row_holder)
      release!(proj_holder)
    end

    test "a failed peek postpones nothing and does not raise", %{base: base} do
      {a, [a1]} = due_instance!(base, 10)
      attach_telemetry([:letflow, :scheduler, :timer_contended])
      {holder, _} = H.hold_row(base.schema, {:projection, a})
      Process.put(:timer_peek_failure, true)

      assert %{claimed: 1, contended: 1} = Scheduler.poll_and_fire(base.schema)
      Process.delete(:timer_peek_failure)

      assert_received {:telemetry, [:letflow, :scheduler, :timer_contended], _, %{postponed: 0}}
      assert reload(base, a1).fire_at == a1.fire_at
      release!(holder)
    end
  end

  # ---- B-6 --------------------------------------------------------------------------------------

  describe "B-6: configuration" do
    test "default, override, invalid values" do
      Application.delete_env(:letflow, :scheduler)
      assert Scheduler.contended_backoff_ms() == 30_000
      configure!(contended_backoff_ms: 5)
      assert Scheduler.contended_backoff_ms() == 5
      configure!(contended_backoff_ms: 0)
      assert Scheduler.contended_backoff_ms() == 0
      configure!(contended_backoff_ms: -1)
      assert Scheduler.contended_backoff_ms() == 30_000
      configure!(contended_backoff_ms: "soon")
      assert Scheduler.contended_backoff_ms() == 30_000
    end

    test "backoff 0 runs no statement: the row is untouched", %{base: base} do
      configure!(max_timers_per_cycle: 3, contended_backoff_ms: 0)
      {a, [a1]} = due_instance!(base, 10)
      before = reload(base, a1)
      {holder, _} = H.hold_row(base.schema, {:projection, a})

      assert %{claimed: 1, contended: 1} = Scheduler.poll_and_fire(base.schema)
      assert %{claimed: 1, contended: 1} = Scheduler.poll_and_fire(base.schema)

      after_polls = reload(base, a1)
      assert after_polls == before
      release!(holder)
    end
  end

  # ---- B-7 --------------------------------------------------------------------------------------

  describe "B-7: a recurring timer after a postponement (REQ-188 anchor)" do
    test "the next occurrence is anchored on the postponed fire_at; scheduled_fire_at too", %{
      base: base
    } do
      configure!(max_timers_per_cycle: 3, contended_backoff_ms: 100)
      {x, [t]} = due_instance!(base, 10)
      interval_us = 3_600_000_000

      Repo.update_all(
        from(r in Timer, where: r.id == ^t.id),
        [set: [repeat_expression: "R/PT1H", repeat_interval_us: interval_us, fired_count: 0]],
        prefix: base.schema
      )

      {holder, _} = H.hold_row(base.schema, {:projection, x})
      assert %{contended: 1} = Scheduler.poll_and_fire(base.schema)
      postponed_fire_at = reload(base, t).fire_at
      assert DateTime.compare(postponed_fire_at, t.fire_at) == :gt

      release!(holder)
      wait_until_due!(base, t)
      assert %{fired: 1} = Scheduler.poll_and_fire(base.schema)

      [next] =
        Repo.all(
          from(r in Timer,
            where: r.instance_id == ^x and r.status == "pending" and r.id != ^t.id
          ),
          prefix: base.schema
        )

      assert DateTime.diff(next.fire_at, postponed_fire_at, :microsecond) == interval_us

      [event] =
        Repo.all(
          from(e in Event, where: e.instance_id == ^x and e.event_type == "TIMER_FIRED"),
          prefix: base.schema
        )

      assert event.payload["scheduled_fire_at"] == DateTime.to_iso8601(postponed_fire_at)
    end
  end
end
