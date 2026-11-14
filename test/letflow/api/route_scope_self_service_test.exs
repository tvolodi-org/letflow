defmodule Letflow.Api.RouteScopeSelfServiceTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-b, AC 18 and AC 21 (design
  `lib/letflow/design/req518-compiler-scope-filter.md` 4.2, 7.1, 10.1 T-S1, T-S8, T-C11; spec
  `test/specs/REQ-518-2c-i-b.md`; SEC code-gate step-12 and REVIEWER step-13 F-2): the walk rules
  of `Letflow.Api.RouteScope.audit_routes/3` for the `:self_service` class and the `:filter`
  expectation, each proven live with SEEDED route rows and a SEEDED self-service list, plus the
  committed lists against the REAL route table.

    * `:self_service_not_listed`: any route under `/me` or `/help` that is not on the list;
    * `:self_service_list_mismatch`: the routes of class `:self_service` are EXACTLY the list
      entries classed `:self_service` (both directions);
    * `:tenant_wide_unruled`: a `:tenant_wide` entry (or its mounted route) with no ruling id;
    * `:pending_marker_unlisted`: the `:pending_sec_ruling` marker on an entry that is not a
      `:tenant_wide` route;
    * `:unexpected_filter_route` in BOTH directions: a `:filter` route not on the committed
      expectation, and a listed route mounted with another class;
    * the committed lists equal the real mounted table (the three filter routes; M1, M2, H1);
      the snapshot lost exactly the six lines.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  @memberships "GET /me/memberships"
  @filter_lines [
    "POST /entities/query EntitiesQuery",
    "POST /entities/query/aggregate EntitiesAggregate",
    "POST /entities/records/:entity_type/export EntitiesRecordsExport",
    # REQ-518 PR 2d (AC 20): the two task list routes
    "GET /tasks TasksList",
    "GET /tasks/inbox TasksList"
  ]
  @removed_lines [
    "GET /help/resolved HelpRead",
    "GET /me/memberships MembershipsRead",
    "GET /me/modules MyModulesRead",
    "GET /me/access MyAccessRead",
    "GET /me/preferences MyAccessRead",
    "PUT /me/preferences MyPreferencesSet",
    "GET /me/notifications MyAccessRead",
    "POST /me/notifications/read MyPreferencesSet"
    | @filter_lines
  ]

  defp row(fields) do
    Map.merge(
      %{
        router: Letflow.Routers.Me,
        method: "GET",
        path: "/me/memberships",
        key: :MembershipsRead,
        declared: nil,
        class: :tenant_wide,
        source: :default
      },
      Map.new(fields)
    )
  end

  defp declared_row(class, fields),
    do: row(Map.merge(%{declared: class, class: class, source: :declared}, Map.new(fields)))

  defp entry(fields) do
    Map.merge(
      %{route: @memberships, key: :MembershipsRead, class: :self_service, ruling: "0051-A7"},
      Map.new(fields)
    )
  end

  defp line(row), do: RouteScope.snapshot_line(row)

  defp errors_of(rows, list), do: rows |> RouteScope.audit_routes([], list) |> Enum.sort()

  defp kinds(errors), do: errors |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  # ===========================================================================================
  describe "a consistent seeded table is clean" do
    test "a listed :self_service route declared :self_service audits to []" do
      assert errors_of([declared_row(:self_service, %{})], [entry(%{})]) == []
    end

    test "a ruled :tenant_wide entry on a mounted :tenant_wide route (SEC-ruled tenant-wide state) is clean" do
      route = declared_row(:tenant_wide, %{})
      assert errors_of([route], [entry(%{class: :tenant_wide, ruling: "SEC-X"})]) == []
    end
  end

  # ===========================================================================================
  describe "T-S1 :self_service_not_listed" do
    test "a route under /me or /help that is not on the list fails, whatever its class" do
      for {path, class} <- [
            {"/me/other", :tenant_wide},
            {"/me", :tenant_wide},
            {"/help/other", :tenant_wide},
            {"/help", :tenant_wide},
            {"/help/resolved/deep", :filter}
          ] do
        route = declared_row(class, %{path: path})
        errors = RouteScope.audit_routes([route], [line(route)], [])

        assert {:self_service_not_listed, route} in errors, "#{path} (#{class})"
      end
    end

    test "a route outside /me and /help is not subject to the rule, and a lookalike prefix is not /me or /help" do
      for path <- ["/instances", "/menu", "/memberships", "/helpdesk", "/mea/x", "/helper"] do
        route = declared_row(:tenant_wide, %{path: path, router: Letflow.Routers.Instances})

        refute Enum.any?(
                 RouteScope.audit_routes([route], [], []),
                 &match?({:self_service_not_listed, _}, &1)
               ),
               path
      end
    end

    test "a /definitions route is not reported as :self_service_not_listed (walk prefixes stay /me and /help)" do
      for path <- ["/definitions", "/definitions/search"] do
        route = declared_row(:tenant_wide, %{path: path, router: Letflow.Routers.Instances})

        refute Enum.any?(
                 RouteScope.audit_routes([route], [], []),
                 &match?({:self_service_not_listed, _}, &1)
               ),
               path
      end
    end

    test "an unlisted route is reported once per route, with the row itself" do
      first = declared_row(:tenant_wide, %{path: "/me/a"})
      second = declared_row(:tenant_wide, %{path: "/help/b", router: Letflow.Routers.Help})

      errors = RouteScope.audit_routes([first, second], [], [])

      assert Enum.filter(errors, &match?({:self_service_not_listed, _}, &1)) |> Enum.sort() ==
               Enum.sort([{:self_service_not_listed, first}, {:self_service_not_listed, second}])
    end
  end

  # ===========================================================================================
  describe "T-S1 :self_service_list_mismatch, both directions" do
    test "a :self_service route that is not on the list fails (adding a route to the class means editing the list)" do
      route =
        declared_row(:self_service, %{path: "/instances/mine", router: Letflow.Routers.Instances})

      assert errors_of([route], []) == [{:self_service_list_mismatch, route}]
    end

    test "a :self_service route under /me that is not on the list fails with both :not_listed and :list_mismatch" do
      route = declared_row(:self_service, %{path: "/me/new"})

      assert kinds(errors_of([route], [])) ==
               Enum.sort([:self_service_list_mismatch, :self_service_not_listed])
    end

    test "an entry classed :self_service whose mounted route is not :self_service fails" do
      for class <- [:tenant_wide, :filter] do
        route = declared_row(class, %{})
        errors = errors_of([route], [entry(%{})])

        assert {:self_service_list_mismatch, route} in errors, inspect(class)
      end
    end

    test "an entry classed :tenant_wide whose mounted route is :self_service fails" do
      route = declared_row(:self_service, %{})
      errors = errors_of([route], [entry(%{class: :tenant_wide, ruling: "SEC-X"})])

      assert errors == [{:self_service_list_mismatch, route}]
    end

    test "a list entry for a route that is not mounted does not fail the walk by itself" do
      # SEC step-12 F-2 (optional hardening): documented, not enforced
      assert errors_of([], [entry(%{})]) == []
    end
  end

  # ===========================================================================================
  describe "T-S1 :tenant_wide_unruled" do
    test "a :tenant_wide entry without a usable ruling fails, by route string" do
      route = declared_row(:tenant_wide, %{})

      for ruling <- [nil, ""] do
        errors = errors_of([route], [entry(%{class: :tenant_wide, ruling: ruling})])
        assert {:tenant_wide_unruled, @memberships} in errors, inspect(ruling)
      end
    end

    test "the mounted :tenant_wide route of an unruled entry is also reported, with its row" do
      route = declared_row(:tenant_wide, %{})
      errors = errors_of([route], [entry(%{class: :tenant_wide, ruling: nil})])

      assert {:tenant_wide_unruled, route} in errors
      assert {:tenant_wide_unruled, @memberships} in errors
    end

    test "a ruling id or the pending marker is a ruled state" do
      route = declared_row(:tenant_wide, %{})

      for ruling <- ["SEC-518-R2-modules", :pending_sec_ruling] do
        assert errors_of([route], [entry(%{class: :tenant_wide, ruling: ruling})]) == [],
               inspect(ruling)
      end
    end

    test "an unruled :self_service entry is not a :tenant_wide_unruled case (the rule is about the SEC-ruled tenant-wide state)" do
      route = declared_row(:self_service, %{})

      refute Enum.any?(
               errors_of([route], [entry(%{ruling: nil})]),
               &match?({:tenant_wide_unruled, _}, &1)
             )
    end
  end

  # ===========================================================================================
  describe "T-S1 / T-S8 :pending_marker_unlisted" do
    test "the marker on an entry classed :self_service fails" do
      route = declared_row(:self_service, %{})
      errors = errors_of([route], [entry(%{ruling: :pending_sec_ruling})])

      assert {:pending_marker_unlisted, @memberships} in errors
    end

    test "the marker on an entry whose mounted route is not :tenant_wide fails" do
      for class <- [:filter, :self_service] do
        route = declared_row(class, %{})
        errors = errors_of([route], [entry(%{class: :tenant_wide, ruling: :pending_sec_ruling})])

        assert {:pending_marker_unlisted, @memberships} in errors, inspect(class)
      end
    end

    test "the marker on a :tenant_wide entry whose route is mounted :tenant_wide is the valid, REQ-519-blocking state" do
      route = declared_row(:tenant_wide, %{})

      assert errors_of([route], [entry(%{class: :tenant_wide, ruling: :pending_sec_ruling})]) ==
               []
    end
  end

  # ===========================================================================================
  describe "T-C11 :unexpected_filter_route, both directions" do
    defp filter_row(line) do
      [method, path, key] = String.split(line, " ")

      declared_row(:filter, %{
        router: Letflow.Routers.Entities,
        method: method,
        path: path,
        key: String.to_atom(key)
      })
    end

    test "the three committed routes mounted as :filter are accepted" do
      for l <- @filter_lines do
        refute Enum.any?(
                 RouteScope.audit_routes([filter_row(l)], [], []),
                 &match?({:unexpected_filter_route, _}, &1)
               ),
               l
      end
    end

    test "a :filter route that is not on the committed expectation fails: another path, another method, another key" do
      [first | _] = @filter_lines

      for fields <- [
            %{path: "/entities/other"},
            %{method: "GET"},
            %{key: :EntitiesAggregate}
          ] do
        route = first |> filter_row() |> Map.merge(fields)
        errors = RouteScope.audit_routes([route], [], [])

        assert {:unexpected_filter_route, route} in errors, inspect(fields)
      end
    end

    test "a listed route mounted with ANOTHER class fails (a regression to the default, an explicit :tenant_wide, :self_service, or admin plane)" do
      for l <- @filter_lines, class <- [:tenant_wide, :self_service, :admin_plane] do
        base = filter_row(l)
        route = %{base | declared: class, class: class}
        errors = RouteScope.audit_routes([route], [], [])

        assert {:unexpected_filter_route, route} in errors, "#{l} as #{class}"
      end

      # the default-sourced form (what a reclassification that forgets the `scope:` option gives)
      defaulted = %{
        filter_row(hd(@filter_lines))
        | declared: nil,
          class: :tenant_wide,
          source: :default
      }

      assert {:unexpected_filter_route, defaulted} in RouteScope.audit_routes(
               [defaulted],
               [line(defaulted)],
               []
             )
    end

    test "a listed route mounted as {:resolver, _} fails too" do
      base = filter_row(hd(@filter_lines))
      resolver = {:resolver, {RouteScope, :class_of}}
      route = %{base | declared: resolver, class: resolver}

      assert {:unexpected_filter_route, route} in RouteScope.audit_routes([route], [], [])
    end

    test "a same-path route with a DIFFERENT method or key and another class is not a listed route" do
      other =
        declared_row(:tenant_wide, %{
          router: Letflow.Routers.Entities,
          method: "GET",
          path: "/entities/query",
          key: :EntitiesQuery
        })

      refute Enum.any?(
               RouteScope.audit_routes([other], [line(other)], []),
               &match?({:unexpected_filter_route, _}, &1)
             )
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

    test "the self-service list is exactly M1, M2, access, H1 and the four definitions reads (REQ-545, REQ-546) and the REQ-551 labels read, each ruled (T-S8)" do
      assert Enum.sort_by(RouteScope.self_service_routes(), & &1.route) ==
               [
                 %{
                   route: "GET /currencies",
                   key: :MyAccessRead,
                   class: :self_service,
                   ruling: "SEC-824-currencies"
                 },
                 %{
                   route: "GET /definitions",
                   key: :DefinitionsRead,
                   class: :self_service,
                   ruling: "SEC-525-R01"
                 },
                 %{
                   route: "GET /definitions/:id",
                   key: :DefinitionsRead,
                   class: :self_service,
                   ruling: "SEC-525-R02"
                 },
                 %{
                   route: "GET /definitions/active/:name",
                   key: :DefinitionsRead,
                   class: :self_service,
                   ruling: "SEC-525-R03"
                 },
                 %{
                   route: "GET /definitions/search",
                   key: :DefinitionsRead,
                   class: :self_service,
                   ruling: "SEC-525-R04"
                 },
                 %{
                   route: "GET /help/resolved",
                   key: :HelpRead,
                   class: :self_service,
                   ruling: "SEC-518-R2-help"
                 },
                 %{
                   route: "GET /labels",
                   key: :MyAccessRead,
                   class: :self_service,
                   ruling: "SEC-551-labels"
                 },
                 %{
                   route: "GET /me/memberships",
                   key: :MembershipsRead,
                   class: :self_service,
                   ruling: "0051-A7"
                 },
                 %{
                   route: "GET /me/modules",
                   key: :MyModulesRead,
                   class: :self_service,
                   ruling: "SEC-518-R2-modules"
                 },
                 %{
                   route: "GET /me/access",
                   key: :MyAccessRead,
                   class: :self_service,
                   ruling: "SEC-REQ-449-access"
                 },
                 # T-1389: the first non-GET self_service entry (the caller's own preferences)
                 %{
                   route: "GET /me/preferences",
                   key: :MyAccessRead,
                   class: :self_service,
                   ruling: "SEC-T1389-prefs-get"
                 },
                 %{
                   route: "PUT /me/preferences",
                   key: :MyPreferencesSet,
                   class: :self_service,
                   ruling: "SEC-T1389-prefs-put"
                 },
                 # T-1561: the caller's own in-app notification list
                 %{
                   route: "GET /me/notifications",
                   key: :MyAccessRead,
                   class: :self_service,
                   ruling: "SEC-T1561-notif-get"
                 },
                 %{
                   route: "POST /me/notifications/read",
                   key: :MyPreferencesSet,
                   class: :self_service,
                   ruling: "SEC-T1561-notif-read"
                 }
               ]
               |> Enum.sort_by(& &1.route)

      refute Enum.any?(RouteScope.self_service_routes(), &(&1.ruling == :pending_sec_ruling))
    end

    test "every list entry names a mounted route of the entry's class with the entry's key", %{
      routes: routes
    } do
      for entry <- RouteScope.self_service_routes() do
        mounted = Enum.filter(routes, &("#{&1.method} #{&1.path}" == entry.route))
        assert [route] = mounted, entry.route
        assert route.class == entry.class, entry.route
        assert route.key == entry.key, entry.route
        assert route.source == :declared, entry.route
      end
    end

    test "every committed :filter line is mounted, as :filter, declared", %{routes: routes} do
      for l <- @filter_lines do
        assert [route] = Enum.filter(routes, &(RouteScope.snapshot_line(&1) == l)), l
        assert route.class == :filter, l
        assert route.source == :declared, l
      end

      assert routes
             |> RouteScope.filter_routes()
             |> Enum.map(&RouteScope.snapshot_line/1)
             |> Enum.sort() ==
               Enum.sort(@filter_lines)
    end

    test "the walk FAILS on the real table if any one of the three filter routes is reverted to the default class",
         %{routes: routes, snapshot: snapshot} do
      for l <- @filter_lines do
        reverted =
          Enum.map(routes, fn r ->
            if RouteScope.snapshot_line(r) == l,
              do: %{r | declared: nil, class: :tenant_wide, source: :default},
              else: r
          end)

        errors = RouteScope.audit_routes(reverted, snapshot)

        assert Enum.any?(errors, &match?({:unexpected_filter_route, %{class: :tenant_wide}}, &1)),
               l

        assert Enum.any?(errors, &match?({:unclassified, _}, &1)), l
      end
    end

    test "the walk FAILS on the real table if a self-service route loses its declaration, or leaves the list",
         %{routes: routes, snapshot: snapshot} do
      reverted =
        Enum.map(routes, fn r ->
          if "#{r.method} #{r.path}" == @memberships,
            do: %{r | declared: nil, class: :tenant_wide, source: :default},
            else: r
        end)

      assert Enum.any?(
               RouteScope.audit_routes(reverted, snapshot),
               &match?({:self_service_list_mismatch, _}, &1)
             )

      without = Enum.reject(RouteScope.self_service_routes(), &(&1.route == @memberships))
      errors = RouteScope.audit_routes(routes, snapshot, without)

      assert Enum.any?(
               errors,
               &match?({:self_service_not_listed, %{path: "/me/memberships"}}, &1)
             )

      assert Enum.any?(
               errors,
               &match?({:self_service_list_mismatch, %{path: "/me/memberships"}}, &1)
             )
    end

    test "MU31: a snapshot that kept one of the six reclassified lines is :stale_snapshot (the committed file must lose them)",
         %{routes: routes, snapshot: snapshot} do
      for l <- @removed_lines do
        assert {:stale_snapshot, l} in RouteScope.audit_routes(routes, Enum.sort([l | snapshot])),
               l
      end
    end

    test "the snapshot lost exactly the six 2c-i-b lines and the fifteen 2c-ii lines: 122 remain, none of the six is present",
         %{snapshot: snapshot} do
      # 122 after 2c-ii; PR 2d removed the seven task lines (the two list lines are in @filter_lines); GH #2548 added one line (116); REQ-510 slice 1 added three exam authoring lines (119), REQ-515 added the reactivate line (120); REQ-545 removed GET /definitions and GET /definitions/search (118), REQ-546 removed GET /definitions/:id and GET /definitions/active/:name (116), REQ-552 added GET /tenant/config-bundle and POST /tenant/config-bundle/import (118)
      # REQ-565 (GH #3201) added the five integration-mappings lines (123).
      # REQ-633 (GH #3530) added the entity-type-hooks dry-run line (160).
      # GH #3610 (REQ-668) added the three catalog_items lot lines and GH #3611 (REQ-667) the five codes write lines (183 -> 191).
      # REQ-712 (GH #3749) added the six stock document lines (194 -> 200).
      # REQ-700 (GH #3737) added the seven stock count lines (200 -> 207).
      # REQ-713 added the three stock post/reverse/cancel lines (208 -> 211); REQ-701 the seven count sheet lines (211 -> 218).
      # REQ-626 (GH #3503) part A added four attachment lines (218 -> 222).
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
      # REQ-765 (GH #3906) added the frozen-locations route line (258 -> 259).
      # The module rollback route (GH T-1549, decision 0055 D9) added one more (259 -> 260).
      # REQ-816 (GH #4375) added the six assets count lines (267 -> 273).
      # REQ-817 (GH #4374) added the eight assets count sheet lines (273 -> 281).
      # T-1924 added the asset card print route line (281 -> 282).
      assert length(snapshot) == 282
      # REQ-751 / REQ-752 (GH #3891, #3890) added the seven assets document lines (248 -> 255).
      # REQ-779 (GH #4017) added the codes label route line (255 -> 256).

      for l <- @removed_lines, do: refute(l in snapshot, l)
    end
  end
end
