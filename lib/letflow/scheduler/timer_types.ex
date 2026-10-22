defmodule Letflow.Scheduler.TimerTypes do
  @moduledoc """
  The single definition of the `timers.timer_type` values (GH #2555).

  `timer_type` stays a plain string column (see `Letflow.Scheduler.Timer`), so the
  values are defined here once as macros: a macro expands to the literal at compile
  time and therefore works in function-head patterns, `case` clauses and Ecto
  queries alike. `require Letflow.Scheduler.TimerTypes` and call e.g.
  `TimerTypes.reminder()`; never write the raw string outside this module. A check
  test (`timer_types_test.exs`) fails when a raw timer-type literal reappears in `lib/`.
  """

  defmacro deadline, do: "deadline"
  defmacro reminder, do: "reminder"
  defmacro escalation, do: "escalation"
  defmacro scheduled_transition, do: "scheduled_transition"

  @all ["deadline", "reminder", "escalation", "scheduled_transition"]

  @doc "All allowed timer types, for `validate_inclusion/3`."
  @spec all() :: [String.t()]
  def all, do: @all
end
