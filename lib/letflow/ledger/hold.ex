defmodule Letflow.Ledger.Hold do
  @moduledoc """
  REQ-764: the advisory hold lock of one ledger id, the serialisation point between a posting
  guard (`posting_guard` of a registration, called by `Letflow.Ledger.HandlerPost` under the SHARED
  side) and the module's own change of what its guard reads (the EXCLUSIVE side,
  `Letflow.Ledger.hold_exclusive!/2`).

  The key is `hashtextextended(prefix || ':ledger_hold:' || ledger_id, 0)`, passed as ONE bound
  parameter (INV-7), so a tenant's lock is never another tenant's. Both sides are transaction-level
  locks: released at commit or rollback. Both raise `ArgumentError` outside a transaction, for a
  prefix that is not a tenant schema name and for an empty ledger id.
  """

  alias Letflow.Repo

  @prefix_form ~r/\Atenant_[0-9a-f]{32}\z/

  @spec exclusive!(String.t(), String.t()) :: :ok
  def exclusive!(prefix, ledger_id) do
    key = key!(prefix, ledger_id)
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    :ok
  end

  @spec shared!(String.t(), String.t()) :: :ok
  def shared!(prefix, ledger_id) do
    key = key!(prefix, ledger_id)
    Repo.query!("SELECT pg_advisory_xact_lock_shared(hashtextextended($1, 0))", [key])
    :ok
  end

  defp key!(prefix, ledger_id) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "Letflow.Ledger hold lock requires an open transaction"
    end

    unless is_binary(prefix) and Regex.match?(@prefix_form, prefix) and is_binary(ledger_id) and
             ledger_id != "" do
      raise ArgumentError, "Letflow.Ledger hold lock: invalid prefix or ledger id"
    end

    prefix <> ":ledger_hold:" <> ledger_id
  end
end
