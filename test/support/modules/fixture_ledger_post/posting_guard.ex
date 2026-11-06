defmodule Letflow.Modules.FixtureLedgerPost.PostingGuard do
  @moduledoc """
  REQ-764 test fixture: the posting guard of the `beta` registration of
  `Letflow.Modules.FixtureLedgerPost`. Behaviour per tenant prefix is set with `set/2`
  (`:ok` default, `{:held, label}`, `:other`, `:raise`, `:throw`, `:exit`, or `:table`: held with the
  label of the first row of the throwaway table `fxlp_hold` of the tenant, else `:ok`). Every call
  is sent to the pid given to `observe/2` as `{:guard_called, prefix, summary, facts}` where
  `facts` says whether the call ran inside a transaction and which advisory locks the connection
  held.
  """

  alias Letflow.Repo

  @spec set(String.t(), term()) :: :ok
  def set(prefix, behaviour), do: :persistent_term.put({__MODULE__, :mode, prefix}, behaviour)

  @spec observe(String.t(), pid()) :: :ok
  def observe(prefix, pid), do: :persistent_term.put({__MODULE__, :observer, prefix}, pid)

  @spec forget(String.t()) :: :ok
  def forget(prefix) do
    :persistent_term.erase({__MODULE__, :mode, prefix})
    :persistent_term.erase({__MODULE__, :observer, prefix})
    :ok
  end

  @doc false
  def check(prefix, summary) do
    case :persistent_term.get({__MODULE__, :observer, prefix}, nil) do
      nil -> :ok
      pid -> send(pid, {:guard_called, prefix, summary, facts(prefix)})
    end

    case :persistent_term.get({__MODULE__, :mode, prefix}, :ok) do
      :ok -> :ok
      {:held, _label} = held -> held
      :other -> :nope
      :raise -> raise "secret guard text"
      :throw -> throw(:secret_guard_text)
      :exit -> exit(:secret_guard_text)
      :table -> table_answer(prefix)
    end
  end

  defp table_answer(prefix) do
    case Repo.query!(~s|SELECT label FROM "#{prefix}".fxlp_hold LIMIT 1|) do
      %{rows: [[label]]} -> {:held, label}
      _none -> :ok
    end
  end

  defp facts(prefix) do
    %{rows: locks} =
      Repo.query!(
        "SELECT classid::bigint, objid::bigint FROM pg_locks WHERE pid = pg_backend_pid() AND locktype = 'advisory' AND mode = 'ShareLock' AND granted",
        []
      )

    %{rows: [[entries]]} = Repo.query!(~s|SELECT count(*) FROM "#{prefix}".ledger_entry|)
    %{in_transaction: Repo.in_transaction?(), shared_holds: locks, entries: entries}
  end
end
