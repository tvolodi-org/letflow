defmodule Letflow.Api.NumberSequencesRouteClassesTest do
  @moduledoc """
  REQ-575 / GH #3263 (design IDs R1, R2): `:NumberSequencesManage` is a tenant-scope core
  permission held by TENANT_ADMIN (and PLATFORM_ADMIN on the platform tenant) only; the two
  routes are declared `:tenant_wide`, none default-sourced, and the default snapshot is unchanged.
  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  @perm :NumberSequencesManage

  test "R1 tenant scope, second to last core permission, TENANT_ADMIN and PLATFORM_ADMIN only" do
    assert Authorization.permission_scope(@perm) == :tenant
    assert Authorization.core_permissions() |> Enum.take(-3) |> hd() == @perm
    assert Authorization.required_permission(@perm) == @perm

    for role <- Authorization.roles() do
      expected = role in [:TENANT_ADMIN, :PLATFORM_ADMIN]
      assert Authorization.role_allows?(role, @perm) == expected, "#{role}"
    end

    outside = %AccessContext{user_id: "u-575", roles: [:PLATFORM_ADMIN], platform_tenant?: false}
    assert Authorization.evaluate_access(outside, @perm).kind == :Deny403
    admin = %AccessContext{user_id: "u-575", roles: [:TENANT_ADMIN], platform_tenant?: false}
    assert Authorization.evaluate_access(admin, @perm).kind == :Allow
  end

  describe "R2 routes" do
    setup do
      routes = RouteInventory.routes()

      {:ok,
       routes: routes, rows: Enum.filter(routes, &(&1.router == Letflow.Routers.NumberSequences))}
    end

    test "two routes with the expected keys and classes", %{rows: rows} do
      assert rows |> Enum.map(&{&1.method, &1.path, &1.key}) |> Enum.sort() == [
               {"GET", "/number-sequences", @perm},
               {"POST", "/number-sequences", @perm}
             ]

      assert Enum.all?(rows, &(&1.source == :declared and &1.class == :tenant_wide))
    end

    test "the walk audits to [] and the default snapshot has no such line", %{routes: routes} do
      snapshot = RouteInventory.read_snapshot()
      assert RouteScope.audit_routes(routes, snapshot) == []
      refute Enum.any?(snapshot, &String.contains?(&1, "/number-sequences"))
    end
  end
end
