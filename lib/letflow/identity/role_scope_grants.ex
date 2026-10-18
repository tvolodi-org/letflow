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

  ## Stage 2 admin plane (REQ-517)

  `insert_scoped/5`, `insert_tenant_wide/4`, `delete_row!/2` and `delete_scoped_rows!/4` are
  the row writers behind `Letflow.Identity.ScopedGrants` (the only caller); `get_row/2`,
  `rows_for/4`, `list_page/4`, `effective?/4` and `references_node?/2` are its readers. This
  module stays the single writer of the table
  (`mix letflow.check_role_scope_grants_writers`).

  ## Checks

  `bindings_without_row/1` is T9 (a `:platform_role` binding with no group row of any
  `tenant_wide` value); `orphan_group_rows/1` is its converse.

  Every function takes an explicit `prefix` (INV-1) and binds every value (INV-7). No function
  here writes an audit entry: the binding writer's own entry records the act (0051 D8 lists no
  `grant.*` event for stage 1).
  """

  import Ecto.Query

  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleScopeGrant
  alias Letflow.Identity.TenantRole
  alias Letflow.Repo
  alias Letflow.ScopeEnforcement

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

  @typedoc """
  The result of `reconcile_binding!/3` (REQ-519 2e-a): `:ok` (the grant rows are as the
  binding needs), `{:skipped, :enforced}` (the tenant is `on`, so NO row was written and the
  binding is left without one, reported by the caller), or `{:refused, :scope_required}` (the
  tenant is `on` and the write would create a binding that needs a tenant-wide row; the caller
  rolls back).
  """
  @type reconcile_result :: :ok | {:skipped, :enforced} | {:refused, :scope_required}

  @doc """
  The entry point every binding writer calls with the binding as it was (`before_binding`)
  and as it is after its write (`after_binding`), in the same transaction. `nil` means no
  binding. With P = `kind == :platform_role` and the tenant mode M read ONCE under lock A
  (`Letflow.ScopeEnforcement.mode_under_lock!/1`):

    * `nil -> P` and `not P -> P`: M `off`/`shadow`: `ensure_tenant_wide_group_row!/3`
      (unconditional create); M `on`: `{:refused, :scope_required}`, nothing written;
    * `P -> P`, same group: `repair_group_row!/3` (inserts only when the binding has no row);
      in `on` it never inserts and answers `{:skipped, :enforced}` when the binding has no row;
    * `P -> P`, other group: `move_group_rows!/4`; in `on` moved rows are `:ok`, none moved is
      `{:skipped, :enforced}` (no repair fallback);
    * `P -> not P` and `P -> nil`: `remove_group_rows!/3` (removal never widens, every mode);
    * anything else: nothing.

  The mode is read only by the clauses that could insert or widen a row, so removals never
  depend on it. In `off` and `shadow` the result is always `:ok`. Raises `ArgumentError` outside a
  transaction (the "same transaction" rule, enforced structurally), raises on any DB error and
  raises `Letflow.ScopeEnforcement.ModeUnavailableError` when the mode cannot be read; the
  caller's transaction turns every raise into a rollback.
  """
  @spec reconcile_binding!(
          before_binding :: TenantRole.t() | nil,
          after_binding :: TenantRole.t() | nil,
          prefix :: String.t()
        ) :: reconcile_result()
  def reconcile_binding!(before_binding, after_binding, prefix) when is_binary(prefix) do
    ensure_in_transaction!("reconcile_binding!/3")
    do_reconcile(before_binding, after_binding, prefix)
  end

  # The mode is read LAZILY (once, under lock A) and only by the clauses that could insert or
  # widen a row; a pure removal (`P -> not P`, `P -> nil`) and the no-op clause never read it,
  # so an unreadable mode cannot fail a removal.
  defp do_reconcile(nil, %TenantRole{kind: :platform_role} = new, prefix),
    do: create_or_refuse(new, prefix)

  defp do_reconcile(
         %TenantRole{kind: :platform_role} = old,
         %TenantRole{kind: :platform_role} = new,
         prefix
       ) do
    mode = ScopeEnforcement.mode_under_lock!(prefix)

    if same_id?(old.group_id, new.group_id) do
      case repair_row!(new.group_id, new.name, prefix, mode) do
        {:skipped, :enforced} = skipped -> skipped
        _inserted_or_covered -> :ok
      end
    else
      case move_rows!(new.name, old.group_id, new.group_id, prefix, mode) do
        {:skipped, :enforced} = skipped -> skipped
        {:moved, _count} -> :ok
      end
    end
  end

  defp do_reconcile(%TenantRole{kind: :platform_role} = old, _not_platform_or_nil, prefix) do
    _ = remove_group_rows!(old.group_id, old.name, prefix)
    :ok
  end

  defp do_reconcile(%TenantRole{}, %TenantRole{kind: :platform_role} = new, prefix),
    do: create_or_refuse(new, prefix)

  defp do_reconcile(_before_binding, _after_binding, _prefix), do: :ok

  defp create_or_refuse(%TenantRole{} = new, prefix) do
    case ScopeEnforcement.mode_under_lock!(prefix) do
      :on ->
        {:refused, :scope_required}

      _off_or_shadow ->
        _ = insert_tenant_wide_row!(new.group_id, new.name, prefix)
        :ok
    end
  end

  @doc """
  Inserts the tenant-wide row of (`:group`, `group_id`, `role`) unless one exists
  (`on_conflict: :nothing` on the tenant-wide partial unique index). Unconditional create:
  called only for a binding that becomes `:platform_role` in this write. Ignores scoped rows
  by design. REQ-519: in an `on` tenant it inserts NOTHING and answers
  `{:skipped, :enforced}` (it reads the mode itself, so no caller can bypass the check; the
  explicit make-tenant-wide act is `insert_tenant_wide/4`). Raises `ArgumentError` outside a
  transaction.
  """
  @spec ensure_tenant_wide_group_row!(
          group_id :: Ecto.UUID.t(),
          role :: String.t(),
          prefix :: String.t()
        ) :: :inserted | :exists | {:skipped, :enforced}
  def ensure_tenant_wide_group_row!(group_id, role, prefix) when is_binary(prefix) do
    ensure_in_transaction!("ensure_tenant_wide_group_row!/3")

    case ScopeEnforcement.mode_under_lock!(prefix) do
      :on -> {:skipped, :enforced}
      _off_or_shadow -> insert_tenant_wide_row!(group_id, role, prefix)
    end
  end

  defp insert_tenant_wide_row!(group_id, role, prefix) do
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
  holding only scoped rows is never widened to tenant-wide. REQ-519: in an `on` tenant it never
  inserts; a binding with no row answers `{:skipped, :enforced}`.

  Precondition: the caller holds the tenant admin lock (every binding writer and the backfill
  take it first). Raises `ArgumentError` outside a transaction.
  """
  @spec repair_group_row!(group_id :: Ecto.UUID.t(), role :: String.t(), prefix :: String.t()) ::
          :inserted | :covered | {:skipped, :enforced}
  def repair_group_row!(group_id, role, prefix) when is_binary(prefix) do
    ensure_in_transaction!("repair_group_row!/3")
    repair_row!(group_id, role, prefix, ScopeEnforcement.mode_under_lock!(prefix))
  end

  defp repair_row!(group_id, role, prefix, mode) do
    cond do
      Repo.exists?(group_rows(group_id, role), prefix: prefix) -> :covered
      mode == :on -> {:skipped, :enforced}
      true -> repair_insert!(group_id, role, prefix)
    end
  end

  defp repair_insert!(group_id, role, prefix) do
    case insert_tenant_wide_row!(group_id, role, prefix) do
      :inserted -> :inserted
      :exists -> :covered
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
  `role`), so the unique indexes cannot fire; in `off`/`shadow`, when no row moved, repairs
  the target. Returns `{:moved, count}`; in an `on` tenant, when no row moved there is NO repair
  fallback and the answer is `{:skipped, :enforced}`. Raises `ArgumentError` outside a
  transaction.
  """
  @spec move_group_rows!(
          role :: String.t(),
          from_group_id :: Ecto.UUID.t(),
          to_group_id :: Ecto.UUID.t(),
          prefix :: String.t()
        ) :: {:moved, non_neg_integer()} | {:skipped, :enforced}
  def move_group_rows!(role, from_group_id, to_group_id, prefix) when is_binary(prefix) do
    ensure_in_transaction!("move_group_rows!/4")

    move_rows!(
      role,
      from_group_id,
      to_group_id,
      prefix,
      ScopeEnforcement.mode_under_lock!(prefix)
    )
  end

  defp move_rows!(role, from_group_id, to_group_id, prefix, mode) do
    _cleared = remove_group_rows!(to_group_id, role, prefix)

    {moved, _} =
      Repo.update_all(
        group_rows(from_group_id, role),
        [set: [principal_id: to_group_id, updated_at: DateTime.utc_now()]],
        prefix: prefix
      )

    cond do
      moved > 0 ->
        {:moved, moved}

      mode == :on ->
        {:skipped, :enforced}

      true ->
        _ = repair_insert!(to_group_id, role, prefix)
        {:moved, 0}
    end
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

  # --- REQ-517 stage 2 admin-plane writers -----------------------------------
  #
  # The scoped / tenant-wide row writers behind `Letflow.Identity.ScopedGrants`. Every one runs
  # inside the caller's transaction under lock A; a Postgres constraint error aborts that
  # transaction, which every caller rolls back on.

  @typedoc "A principal type of a grant row."
  @type principal_type :: :user | :group

  @doc """
  Inserts one scoped row (`tenant_wide: false`). `{:error, :grant_exists}` when the scoped
  unique index fires, `{:error, :invalid_scope_node}` when the scope-node foreign key fires.
  Raises `ArgumentError` outside a transaction, and on any other changeset error (the caller
  validated the role and principal first).
  """
  @spec insert_scoped(
          principal_type(),
          principal_id :: Ecto.UUID.t(),
          role :: String.t(),
          scope_node_id :: String.t(),
          prefix :: String.t()
        ) :: {:ok, RoleScopeGrant.t()} | {:error, :grant_exists | :invalid_scope_node}
  def insert_scoped(principal_type, principal_id, role, scope_node_id, prefix)
      when is_binary(prefix) do
    ensure_in_transaction!("insert_scoped/5")

    attrs = %{
      principal_type: principal_type,
      principal_id: principal_id,
      role: role,
      scope_node_id: scope_node_id,
      tenant_wide: false
    }

    case Repo.insert(RoleScopeGrant.changeset(%RoleScopeGrant{}, attrs), prefix: prefix) do
      {:ok, row} -> {:ok, row}
      {:error, changeset} -> {:error, scoped_insert_error!(changeset)}
    end
  end

  @doc """
  Inserts the tenant-wide row of a principal and role. `{:error, :tenant_wide_row_exists}`
  when the tenant-wide unique index fires. Raises `ArgumentError` outside a transaction.
  """
  @spec insert_tenant_wide(
          principal_type(),
          principal_id :: Ecto.UUID.t(),
          role :: String.t(),
          prefix :: String.t()
        ) :: {:ok, RoleScopeGrant.t()} | {:error, :tenant_wide_row_exists}
  def insert_tenant_wide(principal_type, principal_id, role, prefix) when is_binary(prefix) do
    ensure_in_transaction!("insert_tenant_wide/4")

    attrs = %{
      principal_type: principal_type,
      principal_id: principal_id,
      role: role,
      scope_node_id: nil,
      tenant_wide: true
    }

    case Repo.insert(RoleScopeGrant.changeset(%RoleScopeGrant{}, attrs), prefix: prefix) do
      {:ok, row} ->
        {:ok, row}

      {:error, changeset} ->
        if constraint_error?(changeset, "role_scope_grants_tenant_wide_uniq") do
          {:error, :tenant_wide_row_exists}
        else
          raise ArgumentError, "insert_tenant_wide/4: unexpected changeset error"
        end
    end
  end

  @doc "Deletes one row by id. Raises `ArgumentError` outside a transaction."
  @spec delete_row!(row_id :: Ecto.UUID.t(), prefix :: String.t()) :: :ok
  def delete_row!(row_id, prefix) when is_binary(prefix) do
    ensure_in_transaction!("delete_row!/2")

    {_count, _} =
      Repo.delete_all(from(g in RoleScopeGrant, where: g.id == ^row_id), prefix: prefix)

    :ok
  end

  @doc """
  Deletes every SCOPED row of (principal, role) and returns the removed ids, sorted. Raises
  `ArgumentError` outside a transaction.
  """
  @spec delete_scoped_rows!(
          principal_type(),
          principal_id :: Ecto.UUID.t(),
          role :: String.t(),
          prefix :: String.t()
        ) :: [Ecto.UUID.t()]
  def delete_scoped_rows!(principal_type, principal_id, role, prefix) when is_binary(prefix) do
    ensure_in_transaction!("delete_scoped_rows!/4")

    {_count, ids} =
      Repo.delete_all(
        from(g in principal_role_rows(principal_type, principal_id, role),
          where: not g.tenant_wide,
          select: g.id
        ),
        prefix: prefix
      )

    Enum.sort(ids)
  end

  # --- REQ-517 stage 2 admin-plane readers -----------------------------------

  @doc "One row by id, or `nil`. Plain read."
  @spec get_row(row_id :: Ecto.UUID.t(), prefix :: String.t()) :: RoleScopeGrant.t() | nil
  def get_row(row_id, prefix) when is_binary(prefix),
    do: Repo.get(RoleScopeGrant, row_id, prefix: prefix)

  @doc "Every row of (principal, role), ordered by `(inserted_at, id)`. Plain read."
  @spec rows_for(
          principal_type(),
          principal_id :: Ecto.UUID.t(),
          role :: String.t(),
          prefix :: String.t()
        ) :: [RoleScopeGrant.t()]
  def rows_for(principal_type, principal_id, role, prefix) when is_binary(prefix) do
    Repo.all(
      from(g in principal_role_rows(principal_type, principal_id, role),
        order_by: [asc: g.inserted_at, asc: g.id]
      ),
      prefix: prefix
    )
  end

  @doc """
  True when any row names the scope node `node_id`: the retire guard's read (AC 5). Plain
  read; the retiring caller holds the node row lock.
  """
  @spec references_node?(node_id :: String.t(), prefix :: String.t()) :: boolean()
  def references_node?(node_id, prefix) when is_binary(node_id) and is_binary(prefix) do
    Repo.exists?(from(g in RoleScopeGrant, where: g.scope_node_id == ^node_id), prefix: prefix)
  end

  @doc """
  True when the row currently applies to someone: a `:group` principal bound to `role` as a
  `:platform_role`; a `:user` principal who is a member of a group bound to `role` as a
  `:platform_role`. Plain read.
  """
  @spec effective?(
          principal_type(),
          principal_id :: Ecto.UUID.t(),
          role :: String.t(),
          prefix :: String.t()
        ) :: boolean()
  def effective?(:group, group_id, role, prefix) when is_binary(prefix) do
    Repo.exists?(
      from(t in TenantRole,
        where: t.group_id == ^group_id and t.name == ^role and t.kind == ^:platform_role
      ),
      prefix: prefix
    )
  end

  def effective?(:user, user_id, role, prefix) when is_binary(prefix) do
    Repo.exists?(
      from(m in GroupMember,
        join: t in TenantRole,
        on: t.group_id == m.group_id,
        where: m.user_id == ^user_id and t.name == ^role and t.kind == ^:platform_role
      ),
      prefix: prefix
    )
  end

  @typedoc "Filters of `list_page/4`: any subset of the three keys."
  @type list_filters :: %{
          optional(:principal_type) => principal_type(),
          optional(:principal_id) => Ecto.UUID.t(),
          optional(:role) => String.t()
        }

  @doc """
  One page of rows ordered by `(inserted_at, id)` ascending; `limit + 1` rows are read to
  find the next key. `effective` is computed in the same select by two `exists` subqueries
  (no N+1). Filters are bound parameters. `after_key` is the previous page's `next_key`.
  """
  @spec list_page(
          list_filters(),
          limit :: pos_integer(),
          after_key :: {DateTime.t(), Ecto.UUID.t()} | nil,
          prefix :: String.t()
        ) :: %{
          rows: [%{row: RoleScopeGrant.t(), effective: boolean()}],
          next_key: {DateTime.t(), Ecto.UUID.t()} | nil
        }
  def list_page(filters, limit, after_key, prefix)
      when is_map(filters) and is_integer(limit) and limit > 0 and is_binary(prefix) do
    group_bound =
      from(t in TenantRole,
        where:
          t.group_id == parent_as(:grant).principal_id and t.name == parent_as(:grant).role and
            t.kind == ^:platform_role
      )

    user_held =
      from(m in GroupMember,
        join: t in TenantRole,
        on: t.group_id == m.group_id,
        where:
          m.user_id == parent_as(:grant).principal_id and t.name == parent_as(:grant).role and
            t.kind == ^:platform_role
      )

    query =
      from(g in RoleScopeGrant,
        as: :grant,
        order_by: [asc: g.inserted_at, asc: g.id],
        limit: ^(limit + 1),
        select: {
          g,
          (g.principal_type == ^:group and exists(group_bound)) or
            (g.principal_type == ^:user and exists(user_held))
        }
      )
      |> filter_list(filters)
      |> after_list(after_key)

    {page, rest} = query |> Repo.all(prefix: prefix) |> Enum.split(limit)

    next_key =
      case {rest, List.last(page)} do
        {[_ | _], {last, _effective}} -> {last.inserted_at, last.id}
        _no_more -> nil
      end

    %{
      rows: Enum.map(page, fn {row, effective} -> %{row: row, effective: effective} end),
      next_key: next_key
    }
  end

  defp filter_list(query, filters) do
    Enum.reduce(filters, query, fn
      {:principal_type, type}, q -> where(q, [g], g.principal_type == ^type)
      {:principal_id, id}, q -> where(q, [g], g.principal_id == ^id)
      {:role, role}, q -> where(q, [g], g.role == ^role)
    end)
  end

  defp after_list(query, nil), do: query

  defp after_list(query, {%DateTime{} = ts, id}) do
    where(
      query,
      [g],
      g.inserted_at > ^ts or (g.inserted_at == ^ts and g.id > type(^id, :binary_id))
    )
  end

  defp principal_role_rows(principal_type, principal_id, role) do
    from(g in RoleScopeGrant,
      where:
        g.principal_type == ^principal_type and g.principal_id == ^principal_id and
          g.role == ^role
    )
  end

  defp scoped_insert_error!(changeset) do
    cond do
      constraint_error?(changeset, "role_scope_grants_scope_node_id_fkey") ->
        :invalid_scope_node

      constraint_error?(changeset, "role_scope_grants_scoped_uniq") ->
        :grant_exists

      true ->
        raise ArgumentError, "insert_scoped/5: unexpected changeset error"
    end
  end

  # A mapped constraint error carries the constraint name in its options, whichever field
  # the changeset attached it to.
  defp constraint_error?(changeset, name) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint_name) == name
    end)
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

  @doc """
  REQ-497 PR 1b (0051 D1 step 2, D3; design `req497-1b-allowed-flag-shadow-n1.md` 1.3): the
  APPLICABLE rows of `user_id` in one query. A `:user` row of the user applies; a `:group`
  row applies only when the user is a member of that group AND that group is bound to the
  row's role as a `:platform_role`, i.e. the user holds the role THROUGH that group (a stray
  row of a group for a role it does not bind never applies). Selected columns only, no ids.
  Read-only; every value bound (INV-7), explicit `prefix` (INV-1). Raises on a DB error.
  """
  @spec applicable_rows_for_user(user_id :: Ecto.UUID.t(), prefix :: String.t()) :: [
          %{
            principal_type: :user | :group,
            role: String.t(),
            tenant_wide: boolean(),
            scope_node_id: String.t() | nil
          }
        ]
  def applicable_rows_for_user(user_id, prefix) when is_binary(prefix) do
    held_through_group =
      from(m in GroupMember,
        join: t in TenantRole,
        on: t.group_id == m.group_id,
        where:
          m.user_id == ^user_id and m.group_id == parent_as(:grant).principal_id and
            t.name == parent_as(:grant).role and t.kind == ^:platform_role
      )

    Repo.all(
      from(g in RoleScopeGrant,
        as: :grant,
        where:
          (g.principal_type == ^:user and g.principal_id == ^user_id) or
            (g.principal_type == ^:group and exists(held_through_group)),
        select: %{
          principal_type: g.principal_type,
          role: g.role,
          tenant_wide: g.tenant_wide,
          scope_node_id: g.scope_node_id
        }
      ),
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
