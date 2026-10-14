defmodule Letflow.Supervisor.PollersTest do
  @moduledoc """
  REQ-219 (design `req219-supervision-layering.md` §4/§5/§6/§8): AC2 (a
  genuine cold-boot ordering test), AC4 (crash-loop isolation), and AC7
  (empty-children-list under `config/test.exs`'s current gates).

  `async: false` -- mutates global `Application` config and, uniquely
  among this module's tests, the AC2 test stops/restarts the ENTIRE
  `:letflow` OTP application. Leans on the same ExUnit scheduling
  guarantee `test/support/admission_test_helpers.ex`'s moduledoc already
  documents and relies on for a lighter-weight single-singleton restart:
  all `async: true` modules finish before any `async: false` module
  starts, and `async: false` modules run strictly one at a time relative
  to each other -- so no other test's Sandbox checkout against
  `Letflow.Repo` can be in flight while this module's AC2 test tears it
  down and restarts it.

  Test order in this file is deliberate (not enforced by ExUnit, but
  written in this order per the design doc's own suggestion): AC7, then
  AC4, then AC2 last, since AC2 is the one test in this design that
  stops/restarts the whole application -- running it last avoids
  perturbing the others with an extra full-app restart.

  ## Design doc §9 Q4 -- empirically resolved

  The design's own open question (whether `:logger.add_primary_filter/2`
  raises, vs. silently ignores, a duplicate filter id) was left unverified
  because that design environment had no reachable Elixir/OTP runtime.
  This environment does: running the AC2 test below WITHOUT its
  `:logger.remove_primary_filter/1` defensive step (a temporary local
  edit, reverted before this commit) completed with **no raise and no
  logged error** on this project's pinned toolchain (Elixir 1.20.3 / OTP
  29) -- `:logger.add_primary_filter/2` is a silent no-op (or an ignored
  error return) on a duplicate id here, not a raise, contrary to the
  original inline comment's own stated assumption in
  `lib/letflow/application.ex`. The defensive removal step is kept anyway,
  per the design's own reasoning: it is a no-op-safe call either way, and
  keeping it is more faithful to that comment's "exactly once per node"
  assumption than silently relying on this one runtime's observed
  behavior, which is not itself an OTP-documented contract.
  """

  use ExUnit.Case, async: false

  test "AC7: Letflow.Supervisor.Pollers has zero children under config/test.exs's current gates" do
    refute Application.get_env(:letflow, :start_scheduler, true)
    refute Application.get_env(:letflow, :start_service_task_dispatcher, true)
    refute Application.get_env(:letflow, :start_script_task_dispatcher, true)

    assert Process.whereis(Letflow.Supervisor.Pollers) != nil
    assert Supervisor.which_children(Letflow.Supervisor.Pollers) == []
  end

  test "AC4: init/1 includes exactly the two gated poller children, in order, when both gates are true (pure -- no process started)" do
    # Coverage gap this test closes: the crash-loop test below flips
    # :start_scheduler to true and restarts the LIVE Letflow.Supervisor.Pollers
    # singleton, but that restart is immediately followed by an induced crash
    # -- nothing in this file previously asserted the actual which_children/1
    # id list Letflow.Supervisor.Pollers.init/1 produces when BOTH gates are
    # true (the "owns exactly Letflow.Scheduler.Poller and
    # Letflow.Engine.ServiceTaskDispatcher.Poller" half of AC4's own text, as
    # opposed to the "zero children when both false" half AC7 above already
    # covers). Calling init/1 directly is a plain, side-effect-free function
    # call (Supervisor.init/2's own documented contract: it returns
    # {:ok, {flags, child_specs}}, it starts nothing) -- this does not touch
    # the live supervision tree or spawn either Poller GenServer, so it
    # carries none of the zero-delay-first-tick/DBConnection.OwnershipError
    # hazard the crash-loop test below exists to reproduce deliberately.
    original_scheduler = Application.get_env(:letflow, :start_scheduler, true)
    original_dispatcher = Application.get_env(:letflow, :start_service_task_dispatcher, true)

    on_exit(fn ->
      Application.put_env(:letflow, :start_scheduler, original_scheduler)
      Application.put_env(:letflow, :start_service_task_dispatcher, original_dispatcher)
    end)

    Application.put_env(:letflow, :start_scheduler, true)
    Application.put_env(:letflow, :start_service_task_dispatcher, true)

    {:ok, {_flags, children}} = Letflow.Supervisor.Pollers.init(nil)

    ids = Enum.map(children, & &1.id)
    assert ids == [Letflow.Scheduler.Poller, Letflow.Engine.ServiceTaskDispatcher.Poller]
  end

  test "GH 2534 7c-1: the script poller is a third, independently gated child (pure init/1)" do
    keys = [:start_scheduler, :start_service_task_dispatcher, :start_script_task_dispatcher]
    originals = Map.new(keys, &{&1, Application.get_env(:letflow, &1, true)})

    on_exit(fn -> Enum.each(originals, fn {k, v} -> Application.put_env(:letflow, k, v) end) end)

    Enum.each(keys, &Application.put_env(:letflow, &1, true))
    {:ok, {_flags, children}} = Letflow.Supervisor.Pollers.init(nil)

    assert Enum.map(children, & &1.id) == [
             Letflow.Scheduler.Poller,
             Letflow.Engine.ServiceTaskDispatcher.Poller,
             Letflow.Engine.ScriptTaskDispatcher.Poller
           ]

    Application.put_env(:letflow, :start_script_task_dispatcher, false)
    {:ok, {_flags, children}} = Letflow.Supervisor.Pollers.init(nil)
    refute Letflow.Engine.ScriptTaskDispatcher.Poller in Enum.map(children, & &1.id)
  end

  describe "AC4: crash-loop isolation" do
    test "a Poller crash-looping past Pollers' own restart intensity restarts only Letflow.Supervisor.Pollers" do
      repo_pid_before = Process.whereis(Letflow.Repo)
      pollers_pid_before = Process.whereis(Letflow.Supervisor.Pollers)
      infrastructure_pid_before = Process.whereis(Letflow.Supervisor.Infrastructure)

      assert repo_pid_before != nil
      assert pollers_pid_before != nil

      original_start_scheduler = Application.get_env(:letflow, :start_scheduler, true)

      on_exit(fn ->
        Application.delete_env(:letflow, :force_poller_crash)
        Application.put_env(:letflow, :start_scheduler, original_start_scheduler)
        restart_pollers!()
      end)

      Application.put_env(:letflow, :start_scheduler, true)
      Application.put_env(:letflow, :force_poller_crash, true)

      # ISS-0451 rework iteration 3 (design doc
      # iss0451-poller-crash-budget-isolation.md §5, "REWORK ITERATION 3"):
      # single trigger, no test-issued restart call. Once
      # Letflow.Supervisor.PollersBreaker exists, it is the SOLE restart
      # authority for Letflow.Supervisor.Pollers from the very first :DOWN
      # onward -- a test that also issues its own start_child/2 call here
      # competes with the one actor that legitimately owns all such
      # restarts (empirically reproduced in this rework's prior iteration:
      # a MatchError race on {:error, {:already_started, pid}}, or a lost
      # synchronous window before the breaker's own observation timer).
      # This terminate_child/2 call alone produces exactly the :DOWN
      # PollersBreaker needs to perform its own first, :closed-state
      # restart -- the same trigger mechanism this design's own §6.2
      # regression test uses.
      :ok = Supervisor.terminate_child(Letflow.Supervisor, Letflow.Supervisor.Pollers)

      # Wait for the breaker's own restart, not a bare pid-appears poll:
      # poll PollersBreaker.breaker_state/0 together with
      # Process.whereis/1 until a new, non-nil pid distinct from
      # pollers_pid_before appears AND breaker_state() == :closed --
      # confirming the breaker's own observation timer has not yet seen a
      # 2nd :DOWN (i.e. this is the single-shot case, not yet tripped).
      new_pollers_pid = wait_for_breaker_restart(pollers_pid_before)
      assert new_pollers_pid != nil
      assert new_pollers_pid != pollers_pid_before

      # Clear the fault before a possible SECOND exhaustion cycle,
      # immediately after step 4's wait succeeds -- preserves the existing
      # test's "clear the fault promptly so only ONE exhaustion cycle
      # occurs" intent (REQ-219 AC4's single-shot scenario), now correctly
      # synchronized against the ONE actor (PollersBreaker) that could
      # otherwise trip a 2nd time.
      Application.delete_env(:letflow, :force_poller_crash)
      Application.put_env(:letflow, :start_scheduler, false)

      # Letflow.Repo and Letflow.Supervisor.Infrastructure are untouched --
      # the AC4-mandated proof that the crash-loop is isolated to
      # Letflow.Supervisor.Pollers alone.
      assert Process.whereis(Letflow.Repo) == repo_pid_before
      assert Process.whereis(Letflow.Supervisor.Infrastructure) == infrastructure_pid_before

      # Letflow.Supervisor.Pollers WAS restarted, not merely left down --
      # restated against the breaker-restarted pid captured above (no
      # longer "a third pid distinct from a test-restarted second pid" --
      # there is no test-restarted second pid any more, only the
      # breaker's one restart).
      assert Process.whereis(Letflow.Supervisor.Pollers) == new_pollers_pid

      # ISS-0451-motivated confirming assertion: the single-shot fault did
      # NOT trip the breaker, i.e. this really was REQ-219 AC4's
      # single-shot scenario and not an accidental 2nd trip.
      assert Letflow.Supervisor.PollersBreaker.breaker_state() == :closed
    end
  end

  describe "AC2: cold-boot ordering (Infrastructure fully started before Pollers starts)" do
    test "Obs.Alerts.TaskSupervisor is already registered at the moment Pollers.init/1 runs, on a genuine cold boot" do
      test_pid = self()

      Application.put_env(:letflow, :pollers_init_probe, fn whereis_result ->
        send(test_pid, {:pollers_init_whereis, whereis_result})
      end)

      on_exit(fn -> Application.delete_env(:letflow, :pollers_init_probe) end)

      :ok = Application.stop(:letflow)

      assert Process.whereis(Letflow.Obs.Alerts.TaskSupervisor) == nil

      # Letflow.Application.start/2's first line re-registers this same
      # filter id via :logger.add_primary_filter/2 on the very next line
      # below (Application.ensure_all_started/1). Removed defensively here
      # so that call is a genuine first-time registration again, rather
      # than depending on whatever :logger.add_primary_filter/2 does with a
      # duplicate id -- EMPIRICALLY CONFIRMED (this test module's own
      # moduledoc records the finding) that omitting this line does NOT
      # raise on this OTP release either, but the design's own §4.3 step 3
      # rationale for keeping it regardless (a no-op removal-then-readd is
      # never a hazard, and it stays faithful to the original comment's
      # "exactly once per node" assumption) still holds, so it is kept.
      :logger.remove_primary_filter(:letflow_secrets_redaction)

      {:ok, _apps} = Application.ensure_all_started(:letflow)

      assert_receive {:pollers_init_whereis, whereis_result}, 5_000
      assert whereis_result != nil
    end
  end

  # ISS-0451 rework iteration 3 (design doc §5 step 4): polls (up to ~2
  # seconds wall clock, comfortably inside PollersBreaker's own
  # @observation_window_ms) for BOTH Process.whereis(Letflow.Supervisor.Pollers)
  # to become a pid other than `stale_pid` AND
  # PollersBreaker.breaker_state() == :closed at the same moment --
  # PollersBreaker's own :closed-state restart (Supervisor.start_child/2)
  # is asynchronous relative to this test process, and requiring
  # breaker_state() == :closed alongside the new pid confirms this
  # observation lands on the single-shot restart, not a moment after a
  # 2nd :DOWN has already flipped the breaker toward :open.
  defp wait_for_breaker_restart(stale_pid, attempts_left \\ 2_000) do
    pid = Process.whereis(Letflow.Supervisor.Pollers)
    state = Letflow.Supervisor.PollersBreaker.breaker_state()

    cond do
      not is_nil(pid) and pid != stale_pid and state == :closed ->
        pid

      attempts_left > 0 ->
        wait_for_breaker_restart(stale_pid, attempts_left - 1)

      true ->
        pid
    end
  end

  # ISS-0451 (design iss0451-poller-crash-budget-isolation.md §5, "Second,
  # previously-unflagged consequence"): Letflow.Supervisor.Pollers' own
  # child spec is now restart: :temporary (see lib/letflow/application.ex),
  # so terminate_child/2 deletes its spec immediately, same as an automatic
  # exit -- any subsequent restart_child/2 call returns {:error, :not_found}
  # rather than a fresh pid. start_child/2 with the full restart:
  # :temporary-carrying child spec is the call that still works.
  #
  # Genuine additional defect found while implementing this design (beyond
  # what its own rework already fixed, reported per this step's own task
  # instructions): if Pollers is alive at the moment terminate_child/2 runs
  # here, Letflow.Supervisor.PollersBreaker (in :closed state, monitoring
  # that same live pid) ALSO reacts to the resulting :DOWN and issues its
  # own competing start_child/2 call -- a genuine two-restarter race with
  # this helper for the identical :temporary child spec, empirically
  # observed to make whichever call loses return
  # {:error, {:already_started, pid}} instead of {:ok, pid}. Since
  # PollersBreaker is the design's own intended sole restart authority for
  # Pollers, this helper tolerates that outcome rather than crashing on it
  # -- its contract is "Pollers ends up running again," not "this call
  # personally started it."
  defp restart_pollers! do
    :ok = Supervisor.terminate_child(Letflow.Supervisor, Letflow.Supervisor.Pollers)

    case Supervisor.start_child(
           Letflow.Supervisor,
           Supervisor.child_spec(Letflow.Supervisor.Pollers, restart: :temporary)
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
