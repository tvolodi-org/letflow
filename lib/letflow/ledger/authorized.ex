defmodule Letflow.Ledger.Authorized do
  @moduledoc """
  REQ-637 / GH #3559 part B (slice L2b): the authorized value of the read side of the core
  ledger. The only way to get one is `Letflow.Ledger.authorize/3`; `balances/4`, `entries/3` and
  (part C) `reconcile/2` accept nothing else, and take the tenant schema prefix and the ledger
  id from it, never from a caller map.

  `slot_names` is the ordered list of the slot names of the registration of the ledger id; the
  closed filter key set of `balances/4` is derived from it, so a read never goes back to the
  registry. `purpose` is `:read` or `:reconcile`.

  Elixir structs are not opaque at runtime. The control that nothing outside the ledger files
  builds one is a source scan test (`authorize_test.exs`, T-AZ-8).
  """

  @enforce_keys [:prefix, :ledger_id, :registration_name, :purpose, :slot_names]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          prefix: String.t(),
          ledger_id: String.t(),
          registration_name: String.t(),
          purpose: :read | :reconcile,
          slot_names: [String.t()]
        }
end
