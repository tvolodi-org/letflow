defmodule Letflow.Routers.EntityTypeExtensionsTest do
  @moduledoc """
  REQ-609 / GH #3417: the `/entity-type-extensions` routes. V: the uniform 404; R: statuses and
  shapes; P: the permission is checked before the body; X: INV-10 cross-tenant negative tests;
  A: an audit failure answers a detail-free 500.

  `async: false`: the platform tenant pin is VM-global and tenants are provisioned.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Entities.EntityTypeExtension
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Repo
  alias Letflow.Routers.EntityTypeExtensions, as: Router
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TestSupport.DefinitionsListFixture, as: Defs

  @admin ["TENANT_ADMIN"]
  @type_name "fxm_site"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)

    for t <- [tenants.a, tenants.b, tenants.p] do
      :ok = Fx.install_managed_fixture!(t.schema_name)
    end

    Fx.define_type!(tenants.a.schema_name, "tx_owned", %{append_only: false})
    {:ok, tenants}
  end

  defp call(method, path, fixture, roles, body \\ nil, opts \\ []) do
    conn =
      Fixture.router_conn(method, path, fixture, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
        tenant_id: fixture.tenant_id,
        roles: roles
      })
      |> Plug.Conn.assign(:scoped_opts, prefix: fixture.schema_name)

    Router.call(conn, Router.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp untraced(conn), do: conn |> json() |> Map.delete("trace_id")

  defp shape(conn),
    do: {conn.status, untraced(conn), Plug.Conn.get_resp_header(conn, "content-type")}

  defp body(name, overrides \\ %{}),
    do:
      Map.merge(
        %{"entity_type" => @type_name, "name" => name, "spec" => %{"type" => "string"}},
        overrides
      )

  defp create(fixture, name, overrides \\ %{}, roles \\ @admin),
    do: call(:post, "/", fixture, roles, body(name, overrides))

  defp row!(fixture, name) do
    conn = create(fixture, name)
    assert conn.status == 201, conn.resp_body
    json(conn)
  end

  defp count(fixture),
    do: Repo.aggregate(EntityTypeExtension, :count, :id, prefix: fixture.schema_name)

  defp audits(fixture), do: Repo.aggregate(Entry, :count, :id, prefix: fixture.schema_name)

  describe "V uniform 404" do
    test "V1..V4 an unextensible type answers one identical 404 on every route", %{a: a} do
      user = Ecto.UUID.generate()
      Defs.restrict!(a.schema_name, "fxm_unit")

      absent = call(:delete, "/#{Ecto.UUID.generate()}", a, @admin)
      assert absent.status == 404

      for type <- ["no_such_type", "tx_owned", "fxm_ledger", "fxm_unit"] do
        post = call(:post, "/", a, @admin, body("x_a", %{"entity_type" => type}), user_id: user)
        assert shape(post) == shape(absent), type

        get = call(:get, "/?entity_type=#{type}", a, @admin, nil, user_id: user)
        assert shape(get) == shape(absent), type
      end

      malformed = call(:delete, "/not-a-uuid", a, @admin)
      assert shape(malformed) == shape(absent)
      assert count(a) == 0
    end
  end

  describe "R shapes" do
    test "R1 POST answers 201 with the row, positions count up", %{a: a} do
      one = row!(a, "x_one")
      two = row!(a, "x_two")

      assert Map.keys(one) |> Enum.sort() ==
               ~w(entity_type id kind name position spec status)

      assert {one["kind"], one["status"], one["position"], two["position"]} ==
               {"field", "active", 1, 2}
    end

    test "R2 GET lists by position with retired rows; a missing entity_type is 422", %{a: a} do
      first = row!(a, "x_b")
      row!(a, "x_a")
      assert call(:delete, "/#{first["id"]}", a, @admin).status == 200

      conn = call(:get, "/?entity_type=#{@type_name}", a, @admin)
      assert conn.status == 200
      assert [%{"name" => "x_b", "status" => "retired"}, %{"name" => "x_a"}] = json(conn)["items"]

      assert call(:get, "/", a, @admin).status == 422
      assert call(:get, "/?entity_type=", a, @admin).status == 422
    end

    test "R3 DELETE retires, keeps the row, and a repeat writes no audit entry", %{a: a} do
      r = row!(a, "x_keep")
      conn = call(:delete, "/#{r["id"]}", a, @admin)
      assert conn.status == 200
      assert %{"status" => "retired", "name" => "x_keep"} = json(conn)
      assert count(a) == 1
      audit_count = audits(a)

      again = call(:delete, "/#{r["id"]}", a, @admin)
      assert again.status == 200
      assert json(again)["status"] == "retired"
      assert audits(a) == audit_count
    end

    test "R4 PUT and PATCH are not routes", %{a: a} do
      r = row!(a, "x_nochange")

      for {method, path} <- [put: "/#{r["id"]}", patch: "/#{r["id"]}", put: "/", patch: "/"] do
        conn = call(method, path, a, @admin, %{"name" => "x_other"})
        assert conn.status in [403, 404, 405], "#{method} #{path}: #{conn.status}"
      end

      assert [%{name: "x_nochange"}] = Repo.all(EntityTypeExtension, prefix: a.schema_name)
    end

    test "R5 each refusal is a 422 with its code and no echo of the submission", %{a: a} do
      Repo.update_all(
        from(e in Letflow.Entities.EntityDefinition, where: e.name == @type_name),
        [
          set: [
            definition_json: %{
              "name" => @type_name,
              "fields" => [%{"name" => "x_reserved", "type" => "string"}]
            }
          ]
        ],
        prefix: a.schema_name
      )

      row!(a, "x_taken")
      before = {count(a), audits(a)}

      cases = [
        {body("bad name"), "invalid_extension_key"},
        {body("x_reserved"), "extension_key_reserved"},
        {body("x_taken"), "extension_key_taken"},
        {body("x_new", %{"spec" => %{"type" => "json"}}), "invalid_extension_spec"}
      ]

      for {request, code} <- cases do
        conn = call(:post, "/", a, @admin, request)
        assert conn.status == 422, conn.resp_body
        assert conn.resp_body =~ code
        refute conn.resp_body =~ "bad name"
      end

      assert {count(a), audits(a)} == before
    end

    test "R6 the cap answers extension_limit_reached", %{a: a} do
      for i <- 1..50, do: row!(a, "x_c#{i}")
      conn = create(a, "x_over")
      assert conn.status == 422
      assert conn.resp_body =~ "extension_limit_reached"
    end
  end

  describe "P permission" do
    test "P2 other roles are refused with identical answers before the body is read", %{a: a} do
      for roles <- [["PROCESS_DESIGNER"], ["TASK_WORKER"], ["TENANT_AUDITOR"]] do
        valid = create(a, "x_p", %{}, roles)
        invalid = create(a, "bad name", %{}, roles)
        assert valid.status == 403
        assert shape(valid) == shape(invalid)
        assert call(:get, "/?entity_type=#{@type_name}", a, roles).status == 403
        assert call(:delete, "/#{Ecto.UUID.generate()}", a, roles).status == 403
      end

      assert count(a) == 0
    end

    test "P3 PLATFORM_ADMIN outside the platform tenant is refused", %{a: a} do
      assert create(a, "x_p", %{}, ["PLATFORM_ADMIN"]).status == 403
    end
  end

  describe "X cross-tenant (INV-10)" do
    test "X1 a tenant identifier in the body, query or header never moves the write", %{
      a: a,
      b: b
    } do
      conn =
        Fixture.router_conn(
          :post,
          "/?tenant_id=#{b.tenant_id}",
          a,
          @admin,
          body("x_mine", %{"tenant_id" => b.tenant_id})
        )
        |> Plug.Conn.put_req_header("x-tenant-id", b.tenant_id)
        |> Plug.Conn.assign(:scoped_opts, prefix: a.schema_name)

      assert Router.call(conn, Router.init([])).status == 201
      assert count(a) == 1
      assert count(b) == 0
      assert [%{tenant_id: tenant_id}] = Repo.all(EntityTypeExtension, prefix: a.schema_name)
      assert tenant_id == a.tenant_id
    end

    test "X2 B lists none of A's rows", %{a: a, b: b} do
      row!(a, "x_secret")
      conn = call(:get, "/?entity_type=#{@type_name}", b, @admin)
      assert conn.status == 200
      assert json(conn)["items"] == []
    end

    test "X3 B cannot retire A's row: the unknown-id 404, A unchanged", %{a: a, b: b} do
      r = row!(a, "x_a_only")
      audit_before = audits(a)
      absent = call(:delete, "/#{Ecto.UUID.generate()}", b, @admin)
      conn = call(:delete, "/#{r["id"]}", b, @admin)
      assert shape(conn) == shape(absent)
      assert [%{status: "active"}] = Repo.all(EntityTypeExtension, prefix: a.schema_name)
      assert audits(a) == audit_before
    end

    test "X4 the same name and the caps are per tenant", %{a: a, b: b} do
      for i <- 1..50, do: row!(a, "x_c#{i}")
      assert create(a, "x_c51").status == 422
      assert create(b, "x_c1").status == 201
    end

    test "X5 the platform tenant's admin sees none of the others' rows, as an empty list",
         %{a: a, b: b, p: p} do
      row!(a, "x_in_a")
      row!(b, "x_in_b")
      conn = call(:get, "/?entity_type=#{@type_name}", p, ["PLATFORM_ADMIN"])
      assert conn.status == 200
      assert json(conn)["items"] == []
    end
  end

  describe "A audit failure" do
    test "A3 a dropped audit table answers a detail-free 500 and stores nothing", %{a: a} do
      Repo.query!(~s(DROP TABLE "#{a.schema_name}".audit_entries))
      conn = create(a, "x_boom")
      assert conn.status == 500
      refute conn.resp_body =~ "audit_entries"
      assert count(a) == 0
    end
  end
end
