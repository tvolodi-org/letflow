Code.require_file("codes_fixture.exs", __DIR__)
Code.require_file("../locations/locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.ResolveRouterTest do
  @moduledoc """
  GH #3797 / REQ-730: `POST /api/v1/modules/codes/resolve` through the full pipeline with real
  bearer tokens. Holders H1/H2, answers A1..A7, refusals N1..N3 (decision 0076 R7 ruling 2, fail
  closed), bodies B1..B6, tenancy T1..T3. `async: false`: tenant provisioning runs DDL.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.CodesFixture, as: Fx
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.LocationsFixture, as: Loc
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Codes
  alias Letflow.Repo

  @base "/api/v1/modules/codes"

  setup do
    a = installed!("gh3797a")
    b = installed!("gh3797b")

    %{
      a: a,
      b: b,
      node: Loc.node!(a.schema, "N1"),
      admin: user!(a, ["TENANT_ADMIN"]),
      admin_b: user!(b, ["TENANT_ADMIN"])
    }
  end

  defp installed!(prefix) do
    ctx = Fx.installed_tenant!(prefix)
    Fx.install_module!(ctx.tenant_id, "org")
    Fx.install_module!(ctx.tenant_id, "locations")
    Fx.install_module!(ctx.tenant_id, "catalog_items")
    ctx
  end

  defp user!(ctx, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3797-user-#{Ecto.UUID.generate()}",
        display_name: "Codes Resolve Test User",
        email: "gh3797-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema)

    %{user_id: user.id, plaintext: plaintext, slug: ctx.slug}
  end

  defp call(path, user, body),
    do: M.call(:post, @base, path, user, body, "t-3797")

  defp resolve(user, value), do: call("/resolve", user, %{"value" => value})
  defp json(conn), do: M.json(conn)
  defp strip(body), do: M.strip(body)

  defp ok!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    json(conn)
  end

  @keys ~w(code_id value kind status target_type target_id assignment_id)

  # Row counts of the three code types and of the audit table: a read must change none of them.
  defp snapshot(schema) do
    import Ecto.Query, only: [from: 2]

    types = ["code_tag", "code_assignment", "code_value_change"]

    counts =
      for t <- types,
          do:
            Repo.aggregate(
              from(l in Letflow.Entities.Record.Latest, where: l.entity_type == ^t),
              :count,
              prefix: schema
            )

    audit = Repo.query!("SELECT count(*) FROM \"#{schema}\".audit_entries").rows
    {counts, audit}
  end

  defp not_found_body(ctx) do
    conn = call("/#{Ecto.UUID.generate()}/release", ctx.admin, %{"idempotency_key" => "k"})
    ok!(conn, 404) |> strip()
  end

  describe "holders" do
    test "H1 TENANT_ADMIN resolves an assigned code", ctx do
      tag = Fx.tag!(ctx.a.schema, "H1", %{"status" => "assigned"})
      Fx.assign!(ctx.a.schema, tag, "location_node", ctx.node.record_id)
      assert %{"status" => "assigned"} = ok!(resolve(ctx.admin, "H1"), 200)
    end

    test "H2 designer, operator, worker and auditor are refused", ctx do
      Fx.tag!(ctx.a.schema, "H2")

      for role <- ["PROCESS_DESIGNER", "PROCESS_OPERATOR", "TASK_WORKER", "TENANT_AUDITOR"] do
        assert resolve(user!(ctx.a, [role]), "H2").status == 403, role
      end
    end

    test "H3 only TENANT_ADMIN and PLATFORM_ADMIN hold CodesRead" do
      holders =
        "priv/permission_matrix/effective.golden"
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(&String.split(&1, " "))
        |> Enum.filter(&match?([_role, "CodesRead", "true" | _], &1))
        |> Enum.map(&hd/1)

      assert Enum.sort(holders) == ["PLATFORM_ADMIN", "TENANT_ADMIN"]
    end
  end

  describe "answers" do
    test "A1 location_node target", ctx do
      tag = Fx.tag!(ctx.a.schema, "A1", %{"status" => "assigned"})
      Fx.assign!(ctx.a.schema, tag, "location_node", ctx.node.record_id)
      body = ok!(resolve(ctx.admin, "A1"), 200)
      assert {:ok, expected} = Codes.resolve(ctx.a.schema, "A1")
      assert strip(body) == expected
      assert body["target_type"] == "location_node"
    end

    test "A2 catalog_item target", ctx do
      tag = Fx.tag!(ctx.a.schema, "A2", %{"status" => "assigned"})
      Fx.assign!(ctx.a.schema, tag, "catalog_item", Ecto.UUID.generate())
      body = ok!(resolve(ctx.admin, "A2"), 200)
      assert {:ok, expected} = Codes.resolve(ctx.a.schema, "A2")
      assert strip(body) == expected
    end

    test "A3 catalog_lot target", ctx do
      tag = Fx.tag!(ctx.a.schema, "A3", %{"status" => "assigned"})
      Fx.assign!(ctx.a.schema, tag, "catalog_lot", Ecto.UUID.generate())
      body = ok!(resolve(ctx.admin, "A3"), 200)
      assert {:ok, expected} = Codes.resolve(ctx.a.schema, "A3")
      assert strip(body) == expected
    end

    test "A4 not assigned", ctx do
      Fx.tag!(ctx.a.schema, "A4")
      body = ok!(resolve(ctx.admin, "A4"), 200)
      assert body["status"] == "not_assigned"
      assert [body["target_type"], body["target_id"], body["assignment_id"]] == [nil, nil, nil]
    end

    test "A5 retired: sent value and five nulls", ctx do
      tag = Fx.tag!(ctx.a.schema, "A5")
      Fx.set_status!(ctx.a.schema, tag, "retired")
      body = ok!(resolve(ctx.admin, "A5"), 200)

      assert strip(body) == %{
               "code_id" => nil,
               "value" => "A5",
               "kind" => nil,
               "status" => "retired",
               "target_type" => nil,
               "target_id" => nil,
               "assignment_id" => nil
             }
    end

    test "A6 assigned with no open assignment is assignment_conflict", ctx do
      tag = Fx.tag!(ctx.a.schema, "A6", %{"status" => "assigned"})
      body = ok!(resolve(ctx.admin, "A6"), 200)
      assert tag.record_id
      assert body["status"] == "assignment_conflict"
      assert body["value"] == "A6"
      assert body["code_id"] == nil
    end

    test "A7 every 200 body has exactly the seven keys", ctx do
      Fx.tag!(ctx.a.schema, "A7")
      body = ok!(resolve(ctx.admin, "A7"), 200)
      assert Enum.sort(Map.keys(strip(body))) == Enum.sort(@keys)
    end
  end

  describe "refusals" do
    test "N1 unknown value is the 404 of an unknown code id", ctx do
      assert ok!(resolve(ctx.admin, "nope"), 404) |> strip() == not_found_body(ctx)
    end

    test "N2 a case-only difference is a 404", ctx do
      Fx.tag!(ctx.a.schema, "AbC")
      assert ok!(resolve(ctx.admin, "abc"), 404) |> strip() == not_found_body(ctx)
    end

    test "N3 decision 0076 R7 ruling 2: a target type with no scope declaration is a 404", ctx do
      tag = Fx.tag!(ctx.a.schema, "N3", %{"status" => "assigned"})
      Fx.assign!(ctx.a.schema, tag, "no_such_type", Ecto.UUID.generate())
      assert ok!(resolve(ctx.admin, "N3"), 404) |> strip() == not_found_body(ctx)
    end
  end

  describe "bodies" do
    test "B1 missing value", ctx do
      ok!(call("/resolve", ctx.admin, %{}), 422)
      assert call("/resolve", ctx.admin, %{}).resp_body =~ "value"
    end

    test "B2 value 7 and B3 value null", ctx do
      assert call("/resolve", ctx.admin, %{"value" => 7}).status == 422
      assert call("/resolve", ctx.admin, %{"value" => nil}).status == 422
    end

    test "B4 extra keys incl. idempotency_key and tenant_id are refused", ctx do
      for extra <- ["idempotency_key", "other", "tenant_id"] do
        conn = call("/resolve", ctx.admin, %{"value" => "x", extra => "y"})
        assert conn.status == 422, extra
        assert conn.resp_body =~ extra
      end
    end

    test "B5 a value with plus and trailing space resolves as sent", ctx do
      Fx.tag!(ctx.a.schema, "A+b ")

      assert %{"status" => "not_assigned", "value" => "A+b "} =
               ok!(resolve(ctx.admin, "A+b "), 200)

      assert resolve(ctx.admin, "A+b").status == 404
    end

    test "B6 a request writes no code rows and no audit entries", ctx do
      tag = Fx.tag!(ctx.a.schema, "B6", %{"status" => "assigned"})
      Fx.assign!(ctx.a.schema, tag, "location_node", ctx.node.record_id)
      before = snapshot(ctx.a.schema)

      for v <- ["B6", "unknown", ""], do: resolve(ctx.admin, v)
      call("/resolve", ctx.admin, %{})

      assert snapshot(ctx.a.schema) == before
    end
  end

  describe "tenancy" do
    test "T1 a value that exists only in tenant A is a 404 for tenant B", ctx do
      Fx.tag!(ctx.a.schema, "T1")

      assert ok!(resolve(ctx.admin_b, "T1"), 404) |> strip() ==
               not_found_body(%{admin: ctx.admin_b})

      assert %{"status" => "not_assigned"} = ok!(resolve(ctx.admin, "T1"), 200)
    end

    test "T2 the route reads no tenant identifier from the request" do
      src = File.read!("lib/letflow/modules/codes/router.ex")
      [_, resolve_src] = String.split(src, "defp resolve_action(conn) do", parts: 2)
      [resolve_src | _] = String.split(resolve_src, "defp render_resolve", parts: 2)
      refute resolve_src =~ "params[\"tenant"
      refute resolve_src =~ "tenant_id"
    end

    test "T3 a tenant without codes installed gets the dispatcher 404" do
      ctx = Fx.installed_tenant!("gh3797c")
      admin = user!(ctx, ["TENANT_ADMIN"])
      assert resolve(admin, "x").status == 404
    end
  end
end
