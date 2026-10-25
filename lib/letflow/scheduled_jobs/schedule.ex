defmodule Letflow.ScheduledJobs.Schedule do
  @moduledoc """
  REQ-561 / GH #3194 -- the slot arithmetic of a tenant scheduled job, with no database.

  A job has an `anchor` (a UTC `DateTime`) and an `interval_minutes`; slot `k` is
  `anchor + k * interval_minutes * 60 s`. `next_run_at` is always a slot.

    * `first_slot_not_before/3` is where a new, re-enabled or re-timed job starts: the anchor
      itself when `t` is not after it, otherwise the first slot at or after `t`.
    * `due_plan/2` answers "this job is due at `now`": the latest slot not after `now` is the ONE
      slot that runs, the slots between the stored `next_run_at` and it are counted as skipped
      (never replayed), and `next` is the first slot after `now`.
  """

  @min_interval 5
  @max_interval 10_080

  @type plan :: %{slot: DateTime.t(), skipped: non_neg_integer(), next: DateTime.t()}

  @doc "Smallest allowed interval, in minutes."
  @spec min_interval() :: pos_integer()
  def min_interval, do: @min_interval

  @doc "Largest allowed interval, in minutes (one week)."
  @spec max_interval() :: pos_integer()
  def max_interval, do: @max_interval

  @doc "The first slot at or after `t` (the anchor itself when `t` is not after it)."
  @spec first_slot_not_before(DateTime.t(), pos_integer(), DateTime.t()) :: DateTime.t()
  def first_slot_not_before(%DateTime{} = anchor, interval_minutes, %DateTime{} = t) do
    step = step_seconds(interval_minutes)
    diff = DateTime.diff(t, anchor, :microsecond)

    if diff <= 0 do
      anchor
    else
      step_us = step * 1_000_000
      DateTime.add(anchor, div(diff + step_us - 1, step_us) * step, :second)
    end
  end

  @doc """
  The run plan for a job whose stored `next_run_at` is not after `now`. Returns `:not_due`
  when it is after `now`.
  """
  @spec due_plan(
          %{anchor_at: DateTime.t(), interval_minutes: pos_integer(), next_run_at: DateTime.t()},
          DateTime.t()
        ) :: {:ok, plan()} | :not_due
  def due_plan(%{anchor_at: anchor, interval_minutes: interval, next_run_at: next_run_at}, now) do
    if DateTime.compare(next_run_at, now) == :gt do
      :not_due
    else
      step = step_seconds(interval)
      step_us = step * 1_000_000
      k_due = div(DateTime.diff(now, anchor, :microsecond), step_us)
      k_stored = div(DateTime.diff(next_run_at, anchor, :microsecond), step_us)
      slot = DateTime.add(anchor, k_due * step, :second)

      {:ok,
       %{
         slot: slot,
         skipped: max(k_due - k_stored, 0),
         next: DateTime.add(slot, step, :second)
       }}
    end
  end

  defp step_seconds(interval_minutes), do: interval_minutes * 60
end
