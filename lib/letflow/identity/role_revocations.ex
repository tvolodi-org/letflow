defmodule Letflow.Identity.RoleRevocations do
  @moduledoc """
  GH 2558: reads which role groups an admin explicitly revoked from a user, so the IdP role
  sync (`Letflow.Identity.sync_role_claims_report/3`) never re-grants them.

  ## Decision (GH 2558, option 1: "revocation wins")

  An explicit revocation (`Letflow.Identity.remove_group_member/3`) is permanent against the IdP
  sync: REQ-378 and decision 0051 M3 ("the IdP sync cannot re-widen"). Before this change a
  `RoleBackfill` marker reset re-opened the one-time sync, and the next OIDC login re-granted a
  role an admin had removed. The sync now withholds a group whose revocation is in force and
  audits that (`grant.sync_revocation_honored`). The backfill still resets every marker, so
  existing users keep picking up newly seeded roles (ISS-0886/0910); it only reports the users
  whose next sync will honour a revocation.

  The record of a revocation is the tenant audit chain, no new table: every explicit removal
  writes `group_member.removed` in the same transaction as the delete.

  ## Rule (revocation in force)

  For user U and group G, both of:

    1. the latest `group_member.added` / `group_member.removed` entry for U with
       `after_state.group_id == G` is a `removed`; and
    2. U is not currently a member of G.

  Clause 2 is what lifts a revocation through a path that writes no `group_member.added`
  (the pending TENANT_ADMIN grant bind writes `tenant.admin_grant.bound`).

  The IdP claim is not versioned, so "revoked after the last IdP change" cannot be observed: a
  recorded removal blocks the IdP re-grant of that group until an admin re-adds explicitly.

  Read-only; every query takes the tenant `prefix` and binds its parameters (INV-1, INV-6, INV-7).
  """

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity.GroupMember
  alias Letflow.Repo

  @actions ["group_member.added", "group_member.removed"]

  @doc "The groups whose revocation is in force for `user_id` in the tenant `prefix`."
  @spec revoked_group_ids(user_id :: Ecto.UUID.t(), prefix :: String.t()) ::
          MapSet.t(Ecto.UUID.t())
  def revoked_group_ids(user_id, prefix) do
    [user_id]
    |> revoked_by_user(prefix)
    |> Map.get(user_id, MapSet.new())
  end

  @doc """
  The users among `user_ids` with at least one revocation in force. One pair of queries for
  the whole list.
  """
  @spec users_with_revocation(user_ids :: [Ecto.UUID.t()], prefix :: String.t()) ::
          MapSet.t(Ecto.UUID.t())
  def users_with_revocation([], _prefix), do: MapSet.new()

  def users_with_revocation(user_ids, prefix) do
    user_ids
    |> revoked_by_user(prefix)
    |> Enum.reject(fn {_user_id, groups} -> MapSet.size(groups) == 0 end)
    |> MapSet.new(fn {user_id, _groups} -> user_id end)
  end

  # %{user_id => MapSet of revoked group ids}, net of current membership.
  defp revoked_by_user(user_ids, prefix) do
    resource_ids = Enum.map(user_ids, &to_string/1)

    latest =
      from(e in Entry,
        where: e.resource_type == "group_member" and e.resource_id in ^resource_ids,
        where: e.action in @actions,
        order_by: [asc: e.timestamp, asc: e.id],
        select: {e.resource_id, e.action, fragment("?->>'group_id'", e.after_state)}
      )
      |> Repo.all(prefix: prefix)
      |> Enum.reduce(%{}, fn {user_id, action, group_id}, acc ->
        Map.put(acc, {user_id, group_id}, action)
      end)

    members =
      from(m in GroupMember,
        where: m.user_id in ^user_ids,
        select: {m.user_id, m.group_id}
      )
      |> Repo.all(prefix: prefix)
      |> MapSet.new()

    latest
    |> Enum.filter(fn {{user_id, group_id}, action} ->
      action == "group_member.removed" and is_binary(group_id) and
        not MapSet.member?(members, {user_id, group_id})
    end)
    |> Enum.reduce(%{}, fn {{user_id, group_id}, _action}, acc ->
      Map.update(acc, user_id, MapSet.new([group_id]), &MapSet.put(&1, group_id))
    end)
  end
end
