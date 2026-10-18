defmodule Letflow.Identity do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Context module for the identity domain. `provision_oidc_user/4` (below) ports
  the JIT (just-in-time) user-provisioning orchestration from
  `src/oidc/jit_provisioning.zig` together with the actual upsert from
  `src/identity/registry.zig`'s `createOrGetJitOidcUser` (lines ~843-912),
  operating on REQ-015's `users` schema (`Letflow.Identity.User`), now relocated
  per-tenant-schema per REQ-063 (`opts[:prefix]` selects the target schema — see
  `provision_oidc_user/4`'s own @doc).

  PROVENANCE (historical, not current decision authority):
  `resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`, and
  `verify_realm_ownership/2` (below) port `src/oidc/realm_tenant_binding.zig`
  and the realm-ownership guard from
  `src/design/adp-04b-tenant-realm-binding.md` /
  `src/design/adp-04a-external-identity-linkage-user.md`'s "Cross-tenant
  collision boundaries" section, operating on REQ-015's `tenants` schema
  (`Letflow.Identity.Tenant`). See
  `lib/letflow/design/req019-tenant-realm-binding.md` for the full design
  these three functions implement.

  Matches this project's established `Letflow.RowApproval`-style pattern: a
  top-level context module in `lib/letflow/`, backed by schema files in a
  same-named subdirectory (`lib/letflow/identity/user.ex` and friends).

  See `lib/letflow/design/req018-jit-provisioning.md` for the full design this
  module implements.

  `create_user/2`, `list_users/2`, `get_user/2`, `update_user_profile/3`, and
  `update_user_status/3` (below) are REQ-073's additions — the first
  general user-CRUD functions on this module, backing the five
  `Letflow.Routers.Identity` route handlers. See
  `lib/letflow/design/req073-identity-user-routes.md` §7 for the full design.
  Each takes `opts :: [prefix: String.t()]`, matching this module's existing
  convention — `:prefix` is always derived by the caller from
  `Letflow.Api.Context.scoped_repo_opts/1`, never supplied by request data.

  `create_group/2`, `add_group_member/3`, `list_groups/1`, `delete_group/2`,
  `list_group_members/3`, and `remove_group_member/3` (below) are REQ-074's
  additions — group-management and group-membership functions backing the
  six new `Letflow.Routers.Identity` group routes. See
  `lib/letflow/design/req074-identity-group-routes.md` §8 for the full
  design. Same `opts :: [prefix: String.t()]` convention as REQ-073's
  functions.

  `create_token/3`, `list_tokens/1`, `revoke_token/2`, and `verify_api_token/2`
  (below) are REQ-076's API-token additions, backing the token routes on
  `Letflow.Routers.Identity` and the API-token branch of
  `Letflow.Plugs.AuthPipeline`. `create_onboarding/1`, `get_onboarding/1`, and
  `get_onboarding_by_hostname/1` are REQ-076's onboarding additions, backing
  `Letflow.Routers.Onboarding`. See
  `lib/letflow/design/req076-identity-tokens-roles-onboarding.md` §3/§8 for the
  full design. Same `opts :: [prefix: String.t()]` convention as REQ-073's
  functions for the token group; the onboarding functions take no `opts` —
  `onboarding_registry` is structurally global, like `tenants` (§8.1).
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Letflow.Api.Authorization
  alias Letflow.Api.Pagination
  alias Letflow.Audit
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.AuditContext
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.MembershipScope
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.RoleScopeGrant
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.ServicePrincipal
  alias Letflow.Identity.SyncScopeGuard
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantAdminGuard
  alias Letflow.Identity.TenantMembership
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.LoginDirectory
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.Repo
  alias Letflow.ScopeEnforcement
  alias Letflow.TenantProvisioning

  @type provisioning_error ::
          :jit_disabled
          | :realm_tenant_mismatch
          | :external_identity_collision
          | Ecto.Changeset.t()
          | term()

  @typedoc """
  Keyword opts threaded into every `Repo` call in `provision_oidc_user/4`'s call
  chain, matching `lib/letflow/definitions.ex`'s established `opts :: [prefix:
  String.t()]` convention. `:prefix` is required (no default) — see
  `provision_oidc_user/4`'s own @doc for why a missing prefix must never silently
  fall back to the (post-REQ-063) no-longer-authoritative `public` schema.

  GH 2547: `:audit_context` (optional, `Letflow.Identity.AuditContext.t()`, possibly
  partial) carries actor, trace id and source into the audited identity writes.
  `:group_member_audit` (`:emit`, the default, or `:caller_audits`) is honoured only by
  `add_group_member/3`; see its @doc.
  """
  @type opts :: [
          prefix: String.t(),
          login_directory: :enabled | :skip,
          audit_context: AuditContext.t(),
          group_member_audit: :emit | :caller_audits
        ]

  # GH 2547 (design section 6.6): the IdP sync bounds its wait on the tenant admin lock
  # exactly like the pending-admin-grant bind (`PendingAdminGrants`' @lock_timeout).
  @sync_lock_timeout "2s"
  @tenant_admin_role "TENANT_ADMIN"
  @tenant_admin_lock_label "letflow:tenant_admin_lock:v1:"
  @int32_min -2_147_483_648
  @int32_limit 2_147_483_648

  @doc """
  Idempotent upsert keyed on `(tenant_id, external_realm, external_id)`:
  returns the existing user if one already matches that triple, otherwise
  creates one. `tenant_id` is trusted as already-resolved/authoritative by the
  caller (REQ-019/021's territory) — it is not read from
  `identity_context.tenant_id` (the token-claimed hint, not the authoritative
  value) and not re-derived or cross-checked here.

  `opts[:prefix]` (required, no default) selects which tenant schema's `users`
  table this call targets — REQ-063 moved `users`/`groups`/`tenant_role` out of
  the public schema into each tenant's own schema, so a caller that omitted this
  would resolve against `public`, which no longer holds `users` once the
  Decision 0006 D1 cutover's drop migration has run. The one caller
  (`Letflow.Plugs.AuthPipeline.provision_user/3`) derives this value via
  `Letflow.TenantProvisioning.schema_name_for_tenant/1` on its own
  already-resolved `tenant_id`, never from a caller-supplied/external value.

  Returns `{:ok, %{user: user, created: created?}}` on success, where
  `created?` is `true` only when this call actually inserted the row (`false`
  on every subsequent call for the same identity). Always returns
  `{:error, reason}` on failure — never raises on a realistic failure path
  (JIT-disabled, changeset validation failure including a `username`
  collision, or the conflict-race fallback).
  """
  @spec provision_oidc_user(
          identity_context :: IdentityContext.t(),
          tenant_id :: Ecto.UUID.t(),
          jit_config :: JitProvisioningConfig.t(),
          opts :: opts()
        ) ::
          {:ok, %{user: User.t(), created: boolean()}}
          | {:error, provisioning_error()}
  def provision_oidc_user(
        %IdentityContext{} = identity_context,
        tenant_id,
        %JitProvisioningConfig{} = jit_config,
        opts
      ) do
    if jit_config.enabled do
      upsert_by_external_identity(identity_context, tenant_id, jit_config, opts)
    else
      {:error, :jit_disabled}
    end
  end

  @doc """
  Resolves the tenant bound to a given IdP realm. This is the authoritative
  reverse path from a token's realm claim to a tenant — REQ-021's future
  pipeline calls this before resolving/provisioning the user, and does not
  resolve tenant identity from a client-supplied `tenant_id` claim directly.

  Returns `{:error, :not_found}` if no tenant is bound to `idp_realm_id`.
  """
  @spec resolve_tenant_by_realm(idp_realm_id :: String.t()) ::
          {:ok, Tenant.t()} | {:error, :not_found}
  def resolve_tenant_by_realm(idp_realm_id) do
    case Repo.get_by(Tenant, idp_realm_id: idp_realm_id) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Resolves the IdP realm bound to a given tenant ID.

  Returns `{:ok, nil}` if the tenant exists but has no bound realm (a
  legitimate state for a non-default tenant created while OIDC is disabled —
  not an error). Returns `{:error, :not_found}` if no tenant with that ID
  exists.
  """
  @spec resolve_realm_by_tenant(tenant_id :: Ecto.UUID.t()) ::
          {:ok, String.t() | nil} | {:error, :not_found}
  def resolve_realm_by_tenant(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      %Tenant{idp_realm_id: idp_realm_id} -> {:ok, idp_realm_id}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Realm-ownership guard: verifies that `external_realm` (a token-claimed,
  untrusted value) is actually the realm bound to the already-resolved,
  trusted `tenant_id`. Called by REQ-021's future pipeline before
  `provision_oidc_user/3`, per adp-04a's "Cross-tenant collision boundaries."

  Re-queries the tenant's bound realm from the database itself (via
  `resolve_realm_by_tenant/1`) rather than trusting a caller-supplied realm
  value — a guard that trusted the same claim it's meant to check would be a
  no-op.

  Returns `:ok` if `external_realm` matches the tenant's bound realm.
  Returns `{:error, :realm_tenant_mismatch}` if the tenant exists but its
  bound realm is `nil` or differs from `external_realm`. Returns
  `{:error, :not_found}` if `tenant_id` does not correspond to any tenant.
  """
  @spec verify_realm_ownership(tenant_id :: Ecto.UUID.t(), external_realm :: String.t()) ::
          :ok | {:error, :realm_tenant_mismatch} | {:error, :not_found}
  def verify_realm_ownership(tenant_id, external_realm) do
    case resolve_realm_by_tenant(tenant_id) do
      {:ok, ^external_realm} -> :ok
      {:ok, _mismatched_or_nil} -> {:error, :realm_tenant_mismatch}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @typedoc "Params accepted by `list_users/2` — see its own @doc."
  @type list_users_params :: %{
          optional(:search) => String.t() | nil,
          optional(:status) => :active | :inactive | nil,
          optional(:cursor) => Pagination.Cursor.t() | nil,
          optional(:page_size) => pos_integer()
        }

  @doc """
  Inserts a new internally-created (non-OIDC) user. Ports
  `identity_service.createUser` per
  `lib/letflow/design/req073-identity-user-routes.md` §7 gap 1 — thin,
  changeset + `Repo.insert/2`, no business logic beyond that.

  `attrs` is a caller-validated map (`Letflow.Api.Validation.validate/2`'s
  output, already restricted to the schema's own named fields) with keys
  `"username"`/`"display_name"`/`"email"`/optionally `"status"`.

  Returns `{:error, :duplicate_username}` on a `username` unique-constraint
  violation (mirrors `username_unique_conflict?/1`'s existing check), or
  `{:error, Ecto.Changeset.t()}` for any other changeset failure.
  """
  @spec create_user(attrs :: map(), opts :: user_write_opts()) ::
          {:ok, User.t()}
          | {:error, :duplicate_username}
          | {:error, Ecto.Changeset.t()}
          | {:error, directory_guard_error()}
          | {:error, {:login_directory, term()}}
          | {:error, {:transaction_failed, Exception.t()}}
  def create_user(attrs, opts) do
    with {:ok, directory} <- directory_target(opts) do
      do_create_user(attrs, opts, directory)
    end
  end

  defp do_create_user(attrs, opts, directory) do
    try do
      prefix = Keyword.fetch!(opts, :prefix)
      changeset = User.create_changeset(%User{}, attrs)

      # REQ-195 -- actor_id: nil, per
      # lib/letflow/design/req195-audit-entry-storage.md §3.1b: create_user/2
      # takes only opts :: opts() (prefix-only), and its only caller
      # (lib/letflow/routers/identity.ex) doesn't read any actor-identifying
      # assign today -- widening either would require editing that router,
      # which this requirement's own AC11 forbids. Wrapped in Ecto.Multi here
      # specifically to get the same-transaction guarantee (AC3) -- this
      # function had no transaction of its own before this requirement.
      Multi.new()
      |> Multi.insert(:user, changeset, prefix: prefix)
      |> directory_step(directory, prefix, fn %{user: user} -> {nil, user} end)
      |> Multi.merge(fn %{user: user} ->
        Audit.append_multi(
          Multi.new(),
          :audit,
          %{
            actor_id: nil,
            action: "user.create",
            resource_type: "user",
            resource_id: user.id,
            before_state: nil,
            after_state: Audit.struct_state(user, [:password_hash]),
            trace_id: nil
          },
          prefix
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} ->
          {:ok, user}

        {:error, :user, %Ecto.Changeset{} = changeset, _changes} ->
          if username_unique_conflict?(changeset) do
            {:error, :duplicate_username}
          else
            {:error, changeset}
          end

        {:error, :login_directory, reason, _changes} ->
          {:error, {:login_directory, reason}}

        {:error, :audit, reason, _changes} ->
          {:error, reason}
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  @doc """
  Lists users, filtered by an optional `status` and an optional `search`
  substring (ILIKE across `username`/`display_name`/`email` — design §7 gap 2,
  OQ-4's field-scope choice), cursor-paginated via `Letflow.Api.Pagination`.

  Sorted by `inserted_at` ascending, then `id` ascending as a tiebreaker (OQ-1).
  The minted cursor's freshness (24h expiry) is checked against the wall-clock
  time the cursor was built, not against a row's own `inserted_at` — see
  `build_next_cursor/1`'s comment for why conflating the two would make an
  old row's cursor appear pre-expired the instant it's minted.

  An empty or last page is `{:ok, %{users: [], next_cursor: nil}}`, never an error
  tuple; the only error is `{:error, :invalid_cursor}` for a cursor whose prefix is
  valid but whose payload is malformed (GH 2747).
  """
  @spec list_users(list_users_params(), opts :: opts()) ::
          {:ok, %{users: [User.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor}
  def list_users(params, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    page_size = Map.fetch!(params, :page_size)

    with {:ok, cursor_seek} <- decode_users_cursor(Map.get(params, :cursor)) do
      query =
        User
        |> filter_by_status(Map.get(params, :status))
        |> filter_by_search(Map.get(params, :search))
        |> filter_by_cursor(cursor_seek)
        |> order_by([u], asc: u.inserted_at, asc: u.id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query, prefix: prefix)
      {page, next_cursor} = split_page(rows, page_size)

      {:ok, %{users: page, next_cursor: next_cursor}}
    end
  end

  @doc """
  Fetches a single user by id, scoped to the caller's own tenant schema via
  `opts[:prefix]`. Design §7 gap 3 — the shared lookup every handler
  (including the patch/status-update pre-fetch) uses.
  """
  @spec get_user(id :: Ecto.UUID.t() | String.t(), opts :: opts()) ::
          {:ok, User.t()} | {:error, :not_found}
  def get_user(id, opts) do
    case Repo.get(User, id, prefix: Keyword.fetch!(opts, :prefix)) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Partial-update of a user's profile fields (`display_name`/`email`/`status`
  — all optional). Design §7 gap 4. `attrs` carries only the keys present in
  the request body; an omitted field's existing value is preserved by
  `Ecto.Changeset.cast/3`'s own behavior over an already-loaded struct.

  REQ-435: also maintains the platform login directory in the same
  transaction (design §3.3-§3.4) -- see `t:user_write_opts/0`.

  GH 2564 (design `gh2564-deactivation-revokes-tokens.md` §3): when `attrs` carries a
  `status` key, the write is a status write and behaves as `update_user_status/3` does
  (tenant admin lock, token revocation, zero-tenant-wide-admin guard). Without one, no
  lock is taken and no token is touched.
  """
  @spec update_user_profile(id :: Ecto.UUID.t(), attrs :: map(), opts :: user_write_opts()) ::
          user_write_result()
  def update_user_profile(id, attrs, opts) do
    with {:ok, directory} <- directory_target(opts) do
      update_locked_user(
        id,
        opts,
        directory,
        "user.update_profile",
        fn locked -> User.profile_changeset(locked, attrs) end,
        status_write?(attrs)
      )
    end
  end

  @doc """
  Updates a user's `status` only. Design §7 gap 5 (OQ-5 — a dedicated
  `User.status_changeset/2` rather than reusing `profile_changeset/2`, see
  that function's own @doc).

  REQ-435: also maintains the platform login directory in the same
  transaction (a non-active status removes the entry unless another active
  user in the tenant has the same email) -- see `t:user_write_opts/0`.

  GH 2564 (design `gh2564-deactivation-revokes-tokens.md`, ruling: issue #2564 comment
  6174049298, option 3): in the same transaction, takes `lock_tenant_admins!/1` first
  (for `:active` too: reactivation adds an admin), revokes every non-revoked API token of
  the user when the user is or becomes inactive (one `token.revoke` per token, `cause:
  "owner_deactivated"`; reactivation restores none), and refuses a deactivation that
  takes the tenant from at least one tenant-wide admin to none with
  `{:error, :last_tenant_wide_admin}` (0051 N1; the refusal is then audited in its own
  transaction by `record_guard_refused/2`). A failed token revocation rolls everything
  back and returns `{:error, {:token_revocation_failed, reason}}`.
  """
  @spec update_user_status(
          id :: Ecto.UUID.t(),
          status :: :active | :inactive,
          opts :: user_write_opts()
        ) :: user_write_result()
  def update_user_status(id, status, opts) do
    with {:ok, directory} <- directory_target(opts) do
      update_locked_user(
        id,
        opts,
        directory,
        "user.update_status",
        fn locked -> User.status_changeset(locked, %{status: status}) end,
        true
      )
    end
  end

  @typedoc "Result of `update_user_profile/3` and `update_user_status/3`."
  @type user_write_result ::
          {:ok, User.t()}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
          | {:error, directory_guard_error()}
          | {:error, {:login_directory, term()}}
          | {:error, {:transaction_failed, Exception.t()}}
          | {:error, :last_tenant_wide_admin}
          | {:error, {:token_revocation_failed, term()}}

  # GH 2564 (design §2): a write is a status write when the request carries `status`,
  # whatever its value. Chosen from the request, not the row, because the tenant admin
  # lock must precede the row read.
  @spec status_write?(attrs :: map()) :: boolean()
  defp status_write?(attrs), do: Map.has_key?(attrs, "status") or Map.has_key?(attrs, :status)

  # REQ-435 (design §3.4): the `before` state the directory plan is computed
  # from is read INSIDE the transaction with a row lock (FOR UPDATE), not
  # before it, so two concurrent edits cannot compute plans from the same stale
  # row and leave a ghost entry. The outer rescue (ISS-0983 hardening) is preserved.
  #
  # GH 2564 (design §3): the audit entry carries the actor and trace id from
  # `opts[:audit_context]` (actor nil when none is passed, as REQ-195 had it). Steps
  # marked [S] run only for a status write. Lock order: tenant admin advisory lock ->
  # user row -> token rows by id -> audit chain -> count, the same prefix every other
  # admin-set writer uses, so no cycle. The guard is the transition rule (before > 0 and
  # after == 0): measured, not predicted (#2547 §6.4 step 5).
  @spec update_locked_user(
          Ecto.UUID.t(),
          user_write_opts(),
          term(),
          String.t(),
          (User.t() -> Ecto.Changeset.t()),
          status_write :: boolean()
        ) :: user_write_result()
  defp update_locked_user(id, opts, directory, audit_action, changeset_fun, status_write) do
    prefix = Keyword.fetch!(opts, :prefix)
    ctx = AuditContext.from_opts(opts)

    try do
      Multi.new()
      |> when_status_write(status_write, fn multi ->
        # [S] 1: the FIRST locking statement, before any row lock.
        Multi.run(multi, :tenant_admin_lock, fn _repo, _changes ->
          {:ok, lock_tenant_admins!(prefix)}
        end)
      end)
      |> Multi.run(:locked_user, fn repo, _changes ->
        case repo.one(from(u in User, where: u.id == ^id, lock: "FOR UPDATE"), prefix: prefix) do
          %User{} = locked -> {:ok, locked}
          nil -> {:error, :not_found}
        end
      end)
      |> when_status_write(status_write, fn multi ->
        Multi.run(multi, :admins_before, fn _repo, _changes ->
          {:ok, count_tenant_wide_admins(prefix)}
        end)
      end)
      |> Multi.update(:user, fn %{locked_user: locked} -> changeset_fun.(locked) end,
        prefix: prefix
      )
      |> directory_step(directory, prefix, fn %{locked_user: locked, user: updated} ->
        {locked, updated}
      end)
      |> when_status_write(status_write, fn multi ->
        Multi.run(multi, :revoked_tokens, fn _repo, %{locked_user: locked, user: updated} ->
          if locked.status == :inactive or updated.status == :inactive,
            do: revoke_owner_tokens(updated.id, prefix, ctx),
            else: {:ok, []}
        end)
      end)
      |> Multi.merge(fn %{locked_user: locked, user: updated} = changes ->
        after_state = Audit.struct_state(updated, [:password_hash])

        after_state =
          case changes do
            %{revoked_tokens: revoked} ->
              Map.put(after_state, :revoked_token_count, length(revoked))

            _no_status_write ->
              after_state
          end

        Audit.append_multi(
          Multi.new(),
          :audit,
          %{
            actor_id: ctx.actor_id,
            action: audit_action,
            resource_type: "user",
            resource_id: updated.id,
            before_state: Audit.struct_state(locked, [:password_hash]),
            after_state: after_state,
            trace_id: ctx.trace_id
          },
          prefix
        )
      end)
      |> when_status_write(status_write, fn multi ->
        Multi.run(multi, :admin_guard, fn _repo, %{user: updated, admins_before: before} ->
          admin_guard(updated, before, prefix)
        end)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: updated}} ->
          {:ok, updated}

        {:error, :locked_user, :not_found, _changes} ->
          {:error, :not_found}

        {:error, :user, reason, _changes} ->
          {:error, reason}

        {:error, :login_directory, reason, _changes} ->
          {:error, {:login_directory, reason}}

        {:error, :revoked_tokens, reason, _changes} ->
          {:error, {:token_revocation_failed, reason}}

        {:error, :audit, reason, _changes} ->
          {:error, reason}

        {:error, :admin_guard, {:last_tenant_wide_admin, counted}, _changes} ->
          # The transaction is already rolled back: the refusal is recorded in its own.
          :ok =
            record_guard_refused(prefix, %{
              action: "deactivate_user",
              actor: ctx.actor_id,
              target_id: id,
              reason_code: "last_tenant_wide_admin",
              counted_admins: counted,
              trace_id: ctx.trace_id
            })

          {:error, :last_tenant_wide_admin}
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  defp when_status_write(multi, true, fun), do: fun.(multi)
  defp when_status_write(multi, false, _fun), do: multi

  # GH 2564 (design §3 step 8): only a write that leaves the user inactive can remove an
  # admin. Refuses the transition from at least one tenant-wide admin to none.
  @spec admin_guard(User.t(), non_neg_integer(), String.t()) ::
          {:ok, non_neg_integer() | :not_checked}
          | {:error, {:last_tenant_wide_admin, non_neg_integer()}}
  defp admin_guard(%User{status: :inactive}, before, prefix) do
    case count_tenant_wide_admins(prefix) do
      0 when before > 0 -> {:error, {:last_tenant_wide_admin, 0}}
      counted -> {:ok, counted}
    end
  end

  defp admin_guard(%User{}, _before, _prefix), do: {:ok, :not_checked}

  # GH 2564 (design §2): revokes every non-revoked token of `user_id` (expired ones
  # included), row by row in id order under FOR UPDATE, all with one second-truncated
  # `revoked_at`, one `token.revoke` each with `cause: "owner_deactivated"`. Per-row
  # changesets, never `update_all` (anti-patterns: ISS-0906). Stops at the first error.
  # Runs inside the caller's transaction, after the tenant admin lock.
  @spec revoke_owner_tokens(user_id :: Ecto.UUID.t(), prefix :: String.t(), AuditContext.t()) ::
          {:ok, [ApiToken.t()]} | {:error, Ecto.Changeset.t() | term()}
  defp revoke_owner_tokens(user_id, prefix, ctx) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in ApiToken,
      where: t.user_id == ^user_id and is_nil(t.revoked_at),
      order_by: t.id,
      lock: "FOR UPDATE"
    )
    |> Repo.all(prefix: prefix)
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
      case revoke_token_row(token, prefix, ctx, "owner_deactivated", now) do
        {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, revoked} -> {:ok, Enum.reverse(revoked)}
      error -> error
    end
  end

  @doc false
  # GH 2564 (design §2, 0051 D8 and N1): records a refused tenant-admin guard as
  # `tenant_admin.guard_refused` in its OWN transaction, after the refused change has
  # rolled back (a row written inside the refused transaction would roll back with it).
  # Shared with #2533 1b: keep the name and the map keys. `after_state` is exactly
  # `{action, actor, target_id, reason_code, counted_admins, trace_id}`. Raises
  # `ArgumentError` inside a transaction (a programming error). Otherwise never raises: a
  # failed write is logged (no message, no value) and `:ok` is returned, because the
  # refusal itself stands.
  # REQ-497 PR 1b: the optional `:resource_type` (default "user") names the kind of the
  # refused target (group_member, tenant_role, api_token ...); the six keys are unchanged.
  @spec record_guard_refused(
          prefix :: String.t(),
          refusal :: %{
            required(:action) => String.t(),
            required(:actor) => Ecto.UUID.t() | nil,
            required(:target_id) => Ecto.UUID.t(),
            required(:counted_admins) => non_neg_integer(),
            required(:trace_id) => String.t() | nil,
            optional(:reason_code) => String.t(),
            optional(:resource_type) => String.t()
          }
        ) :: :ok
  def record_guard_refused(prefix, refusal) when is_binary(prefix) and is_map(refusal) do
    if Repo.in_transaction?() do
      raise ArgumentError, "record_guard_refused/2 must run outside a transaction"
    end

    state = %{
      action: Map.fetch!(refusal, :action),
      actor: Map.fetch!(refusal, :actor),
      target_id: Map.fetch!(refusal, :target_id),
      reason_code: Map.get(refusal, :reason_code, "last_tenant_wide_admin"),
      counted_admins: Map.fetch!(refusal, :counted_admins),
      trace_id: Map.fetch!(refusal, :trace_id)
    }

    attrs = %{
      actor_id: state.actor,
      action: "tenant_admin.guard_refused",
      resource_type: Map.get(refusal, :resource_type, "user"),
      resource_id: state.target_id,
      before_state: nil,
      after_state: state,
      trace_id: state.trace_id
    }

    result =
      try do
        Audit.insert_entry(Repo, attrs, prefix)
      rescue
        exception -> {:error, exception}
      end

    case result do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.error("tenant_admin.guard_refused audit write failed",
          action: state.action,
          target_id: state.target_id,
          trace_id: state.trace_id,
          error_kind: guard_error_kind(reason)
        )

        :ok
    end
  end

  # Never a message or a value: the struct's module, the atom, or :unknown.
  defp guard_error_kind(%{__struct__: module}), do: module
  defp guard_error_kind(reason) when is_atom(reason), do: reason
  defp guard_error_kind(_reason), do: :unknown

  @typedoc """
  Opts for the user-write functions that maintain the platform login directory
  (REQ-435, design §3.2): `:prefix` as before, plus a required `:tenant_id`
  supplied by the caller from the authenticated context (never from request
  data). A fail-closed guard checks that `schema_name_for_tenant(tenant_id)`
  equals `:prefix` before any write. `:login_directory` set to `:skip` disables
  the directory write; it exists only for test fixtures whose synthetic schema
  prefix has no `tenants` row, and no `lib/` caller may use it. GH 2564: an optional
  `:audit_context` (see `Letflow.Identity.AuditContext.from_opts/1`) sets the actor and
  trace id of the audit entries.
  """
  @type user_write_opts :: [
          prefix: String.t(),
          tenant_id: Ecto.UUID.t(),
          login_directory: :enabled | :skip,
          audit_context: map()
        ]

  @type directory_guard_error ::
          :tenant_id_required | :invalid_tenant_id | :tenant_prefix_mismatch

  # Fail-closed consistency guard (design §3.2). Returns `{:ok, :skip}` for the
  # test-only opt-out, else `{:ok, {:enabled, canonical_tenant_id}}`, else one
  # of the three typed guard errors. Writes nothing.
  @spec directory_target(opts :: keyword()) ::
          {:ok, :skip | {:enabled, Ecto.UUID.t()}} | {:error, directory_guard_error()}
  defp directory_target(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Keyword.get(opts, :login_directory, :enabled) do
      :skip ->
        {:ok, :skip}

      _enabled ->
        case Keyword.get(opts, :tenant_id) do
          nil ->
            {:error, :tenant_id_required}

          tenant_id ->
            case TenantProvisioning.schema_name_for_tenant(tenant_id) do
              {:ok, ^prefix} ->
                {:ok, canonical} = Ecto.UUID.cast(tenant_id)
                {:ok, {:enabled, canonical}}

              {:ok, _other_schema} ->
                {:error, :tenant_prefix_mismatch}

              {:error, :invalid_tenant_id} ->
                {:error, :invalid_tenant_id}
            end
        end
    end
  end

  # Adds the `:login_directory` Multi step. `states_fun` maps the changes so far
  # to `{before_user_or_nil, after_user}` for `LoginDirectory.plan_user_change/2`.
  defp directory_step(multi, :skip, _prefix, _states_fun), do: multi

  defp directory_step(multi, {:enabled, tenant_id}, prefix, states_fun) do
    Multi.run(multi, :login_directory, fn _repo, changes ->
      {before, after_user} = states_fun.(changes)

      case LoginDirectory.apply_plan(
             LoginDirectory.plan_user_change(before, after_user),
             tenant_id,
             prefix
           ) do
        :ok -> {:ok, :done}
        {:error, _reason} = error -> error
      end
    end)
  end

  @typedoc "Params accepted by `list_group_members/3` — see its own @doc."
  @type list_group_members_params :: %{
          optional(:cursor) => Pagination.Cursor.t() | nil,
          optional(:page_size) => pos_integer()
        }

  @doc """
  Inserts a new group. Ports `identity_service.createGroup`, design §8 gap 1
  — thin, changeset (`Group.create_changeset/2`) + `Repo.insert/2`.

  `attrs` is a caller-validated map (`Letflow.Api.Validation.validate/2`'s
  output) with keys `"name"`/optionally `"display_name"`/`"description"`.
  `display_name` defaults to `name`, and an empty `description` is
  normalized to `nil`, both inside `Group.create_changeset/2` itself (design
  §3.1) — this function passes `attrs` through unchanged.

  Returns `{:error, :duplicate_group_name}` on a `name` unique-constraint
  violation.
  """
  @spec create_group(attrs :: map(), opts :: opts()) ::
          {:ok, Group.t()}
          | {:error, :duplicate_group_name}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:transaction_failed, Exception.t()}}
  def create_group(attrs, opts) do
    try do
      prefix = Keyword.fetch!(opts, :prefix)
      changeset = Group.create_changeset(%Group{}, attrs)

      # REQ-195 -- actor_id: nil, §3.1b (same disposition/reasoning as
      # create_user/2 above). Wrapped in Ecto.Multi for the same-transaction
      # guarantee (AC3).
      Multi.new()
      |> Multi.insert(:group, changeset, prefix: prefix)
      |> Multi.merge(fn %{group: group} ->
        Audit.append_multi(
          Multi.new(),
          :audit,
          %{
            actor_id: nil,
            action: "group.create",
            resource_type: "group",
            resource_id: group.id,
            before_state: nil,
            after_state: Audit.struct_state(group),
            trace_id: nil
          },
          prefix
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{group: group}} ->
          {:ok, group}

        {:error, :group, %Ecto.Changeset{} = changeset, _changes} ->
          if group_name_unique_conflict?(changeset) do
            {:error, :duplicate_group_name}
          else
            {:error, changeset}
          end

        {:error, :audit, reason, _changes} ->
          {:error, reason}
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  @doc """
  Adds a user to a group, idempotently. Ports `identity_service.addGroupMember`,
  design §8 gap 2.

  Looks up the group (→ `:group_not_found`) then the user (→
  `:user_not_found`), both scoped to `opts[:prefix]` — this existence check is
  the exact mechanism the cross-tenant-membership test (design §4) depends
  on: a `user_id` belonging to a different tenant simply does not exist as a
  row under this tenant's own schema, so it 404s the same way a genuinely
  nonexistent user id does, with no membership row ever inserted.

  Select-first, insert-if-absent — the same "check, then conditionally
  insert" shape `upsert_by_external_identity/4` (this module, above) already
  uses. `provision_oidc_user/4`'s sibling `insert_or_fetch/4` instead
  inserts first and re-selects by its own freshly-generated surrogate id to
  tell "genuinely inserted" from "suppressed by ON CONFLICT" apart — that
  trick depends on the id being unique to *this* call, which doesn't hold
  here: `group_members` has no surrogate id (OQ-7), so a post-insert
  re-select by `(group_id, user_id)` would find a row regardless of whether
  *this* call or an earlier one wrote it, and couldn't distinguish
  created-vs-not at all. Checking existence *before* attempting the insert
  sidesteps that — the only remaining ambiguity is a genuine concurrent
  race between the existence check and the insert, handled by re-selecting
  once more after an `on_conflict: :nothing` insert that could have been
  suppressed by that race.

  Returns `{:ok, %{member: GroupMember.t(), created: created?}}` —
  `created?` is `false` when the membership already existed.

  GH 2547 (design `gh2547-tenant-admin-audit-and-count.md` sections 3.2, 6.6): runs in
  one transaction whose first statement is `lock_tenant_admins!/1` (always, any group).
  A row this call actually inserted writes one `group_member.added` audit entry in the
  same transaction (actor, trace and source from `opts[:audit_context]`); a re-add
  writes nothing. A non-raising audit failure rolls back and returns
  `{:error, {:audit_failed, reason}}`; a raise returns
  `{:error, {:transaction_failed, exception}}`.

  `opts[:group_member_audit]` is `:emit` by default; any value other than
  `:caller_audits` is treated as `:emit`. `:caller_audits` suppresses only the audit
  row, for the one caller that writes its own event in the same, already-open
  transaction (the pending-admin-grant bind); outside a transaction it returns
  `{:error, :caller_audit_requires_transaction}` before any query.

  REQ-517 AC 10: `opts[:refuse_self_add]` (default `false`; only `POST /groups/:id/members`
  passes `true`). When true and `user_id` is the audit context's actor, the transaction rolls
  back after lock A and before any insert with `{:error, :self_grant_refused}`.
  """
  @spec add_group_member(group_id :: Ecto.UUID.t(), user_id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, %{member: GroupMember.t(), created: boolean()}}
          | {:error, :group_not_found}
          | {:error, :user_not_found}
          | {:error, :caller_audit_requires_transaction}
          | {:error, :self_grant_refused}
          | {:error, {:audit_failed, term()}}
          | {:error, {:transaction_failed, Exception.t()}}
  def add_group_member(group_id, user_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    mode = group_member_audit_mode(opts)

    if mode == :caller_audits and not Repo.in_transaction?() do
      {:error, :caller_audit_requires_transaction}
    else
      ctx = AuditContext.from_opts(opts)
      refuse_self? = Keyword.get(opts, :refuse_self_add, false) == true

      try do
        Repo.transaction(
          fn -> do_add_group_member(group_id, user_id, prefix, mode, ctx, refuse_self?) end,
          prefix: prefix
        )
      rescue
        exception -> {:error, {:transaction_failed, exception}}
      end
    end
  end

  @doc false
  # Canonical UUID comparison; a nil or uncastable id never matches. Shared with
  # `Letflow.Identity.ScopedGrants` (REQ-517 self-grant check).
  @spec same_user_id?(term(), term()) :: boolean()
  def same_user_id?(a, b) do
    with {:ok, left} <- Ecto.UUID.cast(a), {:ok, right} <- Ecto.UUID.cast(b) do
      left == right
    else
      _no_match -> false
    end
  end

  # Fail to auditing: only the exact literal opts out.
  defp group_member_audit_mode(opts) do
    case Keyword.get(opts, :group_member_audit, :emit) do
      :caller_audits -> :caller_audits
      _emit_or_unknown -> :emit
    end
  end

  # Runs inside add_group_member/3's transaction. Lock order (design section 3.0): the
  # tenant admin lock first; the group row is then locked by the membership insert's FK
  # check (KEY SHARE).
  defp do_add_group_member(group_id, user_id, prefix, mode, ctx, refuse_self?) do
    lock_tenant_admins!(prefix)

    # REQ-517 AC 10: a caller may not add THEMSELVES to a group (only the HTTP route passes
    # `refuse_self_add: true`); decided under lock A, before any insert.
    if refuse_self? and same_user_id?(user_id, ctx.actor_id),
      do: Repo.rollback(:self_grant_refused)

    if is_nil(Repo.get(Group, group_id, prefix: prefix)), do: Repo.rollback(:group_not_found)
    if is_nil(Repo.get(User, user_id, prefix: prefix)), do: Repo.rollback(:user_not_found)

    # Read only when an audit row may be written (`:caller_audits` writes none).
    before_roles = if mode == :emit, do: sorted_effective_role_names(user_id, prefix), else: []
    before_scope = if mode == :emit, do: MembershipScope.snapshot(user_id, prefix), else: %{}

    case insert_or_fetch_group_member(group_id, user_id, prefix) do
      {:ok, %{member: member, created: created, inserted: inserted}} ->
        if inserted and mode == :emit do
          case insert_membership_audit(
                 :added,
                 group_id,
                 user_id,
                 {before_roles, before_scope},
                 prefix,
                 ctx
               ) do
            {:ok, _entry} -> :ok
            {:error, reason} -> Repo.rollback({:audit_failed, reason})
          end
        end

        %{member: member, created: created}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  @doc """
  Lists all groups, unpaginated (design §8 gap 3 — no acceptance criterion
  for this requirement calls for cursor pagination on this endpoint, unlike
  `list_group_members/3`).

  PROVENANCE (historical, not current decision authority):
  Ordered by `name` ascending (OQ-5 — this design's own reasonable default,
  not confirmed against `registry.zig`'s own `listGroups` ordering).

  Always returns `{:ok, _}`.
  """
  @spec list_groups(opts :: opts()) :: {:ok, %{groups: [Group.t()], total: non_neg_integer()}}
  def list_groups(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    query = from(g in Group, order_by: [asc: g.name])

    groups = Repo.all(query, prefix: prefix)
    total = Repo.aggregate(Group, :count, prefix: prefix)

    {:ok, %{groups: groups, total: total}}
  end

  @doc """
  Deletes a group, refusing (rather than cascading) if it still has members —
  design §8 gap 4/§5. Uses a guarded `DELETE ... WHERE NOT EXISTS (...)`:
  a group with ≥1 member and a genuinely nonexistent group both return
  `{:error, :not_found_or_has_members}` — one unified error atom,
  deliberately, so a caller cannot branch on that distinction either (§5).

  A memberless group that any role binding (`tenant_role`, any `kind`) points to returns
  `{:error, :bound_to_role}` (ISS-1032), mapped from the FK violation. Precondition: do not
  call inside a caller's open transaction (the failed statement would abort it).

  Uses `Ecto.Query`'s `not exists/1` (OQ-6, ELIXIR-DEV's choice over raw
  SQL) — empirically verified that a single `prefix:` option passed to
  `Repo.delete_all/2` propagates uniformly to both the outer query and the
  `not exists/1` subquery (no separate per-source prefix needed), so this
  stays inside `Ecto.Query` without a raw-SQL escape hatch.
  """
  @spec delete_group(id :: Ecto.UUID.t() | String.t(), opts :: opts()) ::
          :ok | {:error, :not_found_or_has_members} | {:error, :bound_to_role}
  def delete_group(id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    query =
      from(g in Group,
        as: :group,
        where: g.id == ^id,
        where: not exists(from(m in GroupMember, where: parent_as(:group).id == m.group_id))
      )

    # GH 2547 (design section 6.6): the tenant admin lock is the transaction's first
    # statement. An FK violation raises out of the transaction (after its rollback) into
    # the rescue below, so the ISS-1032 mapping is unchanged.
    Repo.transaction(
      fn ->
        lock_tenant_admins!(prefix)

        # REQ-497 W6: no grant row outlives its group principal.
        case Repo.delete_all(query, prefix: prefix) do
          {1, _} = deleted ->
            _count = RoleScopeGrants.delete_group_principal_rows!(id, prefix)
            deleted

          not_deleted ->
            not_deleted
        end
      end,
      prefix: prefix
    )
    |> case do
      {:ok, {1, _}} -> :ok
      {:ok, {0, _}} -> {:error, :not_found_or_has_members}
    end
  rescue
    # ISS-1032: a memberless group that a `tenant_role` row points to hits the
    # `tenant_role.group_id` FK (NO ACTION). The FK is the only race-safe authority, so the
    # one named violation is mapped; any other Postgrex error is re-raised unchanged.
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{
          postgres: %{code: :foreign_key_violation, constraint: "tenant_role_group_id_fkey"}
        } ->
          {:error, :bound_to_role}

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  @doc """
  Casts an id exactly as the identity route guards and lookups do (`Ecto.UUID.cast/1`,
  INV-10) and returns the canonical lower-case hyphenated text, or `:error` for anything
  that is not a UUID (ISS-1033). Accepts canonical, upper/mixed-case and raw 16-byte input.
  """
  @spec cast_id(term()) :: {:ok, String.t()} | :error
  def cast_id(id), do: Ecto.UUID.cast(id)

  @doc """
  Lists a group's members, cursor-paginated (design §8 gap 5/§1/§3.5 — the
  one member-listing endpoint this requirement ships, using the
  cursor-paginated mechanism `handleListGroupMembers` built but R-Co never
  routed, rather than the bare-array shape `handleListGroupMembersArray`
  actually serves).

  Looks up the group first (→ `:group_not_found`; this single scoped lookup
  is what collapses R-Co's separate `GroupNotFound`/`CrossTenantAccessDenied`
  cases into one, per §3.5), then joins `GroupMember` to `User` on
  `user_id`, both filtered by `opts[:prefix]`. Ordered by
  `GroupMember.inserted_at` ascending, then `user_id` ascending (tiebreaker,
  OQ-4 — same OQ-1-shaped choice as `list_users/2`).

  PROVENANCE (historical, not current decision authority):
  Cursor prefix is `"G:"` (distinct from `list_users/2`'s `"U:"` — the
  distinct namespace stops a cursor minted for one listing endpoint from
  being replayed against the other), using the same cursor-prefix literal
  as the unrouted `handleListGroupMembers` (`identity_service.zig:1107`).
  Same mint-time-vs-row-time care as
  `list_users/2`'s `build_next_cursor/1` — the cursor's expiry-checked slot
  carries the mint time, not `inserted_at`, so an old membership row's
  cursor never appears pre-expired the instant it's minted.
  """
  @spec list_group_members(
          group_id :: Ecto.UUID.t(),
          params :: list_group_members_params(),
          opts :: opts()
        ) ::
          {:ok, %{members: [User.t()], next_cursor: String.t() | nil}}
          | {:error, :group_not_found | :invalid_cursor}
  def list_group_members(group_id, params, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get(Group, group_id, prefix: prefix) do
      nil ->
        {:error, :group_not_found}

      %Group{} ->
        page_size = Map.fetch!(params, :page_size)

        with {:ok, cursor_seek} <- decode_group_members_cursor(Map.get(params, :cursor)) do
          query =
            from(m in GroupMember,
              join: u in User,
              on: u.id == m.user_id,
              where: m.group_id == ^group_id,
              select: {u, m.inserted_at}
            )
            |> filter_group_members_by_cursor(cursor_seek)
            |> order_by([m, u], asc: m.inserted_at, asc: m.user_id)
            |> limit(^(page_size + 1))

          rows = Repo.all(query, prefix: prefix)
          {page, next_cursor} = split_group_members_page(rows, page_size)

          {:ok, %{members: page, next_cursor: next_cursor}}
        end
    end
  end

  @doc """
  Removes a user from a group, idempotently (design §8 gap 6/§1b/§3.6 —
  single-member removal at `DELETE /groups/:id/members/:user_id`, ported
  from `handleRemoveGroupMember`'s never-routed signature; see OQ-1 for the
  open question about whether this is the right port target versus R-Co's
  live bulk-remove-all route, flagged for REVIEWER, not resolved here).

  Looks up the group first (→ `:group_not_found`), then deletes the matching
  membership row if one exists — `Repo.delete_all/2` on zero matching rows
  is still `:ok`: the caller's intent ("this user should not be a member")
  is already satisfied whether or not a row existed to delete, so there is
  no "member didn't exist" error variant.

  GH 2547 (design sections 3.3, 6.6): one transaction; `lock_tenant_admins!/1` first
  (always, any group), then the group row `FOR KEY SHARE`. A deleted row writes one
  `group_member.removed` audit entry in the same transaction; removing a non-member
  writes nothing. A non-raising audit failure rolls back and returns
  `{:error, {:audit_failed, reason}}`; a raise returns
  `{:error, {:transaction_failed, exception}}`.

  REQ-497 PR 1b (design `req497-1b-allowed-flag-shadow-n1.md` 6.2 (b)): the `TENANT_ADMIN`
  binding row is locked right after the tenant admin lock. Removing a member of the group
  that binding points to must leave a tenant-wide admin; otherwise the removal rolls back
  and `{:error, :last_tenant_wide_admin}` is returned after one `tenant_admin.guard_refused`
  entry (action `remove_tenant_admin_member`) is written in its own transaction.
  """
  @spec remove_group_member(
          group_id :: Ecto.UUID.t(),
          user_id :: Ecto.UUID.t(),
          opts :: opts()
        ) ::
          :ok
          | {:error, :group_not_found}
          | {:error, :last_tenant_wide_admin}
          | {:error, {:audit_failed, term()}}
          | {:error, {:transaction_failed, Exception.t()}}
  def remove_group_member(group_id, user_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    ctx = AuditContext.from_opts(opts)

    try do
      Repo.transaction(
        fn -> do_remove_group_member(group_id, user_id, prefix, ctx) end,
        prefix: prefix
      )
      |> case do
        {:ok, :ok} -> :ok
        {:error, {:tenant_admin_guard, refusal}} -> TenantAdminGuard.refuse(prefix, refusal, ctx)
        {:error, reason} -> {:error, reason}
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  defp do_remove_group_member(group_id, user_id, prefix, ctx) do
    lock_tenant_admins!(prefix)

    # REQ-497 PR 1b (design 6.2 (b)): rank R, the TENANT_ADMIN binding row, before the group.
    admin_group_id =
      prefix |> TenantAdminGuard.lock_admin_binding!() |> TenantAdminGuard.admin_group_id()

    # A delete of a referencing row takes no parent lock by itself; KEY SHARE makes a
    # concurrent binding write on this group (FOR UPDATE) serialise with this removal.
    if is_nil(key_share_lock_group(group_id, prefix)), do: Repo.rollback(:group_not_found)

    before_roles = sorted_effective_role_names(user_id, prefix)
    before_scope = MembershipScope.snapshot(user_id, prefix)

    # N1 transition rule: the before-count, under lock A and the row locks, before the
    # delete, only for the group the TENANT_ADMIN platform binding points to.
    admin_before =
      if same_uuid_text?(group_id, admin_group_id),
        do: TenantAdminGuard.count_before!(prefix)

    {count, _rows} =
      from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id)
      |> Repo.delete_all(prefix: prefix)

    # N1: after the delete, before the membership audit; rolls back when the removal took
    # the count from above 0 to 0.
    if count == 1 and is_integer(admin_before) do
      :ok =
        TenantAdminGuard.ensure_admins_remain!(
          prefix,
          :remove_tenant_admin_member,
          user_id,
          admin_before
        )
    end

    if count == 1 do
      case insert_membership_audit(
             :removed,
             group_id,
             user_id,
             {before_roles, before_scope},
             prefix,
             ctx
           ) do
        {:ok, _entry} -> :ok
        {:error, reason} -> Repo.rollback({:audit_failed, reason})
      end
    end

    :ok
  end

  defp same_uuid_text?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same_uuid_text?(_a, _b), do: false

  defp key_share_lock_group(group_id, prefix) do
    Repo.one(from(g in Group, where: g.id == ^group_id, lock: "FOR KEY SHARE"), prefix: prefix)
  end

  @doc """
  Live, uncached role-name lookup for a user (REQ-378 §1-§2 —
  `lib/letflow/design/req378-oidc-live-revocation-check.md`): joins
  `group_members` (this user's memberships) to `tenant_role` on
  `tenant_role.group_id == group_members.group_id`, returning the distinct
  set of role names currently in effect.

  Deliberately added to `Letflow.Identity` rather than
  `Letflow.Identity.RoleRegistry`, whose moduledoc states it has no coupling
  to the OIDC/claim-mapping pipeline — see the design §2 for the full
  reasoning.

  One `Repo.all/2` per call — no caching, no ETS, no memoization, matching
  `verify_api_token/2`'s own uncached-per-call shape so a role revocation
  (a `group_members` row delete) takes effect on the very next call, not
  after some refresh interval.

  Returns `[]` (never an error tuple) when the user belongs to no
  role-bearing group.

  **ISS-0774**: filtered to `tenant_role` rows with `kind == :platform_role`
  — this is the one and only function whose output ever reaches
  `Letflow.Api.Authorization.roles_from_strings/1`, so a process-routing
  role name (a `HUMAN_TASK` routing group binding, structurally unrelated to
  platform permissions — see `lib/letflow/design/iss-0774-role-domain-authorization.md`
  §0) can never reach that untrusted-input-shaped conversion via this path,
  regardless of how many process-routing roles the user holds.
  """
  @spec list_effective_role_names(user_id :: Ecto.UUID.t(), opts :: opts()) :: [String.t()]
  def list_effective_role_names(user_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    query =
      from(gm in GroupMember,
        join: tr in TenantRole,
        on: tr.group_id == gm.group_id,
        where: gm.user_id == ^user_id and tr.kind == :platform_role,
        select: tr.name,
        distinct: true
      )

    Repo.all(query, prefix: prefix)
  end

  @doc """
  GH 2547 (design `gh2547-tenant-admin-audit-and-count.md` section 6, the "Contract for
  #2533 / 7b-2b"): the number of tenant-wide administrators in the tenant schema
  `prefix`. This is the single required source for the 0051 N1 last-admin guard and
  the 0053 D6 / open point 9 eligible-publisher check.

  Counts DISTINCT users with `status == :active` who are (a) a member of the group the
  `TENANT_ADMIN` `:platform_role` binding points to, or (b) the owner of an `api_tokens`
  row whose `roles` contain `"TENANT_ADMIN"`, not revoked, and not expired
  (`expires_at` nil or after now). A user who is both counts once; `PLATFORM_ADMIN` does
  not count; tokens of a deactivated user do not count. Holders limited to an org scope
  are removed by the private `exclude_scoped_holders/2` step (REQ-497 PR 1b): a group
  member whose TENANT_ADMIN rows (user or group) are all scoped is not counted; a token
  owner is never removed by it, and a binding with zero rows is still counted in stage 1.

  One read query: opens no transaction, takes no lock, writes nothing. Inside a
  caller's `Repo.transaction` it sees that transaction's own uncommitted writes. Raises
  on a DB error.

  Lock protocol for a caller that changes the admin set and then guards on this count,
  all in one transaction: `lock_tenant_admins!/1` first, then the TENANT_ADMIN role row
  by name (`FOR UPDATE`, no `kind` filter), then the group row, then business rows,
  then the audit chain; write, then count, then roll back on 0. Because every admin-adding
  path takes that lock, first logins that carry role claims serialise per tenant.
  """
  @spec count_tenant_wide_admins(prefix :: String.t()) :: non_neg_integer()
  def count_tenant_wide_admins(prefix) when is_binary(prefix) do
    prefix
    |> tenant_wide_admins_query(DateTime.utc_now())
    |> select([u], count(u.id, :distinct))
    |> Repo.one(prefix: prefix)
  end

  @doc """
  GH 2547: exactly the set `count_tenant_wide_admins/1` counts, as canonical UUID
  strings sorted ascending. Same transaction properties (no transaction, no lock, no
  write; sees the caller's uncommitted writes). Lets 0053 D6 ask whether the single
  tenant-wide admin IS the publishing author, from the same definition.
  """
  @spec tenant_wide_admin_user_ids(prefix :: String.t()) :: [Ecto.UUID.t()]
  def tenant_wide_admin_user_ids(prefix) when is_binary(prefix) do
    prefix
    |> tenant_wide_admins_query(DateTime.utc_now())
    |> select([u], u.id)
    |> order_by([u], asc: u.id)
    |> Repo.all(prefix: prefix)
  end

  @doc """
  REQ-517 (design `req517-scoped-grants-admin-plane.md` section 3.9, finding F1): the number
  of EXPLICIT tenant-wide administrators. Same base query as `count_tenant_wide_admins/1`
  (active users; the live-token half is identical), but a group-sourced holder must have a
  `tenant_wide = true` TENANT_ADMIN row, as a user principal or as the bound group. A member
  of a binding with ZERO rows, which `count_tenant_wide_admins/1` still counts but
  `Letflow.Api.Scope.allowed?/3` denies under `on`, is NOT counted here. Used by
  `revoke_tenant_admin_grant`. Read-only, no lock, same transaction visibility.
  """
  @spec count_explicit_tenant_wide_admins(prefix :: String.t()) :: non_neg_integer()
  def count_explicit_tenant_wide_admins(prefix) when is_binary(prefix) do
    prefix
    |> tenant_wide_admins_query(DateTime.utc_now(), :explicit)
    |> select([u], count(u.id, :distinct))
    |> Repo.one(prefix: prefix)
  end

  @doc "REQ-517: true when a `users` row with `user_id` exists in `prefix`. Plain read."
  @spec user_exists?(user_id :: Ecto.UUID.t(), prefix :: String.t()) :: boolean()
  def user_exists?(user_id, prefix) when is_binary(prefix),
    do: Repo.exists?(from(u in User, where: u.id == ^user_id), prefix: prefix)

  @doc "REQ-517: true when a `groups` row with `group_id` exists in `prefix`. Plain read."
  @spec group_exists?(group_id :: Ecto.UUID.t(), prefix :: String.t()) :: boolean()
  def group_exists?(group_id, prefix) when is_binary(prefix),
    do: Repo.exists?(from(g in Group, where: g.id == ^group_id), prefix: prefix)

  @doc """
  REQ-517: true when a `tenant_role` row binds `group_id` to `role` as a `:platform_role`
  (a routing-kind binding does not count). Plain read.
  """
  @spec group_bound_to_platform_role?(
          group_id :: Ecto.UUID.t(),
          role :: String.t(),
          prefix :: String.t()
        ) :: boolean()
  def group_bound_to_platform_role?(group_id, role, prefix) when is_binary(prefix) do
    Repo.exists?(
      from(t in TenantRole,
        where: t.group_id == ^group_id and t.name == ^role and t.kind == ^:platform_role
      ),
      prefix: prefix
    )
  end

  @doc "REQ-517: true when `user_id` is a member of `group_id`. Plain read."
  @spec group_member?(group_id :: Ecto.UUID.t(), user_id :: Ecto.UUID.t(), prefix :: String.t()) ::
          boolean()
  def group_member?(group_id, user_id, prefix) when is_binary(prefix) do
    Repo.exists?(
      from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id),
      prefix: prefix
    )
  end

  # GH 2547 (design section 6.2): the one definition both public helpers share, so the
  # count and the id list can never diverge. `now` is taken once per call; truncating it
  # to the second keeps verify_api_token/2's strict `expires_at > now` result unchanged
  # (`expires_at` is whole seconds). The role name is a bound parameter (INV-7). `mode` is
  # `:counted` (the stage-1 definition) or `:explicit` (REQ-517 F1: a group-sourced holder
  # needs a tenant-wide TENANT_ADMIN row).
  @spec tenant_wide_admins_query(
          prefix :: String.t(),
          now :: DateTime.t(),
          mode :: :counted | :explicit
        ) :: Ecto.Query.t()
  defp tenant_wide_admins_query(prefix, now, mode \\ :counted) do
    now = DateTime.truncate(now, :second)

    member_of_admin_group =
      from(gm in GroupMember,
        as: :admin_member,
        join: tr in TenantRole,
        as: :admin_binding,
        on: tr.group_id == gm.group_id,
        where:
          gm.user_id == parent_as(:user).id and tr.name == ^@tenant_admin_role and
            tr.kind == :platform_role
      )
      |> admin_group_holder_filter(prefix, mode)

    owns_live_admin_token =
      from(t in ApiToken,
        where:
          t.user_id == parent_as(:user).id and
            fragment("? = ANY(?)", ^@tenant_admin_role, t.roles) and is_nil(t.revoked_at) and
            (is_nil(t.expires_at) or t.expires_at > ^now)
      )

    from(u in User,
      as: :user,
      where: ^active_user_condition(:user),
      where: exists(member_of_admin_group) or exists(owns_live_admin_token)
    )
  end

  defp admin_group_holder_filter(query, prefix, :counted),
    do: exclude_scoped_holders(query, prefix)

  # REQ-517 F1: an explicit holder has a tenant-wide TENANT_ADMIN row (user or bound group).
  defp admin_group_holder_filter(query, _prefix, :explicit),
    do: where(query, [], exists(admin_member_ta_rows(true)))

  # REQ-497 PR 1b (design `req497-1b-allowed-flag-shadow-n1.md` 5.1, 0051 D1): applied to
  # the TENANT_ADMIN group-membership subquery ONLY (bindings `:admin_member` and
  # `:admin_binding`), never to the token half: a token principal is tenant-wide by rule, so a
  # TA token owner is always counted (the Option A ruling for revoke_token relies on it).
  # A member is dropped when they are a SCOPED-ONLY holder: at least one TENANT_ADMIN row with
  # `tenant_wide = false` exists for (user, the member) or (group, the bound group), and no
  # `tenant_wide = true` row exists for either. Consequences: with only tenant-wide rows
  # (every stage-1 tenant) nothing is dropped; a binding with ZERO rows (a T9 gap) is still
  # counted in stage 1 (OQ-4 ruling; #2535 revisits it for enforced tenants). Both
  # `count_tenant_wide_admins/1` and `tenant_wide_admin_user_ids/1` pass through here. Its
  # role-name twin is `exclude_scoped_role_names/3`. Values are bound (INV-7); the caller's
  # Repo call carries the prefix.
  @spec exclude_scoped_holders(query :: Ecto.Query.t(), prefix :: String.t()) :: Ecto.Query.t()
  defp exclude_scoped_holders(query, _prefix) do
    scoped_rows = admin_member_ta_rows(false)
    tenant_wide_rows = admin_member_ta_rows(true)

    where(query, [], not (exists(scoped_rows) and not exists(tenant_wide_rows)))
  end

  defp admin_member_ta_rows(tenant_wide?) do
    from(g in RoleScopeGrant,
      where:
        g.role == ^@tenant_admin_role and g.tenant_wide == ^tenant_wide? and
          ((g.principal_type == ^:user and g.principal_id == parent_as(:admin_member).user_id) or
             (g.principal_type == ^:group and
                g.principal_id == parent_as(:admin_binding).group_id))
    )
  end

  @doc """
  GH 2547 (design section 6.6): the 64-bit advisory-lock key of the tenant admin lock
  for the tenant schema `prefix`. Pure, no DB access.

  The first 8 bytes of SHA-256 over a fixed, versioned label plus `prefix`, read as a
  signed big-endian integer: stable across calls, nodes, releases and Postgres
  versions, and different per tenant schema (a collision only over-serialises two
  tenants). A value inside [-2^31, 2^31), where every other single-bigint advisory key
  of this codebase lies, gets bit 62 flipped, so the key never equals one in use today.
  """
  @spec tenant_admin_lock_key(prefix :: String.t()) :: integer()
  def tenant_admin_lock_key(prefix) when is_binary(prefix) do
    <<key::signed-big-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, @tenant_admin_lock_label <> prefix)

    if key >= @int32_min and key < @int32_limit,
      do: Bitwise.bxor(key, 0x4000_0000_0000_0000),
      else: key
  end

  @doc """
  GH 2547 (design section 6.6): takes the tenant admin lock,
  `pg_advisory_xact_lock(tenant_admin_lock_key(prefix))`, held until the surrounding
  transaction ends. Every path that adds or removes a tenant-wide admin takes it as the
  first locking statement of its transaction. Re-entrant within one transaction. Blocks
  until acquired and honours a caller's `SET LOCAL lock_timeout`.

  Raises `ArgumentError` when called outside a transaction (a session-level wait with no
  release point would be a bug, not a lock).
  """
  @spec lock_tenant_admins!(prefix :: String.t()) :: :ok
  def lock_tenant_admins!(prefix) when is_binary(prefix) do
    if not Repo.in_transaction?() do
      raise ArgumentError, "lock_tenant_admins!/1 must run inside a transaction"
    end

    # Bound parameter, nothing interpolated (INV-7).
    Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [tenant_admin_lock_key(prefix)])

    :ok
  end

  @doc """
  One-time sync of a JWT's claimed role names into `group_members`, closing
  the JIT-provisioning gap `list_effective_role_names/2` alone cannot close
  (REQ-378 §2.2 —
  `lib/letflow/design/req378-oidc-live-revocation-check.md`): nothing else in
  this codebase ever writes a `group_members` row from a token's claimed
  roles, so a user with zero rows there (every OIDC user, before this
  function's call sites started calling it) reads `roles: []` from
  `list_effective_role_names/2` regardless of what their token claims.

  Always returns a `User.t()` — never an error tuple, never raises past a
  genuine connection failure. On any failure inside the transaction, returns
  the original, unmodified `user` (marker still `nil`, `group_members`
  unchanged) — deliberately self-healing, not merely fail-open: because the
  marker stays `nil`, the very next call for this same user retries the sync
  (§2.2.2's own reasoning for why this is safe: a transient DB error only
  costs one request's worth of `roles: []`, the safe direction to fail in).

  **Callers must only call this when `user.role_claims_synced_at` is `nil`**
  (§2.2.3's call-site gate) — this function itself does not re-check the
  marker, so calling it a second time for an already-synced user would
  needlessly re-run the sync (harmless, since step 2 below is idempotent, but
  wasteful and not this function's job to guard against).

  The sync never removes a membership: a claim that disappears from a later token has
  no effect (GH 2547 design section 5, consistent with 0051 M3); revocation is the
  explicit, audited `remove_group_member/3`.

  GH 2547 (design sections 3.6, 6.6): when there is anything to write, the transaction
  first sets `SET LOCAL lock_timeout` (2s, as the pending-admin-grant bind) and takes
  `lock_tenant_admins!/1`. Every membership this call actually inserts writes one
  `group_member.added` audit entry (actor = the user, source `"idp_sync"`, trace from
  `opts[:audit_context]`). Any failure, an audit failure, a lock timeout or a raise
  included, rolls back every membership of this call and leaves the marker `nil`, and
  the original `user` is returned, so the next login retries.

  REQ-519 2e-b: in a tenant whose scope enforcement is `on` a candidate group whose
  membership would make the user tenant-wide for a role it is not tenant-wide for is
  SUPPRESSED (no membership, one `grant.sync_suppressed` or `binding.pending_scope` audit
  entry per user and role, see `Letflow.Identity.SyncScopeGuard`); login still succeeds. This
  function keeps returning the `User.t()` and discards the suppression summary; callers that
  need it use `sync_role_claims_report/3`.
  """
  @spec sync_role_claims_from_token(
          user :: User.t(),
          identity_context :: IdentityContext.t(),
          opts :: opts()
        ) :: User.t()
  def sync_role_claims_from_token(%User{} = user, %IdentityContext{} = identity_context, opts) do
    case sync_role_claims_report(user, identity_context, opts) do
      {:ok, synced_user} -> synced_user
      {:suppressed, synced_user, _summary} -> synced_user
    end
  end

  @typedoc "One (group, role) pair the sync withheld in an `on` tenant: ids and a fixed kind only."
  @type suppressed_item :: %{
          group_id: Ecto.UUID.t(),
          role: String.t(),
          kind: :has_scoped_rows | :no_scoped_rows
        }

  @typedoc "`deduped` counts the pairs whose audit entry already existed."
  @type suppressed_summary :: %{
          suppressed: [suppressed_item(), ...],
          deduped: non_neg_integer()
        }

  @doc """
  The typed form of `sync_role_claims_from_token/3` (REQ-519 AC 2, design 3.9a): the same
  sync, returning `{:ok, user}` when nothing was suppressed (also for the failure fallback
  that returns the original user) and `{:suppressed, user, summary}` when at least one
  (group, role) was suppressed in this call, whether or not other memberships were written
  and whether or not the audit entry was new. The `user` is the one
  `sync_role_claims_from_token/3` returns. The summary holds ids and the fixed kind only.
  """
  @spec sync_role_claims_report(
          user :: User.t(),
          identity_context :: IdentityContext.t(),
          opts :: opts()
        ) :: {:ok, User.t()} | {:suppressed, User.t(), suppressed_summary()}
  def sync_role_claims_report(%User{} = user, %IdentityContext{} = identity_context, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    ctx = %{AuditContext.from_opts(opts) | actor_id: user.id, source: "idp_sync"}
    group_ids = resolve_group_ids_for_role_names(identity_context.roles, opts)

    if identity_context.roles != [] and group_ids == [] do
      Logger.warning(
        "sync_role_claims_from_token/3: zero group_ids resolved for a non-empty claimed-role " <>
          "list -- user will read roles: [] and gain no grants (tenant=#{inspect(prefix)}, " <>
          "user_id=#{user.id}, claimed_roles=#{inspect(identity_context.roles)})"
      )
    end

    # GH 2547 (design section 6.6, SEC-A6): the tenant admin lock is the first locking
    # statement, under a bounded wait so a login never queues indefinitely; nothing is
    # locked when there is nothing to write.
    multi =
      if group_ids != [] do
        Multi.new()
        |> Multi.run(:lock_timeout, fn repo, _changes ->
          # Fixed statement, nothing interpolated at runtime (INV-7).
          case repo.query("SET LOCAL lock_timeout = '#{@sync_lock_timeout}'") do
            {:ok, _result} -> {:ok, :set}
            {:error, _reason} -> {:error, :lock_timeout_setting}
          end
        end)
        |> Multi.run(:tenant_admin_lock, fn _repo, _changes ->
          {:ok, lock_tenant_admins!(prefix)}
        end)
      else
        Multi.new()
      end

    multi =
      Multi.run(multi, :memberships, fn _repo, _changes ->
        # Reuses insert_or_fetch_group_member/3 (backs add_group_member/3)
        # directly at its lean private arity, per §2.2.2 step 2 — not
        # add_group_member/3's own public wrapper, which would add two
        # redundant Repo.get/3 existence checks for a Group/User this
        # function already knows exist (the group id just came from a live
        # tenant_role row, and `user` is the struct this function was
        # called with). Already on_conflict: :nothing / conflict_target:
        # [:group_id, :user_id] — idempotent, safe even if called twice.
        # GH 2547: every result is checked and every inserted row audited; the
        # first failure halts and aborts the whole Multi.
        insert_synced_memberships(group_ids, user.id, prefix, ctx)
      end)

    # ISS-0773: only stamp role_claims_synced_at when >=1 grant was actually
    # written this call. Stamping unconditionally closes off this function's
    # own designed retry-on-nil-marker self-healing (see moduledoc) for a
    # user whose claimed roles resolve to zero group_ids -- permanently
    # locking them out since the marker-gated call sites
    # (upsert_by_external_identity/4, re_select_on_conflict/3) would never
    # call this function again. Leaving the marker nil when group_ids == []
    # means the very next login retries the sync, identical in shape to the
    # existing transaction-failure fallback below. See
    # lib/letflow/design/iss-0773-role-claims-sync-lockout-fix.md §2.2 for
    # the full reasoning, including why this does not reopen REQ-378's
    # revocation-permanence invariant.
    multi =
      if group_ids != [] do
        Multi.update(
          multi,
          :user,
          Ecto.Changeset.change(user, %{role_claims_synced_at: DateTime.utc_now()}),
          prefix: prefix
        )
      else
        multi
      end

    # GH 2547 (design section 3.0): a raise (a DB error inside the audit insert, a lock
    # timeout) is caught after Ecto rolled back; the sync runs outside any transaction,
    # so nothing aborted is hidden. Only the exception module is logged (INV-4/INV-8).
    result =
      try do
        Repo.transaction(multi)
      rescue
        exception -> {:raised, exception.__struct__}
      end

    case result do
      {:ok, %{user: synced_user, memberships: summary}} ->
        sync_result(synced_user, summary)

      {:ok, %{memberships: summary}} ->
        sync_result(user, summary)

      {:error, step, {:audit_failed, _reason}, _changes} ->
        # The reason holds the audit payload; the tag is enough.
        Logger.error(
          "sync_role_claims_from_token/3: failed at step #{inspect(step)} " <>
            "for user_id=#{user.id}: :audit_failed"
        )

        {:ok, user}

      {:error, step, reason, _changes} ->
        Logger.error(
          "sync_role_claims_from_token/3: failed at step #{inspect(step)} " <>
            "for user_id=#{user.id}: #{inspect(reason)}"
        )

        {:ok, user}

      {:raised, exception_module} ->
        Logger.error(
          "sync_role_claims_from_token/3: transaction raised (tenant=#{inspect(prefix)}, " <>
            "user_id=#{user.id}, exception=#{inspect(exception_module)})"
        )

        {:ok, user}
    end
  end

  defp sync_result(user, %{suppressed: []}), do: {:ok, user}

  defp sync_result(user, %{suppressed: suppressed, deduped: deduped}),
    do: {:suppressed, user, %{suppressed: suppressed, deduped: deduped}}

  # GH 2547 (design section 3.6): one group at a time, in resolution order. Only a row
  # this call inserted is audited; the first failure halts with an error tuple, which
  # aborts the Multi and rolls back every earlier membership of this call.
  @spec insert_synced_memberships(
          group_ids :: [Ecto.UUID.t()],
          user_id :: Ecto.UUID.t(),
          prefix :: String.t(),
          ctx :: AuditContext.t()
        ) ::
          {:ok, %{suppressed: [suppressed_item()], deduped: non_neg_integer()}} | {:error, term()}
  defp insert_synced_memberships(group_ids, user_id, prefix, ctx) do
    guard = sync_guard(group_ids, prefix)

    group_ids
    |> Enum.reduce_while({:ok, %{suppressed: [], deduped: 0}}, fn group_id, {:ok, acc} ->
      case sync_one_group(guard, group_id, user_id, prefix, ctx) do
        :ok ->
          {:cont, {:ok, acc}}

        {:ok, items, deduped} ->
          {:cont, {:ok, %{suppressed: acc.suppressed ++ items, deduped: acc.deduped + deduped}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # REQ-519 2e-b (design 3.9 steps 1 and 2): the mode and the roles each candidate group
  # binds are read here, in the :memberships step, AFTER lock A (SEC C-3). `group_ids == []`
  # takes no lock and reads no mode. A mode read that raises propagates and rolls the sync
  # back (the transaction rescue returns the original user, the marker stays nil).
  defp sync_guard([], _prefix), do: :off

  defp sync_guard(group_ids, prefix) do
    case ScopeEnforcement.mode_under_lock!(prefix) do
      :on -> {:on, SyncScopeGuard.bound_platform_roles(group_ids, prefix)}
      _off_or_shadow -> :off
    end
  end

  defp sync_one_group(guard, group_id, user_id, prefix, ctx) do
    decision =
      case guard do
        {:on, roles_by_group} ->
          SyncScopeGuard.evaluate(
            user_id,
            group_id,
            Map.get(roles_by_group, group_id, []),
            prefix
          )

        :off ->
          :allow
      end

    case decision do
      :allow ->
        insert_synced_membership(group_id, user_id, prefix, ctx)

      {:suppress, suppressed} ->
        SyncScopeGuard.record(user_id, group_id, suppressed, prefix, ctx)
    end
  end

  defp insert_synced_membership(group_id, user_id, prefix, ctx) do
    before_roles = sorted_effective_role_names(user_id, prefix)
    before_scope = MembershipScope.snapshot(user_id, prefix)

    case insert_or_fetch_group_member(group_id, user_id, prefix) do
      {:ok, %{inserted: true}} ->
        case insert_membership_audit(
               :added,
               group_id,
               user_id,
               {before_roles, before_scope},
               prefix,
               ctx
             ) do
          {:ok, _entry} -> :ok
          {:error, reason} -> {:error, {:audit_failed, reason}}
        end

      {:ok, %{inserted: false}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── GH 2547: group_member.added / group_member.removed audit payload ─────
  #
  # Design section 3.1 (0051 D8 names). Ids, role names and fixed strings only: no
  # e-mail, username, display name, claim value or token data (INV-4, 0051 N3).
  # `before_roles` is read by the caller just before the write; `group_roles` and the
  # after roles are read here, AFTER the write, under the group lock (CDV-2 / SEC-B1).
  @spec insert_membership_audit(
          event :: :added | :removed,
          group_id :: Ecto.UUID.t(),
          user_id :: Ecto.UUID.t(),
          before :: {before_roles :: [String.t()], before_scope :: MembershipScope.snapshot()},
          prefix :: String.t(),
          ctx :: AuditContext.t()
        ) :: {:ok, Audit.Entry.t()} | {:error, term()}
  defp insert_membership_audit(
         event,
         group_id,
         user_id,
         {before_roles, before_scope},
         prefix,
         ctx
       ) do
    after_roles = sorted_effective_role_names(user_id, prefix)
    scope_delta = MembershipScope.delta(before_scope, MembershipScope.snapshot(user_id, prefix))

    base = %{
      "group_id" => group_id,
      "user_id" => user_id,
      "group_roles" => group_roles(group_id, prefix)
    }

    {action, was_member?, delta} =
      case event do
        :added -> {"group_member.added", false, %{"roles_gained" => after_roles -- before_roles}}
        :removed -> {"group_member.removed", true, %{"roles_lost" => before_roles -- after_roles}}
      end

    attrs = %{
      actor_id: ctx.actor_id,
      action: action,
      resource_type: "group_member",
      resource_id: user_id,
      before_state:
        Map.merge(base, %{"member" => was_member?, "user_platform_roles" => before_roles}),
      after_state:
        base
        |> Map.merge(%{"member" => not was_member?, "user_platform_roles" => after_roles})
        |> Map.merge(delta)
        |> Map.put("scope_delta", scope_delta)
        |> Map.put("source", ctx.source),
      trace_id: ctx.trace_id
    }

    Audit.insert_entry(Repo, attrs, prefix)
  end

  # Every tenant_role row bound to the group (any kind), sorted by name.
  defp group_roles(group_id, prefix) do
    from(t in TenantRole,
      where: t.group_id == ^group_id,
      order_by: [asc: t.name],
      select: %{"name" => t.name, "kind" => t.kind}
    )
    |> Repo.all(prefix: prefix)
    |> Enum.map(fn %{"kind" => kind} = role -> %{role | "kind" => Atom.to_string(kind)} end)
  end

  defp sorted_effective_role_names(user_id, prefix),
    do: user_id |> list_effective_role_names(prefix: prefix) |> Enum.sort()

  # Resolves claimed role names to the group ids that grant them, per §2.2.2
  # step 1. Lives in Letflow.Identity, not RoleRegistry, for the identical
  # reason list_effective_role_names/2 above does — keeps RoleRegistry's
  # documented "no coupling to the OIDC/claim-mapping pipeline" invariant
  # literally true. A claimed role name with no matching tenant_role row
  # resolves to nothing for that name — not an error. Scoped to
  # `kind == :platform_role` (ISS-0775): an OIDC-claimed string must only
  # ever be able to write a group_members row for a platform-role-kind
  # binding, mirroring list_effective_role_names/2's own kind filter above —
  # never a :process_routing_role-kind row, which this write path has no
  # legitimate reason to touch (see
  # lib/letflow/design/iss-0775-oidc-role-sync-kind-scoping.md §1.2). A
  # claimed name matching only a :process_routing_role-kind row resolves to
  # nothing for that name, identical in shape to "no matching row at all".
  @spec resolve_group_ids_for_role_names(role_names :: [String.t()], opts :: opts()) ::
          [Ecto.UUID.t()]
  defp resolve_group_ids_for_role_names(role_names, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    # REQ-447 PR 2 (design section 3.4): a claimed `PLATFORM_ADMIN` confers
    # nothing outside the platform tenant, even if a legacy binding still exists.
    role_names =
      if Letflow.PlatformTenant.platform_prefix?(prefix),
        do: role_names,
        else: Enum.reject(role_names, &(&1 == "PLATFORM_ADMIN"))

    query =
      from(t in TenantRole,
        where: t.name in ^role_names and t.kind == :platform_role,
        select: t.group_id,
        distinct: true
      )

    Repo.all(query, prefix: prefix)
  end

  # ── Tenant administration (REQ-075) ─────────────────────────────────────
  #
  # None of these six functions take an `opts`/`:prefix` parameter — the
  # structural difference from every function above. `tenants` lives in
  # Postgres's default schema, not inside any tenant's own schema, so there
  # is nothing to `:prefix`-scope by. See
  # `lib/letflow/design/req075-tenant-administration-routes.md` §7 for the
  # full design, and that design's own intro / this module's callers
  # (`Letflow.Routers.Tenants`) for why the only protection on these six is
  # a PLATFORM_ADMIN role check, not tenant scoping.

  @typedoc "Params accepted by `list_tenants/1` — see its own @doc."
  @type list_tenants_params :: %{
          search: String.t() | nil,
          cursor: Pagination.Cursor.t() | nil,
          page_size: pos_integer()
        }

  @doc """
  Creates a tenant row via `Tenant.create_changeset/3`, no business logic
  beyond that. `attrs` is a caller-validated map (`Letflow.Api.Validation.validate/2`'s
  output) with keys `"slug"`/`"display_name"`/optionally `"idp_realm_id"`.

  **`oidc_mode` (REQ-075 OQ-4 — a pre-existing REQ-019 §8 OQ-1 gap, not
  resolved here):** no global OIDC-enabled/disabled config key exists yet in
  this codebase. `:disabled` is passed, matching the only existing
  precedent for this exact gap — `Letflow.TenantFixture.provisioned_tenant!/1`'s
  own `opts[:oidc_mode]` default (`test/support/tenant_fixture.ex`). This is
  a reuse of an already-established placeholder, not a new resolution of
  REQ-019's open question.

  Returns `{:error, :duplicate_slug}` on a `slug` unique-constraint
  violation, or `{:error, Ecto.Changeset.t()}` for any other changeset
  failure. Does **not** provision the tenant's Postgres schema or replay its
  migrations — `Letflow.Routers.Tenants`'s `POST /tenants` handler
  orchestrates `Letflow.TenantProvisioning.provision_tenant_schema/1` and
  `Letflow.TenantProvisioning.replay_migrations/2` itself, immediately after
  this function returns `{:ok, tenant}` — matching `TenantProvisioning`'s
  own "two separate, composable primitives, neither calls the other"
  invariant, extended to this third primitive (design §7.1).
  """
  @spec create_tenant(attrs :: map()) ::
          {:ok, Tenant.t()} | {:error, :duplicate_slug} | {:error, Ecto.Changeset.t()}
  def create_tenant(attrs) do
    changeset = Tenant.create_changeset(%Tenant{}, attrs, :disabled)

    case Repo.insert(changeset) do
      {:ok, tenant} ->
        {:ok, tenant}

      {:error, %Ecto.Changeset{} = changeset} ->
        if slug_unique_conflict?(changeset) do
          {:error, :duplicate_slug}
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  Lists tenants, filtered by an optional `search` substring (`ILIKE` across
  `slug`/`display_name`), cursor-paginated via `Letflow.Api.Pagination`.
  Sorted by `inserted_at` ascending, then `id` ascending as a tiebreaker —
  same convention as `list_users/2`.

  An empty or last page is `{:ok, %{tenants: [], next_cursor: nil}}`, never an
  error tuple; the only error is `{:error, :invalid_cursor}` for a cursor whose
  prefix is valid but whose payload is malformed (GH 2747).
  """
  @spec list_tenants(list_tenants_params()) ::
          {:ok, %{tenants: [Tenant.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor}
  def list_tenants(params) do
    page_size = Map.fetch!(params, :page_size)

    with {:ok, cursor_seek} <- decode_tenants_cursor(Map.get(params, :cursor)) do
      query =
        Tenant
        |> filter_tenants_by_search(Map.get(params, :search))
        |> filter_tenants_by_cursor(cursor_seek)
        |> order_by([t], asc: t.inserted_at, asc: t.id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query)
      {page, next_cursor} = split_tenants_page(rows, page_size)

      {:ok, %{tenants: page, next_cursor: next_cursor}}
    end
  end

  @doc "Fetches a single tenant by its (globally unique) `slug`."
  @spec get_tenant_by_slug(slug :: String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant_by_slug(slug) do
    case Repo.get_by(Tenant, slug: slug) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Fetches a single tenant by `id`. Not itself named by REQ-384's design
  (`lib/letflow/design/req384-tenant-switcher-cache-isolation.md` §2.2),
  which specifies resolving the caller's own home-tenant entry but not the
  mechanics of turning `conn.assigns.auth_context.tenant_id` into a
  slug/display_name — added as the minimal, natural extension that step
  needs (mirrors `get_tenant_by_slug/1`'s own shape exactly, keyed on `id`
  instead of `slug`). Used by `Letflow.Routers.Me`'s `GET /me/memberships`
  handler to render the "always includes the caller's own current tenant"
  entry (design §2.2 point 4).

  Also used for the same shape of lookup by `Letflow.Routers.TenantSettings`
  (REQ-382), which only has `conn.assigns.auth_context.tenant_id` (a UUID)
  available and needs the tenant's own `slug` to call
  `update_tenant_settings/2` (that function's own signature is unchanged by
  this requirement).
  """
  @spec get_tenant(id :: Ecto.UUID.t() | String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant(id) do
    case Repo.get(Tenant, id) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Same lookup as `get_tenant_by_slug/1`, but swallows any exception into
  `{:error, :lookup_failed}` instead of letting it propagate. Shared by the two
  unauthenticated tenant-config bootstrap routes
  (`Letflow.Routers.TenantConfig`, REQ-078; `Letflow.Routers.MobileTenantConfig`,
  REQ-124) — both need this exact never-raise wrapper so a DB hiccup falls
  through to their default response instead of a 500 (their own moduledocs'
  "never-error rule"), and until REQ-124's rework both routers duplicated an
  identical private `safe_get_tenant_by_slug/1` to get it (see
  `handoffs/WF02-REQ124-20260822/step-02d-reviewer.json`).

  `context_label` is a short caller-supplied string (e.g. `"tenant-config"`,
  `"mobile-tenant-config"`) folded into the warning log line so the two
  callers stay distinguishable in logs despite sharing this implementation.

  Logs only the caller-supplied `slug` and `context_label` — **never** the
  exception itself (INV-4: it can carry connection strings and query text).
  """
  @spec safe_get_tenant_by_slug(slug :: String.t(), context_label :: String.t()) ::
          {:ok, Tenant.t()} | {:error, :not_found | :lookup_failed}
  def safe_get_tenant_by_slug(slug, context_label) do
    get_tenant_by_slug(slug)
  rescue
    _exception ->
      Logger.warning(
        "#{context_label} slug lookup failed; falling through to the default realm " <>
          "(slug=#{inspect(slug)})"
      )

      {:error, :lookup_failed}
  end

  @type patch_opts :: [
          actor_id: Ecto.UUID.t() | nil,
          platform_prefix: String.t() | nil,
          trace_id: String.t() | nil
        ]

  @doc """
  Partial-update of a tenant's `display_name` and (REQ-442)
  `login_disclosure_mode`, via `Tenant.admin_patch_changeset/2` — see that
  changeset's own @doc for why `:status` is structurally excluded from this path.

  A `display_name`-only patch is a plain `Repo.update/1` (unaudited, as before).
  When `login_disclosure_mode` actually changes, the update and two audit
  entries (value-free payloads, INV-2) are written in a single transaction, so
  all three commit or all three roll back (ISS-1032 / GH 2351): a TARGET-tenant
  chain entry `tenant.platform_setting.updated` with a NIL actor and the constant
  actor class `platform_operator` (tenant administrators read that chain and must
  not learn which operator acted), then a PLATFORM-chain entry
  `platform.tenant_platform_setting.updated` carrying the operator's user id.
  Lock order: tenant row, tenant chain, platform chain (as `bind_tenant_realm/3`).
  `opts[:platform_prefix]` must be verified by the caller. A mode change with no
  binary `actor_id` or `platform_prefix` in `opts`, a tenant with no provisioned
  schema registration, or any audit/transaction failure returns
  `{:error, :audit_failed}` with nothing written.
  """
  @spec patch_tenant(slug :: String.t(), attrs :: map(), patch_opts()) ::
          {:ok, Tenant.t()}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
          | {:error, :audit_failed}
  def patch_tenant(slug, attrs, opts) do
    case Repo.get_by(Tenant, slug: slug) do
      nil ->
        {:error, :not_found}

      %Tenant{} = tenant ->
        changeset = Tenant.admin_patch_changeset(tenant, attrs)

        cond do
          not changeset.valid? ->
            {:error, changeset}

          Map.has_key?(changeset.changes, :login_disclosure_mode) ->
            patch_tenant_with_audit(changeset, tenant, opts)

          true ->
            Repo.update(changeset)
        end
    end
  end

  defp patch_tenant_with_audit(changeset, %Tenant{} = tenant, opts) do
    actor_id = Keyword.get(opts, :actor_id)

    platform_prefix = Keyword.get(opts, :platform_prefix)

    with true <- is_binary(actor_id) and is_binary(platform_prefix),
         %TenantProvisioning.Registration{schema_name: prefix} <-
           Repo.get_by(TenantProvisioning.Registration, tenant_id: tenant.id) do
      # The tenant chain is read by the tenant's own administrators: NIL actor, no
      # operator-chosen trace id, a constant actor class (ISS-1032, as in the realm bind).
      tenant_entry = %{
        actor_id: nil,
        action: "tenant.platform_setting.updated",
        resource_type: "tenant",
        resource_id: tenant.id,
        trace_id: nil,
        before_state: nil,
        after_state: %{"changed" => true, "actor_class" => "platform_operator"}
      }

      platform_entry = %{
        actor_id: actor_id,
        action: "platform.tenant_platform_setting.updated",
        resource_type: "tenant",
        resource_id: tenant.id,
        trace_id: Keyword.get(opts, :trace_id),
        before_state: nil,
        after_state: %{"tenant_id" => tenant.id, "changed" => true}
      }

      Multi.new()
      |> Multi.update(:tenant, changeset)
      |> Audit.append_multi(:audit, tenant_entry, prefix)
      |> Audit.append_multi(:platform_audit, platform_entry, platform_prefix)
      |> Repo.transaction()
      |> case do
        {:ok, %{tenant: updated}} -> {:ok, updated}
        {:error, :tenant, %Ecto.Changeset{} = failed, _changes} -> {:error, failed}
        {:error, _step, _reason, _changes} -> {:error, :audit_failed}
      end
    else
      _no_actor_or_no_registration -> {:error, :audit_failed}
    end
  rescue
    # Fixed message, tenant id only: never the exception (INV-4).
    _exception ->
      Logger.error("tenant platform-setting patch failed (tenant_id=#{tenant.id})")
      {:error, :audit_failed}
  end

  @doc """
  Sets a tenant's `status` to `:inactive`, via `Tenant.status_changeset/2`.
  Idempotent (design §6.5/§9 OQ-2): re-deactivating an already-`:inactive`
  tenant succeeds as a no-op, same final state — there is no
  `:invalid_transition` error variant, matching this codebase's own
  established idempotency precedent for
  `TenantProvisioning.provision_tenant_schema/1`.

  ISS-0993 / INV-10: the configured platform tenant (resolved ROW id equal to
  `Letflow.PlatformTenant.configured_id/0`) can never be deactivated; the call
  returns `{:error, :platform_tenant_protected}` before any write, for every
  caller of this function. With no pin configured nothing is protected.
  """
  @spec deactivate_tenant(slug :: String.t()) ::
          {:ok, Tenant.t()}
          | {:error, :not_found | :platform_tenant_protected | Ecto.Changeset.t()}
  def deactivate_tenant(slug), do: set_tenant_status(slug, :inactive)

  @doc """
  Sets a tenant's `status` to `:active`, via `Tenant.status_changeset/2`.
  Idempotent, same reasoning as `deactivate_tenant/1`.
  """
  @spec reactivate_tenant(slug :: String.t()) ::
          {:ok, Tenant.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def reactivate_tenant(slug), do: set_tenant_status(slug, :active)

  @doc """
  Partial-update of a tenant's `settings` only, via
  `Tenant.settings_changeset/2` (REQ-280,
  `lib/letflow/design/req280-tenant-settings-store.md` §8) — mirrors
  `patch_tenant/2`'s shape exactly. Not itself called from any HTTP route
  yet; wiring a write path to this function is REQ-281/282's scope.
  """
  @spec update_tenant_settings(slug :: String.t(), attrs :: map()) ::
          {:ok, Tenant.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def update_tenant_settings(slug, attrs) do
    case Repo.get_by(Tenant, slug: slug) do
      nil ->
        {:error, :not_found}

      %Tenant{} = tenant ->
        tenant
        |> Tenant.settings_changeset(attrs)
        |> Repo.update()
    end
  end

  defp set_tenant_status(slug, status) do
    case Repo.get_by(Tenant, slug: slug) do
      nil ->
        {:error, :not_found}

      %Tenant{} = tenant ->
        if status == :inactive and Letflow.PlatformTenant.platform_tenant?(tenant.id) do
          {:error, :platform_tenant_protected}
        else
          tenant
          |> Tenant.status_changeset(%{status: status})
          |> Repo.update()
        end
    end
  end

  # ── Tenant administration private helpers ───────────────────────────────

  @spec slug_unique_conflict?(changeset :: Ecto.Changeset.t()) :: boolean()
  defp slug_unique_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:slug, {_message, keyword}} -> Keyword.get(keyword, :constraint) == :unique
      _other -> false
    end)
  end

  @tenants_cursor_prefix "T:"

  defp filter_tenants_by_search(query, nil), do: query
  defp filter_tenants_by_search(query, ""), do: query

  defp filter_tenants_by_search(query, search) do
    like = "%#{search}%"

    from(t in query, where: ilike(t.slug, ^like) or ilike(t.display_name, ^like))
  end

  defp filter_tenants_by_cursor(query, nil), do: query

  defp filter_tenants_by_cursor(query, {ts, id}) do
    from(t in query,
      where: t.inserted_at > ^ts or (t.inserted_at == ^ts and t.id > ^id)
    )
  end

  # Payload shape: "T:<mint_time_us>:<inserted_at_us>:<id>" — same
  # field-slot repurposing as decode_users_cursor/1 above (see that
  # function's comment for the full expiry-vs-sort-key reasoning, which
  # applies identically here).
  defp decode_tenants_cursor(nil), do: {:ok, nil}

  defp decode_tenants_cursor(%Pagination.Cursor{inner: inner}) do
    decode_naive_seek(inner, @tenants_cursor_prefix)
  end

  defp split_tenants_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_tenants_next_cursor(List.last(page))}
  end

  defp split_tenants_page(rows, _page_size), do: {rows, nil}

  defp build_tenants_next_cursor(%Tenant{id: id, inserted_at: inserted_at}) do
    mint_time_us = System.system_time(:microsecond)
    inserted_at_us = us_from_naive_datetime(inserted_at)

    @tenants_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(mint_time_us, inserted_at_us, id)
    |> Pagination.encode_cursor()
  end

  # ── Tenant memberships (REQ-384) ─────────────────────────────────────────
  #
  # Public-schema query, no opts/:prefix -- same tier as list_tenants/1
  # above (tenant_memberships is a public-schema table per design §1.1, not
  # tenant-scoped). See
  # lib/letflow/design/req384-tenant-switcher-cache-isolation.md §2.1.

  @doc """
  Lists every tenant a `subject_key` (normalized email) holds an admin-
  granted membership in, joined against `tenants` for display fields,
  ordered by `Tenant.display_name` ascending (design §2.1).

  `subject_key` is expected to already be normalized by the caller via
  `Letflow.Identity.TenantMembership.normalize_subject_key/1` — this
  function does not itself re-normalize, matching the design's own
  ordering (normalize once, at the caller, then query).

  Always returns `{:ok, list}` — `{:ok, []}` when the subject has no
  memberships beyond their own home tenant, never an error tuple. The
  caller (the `GET /me/memberships` handler) decides whether the home
  tenant is prepended to the response; this function only ever reflects
  `tenant_memberships` rows.
  """
  @spec list_memberships_for_subject(subject_key :: String.t()) ::
          {:ok, [%{tenant: Tenant.t(), display_label: String.t() | nil}]}
  def list_memberships_for_subject(subject_key) when is_binary(subject_key) do
    rows =
      from(tm in TenantMembership,
        join: t in Tenant,
        on: t.id == tm.tenant_id,
        where: tm.subject_key == ^subject_key,
        order_by: [asc: t.display_name],
        select: %{tenant: t, display_label: tm.display_label}
      )
      |> Repo.all()

    {:ok, rows}
  end

  # ── API tokens (REQ-076) ─────────────────────────────────────────────────
  #
  # Same opts :: [prefix: String.t()] convention as every REQ-073/074 function
  # above -- api_tokens is tenant-scoped (design §2). See
  # lib/letflow/design/req076-identity-tokens-roles-onboarding.md §3 for the
  # full design.

  @issuable_token_roles Enum.map(Authorization.roles(), &Atom.to_string/1)

  @typedoc "Attrs accepted by `create_token/3` — see its own @doc."
  @type create_token_attrs :: %{roles: [String.t()], expires_at: DateTime.t() | nil}

  @doc """
  Issues a new API token for `user_id`. Design §3.1 — behavior, in order:

    1. `user_id` must reference an existing user in `opts[:prefix]`'s schema, or
       this returns `{:error, :user_not_found}`.
    2. `attrs.roles` must be non-empty and every entry must be one of the literal role-name strings `Letflow.Api.Authorization.roles/0` returns as
       strings — exact match, case-sensitive. **This function does NOT call
       `Authorization.roles_from_strings/1`** (that function's contract is
       "silently drop an unrecognized string," correct for untrusted bearer-token
       claims, wrong here — an explicit request for an unrecognized role must be
       rejected loudly, not silently narrowed). Any entry outside that set
       (including an empty/missing list) → `{:error, :invalid_role_set}`.
       REQ-447 PR 2: `"PLATFORM_ADMIN"` is also `{:error, :invalid_role_set}`
       unless `opts[:prefix]` is the platform tenant's schema
       (`Letflow.PlatformTenant.platform_prefix?/1`).
    3. `attrs.expires_at`, if given, must be strictly after `DateTime.utc_now/0`
       at the moment of the check, or this returns `{:error, :expires_at_in_past}`.
    4. The plaintext token value is generated:
       `"lf_tok_" <> (32 random bytes, lowercase hex)` — a deliberate,
       cosmetic-only prefix divergence from R-Co's `"bpm_tok_"`.
    5. `token_hash` is the SHA-256 hex digest of the plaintext — a one-way
       hash, so the plaintext is never recoverable from the stored row.
    6. `name` is `"token-" <> String.slice(token_hash, 0, 8)` — a name
       derived deterministically from the token's own hash needs no
       separate collision check, and exposes none of the plaintext's
       unhashed bytes.
    7. The row is inserted via `Repo.insert/2`, `prefix: opts[:prefix]`.

  **Roles are snapshotted, not live-referenced**: a later role-registry
  change does not affect an already-issued token's effective roles.

  Returns `{:ok, %{token: token, plaintext: plaintext}}` on success —
  `plaintext` is a bare local value that exists only in this return tuple,
  never assigned to any struct field, never persisted, never logged (INV-4).
  The shared `insert_token/5` is the only place that generates the plaintext;
  it is returned through this function and `mint_token/4` (GH 2552) only.

  GH 2547 (design `gh2547-tenant-admin-audit-and-count.md` sections 3.9, 6.6): the
  transaction first takes `lock_tenant_admins!/1` (always, whatever the roles), and the
  `token.create` audit entry carries the actor and trace id from `opts[:audit_context]`
  (actor `nil` when none is passed).

  GH 2552 (design `gh2552-api-token-issuer-and-roles.md` section 3): this is the
  TRUSTED, non-HTTP path (seeds, fixtures). It records no issuer (`issuer_user_id` NULL)
  and applies none of the 0051 M2 minting rules. The HTTP mint path is `mint_token/4`.
  """
  @spec create_token(user_id :: Ecto.UUID.t(), attrs :: create_token_attrs(), opts :: opts()) ::
          {:ok, %{token: ApiToken.t(), plaintext: String.t()}}
          | {:error, :user_not_found}
          | {:error, :invalid_role_set}
          | {:error, :expires_at_in_past}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:transaction_failed, Exception.t()}}
  def create_token(user_id, attrs, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get(User, user_id, prefix: prefix) do
      nil ->
        {:error, :user_not_found}

      %User{} ->
        with :ok <- validate_issuable_roles(Map.get(attrs, :roles)),
             :ok <- reject_platform_admin_outside_platform_tenant(Map.get(attrs, :roles), prefix),
             :ok <- validate_expires_at(Map.get(attrs, :expires_at)) do
          insert_token(user_id, attrs, prefix, AuditContext.from_opts(opts), nil)
        end
    end
  end

  @typedoc "Every error `mint_token/4` returns."
  @type mint_error ::
          :issuer_not_authorized
          | :user_not_found
          | :user_inactive
          | :invalid_role_set
          | :expires_at_in_past
          | :platform_admin_token_not_self
          | :platform_admin_token_expiry
          | :roles_not_held
          | Ecto.Changeset.t()
          | {:transaction_failed, Exception.t()}

  @doc """
  GH 2552 (decision 0051 M2; design `gh2552-api-token-issuer-and-roles.md` section 3):
  the HTTP mint path. Issues a token for `user_id` on behalf of `issuer_user_id`, the
  authenticated caller (never a request value), and records the issuer in
  `api_tokens.issuer_user_id` and in the `token.create` audit entry.

  One transaction. Every check runs AFTER `lock_tenant_admins!/1` (the first locking
  step), in this order, so a caller without mint authority always gets
  `:issuer_not_authorized` and learns nothing about the input or the target:

    1. `lock_tenant_admins!/1`.
    2. The issuer and target `users` rows, `ORDER BY id FOR SHARE` (the only row locks;
       the role reads below are plain reads, kept stable by the advisory lock, which every
       membership/binding writer takes).
    3. Issuer missing, not active, or without mint authority -> `:issuer_not_authorized`.
    4. Input: roles as in `create_token/3` (`:invalid_role_set`, `[]` included),
       `PLATFORM_ADMIN` only in the platform tenant, `expires_at` in the future
       (`:expires_at_in_past`).
    5. Target missing -> `:user_not_found`; not active -> `:user_inactive`.
    6. A token carrying `PLATFORM_ADMIN`: target must be the issuer
       (`:platform_admin_token_not_self`) and must expire within
       `:platform_admin_token_max_ttl_days` (`validate_platform_admin_expiry/4`).
    7. Roles must be a subset of BOTH the issuer's and the target's
       `tenant_wide_role_names/2` -> otherwise `:roles_not_held`.

  Token roles never count as held: a token cannot justify the next token.

  **Owner identity (advisor condition 3).** The token acts as its OWNER, `user_id`
  (`verify_api_token/2`). Separation-of-duties checks (0053 D6) compare owners, never
  `issuer_user_id`; the issuer is recorded for attribution only.
  """
  @spec mint_token(
          issuer_user_id :: Ecto.UUID.t(),
          user_id :: Ecto.UUID.t(),
          attrs :: create_token_attrs(),
          opts :: opts()
        ) :: {:ok, %{token: ApiToken.t(), plaintext: String.t()}} | {:error, mint_error()}
  def mint_token(issuer_user_id, user_id, attrs, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    ctx = AuditContext.from_opts(opts)

    case Ecto.UUID.cast(issuer_user_id) do
      {:ok, issuer_id} -> insert_token(user_id, attrs, prefix, ctx, issuer_id)
      :error -> {:error, :issuer_not_authorized}
    end
  end

  # GH 2552 design section 3, steps 2-7. Runs inside the mint transaction, after
  # lock_tenant_admins!/1. The order is load-bearing: authorization (step 3) first.
  defp run_mint_checks(issuer_id, user_id, attrs, prefix) do
    target_id =
      case Ecto.UUID.cast(user_id) do
        {:ok, id} -> id
        :error -> nil
      end

    users = lock_mint_users([issuer_id, target_id], prefix)
    roles = Map.get(attrs, :roles)
    expires_at = Map.get(attrs, :expires_at)
    target_user = target_id && Map.get(users, target_id)

    with {:ok, issuer_held} <- authorize_minter(Map.get(users, issuer_id), prefix),
         :ok <- validate_issuable_roles(roles),
         :ok <- reject_platform_admin_outside_platform_tenant(roles, prefix),
         :ok <- validate_expires_at(expires_at),
         :ok <- check_mint_target(target_user),
         :ok <- check_platform_admin_token(roles, issuer_id, target_id, expires_at),
         :ok <- check_roles_held(roles, issuer_held, target_id, target_user, prefix) do
      {:ok, :passed}
    end
  end

  # Step 2: the only row locks of the mint, users by id ascending.
  defp lock_mint_users(ids, prefix) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(u in User, where: u.id in ^ids, order_by: [asc: u.id], lock: "FOR SHARE")
    |> Repo.all(prefix: prefix)
    |> Map.new(&{&1.id, &1})
  end

  defp authorize_minter(%User{} = issuer, prefix) do
    held = tenant_wide_role_names(issuer.id, prefix: prefix)

    if active_user?(issuer) and mint_authority?(held, prefix),
      do: {:ok, held},
      else: {:error, :issuer_not_authorized}
  end

  defp authorize_minter(nil, _prefix), do: {:error, :issuer_not_authorized}

  defp check_mint_target(nil), do: {:error, :user_not_found}

  defp check_mint_target(%User{} = target),
    do: if(active_user?(target), do: :ok, else: {:error, :user_inactive})

  # Step 6, advisor conditions (1) and (2).
  defp check_platform_admin_token(roles, issuer_id, target_id, expires_at) do
    cond do
      "PLATFORM_ADMIN" not in roles ->
        :ok

      target_id != issuer_id ->
        {:error, :platform_admin_token_not_self}

      true ->
        validate_platform_admin_expiry(
          roles,
          expires_at,
          DateTime.utc_now(),
          platform_admin_token_max_ttl_days()
        )
    end
  end

  # The PLATFORM_ADMIN token cap (advisor condition 2). A misconfigured value (not a
  # positive integer) fails closed by raising, never silently widening the cap.
  defp platform_admin_token_max_ttl_days do
    case Application.get_env(:letflow, :platform_admin_token_max_ttl_days, 90) do
      days when is_integer(days) and days > 0 and days <= 366 ->
        days

      other ->
        raise ArgumentError,
              ":platform_admin_token_max_ttl_days must be an integer in 1..366, got: " <>
                inspect(other)
    end
  end

  # Step 7: roles must be held by BOTH the minter and the target. REQ-517 AC 13: when the
  # (locked) target carries the admin-set service-principal flag, the target side is
  # relaxed: the roles need only be a subset of the ISSUER's tenant-wide roles. The flag
  # relaxes nothing else (the issuer was authorized at step 3).
  defp check_roles_held(roles, issuer_held, target_id, target_user, prefix) do
    allowed =
      if ServicePrincipal.flagged?(target_user) do
        issuer_held
      else
        MapSet.intersection(issuer_held, tenant_wide_role_names(target_id, prefix: prefix))
      end

    if MapSet.subset?(MapSet.new(roles), allowed),
      do: :ok,
      else: {:error, :roles_not_held}
  end

  # GH 2552 design section 3: who may mint.
  defp mint_authority?(held, prefix) do
    tenant_admin_mint_authority?(held) or platform_admin_mint_exception?(held, prefix)
  end

  # The 0051 M2 / D1(a) rule: a tenant-wide TENANT_ADMIN, held by group membership.
  defp tenant_admin_mint_authority?(held), do: MapSet.member?(held, @tenant_admin_role)

  # DEVIATION from 0051 M2/D1(a), confirmed by advisor 2026-10-15 with conditions
  # (1)-(3) (design section 3). PLATFORM_ADMIN may mint, in the platform tenant only.
  # Bounded by the subset rule, the PA-token self/expiry rules (step 6) and the same
  # issuer/audit recording as every mint. Removing this function and its `or` term in
  # mint_authority?/2 removes the exception; mint_authority?/2's `prefix` argument then
  # becomes unused and must be renamed `_prefix` (compile runs with warnings as errors).
  defp platform_admin_mint_exception?(held, prefix) do
    Letflow.PlatformTenant.platform_prefix?(prefix) and MapSet.member?(held, "PLATFORM_ADMIN")
  end

  @doc """
  GH 2552 (design section 3): the user's tenant-wide platform-role names, as a `MapSet`.
  Group-held roles only (`list_effective_role_names/2`), resolved by the one shared
  `Letflow.Api.Authorization.effective_roles/2` rule, so `PLATFORM_ADMIN` is dropped
  outside the platform tenant. Token roles never count. A role the user holds only through
  scoped rows is removed by the private `exclude_scoped_role_names/3` step (REQ-497 PR 1b);
  in stage 1, where every row is tenant-wide, it removes nothing.
  """
  @spec tenant_wide_role_names(user_id :: Ecto.UUID.t(), opts :: opts()) :: MapSet.t(String.t())
  def tenant_wide_role_names(user_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    user_id
    |> list_effective_role_names(opts)
    |> Authorization.effective_roles(Letflow.PlatformTenant.platform_prefix?(prefix))
    |> MapSet.new(&Atom.to_string/1)
    |> exclude_scoped_role_names(user_id, prefix)
  end

  # REQ-497 PR 1b (design 5.2): the role-name twin of `exclude_scoped_holders/2`, same rule
  # per role. From `names`, drop a role R when (user, U, R) or (group, the group bound to R
  # as a `:platform_role`, R) has at least one scoped row and neither has a tenant-wide row.
  # One query for the whole set (none for an empty set); identity in stage 1.
  @spec exclude_scoped_role_names(
          names :: MapSet.t(String.t()),
          user_id :: Ecto.UUID.t(),
          prefix :: String.t()
        ) :: MapSet.t(String.t())
  defp exclude_scoped_role_names(names, user_id, prefix) do
    if MapSet.size(names) == 0 do
      names
    else
      role_names = MapSet.to_list(names)

      bound_group_row =
        from(t in TenantRole,
          where:
            t.kind == ^:platform_role and t.name == parent_as(:grant).role and
              t.group_id == parent_as(:grant).principal_id
        )

      rows =
        from(g in RoleScopeGrant,
          as: :grant,
          where: g.role in ^role_names,
          where:
            (g.principal_type == ^:user and g.principal_id == ^user_id) or
              (g.principal_type == ^:group and exists(bound_group_row)),
          distinct: true,
          select: {g.role, g.tenant_wide}
        )
        |> Repo.all(prefix: prefix)

      scoped_only =
        rows
        |> Enum.group_by(fn {role, _wide} -> role end, fn {_role, wide} -> wide end)
        |> Enum.filter(fn {_role, wides} -> false in wides and true not in wides end)
        |> Enum.map(fn {role, _wides} -> role end)

      MapSet.difference(names, MapSet.new(scoped_only))
    end
  end

  @doc """
  GH 2552 (design section 3, advisor condition 2): a token whose `roles` contain
  `"PLATFORM_ADMIN"` must expire, and no later than `now + max_ttl_days` days.
  `expires_at` is truncated to whole seconds before the comparison; equal to the cap is
  allowed. Any other role set is `:ok`. Pure.
  """
  @spec validate_platform_admin_expiry(
          roles :: [String.t()],
          expires_at :: DateTime.t() | nil,
          now :: DateTime.t(),
          max_ttl_days :: pos_integer()
        ) :: :ok | {:error, :platform_admin_token_expiry}
  def validate_platform_admin_expiry(roles, expires_at, now, max_ttl_days) do
    cond do
      "PLATFORM_ADMIN" not in roles ->
        :ok

      is_nil(expires_at) ->
        {:error, :platform_admin_token_expiry}

      DateTime.compare(
        DateTime.truncate(expires_at, :second),
        DateTime.add(now, max_ttl_days * 86_400, :second)
      ) == :gt ->
        {:error, :platform_admin_token_expiry}

      true ->
        :ok
    end
  end

  @doc """
  GH 2552 (design section 3): the effective status of a token, for the token list.
  Precedence `:revoked` > `:expired` (`expires_at` not after `now`) > `:owner_inactive`
  > `:active`. The permanent states win; `:owner_inactive` (the only reversible state)
  shows only when the token would otherwise work. Since GH 2564 a deactivation through
  `Identity` revokes the tokens, so `:owner_inactive` arises only for rows changed by
  other means (legacy rows, direct database edits). Pure.
  """
  @spec token_effective_status(
          token :: ApiToken.t(),
          owner_active :: boolean(),
          now :: DateTime.t()
        ) :: :revoked | :expired | :owner_inactive | :active
  def token_effective_status(%ApiToken{} = token, owner_active, now) do
    cond do
      not is_nil(token.revoked_at) -> :revoked
      not is_nil(token.expires_at) and DateTime.compare(token.expires_at, now) != :gt -> :expired
      owner_active != true -> :owner_inactive
      true -> :active
    end
  end

  defp validate_issuable_roles(roles) when is_list(roles) and roles != [] do
    if Enum.all?(roles, &(&1 in @issuable_token_roles)) do
      :ok
    else
      {:error, :invalid_role_set}
    end
  end

  defp validate_issuable_roles(_roles), do: {:error, :invalid_role_set}

  # REQ-447 PR 2 (design section 3.4): `PLATFORM_ADMIN` is issuable only from the
  # platform tenant's schema. The router's platform-scope 403 (PR 1) runs first.
  defp reject_platform_admin_outside_platform_tenant(roles, prefix) do
    if "PLATFORM_ADMIN" in roles and not Letflow.PlatformTenant.platform_prefix?(prefix),
      do: {:error, :invalid_role_set},
      else: :ok
  end

  defp validate_expires_at(nil), do: :ok

  defp validate_expires_at(%DateTime{} = expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, :expires_at_in_past}
    end
  end

  # GH 2552: `issuer_user_id` nil is the trusted create_token/3 path (NULL issuer, no
  # mint checks); non-nil is mint_token/4, whose :mint_checks run between the lock and
  # the insert.
  defp insert_token(user_id, attrs, prefix, ctx, issuer_user_id) do
    try do
      plaintext = generate_token_plaintext()
      token_hash = hash_token_value(plaintext)
      name = "token-" <> String.slice(token_hash, 0, 8)

      changeset =
        ApiToken.insert_changeset(%ApiToken{}, %{
          user_id: user_id,
          name: name,
          token_hash: token_hash,
          roles: Map.get(attrs, :roles),
          expires_at: Map.get(attrs, :expires_at),
          issuer_user_id: issuer_user_id
        })

      # Wrapped in Ecto.Multi for the same-transaction guarantee (AC3).
      # GH 2547: actor and trace come from opts[:audit_context] (REQ-195's
      # actor_id: nil remains the fallback for a caller that passes none), and
      # the tenant admin lock is the first step, for any roles (design 6.6).
      # after_state excludes token_hash (INV-4 -- a hash is
      # still a credential-adjacent secret with no audit value) and, GH 2552, name
      # (a hash prefix); the plaintext itself is never captured anywhere, per
      # ApiToken's own moduledoc.
      Multi.new()
      |> Multi.run(:tenant_admin_lock, fn _repo, _changes ->
        {:ok, lock_tenant_admins!(prefix)}
      end)
      |> maybe_mint_checks(issuer_user_id, user_id, attrs, prefix)
      |> Multi.insert(:token, changeset, prefix: prefix)
      |> Multi.merge(fn %{token: token} ->
        Audit.append_multi(
          Multi.new(),
          :audit,
          %{
            actor_id: ctx.actor_id,
            action: "token.create",
            resource_type: "api_token",
            resource_id: token.id,
            before_state: nil,
            after_state: token_audit_state(token),
            trace_id: ctx.trace_id
          },
          prefix
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{token: token}} -> {:ok, %{token: token, plaintext: plaintext}}
        {:error, :mint_checks, reason, _changes} -> {:error, reason}
        {:error, :token, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
        {:error, :audit, reason, _changes} -> {:error, reason}
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  defp maybe_mint_checks(multi, nil, _user_id, _attrs, _prefix), do: multi

  defp maybe_mint_checks(multi, issuer_id, user_id, attrs, prefix) do
    Multi.run(multi, :mint_checks, fn _repo, _changes ->
      run_mint_checks(issuer_id, user_id, attrs, prefix)
    end)
  end

  # GH 2552 design section 5: the audit state of a token row for `token.create` and
  # `token.revoke`. Excludes token_hash and name (a hash prefix) -- the token value,
  # hash and prefix never reach the audit log (INV-4). Adds the 0051 D1(c) scope.
  defp token_audit_state(%ApiToken{} = token) do
    token
    |> Audit.struct_state([:token_hash, :name])
    |> Map.put(:scope, "tenant_wide")
  end

  defp generate_token_plaintext do
    "lf_tok_" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end

  defp hash_token_value(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end

  @doc """
  Lists every API token in `opts[:prefix]`'s schema, ordered by `inserted_at`
  descending, so the most recently issued token is first — the natural
  default for an admin scanning issued tokens. Unpaginated (design §3.2 —
  no acceptance criterion here calls for cursor pagination on this
  endpoint). Always `{:ok, _}` — an empty result is `{:ok, []}`.

  GH 2552 (design section 3): each item is `%{token: token, owner_active: boolean}`,
  the token joined to its owning user (inner join on the NOT NULL `user_id` FK, so no
  row is lost) with the owner's activity read through `active_user_condition/1`, as in
  `verify_api_token/2`. Feed it to `token_effective_status/3`.
  """
  @spec list_tokens(opts :: opts()) ::
          {:ok, [%{token: ApiToken.t(), owner_active: boolean(), owner_flagged: boolean()}]}
  def list_tokens(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    base =
      from(t in ApiToken,
        as: :token,
        join: u in User,
        as: :owner,
        on: u.id == t.user_id,
        order_by: [desc: t.inserted_at]
      )

    query =
      select(
        base,
        [token: t],
        ^%{
          token: dynamic([token: t], t),
          owner_active: active_user_condition(:owner),
          owner_flagged: dynamic([owner: u], u.admin_flagged_service_principal)
        }
      )

    {:ok, Repo.all(query, prefix: prefix)}
  end

  @doc """
  REQ-447 (design section 3.6b): true iff the user belongs to the group the
  `PLATFORM_ADMIN` binding (`kind == :platform_role`) points to in
  `opts[:prefix]`'s schema. `false` when there is no binding or `user_id` is not
  a UUID.
  """
  @spec platform_admin_member?(user_id :: Ecto.UUID.t() | String.t(), opts :: opts()) ::
          boolean()
  def platform_admin_member?(user_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} ->
        from(m in GroupMember,
          join: t in TenantRole,
          on: t.group_id == m.group_id,
          where: m.user_id == ^uuid and t.name == "PLATFORM_ADMIN" and t.kind == :platform_role
        )
        |> Repo.exists?(prefix: prefix)

      :error ->
        false
    end
  end

  @doc """
  REQ-447 (design section 3.6b, M1): true iff the stored roles of the token
  `token_id` contain `PLATFORM_ADMIN` (by `Authorization.platform_admin_name?/1`).
  `false` for an unknown or non-UUID id (the revoke path then answers as before).
  """
  @spec token_carries_platform_admin?(token_id :: Ecto.UUID.t() | String.t(), opts :: opts()) ::
          boolean()
  def token_carries_platform_admin?(token_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, uuid} <- Ecto.UUID.cast(token_id),
         %ApiToken{roles: roles} when is_list(roles) <- Repo.get(ApiToken, uuid, prefix: prefix) do
      Enum.any?(roles, &Authorization.platform_admin_name?/1)
    else
      _other -> false
    end
  end

  @doc """
  Revokes a token by id, idempotently — re-revoking an already-revoked token
  returns `{:ok, token}` unchanged rather than overwriting `revoked_at` with a
  later timestamp: the first revocation timestamp is the historically
  accurate one, and a second call must not erase it. Returns
  `{:error, :not_found}` if no token with that id exists in
  `opts[:prefix]`'s schema.

  GH 2547 (design `gh2547-tenant-admin-audit-and-count.md` sections 3.9, 6.6, SEC-A5):
  the transaction first takes `lock_tenant_admins!/1` (always, whatever the roles), then
  re-reads the token row `FOR UPDATE` and builds `before_state` from that locked row; a
  token revoked concurrently in between is returned unchanged. The `token.revoke` audit
  entry carries the actor and trace id from `opts[:audit_context]` (actor `nil` when none
  is passed).

  REQ-497 PR 1b (design `req497-1b-allowed-flag-shadow-n1.md` 6.2 (f), Option A): the
  `TENANT_ADMIN` binding row is locked right after the tenant admin lock, whatever the
  token. When the locked token was COUNTED as a tenant-wide admin source (not revoked, not
  expired, owner active, roles contain `TENANT_ADMIN`), the revoke must leave a tenant-wide
  admin; otherwise it rolls back and `{:error, :last_tenant_wide_admin}` is returned after
  one `tenant_admin.guard_refused` entry (action `revoke_token`) is written in its own
  transaction. An uncounted token revokes without a count.
  """
  @spec revoke_token(token_id :: Ecto.UUID.t() | String.t(), opts :: opts()) ::
          {:ok, ApiToken.t()}
          | {:error, :not_found}
          | {:error, :last_tenant_wide_admin}
          | {:error, {:transaction_failed, Exception.t()}}
  def revoke_token(token_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get(ApiToken, token_id, prefix: prefix) do
      nil ->
        {:error, :not_found}

      %ApiToken{revoked_at: revoked_at} = token when not is_nil(revoked_at) ->
        {:ok, token}

      %ApiToken{id: id} ->
        ctx = AuditContext.from_opts(opts)

        try do
          Repo.transaction(fn -> revoke_locked_token(id, prefix, ctx) end, prefix: prefix)
          |> case do
            {:error, {:tenant_admin_guard, refusal}} ->
              TenantAdminGuard.refuse(prefix, refusal, ctx)

            other ->
              other
          end
        rescue
          exception -> {:error, {:transaction_failed, exception}}
        end
    end
  end

  # GH 2547 (design 3.9, 6.6, SEC-A5): the tenant admin lock first (always, whatever
  # the roles), then the token row re-read FOR UPDATE, so before_state is the row as it
  # is under the lock, not the unlocked read above. A token revoked concurrently in
  # between is returned unchanged, as the idempotent path does. Same error shapes as
  # before: a changeset or audit failure comes back as a bare {:error, reason} (FU-2).
  # REQ-195's actor_id: nil remains the fallback when no audit context is passed.
  # before_state/after_state come from token_audit_state/1: no token_hash and no name
  # (INV-4), plus issuer_user_id and scope (GH 2552).
  defp revoke_locked_token(token_id, prefix, ctx) do
    lock_tenant_admins!(prefix)
    # REQ-497 PR 1b (design 6.2 (f), CDV B3/SEC A3): rank R unconditionally, A -> R -> B.
    _binding = TenantAdminGuard.lock_admin_binding!(prefix)

    case Repo.one(from(t in ApiToken, where: t.id == ^token_id, lock: "FOR UPDATE"),
           prefix: prefix
         ) do
      nil ->
        Repo.rollback(:not_found)

      %ApiToken{revoked_at: revoked_at} = token when not is_nil(revoked_at) ->
        token

      %ApiToken{} = token ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        counted? = counted_admin_token?(token, now, prefix)

        case revoke_token_row(token, prefix, ctx, nil, now) do
          {:ok, updated} ->
            # N1 (Option A, REQ-497 PR 1b): only a token counted at lock time is guarded.
            if counted?,
              do: :ok = TenantAdminGuard.ensure_admins_remain!(prefix, :revoke_token, token.id)

            updated

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  # REQ-497 PR 1b (design 6.2 (f), CDV B2): whether the token row read FOR UPDATE is a
  # source `count_tenant_wide_admins/1` counts: not revoked, `expires_at` nil or after the
  # second-truncated `now`, a TENANT_ADMIN role, and an active owner (read in the same
  # transaction, only when the other three hold).
  defp counted_admin_token?(%ApiToken{} = token, now, prefix) do
    is_nil(token.revoked_at) and
      (is_nil(token.expires_at) or DateTime.compare(token.expires_at, now) == :gt) and
      @tenant_admin_role in (token.roles || []) and
      owner_active?(token.user_id, prefix)
  end

  defp owner_active?(user_id, prefix) do
    case Repo.get(User, user_id, prefix: prefix) do
      %User{} = user -> active_user?(user)
      nil -> false
    end
  end

  # GH 2564 (design §2): one live token row revoked at `now` (per-row changeset, never
  # `update_all`) plus its `token.revoke` entry, built from `token_audit_state/1` (no
  # token_hash, no name: INV-4). `cause` nil keeps DELETE /tokens/:id's entry exactly as
  # before; a non-nil cause is added to `after_state`. Must run inside the caller's
  # transaction; returns the error instead of rolling back, so each caller decides.
  @spec revoke_token_row(
          ApiToken.t(),
          prefix :: String.t(),
          ctx :: AuditContext.t(),
          cause :: String.t() | nil,
          now :: DateTime.t()
        ) :: {:ok, ApiToken.t()} | {:error, Ecto.Changeset.t() | term()}
  defp revoke_token_row(%ApiToken{} = token, prefix, ctx, cause, now) do
    with {:ok, updated} <-
           Repo.update(ApiToken.revoke_changeset(token, %{revoked_at: now}), prefix: prefix),
         after_state = token_audit_state(updated),
         after_state = if(cause, do: Map.put(after_state, :cause, cause), else: after_state),
         attrs = %{
           actor_id: ctx.actor_id,
           action: "token.revoke",
           resource_type: "api_token",
           resource_id: updated.id,
           before_state: token_audit_state(token),
           after_state: after_state,
           trace_id: ctx.trace_id
         },
         {:ok, _entry} <- Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, updated}
    end
  end

  @doc """
  Verifies a bearer-token plaintext against `opts[:prefix]`'s schema — the
  propagation-guarantee mechanism behind AC4 (design §3.4). This is a **live,
  uncached, per-call database read**, every single invocation: there is no ETS
  table, no process-dictionary cache, no periodic-refresh worker anywhere in
  this call path — exactly one `Repo` round trip per call, always against
  current data. This is what makes revocation take effect on the very next
  call: nothing between the revoking `UPDATE` and the next `verify_api_token/2`
  call's token lookup can observe a pre-revocation value, because there is
  no cache layer between them to be stale.

  The lookup is one query that joins the token row to its owning `User` in the
  same tenant schema and reads the owner's activity through
  `active_user_condition/1` (GH-2557). A token whose owner is not active
  (`active_user?/1` false) returns `{:error, :revoked}` — the exact term a
  revoked token returns, so the caller renders a byte-identical 401 — and does
  **not** write `last_used_at`. The owner check runs after the revoked check
  and before the expiry check. A deactivation through `update_user_status/3`
  or `update_user_profile/3` revokes all the owner's tokens and reactivation
  restores none (GH 2564); this owner check covers rows left live by other
  means (legacy rows, direct database edits).

  On a successful verification, best-effort updates `last_used_at` — a failure
  on that one non-essential write does not fail the verification itself (logged
  and swallowed).

  Returns `{:ok, %{user_id: user_id, roles: roles}}`, or `{:error, :invalid}`
  (no matching row), `{:error, :revoked}` (revoked, or owner inactive), or
  `{:error, :expired}`.
  """
  @spec verify_api_token(plaintext :: String.t(), opts :: opts()) ::
          {:ok, %{user_id: Ecto.UUID.t(), roles: [String.t()]}}
          | {:error, :invalid}
          | {:error, :revoked}
          | {:error, :expired}
  def verify_api_token(plaintext, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    token_hash = hash_token_value(plaintext)

    base =
      from(t in ApiToken,
        as: :token,
        join: u in User,
        as: :owner,
        on: u.id == t.user_id,
        where: t.token_hash == ^token_hash
      )

    query =
      select(
        base,
        [token: t],
        ^%{
          token: dynamic([token: t], t),
          owner_active: active_user_condition(:owner),
          owner_flagged: dynamic([owner: u], u.admin_flagged_service_principal)
        }
      )

    case Repo.one(query, prefix: prefix) do
      nil ->
        {:error, :invalid}

      %{token: %ApiToken{revoked_at: revoked_at}} when not is_nil(revoked_at) ->
        {:error, :revoked}

      %{owner_active: false} ->
        {:error, :revoked}

      %{token: %ApiToken{expires_at: expires_at} = token, owner_active: true}
      when not is_nil(expires_at) ->
        if DateTime.compare(expires_at, DateTime.utc_now()) != :gt do
          {:error, :expired}
        else
          touch_last_used_and_verify(token, prefix)
        end

      %{token: %ApiToken{} = token, owner_active: true} ->
        touch_last_used_and_verify(token, prefix)
    end
  end

  @doc """
  Returns `true` if and only if `user` is active — `user.status == :active`
  (GH-2557). This is the single in-memory definition of "active user"; the
  OIDC path (`AuthPipeline.verify_local_account_state/2`) calls it, and
  `active_user_condition/1` is its query-side twin (`users.status`, per tenant schema). Pure:
  no I/O. Any other status, including `:inactive`, returns `false`.
  """
  @spec active_user?(User.t()) :: boolean()
  def active_user?(%User{status: status}), do: status == :active

  @doc """
  Returns an `Ecto.Query.dynamic` expression that is true if and only if the
  `Letflow.Identity.User` row bound by the **named binding** `binding` is
  active (`status == :active`) — the query-side twin of `active_user?/1` and
  the single definition `verify_api_token/2` and any tenant-wide admin count
  (#2547) build on (GH-2557).

  The caller must bind `User` with `as: binding` in the query that receives the
  expression; Ecto raises at query build otherwise. No prefix is set or read
  here — the caller's `Repo` call passes `prefix:`, as every tenant query does.
  Parameterised Ecto only, no `fragment`, no I/O.

  The binding must be a `User`: any other schema with a `status` field would
  give a silently wrong predicate. Under a `left_join` with no matching user
  the expression is SQL NULL, which fails closed in a `where` but is `nil` in a
  `select`, so a caller selecting it must handle `nil`.
  """
  @spec active_user_condition(binding :: atom()) :: Ecto.Query.dynamic_expr()
  def active_user_condition(binding) when is_atom(binding) do
    dynamic([{^binding, u}], u.status == :active)
  end

  defp touch_last_used_and_verify(%ApiToken{} = token, prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case token
         |> ApiToken.touch_last_used_changeset(%{last_used_at: now})
         |> Repo.update(prefix: prefix) do
      {:ok, _updated} ->
        :ok

      {:error, _changeset} ->
        Logger.warning(
          "verify_api_token/2: best-effort last_used_at update failed (token_id=#{token.id})"
        )
    end

    {:ok, %{user_id: token.user_id, roles: token.roles}}
  end

  # ── Onboarding (REQ-076) ──────────────────────────────────────────────────
  #
  # No opts/:prefix parameter on any of these three -- onboarding_registry is
  # structurally global, like tenants/tenant_schemas (design §8.1). The
  # tenant-creation orchestration itself (Identity.create_tenant/1 ->
  # TenantProvisioning.provision_tenant_schema/1 ->
  # TenantProvisioning.replay_migrations/2 -> create_onboarding/1) lives in
  # Letflow.Routers.Onboarding's own handler, not in this module -- matching
  # REQ-075's own precedent (Letflow.Routers.Tenants keeps that orchestration
  # at the handler layer) and REQ-022 §6's "no coupling" rule (Letflow.Identity
  # does not call into Letflow.TenantProvisioning).

  @doc """
  Inserts an `OnboardingRecord` row recording a completed tenant-onboarding
  binding — the final step of the router-orchestrated onboarding flow (design
  §8.2 step 3), called only after `Letflow.TenantProvisioning.provision_tenant_schema/1`
  and `Letflow.TenantProvisioning.replay_migrations/2` have both already
  succeeded for `attrs.tenant_id`. `attrs` carries `tenant_id`/`slug`/`hostname`.

  Returns `{:error, :duplicate_hostname}` on a `hostname` unique-constraint
  violation.
  """
  @spec create_onboarding(
          attrs :: %{
            tenant_id: Ecto.UUID.t(),
            slug: String.t(),
            hostname: String.t()
          }
        ) ::
          {:ok, OnboardingRecord.t()}
          | {:error, :duplicate_hostname}
          | {:error, :database_error}
          | {:error, Ecto.Changeset.t()}
  def create_onboarding(attrs) do
    changeset = OnboardingRecord.insert_changeset(%OnboardingRecord{}, attrs)

    case Repo.insert(changeset) do
      {:ok, record} ->
        {:ok, record}

      {:error, %Ecto.Changeset{} = changeset} ->
        if hostname_unique_conflict?(changeset) do
          {:error, :duplicate_hostname}
        else
          {:error, changeset}
        end
    end
  rescue
    # A database fault outside the changeset (a value longer than its column, or the database
    # unreachable) is a typed result for the caller, not an exception (SECURITY-REVIEWER INV-8, F5).
    # The exception class and the SQLSTATE are logged, and the tenant id, so an operator can tie the
    # failure to the committed tenant (F6). The message is not logged: it can carry the value (INV-4).
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error(
        "onboarding record insert failed (tenant_id=#{inspect(Map.get(attrs, :tenant_id))}, " <>
          "exception=#{inspect(error.__struct__)}, sqlstate=#{inspect(sqlstate(error))})"
      )

      {:error, :database_error}
  end

  defp sqlstate(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp sqlstate(_error), do: nil

  @doc "Fetches a single onboarding record by id. Design §8.2."
  @spec get_onboarding(id :: Ecto.UUID.t() | String.t()) ::
          {:ok, OnboardingRecord.t()} | {:error, :not_found}
  def get_onboarding(id) do
    case Repo.get(OnboardingRecord, id) do
      %OnboardingRecord{} = record -> {:ok, record}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  ISS-1030: the login state of an onboarded tenant, one primary-key read of
  `tenants`. `idp_realm_id` is `nil` while the tenant is "not yet loginable".
  Callers must already have passed the `:TenantsManage` gate (the onboarding
  router does); this function performs no authorization check.
  """
  @spec get_onboarding_login_state(tenant_id :: Ecto.UUID.t()) ::
          {:ok, %{idp_realm_id: String.t() | nil}} | {:error, :not_found}
  def get_onboarding_login_state(tenant_id) do
    case Repo.one(from(t in Tenant, where: t.id == ^tenant_id, select: {t.id, t.idp_realm_id})) do
      {_id, realm} -> {:ok, %{idp_realm_id: realm}}
      nil -> {:error, :not_found}
    end
  end

  @type bind_realm_opts :: [
          actor_id: Ecto.UUID.t(),
          platform_prefix: String.t(),
          trace_id: String.t() | nil
        ]

  @doc """
  ISS-1030 (design section 3.2): binds `realm` to a tenant that has none, ONCE.

  The bind-once exception to decision 0006 R5 ("`idp_realm_id` immutable after
  creation"): the tenant row is locked, and the realm is set only while the
  column is still NULL and the tenant is `:active`. A realm that is set is never
  changed or cleared. Outcomes:

    * `{:ok, tenant}` -- bound now, or the SAME realm was already stored
      (idempotent; no second audit entry).
    * `{:error, :not_found}` -- no such tenant.
    * `{:error, :realm_already_bound}` -- a DIFFERENT realm is already stored.
    * `{:error, :tenant_not_active}` -- the tenant is `:migrating` or `:inactive`
      and has no realm; nothing is written. (Not named in the design's spec
      union; the design requires this refusal in section 3.2.)
    * `{:error, :duplicate_realm}` -- the realm belongs to another tenant.
    * `{:error, %Ecto.Changeset{}}` -- the realm failed `Tenant.realm_bind_changeset/2`.
    * `{:error, :audit_failed}` -- an audit write failed or a prefix is missing;
      the whole transaction rolled back.

  Audit (one transaction with the update, section 7a): a TENANT-chain entry
  `tenant.idp_realm.bound` with a NIL actor (the operator's id is deliberately
  not written into a customer tenant's chain) and a PLATFORM-chain entry
  `platform.tenant_idp_realm.bound` carrying the operator's user id. Lock order:
  tenant row, tenant chain, platform chain. `opts[:platform_prefix]` must be
  verified by the caller (`Letflow.PlatformTenant.platform_prefix/0`).
  """
  @spec bind_tenant_realm(
          tenant_id :: Ecto.UUID.t(),
          realm :: String.t(),
          bind_realm_opts()
        ) ::
          {:ok, Tenant.t()}
          | {:error, :not_found}
          | {:error, :realm_already_bound}
          | {:error, :tenant_not_active}
          | {:error, :duplicate_realm}
          | {:error, Ecto.Changeset.t()}
          | {:error, :audit_failed}
  def bind_tenant_realm(tenant_id, realm, opts) when is_binary(realm) do
    actor_id = Keyword.get(opts, :actor_id)
    platform_prefix = Keyword.get(opts, :platform_prefix)

    if is_binary(actor_id) and is_binary(platform_prefix) do
      Multi.new()
      |> Multi.run(:bind, fn repo, _changes -> lock_and_bind_realm(repo, tenant_id, realm) end)
      |> Multi.run(:audit, fn repo, %{bind: bound} ->
        audit_realm_bind(repo, bound, actor_id, platform_prefix, Keyword.get(opts, :trace_id))
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{bind: {_outcome, tenant}}} -> {:ok, tenant}
        {:error, :bind, reason, _changes} -> {:error, reason}
        {:error, _step, _reason, _changes} -> {:error, :audit_failed}
      end
    else
      {:error, :audit_failed}
    end
  rescue
    # Fixed message, tenant id only: never the exception (INV-4).
    exception ->
      # The exception class only: the message can carry the realm (INV-4).
      Logger.error(
        "tenant realm bind failed (tenant_id=#{inspect(tenant_id)}, exception=#{inspect(exception.__struct__)})"
      )

      committed_realm_or_audit_failed(tenant_id, realm)
  catch
    # An exit from the checkout (DBConnection's holder) is not an exception, so the rescue above does not see it
    # (SECURITY-REVIEWER round 3, BLOCKER, INV-8). The outcome is unknown, so the realm is re-read as for a raise.
    # Only the exit tag is logged (INV-4).
    :exit, reason ->
      Logger.error(
        "tenant realm bind failed (tenant_id=#{inspect(tenant_id)}, exit=#{inspect(bind_exit_tag(reason))})"
      )

      committed_realm_or_audit_failed(tenant_id, realm)
  end

  # The exit tag only. The reason can carry the pool and its options (INV-4).
  defp bind_exit_tag({tag, _detail}) when is_atom(tag), do: tag
  defp bind_exit_tag(tag) when is_atom(tag), do: tag
  defp bind_exit_tag(_other), do: :other

  # An exception or exit during COMMIT leaves the outcome unknown, so re-read before reporting a failure
  # (SECURITY-REVIEWER F5). A rolled-back bind shows the realm still NULL and stays :audit_failed.
  defp committed_realm_or_audit_failed(tenant_id, realm) do
    case Repo.get(Tenant, tenant_id) do
      %Tenant{idp_realm_id: ^realm} = tenant -> {:ok, tenant}
      _other -> {:error, :audit_failed}
    end
  rescue
    exception ->
      Logger.error(
        "tenant realm re-read failed (tenant_id=#{inspect(tenant_id)}, exception=#{inspect(exception.__struct__)})"
      )

      {:error, :audit_failed}
  catch
    :exit, reason ->
      Logger.error(
        "tenant realm re-read failed (tenant_id=#{inspect(tenant_id)}, exit=#{inspect(bind_exit_tag(reason))})"
      )

      {:error, :audit_failed}
  end

  defp lock_and_bind_realm(repo, tenant_id, realm) do
    locked = from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE")

    # Status is checked first: design 3.2 answers 409 for any non-active tenant, even when
    # the same realm is already stored, so a repeat call cannot succeed on a non-active tenant.
    case repo.one(locked) do
      nil ->
        {:error, :not_found}

      %Tenant{status: status} when status != :active ->
        {:error, :tenant_not_active}

      %Tenant{idp_realm_id: ^realm} = tenant ->
        {:ok, {:unchanged, tenant}}

      %Tenant{idp_realm_id: stored} when is_binary(stored) ->
        {:error, :realm_already_bound}

      %Tenant{} = tenant ->
        changeset = Tenant.realm_bind_changeset(tenant, %{"idp_realm_id" => realm})

        case repo.update(changeset) do
          {:ok, updated} -> {:ok, {:bound, updated}}
          {:error, %Ecto.Changeset{} = failed} -> {:error, realm_bind_failure(failed)}
        end
    end
  end

  defp realm_bind_failure(%Ecto.Changeset{errors: errors} = changeset) do
    unique? =
      Enum.any?(errors, fn
        {:idp_realm_id, {_message, keyword}} -> Keyword.get(keyword, :constraint) == :unique
        _other -> false
      end)

    if unique?, do: :duplicate_realm, else: changeset
  end

  defp audit_realm_bind(_repo, {:unchanged, _tenant}, _actor_id, _platform_prefix, _trace_id),
    do: {:ok, :unchanged}

  defp audit_realm_bind(repo, {:bound, tenant}, actor_id, platform_prefix, trace_id) do
    # `limit: 1`: tenant_id has only a plain index, so two rows would make get_by raise.
    onboarding_id =
      repo.one(
        from(o in OnboardingRecord, where: o.tenant_id == ^tenant.id, select: o.id, limit: 1)
      )

    with %TenantProvisioning.Registration{schema_name: prefix} <-
           repo.get_by(TenantProvisioning.Registration, tenant_id: tenant.id),
         {:ok, _tenant_entry} <-
           Audit.insert_entry(
             repo,
             %{
               actor_id: nil,
               action: "tenant.idp_realm.bound",
               resource_type: "tenant",
               resource_id: tenant.id,
               # No operator-chosen trace id in the tenant chain (tenant admins read it).
               trace_id: nil,
               before_state: nil,
               after_state: %{
                 "idp_realm_id" => tenant.idp_realm_id,
                 "actor_class" => "platform_operator"
               }
             },
             prefix
           ),
         {:ok, _platform_entry} <-
           Audit.insert_entry(
             repo,
             %{
               actor_id: actor_id,
               action: "platform.tenant_idp_realm.bound",
               resource_type: "tenant",
               resource_id: tenant.id,
               trace_id: trace_id,
               before_state: nil,
               after_state: %{
                 "tenant_id" => tenant.id,
                 "idp_realm_id" => tenant.idp_realm_id,
                 "onboarding_id" => onboarding_id
               }
             },
             platform_prefix
           ) do
      {:ok, :audited}
    else
      _missing_registration_or_audit_failure -> {:error, :audit_failed}
    end
  end

  @doc """
  Fetches a single onboarding record by `hostname`. Design §8.2/§8.4 —
  callers of this function must already have run
  `Letflow.Api.Authorization.evaluate_access/2` against `:TenantsManage`
  **before** calling it (`Letflow.Routers.Onboarding`'s own "no `Repo` call
  before authorization" discipline); this function itself performs no
  authorization check and is not, on its own, INV-5-safe — see the design
  doc §8.4 for the full argument for why the route-level ordering is what
  actually satisfies AC7/INV-5, not this function.
  """
  @spec get_onboarding_by_hostname(hostname :: String.t()) ::
          {:ok, OnboardingRecord.t()} | {:error, :not_found}
  def get_onboarding_by_hostname(hostname) do
    case Repo.get_by(OnboardingRecord, hostname: hostname) do
      %OnboardingRecord{} = record -> {:ok, record}
      nil -> {:error, :not_found}
    end
  end

  @spec hostname_unique_conflict?(changeset :: Ecto.Changeset.t()) :: boolean()
  defp hostname_unique_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:hostname, {_message, keyword}} -> Keyword.get(keyword, :constraint) == :unique
      _other -> false
    end)
  end

  # ── create_group/2 / add_group_member/3 private helpers ─────────────────

  @spec group_name_unique_conflict?(changeset :: Ecto.Changeset.t()) :: boolean()
  defp group_name_unique_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:name, {_message, keyword}} -> Keyword.get(keyword, :constraint) == :unique
      _other -> false
    end)
  end

  # GH 2547 (design section 3.2.1): `created` keeps its meaning (no membership seen
  # before this call); `inserted` says whether THIS call wrote the row, so a lost race
  # is never audited twice. insert_all/3 returns that count (it autogenerates no
  # timestamp, hence the explicit inserted_at, tenant_admin_migration.ex's precedent).
  @spec insert_or_fetch_group_member(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, %{member: GroupMember.t(), created: boolean(), inserted: boolean()}}
          | {:error, :unexpected_missing_member}
  defp insert_or_fetch_group_member(group_id, user_id, prefix) do
    case get_group_member(group_id, user_id, prefix) do
      %GroupMember{} = existing ->
        {:ok, %{member: existing, created: false, inserted: false}}

      nil ->
        now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

        {count, _rows} =
          Repo.insert_all(
            GroupMember,
            [%{group_id: group_id, user_id: user_id, inserted_at: now}],
            on_conflict: :nothing,
            conflict_target: [:group_id, :user_id],
            prefix: prefix
          )

        # Race window between the existence check above and this insert: if
        # a concurrent caller won it, our own insert was suppressed by
        # on_conflict: :nothing (count 0) -- re-select to return the
        # authoritative row either way, still `created: true` from THIS
        # caller's perspective (it observed no prior membership). A missing
        # row cannot happen inside the transaction; it is an error, not assumed.
        case get_group_member(group_id, user_id, prefix) do
          %GroupMember{} = member -> {:ok, %{member: member, created: true, inserted: count == 1}}
          nil -> {:error, :unexpected_missing_member}
        end
    end
  end

  defp get_group_member(group_id, user_id, prefix) do
    Repo.get_by(GroupMember, [group_id: group_id, user_id: user_id], prefix: prefix)
  end

  # ── list_group_members/3 private helpers ────────────────────────────────

  @group_members_cursor_prefix "G:"

  defp filter_group_members_by_cursor(query, nil), do: query

  defp filter_group_members_by_cursor(query, {ts, user_id}) do
    from([m, u] in query,
      where: m.inserted_at > ^ts or (m.inserted_at == ^ts and m.user_id > ^user_id)
    )
  end

  # Same deliberate field-slot repurposing as decode_users_cursor/1 -- see
  # that function's own comment for the full rationale (mint time in the
  # expiry-checked first slot, real sort key/tiebreaker in the other two).
  defp decode_group_members_cursor(nil), do: {:ok, nil}

  defp decode_group_members_cursor(%Pagination.Cursor{inner: inner}) do
    decode_naive_seek(inner, @group_members_cursor_prefix)
  end

  defp split_group_members_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {last_user, last_inserted_at} = List.last(page)

    {Enum.map(page, fn {u, _ts} -> u end),
     build_group_members_next_cursor(last_user, last_inserted_at)}
  end

  defp split_group_members_page(rows, _page_size) do
    {Enum.map(rows, fn {u, _ts} -> u end), nil}
  end

  defp build_group_members_next_cursor(%User{id: user_id}, inserted_at) do
    mint_time_us = System.system_time(:microsecond)
    inserted_at_us = us_from_naive_datetime(inserted_at)

    @group_members_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(mint_time_us, inserted_at_us, user_id)
    |> Pagination.encode_cursor()
  end

  # ── list_users/2 private helpers ────────────────────────────────────────

  @list_users_cursor_prefix "U:"

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: from(u in query, where: u.status == ^status)

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) do
    like = "%#{search}%"

    from(u in query,
      where: ilike(u.username, ^like) or ilike(u.display_name, ^like) or ilike(u.email, ^like)
    )
  end

  defp filter_by_cursor(query, nil), do: query

  defp filter_by_cursor(query, {ts, id}) do
    from(u in query,
      where: u.inserted_at > ^ts or (u.inserted_at == ^ts and u.id > ^id)
    )
  end

  # Payload shape: "U:<mint_time_us>:<inserted_at_us>:<id>" — built via
  # Pagination.build_raw_cursor_timestamp_key/4, but with a deliberate
  # field-slot repurposing over its literal parameter names, called out here
  # since it deviates from a literal reading of design §7 gap 2 (flagged in
  # ELIXIR-DEV's handoff, not silent):
  #
  # `decode_cursor/4`'s expiry check reads the timestamp starting at a FIXED
  # byte offset (this router calls it with `byte_size(prefix)`, i.e. right
  # after "U:") and treats it as "when was this cursor minted" for the 24h
  # freshness window (`Letflow.Api.Pagination`'s own moduledoc/design §5.1).
  # A row's `inserted_at` is NOT a safe value to put there: a user created
  # more than 24h ago would make every cursor built from their row appear
  # already-expired the instant it's minted, which is not what AC-level
  # cursor expiry is supposed to mean. So the FIRST field (the
  # `sort_timestamp_us` parameter slot of `build_raw_cursor_timestamp_key/4`)
  # carries the real mint time (`System.system_time(:microsecond)`), and
  # `inserted_at_us`/`id` — this endpoint's actual sort key and tiebreaker —
  # are carried in the `key`/`cursor_created_at_us` slots instead, purely for
  # their textual position in the payload, not their parameter names' literal
  # meaning.
  defp decode_users_cursor(nil), do: {:ok, nil}

  defp decode_users_cursor(%Pagination.Cursor{inner: inner}) do
    decode_naive_seek(inner, @list_users_cursor_prefix)
  end

  # Shared by the three identity listings whose payload is
  # "<prefix><mint_time_us>:<inserted_at_us>:<uuid>": returns the seek as
  # `{NaiveDateTime, uuid}` (the `inserted_at` columns are naive), or
  # `{:error, :invalid_cursor}` for a malformed tail (GH 2747).
  defp decode_naive_seek(inner, prefix) do
    case Pagination.decode_seek_parts(inner, prefix, [:skip, :datetime_us, :uuid]) do
      {:ok, [inserted_at, id]} -> {:ok, {DateTime.to_naive(inserted_at), id}}
      {:error, :invalid_cursor} = error -> error
    end
  end

  defp split_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_next_cursor(List.last(page))}
  end

  defp split_page(rows, _page_size), do: {rows, nil}

  defp build_next_cursor(%User{id: id, inserted_at: inserted_at}) do
    mint_time_us = System.system_time(:microsecond)
    inserted_at_us = us_from_naive_datetime(inserted_at)

    @list_users_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(mint_time_us, inserted_at_us, id)
    |> Pagination.encode_cursor()
  end

  defp us_from_naive_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  # PROVENANCE (historical, not current decision authority):
  # The upsert algorithm — select-first / INSERT ... ON CONFLICT ... DO
  # NOTHING / re-select-on-conflict, matching registry.zig lines 843-912
  # exactly. Deliberately not Ecto.Multi (this is one logical conditional
  # insert, not several writes needing transactional composition) and
  # deliberately not a naive insert-then-rescue-unique-constraint-error
  # pattern (that would abort the surrounding transaction on the
  # unique-constraint violation unless caught behind an explicit
  # savepoint — added complexity this select-first approach avoids
  # entirely) — see
  # lib/letflow/design/req018-jit-provisioning.md §3.
  defp upsert_by_external_identity(identity_context, tenant_id, jit_config, opts) do
    case get_by_external_identity(tenant_id, identity_context, opts) do
      %User{} = existing ->
        # REQ-378 §2.2.3 -- sync gate: only when this row has never been
        # synced before (marker still nil). Short-circuits before any new
        # Repo call for the overwhelming majority of returning-user
        # requests (marker already non-nil from a prior sync).
        user =
          if is_nil(existing.role_claims_synced_at) do
            sync_role_claims_from_token(existing, identity_context, opts)
          else
            existing
          end

        {:ok, %{user: user, created: false}}

      nil ->
        insert_or_fetch(identity_context, tenant_id, jit_config, opts)
    end
  end

  # REQ-435 (design §3.5, D2): the JIT insert, its created-check and the login
  # directory upsert now run in ONE new Repo.transaction (the insert was not in
  # any transaction before, so there was none to join). Only a genuinely
  # created row writes a directory entry; a directory failure aborts the
  # transaction and surfaces as {:error, {:login_directory, reason}}.
  # sync_role_claims_from_token/3 deliberately runs AFTER the transaction
  # commits, exactly as it ran after the insert before this change.
  defp insert_or_fetch(identity_context, tenant_id, jit_config, opts) do
    case Repo.transaction(fn ->
           insert_or_fetch_in_tx(identity_context, tenant_id, jit_config, opts)
         end) do
      {:ok, {:created, inserted}} ->
        # REQ-378 §2.2.3 -- a brand-new row's marker is always nil, so no
        # gate check is needed here (the row cannot pre-exist).
        synced_user = sync_role_claims_from_token(inserted, identity_context, opts)
        {:ok, %{user: synced_user, created: true}}

      {:ok, {:existing, existing}} ->
        # REQ-378 §2.2.3 -- identical gate to upsert_by_external_identity/4's
        # own %User{} = existing branch: this is the on-conflict race-loser
        # path's "found an existing row" outcome, and both must apply the same
        # marker-gated sync. No directory write: the race winner wrote it.
        user =
          if is_nil(existing.role_claims_synced_at) do
            sync_role_claims_from_token(existing, identity_context, opts)
          else
            existing
          end

        {:ok, %{user: user, created: false}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Runs inside the transaction opened by insert_or_fetch/4. Returns
  # {:created, user} | {:existing, user}, or aborts via Repo.rollback/1.
  defp insert_or_fetch_in_tx(identity_context, tenant_id, jit_config, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    attrs = %{
      external_realm: identity_context.realm,
      external_id: identity_context.external_user_id,
      username: identity_context.preferred_username,
      display_name: identity_context.display_name || identity_context.preferred_username,
      email: identity_context.email,
      status: jit_config.default_status
    }

    changeset = User.jit_changeset(%User{}, attrs)

    # mode: :savepoint -- a unique violation on the separate `username` index
    # would otherwise abort the surrounding Postgres transaction ("current
    # transaction is aborted") and every recovery query below would fail. The
    # savepoint rolls back only this statement, leaving the transaction usable
    # (design §3.5). The on_conflict: :nothing arbiter raises no error.
    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment, "(external_realm, external_id) WHERE external_id IS NOT NULL"},
           returning: true,
           mode: :savepoint,
           prefix: prefix
         ) do
      {:ok, %User{id: id} = inserted} ->
        # Empirically verified against real Postgres (see handoff notes):
        # with this schema's client-generated binary_id primary key,
        # Repo.insert/2 + on_conflict: :nothing + returning: true does NOT
        # distinguish "genuinely inserted" from "suppressed by ON CONFLICT DO
        # NOTHING" anywhere in the returned {:ok, struct} — every field,
        # including the primary key, is padded from the changeset's own
        # locally-known data when the database's RETURNING clause yields zero
        # rows, so a suppressed insert and a real one produce
        # struct-for-struct identical {:ok, %User{}} results. The design's
        # anticipated `id: nil` signal does not occur for this schema (it
        # would only occur for a server-generated, e.g. serial, primary key).
        # The only reliable way to tell them apart is to check whether a row
        # with our own freshly-generated id actually exists in the database —
        # Repo.get/2 on the primary key is the cheapest form of that check.
        if Repo.get(User, id, prefix: prefix) do
          write_jit_directory_entry(inserted, tenant_id, opts)
          {:created, inserted}
        else
          re_select_on_conflict(tenant_id, identity_context, opts)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        if username_unique_conflict?(changeset) do
          # Opponent may have raced us with the identical (external_realm,
          # external_id, username) triple -- find out who actually holds
          # that username now. Postgres's on_conflict: :nothing above only
          # names the (external_realm, external_id) arbiter, so a losing
          # racer can raise on the separate `username` unique index instead
          # -- see lib/letflow/design/iss-0047-username-race-conflict-target.md.
          case get_by_username(identity_context.preferred_username, opts) do
            %User{} = holder ->
              if identity_matches?(holder, identity_context) do
                # Same identity as ours -> this is our own race opponent,
                # already persisted. Resolve exactly like the
                # already-working on_conflict path does.
                re_select_on_conflict(tenant_id, identity_context, opts)
              else
                # A DIFFERENT identity already holds this username ->
                # genuine, unrelated collision. Propagate the original
                # changeset error unchanged.
                Repo.rollback(changeset)
              end

            nil ->
              # Should not happen (Repo.insert/2 just told us a username
              # conflict occurred) but handled defensively rather than
              # assumed unreachable, matching this module's existing
              # defensive-fallback discipline. Propagate the original
              # error -- do not fabricate a {:ok, _} result for a row this
              # call cannot actually locate.
              Repo.rollback(changeset)
          end
        else
          # Not a username-constraint error at all -> unchanged existing
          # behavior.
          Repo.rollback(changeset)
        end
    end
  end

  # REQ-435: only reached for a genuinely created row. A user with an
  # ineligible email or a non-active default status writes nothing and is not
  # an error (design §3.5). The guard runs only when there is an entry to
  # write, so JIT of an ineligible user never depends on the tenant opts.
  defp write_jit_directory_entry(%User{} = inserted, tenant_id, opts) do
    case LoginDirectory.plan_user_change(nil, inserted) do
      [] ->
        :ok

      plan ->
        with {:ok, {:enabled, canonical}} <- jit_directory_target(tenant_id, opts),
             :ok <- LoginDirectory.apply_plan(plan, canonical, Keyword.fetch!(opts, :prefix)) do
          :ok
        else
          {:ok, :skip} -> :ok
          {:error, reason} -> Repo.rollback({:login_directory, reason})
        end
    end
  end

  # provision_oidc_user/4 already receives the authoritative tenant_id as a
  # positional argument, so the same fail-closed guard runs over it.
  defp jit_directory_target(tenant_id, opts),
    do: directory_target(Keyword.put(opts, :tenant_id, tenant_id))

  @spec username_unique_conflict?(changeset :: Ecto.Changeset.t()) :: boolean()
  defp username_unique_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:username, {_message, keyword}} -> Keyword.get(keyword, :constraint) == :unique
      _other -> false
    end)
  end

  # Runs inside insert_or_fetch/4's transaction; the marker-gated role-claims
  # sync is applied by the caller after commit.
  defp re_select_on_conflict(tenant_id, identity_context, opts) do
    case get_by_external_identity(tenant_id, identity_context, opts) do
      %User{} = existing -> {:existing, existing}
      nil -> Repo.rollback(:external_identity_collision)
    end
  end

  # `tenant_id` is accepted here (and by every caller above) only because the
  # upsert-key contract predates Decision 0006 D2 -- see this function's
  # callers' own `tenant_id` parameter threading, unchanged by D2. The actual
  # `Repo.get_by/3` filter below no longer includes `tenant_id:` because
  # `users.tenant_id` was dropped (Decision 0006 D2, REQ-064): the per-tenant
  # Postgres schema (`prefix:` below) already scopes this lookup to exactly
  # one tenant, so filtering on the now-removed column would raise
  # Ecto.QueryError instead of narrowing anything real.
  defp get_by_external_identity(_tenant_id, identity_context, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    Repo.get_by(
      User,
      [
        external_realm: identity_context.realm,
        external_id: identity_context.external_user_id
      ],
      prefix: prefix
    )
  end

  # Same tenant-scoping discipline as get_by_external_identity/3, keyed on
  # `username` instead of `(external_realm, external_id)`. users.username's
  # unique index is per-schema (Decision 0006/REQ-063), so this lookup is
  # automatically tenant-scoped by virtue of targeting the same `prefix:`
  # the failed insert itself used.
  @spec get_by_username(username :: String.t(), opts :: opts()) :: User.t() | nil
  defp get_by_username(username, opts) do
    Repo.get_by(User, [username: username], prefix: Keyword.fetch!(opts, :prefix))
  end

  @spec identity_matches?(user :: User.t(), identity_context :: IdentityContext.t()) ::
          boolean()
  defp identity_matches?(%User{} = user, %IdentityContext{} = identity_context) do
    user.external_realm == identity_context.realm and
      user.external_id == identity_context.external_user_id
  end
end
