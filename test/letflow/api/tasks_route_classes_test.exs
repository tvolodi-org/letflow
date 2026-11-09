defmodule Letflow.Api.TasksRouteClassesTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2d, AC 20 and the walk half of AC 23 (T-L12 to T-L18, MU31, MU32;
  design `lib/letflow/design/req518-compiler-scope-filter.md` 7.1 T1 to T7, 10.3; spec
  `test/specs/REQ-518-2d.md`; SEC code-gate step-24, "exactly seven routes are reclassified"):

    * the REAL route table: every one of the seven routes of `Letflow.Routers.Tasks` is declared,
      none is default-sourced, `GET /tasks` and `GET /tasks/inbox` are `:filter`, the other five are
      `{:resolver, {Letflow.Tasks.ScopeResolver, :task_scope}}` with the resolver exported; the walk
      audits to `[]`; the committed snapshot lost exactly those seven lines (122 to 115) and holds
      none of them;
    * the walk rules are LIVE for the task routes (seeded rows): a default-sourced task route
      (`:data_route_default`, Routers.Tasks is a data router), a resolver route that lost its
      resolver (`:unexpected_resolver_route`), a filter route that lost `:filter`
      (`:unexpected_filter_route`), a snapshot line kept after reclassification (`:stale_snapshot`);
    * `Letflow.Tasks.ScopeResolver.task_scope/1` is pure and fail-closed.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.RouteScope
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Support.RouteInventory
  alias Letflow.Tasks.ScopeResolver

  @resolver {:resolver, {ScopeResolver, :task_scope}}

  @filter_lines ["GET /tasks TasksList", "GET /tasks/inbox TasksList"]

  @resolver_lines [
    "GET /tasks/:id TasksGetById",
    "POST /tasks/:id/assign TasksAssign",
    "POST /tasks/:id/claim TasksComplete",
    "POST /tasks/:id/complete TasksComplete",
    "POST /tasks/:id/reassign TasksReassign"
  ]

  setup_all do
    routes = RouteInventory.routes()

    {:ok,
     routes: routes,
     snapshot: RouteInventory.read_snapshot(),
     task_routes: Enum.filter(routes, &(&1.router == Letflow.Routers.Tasks))}
  end

  defp row(line, fields) do
    [method, path, key] = String.split(line, " ")

    Map.merge(
      %{
        router: Letflow.Routers.Tasks,
        method: method,
        path: path,
        key: String.to_atom(key),
        declared: nil,
        class: :tenant_wide,
        source: :default
      },
      Map.new(fields)
    )
  end

  defp kinds(errors, kind), do: Enum.filter(errors, &(elem(&1, 0) == kind))

  # ===========================================================================================
  describe "T-L12 to T-L18: the real route table" do
    test "Routers.Tasks has exactly the seven routes of the ledger, every one DECLARED (none default-sourced)",
         %{task_routes: task_routes} do
      lines = task_routes |> Enum.map(&RouteScope.snapshot_line/1) |> Enum.sort()
      assert lines == Enum.sort(@filter_lines ++ @resolver_lines)
      assert length(task_routes) == 7

      for route <- task_routes do
        assert route.source == :declared, RouteScope.snapshot_line(route)
        refute route.class == :tenant_wide, RouteScope.snapshot_line(route)
      end
    end

    test "T-L12 / T-L13: GET /tasks and GET /tasks/inbox are :filter", %{task_routes: task_routes} do
      for line <- @filter_lines do
        route = Enum.find(task_routes, &(RouteScope.snapshot_line(&1) == line))
        assert route.class == :filter, line
      end
    end

    test "T-L14 to T-L18: get, claim, complete, assign and reassign are {:resolver, task_scope} with an EXPORTED resolver",
         %{task_routes: task_routes} do
      for line <- @resolver_lines do
        route = Enum.find(task_routes, &(RouteScope.snapshot_line(&1) == line))
        assert route.class == @resolver, line
      end

      assert function_exported?(ScopeResolver, :task_scope, 1)
    end

    test "the walk audits the real table to [] and the snapshot lost exactly the seven task lines (122 to 115), holding none",
         %{routes: routes, snapshot: snapshot} do
      assert RouteScope.audit_routes(routes, snapshot) == []
      # REQ-565 (GH #3201) added the five integration-mappings lines (123).
      # GH #3324 (REQ-588 part A) added the two exam grading-queue read lines (140).
      # GH #3338 (REQ-590) added the two tenant logo lines (142).
      # GH #3162 (REQ-544 part 2) added the five procurement lines; with #3324 part B (grade POST) 149.
      # REQ-633 (GH #3530) added the entity-type-hooks dry-run line (160).
      # GH #3610 (REQ-668) added the three catalog_items lot lines and GH #3611 (REQ-667) the five codes write lines (183 -> 191).
      # REQ-717 (GH #3764) added five count differences lines (222 -> 228); REQ-716 the count scan line (228 -> 229).
      # REQ-725 (GH #3775) added the stock document check line (229 -> 230).
      # REQ-718 (GH #3884) added four count posting lines (230 -> 234).
      # REQ-639 F-5 added the form-validation-dry-run line (234 -> 235).
      # REQ-736 (GH #3861) added the count print route line (235 -> 236).
      # REQ-737 (GH #3860) added the document print route line (236 -> 237).
      # REQ-741 (GH #3879) added the two stock voice draft lines (237 -> 239).
      # REQ-768 (GH #3920) added the module upgrade plan route line (242 -> 243).
      # REQ-749 (GH #3893) added the three assets register read lines (242 -> 245).
      # T-1417 (E5c) added the stock card print route line (246 -> 247).
      # REQ-770 (GH #3918) added the module upgrade apply route line (247 -> 248).
      assert length(snapshot) == 258
      # REQ-751 / REQ-752 (GH #3891, #3890) added the seven assets document lines (248 -> 255).
      # REQ-779 (GH #4017) added the codes label route line (255 -> 256).

      for line <- @filter_lines ++ @resolver_lines do
        refute line in snapshot, line
      end

      refute Enum.any?(snapshot, &String.contains?(&1, " /tasks"))
    end

    test "the real table holds the two filter and the five resolver task routes of the committed expectation lists",
         %{routes: routes} do
      filter = routes |> RouteScope.filter_routes() |> Enum.map(&RouteScope.snapshot_line/1)
      assert Enum.all?(@filter_lines, &(&1 in filter))

      resolver =
        routes
        |> Enum.filter(&match?({:resolver, _}, &1.class))
        |> Enum.map(&RouteScope.snapshot_line/1)

      assert Enum.all?(@resolver_lines, &(&1 in resolver))
    end
  end

  # ===========================================================================================
  describe "the walk rules are live for the task routes (seeded rows; MU31, MU32)" do
    test "a default-sourced route of Routers.Tasks fails :data_route_default, for each of the seven" do
      for line <- @filter_lines ++ @resolver_lines do
        route = row(line, %{})
        errors = RouteScope.audit_routes([route], [RouteScope.snapshot_line(route)], [])

        assert [{:data_route_default, ^route}] = kinds(errors, :data_route_default), line
      end
    end

    test "MU32: a resolver task route mounted as :tenant_wide, :filter or :self_service fails :unexpected_resolver_route" do
      for line <- @resolver_lines, class <- [:tenant_wide, :filter, :self_service] do
        route = row(line, %{class: class, declared: class, source: :declared})
        errors = RouteScope.audit_routes([route], [], [])

        assert [{:unexpected_resolver_route, ^route}] = kinds(errors, :unexpected_resolver_route),
               "#{line} as #{class}"
      end
    end

    test "a filter task route mounted as :tenant_wide or a resolver fails :unexpected_filter_route" do
      for line <- @filter_lines, class <- [:tenant_wide, @resolver] do
        route = row(line, %{class: class, declared: class, source: :declared})
        errors = RouteScope.audit_routes([route], [], [])

        assert [{:unexpected_filter_route, ^route}] = kinds(errors, :unexpected_filter_route),
               "#{line} as #{inspect(class)}"
      end
    end

    test "MU31: a snapshot that kept one of the seven task lines is :stale_snapshot" do
      for line <- @filter_lines ++ @resolver_lines do
        route = row(line, %{class: @resolver, declared: @resolver, source: :declared})
        errors = RouteScope.audit_routes([route], [line], [])

        assert {:stale_snapshot, line} in errors, line
      end
    end

    test "an UNLISTED task route declared as a resolver fails :unexpected_resolver_route" do
      route =
        row("POST /tasks/:id/cancel TasksComplete", %{
          class: @resolver,
          declared: @resolver,
          source: :declared
        })

      assert [{:unexpected_resolver_route, ^route}] =
               kinds(RouteScope.audit_routes([route], [], []), :unexpected_resolver_route)
    end
  end

  # ===========================================================================================
  describe "Letflow.Tasks.ScopeResolver.task_scope/1 (pure, fail closed)" do
    test "a task with a node is {:node, id}; a NULL, empty or malformed node and a non-task are :unresolvable" do
      assert ScopeResolver.task_scope(%EngineTask{scope_node_id: "sf-a"}) == {:node, "sf-a"}
      assert ScopeResolver.task_scope(%EngineTask{scope_node_id: nil}) == :unresolvable
      assert ScopeResolver.task_scope(%EngineTask{scope_node_id: ""}) == :unresolvable
      assert ScopeResolver.task_scope(%EngineTask{scope_node_id: 5}) == :unresolvable

      for other <- [nil, %{scope_node_id: "sf-a"}, "sf-a", {:node, "sf-a"}, []] do
        assert ScopeResolver.task_scope(other) == :unresolvable, inspect(other)
      end
    end
  end
end
