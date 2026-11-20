defmodule Letflow.Modules.Stock.OldAppReads do
  @moduledoc """
  REQ-859 (decision 0091 section 7): the three read calls of the old Qoimeks app, answered in the
  Qoimeks shape from the stock read functions the contract table names. No write of stock, ledger
  or catalog data happens here; the only rows written are the uuid-to-integer mappings of
  `Letflow.SharedStockAccess.IntIds`.

  Every function takes an authorized ledger read value (`Letflow.Ledger.authorize_shared_access/3`,
  tenant-wide read, built by `Letflow.Routers.SharedStockAccess`, not here: Rule 8 lets a module file
  call only the ledger reads) or the tenant `prefix` the router proved; the tenant never comes from
  a request value (INV-1). The router reaches this module only through `Letflow.Modules.Catalog`
  (`old_app_catalog/1`, `old_app_balances/2`, `old_app_movements/2`), the one core file the boundary
  check lets name a module file.

  * `catalog/1` (REQ-908, the old app's `Catalog`): an object `%{skus: [...], locations: [...]}`.
    A sku row (every active catalog item, sorted by code): `id` (the sku integer), `code`, `name`,
    `unit` (code of the base unit of measure, `""` when there is none: the app reads it as text that is
    never null), `location_id` (the place integer of the item's `default_location_id`; the key is absent
    when the item has none or that place is not active) and `barcode` (the first code value assigned to
    the item; the key is absent when there is none). The second place (`alt_location_id`) is not served
    (owner pruning D-150). A location row (every active `location_node`, sorted by code): `id` (its
    integer in `location_node_int_ids`, assigned here when missing), `code`, `name`.
  * `balances/2`: one row per sku and place with a non-zero quantity (summed over org unit,
    responsible, lot and unit of measure): exactly `sku_id`, `location_id`, `location_code`, `qty`,
    sorted by place code (then sku integer). Optional integer filters `sku_id`, `location_id`.
    One place has one integer everywhere: in a sku's `location_id`, a `locations` row, and balance and
    movement rows.
  * `code_lookup/2` (REQ-910, the old app's `CodeInfo`): the scan to find, `GET /api/codes/lookup?code=`.
    The trimmed `code` is resolved by `Codes.resolve/2` (exact, case-sensitive) on the proved tenant's
    schema only. An `assigned` code of an active `catalog_item` (`object_type` `sku`) or `location_node`
    (`location`) whose scope declaration is `:tenant_wide` answers exactly `object_type`, `object_id`
    (the integer of the catalog), `object_code`, `object_name` and `code`; every other outcome is one
    `{:error, :not_found}` and a blank or missing `code` is `{:error, :code_required}`. Read only: no
    code, assignment, audit, stock or ledger row is written, only a missing `IntIds` mapping. The legacy
    plain barcode of an item is found because it enters Letflow as a code assigned to the item (the code
    imports), not as an item field.
  * `movements/2` (REQ-909, the old app's `Movement`): the newest `limit` ledger entries (50 when `limit`
    is missing or outside 1..500), newest first, optional integer filters `sku_id`, `location_id`. A row
    (also the answer of a post and of a reverse, see `OldAppWrites`): `id` (TEXT, the digits of the
    entry's integer in `movement_int_ids`), `kind` (`receipt`, `issue`, `transfer`; any other document
    type is `adjustment`), `sku_id, sku_code, sku_name, unit` (`""` when none), `location_id,
    location_code`, `qty` (positive), `operator` (`""` when the movement has no typed name),
    `created_at` (ISO 8601 UTC) and `balances`. A count row (cause `count_set`: an old-address count, a
    web quick count or a workbook load) has `qty` = the `counted_quantity` of the count document line
    that movement posts, 0 included (REQ-912; a reversal of it keeps the difference taken back), and
    its `operator` is the typed name of the count's submit task when a shared access actor completed it.
    A count equal to the book has no ledger entry: its row (`confirmed_count_row/2`) is answered by
    the post only and is not in this list. A transfer is one row: `location_*` is the place whose
    leg decreases, `to_location_id` and `to_location_code` the place whose leg increases (only a transfer
    has them). A reversal row takes kind, places and quantity from the movement it reverses and has
    `reverses` (that movement's id text); a reversed movement has `reversed_by`. `balances` is `[]` in the
    history list, as on the old server; in the answer of a post or reverse (`movement/2`,
    `movements_of_document/2`) it holds one entry per (item, place) the movement touched, `sku_id,
    location_id, location_code, qty`, sorted by `location_id`, with `qty` read at the movement's own
    posting number, so a replay repeats the same values.

  Quantities are JSON numbers (the old app reads them as numbers). An unknown integer filter
  answers an empty list. A malformed filter is `{:error, :invalid_filter}` (the router answers 400).

  Known QA limits (security review, REQ-859): the catalog and balances reads do one name or code
  lookup per row (N+1), and one movements request can widen its window up to 20 times at `@page`
  rows each; the per-credential request limit (60 a minute) bounds the load. A cap on total rows
  or pages per request is needed before production (INV-8).
  """

  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Ledger
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Codes
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Modules.Stock.Documents.QuickCountPosting
  alias Letflow.SharedStockAccess.IntIds

  @page 200
  @default_limit 50
  @max_limit 500

  # REQ-910: the two target types the old app knows (a lot is not found), with the object type it
  # reads, the `IntIds` kind of the id it shows and the module that reads the record.
  @lookup_targets %{
    "catalog_item" => {"sku", :sku, CatalogItems},
    "location_node" => {"location", :location, Locations}
  }

  @doc "The Qoimeks catalog (`skus` and `locations`) of the tenant schema `prefix`."
  @spec catalog(String.t()) ::
          {:ok, %{skus: [map()], locations: [map()]}} | {:error, :unavailable}
  def catalog(prefix) do
    with {:ok, items} <- CatalogItems.list_active(prefix),
         {:ok, places} <- Locations.list_active(prefix) do
      loc_ids = IntIds.assign(prefix, :location, Enum.map(places, & &1["record_id"]))
      sku_ids = IntIds.assign(prefix, :sku, Enum.map(items, & &1["record_id"]))

      {:ok,
       %{
         skus: sku_rows(prefix, items, sku_ids, loc_ids),
         locations: location_rows(places, loc_ids)
       }}
    else
      _other -> {:error, :unavailable}
    end
  end

  defp sku_rows(prefix, items, sku_ids, loc_ids) do
    items
    |> Enum.flat_map(&sku_row(prefix, &1, sku_ids, loc_ids))
    |> Enum.sort_by(&{&1.code, &1.id})
  end

  # One catalog row of an item record as a one-element list, or `[]` when it has no integer id.
  defp sku_row(prefix, item, sku_ids, loc_ids) do
    case Map.fetch(sku_ids, item["record_id"]) do
      {:ok, int} ->
        row = %{
          id: int,
          code: item["code"],
          name: item["name"],
          unit: uom_code(prefix, item["base_uom_id"])
        }

        [
          row
          |> put_present(:location_id, Map.get(loc_ids, item["default_location_id"]))
          |> put_present(:barcode, barcode(prefix, item["record_id"]))
        ]

      :error ->
        []
    end
  end

  @doc """
  K10 / REQ-911: the catalog rows (the same row `catalog/1` builds) of the given item record ids, in
  the given order, for the voice answer. An id that is not a live active item of the tenant schema
  `prefix` is left out; `location_id` is set only for a default place that is active, as in the
  catalog. Integer ids are assigned when missing (the only write, as in `catalog/1`).
  """
  @spec sku_rows_for(String.t(), [String.t()]) :: [map()]
  def sku_rows_for(prefix, record_ids) when is_binary(prefix) and is_list(record_ids) do
    items =
      Enum.flat_map(record_ids, fn id ->
        case CatalogItems.lookup(prefix, id) do
          {:ok, %{"entity_type" => "catalog_item", "active" => true} = record} -> [record]
          _other -> []
        end
      end)

    default_ids = items |> Enum.map(& &1["default_location_id"]) |> Enum.filter(&is_binary/1)

    active_defaults =
      case default_ids do
        [] ->
          []

        _some ->
          case Locations.list_active(prefix) do
            {:ok, places} ->
              active = MapSet.new(places, & &1["record_id"])
              Enum.filter(default_ids, &MapSet.member?(active, &1))

            _unavailable ->
              []
          end
      end

    sku_ids = IntIds.assign(prefix, :sku, Enum.map(items, & &1["record_id"]))
    loc_ids = IntIds.assign(prefix, :location, active_defaults)
    Enum.flat_map(items, &sku_row(prefix, &1, sku_ids, loc_ids))
  end

  @doc """
  K10 / REQ-911: the catalog row `%{id, code, name}` of one active place record id (the integer id is
  assigned when missing), or `nil` when it is not an active place of the tenant schema `prefix`.
  """
  @spec location_row_for(String.t(), String.t()) :: map() | nil
  def location_row_for(prefix, record_id) when is_binary(prefix) do
    with {:ok, %{"entity_type" => "location_node", "active" => true} = place} <-
           Locations.lookup(prefix, record_id),
         %{} = ids <- IntIds.assign(prefix, :location, [place["record_id"]]),
         {:ok, int} <- Map.fetch(ids, place["record_id"]) do
      %{id: int, code: place["code"], name: place["name"]}
    else
      _other -> nil
    end
  end

  defp location_rows(places, loc_ids) do
    places
    |> Enum.flat_map(fn place ->
      case Map.fetch(loc_ids, place["record_id"]) do
        {:ok, int} -> [%{id: int, code: place["code"], name: place["name"]}]
        :error -> []
      end
    end)
    |> Enum.sort_by(&{&1.code, &1.id})
  end

  defp put_present(row, _key, nil), do: row
  defp put_present(row, key, value), do: Map.put(row, key, value)

  @doc """
  The scan lookup of the old app, `GET /api/codes/lookup?code=` (REQ-910, the old app's `CodeInfo`).
  `params` is the query map. The `code` value is trimmed (as the old server does); a missing,
  non-text or blank one is `{:error, :code_required}`. It is resolved with `Codes.resolve/2` on the
  `prefix` of the proved tenant only (INV-1), an exact, case-sensitive match. Found only when the
  code is `assigned` to a `catalog_item` or a `location_node` whose scope declaration is
  `:tenant_wide` and the target record is live and active: the answer is `%{object_type, object_id,
  object_code, object_name, code}` with `object_type` `"sku"` or `"location"` and `object_id` the same
  integer the catalog gives the item or place (assigned here when missing, the only write). Every
  other outcome (unknown, not assigned, retired, conflicting, a lot, an inactive or other-type
  target, a value the codes module cannot store) is the one `{:error, :not_found}` (INV-5).
  """
  @spec code_lookup(String.t(), map()) ::
          {:ok, map()} | {:error, :code_required | :not_found}
  def code_lookup(prefix, params) when is_binary(prefix) and is_map(params) do
    case code_param(params) do
      nil -> {:error, :code_required}
      text -> resolve_code(prefix, text)
    end
  end

  defp code_param(params) do
    case Map.get(params, "code") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _other ->
        nil
    end
  end

  defp resolve_code(prefix, text) do
    with {:ok, %{"status" => "assigned", "target_type" => type, "target_id" => id} = code} <-
           Codes.resolve(prefix, text),
         {object_type, kind, module} <- Map.get(@lookup_targets, type),
         :tenant_wide <- ScopeDeclaration.for_type(type, prefix),
         {:ok, %{"entity_type" => ^type, "active" => true, "record_id" => record_id} = target} <-
           module.lookup(prefix, id),
         %{^record_id => int} <- IntIds.assign(prefix, kind, [record_id]) do
      {:ok,
       %{
         object_type: object_type,
         object_id: int,
         object_code: target["code"],
         object_name: target["name"],
         code: code["value"]
       }}
    else
      _not_found -> {:error, :not_found}
    end
  end

  @doc "The Qoimeks balances list."
  @spec balances(map(), map()) ::
          {:ok, [map()]} | {:error, :invalid_filter | :unavailable}
  def balances(authorized, params) do
    with {:ok, filters} <- int_filters(authorized.prefix, params) do
      case filters do
        :empty -> {:ok, []}
        slots -> read_balances(authorized, slots)
      end
    end
  end

  @doc "The Qoimeks movements list, newest first."
  @spec movements(map(), map()) ::
          {:ok, [map()]} | {:error, :invalid_filter | :unavailable}
  def movements(authorized, params) do
    limit = movement_limit(Map.get(params, "limit"))

    with {:ok, filters} <- int_filters(authorized.prefix, params) do
      case filters do
        :empty -> {:ok, []}
        slots -> read_movements(authorized, slots, limit)
      end
    end
  end

  @doc "The limit rule of the old app: 50 when missing, not a whole number or outside 1..500."
  @spec movement_limit(term()) :: pos_integer()
  def movement_limit(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n in 1..@max_limit -> n
      _other -> @default_limit
    end
  end

  def movement_limit(_other), do: @default_limit

  # -- filters ------------------------------------------------------------------------------------

  # `{:ok, %{slot => uuid}}`, `{:ok, :empty}` when an integer names nothing (so the answer is empty).
  defp int_filters(prefix, params) do
    with {:ok, sku} <- int_param(params, "sku_id"),
         {:ok, loc} <- int_param(params, "location_id") do
      resolve_filters(prefix, [{"sku", :sku, sku}, {"location", :location, loc}], %{})
    end
  end

  defp resolve_filters(_prefix, [], acc), do: {:ok, acc}

  defp resolve_filters(prefix, [{_slot, _kind, nil} | rest], acc),
    do: resolve_filters(prefix, rest, acc)

  defp resolve_filters(prefix, [{slot, kind, int} | rest], acc) do
    case IntIds.uuid_for(prefix, kind, int) do
      nil -> {:ok, :empty}
      uuid -> resolve_filters(prefix, rest, Map.put(acc, slot, uuid))
    end
  end

  defp int_param(params, key) do
    case Map.fetch(params, key) do
      :error ->
        {:ok, nil}

      {:ok, text} when is_binary(text) ->
        case Integer.parse(text) do
          {n, ""} when n > 0 -> {:ok, n}
          _other -> {:error, :invalid_filter}
        end

      {:ok, _other} ->
        {:error, :invalid_filter}
    end
  end

  # -- balances -----------------------------------------------------------------------------------

  defp read_balances(authorized, filters) do
    with {:ok, rows} <- balance_pages(authorized, filters, nil, nil, []) do
      grouped =
        rows
        |> Enum.group_by(fn %{k: [sku, loc | _]} -> {sku, loc} end, & &1.quantity)
        |> Enum.map(fn {{sku, loc}, quantities} -> {sku, loc, sum(quantities)} end)
        |> Enum.reject(fn {_sku, _loc, qty} -> Decimal.eq?(qty, 0) end)

      prefix = authorized.prefix
      skus = IntIds.assign(prefix, :sku, Enum.map(grouped, &elem(&1, 0)))
      locs = IntIds.assign(prefix, :location, Enum.map(grouped, &elem(&1, 1)))

      out =
        for {sku, loc, qty} <- grouped,
            sku_id = Map.get(skus, uuid(sku)),
            loc_id = Map.get(locs, uuid(loc)),
            not is_nil(sku_id) and not is_nil(loc_id) do
          %{
            sku_id: sku_id,
            location_id: loc_id,
            location_code: location_code(Locations.lookup(prefix, loc)),
            qty: number(qty)
          }
        end

      {:ok, Enum.sort_by(out, &{&1.location_code, &1.sku_id})}
    end
  end

  # One consistent snapshot: the first page fixes the cutoff, later pages read at it.
  defp balance_pages(authorized, filters, n, cursor, acc) do
    page =
      if cursor,
        do: %{limit: @page, cursor: cursor, nonzero: true},
        else: %{limit: @page, nonzero: true}

    case Ledger.balances(authorized, {:posting_seq, n || :latest}, filters, page) do
      {:ok, %{cutoff_seq: seq, rows: rows, next_cursor: next}} ->
        acc = Enum.reverse(rows, acc)
        if next, do: balance_pages(authorized, filters, n || seq, next, acc), else: {:ok, acc}

      {:error, :invalid_filter} ->
        {:error, :invalid_filter}

      {:error, _other} ->
        {:error, :unavailable}
    end
  end

  defp sum([single]), do: to_decimal(single)
  defp sum(quantities), do: quantities |> Enum.map(&to_decimal/1) |> Enum.reduce(&Decimal.add/2)

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(other), do: other |> to_string() |> Decimal.new()

  defp number(%Decimal{} = d) do
    if Decimal.integer?(d), do: Decimal.to_integer(d), else: Decimal.to_float(d)
  end

  # -- movements ----------------------------------------------------------------------------------

  # The ledger answers oldest first. The posting counter is gapless, so the window
  # (latest - w, latest] holds the newest w entries before filters; it is widened (doubling, at most
  # 20 times) until `limit` filtered entries are found or the window reaches the start.
  defp read_movements(authorized, filters, limit) do
    with {:ok, %{ledger_seq: latest}} <-
           Ledger.balances(authorized, {:posting_seq, :latest}, %{}, %{limit: 1}),
         {:ok, rows} <- widen(authorized, filters, limit, latest || 0, limit, 0) do
      newest = rows |> Enum.sort_by(& &1.posting_seq, :desc) |> Enum.take(limit)
      {:ok, build_rows(authorized, newest, false)}
    else
      {:error, :invalid_filter} -> {:error, :invalid_filter}
      {:error, _other} -> {:error, :unavailable}
    end
  end

  # The Qoimeks movement rows (REQ-909) of ledger entries `entries` (as `Ledger.entries/3` answers
  # them), in order. A row is built from the entry, or from the ORIGINAL entry for a reversal (the old
  # server copies kind, place, destination place and quantity of the reversed movement).
  # `balances?` adds the balances after each movement (post and reverse answers); the history list
  # leaves them empty, as the old server does.
  defp build_rows(authorized, entries, balances?) do
    prefix = authorized.prefix

    shapes = Enum.map(entries, &shape(authorized, &1))
    reversed_by = reversed_by(authorized, entries)

    all_legs = Enum.flat_map(shapes, &(&1.entry.legs ++ &1.base.legs))

    movement_refs =
      Enum.flat_map(shapes, &[&1.entry.entry_id, &1.base.entry_id, &1.entry.reverses_entry_id]) ++
        Map.values(reversed_by)

    ids = IntIds.assign(prefix, :movement, movement_refs)
    skus = IntIds.assign(prefix, :sku, for(%{k: [sku | _]} <- all_legs, do: sku))
    locs = IntIds.assign(prefix, :location, for(%{k: [_, loc | _]} <- all_legs, do: loc))
    items = items(prefix, for(%{k: [sku | _]} <- all_legs, uniq: true, do: uuid(sku)))
    places = places(prefix, for(%{k: [_, loc | _]} <- all_legs, uniq: true, do: uuid(loc)))

    operators =
      Posting.shared_operators(
        prefix,
        entries |> Enum.map(& &1.document_id) |> Enum.reject(&is_nil/1)
      )

    # REQ-912: a count row shows the counted quantity of the document line, not the difference.
    counts = Posting.count_contents(prefix, count_document_ids(entries))

    lookup = %{ids: ids, skus: skus, locs: locs, items: items, places: places}

    for %{entry: entry, base: base, from: from, to: to} <- shapes,
        id = Map.get(ids, uuid(entry.entry_id)),
        not is_nil(id) do
      item = Map.get(items, leg_uuid(from, 0), %{})
      loc_uuid = leg_uuid(from, 1)

      %{
        id: Integer.to_string(id),
        kind: kind(base),
        sku_id: leg_ref(from, 0, skus),
        sku_code: Map.get(item, :code, ""),
        sku_name: Map.get(item, :name, ""),
        unit: Map.get(item, :unit, ""),
        location_id: leg_ref(from, 1, locs),
        location_code: Map.get(places, loc_uuid, ""),
        qty: count_quantity(entry, from, counts) || leg_quantity(from),
        operator: Map.get(operators, {entry.document_id, operator_step(entry)}) || "",
        created_at: iso(entry.posting_time),
        balances: if(balances?, do: balances_after(authorized, entry, lookup), else: [])
      }
      |> put_present(:to_location_id, leg_ref(to, 1, locs))
      |> put_present(:to_location_code, to && Map.get(places, leg_uuid(to, 1), ""))
      |> put_present(:reverses, text_id(ids, entry.reverses_entry_id))
      |> put_present(:reversed_by, text_id(ids, Map.get(reversed_by, entry.entry_id)))
    end
  end

  # The documents of the `count_set` entries (a reversal row keeps the difference taken back, REQ-909).
  defp count_document_ids(entries) do
    for %{cause: "count_set", document_id: id} <- entries,
        match?({:ok, _}, is_binary(id) && Ecto.UUID.cast(id)),
        uniq: true,
        do: id
  end

  # REQ-912: the `counted_quantity` of the line of the count document that `leg` posts (matched on
  # item, place, responsible and lot), as a number; nil when the entry is not a count or no line matches.
  defp count_quantity(%{cause: "count_set", document_id: id}, %{k: k}, counts) when is_list(k) do
    with %{content: %{"lines" => lines}} when is_list(lines) <- Map.get(counts, id),
         %{"counted_quantity" => text} <- Enum.find(lines, &line_of_leg?(&1, k)),
         {%Decimal{} = counted, ""} <- Decimal.parse(to_string(text)) do
      number(counted)
    else
      _no_count_line -> nil
    end
  end

  defp count_quantity(_entry, _leg, _counts), do: nil

  defp line_of_leg?(line, [sku, loc, _unit, responsible, lot | _]) do
    uuid(Map.get(line, "catalog_item_id")) == uuid(sku) and
      uuid(Map.get(line, "location_id")) == uuid(loc) and
      blank(Map.get(line, "responsible_id")) == blank(responsible) and
      blank(Map.get(line, "catalog_lot_id")) == blank(lot)
  end

  defp line_of_leg?(_line, _k), do: false

  defp blank(nil), do: ""
  defp blank(text), do: to_string(text)

  defp text_id(_ids, nil), do: nil

  defp text_id(ids, entry_uuid) do
    case Map.get(ids, uuid(entry_uuid)) do
      nil -> nil
      int -> Integer.to_string(int)
    end
  end

  # `%{entry, base, from, to}`: `base` is the entry whose data the row shows (the reversed entry for a
  # reversal), `from` the leg of the place (a transfer: the leg that decreases), `to` the leg of the
  # destination place (a transfer only).
  defp shape(authorized, entry) do
    base = original(authorized, entry)
    legs = Enum.sort_by(base.legs, & &1.leg_no)

    {from, to} =
      if kind(base) == "transfer" do
        {Enum.find(legs, &(sign(&1) < 0)) || Enum.at(legs, 0),
         Enum.find(legs, &(sign(&1) > 0)) || Enum.at(legs, 1)}
      else
        {Enum.at(legs, 0) || %{}, nil}
      end

    %{entry: entry, base: base, from: from || %{}, to: to}
  end

  defp original(authorized, %{cause: "reversal", reverses_entry_id: original_id} = entry)
       when is_binary(original_id),
       do: entry(authorized, original_id) || entry

  defp original(_authorized, entry), do: entry

  defp sign(%{quantity: q}) when not is_nil(q) do
    case q |> to_decimal() |> Decimal.compare(0) do
      :lt -> -1
      :gt -> 1
      :eq -> 0
    end
  end

  defp sign(_leg), do: 0

  # The old app's kind names (REQ-909 point 2): every document type that is not a receipt, an issue or a
  # transfer (a quick count, an opening balance) is an adjustment, as the old server writes imported balances.
  defp kind(%{document_type: "stock_receipt"}), do: "receipt"
  defp kind(%{document_type: "stock_issue"}), do: "issue"
  defp kind(%{document_type: "stock_transfer"}), do: "transfer"
  defp kind(_entry), do: "adjustment"

  # The entry id of the reversal of each given movement, `%{original_entry_id => reversal_entry_id}`.
  # A reversal is newer than its original, so the reversals from the oldest given original on hold them all.
  defp reversed_by(authorized, entries) do
    case entries |> Enum.reject(&(&1.cause == "reversal")) |> Enum.map(& &1.posting_seq) do
      [] -> %{}
      seqs -> reversal_pages(authorized, Enum.min(seqs), nil, %{})
    end
  end

  defp reversal_pages(authorized, from, cursor, acc) do
    page = if cursor, do: %{limit: @page, cursor: cursor}, else: %{limit: @page}

    case Ledger.entries(authorized, %{"cause" => "reversal", "from_seq" => from}, page) do
      {:ok, %{rows: rows, next_cursor: next}} ->
        acc =
          Enum.reduce(rows, acc, fn row, map ->
            Map.put(map, uuid(row.reverses_entry_id), row.entry_id)
          end)

        if next, do: reversal_pages(authorized, from, next, acc), else: acc

      {:error, _reason} ->
        raise "old_app_reversal_read_failed"
    end
  end

  defp operator_step(%{cause: "reversal"}), do: :reversed
  defp operator_step(_row), do: :posted

  # -- the balances after a movement (post and reverse answers) ---------------------------------------

  # One entry per (item, place) the movement touched: the balance of that item at that place as of the
  # movement's own posting number (so a replay shows the same values), sorted by place integer.
  defp balances_after(authorized, entry, lookup) do
    pairs =
      for %{k: [sku, loc | _]} <- entry.legs, uniq: true, do: {uuid(sku), uuid(loc)}

    pairs
    |> Enum.reject(fn {sku, loc} -> is_nil(sku) or is_nil(loc) end)
    |> Enum.uniq()
    |> Enum.flat_map(fn {sku, loc} ->
      sku_id = Map.get(lookup.skus, sku)
      loc_id = Map.get(lookup.locs, loc)

      if is_nil(sku_id) or is_nil(loc_id),
        do: [],
        else: [
          %{
            sku_id: sku_id,
            location_id: loc_id,
            location_code: Map.get(lookup.places, loc, ""),
            qty: balance_at(authorized, entry.posting_seq, sku, loc)
          }
        ]
    end)
    |> Enum.sort_by(& &1.location_id)
  end

  defp balance_at(authorized, seq, sku, loc) do
    case balance_pages(authorized, %{"sku" => sku, "location" => loc}, seq, nil, []) do
      {:ok, []} -> 0
      {:ok, rows} -> rows |> Enum.map(& &1.quantity) |> sum() |> number()
      _error -> raise "old_app_balance_read_failed"
    end
  end

  # -- item and place names for the rows ------------------------------------------------------------

  defp items(prefix, sku_uuids) do
    Map.new(for(sku <- sku_uuids, not is_nil(sku), do: {sku, item_names(prefix, sku)}))
  end

  defp item_names(prefix, sku) do
    case CatalogItems.lookup(prefix, sku) do
      {:ok, item} ->
        %{
          code: item["code"] || "",
          name: item["name"] || "",
          unit: uom_code(prefix, item["base_uom_id"])
        }

      _other ->
        %{}
    end
  end

  defp places(prefix, loc_uuids) do
    Map.new(
      for(
        loc <- loc_uuids,
        not is_nil(loc),
        do: {loc, location_code(Locations.lookup(prefix, loc))}
      )
    )
  end

  defp leg_uuid(%{k: k}, idx) when is_list(k), do: uuid(Enum.at(k, idx))
  defp leg_uuid(_leg, _idx), do: nil

  # The posting time as ISO 8601 UTC text.
  defp iso(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
  defp iso(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at) <> "Z"
  defp iso(other), do: other

  @doc """
  REQ-860: the Qoimeks movement row of ledger entry `entry_uuid` (a uuid), or `nil` when there is none.
  `authorized` is the tenant-wide read value of the shared access.
  """
  @spec movement(map(), String.t()) :: map() | nil
  def movement(authorized, entry_uuid) do
    case Ledger.entries(authorized, %{"entry_id" => entry_uuid}, %{limit: 1}) do
      {:ok, %{rows: [row]}} -> authorized |> build_rows([row], true) |> List.first()
      _none -> nil
    end
  end

  @doc """
  REQ-860: the ledger entry (`Ledger.entries/3` row shape) of entry uuid `entry_uuid`, or `nil`.
  """
  @spec entry(map(), String.t()) :: map() | nil
  def entry(authorized, entry_uuid) do
    case Ledger.entries(authorized, %{"entry_id" => entry_uuid}, %{limit: 1}) do
      {:ok, %{rows: [row]}} -> row
      _none -> nil
    end
  end

  @doc """
  REQ-860: the Qoimeks movement rows of the entries of document `document_id`, oldest first.
  """
  @spec movements_of_document(map(), String.t()) :: [map()]
  def movements_of_document(authorized, document_id) do
    case Ledger.entries(authorized, %{"document_id" => document_id}, %{limit: 100}) do
      {:ok, %{rows: rows}} -> build_rows(authorized, rows, true)
      _error -> []
    end
  end

  @doc """
  REQ-912: the Qoimeks movement row of a quick count document that CONFIRMED the book (counted equal
  to the book: no process, no ledger entry), or `nil` when document `document_id` is not such a count.
  `kind` adjustment, `qty` the counted quantity, `id` the digits of the integer `movement_int_ids`
  holds for the DOCUMENT id (so it never equals an entry's id and is not in the history list),
  `created_at` the time of the issue, `balances` the one entry of the place with its balance now,
  `operator` `""` (no process starts for it, so the typed name is stored nowhere; the replay shows the
  same row).
  """
  @spec confirmed_count_row(map(), String.t()) :: map() | nil
  def confirmed_count_row(authorized, document_id) do
    prefix = authorized.prefix

    with {:ok, _uuid} <- Ecto.UUID.cast(document_id),
         %{content: content, issued_at: issued_at} <-
           Map.get(Posting.count_contents(prefix, [document_id]), document_id),
         true <- QuickCountPosting.confirmed?(content),
         [line] <- Map.get(content, "lines"),
         {%Decimal{} = counted, ""} <- Decimal.parse(to_string(line["counted_quantity"])) do
      sku = uuid(line["catalog_item_id"])
      loc = uuid(line["location_id"])
      [movement_id] = Map.values(IntIds.assign(prefix, :movement, [document_id]))
      sku_id = IntIds.assign(prefix, :sku, [sku]) |> Map.get(sku)
      loc_id = IntIds.assign(prefix, :location, [loc]) |> Map.get(loc)
      item = item_names(prefix, sku)
      place = location_code(Locations.lookup(prefix, loc))

      %{
        id: Integer.to_string(movement_id),
        kind: "adjustment",
        sku_id: sku_id,
        sku_code: Map.get(item, :code, ""),
        sku_name: Map.get(item, :name, ""),
        unit: Map.get(item, :unit, ""),
        location_id: loc_id,
        location_code: place,
        qty: number(counted),
        operator: "",
        created_at: iso(issued_at),
        balances: [
          %{
            sku_id: sku_id,
            location_id: loc_id,
            location_code: place,
            qty: balance_at(authorized, nil, sku, loc)
          }
        ]
      }
    else
      _not_a_confirmed_count -> nil
    end
  end

  defp widen(authorized, filters, limit, latest, window, tries) do
    from = max(latest - window + 1, 1)

    case entry_pages(authorized, filters, from, nil, []) do
      {:ok, rows} ->
        if length(rows) >= limit or from <= 1 or tries >= 20,
          do: {:ok, rows},
          else: widen(authorized, filters, limit, latest, window * 2, tries + 1)

      error ->
        error
    end
  end

  defp entry_pages(authorized, filters, from, cursor, acc) do
    page = if cursor, do: %{limit: @page, cursor: cursor}, else: %{limit: @page}

    case Ledger.entries(
           authorized,
           Map.merge(%{"from_seq" => from}, entry_filters(filters)),
           page
         ) do
      {:ok, %{rows: rows, next_cursor: next}} ->
        acc = Enum.reverse(rows, acc)
        if next, do: entry_pages(authorized, filters, from, next, acc), else: {:ok, acc}

      {:error, _reason} = error ->
        error
    end
  end

  defp entry_filters(filters) when filters == %{}, do: %{}
  defp entry_filters(filters), do: %{"leg_slots" => filters}

  defp leg_ref(%{k: k}, idx, map) when is_list(k), do: Map.get(map, uuid(Enum.at(k, idx)))
  defp leg_ref(_leg, _idx, _map), do: nil

  defp leg_quantity(%{quantity: q}) when not is_nil(q),
    do: q |> to_decimal() |> Decimal.abs() |> number()

  defp leg_quantity(_leg), do: nil

  # -- names --------------------------------------------------------------------------------------

  defp location_code({:ok, record}), do: record["code"] || ""
  defp location_code(_other), do: ""

  defp uom_code(_prefix, nil), do: ""

  defp uom_code(prefix, id) do
    case CatalogItems.lookup(prefix, id) do
      {:ok, uom} -> uom["code"] || ""
      _other -> ""
    end
  end

  defp barcode(prefix, item_id) do
    case Codes.codes_for(prefix, "catalog_item", item_id) do
      [first | _] -> first["value"]
      [] -> nil
    end
  end

  defp uuid(ref) do
    case is_binary(ref) && Ecto.UUID.cast(ref) do
      {:ok, uuid} -> uuid
      _other -> nil
    end
  end
end
