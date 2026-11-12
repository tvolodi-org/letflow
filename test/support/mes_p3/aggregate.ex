defmodule Letflow.Proof.MesP3.Aggregate do
  @moduledoc """
  MES PROOF P3 (T-1831), REMOVABLE: a pure stand-in for the plant's export job or gateway that turns raw high-rate samples
  into per-bucket aggregates. The raw samples never reach the proof tables; only the aggregates do.
  """

  @doc """
  `samples`: `[{DateTime, Decimal}]`. `bucket_seconds`: bucket length. Returns one map per non-empty bucket, oldest first:
  `bucket_start, count, min, max, avg (3 decimals), last, first_ts, last_ts`.
  """
  @spec bucket([{DateTime.t(), Decimal.t()}], pos_integer()) :: [map()]
  def bucket(samples, bucket_seconds) when bucket_seconds > 0 do
    samples
    |> Enum.sort_by(fn {ts, _} -> DateTime.to_unix(ts) end)
    |> Enum.group_by(fn {ts, _} -> div(DateTime.to_unix(ts), bucket_seconds) end)
    |> Enum.sort_by(fn {b, _} -> b end)
    |> Enum.map(fn {b, group} ->
      values = Enum.map(group, &elem(&1, 1))
      {first_ts, _} = hd(group)
      {last_ts, last} = List.last(group)
      count = length(group)

      %{
        bucket_start: DateTime.from_unix!(b * bucket_seconds),
        count: count,
        min: Enum.reduce(values, &Decimal.min/2),
        max: Enum.reduce(values, &Decimal.max/2),
        avg: values |> Enum.reduce(&Decimal.add/2) |> Decimal.div(count) |> Decimal.round(3),
        last: last,
        first_ts: first_ts,
        last_ts: last_ts
      }
    end)
  end
end
