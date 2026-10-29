defmodule Letflow.Api.NotificationDeliveriesRouteClassesTest do
  @moduledoc """
  REQ-584 part 2 / GH #3310 (design ID P1): `GET /notification-deliveries` is one declared
  `:tenant_wide` route gated by `:NotificationTemplatesManage`, absent from the default snapshot.
  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  @perm :NotificationTemplatesManage

  setup do
    routes = RouteInventory.routes()

    {:ok,
     routes: routes,
     rows: Enum.filter(routes, &(&1.router == Letflow.Routers.NotificationDeliveries))}
  end

  test "P1 one declared tenant_wide route with the template-manage key", %{rows: rows} do
    assert Enum.map(rows, &{&1.method, &1.path, &1.key}) == [
             {"GET", "/notification-deliveries", @perm}
           ]

    assert Enum.all?(rows, &(&1.source == :declared and &1.class == :tenant_wide))
    assert Authorization.endpoint_policy_key("GET", "/notification-deliveries") == @perm
  end

  test "P1 the walk audits to [] and the snapshot has no such line", %{routes: routes} do
    snapshot = RouteInventory.read_snapshot()
    assert RouteScope.audit_routes(routes, snapshot) == []
    refute Enum.any?(snapshot, &String.contains?(&1, "/notification-deliveries"))
  end

  test "P1 roles: TENANT_ADMIN allowed, auditor and non-platform PLATFORM_ADMIN denied" do
    admin = %AccessContext{user_id: "u-584", roles: [:TENANT_ADMIN], platform_tenant?: false}
    assert Authorization.evaluate_access(admin, @perm).kind == :Allow
    auditor = %AccessContext{user_id: "u-584", roles: [:TENANT_AUDITOR], platform_tenant?: false}
    assert Authorization.evaluate_access(auditor, @perm).kind == :Deny403
    outside = %AccessContext{user_id: "u-584", roles: [:PLATFORM_ADMIN], platform_tenant?: false}
    assert Authorization.evaluate_access(outside, @perm).kind == :Deny403
  end
end
