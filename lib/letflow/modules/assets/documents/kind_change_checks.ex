defmodule Letflow.Modules.Assets.Documents.KindChangeChecks do
  @moduledoc """
  GH #3902 / REQ-759 (assets C15 part 2): the master checks at issue of a change of kind document
  (`docs/assets/change-of-kind.md` section 5). All reads, no write; the caller
  (`Letflow.Modules.Assets.Documents.issue/4`) runs them inside the per-tenant issue lock, so the
  inventory number checks serialise with every other issue.

  `run/2` stops at the first failure, in this order: the header org unit is a live active `org_unit`
  (`org_unit_not_active`); then per line in `line_no` order (extras always `"line_no"`): the item is
  active (`item_not_active`), the unit is valid for the item (`unit_not_valid`), a given lot belongs to
  the item (`lot_not_valid`), the tracking policy of the item (the reason of
  `Letflow.Modules.Stock.Documents.Checks.tracking_result/3`: `lot_required`, `lot_not_allowed`, ...),
  the stock location then the asset location are active (`location_not_active` + `"field"`), the asset
  org unit is a live active `org_unit` (`org_unit_not_active` + `"field"`), the stock location is linked
  to the header org unit and the asset location to the asset org unit (`not_linked` + `"side"` `stock` /
  `asset`), the stock responsible, the material responsible and a given actual user are active employees
  (`employee_not_active` + `"field"`), the quantity is whole and above zero and exactly 1 for a fixed
  asset (`quantity_invalid`), and the inventory number is held by no card and by no earlier line of the
  document (`inventory_number_taken`; a retired card still holds its number, as the unique constraint
  does). Every read passes the tenant `prefix` (INV-1): an id of another tenant is unknown, so it answers
  the same as an inactive one. The stock balance is not checked here (REQ-760 posts). A second issued,
  unposted document with the same inventory number is not seen; the unique constraint settles it at card
  creation.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Assets.Documents.Checks
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.Documents.Checks, as: StockChecks
  alias Letflow.Repo

  @type refusal :: {:error, {String.t(), map()}}

  @doc "Runs the checks of `view` (the document map of `Letflow.Modules.Assets.Documents`)."
  @spec run(String.t(), map()) :: :ok | refusal()
  def run(prefix, view) do
    with :ok <- Checks.org_unit(prefix, view.org_unit_id) do
      view.lines
      |> Enum.sort_by(& &1.line_no)
      |> Enum.reduce_while({:ok, MapSet.new()}, fn line, {:ok, seen} ->
        case line(prefix, view, line, seen) do
          :ok -> {:cont, {:ok, MapSet.put(seen, line.inventory_number)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, _seen} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp line(prefix, view, line, seen) do
    extras = %{"line_no" => line.line_no}

    with :ok <-
           check(CatalogItems.active?(prefix, line.catalog_item_id), "item_not_active", extras),
         :ok <-
           check(
             CatalogItems.item_uom_valid?(prefix, line.catalog_item_id, line.catalog_uom_id),
             "unit_not_valid",
             extras
           ),
         :ok <- lot(prefix, line, extras),
         :ok <- tracking(prefix, line, extras),
         :ok <- location(prefix, line.stock_location_id, "stock_location_id", extras),
         :ok <- location(prefix, line.asset_location_id, "asset_location_id", extras),
         :ok <- asset_unit(prefix, line.asset_org_unit_id, extras),
         :ok <- linked(prefix, view.org_unit_id, line.stock_location_id, "stock", extras),
         :ok <- linked(prefix, line.asset_org_unit_id, line.asset_location_id, "asset", extras),
         :ok <- employee(prefix, line.stock_responsible_id, "stock_responsible_id", extras),
         :ok <- employee(prefix, line.material_responsible_id, "material_responsible_id", extras),
         :ok <- optional_employee(prefix, line.actual_user_id, extras),
         :ok <- check(quantity_ok?(line.target_kind, line.quantity), "quantity_invalid", extras) do
      inventory_number(prefix, line.inventory_number, seen, extras)
    end
  end

  defp lot(_prefix, %{catalog_lot_id: nil}, _extras), do: :ok

  defp lot(prefix, line, extras),
    do:
      check(
        CatalogItems.item_lot_valid?(prefix, line.catalog_item_id, line.catalog_lot_id),
        "lot_not_valid",
        extras
      )

  defp tracking(prefix, line, extras) do
    case StockChecks.tracking_result(prefix, line.catalog_item_id, line.catalog_lot_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {reason, extras}}
    end
  end

  defp location(prefix, id, field, extras),
    do:
      check(Locations.active?(prefix, id), "location_not_active", Map.put(extras, "field", field))

  defp asset_unit(prefix, id, extras) do
    ok? =
      match?({:ok, %{"entity_type" => "org_unit"}}, Org.lookup(prefix, id)) and
        Org.active?(prefix, id)

    check(ok?, "org_unit_not_active", Map.put(extras, "field", "asset_org_unit_id"))
  end

  defp linked(prefix, org_unit_id, location_id, side, extras),
    do:
      check(
        Locations.linked?(prefix, org_unit_id, location_id),
        "not_linked",
        Map.put(extras, "side", side)
      )

  defp employee(prefix, id, field, extras),
    do:
      check(
        Org.active_employee?(prefix, id),
        "employee_not_active",
        Map.put(extras, "field", field)
      )

  defp optional_employee(_prefix, nil, _extras), do: :ok
  defp optional_employee(prefix, id, extras), do: employee(prefix, id, "actual_user_id", extras)

  defp quantity_ok?(target_kind, quantity) do
    case Decimal.parse(to_string(quantity)) do
      {%Decimal{} = q, ""} ->
        Decimal.equal?(Decimal.round(q, 0), q) and Decimal.gt?(q, 0) and
          (target_kind != "fixed" or Decimal.equal?(q, 1))

      _bad ->
        false
    end
  end

  defp inventory_number(prefix, number, seen, extras) do
    taken? = MapSet.member?(seen, number) or card_holds?(prefix, number)
    check(not taken?, "inventory_number_taken", extras)
  end

  # Any card that is not deleted, retired ones included. Bound parameter, tenant `prefix` (INV-1, INV-7).
  defp card_holds?(prefix, number) do
    Repo.exists?(
      from(c in Latest,
        where:
          c.entity_type == "assets_card" and not c.deleted and
            fragment("?->>'inventory_number' = ?", c.field_values, ^number)
      ),
      prefix: prefix
    )
  end

  defp check(true, _reason, _extras), do: :ok
  defp check(false, reason, extras), do: {:error, {reason, extras}}
end
