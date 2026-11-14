defmodule Letflow.Modules.Stock.StockSheetSource do
  @moduledoc """
  T-1925 (audit slice 9): the impure side of the stock balances sheet (official form Z-7 / Q-7,
  annex 31). `read/4` reads the ledger movements that have a leg at ONE location through the
  caller's `Letflow.Ledger.Authorized` struct and folds them, per item and unit of measure, into
  the balance at the start of a period, the income and expense of the period and the balance at
  its end. The pure shape for the printer is built by `Letflow.Modules.Stock.FormZ7`.

  Isolation: the only tenant input is `authorized.prefix` (INV-1); the location id is a bound
  parameter of the core read. A scoped reader (REQ-693) gets masked legs; those are skipped, so the
  sheet shows the part of the stock the reader may see (INV-2), and a location the reader may not
  see gives no visible leg, which is `{:error, :not_found}` like an absent one (INV-5).

  Why the movements and not the balances: the form needs the gross income and expense of the
  period, which only the movements carry. `Ledger.entries/3` has no time filter, so the whole
  history of the location is read (opening balances need it) and each leg is placed by the
  entry's `event_time` against the tenant-zone day boundaries. A location with more than
  #{25 * 200} entries (25 pages of the ledger page cap) or more than 1000 item rows is refused with
  `{:error, :sheet_too_long}` instead of reading or printing without a bound.

  Quantities are summed one leg at a time, like the Z-3 card: a move between two org units or two
  persons inside the same location shows as both income and expense. Lots of one item are summed
  into one row.
  """

  alias Letflow.Identity.TenantTimezone
  alias Letflow.Ledger
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.CountPaperworkSource
  alias Letflow.Modules.Stock.DocumentPrintSource
  alias Letflow.Modules.Stock.StockCardSource

  @max_pages 25
  @max_rows 1000
  # Asks for more than the core allows; the core clamps the page to its own cap (200 entries).
  @page_limit 1000

  @type sheet :: %{header: map(), rows: [map()]}

  @spec read(map(), String.t(), Date.t(), Date.t()) ::
          {:ok, sheet()}
          | {:error,
             :not_found
             | :sheet_too_long
             | :period_in_future
             | :invalid_timezone
             | :invalid_filter}
  def read(authorized, location, %Date{} = from, %Date{} = to) do
    zone = CountPaperworkSource.zone(authorized.tenant_id)

    page_fun = fn cursor ->
      page = %{limit: @page_limit}
      page = if cursor, do: Map.put(page, :cursor, cursor), else: page
      Ledger.entries(authorized, %{"leg_slots" => %{"location" => location}}, page)
    end

    with {:ok, today} <- TenantTimezone.today(zone),
         :ok <- check_future(to, today),
         {:ok, start_at} <- TenantTimezone.start_of_next_day(Date.add(from, -1), zone),
         {:ok, end_at} <- TenantTimezone.start_of_next_day(to, zone),
         {:ok, entries} <- collect(page_fun),
         [_ | _] = groups <- fold(entries, location, start_at, end_at),
         :ok <- check_rows(groups) do
      {:ok,
       %{
         header: header(authorized, location, groups, from, to, today),
         rows: rows(authorized.prefix, groups)
       }}
    else
      [] -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp check_future(to, today),
    do: if(Date.compare(to, today) == :gt, do: {:error, :period_in_future}, else: :ok)

  defp check_rows(groups),
    do: if(length(groups) > @max_rows, do: {:error, :sheet_too_long}, else: :ok)

  defp collect(page_fun) do
    case StockCardSource.collect(page_fun, @max_pages) do
      {:error, :card_too_long} -> {:error, :sheet_too_long}
      other -> other
    end
  end

  @doc """
  Pure: the sheet rows of the entries for the location. A leg counts when it is not masked and its
  key is `[sku, location, org_unit, responsible, lot | _]` for `location`; the entry's
  `event_time` `t` places it: `t < start_at` opening, `start_at <= t < end_at` income (quantity
  above zero) or expense (minus a quantity below zero), `t >= end_at` ignored. Rows are grouped per
  `{sku, unit_ref}`; a group with no opening, income or expense is dropped. Each row has `sku`,
  `unit_ref`, `opening`, `income`, `expense`, `closing` (`Decimal`) and the sets `org_units` and
  `responsibles` of the legs before `end_at`. Not sorted (sorting needs the names).
  """
  @spec fold([map()], String.t(), DateTime.t(), DateTime.t()) :: [map()]
  def fold(entries, location, %DateTime{} = start_at, %DateTime{} = end_at) do
    zero = Decimal.new(0)

    entries
    |> Enum.flat_map(fn entry ->
      entry.legs
      |> Enum.filter(&visible_leg?(&1, location))
      |> Enum.map(&{entry.event_time, &1})
    end)
    |> Enum.reduce(%{}, fn {t, leg}, acc ->
      case place(t, start_at, end_at) do
        :after ->
          acc

        where ->
          [sku, _loc, org_unit, resp | _] = leg.k
          qty = StockCardSource.quantity(leg.quantity)

          base = %{
            sku: sku,
            unit_ref: leg.unit_ref,
            opening: zero,
            income: zero,
            expense: zero,
            org_units: MapSet.new(),
            responsibles: MapSet.new()
          }

          Map.update(acc, {sku, leg.unit_ref}, add(base, where, qty, org_unit, resp), fn row ->
            add(row, where, qty, org_unit, resp)
          end)
      end
    end)
    |> Map.values()
    |> Enum.map(&close/1)
    |> Enum.reject(&all_zero?/1)
  end

  defp place(%DateTime{} = t, start_at, end_at) do
    cond do
      DateTime.compare(t, start_at) == :lt -> :opening
      DateTime.compare(t, end_at) == :lt -> :period
      true -> :after
    end
  end

  # An entry without a readable time cannot be placed: it is not counted.
  defp place(_other, _start_at, _end_at), do: :after

  defp add(row, :opening, qty, org_unit, resp),
    do: %{row | opening: Decimal.add(row.opening, qty)} |> note(org_unit, resp)

  defp add(row, :period, qty, org_unit, resp) do
    row =
      if Decimal.gt?(qty, 0),
        do: %{row | income: Decimal.add(row.income, qty)},
        else: %{row | expense: Decimal.add(row.expense, Decimal.negate(qty))}

    note(row, org_unit, resp)
  end

  defp note(row, org_unit, resp) do
    %{
      row
      | org_units: put_id(row.org_units, org_unit),
        responsibles: put_id(row.responsibles, resp)
    }
  end

  defp put_id(set, id) when is_binary(id) and id != "", do: MapSet.put(set, id)
  defp put_id(set, _), do: set

  defp close(row),
    do: Map.put(row, :closing, row.opening |> Decimal.add(row.income) |> Decimal.sub(row.expense))

  defp all_zero?(row),
    do: Enum.all?([row.opening, row.income, row.expense], &Decimal.eq?(&1, 0))

  defp visible_leg?(%{masked: true}, _location), do: false

  defp visible_leg?(%{k: [_sku, leg_loc, _org, _resp | _]}, location), do: leg_loc == location

  defp visible_leg?(_other, _location), do: false

  # -- names ------------------------------------------------------------------------------------

  defp rows(prefix, groups) do
    groups
    |> Enum.map(fn g ->
      item = record(CatalogItems.lookup(prefix, g.sku))

      %{
        name: item["name"],
        nom: item["code"],
        unit: StockCardSource.unit_name(prefix, g.unit_ref),
        opening: g.opening,
        income: g.income,
        expense: g.expense,
        closing: g.closing,
        sku: g.sku
      }
    end)
    |> Enum.sort_by(&{&1.nom || "\u{10FFFF}", &1.name || "\u{10FFFF}", &1.sku, &1.unit})
    |> Enum.map(&Map.delete(&1, :sku))
  end

  defp header(authorized, location, groups, from, to, today) do
    prefix = authorized.prefix
    loc = record(Locations.lookup(prefix, location))
    units = groups |> Enum.flat_map(&MapSet.to_list(&1.org_units)) |> Enum.uniq()
    people = groups |> Enum.flat_map(&MapSet.to_list(&1.responsibles)) |> Enum.uniq()
    {org_name, org_bin} = legal_entity(prefix, units)

    %{
      org_name: org_name,
      org_bin: org_bin,
      location_name: loc["name"],
      location_code: loc["code"],
      struct_unit: single(units, prefix, "name"),
      mol_name: single(people, prefix, "full_name"),
      made_on: today,
      from: from,
      to: to
    }
  end

  # Printed only when every unit resolves to the same legal entity; otherwise both blank.
  defp legal_entity(prefix, units) do
    entities =
      units
      |> Enum.map(fn unit ->
        prefix |> DocumentPrintSource.legal_entity(unit) |> Map.get(unit)
      end)
      |> Enum.uniq()

    case entities do
      [%{name: name, bin: bin}] -> {name, bin}
      _ -> {nil, nil}
    end
  end

  # The field of the one record the printed legs point to; zero or several give nil (nothing guessed).
  defp single([id], prefix, field), do: record(Org.lookup(prefix, id))[field]
  defp single(_ids, _prefix, _field), do: nil

  defp record({:ok, %{} = r}), do: r
  defp record(_), do: %{}
end
