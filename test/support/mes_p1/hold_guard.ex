defmodule Letflow.Proof.MesP1.StockCopy.HoldGuard do
  @moduledoc """
  MES PROOF P1 (T-1829), REMOVABLE: the posting guard of the stock copy. It composes the real freeze check
  (`Letflow.Modules.Stock.FreezeGuard`, because a registration has ONE guard slot) with the lot hold rule.

  Lot rule (a guess at the business rule, owner may change it): a lot that is not `released` may not be moved by
  `issue`, `hand_over`, `consume`, `kind_change_out`, nor by a `transfer` whose keys touch a customer location.
  Everything else is allowed (receipt, opening, produce, write_off, count_difference, plant-internal transfer, return,
  reversal). A lot with no status row is a legacy lot and counts as released: unsafe by default, named in doc 09.
  An unknown status text or a query error raises, and the platform maps a raise to `ledger_guard_failed` (fail closed).
  The label is `lot-<status>`.
  """

  alias Letflow.Modules.Stock.FreezeGuard
  alias Letflow.Proof.MesP1.LotStatus

  @blocked_causes ~w(issue hand_over consume kind_change_out)

  @spec check(String.t(), map()) :: :ok | {:held, String.t()}
  def check(prefix, %{keys: keys, cause: cause} = summary)
      when is_binary(prefix) and is_list(keys) do
    case FreezeGuard.check(prefix, summary) do
      :ok -> lot_rule(prefix, cause, keys)
      held -> held
    end
  end

  def check(_prefix, _summary), do: :ok

  defp lot_rule(_prefix, "reversal", _keys), do: :ok

  defp lot_rule(prefix, cause, keys) do
    if guarded?(prefix, cause, keys) do
      keys
      |> Enum.map(&Map.get(&1, "lot", ""))
      |> Enum.uniq()
      |> Enum.find_value(:ok, fn lot -> held(LotStatus.get(prefix, lot)) end)
    else
      :ok
    end
  end

  defp guarded?(_prefix, cause, _keys) when cause in @blocked_causes, do: true

  defp guarded?(prefix, "transfer", keys),
    do: Enum.any?(keys, &LotStatus.customer_location?(prefix, Map.get(&1, "location", "")))

  defp guarded?(_prefix, _cause, _keys), do: false

  defp held(nil), do: nil
  defp held("released"), do: nil
  defp held(status) when status in ["quarantine", "rejected"], do: {:held, "lot-" <> status}
  defp held(other), do: raise("unknown lot status #{inspect(other)}")
end
