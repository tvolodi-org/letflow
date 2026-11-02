defmodule Letflow.Engine.Wasm.InvocationLeaseTest do
  @moduledoc """
  ISS-0418 -- coverage for `Letflow.Engine.Wasm.InvocationLease`'s own mechanics, in
  isolation from any real `wasmex` call. See
  `lib/letflow/design/iss0418-wasm-concurrency-cap.md` §6.5 for the full rationale.

  This suite proves the primitive's mechanics correct against a synthetic
  `Process.exit(pid, :kill)` stand-in for `PluginInterface.invoke/2,3`'s own
  brutal-kill -- fast, deterministic, zero dependency on `wasmex`. It does NOT prove
  the lease's PLACEMENT is correct against a real hang -- that is proven separately by
  the `:wasm_hang`-tagged tests wired directly in `call_timeout_test.exs`,
  `host_api_write_test.exs`, and `plugin_handler_test.exs` (design doc §6.4).

  `async: false`: several tests here start a SECOND process to exercise
  `try_acquire/1` from a distinct caller pid, and rely on this test's own isolated
  `InvocationLease` instance (started fresh per test via `start_supervised!/1`,
  mirroring `Letflow.Admission`'s own `start_link/1` test-isolation `opts` override
  convention) not being contended by any other concurrently-running test.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Engine.Wasm.InvocationLease

  defp start_lease(cap) do
    name = :"invocation_lease_test_#{System.unique_integer([:positive])}"
    start_supervised!({InvocationLease, name: name, cap: cap})
    name
  end

  describe "try_acquire/1 and release/2: ordinary acquire/release lifecycle" do
    test "a first try_acquire/1 succeeds and reports the configured cap" do
      server = start_lease(2)

      assert InvocationLease.cap(server) == 2
      assert {:ok, %InvocationLease.Lease{}} = InvocationLease.try_acquire(server)
    end

    test "an explicit release/2 frees the slot for a subsequent try_acquire/1" do
      server = start_lease(1)

      assert {:ok, lease} = InvocationLease.try_acquire(server)
      assert {:error, :capacity} = InvocationLease.try_acquire(server)

      assert :ok = InvocationLease.release(lease, server)

      assert {:ok, _lease2} = InvocationLease.try_acquire(server)
    end
  end

  describe "PROVE NON-VACUITY: a cap that ignores the limit, or a release that is skipped, must make these tests fail" do
    test "a second, concurrent try_acquire/1 against a cap: 1 instance returns {:error, :capacity} while the first lease is held" do
      server = start_lease(1)

      assert {:ok, _lease} = InvocationLease.try_acquire(server)

      # From a SECOND process, exactly the "concurrent caller" shape this cap exists
      # to bound -- if the cap were ignored (e.g. always replying {:ok, _}), this
      # assertion is the one that would catch it.
      test_pid = self()

      second_pid =
        spawn(fn ->
          result = InvocationLease.try_acquire(server)
          send(test_pid, {:second_result, result})
        end)

      assert_receive {:second_result, second_result}, 1_000
      assert second_result == {:error, :capacity}
      refute Process.alive?(second_pid)
    end

    test "release/2 genuinely decrements in_use -- a no-op release would leave the second acquire blocked" do
      server = start_lease(1)

      assert {:ok, lease} = InvocationLease.try_acquire(server)
      assert :ok = InvocationLease.release(lease, server)

      # If release/2 were a no-op (the "skip release" defect this test exists to
      # catch), in_use would still read 1 against a cap of 1 and this would fail
      # with {:error, :capacity}.
      assert {:ok, _lease2} = InvocationLease.try_acquire(server)
    end
  end

  describe "the monitor backstop: a lease is released automatically when its holder dies" do
    test "after the lease-holder is killed WITHOUT calling release/2, a subsequent try_acquire/1 succeeds within a bounded wait" do
      server = start_lease(1)

      test_pid = self()

      holder_pid =
        spawn(fn ->
          {:ok, _lease} = InvocationLease.try_acquire(server)
          send(test_pid, :acquired)
          # Never calls release/2 -- dies uncleanly instead, mirroring the exact
          # brutal-kill shape PluginInterface.invoke/2,3's own outer timeout would
          # inflict on a lease-holder wired in wrong (design doc §2).
          Process.sleep(:infinity)
        end)

      assert_receive :acquired, 1_000

      # Cap is exhausted while the holder is still alive.
      assert {:error, :capacity} = InvocationLease.try_acquire(server)

      Process.exit(holder_pid, :kill)

      # The monitor-driven auto-release (design doc §2/§5.4) must free the slot --
      # if the monitor backstop were missing or wrong (e.g. never installed, or
      # installed against the wrong pid), this in_use count would never return to
      # 0 and the assertion below would time out against a permanently-exhausted
      # cap of 1.
      assert wait_until(fn -> match?({:ok, _}, InvocationLease.try_acquire(server)) end, 2_000),
             "expected try_acquire/1 to succeed once the dead holder's lease was " <>
               "automatically released, but the cap stayed exhausted"
    end

    test "an explicit release/2 immediately followed by that same process exiting does not double-decrement in_use" do
      server = start_lease(1)

      test_pid = self()

      holder_pid =
        spawn(fn ->
          {:ok, lease} = InvocationLease.try_acquire(server)
          :ok = InvocationLease.release(lease, server)
          send(test_pid, :released)
        end)

      assert_receive :released, 1_000
      # Give the holder process a moment to actually terminate (normal return),
      # racing its own :DOWN against the explicit release/2 call above -- the
      # demonitor+flush in release/2's own implementation (design doc §5.3) is
      # what must close this race.
      ref = Process.monitor(holder_pid)
      assert_receive {:DOWN, ^ref, :process, ^holder_pid, _reason}, 1_000

      # If the race were open (no demonitor+flush), the stale :DOWN would arrive
      # at InvocationLease AFTER the explicit release already freed the slot,
      # double-decrementing in_use to -1 and permanently OVER-admitting (cap
      # effectively becomes cap + 1) -- acquire twice more than the cap allows
      # to positively demonstrate in_use did not go negative.
      assert {:ok, lease_a} = InvocationLease.try_acquire(server)
      assert {:error, :capacity} = InvocationLease.try_acquire(server)
      assert :ok = InvocationLease.release(lease_a, server)
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end
end
