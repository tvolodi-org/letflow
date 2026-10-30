defmodule Letflow.Api.EntityTypeExtensionsRouteClassesTest do
  @moduledoc """
  REQ-609 / GH #3417 (design ID P1): `:EntitiesExtensionsManage` is a tenant-scope core
  permission held by TENANT_ADMIN (and PLATFORM_ADMIN on the platform tenant) only; the three
  routes are declared `:tenant_wide`, none default-sourced, and the default snapshot is unchanged.
  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  @perm :EntitiesExtensionsManage

  test "P1 tenant scope, last core permission, TENANT_ADMIN and PLATFORM_ADMIN only" do
    assert Authorization.permission_scope(@perm) == :tenant
    assert Authorization.core_permissions() |> Enum.take(-1) |> hd() == @perm
    assert Authorization.required_permission(@perm) == @perm

    for role <- Authorization.roles() do
      expected = role in [:TENANT_ADMIN, :PLATFORM_ADMIN]
      assert Authorization.role_allows?(role, @perm) == expected, "#{role}"
    end

    outside = %AccessContext{user_id: "u-609", roles: [:PLATFORM_ADMIN], platform_tenant?: false}
    assert Authorization.evaluate_access(outside, @perm).kind == :Deny403
    admin = %AccessContext{user_id: "u-609", roles: [:TENANT_ADMIN], platform_tenant?: false}
    assert Authorization.evaluate_access(admin, @perm).kind == :Allow
  end

  describe "P1 routes" do
    setup do
      routes = RouteInventory.routes()

      {:ok,
       routes: routes,
       rows: Enum.filter(routes, &(&1.router == Letflow.Routers.EntityTypeExtensions))}
    end

    test "three routes with the expected keys and classes", %{rows: rows} do
      assert rows |> Enum.map(&{&1.method, &1.path, &1.key}) |> Enum.sort() == [
               {"DELETE", "/entity-type-extensions/:id", @perm},
               {"GET", "/entity-type-extensions", @perm},
               {"POST", "/entity-type-extensions", @perm}
             ]

      assert Enum.all?(rows, &(&1.source == :declared and &1.class == :tenant_wide))
    end

    test "the walk audits to [] and the default snapshot has no such line", %{routes: routes} do
      snapshot = RouteInventory.read_snapshot()
      assert RouteScope.audit_routes(routes, snapshot) == []
      refute Enum.any?(snapshot, &String.contains?(&1, "/entity-type-extensions"))
    end
  end

  test "P3 no module route_policies names the core permission" do
    hits =
      Path.wildcard("lib/letflow/modules/**/*.ex")
      |> Enum.filter(&(File.read!(&1) =~ "EntitiesExtensionsManage"))

    assert hits == []
  end
end
