defmodule Letflow.Secrets do
  @moduledoc """
  Context module for the global `secrets` table: `put/2`, `resolve/2`,
  `disable/2`. See `lib/letflow/design/req190-secrets-core.md` for the full
  design this module implements, and
  `docs/migration/decisions/0016-secrets-storage-backend.md` for the
  underlying decisions (REVIEWER sign-off GRANTED 2026-08-30). Plain Ecto
  context module, no process — same shape as `Letflow.Dlq`/`Letflow.Webhooks`.

  ## Why no `opts: [prefix: ...]` (design §3.0)

  Every other tenant-scoped context module in this codebase takes
  `opts :: [prefix: String.t()]` because its table lives in a tenant schema
  and the caller must supply which schema. `secrets` is global (0016 §B) — a
  function here has no schema to select. Instead, every function that needs
  tenant scoping takes `tenant_id` directly, always the caller's own
  authenticated tenant_id, never derived from a `prefix`.

  ## Tenant isolation (INV-1's application-level substitute for this one
  ## table, 0016 §B)

  `resolve/2`'s tenant check (§3.2 step 2) is the FIRST operation after
  reference parsing, unconditionally, on every call — no code path reaches
  the `secrets` table query without first passing this check.

  ## INV-4 — secrets by reference only

  `put/2` never returns plaintext or ciphertext. `resolve/2` returns
  plaintext only in its own return value, never logged — this module never
  calls `Logger` with the resolved plaintext or any raw metadata map
  (`Letflow.Secrets.Redaction.redact_map/1` is applied globally via the
  `:logger` filter registered in `Letflow.Application`, §6.2, as defense in
  depth, but this module's own code never logs a plaintext value in the
  first place).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Identity
  alias Letflow.Repo
  alias Letflow.Secrets.Secret

  @typedoc """
  `put/2` options. `:platform` (GH 2534 7b-1): `true` only for the platform-owned secrets of
  the reserved `platform` namespace (decision 0053 D9, advisor Q2); every other caller is
  refused that namespace (`{:error, :reserved_namespace}`).
  """
  @type put_opts :: [platform: boolean()]

  # GH 2534 7b-1 (decision 0053 D9, advisor Q2): the `platform` namespace is reserved for
  # platform-owned per-tenant secrets (the script-input HMAC key). put/2, resolve/2 and
  # disable/2 refuse it unless the caller passes `platform: true`; only
  # Letflow.Scripts.HmacSecret does (source-scan tested). No tenant-facing secrets route
  # exists today; this keeps a future one from borrowing the key.
  @reserved_namespace "platform"

  @name_format ~r/^[a-z0-9_-]+$/
  @reference_format ~r/^sec:\/\/tenant\/([a-z0-9_-]+)\/([a-z0-9_-]+)\/([a-z0-9_-]+)(?:#(\d+))?$/

  # ===========================================================================
  # put/2 (design §3.1)
  # ===========================================================================

  @type put_attrs :: %{
          required(:tenant_id) => Ecto.UUID.t(),
          required(:namespace) => String.t(),
          required(:name) => String.t(),
          required(:purpose) => :webhook_hmac | :generic | :script_hmac,
          required(:plaintext) => binary(),
          required(:created_by) => String.t()
        }

  @doc """
  Envelope-encrypts `attrs.plaintext` (AES-256-GCM payload, wrapped under
  `LETFLOW_SECRETS_MASTER_KEY` with a second AES-256-GCM pass, per
  `docs/migration/decisions/0016-secrets-storage-backend.md` §D) and inserts
  a new `secrets` row. `namespace`/`name` are validated against
  `^[a-z0-9_-]+$` before any DB access.

  On a `(tenant_id, namespace, name, key_id)` unique-constraint collision
  (a concurrent `put/2` computed the same `key_id`), retries once from a
  fresh `key_id` computation; a second collision is a genuine write failure.

  Returns `{:ok, %{reference: reference, key_id: key_id, created_at:
  created_at}}` — **exactly these three keys**, never plaintext, ciphertext,
  or any other secret-shaped column. `reference` is always the **unpinned**
  form (`sec://tenant/<tenant>/<namespace>/<name>`) — a caller that needs
  the pinned form composes it from `key_id` itself
  (`"\#{reference}#\#{key_id}"`).
  """
  @spec put(put_attrs(), put_opts()) ::
          {:ok, %{reference: String.t(), key_id: pos_integer(), created_at: DateTime.t()}}
          | {:error, :invalid_namespace}
          | {:error, :invalid_name}
          | {:error, :reserved_namespace}
          | {:error, Ecto.Changeset.t()}
  def put(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with :ok <- validate_segment(Map.get(attrs, :namespace), :invalid_namespace),
         :ok <- validate_segment(Map.get(attrs, :name), :invalid_name),
         :ok <- check_reserved(Map.get(attrs, :namespace), opts) do
      do_put(attrs, retry?: true)
    end
  end

  defp validate_segment(value, error_tag) do
    if is_binary(value) and Regex.match?(@name_format, value) do
      :ok
    else
      {:error, error_tag}
    end
  end

  defp do_put(attrs, retry?: retry?) do
    tenant_id = Map.fetch!(attrs, :tenant_id)
    namespace = Map.fetch!(attrs, :namespace)
    name = Map.fetch!(attrs, :name)
    purpose = Map.fetch!(attrs, :purpose)
    plaintext = Map.fetch!(attrs, :plaintext)
    created_by = Map.fetch!(attrs, :created_by)

    master_key = master_key!()
    created_at = current_timestamp()

    Multi.new()
    |> Multi.run(:key_id, fn repo, _changes ->
      {:ok, next_key_id(repo, tenant_id, namespace, name)}
    end)
    |> Multi.run(:secret, fn repo, %{key_id: key_id} ->
      insert_secret(
        repo,
        %{
          tenant_id: tenant_id,
          namespace: namespace,
          name: name,
          key_id: key_id,
          purpose: purpose,
          created_by: created_by,
          created_at: created_at
        },
        plaintext,
        master_key
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{secret: secret}} ->
        {:ok,
         %{
           reference: unpinned_reference(tenant_slug!(tenant_id), namespace, name),
           key_id: secret.key_id,
           created_at: secret.created_at
         }}

      {:error, :secret, %Ecto.Changeset{} = changeset, _changes} ->
        if retry? and unique_key_id_conflict?(changeset) do
          do_put(attrs, retry?: false)
        else
          {:error, changeset}
        end

      {:error, _failed_step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp next_key_id(repo, tenant_id, namespace, name) do
    query =
      from(s in Secret,
        where: s.tenant_id == ^tenant_id and s.namespace == ^namespace and s.name == ^name,
        select: coalesce(max(s.key_id), 0)
      )

    (repo.one(query) || 0) + 1
  end

  defp insert_secret(repo, base_attrs, plaintext, master_key) do
    aad =
      build_aad(base_attrs.tenant_id, base_attrs.namespace, base_attrs.name, base_attrs.purpose)

    data_key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, auth_tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, data_key, nonce, plaintext, aad, true)

    wrap_nonce = :crypto.strong_rand_bytes(12)

    {wrapped_data_key, wrap_auth_tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, master_key, wrap_nonce, data_key, "", true)

    # Best-effort only -- Erlang binaries are immutable, so this rebinds the
    # variable rather than wiping memory in place; the BEAM has no primitive
    # for a true in-place wipe (design §3.1 step 2i).
    _data_key = <<0::256>>

    insert_attrs =
      Map.merge(base_attrs, %{
        status: :active,
        algorithm: :aes_256_gcm,
        wrapped_key_algorithm: :aes_256_gcm,
        ciphertext: ciphertext,
        wrapped_data_key: wrapped_data_key,
        nonce: nonce,
        wrap_nonce: wrap_nonce,
        auth_tag: auth_tag,
        wrap_auth_tag: wrap_auth_tag,
        aad: aad,
        wrapping_key_ref: "env:LETFLOW_SECRETS_MASTER_KEY",
        wrapping_key_version: 1
      })

    %Secret{}
    |> Secret.insert_changeset(insert_attrs)
    |> repo.insert()
  end

  defp build_aad(tenant_id, namespace, name, purpose) do
    "#{tenant_id}:#{namespace}:#{name}:#{purpose}"
  end

  defp unique_key_id_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == "secrets_tenant_namespace_name_key_id_index"

      _ ->
        false
    end)
  end

  defp unpinned_reference(tenant_slug, namespace, name) do
    "sec://tenant/#{tenant_slug}/#{namespace}/#{name}"
  end

  # ===========================================================================
  # resolve/2 (design §3.2)
  # ===========================================================================

  @type resolve_opts :: [
          tenant_id: Ecto.UUID.t(),
          consumer: :webhook_dispatcher | :generic | :script_runner,
          platform: boolean()
        ]

  @doc """
  Resolves a `sec://tenant/...` reference to its current plaintext.

  Behavior, in order (0016's own `resolveSecret` ordering, preserved
  exactly):

  1. Parse `reference` — no match against
     `^sec://tenant/([a-z0-9_-]+)/([a-z0-9_-]+)/([a-z0-9_-]+)(?:#(\\d+))?$` →
     `{:error, :invalid_reference}`, no query run at all.
  2. Tenant check, **before any query**: the reference's own tenant segment
     must resolve to a known tenant AND match `opts[:tenant_id]` — both "no
     such tenant" and "different tenant" return the same
     `{:error, :tenant_mismatch}`, so the error never discloses whether the
     named secret exists.
  3. Purpose/consumer matrix, applied against the fetched row (`purpose` is
     an output of the row, not knowable beforehand): `:webhook_dispatcher`
     may resolve `:webhook_hmac` or `:generic`; `:generic` (the default when
     `opts[:consumer]` is omitted) may resolve `:generic` only.
  4. Row lookup: pinned (`#<key_id>` present) looks up that exact version
     regardless of `:active`/`:disabled` status (but `:deleted` still fails
     with `{:error, :deleted}`); unpinned selects the newest `:active` row,
     filtered in-query.
  5. Decrypt (unwrap the data key under the master key, then decrypt the
     payload) — a GCM authentication failure on either step is treated as an
     internal-consistency failure and raises, rather than returning a
     graceful `{:error, _}` (design §3.2 step 6c).

  Returns `{:ok, %{plaintext: plaintext, key_id: key_id, purpose: purpose}}`.
  """
  @spec resolve(reference :: String.t(), resolve_opts()) ::
          {:ok,
           %{
             plaintext: binary(),
             key_id: pos_integer(),
             purpose: :webhook_hmac | :generic | :script_hmac
           }}
          | {:error, :invalid_reference}
          | {:error, :reserved_namespace}
          | {:error, :tenant_mismatch}
          | {:error, :not_found}
          | {:error, :purpose_not_allowed}
          | {:error, :disabled}
          | {:error, :deleted}
  def resolve(reference, opts) when is_binary(reference) and is_list(opts) do
    caller_tenant_id = Keyword.fetch!(opts, :tenant_id)
    consumer = Keyword.get(opts, :consumer, :generic)

    with {:ok, tenant_slug, namespace, name, key_id_segment} <- parse_reference(reference),
         :ok <- check_reserved(namespace, opts),
         :ok <- check_tenant_match(tenant_slug, caller_tenant_id),
         {:ok, secret} <- fetch_secret(caller_tenant_id, namespace, name, key_id_segment),
         :ok <- check_purpose_allowed(consumer, secret.purpose) do
      decrypt(secret)
    end
  end

  defp check_reserved(@reserved_namespace, opts) do
    if Keyword.get(opts, :platform) == true, do: :ok, else: {:error, :reserved_namespace}
  end

  defp check_reserved(_namespace, _opts), do: :ok

  defp parse_reference(reference) do
    case Regex.run(@reference_format, reference) do
      [_full, tenant_slug, namespace, name] ->
        {:ok, tenant_slug, namespace, name, nil}

      [_full, tenant_slug, namespace, name, key_id_str] ->
        {:ok, tenant_slug, namespace, name, String.to_integer(key_id_str)}

      nil ->
        {:error, :invalid_reference}
    end
  end

  defp check_tenant_match(tenant_slug, caller_tenant_id) do
    case Identity.get_tenant_by_slug(tenant_slug) do
      {:ok, %{id: ^caller_tenant_id}} -> :ok
      {:ok, %{id: _other}} -> {:error, :tenant_mismatch}
      {:error, :not_found} -> {:error, :tenant_mismatch}
    end
  end

  defp fetch_secret(tenant_id, namespace, name, nil) do
    query =
      from(s in Secret,
        where:
          s.tenant_id == ^tenant_id and s.namespace == ^namespace and s.name == ^name and
            s.status == :active,
        order_by: [desc: s.created_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Secret{} = secret -> {:ok, secret}
    end
  end

  defp fetch_secret(tenant_id, namespace, name, key_id) when is_integer(key_id) do
    query =
      from(s in Secret,
        where:
          s.tenant_id == ^tenant_id and s.namespace == ^namespace and s.name == ^name and
            s.key_id == ^key_id
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Secret{status: :deleted} -> {:error, :deleted}
      %Secret{} = secret -> {:ok, secret}
    end
  end

  defp check_purpose_allowed(:webhook_dispatcher, purpose)
       when purpose in [:webhook_hmac, :generic],
       do: :ok

  defp check_purpose_allowed(:generic, :generic), do: :ok
  # GH 2534 7b-1: only the script runner may resolve the script-input HMAC key, and it may
  # resolve nothing else.
  defp check_purpose_allowed(:script_runner, :script_hmac), do: :ok
  defp check_purpose_allowed(_consumer, _purpose), do: {:error, :purpose_not_allowed}

  defp decrypt(%Secret{} = secret) do
    master_key = master_key!()

    data_key =
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             master_key,
             secret.wrap_nonce,
             secret.wrapped_data_key,
             "",
             secret.wrap_auth_tag,
             false
           ) do
        :error ->
          raise "Letflow.Secrets.resolve/2: key-wrap GCM authentication failed for secret #{secret.id} -- corrupted row or master-key mismatch"

        decoded ->
          decoded
      end

    plaintext =
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             data_key,
             secret.nonce,
             secret.ciphertext,
             secret.aad,
             secret.auth_tag,
             false
           ) do
        :error ->
          raise "Letflow.Secrets.resolve/2: payload GCM authentication failed for secret #{secret.id} -- corrupted row or master-key mismatch"

        decoded ->
          decoded
      end

    {:ok, %{plaintext: plaintext, key_id: secret.key_id, purpose: secret.purpose}}
  end

  # ===========================================================================
  # disable/2 (design §3.3)
  # ===========================================================================

  @type disable_opts :: [tenant_id: Ecto.UUID.t(), platform: boolean()]

  @doc """
  Disables a specific **pinned** secret version (`#<key_id>` required in
  `reference_pinned` — this function never disables "the newest version" by
  an unpinned reference). Sets `status: :disabled, disabled_at: <now>` via a
  changeset that casts only `:status, :disabled_at` — `created_by` is never
  overwritten (structurally impossible, `Secret.disable_changeset/2` never
  casts it).

  `{:error, :already_disabled}` if the row's `status` is already
  `:disabled` or `:deleted` — a repeated `disable/2` call is not silently
  treated as success.
  """
  @spec disable(reference_pinned :: String.t(), disable_opts()) ::
          {:ok, %{key_id: pos_integer(), disabled_at: DateTime.t()}}
          | {:error, :invalid_reference}
          | {:error, :reserved_namespace}
          | {:error, :tenant_mismatch}
          | {:error, :not_found}
          | {:error, :already_disabled}
  def disable(reference_pinned, opts) when is_binary(reference_pinned) and is_list(opts) do
    caller_tenant_id = Keyword.fetch!(opts, :tenant_id)

    with {:ok, tenant_slug, namespace, name, key_id} when is_integer(key_id) <-
           parse_reference(reference_pinned),
         :ok <- check_reserved(namespace, opts),
         :ok <- check_tenant_match(tenant_slug, caller_tenant_id),
         {:ok, secret} <- fetch_pinned_for_disable(caller_tenant_id, namespace, name, key_id),
         :ok <- check_not_already_disabled(secret) do
      disabled_at = current_timestamp()

      secret
      |> Secret.disable_changeset(%{status: :disabled, disabled_at: disabled_at})
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, %{key_id: updated.key_id, disabled_at: updated.disabled_at}}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:ok, _tenant_slug, _namespace, _name, nil} -> {:error, :invalid_reference}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_pinned_for_disable(tenant_id, namespace, name, key_id) do
    query =
      from(s in Secret,
        where:
          s.tenant_id == ^tenant_id and s.namespace == ^namespace and s.name == ^name and
            s.key_id == ^key_id
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Secret{} = secret -> {:ok, secret}
    end
  end

  defp check_not_already_disabled(%Secret{status: status}) when status in [:disabled, :deleted] do
    {:error, :already_disabled}
  end

  defp check_not_already_disabled(%Secret{}), do: :ok

  # ── shared helpers ──────────────────────────────────────────────────────

  defp master_key! do
    Application.fetch_env!(:letflow, :secrets_master_key)
  end

  defp tenant_slug!(tenant_id) do
    case Repo.get(Letflow.Identity.Tenant, tenant_id) do
      %{slug: slug} ->
        slug

      nil ->
        raise "Letflow.Secrets.put/2: tenant_id #{tenant_id} does not correspond to any known tenant"
    end
  end

  defp current_timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
