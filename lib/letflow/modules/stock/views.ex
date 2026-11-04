defmodule Letflow.Modules.Stock.Views do
  @moduledoc """
  REQ-687 / GH #3707: the read-API names of module `stock` (decision 0073 naming map): pure functions
  that turn a row of `Letflow.Ledger.balances/4`, `entries/3` or `reconcile/2` into a map with named
  slots. Every map is built field by field (an allowlist, INV-2): a key the core adds later never
  reaches the wire by itself. No database view, no SQL.

  Slot order of `k`: sku, location, org_unit, responsible, lot. An empty responsible or lot is `nil`.
  A leg the core masks for a scoped reader (REQ-682) keeps exactly `leg_no, quantity, unit_ref,
  masked: true`; the slot keys are absent, not nil.
  """

  @doc "A `stock_balance` view."
  @spec stock_balance(map()) :: map()
  def stock_balance(%{k: k, unit_ref: unit_ref, quantity: quantity, last_posting_seq: seq}) do
    Map.merge(slots(k), %{unit_ref: unit_ref, quantity: quantity, last_posting_seq: seq})
  end

  @doc "A `stock_movement` view (an entry with its legs)."
  @spec stock_movement(map()) :: map()
  def stock_movement(row) do
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
      legs: Enum.map(row.legs, &stock_movement_leg/1)
    }
  end

  @doc "A `stock_movement_leg` view."
  @spec stock_movement_leg(map()) :: map()
  def stock_movement_leg(%{masked: true, leg_no: leg_no, quantity: quantity, unit_ref: unit_ref}),
    do: %{leg_no: leg_no, quantity: quantity, unit_ref: unit_ref, masked: true}

  def stock_movement_leg(%{
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
    [sku, location, org_unit, responsible, lot] = pad(k)

    %{
      sku: sku,
      location: location,
      org_unit: org_unit,
      responsible: empty_to_nil(responsible),
      lot: empty_to_nil(lot)
    }
  end

  defp pad(k), do: k |> Enum.take(5) |> then(&(&1 ++ List.duplicate(nil, 5 - length(&1))))

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
