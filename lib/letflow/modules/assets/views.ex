defmodule Letflow.Modules.Assets.Views do
  @moduledoc """
  REQ-749 / GH #3893: the read-API names of module `assets`: pure functions that turn a row of
  `Letflow.Ledger.balances/4`, `entries/3` or `reconcile/2` into a map with named slots. Every map is
  built field by field (an allowlist, INV-2): a key the core adds later never reaches the wire by
  itself. No database view, no SQL. The code follows `Letflow.Modules.Stock.Views`; it is copied, not
  called, because module `assets` does not depend on `stock` (boundary Rule 4).

  Slot order of `k`: asset, org_unit, location, material_responsible, actual_user. An empty location
  or actual user is `nil`. A leg the core masks for a scoped reader (REQ-682) keeps exactly `leg_no,
  quantity, unit_ref, masked: true`; the slot keys are absent, not nil.
  """

  alias Letflow.Modules.KeyHelpers

  @doc "An `asset_balance` view."
  @spec asset_balance(map()) :: map()
  def asset_balance(%{k: k, unit_ref: unit_ref, quantity: quantity, last_posting_seq: seq}) do
    Map.merge(slots(k), %{unit_ref: unit_ref, quantity: quantity, last_posting_seq: seq})
  end

  @doc "An `asset_movement` view (an entry with its legs)."
  @spec asset_movement(map()) :: map()
  def asset_movement(row) do
    %{
      entry_id: row.entry_id,
      posting_seq: row.posting_seq,
      cause: row.cause,
      reverses_entry_id: row.reverses_entry_id,
      reason_code: row.reason_code,
      document_type: row.document_type,
      document_id: row.document_id,
      related_document_id: row.related_document_id,
      correlation_id: row.correlation_id,
      event_time: row.event_time,
      posting_time: row.posting_time,
      legs: Enum.map(row.legs, &asset_movement_leg/1)
    }
  end

  @doc "An `asset_movement_leg` view."
  @spec asset_movement_leg(map()) :: map()
  def asset_movement_leg(%{masked: true, leg_no: leg_no, quantity: quantity, unit_ref: unit_ref}),
    do: %{leg_no: leg_no, quantity: quantity, unit_ref: unit_ref, masked: true}

  def asset_movement_leg(%{
        leg_no: leg_no,
        k: k,
        quantity: quantity,
        unit_ref: unit_ref,
        document_line_id: line_id
      }) do
    Map.merge(
      %{leg_no: leg_no},
      Map.merge(slots(k), %{quantity: quantity, unit_ref: unit_ref, document_line_id: line_id})
    )
  end

  @doc "A reconcile mismatch; a key shorter than five slots (trailing empties trimmed) is padded."
  @spec mismatch(map()) :: map()
  def mismatch(%{key: key, balance: balance, ledger_sum: ledger_sum}) do
    Map.merge(slots(key), %{balance: balance, ledger_sum: ledger_sum})
  end

  defp slots(k) do
    [asset, org_unit, location, responsible, user] = KeyHelpers.pad(k)

    %{
      asset: asset,
      org_unit: org_unit,
      location: KeyHelpers.empty_to_nil(location),
      material_responsible: responsible,
      actual_user: KeyHelpers.empty_to_nil(user)
    }
  end
end
