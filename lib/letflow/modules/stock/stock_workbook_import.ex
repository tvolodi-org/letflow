defmodule Letflow.Modules.Stock.StockWorkbookImport do
  @moduledoc """
  REQ-884 / GH #4607: the check of a Qoimeks-layout balances workbook against the stock of one org
  unit. The check writes nothing (no record, ledger entry, audit entry or document number); the
  load is REQ-885.

  Two halves in one module:

    * `parse/1` is pure: bytes in, `{:ok, %{sheet, rows_read, rows}}` or `{:error, reason}` out.
      The bytes are read only through `Letflow.Entities.XlsxImport.read_text_rows/1` (one parse,
      the same bounded reader and refusals as the record import; this module opens no
      archive itself). Only the first worksheet is read.
    * `check/3` reads the book through `Letflow.Ledger.balances/4` (first page at `:latest` fixes
      the posting counter, later pages at that counter) and answers what a load would change.

  Layout (columns A to J of REQ-865): A article (the `catalog_item` code, trimmed, inner spaces
  collapsed), B name, C quantity, D zone, E rack, F shelf, H place code (read only when D, E and
  F are all empty). G, I and J are not read. Rows before the first row whose cell A is "Артикул"
  are skipped; after it a row with A or B empty is skipped without a remark.

  Normalising (the Qoimeks rules): text is trimmed and runs of white space become one space; zone
  and rack are upper-cased and the Cyrillic letters А В С Е Н К М О Р Т Х become the Latin
  A B C E H K M O P T X; a zone or rack "0" becomes the letter O. A quantity cell loses white
  space, `'` and `’`; when both `,` and `.` occur the one written last is the decimal sign and the
  other is removed; a single `,` or `.` is the decimal sign; several of one sign and none of the
  other are thousands signs. The result must be a decimal of 0 or more with at most 9 decimals.

  Remarks R1 to R11 are Russian texts, see `docs/runbooks/stock-workbook-import.md`.

  Byte bounds (INV-8): before any normalising, a read cell over its byte cap (256; 512 for B; 64
  for C), a total of the read cells over 2 MiB, or more filled rows than the row cap refuses the
  whole file as `:workbook_too_large`. Shared strings make the file smaller than its text.

  Test seams (each can only lower its cap): `:stock_workbook_import_max_rows` (10 000 data rows)
  and `:stock_workbook_import_max_changes` (1000, the line cap of `Documents.Shape`);
  `:stock_workbook_balance_page` (the REQ-865 page seam) is shared.
  """

  alias Letflow.Entities.XlsxImport
  alias Letflow.Ledger
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.Views

  @max_rows 10_000
  # Byte bounds on the cell text, checked before any per-character work (T-2041, INV-8). A shared
  # string is passed by reference, so the inflate cap of the reader does not bound the text.
  @max_cell_bytes 256
  @max_name_bytes 512
  @max_quantity_bytes 64
  @max_header_bytes 64
  @max_total_bytes 2_097_152
  @max_changes 1000
  @balance_page 200
  @header "Артикул"
  @unknown_place "?"

  @lookalikes %{
    "А" => "A",
    "В" => "B",
    "С" => "C",
    "Е" => "E",
    "Н" => "H",
    "К" => "K",
    "М" => "M",
    "О" => "O",
    "Р" => "P",
    "Т" => "T",
    "Х" => "X"
  }

  @type row :: %{
          line: pos_integer(),
          article: String.t(),
          name: String.t(),
          quantity: {:ok, Decimal.t()} | {:error, String.t()},
          zone: String.t(),
          rack: String.t(),
          shelf: String.t(),
          place: String.t(),
          raw_zone: String.t(),
          raw_rack: String.t(),
          raw_shelf: String.t(),
          remarks: [String.t()]
        }

  # --- parse (pure) ---------------------------------------------------------------------------

  @doc """
  Reads the workbook bytes. `{:ok, %{sheet: name, rows_read: n, rows: [row]}}`, or
  `{:error, :xlsx_unreadable | :header_missing | :workbook_too_large}`.
  """
  @spec parse(binary()) ::
          {:ok, %{sheet: String.t(), rows_read: non_neg_integer(), rows: [row()]}}
          | {:error, :xlsx_unreadable | :header_missing | :workbook_too_large}
  def parse(bytes) when is_binary(bytes) do
    with {:ok, sheet, lines} <- read(bytes),
         {:ok, after_header} <- after_header(lines),
         :ok <- bound(after_header),
         data = Enum.filter(after_header, &data_row?/1),
         :ok <- cap(data) do
      {:ok, %{sheet: sheet, rows_read: length(data), rows: Enum.map(data, &to_row/1)}}
    end
  end

  def parse(_other), do: {:error, :xlsx_unreadable}

  defp read(bytes) do
    case XlsxImport.read_text_rows(bytes) do
      {:ok, sheet, lines} -> {:ok, sheet, lines}
      {:error, _} -> {:error, :xlsx_unreadable}
    end
  end

  defp after_header(lines) do
    case Enum.drop_while(lines, fn {_line, cells} -> not header?(cell(cells, 0)) end) do
      [] -> {:error, :header_missing}
      [_header | rest] -> {:ok, rest}
    end
  end

  # A header cell is short: anything longer than the bound is not the header and is never normalised.
  defp header?(text), do: byte_size(text) <= @max_header_bytes and collapse(text) == @header

  # Cheap checks only (byte_size, == ""), before collapse/1: the read cells of the rows after the
  # header are each under their byte cap and under a total cap, and the rows that carry an A and a
  # B cell are counted against the row cap. Otherwise the whole file is refused.
  defp bound(lines) do
    result =
      Enum.reduce_while(lines, {0, 0}, fn {_line, cells}, {total, rows} ->
        read = Enum.take(cells, 8)

        with true <- within_caps?(read),
             sum = total + read_bytes(read),
             true <- sum <= @max_total_bytes do
          {:cont, {sum, rows + if(filled?(read), do: 1, else: 0)}}
        else
          _ -> {:halt, :too_large}
        end
      end)

    case result do
      {_total, rows} -> if rows > max_rows(), do: {:error, :workbook_too_large}, else: :ok
      :too_large -> {:error, :workbook_too_large}
    end
  end

  # Columns A B C D E F (G is not read) H.
  defp within_caps?(cells) do
    cells
    |> Enum.with_index()
    |> Enum.all?(fn {text, index} -> index == 6 or byte_size(text) <= cell_cap(index) end)
  end

  defp cell_cap(1), do: @max_name_bytes
  defp cell_cap(2), do: @max_quantity_bytes
  defp cell_cap(_), do: @max_cell_bytes

  defp read_bytes(cells) do
    cells
    |> Enum.with_index()
    |> Enum.reduce(0, fn {t, i}, acc -> if i == 6, do: acc, else: acc + byte_size(t) end)
  end

  defp filled?(cells), do: byte_size(cell(cells, 0)) > 0 and byte_size(cell(cells, 1)) > 0

  defp data_row?({_line, cells}),
    do: collapse(cell(cells, 0)) != "" and collapse(cell(cells, 1)) != ""

  defp cap(data) do
    if length(data) > max_rows(), do: {:error, :workbook_too_large}, else: :ok
  end

  defp to_row({line, cells}) do
    article = collapse(cell(cells, 0))
    raw_zone = collapse(cell(cells, 3))
    raw_rack = collapse(cell(cells, 4))
    raw_shelf = collapse(cell(cells, 5))
    h = collapse(cell(cells, 7))
    zone = letters(raw_zone)
    rack = letters(raw_rack)

    {place, remarks} =
      if raw_zone == "" and raw_rack == "" and raw_shelf == "" do
        {letters(h), []}
      else
        place = zone <> rack <> raw_shelf

        if changed?(raw_zone, zone) or changed?(raw_rack, rack),
          do: {place, [r11(line, article, raw_zone, raw_rack, raw_shelf, place)]},
          else: {place, []}
      end

    %{
      line: line,
      article: article,
      name: collapse(cell(cells, 1)),
      quantity: quantity(cell(cells, 2)),
      zone: zone,
      rack: rack,
      shelf: raw_shelf,
      place: place,
      raw_zone: raw_zone,
      raw_rack: raw_rack,
      raw_shelf: raw_shelf,
      remarks: remarks
    }
  end

  defp cell(cells, index), do: Enum.at(cells, index) || ""

  # Trim and collapse runs of white space (any Unicode white space) into one space.
  defp collapse(text) when is_binary(text) do
    text |> String.split(~r/[\s\x{00A0}]+/u, trim: true) |> Enum.join(" ")
  end

  # Upper case, Cyrillic look-alikes to Latin, a lone "0" to the letter O.
  defp letters(text) do
    out =
      text
      |> String.upcase()
      |> String.graphemes()
      |> Enum.map_join(&Map.get(@lookalikes, &1, &1))

    if out == "0", do: "O", else: out
  end

  # A case change alone is no remark (importer.go): compare with the upper-cased cell text.
  defp changed?(raw, normalised), do: String.upcase(raw) != normalised

  @doc false
  @spec quantity(String.t()) :: {:ok, Decimal.t()} | {:error, String.t()}
  def quantity(raw) when is_binary(raw) do
    cleaned = String.replace(raw, ~r/[\s\x{00A0}'’]/u, "")

    with {:ok, text} <- separators(cleaned),
         true <- Regex.match?(~r/\A\d+(\.\d{1,9})?\z/, text),
         {:ok, decimal} <- decimal(text) do
      {:ok, decimal}
    else
      _ -> {:error, raw}
    end
  end

  defp decimal(text) do
    case Decimal.parse(text) do
      {%Decimal{} = d, ""} -> {:ok, d}
      _ -> :error
    end
  end

  defp separators(text) do
    commas = count(text, ",")
    dots = count(text, ".")

    cond do
      commas > 0 and dots > 0 ->
        last = last_sign(text)
        other = if last == ",", do: ".", else: ","
        {:ok, text |> String.replace(other, "") |> String.replace(last, ".")}

      commas == 1 ->
        {:ok, String.replace(text, ",", ".")}

      commas > 1 ->
        {:ok, String.replace(text, ",", "")}

      dots > 1 ->
        {:ok, String.replace(text, ".", "")}

      true ->
        {:ok, text}
    end
  end

  defp count(text, sign), do: length(String.split(text, sign)) - 1

  defp last_sign(text) do
    text |> String.graphemes() |> Enum.filter(&(&1 in [",", "."])) |> List.last()
  end

  # --- remarks --------------------------------------------------------------------------------

  defp prefix(line), do: "строка #{line}: "

  defp r11(line, a, zone, rack, shelf, code),
    do: ~s(#{prefix(line)}#{a}: место "#{zone}" "#{rack}" #{shelf} прочитано как #{code})

  @doc false
  def remark(:r1, line, a, raw),
    do:
      ~s(#{prefix(line)}#{a}: остаток "#{raw}" не является количеством. Остатки этого товара в системе не изменяются)

  def remark(:r2, line, a, {code, sum}),
    do: "#{prefix(line)}#{a}: место #{code} указано повторно, остатки сложены: #{sum}"

  def remark(:r3, line, a, {zone, rack, shelf}),
    do:
      ~s(#{prefix(line)}#{a}: в месте "#{zone}" "#{rack}" "#{shelf}" не указана зона. Остатки этого товара в системе не изменяются)

  def remark(:r4, line, a, q),
    do: ~s(#{prefix(line)}#{a}: остаток #{q} без места, записан в место "?")

  def remark(:r5, line, a, q),
    do:
      "#{prefix(line)}#{a}: остаток #{q} без места. Остатки этого товара в системе не изменяются"

  def remark(:r6, line, a, code),
    do:
      "#{prefix(line)}#{a}: место #{code} не найдено. Остатки этого товара в системе не изменяются"

  def remark(:r7, line, a, nil),
    do:
      "#{prefix(line)}#{a}: остаток ведётся отдельно по подразделениям, ответственным, партиям или единицам. Остатки этого товара в системе не изменяются"

  def remark(:r8, line, a, nil), do: "#{prefix(line)}#{a}: артикул не найден, строка пропущена"

  def remark(:r9, line, a, nil),
    do:
      "#{prefix(line)}#{a}: товар учитывается по партиям или серийным номерам. Остатки этого товара в системе не изменяются"

  def remark(:r10, line, a, name),
    do: ~s(#{prefix(line)}#{a}: артикул повторяется с другим названием "#{name}". Остатки сложены)

  # --- check ----------------------------------------------------------------------------------

  @doc """
  Checks the workbook `bytes` against the stock of `org_unit_id` for the tenant of `authorized`
  (a tenant-wide `Letflow.Ledger.authorize/3` result; the router refuses a scoped reader before
  this runs). Writes nothing.

  Returns `{:ok, answer}` with string keys `sheet`, `rows_read`, `remarks`, `changes`,
  `unchanged_count`, `too_many_changes`, or `{:error, reason}` (`:xlsx_unreadable`,
  `:header_missing`, `:workbook_too_large`, `:ledger_read_failed`).
  """
  @spec check(map(), String.t(), binary()) :: {:ok, map()} | {:error, atom()}
  def check(%{prefix: prefix} = authorized, org_unit_id, bytes) do
    with {:ok, parsed} <- parse(bytes),
         {:ok, book} <- read_book(authorized) do
      items = item_index(prefix)
      locations = location_index(prefix)
      {:ok, build(parsed, org_unit_id, prefix, items, locations, book)}
    end
  end

  defp item_index(prefix) do
    case CatalogItems.list_active(prefix) do
      {:ok, items} -> Map.new(items, &{&1["code"], &1})
      _ -> %{}
    end
  end

  defp location_index(prefix) do
    case Locations.list_active(prefix) do
      {:ok, nodes} ->
        nodes
        |> Enum.filter(&(&1["entity_type"] == "location_node"))
        |> Map.new(&{&1["code"], &1["record_id"]})

      _ ->
        %{}
    end
  end

  # One chain of balance pages, first at :latest (fixes N), the rest at N. Grouped by item.
  defp read_book(authorized) do
    case read_pages(authorized, nil, nil, []) do
      {:ok, rows} -> {:ok, Enum.group_by(rows, & &1.sku)}
      error -> error
    end
  end

  defp read_pages(authorized, n, cursor, acc) do
    page = if cursor, do: %{limit: balance_page(), cursor: cursor}, else: %{limit: balance_page()}

    case Ledger.balances(authorized, {:posting_seq, n || :latest}, %{}, page) do
      {:ok, %{cutoff_seq: seq, rows: rows, next_cursor: next}} ->
        acc = Enum.reduce(rows, acc, &[Views.stock_balance(&1) | &2])
        if next, do: read_pages(authorized, n || seq, next, acc), else: {:ok, acc}

      {:error, _} ->
        {:error, :ledger_read_failed}
    end
  end

  defp balance_page do
    case Application.get_env(:letflow, :stock_workbook_balance_page) do
      n when is_integer(n) and n in 1..@balance_page -> n
      _ -> @balance_page
    end
  end

  defp build(parsed, org_unit_id, prefix, items, locations, book) do
    ctx = %{
      unit: org_unit_id,
      prefix: prefix,
      locs: locations,
      book: book,
      uoms: uom_codes(parsed.rows, items, prefix)
    }

    results =
      parsed.rows
      |> group_by_article()
      |> Enum.map(fn {article, rows} -> process(article, rows, Map.get(items, article), ctx) end)

    changes = Enum.flat_map(results, & &1.changes)

    %{
      "sheet" => parsed.sheet,
      "rows_read" => parsed.rows_read,
      "remarks" =>
        results
        |> Enum.flat_map(& &1.remarks)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {line, text} -> %{"row" => line, "text" => text} end),
      "changes" => changes,
      "unchanged_count" => results |> Enum.map(& &1.unchanged) |> Enum.sum(),
      "too_many_changes" => length(changes) > max_changes()
    }
  end

  # The code of each base unit of the articles in the file, one read per unit (not per balance row).
  defp uom_codes(rows, items, prefix) do
    rows
    |> Enum.map(&get_in(items, [&1.article, "base_uom_id"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(fn id ->
      case CatalogItems.lookup(prefix, id) do
        {:ok, uom} -> {id, uom["code"]}
        _ -> {id, nil}
      end
    end)
  end

  defp group_by_article(rows) do
    order = rows |> Enum.map(& &1.article) |> Enum.uniq()
    by = Enum.group_by(rows, & &1.article)
    Enum.map(order, &{&1, Map.fetch!(by, &1)})
  end

  defp left_out(remarks), do: %{changes: [], remarks: remarks, unchanged: 0}

  # Per article, in file order, the first rule that applies wins (REQ-884 description a to g).
  defp process(article, rows, nil, _ctx) do
    left_out(for(r <- rows, do: {r.line, remark(:r8, r.line, article, nil)}))
  end

  defp process(article, rows, item, ctx) do
    first = hd(rows)
    r11 = for r <- rows, text <- r.remarks, do: {r.line, text}
    held = Map.get(ctx.book, item["record_id"], [])
    bad_qty = Enum.filter(rows, &match?({:error, _}, &1.quantity))

    cond do
      item["tracking_policy"] in ["lot", "serial", "expiry"] ->
        left_out([{first.line, remark(:r9, first.line, article, nil)}])

      bad_qty != [] ->
        left_out(
          r11 ++
            for(r <- bad_qty, do: {r.line, remark(:r1, r.line, article, elem(r.quantity, 1))})
        )

      true ->
        placed(article, rows, item, held, r11, ctx)
    end
  end

  defp qty(r), do: elem(r.quantity, 1)
  defp positive?(r), do: Decimal.compare(qty(r), 0) == :gt
  defp no_place?(r), do: r.place == ""

  defp placed(article, rows, item, held, r11, ctx) do
    unplaced = Enum.filter(rows, &(no_place?(&1) and positive?(&1)))
    unzoned = Enum.filter(rows, &((&1.rack != "" or &1.shelf != "") and not zone_letter?(&1)))
    unknown = Enum.filter(rows, &(not no_place?(&1) and not Map.has_key?(ctx.locs, &1.place)))

    cond do
      unplaced != [] and not Map.has_key?(ctx.locs, @unknown_place) ->
        left_out(
          r11 ++ for(r <- unplaced, do: {r.line, remark(:r5, r.line, article, text(qty(r)))})
        )

      unzoned != [] ->
        left_out(
          r11 ++
            for(
              r <- unzoned,
              do: {r.line, remark(:r3, r.line, article, {r.raw_zone, r.raw_rack, r.raw_shelf})}
            )
        )

      unknown != [] ->
        left_out(r11 ++ for(r <- unknown, do: {r.line, remark(:r6, r.line, article, r.place)}))

      Enum.any?(held, &(nonzero?(&1) and not plain?(&1, item, ctx))) ->
        first = hd(rows)
        left_out(r11 ++ [{first.line, remark(:r7, first.line, article, nil)}])

      true ->
        compare(article, rows, item, held, r11, ctx)
    end
  end

  defp zone_letter?(r), do: Regex.match?(~r/\A[A-Z]/, r.zone)

  # The ledger's unit_ref is the unit's id or its code.
  defp base_unit?(row, item, ctx) do
    code = Map.get(ctx.uoms, item["base_uom_id"])
    row.unit_ref == item["base_uom_id"] or (code != nil and code == row.unit_ref)
  end

  defp plain?(row, item, ctx) do
    row.org_unit == ctx.unit and blank?(row.responsible) and blank?(row.lot) and
      base_unit?(row, item, ctx)
  end

  defp blank?(v), do: v in [nil, ""]

  defp nonzero?(row), do: Decimal.compare(Decimal.new(row.quantity), 0) != :eq

  defp compare(article, rows, item, held, r11, ctx) do
    # Rows that name a place (or an amount with no place, which goes to "?") add up per place.
    contributing =
      for r <- rows,
          not (no_place?(r) and not positive?(r)),
          do: {r, if(no_place?(r), do: @unknown_place, else: r.place)}

    {targets, firsts, repeated} =
      Enum.reduce(contributing, {%{}, %{}, []}, fn {r, code}, {t, f, rep} ->
        if Map.has_key?(t, code),
          do: {Map.update!(t, code, &Decimal.add(&1, qty(r))), f, [{r, code} | rep]},
          else: {Map.put(t, code, qty(r)), Map.put(f, code, r.line), rep}
      end)

    r2 =
      for {r, code} <- Enum.reverse(repeated),
          do: {r.line, remark(:r2, r.line, article, {code, text(Map.fetch!(targets, code))})}

    r4 =
      for r <- rows,
          no_place?(r),
          positive?(r),
          do: {r.line, remark(:r4, r.line, article, text(qty(r)))}

    name = hd(rows).name
    r10 = for r <- tl(rows), r.name != name, do: {r.line, remark(:r10, r.line, article, r.name)}

    by_loc =
      for row <- held, plain?(row, item, ctx), nonzero?(row), into: %{} do
        {row.location, Decimal.new(row.quantity)}
      end

    id_code = Map.new(ctx.locs, fn {code, id} -> {id, code} end)
    book_places = by_loc |> Map.keys() |> Enum.map(&Map.get(id_code, &1, &1))

    {changes, unchanged} =
      (Map.keys(targets) ++ book_places)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce({[], 0}, fn code, {acc, same} ->
        book = Map.get(by_loc, Map.get(ctx.locs, code, code), Decimal.new(0))
        target = Map.get(targets, code, Decimal.new(0))

        case {Decimal.compare(target, book), Decimal.compare(book, 0)} do
          {:eq, :eq} -> {acc, same}
          {:eq, _} -> {acc, same + 1}
          _ -> {[change(article, item, code, firsts, book, target) | acc], same}
        end
      end)

    %{changes: Enum.reverse(changes), remarks: r11 ++ r2 ++ r4 ++ r10, unchanged: unchanged}
  end

  defp change(article, item, code, firsts, book, target) do
    %{
      "row" => Map.get(firsts, code),
      "item_code" => article,
      "item_name" => item["name"],
      "place_code" => code,
      "book_quantity" => text(book),
      "file_quantity" => text(target),
      "difference" => text(Decimal.sub(target, book))
    }
  end

  defp text(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp max_rows do
    case Application.get_env(:letflow, :stock_workbook_import_max_rows) do
      n when is_integer(n) and n in 1..@max_rows -> n
      _ -> @max_rows
    end
  end

  defp max_changes do
    case Application.get_env(:letflow, :stock_workbook_import_max_changes) do
      n when is_integer(n) and n in 1..@max_changes -> n
      _ -> @max_changes
    end
  end
end
