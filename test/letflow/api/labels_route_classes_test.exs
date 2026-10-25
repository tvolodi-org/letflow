defmodule Letflow.Api.LabelsRouteClassesTest do
  @moduledoc """
  REQ-551 / GH #3180, criterion 4 (design IDs L1..L5):

    * L1 `:LabelsManage` is a core permission of TENANT scope, second to last in `core_permissions/0` (REQ-555 appended :EntitiesViewsManage);
      TENANT_ADMIN holds it; every other role does not; PLATFORM_ADMIN is denied outside the
      platform tenant;
    * L2 every role holds `:MyAccessRead` (the role-agnostic key of `GET /labels`);
    * L3 the three routes are declared with the expected keys;
    * L4 classes: GET `:self_service`, PUT and DELETE `:tenant_wide`, none default-sourced;
    * L5 the walk audits to `[]` and the default snapshot holds no labels line.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  describe "L1/L2 permissions" do
    test "L1 LabelsManage is tenant scope, appended after the document permissions (REQ-565 then appended IntegrationMappingsManage, EntitiesViewsManage and NotificationTemplatesManage), TENANT_ADMIN only" do
      assert Authorization.permission_scope(:LabelsManage) == :tenant
      assert Authorization.core_permissions() |> Enum.take(-4) |> hd() == :LabelsManage
      assert Authorization.required_permission(:LabelsManage) == :LabelsManage
      assert Authorization.role_allows?(:TENANT_ADMIN, :LabelsManage)

      for role <- Authorization.roles(), role not in [:TENANT_ADMIN, :PLATFORM_ADMIN] do
        refute Authorization.role_allows?(role, :LabelsManage), "#{role}"
      end
    end

    test "L1 PLATFORM_ADMIN outside the platform tenant is denied; the tenant admin is allowed" do
      outside = %AccessContext{
        user_id: "u-551",
        roles: [:PLATFORM_ADMIN],
        platform_tenant?: false
      }

      assert Authorization.evaluate_access(outside, :LabelsManage).kind == :Deny403

      admin = %AccessContext{user_id: "u-551", roles: [:TENANT_ADMIN], platform_tenant?: false}
      assert Authorization.evaluate_access(admin, :LabelsManage).kind == :Allow

      auditor = %AccessContext{
        user_id: "u-551",
        roles: [:TENANT_AUDITOR],
        platform_tenant?: false
      }

      assert Authorization.evaluate_access(auditor, :LabelsManage).kind == :Deny403
    end

    test "L2 every role holds MyAccessRead, the key of the read route" do
      assert Authorization.endpoint_policy_key("GET", "/labels") == :MyAccessRead

      for role <- Authorization.roles() do
        assert Authorization.role_allows?(role, :MyAccessRead), "#{role}"
      end
    end
  end

  describe "L3..L5 routes" do
    setup do
      routes = RouteInventory.routes()

      {:ok, routes: routes, rows: Enum.filter(routes, &(&1.router == Letflow.Routers.Labels))}
    end

    test "L3 three routes with the expected keys", %{rows: rows} do
      assert rows |> Enum.map(&{&1.method, &1.path, &1.key}) |> Enum.sort() == [
               {"DELETE", "/labels/:message_id", :LabelsManage},
               {"GET", "/labels", :MyAccessRead},
               {"PUT", "/labels/:message_id", :LabelsManage}
             ]

      assert Authorization.endpoint_policy_key("PUT", "/labels/:message_id") == :LabelsManage
      assert Authorization.endpoint_policy_key("DELETE", "/labels/:message_id") == :LabelsManage
    end

    test "L4 classes are declared, none default-sourced", %{rows: rows} do
      assert Enum.all?(rows, &(&1.source == :declared))

      for row <- rows do
        expected = if row.method == "GET", do: :self_service, else: :tenant_wide
        assert row.class == expected, "#{row.method} #{row.path}"
      end
    end

    test "L5 the walk audits to [] and the default snapshot has no labels line", %{routes: routes} do
      snapshot = RouteInventory.read_snapshot()
      assert RouteScope.audit_routes(routes, snapshot) == []
      refute Enum.any?(snapshot, &String.contains?(&1, "/labels"))

      assert Enum.any?(
               RouteScope.self_service_routes(),
               &(&1.route == "GET /labels" and &1.ruling == "SEC-551-labels")
             )
    end
  end
end
