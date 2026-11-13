defmodule Letflow.Api.ImportAnyTypeTest do
  @moduledoc """
  Roles stage 0 S0-1 (decision 0088, docs/design/roles-stage0-slices.md): the permission
  `:EntitiesRecordsImportAnyType` replaces the role name STOREKEEPER in the import route's rule.

    * P1 the atom: fourth-to-last core permission, tenant scope, resolves to itself, no route gates on it;
    * P2 holders are exactly PLATFORM_ADMIN and TENANT_ADMIN, STOREKEEPER keeps Import only;
    * P3 platform rule;
    * P4 the new predicate equals today's STOREKEEPER-only predicate for all 512 role sets;
    * P5 the golden rows.

  Pure, no database: `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.Authorization

  @perm :EntitiesRecordsImportAnyType
  @import :EntitiesRecordsImport
  @golden "priv/permission_matrix/effective.golden"

  # today's code (record_import.ex before S0-1), restated
  defp old(roles) do
    :STOREKEEPER in roles and
      not Enum.any?(roles -- [:STOREKEEPER], &Authorization.role_allows?(&1, @import))
  end

  defp new(roles) do
    Authorization.has_permission?(roles, @import) and
      not Authorization.has_permission?(roles, @perm)
  end

  defp subsets([]), do: [[]]

  defp subsets([h | t]) do
    rest = subsets(t)
    rest ++ Enum.map(rest, &[h | &1])
  end

  test "P1 fourth-to-last core permission, tenant scope, resolves to itself, no route gates on it" do
    assert @perm in Authorization.core_permissions()
    assert Authorization.core_permissions() |> Enum.take(-4) |> hd() == @perm
    assert Authorization.permission_scope(@perm) == :tenant
    assert Authorization.required_permission(@perm) == @perm

    keys =
      for route <- Letflow.Routers.Entities.__authz_routes__(),
          do: inspect(route)

    refute Enum.any?(keys, &String.contains?(&1, "EntitiesRecordsImportAnyType"))
  end

  test "P2 holders are PLATFORM_ADMIN and TENANT_ADMIN; STOREKEEPER keeps Import only" do
    holders = for r <- Authorization.roles(), Authorization.role_allows?(r, @perm), do: r
    assert Enum.sort(holders) == [:PLATFORM_ADMIN, :TENANT_ADMIN]
    assert Authorization.role_allows?(:STOREKEEPER, @import)
    refute Authorization.role_allows?(:STOREKEEPER, @perm)
  end

  test "P3 platform rule" do
    assert Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], @perm, true)
    refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], @perm, false)
    assert Authorization.has_permission_in_scope?([:TENANT_ADMIN], @perm, false)
  end

  @tag timeout: 60_000
  test "P4 new predicate equals the STOREKEEPER-only predicate for every role set" do
    all = subsets(Authorization.roles())
    assert length(all) == :math.pow(2, length(Authorization.roles())) |> trunc()

    for roles <- all do
      assert old(roles) == new(roles), "differs for #{inspect(roles)}"
    end

    # refused and allowed branches, so the loop is not vacuous
    assert new([:STOREKEEPER])
    refute new([:STOREKEEPER, :TENANT_ADMIN])
    refute new([:STOREKEEPER, :PLATFORM_ADMIN])
    refute new([:TENANT_ADMIN])
    refute new([:PROCESS_OPERATOR])
  end

  test "P5 golden rows: true for the two admins, false for the rest, never without Import" do
    rows =
      @golden
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(&String.split(&1, " "))

    any = for [role, "EntitiesRecordsImportAnyType", allowed | _] <- rows, do: {role, allowed}
    imp = for [role, "EntitiesRecordsImport", allowed | _] <- rows, into: %{}, do: {role, allowed}

    assert length(any) == length(Authorization.roles())

    for {role, allowed} <- any do
      assert allowed == "true" == role in ["PLATFORM_ADMIN", "TENANT_ADMIN"], role
      if allowed == "true", do: assert(imp[role] == "true", role)
    end
  end
end
