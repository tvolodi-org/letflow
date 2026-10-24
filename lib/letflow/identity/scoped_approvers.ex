defmodule Letflow.Identity.ScopedApprovers do
  @moduledoc """
  The "scoped approver" count reported by the `on` gate (REQ-519 2f-a, GH #2535, AC 10; design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 4.5, SEC ruling S-4 and
  open question OQ-4).

  Definitions, over ACTIVE users only (an inactive user cannot act and returns through
  reactivation; the integrity endpoint shows the count):

    * HOLDER(U): U is a member of a group bound as a `:platform_role` to `TASK_WORKER`.
    * SCOPED_TW(U): HOLDER(U), at least one applicable `TASK_WORKER` row of U has
      `tenant_wide = false` (a user-principal row of U, or a group row of a group U belongs to
      that binds `TASK_WORKER`), and NO applicable `TASK_WORKER` row has `tenant_wide = true`.
    * ROUTED(U): U is a member of a group bound as a `:process_routing_role` (any name).
    * `approvers` = |SCOPED_TW and ROUTED|; `task_workers_not_approvers` = |SCOPED_TW and
      not ROUTED| (informational; not a blocker).

  This is the literal AC 10 text ("holds TASK_WORKER only through scoped rows (no tenant-wide
  TASK_WORKER)"). It can only refuse more than the F1-aligned alternative, never allow a
  lockout. A holder with ZERO applicable rows is not a scoped approver (it is denied outright
  and is already counted by gate fact 1, bindings without a row).

  The count no longer blocks the flip. It was the blocker `scoped_approvers_without_task_scope`
  (REQ-519 AC 10) until REQ-532 / GH #3091 wrote `tasks.scope_node_id` from the instance's scope
  node, so a scoped approver sees the tasks of its scope. The count is kept, informational, in the
  flip report and the integrity report. It is a plain read (two queries, bound values only,
  INV-7); inside the `on` gate it runs after lock A and the scope-tree lock S, and every input is
  written under lock A.
  """

  import Ecto.Query

  alias Letflow.Identity
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleScopeGrant
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo

  @role "TASK_WORKER"

  @type counts :: %{
          approvers: non_neg_integer(),
          task_workers_not_approvers: non_neg_integer()
        }

  @doc """
  The scoped approver counts for the tenant schema `prefix` (see the moduledoc). Read-only,
  no lock, no audit.
  """
  @spec count(prefix :: String.t()) :: counts()
  def count(prefix) when is_binary(prefix) do
    base = scoped_task_workers()

    routed =
      from(gm in GroupMember,
        join: tr in TenantRole,
        on: tr.group_id == gm.group_id,
        where: gm.user_id == parent_as(:u).id and tr.kind == :process_routing_role,
        select: 1
      )

    approvers =
      base
      |> where([], exists(routed))
      |> select([u], count(u.id, :distinct))
      |> Repo.one(prefix: prefix)

    not_approvers =
      base
      |> where([], not exists(routed))
      |> select([u], count(u.id, :distinct))
      |> Repo.one(prefix: prefix)

    %{approvers: approvers, task_workers_not_approvers: not_approvers}
  end

  # SCOPED_TW(U): active holder, a scoped applicable row, no tenant-wide applicable row.
  defp scoped_task_workers do
    holder =
      from(gm in GroupMember,
        join: tr in TenantRole,
        on: tr.group_id == gm.group_id,
        where: gm.user_id == parent_as(:u).id and tr.name == ^@role and tr.kind == :platform_role,
        select: 1
      )

    scoped_user_row = user_rows(false)
    scoped_group_row = group_rows(false)
    wide_user_row = user_rows(true)
    wide_group_row = group_rows(true)

    from(u in User,
      as: :u,
      where: ^Identity.active_user_condition(:u),
      where: exists(holder),
      where: exists(scoped_user_row) or exists(scoped_group_row),
      where: not (exists(wide_user_row) or exists(wide_group_row))
    )
  end

  defp user_rows(tenant_wide?) do
    from(g in RoleScopeGrant,
      where:
        g.role == ^@role and g.tenant_wide == ^tenant_wide? and g.principal_type == :user and
          g.principal_id == parent_as(:u).id,
      select: 1
    )
  end

  # A group row of a group the user belongs to AND that group binds the role as a platform role.
  defp group_rows(tenant_wide?) do
    from(gm in GroupMember,
      join: g in RoleScopeGrant,
      on: g.principal_type == :group and g.principal_id == gm.group_id,
      join: tr in TenantRole,
      on: tr.group_id == gm.group_id,
      where:
        gm.user_id == parent_as(:u).id and g.role == ^@role and
          g.tenant_wide == ^tenant_wide? and tr.name == ^@role and tr.kind == :platform_role,
      select: 1
    )
  end
end
