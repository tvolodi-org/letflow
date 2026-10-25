defmodule Letflow.Documents.DocumentSequence do
  @moduledoc """
  Persistence shape of a `document_sequences` row (REQ-500, GH #2588, decision 0056 D2).

  One counter per (type, legal entity or sentinel, period). `legal_entity_key` holds
  the legal entity uuid as text, or the zero-UUID sentinel of `Letflow.Documents.Canonical.legal_entity_sentinel/0` for a type declared
  `legal_entity_required = false`. The counter only grows (trigger
  `document_sequences_guard_update`). The writer is the `Letflow.Documents` context
  (PR B), which allocates numbers under the sequence row lock.
  """

  use Ecto.Schema

  @primary_key false

  schema "document_sequences" do
    field(:tenant_id, :binary_id)
    field(:type_key, :string, primary_key: true)
    field(:legal_entity_key, :string, primary_key: true)
    field(:period, :string, primary_key: true)
    field(:counter, :integer, default: 0)
  end
end
