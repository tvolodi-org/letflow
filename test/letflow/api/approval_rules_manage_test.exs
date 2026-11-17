defmodule Letflow.Api.ApprovalRulesManageTest do
  @moduledoc """
  T-1986 (four-eyes switch, slice 1): the permission `:ApprovalRulesManage`.

    * P1 the atom: fifth to last core permission (OfficialFormTemplatesManage, LedgerSettingsManage, PhotosAdd and PhotosDelete follow), tenant scope, resolves to itself, both routes carry its key;
    * P2 holders are exactly TENANT_ADMIN; PLATFORM_ADMIN is refused by the explicit false clause;
    * P3 non-assignable: not in `grantable/0`, a forged overlay grants it to no role, Catalog cannot grant it;
    * P4 the golden carries exactly nine rows, only TENANT_ADMIN true;
    * P5 a scoped TENANT_ADMIN grant does not count tenant-wide.

  Pure (no database): `async: true` is safe.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.{Grants, Principal}

  @perm :ApprovalRulesManage

  test "P1 fifth to last core permission (OfficialFormTemplatesManage, LedgerSettingsManage, PhotosAdd and PhotosDelete follow), tenant scope, resolves to itself, both routes carry the key" do
    assert Enum.at(Authorization.core_permissions(), -5) == @perm
    assert Authorization.permission_scope(@perm) == :tenant
    assert Authorization.required_permission(@perm) == @perm
    assert Authorization.endpoint_policy_key("GET", "/approval-rules") == @perm

    assert Authorization.endpoint_policy_key("PUT", "/approval-rules/:definition_name/:node_id") ==
             @perm
  end

  test "P2 holders are TENANT_ADMIN only; PLATFORM_ADMIN is refused in both tenants" do
    holders = for r <- Authorization.roles(), Authorization.role_allows?(r, @perm), do: r
    assert holders == [:TENANT_ADMIN]

    for flag <- [true, false] do
      assert Authorization.has_permission_in_scope?([:TENANT_ADMIN], @perm, flag)
      refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], @perm, flag)

      for role <- Authorization.roles() -- [:TENANT_ADMIN] do
        refute Authorization.has_permission_in_scope?([role], @perm, flag), inspect(role)
      end
    end
  end

  test "P3 non-assignable: not grantable, forged overlays grant nothing, Catalog cannot grant it" do
    refute @perm in (Authorization.grantable() |> Map.values() |> List.flatten())

    for role <- Authorization.roles() -- [:TENANT_ADMIN] do
      refute Authorization.role_allows?(role, @perm, %{role => [@perm]}), inspect(role)
    end

    for role <- Authorization.roles() do
      refute @perm in Letflow.Modules.Catalog.role_grants(role), inspect(role)
    end
  end

  test "P4 the golden carries exactly nine rows, only TENANT_ADMIN true" do
    rows = Letflow.GoldenRows.rows_for("ApprovalRulesManage")

    assert length(rows) == length(Letflow.GoldenRows.roles())

    assert Enum.filter(rows, &(Enum.at(&1, 2) == "true")) == [
             ["TENANT_ADMIN", "ApprovalRulesManage", "true", "core", "core"]
           ]
  end

  test "P5 a scoped TENANT_ADMIN grant is denied tenant-wide; a tenant-wide grant is allowed" do
    uid = Ecto.UUID.generate()

    principal = fn row ->
      %Principal{
        kind: :user,
        user_id: uid,
        prefix: "tenant_x",
        platform_tenant?: false,
        roles: [:TENANT_ADMIN],
        grants: %Grants{user_id: uid, rows_by_role: %{"TENANT_ADMIN" => [row]}},
        role_overlay: %{}
      }
    end

    scoped = %{principal_type: :group, tenant_wide: false, scope_node_id: "n1"}
    wide = %{principal_type: :group, tenant_wide: true, scope_node_id: nil}

    assert {:deny, _} = Scope.allowed?(principal.(scoped), @perm, :tenant_wide)
    assert {:allow, _} = Scope.allowed?(principal.(wide), @perm, :tenant_wide)
  end
end
