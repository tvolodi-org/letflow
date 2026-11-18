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

  * `catalog/1`: every active catalog item: `id` (the sku integer), `name`, `article` (the item
    code), `unit` (code of the base unit of measure, or null), `barcode` (the first code value
    assigned to the item, or null).
  * `balances/2`: one row per sku and place with a non-zero quantity (summed over org unit,
    responsible, lot and unit of measure): `sku_id`, `location_id`, `quantity`, `sku_name`,
    `location_name`. Optional integer filters `sku_id`, `location_id`.
  * `movements/2`: the newest `limit` ledger entries (50 when `limit` is missing or outside 1..500),
    newest first: `id`, `kind` (the document type, `reversal` for a reversal), `sku_id`,
    `location_id` (null when the entry has no place), `quantity` (absolute value of the first leg),
    `operator` (the typed operator name of a movement made through the shared access, null for a personal account's), `created_at` (posting time).
    Optional integer filters `sku_id`, `location_id`.

  Quantities are JSON numbers (the old app reads them as numbers). An unknown integer filter
  answers an empty list. A malformed filter is `{:error, :invalid_filter}` (the router answers 400).

  Known QA limits (security review, REQ-859): the catalog and balances reads do one name or code
  lookup per row (N+1), and one movements request can widen its window up to 20 times at `@page`
  rows each; the per-credential request limit (60 a minute) bounds the load. A cap on total rows
  or pages per request is needed before production (INV-8).
  """

  alias Letflow.Ledger
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Codes
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.SharedStockAccess.IntIds

  @page 200
  @default_limit 50
  @max_limit 500

  @doc "The Qoimeks catalog list of the tenant schema `prefix`."
  @spec catalog(String.t()) :: {:ok, [map()]} | {:error, :unavailable}
  def catalog(prefix) do
    case CatalogItems.list_active(prefix) do
      {:ok, items} ->
        ids = IntIds.assign(prefix, :sku, Enum.map(items, & &1["record_id"]))

        rows =
          items
          |> Enum.flat_map(fn item ->
            case Map.fetch(ids, item["record_id"]) do
              {:ok, int} ->
                [
                  %{
                    id: int,
                    name: item["name"],
                    article: item["code"],
                    unit: uom_code(prefix, item["base_uom_id"]),
                    barcode: barcode(prefix, item["record_id"])
                  }
                ]

              :error ->
                []
            end
          end)
          |> Enum.sort_by(& &1.id)

        {:ok, rows}

      _other ->
        {:error, :unavailable}
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
            quantity: number(qty),
            sku_name: name_of(CatalogItems.lookup(prefix, sku)),
            location_name: name_of(Locations.lookup(prefix, loc))
          }
        end

      {:ok, Enum.sort_by(out, &{&1.sku_id, &1.location_id})}
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
      {:ok, build_rows(authorized, newest)}
    else
      {:error, :invalid_filter} -> {:error, :invalid_filter}
      {:error, _other} -> {:error, :unavailable}
    end
  end

  # The Qoimeks movement rows of ledger entries `newest` (as `Ledger.entries/3` answers them), in order.
  defp build_rows(authorized, newest) do
    prefix = authorized.prefix
    entry_ids = IntIds.assign(prefix, :movement, Enum.map(newest, & &1.entry_id))

    legs = Enum.map(newest, &first_leg/1)
    skus = IntIds.assign(prefix, :sku, for(%{k: [sku | _]} <- legs, do: sku))
    locs = IntIds.assign(prefix, :location, for(%{k: [_, loc | _]} <- legs, do: loc))

    operators =
      Posting.shared_operators(
        prefix,
        newest |> Enum.map(& &1.document_id) |> Enum.reject(&is_nil/1)
      )

    for {row, leg} <- Enum.zip(newest, legs),
        id = Map.get(entry_ids, uuid(row.entry_id)),
        not is_nil(id) do
      %{
        id: id,
        kind: kind(row),
        sku_id: leg_ref(leg, 0, skus),
        location_id: leg_ref(leg, 1, locs),
        quantity: leg_quantity(leg),
        operator: Map.get(operators, {row.document_id, operator_step(row)}),
        created_at: row.posting_time
      }
    end
  end

  defp operator_step(%{cause: "reversal"}), do: :reversed
  defp operator_step(_row), do: :posted

  @doc """
  REQ-860: the Qoimeks movement row of ledger entry `entry_uuid` (a uuid), or `nil` when there is none.
  `authorized` is the tenant-wide read value of the shared access.
  """
  @spec movement(map(), String.t()) :: map() | nil
  def movement(authorized, entry_uuid) do
    case Ledger.entries(authorized, %{"entry_id" => entry_uuid}, %{limit: 1}) do
      {:ok, %{rows: [row]}} -> authorized |> build_rows([row]) |> List.first()
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
      {:ok, %{rows: rows}} -> build_rows(authorized, rows)
      _error -> []
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

  defp first_leg(%{legs: legs}) do
    legs |> Enum.sort_by(& &1.leg_no) |> List.first() || %{}
  end

  defp leg_ref(%{k: k}, idx, map) when is_list(k), do: Map.get(map, uuid(Enum.at(k, idx)))
  defp leg_ref(_leg, _idx, _map), do: nil

  defp leg_quantity(%{quantity: q}) when not is_nil(q),
    do: q |> to_decimal() |> Decimal.abs() |> number()

  defp leg_quantity(_leg), do: nil

  defp kind(%{cause: "reversal"}), do: "reversal"
  defp kind(%{document_type: type}) when is_binary(type), do: type
  defp kind(%{cause: cause}), do: cause

  # -- names --------------------------------------------------------------------------------------

  defp name_of({:ok, record}), do: record["name"]
  defp name_of(_other), do: nil

  defp uom_code(_prefix, nil), do: nil

  defp uom_code(prefix, id) do
    case CatalogItems.lookup(prefix, id) do
      {:ok, uom} -> uom["code"]
      _other -> nil
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
