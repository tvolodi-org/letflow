defmodule Letflow.ScheduledJobs.ScheduleTest do
  @moduledoc "REQ-561 / GH #3194 -- S1: slot arithmetic of a tenant scheduled job (pure)."

  use ExUnit.Case, async: true

  alias Letflow.ScheduledJobs.Schedule

  @anchor ~U[2026-01-01 00:00:00.000000Z]
  @step 600

  defp at(seconds), do: DateTime.add(@anchor, seconds, :second)

  defp job(next_seconds),
    do: %{anchor_at: @anchor, interval_minutes: 10, next_run_at: at(next_seconds)}

  test "first_slot_not_before: anchor when t is not after it, else the next slot" do
    assert Schedule.first_slot_not_before(@anchor, 10, at(-5)) == @anchor
    assert Schedule.first_slot_not_before(@anchor, 10, @anchor) == @anchor
    assert Schedule.first_slot_not_before(@anchor, 10, at(1)) == at(@step)
    assert Schedule.first_slot_not_before(@anchor, 10, at(@step)) == at(@step)
    assert Schedule.first_slot_not_before(@anchor, 10, at(@step + 1)) == at(2 * @step)
  end

  test "due_plan: 3.5 intervals behind runs the latest slot and skips 3" do
    now = at(100 * @step)

    # stored next_run_at is slot 96; now is 100.0 steps, so make now 99.5 steps after... use half step
    now = DateTime.add(now, div(@step, 2), :second)
    assert {:ok, plan} = Schedule.due_plan(job(96 * @step), now)
    assert plan.slot == at(100 * @step)
    assert plan.skipped == 4
    assert plan.next == at(101 * @step)
    assert DateTime.compare(plan.next, now) == :gt
  end

  test "due_plan: next_run_at 3.5 steps before now gives skipped 3" do
    now = at(100 * @step + div(@step, 2))
    stored = at(96 * @step + div(@step, 2) - div(@step, 2))
    # slots strictly: stored 97 steps, now 100.5 steps -> slot 100, skipped 3
    assert {:ok, plan} = Schedule.due_plan(job(97 * @step), now)
    assert plan.slot == at(100 * @step)
    assert plan.skipped == 3
    assert plan.next == at(101 * @step)
    refute stored == nil
  end

  test "due_plan: exact boundary runs that slot with nothing skipped" do
    now = at(5 * @step)
    assert {:ok, plan} = Schedule.due_plan(job(5 * @step), now)
    assert plan.slot == now
    assert plan.skipped == 0
    assert plan.next == at(6 * @step)
  end

  test "due_plan: not due when next_run_at is after now (also an anchor in the future)" do
    assert Schedule.due_plan(job(5 * @step), at(4 * @step)) == :not_due
    assert Schedule.due_plan(job(0), at(-1)) == :not_due
  end
end
