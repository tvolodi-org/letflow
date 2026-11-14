defmodule Letflow.Api.TenantSecurityManageTest do
  @moduledoc """
  Roles stage 0, slice S0-3 (decision 0088, `docs/design/roles-stage0-slices.md`): the permission
  `:TenantSecurityManage` replaces the TENANT_ADMIN role-name check in `require_interactive_tenant_admin/1`.

    * S1 the atom: third-to-last core permission, tenant scope, resolves to itself, no route gates on it;
    * S2 holders are exactly TENANT_ADMIN; PLATFORM_ADMIN is refused by the explicit false clause,
      and a tenant overlay cannot add it (non-assignable);
    * S3 non-assignable: not in `grantable/0`, the overlay cannot add it, Catalog cannot grant it;
    * S4 the false clause is narrow: no other permission changes for the two admin roles;
    * S5 the golden carries exactly the nine new rows;
    * S6 old and new predicate give the same answer for every role-set × platform-tenant flag ×
      grant shape combination (512 × 2 × 4 = 4096 cases).

  Pure (no database): `async: true` is safe.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.{Grants, Principal}

  @perm :TenantSecurityManage
  @golden "priv/permission_matrix/effective.golden"

  test "S1 third-to-last core permission, tenant scope, resolves to itself, no route gates on it" do
    assert Authorization.core_permissions() |> Enum.take(-5) |> hd() == @perm
    assert Authorization.permission_scope(@perm) == :tenant
    assert Authorization.required_permission(@perm) == @perm

    # Not a route-level policy on either caller route
    enforcement_keys =
      for route <- Letflow.Routers.TenantScopeEnforcement.__authz_routes__(), do: inspect(route)

    identity_keys =
      for route <- Letflow.Routers.Identity.__authz_routes__(), do: inspect(route)

    refute Enum.any?(enforcement_keys, &String.contains?(&1, "TenantSecurityManage"))
    refute Enum.any?(identity_keys, &String.contains?(&1, "TenantSecurityManage"))

    # Route-level policy of the two callers remains UsersGroupsRolesManage
    assert Authorization.required_permission(:ScopeEnforcementManage) == :UsersGroupsRolesManage
    assert Authorization.required_permission(:ServicePrincipalManage) == :UsersGroupsRolesManage
  end

  test "S2 holders are TENANT_ADMIN only; PLATFORM_ADMIN is refused; overlay cannot add it" do
    holders = for r <- Authorization.roles(), Authorization.role_allows?(r, @perm), do: r
    assert holders == [:TENANT_ADMIN]

    # allowed branch: TENANT_ADMIN in a regular tenant and in the platform tenant
    for flag <- [true, false] do
      assert Authorization.has_permission_in_scope?([:TENANT_ADMIN], @perm, flag)
    end

    # refused branch: PLATFORM_ADMIN (explicit false clause, ruling 2)
    refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], @perm, true)
    refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], @perm, false)

    # refused: every other role
    for role <- Authorization.roles() -- [:TENANT_ADMIN] do
      for flag <- [true, false] do
        refute Authorization.has_permission_in_scope?([role], @perm, flag), inspect(role)
      end
    end

    # overlay cannot add it (non-assignable)
    overlay = %{STOREKEEPER: [@perm], PLATFORM_ADMIN: [@perm]}
    refute Authorization.role_allows?(:STOREKEEPER, @perm, overlay)
    refute Authorization.role_allows?(:PLATFORM_ADMIN, @perm, overlay)
    # TENANT_ADMIN holds it through core, not overlay
    assert Authorization.role_allows?(:TENANT_ADMIN, @perm, %{})
  end

  test "S3 non-assignable: not in grantable/0, overlay cannot grant it to any non-holder, Catalog cannot grant it" do
    grantable_values = Authorization.grantable() |> Map.values() |> List.flatten()
    refute @perm in grantable_values

    # For every role other than TENANT_ADMIN, a forged overlay does not grant it
    for role <- Authorization.roles() -- [:TENANT_ADMIN] do
      refute Authorization.role_allows?(role, @perm, %{role => [@perm]}), inspect(role)
    end

    # STOREKEEPER with the grantable key plus the atom: still refused
    refute Authorization.role_allows?(:STOREKEEPER, @perm, %{STOREKEEPER: [@perm, :AssetsRead]})

    # Catalog cannot grant a core permission
    for role <- Authorization.roles() do
      refute @perm in Letflow.Modules.Catalog.role_grants(role), inspect(role)
    end
  end

  test "S4 the false clause is narrow: no other permission changes for PLATFORM_ADMIN or TENANT_ADMIN" do
    # PLATFORM_ADMIN still holds everything except TasksWorkInScope and TenantSecurityManage
    # Roles stage 0 S0-4: TasksReassignRouted is also TENANT_ADMIN's alone.
    for p <- Authorization.permissions() -- [:TasksWorkInScope, @perm, :TasksReassignRouted] do
      assert Authorization.role_allows?(:PLATFORM_ADMIN, p), inspect(p)
    end

    # TENANT_ADMIN holds exactly the tenant-scope permissions, except TasksWorkInScope (ruling 1)
    for p <- Authorization.permissions() -- [:TasksWorkInScope] do
      assert Authorization.role_allows?(:TENANT_ADMIN, p) ==
               (Authorization.permission_scope(p) == :tenant),
             inspect(p)
    end

    # TasksWorkInScope is tenant-scope but TENANT_ADMIN does NOT hold it (ruling 1 explicit false clause)
    refute Authorization.role_allows?(:TENANT_ADMIN, :TasksWorkInScope)
  end

  test "S5 the golden carries exactly nine TenantSecurityManage rows" do
    rows =
      @golden
      |> File.read!()
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(&String.split(&1, " "))
      |> Enum.filter(fn [_role, permission | _] -> permission == "TenantSecurityManage" end)

    assert length(rows) == 9

    assert Enum.filter(rows, &(Enum.at(&1, 2) == "true")) == [
             ["TENANT_ADMIN", "TenantSecurityManage", "true", "core", "core"]
           ]

    refused = Enum.filter(rows, &(Enum.at(&1, 2) == "false"))
    assert length(refused) == 8
    assert Enum.all?(refused, &(Enum.drop(&1, 3) == ["core", "-"]))
  end

  @tag timeout: 60_000
  test "S6 old and new predicate give identical answers for all role-set × platform-flag × grant-shape combinations" do
    uuid = "00000000-0000-0000-0000-000000000001"
    all_role_strings = Enum.map(Authorization.roles(), &Atom.to_string/1)

    allow_count = :counters.new(1, [])
    deny_count = :counters.new(1, [])

    # Four named cases verified explicitly
    named = [
      {["TENANT_ADMIN"], false, :tenant_wide, true,
       "[TENANT_ADMIN] regular tenant tenant-wide -> allow"},
      {["PLATFORM_ADMIN"], true, :tenant_wide, false, "[PLATFORM_ADMIN] platform tenant -> deny"},
      {["PLATFORM_ADMIN", "TENANT_ADMIN"], true, :scoped, false,
       "[PLATFORM_ADMIN, TENANT_ADMIN] platform tenant TENANT_ADMIN scoped -> deny"},
      {["PLATFORM_ADMIN", "TENANT_ADMIN"], true, :tenant_wide, true,
       "[PLATFORM_ADMIN, TENANT_ADMIN] platform tenant TENANT_ADMIN tenant-wide -> allow"}
    ]

    for {role_strings, platform_flag, grant_shape, expected_allow, label} <- named do
      p = build_principal(uuid, role_strings, platform_flag, grant_shape)
      result = match?({:allow, _}, Scope.allowed?(p, @perm, :tenant_wide))
      assert result == expected_allow, label
    end

    for n <- 0..511 do
      role_strings =
        all_role_strings
        |> Enum.with_index()
        |> Enum.filter(fn {_r, i} -> band(n, bsl(1, i)) != 0 end)
        |> Enum.map(&elem(&1, 0))

      for platform_flag <- [true, false],
          grant_shape <- [:none, :scoped, :tenant_wide, :not_loaded] do
        p = build_principal(uuid, role_strings, platform_flag, grant_shape)

        old_result = old_predicate(p)
        new_result = match?({:allow, _}, Scope.allowed?(p, @perm, :tenant_wide))

        assert old_result == new_result,
               "mismatch: roles=#{inspect(role_strings)}, platform=#{platform_flag}, grant=#{grant_shape}: old=#{old_result} new=#{new_result}"

        if new_result,
          do: :counters.add(allow_count, 1, 1),
          else: :counters.add(deny_count, 1, 1)
      end
    end

    assert :counters.get(allow_count, 1) > 0, "no allow cases found"
    assert :counters.get(deny_count, 1) > 0, "no deny cases found"
  end

  # Builds a Principal matching the given role strings, platform flag and grant shape.
  defp build_principal(uuid, role_strings, platform_flag, grant_shape) do
    effective = Authorization.effective_roles(role_strings, platform_flag)

    grants =
      case grant_shape do
        :not_loaded ->
          :not_loaded

        :none ->
          %Grants{
            user_id: uuid,
            rows_by_role:
              Map.new(effective -- [:TENANT_ADMIN], fn role ->
                {Atom.to_string(role),
                 [%{principal_type: :group, tenant_wide: true, scope_node_id: nil}]}
              end)
              |> Map.put("TENANT_ADMIN", [])
          }

        :scoped ->
          %Grants{
            user_id: uuid,
            rows_by_role:
              Map.new(effective -- [:TENANT_ADMIN], fn role ->
                {Atom.to_string(role),
                 [%{principal_type: :group, tenant_wide: true, scope_node_id: nil}]}
              end)
              |> Map.put("TENANT_ADMIN", [
                %{principal_type: :group, tenant_wide: false, scope_node_id: "n1"}
              ])
          }

        :tenant_wide ->
          %Grants{
            user_id: uuid,
            rows_by_role:
              Map.new(effective -- [:TENANT_ADMIN], fn role ->
                {Atom.to_string(role),
                 [%{principal_type: :group, tenant_wide: true, scope_node_id: nil}]}
              end)
              |> Map.put("TENANT_ADMIN", [
                %{principal_type: :group, tenant_wide: true, scope_node_id: nil}
              ])
          }
      end

    %Principal{
      kind: :user,
      user_id: uuid,
      prefix: "tenant_x",
      platform_tenant?: platform_flag,
      roles: effective,
      grants: grants,
      role_overlay: %{}
    }
  end

  # Old predicate: TENANT_ADMIN in roles AND effective_scope(principal, "TENANT_ADMIN") == :tenant_wide
  defp old_predicate(%Principal{} = p) do
    :TENANT_ADMIN in p.roles and
      Scope.effective_scope(p, "TENANT_ADMIN") == :tenant_wide
  end

  defp band(a, b), do: :erlang.band(a, b)
  defp bsl(a, b), do: :erlang.bsl(a, b)
end
