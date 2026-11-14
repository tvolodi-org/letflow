defmodule Letflow.Api.TasksWorkInScopeTest do
  @moduledoc """
  Roles stage 0, slice S0-2 (decision 0088, `docs/design/roles-stage0-slices.md`): the permission
  `:TasksWorkInScope` replaces the role name TASK_WORKER in the scoped task-work rule (F1).

    * W1 the atom: fourth-to-last core permission, tenant scope, resolves to itself, no route gates on it;
    * W2 holders are exactly TASK_WORKER (allowed branch); PLATFORM_ADMIN and TENANT_ADMIN are
      refused by the two explicit false clauses (ruling 1 of
      `docs/design/roles-stage0-security-rulings.md`), and a tenant overlay cannot add it;
    * W3 the false clauses are narrow: no other permission changes for the two admin roles;
    * W4 the effective golden carries exactly the nine new rows;
    * W5 `ScopedApprovers.holder_roles/0` derives the old hard-coded name.

  Pure (no database): `async: true` is safe.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.Authorization
  alias Letflow.Identity.ScopedApprovers

  @perm :TasksWorkInScope
  @golden "priv/permission_matrix/effective.golden"

  test "W1 fourth-to-last core permission, tenant scope, resolves to itself, no route gates on it" do
    assert Authorization.core_permissions() |> Enum.take(-6) |> hd() == @perm
    assert Authorization.permission_scope(@perm) == :tenant
    assert Authorization.required_permission(@perm) == @perm

    keys = for route <- Letflow.Routers.Tasks.__authz_routes__(), do: inspect(route)
    refute Enum.any?(keys, &String.contains?(&1, "TasksWorkInScope"))
  end

  test "W2 holders are TASK_WORKER only; the two admin roles are refused, the overlay cannot add it" do
    holders = for r <- Authorization.roles(), Authorization.role_allows?(r, @perm), do: r
    assert holders == [:TASK_WORKER]

    # allowed branch
    for flag <- [true, false] do
      assert Authorization.has_permission_in_scope?([:TASK_WORKER], @perm, flag)
    end

    # refused branch: the platform tenant's PLATFORM_ADMIN and TENANT_ADMIN
    refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], @perm, true)

    for flag <- [true, false] do
      refute Authorization.has_permission_in_scope?([:TENANT_ADMIN], @perm, flag)
    end

    overlay = %{STOREKEEPER: [@perm], TENANT_ADMIN: [@perm]}
    assert Authorization.role_allows?(:TASK_WORKER, @perm, overlay)
    refute Authorization.role_allows?(:TENANT_ADMIN, @perm, overlay)
    refute Authorization.role_allows?(:STOREKEEPER, @perm, overlay)
  end

  test "W3 the exceptions are narrow: every other permission keeps the admin catch-all rules" do
    # Roles stage 0 S0-3: TenantSecurityManage is TENANT_ADMIN's alone; also exclude it from PLATFORM_ADMIN.
    for p <- Authorization.permissions() -- [@perm, :TenantSecurityManage, :TasksReassignRouted] do
      assert Authorization.role_allows?(:PLATFORM_ADMIN, p), inspect(p)
    end

    for p <- Authorization.permissions() -- [@perm] do
      assert Authorization.role_allows?(:TENANT_ADMIN, p) ==
               (Authorization.permission_scope(p) == :tenant),
             inspect(p)
    end
  end

  test "W4 the golden holds exactly the nine TasksWorkInScope rows" do
    rows =
      @golden
      |> File.read!()
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(&String.split(&1, " "))
      |> Enum.filter(fn [_role, permission | _] -> permission == "TasksWorkInScope" end)

    assert length(rows) == 9

    assert Enum.filter(rows, &(Enum.at(&1, 2) == "true")) == [
             ["TASK_WORKER", "TasksWorkInScope", "true", "core", "core"]
           ]

    refused = Enum.filter(rows, &(Enum.at(&1, 2) == "false"))
    assert length(refused) == 8
    assert Enum.all?(refused, &(Enum.drop(&1, 3) == ["core", "-"]))
  end

  test "W5 the approver role list is derived from the permission and equals the old name" do
    assert ScopedApprovers.holder_roles() == ["TASK_WORKER"]
  end
end
