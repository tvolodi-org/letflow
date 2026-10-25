defmodule Letflow.Entities.CsvImport do
  @moduledoc """
  CSV front end of the record import (GH #3182, REQ-557): turns the text of a CSV file into
  the entries of the REQ-320 export document (`"field_values"`, optionally `"external_ref"`),
  so `POST /entities/records/:entity_type/import` can take `text/csv` as a second content
  type. Pure: text and the entity's field definitions in, entries and a row-to-line table
  out. No database, no process, no clock; every record is still written by the unchanged
  import handler through the records context.

  Format (RFC 4180, comma only, UTF-8 with an optional BOM):

    * the first record is the header; each header is exactly a field name of the type
      (no trimming, no case folding); in upsert mode `external_ref_system` and
      `external_ref_id` are also accepted and together form the entry's `"external_ref"`;
    * a quoted cell may contain commas, line breaks and `""` for one quote; CRLF inside a
      quoted cell is read as LF so LF and CRLF files give identical entries;
    * a blank line is skipped; an empty cell yields no key at all (not null, not `""`);
    * cells are coerced by the declared field type. The converter never guesses: a cell that
      does not fit its type is a row error, string and enum cells are passed on as they are
      (enum membership is the existing validation's job).

  Result: `{:ok, rows}` with `%{line: n, result: {:ok, entry} | {:error, reason, header}}` per
  record in file order (`line` is the physical line the record starts on, header = line 1),
  `{:error, refusal}` for a whole-file refusal, or `{:error, :too_many_records, count}`.
  Every reason is a constant atom; none carries cell text, and a whole-file refusal carries
  no header text either.
  """

  @external_ref_system "external_ref_system"
  @external_ref_id "external_ref_id"

  @refusals [
    :csv_invalid_utf8,
    :csv_header_missing,
    :csv_malformed,
    :csv_duplicate_header,
    :csv_unknown_header,
    :csv_external_ref_pair
  ]

  @type entry :: %{required(String.t()) => term()}
  @type row :: %{
          line: pos_integer(),
          result: {:ok, entry()} | {:error, atom(), String.t() | nil}
        }

  @doc "The whole-file refusal reasons `convert/3` can return."
  @spec refusals() :: [atom()]
  def refusals, do: @refusals

  @spec convert(binary(), [map()], keyword()) ::
          {:ok, [row()]}
          | {:error, atom()}
          | {:error, :too_many_records, non_neg_integer()}
  def convert(text, fields, opts \\ []) when is_binary(text) and is_list(fields) do
    upsert? = Keyword.get(opts, :upsert, false)
    max_rows = Keyword.get(opts, :max_rows, :infinity)
    text = strip_bom(text)

    with :ok <- check_utf8(text),
         {:ok, records} <- tokenize(text),
         {:ok, header, data} <- split_header(records),
         field_types = field_types(fields),
         :ok <- check_header(header, field_types, upsert?),
         :ok <- check_cap(data, max_rows) do
      {:ok,
       Enum.map(data, fn {line, cells} ->
         convert_row(line, cells, header, field_types, upsert?)
       end)}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(text), do: text

  defp check_utf8(text), do: if(String.valid?(text), do: :ok, else: {:error, :csv_invalid_utf8})

  defp split_header([]), do: {:error, :csv_header_missing}
  defp split_header([{_line, header} | data]), do: {:ok, header, data}

  defp field_types(fields) do
    for %{"name" => name} = field <- fields, into: %{} do
      {name, {field["type"], field["decimal_strict"] == true}}
    end
  end

  defp check_header(header, field_types, upsert?) do
    cond do
      length(header) != length(Enum.uniq(header)) ->
        {:error, :csv_duplicate_header}

      Enum.any?(header, &(not known_header?(&1, field_types, upsert?))) ->
        {:error, :csv_unknown_header}

      upsert? and @external_ref_system in header != @external_ref_id in header ->
        {:error, :csv_external_ref_pair}

      true ->
        :ok
    end
  end

  defp known_header?(name, field_types, upsert?) do
    Map.has_key?(field_types, name) or
      (upsert? and name in [@external_ref_system, @external_ref_id])
  end

  defp check_cap(_data, :infinity), do: :ok

  defp check_cap(data, max_rows) do
    count = length(data)
    if count > max_rows, do: {:error, :too_many_records, count}, else: :ok
  end

  # ── rows ──────────────────────────────────────────────────────────────

  defp convert_row(line, cells, header, _field_types, _upsert?)
       when length(cells) != length(header) do
    %{line: line, result: {:error, :csv_cell_count, nil}}
  end

  defp convert_row(line, cells, header, field_types, upsert?) do
    pairs = header |> Enum.zip(cells) |> Enum.reject(fn {_name, cell} -> cell == "" end)

    result =
      Enum.reduce_while(pairs, {:ok, %{}, %{}}, fn {name, cell}, {:ok, values, refs} ->
        cond do
          upsert? and name in [@external_ref_system, @external_ref_id] ->
            {:cont, {:ok, values, Map.put(refs, name, cell)}}

          true ->
            {type, strict?} = Map.fetch!(field_types, name)

            case coerce(type, strict?, cell) do
              {:ok, value} -> {:cont, {:ok, Map.put(values, name, value), refs}}
              {:error, reason} -> {:halt, {:error, reason, name}}
            end
        end
      end)

    case result do
      {:ok, values, refs} -> %{line: line, result: {:ok, build_entry(values, refs)}}
      {:error, _reason, _name} = error -> %{line: line, result: error}
    end
  end

  defp build_entry(values, %{@external_ref_system => system, @external_ref_id => id}) do
    %{"field_values" => values, "external_ref" => %{"system" => system, "id" => id}}
  end

  defp build_entry(values, _refs), do: %{"field_values" => values}

  # ── coercion by declared type ─────────────────────────────────────────

  @integer ~r/\A[+-]?[0-9]{1,64}\z/
  @decimal_strict ~r/\A-?(0|[1-9][0-9]*)(\.[0-9]+)?\z/
  @json_number ~r/\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z/
  @date ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/
  # the grammar of Letflow.Entities.Record.Decimals
  @decimal_max_bytes 1100

  defp coerce("integer", _strict?, cell) do
    if Regex.match?(@integer, cell),
      do: {:ok, String.to_integer(cell)},
      else: {:error, :csv_invalid_integer}
  end

  defp coerce("decimal", true, cell) do
    if byte_size(cell) <= @decimal_max_bytes and Regex.match?(@decimal_strict, cell),
      do: {:ok, cell},
      else: {:error, :csv_invalid_decimal}
  end

  defp coerce("decimal", _not_strict, cell) do
    with true <- byte_size(cell) <= @decimal_max_bytes and Regex.match?(@json_number, cell),
         {:ok, number} <- Jason.decode(cell) do
      {:ok, number}
    else
      _ -> {:error, :csv_invalid_decimal}
    end
  end

  defp coerce("boolean", _strict?, cell) do
    case String.downcase(cell) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, :csv_invalid_boolean}
    end
  end

  defp coerce("date", _strict?, cell) do
    if Regex.match?(@date, cell) and match?({:ok, _}, Date.from_iso8601(cell)),
      do: {:ok, cell},
      else: {:error, :csv_invalid_date}
  end

  defp coerce("datetime", _strict?, cell) do
    case DateTime.from_iso8601(cell) do
      {:ok, _datetime, _offset} -> {:ok, cell}
      _ -> {:error, :csv_invalid_datetime}
    end
  end

  defp coerce("json", _strict?, cell) do
    case Jason.decode(cell) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> {:error, :csv_invalid_json}
    end
  end

  defp coerce("localized_text", _strict?, cell) do
    case Jason.decode(cell) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :csv_invalid_localized_text}
    end
  end

  # string, enum, and a type this converter does not know (a stored definition is already
  # validated): the cell is passed on as text.
  defp coerce(_type, _strict?, cell), do: {:ok, cell}

  # ── RFC 4180 tokenizer ────────────────────────────────────────────────

  # Returns the records as `{start_line, [cell]}`. `line` counts physical lines; a line break
  # inside a quoted cell advances it but not the start line of the record being read.
  defp tokenize(text), do: records(text, 1, [])

  defp records("", _line, acc), do: {:ok, Enum.reverse(acc)}
  defp records(<<"\r\n", rest::binary>>, line, acc), do: records(rest, line + 1, acc)
  defp records(<<"\n", rest::binary>>, line, acc), do: records(rest, line + 1, acc)

  defp records(text, line, acc) do
    case field(text, [], 0) do
      {:ok, cells, rest, breaks} -> records(rest, line + breaks + 1, [{line, cells} | acc])
      {:error, _} = error -> error
    end
  end

  defp field(<<?", rest::binary>>, cells, breaks), do: quoted(rest, [], cells, breaks)
  defp field(rest, cells, breaks), do: unquoted(rest, [], cells, breaks)

  defp unquoted("", cur, cells, breaks), do: {:ok, finish(cur, cells), "", breaks}

  defp unquoted(<<"\r\n", rest::binary>>, cur, cells, breaks),
    do: {:ok, finish(cur, cells), rest, breaks}

  defp unquoted(<<"\n", rest::binary>>, cur, cells, breaks),
    do: {:ok, finish(cur, cells), rest, breaks}

  defp unquoted(<<",", rest::binary>>, cur, cells, breaks),
    do: field(rest, [cell(cur) | cells], breaks)

  defp unquoted(<<?", _::binary>>, _cur, _cells, _breaks), do: {:error, :csv_malformed}

  defp unquoted(<<c, rest::binary>>, cur, cells, breaks),
    do: unquoted(rest, [c | cur], cells, breaks)

  defp quoted("", _cur, _cells, _breaks), do: {:error, :csv_malformed}

  defp quoted(<<?", ?", rest::binary>>, cur, cells, breaks),
    do: quoted(rest, [?" | cur], cells, breaks)

  defp quoted(<<?", rest::binary>>, cur, cells, breaks), do: after_quote(rest, cur, cells, breaks)

  defp quoted(<<"\r\n", rest::binary>>, cur, cells, breaks),
    do: quoted(rest, [?\n | cur], cells, breaks + 1)

  defp quoted(<<?\n, rest::binary>>, cur, cells, breaks),
    do: quoted(rest, [?\n | cur], cells, breaks + 1)

  defp quoted(<<c, rest::binary>>, cur, cells, breaks), do: quoted(rest, [c | cur], cells, breaks)

  defp after_quote("", cur, cells, breaks), do: {:ok, finish(cur, cells), "", breaks}

  defp after_quote(<<"\r\n", rest::binary>>, cur, cells, breaks),
    do: {:ok, finish(cur, cells), rest, breaks}

  defp after_quote(<<"\n", rest::binary>>, cur, cells, breaks),
    do: {:ok, finish(cur, cells), rest, breaks}

  defp after_quote(<<",", rest::binary>>, cur, cells, breaks),
    do: field(rest, [cell(cur) | cells], breaks)

  defp after_quote(_other, _cur, _cells, _breaks), do: {:error, :csv_malformed}

  defp cell(cur), do: cur |> Enum.reverse() |> :binary.list_to_bin()
  defp finish(cur, cells), do: Enum.reverse([cell(cur) | cells])
end
