defmodule Letflow.Api.RouteScopeResolverTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-ii, AC 19 (design `lib/letflow/design/req518-compiler-scope-filter.md`
  3.6, 7.1, 10.2 T-L4 to T-L11 walk half, mutant MU32, MU31; spec `test/specs/REQ-518-2c-ii.md`;
  SEC code-gate step-17 condition F-1, which makes these seeded walk tests a MERGE CONDITION):
  the two walk rules of `Letflow.Api.RouteScope.audit_routes/3` shipped with the first declared
  resolver route, each proven live with SEEDED route rows, plus the committed lists against the
  REAL route table.

    * `:unexpected_resolver_route` in BOTH directions: a `{:resolver, _}` route that is not on the
      committed expectation (`@expected_resolver_routes`, the nine entity record write, history and
      attachment routes), and a listed route mounted with ANOTHER class (the resolver silently
      dropped, or the route left on the default);
    * `:data_route_default`: a default-sourced route of a data router (`Letflow.Routers.Entities`
      now) fails the walk; declared and key-table routes, and the default-sourced routes of other
      routers, do not (`Letflow.Routers.Tasks` is deliberately NOT a data router until PR 2d
      classifies its seven routes: pinned here so 2d has to change this test with its change);
    * the real table: the nine resolver routes mounted exactly as listed with the exported
      `ScopeResolver.record_scope/1`, the seven definition/restriction routes declared
      `:tenant_wide`, no default-sourced route in `Routers.Entities`, and the committed snapshot
      lost exactly those fifteen lines (137 to 122).

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.RouteScope
  alias Letflow.Entities.ScopeResolver
  alias Letflow.Support.RouteInventory

  @resolver {:resolver, {ScopeResolver, :record_scope}}

  @resolver_lines [
    "DELETE /entities/records/:entity_type/:record_id EntitiesRecordsWrite",
    "DELETE /entities/records/:entity_type/:record_id/attachments/:attachment_id EntitiesAttachmentsManage",
    "GET /entities/records/:entity_type/:record_id/attachments EntitiesAttachmentsRead",
    "GET /entities/records/:entity_type/:record_id/history EntitiesQuery",
    "GET /entities/records/:entity_type/:record_id/attachments/:attachment_id EntitiesAttachmentsRead",
    "POST /entities/records/:entity_type EntitiesRecordsWrite",
    "POST /entities/records/:entity_type/:record_id/attachments EntitiesAttachmentsManage",
    "POST /entities/records/:entity_type/import EntitiesRecordsImport",
    "PUT /entities/records/:entity_type/:record_id EntitiesRecordsWrite"
  ]

  @tenant_wide_lines [
    "GET /entities/definitions EntitiesDefinitionsRead",
    "GET /entities/definitions/:id EntitiesDefinitionsRead",
    "GET /entities/definitions/active/:name EntitiesDefinitionsRead",
    "GET /entities/definitions/by-name/:name EntitiesDefinitionsRead",
    "POST /entities/definitions EntitiesDefinitionsWrite",
    "POST /entities/definitions/:name/activate EntitiesDefinitionsWrite",
    "POST /entities/restrictions/import EntitiesRestrictionsManage"
  ]

  defp resolver_row(line, fields \\ %{}) do
    [method, path, key] = String.split(line, " ")

    Map.merge(
      %{
        router: Letflow.Routers.Entities,
        method: method,
        path: path,
        key: String.to_atom(key),
        declared: @resolver,
        class: @resolver,
        source: :declared
      },
      Map.new(fields)
    )
  end

  defp kinds(errors, kind), do: Enum.filter(errors, &(elem(&1, 0) == kind))

  defp audit(rows, snapshot \\ []), do: RouteScope.audit_routes(rows, snapshot, [])

  # ===========================================================================================
  describe ":unexpected_resolver_route (SEC step-12 F-1 / step-17 F-1), seeded" do
    test "the nine committed routes mounted as the resolver class are accepted" do
      for line <- @resolver_lines do
        assert kinds(audit([resolver_row(line)]), :unexpected_resolver_route) == [], line
      end
    end

    test "a resolver route NOT on the committed list fails: another path, method, key or router" do
      first = hd(@resolver_lines)

      for fields <- [
            %{path: "/entities/records/:entity_type/other"},
            %{method: "PATCH"},
            %{key: :EntitiesRecordsImport},
            %{router: Letflow.Routers.Instances, path: "/instances/:id/x"}
          ] do
        route = resolver_row(first, fields)
        assert {:unexpected_resolver_route, route} in audit([route]), inspect(fields)
      end
    end

    test "a {:resolver, _} route with ANOTHER resolver function is still a resolver route and must be listed" do
      other = {:resolver, {RouteScope, :class_of}}

      route =
        resolver_row("GET /tasks/:id TasksGetById", %{
          router: Letflow.Routers.Tasks,
          path: "/tasks/:id/other",
          declared: other,
          class: other
        })

      assert {:unexpected_resolver_route, route} in audit([route])
    end

    test "a LISTED route mounted with another class fails (MU32): default, tenant_wide, filter, self_service, admin_plane" do
      for line <- @resolver_lines,
          class <- [:tenant_wide, :filter, :self_service, :admin_plane] do
        route = resolver_row(line, %{declared: class, class: class})
        assert {:unexpected_resolver_route, route} in audit([route]), "#{line} as #{class}"
      end

      for line <- @resolver_lines do
        defaulted = resolver_row(line, %{declared: nil, class: :tenant_wide, source: :default})
        errors = audit([defaulted], [RouteScope.snapshot_line(defaulted)])
        assert {:unexpected_resolver_route, defaulted} in errors, line
      end
    end

    test "a same-path route with a DIFFERENT method or key and another class is not a listed route" do
      other =
        resolver_row("GET /entities/records/:entity_type EntitiesRecordsWrite", %{
          declared: :tenant_wide,
          class: :tenant_wide
        })

      assert kinds(audit([other]), :unexpected_resolver_route) == []
    end

    test "the rule reports once per offending route and reports nothing for unrelated routes" do
      a = resolver_row(hd(@resolver_lines), %{declared: :filter, class: :filter})
      b = resolver_row("GET /x/y XRead", %{router: Letflow.Routers.Instances})

      unrelated =
        resolver_row("GET /instances InstancesRead", %{
          router: Letflow.Routers.Instances,
          declared: :tenant_wide,
          class: :tenant_wide
        })

      assert kinds(audit([a, b, unrelated]), :unexpected_resolver_route) |> Enum.sort() ==
               Enum.sort([{:unexpected_resolver_route, a}, {:unexpected_resolver_route, b}])
    end

    test "pinned (SEC OBS-3): an UNMOUNTED listed route is not reported; the real-table tests pin that all are mounted" do
      assert kinds(audit([]), :unexpected_resolver_route) == []
    end
  end

  # ===========================================================================================
  describe ":data_route_default, seeded" do
    defp entities_row(fields) do
      Map.merge(
        %{
          router: Letflow.Routers.Entities,
          method: "GET",
          path: "/entities/new",
          key: :EntitiesQuery,
          declared: nil,
          class: :tenant_wide,
          source: :default
        },
        Map.new(fields)
      )
    end

    test "a default-sourced route of Routers.Entities fails, even when its snapshot line is present" do
      route = entities_row(%{})
      assert {:data_route_default, route} in audit([route], [RouteScope.snapshot_line(route)])
      assert {:data_route_default, route} in audit([route], [])
    end

    test "the seeded failure holds for every method and for a route that would otherwise be an unclassified one" do
      for method <- ["GET", "POST", "PUT", "DELETE", "PATCH"] do
        route = entities_row(%{method: method, path: "/entities/zzz"})
        assert {:data_route_default, route} in audit([route])
      end
    end

    test "a declared route of Routers.Entities does not fail (every declared class)" do
      for class <- [:tenant_wide, :filter, :self_service, @resolver] do
        route = entities_row(%{declared: class, class: class, source: :declared})
        assert kinds(audit([route]), :data_route_default) == [], inspect(class)
      end
    end

    test "a key-table route (admin plane) of Routers.Entities does not fail" do
      route = entities_row(%{declared: nil, class: :admin_plane, source: :key_table})
      assert kinds(audit([route]), :data_route_default) == []
    end

    test "a default-sourced route of ANOTHER router does not fail (Instances, Webhooks, Modules)" do
      for router <- [Letflow.Routers.Instances, Letflow.Routers.Me] do
        route = entities_row(%{router: router, path: "/anything"})
        assert kinds(audit([route], [RouteScope.snapshot_line(route)]), :data_route_default) == []
      end
    end

    test "Routers.Tasks IS a data router (REQ-518 PR 2d added it in the SAME change that classified its seven routes)" do
      route =
        entities_row(%{router: Letflow.Routers.Tasks, path: "/tasks/:id", key: :TasksGetById})

      assert [{:data_route_default, ^route}] =
               kinds(audit([route], [RouteScope.snapshot_line(route)]), :data_route_default)
    end
  end

  # ===========================================================================================
  setup_all do
    {:ok, routes: RouteInventory.routes(), snapshot: RouteInventory.read_snapshot()}
  end

  describe "the committed lists equal the REAL route table" do
    test "the real table audits to [] with the shipped lists", %{
      routes: routes,
      snapshot: snapshot
    } do
      assert RouteScope.audit_routes(routes, snapshot) == []
    end

    test "the {:resolver, _} routes of the table are EXACTLY the nine entity routes and the five task routes (PR 2d), with the exported resolvers",
         %{
           routes: routes
         } do
      resolver_rows = Enum.filter(routes, &match?({:resolver, _}, &1.class))

      task_lines = [
        "GET /tasks/:id TasksGetById",
        "POST /tasks/:id/assign TasksAssign",
        "POST /tasks/:id/claim TasksComplete",
        "POST /tasks/:id/complete TasksComplete",
        "POST /tasks/:id/reassign TasksReassign",
        "POST /documents/:document_id/hold DocumentHold",
        "POST /documents/:document_id/hold/release DocumentHold"
      ]

      assert resolver_rows |> Enum.map(&RouteScope.snapshot_line/1) |> Enum.sort() ==
               Enum.sort(@resolver_lines ++ task_lines)

      for row <- resolver_rows do
        assert row.source == :declared

        case row.router do
          Letflow.Routers.Documents ->
            assert row.class == {:resolver, {Letflow.Documents.ScopeResolver, :document_scope}}

          Letflow.Routers.Tasks ->
            assert row.class == {:resolver, {Letflow.Tasks.ScopeResolver, :task_scope}}

          Letflow.Routers.Entities ->
            assert row.class == @resolver
        end
      end

      assert function_exported?(Letflow.Documents.ScopeResolver, :document_scope, 1)
      assert function_exported?(ScopeResolver, :record_scope, 1)
      assert function_exported?(Letflow.Tasks.ScopeResolver, :task_scope, 1)
    end

    test "the seven definition/restriction routes are declared :tenant_wide", %{routes: routes} do
      for line <- @tenant_wide_lines do
        row = Enum.find(routes, &(RouteScope.snapshot_line(&1) == line))
        assert row, "#{line} is mounted"
        assert row.class == :tenant_wide and row.source == :declared, line
      end
    end

    test "NO route of Routers.Entities is default-sourced", %{routes: routes} do
      entity_rows = Enum.filter(routes, &(&1.router == Letflow.Routers.Entities))
      assert length(entity_rows) == 19
      assert Enum.filter(entity_rows, &(&1.source == :default)) == []
    end

    test "the snapshot lost exactly the fifteen lines of AC 19 and holds none of E1-E7 or E11-E18 (MU31)",
         %{
           snapshot: snapshot
         } do
      # 122 after 2c-ii; PR 2d removed the seven task lines (design 7.1 T1-T7); GH #2548 added the auditor source-read line (116); REQ-510 slice 1 added the three exam authoring lines (119), REQ-515 added the reactivate line (120); REQ-545 removed GET /definitions and GET /definitions/search (118), REQ-546 removed GET /definitions/:id and GET /definitions/active/:name (116), REQ-552 added GET /tenant/config-bundle and POST /tenant/config-bundle/import (118)
      # REQ-565 (GH #3201) added the five integration-mappings lines (123).
      # REQ-567 part 2 (GH #3217) added the three entity-type-hooks lines (126).
      # REQ-561 part 2 (GH #3194) added the six scheduled-jobs lines (132).
      # REQ-570 part 2 (GH #3248) added the three record-trigger-bindings lines (135).
      assert length(snapshot) == 136

      for line <- @resolver_lines ++ @tenant_wide_lines do
        refute line in snapshot, line
      end

      # a snapshot that KEPT one of the lines is reported as stale for the real table
      routes = RouteInventory.routes()

      for line <- @resolver_lines ++ @tenant_wide_lines do
        assert {:stale_snapshot, line} in RouteScope.audit_routes(routes, [line | snapshot]), line
      end
    end

    test "no Routers.Entities line is left in the snapshot at all except none (every entity route is classified)",
         %{
           snapshot: snapshot
         } do
      entity_lines = Enum.filter(snapshot, &String.contains?(&1, " /entities/"))
      assert entity_lines == [], inspect(entity_lines)
    end
  end
end
