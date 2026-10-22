defmodule Letflow.Identity.PlatformAdminTokens do
  @moduledoc """
  GH 2579 -- standing PLATFORM_ADMIN API tokens with no expiry. Legacy rows minted before
  GH 2552 capped the lifetime can still have `expires_at` NULL: full-platform credentials that
  nobody reviews. This module is the operator's way to see them and to replace one.

    * `inventory/1` is a read-only query over one tenant schema.
    * `reissue/4` is the explicit act for ONE token: it mints a replacement with an expiry inside
      `:platform_admin_token_max_ttl_days`, writes the replacement's plaintext to an
      operator-named file, and revokes the old token last.

  Both are reached through `Letflow.Release` (`platform_admin_token_inventory/1` and
  `reissue_platform_admin_token/4`), see `docs/runbooks/platform-admin-token-reissue.md`. There is
  no function that takes more than one token id, and nothing revokes on its own: no mass revoke.

  ## Secrets (INV-4)

  The inventory selects only the ids, roles and timestamps it reports: `token_hash` and `name`
  are never read. `reissue/4` returns no plaintext. The new value goes only to the file, which
  is created exclusively (an existing file is never overwritten) and restricted to its owner
  (mode 0600, POSIX only) BEFORE anything is minted, so a file problem refuses the act with no
  token minted and none revoked.

  ## Order of the act (`reissue/4`)

  1. Resolve the tenant; 2. load the token (must exist, be live, carry PLATFORM_ADMIN and have no
  expiry); 3. the operator must be an active PLATFORM_ADMIN member of the tenant; 4. validate
  `cause`, `days` and the path; 5. create the plaintext file exclusively. Steps 1-5 write nothing.
  6. Mint the replacement as the OWNER (`Letflow.Identity.mint_token/4` allows a PLATFORM_ADMIN
  token only for its issuer); 7. write the plaintext; 8. revoke the old token. A write failure
  after the mint revokes the NEW token; a revoke failure after the mint keeps the file, which
  holds the live new token.
  """

  import Ecto.Query

  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.AuditContext
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @seconds_per_day 86_400
  @max_cause_bytes 200
  @control_char ~r/\p{Cc}/u

  @type inventory_row :: %{
          id: Ecto.UUID.t(),
          owner_user_id: Ecto.UUID.t(),
          issuer_user_id: Ecto.UUID.t() | nil,
          created_at: DateTime.t(),
          last_used_at: DateTime.t() | nil
        }

  @doc """
  The live (not revoked) PLATFORM_ADMIN tokens with no expiry in `prefix`'s schema, oldest first.
  `issuer_user_id` is `nil` for a legacy row (no issuer recorded). Read-only: one `SELECT`
  inside a transaction, so a broken schema rolls back cleanly (the exception propagates).
  """
  @spec inventory(prefix :: String.t()) :: [inventory_row()]
  def inventory(prefix) do
    query =
      from(t in ApiToken,
        where: is_nil(t.expires_at) and is_nil(t.revoked_at) and ^"PLATFORM_ADMIN" in t.roles,
        order_by: [asc: t.inserted_at, asc: t.id],
        select: %{
          id: t.id,
          owner_user_id: t.user_id,
          issuer_user_id: t.issuer_user_id,
          created_at: t.inserted_at,
          last_used_at: t.last_used_at
        }
      )

    {:ok, rows} = Repo.transaction(fn -> Repo.all(query, prefix: prefix) end)
    Enum.map(rows, &to_utc/1)
  end

  defp to_utc(%{created_at: %NaiveDateTime{} = created} = row),
    do: %{row | created_at: DateTime.from_naive!(created, "Etc/UTC")}

  @doc """
  Replaces ONE non-expiring PLATFORM_ADMIN token (see the moduledoc for the order).

  Options: `:cause` (required; the reason, stored as the audit `cause` of both entries; at most
  200 bytes, no control characters), `:days` (default the cap, 1..cap), `:plaintext_file`
  (required; must not exist), and `:write_plaintext` (tests only: replaces the file writer).

  Returns `{:ok, %{old_token_id, new_token_id, owner_user_id, expires_at, plaintext_file}}`.
  Errors: `:unknown_tenant`, `:not_found`, `:already_revoked`, `:not_non_expiring_platform_admin`,
  `:operator_not_platform_admin`, `:invalid_cause`, `:invalid_days`, `:invalid_plaintext_file`,
  `:plaintext_file_exists`, `{:plaintext_file, posix}`, the mint errors of `mint_token/4`,
  `{:plaintext_write_failed, new_id, posix}` (the new token was revoked again; with a fourth
  element `{:compensate_failed, reason}` when that revoke failed too), and
  `{:revoke_failed, new_id, reason}` (the file is kept).
  """
  @spec reissue(
          tenant_id :: String.t(),
          token_id :: String.t(),
          operator_id :: String.t(),
          opts :: keyword()
        ) :: {:ok, map()} | {:error, term()}
  def reissue(tenant_id, token_id, operator_id, opts) do
    with {:ok, prefix} <- resolve_tenant(tenant_id),
         {:ok, token} <- load_token(prefix, token_id),
         :ok <- check_operator(operator_id, prefix),
         {:ok, input} <- validate_input(opts),
         {:ok, io} <- open_plaintext_file(input.plaintext_file) do
      replace(prefix, token, operator_id, input, io)
    end
  end

  defp resolve_tenant(tenant_id) do
    with {:ok, canonical} <- Ecto.UUID.cast(tenant_id),
         {:ok, schema} <- TenantProvisioning.registered_schema(canonical) do
      {:ok, schema}
    else
      _ -> {:error, :unknown_tenant}
    end
  end

  defp load_token(prefix, token_id) do
    with {:ok, id} <- Ecto.UUID.cast(token_id),
         %ApiToken{} = token <- Repo.get(ApiToken, id, prefix: prefix) do
      cond do
        not is_nil(token.revoked_at) ->
          {:error, :already_revoked}

        not ApiToken.non_expiring_platform_admin?(token) ->
          {:error, :not_non_expiring_platform_admin}

        true ->
          {:ok, token}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  # The operator is the audit actor. Membership alone is not enough: the user must be active.
  defp check_operator(operator_id, prefix) do
    if Identity.platform_admin_member?(operator_id, prefix: prefix) and
         operator_active?(operator_id, prefix),
       do: :ok,
       else: {:error, :operator_not_platform_admin}
  end

  defp operator_active?(operator_id, prefix) do
    case Repo.get(User, operator_id, prefix: prefix) do
      %User{} = user -> Identity.active_user?(user)
      nil -> false
    end
  end

  defp validate_input(opts) do
    cap = Identity.platform_admin_token_max_ttl_days()
    days = Keyword.get(opts, :days, cap)

    with {:ok, cause} <- validate_cause(Keyword.get(opts, :cause)),
         :ok <- validate_days(days, cap),
         {:ok, path} <- validate_path(Keyword.get(opts, :plaintext_file)) do
      {:ok,
       %{
         cause: cause,
         days: days,
         plaintext_file: path,
         write_plaintext: Keyword.get(opts, :write_plaintext, &write_plaintext/2)
       }}
    end
  end

  defp validate_cause(cause) when is_binary(cause) do
    trimmed = String.trim(cause)

    if trimmed != "" and byte_size(trimmed) <= @max_cause_bytes and String.valid?(trimmed) and
         not Regex.match?(@control_char, trimmed),
       do: {:ok, trimmed},
       else: {:error, :invalid_cause}
  end

  defp validate_cause(_cause), do: {:error, :invalid_cause}

  defp validate_days(days, cap) when is_integer(days) and days >= 1 and days <= cap, do: :ok
  defp validate_days(_days, _cap), do: {:error, :invalid_days}

  defp validate_path(path) when is_binary(path) and path != "", do: {:ok, path}
  defp validate_path(_path), do: {:error, :invalid_plaintext_file}

  # Step 5: the file is created here, before any DB write. `:exclusive` never overwrites. The mode is
  # then restricted to the owner (0600) before anything is minted: the default umask would leave a
  # full-platform credential readable by other local users. If the restriction fails, nothing is minted.
  defp open_plaintext_file(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} -> restrict_plaintext_file(io, path)
      {:error, :eexist} -> {:error, :plaintext_file_exists}
      {:error, posix} -> {:error, {:plaintext_file, posix}}
    end
  end

  defp restrict_plaintext_file(io, path) do
    case File.chmod(path, 0o600) do
      :ok ->
        {:ok, io}

      {:error, posix} ->
        discard_file(io, path)
        {:error, {:plaintext_file, posix}}
    end
  end

  # Steps 6-8. Every failure path that follows the mint says what happened to the new token.
  defp replace(prefix, token, operator_id, input, io) do
    owner_id = token.user_id
    expires_at = DateTime.utc_now() |> DateTime.add(input.days * @seconds_per_day, :second)
    expires_at = DateTime.truncate(expires_at, :second)
    audit = audit_context(operator_id)

    attrs = %{roles: token.roles, expires_at: expires_at}

    case Identity.mint_token(owner_id, owner_id, attrs,
           prefix: prefix,
           audit_context: audit,
           cause: input.cause
         ) do
      {:error, reason} ->
        discard_file(io, input.plaintext_file)
        {:error, reason}

      {:ok, %{token: new_token, plaintext: plaintext}} ->
        case write_and_close(io, plaintext, input.write_plaintext) do
          :ok ->
            revoke_old(prefix, token, new_token, expires_at, input, audit)

          {:error, posix} ->
            compensate(prefix, new_token, posix, input, audit)
        end
    end
  end

  # One trace id for both audit entries of the act: the Logger trace of the CLI run when there is
  # one (`Letflow.Obs.Logger.with_trace/1`), else a fresh id.
  defp audit_context(operator_id) do
    %{
      actor_id: operator_id,
      trace_id: AuditContext.current_trace_id() || Ecto.UUID.generate()
    }
  end

  defp write_and_close(io, plaintext, write_plaintext) do
    case write_plaintext.(io, plaintext) do
      :ok ->
        File.close(io)

      {:error, posix} ->
        File.close(io)
        {:error, posix}
    end
  end

  defp write_plaintext(io, plaintext) do
    with :ok <- IO.binwrite(io, plaintext), do: :file.sync(io)
  end

  defp compensate(prefix, new_token, posix, input, audit) do
    revoked =
      Identity.revoke_token(new_token.id,
        prefix: prefix,
        audit_context: audit,
        cause: input.cause
      )

    File.rm(input.plaintext_file)

    case revoked do
      {:ok, _} ->
        {:error, {:plaintext_write_failed, new_token.id, posix}}

      {:error, reason} ->
        {:error, {:plaintext_write_failed, new_token.id, posix, {:compensate_failed, reason}}}
    end
  end

  defp revoke_old(prefix, old_token, new_token, expires_at, input, audit) do
    case Identity.revoke_token(old_token.id,
           prefix: prefix,
           audit_context: audit,
           cause: input.cause
         ) do
      {:ok, _} ->
        {:ok,
         %{
           old_token_id: old_token.id,
           new_token_id: new_token.id,
           owner_user_id: old_token.user_id,
           expires_at: expires_at,
           plaintext_file: input.plaintext_file
         }}

      {:error, reason} ->
        {:error, {:revoke_failed, new_token.id, reason}}
    end
  end

  defp discard_file(io, path) do
    File.close(io)
    File.rm(path)
  end
end
