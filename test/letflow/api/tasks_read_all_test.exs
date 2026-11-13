defmodule Letflow.Api.TasksReadAllTest do
  @moduledoc """
  Roles stage 0, slice S0-5 (decision 0088, `docs/design/roles-stage0-slices.md`, ruling
  `docs/design/storekeeper-task-visibility-ruling.md`): the permission `:TasksReadAll` replaces the
  role-name test `is_task_worker_only?/1` on the task read routes.

    * A1 the atom: last core permission, tenant scope, resolves to itself, no route gates on it;
    * A2 holders are exactly the five roles that saw every task before;
    * A3 non-assignable: not in `grantable/0`, the overlay cannot add it, Catalog cannot grant it;
    * A4 every role set x platform flag: the only changed answer of `GET /tasks` is the
      STOREKEEPER-only case, and it only narrows;
    * A5 `reads_all_tasks?/2` (the inbox and by-id predicate) agrees with A4;
    * A6 the catch-alls are untouched: no false clause was added;
    * A7 the golden carries exactly nine `TasksReadAll` rows.

  The HTTP side (both branches through `GET /tasks`, `/tasks/inbox`, `/tasks/:id`) is in
  `test/letflow/routers/tasks_test.exs` (H1..H5). Pure (no database): `async: true` is safe.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext

  @perm :TasksReadAll
  @golden "priv/permission_matrix/effective.golden"
  @five [:PLATFORM_ADMIN, :PROCESS_DESIGNER, :PROCESS_OPERATOR, :TENANT_ADMIN, :TENANT_AUDITOR]

  test "A1 last core permission, tenant scope, resolves to itself, no route gates on it" do
    assert List.last(Authorization.core_permissions()) == @perm
    assert Authorization.permission_scope(@perm) == :tenant
    assert Authorization.required_permission(@perm) == @perm

    for route <- Letflow.Routers.Tasks.__authz_routes__() do
      refute inspect(route) =~ "TasksReadAll"
    end

    assert Authorization.required_permission(:TasksList) == :TasksRead
    assert Authorization.required_permission(:TasksGetById) == :TasksRead
  end

  test "A2 holders are the five roles; both platform flags" do
    holders = for r <- Authorization.roles(), Authorization.role_allows?(r, @perm), do: r
    assert holders == Enum.filter(Authorization.roles(), &(&1 in @five))
    assert Enum.sort(holders) == Enum.sort(@five)

    assert Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], @perm, true)
    refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], @perm, false)

    for role <- @five -- [:PLATFORM_ADMIN] do
      assert Authorization.has_permission_in_scope?([role], @perm, true), inspect(role)
      assert Authorization.has_permission_in_scope?([role], @perm, false), inspect(role)
    end

    for role <- Authorization.roles() -- @five, flag <- [true, false] do
      refute Authorization.has_permission_in_scope?([role], @perm, flag), inspect(role)
    end
  end

  test "A3 non-assignable: not grantable, overlay cannot add it, Catalog cannot grant it" do
    refute @perm in (Authorization.grantable() |> Map.values() |> List.flatten())

    overlay = %{STOREKEEPER: [@perm], TASK_WORKER: [@perm]}

    for role <- [:STOREKEEPER, :TASK_WORKER] do
      refute Authorization.role_allows?(role, @perm, overlay), inspect(role)
    end

    for role <- Authorization.roles() do
      refute @perm in Letflow.Modules.Catalog.role_grants(role), inspect(role)
    end
  end

  defp subsets([]), do: [[]]

  defp subsets([h | t]) do
    rest = subsets(t)
    rest ++ Enum.map(rest, &[h | &1])
  end

  defp decide(roles, flag) do
    Authorization.evaluate_access(
      %AccessContext{user_id: "u", roles: roles, platform_tenant?: flag},
      :TasksList
    )
  end

  defp eff(roles, true), do: roles
  defp eff(roles, false), do: roles -- [:PLATFORM_ADMIN]

  @tag timeout: 60_000
  test "A4 only the STOREKEEPER-only answers change, and they only narrow" do
    cases = for s <- subsets(Authorization.roles()), flag <- [true, false], do: {s, flag}
    assert length(cases) == 1024

    changed =
      for {s, flag} <- cases, reduce: [] do
        acc ->
          e = eff(s, flag)
          decision = decide(s, flag)
          holds_read? = Enum.any?(e, &Authorization.role_allows?(&1, :TasksRead))

          old_filtered? = holds_read? and Authorization.is_task_worker_only?(e)
          new_filtered? = holds_read? and not Enum.any?(e, &(&1 in @five))

          cond do
            not holds_read? ->
              assert decision.kind == :Deny403
              acc

            new_filtered? ->
              assert decision.kind == :AllowWithRowFilter
              assert decision.task_scope == {:own_user_and_groups, "u"}
              if old_filtered?, do: acc, else: [{s, flag} | acc]

            true ->
              assert decision.kind == :Allow
              assert decision.task_scope == :all
              # never widened: a case filtered before is filtered now
              refute old_filtered?
              acc
          end
      end

    expected =
      for {s, flag} <- cases,
          e = eff(s, flag),
          :STOREKEEPER in e and :TASK_WORKER not in e and Enum.all?(e, &(&1 not in @five)),
          do: {s, flag}

    assert Enum.sort(changed) == Enum.sort(expected)
    assert Enum.count(expected, fn {_, flag} -> flag end) == 4
    assert Enum.count(expected, fn {_, flag} -> not flag end) == 8
  end

  test "A5 reads_all_tasks?/2 agrees with the list decision for every TasksRead holder" do
    for s <- subsets(Authorization.roles()), flag <- [true, false] do
      e = eff(s, flag)

      if Enum.any?(e, &Authorization.role_allows?(&1, :TasksRead)) do
        assert Authorization.reads_all_tasks?(e, flag) == (decide(s, flag).task_scope == :all),
               inspect({s, flag})
      end
    end

    refute Authorization.reads_all_tasks?([:STOREKEEPER], false)
    assert Authorization.reads_all_tasks?([:TENANT_AUDITOR, :STOREKEEPER], false)
  end

  test "A6 the catch-alls are untouched: no false clause was added" do
    for p <-
          Authorization.permissions() --
            [:TasksWorkInScope, :TenantSecurityManage, :TasksReassignRouted] do
      assert Authorization.role_allows?(:PLATFORM_ADMIN, p), inspect(p)
    end

    for p <- Authorization.permissions() -- [:TasksWorkInScope] do
      assert Authorization.role_allows?(:TENANT_ADMIN, p) ==
               (Authorization.permission_scope(p) == :tenant),
             inspect(p)
    end
  end

  test "A7 the golden carries exactly the nine TasksReadAll rows" do
    lines = @golden |> File.read!() |> String.split(~r/\r?\n/, trim: true)
    rows = lines |> Enum.reject(&String.starts_with?(&1, "#")) |> Enum.map(&String.split(&1, " "))
    mine = Enum.filter(rows, fn [_role, permission | _] -> permission == "TasksReadAll" end)

    assert length(mine) == 9

    granted = for [role, _, "true", "core", "core"] <- mine, do: role
    assert Enum.sort(granted) == Enum.sort(Enum.map(@five, &Atom.to_string/1))

    refused = Enum.filter(mine, &(Enum.at(&1, 2) == "false"))
    assert length(refused) == 4
    assert Enum.all?(refused, &(Enum.drop(&1, 3) == ["core", "-"]))

    permission_count = rows |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq() |> length()
    assert "# permissions: #{permission_count}" in lines
    assert "# rows: #{length(rows)}" in lines
  end
end
