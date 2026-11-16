defmodule Letflow.Modules.Stock.StockSheetSourceTest do
  @moduledoc """
  T-1925 (audit slice 9), design tests S1..S6: the pure fold of ledger entries into the Z-7 sheet
  rows (opening, income, expense, closing per item and unit), the 25-page bound, and the sheet's
  header facts. No database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Stock.StockCardSource
  alias Letflow.Modules.Stock.StockSheetSource

  @loc "loc-1"
  @start ~U[2026-11-01 00:00:00.000000Z]
  @stop ~U[2026-11-08 00:00:00.000000Z]

  defp leg(sku, qty, opts \\ []) do
    %{
      k: [
        sku,
        Keyword.get(opts, :loc, @loc),
        Keyword.get(opts, :ou, "ou1"),
        Keyword.get(opts, :resp, "p1"),
        Keyword.get(opts, :lot, "")
      ],
      quantity: qty,
      unit_ref: Keyword.get(opts, :unit, "u1"),
      masked: Keyword.get(opts, :masked, false)
    }
  end

  defp entry(time, legs), do: %{event_time: time, legs: legs}

  defp row(rows, sku, unit \\ "u1"), do: Enum.find(rows, &(&1.sku == sku and &1.unit_ref == unit))

  test "S1 the day boundaries: opening, income, expense, and the instant `end` is ignored" do
    rows =
      StockSheetSource.fold(
        [
          entry(DateTime.add(@start, -1, :microsecond), [leg("a", "2.000000000")]),
          entry(@start, [leg("a", "3.000000000")]),
          entry(DateTime.add(@stop, -1, :microsecond), [leg("a", "-1.000000000")]),
          entry(@stop, [leg("a", "9.000000000")])
        ],
        @loc,
        @start,
        @stop
      )

    assert [r] = rows
    assert Decimal.eq?(r.opening, 2)
    assert Decimal.eq?(r.income, 3)
    assert Decimal.eq?(r.expense, 1)
    assert Decimal.eq?(r.closing, 4)
  end

  test "S2 lots are summed, units give two rows, another location is skipped" do
    t = DateTime.add(@start, 3600, :second)

    rows =
      StockSheetSource.fold(
        [
          entry(t, [
            leg("a", "1.000000000", lot: "l1"),
            leg("a", "2.000000000", lot: "l2"),
            leg("a", "5.000000000", unit: "u2"),
            leg("a", "7.000000000", loc: "other")
          ])
        ],
        @loc,
        @start,
        @stop
      )

    assert length(rows) == 2
    assert Decimal.eq?(row(rows, "a").income, 3)
    assert Decimal.eq?(row(rows, "a", "u2").income, 5)
  end

  test "S3 empty groups are dropped, an opening-only item is kept" do
    t = DateTime.add(@start, 3600, :second)

    rows =
      StockSheetSource.fold(
        [
          entry(DateTime.add(@start, -7200, :second), [
            leg("gone", "4.000000000"),
            leg("kept", "6.000000000")
          ]),
          entry(DateTime.add(@start, -3600, :second), [leg("gone", "-4.000000000")]),
          entry(DateTime.add(@stop, 3600, :second), [leg("later", "1.000000000")]),
          entry(t, [leg("zero", "0.000000000")])
        ],
        @loc,
        @start,
        @stop
      )

    assert Enum.map(rows, & &1.sku) == ["kept"]
    [r] = rows
    assert Decimal.eq?(r.opening, 6) and Decimal.eq?(r.income, 0) and Decimal.eq?(r.closing, 6)
  end

  test "S4 a move inside the location is income and expense, closing unchanged" do
    t = DateTime.add(@start, 3600, :second)

    [r] =
      StockSheetSource.fold(
        [entry(t, [leg("a", "-1.000000000", ou: "ou1"), leg("a", "1.000000000", ou: "ou2")])],
        @loc,
        @start,
        @stop
      )

    assert Decimal.eq?(r.income, 1) and Decimal.eq?(r.expense, 1) and Decimal.eq?(r.closing, 0)
    assert r.org_units == MapSet.new(["ou1", "ou2"])
    assert r.responsibles == MapSet.new(["p1"])
  end

  test "S5 masked legs, short keys and unreadable times are skipped without a crash" do
    t = DateTime.add(@start, 3600, :second)

    assert [] =
             StockSheetSource.fold(
               [
                 entry(t, [
                   leg("a", "1.000000000", masked: true),
                   %{k: ["a"], quantity: "1", unit_ref: "u1", masked: false},
                   %{k: nil, quantity: "1", unit_ref: "u1", masked: false}
                 ]),
                 entry(nil, [leg("a", "1.000000000")])
               ],
               @loc,
               @start,
               @stop
             )
  end

  test "S6 the page bound: 25 pages are read, a 26th is card_too_long (and 5 by default)" do
    page = fn cursor ->
      n = cursor || 0
      {:ok, %{rows: [%{posting_seq: n + 1}], next_cursor: if(n < 24, do: n + 1)}}
    end

    assert {:ok, rows} = StockCardSource.collect(page, 25)
    assert length(rows) == 25
    assert {:error, :card_too_long} = StockCardSource.collect(page)

    endless = fn cursor -> {:ok, %{rows: [], next_cursor: (cursor || 0) + 1}} end
    assert {:error, :card_too_long} = StockCardSource.collect(endless, 25)
  end
end
