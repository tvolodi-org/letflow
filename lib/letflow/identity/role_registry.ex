defmodule Letflow.Identity.RoleRegistry do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Ports R-Co `src/identity/role_registry.zig`'s `TenantRoleStore` (`list_roles`,
  `upsert_role`) and `resolveRoleInTx` — see also
  `src/design/idn05-role-registry.md`, the design doc `role_registry.zig` itself points
  to. Operates on REQ-015's `tenant_role`/`groups` schema
  (`Letflow.Identity.TenantRole`, `Letflow.Identity.Group`). Full design:
  `lib/letflow/design/req020-role-registry.md`.

  This module has **no coupling to the OIDC/claim-mapping pipeline**: it does not
  `alias` or call any `Letflow.Oidc.*` module, and it does not call or get called by
  `Letflow.Identity`'s OIDC-pipeline functions (`provision_oidc_user/3`,
  `resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`, `verify_realm_ownership/2`).
  It is a standalone, workflow-engine-facing role registry — consumed by a future S3
  transition-time lookup (role name → group UUID) — not part of token verification or
  identity resolution.
  """

  import Ecto.Query

  alias Letflow.Api.Authorization
  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.AuditContext
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.TenantRole
  alias Letflow.PlatformTenant
  alias Letflow.Repo

  @type kind :: TenantRole.kind()

  @type upsert_error ::
          :invalid_role_name
          | :invalid_group_id
          | :group_not_found
          | :name_not_a_recognized_platform_role
          | :platform_admin_outside_platform_tenant
          | :role_already_bound
          | {:audit_failed, term()}
          | {:transaction_failed, Exception.t()}
          | Ecto.Changeset.t()

  @type rebind_error ::
          :role_not_found
          | :group_not_found
          | :invalid_group_id
          | :invalid_reason
          | :platform_admin_outside_platform_tenant
          | {:audit_failed, term()}
          | Ecto.Changeset.t()

  @type coverage_gap :: %{
          held_process_routing_roles: [String.t()],
          held_platform_roles: [String.t()]
        }

  @max_name_codepoints 128
  @control_char_pattern ~r/[\x00-\x1F\x7F]/u

  # GH 2524: a rebind reason is free text shown to audit readers. Cc (C0, DEL, C1), Cf
  # (format/bidi characters such as U+200B..U+200F, U+202A..U+202E, U+2066..U+2069, U+FEFF)
  # and the line/paragraph separators Zl/Zp (U+2028, U+2029) are refused so a reason is one
  # line and cannot visually spoof an audit reader.
  @max_reason_codepoints 500
  @reason_forbidden_pattern ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

  @doc """
  Returns every role binding sorted by `name` ascending. Returns `[]` (not an error)
  when `tenant_role` is empty.
  """
  @spec list_roles(opts :: [prefix: String.t()]) :: [TenantRole.t()]
  def list_roles(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    Repo.all(from(t in TenantRole, order_by: [asc: t.name]), prefix: prefix)
  end

  @doc """
  REQ-447 (design section 3.6b): the id of the group the `PLATFORM_ADMIN`
  binding (`kind == :platform_role`) points to in `opts[:prefix]`'s schema, or
  `:none` when there is no such binding. Resolved by BINDING, never by group name.
  """
  @spec platform_admin_group_id(opts :: [prefix: String.t()]) :: {:ok, Ecto.UUID.t()} | :none
  def platform_admin_group_id(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    query =
      from(t in TenantRole,
        where: t.name == "PLATFORM_ADMIN" and t.kind == :platform_role,
        select: t.group_id
      )

    case Repo.one(query, prefix: prefix) do
      nil -> :none
      group_id -> {:ok, group_id}
    end
  end

  @doc """
  Inserts or updates the `(name -> group_id)` binding for the given `kind` domain
  (ISS-0774): validates `name`'s format, `kind == :platform_role`'s membership in
  `Letflow.Api.Authorization.roles/0`'s eight literal strings, and `group_id`'s UUID
  syntax before any DB round-trip, then confirms `group_id` references an existing
  group and binds `name` inside one transaction.

  GH 2524: this never moves an existing binding to another group. A name that is not
  bound is inserted; a name already bound to the same group is returned unchanged (a
  different `kind` is still converted, as before); a name bound to a different group
  returns `{:error, :role_already_bound}` and writes nothing. Moving a binding is the
  explicit, audited `rebind_role/4`. Design: `lib/letflow/design/gh2524-role-rebind-explicit.md`.

  `kind` is a required, non-defaulted parameter — deliberately call-site-breaking
  over the prior `upsert_role/3`, so every caller states which domain it is writing
  rather than falling through a default that could silently mis-tag a row (design
  §2.3). `kind == :platform_role` additionally requires `name` to be one of
  `Letflow.Api.Authorization.roles/0`'s eight recognized literals — any other value
  returns `{:error, :name_not_a_recognized_platform_role}` before any `Repo` call,
  loudly rejecting a typo'd platform-role grant instead of silently creating a dead
  role binding nothing ever resolves. REQ-447 PR 2: a `:platform_role` binding named
  `PLATFORM_ADMIN` outside the platform tenant's schema returns
  `{:error, :platform_admin_outside_platform_tenant}` (also before any `Repo` call).
  `kind == :process_routing_role` gets no such
  literal-set check — that domain is open-ended by design (any
  process-definition-chosen string), only `validate_role_name/1`'s existing format
  checks apply.

  GH 2547 (design `gh2547-tenant-admin-audit-and-count.md` sections 3.4, 6.6): the
  transaction takes `Letflow.Identity.lock_tenant_admins!/1`, then the role row by name,
  then the group row `FOR UPDATE`. A binding write that grants someone (a new binding,
  or a `kind` conversion, over a group with at least one member) writes one
  `role_binding.created` / `role_binding.kind_changed` audit entry listing the members,
  with actor, trace and source from `opts[:audit_context]`; over an empty group it
  writes none. A non-raising audit failure rolls back and returns
  `{:error, {:audit_failed, reason}}`; a raise returns
  `{:error, {:transaction_failed, exception}}`.
  """
  @spec upsert_role(
          name :: String.t(),
          kind :: kind(),
          group_id :: Ecto.UUID.t() | String.t(),
          opts :: [prefix: String.t(), audit_context: AuditContext.t()]
        ) ::
          {:ok, TenantRole.t()} | {:error, upsert_error()}
  def upsert_role(name, kind, group_id, opts)
      when kind in [:platform_role, :process_routing_role] do
    with :ok <- validate_role_name(name),
         :ok <- validate_platform_role_name(kind, name),
         :ok <- reject_platform_admin_outside_platform_tenant(kind, name, opts),
         {:ok, normalized_group_id} <- Ecto.UUID.cast(group_id) do
      do_upsert_role(name, kind, normalized_group_id, opts)
    else
      :error -> {:error, :invalid_group_id}
      {:error, reason} -> {:error, reason}
    end
  end

  # REQ-447 PR 2 (design section 3.4): the `PLATFORM_ADMIN` binding exists only in
  # the platform tenant. Decided purely from the schema name, before any `Repo`
  # call; a `:process_routing_role` row is a different domain and is not touched.
  @spec reject_platform_admin_outside_platform_tenant(kind(), String.t(), keyword()) ::
          :ok | {:error, :platform_admin_outside_platform_tenant}
  defp reject_platform_admin_outside_platform_tenant(:platform_role, "PLATFORM_ADMIN", opts) do
    if Letflow.PlatformTenant.platform_prefix?(Keyword.get(opts, :prefix)),
      do: :ok,
      else: {:error, :platform_admin_outside_platform_tenant}
  end

  defp reject_platform_admin_outside_platform_tenant(_kind, _name, _opts), do: :ok

  @spec validate_platform_role_name(kind(), String.t()) ::
          :ok | {:error, :name_not_a_recognized_platform_role}
  defp validate_platform_role_name(:process_routing_role, _name), do: :ok

  defp validate_platform_role_name(:platform_role, name) do
    if name in platform_role_names() do
      :ok
    else
      {:error, :name_not_a_recognized_platform_role}
    end
  end

  @spec platform_role_names() :: [String.t()]
  defp platform_role_names, do: Enum.map(Authorization.roles(), &Atom.to_string/1)

  @doc """
  ISS-0778 / REQ-447: seeds the group/role bindings for the platform roles the
  tenant is entitled to, `seedable_role_names/1` (all eight roles of
  `Letflow.Api.Authorization.roles/0` in the platform tenant, every role except
  `PLATFORM_ADMIN` in any other tenant, so every tenant gets a `TENANT_ADMIN`
  binding; names come from this module's own
  `platform_role_names/0` — no new literal list invented). For each name, in
  `Authorization.roles/0`'s own declared order: get-or-creates a `Group`
  named after that literal (`get_or_create_group_by_name/2`), then binds it
  as `kind: :platform_role` (`ensure_platform_role_binding/2`). GH 2524: a name
  that already has a `:platform_role` binding keeps it, whatever group it points
  at (an administrator may have moved it with `rebind_role/4`); the seed never
  moves a binding.

  Idempotent under re-invocation against a tenant whose `groups`/`tenant_role`
  rows may already exist (design §2.4) — a second call keeps the existing
  bindings rather than erroring or duplicating rows. This is what makes
  it safe to call both from the normal onboarding-creation path and from
  `Letflow.TenantOnboarding.recover_provisioning/1`.

  Returns the first `{:error, _}` immediately on either step's failure — no
  partial-success return value. The individual writes already made by this
  call are **not** rolled back (matches this module's and
  `Letflow.TenantOnboarding`'s existing no-compensating-rollback precedent);
  a retried call converges via idempotency instead.

  Name-collision guard (REQ-447, design F12; widened by REQ-448, then by GH 2524 to
  every seedable name): `tenant_role.name` is unique across kinds, so when a
  `:process_routing_role` row already holds any name the seed would bind, the seed returns
  `{:error, {:role_name_taken_by_routing_role, name}}` (the colliding name, first
  by name order) before writing anything, never silently converting the row.
  """
  @spec seed_default_platform_role_groups(opts :: [prefix: String.t()]) ::
          {:ok, [TenantRole.t()]} | {:error, term()}
  def seed_default_platform_role_groups(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with :ok <- check_guarded_names_free(prefix) do
      seed_names(seedable_role_names(prefix), opts)
    end
  end

  @doc """
  REQ-447: the role names `seed_default_platform_role_groups/1` seeds for the
  tenant schema `prefix`. Every name of `Letflow.Api.Authorization.roles/0`, in
  its declared order, for the platform tenant's schema
  (`Letflow.PlatformTenant.platform_prefix?/1`); every name EXCEPT
  `"PLATFORM_ADMIN"` for any other schema, including a malformed or non-binary
  one and the case where no platform tenant is pinned (fail closed). Pure.
  """
  @spec seedable_role_names(prefix :: term()) :: [String.t()]
  def seedable_role_names(prefix) do
    if PlatformTenant.platform_prefix?(prefix) do
      platform_role_names()
    else
      Enum.reject(platform_role_names(), &(&1 == "PLATFORM_ADMIN"))
    end
  end

  # REQ-447 / REQ-448 guarded TENANT_ADMIN and TENANT_AUDITOR here. GH 2524 widens it to
  # every seedable name: the seed no longer moves a binding, so converting a
  # `:process_routing_role` row with a built-in name to `:platform_role` would hand the
  # group someone chose for it that built-in role. The seed refuses instead.
  @spec check_guarded_names_free(String.t()) ::
          :ok | {:error, {:role_name_taken_by_routing_role, String.t()}}
  defp check_guarded_names_free(prefix) do
    names = seedable_role_names(prefix)

    case Repo.all(
           from(t in TenantRole,
             where: t.name in ^names and t.kind == :process_routing_role,
             order_by: t.name,
             select: t.name
           ),
           prefix: prefix
         ) do
      [name | _rest] -> {:error, {:role_name_taken_by_routing_role, name}}
      [] -> :ok
    end
  end

  @spec seed_names([String.t()], prefix: String.t()) ::
          {:ok, [TenantRole.t()]} | {:error, term()}
  defp seed_names(names, opts) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case ensure_platform_role_binding(name, opts) do
        {:ok, %TenantRole{} = role} -> {:cont, {:ok, [role | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, roles} -> {:ok, Enum.reverse(roles)}
      {:error, _reason} = error -> error
    end
  end

  # GH 2524 (design 4.3): one transaction with the name's row locked, so a concurrent
  # rebind cannot slip between the read and the write. An existing `:platform_role`
  # binding keeps its group (an admin may have rebound it); a `:process_routing_role`
  # row with this name fails closed (check_guarded_names_free/1 normally catches it
  # first); no row binds the group named after the role, as before.
  @spec ensure_platform_role_binding(String.t(), prefix: String.t()) ::
          {:ok, TenantRole.t()} | {:error, term()}
  defp ensure_platform_role_binding(name, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    Repo.transaction(
      fn ->
        # GH 2547 (design 6.6): the tenant admin lock before the role row, so the nested
        # upsert_role/4 re-enters it instead of taking it after a row lock.
        Identity.lock_tenant_admins!(prefix)

        case lock_role_by_name(name, prefix) do
          %TenantRole{kind: :platform_role} = role ->
            # REQ-497 W4 (b): repair-only, inserts a row only for a binding with none.
            :ok = RoleScopeGrants.reconcile_binding!(role, role, prefix)
            role

          %TenantRole{kind: :process_routing_role} ->
            Repo.rollback({:role_name_taken_by_routing_role, name})

          nil ->
            with {:ok, %Group{id: group_id}} <- get_or_create_group_by_name(name, opts),
                 {:ok, %TenantRole{} = role} <-
                   upsert_role(name, :platform_role, group_id, opts) do
              role
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end,
      prefix: prefix
    )
  end

  @doc """
  Get-or-create a `Group` by `name` (ISS-0778 design §3.2). Checks first
  (`Repo.get_by/3`), unlike this module's `insert_or_fetch_*` helpers, which
  always attempt the insert first — this helper's common case
  post-first-provisioning-call is "already exists" (idempotent
  re-invocation), so it checks first. Falls back to an `on_conflict: :nothing`
  insert, and re-fetches by `name` if a concurrent caller won the race —
  mirroring `Letflow.TenantProvisioning`'s `insert_or_fetch_registration/2`
  "insert raced, fetch the winner's row" shape.
  """
  @spec get_or_create_group_by_name(name :: String.t(), opts :: [prefix: String.t()]) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_group_by_name(name, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get_by(Group, [name: name], prefix: prefix) do
      %Group{} = group ->
        {:ok, group}

      nil ->
        insert_group(name, prefix)
    end
  end

  defp insert_group(name, prefix) do
    changeset = Group.create_changeset(%Group{}, %{"name" => name})

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: :name,
           returning: true,
           prefix: prefix
         ) do
      {:ok, %Group{id: id} = group} ->
        if Repo.get(Group, id, prefix: prefix) do
          {:ok, group}
        else
          fetch_group_by_name(name, prefix)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp fetch_group_by_name(name, prefix) do
    case Repo.get_by(Group, [name: name], prefix: prefix) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, :group_not_found}
    end
  end

  @doc """
  Transition-time role resolution: looks up `name`'s bound `group_id`. Meant to be
  called from inside a caller's own `Repo.transaction/1` (a future S3 `applyTransition`)
  — takes no repo/connection argument itself, since Ecto's transaction context is
  ambient to the calling process once invoked from inside that callback.

  Returns `nil` on any lookup failure — unknown `name`, or a genuine DB/connection
  error — never raises, never returns an `{:error, _}` tuple. This is a deliberate
  divergence from this module's other functions: role resolution must never fail a
  transition transaction due to a lookup problem.
  """
  @spec resolve_role_in_tx(name :: String.t()) :: Ecto.UUID.t() | nil
  def resolve_role_in_tx(name) do
    case Repo.get_by(TenantRole, name: name) do
      %TenantRole{group_id: group_id} -> group_id
      nil -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Provisioning-time signal (ISS-0774 AC2, design §2.5): does `user_id` hold at
  least one platform role, given everything they currently hold?

  Computes the same `group_members ⋈ tenant_role` join
  `Letflow.Identity.list_effective_role_names/2` uses but **unfiltered by
  `kind`** (reads both domains), partitions the result, and:

    * `held_platform_roles != []` → `:ok` — the user holds at least one
      platform role, regardless of what else they hold.
    * `held_platform_roles == [] and held_process_routing_roles != []` →
      `{:error, {:missing_platform_role, coverage_gap}}` — names the exact
      gap: this user's only `tenant_role` membership(s) are process-routing
      names, none of which confer any platform permission by themselves.
    * `held_platform_roles == [] and held_process_routing_roles == []` →
      `:ok` — a user with no `tenant_role` membership at all is an ordinary,
      unprovisioned-for-any-role user, not this function's scenario.

  This is a **pure read/check**, not a gate — it does not block
  `Letflow.Identity.add_group_member/3` or any other write path. It exists to
  be called explicitly, by a provisioning script immediately after binding a
  user's group memberships, or by a regression test — not auto-wired into any
  existing call site (design §2.5, OQ-2).
  """
  @spec check_platform_role_coverage(user_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
          :ok | {:error, {:missing_platform_role, coverage_gap()}}
  def check_platform_role_coverage(user_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    query =
      from(gm in GroupMember,
        join: tr in TenantRole,
        on: tr.group_id == gm.group_id,
        where: gm.user_id == ^user_id,
        select: {tr.kind, tr.name},
        distinct: true
      )

    {held_platform_roles, held_process_routing_roles} =
      query
      |> Repo.all(prefix: prefix)
      |> Enum.reduce({[], []}, fn
        {:platform_role, name}, {platform, routing} -> {[name | platform], routing}
        {:process_routing_role, name}, {platform, routing} -> {platform, [name | routing]}
      end)

    case held_platform_roles do
      [] when held_process_routing_roles != [] ->
        {:error,
         {:missing_platform_role,
          %{
            held_process_routing_roles: Enum.sort(held_process_routing_roles),
            held_platform_roles: []
          }}}

      _ ->
        :ok
    end
  end

  @spec do_upsert_role(
          name :: String.t(),
          kind :: kind(),
          group_id :: Ecto.UUID.t(),
          opts :: [prefix: String.t()]
        ) :: {:ok, TenantRole.t()} | {:error, upsert_error()}
  # GH 2547 (design 3.0, 3.4, 6.6): lock order is the tenant admin lock, the role row by
  # name, then the group row FOR UPDATE (taken on BOTH branches, so a concurrent member
  # insert on that group, which needs KEY SHARE, waits for this write or this waits for
  # it). A raise is caught after Ecto's rollback.
  defp do_upsert_role(name, kind, group_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    ctx = AuditContext.from_opts(opts)

    try do
      Repo.transaction(
        fn ->
          Identity.lock_tenant_admins!(prefix)
          _role_or_nil = lock_role_by_name(name, prefix)

          case lock_group_for_update(group_id, prefix) do
            nil -> Repo.rollback(:group_not_found)
            %Group{} -> insert_or_update_role(name, kind, group_id, prefix, ctx)
          end
        end,
        prefix: prefix
      )
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  defp lock_group_for_update(group_id, prefix) do
    Repo.one(from(g in Group, where: g.id == ^group_id, lock: "FOR UPDATE"), prefix: prefix)
  end

  @spec insert_or_update_role(
          name :: String.t(),
          kind :: kind(),
          group_id :: Ecto.UUID.t(),
          prefix :: String.t(),
          ctx :: AuditContext.t()
        ) :: TenantRole.t()
  # GH 2524 (design 4.1): never moves an existing binding. Must run inside a transaction
  # (the row lock is held until it ends).
  defp insert_or_update_role(name, kind, group_id, prefix, ctx) do
    case lock_role_by_name(name, prefix) do
      nil -> insert_role(name, kind, group_id, prefix, ctx)
      %TenantRole{} = existing -> converge_existing_role(existing, kind, group_id, prefix, ctx)
    end
  end

  # TenantRole autogenerates its id client-side, so an insert that lost a race against a
  # concurrent insert of the same name still returns {:ok, struct} with an id that is not
  # in the table. Re-read by name under the lock and compare ids (insert_group/2's
  # precedent); a lost race continues with the winner's row.
  @spec insert_role(String.t(), kind(), Ecto.UUID.t(), String.t(), AuditContext.t()) ::
          TenantRole.t()
  defp insert_role(name, kind, group_id, prefix, ctx) do
    case %TenantRole{}
         |> TenantRole.changeset(%{name: name, group_id: group_id, kind: kind})
         |> Repo.insert(
           conflict_target: :name,
           on_conflict: :nothing,
           returning: true,
           prefix: prefix
         ) do
      {:ok, %TenantRole{id: inserted_id}} ->
        case lock_role_by_name(name, prefix) do
          %TenantRole{id: ^inserted_id} = role ->
            # REQ-497 W1: the grant row in the binding's transaction, before its audit.
            :ok = RoleScopeGrants.reconcile_binding!(nil, role, prefix)
            :ok = audit_binding_write(:created, role, prefix, ctx)
            role

          %TenantRole{} = winner ->
            converge_existing_role(winner, kind, group_id, prefix, ctx)

          nil ->
            Repo.rollback(:unexpected_missing_role)
        end

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @spec converge_existing_role(
          TenantRole.t(),
          kind(),
          Ecto.UUID.t(),
          String.t(),
          AuditContext.t()
        ) ::
          TenantRole.t()
  defp converge_existing_role(%TenantRole{group_id: bound} = role, kind, group_id, prefix, ctx) do
    cond do
      not same_id?(bound, group_id) ->
        Repo.rollback(:role_already_bound)

      role.kind == kind ->
        # REQ-497 W2 (b): repair-only for a platform binding, a no-op for a routing one.
        :ok = RoleScopeGrants.reconcile_binding!(role, role, prefix)
        role

      true ->
        case role |> Ecto.Changeset.change(kind: kind) |> Repo.update(prefix: prefix) do
          {:ok, updated} ->
            # REQ-497 W2 (a): inserts on routing -> platform, removes on platform -> routing.
            :ok = RoleScopeGrants.reconcile_binding!(role, updated, prefix)
            :ok = audit_binding_write({:kind_changed, role.kind}, updated, prefix, ctx)
            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  # GH 2547 (design 3.4, ruling 5 b'): only a grant-relevant binding write is audited,
  # i.e. one over a group with at least one member (any user status). The member list is
  # read after the write, under the group lock, so it is exactly who gains (or, for a
  # kind change, gains/loses) the role at commit. A raise propagates to do_upsert_role/4.
  @spec audit_binding_write(
          event :: :created | {:kind_changed, old_kind :: kind()},
          role :: TenantRole.t(),
          prefix :: String.t(),
          ctx :: AuditContext.t()
        ) :: :ok
  defp audit_binding_write(event, %TenantRole{} = role, prefix, ctx) do
    case group_member_ids(role.group_id, prefix) do
      [] ->
        :ok

      member_ids ->
        attrs =
          Map.merge(binding_audit_states(event, role, member_ids, ctx.source), %{
            actor_id: ctx.actor_id,
            resource_type: "tenant_role",
            resource_id: role.id,
            trace_id: ctx.trace_id
          })

        case Audit.insert_entry(Repo, attrs, prefix) do
          {:ok, _entry} -> :ok
          {:error, reason} -> Repo.rollback({:audit_failed, reason})
        end
    end
  end

  defp binding_audit_states(:created, role, member_ids, source) do
    %{
      action: "role_binding.created",
      before_state: nil,
      after_state:
        Map.merge(role_state(role), %{
          "granted_user_ids" => member_ids,
          "granted_count" => length(member_ids),
          "source" => source
        })
    }
  end

  defp binding_audit_states({:kind_changed, old_kind}, role, member_ids, source) do
    %{
      action: "role_binding.kind_changed",
      before_state: %{role_state(role) | "kind" => Atom.to_string(old_kind)},
      after_state:
        Map.merge(role_state(role), %{
          "affected_user_ids" => member_ids,
          "affected_count" => length(member_ids),
          "source" => source
        })
    }
  end

  @spec group_member_ids(group_id :: Ecto.UUID.t(), prefix :: String.t()) :: [Ecto.UUID.t()]
  defp group_member_ids(group_id, prefix) do
    from(m in GroupMember, where: m.group_id == ^group_id, select: m.user_id, order_by: m.user_id)
    |> Repo.all(prefix: prefix)
  end

  defp lock_role_by_name(name, prefix) do
    Repo.one(from(t in TenantRole, where: t.name == ^name, lock: "FOR UPDATE"), prefix: prefix)
  end

  # Both sides through Ecto.UUID.cast/1: canonical lower-case text compare (INV-10).
  defp same_id?(a, b) do
    case {Ecto.UUID.cast(a), Ecto.UUID.cast(b)} do
      {{:ok, x}, {:ok, x}} -> true
      _ -> false
    end
  end

  @doc """
  GH 2524: the explicit, audited rebind of an existing role binding to another group.

  Runs in one transaction (design `gh2524-role-rebind-explicit.md` section 3, steps 3-9):
  locks the role row by id (`{:error, :role_not_found}`); refuses the `PLATFORM_ADMIN`
  name unless `opts[:platform_scope]` is `true` (default `false`, fail closed;
  `{:error, :platform_admin_outside_platform_tenant}`); validates `reason` (a string,
  trimmed, 1..500 codepoints, no `Cc`/`Cf`/`Zl`/`Zp` character; `{:error, :invalid_reason}`) and
  `group_id` (`{:error, :invalid_group_id}`); reads the target group with `FOR SHARE`
  (`{:error, :group_not_found}`). The same group is a no-op: `{:ok, role}`, nothing
  written, no audit entry. Otherwise it updates `group_id` only (`name` and `kind` stay)
  and appends one `role.rebound` audit entry in the same transaction, carrying the
  actor, the old and new group and the trimmed reason; an audit failure rolls the
  update back and returns `{:error, {:audit_failed, reason}}`.

  `role_id` must already be canonical (the router casts it). `actor_id` may be `nil`
  only for a non-HTTP caller.

  GH 2547 (design 3.4b, 6.6): the transaction first takes
  `Letflow.Identity.lock_tenant_admins!/1`; the `role.rebound` entry carries the trace id
  from `opts[:audit_context]` (the actor stays `attrs.actor_id`).
  """
  @spec rebind_role(
          role_id :: Ecto.UUID.t(),
          group_id :: term(),
          attrs :: %{actor_id: Ecto.UUID.t() | nil, reason: term()},
          opts :: [prefix: String.t(), platform_scope: boolean(), audit_context: AuditContext.t()]
        ) :: {:ok, TenantRole.t()} | {:error, rebind_error()}
  def rebind_role(role_id, group_id, %{actor_id: actor_id, reason: reason}, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    platform_scope? = Keyword.get(opts, :platform_scope, false) == true
    trace_id = AuditContext.from_opts(opts).trace_id

    Repo.transaction(
      fn ->
        Identity.lock_tenant_admins!(prefix)
        role = lock_role_by_id(role_id, prefix) || Repo.rollback(:role_not_found)

        if Authorization.platform_admin_name?(role.name) and not platform_scope? do
          Repo.rollback(:platform_admin_outside_platform_tenant)
        end

        trimmed_reason = validate_reason(reason) || Repo.rollback(:invalid_reason)

        target =
          case Ecto.UUID.cast(group_id) do
            {:ok, canonical} -> canonical
            :error -> Repo.rollback(:invalid_group_id)
          end

        share_lock_group(target, prefix) || Repo.rollback(:group_not_found)

        if same_id?(role.group_id, target) do
          role
        else
          move_role(role, target, actor_id, trimmed_reason, prefix, trace_id)
        end
      end,
      prefix: prefix
    )
  end

  defp move_role(role, target, actor_id, reason, prefix, trace_id) do
    updated =
      role
      |> Ecto.Changeset.change(group_id: target)
      |> Ecto.Changeset.foreign_key_constraint(:group_id)
      |> Repo.update(prefix: prefix)
      |> case do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end

    # REQ-497 W3: the binding's grant rows follow it to the target group (no rescue in 1a).
    :ok = RoleScopeGrants.reconcile_binding!(role, updated, prefix)

    attrs = %{
      actor_id: actor_id,
      action: "role.rebound",
      resource_type: "tenant_role",
      resource_id: role.id,
      before_state: role_state(role),
      after_state: Map.put(role_state(updated), "reason", reason),
      trace_id: trace_id
    }

    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _entry} -> updated
      {:error, audit_error} -> Repo.rollback({:audit_failed, audit_error})
    end
  end

  defp role_state(%TenantRole{} = role) do
    %{"name" => role.name, "kind" => Atom.to_string(role.kind), "group_id" => role.group_id}
  end

  defp lock_role_by_id(role_id, prefix) do
    Repo.one(from(t in TenantRole, where: t.id == ^role_id, lock: "FOR UPDATE"), prefix: prefix)
  end

  defp share_lock_group(group_id, prefix) do
    Repo.one(from(g in Group, where: g.id == ^group_id, lock: "FOR SHARE"), prefix: prefix)
  end

  # nil when the reason is not acceptable; the trimmed reason otherwise.
  defp validate_reason(reason) when is_binary(reason) do
    trimmed = String.trim(reason)

    # Codepoints, not graphemes (String.length/1 counts graphemes).
    if String.valid?(trimmed) and length(String.codepoints(trimmed)) in 1..@max_reason_codepoints and
         not String.match?(trimmed, @reason_forbidden_pattern) do
      trimmed
    end
  end

  defp validate_reason(_reason), do: nil

  defp validate_role_name(name) do
    cond do
      name == "" ->
        {:error, :invalid_role_name}

      String.length(name) > @max_name_codepoints ->
        {:error, :invalid_role_name}

      String.match?(name, @control_char_pattern) ->
        {:error, :invalid_role_name}

      true ->
        :ok
    end
  end
end
