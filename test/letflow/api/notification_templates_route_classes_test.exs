defmodule Letflow.Api.NotificationTemplatesRouteClassesTest do
  @moduledoc """
  REQ-563 / GH #3199 (design IDs A1, A3): `:NotificationTemplatesManage` is a tenant-scope core
  permission held by TENANT_ADMIN (and PLATFORM_ADMIN on the platform tenant) only; the four
  routes are declared `:tenant_wide`, none default-sourced, and the default snapshot is unchanged.
  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  @perm :NotificationTemplatesManage

  test "A1 tenant scope, last core permission, TENANT_ADMIN and PLATFORM_ADMIN only" do
    assert Authorization.permission_scope(@perm) == :tenant
    assert List.last(Authorization.core_permissions()) == @perm
    assert Authorization.required_permission(@perm) == @perm

    for role <- Authorization.roles() do
      expected = role in [:TENANT_ADMIN, :PLATFORM_ADMIN]
      assert Authorization.role_allows?(role, @perm) == expected, "#{role}"
    end

    outside = %AccessContext{user_id: "u-563", roles: [:PLATFORM_ADMIN], platform_tenant?: false}
    assert Authorization.evaluate_access(outside, @perm).kind == :Deny403
    admin = %AccessContext{user_id: "u-563", roles: [:TENANT_ADMIN], platform_tenant?: false}
    assert Authorization.evaluate_access(admin, @perm).kind == :Allow
  end

  describe "A3 routes" do
    setup do
      routes = RouteInventory.routes()

      {:ok,
       routes: routes,
       rows: Enum.filter(routes, &(&1.router == Letflow.Routers.NotificationTemplates))}
    end

    test "four routes with the expected keys and classes", %{rows: rows} do
      assert rows |> Enum.map(&{&1.method, &1.path, &1.key}) |> Enum.sort() == [
               {"DELETE", "/notification-templates/:template_key", @perm},
               {"GET", "/notification-templates", @perm},
               {"POST", "/notification-templates/:template_key/preview", @perm},
               {"PUT", "/notification-templates/:template_key", @perm}
             ]

      assert Enum.all?(rows, &(&1.source == :declared and &1.class == :tenant_wide))
    end

    test "the walk audits to [] and the default snapshot has no such line", %{routes: routes} do
      snapshot = RouteInventory.read_snapshot()
      assert RouteScope.audit_routes(routes, snapshot) == []
      refute Enum.any?(snapshot, &String.contains?(&1, "/notification-templates"))
    end
  end
end
