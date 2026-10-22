defmodule Letflow.Identity.SyncScopeGuard do
  @moduledoc """
  The no-widening rule of the IdP role-claims sync in a tenant whose scope enforcement is `on`
  (REQ-519 2e-b, GH #2535, design `lib/letflow/design/req519-enforced-writers-and-flag-on.md`
  section 3.9, decision 0051 D1/N3, SEC rulings S-2 and C-3 of
  `handoffs/WF02-REQ519-ENFORCED-WRITERS-20261018/step-04-security-reviewer-design.json`).

  `Letflow.Identity.sync_role_claims_report/3` calls this module from its `:memberships` step,
  AFTER lock A and the mode read. Two parts:

    * `bound_platform_roles/2` -- the platform roles each candidate group binds, read AFTER
      lock A inside the step (SEC C-3), never carried from the pre-lock resolve. A
      `:process_routing_role` binding is ignored, so a routing-role-only group never widens.
    * `evaluate/4` -- for one candidate group the user is not yet a member of: would adding the
      group make the user `:tenant_wide` for a role bound to it that the user is not already
      tenant-wide for? If so the membership is SUPPRESSED (the whole group is withheld when ANY
      bound role would widen; a membership cannot be split by role). A suppressed (group,
      role) is `:has_scoped_rows` (audit `grant.sync_suppressed`) when the user already holds scoped rows for the role and
      `:no_scoped_rows` (audit `binding.pending_scope`) when the user holds none.

  Classification of a user whose ONLY row for the role is a tenant-wide USER-principal row
  while the role is not held through any group: the membership still widens (the held-aware
  before scope is `:deny`, the after scope `:tenant_wide`), and the user holds no SCOPED rows,
  so the pair is `:no_scoped_rows` (audit `binding.pending_scope`), not
  `:has_scoped_rows`. Only a scoped (node) row, user or group principal, selects
  `:has_scoped_rows`.

  `record/5` writes the audit entry per suppressed role, `grant.sync_suppressed` or
  `binding.pending_scope`, in the caller's transaction, with EXACTLY the keys
  `user`, `group`, `role`, `trace_id` (ids and a fixed string; no IdP claim value, INV-4).
  Dedup is permanent per (user, role, action) and derived from the stored audit table, so it
  survives a restart: a pair that already has an entry gets no new one and is counted in
  `deduped`.

  No lock of its own; reads and audit writes only.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Identity.AuditContext
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.MembershipScope
  alias Letflow.Identity.TenantRole
  alias Letflow.Repo

  @resource_type "user_role"

  @actions %{
    has_scoped_rows: "grant.sync_suppressed",
    no_scoped_rows: "binding.pending_scope"
  }

  @type kind :: :has_scoped_rows | :no_scoped_rows
  @type item :: %{group_id: Ecto.UUID.t(), role: String.t(), kind: kind()}

  @doc """
  The platform roles each group binds, `%{group_id => [role_name]}`. One query on `tenant_roles`
  restricted to `kind == :platform_role`. Must be called after lock A, inside the transaction.
  """
  @spec bound_platform_roles(group_ids :: [Ecto.UUID.t()], prefix :: String.t()) ::
          %{optional(Ecto.UUID.t()) => [String.t()]}
  def bound_platform_roles([], _prefix), do: %{}

  def bound_platform_roles(group_ids, prefix) when is_list(group_ids) and is_binary(prefix) do
    from(t in TenantRole,
      where: t.group_id in ^group_ids and t.kind == :platform_role,
      select: {t.group_id, t.name}
    )
    |> Repo.all(prefix: prefix)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  The decision for one candidate group: `:allow` (insert the membership as today, also when the
  user is already a member or the group binds no platform role) or `{:suppress, [{role, kind}]}`
  listing every bound role the membership would widen, sorted by role name.
  """
  @spec evaluate(
          user_id :: Ecto.UUID.t(),
          group_id :: Ecto.UUID.t(),
          bound_roles :: [String.t()],
          prefix :: String.t()
        ) :: :allow | {:suppress, [{String.t(), kind()}, ...]}
  def evaluate(_user_id, _group_id, [], _prefix), do: :allow

  def evaluate(user_id, group_id, bound_roles, prefix) do
    if member?(group_id, user_id, prefix) do
      :allow
    else
      before_snapshot = MembershipScope.snapshot(user_id, prefix)
      after_snapshot = MembershipScope.snapshot_if_added(user_id, group_id, bound_roles, prefix)
      row_scopes = MembershipScope.row_scopes(user_id, prefix)

      widening =
        bound_roles
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.flat_map(fn role ->
          before_scope = Map.get(before_snapshot, role, :deny)
          after_scope = Map.get(after_snapshot, role, :deny)

          cond do
            not MembershipScope.would_widen?(before_scope, after_scope) -> []
            match?({:nodes, _ids}, Map.get(row_scopes, role)) -> [{role, :has_scoped_rows}]
            true -> [{role, :no_scoped_rows}]
          end
        end)

      if widening == [], do: :allow, else: {:suppress, widening}
    end
  end

  @doc """
  Records the suppressed roles of one group. Returns the items (every suppressed pair, new or
  deduped) and the number of pairs whose entry already existed. An audit failure returns
  `{:error, {:audit_failed, reason}}` and the caller rolls the whole sync back.
  """
  @spec record(
          user_id :: Ecto.UUID.t(),
          group_id :: Ecto.UUID.t(),
          suppressed :: [{String.t(), kind()}],
          prefix :: String.t(),
          ctx :: AuditContext.t()
        ) :: {:ok, [item()], deduped :: non_neg_integer()} | {:error, {:audit_failed, term()}}
  def record(user_id, group_id, suppressed, prefix, %{actor_id: _, trace_id: _} = ctx) do
    suppressed
    |> Enum.reduce_while({:ok, [], 0}, fn {role, kind}, {:ok, items, deduped} ->
      item = %{group_id: group_id, role: role, kind: kind}

      case write_once(user_id, group_id, role, kind, prefix, ctx) do
        :written -> {:cont, {:ok, [item | items], deduped}}
        :deduped -> {:cont, {:ok, [item | items], deduped + 1}}
        {:error, reason} -> {:halt, {:error, {:audit_failed, reason}}}
      end
    end)
    |> case do
      {:ok, items, deduped} -> {:ok, Enum.reverse(items), deduped}
      {:error, _reason} = error -> error
    end
  end

  defp write_once(user_id, group_id, role, kind, prefix, ctx) do
    action = action_for(kind)
    resource_id = "#{user_id}:#{role}"

    if already_recorded?(resource_id, action, prefix) do
      :deduped
    else
      attrs = %{
        actor_id: ctx.actor_id,
        action: action,
        resource_type: @resource_type,
        resource_id: resource_id,
        before_state: nil,
        after_state: %{
          "user" => user_id,
          "group" => group_id,
          "role" => role,
          "trace_id" => ctx.trace_id
        },
        trace_id: ctx.trace_id
      }

      case Audit.insert_entry(Repo, attrs, prefix) do
        {:ok, _entry} -> :written
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  The audit action recorded for a suppression kind. The only place the pairing is written:
  the writer (`record/5`) and every reader of the audit trail go through it.
  """
  @spec action_for(kind()) :: String.t()
  def action_for(kind) when is_map_key(@actions, kind), do: Map.fetch!(@actions, kind)

  @doc "Every suppression kind; each one has an audit action (`action_for/1`)."
  @spec kinds() :: [kind(), ...]
  def kinds, do: Map.keys(@actions)

  defp already_recorded?(resource_id, action, prefix) do
    Audit.latest_matching(prefix, @resource_type, resource_id, [action]) != nil
  end

  defp member?(group_id, user_id, prefix) do
    Repo.exists?(
      from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id),
      prefix: prefix
    )
  end
end
