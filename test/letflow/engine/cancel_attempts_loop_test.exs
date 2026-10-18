defmodule Letflow.Engine.CancelAttemptsLoopTest do
  @moduledoc """
  GH #2706 / PR-1 (TDV F1): the caps of `Letflow.Engine.run_cancel_attempts/5`, the retry loop of
  `cancel_instance/3`, without a database and without sleeps: the attempt is a closure that counts
  its calls. The real-holder cap test needs the PR-2 lock timeout and its test override.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Letflow.Engine

  @instance "11111111-2222-3333-4444-555555555555"

  defp counting(results) do
    counter = :counters.new(1, [])
    {:ok, agent} = Agent.start_link(fn -> results end)

    attempt = fn ->
      :counters.add(counter, 1, 1)

      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)
    end

    {attempt, fn -> :counters.get(counter, 1) end}
  end

  defp now, do: System.monotonic_time(:millisecond)

  test "always held by another: exactly 3 attempts, then :cancel_contention" do
    {attempt, calls} = counting([:held_by_other])

    log =
      capture_log(fn ->
        assert Engine.run_cancel_attempts(attempt, 1, now(), true, @instance) ==
                 {:error, :cancel_contention}
      end)

    assert calls.() == 3
    assert log =~ "instance_id=#{@instance}"
    assert log =~ "attempt 3"
  end

  test "nested (no retry allowed): one attempt, the typed error at once" do
    {attempt, calls} = counting([:held_by_other])

    capture_log(fn ->
      assert Engine.run_cancel_attempts(attempt, 1, now(), false, @instance) ==
               {:error, :cancel_contention}
    end)

    assert calls.() == 1
  end

  test "the time cap: a first attempt older than one contention timeout is not retried" do
    {attempt, calls} = counting([:held_by_other])
    old = now() - (Letflow.Engine.Contention.lock_timeout_ms() + 1_000)

    capture_log(fn ->
      assert Engine.run_cancel_attempts(attempt, 1, old, true, @instance) ==
               {:error, :cancel_contention}
    end)

    assert calls.() == 1
  end

  test "a success on the second attempt stops the loop" do
    {attempt, calls} = counting([:held_by_other, {:final, {:ok, :cancelled}}])

    assert Engine.run_cancel_attempts(attempt, 1, now(), true, @instance) == {:ok, :cancelled}
    assert calls.() == 2
  end

  test "a final error is returned as is, never retried" do
    {attempt, calls} = counting([{:final, {:error, {:instance_already_terminal, :cancelled}}}])

    assert Engine.run_cancel_attempts(attempt, 1, now(), true, @instance) ==
             {:error, {:instance_already_terminal, :cancelled}}

    assert calls.() == 1
  end
end
