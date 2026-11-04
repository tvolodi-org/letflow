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

  `scope` is `:all` (tenant-wide reader) or `{:nodes, ids}` (REQ-693: the allowed org unit ids of
  a scoped reader, taken from `Letflow.Api.Scope.allowed_set/2` inside `authorize/3` only), and
  `scope_col` is the balance key column (`:k1`..`:k8`) of the registration's `scope_slot`, or `nil`
  when it names none. A `{:nodes, _}` value always has a `scope_col`.
  """

  @enforce_keys [:prefix, :ledger_id, :registration_name, :purpose, :slot_names]
  defstruct @enforce_keys ++ [scope: :all, scope_col: nil]

  @type t :: %__MODULE__{
          prefix: String.t(),
          ledger_id: String.t(),
          registration_name: String.t(),
          purpose: :read | :reconcile,
          slot_names: [String.t()],
          scope: :all | {:nodes, [String.t()]},
          scope_col: nil | :k1 | :k2 | :k3 | :k4 | :k5 | :k6 | :k7 | :k8
        }
end
