defmodule Letflow.Proof.MesP3.CsvImport do
  @moduledoc """
  MES PROOF P3 (T-1831), REMOVABLE: ONE file import of readings (CSV of tank levels or flow totals) into the proof tables.

  Header (exact, case-insensitive): `equipment,kind,quantity,unit,measured_at,quality`. The importer sets `source = file`;
  a `source` column is refused. Rows that fail a rule are rejected with a reason and never stop the others. A whole-file
  problem (`empty_file`, `bad_header`, `unexpected_column`, `too_large`, `not_utf8`) refuses the file and writes nothing.
  The file is parsed ONCE (`parse/2`); the database step gets only the parsed rows.

  Idempotent in two layers: the sha256 of the bytes (`proof_import.file_hash`), and a unique (source, row key) per reading.
  The whole file is written in one transaction. The density cap (guess: at most #{4} readings per equipment, kind and UTC
  clock hour) is the proof's policy that raw high-rate data does not get in: aggregate before import.

  This module only reads and writes the two proof tables. It has no access to any stock or ledger module.
  """

  alias Letflow.Proof.MesP3.Readings
  alias Letflow.Repo

  @header ~w(equipment kind quantity unit measured_at quality)
  @max_bytes 1_000_000
  @max_rows 10_000
  @max_per_hour 4
  @schema_re ~r/\Atenant_[0-9a-f]{32}\z/

  def max_per_hour, do: @max_per_hour
  def max_rows, do: @max_rows

  @doc "Parse only (pure). `{:ok, %{rows: [...], rejected: [...]}}` or `{:error, file_reason}`."
  @spec parse(binary(), keyword()) ::
          {:ok, %{rows: [map()], rejected: [map()]}} | {:error, atom()}
  def parse(bin, opts \\ []) when is_binary(bin) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    cond do
      byte_size(bin) > @max_bytes -> {:error, :too_large}
      not String.valid?(bin) -> {:error, :not_utf8}
      true -> bin |> strip_bom() |> parse_text(now)
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(bin), do: bin

  defp parse_text(text, now) do
    case read_csv(text) do
      [] ->
        {:error, :empty_file}

      [header | data] ->
        with :ok <- check_header(header),
             :ok <- check_size(data) do
          {ok, bad} =
            data
            |> Enum.with_index(2)
            |> Enum.map(fn {fields, line} -> validate(fields, line, now) end)
            |> Enum.split_with(&match?({:ok, _}, &1))

          {rows, dense} = density(Enum.map(ok, &elem(&1, 1)))
          {:ok, %{rows: rows, rejected: Enum.map(bad, &elem(&1, 1)) ++ dense}}
        end
    end
  end

  defp check_header(fields) do
    names = Enum.map(fields, &(&1 |> String.trim() |> String.downcase()))

    cond do
      names == @header -> :ok
      "source" in names -> {:error, :unexpected_column}
      true -> {:error, :bad_header}
    end
  end

  defp check_size(data), do: if(length(data) > @max_rows, do: {:error, :too_large}, else: :ok)

  defp validate(fields, line, now) do
    raw = Enum.join(fields, ",")
    reject = fn reason -> {:error, %{line: line, reason: reason, raw: raw}} end

    case Enum.map(fields, &String.trim/1) do
      [equipment, kind, qty, unit, time, quality] ->
        with {:equipment, true} <- {:equipment, equipment != ""},
             {:kind, true} <- {:kind, kind in ~w(level flow_total)},
             {:quantity, {:ok, q}} <- {:quantity, quantity(qty)},
             {:unit, true} <- {:unit, unit in ~w(kg l)},
             {:time, {:ok, t}} <- {:time, time(time, now)},
             {:quality, true} <- {:quality, quality in ~w(good uncertain bad)} do
          {:ok,
           %{
             line: line,
             raw: raw,
             equipment: equipment,
             kind: kind,
             quantity: q,
             unit: unit,
             measured_at: t,
             source: "file",
             quality: quality
           }}
        else
          {:equipment, _} -> reject.(:empty_equipment)
          {:kind, _} -> reject.(:bad_kind)
          {:quantity, _} -> reject.(:bad_quantity)
          {:unit, _} -> reject.(:bad_unit)
          {:time, _} -> reject.(:bad_time)
          {:quality, _} -> reject.(:bad_quality)
        end

      _ ->
        reject.(:wrong_column_count)
    end
  end

  # no locale guessing: "1,5" is a bad quantity (and in a CSV it is two fields anyway when unquoted)
  defp quantity(text) do
    if Regex.match?(~r/\A\d+(\.\d{1,3})?\z/, text), do: {:ok, Decimal.new(text)}, else: :error
  end

  defp time(text, now) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} ->
        if DateTime.diff(dt, now) > 86_400, do: :error, else: {:ok, dt}

      _ ->
        :error
    end
  end

  # file-level density: per (equipment, kind, UTC hour) the first #{@max_per_hour} rows by line pass
  defp density(rows) do
    {kept, dense, _} =
      Enum.reduce(rows, {[], [], %{}}, fn row, {kept, dense, seen} ->
        key = hour_key(row)
        n = Map.get(seen, key, 0)

        if n >= @max_per_hour do
          {kept, [%{line: row.line, reason: :too_dense, raw: row.raw} | dense], seen}
        else
          {[row | kept], dense, Map.put(seen, key, n + 1)}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(dense)}
  end

  defp hour_key(row), do: {row.equipment, row.kind, hour_start(row.measured_at)}

  defp hour_start(dt) do
    {:ok, utc} = DateTime.shift_zone(dt, "Etc/UTC")
    DateTime.from_unix!(div(DateTime.to_unix(utc), 3600) * 3600)
  end

  @doc """
  Imports `csv` into the proof tables of `schema`. Options: `:now` (DateTime, default now), `:fail_after` (a test hook:
  raise after that many readings were inserted, to prove the rollback).

  Returns `{:ok, %{status: :loaded | :already_imported, file_hash, loaded, duplicates, rejected: [...]}}` or
  `{:error, file_reason}` (nothing written).
  """
  @spec import(String.t(), binary(), keyword()) :: {:ok, map()} | {:error, atom()}
  def import(schema, csv, opts \\ []) when is_binary(schema) and is_binary(csv) do
    true = Regex.match?(@schema_re, schema)

    with {:ok, parsed} <- parse(csv, opts) do
      hash = :crypto.hash(:sha256, csv) |> Base.encode16(case: :lower)
      {:ok, result} = Repo.transaction(fn -> write(schema, hash, parsed, opts) end)
      {:ok, result}
    end
  end

  defp write(schema, hash, %{rows: rows, rejected: rejected}, opts) do
    case Repo.query!(
           ~s|INSERT INTO "#{schema}".proof_import (file_hash) VALUES ($1) ON CONFLICT (file_hash) DO NOTHING RETURNING id::text|,
           [hash]
         ) do
      %{rows: []} ->
        %{status: :already_imported, file_hash: hash, loaded: 0, duplicates: 0, rejected: []}

      %{rows: [[import_id]]} ->
        {loaded, dups, dense} =
          Enum.reduce(rows, {0, 0, []}, &write_row(schema, import_id, opts, &1, &2))

        all_rejected = Enum.sort_by(rejected ++ Enum.reverse(dense), & &1.line)

        Repo.query!(
          ~s|UPDATE "#{schema}".proof_import SET loaded = $2, duplicates = $3, rejected = $4 WHERE id = $1::text::uuid|,
          [import_id, loaded, dups, length(all_rejected)]
        )

        %{
          status: :loaded,
          file_hash: hash,
          loaded: loaded,
          duplicates: dups,
          rejected: all_rejected
        }
    end
  end

  defp write_row(schema, import_id, opts, row, {loaded, dups, dense}) do
    attrs = Map.put(row, :import_id, import_id)

    cond do
      exists?(schema, attrs) ->
        {loaded, dups + 1, dense}

      stored_in_hour(schema, row) >= @max_per_hour ->
        {loaded, dups, [%{line: row.line, reason: :too_dense, raw: row.raw} | dense]}

      true ->
        {:ok, :inserted} = Readings.insert(schema, attrs)

        if opts[:fail_after] && loaded + 1 >= opts[:fail_after],
          do: raise("proof hook: fail_after")

        {loaded + 1, dups, dense}
    end
  end

  defp exists?(schema, attrs) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{schema}".proof_reading WHERE source = $1 AND row_key = $2|,
        [
          attrs.source,
          Readings.row_key(attrs)
        ]
      )

    n > 0
  end

  # the cap also counts readings of ANY source already stored in that hour (aggregates from the historian path)
  defp stored_in_hour(schema, row) do
    from = hour_start(row.measured_at)

    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{schema}".proof_reading WHERE equipment = $1 AND kind = $2 AND measured_at >= $3 AND measured_at < $4|,
        [row.equipment, row.kind, from, DateTime.add(from, 3600)]
      )

    n
  end

  # ── a small RFC-4180 reader: quoted fields, "" escape, CRLF or LF, blank lines skipped ──

  defp read_csv(text), do: scan(text, [], "", [], false)

  defp scan(<<>>, row, field, acc, _q), do: Enum.reverse(finish_row(row, field, acc))

  defp scan(<<?", ?", rest::binary>>, row, field, acc, true),
    do: scan(rest, row, field <> "\"", acc, true)

  defp scan(<<?", rest::binary>>, row, field, acc, true), do: scan(rest, row, field, acc, false)

  defp scan(<<c, rest::binary>>, row, field, acc, true),
    do: scan(rest, row, <<field::binary, c>>, acc, true)

  defp scan(<<?", rest::binary>>, row, "", acc, false), do: scan(rest, row, "", acc, true)

  defp scan(<<?,, rest::binary>>, row, field, acc, false),
    do: scan(rest, [field | row], "", acc, false)

  defp scan(<<?\r, ?\n, rest::binary>>, row, field, acc, false),
    do: scan(rest, [], "", finish_row(row, field, acc), false)

  defp scan(<<?\n, rest::binary>>, row, field, acc, false),
    do: scan(rest, [], "", finish_row(row, field, acc), false)

  defp scan(<<c, rest::binary>>, row, field, acc, false),
    do: scan(rest, row, <<field::binary, c>>, acc, false)

  defp finish_row([], "", acc), do: acc
  defp finish_row(row, field, acc), do: [Enum.reverse([field | row]) | acc]
end
