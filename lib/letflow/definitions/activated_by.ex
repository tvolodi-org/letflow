defmodule Letflow.Definitions.ActivatedBy do
  @moduledoc """
  T-0250 / GH #2644 (design `state/tasks/T-0250/design.md`, option (a)): the signature on the
  `process_definitions.activated_by` document.

  The document is the recorded authority the run-time entity-write path trusts
  (`Letflow.Engine`, `recorded_activator/2`). Its column is plain jsonb, so anything that can
  write the row (a raw `UPDATE`, a future writer bug) could forge it. This module signs the
  document when a path makes a definition ACTIVE (activation, rollback, promotion) and verifies
  the signature at use. Nothing else signs, so a row that was never signed is refused at use.

  ## What the MAC covers

      mac = HMAC-SHA256(key, "letflow/activated-by/v1" <> <<0>> <> canonical)
      canonical = canonical_json(%{definition_id, version, graph_hash, document})

  `document` is the stored document without its `"signature"` key. The definition id, version
  and graph hash are inside the MAC, so a document copied to another definition, version or
  graph, or a graph edited after activation, fails verification. The key is per tenant, so a
  copy to another tenant fails too.

  ## The key

  A per-tenant secret `platform/activated-by-hmac` (purpose `:generic`) in `Letflow.Secrets`,
  referenced by name (INV-4). It is its own key, not the script-input key, so a leak in one
  domain cannot forge the other. Plaintext never leaves the functions here: not in a row, a
  log, or an error.

  The key is created by `ensure/1` on the SIGNING path only (activate, rollback, promotion).
  Verification only resolves it, so the read path never creates a key.

  ## Key version rule

  Both signing and verification use the UNPINNED reference, which resolves the newest ACTIVE
  version. A document verifies only when its `key_version` equals the resolved `key_id` and the
  MAC matches. So rotation (a new version) and disabling the newest version both refuse the
  documents signed under the version they replace. The rotation procedure is: put the new
  version, then disable the old one.

  ## Not covered by this signature

  - Compromise of the tenant's signing key: whoever holds it can mint documents.
  - Replay of an old, validly signed document of the same definition, version and graph. The
    signature binds the row, not the time; `activated_at` inside the document is informational.
  - A superuser or migration that can read the key row (the key is wrapped under
    `LETFLOW_SECRETS_MASTER_KEY`, so the master-key holder is also in scope).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Identity
  alias Letflow.Repo
  alias Letflow.Secrets
  alias Letflow.Secrets.Secret
  alias Letflow.TenantProvisioning

  @namespace "platform"
  @name "activated-by-hmac"
  @created_by "system:activated-by"
  @alg "HMAC-SHA256"
  @label "letflow/activated-by/v1"

  @typedoc "A definition row (or any map with `id`, `version` and `graph`)."
  @type row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:version) => String.t(),
          required(:graph) => map()
        }

  @doc """
  Creates the tenant's signing key if it has no active one. Idempotent and safe under
  concurrency (a per-tenant advisory lock, existence checked by tenant id). Returns `:ok` or
  `{:error, reason}`. Signing path only.
  """
  @spec ensure(%{required(:id) => Ecto.UUID.t()}) :: :ok | {:error, term()}
  def ensure(%{id: tenant_id}) when is_binary(tenant_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
        "activated-by-hmac:" <> tenant_id
      ])

      if exists?(tenant_id) do
        :ok
      else
        case Secrets.put(
               %{
                 tenant_id: tenant_id,
                 namespace: @namespace,
                 name: @name,
                 purpose: :generic,
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

  @doc """
  Signs `record` (the activated_by document, without a signature) for `row` in `prefix`.
  Returns `{:ok, signed_record}` or `{:error, reason}`; the caller rolls back on error, so the
  row is never made ACTIVE unsigned. Ensures the key first (signing path only).
  """
  @spec sign(map(), row(), String.t()) :: {:ok, map()} | {:error, term()}
  def sign(record, row, prefix) when is_map(record) and is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         :ok <- ensure(%{id: tenant_id}),
         {:ok, key} <- resolve_key_safely(tenant_id) do
      signature = %{
        "alg" => @alg,
        "key_version" => key.key_id,
        "mac" => mac(key.plaintext, row, record)
      }

      {:ok, Map.put(record, "signature", signature)}
    end
  end

  @doc """
  Verifies the stored `activated_by` document of `row` in `prefix` (reader side).

  - `{:error, :unsigned}`: no well-formed `signature` key (a pre-deploy or forged document).
  - `{:error, :no_key}`: the tenant has no resolvable key. Never creates one. A resolve that
    raises (corrupted row, master-key mismatch) is `:no_key` too, so the completion does not
    crash (INV-8).
  - `{:error, :mismatch}`: the key version is not the resolved one, or the MAC differs.
  """
  @spec verify(term(), row(), String.t()) ::
          {:ok, :verified} | {:error, :unsigned | :mismatch | :no_key}
  def verify(
        %{"signature" => %{"alg" => @alg, "key_version" => version, "mac" => mac}} = activated_by,
        row,
        prefix
      )
      when is_integer(version) and is_binary(mac) and is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, key} <- resolve_key_safely(tenant_id),
         :ok <- check_key_version(key, version),
         expected = mac(key.plaintext, row, Map.delete(activated_by, "signature")),
         true <- :crypto.hash_equals(expected, mac) do
      {:ok, :verified}
    else
      {:error, :no_key} -> {:error, :no_key}
      _mismatch_or_bad_prefix -> {:error, :mismatch}
    end
  end

  def verify(_activated_by, _row, _prefix), do: {:error, :unsigned}

  defp check_key_version(%{key_id: key_id}, version) when key_id == version, do: :ok
  defp check_key_version(_key, _version), do: :mismatch

  defp resolve_key(tenant_id) do
    with {:ok, %{slug: slug}} <- Identity.get_tenant(tenant_id),
         {:ok, %{plaintext: plaintext, key_id: key_id}} <-
           Secrets.resolve(reference(slug),
             tenant_id: tenant_id,
             consumer: :generic,
             platform: true
           ) do
      {:ok, %{plaintext: plaintext, key_id: key_id}}
    else
      _missing_or_failed -> {:error, :no_key}
    end
  end

  # Rescues here, for signing and verifying alike: `Secrets.resolve/2` raises on a GCM failure (INV-8). The
  # rescue binds neither the exception nor the stacktrace, so no plaintext can reach a log.
  defp resolve_key_safely(tenant_id) do
    resolve_key(tenant_id)
  rescue
    _ -> {:error, :no_key}
  catch
    _, _ -> {:error, :no_key}
  end

  defp reference(slug), do: "sec://tenant/#{slug}/#{@namespace}/#{@name}"

  # HMAC-SHA256 over the domain label and the canonical JSON of the binding and the document.
  defp mac(key, row, document) do
    canonical =
      OwnerStamp.canonical_json(%{
        "definition_id" => row.id,
        "version" => row.version,
        "graph_hash" => OwnerStamp.graph_hash(row.graph),
        "document" => document
      })

    :crypto.mac(:hmac, :sha256, key, @label <> <<0>> <> canonical)
    |> Base.encode16(case: :lower)
  end

  defp exists?(tenant_id) do
    Repo.exists?(
      from(s in Secret,
        where:
          s.tenant_id == ^tenant_id and s.namespace == @namespace and s.name == @name and
            s.status == :active
      )
    )
  end
end
