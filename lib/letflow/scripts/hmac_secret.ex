defmodule Letflow.Scripts.HmacSecret do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D9, advisor Q2): the per-tenant key that the per-run record
  (7c) uses to HMAC a script's canonical input. Design section 9.

  It lives in `Letflow.Secrets` under the RESERVED `platform` namespace,
  `sec://tenant/<slug>/platform/script-input-hmac`, purpose `:script_hmac`, and is the ONLY
  caller that passes `platform: true` (a source-scan test checks that). It is created at tenant
  provisioning and by `mix letflow.backfill_script_hmac_secrets` for existing tenants, never
  lazily during a run; the plaintext is never logged or returned by `ensure/1`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Repo
  alias Letflow.Secrets
  alias Letflow.Secrets.Secret

  @namespace "platform"
  @name "script-input-hmac"
  @created_by "system:provisioning"

  @doc "The secret's name segments (for 7c and the tests)."
  @spec namespace_and_name() :: {String.t(), String.t()}
  def namespace_and_name, do: {@namespace, @name}

  @doc """
  Creates the tenant's HMAC key if it has no active one. Idempotent and safe under
  concurrency (a per-tenant advisory lock; existence is checked by tenant id, never by the
  slug-bearing reference, so a slug change cannot create a second key). Returns `:ok` or
  `{:error, reason}`.
  """
  @spec ensure(%{required(:id) => Ecto.UUID.t()}) :: :ok | {:error, term()}
  def ensure(%{id: tenant_id}) when is_binary(tenant_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["script-hmac:" <> tenant_id])

      if exists?(tenant_id) do
        :ok
      else
        case Secrets.put(
               %{
                 tenant_id: tenant_id,
                 namespace: @namespace,
                 name: @name,
                 purpose: :script_hmac,
                 plaintext: :crypto.strong_rand_bytes(32),
                 created_by: @created_by
               },
               platform: true
             ) do
          {:ok, _result} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether the tenant has an active HMAC key."
  @spec exists?(Ecto.UUID.t()) :: boolean()
  def exists?(tenant_id) do
    Repo.exists?(
      from(s in Secret,
        where:
          s.tenant_id == ^tenant_id and s.namespace == @namespace and s.name == @name and
            s.status == :active
      )
    )
  end
end
