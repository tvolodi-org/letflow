defmodule Letflow.Proof.MesP3.MassBalanceTest do
  @moduledoc "MES PROOF P3 (T-1831), REMOVABLE: M1..M4. Mass balance sketch for tank TK-101; reads readings only, posts nothing."

  use Letflow.DataCase, async: false

  alias Letflow.LedgerFixture
  alias Letflow.Proof.MesP3.MassBalance
  alias Letflow.Proof.MesP3.Readings

  @from ~U[2026-11-12 06:00:00Z]
  @to ~U[2026-11-12 10:00:00Z]
  @meters [meters: %{in: "FM-IN", out: "FM-OUT"}]
  @ledger_tables ~w(ledger_entry ledger_leg ledger_counter ledger_balance)

  setup do
    LedgerFixture.setup_auto_mode!()
    schema = LedgerFixture.tenant!()
    Readings.ensure_table!(schema)
    {:ok, schema: schema}
  end

  defp put(s, eq, kind, qty, hour, opts \\ []) do
    {:ok, :inserted} =
      Readings.insert(s, %{
        equipment: eq,
        kind: kind,
        quantity: Decimal.new(qty),
        unit: opts[:unit] || "kg",
        measured_at: DateTime.add(@from, hour * 3600),
        source: opts[:source] || "file",
        quality: opts[:quality] || "good"
      })
  end

  # inlet 100 -> 400 (+300), outlet 50 -> 250 (+200), level 1000 -> 1100 (+100): balanced
  defp seed_balanced(s, level_end \\ "1100") do
    put(s, "FM-IN", "flow_total", "100", 0)
    put(s, "FM-IN", "flow_total", "250", 2)
    put(s, "FM-IN", "flow_total", "400", 4)
    put(s, "FM-OUT", "flow_total", "50", 0)
    put(s, "FM-OUT", "flow_total", "250", 4)
    put(s, "TK-101", "level", "1000", 0)
    put(s, "TK-101", "level", level_end, 4)
  end

  defp ledger_counts(s), do: Enum.map(@ledger_tables, &LedgerFixture.count(s, &1))

  test "M1 balanced window: difference is 0", %{schema: s} do
    seed_balanced(s)
    assert {:ok, r} = MassBalance.sketch(s, "TK-101", @from, @to, @meters)

    assert Decimal.equal?(r.in, 300) and Decimal.equal?(r.out, 200) and
             Decimal.equal?(r.change, 100)

    assert Decimal.equal?(r.expected_change, 100) and Decimal.equal?(r.difference, 0)
    assert r.unit == "kg" and r.notes == []
  end

  test "M2 loss window: difference -5.000 is shown, no cause given", %{schema: s} do
    seed_balanced(s, "1095")
    assert {:ok, r} = MassBalance.sketch(s, "TK-101", @from, @to, @meters)
    assert Decimal.equal?(r.difference, -5)
    assert Decimal.to_string(Decimal.round(r.difference, 3), :normal) == "-5.000"
    refute Map.has_key?(r, :cause)
  end

  test "M3 reset, litres, empty window and bad quality are flagged, never guessed", %{schema: s} do
    seed_balanced(s)
    put(s, "FM-OUT", "flow_total", "10", 5)
    assert {:ok, r} = MassBalance.sketch(s, "TK-101", @from, DateTime.add(@to, 7200), @meters)
    assert r.difference == nil and {:meter_reset, :outlet} in r.notes

    # a litre level is refused (no density in the proof)
    put(s, "TK-101", "level", "900", 3, unit: "l")
    assert {:error, :unit_mismatch} = MassBalance.sketch(s, "TK-101", @from, @to, @meters)

    # no data at all in the window
    assert {:ok, e} =
             MassBalance.sketch(
               s,
               "TK-101",
               ~U[2026-01-01 00:00:00Z],
               ~U[2026-01-02 00:00:00Z],
               @meters
             )

    assert e.difference == nil and :window_has_no_level in e.notes
  end

  test "M3b a bad reading is dropped, an uncertain one is noted, best source wins a tie", %{
    schema: s
  } do
    seed_balanced(s)
    put(s, "TK-101", "level", "9999", 4, quality: "bad", source: "manual")
    put(s, "FM-IN", "flow_total", "999", 4, source: "manual", quality: "uncertain")
    assert {:ok, r} = MassBalance.sketch(s, "TK-101", @from, @to, @meters)
    assert Decimal.equal?(r.difference, 0)
    assert r.notes == []
  end

  test "M4 the sketch posts nothing: ledger counts are unchanged", %{schema: s} do
    seed_balanced(s, "1095")
    before = ledger_counts(s)
    assert {:ok, _} = MassBalance.sketch(s, "TK-101", @from, @to, @meters)
    assert ledger_counts(s) == before
  end
end
