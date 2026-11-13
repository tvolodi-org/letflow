defmodule Letflow.Proof.MesP3.RawOutsideTest do
  @moduledoc "MES PROOF P3 (T-1831), REMOVABLE: R1..R4. Raw 1 Hz data (7 200 samples) stays outside; only aggregates with a source are stored."

  use Letflow.DataCase, async: false

  alias Letflow.LedgerFixture
  alias Letflow.Proof.MesP3.Aggregate
  alias Letflow.Proof.MesP3.CsvImport
  alias Letflow.Proof.MesP3.Readings
  alias Letflow.Repo

  @t0 ~U[2026-11-12 00:00:00Z]
  @now ~U[2026-11-13 12:00:00Z]
  @n 7200

  setup do
    LedgerFixture.setup_auto_mode!()
    schema = LedgerFixture.tenant!()
    Readings.ensure_table!(schema)
    {:ok, schema: schema}
  end

  # deterministic 1 Hz level in kg: 1000 + (7 i mod 13)
  defp samples,
    do: for(i <- 0..(@n - 1), do: {DateTime.add(@t0, i), Decimal.new(1000 + rem(i * 7, 13))})

  defp raw_csv do
    rows = for {ts, v} <- samples(), do: "TK-101,level,#{v},kg,#{DateTime.to_iso8601(ts)},good\n"
    "equipment,kind,quantity,unit,measured_at,quality\n" <> Enum.join(rows)
  end

  test "R1 7200 samples become 8 quarter-hour aggregates, values checked by hand" do
    buckets = Aggregate.bucket(samples(), 900)
    assert length(buckets) == 8
    assert Enum.all?(buckets, &(&1.count == 900))
    b0 = hd(buckets)

    # residues of 7 i mod 13 over i = 0..899: 69 full cycles (sum 78 each) + residues 0, 7, 1 of i = 897..899
    assert Decimal.equal?(b0.min, 1000) and Decimal.equal?(b0.max, 1012) and
             Decimal.equal?(b0.last, 1001)

    assert Decimal.equal?(b0.avg, "1005.989")
    assert b0.first_ts == @t0 and b0.last_ts == DateTime.add(@t0, 899)
  end

  test "R2 the raw file is refused by density, at most 4 rows per hour pass the parse", %{
    schema: s
  } do
    assert {:ok, %{rows: kept, rejected: rej}} = CsvImport.parse(raw_csv(), now: @now)
    assert length(kept) == 8 and length(rej) == @n - 8
    assert Enum.all?(rej, &(&1.reason == :too_dense))

    assert {:ok, %{loaded: 8, rejected: rej2}} = CsvImport.import(s, raw_csv(), now: @now)
    assert length(rej2) == @n - 8
    assert Readings.count(s) == 8
  end

  test "R3 aggregates first: raw import afterwards adds nothing, no raw-series table exists", %{
    schema: s
  } do
    for b <- Aggregate.bucket(samples(), 900) do
      assert {:ok, :inserted} =
               Readings.insert(s, %{
                 equipment: "TK-101",
                 kind: "level",
                 quantity: b.last,
                 unit: "kg",
                 measured_at: b.last_ts,
                 source: "historian",
                 quality: "good",
                 agg_count: b.count,
                 agg_kind: "last"
               })
    end

    assert Readings.count(s) == 8
    assert {:ok, %{loaded: 0, rejected: rej}} = CsvImport.import(s, raw_csv(), now: @now)
    # 7 192 refused by the file-level cap, the other 8 by the stored aggregates of the same hours
    assert length(rej) == @n
    assert Readings.count(s) == 8

    %{rows: tables} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_name LIKE 'proof\\_%' ORDER BY 1",
        [s]
      )

    assert List.flatten(tables) == ["proof_import", "proof_reading"]
    # 7 200 raw samples -> 8 stored rows (900:1)
    assert div(@n, Readings.count(s)) == 900
  end

  test "R4 every stored aggregate carries a source and its sample count", %{schema: s} do
    for b <- Aggregate.bucket(samples(), 900) do
      {:ok, :inserted} =
        Readings.insert(s, %{
          equipment: "TK-101",
          kind: "level",
          quantity: b.last,
          unit: "kg",
          measured_at: b.last_ts,
          source: "historian",
          quality: "good",
          agg_count: b.count,
          agg_kind: "last"
        })
    end

    rows = Readings.list(s, source: "historian")
    assert length(rows) == 8

    assert Enum.all?(
             rows,
             &(&1.source == "historian" and &1.agg_kind == "last" and &1.agg_count == 900)
           )

    assert rows |> Enum.map(& &1.agg_count) |> Enum.sum() == @n
  end
end
