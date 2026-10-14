defmodule Letflow.Identity.PendingAdminGrants do
  @moduledoc """
  ISS-1030 (design `lib/letflow/design/iss1030-onboarding-administrator.md`
  sections 4.3, 5, 7, 7a): the pending tenant-administrator grant.

  When the platform operator names an administrator at onboarding time
  (`POST /onboarding` with `admin_email`), the address is stored as a pending
  grant in the new tenant's own schema. It is bound to `TENANT_ADMIN` when that
  person first signs in through the tenant's own realm with a VERIFIED e-mail
  claim equal to the stored key (`bind_on_login/5`, called from
  `Letflow.Plugs.AuthPipeline`).

  Binding rules (decision 0048): verified e-mail claim only (`email_verified`
  JSON `true`, or the operator-set per-realm setting), never `preferred_username`;
  exactly once, inside one transaction together with BOTH audit entries; confers
  `TENANT_ADMIN` and nothing else; a failure of any step is a silent `:noop`.

  ## Audit split (design section 7a)

  The tenant audit chain is readable by every `:AuditRead` holder of the tenant,
  so no entry written to it names a platform operator: created and revoked
  entries carry a NIL actor, the bind entry carries the bound user (a user of
  that tenant). The operator's user id is written only to the PLATFORM tenant's
  chain, in the same transaction, referencing the same grant id. Lock order,
  everywhere a grant is touched: grant row, user row, membership, tenant chain,
  platform chain (the platform chain is always last).

  No audit entry, in either chain, and no log line ever contains an e-mail
  address (INV-4).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.AuditContext
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.PendingAdminGrants.FaultThrottle
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantAdminGuard
  alias Letflow.Identity.TenantMembership
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.PlatformTenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  require Logger

  @email_max 254
  @local_max 64
  @domain_min 3
  @lock_timeout "2s"
  @created_via_class "platform_operator_onboarding"
  @role "TENANT_ADMIN"

  @type creator :: %{user_id: Ecto.UUID.t()}

  @type write_opts :: [
          prefix: String.t(),
          platform_prefix: String.t(),
          trace_id: String.t() | nil,
          onboarding_id: Ecto.UUID.t() | nil
        ]

  # ── e-mail normalisation ─────────────────────────────────────────────────

  @doc """
  Validates and normalises an administrator e-mail address: trim + lower-case
  ONLY (plus tags and dots are preserved), through the one shared normaliser
  (`TenantMembership.normalize_subject_key/1`).

  The address must be ASCII (an internationalised address is given in its
  punycode `xn--` form): Unicode case folding could otherwise map a look-alike
  character onto an ASCII letter of the key. At most 254 characters in total,
  exactly one `@`, local part 1..64, a domain of at least 3 characters with a
  `.` that is neither first nor last, no whitespace or control characters.
  Never echoes the value.
  """
  @spec normalize_email(raw :: term()) :: {:ok, String.t()} | :error
  def normalize_email(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    with true <- printable_ascii?(trimmed),
         key = TenantMembership.normalize_subject_key(trimmed),
         true <- byte_size(key) <= @email_max,
         [local, domain] <- String.split(key, "@"),
         true <- byte_size(local) in 1..@local_max,
         true <- byte_size(domain) >= @domain_min,
         true <- domain_shape?(domain) do
      {:ok, key}
    else
      _invalid -> :error
    end
  end

  def normalize_email(_other), do: :error

  # Visible ASCII only: no whitespace, no control characters, nothing above 0x7F.
  defp printable_ascii?(""), do: false
  defp printable_ascii?(value), do: for(<<byte <- value>>, byte not in 0x21..0x7E, do: byte) == []

  defp domain_shape?(domain),
    do:
      String.contains?(domain, ".") and not String.starts_with?(domain, ".") and
        not String.ends_with?(domain, ".")

  # ── create ───────────────────────────────────────────────────────────────

  @doc """
  Stores a pending grant for the already-normalised `email_key`.

  One transaction: the grant row, the TENANT-chain entry
  `tenant.admin_grant.created` (NIL actor, no operator id) and the PLATFORM-chain
  entry `platform.tenant_admin_grant.created` (the only place the operator's
  user id is recorded). `opts[:prefix]` is the new tenant's schema;
  `opts[:platform_prefix]` must be verified by the caller. `opts[:onboarding_id]`
  is recorded on the platform entry only.

  `create/3` has exactly ONE caller, the onboarding handler.
  """
  @spec create(email_key :: String.t(), creator(), write_opts()) ::
          {:ok, PendingAdminGrant.t()}
          | {:error, :duplicate}
          | {:error, Ecto.Changeset.t()}
          | {:error, :audit_failed}
  def create(email_key, %{user_id: user_id}, opts) when is_binary(email_key) do
    prefix = Keyword.fetch!(opts, :prefix)
    platform_prefix = Keyword.fetch!(opts, :platform_prefix)
    grant_id = Ecto.UUID.generate()

    with {:ok, tenant_id} <- tenant_id_for(prefix),
         true <- is_binary(user_id) do
      Multi.new()
      |> Multi.insert(
        :grant,
        PendingAdminGrant.create_changeset(%PendingAdminGrant{id: grant_id}, %{
          email_key: email_key
        }),
        prefix: prefix
      )
      |> Multi.run(:tenant_audit, fn repo, _changes ->
        Audit.insert_entry(
          repo,
          grant_entry("tenant.admin_grant.created", nil, grant_id, nil, %{
            "grant_id" => grant_id,
            "role" => @role,
            "created_via" => @created_via_class
          }),
          prefix
        )
      end)
      |> Multi.run(:platform_audit, fn repo, _changes ->
        Audit.insert_entry(
          repo,
          grant_entry(
            "platform.tenant_admin_grant.created",
            user_id,
            grant_id,
            Keyword.get(opts, :trace_id),
            %{
              "grant_id" => grant_id,
              "tenant_id" => tenant_id,
              "onboarding_id" => Keyword.get(opts, :onboarding_id)
            }
          ),
          platform_prefix
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{grant: grant}} -> {:ok, grant}
        {:error, :grant, changeset, _changes} -> {:error, insert_failure(changeset)}
        {:error, _step, _reason, _changes} -> {:error, :audit_failed}
      end
    else
      _invalid_prefix_or_creator -> {:error, :audit_failed}
    end
  rescue
    exception ->
      Logger.error(
        "pending administrator grant create failed (exception=#{inspect(exception.__struct__)})"
      )

      {:error, :audit_failed}
  catch
    :exit, _reason ->
      Logger.error("pending administrator grant create failed (exit)")
      {:error, :audit_failed}
  end

  defp insert_failure(%Ecto.Changeset{errors: errors} = changeset) do
    duplicate? =
      Enum.any?(errors, fn
        {:email_key, {_message, keyword}} -> Keyword.get(keyword, :constraint) == :unique
        _other -> false
      end)

    if duplicate?, do: :duplicate, else: changeset
  end

  # ── list ─────────────────────────────────────────────────────────────────

  @doc """
  Every grant of the tenant schema `opts[:prefix]`, oldest first, with its
  lifecycle state and, for an OPEN grant only, its AGE in seconds.
  """
  @spec list(opts :: [prefix: String.t(), now: DateTime.t()]) :: [
          %{
            grant: PendingAdminGrant.t(),
            state: PendingAdminGrant.state(),
            age_seconds: non_neg_integer() | nil
          }
        ]
  def list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    from(g in PendingAdminGrant, order_by: [asc: g.inserted_at, asc: g.id])
    |> Repo.all(prefix: prefix)
    |> Enum.map(fn grant ->
      state = PendingAdminGrant.state(grant)
      %{grant: grant, state: state, age_seconds: age_seconds(state, grant, now)}
    end)
  end

  defp age_seconds(:open, %PendingAdminGrant{inserted_at: %DateTime{} = at}, now),
    do: max(DateTime.diff(now, at, :second), 0)

  defp age_seconds(_state, _grant, _now), do: nil

  @doc """
  The creating operator's user id per grant id, read from the PLATFORM chain
  entry `platform.tenant_admin_grant.created` (design 5.2). Grants with no such
  entry are absent from the map.
  """
  @spec creators(grant_ids :: [String.t()], platform_prefix :: String.t()) ::
          %{optional(String.t()) => Ecto.UUID.t() | nil}
  def creators([], _platform_prefix), do: %{}

  def creators(grant_ids, platform_prefix) when is_list(grant_ids) do
    from(e in Audit.Entry,
      where: e.action == "platform.tenant_admin_grant.created" and e.resource_id in ^grant_ids,
      select: {e.resource_id, e.actor_id}
    )
    |> Repo.all(prefix: platform_prefix)
    |> Map.new()
  end

  @doc """
  The schema name of a provisioned tenant's registration, or `:error` when the
  tenant has no registration. Used by the operator routes, which resolve the
  tenant from the onboarding record, never from the request.
  """
  @spec registered_prefix(tenant_id :: Ecto.UUID.t()) :: {:ok, String.t()} | :error
  def registered_prefix(tenant_id) do
    case Repo.get_by(TenantProvisioning.Registration, tenant_id: tenant_id) do
      %TenantProvisioning.Registration{schema_name: schema_name} -> {:ok, schema_name}
      nil -> :error
    end
  end

  # ── revoke ───────────────────────────────────────────────────────────────

  @doc """
  Revokes an OPEN grant (the operator withdraws it) and scrubs its e-mail, in one
  transaction with the TENANT-chain entry `tenant.admin_grant.revoked` (NIL
  actor) and the PLATFORM-chain entry `platform.tenant_admin_grant.revoked` (the
  operator). A bound or already revoked grant is refused (`:not_open`).

  REQ-497 PR 1b (design `req497-1b-allowed-flag-shadow-n1.md` 6.2 (d), 0051 AC12): the
  tenant admin lock is the FIRST step. Revoking the last OPEN grant of a tenant that has no
  counted tenant-wide admin is refused with `{:error, :last_tenant_wide_admin}`: the grant
  stays open, and one `tenant_admin.guard_refused` entry (action `revoke_pending_grant`) is
  written to the tenant chain with a nil actor and trace, plus a companion entry with the
  operator and the trace written last on the platform chain, both in one transaction of
  their own after the rollback (no operator id ever enters the tenant chain).
  """
  @spec revoke(grant_id :: Ecto.UUID.t(), actor :: creator(), write_opts()) ::
          :ok
          | {:error, :not_found}
          | {:error, :not_open}
          | {:error, :last_tenant_wide_admin}
          | {:error, :audit_failed}
  def revoke(grant_id, %{user_id: user_id}, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    platform_prefix = Keyword.fetch!(opts, :platform_prefix)

    with {:ok, tenant_id} <- tenant_id_for(prefix),
         true <- is_binary(user_id) do
      Multi.new()
      |> Multi.run(:tenant_admin_lock, fn _repo, _changes ->
        {:ok, Identity.lock_tenant_admins!(prefix)}
      end)
      |> Multi.run(:grant, fn repo, _changes -> lock_grant_by_id(repo, grant_id, prefix) end)
      |> Multi.run(:revoke, fn repo, %{grant: grant} ->
        {count, _rows} =
          repo.update_all(
            from(g in PendingAdminGrant,
              where: g.id == ^grant.id and is_nil(g.consumed_at) and is_nil(g.revoked_at)
            ),
            [set: [revoked_at: DateTime.utc_now(), email_key: nil]],
            prefix: prefix
          )

        if count == 1, do: {:ok, :revoked}, else: {:error, :not_open}
      end)
      |> Multi.run(:tenant_admin_guard, fn repo, _changes ->
        last_grant_guard(repo, grant_id, prefix)
      end)
      |> Multi.run(:tenant_audit, fn repo, _changes ->
        Audit.insert_entry(
          repo,
          grant_entry("tenant.admin_grant.revoked", nil, grant_id, nil, %{
            "grant_id" => grant_id,
            "role" => @role,
            "created_via" => @created_via_class
          }),
          prefix
        )
      end)
      |> Multi.run(:platform_audit, fn repo, _changes ->
        Audit.insert_entry(
          repo,
          grant_entry(
            "platform.tenant_admin_grant.revoked",
            user_id,
            grant_id,
            Keyword.get(opts, :trace_id),
            %{"grant_id" => grant_id, "tenant_id" => tenant_id}
          ),
          platform_prefix
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          :ok

        {:error, :grant, reason, _changes} when reason in [:not_found, :not_open] ->
          {:error, reason}

        {:error, :tenant_admin_guard, refusal, _changes} ->
          ctx = %{actor_id: user_id, trace_id: Keyword.get(opts, :trace_id), source: "api"}
          TenantAdminGuard.refuse(prefix, refusal, ctx, platform_companion: platform_prefix)

        {:error, _step, _reason, _changes} ->
          {:error, :audit_failed}
      end
    else
      _invalid_prefix_or_actor -> {:error, :audit_failed}
    end
  rescue
    exception ->
      Logger.error(
        "pending administrator grant revoke failed (exception=#{inspect(exception.__struct__)})"
      )

      {:error, :audit_failed}
  catch
    :exit, _reason ->
      Logger.error("pending administrator grant revoke failed (exit)")
      {:error, :audit_failed}
  end

  defp lock_grant_by_id(repo, grant_id, prefix) do
    locked = from(g in PendingAdminGrant, where: g.id == ^grant_id, lock: "FOR UPDATE")

    case repo.one(locked, prefix: prefix) do
      nil -> {:error, :not_found}
      %PendingAdminGrant{} = grant -> if open?(grant), do: {:ok, grant}, else: {:error, :not_open}
    end
  end

  # REQ-497 PR 1b N1 (design 6.2 (d)): after the revoke, under lock A. Refused only when NO
  # other open grant remains AND the tenant counts 0 tenant-wide admins (the count runs only
  # when no open grant is left).
  defp last_grant_guard(repo, grant_id, prefix) do
    open_left =
      repo.aggregate(
        from(g in PendingAdminGrant, where: is_nil(g.consumed_at) and is_nil(g.revoked_at)),
        :count,
        prefix: prefix
      )

    if open_left == 0 and Identity.count_tenant_wide_admins(prefix) == 0 do
      {:error, %{action: :revoke_pending_grant, target_id: grant_id, counted_admins: 0}}
    else
      {:ok, :admins_remain}
    end
  end

  defp open?(%PendingAdminGrant{consumed_at: nil, revoked_at: nil}), do: true
  defp open?(%PendingAdminGrant{}), do: false

  # ── bind on login ────────────────────────────────────────────────────────

  @doc """
  The first-login binding (design section 7). Called by the OIDC auth pipeline
  between JIT provisioning and the per-request effective-role read, with the
  DB-resolved `tenant`, the `provisioned` map, the mapped `identity_context`, the
  realm's `jit_config`, and `opts[:prefix]` (the tenant's schema).

  Returns `:bound` when the verified e-mail matched an open grant and the
  `TENANT_ADMIN` membership was written, `:noop` in EVERY other case. It never
  raises and never returns an error: the request continues exactly as if no grant
  existed (same status, same body, no hint). Every log line is fixed text plus
  the tenant id only; expected no-ops log at `:debug`, real faults at `:warning`
  at most once per tenant per hour.

  GH 2547: `opts[:trace_id]` (the request's, default `nil`) is written into both bound
  audit entries, after `Letflow.Identity.AuditContext.normalize_trace_id/1`. The bind
  takes the tenant admin lock (`Letflow.Identity.lock_tenant_admins!/1`) right after its
  bounded `lock_timeout`; a timeout there is a fault and a `:noop`.
  """
  @spec bind_on_login(
          tenant :: Tenant.t(),
          provisioned :: %{user: User.t(), created: boolean()},
          identity_context :: IdentityContext.t(),
          jit_config :: JitProvisioningConfig.t(),
          opts :: [prefix: String.t(), trace_id: String.t() | nil]
        ) :: :bound | :noop
  def bind_on_login(tenant, provisioned, identity_context, jit_config, opts) do
    case precheck(tenant, provisioned, identity_context, jit_config) do
      {:ok, key, basis, platform_prefix} ->
        run_bind(
          tenant,
          provisioned.user,
          provisioned.created,
          key,
          basis,
          platform_prefix,
          Keyword.fetch!(opts, :prefix),
          AuditContext.normalize_trace_id(Keyword.get(opts, :trace_id))
        )

      :skip ->
        :noop

      :expected ->
        log_expected(tenant)
        :noop

      :fault ->
        log_fault(tenant)
        :noop
    end
  rescue
    # Never the exception: its message can carry parameters (INV-4, INV-8).
    _exception ->
      log_fault(tenant)
      :noop
  catch
    :exit, _reason ->
      log_fault(tenant)
      :noop
  end

  # Cheap pre-checks, no database access (design section 7 steps 1-4b).
  defp precheck(tenant, %{user: %User{} = user, created: created}, ctx, jit_config) do
    cond do
      # Step 1: a user with synced role claims never binds (costs nothing).
      not (created == true or is_nil(user.role_claims_synced_at)) ->
        :skip

      # Step 1b: only an `:active` tenant binds (never a `:migrating` or
      # `:inactive` one; the TenantStatus gate runs after this step).
      not match?(%Tenant{status: :active}, tenant) ->
        :expected

      # Step 2.
      user.status != :active ->
        :expected

      # Step 3.
      not realm_matches?(tenant, user, ctx) ->
        :expected

      true ->
        precheck_platform_and_email(user, ctx, jit_config)
    end
  end

  defp precheck(_tenant, _provisioned, _ctx, _jit_config), do: :expected

  defp realm_matches?(%Tenant{idp_realm_id: realm}, %User{external_realm: external}, ctx),
    do: is_binary(realm) and ctx.realm == external and external == realm

  defp precheck_platform_and_email(user, ctx, jit_config) do
    # Step 3b: fail closed when the platform chain is not reachable. The platform
    # prefix comes from server configuration, never from the token or request.
    case PlatformTenant.platform_prefix() do
      {:ok, platform_prefix} ->
        with {:ok, key} <- claim_key(ctx.email),
             {:ok, basis} <- email_basis(ctx, jit_config),
             :ok <- stored_email_matches(user.email, key) do
          {:ok, key, basis, platform_prefix}
        else
          :error -> :expected
        end

      :error ->
        :fault
    end
  end

  # Step 4: a non-blank, ASCII-only claim e-mail. `preferred_username` and
  # `display_name` are never read.
  defp claim_key(email) when is_binary(email) do
    trimmed = String.trim(email)

    if printable_ascii?(trimmed),
      do: {:ok, TenantMembership.normalize_subject_key(trimmed)},
      else: :error
  end

  defp claim_key(_other), do: :error

  defp email_basis(%IdentityContext{email_verified: true}, _jit_config),
    do: {:ok, "verified_claim"}

  defp email_basis(_ctx, %JitProvisioningConfig{accept_unverified_email_for_admin_bind: true}),
    do: {:ok, "unverified_realm_setting"}

  defp email_basis(_ctx, _jit_config), do: :error

  # Step 4b: the address stored at JIT time must equal the claim address (an
  # address changed in the realm after the first login never binds). The stored
  # address must be ASCII as well, so case folding cannot make it match.
  defp stored_email_matches(stored, key) when is_binary(stored) do
    trimmed = String.trim(stored)

    if ascii?(trimmed) and TenantMembership.normalize_subject_key(trimmed) == key,
      do: :ok,
      else: :error
  end

  defp stored_email_matches(_stored, _key), do: :error

  defp ascii?(value), do: for(<<byte <- value>>, byte > 0x7F, do: byte) == []

  defp run_bind(tenant, user, created, key, basis, platform_prefix, prefix, trace_id) do
    if open_grant_exists?(key, prefix) do
      transact_bind(tenant, user, created, key, basis, platform_prefix, prefix, trace_id)
    else
      # The common login: no grant waits for this address. No transaction, no
      # `SET LOCAL`, no lock; the locked re-check below stays authoritative.
      log_expected(tenant)
      :noop
    end
  end

  # Lock-free existence probe (hot path): a stale answer is harmless, a false
  # positive is re-decided under the row lock and a false negative is retried by
  # the next login (the marker stays NIL).
  defp open_grant_exists?(key, prefix) do
    from(g in PendingAdminGrant,
      where: g.email_key == ^key and is_nil(g.consumed_at) and is_nil(g.revoked_at)
    )
    |> Repo.exists?(prefix: prefix)
  end

  defp transact_bind(tenant, user, created, key, basis, platform_prefix, prefix, trace_id) do
    Multi.new()
    |> Multi.run(:lock_timeout, fn repo, _changes ->
      # Bounded wait on the contended platform chain lock: a login never queues
      # behind operator writes. Fixed statement, nothing interpolated (INV-7).
      case repo.query("SET LOCAL lock_timeout = '#{@lock_timeout}'") do
        {:ok, _result} -> {:ok, :set}
        {:error, _reason} -> {:error, :lock_timeout_setting}
      end
    end)
    # GH 2547 (design 6.6): the tenant admin lock, before any row lock and bounded by
    # the lock_timeout above. A timeout raises into bind_on_login/5's rescue: `:noop`,
    # marker still NIL, the next login retries. add_group_member/3 below re-enters it.
    |> Multi.run(:tenant_admin_lock, fn _repo, _changes ->
      {:ok, Identity.lock_tenant_admins!(prefix)}
    end)
    |> Multi.run(:grant, fn repo, _changes -> lock_open_grant(repo, key, prefix) end)
    |> Multi.run(:user, fn repo, _changes -> lock_user(repo, user, created, key, prefix) end)
    |> Multi.run(:duplicates, fn repo, _changes ->
      no_duplicate_holder(repo, user, key, prefix)
    end)
    |> Multi.run(:group, fn _repo, _changes -> admin_group_id(prefix) end)
    |> Multi.run(:membership, fn _repo, %{group: group_id} ->
      # GH 2547 (AC4): this bind writes its own two events below, so the membership's
      # `group_member.added` row is suppressed. The one opt-out caller; literal only.
      case Identity.add_group_member(group_id, user.id,
             prefix: prefix,
             group_member_audit: :caller_audits
           ) do
        {:ok, _member} -> {:ok, :member}
        {:error, _reason} -> {:error, :membership}
      end
    end)
    |> Multi.run(:consume, fn repo, %{grant: grant} -> consume(repo, grant, user, prefix) end)
    |> Multi.run(:stamp, fn repo, %{user: locked} -> stamp_marker(repo, locked, prefix) end)
    |> Multi.run(:tenant_audit, fn repo, %{grant: grant} ->
      Audit.insert_entry(
        repo,
        grant_entry("tenant.admin_grant.bound", user.id, grant.id, trace_id, %{
          "grant_id" => grant.id,
          "role" => @role,
          "bound_user_id" => user.id,
          "created_via" => @created_via_class,
          "email_basis" => basis
        }),
        prefix
      )
    end)
    |> Multi.run(:platform_audit, fn repo, %{grant: grant} ->
      Audit.insert_entry(
        repo,
        grant_entry("platform.tenant_admin_grant.bound", user.id, grant.id, trace_id, %{
          "grant_id" => grant.id,
          "tenant_id" => tenant.id,
          "bound_user_id" => user.id
        }),
        platform_prefix
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} ->
        :bound

      # Expected: nobody is waiting for this address, or two accounts share it.
      {:error, step, _reason, _changes} when step in [:grant, :user, :duplicates] ->
        log_expected(tenant)
        :noop

      {:error, _step, _reason, _changes} ->
        log_fault(tenant)
        :noop
    end
  end

  # Step 5: the open grant for the key, row-locked. Two simultaneous logins
  # serialise here; the second re-evaluates its WHERE after the first commits.
  defp lock_open_grant(repo, key, prefix) do
    query =
      from(g in PendingAdminGrant,
        where: g.email_key == ^key and is_nil(g.consumed_at) and is_nil(g.revoked_at),
        lock: "FOR UPDATE"
      )

    case repo.one(query, prefix: prefix) do
      %PendingAdminGrant{} = grant -> {:ok, grant}
      nil -> {:error, :no_open_grant}
    end
  end

  # Step 5a: the user row, locked AFTER the grant row and BEFORE the membership
  # insert, then re-checked against the committed row: precheck ran on a struct read
  # earlier in the request, so a concurrent deactivation, e-mail change or
  # role-claim sync would otherwise go unnoticed. Same predicates as precheck steps
  # 1, 2 and 4b (`stored_email_matches/2` is the same normaliser).
  defp lock_user(repo, %User{id: id}, created, key, prefix) do
    query = from(u in User, where: u.id == ^id, lock: "FOR UPDATE")

    case repo.one(query, prefix: prefix) do
      %User{status: :active} = locked ->
        if (created == true or is_nil(locked.role_claims_synced_at)) and
             stored_email_matches(locked.email, key) == :ok,
           do: {:ok, locked},
           else: {:error, :user_changed}

      _inactive_or_missing ->
        {:error, :user_changed}
    end
  end

  # Step 5b (fail closed): any OTHER user of this tenant schema holding the same
  # address abandons the bind. Postgres lower() depends on the collation, so the
  # non-ASCII candidates are compared in Elixir with the shared normaliser.
  defp no_duplicate_holder(repo, user, key, prefix) do
    candidates =
      from(u in User,
        where: u.id != ^user.id and not is_nil(u.email),
        where:
          fragment("lower(btrim(?)) = ?", u.email, ^key) or
            fragment("? ~ '[^\\x01-\\x7F]'", u.email),
        select: {u.email, fragment("lower(btrim(?)) = ?", u.email, ^key)}
      )
      |> repo.all(prefix: prefix)

    duplicate? =
      Enum.any?(candidates, fn {email, sql_equal?} ->
        sql_equal? or TenantMembership.normalize_subject_key(email) == key
      end)

    if duplicate?, do: {:error, :duplicate_holder}, else: {:ok, :unique}
  end

  # Step 6: the group the `TENANT_ADMIN` platform-role binding points to.
  defp admin_group_id(prefix) do
    binding =
      [prefix: prefix]
      |> RoleRegistry.list_roles()
      |> Enum.find(&(&1.name == @role and &1.kind == :platform_role))

    case binding do
      %{group_id: group_id} when is_binary(group_id) -> {:ok, group_id}
      _missing -> {:error, :admin_binding_missing}
    end
  end

  # Step 8: consume the grant, asserted: exactly one row must change, otherwise
  # the whole transaction rolls back. The e-mail is scrubbed (the bound user's
  # row already holds it).
  defp consume(repo, grant, user, prefix) do
    {count, _rows} =
      repo.update_all(
        from(g in PendingAdminGrant,
          where: g.id == ^grant.id and is_nil(g.consumed_at) and is_nil(g.revoked_at)
        ),
        [set: [consumed_at: DateTime.utc_now(), consumed_by_user_id: user.id, email_key: nil]],
        prefix: prefix
      )

    if count == 1, do: {:ok, :consumed}, else: {:error, :not_consumed}
  end

  # Ends the per-request retry of step 1 and keeps REQ-378's "roles are
  # database-managed after the first sync" semantics.
  # `user` is the row locked by `lock_user/5`: when its marker was NIL exactly one
  # row must change (the lock makes that certain), otherwise the transaction rolls
  # back. A user created in this request may already carry the stamp (nothing to do).
  defp stamp_marker(repo, %User{role_claims_synced_at: nil} = user, prefix) do
    {count, _rows} =
      repo.update_all(
        from(u in User, where: u.id == ^user.id and is_nil(u.role_claims_synced_at)),
        [set: [role_claims_synced_at: DateTime.utc_now()]],
        prefix: prefix
      )

    if count == 1, do: {:ok, :stamped}, else: {:error, :not_stamped}
  end

  defp stamp_marker(_repo, %User{}, _prefix), do: {:ok, :already_stamped}

  # ── shared ───────────────────────────────────────────────────────────────

  defp grant_entry(action, actor_id, grant_id, trace_id, after_state) do
    %{
      actor_id: actor_id,
      action: action,
      resource_type: "pending_admin_grant",
      resource_id: grant_id,
      trace_id: trace_id,
      before_state: nil,
      after_state: after_state
    }
  end

  defp tenant_id_for(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, tenant_id} -> {:ok, tenant_id}
      {:error, _reason} -> :error
    end
  end

  # Fixed text plus the tenant id only: never an exception, a claim or an e-mail.
  defp log_expected(%Tenant{id: tenant_id}),
    do: Logger.debug("pending administrator bind skipped (tenant_id=#{inspect(tenant_id)})")

  defp log_expected(_other), do: :ok

  defp log_fault(%Tenant{id: tenant_id}) do
    if FaultThrottle.allow?(tenant_id) do
      Logger.warning("pending administrator bind failed (tenant_id=#{inspect(tenant_id)})")
    end

    :ok
  end

  defp log_fault(_other), do: :ok
end
