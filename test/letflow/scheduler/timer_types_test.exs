defmodule Letflow.Scheduler.TimerTypesTest do
  use ExUnit.Case, async: true

  alias Letflow.Scheduler.TimerTypes

  require Letflow.Scheduler.TimerTypes

  @definition "lib/letflow/scheduler/timer_types.ex"

  test "all/0 lists the four types the macros expand to" do
    assert Enum.sort(TimerTypes.all()) ==
             Enum.sort([
               TimerTypes.deadline(),
               TimerTypes.reminder(),
               TimerTypes.escalation(),
               TimerTypes.scheduled_transition()
             ])
  end

  test "no raw timer-type literal appears in lib/ outside the definition (GH #2555)" do
    types = Enum.map(TimerTypes.all(), &Regex.escape/1) |> Enum.join("|")
    # `timer_type: "x"`, `timer_type == "x"`, or a bare `"x" ->` case clause
    # near a timer_type match; the bare-clause form is covered by the second pattern.
    patterns = [
      ~r/timer_type\s*(:|==|!=)\s*"(#{types})"/,
      ~r/^\s*"(#{types})"\s*->/
    ]

    offenders =
      for file <- Path.wildcard("lib/**/*.ex"),
          file != @definition,
          {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim(line), "#"),
          Enum.any?(patterns, &Regex.match?(&1, line)),
          do: "#{file}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "raw timer-type literals; use Letflow.Scheduler.TimerTypes:\n" <>
             Enum.join(offenders, "\n")
  end
end
