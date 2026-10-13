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
          | Ecto.Changeset.t()

  @type coverage_gap :: %{
          held_process_routing_roles: [String.t()],
          held_platform_roles: [String.t()]
        }

  @max_name_codepoints 128
  @control_char_pattern ~r/[\x00-\x1F\x7F]/u

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
  group and upserts on `name` conflict (updating `group_id` and `kind`) inside one
  transaction.

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

  # REQ-447 / REQ-448: the built-in names introduced after ISS-0774 classified
  # existing rows, so a `:process_routing_role` row may still hold them.
  @guarded_role_names ["TENANT_ADMIN", "TENANT_AUDITOR"]

  @spec check_guarded_names_free(String.t()) ::
          :ok | {:error, {:role_name_taken_by_routing_role, String.t()}}
  defp check_guarded_names_free(prefix) do
    names = @guarded_role_names

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
      with {:ok, %Group{id: group_id}} <- get_or_create_group_by_name(name, opts),
           {:ok, %TenantRole{} = role} <- upsert_role(name, :platform_role, group_id, opts) do
        {:cont, {:ok, [role | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, roles} -> {:ok, Enum.reverse(roles)}
      {:error, _reason} = error -> error
    end
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
  defp insert_or_update_role(name, kind, group_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case %TenantRole{}
         |> TenantRole.changeset(%{name: name, group_id: group_id, kind: kind})
         |> Repo.insert(
           conflict_target: :name,
           on_conflict: [set: [group_id: group_id, kind: kind]],
           returning: true,
           prefix: prefix
         ) do
      {:ok, role} -> role
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

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
