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

  # ── 7c-1: the run-time HMAC (design gh2534-7c-script-handler.md 7.2, C14, C15) ──────────

  @typedoc """
  HMAC-SHA256 of `bytes` under the tenant key, as lowercase hex plus the secret's `key_id`.
  Every crypto failure inside is a fixed `{:error, :hmac_failed}`.
  """
  @type hmac_fun :: (binary() ->
                       {:ok, {key_version :: pos_integer(), hex :: String.t()}}
                       | {:error, :hmac_failed})

  @doc """
  The tenant's newest active HMAC key, kept inside a closure (`build_hmac_fun/2`) so the
  plaintext never appears as a function argument (a crash report prints arguments, not closure
  captures). Every non-`{:ok, _}` outcome of the lookups, and any raise, is
  `{:error, :missing}`: never a bare match, so no `MatchError` can carry the plaintext into a
  log (SEC S3). NEVER calls `ensure/1` or `Letflow.Secrets.put/2` (D9 / advisor Q11: a key is
  never created lazily on the run path). Still the ONLY `platform: true` caller.
  """
  @spec hmac_fun(Ecto.UUID.t()) :: {:ok, hmac_fun()} | {:error, :missing}
  def hmac_fun(tenant_id) when is_binary(tenant_id) do
    case Letflow.Identity.get_tenant(tenant_id) do
      {:ok, %{slug: slug}} when is_binary(slug) -> resolve_key(tenant_id, slug)
      _not_found -> {:error, :missing}
    end
  rescue
    _ -> {:error, :missing}
  end

  def hmac_fun(_tenant_id), do: {:error, :missing}

  defp resolve_key(tenant_id, slug) do
    case Secrets.resolve("sec://tenant/#{slug}/#{@namespace}/#{@name}",
           tenant_id: tenant_id,
           consumer: :script_runner,
           platform: true
         ) do
      {:ok, %{plaintext: key, key_id: key_id}} when is_binary(key) and is_integer(key_id) ->
        {:ok, build_hmac_fun(key, key_id)}

      _disabled_deleted_or_absent ->
        {:error, :missing}
    end
  end

  @doc false
  # Pure: the closure over `key`. `hmac_fun/1` is its only production caller; the AC12
  # crypto-fault test builds one over a non-binary key through the dispatcher's test seam. The
  # rescue binds neither the exception nor the stacktrace.
  @spec build_hmac_fun(term(), pos_integer()) :: hmac_fun()
  def build_hmac_fun(key, key_id) do
    fn bytes ->
      try do
        mac = :crypto.mac(:hmac, :sha256, key, bytes)
        {:ok, {key_id, Base.encode16(mac, case: :lower)}}
      rescue
        _ -> {:error, :hmac_failed}
      catch
        _, _ -> {:error, :hmac_failed}
      end
    end
  end
end
