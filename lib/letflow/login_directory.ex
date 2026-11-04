defmodule Letflow.LoginDirectory do
  @moduledoc """
  Platform tenant-login directory context (REQ-435; design
  `lib/letflow/design/req434-email-first-login-directory.md` §1-§5, decision
  `docs/migration/decisions/0042-email-first-login-tenant-directory.md`).

  Maintains and reads `tenant_login_directory`
  (`Letflow.Identity.TenantLoginDirectoryEntry`): a public-schema pointer table
  of `(email_key, tenant_id)` pairs answering "which tenants hold an active user
  with this email". It builds only the data layer and its population; the
  limiter, the public lookup route and the SPA are later requirements.

  ## Key form

  `email_key = HMAC-SHA256(pepper, "letflow:login-directory:v1:" <> normalised_email)`,
  32 raw bytes, where the normalised email is
  `Letflow.Identity.TenantMembership.normalize_subject_key/1` (one shared
  implementation, never forked). Peppers are read at the point of use from
  `config :letflow, :login_directory_keys` (`[current: slot, previous: slot | nil]`,
  `slot = %{id, pepper}`; populated at boot from the `LETFLOW_LOGIN_DIRECTORY_PEPPER*`
  environment-variable references by `config/runtime.exs`, which fails closed).
  A pepper is never logged, stored in a struct or returned; only the key **id**
  (a label) may be returned (0043 D-C).

  `email_key/1` and `sentinel_key/0` are the CURRENT-pepper forms (writers,
  backfill, limiter). `email_keys/1` and `sentinel_keys/0` return the candidate
  list, current first, plus the previous key only during a planned rotation
  (length 1 or 2, a function of deployment state, never of the input);
  `lookup_by_keys/1` is dual-read over that list.

  ## Per-tenant disclosure (REQ-442, decision 0043 D-A)

  The lookup's internal match type is `tenant_match` (`slug`, `display_name` and a
  boolean `disclose`, computed in the same single query: deployment mode is
  `:redirect_single` AND the tenant's `login_disclosure_mode` is NULL or
  `redirect_single`). `disclose` is consumed by the decision function and stripped
  before any response is built; no tenant id, realm id or stored mode leaves
  this module.

  ## Writers

  `upsert_entry/2` and `remove_entry_if_unreferenced/3` must run inside a
  transaction (they return `{:error, :not_in_transaction}` otherwise) and take a
  transaction-scoped advisory lock per `(tenant_id, email_key)` so concurrent
  decisions observe each other's outcome (the lock is on the CURRENT key only;
  writes use the current key and key id only, removal deletes under every
  candidate key, 0043 D-C). `plan_user_change/2` is the pure single
  source of truth for add/remove decisions; `apply_plan/3` executes a plan,
  acquiring every lock in ascending key order first. The callers are the
  `Letflow.Identity` user functions, in the same transaction as the user write.

  ## Logging (INV-4)

  Every `Repo` call that touches the directory, or binds a normalised email or
  an `email_key`, passes `log: false`: Ecto's default query log prints bound
  parameters at `:debug`. Telemetry events still fire. No email, key or IP is
  logged, audited or put in telemetry by this module.
  """

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantLoginDirectoryEntry
  alias Letflow.Identity.TenantMembership
  alias Letflow.Identity.User
  alias Letflow.Repo

  @key_domain "letflow:login-directory:v1:"
  # Fixed string no valid address can equal (it contains no "@"); keyed with the
  # same pepper so it costs the same as a real key.
  @sentinel_input "sentinel-no-at-sign"
  @max_email_bytes 255
  @lookup_limit 50
  # First int4 of the two-integer advisory lock: a fixed namespace constant.
  @lock_namespace 435_001

  @type email_key :: <<_::256>>
  @type candidate_keys :: [email_key(), ...]
  @type disclosure_mode :: :uniform_plus_email | :redirect_single
  @type tenant_ref :: %{slug: String.t(), display_name: String.t()}
  @type tenant_match :: %{slug: String.t(), display_name: String.t(), disclose: boolean()}

  @type plan_step ::
          {:upsert, email :: String.t()}
          | {:remove_if_unreferenced, email :: String.t()}

  # ── keys ────────────────────────────────────────────────────────────────

  @doc """
  The email key for `email` under the CURRENT pepper. Returns `:invalid` when
  `email` is not a binary, its trimmed size is outside 1..255 bytes, or it fails
  `TenantMembership.email_shape?/1`; `{:error, :pepper_unavailable}` when the
  keys are not configured.
  """
  @spec email_key(term()) :: {:ok, email_key()} | :invalid | {:error, :pepper_unavailable}
  def email_key(email) do
    if valid_email?(email) do
      with {:ok, [current | _previous]} <- hmacs(TenantMembership.normalize_subject_key(email)) do
        {:ok, current}
      end
    else
      :invalid
    end
  end

  @doc """
  Candidate keys for `email`, current first, then the previous pepper's key only
  while a rotation is configured (length 1 or 2). Same error returns as
  `email_key/1`.
  """
  @spec email_keys(term()) :: {:ok, candidate_keys()} | :invalid | {:error, :pepper_unavailable}
  def email_keys(email) do
    if valid_email?(email) do
      hmacs(TenantMembership.normalize_subject_key(email))
    else
      :invalid
    end
  end

  @doc """
  The sentinel key under the CURRENT pepper: a keyed HMAC of a fixed string no
  valid address can equal. The writers never write it, so it never matches a row.
  """
  @spec sentinel_key() :: email_key() | {:error, :pepper_unavailable}
  def sentinel_key do
    case hmacs(@sentinel_input) do
      {:ok, [current | _previous]} -> current
      {:error, :pepper_unavailable} = error -> error
    end
  end

  @doc """
  Sentinel keys, one per candidate pepper, current first (same length as
  `email_keys/1` returns for a valid address).
  """
  @spec sentinel_keys() :: candidate_keys() | {:error, :pepper_unavailable}
  def sentinel_keys do
    case hmacs(@sentinel_input) do
      {:ok, keys} -> keys
      {:error, :pepper_unavailable} = error -> error
    end
  end

  @doc """
  The id of the CURRENT pepper (a label, not a secret), recorded in every row
  written.
  """
  @spec current_key_id() :: {:ok, String.t()} | {:error, :pepper_unavailable}
  def current_key_id do
    case key_slots() do
      {:ok, [%{id: id} | _previous]} -> {:ok, id}
      :error -> {:error, :pepper_unavailable}
    end
  end

  # Configured slots, current first, previous (if any) second.
  defp key_slots do
    with {:ok, keys} when is_list(keys) <- Application.fetch_env(:letflow, :login_directory_keys),
         %{id: id, pepper: <<_::binary-size(32)>>} = current when is_binary(id) <-
           Keyword.get(keys, :current) do
      case Keyword.get(keys, :previous) do
        %{id: prev_id, pepper: <<_::binary-size(32)>>} = previous when is_binary(prev_id) ->
          {:ok, [current, previous]}

        _none ->
          {:ok, [current]}
      end
    else
      _other -> :error
    end
  end

  defp hmacs(normalised) do
    case key_slots() do
      {:ok, slots} ->
        {:ok,
         Enum.map(slots, fn %{pepper: pepper} ->
           :crypto.mac(:hmac, :sha256, pepper, @key_domain <> normalised)
         end)}

      :error ->
        {:error, :pepper_unavailable}
    end
  end

  # Pepper-free validity check, shared by key derivation and the pure plan.
  defp valid_email?(email) when is_binary(email) do
    trimmed = String.trim(email)
    byte_size(trimmed) in 1..@max_email_bytes and TenantMembership.email_shape?(trimmed)
  end

  defp valid_email?(_email), do: false

  # ── read ────────────────────────────────────────────────────────────────

  @doc """
  The one discovery query (dual-read, 0043 D-C/D15): `tenants` semijoined
  (`EXISTS`) to the directory rows whose `email_key` is any of `keys` (1..2
  keys), so a tenant is returned once even when a person holds a row under each
  key. Active tenants with a bound (non-empty) `idp_realm_id` only, ordered by
  `display_name` then `slug`, limited to 50. Returns plain maps holding only
  `slug`, `display_name` and the internal `disclose` boolean (REQ-442; the `Tenant`
  struct is never loaded). Touches public tables only (no `:prefix`); one Repo
  round trip, `log: false`. Any other argument, or a failure, is
  `{:error, :lookup_failed}`.

  `lookup_by_keys/1` reads the deployment mode from config; `lookup_by_keys/2`
  takes it explicitly. Exactly `:redirect_single` lets a tenant disclose; any other
  term (including `:uniform_plus_email`) forces `disclose: false` for every tenant
  (the deployment mode is a ceiling, preserving the 0042 kill switch).
  """
  @spec lookup_by_keys(candidate_keys()) :: {:ok, [tenant_match()]} | {:error, :lookup_failed}
  def lookup_by_keys(keys), do: lookup_by_keys(keys, deployment_mode())

  @spec lookup_by_keys(candidate_keys(), disclosure_mode() | term()) ::
          {:ok, [tenant_match()]} | {:error, :lookup_failed}
  def lookup_by_keys([_ | _] = keys, deployment_mode) when length(keys) <= 2 do
    if Enum.all?(keys, &match?(<<_::binary-size(32)>>, &1)) do
      deployment_allows? = deployment_mode == :redirect_single

      directory =
        from(d in TenantLoginDirectoryEntry,
          where: d.tenant_id == parent_as(:tenant).id and d.email_key in ^keys,
          select: 1
        )

      query =
        from(t in Tenant,
          as: :tenant,
          where:
            exists(directory) and t.status == :active and not is_nil(t.idp_realm_id) and
              t.idp_realm_id != "",
          order_by: [asc: t.display_name, asc: t.slug],
          limit: @lookup_limit,
          select: %{
            slug: t.slug,
            display_name: t.display_name,
            disclose:
              fragment(
                "? AND COALESCE(?, 'redirect_single') = 'redirect_single'",
                type(^deployment_allows?, :boolean),
                t.login_disclosure_mode
              )
          }
        )

      {:ok, Repo.all(query, log: false)}
    else
      {:error, :lookup_failed}
    end
  rescue
    _exception -> {:error, :lookup_failed}
  end

  def lookup_by_keys(_other, _deployment_mode), do: {:error, :lookup_failed}

  @doc """
  The deployment-wide disclosure mode, the ONLY reader of the mode config
  (REQ-437, design 434 s7 D21/D28): `config :letflow, Letflow.LoginDiscovery, mode:`.
  A missing/`nil` value is the ratified default `:redirect_single`;
  `:redirect_single` stays itself; any other term is treated as the most
  conservative `:uniform_plus_email`. Never logs (D29).
  """
  @spec deployment_mode() :: disclosure_mode()
  def deployment_mode do
    case :letflow
         |> Application.get_env(Letflow.LoginDiscovery, [])
         |> Keyword.get(:mode) do
      nil -> :redirect_single
      :redirect_single -> :redirect_single
      _other -> :uniform_plus_email
    end
  end

  @doc """
  The ONLY parser of `LETFLOW_LOGIN_DISCOVERY_MODE` (called by `config/runtime.exs`).
  `nil`, empty or all-whitespace is `{:ok, nil}` (no override: the config default
  stands); exactly `"uniform_plus_email"` or `"redirect_single"` after trim is the
  matching atom (explicit clause per value, never `String.to_atom/1`); anything
  else is `{:error, :invalid_mode}`. The supplied value is never echoed.
  """
  @spec parse_deployment_mode(String.t() | nil) ::
          {:ok, disclosure_mode() | nil} | {:error, :invalid_mode}
  def parse_deployment_mode(nil), do: {:ok, nil}

  def parse_deployment_mode(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      "uniform_plus_email" -> {:ok, :uniform_plus_email}
      "redirect_single" -> {:ok, :redirect_single}
      _other -> {:error, :invalid_mode}
    end
  end

  def parse_deployment_mode(_other), do: {:error, :invalid_mode}

  @doc """
  Convenience composition of `email_keys/1` and `lookup_by_keys/1`: an invalid
  input uses the sentinel keys. An unavailable pepper is `{:error, :lookup_failed}`.
  """
  @spec lookup_by_email(term()) :: {:ok, [tenant_match()]} | {:error, :lookup_failed}
  def lookup_by_email(email) do
    case email_keys(email) do
      {:ok, keys} ->
        lookup_by_keys(keys)

      :invalid ->
        case sentinel_keys() do
          {:error, :pepper_unavailable} -> {:error, :lookup_failed}
          keys -> lookup_by_keys(keys)
        end

      {:error, :pepper_unavailable} ->
        {:error, :lookup_failed}
    end
  end

  # ── plan ────────────────────────────────────────────────────────────────

  @doc """
  Pure plan function: the single source of truth for what a user change does to
  the directory (design §3.3). A user is eligible when `status == :active` and
  its email is valid. `before` is `nil` for a create.
  """
  @spec plan_user_change(before :: User.t() | nil, after_user :: User.t()) :: [plan_step()]
  def plan_user_change(before, %User{} = after_user) do
    case {eligible?(before), eligible?(after_user)} do
      {false, true} ->
        [{:upsert, after_user.email}]

      {true, false} ->
        [{:remove_if_unreferenced, before.email}]

      {true, true} ->
        if TenantMembership.normalize_subject_key(before.email) ==
             TenantMembership.normalize_subject_key(after_user.email) do
          []
        else
          [{:remove_if_unreferenced, before.email}, {:upsert, after_user.email}]
        end

      {false, false} ->
        []
    end
  end

  defp eligible?(%User{status: :active, email: email}), do: valid_email?(email)
  defp eligible?(_other), do: false

  @doc """
  Executes `plan` for `tenant_id` against the tenant schema `prefix` (used only
  by the removal check). Must run inside a transaction. Acquires the advisory
  lock of every touched key in ascending key-byte order before any step, so two
  concurrent multi-key plans cannot deadlock.
  """
  @spec apply_plan([plan_step()], tenant_id :: Ecto.UUID.t(), prefix :: String.t()) ::
          :ok | {:error, term()}
  def apply_plan([], _tenant_id, _prefix), do: :ok

  def apply_plan(plan, tenant_id, prefix) when is_list(plan) do
    with :ok <- ensure_in_transaction(),
         {:ok, keys} <- plan_keys(plan),
         :ok <- lock_keys(tenant_id, keys) do
      run_steps(plan, tenant_id, prefix)
    end
  end

  defp plan_keys(plan) do
    plan
    |> Enum.reduce_while({:ok, []}, fn {_op, email}, {:ok, acc} ->
      case email_key(email) do
        {:ok, key} -> {:cont, {:ok, [key | acc]}}
        :invalid -> {:halt, {:error, :invalid_email}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, keys |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp lock_keys(tenant_id, keys) do
    Enum.each(keys, &acquire_key_lock(tenant_id, &1))
    :ok
  end

  defp run_steps(plan, tenant_id, prefix) do
    Enum.reduce_while(plan, :ok, fn
      {:upsert, email}, :ok ->
        step_result(upsert_entry(tenant_id, email))

      {:remove_if_unreferenced, email}, :ok ->
        step_result(remove_entry_if_unreferenced(tenant_id, email, prefix))
    end)
  end

  defp step_result({:ok, _outcome}), do: {:cont, :ok}
  defp step_result({:error, _reason} = error), do: {:halt, error}

  # ── writers ─────────────────────────────────────────────────────────────

  @doc """
  Inserts the entry for `(email_key(email), tenant_id)` under the current key and
  `current_key_id/0` if absent (`ON CONFLICT DO NOTHING`). Must run inside a transaction. Returns
  `{:ok, :inserted | :exists}`, `{:error, :invalid_email}` (nothing written, the
  sentinel is never written), `{:error, :pepper_unavailable}`,
  `{:error, :not_in_transaction}`, `{:error, :directory_unavailable}` (undefined column or
  table: schema drift, fixed reason, no exception text) or `{:error, :write_failed}`.
  """
  @spec upsert_entry(tenant_id :: Ecto.UUID.t(), email :: String.t()) ::
          {:ok, :inserted | :exists}
          | {:error,
             :invalid_email
             | :pepper_unavailable
             | :not_in_transaction
             | :directory_unavailable
             | :write_failed}
  def upsert_entry(tenant_id, email) do
    with :ok <- ensure_in_transaction(),
         {:ok, key} <- key_or_error(email),
         {:ok, key_id} <- current_key_id(),
         :ok <- acquire_key_lock(tenant_id, key) do
      row = %{
        email_key: key,
        key_id: key_id,
        tenant_id: tenant_id,
        inserted_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
      }

      case Repo.insert_all(TenantLoginDirectoryEntry, [row],
             on_conflict: :nothing,
             conflict_target: [:email_key, :tenant_id],
             log: false
           ) do
        {1, _} -> {:ok, :inserted}
        {0, _} -> {:ok, :exists}
      end
    end
  rescue
    # Fixed reasons only: the exception text must never reach a caller or a log.
    exception -> {:error, classify_write_failure(exception)}
  end

  @doc """
  Deletes the entries for `tenant_id` under every candidate key of `email`
  (`email_keys/1`; the advisory lock is on the current key) only if no other active
  user in the tenant schema `prefix` has the same normalised email (design §3.6;
  `users.email` carries no unique index, so two active users can share it). The
  caller has already applied the user write in this transaction, so the check is
  simply "does any active user row still carry this email". Must run inside a
  transaction. Returns `{:ok, :removed | :kept | :absent}` or an error as for
  `upsert_entry/2`.
  """
  @spec remove_entry_if_unreferenced(
          tenant_id :: Ecto.UUID.t(),
          email :: String.t(),
          prefix :: String.t()
        ) ::
          {:ok, :removed | :kept | :absent}
          | {:error,
             :invalid_email
             | :pepper_unavailable
             | :not_in_transaction
             | :directory_unavailable
             | :write_failed}
  def remove_entry_if_unreferenced(tenant_id, email, prefix) when is_binary(prefix) do
    with :ok <- ensure_in_transaction(),
         {:ok, key} <- key_or_error(email),
         {:ok, candidate_keys} <- email_keys(email),
         :ok <- acquire_key_lock(tenant_id, key) do
      normalised = TenantMembership.normalize_subject_key(email)

      still_referenced? =
        Repo.exists?(
          from(u in User,
            where: u.status == :active and fragment("lower(btrim(?))", u.email) == ^normalised
          ),
          prefix: prefix,
          log: false
        )

      if still_referenced? do
        {:ok, :kept}
      else
        {count, _} =
          Repo.delete_all(
            from(d in TenantLoginDirectoryEntry,
              where: d.email_key in ^candidate_keys and d.tenant_id == ^tenant_id
            ),
            log: false
          )

        if count > 0, do: {:ok, :removed}, else: {:ok, :absent}
      end
    end
  rescue
    exception -> {:error, classify_write_failure(exception)}
  end

  # GH #2498: schema drift (a missing column or table in the public directory table) is an
  # infrastructure fault, not a write race; classify by exception class and Postgres error
  # code only, never by message, and return a fixed atom.
  defp classify_write_failure(%Postgrex.Error{postgres: %{code: code}})
       when code in [:undefined_column, :undefined_table],
       do: :directory_unavailable

  defp classify_write_failure(_exception), do: :write_failed

  defp key_or_error(email) do
    case email_key(email) do
      {:ok, key} -> {:ok, key}
      :invalid -> {:error, :invalid_email}
      {:error, _} = error -> error
    end
  end

  defp ensure_in_transaction do
    if Repo.in_transaction?(), do: :ok, else: {:error, :not_in_transaction}
  end

  # Transaction-scoped two-integer advisory lock over (tenant_id, email_key):
  # a fixed namespace constant plus a hash of the pair; a hash collision only
  # over-serialises. Bound parameters only (INV-7); log: false (INV-4).
  defp acquire_key_lock(tenant_id, key) do
    hash = :erlang.phash2({tenant_id, key}, 2_147_483_647)

    Repo.query!("SELECT pg_advisory_xact_lock($1::int, $2::int)", [@lock_namespace, hash],
      log: false
    )

    :ok
  end
end
