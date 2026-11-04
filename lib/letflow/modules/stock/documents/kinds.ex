defmodule Letflow.Modules.Stock.Documents.Kinds do
  @moduledoc """
  REQ-715 / GH #3746: the closed table of stock document kinds (`receipt`, `issue`, `write_off`). Pure data,
  no database. `Shape`, `Documents`, `Posting` and the manifest read it, so a kind is added in one place.

  Per kind: the versioned document type key, the header and line record types, the ledger cause, the side of
  the one leg (`"to"` puts the quantity in, `"from"` takes it out), the sign of the legs in the ledger, the
  module's process definition that posts it, the offline device id (a separate (device, seq) space per kind) and
  the number prefix. The reversal definition `stock_reversal` is shared by all kinds.
  """

  @kinds [
    %{
      kind: "receipt",
      type_key: "stock_receipt",
      header_type: "stock_receipt",
      line_type: "stock_receipt_line",
      cause: "receipt",
      side: "to",
      sign: 1,
      process: "stock_receipt",
      device_id: "stock-receipt",
      prefix: "RCP"
    },
    %{
      kind: "issue",
      type_key: "stock_issue",
      header_type: "stock_issue",
      line_type: "stock_issue_line",
      cause: "issue",
      side: "from",
      sign: -1,
      process: "stock_issue",
      device_id: "stock-issue",
      prefix: "ISS"
    },
    %{
      kind: "write_off",
      type_key: "stock_writeoff",
      header_type: "stock_writeoff",
      line_type: "stock_writeoff_line",
      cause: "write_off",
      side: "from",
      sign: -1,
      process: "stock_writeoff",
      device_id: "stock-writeoff",
      prefix: "WOF"
    }
  ]

  @doc "The kinds in a fixed order."
  @spec all() :: [map()]
  def all, do: @kinds

  @doc "The row of kind `kind` (a string), or `nil`."
  @spec get(term()) :: map() | nil
  def get(kind), do: Enum.find(@kinds, &(&1.kind == kind))

  @doc "The row whose versioned document type key is `type_key`, or `nil`."
  @spec by_type_key(term()) :: map() | nil
  def by_type_key(type_key), do: Enum.find(@kinds, &(&1.type_key == type_key))

  @doc "The kind names."
  @spec kinds() :: [String.t()]
  def kinds, do: Enum.map(@kinds, & &1.kind)

  @doc "The versioned document type keys."
  @spec type_keys() :: [String.t()]
  def type_keys, do: Enum.map(@kinds, & &1.type_key)

  @doc "The header record types."
  @spec header_types() :: [String.t()]
  def header_types, do: Enum.map(@kinds, & &1.header_type)

  @doc "The names of the posting process definitions, one per kind."
  @spec process_definitions() :: [String.t()]
  def process_definitions, do: Enum.map(@kinds, & &1.process)
end
