defmodule Letflow.Modules.Assets.Documents.OpeningChecks do
  @moduledoc """
  GH #4037 / G5 part 1 (decision 0083 D4): the checks of an asset opening document, all reads, no
  write, no lock. `check_all/2` runs EVERY check on EVERY line and returns the reasons per line (the
  `check` route shows them all); `first_failure/1` is the one refusal the issue step raises. Mirrors
  `Letflow.Modules.Stock.Documents.OpeningChecks` (module `assets` cannot call `stock`, boundary Rule 4).
  The tenant is the `prefix` argument only (INV-1): a card, location or employee id of another tenant
  is looked up in this tenant and answers like an unknown one.

  Header: the org unit is a live active `org_unit` (`org_unit_not_active`). Per line, in this order, each
  reason at most once: `card_not_active` (unknown, retired, another tenant's id: one answer; when it
  fails the reasons that need the card are skipped), `duplicate_asset` (a fixed or intangible asset on an
  earlier line; a low-value asset on an earlier line with the same placement, location + responsible +
  actual user, a different placement is a split and allowed), `quantity_invalid`, `org_unit_mismatch`
  (the card's org unit is not the header's), `location_required` / `location_not_allowed`, `not_linked`
  (the location is not active and linked to the header's org unit), `employee_not_active` (the
  material responsible, and the actual user when given; `fields` names the key) and
  `asset_already_in_register` (any card kind: an issued, non-reversed commission or opening holds it;
  the register balance of the asset is non-zero: the ledger-balance half of the rule, G5 part 2).

  The balance half reads the register through the caller's ledger read authorization and only when it
  is tenant-wide (`register_readable?/1`): a scoped reader (REQ-693) would see a filtered page and an
  empty one would prove nothing. Without a tenant-wide read the issue refuses (`register_unreadable`)
  and the advisory check shows the document half only. A failed read counts as "already in the
  register" (fail closed).
  """

  require Logger

  alias Letflow.Ledger
  alias Letflow.Modules.Assets.Documents.Checks
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org

  @type line_result :: %{line_no: pos_integer(), reasons: [String.t()], fields: [String.t()]}
  @type result :: %{header: [String.t()], lines: [line_result()]}

  @doc "Every check on the header and on every line of `view` (the document map), in `line_no` order."
  @spec check_all(String.t(), map(), term()) :: result()
  def check_all(prefix, view, authorized \\ nil) do
    {results, _seen} =
      view.lines
      |> Enum.sort_by(& &1.line_no)
      |> Enum.map_reduce(%{assets: MapSet.new(), placements: MapSet.new()}, fn line, seen ->
        line_result(prefix, view, line, seen, authorized)
      end)

    %{header: header(prefix, view), lines: results}
  end

  @doc "The header reasons: the org unit is active."
  @spec header(String.t(), map()) :: [String.t()]
  def header(prefix, view) do
    case Checks.org_unit(prefix, view.org_unit_id) do
      :ok -> []
      {:error, {reason, _}} -> [reason]
    end
  end

  @doc """
  The first failure of a `check_all/2` result as `{reason, extras}` (header first, then the lines in
  order), or `nil`. `extras` is `%{"line_no" => n}`, plus `"field"` for an employee reason.
  """
  @spec first_failure(result()) :: {String.t(), map()} | nil
  def first_failure(%{header: [reason | _]}), do: {reason, %{}}

  def first_failure(%{lines: lines}) do
    case Enum.find(lines, &(&1.reasons != [])) do
      nil ->
        nil

      %{line_no: no, reasons: [reason | _], fields: fields} ->
        extras = %{"line_no" => no}

        if reason == "employee_not_active",
          do: {reason, Map.put(extras, "field", hd(fields))},
          else: {reason, extras}
    end
  end

  # -- one line -----------------------------------------------------------------------------------

  @doc """
  True only for a ledger read authorization that reads the whole register (`scope: :all`). `nil` and
  a scoped reader are false. Reads the field with `Map.get`: the authorization struct is not matched
  outside the ledger (scan T-AZ-8).
  """
  @spec register_readable?(term()) :: boolean()
  def register_readable?(authorized),
    do: is_map(authorized) and Map.get(authorized, :scope) == :all

  defp line_result(prefix, view, line, seen, authorized) do
    card = Checks.card_lookup(prefix, line.asset_id)
    kind = with {:ok, c} <- card, do: c["kind"]
    placement = {line.location_id, line.material_responsible_id, line.actual_user_id}
    employees = employee_fields(prefix, line)

    reasons =
      [
        {"card_not_active", card == :error},
        {"duplicate_asset", duplicate?(seen, line.asset_id, kind, placement)},
        {"quantity_invalid", card_ok?(card) and not Checks.quantity_ok?(kind, line.quantity)},
        {"org_unit_mismatch", card_ok?(card) and card_unit(card) != view.org_unit_id},
        {"location_required", card_ok?(card) and location_missing?(kind, line)},
        {"location_not_allowed", card_ok?(card) and location_given?(kind, line)},
        {"not_linked", card_ok?(card) and not linked?(prefix, view, line)},
        {"employee_not_active", employees != []},
        {"asset_already_in_register",
         Checks.held?(prefix, line.asset_id) or
           (card_ok?(card) and in_balance?(authorized, line.asset_id))}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    seen = %{
      assets: MapSet.put(seen.assets, line.asset_id),
      placements: MapSet.put(seen.placements, {line.asset_id, placement})
    }

    {%{line_no: line.line_no, reasons: reasons, fields: employees}, seen}
  end

  # The register half of "once": a non-zero balance row of the asset. Only with a tenant-wide read.
  defp in_balance?(authorized, asset_id) do
    if register_readable?(authorized) do
      case Ledger.balances(authorized, {:posting_seq, :latest}, %{"asset" => asset_id}, %{
             limit: 1,
             nonzero: true
           }) do
        {:ok, %{rows: [_ | _]}} ->
          true

        {:ok, %{rows: []}} ->
          false

        {:error, reason} ->
          Logger.warning("assets opening register read refused: #{inspect(tag(reason))}")
          true
      end
    else
      false
    end
  end

  defp tag(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp tag(reason), do: reason

  defp card_ok?({:ok, _card}), do: true
  defp card_ok?(:error), do: false

  defp card_unit({:ok, card}), do: card["org_unit_id"]

  # Fixed and intangible: one unit, so the asset may appear once. Low value (or a card that could not
  # be read): the same placement twice is a duplicate, another placement is a split.
  defp duplicate?(seen, asset_id, kind, _placement) when kind in ["fixed", "intangible"],
    do: MapSet.member?(seen.assets, asset_id)

  defp duplicate?(seen, asset_id, _kind, placement),
    do: MapSet.member?(seen.placements, {asset_id, placement})

  defp location_missing?(kind, line), do: kind != "intangible" and is_nil(line.location_id)
  defp location_given?(kind, line), do: kind == "intangible" and not is_nil(line.location_id)

  defp linked?(_prefix, _view, %{location_id: nil}), do: true

  defp linked?(prefix, view, line),
    do: Locations.linked?(prefix, view.org_unit_id, line.location_id)

  # The keys of the employees that are not active (the actual user only when given).
  defp employee_fields(prefix, line) do
    [
      {"material_responsible_id", line.material_responsible_id},
      {"actual_user_id", line.actual_user_id}
    ]
    |> Enum.reject(fn {_key, id} -> is_nil(id) end)
    |> Enum.reject(fn {_key, id} -> Org.active_employee?(prefix, id) end)
    |> Enum.map(&elem(&1, 0))
  end
end
