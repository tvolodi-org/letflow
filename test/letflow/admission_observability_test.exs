defmodule Letflow.AdmissionObservabilityTest do
  @moduledoc """
  T-3034: the observability counters of `Letflow.Admission` and the rendering of
  `Letflow.Admission.Observability`.

  Every test starts its own isolated admission instance under a unique `:name`
  (the convention of `test/letflow/admission_test.exs`), so the file runs
  `async: true` and touches no shared state — except the rate limiter of the
  refusal line, which is node-wide by design; that one is reset explicitly.

  What is proved here:

    * the counters report the budget that is ACTUALLY applied (pool_size,
      reserved_headroom, cap), the fair-share divisor and the refusals since
      the process started, split by kind;
    * the per-tenant rows carry the route CLASS of the in-flight admissions
      and their age, and the tenant name is HASHED on the way out;
    * the leak guard: an admission whose holder process dies is released
      through the monitor `:DOWN` path instead of leaking a global slot;
    * the stale sweep logs an over-age admission ONCE with its route class —
      and does NOT release it (the admission contract forbids revoking a held
      admission);
    * the refusal line is rate limited to one per second and carries no token,
      no body, no path and no raw tenant name.
  """

  use ExUnit.Case, async: true

  alias Letflow.Admission
  alias Letflow.Admission.Observability
  alias Letflow.Test.LoggerCollector

  @class "/api/v1/instances"

  defp start_admission(opts) do
    n = System.unique_integer([:positive])
    name = Module.concat(__MODULE__, "Server#{n}")

    {:ok, pid} =
      start_supervised(%{
        id: {Admission, n},
        start: {Admission, :start_link, [Keyword.put(opts, :name, name)]}
      })

    {pid, name}
  end

  # Bounded poll with a deadline: no fixed sleep, and it fails loudly on a
  # timeout instead of hanging the suite.
  defp wait_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end

  describe "counters/1: the budget that is actually applied" do
    test "reports pool_size, reserved_headroom and the cap derived from them" do
      {_pid, name} = start_admission(pool_size: 9, reserved_headroom: 2)

      counters = Admission.counters(name)

      assert counters.pool_size == 9
      assert counters.reserved_headroom == 2
      assert counters.cap == 7
      assert counters.in_use == 0
    end

    test "the fair-share divisor is the number of tracked tenants" do
      {_pid, name} = start_admission(pool_size: 9, reserved_headroom: 2)

      assert Admission.counters(name).tracked_tenants == 0

      {:ok, ref} = Admission.try_acquire({:tenant, "tenant_a"}, name)
      assert Admission.counters(name).tracked_tenants == 1

      {:ok, ref2} = Admission.try_acquire({:tenant, "tenant_b"}, name)
      assert Admission.counters(name).tracked_tenants == 2

      Admission.release(ref)
      Admission.release(ref2)
    end

    test "the refusals since the process started are counted per kind" do
      {_pid, name} = start_admission(pool_size: 1, reserved_headroom: 0)

      {:ok, held} = Admission.try_acquire(:global, name)

      assert {:error, :capacity} = Admission.try_acquire(:global, name)
      assert {:error, :capacity} = Admission.try_acquire({:tenant, "tenant_a"}, name)

      counters = Admission.counters(name)
      assert counters.rejections.global == 1
      assert counters.rejections.tenant == 1

      Admission.release(held)
    end
  end

  describe "counters/1: the in-flight rows" do
    test "carry the route class and the age of every in-flight admission" do
      {_pid, name} = start_admission(pool_size: 9, reserved_headroom: 2)

      {:ok, ref} = Admission.try_acquire({:tenant, "tenant_a"}, name, class: @class)
      {:ok, ref2} = Admission.try_acquire({:tenant, "tenant_a"}, name, class: "/api/v1/tasks")

      counters = Admission.counters(name)
      assert counters.in_use == 2

      assert [row] = counters.tenants
      assert row.tenant == "tenant_a"
      assert row.in_use == 2
      assert row.oldest_ms >= 0
      assert Enum.sort(row.routes) == [{"/api/v1/instances", 1}, {"/api/v1/tasks", 1}]

      assert counters.oldest.tenant == "tenant_a"
      assert counters.oldest.route in ["/api/v1/instances", "/api/v1/tasks"]
      assert counters.oldest.age_ms >= 0

      Admission.release(ref)
      Admission.release(ref2)
    end

    test "an admission without a class is stored as unknown, never as a request path" do
      {_pid, name} = start_admission(pool_size: 9, reserved_headroom: 2)

      {:ok, ref} = Admission.try_acquire({:tenant, "tenant_a"}, name)

      assert [row] = Admission.counters(name).tenants
      assert row.routes == [{"unknown", 1}]

      Admission.release(ref)
    end

    test "at most five tenants are reported, the busiest first" do
      {_pid, name} = start_admission(pool_size: 100, reserved_headroom: 0)

      refs =
        for i <- 1..7 do
          for _ <- 1..i do
            {:ok, ref} = Admission.try_acquire({:tenant, "tenant_#{i}"}, name, class: @class)
            ref
          end
        end
        |> List.flatten()

      counters = Admission.counters(name)
      assert length(counters.tenants) == 5
      assert Enum.map(counters.tenants, & &1.in_use) == [7, 6, 5, 4, 3]

      assert Enum.map(counters.tenants, & &1.tenant) == [
               "tenant_7",
               "tenant_6",
               "tenant_5",
               "tenant_4",
               "tenant_3"
             ]

      Enum.each(refs, &Admission.release/1)
    end
  end

  describe "the leak guard: the monitor DOWN path" do
    test "an admission whose holder process dies is released, the budget does not leak" do
      {_pid, name} = start_admission(pool_size: 1, reserved_headroom: 0, monitor_callers: true)

      parent = self()

      holder =
        spawn(fn ->
          {:ok, _ref} = Admission.try_acquire(:global, name)
          send(parent, :acquired)
          # the holder dies WITHOUT releasing: the monitor :DOWN must do it
        end)

      assert_receive :acquired, 1_000
      ref = Process.monitor(holder)
      assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 1_000

      assert :ok = wait_until(fn -> Admission.counters(name).in_use == 0 end)
      assert Admission.counters(name).in_use == 0

      # the budget is whole again: a new admission succeeds
      assert {:ok, fresh} = Admission.try_acquire(:global, name)
      Admission.release(fresh)
    end

    test "without caller monitoring the same holder leaks the slot (the fault T-3034 closes)" do
      {_pid, name} = start_admission(pool_size: 1, reserved_headroom: 0, monitor_callers: false)

      parent = self()

      holder =
        spawn(fn ->
          {:ok, _ref} = Admission.try_acquire(:global, name)
          send(parent, :acquired)
        end)

      assert_receive :acquired, 1_000
      ref = Process.monitor(holder)
      assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 1_000

      # the slot stays taken: nothing released it
      assert Admission.counters(name).in_use == 1
      assert {:error, :capacity} = Admission.try_acquire(:global, name)
    end
  end

  describe "the stale in-flight sweep" do
    test "logs an over-age admission ONCE with its route class, and does not release it" do
      {_pid, name} =
        start_admission(
          pool_size: 9,
          reserved_headroom: 2,
          max_in_flight_age_ms: 20,
          stale_sweep_interval_ms: 10
        )

      {:ok, ref} = Admission.try_acquire({:tenant, "tenant_a"}, name, class: @class)

      collector = LoggerCollector.attach!()

      try do
        {:ok, entries} =
          LoggerCollector.await(
            collector,
            fn got ->
              Enum.any?(got, &String.contains?(&1.text, "admission_stale"))
            end,
            2_000
          )

        LoggerCollector.assert_alive!(collector)
        text = LoggerCollector.text(entries)
        assert text =~ "admission_stale"
        assert text =~ "route=/api/v1/instances"
        assert text =~ "age_ms="

        # the raw tenant schema name never reaches the line
        refute text =~ "tenant_a"

        # wait for a few more sweeps: the line is logged ONCE
        Process.sleep(150)
        {:timeout, more} = LoggerCollector.await(collector, fn _got -> false end, 50)
        text = LoggerCollector.text(more)
        assert length(Regex.scan(~r/admission_stale/, text)) == 0
      after
        LoggerCollector.detach(collector)
      end

      # the admission is STILL held: the sweep logs, it never revokes
      assert Admission.counters(name).in_use == 1
      Admission.release(ref)
    end

    test "a bound of 0 switches the sweep off entirely" do
      {_pid, name} =
        start_admission(
          pool_size: 9,
          reserved_headroom: 2,
          max_in_flight_age_ms: 0,
          stale_sweep_interval_ms: 10
        )

      {:ok, ref} = Admission.try_acquire({:tenant, "tenant_a"}, name, class: @class)

      collector = LoggerCollector.attach!()

      try do
        Process.sleep(150)
        refute LoggerCollector.text(LoggerCollector.collected(collector)) =~ "admission_stale"
      after
        LoggerCollector.detach(collector)
      end

      Admission.release(ref)
    end
  end

  describe "the tenant pseudonym" do
    test "is 16 hex characters, stable, and never the raw name" do
      hash = Observability.hash_tenant("tenant_abc")

      assert hash =~ ~r/\A[0-9a-f]{16}\z/
      assert hash == Observability.hash_tenant("tenant_abc")
      assert hash != Observability.hash_tenant("tenant_abd")
      refute hash =~ "tenant_abc"
    end

    test "a missing name is none" do
      assert Observability.hash_tenant(nil) == "none"
      assert Observability.hash_tenant("") == "none"
    end
  end

  describe "the refusal line" do
    setup do
      Observability.reset()
      on_exit(&Observability.reset/0)
      :ok
    end

    test "names the budget, the route class and the oldest holder, and no raw tenant name" do
      counters = %{
        tracked_tenants: 1,
        in_use: 7,
        cap: 7,
        reserved_headroom: 2,
        pool_size: 9,
        rejections: %{global: 1, tenant: 0},
        tenants: [%{tenant: "tenant_a", in_use: 1, oldest_ms: 120, routes: [{"x", 1}]}],
        oldest: %{tenant: "tenant_a", route: "/api/v1/instances", age_ms: 4_200}
      }

      {_result, entries} =
        LoggerCollector.capture(fn ->
          assert :ok =
                   Observability.log_rejection(
                     %{kind: :global, tenant: "tenant_a", route: "/api/v1/tenants"},
                     counters
                   )
        end)

      text = LoggerCollector.text(entries)

      assert text =~ "admission_rejected"
      assert text =~ "kind=global"
      assert text =~ "in_use=7"
      assert text =~ "cap=7"
      assert text =~ "route=/api/v1/tenants"
      assert text =~ "holder_route=/api/v1/instances"
      assert text =~ "holder_age_ms=4200"
      assert text =~ "tenant=" <> Observability.hash_tenant("tenant_a")
      refute text =~ "tenant_a"
    end

    test "is rate limited to one line per second; the withheld ones are counted" do
      counters = %{
        tracked_tenants: 0,
        in_use: 1,
        cap: 1,
        reserved_headroom: 0,
        pool_size: 1,
        rejections: %{global: 3, tenant: 0},
        tenants: [],
        oldest: nil
      }

      {_result, entries} =
        LoggerCollector.capture(fn ->
          for _ <- 1..5 do
            Observability.log_rejection(
              %{kind: :global, tenant: nil, route: "/api/v1/x"},
              counters
            )
          end
        end)

      text = LoggerCollector.text(entries)

      # one line for the five refusals of the same second
      assert length(Regex.scan(~r/admission_rejected/, text)) == 1

      # the four withheld ones are counted on the NEXT line (the same contract
      # as Letflow.Api.AuthzDenyLog's own sampling)
      Process.sleep(1_100)

      {_result, later} =
        LoggerCollector.capture(fn ->
          Observability.log_rejection(%{kind: :global, tenant: nil, route: "/api/v1/x"}, counters)
        end)

      assert LoggerCollector.text(later) =~ "suppressed=4"
    end
  end

  describe "the route class of a request" do
    test "is unmatched when no route was matched" do
      conn = Plug.Test.conn(:get, "/api/v1/whatever")

      assert Observability.route_class(conn) == "unmatched"
    end

    test "is the route pattern of the matched route, never the request path" do
      conn = Plug.Test.conn(:get, "/api/v1/instances/8f3e2a1b-0000-4000-8000-000000000001")

      conn =
        Plug.Conn.put_private(conn, :plug_route, {"/api/v1/instances/:id", fn _conn -> conn end})

      assert Observability.route_class(conn) == "/api/v1/instances/:id"
    end

    test "is unmatched for the catch-all of a router" do
      conn = Plug.Test.conn(:get, "/api/v1/whatever")

      conn = Plug.Conn.put_private(conn, :plug_route, {"/api/v1/*_path", fn _conn -> conn end})

      assert Observability.route_class(conn) == "unmatched"
    end
  end
end
