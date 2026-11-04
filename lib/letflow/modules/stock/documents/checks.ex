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

  REQ-714 / GH #3747: `received_on/2` refuses a real receipt date after the event day (local date in the
  constant zone `Asia/Almaty`, read from PostgreSQL because the project has no Elixir tz database;
  assumption, owner may change at GATE B): `received_on_after_event`. Per line, after the unit check and
  before the lot-belongs-to check, the lot is checked against the item's tracking policy: `lot_required`,
  `lot_not_allowed`, `lot_expiry_missing`, `tracking_policy_not_supported` (serial), and `tracking_invalid`
  as the INV-8 fallback. `received_on` never feeds `event_time`.
  """

  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock
  alias Letflow.Repo

  @future_seconds 300
  @receipt_timezone Letflow.Identity.TenantTimezone.default()

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

  @doc """
  The real receipt date may not be after the event day in the module zone. `nil` is always fine.
  A failed zone query is `{:error, :internal}` (nothing is issued).
  """
  @spec received_on(String.t() | nil, String.t()) :: :ok | refusal() | {:error, :internal}
  def received_on(nil, _event_time), do: :ok

  def received_on(received_on, event_time) when is_binary(received_on) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(event_time),
         {:ok, wanted} <- Date.from_iso8601(received_on),
         {:ok, %{rows: [[%Date{} = day]]}} <-
           Repo.query("SELECT (($1::timestamptz) AT TIME ZONE $2)::date", [
             at,
             @receipt_timezone
           ]) do
      if Date.compare(wanted, day) == :gt,
        do: {:error, {"received_on_after_event", %{}}},
        else: :ok
    else
      _failed -> {:error, :internal}
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
        tracking_then_lot(prefix, line)
    end
  end

  defp tracking_then_lot(prefix, line) do
    with :ok <- tracking(prefix, line),
         true <-
           not is_binary(line.catalog_lot_id) or
             CatalogItems.item_lot_valid?(prefix, line.catalog_item_id, line.catalog_lot_id) do
      {:cont, :ok}
    else
      false -> {:halt, {:error, {"lot_not_valid", %{"line_no" => line.line_no}}}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp tracking(prefix, line) do
    refusal = fn reason -> {:error, {reason, %{"line_no" => line.line_no}}} end

    policy =
      case CatalogItems.lookup(prefix, line.catalog_item_id) do
        {:ok, %{"tracking_policy" => policy}} when is_binary(policy) -> policy
        _none -> "none"
      end

    if policy == "serial" do
      refusal.("tracking_policy_not_supported")
    else
      capture = capture(prefix, policy, line.catalog_lot_id)

      case CatalogItems.validate_capture(prefix, line.catalog_item_id, capture) do
        :ok -> :ok
        other -> refusal.(tracking_reason(other))
      end
    end
  end

  defp capture(prefix, "expiry", lot_id) when is_binary(lot_id) do
    expiry =
      case CatalogItems.lookup(prefix, lot_id) do
        {:ok, %{"entity_type" => "catalog_lot"} = lot} -> lot["expiry_date"]
        _other -> nil
      end

    %{"lot" => lot_id, "expiry" => expiry}
  end

  defp capture(_prefix, _policy, lot_id), do: %{"lot" => lot_id}

  @doc false
  @spec tracking_reason(term()) :: String.t()
  def tracking_reason({:error, {:capture_required, "lot"}}), do: "lot_required"
  def tracking_reason({:error, {:capture_not_allowed, "lot"}}), do: "lot_not_allowed"
  def tracking_reason({:error, {:capture_required, "expiry"}}), do: "lot_expiry_missing"
  def tracking_reason({:error, {:capture_invalid, "expiry"}}), do: "lot_expiry_missing"
  def tracking_reason(_other), do: "tracking_invalid"

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, {reason, %{}}}
end
