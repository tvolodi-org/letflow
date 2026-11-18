defmodule Letflow.SharedStockAccess do
  @moduledoc """
  REQ-858 / GH #4573 (decision 0091 sections 3 to 5; Qoimeks parity G13 part 2): the life cycle of
  the tenant's shared stock access, a stock-only token for the old Qoimeks app. The context
  behind `GET`, `POST` and `DELETE /shared-stock-access` (`Letflow.Routers.Identity`).

  The value is accepted only by `verify/2`, called by `Letflow.Routers.SharedStockAccess` (REQ-859).
  Owner decision 2026-11-16: no time limit (it is revoked by an administrator), no screen.

  * `status/2`: `enabled` (the tenant slug is listed in the deployment setting
    `LETFLOW_SHARED_STOCK_ACCESS_TENANTS`, read from `config :letflow, :shared_stock_access_tenants`
    at every call), `exists` (an active row), `created_at`, `created_by`, `rotated_at`. Never the
    value or its hash.
  * `put/4`: creates when none is active, rotates when one is (same row, `created_at` kept,
    `rotated_at` set, `actor_id` kept). An empty body generates the value (64 lowercase hex
    characters, 32 random bytes as `openssl rand -hex 32`); `%{"value" => v}` stores a given value
    (the old Qoimeks token). The plaintext is returned in the `{:ok, ...}` result only, to be sent
    once; it is never stored, logged or audited (INV-4). Refused with `:not_enabled` when the
    tenant is not listed, and `:invalid_value` when a given value is not 32 to 256 printable
    ASCII characters without space (nothing changes).
  * `revoke/2`: sets `revoked_at`; allowed even when the tenant is no longer listed (the
    administrator can always clean up, decision 0091 section 3.4). `{:error, :not_found}` when
    none is active.

  Write and audit entry (`shared_stock_access.created`, `.rotated`, `.revoked`, actor and trace id,
  no value and no hash) are ONE transaction, serialised by a row lock (create races end in the
  unique index and answer `:conflict`). The tenant comes only from `prefix` (INV-1); every value
  is a bound parameter (INV-7).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Repo
  alias Letflow.SharedStockAccess.Credential

  @value_re ~r/\A[\x21-\x7E]{32,256}\z/

  @type actor :: %{user_id: Ecto.UUID.t(), trace_id: String.t() | nil}
  @type status :: %{
          enabled: boolean(),
          exists: boolean(),
          created_at: DateTime.t() | nil,
          created_by: Ecto.UUID.t() | nil,
          rotated_at: DateTime.t() | nil
        }

  @doc "True when `slug` is listed in the deployment setting."
  @spec enabled?(String.t()) :: boolean()
  def enabled?(slug) when is_binary(slug),
    do: slug in Application.get_env(:letflow, :shared_stock_access_tenants, [])

  @doc """
  Parses the setting text (comma-separated slugs, whitespace trimmed, empty entries dropped).
  Used by `config/runtime.exs`.
  """
  @spec parse_tenants(String.t() | nil) :: [String.t()]
  def parse_tenants(nil), do: []

  def parse_tenants(text) when is_binary(text),
    do: text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  @spec status(String.t(), String.t()) :: status()
  def status(prefix, slug) do
    case active(prefix) do
      nil ->
        %{
          enabled: enabled?(slug),
          exists: false,
          created_at: nil,
          created_by: nil,
          rotated_at: nil
        }

      %Credential{} = row ->
        %{
          enabled: enabled?(slug),
          exists: true,
          created_at: row.created_at,
          created_by: row.created_by_user_id,
          rotated_at: row.rotated_at
        }
    end
  end

  @spec put(String.t(), String.t(), term(), actor()) ::
          {:ok, :created | :rotated, String.t()}
          | {:error, :not_enabled | :invalid_value | :conflict | :failed}
  def put(prefix, slug, body, %{user_id: _} = actor) do
    with true <- enabled?(slug) || {:error, :not_enabled},
         {:ok, value} <- value_from(body) do
      do_put(prefix, value, actor)
    end
  end

  @spec revoke(String.t(), actor()) :: :ok | {:error, :not_found | :failed}
  def revoke(prefix, %{user_id: _} = actor) do
    multi =
      Multi.new()
      |> Multi.run(:row, fn repo, _ ->
        case lock_active(repo, prefix) do
          nil ->
            {:error, :not_found}

          row ->
            row
            |> Ecto.Changeset.change(%{
              revoked_at: DateTime.utc_now(),
              revoked_by_user_id: actor.user_id
            })
            |> repo.update(prefix: prefix)
        end
      end)
      |> audit_step("shared_stock_access.revoked", prefix, actor)

    case Repo.transaction(multi) do
      {:ok, _} -> :ok
      {:error, :row, :not_found, _} -> {:error, :not_found}
      {:error, _, _, _} -> {:error, :failed}
    end
  rescue
    _ -> {:error, :failed}
  end

  @doc """
  REQ-859: the active credential of the tenant schema `prefix` whose value hashes to `value`, or
  `:error` (no active row, a revoked or rotated-away value, a wrong value, a value over 512 bytes).
  The lookup is by the SHA-256 hex of the presented value in that tenant's own table (INV-1), then
  confirmed with a constant-time compare. Never logs or returns the value.
  """
  @spec verify(String.t(), term()) :: {:ok, Credential.t()} | :error
  def verify(prefix, value)
      when is_binary(prefix) and is_binary(value) and byte_size(value) <= 512 do
    hash = hash_value(value)

    case Repo.one(
           from(c in Credential, where: is_nil(c.revoked_at) and c.token_hash == ^hash),
           prefix: prefix
         ) do
      %Credential{token_hash: stored} = row ->
        if Plug.Crypto.secure_compare(stored, hash), do: {:ok, row}, else: :error

      nil ->
        :error
    end
  rescue
    _ -> :error
  end

  def verify(_prefix, _value), do: :error

  @doc """
  REQ-860: true when `actor_id` is the actor of an ACTIVE (not revoked) credential of tenant schema
  `prefix`. The ledger authority step asks it before it lets the shared access post (so a value
  revoked between the request and the posting is refused). Anything that is not a uuid is `false`.
  """
  @spec active_actor?(String.t(), term()) :: boolean()
  def active_actor?(prefix, actor_id) when is_binary(prefix) and is_binary(actor_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(actor_id) do
      Repo.exists?(
        from(c in Credential, where: c.actor_id == ^uuid and is_nil(c.revoked_at)),
        prefix: prefix
      )
    else
      _not_uuid -> false
    end
  rescue
    _ -> false
  end

  def active_actor?(_prefix, _actor_id), do: false

  @doc """
  REQ-860: the rule of `Letflow.Ledger.Authority` for the credential kind `:shared_access`: the
  posting is of the `stock` module, the permission the ledger registration names is `StockPost` or
  `StockReverse` (the credential holds those and `StockRead`, nothing else, decision 0091 section 2),
  and `subject_id` is the actor of an active credential of tenant schema `prefix`.
  """
  @spec may_post?(String.t(), term(), term(), term()) :: boolean()
  def may_post?(prefix, "stock", subject_id, permission)
      when permission in [:StockPost, :StockReverse],
      do: active_actor?(prefix, subject_id)

  def may_post?(_prefix, _module_id, _subject_id, _permission), do: false

  @doc """
  REQ-860: the subset of `actor_ids` that belong to a credential of tenant schema `prefix`, revoked or
  not (a stock read shows the typed operator name for them, never for a personal account).
  """
  @spec shared_actors(String.t(), [term()]) :: MapSet.t(String.t())
  def shared_actors(prefix, actor_ids) when is_binary(prefix) and is_list(actor_ids) do
    uuids =
      actor_ids
      |> Enum.flat_map(fn id ->
        case is_binary(id) && Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          _other -> []
        end
      end)
      |> Enum.uniq()

    if uuids == [] do
      MapSet.new()
    else
      from(c in Credential, where: c.actor_id in ^uuids, select: c.actor_id)
      |> Repo.all(prefix: prefix)
      |> MapSet.new()
    end
  end

  # An empty body generates the value; a body with "value" must hold a valid string.
  defp value_from(body) when body in [nil, %{}], do: {:ok, generate()}

  defp value_from(%{"value" => value}) when is_binary(value) do
    if Regex.match?(@value_re, value), do: {:ok, value}, else: {:error, :invalid_value}
  end

  defp value_from(_other), do: {:error, :invalid_value}

  defp hash_value(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp generate, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp do_put(prefix, value, actor) do
    # Same digest as `Letflow.Identity`'s token hash: lowercase hex SHA-256 of the value.
    hash = hash_value(value)

    multi =
      Multi.new()
      |> Multi.run(:row, fn repo, _ -> write(repo, prefix, hash, actor) end)
      |> Multi.run(:audit, fn repo, %{row: {kind, row}} ->
        Audit.insert_entry(repo, entry("shared_stock_access.#{kind}", row, actor), prefix)
      end)

    case Repo.transaction(multi) do
      {:ok, %{row: {kind, _row}}} -> {:ok, kind, value}
      {:error, _, _, _} -> {:error, :failed}
    end
  rescue
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      if match?(%Postgrex.Error{postgres: %{code: :unique_violation}}, e) or
           is_struct(e, Ecto.ConstraintError),
         do: {:error, :conflict},
         else: {:error, :failed}

    _other ->
      {:error, :failed}
  end

  defp write(repo, prefix, hash, actor) do
    now = DateTime.utc_now()

    case lock_active(repo, prefix) do
      nil ->
        repo.insert(
          %Credential{
            token_hash: hash,
            actor_id: Ecto.UUID.generate(),
            created_by_user_id: actor.user_id,
            created_at: now
          },
          prefix: prefix
        )
        |> tag(:created)

      %Credential{} = row ->
        row
        |> Ecto.Changeset.change(%{token_hash: hash, rotated_at: now})
        |> repo.update(prefix: prefix)
        |> tag(:rotated)
    end
  end

  defp tag({:ok, row}, kind), do: {:ok, {kind, row}}
  defp tag(other, _kind), do: other

  defp audit_step(multi, action, prefix, actor) do
    Multi.run(multi, :audit, fn repo, %{row: row} ->
      Audit.insert_entry(repo, entry(action, row, actor), prefix)
    end)
  end

  # No value and no hash: the actor, the trace id and the row id only (INV-4).
  defp entry(action, %Credential{} = row, actor) do
    %{
      actor_id: actor.user_id,
      action: action,
      resource_type: "shared_stock_access",
      resource_id: row.id,
      before_state: nil,
      after_state: %{"created_by" => row.created_by_user_id},
      trace_id: Map.get(actor, :trace_id)
    }
  end

  defp active(prefix),
    do: Repo.one(from(c in Credential, where: is_nil(c.revoked_at)), prefix: prefix)

  defp lock_active(repo, prefix) do
    repo.one(from(c in Credential, where: is_nil(c.revoked_at), lock: "FOR UPDATE"),
      prefix: prefix
    )
  end
end
