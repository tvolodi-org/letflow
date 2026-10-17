defmodule Letflow.Routers.GroupMemberSelfAddTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2a, AC 10 (design `lib/letflow/design/req517-scoped-grants-admin-plane.md`
  section 3.10; spec `test/specs/REQ-517-2a.md`, T-M1..T-M3): a caller may not add THEMSELVES to a
  group through `POST /groups/:id/members`.

    * T-M1 the caller adding themselves: 409 `self_grant_refused`, no membership row, no
      `group_member.added` entry, and `grant.self_grant_refused` (act `add_member`) in its own
      transaction;
    * T-M2 adding another user is unchanged (201);
    * T-M3 `Identity.add_group_member/3` defaults `refuse_self_add` to false, so the callers that
      add a user to a group on that user's own behalf (`PendingAdminGrants.bind_on_login`, the IdP
      sync) are unchanged; only the HTTP route passes `true`.

  `async: false`: committed writes.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity
  alias Letflow.Identity.GroupMember
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @identity Letflow.Routers.Identity

  defp member?(fx, group_id, user_id) do
    Repo.exists?(
      from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id),
      prefix: fx.schema_name
    )
  end

  test "T-M1 the caller adding themselves is 409 self_grant_refused: no membership, no group_member.added, one grant.self_grant_refused (add_member)" do
    fx = S.tenant!("r517-m1")
    group = RSG.fresh_group!(fx.schema_name)

    conn =
      S.as_admin(@identity, :post, "/groups/#{group.id}/members", fx, %{"user_id" => fx.admin.id})

    assert conn.status == 409, conn.resp_body
    assert S.body(conn)["detail"] == "self_grant_refused"
    refute member?(fx, group.id, fx.admin.id)

    assert Enum.filter(
             S.entries(fx, "group_member.added"),
             &(&1.resource_id == fx.admin.id and &1.after_state["group_id"] == group.id)
           ) == []

    assert [entry] = S.entries(fx, "grant.self_grant_refused")
    assert entry.actor_id == fx.admin.id
    assert entry.resource_type == "role_scope_grant"
    assert entry.after_state["act"] == "add_member"
    assert entry.after_state["principal_type"] == "user"
    assert entry.after_state["principal_id"] == fx.admin.id
    assert entry.after_state["credential"] == "oidc"
    assert entry.after_state["trace_id"] == S.trace()
  end

  test "T-M1 the refusal also covers the list form of the body and a group the caller already belongs to" do
    fx = S.tenant!("r517-m1b")
    ta_group = RSG.group_of!(fx.schema_name, "TENANT_ADMIN")
    assert member?(fx, ta_group, fx.admin.id)

    for body <- [%{"user_id" => fx.admin.id}, %{"user_ids" => [fx.admin.id]}] do
      conn = S.as_admin(@identity, :post, "/groups/#{ta_group}/members", fx, body)
      assert conn.status == 409, inspect(body)
      assert S.body(conn)["detail"] == "self_grant_refused"
    end

    # also with a different casing of the same UUID (the comparison is canonical)
    conn =
      S.as_admin(@identity, :post, "/groups/#{ta_group}/members", fx, %{
        "user_id" => String.upcase(fx.admin.id)
      })

    assert conn.status == 409
  end

  test "T-M2 adding another user is unchanged: 201, the membership and the group_member.added entry exist" do
    fx = S.tenant!("r517-m2")
    group = RSG.fresh_group!(fx.schema_name)
    other = RSG.user!(fx.schema_name)

    conn =
      S.as_admin(@identity, :post, "/groups/#{group.id}/members", fx, %{"user_id" => other.id})

    assert conn.status == 201, conn.resp_body
    assert member?(fx, group.id, other.id)
    assert [_] = Enum.filter(S.entries(fx, "group_member.added"), &(&1.resource_id == other.id))
    assert S.entries(fx, "grant.self_grant_refused") == []
  end

  test "T-M3 add_group_member/3 defaults refuse_self_add to false (a user may be added on their own behalf); only an explicit true refuses" do
    fx = S.tenant!("r517-m3")
    s = fx.schema_name
    group = RSG.fresh_group!(s)
    user = RSG.user!(s)
    self_context = %{actor_id: user.id, trace_id: nil, source: "idp_sync"}

    # default: allowed (bind_on_login, the IdP sync)
    assert {:ok, %{created: true}} =
             Identity.add_group_member(group.id, user.id, prefix: s, audit_context: self_context)

    assert member?(fx, group.id, user.id)

    other_group = RSG.fresh_group!(s)

    assert {:error, :self_grant_refused} =
             Identity.add_group_member(other_group.id, user.id,
               prefix: s,
               audit_context: self_context,
               refuse_self_add: true
             )

    refute member?(fx, other_group.id, user.id)

    # an explicit true with a DIFFERENT actor is not a self-add
    assert {:ok, %{created: true}} =
             Identity.add_group_member(other_group.id, user.id,
               prefix: s,
               audit_context: %{actor_id: fx.admin.id, trace_id: nil, source: "api"},
               refuse_self_add: true
             )

    # a non-true value (a truthy string) does not enable the refusal
    third = RSG.fresh_group!(s)

    assert {:ok, %{created: true}} =
             Identity.add_group_member(third.id, user.id,
               prefix: s,
               audit_context: self_context,
               refuse_self_add: "yes"
             )
  end
end
