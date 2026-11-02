defmodule Letflow.Entities.XlsxImport do
  @moduledoc """
  `.xlsx` front end of the record import (GH #3603, REQ-650, decision 0077): turns the bytes of
  a workbook into the same rows `Letflow.Entities.CsvImport` produces, so
  `POST /entities/records/:entity_type/import` can take the `.xlsx` media type for a type that
  is not module-managed. Pure: bytes and the entity's field definitions in, rows out. No
  database, no process, no clock, never raises.

  Rules (the mapping is decision 0077 D3):

    * only the first worksheet (workbook order) is read; row 1 is the header, exactly the field
      names of the type (as for CSV; in upsert mode also `external_ref_system` and
      `external_ref_id`, together);
    * a cell becomes text (strings as they are, numbers as their plain decimal text, booleans
      `true`/`false`, dates ISO 8601) and then goes through the same per-cell coercion as a CSV
      cell, so the reasons are the `csv_invalid_*` ones; an empty cell yields no key;
    * a formula cell is its cached value; a formula is never evaluated;
    * `line` is the sheet row number (header = 1); blank rows are skipped;
    * a non-blank cell to the right of the header is the row error `xlsx_cell_count`.

  Limits: the workbook's parts may inflate to 25 MiB at most (checked on the declared sizes
  first, then on the real inflated bytes part by part), an XML part with a `<!DOCTYPE` or in a
  non-UTF-8 encoding is refused, and more than the caller's `max_rows` data rows is
  `{:error, :too_many_records, count}`. Whole-file refusals are constant atoms; none carries
  file text.
  """

  alias Letflow.Entities.CsvImport

  @max_inflated 26_214_400

  @refusals [
    :xlsx_unreadable,
    :xlsx_too_large,
    :xlsx_header_missing,
    :xlsx_duplicate_header,
    :xlsx_unknown_header,
    :xlsx_external_ref_pair
  ]

  @header_refusals %{
    csv_duplicate_header: :xlsx_duplicate_header,
    csv_unknown_header: :xlsx_unknown_header,
    csv_external_ref_pair: :xlsx_external_ref_pair
  }

  @doc "The whole-file refusal reasons `convert/3` can return."
  @spec refusals() :: [atom()]
  def refusals, do: @refusals

  @doc "The limit on the inflated size of all parts of a workbook, in bytes."
  @spec max_inflated_bytes() :: pos_integer()
  def max_inflated_bytes, do: @max_inflated

  @spec convert(binary(), [map()], keyword()) ::
          {:ok, [CsvImport.row()]}
          | {:error, atom()}
          | {:error, :too_many_records, non_neg_integer()}
  def convert(binary, fields, opts \\ []) when is_binary(binary) and is_list(fields) do
    upsert? = Keyword.get(opts, :upsert, false)
    max_rows = Keyword.get(opts, :max_rows, :infinity)

    try do
      with :ok <- check_declared_size(binary),
           :ok <- check_parts(binary),
           {:ok, rows} <- read_first_sheet(binary),
           {:ok, header, data} <- split_header(rows),
           field_types = CsvImport.field_types(fields),
           :ok <- check_header(header, field_types, upsert?),
           :ok <- check_cap(data, max_rows) do
        {:ok,
         Enum.map(data, fn {line, cells} ->
           row(line, cells, header, field_types, upsert?)
         end)}
      end
    rescue
      _ -> {:error, :xlsx_unreadable}
    catch
      _, _ -> {:error, :xlsx_unreadable}
    end
  end

  # ── zip guards ────────────────────────────────────────────────────────

  # Stage 1: the sizes the archive declares; nothing is inflated.
  defp check_declared_size(binary) do
    case :zip.list_dir(binary) do
      {:ok, entries} ->
        total =
          Enum.reduce(entries, 0, fn
            {:zip_file, _name, info, _comment, _offset, _csize}, acc -> acc + elem(info, 1)
            _other, acc -> acc
          end)

        if total > @max_inflated, do: {:error, :xlsx_too_large}, else: :ok

      {:error, _} ->
        {:error, :xlsx_unreadable}
    end
  end

  # Stage 2: the declared sizes are the archive's own claim, so the parts are inflated one by one
  # with a running real-size cap. Every XML part is also checked for a DOCTYPE and its encoding.
  defp check_parts(binary) do
    {:ok, handle} = :zip.zip_open(binary, [:memory])

    try do
      {:ok, entries} = :zip.zip_list_dir(handle)

      names =
        for {:zip_file, name, _info, _comment, _offset, _csize} <- entries, do: name

      Enum.reduce_while(names, {:ok, 0}, fn name, {:ok, total} ->
        {:ok, {_name, part}} = :zip.zip_get(name, handle)
        total = total + byte_size(part)

        cond do
          total > @max_inflated -> {:halt, {:error, :xlsx_too_large}}
          xml_part?(name) and not safe_xml?(part) -> {:halt, {:error, :xlsx_unreadable}}
          true -> {:cont, {:ok, total}}
        end
      end)
      |> case do
        {:ok, _total} -> :ok
        {:error, _} = error -> error
      end
    after
      :zip.zip_close(handle)
    end
  end

  defp xml_part?(name) do
    name = to_string(name)
    String.ends_with?(name, ".xml") or String.ends_with?(name, ".rels")
  end

  defp safe_xml?(part) do
    text =
      case part do
        <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
        _ -> part
      end

    String.valid?(text) and String.starts_with?(String.trim_leading(text), "<") and
      not Regex.match?(~r/<!doctype/i, text)
  end

  # ── reading ───────────────────────────────────────────────────────────

  defp read_first_sheet(binary) do
    with {:ok, package} <- XlsxReader.open(binary, source: :binary),
         [first | _] <- XlsxReader.sheet_names(package),
         {:ok, rows} <-
           XlsxReader.sheet(package, first,
             blank_value: nil,
             empty_rows: true,
             number_type: Decimal
           ) do
      {:ok, rows}
    else
      _ -> {:error, :xlsx_unreadable}
    end
  end

  # The list index is the sheet row number only while empty rows are kept; they are, so the
  # line of a row is its index + 1. Cells beyond the used range are not in the row.
  defp split_header(rows) do
    numbered = rows |> Enum.with_index(1) |> Enum.map(fn {cells, line} -> {line, cells} end)

    case numbered do
      [{_line, header_cells} | data] ->
        header = header_cells |> Enum.map(&header_text/1) |> drop_trailing_blank()

        if header == [] do
          {:error, :xlsx_header_missing}
        else
          {:ok, header, Enum.reject(data, fn {_line, cells} -> blank_row?(cells) end)}
        end

      [] ->
        {:error, :xlsx_header_missing}
    end
  end

  defp header_text(cell) do
    case cell_text(cell) do
      {:ok, text} -> text
      :error -> ""
    end
  end

  defp drop_trailing_blank(header) do
    header |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
  end

  defp blank_row?(cells), do: Enum.all?(cells, &blank?/1)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_cell), do: false

  # A blank header cell inside the header is not a field name: the shared check refuses "".
  defp check_header(header, field_types, upsert?) do
    case CsvImport.check_header(header, field_types, upsert?) do
      :ok -> :ok
      {:error, reason} -> {:error, Map.fetch!(@header_refusals, reason)}
    end
  end

  defp check_cap(_data, :infinity), do: :ok

  defp check_cap(data, max_rows) do
    count = length(data)
    if count > max_rows, do: {:error, :too_many_records, count}, else: :ok
  end

  # ── rows ──────────────────────────────────────────────────────────────

  defp row(line, cells, header, field_types, upsert?) do
    width = length(header)
    {inside, beyond} = Enum.split(cells, width)

    if Enum.all?(beyond, &blank?/1) do
      inside = inside ++ List.duplicate(nil, width - length(inside))

      case texts(inside) do
        {:ok, texts} -> CsvImport.convert_row(line, texts, header, field_types, upsert?)
        :error -> %{line: line, result: {:error, :csv_invalid_value, nil}}
      end
    else
      %{line: line, result: {:error, :xlsx_cell_count, nil}}
    end
  end

  defp texts(cells) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, acc} ->
      case cell_text(cell) do
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  # Cell value -> the text the CSV coercion reads (decision 0077 D3).
  defp cell_text(nil), do: {:ok, ""}
  defp cell_text(text) when is_binary(text), do: {:ok, text}
  defp cell_text(true), do: {:ok, "true"}
  defp cell_text(false), do: {:ok, "false"}
  defp cell_text(int) when is_integer(int), do: {:ok, Integer.to_string(int)}

  defp cell_text(float) when is_float(float) do
    if float == Float.round(float) and abs(float) < 9_007_199_254_740_992.0,
      do: {:ok, Integer.to_string(trunc(float))},
      else: {:ok, Float.to_string(float)}
  end

  defp cell_text(%Decimal{} = decimal) do
    if Decimal.integer?(decimal),
      do: {:ok, decimal |> Decimal.to_integer() |> Integer.to_string()},
      else: {:ok, Decimal.to_string(decimal, :normal)}
  end

  defp cell_text(%Date{} = date), do: {:ok, Date.to_iso8601(date)}

  # A date-and-time cell has no zone in the workbook: it is read as UTC (decision 0077 D3).
  defp cell_text(%NaiveDateTime{} = naive) do
    {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()}
  end

  defp cell_text(%DateTime{} = datetime), do: {:ok, DateTime.to_iso8601(datetime)}
  defp cell_text(%Time{} = time), do: {:ok, Time.to_iso8601(time)}
  defp cell_text(_other), do: :error
end
