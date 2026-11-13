defmodule Letflow.Proof.MesP3.MassBalance do
  @moduledoc """
  MES PROOF P3 (T-1831), REMOVABLE: a mass balance SKETCH for one tank. It only READS readings and returns numbers. It
  posts nothing and never refers to the stock side.

  `in` and `out` are the change of a cumulative flow totaliser (last minus first reading in the window) of an inlet and an
  outlet meter; `change` is the tank level at the end minus the level at the start; `expected_change = in - out`;
  `difference = change - expected_change` (negative = less in the tank than the meters explain). The sketch states no cause.
  Unknown is never guessed: a totaliser reset, a litre reading (no density in the proof), or fewer than two level readings
  give `difference: nil` and a note, or an error.

  The tank to meters mapping is an argument (guess: the real build needs a mapping table).
  """

  alias Letflow.Proof.MesP3.Readings

  @source_rank %{"file" => 0, "historian" => 1, "manual" => 2}
  @quality_rank %{"good" => 0, "uncertain" => 1}

  @spec sketch(String.t(), String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, :unit_mismatch}
  def sketch(schema, tank, from, to, meters: %{in: inlet, out: outlet}) do
    levels = series(schema, tank, "level", from, to)
    ins = series(schema, inlet, "flow_total", from, to)
    outs = series(schema, outlet, "flow_total", from, to)

    if Enum.any?(levels ++ ins ++ outs, &(&1.unit != "kg")) do
      {:error, :unit_mismatch}
    else
      {in_amt, in_notes} = delta(ins, :inlet)
      {out_amt, out_notes} = delta(outs, :outlet)
      {l0, l1, level_notes} = level_ends(levels)

      notes =
        in_notes ++
          out_notes ++
          level_notes ++
          if(Enum.any?(levels ++ ins ++ outs, &(&1.quality == "uncertain")),
            do: [:quality_uncertain],
            else: []
          )

      change = if l0 && l1, do: Decimal.sub(l1.quantity, l0.quantity)
      expected = if in_amt && out_amt, do: Decimal.sub(in_amt, out_amt)
      diff = if change && expected, do: Decimal.sub(change, expected)

      {:ok,
       %{
         in: in_amt,
         out: out_amt,
         level_start: l0 && l0.quantity,
         level_end: l1 && l1.quantity,
         change: change,
         expected_change: expected,
         difference: diff,
         unit: "kg",
         notes: Enum.uniq(notes)
       }}
    end
  end

  # readings in the window, bad quality dropped, one per measured_at (best quality, then source order)
  defp series(schema, equipment, kind, from, to) do
    schema
    |> Readings.list(equipment: equipment, kind: kind)
    |> Enum.filter(
      &(&1.quality != "bad" and DateTime.compare(&1.measured_at, from) != :lt and
          DateTime.compare(&1.measured_at, to) != :gt)
    )
    |> Enum.group_by(& &1.measured_at)
    |> Enum.map(fn {_t, group} ->
      Enum.min_by(
        group,
        &{Map.fetch!(@quality_rank, &1.quality), Map.fetch!(@source_rank, &1.source)}
      )
    end)
    |> Enum.sort_by(&DateTime.to_unix(&1.measured_at))
  end

  defp delta([_, _ | _] = series, side) do
    values = Enum.map(series, & &1.quantity)

    if values
       |> Enum.chunk_every(2, 1, :discard)
       |> Enum.any?(fn [a, b] -> Decimal.lt?(b, a) end) do
      {nil, [{:meter_reset, side}]}
    else
      {Decimal.sub(List.last(values), hd(values)), []}
    end
  end

  defp delta(_series, side), do: {nil, [{:meter_window_empty, side}]}

  defp level_ends([a, _ | _] = levels), do: {a, List.last(levels), []}
  defp level_ends(_), do: {nil, nil, [:window_has_no_level]}
end
