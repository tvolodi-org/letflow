defmodule Letflow.Identity.PasswordResetThrottle do
  @moduledoc """
  REQ-814 (F4-4): per-user throttle for `POST /users/:id/reset-password`.

  Kept out of the route layer, which holds no `Repo.` call (INV-RT-1). An advisory lock keyed on
  tenant schema and user id serialises concurrent requests for one user; the latest
  `user.password_reset_requested` audit entry is read and the new one inserted in the same
  transaction (`Audit.insert_entry/3` joins it). The caller starts the delivery after the commit.
  """

  alias Letflow.Audit

  @doc """
  Returns `{:ok, {:sent, entry}}` when a new entry was written, `{:ok, :throttled}` when the
  user's latest entry is newer than `window` minutes (nothing written), or
  `{:error, :audit_failed}`.
  """
  @spec request(map(), map(), String.t(), pos_integer()) ::
          {:ok, {:sent, map()} | :throttled} | {:error, :audit_failed}
  def request(user, attrs, prefix, window) do
    Letflow.Repo.transaction(fn ->
      Letflow.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [prefix <> ":" <> user.id])

      cutoff = DateTime.add(DateTime.utc_now(), -window * 60, :second)

      case Audit.latest_matching(prefix, "user", user.id, [attrs.action]) do
        %{timestamp: ts} when not is_nil(ts) ->
          if DateTime.compare(ts, cutoff) == :gt,
            do: :throttled,
            else: insert_entry(attrs, prefix)

        _none ->
          insert_entry(attrs, prefix)
      end
    end)
  rescue
    _exception -> {:error, :audit_failed}
  end

  defp insert_entry(attrs, prefix) do
    case Audit.insert_entry(Letflow.Repo, attrs, prefix) do
      {:ok, entry} -> {:sent, entry}
      {:error, reason} -> Letflow.Repo.rollback(reason)
    end
  end
end
