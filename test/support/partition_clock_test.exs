defmodule Letflow.Test.PartitionClockTest do
  @moduledoc """
  ISS-0937 regression tests for `Letflow.Test.PartitionClock`.

  The retention tests pick a month partition that
  `Letflow.EventStore.PartitionMaintenance` must consider eligible for
  retirement. Production rule (`lib/letflow/event_store/partition_maintenance.ex`):
  month `M` is eligible iff `today >= first_day_of_next_month(M) + N` days,
  `N` = `min_partition_age_days`. The old fixture, "last calendar month with
  N = 1", is ineligible on the 1st of every month, which broke CI at the
  2026-09-30 / 2026-10-01 UTC rollover.

  Everything here is pure date arithmetic over an INJECTED `today`: no
  `Date.utc_today/0`, no database, so the result is identical on every real
  date. The oracle below re-implements the production rule independently of
  `PartitionClock` (DIRECTIVE T-4) and shares none of its code.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Test.PartitionClock

  @ages [1, 2, 7, 31, 400]

  # Test-file-relative paths to the three DB-backed retention test files whose
  # fixtures must go through PartitionClock.
  @retention_test_files [
    "../letflow/event_store/partition_maintenance_test.exs",
    "../letflow/event_store/retention_operations_test.exs",
    "../letflow/routers/event_retention_test.exs"
  ]

  # ---- independent oracle ---------------------------------------------------

  defp first_day_of_next_month({year, month}) do
    {year, month, 1} |> Date.from_erl!() |> Date.end_of_month() |> Date.add(1)
  end

  # Mirrors the production rule: today >= first_day_of_next_month + N.
  defp eligible?(month, today, n) do
    Date.compare(today, Date.add(first_day_of_next_month(month), n)) != :lt
  end

  defp next_month({year, month}) do
    d = first_day_of_next_month({year, month})
    {d.year, d.month}
  end

  defp previous_month({year, month}) do
    d = {year, month, 1} |> Date.from_erl!() |> Date.add(-1)
    {d.year, d.month}
  end

  defp days(from, to), do: Date.range(from, to)

  # ---- tests ------------------------------------------------------------------

  test "eligible_past_month/2 is eligible for every day of 2024-01-01..2027-12-31 and every N" do
    for today <- days(~D[2024-01-01], ~D[2027-12-31]), n <- @ages do
      month = PartitionClock.eligible_past_month(today, n)

      assert eligible?(month, today, n),
             "month #{inspect(month)} is NOT eligible on #{today} with N=#{n}"
    end
  end

  test "eligible_past_month/2 is the latest eligible month (the next month is not eligible)" do
    for today <- days(~D[2024-01-01], ~D[2027-12-31]), n <- @ages do
      month = PartitionClock.eligible_past_month(today, n)

      refute eligible?(next_month(month), today, n),
             "month #{inspect(next_month(month))} is also eligible on #{today} with N=#{n}, " <>
               "so #{inspect(month)} is over-conservative"
    end
  end

  test "regression: legacy derivation (last calendar month, N=1) is ineligible on the 1st of every month" do
    # 24 months, every 1st and 2nd included.
    for today <- days(~D[2026-01-01], ~D[2027-12-31]) do
      legacy_month = previous_month({today.year, today.month})

      if today.day == 1 do
        refute eligible?(legacy_month, today, 1),
               "legacy month #{inspect(legacy_month)} unexpectedly eligible on #{today}"
      else
        assert eligible?(legacy_month, today, 1),
               "legacy month #{inspect(legacy_month)} unexpectedly ineligible on #{today}"
      end

      # The fixed helper must be eligible on exactly the days the legacy one is not.
      assert eligible?(PartitionClock.eligible_past_month(today, 1), today, 1)
    end
  end

  test "explicit boundary dates" do
    cases = [
      {~D[2026-10-01], 1, {2026, 8}},
      {~D[2026-10-02], 1, {2026, 9}},
      {~D[2026-10-31], 1, {2026, 9}},
      {~D[2027-01-01], 1, {2026, 11}},
      {~D[2028-03-01], 1, {2028, 1}}
    ]

    for {today, n, expected} <- cases do
      assert PartitionClock.eligible_past_month(today, n) == expected,
             "eligible_past_month(#{today}, #{n}) != #{inspect(expected)}"
    end
  end

  test "shift_months/2 crosses year boundaries in both directions" do
    assert PartitionClock.shift_months({2026, 1}, -1) == {2025, 12}
    assert PartitionClock.shift_months({2026, 12}, 1) == {2027, 1}
    assert PartitionClock.shift_months({2026, 3}, -15) == {2024, 12}
    assert PartitionClock.shift_months({2026, 3}, 0) == {2026, 3}
  end

  test "retention test files do not use the legacy last-month derivation" do
    for relative <- @retention_test_files do
      source = File.read!(Path.expand(relative, __DIR__))

      assert source =~ "PartitionClock.eligible_past_month(",
             "#{relative} does not derive its eligible month via PartitionClock"

      refute source =~ "shift_months(current_month(), -1)",
             "#{relative} still uses the legacy `shift_months(current_month(), -1)` derivation"

      refute source =~ "shift_months({today.year, today.month}, -1)",
             "#{relative} still uses the legacy `shift_months({today.year, today.month}, -1)` derivation"

      refute source =~ "[min_partition_age_days: 1",
             "#{relative} hard-codes the override age instead of the shared @override_age_days"
    end
  end
end
