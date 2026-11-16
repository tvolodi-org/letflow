defmodule Letflow.Modules.Stock.StockWorkbook do
  @moduledoc """
  REQ-865 / GH #4579: the whole-stock workbook in the Qoimeks import layout.

  Builds a single `.xlsx` workbook whose sheet "Остатки YYYY-MM-DD" matches the layout
  Qoimeks's importer reads: columns A–J per the headers below, one row per item/place/unit
  with a non-zero balance (plus one placeholder row for items whose balance is entirely zero
  or whose only place is their usual place with nothing there).

  Row order: items sorted by code (byte order); within an item, the usual place first
  (quantity 0 when nothing is stored there), then other places by place code ascending; an
  item with no usual place and no balance gets one row with empty D–H and quantity 0.

  Reader rule: only a tenant-wide reader (`authorized.scope == :all`) may download this file.
  A scoped reader would see some items as "zero stock" even when their hidden units hold
  stock, so it gets the same `{:error, :not_found}` as a path that does not exist.

  Snapshot rule: the first balance page is read at `:latest`, which fixes the posting counter
  N; every later page is read at N, so the whole file is one consistent moment.

  G3 amendment (task T-2082): the usual place is `catalog_item.default_location_id` (the
  single optional default location per item, Qoimeks parity G3). Column G (second place) is
  always empty; REQ-841's second_location_id was not built.

  A balance whose sku has no catalog item (it cannot be looked up) has no article or name to
  write, so it is left out of the file; this is the only case where a quantity is not listed.

  Cap: more than 10 000 data rows is `{:error, :workbook_too_large}` and no file is returned.
  Test seams: `:stock_workbook_max_rows` (can only lower the cap) and
  `:stock_workbook_balance_page` (can only lower the page size).

  Unit of measure in column I: the balance row's `unit_ref` is used as the UOM code when it
  is a human-readable code (e.g. "pcs"); when it is a UUID (a catalog_uom record_id), it is
  resolved via `CatalogItems.lookup/2` to get the code. Zero-quantity rows use the item's
  `base_uom_id` (resolved the same way).
  """

  alias Elixlsx.{Sheet, Workbook}
  alias Letflow.Documents.XlsxStyle
  alias Letflow.Identity.TenantTimezone
  alias Letflow.Ledger
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Codes
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.CountPaperworkSource

  @balance_page 200
  @max_rows 10_000

  # The column headers of the Qoimeks import layout (importer.go).
  @headers [
    "Артикул",
    "Номенклатура",
    "Конечный остаток",
    "Зона",
    "Стеллаж",
    "Полка",
    "Второе место",
    "Место",
    "Ед. изм.",
    "Коды / Codes"
  ]

  # Place code pattern from Qoimeks importer.go: D zone letter + E rack letter (optional) +
  # F shelf number (digits).  Codes that do not match leave D, E, F empty.
  @place_re ~r/\A([A-Z])([A-Z]?)(\d*)\z/

  # Used to detect UUID unit_refs so they can be resolved to catalog_uom codes.
  @uuid_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc """
  Builds the whole-stock workbook for the tenant whose ledger principal is `authorized`.
  Returns `{:ok, {filename, bytes}}` or `{:error, reason}`.

  Reasons: `:not_found` (scoped reader), `:workbook_too_large`, `:invalid_timezone`,
  `:xlsx_write_failed`.
  """
  @spec build(map()) ::
          {:ok, {String.t(), binary()}}
          | {:error, :not_found | :workbook_too_large | :invalid_timezone | :xlsx_write_failed}
  def build(authorized) do
    with {:ok, authorized} <- full_reader(authorized),
         zone = CountPaperworkSource.zone(authorized.tenant_id),
         {:ok, today} <- TenantTimezone.today(zone),
         {:ok, _n, raw_rows} <- read_all_balances(authorized),
         {:ok, data_rows} <- build_rows(authorized.prefix, raw_rows) do
      render(today, data_rows)
    end
  end

  # --- reader check ---------------------------------------------------------------------------

  defp full_reader(%{scope: :all} = authorized), do: {:ok, authorized}
  defp full_reader(_other), do: {:error, :not_found}

  # --- balance reading ------------------------------------------------------------------------

  # Reads all balance pages at one cutoff.  The first page is read at :latest, which returns
  # the cutoff_seq N; every later page is read at N.  Returns {:ok, n, [row]} or :error.
  defp read_all_balances(authorized) do
    case read_pages(authorized, nil, nil, []) do
      {:ok, nil, rows} -> {:ok, 0, rows}
      other -> other
    end
  end

  defp read_pages(authorized, n, cursor, acc) do
    basis = {:posting_seq, n || :latest}

    page =
      if cursor,
        do: %{limit: balance_page(), cursor: cursor},
        else: %{limit: balance_page()}

    case Ledger.balances(authorized, basis, %{}, page) do
      {:ok, %{cutoff_seq: seq, rows: rows, next_cursor: next}} ->
        n = n || seq
        new_acc = Enum.reduce(rows, acc, &[&1 | &2])

        if next,
          do: read_pages(authorized, n, next, new_acc),
          else: {:ok, n, new_acc}

      {:error, _} ->
        {:error, :ledger_read_failed}
    end
  end

  # Test seam: balance page can only be lowered.
  defp balance_page do
    case Application.get_env(:letflow, :stock_workbook_balance_page) do
      n when is_integer(n) and n in 1..@balance_page -> n
      _ -> @balance_page
    end
  end

  # --- row building ---------------------------------------------------------------------------

  defp build_rows(prefix, raw_rows) do
    # Aggregate: sum quantity over {sku, location, unit_ref} across org_unit/responsible/lot.
    # Ledger balance row k-slot order: [sku, location, org_unit, responsible, lot].
    # unit_ref in a balance row is the UOM code string (e.g. "шт"), not a record id.
    agg = aggregate_balances(raw_rows)

    # Collect all item IDs: active materials + any item holding a non-zero balance.
    balance_skus = agg |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    active_materials = list_active_materials(prefix)
    all_item_ids = Enum.uniq(active_materials ++ balance_skus)

    # Fetch item data; sort by code (byte order).
    items =
      all_item_ids
      |> Enum.map(&{&1, item_data(prefix, &1)})
      |> Enum.reject(fn {_id, item} -> is_nil(item) end)
      |> Enum.sort_by(fn {_id, item} -> item.code end)

    rows =
      Enum.flat_map(items, fn {item_id, item} ->
        item_rows(prefix, item_id, item, agg)
      end)

    if length(rows) > max_rows(),
      do: {:error, :workbook_too_large},
      else: {:ok, rows}
  end

  # Aggregate raw ledger rows: sum quantity over {sku, location, unit_ref}.
  defp aggregate_balances(raw_rows) do
    Enum.reduce(raw_rows, %{}, fn row, acc ->
      [sku, loc | _] = row.k
      key = {sku, loc, row.unit_ref}
      Map.update(acc, key, Decimal.new(row.quantity), &Decimal.add(&1, Decimal.new(row.quantity)))
    end)
  end

  # Active catalog_items of kind "material". Returns list of record ids.
  defp list_active_materials(prefix) do
    case CatalogItems.list_active(prefix) do
      {:ok, items} ->
        items
        |> Enum.filter(&(&1["kind"] == "material"))
        |> Enum.map(& &1["record_id"])

      _ ->
        []
    end
  end

  # Fetch one catalog item's display data. Returns nil when not found.
  defp item_data(prefix, item_id) do
    case CatalogItems.lookup(prefix, item_id) do
      {:ok, item} ->
        %{
          code: item["code"],
          name: item["name"],
          base_uom_id: item["base_uom_id"],
          default_location_id: item["default_location_id"]
        }

      _ ->
        nil
    end
  end

  # Build the data rows for one item.
  defp item_rows(prefix, item_id, item, agg) do
    usual_loc_id = item.default_location_id
    codes_j = codes_str(prefix, item_id)

    # Aggregate rows for this item, keeping only non-zero quantities.
    # Key: {location_id, unit_code}.
    item_agg =
      agg
      |> Enum.filter(fn {{sku, _loc, _unit}, _qty} -> sku == item_id end)
      |> Enum.reject(fn {_key, qty} -> Decimal.compare(qty, 0) == :eq end)
      |> Map.new(fn {{_sku, loc, unit}, qty} -> {{loc, unit}, qty} end)

    # Other places: balance places that are not the usual place, sorted by location code.
    other_place_ids =
      item_agg
      |> Map.keys()
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.reject(&(&1 == usual_loc_id))
      |> Enum.map(&{&1, loc_code(prefix, &1)})
      |> Enum.sort_by(fn {_id, code} -> code end)
      |> Enum.map(&elem(&1, 0))

    has_balance = map_size(item_agg) > 0
    has_usual = not is_nil(usual_loc_id)

    cond do
      not has_balance and not has_usual ->
        # No balance, no usual place: one placeholder row with empty D–H.
        base_uom = base_uom_code(prefix, item)
        [make_row(item.code, item.name, Decimal.new(0), nil, codes_j, base_uom)]

      not has_balance and has_usual ->
        # No balance but has usual place: one row at usual place with quantity 0 and base UOM.
        code = loc_code(prefix, usual_loc_id)
        base_uom = base_uom_code(prefix, item)
        [make_row(item.code, item.name, Decimal.new(0), code, codes_j, base_uom)]

      true ->
        usual_rows =
          if has_usual do
            balance_at_usual =
              Enum.filter(item_agg, fn {{loc, _unit}, _qty} -> loc == usual_loc_id end)

            usual_code = loc_code(prefix, usual_loc_id)

            if balance_at_usual == [] do
              # Usual place has no balance: one row at usual place with quantity 0 and base UOM.
              base_uom = base_uom_code(prefix, item)

              [
                make_row(
                  item.code,
                  item.name,
                  Decimal.new(0),
                  usual_code,
                  codes_j,
                  base_uom
                )
              ]
            else
              Enum.map(balance_at_usual, fn {{_loc, unit_ref}, qty} ->
                uom = uom_code_for(prefix, unit_ref)
                make_row(item.code, item.name, qty, usual_code, codes_j, uom)
              end)
            end
          else
            []
          end

        other_rows =
          Enum.flat_map(other_place_ids, fn loc_id ->
            code = loc_code(prefix, loc_id)

            item_agg
            |> Enum.filter(fn {{loc, _unit}, _qty} -> loc == loc_id end)
            |> Enum.map(fn {{_loc, unit_ref}, qty} ->
              uom = uom_code_for(prefix, unit_ref)
              make_row(item.code, item.name, qty, code, codes_j, uom)
            end)
          end)

        usual_rows ++ other_rows
    end
  end

  # Build one data row (columns A–J).
  # Column G (second place) is always empty (G3 amendment), so it has no parameter.
  defp make_row(article, name, qty, loc_code, codes_j, uom_code) do
    {zone, rack, shelf} = split_place(loc_code)

    [
      article,
      name,
      qty_cell(qty),
      blank_or(zone),
      blank_or(rack),
      shelf_cell(shelf),
      "",
      blank_or(loc_code),
      blank_or(uom_code),
      blank_or(codes_j)
    ]
  end

  # Split a place code into {zone, rack, shelf} using the Qoimeks place pattern.
  # Codes that do not match the pattern (e.g. "WH-01", "?") give {"", "", ""} so D–F are empty.
  defp split_place(nil), do: {"", "", ""}

  defp split_place(code) do
    case Regex.run(@place_re, code, capture: :all_but_first) do
      [zone, rack, shelf] -> {zone, rack, shelf}
      nil -> {"", "", ""}
    end
  end

  # F cell: integer when the shelf is all digits without a leading zero; text otherwise.
  # An empty shelf becomes "" (blank cell).
  defp shelf_cell(""), do: ""

  defp shelf_cell(shelf) do
    cond do
      String.starts_with?(shelf, "0") ->
        shelf

      Regex.match?(~r/\A\d+\z/, shelf) ->
        case Integer.parse(shelf) do
          {n, ""} -> n
          _ -> shelf
        end

      true ->
        shelf
    end
  end

  # Returns "" for nil and empty strings; identity otherwise.  Elixlsx writes "" as an empty
  # cell element (preserving the column index), whereas nil skips the element entirely.
  defp blank_or(nil), do: ""
  defp blank_or(""), do: ""
  defp blank_or(val), do: val

  # Quantity cell: whole-number floats are written as integers so the XML value is "10" not
  # "10.0".  XlsxStyle.cell_quantity handles the 15-significant-digit guard.
  defp qty_cell(%Decimal{} = qty) do
    case XlsxStyle.cell_quantity(qty) do
      f when is_float(f) ->
        i = trunc(f)
        if i * 1.0 == f, do: i, else: f

      other ->
        other
    end
  end

  # Resolve a unit_ref to a UOM code.  When the unit_ref is a catalog_uom record_id (UUID),
  # it is looked up to get the catalog code (which may contain non-ASCII characters such as
  # Cyrillic "шт").  When it is already a plain code token, it is returned as-is.
  defp uom_code_for(prefix, unit_ref) when is_binary(unit_ref) do
    if Regex.match?(@uuid_re, unit_ref) do
      case CatalogItems.lookup(prefix, unit_ref) do
        {:ok, uom} -> uom["code"] || unit_ref
        _ -> unit_ref
      end
    else
      unit_ref
    end
  end

  defp uom_code_for(_prefix, nil), do: nil

  # Resolve base UOM code from the item's base_uom_id (a catalog_uom record id).
  defp base_uom_code(prefix, %{base_uom_id: uom_id}), do: uom_code_for(prefix, uom_id)

  # Location code lookup; nil for a missing or unknown id.
  defp loc_code(_prefix, nil), do: nil

  defp loc_code(prefix, loc_id) do
    case Locations.lookup(prefix, loc_id) do
      {:ok, loc} -> loc["code"]
      _ -> nil
    end
  end

  # Codes for column J: values joined by "; " in value order; nil when no codes.
  defp codes_str(prefix, item_id) do
    case Codes.codes_for(prefix, "catalog_item", item_id) do
      [] -> nil
      codes -> codes |> Enum.map(& &1["value"]) |> Enum.join("; ")
    end
  end

  # Test seam: cap can only be lowered.
  defp max_rows do
    case Application.get_env(:letflow, :stock_workbook_max_rows) do
      n when is_integer(n) and n in 1..@max_rows -> n
      _ -> @max_rows
    end
  end

  # --- xlsx rendering -------------------------------------------------------------------------

  defp render(today, data_rows) do
    date_str = Date.to_iso8601(today)
    sheet_name = "Остатки #{date_str}"
    file_name = "stock-#{date_str}.xlsx"

    header_row = Enum.map(@headers, &[&1, bold: true])

    sheet = %Sheet{name: sheet_name, rows: [header_row | data_rows]}

    workbook = %Workbook{sheets: [XlsxStyle.style(sheet)]}

    case XlsxStyle.write_to_memory(workbook, file_name) do
      {:ok, {_name, binary}} -> {:ok, {file_name, binary}}
      _ -> {:error, :xlsx_write_failed}
    end
  rescue
    _ -> {:error, :xlsx_write_failed}
  end
end
