defmodule Letflow.Modules.Stock.Documents.OpeningChecks do
  @moduledoc """
  REQ-725 / GH #3775: the checks of an opening balance document (decision 0079 D3), all reads, no
  lock, no write. `check_all/3` runs every check on every line and returns the reasons per line;
  `first_failure/1` picks the first failing line for the issue step, which stops there.

  Reasons per line, in this order, each at most once: `not_linked` (the line's location is not linked
  to the document's org unit), `employee_not_active`, `unit_not_valid`, the tracking reasons of
  `Letflow.Modules.Stock.Documents.Checks.tracking_result/3` (`tracking_policy_not_supported`,
  `lot_required`, `lot_not_allowed`, `lot_expiry_missing`, `tracking_invalid`; one code path with
  the receipt), `lot_not_valid`, `received_on_in_future` (the real receipt date is after `today`).
  `today` is the local date of the clock in the module zone, taken once by the caller from
  `Checks.event_day/1`; this module holds no zone constant and no clock. A master retired between
  this check and the posting is not caught until slice L7 (runbook).
  """

  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.Documents.Checks

  @type result :: %{line_no: pos_integer(), reasons: [String.t()]}

  @doc "The reasons of every line of `view` (as `Documents.fetch/3` renders it), in `line_no` order."
  @spec check_all(String.t(), map(), Date.t()) :: [result()]
  def check_all(prefix, view, %Date{} = today) do
    view.lines
    |> Enum.sort_by(& &1.line_no)
    |> Enum.map(fn line ->
      %{line_no: line.line_no, reasons: reasons(prefix, view.org_unit_id, line, today)}
    end)
  end

  @doc "The first `{reason, line_no}` in line order, or `:ok` when no line fails."
  @spec first_failure([result()]) :: :ok | {String.t(), pos_integer()}
  def first_failure(results) do
    Enum.find_value(results, :ok, fn
      %{reasons: [reason | _], line_no: no} -> {reason, no}
      %{reasons: []} -> nil
    end)
  end

  defp reasons(prefix, org_unit_id, line, today) do
    lot? = is_binary(line.catalog_lot_id)

    [
      {not Locations.linked?(prefix, org_unit_id, line.location_id), "not_linked"},
      {not Org.active_employee?(prefix, line.responsible_id), "employee_not_active"},
      {not CatalogItems.item_uom_valid?(prefix, line.catalog_item_id, line.catalog_uom_id),
       "unit_not_valid"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Kernel.++(tracking(prefix, line))
    |> Kernel.++(
      if(
        lot? and
          not CatalogItems.item_lot_valid?(prefix, line.catalog_item_id, line.catalog_lot_id),
        do: ["lot_not_valid"],
        else: []
      )
    )
    |> Kernel.++(future(line.received_on, today))
  end

  defp tracking(prefix, line) do
    case Checks.tracking_result(prefix, line.catalog_item_id, line.catalog_lot_id) do
      :ok -> []
      {:error, reason} -> [reason]
    end
  end

  defp future(received_on, today) when is_binary(received_on) do
    case Date.from_iso8601(received_on) do
      {:ok, date} -> if Date.compare(date, today) == :gt, do: ["received_on_in_future"], else: []
      _bad -> ["received_on_in_future"]
    end
  end

  defp future(_other, _today), do: []
end
