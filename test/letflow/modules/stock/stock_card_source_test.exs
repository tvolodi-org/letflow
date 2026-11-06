defmodule Letflow.Modules.Stock.StockCardSourceTest do
  @moduledoc """
  T-1417 (E5c), design tests T-Z3-1 and T-Z3-6: the pure fold of ledger entries into card lines,
  the paging bound (with a fake page function), and the Z-3 data map.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Stock.FormZ3
  alias Letflow.Modules.Stock.StockCardSource

  @sku "sku-1"
  @loc "loc-1"

  defp leg(q, opts \\ []) do
    %{
      leg_no: 1,
      k:
        [
          Keyword.get(opts, :sku, @sku),
          Keyword.get(opts, :loc, @loc),
          "ou-1",
          "",
          Keyword.get(opts, :lot, "")
        ] ++ ["", "", ""],
      quantity: q,
      unit_ref: Keyword.get(opts, :unit, "pcs"),
      document_line_id: nil
    }
  end

  defp entry(seq, legs),
    do: %{
      posting_seq: seq,
      event_time: ~U[2026-11-05 10:00:00Z],
      document_id: "d-#{seq}",
      legs: legs
    }

  test "T-Z3-1 signed legs give income, expense and a running balance; a reversal is a line too" do
    entries = [
      entry(1, [leg("10.000000000")]),
      entry(2, [leg("-3.000000000")]),
      entry(3, [leg("3.000000000")])
    ]

    lines = StockCardSource.fold(entries, @sku, @loc, nil)

    assert Enum.map(lines, &Decimal.to_string(&1.balance, :normal)) == [
             "10.000000000",
             "7.000000000",
             "10.000000000"
           ]

    assert [%{expense: nil}, %{income: nil, expense: exp}, %{expense: nil}] = lines
    assert Decimal.equal?(exp, 3)
  end

  test "T-Z3-1 masked legs, other items, other places and other lots are skipped; balance per unit" do
    entries = [
      entry(1, [
        leg("5", lot: "lot-a"),
        %{leg_no: 2, quantity: "100", unit_ref: "pcs", masked: true},
        leg("7", sku: "other"),
        leg("9", loc: "other"),
        leg("2", unit: "kg")
      ]),
      entry(2, [leg("1", lot: "lot-b")])
    ]

    assert [_, _, _] = StockCardSource.fold(entries, @sku, @loc, nil)
    assert [one] = StockCardSource.fold(entries, @sku, @loc, "lot-b")
    assert Decimal.equal?(one.balance, 1)

    by_unit =
      StockCardSource.fold(entries, @sku, @loc, nil) |> Map.new(&{&1.unit_ref, &1.balance})

    assert Decimal.equal?(by_unit["kg"], 2) and Decimal.equal?(by_unit["pcs"], 6)
  end

  test "T-Z3-6 more than five pages is card_too_long; five full pages are read" do
    page = fn cursor ->
      n = cursor || 0
      {:ok, %{rows: [%{posting_seq: n + 1}], next_cursor: n + 1}}
    end

    assert {:error, :card_too_long} = StockCardSource.collect(page)

    last = fn cursor ->
      n = cursor || 0
      {:ok, %{rows: [%{posting_seq: n + 1}], next_cursor: if(n < 4, do: n + 1)}}
    end

    assert {:ok, rows} = StockCardSource.collect(last)
    assert Enum.map(rows, & &1.posting_seq) == [1, 2, 3, 4, 5]

    assert {:error, :invalid_filter} =
             StockCardSource.collect(fn _ -> {:error, :invalid_filter} end)
  end

  test "the Z-3 data map leaves unknown cells out and builds in both languages" do
    card = %{
      header: %{
        org_name: "ТОО",
        org_bin: "1",
        struct_unit: "Склад",
        item_name: "Болт",
        nom: "B-1",
        unit: "шт",
        mark: nil,
        shelf: "2027-01-31"
      },
      rows: [
        %{
          event_time: "2026-11-05T16:00:00+06:00",
          document_number: "RCP-2026-000001",
          no: 1,
          income: Decimal.new("2.000000000"),
          expense: nil,
          balance: Decimal.new("2.000000000")
        }
      ]
    }

    d = FormZ3.data(card)
    assert d["shelf"] == "31.01.2027" and d["mark"] == ""

    assert [%{"date" => "05.11.2026", "income" => "2.000000000", "expense" => "", "party" => nil}] =
             Enum.map(d["rows"], &Map.merge(%{"party" => nil}, &1))

    refute Enum.any?(d["rows"], &Map.has_key?(&1, "party"))

    for lang <- ["ru", "kk"],
        fmt <- [:pdf, :docx],
        do: assert({:ok, _} = FormPrint.build("z3", d, lang, fmt))
  end
end
