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
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
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
          | Ecto.Changeset.t()

  @type rebind_error ::
          :role_not_found
          | :group_not_found
          | :invalid_group_id
          | :invalid_reason
          | :platform_admin_outside_platform_tenant
          | Ecto.Changeset.t()
          | term()

  @type coverage_gap :: %{
          held_process_routing_roles: [String.t()],
          held_platform_roles: [String.t()]
        }

  @max_name_codepoints 128
  @control_char_pattern ~r/[\x00-\x1F\x7F]/u

  # GH 2524: a rebind reason is free text shown to audit readers. Cc (C0, DEL, C1) and Cf
  # (format/bidi characters such as U+200B..U+200F, U+202A..U+202E, U+2066..U+2069, U+FEFF)
  # are refused so a reason cannot visually spoof an audit reader.
  @max_reason_codepoints 500
  @reason_forbidden_pattern ~r/[\p{Cc}\p{Cf}]/u

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
  """
  @spec upsert_role(
          name :: String.t(),
          kind :: kind(),
          group_id :: Ecto.UUID.t() | String.t(),
          opts :: [prefix: String.t()]
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
  via the existing, unmodified `upsert_role/4` as `kind: :platform_role`.

  Idempotent under re-invocation against a tenant whose `groups`/`tenant_role`
  rows may already exist (design §2.4) — a second call converges on the same
  bindings rather than erroring or duplicating rows. This is what makes
  it safe to call both from the normal onboarding-creation path and from
  `Letflow.TenantOnboarding.recover_provisioning/1`.

  Returns the first `{:error, _}` immediately on either step's failure — no
  partial-success return value. The individual writes already made by this
  call are **not** rolled back (matches this module's and
  `Letflow.TenantOnboarding`'s existing no-compensating-rollback precedent);
  a retried call converges via idempotency instead.

  Name-collision guard (REQ-447, design F12; widened by REQ-448): `tenant_role.name`
  is unique across kinds and `upsert_role/4` overwrites `kind` on conflict, so
  when a `:process_routing_role` row already holds the name `TENANT_ADMIN` or
  `TENANT_AUDITOR` the seed returns
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
        case lock_role_by_name(name, prefix) do
          %TenantRole{kind: :platform_role} = role ->
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
  defp do_upsert_role(name, kind, group_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    Repo.transaction(
      fn ->
        case Repo.get(Group, group_id, prefix: prefix) do
          nil ->
            Repo.rollback(:group_not_found)

          %Group{} ->
            insert_or_update_role(name, kind, group_id, opts)
        end
      end,
      prefix: prefix
    )
  end

  @spec insert_or_update_role(
          name :: String.t(),
          kind :: kind(),
          group_id :: Ecto.UUID.t(),
          opts :: [prefix: String.t()]
        ) :: TenantRole.t()
  # GH 2524 (design 4.1): never moves an existing binding. Must run inside a transaction
  # (the row lock is held until it ends).
  defp insert_or_update_role(name, kind, group_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case lock_role_by_name(name, prefix) do
      nil -> insert_role(name, kind, group_id, prefix)
      %TenantRole{} = existing -> converge_existing_role(existing, kind, group_id, prefix)
    end
  end

  # TenantRole autogenerates its id client-side, so an insert that lost a race against a
  # concurrent insert of the same name still returns {:ok, struct} with an id that is not
  # in the table. Re-read by name under the lock and compare ids (insert_group/2's
  # precedent); a lost race continues with the winner's row.
  defp insert_role(name, kind, group_id, prefix) do
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
          %TenantRole{id: ^inserted_id} = role -> role
          %TenantRole{} = winner -> converge_existing_role(winner, kind, group_id, prefix)
          nil -> Repo.rollback(:unexpected_missing_role)
        end

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp converge_existing_role(%TenantRole{group_id: bound} = role, kind, group_id, prefix) do
    cond do
      not same_id?(bound, group_id) ->
        Repo.rollback(:role_already_bound)

      role.kind == kind ->
        role

      true ->
        case role |> Ecto.Changeset.change(kind: kind) |> Repo.update(prefix: prefix) do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
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
  trimmed, 1..500 codepoints, no `Cc`/`Cf` character; `{:error, :invalid_reason}`) and
  `group_id` (`{:error, :invalid_group_id}`); reads the target group with `FOR SHARE`
  (`{:error, :group_not_found}`). The same group is a no-op: `{:ok, role}`, nothing
  written, no audit entry. Otherwise it updates `group_id` only (`name` and `kind` stay)
  and appends one `role.rebound` audit entry in the same transaction, carrying the
  actor, the old and new group and the trimmed reason; an audit failure rolls the
  update back.

  `role_id` must already be canonical (the router casts it). `actor_id` may be `nil`
  only for a non-HTTP caller.
  """
  @spec rebind_role(
          role_id :: Ecto.UUID.t(),
          group_id :: term(),
          attrs :: %{actor_id: Ecto.UUID.t() | nil, reason: term()},
          opts :: [prefix: String.t(), platform_scope: boolean()]
        ) :: {:ok, TenantRole.t()} | {:error, rebind_error()}
  def rebind_role(role_id, group_id, %{actor_id: actor_id, reason: reason}, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    platform_scope? = Keyword.get(opts, :platform_scope, false) == true

    Repo.transaction(
      fn ->
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
          move_role(role, target, actor_id, trimmed_reason, prefix)
        end
      end,
      prefix: prefix
    )
  end

  defp move_role(role, target, actor_id, reason, prefix) do
    updated =
      role
      |> Ecto.Changeset.change(group_id: target)
      |> Ecto.Changeset.foreign_key_constraint(:group_id)
      |> Repo.update(prefix: prefix)
      |> case do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end

    attrs = %{
      actor_id: actor_id,
      action: "role.rebound",
      resource_type: "tenant_role",
      resource_id: role.id,
      before_state: role_state(role),
      after_state: Map.put(role_state(updated), "reason", reason),
      trace_id: nil
    }

    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _entry} -> updated
      {:error, reason} -> Repo.rollback(reason)
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
