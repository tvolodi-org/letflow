defmodule Letflow.Audit.LedgerPosted do
  @moduledoc """
  REQ-686 / GH #3696 (slice L3c, decision 0073 D8): the audit attributes of one posted ledger
  entry, `ledger.posted`. Pure data, shared by the engine (which writes it in the completion's
  transaction, after the ledger counter: lock class 5b before the audit chain row of class 6), by
  `Letflow.Ledger.Reconcile` (which compares the stored `chain_hash` with the entry's) and by the
  test fixture.

  The stored `after_state` has exactly seven keys: ids, the cause, the leg count and the chain
  hash. No quantity, slot value, reason text or free text.
  """

  @action "ledger.posted"
  @resource_type "ledger_entry"

  @spec action() :: String.t()
  def action, do: @action

  @spec resource_type() :: String.t()
  def resource_type, do: @resource_type

  @doc "The `Letflow.Audit.insert_entry/3` attributes of one posted summary."
  @spec attrs(map(), String.t() | nil) :: map()
  def attrs(summary, actor_id) when is_map(summary) do
    %{
      actor_id: actor_id,
      action: @action,
      resource_type: @resource_type,
      resource_id: summary.entry_id,
      before_state: nil,
      after_state: %{
        "entry_id" => summary.entry_id,
        "ledger_id" => summary.ledger_id,
        "posting_seq" => summary.posting_seq,
        "cause" => summary.cause,
        "leg_count" => summary.leg_count,
        "actor_id" => actor_id,
        "chain_hash" => summary.chain_hash
      },
      trace_id: nil
    }
  end

  @doc """
  GH #T-1557: the document-level audit attributes of one posted summary, or `nil` when the
  summary carries no document id. `document.reversed` / `document.written_off` / `document.posted`,
  keyed by the document id so the administrator can filter "this document". No quantity, no free text.
  """
  @spec document_attrs(map(), String.t() | nil) :: map() | nil
  def document_attrs(summary, actor_id) when is_map(summary) do
    case Map.get(summary, :document_id) do
      id when is_binary(id) and id != "" ->
        %{
          actor_id: actor_id,
          action: document_action(Map.get(summary, :cause)),
          resource_type: "document",
          resource_id: id,
          before_state: nil,
          after_state: %{
            "document_type" => Map.get(summary, :document_type),
            "cause" => Map.get(summary, :cause),
            "ledger_id" => summary.ledger_id,
            "entry_id" => summary.entry_id,
            "actor_id" => actor_id
          },
          trace_id: nil
        }

      _none ->
        nil
    end
  end

  defp document_action("reversal"), do: "document.reversed"
  defp document_action("writeoff"), do: "document.written_off"
  defp document_action(_cause), do: "document.posted"
end
