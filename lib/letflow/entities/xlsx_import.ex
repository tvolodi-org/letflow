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
  `{:error, :too_many_records, count}`. The reader fills in the rows and cells a sheet omits from
  the row and cell references (`r="XFD1000"`), so a few bytes of XML can name millions of cells:
  before the reader runs, every verified part is scanned for those references with the reader's
  own XML parser and the same fill-in rules, and a part whose filled-in sheet would pass
  `max_sheet_rows` rows (default 100 000) or `max_sheet_cells` cells (default 500 000) is
  `{:error, :xlsx_too_large}` (INV-8, T-2041). Whole-file refusals are constant atoms; none carries
  file text.
  """

  import Bitwise, only: [band: 2]

  alias Letflow.Entities.CsvImport

  @max_inflated 26_214_400
  @max_sheet_rows 100_000
  @max_sheet_cells 500_000

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
    case convert_detailed(binary, fields, opts) do
      {:error, reason, %{} = _detail} -> {:error, reason}
      other -> other
    end
  end

  @doc """
  Like `convert/3`, but a refused header answers `{:error, reason, %{headers: [name]}}` naming the
  offending header cells (taken from the one parse that produced the header). Every other
  refusal is exactly what `convert/3` answers.
  """
  def convert_detailed(binary, fields, opts \\ []) when is_binary(binary) and is_list(fields) do
    upsert? = Keyword.get(opts, :upsert, false)
    max_rows = Keyword.get(opts, :max_rows, :infinity)
    required = Keyword.get(opts, :required_headers, [])

    try do
      with :ok <- check_declared_size(binary),
           {:ok, verified} <- check_parts(binary, sheet_budget(opts)),
           {:ok, rows} <- read_first_sheet(verified),
           {:ok, header, data} <- split_header(rows),
           field_types = CsvImport.field_types(fields),
           :ok <- check_header(header, field_types, upsert?),
           :ok <- check_required(header, required),
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

  @doc """
  REQ-884: the first worksheet's name and its rows as text cells, `{:ok, name, [{line, [text]}]}`
  with `line` the sheet row number (1 = first row, blank rows kept so the number is the sheet's).
  Same bounded reader as `convert/3` (declared-size check, bounded inflate, no DOCTYPE, rebuilt
  archive, reference scan): one parse, no second unzip. Whole-file refusals are
  `{:error, :xlsx_unreadable}` or `{:error, :xlsx_too_large}`; never raises.

  Options: `max_sheet_rows` (also the reference-scan row budget; more sheet rows is
  `:xlsx_too_large`), `max_sheet_cells` (reference-scan cell budget) and `max_columns` (only the
  first N cells of a row are converted; the rest are dropped unread).
  """
  @spec read_text_rows(binary(), keyword()) ::
          {:ok, String.t(), [{pos_integer(), [String.t()]}]} | {:error, atom()}
  def read_text_rows(binary, opts \\ []) when is_binary(binary) do
    budget = sheet_budget(opts)

    with :ok <- check_declared_size(binary),
         {:ok, verified} <- check_parts(binary, budget),
         {:ok, name, rows} <- read_first_sheet_named(verified),
         {:ok, text_rows} <- text_rows(rows, budget.rows, Keyword.get(opts, :max_columns)) do
      {:ok, name, text_rows}
    end
  rescue
    _ -> {:error, :xlsx_unreadable}
  catch
    _, _ -> {:error, :xlsx_unreadable}
  end

  # The reference scan already bounds the rows and cells; the row cap and the column cut here keep
  # this function bounded on its own (a shape the scan would miss still cannot fan out).
  defp text_rows(rows, max_rows, _max_columns) when length(rows) > max_rows,
    do: {:error, :xlsx_too_large}

  defp text_rows(rows, _max_rows, max_columns) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {cells, line}, {:ok, acc} ->
      cells = if is_integer(max_columns), do: Enum.take(cells, max_columns), else: cells

      case texts(cells, :bounded) do
        {:ok, texts} -> {:cont, {:ok, [{line, texts} | acc]}}
        :error -> {:halt, {:error, :xlsx_unreadable}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
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

  # Stage 2: the declared sizes are the archive's own claim, so they are not trusted. The entries
  # come from `:zip.list_dir/1` (the same directory XlsxReader would read, EOCD and ZIP64 rules
  # included); each is inflated from its local header as a bounded stream (`:zlib.safeInflate/2`)
  # that stops as soon as the running real total passes the cap, so nothing over the cap is ever
  # allocated. Every XML part is also checked for a DOCTYPE and its encoding. XlsxReader then gets
  # a fresh archive rebuilt from only the verified parts, so it can never inflate bytes that were
  # not counted here, whatever the original archive's directory says.
  # Stage 3 (in the same pass): every verified part is scanned for row and cell references
  # (`ReferenceScan`), so the reader never fills in more rows or cells than the budget, counting
  # the cells it builds and then drops (outside a row, under a nested row) as well, and every
  # text the reader turns into an integer (row and cell `r`, style `s`, a shared-string index, a
  # shared formula's `si`) is capped at 10 bytes before any conversion. The scan
  # reads the part as the reader will (`reader_text/1`), and the rebuilt archive holds those very
  # bytes, so the reader's own decoding step leaves them as they are: scan and reader parse the
  # same bytes (T-1122).
  defp check_parts(binary, budget) do
    with {:ok, entries} <- :zip.list_dir(binary) |> list_entries() do
      Enum.reduce_while(entries, {:ok, 0, []}, fn entry, {:ok, total, parts} ->
        case inflate_entry(binary, entry, @max_inflated - total) do
          {:ok, name, part} ->
            text = reader_text(part)
            total = total + max(byte_size(part), byte_size(text))

            cond do
              xml_part?(name) and not safe_xml?(part) ->
                {:halt, {:error, :xlsx_unreadable}}

              text != part and not safe_text?(text) ->
                {:halt, {:error, :xlsx_unreadable}}

              total > @max_inflated ->
                {:halt, {:error, :xlsx_too_large}}

              true ->
                case __MODULE__.ReferenceScan.check(text, budget) do
                  :ok -> {:cont, {:ok, total, [{String.to_charlist(name), text} | parts]}}
                  :too_large -> {:halt, {:error, :xlsx_too_large}}
                  :unreadable -> {:halt, {:error, :xlsx_unreadable}}
                end
            end

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, _total, parts} ->
          case :zip.create(~c"x.xlsx", Enum.reverse(parts), [:memory]) do
            {:ok, {_name, rebuilt}} -> {:ok, rebuilt}
            _ -> {:error, :xlsx_unreadable}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp sheet_budget(opts) do
    %{
      rows: Keyword.get(opts, :max_sheet_rows, @max_sheet_rows),
      cells: Keyword.get(opts, :max_sheet_cells, @max_sheet_cells)
    }
  end

  defp list_entries({:ok, entries}) do
    files =
      for {:zip_file, name, _info, _comment, offset, csize} <- entries,
          not String.ends_with?(to_string(name), "/") do
        %{name: to_string(name), offset: offset, csize: csize}
      end

    {:ok, files}
  end

  defp list_entries(_), do: {:error, :xlsx_unreadable}

  # `budget` is what is left of the cap; a part that would pass it is refused before it is
  # allocated. The compressed bytes are bounded by the archive itself (the 2 MiB body).
  defp inflate_entry(binary, %{name: name, csize: csize, offset: offset}, budget) do
    case binary do
      <<_::binary-size(^offset), 0x04034B50::32-little, _need::16-little, flags::16-little,
        method::16-little, _time::16-little, _date::16-little, _crc::32-little, _csize::32-little,
        _usize::32-little, nlen::16-little, elen::16-little, rest::binary>>
      when byte_size(rest) >= nlen + elen and band(flags, 1) == 0 ->
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

  # The bytes XlsxReader parses for a part: its `extract_xml/2` runs `Utils.ensure_utf8/1`, which
  # strips a UTF-8 BOM and decodes UTF-16/32 by BOM. A part that function cannot decode is never
  # parsed by the reader, so it is kept as it is. The rebuilt archive stores the decoded bytes,
  # so a second BOM inside them (the reader would strip it and parse what follows) is refused by
  # `safe_text?/1` instead of being handed on.
  defp reader_text(part) do
    case XlsxReader.Parsers.Utils.ensure_utf8(part) do
      {:ok, text} -> text
      {:error, _} -> part
    end
  end

  defp safe_text?(text) do
    :unicode.bom_to_encoding(text) == {:latin1, 0} and not Regex.match?(~r/<!doctype/i, text)
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
    with {:ok, _name, rows} <- read_first_sheet_named(binary), do: {:ok, rows}
  end

  defp read_first_sheet_named(binary) do
    with {:ok, package} <- XlsxReader.open(binary, source: :binary),
         [first | _] <- XlsxReader.sheet_names(package),
         {:ok, rows} <-
           XlsxReader.sheet(package, first,
             blank_value: nil,
             empty_rows: true,
             number_type: Decimal
           ) do
      {:ok, first, rows}
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
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Map.fetch!(@header_refusals, reason),
         %{headers: CsvImport.offending_headers(header, field_types, upsert?)}}
    end
  end

  # T-1609: opt-in (`required_headers:`), so the record import is unchanged. A header that must be
  # present is named, never a cell.
  defp check_required(_header, []), do: :ok

  defp check_required(header, required) do
    case required -- header do
      [] -> :ok
      missing -> {:error, :xlsx_missing_header, %{headers: missing}}
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

  defp texts(cells, mode \\ :exact) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, acc} ->
      case cell_text(cell, mode) do
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  # `:bounded` (read_text_rows/1, which has no row or column cap of its own): a numeric cell too
  # large to render cheaply (a Decimal like 1E6144 would build a 6 KB string per cell) becomes a
  # fixed over-cap placeholder instead of being expanded; the caller's byte bounds refuse it.
  # Checks are O(1) on the exponent and coefficient, before any rendering (INV-8, T-2041).
  @oversize_text String.duplicate("#", 1024)
  @max_decimal_exp 64
  @max_decimal_coef Integer.pow(10, 64)

  defp cell_text(%Decimal{exp: exp, coef: coef}, :bounded)
       when is_integer(coef) and (abs(exp) > @max_decimal_exp or coef >= @max_decimal_coef),
       do: {:ok, @oversize_text}

  defp cell_text(cell, _mode), do: cell_text(cell)

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

defmodule Letflow.Entities.XlsxImport.ReferenceScan do
  @moduledoc """
  Counts, before XlsxReader runs, how many rows and cells XlsxReader's worksheet parser would
  build from one XML part, and stops as soon as a budget is passed (INV-8, T-2041). XlsxReader
  fills in omitted rows and cells from the `r` references of `<row>` and `<c>`
  (`handle_omitted_rows`, `handle_omitted_cells` in its worksheet parser), so the size of its
  result is set by those numbers, not by the bytes of the XML.

  The scan is the same parse: the same parser (`Saxy.parse_string/3`, default options) over the
  same verified bytes the rebuilt archive hands the reader (already decoded the way the reader's
  `Utils.ensure_utf8/1` decodes them, in `XlsxImport.check_parts/2`), the same element names
  (`row`, `c`, unprefixed), and the same rules: a row's number is its first `r` or the expected row; the rows
  between the expected row and that number are filled in, each as wide as the row that follows
  them (a lower number fills nothing, and the next row counts its own gap from it); a cell's
  column is its last `r` (parsed by XlsxReader's own `CellReference.parse/1`), and the cells
  between the expected column and that column are filled in. Constant memory; the part that
  XlsxReader reads is one of the parts scanned, whichever its relationship names.

  The cell budget bounds the reader's work, not only its result: `cells` only grows, by every
  cell filled in at a `<c>`, every `</c>` and every filled-in row's copy of the row. Cells the
  reader builds and then drops count as well: a `<c>` outside any `<row>` (the reader prepends
  its fill-in to the closed row's `nil`) and the cells of an outer row that a nested `<row>`
  resets (the reader's `<row>` start sets `row: []`). Neither resets the count.

  Every text the reader turns into an integer is capped at 10 bytes before any
  conversion (`XFD1048576`, Excel's largest cell reference, is 10 bytes): a row's `r` and a cell's
  `r` (which the scan itself parses), a cell's style index `s` (its last one, kept until `</c>`, as
  the reader keeps it) and the value of a shared-string cell (`t="s"`: the first characters after
  a `<v>` or `<t>` start, which the reader stores, kept until `</c>`). A longer one is
  `:too_large`. A shared formula (`<f t="shared" ref=..>`, its first `t`, `ref` and `si`, as the
  reader reads them) needs an `si` of at most 10 bytes whose value is at least 0 and
  below the cell budget (`:too_large` otherwise, `:unreadable` when it is missing or not an
  integer): the reader keeps one array slot per index up to it, so the budget bounds that array.
  The text of other cells is not capped here: the reader's `Decimal`/number parsing of it is
  bounded by the inflate cap.

  The scan fails closed: an XML part the parser cannot read to the end is `:unreadable` when it
  holds a `<row>` or `<c>` tag (the reader may have started building rows from it), and so is a
  row `r` that is not an integer (the reader's `String.to_integer/1` raises on it). A part that
  does not start with `<` (a picture, a binary part) fails on its first byte, before any event,
  and is `:ok`: the reader builds no row from it. Real cells are counted at every `</c>`, so a
  row that never closes is bounded too.
  """

  @behaviour Saxy.Handler

  @max_index_bytes 10

  @doc """
  `:ok` when the filled-in rows and cells of `xml` stay within `budget`, `:too_large` when they
  pass it, `:unreadable` when a part with rows or cells cannot be parsed to the end.
  """
  @spec check(binary(), %{rows: pos_integer(), cells: pos_integer()}) ::
          :ok | :too_large | :unreadable
  def check(xml, %{rows: _, cells: _} = budget) when is_binary(xml) do
    state = %{
      budget: budget,
      rows: 0,
      cells: 0,
      expected_row: 1,
      current_row: 1,
      row_len: 0,
      expected_column: 1,
      cell_ref: nil,
      cell_style: nil,
      cell_type: nil,
      value_pending: false,
      value_bytes: 0
    }

    case Saxy.parse_string(xml, __MODULE__, state) do
      {:ok, :too_large} -> :too_large
      {:ok, :unreadable} -> :unreadable
      {:ok, _state} -> :ok
      {:error, _} -> if contains_sheet_element?(xml), do: :unreadable, else: :ok
    end
  rescue
    _ -> :unreadable
  end

  @impl Saxy.Handler
  def handle_event(:start_element, {"row", attributes}, state) do
    case first_attr(attributes, "r") do
      value when is_binary(value) and byte_size(value) > @max_index_bytes ->
        {:stop, :too_large}

      value ->
        current_row = if value, do: String.to_integer(value), else: state.expected_row
        {:ok, %{state | current_row: current_row, row_len: 0, expected_column: 1}}
    end
  rescue
    ArgumentError -> {:stop, :unreadable}
  end

  def handle_event(:start_element, {"c", attributes}, state) do
    ref = last_attr(attributes, "r", state.cell_ref)
    style = last_attr(attributes, "s", state.cell_style)

    if oversize?(ref) or oversize?(style),
      do: {:stop, :too_large},
      else: count_cell(%{state | cell_style: style}, ref, attributes)
  end

  def handle_event(:end_element, "c", state) do
    state = %{state | row_len: state.row_len + 1, cells: state.cells + 1}

    cond do
      state.cell_type == "s" and state.value_bytes > @max_index_bytes ->
        {:stop, :too_large}

      state.cells > state.budget.cells ->
        {:stop, :too_large}

      true ->
        {:ok,
         %{
           state
           | cell_ref: nil,
             cell_style: nil,
             cell_type: nil,
             value_pending: false,
             value_bytes: 0
         }}
    end
  end

  # The reader stores the first characters after a `<v>` or `<t>` start as the cell's value, and
  # a `<f>` start or a `</v>` ends the wait.
  def handle_event(:start_element, {name, _attributes}, state) when name in ["v", "t"],
    do: {:ok, %{state | value_pending: true}}

  def handle_event(:end_element, "v", state), do: {:ok, %{state | value_pending: false}}

  def handle_event(:characters, chars, %{value_pending: true} = state),
    do:
      {:ok,
       %{state | value_pending: false, value_bytes: max(state.value_bytes, byte_size(chars))}}

  def handle_event(:start_element, {"f", attributes}, state) do
    state = %{state | value_pending: false}

    case {first_attr(attributes, "t"), first_attr(attributes, "ref")} do
      {"shared", ref} when is_binary(ref) -> shared_index(first_attr(attributes, "si"), state)
      _ -> {:ok, state}
    end
  end

  # The row's own cells are already in `cells`; the rows filled in before it add one copy each.
  def handle_event(:end_element, "row", state) do
    built = max(state.current_row - state.expected_row, 0) + 1
    rows = state.rows + built
    cells = state.cells + (built - 1) * state.row_len

    if rows > state.budget.rows or cells > state.budget.cells,
      do: {:stop, :too_large},
      else: {:ok, %{state | rows: rows, cells: cells, expected_row: state.current_row + 1}}
  end

  def handle_event(_event, _data, state), do: {:ok, state}

  # The cells between the expected column and the cell's column are filled in (ref at most
  # 10 bytes here, so `CellReference.parse/1` is cheap).
  defp count_cell(state, ref, attributes) do
    state =
      case ref && XlsxReader.CellReference.parse(ref) do
        {column, _row} ->
          omitted = max(column - state.expected_column, 0)

          %{
            state
            | row_len: state.row_len + omitted,
              cells: state.cells + omitted,
              expected_column: column + 1
          }

        _ ->
          state
      end

    if state.cells > state.budget.cells,
      do: {:stop, :too_large},
      else:
        {:ok, %{state | cell_ref: ref, cell_type: last_attr(attributes, "t", state.cell_type)}}
  end

  # The reader's `String.to_integer/1` and `:array.set/3` on a shared formula's index.
  defp shared_index(si, state) when is_binary(si) and byte_size(si) <= @max_index_bytes do
    index = String.to_integer(si)

    if index >= 0 and index < state.budget.cells,
      do: {:ok, state},
      else: {:stop, :too_large}
  rescue
    ArgumentError -> {:stop, :unreadable}
  end

  defp shared_index(si, _state) when is_binary(si), do: {:stop, :too_large}
  defp shared_index(_si, _state), do: {:stop, :unreadable}

  defp oversize?(value), do: is_binary(value) and byte_size(value) > @max_index_bytes

  # A parse error leaves no state behind, so whether a row or cell came before it is read from the
  # bytes. A part that does not start with `<` (after a BOM and white space) fails on its first
  # byte, before any event (a picture, a binary part); otherwise any `<row` or `<c` tag
  # (unprefixed, as the reader matches them) counts. Pictures are thus never refused for a chance `<c ` byte pair.
  defp contains_sheet_element?(xml),
    do: Regex.match?(~r/\A(\xEF\xBB\xBF)?\s*</, xml) and Regex.match?(~r/<(row|c)[\s\/>]/, xml)

  defp first_attr(attributes, name) do
    Enum.find_value(attributes, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp last_attr(attributes, name, default) do
    Enum.reduce(attributes, default, fn
      {^name, value}, _acc -> value
      _, acc -> acc
    end)
  end
end
