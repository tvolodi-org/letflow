defmodule Letflow.Routers.ApprovalRulesTest do
  @moduledoc """
  T-1986 (four-eyes switch, slice 1) -- `Letflow.Routers.ApprovalRules` through its own `call/2`
  (the real Authorize plug) over provisioned tenant schemas. IDs: R1 read, R2/R3 writes and audit,
  R4 step existence, R5 body and reason refusals, R6 route and engine agree, F1 uniform 403,
  X1 cross-tenant (INV-10), A1 audit failure.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Scope.Grants
  alias Letflow.Audit.Entry
  alias Letflow.Engine
  alias Letflow.Engine.ApprovalRuleSetting
  alias Letflow.Repo
  alias Letflow.SodSupport, as: S

  @opts Letflow.Routers.ApprovalRules.init([])
  @n1 S.n1()
  @n2 S.n2()
  @keys [
    "changed_at",
    "changed_by",
    "changed_by_name",
    "definition_name",
    "four_eyes",
    "in_active_definition",
    "node_id",
    "node_label",
    "reason"
  ]

  defp case! do
    ctx = S.new_case!(S.seq_graph(%{"distinct_from" => [@n1]}), %{}, %{"seed" => "value"})
    u = S.insert_user!(ctx.schema_name, "u")
    S.grant_role!(ctx.schema_name, "role-a", [u.id])
    S.grant_role!(ctx.schema_name, "role-b", [u.id])
    Map.put(ctx, :u, u)
  end

  defp wide_grants(uid),
    do: %Grants{
      user_id: uid,
      rows_by_role: %{
        "TENANT_ADMIN" => [%{principal_type: :group, tenant_wide: true, scope_node_id: nil}]
      }
    }

  defp call(method, path, t, opts) do
    uid = Keyword.get(opts, :user_id, Ecto.UUID.generate())

    auth =
      %{
        user_id: uid,
        tenant_id: t.tenant_id,
        roles: Keyword.get(opts, :roles, ["TENANT_ADMIN"]),
        credential: Keyword.get(opts, :credential, :oidc)
      }
      |> Map.put(:scope_grants, Keyword.get(opts, :scope_grants, wide_grants(uid)))

    conn(method, path)
    |> Map.put(:body_params, Keyword.get(opts, :body, %{}))
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, auth)
    |> assign(:trace_id, "t1986-trace")
    |> Letflow.Routers.ApprovalRules.call(@opts)
  end

  defp read(t, opts \\ []) do
    conn = call(:get, "/", t, opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp put(t, name, node, body, opts \\ []),
    do:
      call(:put, "/#{URI.encode(name, &URI.char_unreserved?/1)}/#{node}", t, [body: body] ++ opts)

  defp rows(t), do: Repo.all(ApprovalRuleSetting, prefix: t.schema_name)

  defp changed(t),
    do:
      Repo.all(from(a in Entry, where: a.action == "approval_rule.changed"),
        prefix: t.schema_name
      )

  @off %{"four_eyes" => false, "reason" => "one-person company"}

  test "R1 GET lists the four-eyes step, ON, with exactly the contract keys" do
    t = case!()
    assert {200, %{"items" => [item]}} = read(t)
    assert item |> Map.keys() |> Enum.sort() == @keys
    assert %{"node_id" => @n2, "four_eyes" => true, "in_active_definition" => true} = item
    assert item["definition_name"] == t.definition.name
  end

  test "R2 PUT off: 200 item, one approval_rule.changed with before, after, reason; GET shows OFF" do
    t = case!()
    uid = Ecto.UUID.generate()
    conn = put(t, t.definition.name, @n2, @off, user_id: uid)
    assert conn.status == 200
    item = Jason.decode!(conn.resp_body)
    assert %{"four_eyes" => false, "reason" => "one-person company", "changed_by" => ^uid} = item

    assert [entry] = changed(t)
    assert entry.before_state["four_eyes"] == true
    assert entry.after_state["four_eyes"] == false
    assert entry.after_state["reason"] == "one-person company"
    assert entry.actor_id == uid
    assert {200, %{"items" => [%{"four_eyes" => false}]}} = read(t)
  end

  test "R7 changed_by_name is the changer's display name in PUT and GET; nil when never changed" do
    t = case!()
    assert {200, %{"items" => [never]}} = read(t)
    assert never["changed_by"] == nil and never["changed_by_name"] == nil

    conn = put(t, t.definition.name, @n2, @off, user_id: t.u.id)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["changed_by_name"] == t.u.display_name

    assert {200, %{"items" => [item]}} = read(t)
    assert item |> Map.keys() |> Enum.sort() == @keys
    assert item["changed_by_name"] == t.u.display_name
  end

  test "R3 PUT back on writes a second entry; a repeated PUT writes nothing" do
    t = case!()
    assert put(t, t.definition.name, @n2, @off).status == 200
    on = %{"four_eyes" => true, "reason" => "second person joined"}
    assert put(t, t.definition.name, @n2, on).status == 200
    assert [%{four_eyes: true}] = rows(t)
    assert length(changed(t)) == 2

    assert put(t, t.definition.name, @n2, on).status == 200
    assert length(changed(t)) == 2
  end

  test "R4 an unknown step or definition is 422; a stored orphan OFF row can be switched ON" do
    t = case!()

    for {name, node} <- [{t.definition.name, @n1}, {"no-such-def", @n2}] do
      conn = put(t, name, node, @off)
      assert conn.status == 422
      assert conn.resp_body =~ "not_a_four_eyes_step"
    end

    assert rows(t) == []

    Repo.insert!(
      %ApprovalRuleSetting{
        definition_name: "retired-def",
        node_id: "x",
        four_eyes: false,
        changed_by: Ecto.UUID.generate(),
        changed_at: DateTime.utc_now(),
        reason: "old"
      },
      prefix: t.schema_name
    )

    assert {200, %{"items" => items}} = read(t)

    assert Enum.any?(
             items,
             &(&1["definition_name"] == "retired-def" and &1["in_active_definition"] == false)
           )

    assert put(t, "retired-def", "x", %{"four_eyes" => true, "reason" => "close it"}).status ==
             200
  end

  test "R5 body and reason refusals are 422, write nothing and never echo the reason" do
    t = case!()
    secret = "SECRET-REASON-TEXT"

    cases = [
      {%{"reason" => "ok"}, "invalid_body"},
      {%{"four_eyes" => "no", "reason" => "ok"}, "invalid_body"},
      {%{"four_eyes" => false}, "invalid_reason"},
      {%{"four_eyes" => false, "reason" => "   "}, "invalid_reason"},
      {%{"four_eyes" => false, "reason" => secret <> <<0x202E::utf8>>}, "invalid_reason"}
    ]

    for {body, text} <- cases do
      conn = put(t, t.definition.name, @n2, body)
      assert conn.status == 422
      assert conn.resp_body =~ text
      refute conn.resp_body =~ secret
    end

    assert rows(t) == []
    assert changed(t) == []
  end

  test "R6 OFF through the route lets the same person complete (route and engine agree)" do
    t = case!()
    assert put(t, t.definition.name, @n2, @off).status == 200
    S.complete_node!(t, @n1, t.u.id, %{})
    n2 = S.pending_task!(t, @n2)

    assert {:ok, _} =
             Engine.complete_task(
               n2.id,
               %{output_variables: %{}, actor_id: t.u.id, idempotency_key: S.unique("r6")},
               prefix: t.schema_name,
               credential: :oidc
             )
  end

  test "F1 every refused caller gets the same 403 and nothing is written" do
    t = case!()
    uid = Ecto.UUID.generate()

    scoped =
      %Grants{
        user_id: uid,
        rows_by_role: %{
          "TENANT_ADMIN" => [%{principal_type: :group, tenant_wide: false, scope_node_id: "n1"}]
        }
      }

    refused = [
      [credential: nil],
      [credential: :api_token],
      [roles: ["TASK_WORKER"]],
      [roles: ["STOREKEEPER"]],
      [roles: ["TENANT_AUDITOR"]],
      [roles: ["PROCESS_DESIGNER"]],
      [roles: ["TENANT_ADMIN"], user_id: uid, scope_grants: scoped]
    ]

    bodies =
      for opts <- refused,
          {method, path, extra} <- [{:get, "/", []}, {:put, "/d/#{@n2}", [body: @off]}] do
        conn = call(method, path, t, opts ++ extra)
        assert conn.status == 403, "#{inspect(opts)} #{method}"
        conn.resp_body
      end

    assert bodies |> Enum.uniq() |> length() <= 2
    assert Enum.all?(bodies, &(&1 =~ "insufficient permissions"))
    assert rows(t) == []
    assert changed(t) == []
  end

  test "X1 a tenant_id in the body is ignored: only the caller's own tenant is written" do
    a = case!()
    b = case!()
    body = Map.put(@off, "tenant_id", b.tenant_id)

    assert put(a, a.definition.name, @n2, body).status == 200
    assert [_one] = rows(a)
    assert rows(b) == []
    assert {200, %{"items" => [%{"four_eyes" => true}]}} = read(b)
  end

  test "A1 a failing audit write answers 500 and the setting row is not written" do
    t = case!()
    schema = t.schema_name
    Repo.query!(~s|ALTER TABLE "#{schema}".audit_entries RENAME TO audit_entries_x|)

    try do
      conn = put(t, t.definition.name, @n2, @off)
      assert conn.status == 500
    after
      Repo.query!(~s|ALTER TABLE "#{schema}".audit_entries_x RENAME TO audit_entries|)
    end

    assert rows(t) == []
  end
end
