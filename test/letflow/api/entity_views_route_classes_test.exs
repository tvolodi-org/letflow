defmodule Letflow.Api.EntityViewsRouteClassesTest do
  @moduledoc """
  REQ-555 / GH #3157, criteria 3 and 7 (decision 0066 D4; design ids M1-M4):

    * M1 `:EntitiesViewsManage` is a core permission of TENANT scope, second to last (REQ-563 appended :NotificationTemplatesManage); TENANT_ADMIN
      holds it; every other tenant built-in role does not;
    * M2 PLATFORM_ADMIN is denied it outside the platform tenant (0046 D4);
    * M3 the five routes resolve their policy keys: reads `:EntitiesQuery`, writes the new key;
    * M4 the five routes are mounted, all declared `:tenant_wide`, none default-sourced, and the
      router is one of the data routers whose default-sourced routes fail the walk.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  describe "M1 permission" do
    test "a core permission of tenant scope, second to last" do
      assert Authorization.core_permissions() |> Enum.take(-2) |> hd() == :EntitiesViewsManage
      assert Authorization.permission_scope(:EntitiesViewsManage) == :tenant
      assert Authorization.required_permission(:EntitiesViewsManage) == :EntitiesViewsManage
    end

    test "TENANT_ADMIN holds it; every other tenant built-in role does not" do
      assert Authorization.role_allows?(:TENANT_ADMIN, :EntitiesViewsManage)

      others = Authorization.roles() -- [:TENANT_ADMIN, :PLATFORM_ADMIN]
      assert length(others) == 6

      for role <- others do
        refute Authorization.role_allows?(role, :EntitiesViewsManage), "#{role}"
      end
    end
  end

  describe "M2 evaluation" do
    test "PLATFORM_ADMIN outside the platform tenant is denied; the tenant admin is allowed" do
      outside = %AccessContext{
        user_id: "u-555",
        roles: [:PLATFORM_ADMIN],
        platform_tenant?: false
      }

      admin = %AccessContext{user_id: "u-555", roles: [:TENANT_ADMIN], platform_tenant?: false}
      worker = %AccessContext{user_id: "u-555", roles: [:TASK_WORKER], platform_tenant?: false}

      assert Authorization.evaluate_access(outside, :EntitiesViewsManage).kind == :Deny403
      assert Authorization.evaluate_access(admin, :EntitiesViewsManage).kind == :Allow
      assert Authorization.evaluate_access(worker, :EntitiesViewsManage).kind == :Deny403
      assert Authorization.evaluate_access(worker, :EntitiesQuery).kind == :Allow
    end
  end

  describe "M3 policy keys" do
    test "reads use EntitiesQuery, writes use EntitiesViewsManage" do
      assert Authorization.endpoint_policy_key("GET", "/entity-views") == :EntitiesQuery
      assert Authorization.endpoint_policy_key("GET", "/entity-views/:id") == :EntitiesQuery

      for {method, path} <- [
            {"POST", "/entity-views"},
            {"PUT", "/entity-views/:id"},
            {"DELETE", "/entity-views/:id"}
          ] do
        assert Authorization.endpoint_policy_key(method, path) == :EntitiesViewsManage
      end
    end
  end

  describe "M4 route classes" do
    setup do
      routes = RouteInventory.routes()

      {:ok,
       routes: routes, rows: Enum.filter(routes, &(&1.router == Letflow.Routers.EntityViews))}
    end

    test "five routes, all declared tenant-wide and none admin-plane", %{rows: rows} do
      assert length(rows) == 5
      assert Enum.all?(rows, &(&1.source == :declared))
      assert Enum.all?(rows, &(&1.class == :tenant_wide))

      assert rows |> Enum.map(&{&1.method, &1.path}) |> Enum.sort() ==
               [
                 {"DELETE", "/entity-views/:id"},
                 {"GET", "/entity-views"},
                 {"GET", "/entity-views/:id"},
                 {"POST", "/entity-views"},
                 {"PUT", "/entity-views/:id"}
               ]
    end

    test "the walk audits to [] and the default snapshot holds none of the routes", %{
      routes: routes
    } do
      snapshot = RouteInventory.read_snapshot()
      assert RouteScope.audit_routes(routes, snapshot) == []
      refute Enum.any?(snapshot, &String.contains?(&1, "/entity-views"))
    end
  end
end
