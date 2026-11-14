defmodule Letflow.Api.DataExportPermissionTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Support.RouteInventory

  test "DX-19 DataExport is the last core atom, tenant scope, admins only" do
    assert List.last(Authorization.core_permissions()) == :DataExport
    assert Authorization.required_permission(:DataExport) == :DataExport
    assert Authorization.permission_scope(:DataExport) == :tenant

    for role <- Authorization.roles() do
      assert Authorization.role_allows?(role, :DataExport) ==
               role in [:PLATFORM_ADMIN, :TENANT_ADMIN]
    end

    assert Authorization.evaluate_access(
             %AccessContext{user_id: "u", roles: [:PLATFORM_ADMIN], platform_tenant?: false},
             :DataExport
           ).kind == :Deny403

    golden = File.read!("priv/permission_matrix/effective.golden")

    for role <- Authorization.roles() do
      verdict = if role in [:PLATFORM_ADMIN, :TENANT_ADMIN], do: "true", else: "false"
      assert golden =~ "#{role} DataExport #{verdict}"
    end
  end

  test "DX-19 both routes declare tenant-wide DataExport and policy resolves" do
    rows = RouteInventory.routes() |> Enum.filter(&(&1.router == Letflow.Routers.DataExport))

    assert Enum.sort(Enum.map(rows, &{&1.method, &1.path})) == [
             {"GET", "/data-export/datasets"},
             {"POST", "/data-export"}
           ]

    for row <- rows do
      assert row.key == :DataExport and row.class == :tenant_wide and row.source == :declared
      assert Authorization.endpoint_policy_key(row.method, row.path) == :DataExport
    end
  end
end
