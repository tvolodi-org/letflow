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
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantMembership
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.LoginDirectory
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.Repo
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
  """
  @type opts :: [prefix: String.t(), login_directory: :enabled | :skip]

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

  Always returns `{:ok, _}` — an empty or last page is
  `{:ok, %{users: [], next_cursor: nil}}`, never an error tuple.
  """
  @spec list_users(list_users_params(), opts :: opts()) ::
          {:ok, %{users: [User.t()], next_cursor: String.t() | nil}}
  def list_users(params, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    page_size = Map.fetch!(params, :page_size)

    query =
      User
      |> filter_by_status(Map.get(params, :status))
      |> filter_by_search(Map.get(params, :search))
      |> filter_by_cursor(Map.get(params, :cursor))
      |> order_by([u], asc: u.inserted_at, asc: u.id)
      |> limit(^(page_size + 1))

    rows = Repo.all(query, prefix: prefix)
    {page, next_cursor} = split_page(rows, page_size)

    {:ok, %{users: page, next_cursor: next_cursor}}
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
  """
  @spec update_user_profile(id :: Ecto.UUID.t(), attrs :: map(), opts :: user_write_opts()) ::
          {:ok, User.t()}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
          | {:error, directory_guard_error()}
          | {:error, {:login_directory, term()}}
          | {:error, {:transaction_failed, Exception.t()}}
  def update_user_profile(id, attrs, opts) do
    with {:ok, directory} <- directory_target(opts) do
      update_locked_user(id, opts, directory, "user.update_profile", fn locked ->
        User.profile_changeset(locked, attrs)
      end)
    end
  end

  @doc """
  Updates a user's `status` only. Design §7 gap 5 (OQ-5 — a dedicated
  `User.status_changeset/2` rather than reusing `profile_changeset/2`, see
  that function's own @doc).

  REQ-435: also maintains the platform login directory in the same
  transaction (a non-active status removes the entry unless another active
  user in the tenant has the same email) -- see `t:user_write_opts/0`.
  """
  @spec update_user_status(
          id :: Ecto.UUID.t(),
          status :: :active | :inactive,
          opts :: user_write_opts()
        ) ::
          {:ok, User.t()}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
          | {:error, directory_guard_error()}
          | {:error, {:login_directory, term()}}
          | {:error, {:transaction_failed, Exception.t()}}
  def update_user_status(id, status, opts) do
    with {:ok, directory} <- directory_target(opts) do
      update_locked_user(id, opts, directory, "user.update_status", fn locked ->
        User.status_changeset(locked, %{status: status})
      end)
    end
  end

  # REQ-435 (design §3.4): the `before` state the directory plan is computed
  # from is read INSIDE the transaction with a row lock (FOR UPDATE), not
  # before it, so two concurrent edits cannot compute plans from the same stale
  # row and leave a ghost entry. REQ-195 -- actor_id: nil, §3.1b (same
  # disposition/reasoning as create_user/2). The outer rescue (ISS-0983
  # hardening) is preserved.
  defp update_locked_user(id, opts, directory, audit_action, changeset_fun) do
    prefix = Keyword.fetch!(opts, :prefix)

    try do
      Multi.new()
      |> Multi.run(:locked_user, fn repo, _changes ->
        case repo.one(from(u in User, where: u.id == ^id, lock: "FOR UPDATE"), prefix: prefix) do
          %User{} = locked -> {:ok, locked}
          nil -> {:error, :not_found}
        end
      end)
      |> Multi.update(:user, fn %{locked_user: locked} -> changeset_fun.(locked) end,
        prefix: prefix
      )
      |> directory_step(directory, prefix, fn %{locked_user: locked, user: updated} ->
        {locked, updated}
      end)
      |> Multi.merge(fn %{locked_user: locked, user: updated} ->
        Audit.append_multi(
          Multi.new(),
          :audit,
          %{
            actor_id: nil,
            action: audit_action,
            resource_type: "user",
            resource_id: updated.id,
            before_state: Audit.struct_state(locked, [:password_hash]),
            after_state: Audit.struct_state(updated, [:password_hash]),
            trace_id: nil
          },
          prefix
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: updated}} -> {:ok, updated}
        {:error, :locked_user, :not_found, _changes} -> {:error, :not_found}
        {:error, :user, reason, _changes} -> {:error, reason}
        {:error, :login_directory, reason, _changes} -> {:error, {:login_directory, reason}}
        {:error, :audit, reason, _changes} -> {:error, reason}
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  @typedoc """
  Opts for the user-write functions that maintain the platform login directory
  (REQ-435, design §3.2): `:prefix` as before, plus a required `:tenant_id`
  supplied by the caller from the authenticated context (never from request
  data). A fail-closed guard checks that `schema_name_for_tenant(tenant_id)`
  equals `:prefix` before any write. `:login_directory` set to `:skip` disables
  the directory write; it exists only for test fixtures whose synthetic schema
  prefix has no `tenants` row, and no `lib/` caller may use it.
  """
  @type user_write_opts :: [
          prefix: String.t(),
          tenant_id: Ecto.UUID.t(),
          login_directory: :enabled | :skip
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
  """
  @spec add_group_member(group_id :: Ecto.UUID.t(), user_id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, %{member: GroupMember.t(), created: boolean()}}
          | {:error, :group_not_found}
          | {:error, :user_not_found}
  def add_group_member(group_id, user_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get(Group, group_id, prefix: prefix) do
      nil ->
        {:error, :group_not_found}

      %Group{} ->
        case Repo.get(User, user_id, prefix: prefix) do
          nil -> {:error, :user_not_found}
          %User{} -> insert_or_fetch_group_member(group_id, user_id, prefix)
        end
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

    case Repo.delete_all(query, prefix: prefix) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found_or_has_members}
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
          | {:error, :group_not_found}
  def list_group_members(group_id, params, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get(Group, group_id, prefix: prefix) do
      nil ->
        {:error, :group_not_found}

      %Group{} ->
        page_size = Map.fetch!(params, :page_size)

        query =
          from(m in GroupMember,
            join: u in User,
            on: u.id == m.user_id,
            where: m.group_id == ^group_id,
            select: {u, m.inserted_at}
          )
          |> filter_group_members_by_cursor(Map.get(params, :cursor))
          |> order_by([m, u], asc: m.inserted_at, asc: m.user_id)
          |> limit(^(page_size + 1))

        rows = Repo.all(query, prefix: prefix)
        {page, next_cursor} = split_group_members_page(rows, page_size)

        {:ok, %{members: page, next_cursor: next_cursor}}
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
  """
  @spec remove_group_member(
          group_id :: Ecto.UUID.t(),
          user_id :: Ecto.UUID.t(),
          opts :: opts()
        ) :: :ok | {:error, :group_not_found}
  def remove_group_member(group_id, user_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get(Group, group_id, prefix: prefix) do
      nil ->
        {:error, :group_not_found}

      %Group{} ->
        from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id)
        |> Repo.delete_all(prefix: prefix)

        :ok
    end
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
  """
  @spec sync_role_claims_from_token(
          user :: User.t(),
          identity_context :: IdentityContext.t(),
          opts :: opts()
        ) :: User.t()
  def sync_role_claims_from_token(%User{} = user, %IdentityContext{} = identity_context, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    group_ids = resolve_group_ids_for_role_names(identity_context.roles, opts)

    if identity_context.roles != [] and group_ids == [] do
      Logger.warning(
        "sync_role_claims_from_token/3: zero group_ids resolved for a non-empty claimed-role " <>
          "list -- user will read roles: [] and gain no grants (tenant=#{inspect(prefix)}, " <>
          "user_id=#{user.id}, claimed_roles=#{inspect(identity_context.roles)})"
      )
    end

    multi =
      Multi.new()
      |> Multi.run(:memberships, fn _repo, _changes ->
        # Reuses insert_or_fetch_group_member/3 (backs add_group_member/3)
        # directly at its lean private arity, per §2.2.2 step 2 — not
        # add_group_member/3's own public wrapper, which would add two
        # redundant Repo.get/3 existence checks for a Group/User this
        # function already knows exist (the group id just came from a live
        # tenant_role row, and `user` is the struct this function was
        # called with). Already on_conflict: :nothing / conflict_target:
        # [:group_id, :user_id] — idempotent, safe even if called twice.
        Enum.each(group_ids, &insert_or_fetch_group_member(&1, user.id, prefix))

        {:ok, group_ids}
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

    result = Repo.transaction(multi)

    case result do
      {:ok, %{user: synced_user}} ->
        synced_user

      {:ok, %{memberships: _}} ->
        user

      {:error, step, reason, _changes} ->
        Logger.error(
          "sync_role_claims_from_token/3: failed at step #{inspect(step)} " <>
            "for user_id=#{user.id}: #{inspect(reason)}"
        )

        user
    end
  end

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

  Always returns `{:ok, _}` — an empty or last page is `{:ok, %{tenants: [],
  next_cursor: nil}}`, never an error tuple.
  """
  @spec list_tenants(list_tenants_params()) ::
          {:ok, %{tenants: [Tenant.t()], next_cursor: String.t() | nil}}
  def list_tenants(params) do
    page_size = Map.fetch!(params, :page_size)

    query =
      Tenant
      |> filter_tenants_by_search(Map.get(params, :search))
      |> filter_tenants_by_cursor(Map.get(params, :cursor))
      |> order_by([t], asc: t.inserted_at, asc: t.id)
      |> limit(^(page_size + 1))

    rows = Repo.all(query)
    {page, next_cursor} = split_tenants_page(rows, page_size)

    {:ok, %{tenants: page, next_cursor: next_cursor}}
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

  @type patch_opts :: [actor_id: Ecto.UUID.t() | nil, trace_id: String.t() | nil]

  @doc """
  Partial-update of a tenant's `display_name` and (REQ-442)
  `login_disclosure_mode`, via `Tenant.admin_patch_changeset/2` — see that
  changeset's own @doc for why `:status` is structurally excluded from this path.

  A `display_name`-only patch is a plain `Repo.update/1` (unaudited, as before).
  When `login_disclosure_mode` actually changes, the update and one audit entry
  (`tenant.platform_setting.updated`, value-free payload, INV-2) are written in a
  single transaction in the TARGET tenant's audit chain, so both commit or both
  roll back. A mode change with no binary `actor_id` in `opts`, a tenant with no
  provisioned schema registration, or any audit/transaction failure returns
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

    with true <- is_binary(actor_id),
         %TenantProvisioning.Registration{schema_name: prefix} <-
           Repo.get_by(TenantProvisioning.Registration, tenant_id: tenant.id) do
      audit_attrs = %{
        actor_id: actor_id,
        action: "tenant.platform_setting.updated",
        resource_type: "tenant",
        resource_id: tenant.id,
        trace_id: Keyword.get(opts, :trace_id),
        before_state: nil,
        after_state: %{"changed" => true}
      }

      Multi.new()
      |> Multi.update(:tenant, changeset)
      |> Audit.append_multi(:audit, audit_attrs, prefix)
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

  defp filter_tenants_by_cursor(query, %Pagination.Cursor{} = cursor) do
    {inserted_at_us, id} = decode_tenants_cursor(cursor)
    ts = naive_datetime_from_us(inserted_at_us)

    from(t in query,
      where: t.inserted_at > ^ts or (t.inserted_at == ^ts and t.id > ^id)
    )
  end

  # Payload shape: "T:<mint_time_us>:<inserted_at_us>:<id>" — same
  # field-slot repurposing as decode_users_cursor/1 above (see that
  # function's comment for the full expiry-vs-sort-key reasoning, which
  # applies identically here).
  defp decode_tenants_cursor(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@tenants_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [_mint_time_us_str, inserted_at_us_str, id_str] = String.split(rest, ":", parts: 3)
    {String.to_integer(inserted_at_us_str), id_str}
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
  This is the single call site in the whole codebase that ever holds the
  plaintext after generation.
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
          insert_token(user_id, attrs, prefix)
        end
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

  defp insert_token(user_id, attrs, prefix) do
    try do
      plaintext = generate_token_plaintext()
      token_hash = hash_token_value(plaintext)
      name = "token-" <> String.slice(token_hash, 0, 8)

      changeset =
        ApiToken.insert_changeset(%ApiToken{}, %{
          user_id: user_id,
          name: name,
          token_hash: token_hash,
          roles: attrs.roles,
          expires_at: Map.get(attrs, :expires_at)
        })

      # REQ-195 -- actor_id: nil, §3.1b (same disposition/reasoning as
      # create_user/2 above). Wrapped in Ecto.Multi for the same-transaction
      # guarantee (AC3). after_state excludes token_hash (INV-4 -- a hash is
      # still a credential-adjacent secret with no audit value); the plaintext
      # itself is never captured anywhere, per ApiToken's own moduledoc.
      Multi.new()
      |> Multi.insert(:token, changeset, prefix: prefix)
      |> Multi.merge(fn %{token: token} ->
        Audit.append_multi(
          Multi.new(),
          :audit,
          %{
            actor_id: nil,
            action: "token.create",
            resource_type: "api_token",
            resource_id: token.id,
            before_state: nil,
            after_state: Audit.struct_state(token, [:token_hash]),
            trace_id: nil
          },
          prefix
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{token: token}} -> {:ok, %{token: token, plaintext: plaintext}}
        {:error, :token, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
        {:error, :audit, reason, _changes} -> {:error, reason}
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
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
  """
  @spec list_tokens(opts :: opts()) :: {:ok, [ApiToken.t()]}
  def list_tokens(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    tokens = Repo.all(from(t in ApiToken, order_by: [desc: t.inserted_at]), prefix: prefix)

    {:ok, tokens}
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
  """
  @spec revoke_token(token_id :: Ecto.UUID.t() | String.t(), opts :: opts()) ::
          {:ok, ApiToken.t()}
          | {:error, :not_found}
          | {:error, {:transaction_failed, Exception.t()}}
  def revoke_token(token_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get(ApiToken, token_id, prefix: prefix) do
      nil ->
        {:error, :not_found}

      %ApiToken{revoked_at: revoked_at} = token when not is_nil(revoked_at) ->
        {:ok, token}

      %ApiToken{} = token ->
        try do
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          # REQ-195 -- actor_id: nil, §3.1b (same disposition/reasoning as
          # create_user/2 above). Wrapped in Ecto.Multi for the
          # same-transaction guarantee (AC3). before_state/after_state both
          # exclude token_hash (INV-4).
          Multi.new()
          |> Multi.update(:token, ApiToken.revoke_changeset(token, %{revoked_at: now}),
            prefix: prefix
          )
          |> Multi.merge(fn %{token: updated} ->
            Audit.append_multi(
              Multi.new(),
              :audit,
              %{
                actor_id: nil,
                action: "token.revoke",
                resource_type: "api_token",
                resource_id: updated.id,
                before_state: Audit.struct_state(token, [:token_hash]),
                after_state: Audit.struct_state(updated, [:token_hash]),
                trace_id: nil
              },
              prefix
            )
          end)
          |> Repo.transaction()
          |> case do
            {:ok, %{token: updated}} -> {:ok, updated}
            {:error, :token, reason, _changes} -> {:error, reason}
            {:error, :audit, reason, _changes} -> {:error, reason}
          end
        rescue
          exception -> {:error, {:transaction_failed, exception}}
        end
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
  call's `Repo.get_by/3` can observe a pre-revocation value, because there is
  no cache layer between them to be stale.

  On a successful verification, best-effort updates `last_used_at` — a failure
  on that one non-essential write does not fail the verification itself (logged
  and swallowed).

  Returns `{:ok, %{user_id: user_id, roles: roles}}`, or `{:error, :invalid}`
  (no matching row), `{:error, :revoked}`, or `{:error, :expired}`.
  """
  @spec verify_api_token(plaintext :: String.t(), opts :: opts()) ::
          {:ok, %{user_id: Ecto.UUID.t(), roles: [String.t()]}}
          | {:error, :invalid}
          | {:error, :revoked}
          | {:error, :expired}
  def verify_api_token(plaintext, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    token_hash = hash_token_value(plaintext)

    case Repo.get_by(ApiToken, [token_hash: token_hash], prefix: prefix) do
      nil ->
        {:error, :invalid}

      %ApiToken{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        {:error, :revoked}

      %ApiToken{expires_at: expires_at} = token when not is_nil(expires_at) ->
        if DateTime.compare(expires_at, DateTime.utc_now()) != :gt do
          {:error, :expired}
        else
          touch_last_used_and_verify(token, prefix)
        end

      %ApiToken{} = token ->
        touch_last_used_and_verify(token, prefix)
    end
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
  end

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
    _exception ->
      Logger.error("tenant realm bind failed (tenant_id=#{inspect(tenant_id)})")
      {:error, :audit_failed}
  end

  defp lock_and_bind_realm(repo, tenant_id, realm) do
    locked = from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE")

    case repo.one(locked) do
      nil ->
        {:error, :not_found}

      %Tenant{idp_realm_id: ^realm} = tenant ->
        {:ok, {:unchanged, tenant}}

      %Tenant{idp_realm_id: stored} when is_binary(stored) ->
        {:error, :realm_already_bound}

      %Tenant{status: status} when status != :active ->
        {:error, :tenant_not_active}

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
    onboarding_id =
      case repo.get_by(OnboardingRecord, tenant_id: tenant.id) do
        %OnboardingRecord{id: id} -> id
        nil -> nil
      end

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
               trace_id: trace_id,
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

  defp insert_or_fetch_group_member(group_id, user_id, prefix) do
    case get_group_member(group_id, user_id, prefix) do
      %GroupMember{} = existing ->
        {:ok, %{member: existing, created: false}}

      nil ->
        changeset =
          %GroupMember{}
          |> Ecto.Changeset.change(%{group_id: group_id, user_id: user_id})

        {:ok, inserted} =
          Repo.insert(changeset,
            on_conflict: :nothing,
            conflict_target: [:group_id, :user_id],
            prefix: prefix
          )

        # Race window between the existence check above and this insert: if
        # a concurrent caller won it, our own insert was suppressed by
        # on_conflict: :nothing and `inserted` doesn't reflect a real row --
        # re-select to return the authoritative one, still `created: true`
        # from THIS caller's perspective (it observed no prior membership).
        case get_group_member(group_id, user_id, prefix) do
          %GroupMember{} = member -> {:ok, %{member: member, created: true}}
          nil -> {:ok, %{member: inserted, created: true}}
        end
    end
  end

  defp get_group_member(group_id, user_id, prefix) do
    Repo.get_by(GroupMember, [group_id: group_id, user_id: user_id], prefix: prefix)
  end

  # ── list_group_members/3 private helpers ────────────────────────────────

  @group_members_cursor_prefix "G:"

  defp filter_group_members_by_cursor(query, nil), do: query

  defp filter_group_members_by_cursor(query, %Pagination.Cursor{} = cursor) do
    {inserted_at_us, user_id} = decode_group_members_cursor(cursor)
    ts = naive_datetime_from_us(inserted_at_us)

    from([m, u] in query,
      where: m.inserted_at > ^ts or (m.inserted_at == ^ts and m.user_id > ^user_id)
    )
  end

  # Same deliberate field-slot repurposing as decode_users_cursor/1 -- see
  # that function's own comment for the full rationale (mint time in the
  # expiry-checked first slot, real sort key/tiebreaker in the other two).
  defp decode_group_members_cursor(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@group_members_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [_mint_time_us_str, inserted_at_us_str, user_id_str] = String.split(rest, ":", parts: 3)
    {String.to_integer(inserted_at_us_str), user_id_str}
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

  defp filter_by_cursor(query, %Pagination.Cursor{} = cursor) do
    {ts_us, id} = decode_users_cursor(cursor)
    ts = naive_datetime_from_us(ts_us)

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
  defp decode_users_cursor(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@list_users_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [_mint_time_us_str, inserted_at_us_str, id_str] = String.split(rest, ":", parts: 3)
    {String.to_integer(inserted_at_us_str), id_str}
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

  defp naive_datetime_from_us(us) when is_integer(us) do
    us
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_naive()
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
