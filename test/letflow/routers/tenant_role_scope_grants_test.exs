defmodule Letflow.Routers.TenantRoleScopeGrantsTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2a, AC 1, 2, 6, 7, 9 and 11 at the HTTP layer:
  `Letflow.Routers.TenantRoleScopeGrants` (`POST|GET /tenant/role-scope-grants`,
  `DELETE /tenant/role-scope-grants/:id`, `POST /tenant/role-scope-grants/make-tenant-wide`).
  Design `lib/letflow/design/req517-scoped-grants-admin-plane.md` sections 3.2, 3.3, 3.8, 3.10 and
  3.11; spec `test/specs/REQ-517-2a.md`, tests T-A1..T-A8, T-V1..T-V10, T-W1..T-W5, T-L1..T-L7,
  T-Z7, T-S1..T-S4, T-U1..T-U6.

  Request shapes:

    * `Letflow.Routers.TenantRoleScopeGrants.call/2` with a hand-assigned `auth_context` that
      carries `credential: :oidc` and the id of a REAL user (the tenant-wide gate builds a
      principal and loads that user's grant rows), through `Letflow.Support.ScopedGrantsFixture`;
    * the FULL `Letflow.Router` pipeline with a real TENANT_ADMIN API token (credential
      `:api_token`: tokens may call the grant writes, with the credential in the audit entry).

  Every tenant is a dedicated `TenantFixture.provisioned_tenant!/1` tenant. Rows a test needs in
  a state the routes cannot produce (a binding with no row, a user's tenant-wide row, a scoped
  TENANT_ADMIN row) are written RAW through `Letflow.Support.RoleScopeGrantsFixture`, and each
  such test says so.

  `async: false`: committed writes, DDL (audit fault triggers), cross-connection locks.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Api.Scope
  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.TenantRole
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture

  import Ecto.Query, only: [from: 2]

  @grants Letflow.Routers.TenantRoleScopeGrants
  @identity Letflow.Routers.Identity
  @worker "TASK_WORKER"
  @admin_role "TENANT_ADMIN"
  @view_keys ~w(effective id principal_id principal_type role scope_node_id tenant_wide)

  # --- helpers ---------------------------------------------------------------------------------

  defp grants(fx, method, path, body), do: S.as_admin(@grants, method, path, fx, body)

  defp create(fx, type, principal_id, role, node),
    do: grants(fx, :post, "/", S.create_body(type, principal_id, role, node))

  defp make_wide(fx, type, principal_id, role),
    do:
      grants(
        fx,
        :post,
        "/make-tenant-wide",
        S.create_body(type, principal_id, role, "x") |> Map.delete("scope_node_id")
      )

  # A scoped create that must succeed; returns the decoded body.
  defp create!(fx, type, principal_id, role, node) do
    conn = create(fx, type, principal_id, role, node)
    assert conn.status == 201, conn.resp_body
    S.body(conn)
  end

  defp detail(conn), do: S.body(conn)["detail"]

  defp rows(fx), do: RSG.rows(fx.schema_name)

  defp grant_row_ids(fx, group_id, role),
    do: for(r <- RSG.group_structs(fx.schema_name, group_id), r.role == role, do: r.id)

  # Every page of the listing, following next_cursor.
  defp collect_pages(fx, limit, cursor, acc) do
    query =
      "/?limit=#{limit}" <>
        if(cursor, do: "&cursor=" <> URI.encode_www_form(cursor), else: "")

    page = fx |> grants(:get, query, nil) |> S.body()
    acc = acc ++ page["items"]
    if page["next_cursor"], do: collect_pages(fx, limit, page["next_cursor"], acc), else: acc
  end

  defp call_as(fx, user_id, roles, method, path, body),
    do: S.call(@grants, method, path, fx, S.ctx(fx, user_id, roles, :oidc), body)

  # A user holding TENANT_ADMIN tenant-wide through a USER row only (not a TENANT_ADMIN group
  # member, so it is not one of the counted administrators). RAW row, stated in each test.
  defp user_row_admin!(fx) do
    user = RSG.user!(fx.schema_name)
    :ok = RSG.raw_user_row!(fx.schema_name, user.id, @admin_role, nil)
    user
  end

  # ===========================================================================================
  describe "T-A1 POST /: create one scoped row" do
    test "201 with exactly the seven view keys, the row exists, effective is true for a bound group" do
      fx = S.tenant!("r517-a1")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)

      conn = create(fx, :group, gid, @worker, node)

      assert conn.status == 201, conn.resp_body
      b = S.body(conn)
      assert b |> Map.keys() |> Enum.sort() == @view_keys

      assert %{
               "principal_type" => "group",
               "principal_id" => ^gid,
               "role" => @worker,
               "scope_node_id" => ^node,
               "tenant_wide" => false,
               "effective" => true
             } = b

      assert {:ok, _uuid} = Ecto.UUID.cast(b["id"])
      assert RSG.scoped(gid, @worker, node) in rows(fx)
    end

    test "T-V11 a user row for a role the user does not hold through a group is accepted with effective false; held through a group it is true" do
      fx = S.tenant!("r517-a1-user")
      s = fx.schema_name
      node = RSG.node!(s)
      plain = RSG.user!(s)
      holder = TokenMintFixture.role_holder!(s, [@worker])

      b = create!(fx, :user, plain.id, @worker, node)
      assert b["effective"] == false
      assert b["principal_type"] == "user"

      b = create!(fx, :user, holder.id, @worker, node)
      assert b["effective"] == true
    end
  end

  # ===========================================================================================
  describe "T-A2 GET /: list" do
    test "tenant-wide rows are listed with scope_node_id null; filters, limit and cursor pages; another tenant's rows are absent" do
      fx = S.tenant!("r517-a2")
      other = S.tenant!("r517-a2-other")
      g1 = S.rowless_group!(fx, @worker)
      g2 = S.rowless_group!(fx, "PROCESS_DESIGNER")
      [n1, n2, n3] = for _ <- 1..3, do: RSG.node!(fx.schema_name)

      r1 = create!(fx, :group, g1, @worker, n1)
      r2 = create!(fx, :group, g1, @worker, n2)
      r3 = create!(fx, :group, g2, "PROCESS_DESIGNER", n3)

      other_gid = S.rowless_group!(other, @worker)
      other_row = create!(other, :group, other_gid, @worker, RSG.node!(other.schema_name))

      conn = grants(fx, :get, "/", nil)
      assert conn.status == 200
      page = S.body(conn)
      items = page["items"]
      assert page["count"] == length(items)

      scoped_ids = for i <- items, i["tenant_wide"] == false, do: i["id"]
      assert Enum.sort(scoped_ids) == Enum.sort([r1["id"], r2["id"], r3["id"]])
      refute other_row["id"] in Enum.map(items, & &1["id"])

      tenant_wide = Enum.filter(items, & &1["tenant_wide"])
      assert tenant_wide != []
      assert Enum.all?(tenant_wide, &(&1["scope_node_id"] == nil))
      assert Enum.all?(items, &(Enum.sort(Map.keys(&1)) == @view_keys))

      # filters
      by_principal =
        fx
        |> grants(:get, "/?principal_type=group&principal_id=#{g1}&role=#{@worker}", nil)
        |> S.body()

      assert by_principal["items"] |> Enum.map(& &1["scope_node_id"]) |> Enum.sort() ==
               Enum.sort([n1, n2])

      by_role = fx |> grants(:get, "/?role=PROCESS_DESIGNER", nil) |> S.body()
      assert [r3["id"]] == for(i <- by_role["items"], i["tenant_wide"] == false, do: i["id"])

      # pages: limit 2, following the cursor, equal the single big page in order
      first = fx |> grants(:get, "/?limit=2", nil) |> S.body()
      assert length(first["items"]) == 2
      assert is_binary(first["next_cursor"])

      all_paged = collect_pages(fx, 2, nil, [])
      assert Enum.map(all_paged, & &1["id"]) == Enum.map(items, & &1["id"])
      assert Enum.uniq_by(all_paged, & &1["id"]) == all_paged
    end

    test "bad query values: limit outside 1..200 or not an integer and a bad cursor are 400; a bad filter value is 422; other query params (a tenant) are ignored" do
      fx = S.tenant!("r517-a2-bad")
      other = S.tenant!("r517-a2-bad-other")
      gid = S.rowless_group!(other, @worker)
      _row = create!(other, :group, gid, @worker, RSG.node!(other.schema_name))

      for bad <- ["0", "201", "-1", "abc", "1.5", ""] do
        conn = grants(fx, :get, "/?limit=#{bad}", nil)
        assert conn.status == 400, "limit=#{bad}"
        assert detail(conn) == "invalid limit"
      end

      conn = grants(fx, :get, "/?cursor=not-a-cursor", nil)
      assert conn.status == 400
      assert detail(conn) == "invalid cursor"

      for {query, code} <- [
            {"principal_type=robot", "invalid_principal"},
            {"principal_id=not-a-uuid", "invalid_principal"},
            {"role=NOPE", "invalid_role"},
            {"role=PLATFORM_ADMIN", "invalid_role"}
          ] do
        conn = grants(fx, :get, "/?" <> query, nil)
        assert conn.status == 422, query
        assert detail(conn) == code
      end

      plain = fx |> grants(:get, "/", nil) |> S.body()

      with_tenant =
        fx
        |> grants(:get, "/?tenant=#{other.tenant.slug}&tenant_id=#{other.tenant_id}", nil)
        |> S.body()

      assert Enum.map(with_tenant["items"], & &1["id"]) == Enum.map(plain["items"], & &1["id"])
    end
  end

  # ===========================================================================================
  describe "T-A3 DELETE /:id" do
    test "204 with an empty body, the row is gone; unknown and non-UUID ids are the same 404" do
      fx = S.tenant!("r517-a3")
      gid = S.rowless_group!(fx, @worker)
      [n1, n2] = for _ <- 1..2, do: RSG.node!(fx.schema_name)
      first = create!(fx, :group, gid, @worker, n1)
      _second = create!(fx, :group, gid, @worker, n2)

      conn = grants(fx, :delete, "/#{first["id"]}", nil)
      assert conn.status == 204
      assert conn.resp_body == ""
      refute RSG.scoped(gid, @worker, n1) in rows(fx)
      assert RSG.scoped(gid, @worker, n2) in rows(fx)

      unknown = grants(fx, :delete, "/#{Ecto.UUID.generate()}", nil)
      malformed = grants(fx, :delete, "/not-a-uuid", nil)
      assert unknown.status == 404
      assert malformed.status == 404
      assert unknown.resp_body == malformed.resp_body

      # deleting the same id twice: the second is a 404
      assert grants(fx, :delete, "/#{first["id"]}", nil).status == 404
    end
  end

  # ===========================================================================================
  describe "T-A4 POST /make-tenant-wide" do
    test "200 with {id, tenant_wide, removed_scoped_ids sorted}; one tenant-wide row replaces the scoped rows" do
      fx = S.tenant!("r517-a4")
      gid = S.rowless_group!(fx, @worker)
      [n1, n2] = for _ <- 1..2, do: RSG.node!(fx.schema_name)
      a = create!(fx, :group, gid, @worker, n1)
      b = create!(fx, :group, gid, @worker, n2)

      conn = make_wide(fx, :group, gid, @worker)

      assert conn.status == 200, conn.resp_body
      resp = S.body(conn)
      assert resp |> Map.keys() |> Enum.sort() == ["id", "removed_scoped_ids", "tenant_wide"]
      assert resp["tenant_wide"] == true
      assert resp["removed_scoped_ids"] == Enum.sort([a["id"], b["id"]])

      assert Enum.filter(rows(fx), &match?({:group, ^gid, @worker, _node, _tw}, &1)) ==
               [RSG.tw(gid, @worker)]

      assert [%{id: id}] =
               Enum.filter(RSG.group_structs(fx.schema_name, gid), &(&1.role == @worker))

      assert id == resp["id"]
    end
  end

  # ===========================================================================================
  describe "T-A6 the 403 gate" do
    test "a caller without the permission, a non-admin and a scoped-only TENANT_ADMIN get the same 403 bytes per route, and nothing is written" do
      fx = S.tenant!("r517-a6")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      row = create!(fx, :group, gid, @worker, node)
      designer = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
      worker = TokenMintFixture.role_holder!(s, [@worker])
      before = rows(fx)

      requests = [
        {:post, "/", S.create_body(:group, gid, @worker, node)},
        {:get, "/", nil},
        {:delete, "/#{row["id"]}", nil},
        {:post, "/make-tenant-wide",
         Map.delete(S.create_body(:group, gid, @worker, node), "scope_node_id")}
      ]

      callers = [
        {designer.id, ["PROCESS_DESIGNER"]},
        {worker.id, [@worker]},
        # a TENANT_ADMIN role claim with no grant row at all (no_grant_rows)
        {RSG.user!(s).id, [@admin_role]}
      ]

      for {method, path, body} <- requests do
        bytes =
          for {uid, roles} <- callers do
            conn = call_as(fx, uid, roles, method, path, body)
            assert conn.status == 403, "#{method} #{path} as #{inspect(roles)}"
            assert detail(conn) == "insufficient permissions"
            conn.resp_body
          end

        assert length(Enum.uniq(bytes)) == 1, "#{method} #{path}: 403 bytes differ across callers"
      end

      assert rows(fx) == before
      assert S.entries(fx, "grant.revoked") == []
      assert S.entries(fx, "grant.made_tenant_wide") == []
    end

    test "a TENANT_ADMIN whose group holds only a scoped row gets the same 403 on all four routes" do
      fx = S.tenant!("r517-a6-scoped")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      row = create!(fx, :group, gid, @worker, node)
      _node = RSG.make_group_scoped_only!(s, RSG.group_of!(s, @admin_role), @admin_role)

      for {method, path, body} <- [
            {:post, "/", S.create_body(:group, gid, @worker, node)},
            {:get, "/", nil},
            {:delete, "/#{row["id"]}", nil},
            {:post, "/make-tenant-wide",
             Map.delete(S.create_body(:group, gid, @worker, node), "scope_node_id")}
          ] do
        conn = grants(fx, method, path, body)
        assert conn.status == 403, "#{method} #{path}"
        assert detail(conn) == "insufficient permissions"
      end

      assert RSG.scoped(gid, @worker, node) in rows(fx)
    end
  end

  # ===========================================================================================
  describe "T-A7 every listed 409 and 422 code once, with the code in detail" do
    test "create and make-tenant-wide" do
      fx = S.tenant!("r517-a7")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      dup_group = RSG.group_of!(s, "PROCESS_OPERATOR")
      create!(fx, :group, gid, @worker, node)

      cases = [
        {:post, "/", %{}, 422, "invalid_body"},
        {:post, "/", S.create_body(:group, gid, "PLATFORM_ADMIN", node), 422, "invalid_role"},
        {:post, "/", S.create_body(:robot, gid, @worker, node), 422, "invalid_principal"},
        {:post, "/", S.create_body(:group, RSG.fresh_group!(s).id, @worker, node), 422,
         "no_binding"},
        {:post, "/", S.create_body(:group, gid, @worker, "no-such-node"), 422,
         "invalid_scope_node"},
        {:post, "/", S.create_body(:group, gid, @worker, node), 409, "grant_exists"},
        {:post, "/", S.create_body(:group, dup_group, "PROCESS_OPERATOR", node), 409,
         "tenant_wide_row_exists"},
        {:post, "/", S.create_body(:user, fx.admin.id, @worker, node), 409, "self_grant_refused"},
        {:post, "/make-tenant-wide", %{}, 422, "invalid_body"},
        {:post, "/make-tenant-wide",
         %{"principal_type" => "group", "principal_id" => gid, "role" => "NOPE"}, 422,
         "invalid_role"},
        {:post, "/make-tenant-wide",
         %{"principal_type" => "robot", "principal_id" => gid, "role" => @worker}, 422,
         "invalid_principal"},
        {:post, "/make-tenant-wide",
         %{
           "principal_type" => "group",
           "principal_id" => RSG.fresh_group!(s).id,
           "role" => @worker
         }, 422, "no_binding"},
        {:post, "/make-tenant-wide",
         %{
           "principal_type" => "group",
           "principal_id" => dup_group,
           "role" => "PROCESS_OPERATOR"
         }, 409, "tenant_wide_row_exists"},
        {:post, "/make-tenant-wide",
         %{"principal_type" => "user", "principal_id" => fx.admin.id, "role" => @worker}, 409,
         "self_grant_refused"}
      ]

      for {method, path, body, status, code} <- cases do
        conn = grants(fx, method, path, body)
        assert conn.status == status, "#{path} #{inspect(code)}: #{conn.resp_body}"
        assert detail(conn) == code, "#{path}: #{conn.resp_body}"
      end
    end

    test "no tenant segment, tenant body field or tenant query is read (INV-1)" do
      fx = S.tenant!("r517-a8")
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(fx.schema_name)
      before = rows(fx)

      conn =
        grants(
          fx,
          :post,
          "/",
          Map.put(S.create_body(:group, gid, @worker, node), "tenant_id", fx.tenant_id)
        )

      assert conn.status == 422
      assert detail(conn) == "invalid_body"

      conn =
        grants(
          fx,
          :post,
          "/",
          Map.put(S.create_body(:group, gid, @worker, node), "tenant", fx.tenant.slug)
        )

      assert conn.status == 422
      assert rows(fx) == before
    end
  end

  # ===========================================================================================
  describe "T-V create validation" do
    test "T-V1..V3 PLATFORM_ADMIN, a routing-role name, an unknown role and a wrong-case role are 422 invalid_role" do
      fx = S.tenant!("r517-v1")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)

      _binding =
        RSG.raw_binding!(s, "my-routing-role", :process_routing_role, RSG.fresh_group!(s).id)

      for role <- ["PLATFORM_ADMIN", "my-routing-role", "NOPE", "task_worker", "TASK_WORKER ", ""] do
        for {path, body} <- [
              {"/", S.create_body(:group, gid, role, node)},
              {"/make-tenant-wide",
               Map.delete(S.create_body(:group, gid, role, node), "scope_node_id")}
            ] do
          conn = grants(fx, :post, path, body)
          assert conn.status == 422, "#{path} role #{inspect(role)}"
          assert detail(conn) == "invalid_role"
        end
      end

      assert RSG.scoped(gid, @worker, node) not in rows(fx)
    end

    test "T-V4 a group with no binding and a group whose only binding for the role is routing-kind are 422 no_binding" do
      fx = S.tenant!("r517-v4")
      s = fx.schema_name
      node = RSG.node!(s)
      unbound = RSG.fresh_group!(s)
      routed = RSG.group_of!(s, "PROCESS_OPERATOR")

      {1, _} =
        Repo.update_all(
          from(t in TenantRole, where: t.name == "PROCESS_OPERATOR"),
          [set: [kind: :process_routing_role]],
          prefix: s
        )

      for {gid, role} <- [{unbound.id, @worker}, {routed, "PROCESS_OPERATOR"}] do
        conn = create(fx, :group, gid, role, node)
        assert conn.status == 422
        assert detail(conn) == "no_binding"
      end
    end

    test "T-V5..V7 unknown user, unknown group and malformed principal ids are 422 invalid_principal" do
      fx = S.tenant!("r517-v5")
      node = RSG.node!(fx.schema_name)

      for {type, id} <- [
            {:user, Ecto.UUID.generate()},
            {:group, Ecto.UUID.generate()},
            {:user, "not-a-uuid"},
            {:group, "'; DROP TABLE users;--"}
          ] do
        conn = create(fx, type, id, @worker, node)
        assert conn.status == 422, "#{type} #{id}"
        assert detail(conn) == "invalid_principal"
      end
    end

    test "T-V8 a retired, unknown or malformed node is one 422 invalid_scope_node with the same bytes" do
      fx = S.tenant!("r517-v8")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      retired = RSG.node!(s)
      {:ok, _node} = ScopeNodePaths.write({:retire, retired}, s)

      bytes =
        for node <- [
              retired,
              "no-such-node",
              "a/b",
              "",
              String.duplicate("n", 65),
              "bad\u0007node"
            ] do
          conn = create(fx, :group, gid, @worker, node)
          assert conn.status == 422, inspect(node)
          assert detail(conn) == "invalid_scope_node"
          conn.resp_body
        end

      assert length(Enum.uniq(bytes)) == 1
      assert Enum.filter(rows(fx), &match?({:group, ^gid, @worker, _, false}, &1)) == []
    end

    test "T-V9 a duplicate scoped row is 409 grant_exists" do
      fx = S.tenant!("r517-v9")
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(fx.schema_name)
      create!(fx, :group, gid, @worker, node)

      conn = create(fx, :group, gid, @worker, node)
      assert conn.status == 409
      assert detail(conn) == "grant_exists"
    end

    test "T-V10 a missing key, an extra key, a non-string value and a non-map body are 422 invalid_body" do
      fx = S.tenant!("r517-v10")
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(fx.schema_name)
      full = S.create_body(:group, gid, @worker, node)

      bodies = [
        %{},
        Map.delete(full, "scope_node_id"),
        Map.delete(full, "role"),
        Map.put(full, "extra", "x"),
        Map.put(full, "scope_node_id", 123),
        Map.put(full, "principal_id", nil),
        Map.put(full, "role", ["TASK_WORKER"])
      ]

      for b <- bodies do
        conn = grants(fx, :post, "/", b)
        assert conn.status == 422, inspect(b)
        assert detail(conn) == "invalid_body"
      end

      for b <- [[], "text", 5] do
        conn = S.as_admin(@grants, :post, "/", fx, b)
        assert conn.status == 422, inspect(b)
        assert detail(conn) == "invalid_body"
      end
    end

    test "hostile strings are only ever bound values: they never appear in the SQL text, the tables survive, % and _ are literal" do
      fx = S.tenant!("r517-v-hostile")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      literal = RSG.node!(s)
      hostile = "'; DROP TABLE users;--"

      {conns, queries} =
        Fixture.capture_repo_queries(fn ->
          [
            create(fx, :group, gid, @worker, hostile),
            create(fx, :group, hostile, @worker, literal),
            create(fx, :group, gid, "TASK_WORKER'; --", literal),
            # % and _ must not behave as LIKE wildcards: no node is called "%"
            create(fx, :group, gid, @worker, "%"),
            create(fx, :group, gid, @worker, String.slice(literal, 0, 5) <> "%")
          ]
        end)

      assert Enum.map(conns, & &1.status) == [422, 422, 422, 422, 422]

      refute Enum.any?(queries, fn q ->
               String.contains?(to_string(Map.get(q, :query)), "DROP TABLE")
             end)

      assert %{rows: [[1]]} = Repo.query!(~s|SELECT 1 FROM "#{s}".users LIMIT 1|)
    end
  end

  # ===========================================================================================
  describe "T-W tenant-wide versus scoped" do
    test "T-W1 a scoped create while a tenant-wide row exists is 409 tenant_wide_row_exists and writes nothing" do
      fx = S.tenant!("r517-w1")
      gid = RSG.group_of!(fx.schema_name, @worker)
      node = RSG.node!(fx.schema_name)
      before = rows(fx)
      assert RSG.tw(gid, @worker) in before

      conn = create(fx, :group, gid, @worker, node)

      assert conn.status == 409
      assert detail(conn) == "tenant_wide_row_exists"
      assert rows(fx) == before
      assert S.entries(fx, "grant.created") == []
    end

    test "T-W2 make-tenant-wide when the tenant-wide row exists is 409 tenant_wide_row_exists" do
      fx = S.tenant!("r517-w2")
      gid = RSG.group_of!(fx.schema_name, @worker)
      before = rows(fx)

      conn = make_wide(fx, :group, gid, @worker)

      assert conn.status == 409
      assert detail(conn) == "tenant_wide_row_exists"
      assert rows(fx) == before
    end

    test "T-W3 between deleting the tenant-wide row and the scoped create a group member is denied (no_grant_rows); after it the node is allowed and others are not" do
      fx = S.tenant!("r517-w3")
      s = fx.schema_name
      member = TokenMintFixture.role_holder!(s, [@worker])
      gid = RSG.group_of!(s, @worker)
      node = RSG.node!(s)
      elsewhere = RSG.node!(s)

      assert Scope.allowed?(S.principal(fx, member.id), :TasksRead, :tenant_wide) ==
               {:allow, :tenant_wide}

      [tw_id] = grant_row_ids(fx, gid, @worker)
      conn = grants(fx, :delete, "/#{tw_id}", nil)
      assert conn.status == 204

      assert Scope.allowed?(S.principal(fx, member.id), :TasksRead, :tenant_wide) ==
               {:deny, :no_grant_rows}

      create!(fx, :group, gid, @worker, node)
      p = S.principal(fx, member.id)
      assert Scope.allowed?(p, :TasksRead, {:node, node}) == {:allow, :subtree}
      assert Scope.allowed?(p, :TasksRead, {:node, elsewhere}) == {:deny, :out_of_scope}
      assert Scope.allowed?(p, :TasksRead, :tenant_wide) == {:deny, :not_tenant_wide}
    end

    test "T-W4 make-tenant-wide with two scoped rows: one tenant-wide row, the scoped rows are gone, grant.made_tenant_wide lists both" do
      fx = S.tenant!("r517-w4")
      gid = S.rowless_group!(fx, @worker)
      [n1, n2] = for _ <- 1..2, do: RSG.node!(fx.schema_name)
      a = create!(fx, :group, gid, @worker, n1)
      b = create!(fx, :group, gid, @worker, n2)

      resp = fx |> make_wide(:group, gid, @worker) |> S.body()
      ids = Enum.sort([a["id"], b["id"]])
      assert resp["removed_scoped_ids"] == ids

      assert [entry] = S.entries(fx, "grant.made_tenant_wide")
      assert entry.resource_id == resp["id"]
      assert entry.resource_type == "role_scope_grant"

      assert entry.before_state["removed"] |> Enum.map(& &1["id"]) |> Enum.sort() == ids

      assert entry.before_state["removed"] |> Enum.map(& &1["scope_node_id"]) |> Enum.sort() ==
               Enum.sort([n1, n2])

      assert entry.after_state["removed_scoped_ids"] == ids
    end

    test "T-W5 a forced audit failure after the scoped delete restores both scoped rows" do
      fx = S.tenant!("r517-w5")
      gid = S.rowless_group!(fx, @worker)
      [n1, n2] = for _ <- 1..2, do: RSG.node!(fx.schema_name)
      create!(fx, :group, gid, @worker, n1)
      create!(fx, :group, gid, @worker, n2)
      before = rows(fx)

      conn =
        S.with_audit_fault(fx, "grant.made_tenant_wide", fn ->
          make_wide(fx, :group, gid, @worker)
        end)

      assert conn.status == 500
      assert rows(fx) == before
      assert S.entries(fx, "grant.made_tenant_wide") == []
    end

    test "make-tenant-wide of a principal with zero rows creates the tenant-wide row (the documented repair); removed_scoped_ids is empty" do
      fx = S.tenant!("r517-w6")
      gid = S.rowless_group!(fx, @worker)

      conn = make_wide(fx, :group, gid, @worker)

      assert conn.status == 200
      assert S.body(conn)["removed_scoped_ids"] == []
      assert RSG.tw(gid, @worker) in rows(fx)
    end
  end

  # ===========================================================================================
  describe "T-L last row" do
    test "T-L1 deleting the only scoped row of a group principal is 409 last_scoped_row; the row and the effective scope are unchanged" do
      fx = S.tenant!("r517-l1")
      s = fx.schema_name
      member = TokenMintFixture.role_holder!(s, [@worker])
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      row = create!(fx, :group, gid, @worker, node)
      before = rows(fx)

      conn = grants(fx, :delete, "/#{row["id"]}", nil)

      assert conn.status == 409
      assert detail(conn) == "last_scoped_row"
      assert rows(fx) == before

      assert Scope.allowed?(S.principal(fx, member.id), :TasksRead, {:node, node}) ==
               {:allow, :subtree}

      assert S.entries(fx, "grant.revoked") == []
    end

    test "T-L2 the same for a user principal whose only row is scoped" do
      fx = S.tenant!("r517-l2")
      user = RSG.user!(fx.schema_name)
      node = RSG.node!(fx.schema_name)
      row = create!(fx, :user, user.id, @worker, node)

      conn = grants(fx, :delete, "/#{row["id"]}", nil)

      assert conn.status == 409
      assert detail(conn) == "last_scoped_row"
      assert {:user, user.id, @worker, node, false} in rows(fx)
    end

    test "T-L3 deleting one of two scoped rows is 204" do
      fx = S.tenant!("r517-l3")
      gid = S.rowless_group!(fx, @worker)
      [n1, n2] = for _ <- 1..2, do: RSG.node!(fx.schema_name)
      first = create!(fx, :group, gid, @worker, n1)
      _second = create!(fx, :group, gid, @worker, n2)

      assert grants(fx, :delete, "/#{first["id"]}", nil).status == 204

      assert [{:group, gid, @worker, n2, false}] ==
               Enum.filter(rows(fx), &match?({:group, ^gid, @worker, _, _}, &1))
    end

    test "T-L4 deleting a tenant-wide row: 204; a group principal is then denied; a user principal falls back to its groups' rows; the integrity report lists the zero-row binding" do
      fx = S.tenant!("r517-l4")
      s = fx.schema_name
      worker = TokenMintFixture.role_holder!(s, [@worker])
      gid = RSG.group_of!(s, @worker)
      node = RSG.node!(s)

      [tw_id] = grant_row_ids(fx, gid, @worker)
      assert grants(fx, :delete, "/#{tw_id}", nil).status == 204

      assert Scope.allowed?(S.principal(fx, worker.id), :TasksRead, :tenant_wide) ==
               {:deny, :no_grant_rows}

      conn = S.as_admin(Letflow.Routers.TenantScopeEnforcement, :get, "/integrity", fx, nil)
      assert conn.status == 200
      assert @worker in Enum.map(S.body(conn)["items"], & &1["name"])

      # A user principal with its own tenant-wide row (created by the route) AND a group scoped row:
      # deleting the user's tenant-wide row leaves the group's scoped row in force.
      create!(fx, :group, gid, @worker, node)
      assert make_wide(fx, :user, worker.id, @worker).status == 200

      assert Scope.allowed?(S.principal(fx, worker.id), :TasksRead, :tenant_wide) ==
               {:allow, :tenant_wide}

      [user_tw] =
        for r <-
              Repo.all(
                from(g in Letflow.Identity.RoleScopeGrant, where: g.principal_id == ^worker.id),
                prefix: s
              ),
            do: r.id

      assert grants(fx, :delete, "/#{user_tw}", nil).status == 204

      p = S.principal(fx, worker.id)
      assert Scope.allowed?(p, :TasksRead, {:node, node}) == {:allow, :subtree}
      assert Scope.allowed?(p, :TasksRead, :tenant_wide) == {:deny, :not_tenant_wide}
    end

    test "T-L5 removing the role binding still cascades every row, scoped ones included, and frees the node" do
      fx = S.tenant!("r517-l5")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      create!(fx, :group, gid, @worker, node)
      assert RoleScopeGrants.references_node?(node, s)

      conn =
        S.as_admin(@identity, :post, "/roles", fx, %{
          "name" => @worker,
          "kind" => "process_routing_role",
          "group_id" => gid
        })

      assert conn.status in [200, 201], conn.resp_body
      assert Enum.filter(rows(fx), &match?({:group, ^gid, @worker, _, _}, &1)) == []
      refute RoleScopeGrants.references_node?(node, s)
      assert {:ok, _} = ScopeNodePaths.write({:retire, node}, s)
    end

    test "T-L6 the only row of the TENANT_ADMIN group (tenant-wide) cannot be deleted: 409 last_admin_binding_row, no guard event, no zero-row binding, counts agree; unbinding still works" do
      fx = S.tenant!("r517-l6")
      s = fx.schema_name
      ga = RSG.group_of!(s, @admin_role)
      other = RSG.user!(s)

      {:ok, %{token: _token}} =
        Identity.create_token(other.id, %{roles: [@admin_role], expires_at: nil}, prefix: s)

      [row_id] = grant_row_ids(fx, ga, @admin_role)
      before = rows(fx)
      assert Identity.count_tenant_wide_admins(s) == Identity.count_explicit_tenant_wide_admins(s)

      conn = grants(fx, :delete, "/#{row_id}", nil)

      assert conn.status == 409
      assert detail(conn) == "last_admin_binding_row"
      assert rows(fx) == before
      assert S.entries(fx, "tenant_admin.guard_refused") == []
      assert S.entries(fx, "grant.revoked") == []
      assert RSG.binding(s, @admin_role).kind == :platform_role
      assert Identity.count_tenant_wide_admins(s) == Identity.count_explicit_tenant_wide_admins(s)

      # The operator route for this: unbind the role (existing N1 guards, cascade of the rows).
      conn =
        S.as_admin(@identity, :post, "/roles", fx, %{
          "name" => @admin_role,
          "kind" => "process_routing_role",
          "group_id" => ga
        })

      assert conn.status in [200, 201], conn.resp_body
      assert Enum.filter(rows(fx), &match?({:group, ^ga, @admin_role, _, _}, &1)) == []
    end

    test "T-L6b with rows [tenant-wide, scoped] the tenant-wide row can be deleted while another explicit administrator exists; counts then agree and the last administrator cannot be deactivated" do
      fx = S.tenant!("r517-l6b")
      s = fx.schema_name
      ga = RSG.group_of!(s, @admin_role)
      other = RSG.user!(s)

      {:ok, %{token: _token}} =
        Identity.create_token(other.id, %{roles: [@admin_role], expires_at: nil}, prefix: s)

      # RAW: a scoped TENANT_ADMIN group row next to the tenant-wide one (the routes refuse to create it).
      :ok = RSG.raw_scoped_row!(s, ga, @admin_role, RSG.node!(s))

      [tw_id] =
        for r <- RSG.group_structs(s, ga), r.role == @admin_role and r.tenant_wide, do: r.id

      conn = grants(fx, :delete, "/#{tw_id}", nil)

      assert conn.status == 204, conn.resp_body
      assert S.entries(fx, "tenant_admin.guard_refused") == []
      assert Identity.count_tenant_wide_admins(s) == 1
      assert Identity.count_tenant_wide_admins(s) == Identity.count_explicit_tenant_wide_admins(s)

      assert {:error, :last_tenant_wide_admin} ==
               Identity.update_user_status(other.id, :inactive, prefix: s, login_directory: :skip)
    end

    test "T-L7 precedence: the sole remaining row of the TENANT_ADMIN group, when scoped, is last_scoped_row" do
      fx = S.tenant!("r517-l7")
      s = fx.schema_name
      ga = RSG.group_of!(s, @admin_role)
      # RAW state: the group's only TENANT_ADMIN row is a scoped one. The caller holds
      # TENANT_ADMIN tenant-wide through a USER row (so the gate passes).
      _ = RSG.raw_delete_rows!(s, ga, @admin_role)
      :ok = RSG.raw_scoped_row!(s, ga, @admin_role, RSG.node!(s))
      caller = user_row_admin!(fx)
      [row_id] = grant_row_ids(fx, ga, @admin_role)

      conn = call_as(fx, caller.id, [@admin_role], :delete, "/#{row_id}", nil)

      assert conn.status == 409
      assert detail(conn) == "last_scoped_row"
      assert length(grant_row_ids(fx, ga, @admin_role)) == 1
      assert Identity.count_tenant_wide_admins(s) == Identity.count_explicit_tenant_wide_admins(s)
    end

    test "G3 rows [tenant-wide, scoped] and no other administrator: deleting the tenant-wide row is refused (last_tenant_wide_admin) and the counted and explicit counts still agree" do
      fx = S.tenant!("r517-g3")
      s = fx.schema_name
      ga = RSG.group_of!(s, @admin_role)
      # RAW: a scoped TENANT_ADMIN group row next to the tenant-wide one (the routes refuse to
      # create it). fx.admin is the only administrator, through the group's tenant-wide row.
      :ok = RSG.raw_scoped_row!(s, ga, @admin_role, RSG.node!(s))

      [tw_id] =
        for r <- RSG.group_structs(s, ga), r.role == @admin_role and r.tenant_wide, do: r.id

      before = rows(fx)
      assert Identity.count_tenant_wide_admins(s) == 1
      assert Identity.count_explicit_tenant_wide_admins(s) == 1

      conn = grants(fx, :delete, "/#{tw_id}", nil)

      assert conn.status == 409, conn.resp_body
      assert detail(conn) == "last_tenant_wide_admin"
      assert rows(fx) == before
      assert [event] = S.entries(fx, "tenant_admin.guard_refused")
      assert event.after_state["action"] == "revoke_tenant_admin_grant"
      assert S.entries(fx, "grant.revoked") == []
      assert Identity.count_tenant_wide_admins(s) == 1
      assert Identity.count_tenant_wide_admins(s) == Identity.count_explicit_tenant_wide_admins(s)
    end
  end

  # ===========================================================================================
  describe "T-Z the zero-admin guard over the routes" do
    test "T-Z1 deleting the tenant-wide TENANT_ADMIN row of the last explicit administrator: 409 last_tenant_wide_admin, row present, one guard_refused event with the six keys (revoke_tenant_admin_grant)" do
      fx = S.tenant!("r517-z1")
      s = fx.schema_name
      ga = RSG.group_of!(s, @admin_role)
      # RAW state, stated: the TENANT_ADMIN group has no row (a zero-row binding); U is its member
      # with a tenant-wide USER row, so U is the only explicit administrator. The caller C holds
      # TENANT_ADMIN through a user row and is not a group member.
      _ = RSG.raw_delete_rows!(s, ga, @admin_role)
      u = RSG.member!(s, ga, RSG.user!(s))
      :ok = RSG.raw_user_row!(s, u.id, @admin_role, nil)
      caller = user_row_admin!(fx)
      assert Identity.count_explicit_tenant_wide_admins(s) == 1

      [u_row] =
        for r <-
              Repo.all(from(g in Letflow.Identity.RoleScopeGrant, where: g.principal_id == ^u.id),
                prefix: s
              ),
            do: r.id

      before = rows(fx)

      conn = call_as(fx, caller.id, [@admin_role], :delete, "/#{u_row}", nil)

      assert conn.status == 409, conn.resp_body
      assert detail(conn) == "last_tenant_wide_admin"
      assert rows(fx) == before
      assert S.entries(fx, "grant.revoked") == []
      assert [entry] = S.entries(fx, "tenant_admin.guard_refused")
      assert entry.resource_type == "role_scope_grant"
      assert entry.resource_id == u.id
      assert entry.actor_id == caller.id
      assert entry.trace_id == S.trace()

      assert entry.after_state |> Map.keys() |> Enum.sort() ==
               ~w(action actor counted_admins reason_code target_id trace_id)

      assert entry.after_state == %{
               "action" => "revoke_tenant_admin_grant",
               "actor" => caller.id,
               "target_id" => u.id,
               "reason_code" => "last_tenant_wide_admin",
               "counted_admins" => 0,
               "trace_id" => S.trace()
             }

      assert {:ok, :valid} = Audit.verify_chain(s)
    end

    test "T-Z3 the same delete succeeds while another explicit administrator exists" do
      fx = S.tenant!("r517-z3")
      s = fx.schema_name
      ga = RSG.group_of!(s, @admin_role)
      _ = RSG.raw_delete_rows!(s, ga, @admin_role)
      u1 = RSG.member!(s, ga, RSG.user!(s))
      u2 = RSG.member!(s, ga, RSG.user!(s))
      :ok = RSG.raw_user_row!(s, u1.id, @admin_role, nil)
      :ok = RSG.raw_user_row!(s, u2.id, @admin_role, nil)
      caller = user_row_admin!(fx)

      [u1_row] =
        for r <-
              Repo.all(
                from(g in Letflow.Identity.RoleScopeGrant, where: g.principal_id == ^u1.id),
                prefix: s
              ),
            do: r.id

      conn = call_as(fx, caller.id, [@admin_role], :delete, "/#{u1_row}", nil)

      assert conn.status == 204
      assert S.entries(fx, "tenant_admin.guard_refused") == []
      assert [_] = S.entries(fx, "grant.revoked")
    end

    test "T-Z3b a scoped TENANT_ADMIN row for a user principal is created while another explicit administrator exists" do
      fx = S.tenant!("r517-z3b")
      user = RSG.user!(fx.schema_name)

      b = create!(fx, :user, user.id, @admin_role, RSG.node!(fx.schema_name))

      assert b["role"] == @admin_role
      assert S.entries(fx, "tenant_admin.guard_refused") == []
    end

    test "T-Z5 a concurrent holder of lock A blocks create, delete and make-tenant-wide until it is released" do
      fx = S.tenant!("r517-z5")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      [n1, n2, n3, n4] = for _ <- 1..4, do: RSG.node!(s)
      doomed = create!(fx, :group, gid, @worker, n1)
      _keep = create!(fx, :group, gid, @worker, n2)
      widened = S.rowless_group!(fx, "PROCESS_DESIGNER")
      _scoped = create!(fx, :group, widened, "PROCESS_DESIGNER", n4)

      requests = [
        fn -> create(fx, :group, gid, @worker, n3) end,
        fn -> grants(fx, :delete, "/#{doomed["id"]}", nil) end,
        fn -> make_wide(fx, :group, widened, "PROCESS_DESIGNER") end
      ]

      for request <- requests do
        holder = S.hold_admin_lock(s, self())
        assert_receive {:admin_lock_held, _prefix}, 5_000
        task = Task.async(request)

        try do
          assert S.lock_waiter?("pg_advisory_xact_lock"), "the route never queued on lock A"
          assert Task.yield(task, 300) == nil

          send(holder.pid, :release)
          assert {:ok, {:error, :released}} = Task.yield(holder, 5_000)
          assert {:ok, conn} = Task.yield(task, 5_000)
          assert conn.status in [200, 201, 204], conn.resp_body
        after
          S.stop_task(task)
          S.stop_task(holder)
        end
      end
    end

    test "T-Z6 the explicit count: a zero-row TENANT_ADMIN binding counts 0 explicit and 1 counted; a token owner counts in both" do
      fx = S.tenant!("r517-z6")
      s = fx.schema_name
      ga = RSG.group_of!(s, @admin_role)
      assert Identity.count_tenant_wide_admins(s) == 1
      assert Identity.count_explicit_tenant_wide_admins(s) == 1

      _ = RSG.raw_delete_rows!(s, ga, @admin_role)
      assert Identity.count_tenant_wide_admins(s) == 1
      assert Identity.count_explicit_tenant_wide_admins(s) == 0

      owner = RSG.user!(s)

      {:ok, %{token: _token}} =
        Identity.create_token(owner.id, %{roles: [@admin_role], expires_at: nil}, prefix: s)

      assert Identity.count_tenant_wide_admins(s) == 2
      assert Identity.count_explicit_tenant_wide_admins(s) == 1
    end
  end

  # ===========================================================================================
  describe "T-S self-grant" do
    test "T-S1 create for the caller (user) is 409 self_grant_refused, writes no row, and records grant.self_grant_refused in its own transaction" do
      fx = S.tenant!("r517-s1")
      node = RSG.node!(fx.schema_name)
      before = rows(fx)

      conn = create(fx, :user, fx.admin.id, @worker, node)

      assert conn.status == 409
      assert detail(conn) == "self_grant_refused"
      assert rows(fx) == before
      assert [entry] = S.entries(fx, "grant.self_grant_refused")
      assert entry.resource_type == "role_scope_grant"
      assert entry.resource_id == fx.admin.id
      assert entry.actor_id == fx.admin.id
      assert entry.before_state == nil

      assert entry.after_state |> Map.keys() |> Enum.sort() ==
               ~w(act actor credential principal_id principal_type role scope_node_id trace_id)

      assert entry.after_state == %{
               "act" => "create",
               "actor" => fx.admin.id,
               "principal_type" => "user",
               "principal_id" => fx.admin.id,
               "role" => @worker,
               "scope_node_id" => node,
               "trace_id" => S.trace(),
               "credential" => "oidc"
             }
    end

    test "T-S2 create for a group the caller belongs to is refused" do
      fx = S.tenant!("r517-s2")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      _ = RSG.member!(s, gid, fx.admin)
      node = RSG.node!(s)

      conn = create(fx, :group, gid, @worker, node)

      assert conn.status == 409
      assert detail(conn) == "self_grant_refused"
      assert RSG.scoped(gid, @worker, node) not in rows(fx)
      assert [entry] = S.entries(fx, "grant.self_grant_refused")
      assert entry.after_state["principal_type"] == "group"
      assert entry.after_state["principal_id"] == gid
    end

    test "T-S3 make-tenant-wide for the caller is refused (act make_tenant_wide, no scope node)" do
      fx = S.tenant!("r517-s3")
      before = rows(fx)

      conn = make_wide(fx, :user, fx.admin.id, @worker)

      assert conn.status == 409
      assert detail(conn) == "self_grant_refused"
      assert rows(fx) == before
      assert [entry] = S.entries(fx, "grant.self_grant_refused")
      assert entry.after_state["act"] == "make_tenant_wide"
      assert entry.after_state["scope_node_id"] == nil
    end

    test "T-S4 deleting the caller's own scoped row (another remains) is allowed" do
      fx = S.tenant!("r517-s4")
      s = fx.schema_name
      [n1, n2] = for _ <- 1..2, do: RSG.node!(s)
      # RAW rows: the create route refuses to grant the caller itself.
      :ok = RSG.raw_user_row!(s, fx.admin.id, @worker, n1)
      :ok = RSG.raw_user_row!(s, fx.admin.id, @worker, n2)

      [first | _] =
        for r <-
              Repo.all(
                from(g in Letflow.Identity.RoleScopeGrant,
                  where: g.principal_id == ^fx.admin.id and g.role == ^@worker,
                  order_by: g.scope_node_id
                ),
                prefix: s
              ),
            do: r.id

      assert grants(fx, :delete, "/#{first}", nil).status == 204
    end

    test "a refusal event that cannot be written does not turn the refusal into an error (one constant log line, no ids)" do
      fx = S.tenant!("r517-s-audit")
      node = RSG.node!(fx.schema_name)

      log =
        capture_log(fn ->
          conn =
            S.with_audit_fault(fx, "grant.self_grant_refused", fn ->
              create(fx, :user, fx.admin.id, @worker, node)
            end)

          assert conn.status == 409
        end)

      assert S.entries(fx, "grant.self_grant_refused") == []
      assert log =~ "grant_self_refusal_not_recorded"
      # The capture also holds the Ecto debug SQL of the whole test (params carry ids): only the
      # refusal-not-recorded log line itself must be id-free.
      line =
        log
        |> String.split("
")
        |> Enum.find(&(&1 =~ "grant_self_refusal_not_recorded"))
      refute line =~ fx.admin.id
    end

    test "G1 tokens: a TENANT_ADMIN token creates, deletes and makes tenant-wide (credential api_token in every audit entry); a non-admin token gets the uniform 403 on all four routes" do
      fx = S.tenant!("r517-g1")
      s = fx.schema_name
      owner = RSG.user!(s)
      gid = S.rowless_group!(fx, @worker)
      [n1, n2] = for _ <- 1..2, do: RSG.node!(s)

      {:ok, %{plaintext: admin_token}} =
        Identity.create_token(owner.id, %{roles: [@admin_role], expires_at: nil}, prefix: s)

      api = fn token, method, path, body ->
        method
        |> Fixture.api_conn(
          "/api/v1/tenant/role-scope-grants" <> path,
          token,
          fx.tenant.slug,
          body
        )
        |> Fixture.dispatch_api()
      end

      first = api.(admin_token, :post, "", S.create_body(:group, gid, @worker, n1))
      second = api.(admin_token, :post, "", S.create_body(:group, gid, @worker, n2))
      assert first.status == 201, first.resp_body
      assert second.status == 201, second.resp_body
      first_id = Jason.decode!(first.resp_body)["id"]
      second_id = Jason.decode!(second.resp_body)["id"]

      assert api.(admin_token, :delete, "/#{first_id}", nil).status == 204
      assert [revoked] = S.entries(fx, "grant.revoked")
      assert revoked.resource_id == first_id
      assert revoked.actor_id == owner.id
      assert revoked.after_state["credential"] == "api_token"

      wide =
        api.(admin_token, :post, "/make-tenant-wide", %{
          "principal_type" => "group",
          "principal_id" => gid,
          "role" => @worker
        })

      assert wide.status == 200, wide.resp_body
      assert Jason.decode!(wide.resp_body)["removed_scoped_ids"] == [second_id]
      assert [made] = S.entries(fx, "grant.made_tenant_wide")
      assert made.after_state["credential"] == "api_token"
      assert made.actor_id == owner.id

      created = S.entries(fx, "grant.created")
      assert length(created) == 2
      assert Enum.all?(created, &(&1.after_state["credential"] == "api_token"))

      # a token WITHOUT the administrator role: the uniform 403 on all four routes, nothing written
      plain_owner = RSG.user!(s)

      {:ok, %{plaintext: plain_token}} =
        Identity.create_token(plain_owner.id, %{roles: [@worker], expires_at: nil}, prefix: s)

      before = rows(fx)

      for {method, path, body} <- [
            {:post, "", S.create_body(:group, gid, @worker, n1)},
            {:get, "", nil},
            {:delete, "/#{second_id}", nil},
            {:post, "/make-tenant-wide",
             %{"principal_type" => "group", "principal_id" => gid, "role" => @worker}}
          ] do
        conn = api.(plain_token, method, path, body)
        assert conn.status == 403, "#{method} #{path}: #{conn.resp_body}"
        assert Jason.decode!(conn.resp_body)["detail"] == "insufficient permissions"
      end

      assert rows(fx) == before
    end

    test "AC 9 for tokens: a TENANT_ADMIN API token may write grants (credential api_token in the audit), but cannot widen its owner or the owner's groups" do
      fx = S.tenant!("r517-s5")
      s = fx.schema_name
      owner = RSG.user!(s)
      gid = S.rowless_group!(fx, @worker)
      other_user = RSG.user!(s)
      _ = RSG.member!(s, gid, owner)
      other_group = S.rowless_group!(fx, "PROCESS_DESIGNER")
      node = RSG.node!(s)

      {:ok, %{plaintext: token}} =
        Identity.create_token(owner.id, %{roles: [@admin_role], expires_at: nil}, prefix: s)

      api = fn method, path, body ->
        method
        |> Fixture.api_conn(
          "/api/v1/tenant/role-scope-grants" <> path,
          token,
          fx.tenant.slug,
          body
        )
        |> Fixture.dispatch_api()
      end

      # the owner and the owner's group are refused
      for body <- [
            S.create_body(:user, owner.id, @worker, node),
            S.create_body(:group, gid, @worker, node)
          ] do
        conn = api.(:post, "", body)
        assert conn.status == 409, conn.resp_body
        assert Jason.decode!(conn.resp_body)["detail"] == "self_grant_refused"
      end

      refute RSG.scoped(gid, @worker, node) in rows(fx)

      # another user and another group are allowed: tokens may call grant writes
      conn = api.(:post, "", S.create_body(:user, other_user.id, @worker, node))
      assert conn.status == 201, conn.resp_body

      assert api.(:post, "", S.create_body(:group, other_group, "PROCESS_DESIGNER", node)).status ==
               201

      assert api.(:get, "", nil).status == 200

      assert [refusal, _second] = S.entries(fx, "grant.self_grant_refused")
      assert refusal.after_state["credential"] == "api_token"
      assert refusal.actor_id == owner.id
      created = S.entries(fx, "grant.created")
      assert length(created) == 2
      assert Enum.all?(created, &(&1.after_state["credential"] == "api_token"))
      assert Enum.all?(created, &(&1.actor_id == owner.id))
    end
  end

  # ===========================================================================================
  describe "T-U audit events" do
    test "T-U1 grant.created: same transaction, exact keys, credential oidc" do
      fx = S.tenant!("r517-u1")
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(fx.schema_name)
      row = create!(fx, :group, gid, @worker, node)

      assert [entry] = S.entries(fx, "grant.created")
      assert entry.resource_type == "role_scope_grant"
      assert entry.resource_id == row["id"]
      assert entry.actor_id == fx.admin.id
      assert entry.trace_id == S.trace()
      assert entry.before_state == nil

      assert entry.after_state == %{
               "id" => row["id"],
               "principal_type" => "group",
               "principal_id" => gid,
               "role" => @worker,
               "scope_node_id" => node,
               "tenant_wide" => false,
               "trace_id" => S.trace(),
               "credential" => "oidc"
             }
    end

    test "T-U2 grant.revoked: before_state is the row keys; after_state is {credential, actor, trace_id}" do
      fx = S.tenant!("r517-u2")
      gid = S.rowless_group!(fx, @worker)
      [n1, n2] = for _ <- 1..2, do: RSG.node!(fx.schema_name)
      row = create!(fx, :group, gid, @worker, n1)
      _other = create!(fx, :group, gid, @worker, n2)
      assert grants(fx, :delete, "/#{row["id"]}", nil).status == 204

      assert [entry] = S.entries(fx, "grant.revoked")
      assert entry.resource_id == row["id"]

      assert entry.before_state == %{
               "id" => row["id"],
               "principal_type" => "group",
               "principal_id" => gid,
               "role" => @worker,
               "scope_node_id" => n1,
               "tenant_wide" => false
             }

      assert entry.after_state == %{
               "credential" => "oidc",
               "actor" => fx.admin.id,
               "trace_id" => S.trace()
             }
    end

    test "T-U3 grant.made_tenant_wide: exact after_state keys" do
      fx = S.tenant!("r517-u3")
      gid = S.rowless_group!(fx, @worker)
      n1 = RSG.node!(fx.schema_name)
      a = create!(fx, :group, gid, @worker, n1)
      resp = fx |> make_wide(:group, gid, @worker) |> S.body()

      assert [entry] = S.entries(fx, "grant.made_tenant_wide")

      design_keys =
        ~w(id principal_type principal_id role tenant_wide removed_scoped_ids trace_id credential)

      keys = Map.keys(entry.after_state)

      # Design 3.11 lists these keys. The implementation also carries the row's scope_node_id
      # (always nil here): the only extra key tolerated (reported as a deviation).
      assert Enum.all?(design_keys, &(&1 in keys))
      assert Enum.sort(keys -- design_keys) in [[], ["scope_node_id"]]
      assert Map.get(entry.after_state, "scope_node_id") == nil

      assert Map.take(entry.after_state, design_keys) == %{
               "id" => resp["id"],
               "principal_type" => "group",
               "principal_id" => gid,
               "role" => @worker,
               "tenant_wide" => true,
               "removed_scoped_ids" => [a["id"]],
               "trace_id" => S.trace(),
               "credential" => "oidc"
             }
    end

    test "T-U4 a forced audit failure rolls the create and the delete back (500, row state unchanged)" do
      fx = S.tenant!("r517-u4")
      gid = S.rowless_group!(fx, @worker)
      [n1, n2, n3] = for _ <- 1..3, do: RSG.node!(fx.schema_name)
      first = create!(fx, :group, gid, @worker, n1)
      _second = create!(fx, :group, gid, @worker, n2)
      before = rows(fx)

      conn =
        S.with_audit_fault(fx, "grant.created", fn -> create(fx, :group, gid, @worker, n3) end)

      assert conn.status == 500
      assert rows(fx) == before

      conn =
        S.with_audit_fault(fx, "grant.revoked", fn ->
          grants(fx, :delete, "/#{first["id"]}", nil)
        end)

      assert conn.status == 500
      assert rows(fx) == before
      assert S.entries(fx, "grant.revoked") == []
    end

    test "no token value, hash, prefix or claim appears in any grant event" do
      fx = S.tenant!("r517-u5")
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(fx.schema_name)
      create!(fx, :group, gid, @worker, node)
      _ = create(fx, :user, fx.admin.id, @worker, node)

      for action <- ["grant.created", "grant.self_grant_refused"],
          entry <- S.entries(fx, action) do
        encoded = Jason.encode!(Map.take(entry, [:before_state, :after_state, :resource_id]))
        refute encoded =~ "lf_tok_"
        refute encoded =~ "token_hash"
      end
    end

    test "T-U6 the audit listing and GET /audit return every grant event by resource_type; the listing has no action filter (finding F8)" do
      fx = S.tenant!("r517-u6")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      [n1, n2] = for _ <- 1..2, do: RSG.node!(s)
      row = create!(fx, :group, gid, @worker, n1)
      _other = create!(fx, :group, gid, @worker, n2)
      assert grants(fx, :delete, "/#{row["id"]}", nil).status == 204
      _ = make_wide(fx, :group, gid, @worker)
      _ = create(fx, :user, fx.admin.id, @worker, n1)

      assert {:ok, %{items: items}} =
               Audit.list_entries(%{prefix: s, page_size: 100, resource_type: "role_scope_grant"})

      actions = items |> Enum.map(& &1.action) |> Enum.uniq() |> Enum.sort()

      assert actions == [
               "grant.created",
               "grant.made_tenant_wide",
               "grant.revoked",
               "grant.self_grant_refused"
             ]

      # No `action` filter exists: an unknown key narrows nothing. If one is ever added this
      # assertion fails and the filter must be exercised here too (design 3.11, finding F8).
      assert {:ok, %{items: unfiltered}} =
               Audit.list_entries(%{
                 prefix: s,
                 page_size: 100,
                 resource_type: "role_scope_grant",
                 action: "grant.revoked"
               })

      assert length(unfiltered) == length(items)

      conn =
        S.as_admin(
          Letflow.Routers.Audit,
          :get,
          "/?resource_type=role_scope_grant&page_size=100",
          fx,
          nil
        )

      assert conn.status == 200
      mapped = S.body(conn)["items"]
      assert mapped |> Enum.map(& &1["action"]) |> Enum.uniq() |> Enum.sort() == actions
      assert Enum.all?(mapped, &(&1["resource_type"] == "role_scope_grant"))
    end
  end
end
