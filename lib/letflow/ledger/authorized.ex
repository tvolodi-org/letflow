defmodule Letflow.Ledger.Authorized do
  @moduledoc """
  REQ-637 part C (GH #3559): the authorised value of one ledger id.

  Minted only by `authorize/3` (part B). Part C adds the struct so `Letflow.Ledger.reconcile/2`
  can pattern-match on it; part B adds its own fields (a merge of the two keeps both sides'
  fields). `purpose` is `:read` or `:reconcile`; `reconcile/2` accepts only `:reconcile`.
  """

  @enforce_keys [:prefix, :ledger_id, :purpose]
  defstruct [:prefix, :ledger_id, :purpose]

  @type t :: %__MODULE__{
          prefix: String.t(),
          ledger_id: String.t(),
          purpose: :read | :reconcile
        }
end
