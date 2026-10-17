defmodule Letflow.Api.RoleScopeGrantsPolicyKeysTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2a, AC 1 (design `lib/letflow/design/req517-scoped-grants-admin-plane.md`
  section 3.14; spec `test/specs/REQ-517-2a.md`, T-K1, T-A9): the five admin-plane routes resolve
  to three NEW policy keys that all map to the EXISTING tenant-scope permission
  `:UsersGroupsRolesManage`.

  `required_permission/1` must be explicit for the three keys: without the clause the identity
  fallback returns the key itself and `permission_scope/1` would classify the unknown atom as
  platform (the trap that made the `:Scope*` keys explicit). No new permission atom exists, so the
  effective-permission golden (`priv/permission_matrix/effective.golden`) is unchanged
  (`test/letflow/api/permission_matrix_test.exs` is the byte-level check).

  Pure: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization

  @routes [
    {"GET", "/tenant/role-scope-grants", :RoleScopeGrantsRead},
    {"POST", "/tenant/role-scope-grants", :RoleScopeGrantsManage},
    {"DELETE", "/tenant/role-scope-grants/:id", :RoleScopeGrantsManage},
    {"POST", "/tenant/role-scope-grants/make-tenant-wide", :RoleScopeGrantsManage},
    {"PUT", "/users/:id/service-principal", :ServicePrincipalManage}
  ]

  @keys @routes |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

  test "T-K1 each of the five routes resolves to its policy key" do
    for {method, path, key} <- @routes do
      assert Authorization.endpoint_policy_key(method, path) == key, "#{method} #{path}"
    end
  end

  test "T-K1 the three keys require exactly :UsersGroupsRolesManage, which is tenant scope" do
    assert length(@keys) == 3

    for key <- @keys do
      assert Authorization.required_permission(key) == :UsersGroupsRolesManage, inspect(key)

      assert Authorization.permission_scope(Authorization.required_permission(key)) == :tenant,
             inspect(key)
    end
  end

  test "T-A9 no new permission atom: the keys are policy keys, not permissions" do
    permissions = Authorization.permissions()

    for key <- @keys do
      refute key in permissions, "#{inspect(key)} is a permission atom"
    end

    assert :UsersGroupsRolesManage in permissions
  end

  defp declared(router) do
    for {method, path, key} <- router.__authz_routes__(),
        do: {method |> to_string() |> String.upcase(), path, key}
  end

  test "the grants router declares exactly the four grant routes with the table's keys" do
    declared = declared(Letflow.Routers.TenantRoleScopeGrants)

    for expected <- [
          {"GET", "/", :RoleScopeGrantsRead},
          {"POST", "/", :RoleScopeGrantsManage},
          {"POST", "/make-tenant-wide", :RoleScopeGrantsManage},
          {"DELETE", "/:id", :RoleScopeGrantsManage}
        ] do
      assert expected in declared
    end

    assert Enum.count(declared, &(elem(&1, 2) in @keys)) == 4
  end

  test "the identity router declares the flag route with :ServicePrincipalManage" do
    assert {"PUT", "/users/:id/service-principal", :ServicePrincipalManage} in declared(
             Letflow.Routers.Identity
           )
  end
end
