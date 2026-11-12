defmodule Letflow.Proof.MesP3.ImportTest do
  @moduledoc "MES PROOF P3 (T-1831), REMOVABLE: I1..I10 of the design. Committed test tenant, Sandbox auto, `async: false`."

  use Letflow.DataCase, async: false

  alias Letflow.LedgerFixture
  alias Letflow.Proof.MesP3.CsvImport
  alias Letflow.Proof.MesP3.Readings

  @hdr "equipment,kind,quantity,unit,measured_at,quality\n"
  @now ~U[2026-11-13 12:00:00Z]
  @ledger_tables ~w(ledger_entry ledger_leg ledger_counter ledger_balance)

  setup do
    LedgerFixture.setup_auto_mode!()
    schema = LedgerFixture.tenant!()
    Readings.ensure_table!(schema)
    {:ok, schema: schema}
  end

  defp ledger_counts(schema), do: Enum.map(@ledger_tables, &LedgerFixture.count(schema, &1))

  defp good_rows(n, tank \\ "TK-101") do
    for i <- 0..(n - 1) do
      h = div(i, 4)
      m = rem(i, 4) * 15
      "#{tank},level,#{1000 + i}.5,kg,2026-11-12T#{pad(h)}:#{pad(m)}:00Z,good\n"
    end
    |> Enum.join()
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp imp(schema, csv, opts \\ []),
    do: CsvImport.import(schema, csv, Keyword.put_new(opts, :now, @now))

  test "I1 a manual reading holds all its fields", %{schema: s} do
    r = %{
      equipment: "TK-101",
      kind: "level",
      quantity: Decimal.new("1234.5"),
      unit: "l",
      measured_at: ~U[2026-11-12 08:00:00Z],
      source: "manual",
      quality: "uncertain"
    }

    assert {:ok, :inserted} = Readings.insert(s, r)
    assert [row] = Readings.list(s)
    assert row.equipment == "TK-101" and row.kind == "level" and row.unit == "l"
    assert Decimal.equal?(row.quantity, "1234.5")

    assert row.source == "manual" and row.quality == "uncertain" and
             DateTime.compare(row.measured_at, r.measured_at) == :eq

    assert {:ok, :duplicate} = Readings.insert(s, r)
  end

  test "I2 the table refuses a bad unit, source or quality", %{schema: s} do
    base = %{
      equipment: "TK-1",
      kind: "level",
      quantity: Decimal.new(1),
      unit: "kg",
      measured_at: ~U[2026-11-12 08:00:00Z],
      source: "manual",
      quality: "good"
    }

    for bad <- [%{unit: "g"}, %{source: "live"}, %{quality: "x"}] do
      assert_raise Postgrex.Error, fn -> Readings.insert(s, Map.merge(base, bad)) end
    end

    assert Readings.count(s) == 0
  end

  test "I3 a valid file loads, source is file, one import id", %{schema: s} do
    assert {:ok, %{status: :loaded, loaded: 10, rejected: [], duplicates: 0}} =
             imp(s, @hdr <> good_rows(10))

    rows = Readings.list(s)
    assert length(rows) == 10
    assert Enum.all?(rows, &(&1.source == "file" and &1.quality == "good"))
    assert rows |> Enum.map(& &1.import_id) |> Enum.uniq() |> length() == 1
  end

  test "I3b BOM, CRLF and quoted fields are accepted" do
    csv =
      "﻿" <>
        "Equipment,Kind,Quantity,Unit,Measured_At,Quality\r\n\"TK-1\",flow_total,\"12.5\",l,2026-11-12T01:00:00+06:00,good\r\n"

    assert {:ok, %{rows: [row], rejected: []}} = CsvImport.parse(csv, now: @now)

    assert row.equipment == "TK-1"

    assert DateTime.to_unix(row.measured_at) == DateTime.to_unix(~U[2026-11-11 19:00:00Z])
  end

  test "I4 each bad row is rejected with its reason, good rows still load", %{schema: s} do
    csv =
      @hdr <>
        "TK-1,level,10,kg,2026-11-12T01:00:00Z,good\n" <>
        "TK-1,level,10,kg\n" <>
        ",level,10,kg,2026-11-12T02:00:00Z,good\n" <>
        "TK-1,volume,10,kg,2026-11-12T02:00:00Z,good\n" <>
        "TK-1,level,-5,kg,2026-11-12T02:00:00Z,good\n" <>
        "TK-1,level,1.2345,kg,2026-11-12T02:00:00Z,good\n" <>
        "TK-1,level,10,g,2026-11-12T02:00:00Z,good\n" <>
        "TK-1,level,10,kg,2026-11-12T02:00:00,good\n" <>
        "TK-1,level,10,kg,2026-11-20T02:00:00Z,good\n" <>
        "TK-1,level,10,kg,2026-11-12T02:00:00Z,great\n" <>
        "TK-1,level,\"1,5\",kg,2026-11-12T03:00:00Z,good\n" <>
        "TK-1,level,20,kg,2026-11-12T04:00:00Z,good\n"

    assert {:ok, %{loaded: 2, rejected: rej}} = imp(s, csv)

    assert Enum.map(rej, &{&1.line, &1.reason}) == [
             {3, :wrong_column_count},
             {4, :empty_equipment},
             {5, :bad_kind},
             {6, :bad_quantity},
             {7, :bad_quantity},
             {8, :bad_unit},
             {9, :bad_time},
             {10, :bad_time},
             {11, :bad_quality},
             {12, :bad_quantity}
           ]

    assert Enum.all?(rej, &(is_binary(&1.raw) and &1.raw != ""))
    assert Readings.count(s) == 2
  end

  test "I5 file-level refusals write nothing", %{schema: s} do
    too_many =
      @hdr <>
        String.duplicate("T,level,1,kg,2026-11-12T01:00:00Z,good\n", CsvImport.max_rows() + 1)

    cases = [
      {"", :empty_file},
      {"\n\n", :empty_file},
      {"a,b,c\n1,2,3\n", :bad_header},
      {"equipment,kind,quantity,unit,measured_at,quality,source\nT,level,1,kg,2026-11-12T01:00:00Z,good,live\n",
       :unexpected_column},
      {@hdr <> <<0xFF, 0xFE, ?\n>>, :not_utf8},
      {too_many, :too_large},
      {String.duplicate("x", 1_000_001), :too_large}
    ]

    for {csv, reason} <- cases, do: assert({:error, ^reason} = imp(s, csv))
    assert Readings.count(s) == 0 and Readings.import_count(s) == 0
  end

  test "I6 the same bytes twice: second import writes nothing", %{schema: s} do
    csv = @hdr <> good_rows(6)
    assert {:ok, %{status: :loaded, loaded: 6}} = imp(s, csv)
    assert {:ok, %{status: :already_imported, loaded: 0}} = imp(s, csv)
    assert Readings.count(s) == 6 and Readings.import_count(s) == 1
  end

  test "I7 overlap and reordered files load only new rows", %{schema: s} do
    assert {:ok, %{loaded: 6}} = imp(s, @hdr <> good_rows(6))
    assert {:ok, %{status: :loaded, loaded: 4, duplicates: 6}} = imp(s, @hdr <> good_rows(10))

    reordered =
      @hdr <>
        (good_rows(10) |> String.split("\n", trim: true) |> Enum.reverse() |> Enum.join("\n")) <>
        "\n"

    assert {:ok, %{status: :loaded, loaded: 0, duplicates: 10}} = imp(s, reordered)
    assert Readings.count(s) == 10
    # a duplicate row inside one file is a duplicate, not a rejection
    row = "TK-9,level,5,kg,2026-11-12T01:00:00Z,good\n"
    assert {:ok, %{loaded: 1, duplicates: 1, rejected: []}} = imp(s, @hdr <> row <> row)
  end

  test "I8 the import never writes to the stock ledger", %{schema: s} do
    before = ledger_counts(s)
    bad = @hdr <> good_rows(3) <> "TK-1,level,x,kg,2026-11-12T01:00:00Z,good\n"
    assert {:ok, %{loaded: 3, rejected: [_]}} = imp(s, bad)
    assert ledger_counts(s) == before

    # failed import: rolled back, nothing left in either table, ledger untouched
    assert_raise RuntimeError, ~r/fail_after/, fn ->
      imp(s, @hdr <> good_rows(8), fail_after: 3)
    end

    assert Readings.count(s) == 3 and Readings.import_count(s) == 1
    assert ledger_counts(s) == before
    assert {:ok, %{loaded: 5, duplicates: 3}} = imp(s, @hdr <> good_rows(8))
  end

  test "I9 the proof sources do not refer to ledger writers" do
    for f <- ~w(readings csv_import aggregate mass_balance) do
      src = File.read!(Path.join(["test", "support", "mes_p3", f <> ".ex"]))

      for banned <- ["Letflow.Ledger", "post(", "Records", "Modules.Stock"] do
        refute String.contains?(src, banned), "#{f}.ex mentions #{banned}"
      end
    end
  end

  test "I10 a second tenant sees none of the first tenant's readings", %{schema: a} do
    b = LedgerFixture.tenant!()
    Readings.ensure_table!(b)
    assert {:ok, %{loaded: 5}} = imp(a, @hdr <> good_rows(5))
    assert Readings.count(a) == 5 and Readings.count(b) == 0
  end
end
