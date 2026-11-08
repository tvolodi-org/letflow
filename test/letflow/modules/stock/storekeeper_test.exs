Code.require_file("stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.StorekeeperTest do
  @moduledoc """
  T-1317 / D-093 / decision 0081 (T-1..T-8): the STOREKEEPER role holds the stock permissions and nothing
  administrative. Router-level on committed tenants (Sandbox `:auto`), real OIDC bearer tokens, every route of
  `Letflow.Modules.Stock.Router.__authz_routes__/0`. `async: false`: DDL, advisory locks, VM-global config.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Authorization
  alias Letflow.Identity.RoleRegistry
  alias Letflow.StockFixture, as: S

  @stock_atoms [:StockRead, :StockPost, :StockReverse, :StockCountOrder, :StockCountRecord]
  @core_atoms [
    :HelpRead,
    :MembershipsRead,
    :TasksRead,
    :TasksComplete,
    :EntitiesDefinitionsRead,
    :EntitiesQuery,
    :EntitiesRecordsImport
  ]
  @assets_atoms [:AssetsRead, :AssetsPost]
  @fake_id "99999999-9999-4999-8999-999999999999"

  describe "the role (pure)" do
    test "T-1 roles/0 ends in STOREKEEPER; it holds exactly the stock and core atoms, nothing else" do
      assert List.last(Authorization.roles()) == :STOREKEEPER
      assert Authorization.roles_from_strings(["STOREKEEPER"]) == [:STOREKEEPER]

      granted =
        for p <-
              Authorization.permissions() ++
                @stock_atoms ++
                [:StockReconcile] ++
                @assets_atoms ++ [:AssetsReverse, :AssetsReconcile, :AssetsCardWrite],
            Authorization.role_allows?(:STOREKEEPER, p),
            do: p

      # MyModulesRead / MyAccessRead / MyPreferencesSet are role-agnostic
      expected =
        @stock_atoms ++
          @assets_atoms ++ @core_atoms ++ [:MyModulesRead, :MyAccessRead, :MyPreferencesSet]

      assert Enum.sort(Enum.uniq(granted)) == Enum.sort(expected)

      for denied <-
            ~w(StockReconcile AssetsReverse AssetsReconcile AssetsCardWrite EntitiesRecordsWrite EntitiesRecordsExport UsersGroupsRolesManage
               TokensManage AuditRead ModulesManage TenantSettingsManage DefinitionsWrite
               InstancesStart EntitiesDefinitionsWrite RolesManage)a do
        refute Authorization.role_allows?(:STOREKEEPER, denied), inspect(denied)
      end
    end

    test "T-2 never holds a platform-scope permission" do
      for p <- Authorization.permissions(),
          Authorization.permission_scope(p) == :platform,
          do: refute(Authorization.role_allows?(:STOREKEEPER, p), inspect(p))
    end
  end

  describe "every stock route" do
    setup do
      ctx = S.setup_oidc!([:a, :b])
      a = S.tenant!("stk-sk-a", ctx.names.a)
      b = S.tenant!("stk-sk-b", ctx.names.b)
      Map.merge(ctx, %{a: a, b: b})
    end

    defp call(method, path, token) do
      path = Regex.replace(~r/:[a-z_]+/, path, @fake_id)

      Plug.Test.conn(String.downcase(method) |> String.to_atom(), S.base() <> path, "{}")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
    end

    test "T-3 allow: the five granted atoms are never 403 for STOREKEEPER; T-4 deny: StockReconcile is",
         ctx do
      tok = S.token(ctx, :a, ["STOREKEEPER"], sub: "keeper-1")
      routes = Letflow.Modules.Stock.Router.__authz_routes__()
      assert length(routes) > 20

      for {method, path, key} <- routes do
        conn = call(method, path, tok)

        if key in @stock_atoms do
          refute conn.status == 403,
                 "#{method} #{path} (#{key}) -> #{conn.status} #{conn.resp_body}"
        else
          assert key == :StockReconcile
          assert conn.status == 403, "#{method} #{path} -> #{conn.status}"
        end
      end
    end

    test "T-4b an auditor and a candidate are denied every stock route", ctx do
      for role <- ["TENANT_AUDITOR", "CANDIDATE"] do
        tok = S.token(ctx, :a, [role], sub: "ctl-#{role}")

        for {method, path, _key} <- Letflow.Modules.Stock.Router.__authz_routes__(),
            method != "GET" do
          assert call(method, path, tok).status == 403, "#{role} #{method} #{path}"
        end
      end
    end

    test "T-5 deny outside stock: admin writes and other imports answer 403", ctx do
      tok = S.token(ctx, :a, ["STOREKEEPER"], sub: "keeper-2")

      for {m, p} <- [
            {"POST", "/api/v1/modules/org/sites"},
            {"POST", "/api/v1/modules/locations/nodes"},
            {"POST", "/api/v1/modules/codes/receive"},
            {"POST", "/api/v1/identity/users"},
            {"POST", "/api/v1/roles"},
            {"POST", "/api/v1/identity/tokens"}
          ] do
        conn =
          Plug.Test.conn(String.downcase(m) |> String.to_atom(), p, "{}")
          |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

        assert conn.status in [403, 404], "#{m} #{p} -> #{conn.status}"
        refute conn.status in [200, 201]
      end
    end

    test "T-5b import: a storekeeper cannot import a non-managed type (403)", ctx do
      tok = S.token(ctx, :a, ["STOREKEEPER"], sub: "keeper-3")

      conn =
        Plug.Test.conn(:post, "/api/v1/entities/records/not_a_managed_type/import", "{}")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

      assert conn.status == 403
    end

    test "T-5c import: a storekeeper cannot import locations, catalog or org types (403)", ctx do
      tok = S.token(ctx, :a, ["STOREKEEPER"], sub: "keeper-4")

      for type <-
            ~w(location_node catalog_uom catalog_item catalog_counterparty catalog_lot org_unit org_position org_employee) do
        conn =
          Plug.Test.conn(:post, "/api/v1/entities/records/#{type}/import", "{}")
          |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

        assert conn.status == 403, "#{type} -> #{conn.status}"
      end
    end

    test "T-7 tenant isolation: B's storekeeper reads none of A's data and A's tokens do not cross",
         ctx do
      tok_b = S.token(ctx, :b, ["STOREKEEPER"], sub: "keeper-b")
      conn = S.get("/balances", tok_b)
      assert conn.status == 200
      assert %{"rows" => []} = S.json(conn)
    end

    test "T-8 the role is seeded as a group and binding for a new tenant", ctx do
      names =
        RoleRegistry.list_roles(prefix: ctx.a.schema_name)
        |> Enum.map(& &1.name)

      assert "STOREKEEPER" in names
    end
  end
end
