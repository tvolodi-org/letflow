defmodule Letflow.Identity.RoleScopeGrants do
  @moduledoc """
  The single core module that writes and checks `role_scope_grants` (REQ-497 / GH #2533 PR
  1a, decision 0051 D1; design
  `lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` section 2.2).

  ## Writers

  Every binding writer (`RoleRegistry.upsert_role/4`, `RoleRegistry.rebind_role/4`, the
  platform-role seeding, `TenantAdminMigration.run/1`, `Identity.delete_group/2`) calls into
  this module from inside its own transaction, after the tenant admin lock (lock A,
  `Letflow.Identity.lock_tenant_admins!/1`) and before its own audit entry, so the grant row
  commits or rolls back with the binding. Stage 1 has one row shape: a tenant-wide GROUP row
  per `:platform_role` binding. Membership writers never call this module and no user row is
  ever written in stage 1.

  Lock A serialises every group-row write of a tenant, which is what makes
  `repair_group_row!/3`'s check-then-insert race-free; a caller must hold it.

  ## Checks

  `bindings_without_row/1` is T9 (a `:platform_role` binding with no group row of any
  `tenant_wide` value); `orphan_group_rows/1` is its converse.

  Every function takes an explicit `prefix` (INV-1) and binds every value (INV-7). No function
  here writes an audit entry: the binding writer's own entry records the act (0051 D8 lists no
  `grant.*` event for stage 1).
  """

  import Ecto.Query

  alias Letflow.Identity.RoleScopeGrant
  alias Letflow.Identity.TenantRole
  alias Letflow.Repo

  # A constant, nothing interpolated (INV-7): the partial unique index of tenant-wide rows.
  @tenant_wide_conflict_target {:unsafe_fragment,
                                "(principal_type, principal_id, role) WHERE tenant_wide"}

  @typedoc "A T9 result row."
  @type binding_without_row :: %{
          role_id: Ecto.UUID.t(),
          name: String.t(),
          group_id: Ecto.UUID.t()
        }

  @typedoc "An `orphan_group_rows/1` result row."
  @type orphan_row :: %{id: Ecto.UUID.t(), principal_id: Ecto.UUID.t(), role: String.t()}

  # --- writers ---------------------------------------------------------------

  @doc """
  The entry point every binding writer calls with the binding as it was (`before_binding`)
  and as it is after its write (`after_binding`), in the same transaction. `nil` means no
  binding. With P = `kind == :platform_role`:

    * `nil -> P` and `not P -> P`: `ensure_tenant_wide_group_row!/3` (unconditional create);
    * `P -> P`, same group: `repair_group_row!/3` (inserts only when the binding has no row);
    * `P -> P`, other group: `move_group_rows!/4`;
    * `P -> not P` and `P -> nil`: `remove_group_rows!/3`;
    * anything else: nothing.

  Raises `ArgumentError` outside a transaction (the "same transaction" rule, enforced
  structurally) and raises on any DB error, which the caller's transaction turns into a
  rollback.
  """
  @spec reconcile_binding!(
          before_binding :: TenantRole.t() | nil,
          after_binding :: TenantRole.t() | nil,
          prefix :: String.t()
        ) :: :ok
  def reconcile_binding!(before_binding, after_binding, prefix) when is_binary(prefix) do
    ensure_in_transaction!("reconcile_binding!/3")
    _ = do_reconcile(before_binding, after_binding, prefix)
    :ok
  end

  defp do_reconcile(nil, %TenantRole{kind: :platform_role} = new, prefix),
    do: ensure_tenant_wide_group_row!(new.group_id, new.name, prefix)

  defp do_reconcile(
         %TenantRole{kind: :platform_role} = old,
         %TenantRole{kind: :platform_role} = new,
         prefix
       ) do
    if same_id?(old.group_id, new.group_id) do
      repair_group_row!(new.group_id, new.name, prefix)
    else
      move_group_rows!(new.name, old.group_id, new.group_id, prefix)
    end
  end

  defp do_reconcile(%TenantRole{kind: :platform_role} = old, _not_platform_or_nil, prefix),
    do: remove_group_rows!(old.group_id, old.name, prefix)

  defp do_reconcile(%TenantRole{}, %TenantRole{kind: :platform_role} = new, prefix),
    do: ensure_tenant_wide_group_row!(new.group_id, new.name, prefix)

  defp do_reconcile(_before_binding, _after_binding, _prefix), do: :ok

  @doc """
  Inserts the tenant-wide row of (`:group`, `group_id`, `role`) unless one exists
  (`on_conflict: :nothing` on the tenant-wide partial unique index). Unconditional create:
  called only for a binding that becomes `:platform_role` in this write. Ignores scoped rows
  by design.
  """
  @spec ensure_tenant_wide_group_row!(
          group_id :: Ecto.UUID.t(),
          role :: String.t(),
          prefix :: String.t()
        ) :: :inserted | :exists
  def ensure_tenant_wide_group_row!(group_id, role, prefix) when is_binary(prefix) do
    now = DateTime.utc_now()

    row = %{
      id: Ecto.UUID.generate(),
      principal_type: :group,
      principal_id: group_id,
      role: role,
      scope_node_id: nil,
      tenant_wide: true,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(RoleScopeGrant, [row],
           on_conflict: :nothing,
           conflict_target: @tenant_wide_conflict_target,
           prefix: prefix
         ) do
      {1, _} -> :inserted
      {0, _} -> :exists
    end
  end

  @doc """
  The ensure/repair path for an EXISTING binding (SEC B1): inserts the tenant-wide row only
  when (`:group`, `group_id`, `role`) has no row of any `tenant_wide` value, i.e. exactly when
  the binding is in T9's result; otherwise writes nothing and returns `:covered`. A group
  holding only scoped rows is never widened to tenant-wide.

  Precondition: the caller holds the tenant admin lock (every binding writer and the backfill
  take it first). Raises `ArgumentError` outside a transaction.
  """
  @spec repair_group_row!(group_id :: Ecto.UUID.t(), role :: String.t(), prefix :: String.t()) ::
          :inserted | :covered
  def repair_group_row!(group_id, role, prefix) when is_binary(prefix) do
    ensure_in_transaction!("repair_group_row!/3")

    if Repo.exists?(group_rows(group_id, role), prefix: prefix) do
      :covered
    else
      case ensure_tenant_wide_group_row!(group_id, role, prefix) do
        :inserted -> :inserted
        :exists -> :covered
      end
    end
  end

  @doc """
  Deletes every row (tenant-wide and scoped) of (`:group`, `group_id`, `role`): removing the
  binding cascades its rows (0051 D1). Returns the deleted count. Raises `ArgumentError`
  outside a transaction.
  """
  @spec remove_group_rows!(group_id :: Ecto.UUID.t(), role :: String.t(), prefix :: String.t()) ::
          non_neg_integer()
  def remove_group_rows!(group_id, role, prefix) when is_binary(prefix) do
    ensure_in_transaction!("remove_group_rows!/3")
    {count, _} = Repo.delete_all(group_rows(group_id, role), prefix: prefix)
    count
  end

  @doc """
  Re-points every row of (`:group`, `from_group_id`, `role`) to `to_group_id` (the rows follow
  a rebound binding). First deletes any stale row already on (`:group`, `to_group_id`,
  `role`), so the unique indexes cannot fire; when no row moved, repairs the target with
  `repair_group_row!/3`. Returns the moved count. Raises `ArgumentError` outside a
  transaction.
  """
  @spec move_group_rows!(
          role :: String.t(),
          from_group_id :: Ecto.UUID.t(),
          to_group_id :: Ecto.UUID.t(),
          prefix :: String.t()
        ) :: non_neg_integer()
  def move_group_rows!(role, from_group_id, to_group_id, prefix) when is_binary(prefix) do
    ensure_in_transaction!("move_group_rows!/4")
    _cleared = remove_group_rows!(to_group_id, role, prefix)

    {moved, _} =
      Repo.update_all(
        group_rows(from_group_id, role),
        [set: [principal_id: to_group_id, updated_at: DateTime.utc_now()]],
        prefix: prefix
      )

    if moved == 0, do: _ = repair_group_row!(to_group_id, role, prefix)

    moved
  end

  @doc """
  Deletes every row whose principal is the group `group_id` (any role), so no grant outlives
  its principal. Used by `Letflow.Identity.delete_group/2`. Returns the deleted count. Raises
  `ArgumentError` outside a transaction.
  """
  @spec delete_group_principal_rows!(group_id :: Ecto.UUID.t(), prefix :: String.t()) ::
          non_neg_integer()
  def delete_group_principal_rows!(group_id, prefix) when is_binary(prefix) do
    ensure_in_transaction!("delete_group_principal_rows!/2")

    {count, _} =
      Repo.delete_all(
        from(g in RoleScopeGrant,
          where: g.principal_type == ^:group and g.principal_id == ^group_id
        ),
        prefix: prefix
      )

    count
  end

  # --- checks ----------------------------------------------------------------

  @doc """
  T9: every `:platform_role` binding with no `role_scope_grants` row of (`:group`, its
  `group_id`, its `name`), any `tenant_wide` value, ordered by `name`. Read-only, no lock;
  inside a transaction it sees that transaction's uncommitted writes.
  """
  @spec bindings_without_row(prefix :: String.t()) :: [binding_without_row()]
  def bindings_without_row(prefix) when is_binary(prefix) do
    Repo.all(
      from(t in uncovered_bindings(),
        order_by: t.name,
        select: %{role_id: t.id, name: t.name, group_id: t.group_id}
      ),
      prefix: prefix
    )
  end

  @doc "The count of `bindings_without_row/1`. Same predicate and properties."
  @spec bindings_without_row_count(prefix :: String.t()) :: non_neg_integer()
  def bindings_without_row_count(prefix) when is_binary(prefix) do
    Repo.aggregate(uncovered_bindings(), :count, prefix: prefix)
  end

  @doc """
  Group rows with no `:platform_role` binding of that (group, name): the converse of T9.
  Read-only.
  """
  @spec orphan_group_rows(prefix :: String.t()) :: [orphan_row()]
  def orphan_group_rows(prefix) when is_binary(prefix) do
    Repo.all(
      from(g in RoleScopeGrant,
        as: :grant,
        where: g.principal_type == ^:group,
        where:
          not exists(
            from(t in TenantRole,
              where:
                t.kind == ^:platform_role and t.group_id == parent_as(:grant).principal_id and
                  t.name == parent_as(:grant).role
            )
          ),
        order_by: [g.role, g.principal_id],
        select: %{id: g.id, principal_id: g.principal_id, role: g.role}
      ),
      prefix: prefix
    )
  end

  @doc "The count of `principal_type == :user` rows (0 throughout stage 1). Read-only."
  @spec user_row_count(prefix :: String.t()) :: non_neg_integer()
  def user_row_count(prefix) when is_binary(prefix) do
    Repo.aggregate(
      from(g in RoleScopeGrant, where: g.principal_type == ^:user),
      :count,
      prefix: prefix
    )
  end

  # --- private ---------------------------------------------------------------

  defp uncovered_bindings do
    from(t in TenantRole,
      as: :binding,
      where: t.kind == ^:platform_role,
      where:
        not exists(
          from(g in RoleScopeGrant,
            where:
              g.principal_type == ^:group and g.principal_id == parent_as(:binding).group_id and
                g.role == parent_as(:binding).name
          )
        )
    )
  end

  defp group_rows(group_id, role) do
    from(g in RoleScopeGrant,
      where: g.principal_type == ^:group and g.principal_id == ^group_id and g.role == ^role
    )
  end

  defp ensure_in_transaction!(function) do
    if not Repo.in_transaction?() do
      raise ArgumentError, "#{function} must run inside a transaction"
    end
  end

  defp same_id?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same_id?(_a, _b), do: false
end
