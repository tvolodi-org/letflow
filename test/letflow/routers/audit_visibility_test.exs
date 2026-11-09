defmodule Letflow.Routers.AuditVisibilityTest do
  @moduledoc """
  T-1557 (B2 #5): names instead of ids, filters, CSV export, `group.delete`, cross-tenant
  negatives. Dispatches straight to `Letflow.Routers.Audit` like `Req196AuditRouteTest`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Audit.init([])

  defp get_audit(tenant, query \\ "", roles \\ ["TENANT_ADMIN"]) do
    path = if query == "", do: "/", else: "/?" <> query

    conn(:get, path)
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "t1557")
    |> Letflow.Routers.Audit.call(@opts)
  end

  defp mk_user!(tenant, attrs) do
    Repo.insert!(
      struct(
        User,
        Map.merge(
          %{
            email: "e#{System.unique_integer([:positive])}@x.test",
            password_hash: "x",
            username: "u" <> Integer.to_string(System.unique_integer([:positive]))
          },
          attrs
        )
      ),
      prefix: tenant.schema_name
    )
  end

  defp seed!(tenant, attrs) do
    base = %{
      actor_id: nil,
      action: "x.y",
      resource_type: "document",
      resource_id: "d1",
      before_state: nil,
      after_state: nil,
      trace_id: nil
    }

    {:ok, e} = Audit.insert_entry(Repo, Map.merge(base, Map.new(attrs)), tenant.schema_name)
    e
  end

  test "T8 actor_name and resource_name: display name, username fallback, deleted actor nil" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-names")
    named = mk_user!(t, %{display_name: "Ann Admin"})
    plain = mk_user!(t, %{username: "bob", display_name: ""})

    seed!(t,
      actor_id: named.id,
      action: "user.update_profile",
      resource_type: "user",
      resource_id: plain.id
    )

    seed!(t, actor_id: Ecto.UUID.generate(), action: "ghost")

    body = Jason.decode!(get_audit(t).resp_body)
    by_action = Map.new(body["items"], &{&1["action"], &1})
    assert by_action["user.update_profile"]["actor_name"] == "Ann Admin"
    assert by_action["user.update_profile"]["resource_name"] == "bob"
    assert by_action["ghost"]["actor_name"] == nil
    assert by_action["ghost"]["resource_name"] == nil
  end

  test "T9 filters by object and user narrow the list" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-filter")
    u = mk_user!(t, %{display_name: "Ann"})
    seed!(t, actor_id: u.id, action: "document.posted", resource_id: "d1")
    seed!(t, actor_id: nil, action: "document.reversed", resource_id: "d2")

    q = fn s -> Jason.decode!(get_audit(t, s).resp_body)["items"] |> Enum.map(& &1["action"]) end
    assert q.("resource_type=document&resource_id=d1") == ["document.posted"]
    assert q.("actor_id=#{u.id}") == ["document.posted"]
    assert q.("resource_id=d2") == ["document.reversed"]
  end

  test "T6 delete_group writes a group.delete audit entry" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-grp")
    opts = [prefix: t.schema_name]

    assert {:ok, group} =
             Identity.create_group(%{"name" => "g-#{System.unique_integer([:positive])}"}, opts)

    assert :ok = Identity.delete_group(group.id, opts)

    items = Jason.decode!(get_audit(t, "resource_type=group").resp_body)["items"]
    assert "group.delete" in Enum.map(items, & &1["action"])
    del = Enum.find(items, &(&1["action"] == "group.delete"))
    assert del["resource_id"] == group.id
    assert del["before_state"]["name"] == group.name
  end

  test "T10 csv export: filtered rows only, header, no states, content type" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-csv")
    u = mk_user!(t, %{display_name: "Ann, \"A\""})

    seed!(t,
      actor_id: u.id,
      action: "document.posted",
      resource_id: "d1",
      after_state: %{"secret" => "v"}
    )

    seed!(t, action: "other.thing", resource_id: "d2")

    resp = get_audit(t, "format=csv&resource_id=d1")
    assert resp.status == 200
    assert [ct] = get_resp_header(resp, "content-type")
    assert ct =~ "text/csv"
    assert get_resp_header(resp, "x-audit-export-truncated") == ["false"]
    assert get_resp_header(resp, "content-disposition") == [~s(attachment; filename="audit.csv")]

    [header, row | rest] = String.split(resp.resp_body, "\r\n", trim: true)

    assert header ==
             "timestamp,actor_name,actor_id,action,resource_type,resource_id,resource_name"

    assert row =~ ~s("Ann, ""A""")
    assert row =~ "document.posted"
    assert rest == []
    refute resp.resp_body =~ "secret"
  end

  test "T11 export cap sets the truncation header" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-cap")
    for i <- 1..3, do: seed!(t, action: "a#{i}")
    Application.put_env(:letflow, :audit_export_cap, 2)
    on_exit(fn -> Application.delete_env(:letflow, :audit_export_cap) end)

    resp = get_audit(t, "format=csv&resource_type=document")
    assert get_resp_header(resp, "x-audit-export-truncated") == ["true"]
    assert length(String.split(resp.resp_body, "\r\n", trim: true)) == 3
  end

  test "T12 formula injection is neutralised" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-inj")
    u = mk_user!(t, %{display_name: "=1+1"})
    seed!(t, actor_id: u.id)
    assert get_audit(t, "format=csv").resp_body =~ "'=1+1"
  end

  test "T13 unknown format is 422" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-fmt")
    assert get_audit(t, "format=xml").status == 422
  end

  test "T14 export writes one audit.exported entry without data" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-rec")
    seed!(t, [])
    assert get_audit(t, "format=csv").status == 200
    items = Jason.decode!(get_audit(t, "resource_type=audit").resp_body)["items"]
    assert [%{"action" => "audit.exported", "after_state" => %{"row_count" => 1}}] = items
  end

  test "T15 export needs :AuditRead" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-authz")
    assert get_audit(t, "format=csv", ["TASK_WORKER"]).status == 403
    assert get_audit(t, "format=csv", ["TENANT_AUDITOR"]).status == 200
  end

  test "T16 cross-tenant: no rows and no names from another tenant" do
    a = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-xa")
    b = TenantFixture.provisioned_tenant!(slug_prefix: "t1557-xb")
    u = mk_user!(a, %{display_name: "Alice"})
    seed!(a, actor_id: u.id, action: "only.a")
    seed!(b, actor_id: u.id, action: "only.b")

    items = Jason.decode!(get_audit(b, "actor_id=#{u.id}").resp_body)["items"]
    assert [%{"action" => "only.b", "actor_name" => nil}] = items
    refute get_audit(b, "format=csv").resp_body =~ "only.a"
    refute get_audit(b, "format=csv").resp_body =~ "Alice"
  end
end
