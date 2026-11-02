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

  import Bitwise, only: [band: 2]

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

  # Stage 2: the declared sizes are the archive's own claim, so they are not trusted. The central
  # directory is read here and every part is inflated as a bounded stream (`:zlib.safeInflate/2`)
  # that stops as soon as the running real total passes the cap, so nothing over the cap is ever
  # allocated, whatever the archive declares. Every XML part is also checked for a DOCTYPE and its
  # encoding. Only a workbook that passes is handed to XlsxReader.
  defp check_parts(binary) do
    with {:ok, entries} <- central_entries(binary) do
      Enum.reduce_while(entries, {:ok, 0}, fn entry, {:ok, total} ->
        case inflate_entry(binary, entry, @max_inflated - total) do
          {:ok, name, part} ->
            total = total + byte_size(part)

            if xml_part?(name) and not safe_xml?(part),
              do: {:halt, {:error, :xlsx_unreadable}},
              else: {:cont, {:ok, total}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, _total} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp central_entries(binary) do
    case find_eocd(binary) do
      {:ok, count, cd_size, cd_offset}
      when cd_offset + cd_size <= byte_size(binary) ->
        parse_central(binary_part(binary, cd_offset, cd_size), count, [])

      _ ->
        {:error, :xlsx_unreadable}
    end
  end

  defp find_eocd(binary) do
    size = byte_size(binary)
    window = min(size, 22 + 65_535)
    tail = binary_part(binary, size - window, window)

    case :binary.matches(tail, <<0x50, 0x4B, 0x05, 0x06>>) do
      [] ->
        :error

      matches ->
        {pos, _} = List.last(matches)

        case tail do
          <<_::binary-size(^pos), 0x06054B50::32-little, _disk::16-little, _cd_disk::16-little,
            _n_disk::16-little, count::16-little, cd_size::32-little, cd_offset::32-little,
            _rest::binary>> ->
            {:ok, count, cd_size, cd_offset}

          _ ->
            :error
        end
    end
  end

  defp parse_central(_data, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_central(
         <<0x02014B50::32-little, _made::16-little, _need::16-little, flags::16-little,
           method::16-little, _time::16-little, _date::16-little, _crc::32-little,
           csize::32-little, _usize::32-little, nlen::16-little, elen::16-little, clen::16-little,
           _disk::16-little, _iattr::16-little, _eattr::32-little, offset::32-little,
           name::binary-size(nlen), _extra::binary-size(elen), _comment::binary-size(clen),
           rest::binary>>,
         count,
         acc
       ) do
    entry = %{name: name, flags: flags, method: method, csize: csize, offset: offset}
    parse_central(rest, count - 1, [entry | acc])
  end

  defp parse_central(_data, _count, _acc), do: {:error, :xlsx_unreadable}

  # `budget` is what is left of the cap; a part that would pass it is refused before it is
  # allocated. The compressed bytes are bounded by the archive itself (the 2 MiB body).
  defp inflate_entry(_binary, %{flags: flags}, _budget) when band(flags, 1) == 1,
    do: {:error, :xlsx_unreadable}

  defp inflate_entry(binary, %{name: name, method: method, csize: csize, offset: offset}, budget) do
    case binary do
      <<_::binary-size(^offset), 0x04034B50::32-little, _need::16-little, _flags::16-little,
        _method::16-little, _time::16-little, _date::16-little, _crc::32-little,
        _csize::32-little, _usize::32-little, nlen::16-little, elen::16-little, rest::binary>>
      when byte_size(rest) >= nlen + elen ->
        skip = nlen + elen
        <<_::binary-size(^skip), data::binary>> = rest
        inflate_data(name, method, data, csize, budget)

      _ ->
        {:error, :xlsx_unreadable}
    end
  end

  defp inflate_data(name, 0, data, csize, budget) when byte_size(data) >= csize do
    if csize > budget,
      do: {:error, :xlsx_too_large},
      else: {:ok, name, binary_part(data, 0, csize)}
  end

  defp inflate_data(name, 8, data, _csize, budget) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_loop(z, :zlib.safeInflate(z, data), 0, [], budget, name)
    after
      :zlib.close(z)
    end
  end

  defp inflate_data(_name, _method, _data, _csize, _budget), do: {:error, :xlsx_unreadable}

  defp inflate_loop(z, {state, out}, size, acc, budget, name) do
    size = size + IO.iodata_length(out)

    cond do
      size > budget ->
        {:error, :xlsx_too_large}

      state == :finished ->
        {:ok, name, IO.iodata_to_binary([acc, out])}

      true ->
        inflate_loop(z, :zlib.safeInflate(z, []), size, [acc, out], budget, name)
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
