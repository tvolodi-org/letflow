defmodule Letflow.Ledger.LockedPlan do
  @moduledoc """
  REQ-692 / GH #3725 (slice L2a rework, decision 0073 A2/A3): the opaque result of
  `Letflow.Ledger.lock_postings/1`. Holds the tenant prefix and, per ledger id, everything
  `Letflow.Ledger.write_posting/2` needs to write that posting under the locks already taken
  (locked balance rows, locked counter values, event time). A posting that was found to be a
  duplicate carries the existing entry in `duplicate` and writes nothing.

  Built only in `lib/letflow/ledger.ex`; not for callers outside the ledger core.
  """

  @enforce_keys [:prefix, :postings]
  defstruct [:prefix, :postings]

  @type t :: %__MODULE__{prefix: String.t(), postings: %{String.t() => map()}}
end
