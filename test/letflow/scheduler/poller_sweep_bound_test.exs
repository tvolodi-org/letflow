defmodule Letflow.Scheduler.PollerSweepBoundTest do
  @moduledoc "T-3055: sweeps never take the whole global admission budget."
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Letflow.Admission
  alias Letflow.AdmissionTestHelpers
  alias Letflow.Scheduler.Poller

  test "every run_sweep call site passes sweep_concurrency(), none global_cap()" do
    src = File.read!("lib/letflow/scheduler/poller.ex")

    # Every call-site argument list, newlines included, up to the fun argument.
    sites =
      Regex.scan(~r/(?<!defp |@spec )run_sweep\(\s*[^,]+,\s*[^,]+,\s*([^,]+),/, src,
        capture: :all_but_first
      )

    assert sites != []
    assert length(sites) == length(Regex.scan(~r/(?<!defp |@spec )run_sweep\(\s*schemas\b/, src))

    for [bound] <- sites do
      assert String.trim(bound) == "sweep_concurrency()"
    end

    refute src =~ ~r/run_sweep\([^)]*global_cap\(\)/s
  end

  test "default bound leaves at least `reserve` units free" do
    for cap <- [2, 3, 4, 8, 16, 28, 100] do
      bound = Poller.sweep_concurrency(cap, nil)
      assert bound >= 1
      assert cap - bound >= max(1, div(cap, 2))
    end

    assert Poller.sweep_concurrency(1, nil) == 1
    assert Poller.sweep_concurrency(28, nil) == 4
  end

  test "a configured value is used but clamped below the cap" do
    assert Poller.sweep_concurrency(28, 2) == 2
    assert Poller.sweep_concurrency(28, 28) == 14
    assert Poller.sweep_concurrency(28, 0) == 4
  end

  describe "config" do
    setup do
      prev = Application.get_env(:letflow, Poller)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:letflow, Poller, prev),
          else: Application.delete_env(:letflow, Poller)
      end)
    end

    test "the bound is read from config" do
      Application.put_env(:letflow, Poller, sweep_concurrency: 1)
      assert Poller.sweep_concurrency() == 1
    end

    test "a malformed app env falls back to the default instead of raising" do
      Application.put_env(:letflow, Poller, 5)
      assert Poller.sweep_concurrency() >= 1
    end

    test "init/1 logs the configured bound at boot" do
      Application.put_env(:letflow, Poller, sweep_concurrency: 1)
      prev_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      log =
        capture_log([level: :info], fn ->
          {:ok, _} = Poller.init(%{})
        end)

      assert log =~ "scheduler sweep concurrency bound"
      assert log =~ "sweep_concurrency=1"
    end
  end

  test "with sweeps holding their bound, `reserve` global units stay free for users" do
    AdmissionTestHelpers.restart_admission!(pool_size: 30, reserved_headroom: 2)
    bound = Poller.sweep_concurrency()
    %{cap: cap} = Admission.usage()
    assert cap == 28
    assert bound == 4

    # A sweep task holds one global unit per concurrently running tenant.
    refs =
      for _ <- 1..bound do
        assert {:ok, ref} = Admission.try_acquire(:global)
        ref
      end

    %{in_use: in_use, cap: cap} = Admission.usage()
    assert in_use == bound
    assert cap - in_use >= max(1, div(cap, 2))

    # A user request still gets a unit.
    assert {:ok, user_ref} = Admission.try_acquire(:global)
    Admission.release(user_ref)
    Enum.each(refs, &Admission.release/1)
  end
end
