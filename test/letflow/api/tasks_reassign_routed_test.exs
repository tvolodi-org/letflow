defmodule Letflow.Api.TasksReassignRoutedTest do
  @moduledoc """
  Roles stage 0, slice S0-4 (decision 0088, `docs/design/roles-stage0-slices.md`): the permission
  `:TasksReassignRouted` replaces the TENANT_ADMIN role-name check in `Letflow.Tasks.authorize_reassign/3`.

    * R1 the atom: second-to-last core permission, tenant scope, resolves to itself, no route gates on it;
    * R2 holders are exactly TENANT_ADMIN; PLATFORM_ADMIN is refused by the explicit false clause;
    * R3 non-assignable: not in `grantable/0`, the overlay cannot add it, Catalog cannot grant it;
    * R4 the false clause is narrow: no other permission changes for the two admin roles;
    * R5 the golden carries exactly nine new rows;
    * R6 old and new predicate give the same answer for every role-string set x platform-tenant flag
      (8192 x 2 = 16384 cases).

  The HTTP side (both branches through `POST /tasks/:id/reassign`) is in
  `test/letflow/routers/tasks_test.exs` (H1a..H4). Pure (no database): `async: true` is safe.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.Authorization

  @perm :TasksReassignRouted
  @golden "priv/permission_matrix/effective.golden"

  test "R1 second-to-last core permission, tenant scope, resolves to itself, no route gates on it" do
    assert Authorization.core_permissions() |> Enum.take(-3) |> hd() == @perm
    assert Authorization.permission_scope(@perm) == :tenant
    assert Authorization.required_permission(@perm) == @perm

    for route <- Letflow.Routers.Tasks.__authz_routes__() do
      refute inspect(route) =~ "TasksReassignRouted"
    end

    # The route policy of the reassign endpoint is unchanged.
    assert Authorization.required_permission(:TasksReassign) == :TasksAssign
  end

  test "R2 holders are TENANT_ADMIN only; PLATFORM_ADMIN is refused" do
    holders = for r <- Authorization.roles(), Authorization.role_allows?(r, @perm), do: r
    assert holders == [:TENANT_ADMIN]

    for flag <- [true, false] do
      assert Authorization.has_permission_in_scope?([:TENANT_ADMIN], @perm, flag)
      refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], @perm, flag)
    end

    for role <- Authorization.roles() -- [:TENANT_ADMIN], flag <- [true, false] do
      refute Authorization.has_permission_in_scope?([role], @perm, flag), inspect(role)
    end
  end

  test "R3 non-assignable: not grantable, overlay cannot add it, Catalog cannot grant it" do
    grantable_values = Authorization.grantable() |> Map.values() |> List.flatten()
    refute @perm in grantable_values

    overlay = %{STOREKEEPER: [@perm], PLATFORM_ADMIN: [@perm], PROCESS_OPERATOR: [@perm]}

    for role <- [:STOREKEEPER, :PLATFORM_ADMIN, :PROCESS_OPERATOR] do
      refute Authorization.role_allows?(role, @perm, overlay), inspect(role)
    end

    for role <- Authorization.roles() do
      refute @perm in Letflow.Modules.Catalog.role_grants(role), inspect(role)
    end
  end

  test "R4 the false clause is narrow: no other permission changes for PLATFORM_ADMIN or TENANT_ADMIN" do
    for p <- Authorization.permissions() -- [:TasksWorkInScope, :TenantSecurityManage, @perm] do
      assert Authorization.role_allows?(:PLATFORM_ADMIN, p), inspect(p)
    end

    for p <- Authorization.permissions() -- [:TasksWorkInScope] do
      assert Authorization.role_allows?(:TENANT_ADMIN, p) ==
               (Authorization.permission_scope(p) == :tenant),
             inspect(p)
    end
  end

  test "R5 the golden carries exactly nine TasksReassignRouted rows" do
    lines =
      @golden
      |> File.read!()
      |> String.split(~r/\r?\n/, trim: true)

    rows = lines |> Enum.reject(&String.starts_with?(&1, "#")) |> Enum.map(&String.split(&1, " "))

    mine =
      Enum.filter(rows, fn [_role, permission | _] -> permission == "TasksReassignRouted" end)

    assert length(mine) == 9

    assert Enum.filter(mine, &(Enum.at(&1, 2) == "true")) ==
             [["TENANT_ADMIN", "TasksReassignRouted", "true", "core", "core"]]

    refused = Enum.filter(mine, &(Enum.at(&1, 2) == "false"))
    assert length(refused) == 8
    assert Enum.all?(refused, &(Enum.drop(&1, 3) == ["core", "-"]))

    # Header counts agree with the rows.
    permission_count = rows |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq() |> length()
    assert "# permissions: #{permission_count}" in lines
    assert "# rows: #{length(rows)}" in lines
    assert length(rows) == 9 * permission_count
  end

  @tag timeout: 60_000
  test "R6 old and new predicate agree for every role-string set x platform-tenant flag" do
    named = [
      {["PLATFORM_ADMIN"], true, false},
      {["PLATFORM_ADMIN", "TENANT_ADMIN"], true, true},
      {["TENANT_ADMIN"], false, true},
      {["PROCESS_OPERATOR"], false, false},
      {["tenant_admin"], false, false}
    ]

    for {strings, flag, expected} <- named do
      assert new_predicate(strings, flag) == expected, inspect({strings, flag})
    end

    universe =
      Enum.map(Authorization.roles(), &Atom.to_string/1) ++
        ["tenant_admin", "Tenant_Admin", "role-ops-manager", ""]

    indexed = Enum.with_index(universe)
    assert length(universe) == 13

    for n <- 0..(Bitwise.bsl(1, length(universe)) - 1), flag <- [true, false] do
      strings = for {s, i} <- indexed, Bitwise.band(n, Bitwise.bsl(1, i)) != 0, do: s
      old = "TENANT_ADMIN" in strings
      new = new_predicate(strings, flag)

      assert old == new,
             "mismatch: roles=#{inspect(strings)} platform=#{flag} old=#{old} new=#{new}"
    end
  end

  # The exact expression of `Letflow.Tasks.reassign_routed_holder?/2`.
  defp new_predicate(strings, platform_tenant?) do
    strings
    |> Authorization.effective_roles(platform_tenant?)
    |> Authorization.has_permission_in_scope?(@perm, platform_tenant?)
  end
end
