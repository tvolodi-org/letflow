Code.require_file("codes_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)
Code.require_file("../locations/locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.RouterTest do
  @moduledoc """
  GH #3611 / REQ-667: the five write routes of module `codes` through the full pipeline
  (`Letflow.Router`) with real bearer tokens. Tests H1/H2 (holders), R1..R6 (routes),
  E1..E5 (refusals), T1..T3 (tenancy). `async: false`: tenant provisioning runs DDL.
  On /receive the same key with another body is 409 `idempotency_key_reuse` (T-1153);
  the single-code routes still replay without comparing (runbook item 17).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.CodesFixture, as: Fx
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.LocationsFixture, as: Loc
  alias Letflow.Modules.Codes
  alias Letflow.Repo

  @base "/api/v1/modules/codes"

  setup do
    a = installed!("gh3611a")
    b = installed!("gh3611b")
    node = Loc.node!(a.schema, "N1")

    %{
      a: a,
      b: b,
      node: node,
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
        username: "gh3611-user-#{Ecto.UUID.generate()}",
        display_name: "Codes Router Test User",
        email: "gh3611-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema)

    %{user_id: user.id, plaintext: plaintext, slug: ctx.slug}
  end

  defp call(method, path, user, body) do
    conn(method, @base <> path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> put_req_header("x-trace-id", "t-3611")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp key, do: "k-" <> Ecto.UUID.generate()
  defp strip(body), do: Map.delete(body, "trace_id")

  defp ok!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    json(conn)
  end

  defp post(ctx, path, body, status, user \\ nil),
    do:
      ok!(
        call(:post, path, user || ctx.admin, Map.put_new(body, "idempotency_key", key())),
        status
      )

  defp receive!(ctx, values) do
    entries = Enum.map(values, &%{"value" => &1, "kind" => "barcode"})
    post(ctx, "/receive", %{"entries" => entries}, 201)
  end

  defp code_id!(ctx, value), do: hd(receive!(ctx, [value]))["code_id"]

  defp lookup!(ctx, id) do
    {:ok, rec} = Codes.lookup(ctx.a.schema, id)
    rec
  end

  defp count(schema) do
    import Ecto.Query, only: [from: 2]

    Repo.aggregate(
      from(l in Letflow.Entities.Record.Latest, where: l.entity_type == "code_tag"),
      :count,
      prefix: schema
    )
  end

  describe "holders" do
    test "H1 TENANT_ADMIN receives codes", ctx do
      assert [%{"value" => "H1"}] = receive!(ctx, ["H1"])
    end

    test "H2 operator, worker and auditor are refused", ctx do
      for role <- ["PROCESS_OPERATOR", "TASK_WORKER", "TENANT_AUDITOR"] do
        u = user!(ctx.a, [role])

        conn =
          call(:post, "/receive", u, %{
            "idempotency_key" => key(),
            "entries" => [%{"value" => "x"}]
          })

        assert conn.status == 403, role
      end

      assert count(ctx.a.schema) == 0
    end

    test "H3 only TENANT_ADMIN and PLATFORM_ADMIN hold CodesWrite" do
      holders =
        "priv/permission_matrix/effective.golden"
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(&String.split(&1, " "))
        |> Enum.filter(&match?([_role, "CodesWrite", "true" | _], &1))
        |> Enum.map(&hd/1)

      assert Enum.sort(holders) == ["PLATFORM_ADMIN", "TENANT_ADMIN"]
    end
  end

  describe "routes" do
    test "R1 receive two values gives 201 and two records", ctx do
      res = receive!(ctx, ["R1a", "R1b"])
      assert Enum.map(res, & &1["value"]) == ["R1a", "R1b"]
      assert count(ctx.a.schema) == 2
    end

    test "R1b receive: same key and body replays, other body is 409", ctx do
      k = key()

      body = fn v ->
        %{"idempotency_key" => k, "entries" => [%{"value" => v, "kind" => "barcode"}]}
      end

      assert [%{"value" => "R1b1"}] = ok!(call(:post, "/receive", ctx.admin, body.("R1b1")), 201)
      assert [%{"value" => "R1b1"}] = ok!(call(:post, "/receive", ctx.admin, body.("R1b1")), 201)
      res = ok!(call(:post, "/receive", ctx.admin, body.("R1b2")), 409)
      assert res["reason"] == "idempotency_key_reuse"
      assert count(ctx.a.schema) == 1
    end

    test "R2 a taken value in entry 1 is entry_invalid and nothing is created", ctx do
      receive!(ctx, ["R2x"])

      res =
        post(
          ctx,
          "/receive",
          %{
            "entries" => [
              %{"value" => "R2new", "kind" => "barcode"},
              %{"value" => "R2x", "kind" => "barcode"}
            ]
          },
          422
        )

      assert res["reason"] == "entry_invalid"
      assert res["index"] == 1
      assert res["entry_reason"] == "value_taken"
      refute res |> Jason.encode!() |> String.contains?("R2new")
      assert count(ctx.a.schema) == 1
    end

    test "R3 assign, R4 release", ctx do
      id = code_id!(ctx, "R3")

      res =
        post(
          ctx,
          "/#{id}/assign",
          %{"target_type" => "location_node", "target_id" => ctx.node.record_id},
          200
        )

      assert res["status"] == "assigned"
      assert lookup!(ctx, id)["status"] == "assigned"

      post(ctx, "/#{id}/release", %{}, 200)
      assert lookup!(ctx, id)["status"] == "not_assigned"
    end

    test "R5 retire", ctx do
      id = code_id!(ctx, "R5")
      post(ctx, "/#{id}/retire", %{}, 200)
      assert lookup!(ctx, id)["status"] == "retired"
    end

    test "R6 change value of a rewritable tag", ctx do
      [c] =
        post(ctx, "/receive", %{"entries" => [%{"value" => "R6", "kind" => "epc"}]}, 201)

      post(ctx, "/#{c["code_id"]}/value", %{"value" => "R6new"}, 200)
      assert lookup!(ctx, c["code_id"])["value"] == "R6new"
    end
  end

  describe "refusals" do
    test "E1 assign of a retired code", ctx do
      id = code_id!(ctx, "E1")
      post(ctx, "/#{id}/retire", %{}, 200)

      res =
        post(
          ctx,
          "/#{id}/assign",
          %{"target_type" => "location_node", "target_id" => ctx.node.record_id},
          422
        )

      assert res["reason"] == "code_retired"
    end

    test "E2 an unknown target id gives the 404 of an unknown code", ctx do
      id = code_id!(ctx, "E2")

      unknown =
        call(:post, "/#{Ecto.UUID.generate()}/retire", ctx.admin, %{"idempotency_key" => key()})

      assert unknown.status == 404

      other = Loc.node!(ctx.b.schema, "N-B")

      for target <- [Ecto.UUID.generate(), other.record_id] do
        conn =
          call(:post, "/#{id}/assign", ctx.admin, %{
            "idempotency_key" => key(),
            "target_type" => "location_node",
            "target_id" => target
          })

        assert conn.status == 404
        assert strip(json(conn)) == strip(json(unknown))
      end
    end

    test "E3 an empty batch is batch_size", ctx do
      assert post(ctx, "/receive", %{"entries" => []}, 422)["reason"] == "batch_size"
    end

    test "E4 a missing or blank idempotency_key", ctx do
      for body <- [
            %{"entries" => [%{"value" => "x"}]},
            %{"idempotency_key" => " ", "entries" => []}
          ] do
        res = ok!(call(:post, "/receive", ctx.admin, body), 422)
        assert res["reason"] == "field_invalid"
        assert res["field"] == "idempotency_key"
      end
    end

    test "E5 an extra or missing body key", ctx do
      id = code_id!(ctx, "E5")

      res = post(ctx, "/#{id}/retire", %{"extra" => 1}, 422)
      assert res["reason"] == "field_not_allowed"

      res = post(ctx, "/#{id}/value", %{}, 422)
      assert res["reason"] == "field_invalid"
      assert res["field"] == "value"
    end
  end

  describe "tenancy" do
    test "T1 tenant B cannot touch a code of tenant A", ctx do
      id = code_id!(ctx, "T1")
      before = lookup!(ctx, id)

      unknown =
        call(:post, "/#{Ecto.UUID.generate()}/retire", ctx.admin_b, %{"idempotency_key" => key()})

      calls = [
        {"/#{id}/assign", %{"target_type" => "location_node", "target_id" => ctx.node.record_id}},
        {"/#{id}/release", %{}},
        {"/#{id}/retire", %{}},
        {"/#{id}/value", %{"value" => "T1new"}}
      ]

      for {path, body} <- calls do
        conn = call(:post, path, ctx.admin_b, Map.put(body, "idempotency_key", key()))
        assert conn.status == 404, path
        assert strip(json(conn)) == strip(json(unknown))
      end

      assert lookup!(ctx, id) == before
    end

    test "T2 a tenant identifier in the body is refused; no route has a tenant param", ctx do
      for k <- ["tenant_id", "prefix"] do
        res =
          ok!(
            call(:post, "/receive", ctx.admin_b, %{
              "idempotency_key" => key(),
              "entries" => [%{"value" => "T2"}],
              k => ctx.a.tenant_id
            }),
            422
          )

        assert res["reason"] == "field_not_allowed"
      end

      assert count(ctx.b.schema) == 0

      paths = Enum.map(Codes.manifest().route_policies, &elem(&1, 1))
      refute Enum.any?(paths, &String.contains?(&1, "tenant"))
      src = File.read!(Path.join(File.cwd!(), "lib/letflow/modules/codes/router.ex"))
      refute src =~ ~s(params["tenant)
    end

    test "T3 a tenant without codes answers the dispatcher 404" do
      t = Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "gh3611n")
      slug = Repo.get!(Letflow.Identity.Tenant, t.tenant_id).slug
      u = user!(%{schema: t.schema_name, slug: slug}, ["TENANT_ADMIN"])
      body = %{"idempotency_key" => key()}
      unknown = call(:post, "/nothing-here/x/y", u, body)

      for path <- ["/receive", "/x/retire"] do
        conn = call(:post, path, u, body)
        assert conn.status == 404, path
        assert strip(json(conn)) == strip(json(unknown))
      end
    end
  end
end
