defmodule Letflow.Identity.MembershipScope do
  @moduledoc """
  A user's effective scope per platform role, and the difference between two such snapshots
  (REQ-519 2e-b, GH #2535, design `lib/letflow/design/req519-enforced-writers-and-flag-on.md`
  sections 3.8 and 3.9, decision 0051 D1/D8).

  Used by two callers: `Letflow.Identity` (the `scope_delta` of `group_member.added` /
  `group_member.removed`) and `Letflow.Identity.SyncScopeGuard` (the no-widening test of the
  IdP sync). Read-only: no write, no lock; the caller holds lock A.

  A snapshot maps each role the user holds THROUGH a group (the coarse rule of
  `Letflow.Identity.list_effective_role_names/2`) to its scope, computed with the pure
  `Letflow.Api.Scope.effective_from_rows/1` over the applicable grant rows. A role that is not
  held is absent and reads as `:deny`.
  """

  alias Letflow.Api.Scope
  alias Letflow.Identity
  alias Letflow.Identity.RoleScopeGrants

  @max_node_ids 50

  @type scope :: :deny | :tenant_wide | {:nodes, [String.t()]}
  @type snapshot :: %{optional(String.t()) => scope()}
  @type delta_entry :: %{String.t() => String.t() | map()}

  @typedoc """
  The user's held roles and applicable grant rows, read once (`read/2`). Every snapshot of one
  step is built from one read, so a step that needs several of them does not repeat the reads.
  """
  @type read :: %{held: [String.t()], rows: [map()]}

  @doc """
  Reads the user's held roles and applicable grant rows: two reads. The caller holds lock A and
  must not write between this read and the snapshots built from it.
  """
  @spec read(user_id :: Ecto.UUID.t(), prefix :: String.t()) :: read()
  def read(user_id, prefix) when is_binary(prefix) do
    %{
      held: Identity.list_effective_role_names(user_id, prefix: prefix),
      rows: RoleScopeGrants.applicable_rows_for_user(user_id, prefix)
    }
  end

  @doc """
  The user's current scope per held role, from one read (`read/2`). Two reads.
  """
  @spec snapshot(user_id :: Ecto.UUID.t(), prefix :: String.t()) :: snapshot()
  def snapshot(user_id, prefix) when is_binary(prefix),
    do: user_id |> read(prefix) |> snapshot_of()

  @doc "The snapshot of a read: the same map `snapshot/2` returns, with no read."
  @spec snapshot_of(read()) :: snapshot()
  def snapshot_of(%{held: held, rows: rows}), do: build(held, rows)

  @doc """
  The scope of the user's applicable grant rows per role, ignoring whether the role is held
  (a scoped user-principal row exists for a role the user holds through no group yet). Used to
  tell "already holds scoped rows" from "holds none" when classifying a suppressed sync.
  """
  @spec row_scopes(user_id :: Ecto.UUID.t(), prefix :: String.t()) :: snapshot()
  def row_scopes(user_id, prefix) when is_binary(prefix),
    do: user_id |> read(prefix) |> row_scopes_of()

  @doc "The row scopes of a read: the same map `row_scopes/2` returns, with no read."
  @spec row_scopes_of(read()) :: snapshot()
  def row_scopes_of(%{rows: rows}), do: build(rows |> Enum.map(& &1.role) |> Enum.uniq(), rows)

  @doc """
  The snapshot the user WOULD have if added to a group that binds `bound_roles` as platform
  roles, computed in memory: nothing is written. `group_id`'s own rows for each bound role are
  added to the user's applicable rows and the bound roles are added to the held set.
  """
  @spec snapshot_if_added(
          user_id :: Ecto.UUID.t(),
          group_id :: Ecto.UUID.t(),
          bound_roles :: [String.t()],
          prefix :: String.t()
        ) :: snapshot()
  def snapshot_if_added(user_id, group_id, bound_roles, prefix) when is_binary(prefix) do
    user_id |> read(prefix) |> snapshot_if_added_to(group_id, bound_roles, prefix)
  end

  @doc "`snapshot_if_added/4` from a read the caller already holds (no read of the user's roles)."
  @spec snapshot_if_added_to(
          read(),
          group_id :: Ecto.UUID.t(),
          bound_roles :: [String.t()],
          prefix :: String.t()
        ) :: snapshot()
  def snapshot_if_added_to(%{held: held, rows: rows}, group_id, bound_roles, prefix) do
    group_rows =
      Enum.flat_map(bound_roles, fn role ->
        :group
        |> RoleScopeGrants.rows_for(group_id, role, prefix)
        |> Enum.map(&%{role: role, tenant_wide: &1.tenant_wide, scope_node_id: &1.scope_node_id})
      end)

    build(Enum.uniq(held ++ bound_roles), rows ++ group_rows)
  end

  defp build(held_roles, rows) do
    by_role = Enum.group_by(rows, & &1.role)

    Map.new(held_roles, fn role ->
      {role, by_role |> Map.get(role, []) |> Scope.effective_from_rows()}
    end)
  end

  @doc """
  The roles whose scope differs between the two snapshots, sorted by role name, as
  `%{"role" => name, "from" => rendered, "to" => rendered}`. A role absent from a snapshot
  counts as `:deny`.
  """
  @spec delta(before_snapshot :: snapshot(), after_snapshot :: snapshot()) :: [delta_entry()]
  def delta(before_snapshot, after_snapshot) do
    (Map.keys(before_snapshot) ++ Map.keys(after_snapshot))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn role ->
      from = Map.get(before_snapshot, role, :deny)
      to = Map.get(after_snapshot, role, :deny)

      if from == to,
        do: [],
        else: [%{"role" => role, "from" => render(from), "to" => render(to)}]
    end)
  end

  @doc """
  True when the change makes the user tenant-wide for a role it was not tenant-wide for.
  """
  @spec would_widen?(before_scope :: scope(), after_scope :: scope()) :: boolean()
  def would_widen?(before_scope, :tenant_wide), do: before_scope != :tenant_wide
  def would_widen?(_before_scope, _after_scope), do: false

  @doc """
  Payload form of a scope: `"deny"`, `"tenant_wide"`, or `%{"nodes" => ids, "count" => n}`
  with at most #{@max_node_ids} org-unit record ids (sorted); ids only, no names or paths.
  """
  @spec render(scope()) :: String.t() | map()
  def render(:deny), do: "deny"
  def render(:tenant_wide), do: "tenant_wide"

  def render({:nodes, ids}) do
    sorted = Enum.sort(ids)
    %{"nodes" => Enum.take(sorted, @max_node_ids), "count" => length(sorted)}
  end
end
