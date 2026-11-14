defmodule Letflow.Api.CurrenciesRouteClassesTest do
  @moduledoc """
  REQ-824 / GH #4393: `:CurrenciesManage` is a tenant-scope core permission held by TENANT_ADMIN
  (and PLATFORM_ADMIN inside the platform tenant) only; the two routes are declared with the
  expected keys and classes; the route walk audits clean. No database: `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  test "C1 the permission is the second to last core permission, tenant scope, admins only" do
    assert Enum.at(Authorization.core_permissions(), -2) == :CurrenciesManage
    assert Authorization.permission_scope(:CurrenciesManage) == :tenant
    assert Authorization.required_permission(:CurrenciesManage) == :CurrenciesManage

    for role <- Authorization.roles() do
      expected = role in [:TENANT_ADMIN, :PLATFORM_ADMIN]
      assert Authorization.role_allows?(role, :CurrenciesManage) == expected, "#{role}"
    end

    outside = %AccessContext{user_id: "u-824", roles: [:PLATFORM_ADMIN], platform_tenant?: false}
    assert Authorization.evaluate_access(outside, :CurrenciesManage).kind == :Deny403
  end

  test "C2 routes, keys and classes; the walk audits to []" do
    routes = RouteInventory.routes()
    rows = Enum.filter(routes, &(&1.router == Letflow.Routers.Currencies))

    assert rows |> Enum.map(&{&1.method, &1.path, &1.key}) |> Enum.sort() == [
             {"GET", "/currencies", :MyAccessRead},
             {"PUT", "/currencies/:code", :CurrenciesManage}
           ]

    assert Enum.all?(rows, &(&1.source == :declared))

    for row <- rows do
      expected = if row.method == "GET", do: :self_service, else: :tenant_wide
      assert row.class == expected, "#{row.method} #{row.path}"
    end

    snapshot = RouteInventory.read_snapshot()
    assert RouteScope.audit_routes(routes, snapshot) == []
    refute Enum.any?(snapshot, &Regex.match?(~r{^[A-Z]+ /currencies}, &1))
  end
end
