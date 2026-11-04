defmodule Letflow.Modules.Stock.Documents.Checks do
  @moduledoc """
  REQ-712 / GH #3749: the checks of the issue step of a stock document, all reads, no lock, no write.

  `event_time/2` is pure: the header time must not be more than `max_event_lateness_hours` (96, read
  from the `stock` ledger registration, not a second literal) before the clock nor more than 5 minutes
  after it; the boundaries are accepted, one second beyond is refused (`event_time_too_old`,
  `event_time_in_future`). `masters/2` runs the master checks of decision 0073 D-P (`declare/2` reads no
  master data; the ledger's own master validation is slice L7), in the order of the entry, and stops at
  the first failure: the org unit and the location are linked (`not_linked`), the responsible employee is
  active (`employee_not_active`), a given counterparty is a live active `catalog_counterparty`
  (`counterparty_not_active`), then per line in `line_no` order the unit is valid for the item
  (`unit_not_valid`) and a given lot belongs to the item (`lot_not_valid`). A failure carries the
  reason and, for a line check, its `line_no`. A master retired between this check and the posting is not
  caught until L7 (runbook).
  """

  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock

  @future_seconds 300

  @type refusal :: {:error, {String.t(), map()}}

  @doc "The 96-hour window of the `stock` ledger registration, in seconds."
  @spec lateness_seconds() :: pos_integer()
  def lateness_seconds do
    Stock.manifest().ledger["stock"].max_event_lateness_hours * 3600
  end

  @doc "Checks the event time (UTC ISO text) against `now`."
  @spec event_time(String.t(), DateTime.t()) :: :ok | refusal()
  def event_time(text, %DateTime{} = now) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)
    delta = DateTime.diff(at, now, :second)

    cond do
      delta > @future_seconds -> {:error, {"event_time_in_future", %{}}}
      delta < -lateness_seconds() -> {:error, {"event_time_too_old", %{}}}
      true -> :ok
    end
  end

  @doc "Runs the master checks of `view` (the document map of `Letflow.Modules.Stock.Documents`)."
  @spec masters(String.t(), map()) :: :ok | refusal()
  def masters(prefix, view) do
    with :ok <- check(Locations.linked?(prefix, view.org_unit_id, view.location_id), "not_linked"),
         :ok <- check(Org.active_employee?(prefix, view.responsible_id), "employee_not_active"),
         :ok <- counterparty(prefix, view.counterparty_id) do
      view.lines |> Enum.sort_by(& &1.line_no) |> Enum.reduce_while(:ok, &line(prefix, &1, &2))
    end
  end

  defp counterparty(_prefix, nil), do: :ok

  defp counterparty(prefix, id) do
    ok? =
      match?(
        {:ok, %{"entity_type" => "catalog_counterparty", "active" => true}},
        CatalogItems.lookup(prefix, id)
      )

    check(ok?, "counterparty_not_active")
  end

  defp line(prefix, line, :ok) do
    cond do
      not CatalogItems.item_uom_valid?(prefix, line.catalog_item_id, line.catalog_uom_id) ->
        {:halt, {:error, {"unit_not_valid", %{"line_no" => line.line_no}}}}

      is_binary(line.catalog_lot_id) and
          not CatalogItems.item_lot_valid?(prefix, line.catalog_item_id, line.catalog_lot_id) ->
        {:halt, {:error, {"lot_not_valid", %{"line_no" => line.line_no}}}}

      true ->
        {:cont, :ok}
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, {reason, %{}}}
end
