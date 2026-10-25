defmodule Letflow.Api.RouteScopeWalkTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 17 and AC 21 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` sections 4.1 and 4.6; spec
  `test/specs/REQ-517-2b.md`, T-C1..T-C5, T-C7, T-C8, T-K2 and SEC follow-ups F-1, F-2, F-3):
  the route walk over EVERY route of EVERY mounted core and module router.

    * the real route table audits to `[]` against the committed snapshot
      `test/fixtures/route_scope/tenant_wide_default_routes.txt`, and the snapshot is exactly the
      set of default-sourced routes (the committed snapshot is the "listed in the PR body"
      artefact of the design);
    * each rule is proven live on the REAL table by seeding one violation (an unlisted route, a
      stale line, a reclassified link route, a `:filter` route), so a walk that silently stopped
      seeing routes would be noticed;
    * every admin-plane key is mounted and classified `:admin_plane` from the key table;
    * the macro: `__authz_routes__/0` keeps its 3-tuple shape, `__authz_route_scopes__/0` lists
      DECLARED routes only (the two attachment-link routes), and a non-literal or unknown class is
      a `CompileError` for every verb macro.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  @issue_path "/instances/:id/attachments/:attachment_id/link"
  @content_path "/instances/:id/attachments/:attachment_id/link-content"
  @verbs ~w(authz_get authz_post authz_put authz_patch authz_delete)

  setup_all do
    routes = RouteInventory.routes()
    {:ok, routes: routes, snapshot: RouteInventory.read_snapshot()}
  end

  defp link_rows(routes), do: Enum.filter(routes, &(&1.path in [@issue_path, @content_path]))

  # --- T-C1: the real walk ---------------------------------------------------------------------

  describe "T-C1 the real route table" do
    test "audits to [] against the committed snapshot", %{routes: routes, snapshot: snapshot} do
      assert RouteScope.audit_routes(routes, snapshot) == []
    end

    test "the inventory really sees the mounted routers (a walk over nothing would pass)", %{
      routes: routes
    } do
      routers = routes |> Enum.map(& &1.router) |> Enum.uniq()

      assert length(routes) > 150
      assert length(routers) >= 20
      assert Letflow.Routers.Instances in routers
      assert Letflow.Routers.Tasks in routers
      assert Letflow.Routers.Identity in routers
      assert Letflow.Routers.TenantRoleScopeGrants in routers

      for r <- routes do
        assert String.starts_with?(r.path, "/"), inspect(r)
        assert r.method in ~w(GET POST PUT PATCH DELETE), inspect(r)
        assert is_atom(r.key)
      end
    end

    test "the snapshot is exactly the default-sourced routes, sorted and without duplicates (T-C8)",
         %{routes: routes, snapshot: snapshot} do
      assert snapshot == RouteInventory.default_snapshot_lines(routes)
      assert snapshot == Enum.sort(snapshot)
      assert snapshot == Enum.uniq(snapshot)

      for line <- snapshot do
        assert [method, "/" <> _path, key] = String.split(line, " "), line
        assert method in ~w(GET POST PUT PATCH DELETE), line
        assert key =~ ~r/\A[A-Z][A-Za-z0-9]*\z/, line
      end
    end

    test "every route is exactly one class; :filter and :self_service are exactly the committed REQ-518 2c-i-b routes",
         %{routes: routes} do
      for r <- routes do
        assert r.class in [:admin_plane, :tenant_wide, :filter, :self_service] or
                 match?({:resolver, _}, r.class),
               inspect(r)
      end

      assert routes
             |> RouteScope.filter_routes()
             |> Enum.map(&RouteScope.snapshot_line/1)
             |> Enum.sort() ==
               Enum.sort([
                 "POST /entities/query EntitiesQuery",
                 "POST /entities/query/aggregate EntitiesAggregate",
                 "POST /entities/records/:entity_type/export EntitiesRecordsExport",
                 # REQ-518 PR 2d (AC 20): the two task list routes
                 "GET /tasks TasksList",
                 "GET /tasks/inbox TasksList"
               ])

      assert routes
             |> Enum.filter(&(&1.class == :self_service))
             |> Enum.map(&"#{&1.method} #{&1.path}")
             |> Enum.sort() ==
               [
                 "GET /definitions",
                 "GET /definitions/:id",
                 "GET /definitions/active/:name",
                 "GET /definitions/search",
                 "GET /help/resolved",
                 "GET /labels",
                 "GET /me/access",
                 "GET /me/memberships",
                 "GET /me/modules"
               ]
    end
  end

  # --- the walk can fail on the real table (seeded violations) ---------------------------------

  describe "each rule fires on the real table when one violation is seeded" do
    test "an unlisted default route is :unclassified (T-C1 seeded fixture route)", %{
      routes: routes,
      snapshot: snapshot
    } do
      seeded = %{
        router: Letflow.Routers.Instances,
        method: "POST",
        path: "/instances/seeded-unlisted-route",
        key: :InstancesStart,
        declared: nil,
        class: :tenant_wide,
        source: :default
      }

      assert RouteScope.audit_routes(routes ++ [seeded], snapshot) == [{:unclassified, seeded}]
    end

    test "a snapshot line for a vanished route is :stale_snapshot (T-C7)", %{
      routes: routes,
      snapshot: snapshot
    } do
      stale = "GET /instances/vanished-route InstancesRead"

      assert RouteScope.audit_routes(routes, [stale | snapshot]) == [{:stale_snapshot, stale}]
    end

    test "a default route turned :filter makes its snapshot line stale and the filter unexpected",
         %{routes: routes, snapshot: snapshot} do
      target = Enum.find(routes, &(&1.source == :default and &1.path == "/instances"))
      refute is_nil(target)

      reclassified = %{target | declared: :filter, class: :filter, source: :declared}
      swapped = Enum.map(routes, &if(&1 == target, do: reclassified, else: &1))

      errors = RouteScope.audit_routes(swapped, snapshot)
      assert {:stale_snapshot, RouteScope.snapshot_line(target)} in errors
      assert {:unexpected_filter_route, reclassified} in errors
    end

    test "reclassifying either attachment-link route is :link_route_reclassified (AC 21)", %{
      routes: routes,
      snapshot: snapshot
    } do
      for target <- link_rows(routes), class <- [:filter, {:resolver, {RouteScope, :class_of}}] do
        reclassified = %{target | declared: class, class: class, source: :declared}
        swapped = Enum.map(routes, &if(&1 == target, do: reclassified, else: &1))

        errors = RouteScope.audit_routes(swapped, snapshot)
        message = "#{target.method} #{target.path} as #{inspect(class)}"
        assert {:link_route_reclassified, reclassified} in errors, message
      end
    end

    test "an admin-plane key declared as another class is :declared_conflicts_with_key_table", %{
      routes: routes,
      snapshot: snapshot
    } do
      target = Enum.find(routes, &(&1.key == :RoleScopeGrantsManage))
      refute is_nil(target)

      conflicting = %{target | declared: :tenant_wide}
      swapped = Enum.map(routes, &if(&1 == target, do: conflicting, else: &1))

      assert RouteScope.audit_routes(swapped, snapshot) ==
               [{:declared_conflicts_with_key_table, conflicting}]
    end
  end

  # --- AC 17: key table ------------------------------------------------------------------------

  describe "T-C3 the admin-plane key table against the real routes" do
    test "every route with an admin-plane key is :admin_plane from the key table", %{
      routes: routes
    } do
      admin_rows = Enum.filter(routes, &(&1.key in RouteScope.admin_plane_keys()))
      assert admin_rows != []

      for r <- admin_rows do
        assert {r.class, r.source} == {:admin_plane, :key_table}, inspect(r)
      end

      # and nothing else is admin-plane
      other = Enum.reject(routes, &(&1.key in RouteScope.admin_plane_keys()))
      assert Enum.all?(other, &(&1.class != :admin_plane))
    end

    test "every key of the table is mounted (no dead entry), the three 2a keys included", %{
      routes: routes
    } do
      mounted = routes |> Enum.map(& &1.key) |> MapSet.new()

      for key <- RouteScope.admin_plane_keys() do
        assert MapSet.member?(mounted, key), "admin-plane key #{key} has no mounted route"
      end

      for key <- [:RoleScopeGrantsRead, :RoleScopeGrantsManage, :ServicePrincipalManage] do
        assert MapSet.member?(mounted, key), "2a key #{key} is not mounted"
      end
    end

    test "completeness is DERIVED: every mounted key with permission :UsersGroupsRolesManage, :TokensManage or :RolesManage is in the table",
         %{routes: routes} do
      derived =
        routes
        |> Enum.map(& &1.key)
        |> Enum.uniq()
        |> Enum.filter(&(&1 in [:TokensManage, :RolesManage]))
        |> Kernel.++(
          for key <- Enum.uniq(Enum.map(routes, & &1.key)),
              Authorization.required_permission(key) == :UsersGroupsRolesManage,
              do: key
        )

      assert derived != []

      for key <- derived do
        assert key in RouteScope.admin_plane_keys(), "#{key} is admin-plane by permission only"
      end
    end
  end

  describe "SEC F-3 every mounted policy key resolves to a real permission" do
    test "required_permission/1 of each key is a member of Authorization.permissions/0", %{
      routes: routes
    } do
      permissions = Authorization.permissions()

      offenders =
        routes
        |> Enum.map(& &1.key)
        |> Enum.uniq()
        |> Enum.reject(&(Authorization.required_permission(&1) in permissions))

      assert offenders == [],
             "these keys map to no permission and would 403 everyone under `on`: " <>
               inspect(offenders)
    end
  end

  # --- AC 21 / T-K2 ----------------------------------------------------------------------------

  describe "T-K2 the two attachment-link routes" do
    test "are exactly two rows, declared :tenant_wide explicitly (never default-sourced)", %{
      routes: routes,
      snapshot: snapshot
    } do
      rows = link_rows(routes)

      assert Enum.sort(Enum.map(rows, &{&1.method, &1.path, &1.key})) == [
               {"GET", @content_path, :AttachmentsRead},
               {"POST", @issue_path, :AttachmentLinksIssue}
             ]

      for r <- rows do
        assert {r.declared, r.class, r.source} == {:tenant_wide, :tenant_wide, :declared},
               inspect(r)

        refute RouteScope.snapshot_line(r) in snapshot
      end
    end
  end

  # --- T-C4: the macro's two accumulators ------------------------------------------------------

  describe "T-C4 __authz_routes__/0 and __authz_route_scopes__/0" do
    test "__authz_routes__/0 of every router keeps its 3-tuple shape", %{routes: routes} do
      for router <- routes |> Enum.map(& &1.router) |> Enum.uniq() do
        entries = router.__authz_routes__()
        assert entries != [], inspect(router)

        for entry <- entries do
          assert {method, path, key} = entry
          assert is_binary(method) and is_binary(path) and is_atom(key), inspect(entry)
        end
      end
    end

    test "__authz_route_scopes__/0 lists DECLARED routes only: the two link routes and the REQ-518 2c-i-b and 2c-ii routes, nothing else",
         %{routes: routes} do
      scopes =
        for router <- routes |> Enum.map(& &1.router) |> Enum.uniq(),
            entry <- router.__authz_route_scopes__(),
            do: {router, entry}

      resolver = {:resolver, {Letflow.Entities.ScopeResolver, :record_scope}}
      task_resolver = {:resolver, {Letflow.Tasks.ScopeResolver, :task_scope}}
      document_resolver = {:resolver, {Letflow.Documents.ScopeResolver, :document_scope}}

      assert Enum.sort(Enum.map(scopes, fn {_router, entry} -> entry end)) ==
               Enum.sort([
                 {"GET", "/:id/attachments/:attachment_id/link-content", :tenant_wide},
                 {"GET", "/memberships", :self_service},
                 {"GET", "/modules", :self_service},
                 {"GET", "/access", :self_service},
                 {"GET", "/resolved", :self_service},
                 # REQ-545: the definitions collection reads (router-local paths "/" and "/search")
                 {"GET", "/", :self_service},
                 {"GET", "/search", :self_service},
                 # REQ-551: the Labels router (router-local paths): the catalog read and the two override writes
                 {"GET", "/", :self_service},
                 {"PUT", "/:message_id", :tenant_wide},
                 {"DELETE", "/:message_id", :tenant_wide},
                 # REQ-546: the two single-object definition reads
                 {"GET", "/active/:name", :self_service},
                 {"GET", "/:id", :self_service},
                 {"POST", "/:id/attachments/:attachment_id/link", :tenant_wide},
                 {"POST", "/query", :filter},
                 {"POST", "/query/aggregate", :filter},
                 {"POST", "/records/:entity_type/export", :filter},
                 # REQ-518 PR 2c-ii: seven explicit :tenant_wide declarations ...
                 {"POST", "/definitions/:name/activate", :tenant_wide},
                 {"POST", "/definitions", :tenant_wide},
                 {"GET", "/definitions/active/:name", :tenant_wide},
                 {"GET", "/definitions/by-name/:name", :tenant_wide},
                 {"GET", "/definitions/:id", :tenant_wide},
                 {"GET", "/definitions", :tenant_wide},
                 {"POST", "/restrictions/import", :tenant_wide},
                 # ... and the nine resolver routes (REQ-516 S2 adds the history read)
                 {"GET", "/records/:entity_type/:record_id/history", resolver},
                 {"POST", "/records/:entity_type", resolver},
                 {"PUT", "/records/:entity_type/:record_id", resolver},
                 {"DELETE", "/records/:entity_type/:record_id", resolver},
                 {"POST", "/records/:entity_type/import", resolver},
                 {"POST", "/records/:entity_type/:record_id/attachments", resolver},
                 {"GET", "/records/:entity_type/:record_id/attachments", resolver},
                 {"GET", "/records/:entity_type/:record_id/attachments/:attachment_id", resolver},
                 {"DELETE", "/records/:entity_type/:record_id/attachments/:attachment_id",
                  resolver},
                 # REQ-518 PR 2d: the two task list routes and the five single-task routes
                 {"GET", "/inbox", :filter},
                 {"GET", "/", :filter},
                 {"GET", "/:id", task_resolver},
                 {"POST", "/:id/complete", task_resolver},
                 {"POST", "/:id/claim", task_resolver},
                 {"POST", "/:id/assign", task_resolver},
                 {"POST", "/:id/reassign", task_resolver},
                 # REQ-536: the policy route is tenant-wide, the two hold routes are resolvers
                 {"PUT", "/types/:key/retention", :tenant_wide},
                 {"POST", "/:document_id/hold", document_resolver},
                 {"POST", "/:document_id/hold/release", document_resolver},
                 # REQ-555: the five saved-view routes are all tenant-wide
                 {"GET", "/", :tenant_wide},
                 {"GET", "/:id", :tenant_wide},
                 {"POST", "/", :tenant_wide},
                 {"PUT", "/:id", :tenant_wide},
                 {"DELETE", "/:id", :tenant_wide}
               ])

      assert scopes |> Enum.map(fn {router, _entry} -> router end) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort([
                 Letflow.Routers.Definitions,
                 Letflow.Routers.Documents,
                 Letflow.Routers.Entities,
                 Letflow.Routers.EntityViews,
                 Letflow.Routers.Help,
                 Letflow.Routers.Instances,
                 Letflow.Routers.Labels,
                 Letflow.Routers.Me,
                 Letflow.Routers.Tasks
               ])
    end
  end

  # --- T-C5: macro validation (CompileError) ---------------------------------------------------

  defp fixture_module do
    Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")
  end

  defp compile_router!(route_lines) do
    mod = fixture_module()

    source = """
    defmodule #{inspect(mod)} do
      use Letflow.Api.AuthorizedRouter

    #{route_lines}
    end
    """

    Code.compile_string(source)
    mod
  end

  defp route_source(verb, path, option) do
    "  #{verb} \"#{path}\", :InstancesRead, #{option} do
" <>
      "    send_resp(conn, 200, \"ok\")
  end"
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :ok
  end

  describe "T-C5 the scope: option is validated at compile time" do
    test "a literal class compiles for every verb and every class, and is accumulated" do
      declared = [
        {"authz_get", "/a", ":admin_plane"},
        {"authz_post", "/b", ":tenant_wide"},
        {"authz_put", "/c", ":filter"},
        {"authz_patch", "/d", ":self_service"},
        {"authz_delete", "/e", "{:resolver, {Letflow.Api.RouteScope, :class_of}}"}
      ]

      declared_lines =
        Enum.map_join(declared, "
", fn {verb, path, class} ->
          route_source(verb, path, "scope: " <> class)
        end)

      plain = "  authz_get \"/plain\", :InstancesRead do
    send_resp(conn, 200, \"ok\")
  end"
      mod = compile_router!(declared_lines <> "
" <> plain)

      try do
        assert Enum.sort(mod.__authz_route_scopes__()) ==
                 Enum.sort([
                   {"GET", "/a", :admin_plane},
                   {"POST", "/b", :tenant_wide},
                   {"PUT", "/c", :filter},
                   {"PATCH", "/d", :self_service},
                   {"DELETE", "/e", {:resolver, {Letflow.Api.RouteScope, :class_of}}}
                 ])

        # the undeclared route is still a 3-tuple route and is NOT in the scope list
        assert {"GET", "/plain", :InstancesRead} in mod.__authz_routes__()
        assert length(mod.__authz_routes__()) == 6
        refute Enum.any?(mod.__authz_route_scopes__(), &(elem(&1, 1) == "/plain"))
      after
        purge(mod)
      end
    end

    test "an unknown atom, a variable, a string, a malformed resolver or a wrong option shape is a CompileError for every verb" do
      bad_options = [
        "scope: :bogus",
        "scope: some_variable",
        ~s|scope: "filter"|,
        "scope: nil",
        "scope: {:resolver, {Letflow.Api.RouteScope, some_fun}}",
        "scope: {:resolver, {1, :class_of}}",
        "scope: {:resolver, :class_of}",
        "scope: [:filter]",
        "other: :filter",
        "scope: :filter, extra: 1"
      ]

      for verb <- @verbs, option <- bad_options do
        source = route_source(verb, "/bad", option)

        compiled? =
          try do
            mod = compile_router!(source)
            purge(mod)
            true
          rescue
            CompileError -> false
          end

        refute compiled?, "#{verb} with #{option} must not compile"
      end
    end
  end

  describe "REQ-546 the walk fails when one edit of a self-service route is missing" do
    for route <- ["GET /definitions/:id", "GET /definitions/active/:name"] do
      test "#{route}: declared :self_service but not on the list", %{
        routes: routes,
        snapshot: snapshot
      } do
        route = unquote(route)
        list = Enum.reject(RouteScope.self_service_routes(), &(&1.route == route))

        errors = RouteScope.audit_routes(routes, snapshot, list)

        assert Enum.any?(errors, fn
                 {:self_service_list_mismatch, r} -> "#{r.method} #{r.path}" == route
                 _ -> false
               end)
      end

      test "#{route}: on the list but declared :tenant_wide", %{
        routes: routes,
        snapshot: snapshot
      } do
        route = unquote(route)

        swapped =
          Enum.map(routes, fn r ->
            if "#{r.method} #{r.path}" == route,
              do: %{r | declared: :tenant_wide, class: :tenant_wide, source: :declared},
              else: r
          end)

        errors = RouteScope.audit_routes(swapped, snapshot)

        assert Enum.any?(errors, fn
                 {:self_service_list_mismatch, r} -> "#{r.method} #{r.path}" == route
                 _ -> false
               end)
      end
    end
  end
end
