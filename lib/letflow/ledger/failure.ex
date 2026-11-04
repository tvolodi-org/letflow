defmodule Letflow.Ledger.Failure do
  @moduledoc """
  REQ-686 / GH #3696 (slice L3c, design note 12.2): maps what a failed ledger step returned to the
  engine's failure channel (`Letflow.Engine.EntityPort.failure/0`).

    * a typed refusal `{:ledger_refused, code, wire, details}` whose code is a core code (or
      `validation_failed`) becomes `{:refused_detailed, index, code, wire, code, details}`: the
      public body carries `wire` (the module's alias when it has one) and `details`; the audit
      entry, the log and any metric carry only the neutral core `code`;
    * a contract failure `{:ledger_contract, atom}` is an internal fault, the closed
      `{:failed, index, :ledger_marker}` (no code, no detail on the wire);
    * anything else keeps the L3b closed failure `{:failed, index, :ledger_post}`, so no unknown
      code can reach the wire.

  Pure. The `details` map is never logged or inspected here.
  """

  alias Letflow.Ledger.Codes

  @spec map(non_neg_integer(), term()) :: Letflow.Engine.EntityPort.failure()
  def map(index, {:ledger_refused, code, wire, details})
      when is_atom(code) and is_binary(wire) and is_map(details) do
    if known?(code) do
      {:refused_detailed, index, code, wire, code, details}
    else
      {:failed, index, :ledger_post}
    end
  end

  def map(index, {:ledger_contract, reason}) when is_atom(reason),
    do: {:failed, index, :ledger_marker}

  def map(index, _other), do: {:failed, index, :ledger_post}

  # The membership test is by text: `Validate.refuse` builds its atoms from a closed set, so no
  # `String.to_existing_atom/1` is needed.
  defp known?(code) do
    text = Atom.to_string(code)
    text == "validation_failed" or Codes.status(text) != nil
  end
end
