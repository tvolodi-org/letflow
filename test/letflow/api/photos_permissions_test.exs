defmodule Letflow.Api.PhotosPermissionsTest do
  @moduledoc """
  T-2041 A1–A3: the two photo atoms are core, tenant-scoped, handler-checked permissions held only
  by the two administrator roles, and the committed golden contains their complete role matrix.
  """
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Api.Authorization
  alias Letflow.Modules.Assets
  alias Letflow.Modules.Assets.Router

  @atoms [:PhotosAdd, :PhotosDelete]

  test "A1 appended core atoms are tenant scope and never route-level" do
    assert Enum.take(Authorization.core_permissions(), -3) ==
             @atoms ++ [:OutboundDestinationsManage]

    for permission <- @atoms do
      assert Authorization.permission_scope(permission) == :tenant
      assert Authorization.required_permission(permission) == permission

      refute Enum.any?(Router.__authz_routes__(), fn route ->
               permission in Tuple.to_list(route)
             end)

      refute Enum.any?(Assets.manifest().route_policies, fn {_m, _p, key} -> key == permission end)
    end
  end

  test "A2 only the administrators hold the atoms, with the platform scope bound" do
    for permission <- @atoms do
      holders = Enum.filter(Authorization.roles(), &Authorization.role_allows?(&1, permission))
      assert holders == [:PLATFORM_ADMIN, :TENANT_ADMIN]

      assert Authorization.has_permission_in_scope?([:TENANT_ADMIN], permission, false)
      assert Authorization.has_permission_in_scope?([:TENANT_ADMIN], permission, true)
      assert Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], permission, true)
      refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], permission, false)
      refute Authorization.has_permission_in_scope?([:STOREKEEPER], permission, false)
      refute Authorization.has_permission_in_scope?([:TENANT_AUDITOR], permission, false)
      refute permission in Map.get(Authorization.grantable(), :STOREKEEPER, [])
    end
  end

  test "A3 the regenerated golden carries every PhotosAdd and PhotosDelete row" do
    rows =
      for permission <- ["PhotosAdd", "PhotosDelete"],
          [role, perm, allowed, owner, via] <- Letflow.GoldenRows.rows_for(permission),
          do: Enum.join([role, perm, allowed, owner, via], " ")

    assert length(rows) == 2 * length(Letflow.GoldenRows.roles())
    assert "TENANT_ADMIN PhotosAdd true core core" in rows
    assert "TENANT_ADMIN PhotosDelete true core core" in rows
    assert "PLATFORM_ADMIN PhotosAdd true core core" in rows
    assert "PLATFORM_ADMIN PhotosDelete true core core" in rows
    assert "STOREKEEPER PhotosAdd false core -" in rows
    assert "STOREKEEPER PhotosDelete false core -" in rows
    assert "TENANT_AUDITOR PhotosAdd false core -" in rows
    assert "TENANT_AUDITOR PhotosDelete false core -" in rows
  end
end
