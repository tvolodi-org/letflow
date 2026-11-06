defmodule Letflow.Modules.Assets.Responsible do
  @moduledoc """
  The single read point for "the material responsible employee of an asset" (GH #3894 family,
  phase C item C12; spec `docs/assets/asset-workflow-documents.md` section 9).

  The asset card holds no responsible person: that lives in the asset register (C8 ledger
  registration, C10 commission), which is not built yet. Until it lands this function answers
  `:none`, so `Letflow.Modules.Assets.Reminders` sends nothing in production. The register slice
  changes only this function (and adds there the "positive balance" condition: an asset with no
  balance has no responsible employee). Tests of the reminder pass their own resolver as
  `responsible_fun:`.
  """

  @doc "`{:ok, org_employee_record_id}` or `:none`. The tenant comes only from `prefix` (INV-1)."
  @spec employee_id(String.t(), String.t()) :: {:ok, String.t()} | :none
  def employee_id(prefix, card_id) when is_binary(prefix) and is_binary(card_id), do: :none
  def employee_id(_prefix, _card_id), do: :none
end
