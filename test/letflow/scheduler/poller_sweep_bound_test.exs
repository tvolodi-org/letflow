defmodule Letflow.Scheduler.PollerSweepBoundTest do
  @moduledoc "T-3055: sweeps never take the whole global admission budget."
  use ExUnit.Case, async: false

  alias Letflow.Scheduler.Poller

  test "no call site passes global_cap() as a sweep concurrency" do
    src = File.read!("lib/letflow/scheduler/poller.ex")
    refute src =~ ~r/run_sweep\([^\n]*global_cap\(\)/
    assert length(Regex.scan(~r/run_sweep\(schemas, :\w+, sweep_concurrency\(\)/, src)) >= 10
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

  test "the bound is read from config" do
    prev = Application.get_env(:letflow, Poller)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:letflow, Poller, prev),
        else: Application.delete_env(:letflow, Poller)
    end)

    Application.put_env(:letflow, Poller, sweep_concurrency: 1)
    assert Poller.sweep_concurrency() == 1
  end
end
