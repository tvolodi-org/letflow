defmodule Letflow.Modules.Stock.StockCardSource do
  @moduledoc """
  T-1417 (phase E, E5c): the impure side of the stock card (official form Z-3). `read/4` reads the
  ledger movements of ONE item at ONE place (and, when given, one lot) through the caller's
  `Letflow.Ledger.Authorized` struct, folds them into card lines (income, expense, running balance)
  and reads the names the header needs. The pure shape for the printer is built by
  `Letflow.Modules.Stock.FormZ3`.

  Isolation: the only tenant input is `authorized.prefix` (INV-1); the ids come from the query and
  are bound parameters of the core read. A scoped reader (REQ-693) gets masked legs; those are
  skipped, so the card shows the part of the stock the reader may see (INV-2), and an item or place
  the reader may not see gives no visible leg, which is `{:error, :not_found}` like an absent one
  (INV-5).

  The card is read from the movements, not from the balances: income is a leg quantity above zero,
  expense is minus a leg quantity below zero (the leg quantity is signed), the balance is the
  running sum in `posting_seq` order, kept per unit of measure (a card normally has one). A card of
  more than #{5 * 200} entries (#{5} pages of the ledger page cap) is refused with
  `{:error, :card_too_long}` instead of reading without a bound.
  """

  alias Letflow.Ledger
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.CountPaperworkSource
  alias Letflow.Modules.Stock.DocumentNumbers
  alias Letflow.Modules.Stock.DocumentPrintSource

  @max_pages 5
  # Asks for more than the core allows; the core clamps the page to its own cap (200 entries).
  @page_limit 1000
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @type card :: %{header: map(), rows: [map()]}

  @spec read(map(), String.t(), String.t(), String.t() | nil) ::
          {:ok, card()} | {:error, :not_found | :card_too_long | :invalid_filter}
  def read(authorized, sku, location, lot) do
    slots = %{"sku" => sku, "location" => location}
    slots = if is_binary(lot), do: Map.put(slots, "lot", lot), else: slots

    page_fun = fn cursor ->
      page = %{limit: @page_limit}
      page = if cursor, do: Map.put(page, :cursor, cursor), else: page
      Ledger.entries(authorized, %{"leg_slots" => slots}, page)
    end

    with {:ok, entries} <- collect(page_fun),
         [_ | _] = lines <- fold(entries, sku, location, lot) do
      {:ok, %{header: header(authorized, sku, lines, lot), rows: rows(authorized, lines)}}
    else
      [] -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Pages through `page_fun` (cursor -> `{:ok, %{rows, next_cursor}}`) in order, at most `max_pages`
  (default #{@max_pages}; the stock sheet of T-1925 asks for more) pages; a further page is `{:error, :card_too_long}`. Public so a test can drive it with a fake.
  """
  @spec collect(
          (term() -> {:ok, %{rows: [map()], next_cursor: term()}} | {:error, term()}),
          pos_integer()
        ) :: {:ok, [map()]} | {:error, term()}
  def collect(page_fun, max_pages \\ @max_pages), do: collect(page_fun, nil, 1, [], max_pages)

  defp collect(page_fun, cursor, n, acc, max_pages) do
    case page_fun.(cursor) do
      {:ok, %{rows: rows, next_cursor: nil}} ->
        {:ok, Enum.reverse(acc, rows)}

      {:ok, %{rows: rows, next_cursor: next}} ->
        if n >= max_pages,
          do: {:error, :card_too_long},
          else: collect(page_fun, next, n + 1, Enum.reverse(rows, acc), max_pages)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Pure: the card lines of the entries (ascending `posting_seq`) for the item, place and optional
  lot. Masked legs and legs of other slots are skipped. Each line has the entry's `event_time`,
  `document_id`, `unit_ref`, `income` and `expense` (`Decimal`, the unused side `nil`), the running
  `balance` of its unit of measure, and the leg slot values `org_unit`, `lot`.
  """
  @spec fold([map()], String.t(), String.t(), String.t() | nil) :: [map()]
  def fold(entries, sku, location, lot) do
    {lines, _balances} =
      entries
      |> Enum.flat_map(fn entry ->
        entry.legs
        |> Enum.filter(&visible_leg?(&1, sku, location, lot))
        |> Enum.map(&{entry, &1})
      end)
      |> Enum.map_reduce(%{}, fn {entry, leg}, balances ->
        qty = quantity(leg.quantity)
        balance = Decimal.add(Map.get(balances, leg.unit_ref, Decimal.new(0)), qty)
        [_sku, _loc, org_unit, _resp, leg_lot | _] = leg.k

        line = %{
          posting_seq: entry.posting_seq,
          event_time: entry.event_time,
          document_id: entry.document_id,
          unit_ref: leg.unit_ref,
          org_unit: org_unit,
          lot: if(leg_lot != "", do: leg_lot),
          income: if(Decimal.gt?(qty, 0), do: qty),
          expense: if(Decimal.lt?(qty, 0), do: Decimal.negate(qty)),
          balance: balance
        }

        {line, Map.put(balances, leg.unit_ref, balance)}
      end)

    lines
  end

  defp visible_leg?(%{masked: true}, _sku, _location, _lot), do: false

  defp visible_leg?(%{k: [leg_sku, leg_loc, _org, _resp, leg_lot | _]}, sku, location, lot),
    do: leg_sku == sku and leg_loc == location and (is_nil(lot) or leg_lot == lot)

  defp visible_leg?(_other, _sku, _location, _lot), do: false

  @doc false
  # Also used by `StockSheetSource` (T-1925): one quantity text to a `Decimal`.
  def quantity(text) when is_binary(text) do
    case Decimal.parse(text) do
      {%Decimal{} = d, ""} -> d
      _ -> Decimal.new(0)
    end
  end

  def quantity(%Decimal{} = d), do: d
  def quantity(n) when is_integer(n), do: Decimal.new(n)
  def quantity(_), do: Decimal.new(0)

  # -- rows -------------------------------------------------------------------------------------

  defp rows(authorized, lines) do
    numbers = DocumentNumbers.for_ids(authorized.prefix, Enum.map(lines, & &1.document_id))
    zone = CountPaperworkSource.zone(authorized.tenant_id)

    {rows, _cache} =
      lines
      |> Enum.with_index(1)
      |> Enum.map_reduce(%{}, fn {line, n}, cache ->
        {offset, cache} = offset(zone, line.event_time, cache)
        names = %{offsets: %{event_time: offset}}

        row = %{
          event_time: CountPaperwork.time(line.event_time, names, :event_time),
          document_number: Map.get(numbers, line.document_id),
          no: n,
          income: line.income,
          expense: line.expense,
          balance: line.balance
        }

        {row, cache}
      end)

    rows
  end

  # One offset read per distinct UTC day (the zone offset does not change inside a day here).
  defp offset(zone, %DateTime{} = at, cache) do
    day = DateTime.to_date(at)

    case cache do
      %{^day => seconds} ->
        {seconds, cache}

      _ ->
        seconds = CountPaperworkSource.offset(zone, at)
        {seconds, Map.put(cache, day, seconds)}
    end
  end

  defp offset(_zone, _other, cache), do: {0, cache}

  @doc false
  # Also used by `StockSheetSource` (T-1925).
  def unit_name(prefix, ref) when is_binary(ref) do
    with true <- Regex.match?(@uuid, ref),
         {:ok, r} <- CatalogItems.lookup(prefix, ref),
         name when is_binary(name) and name != "" <- r["name"] || r["code"] do
      name
    else
      _ -> ref
    end
  end

  def unit_name(_prefix, ref), do: to_string(ref)

  # -- header -----------------------------------------------------------------------------------

  defp header(authorized, sku, [first | _] = lines, lot) do
    prefix = authorized.prefix
    item = record(CatalogItems.lookup(prefix, sku))
    lot_record = if is_binary(lot), do: record(CatalogItems.lookup(prefix, lot)), else: %{}
    unit = Org.lookup(prefix, first.org_unit) |> record()

    entity =
      prefix |> DocumentPrintSource.legal_entity(first.org_unit) |> Map.get(first.org_unit, %{})

    %{
      org_name: entity[:name],
      org_bin: entity[:bin],
      struct_unit: unit["name"],
      item_name: item["name"],
      nom: item["code"],
      unit: lines |> Enum.map(& &1.unit_ref) |> Enum.uniq() |> unit_label(prefix),
      mark: lot_record["mark"],
      shelf: lot_record["expiry_date"]
    }
  end

  defp unit_label(refs, prefix), do: refs |> Enum.map_join(", ", &unit_name(prefix, &1))

  defp record({:ok, %{} = r}), do: r
  defp record(_), do: %{}
end
