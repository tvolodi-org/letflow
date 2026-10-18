defmodule Letflow.Api.RouteScopeTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 17 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.1; spec
  `test/specs/REQ-517-2b.md`, T-C1, T-C2, T-C3, T-C6, T-C7 and the SEC code-gate follow-ups
  F-1 and F-3): the PURE logic of `Letflow.Api.RouteScope` -- `class_of/1` and every error of
  `audit_routes/2` -- driven with seeded route rows, so each rule is proven to fire (the real
  route table is walked in `route_scope_walk_test.exs`).

  No database, no routers: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.RouteScope

  @admin_keys ~w(GroupsManage UsersManage TokensManage RolesManage RolesRebind
                 ScopeNodePathsConsistencyRead ScopeEnforcementRead ScopeEnforcementManage
                 ScopeGrantsIntegrityRead ScopeEnforcementTokensRead RoleScopeGrantsRead
                 RoleScopeGrantsManage ServicePrincipalManage)a

  # A default-sourced `:tenant_wide` row; `fields` override.
  defp row(fields) do
    Map.merge(
      %{
        router: Letflow.Routers.Instances,
        method: "GET",
        path: "/instances",
        key: :InstancesRead,
        declared: nil,
        class: :tenant_wide,
        source: :default
      },
      Map.new(fields)
    )
  end

  defp declared_row(class, fields) do
    row(Map.merge(%{declared: class, class: class, source: :declared}, Map.new(fields)))
  end

  defp line(row), do: RouteScope.snapshot_line(row)

  # --- class_of/1 ------------------------------------------------------------------------------

  describe "class_of/1" do
    test "a route with no declared class is the fail-closed :tenant_wide default" do
      assert RouteScope.class_of(%{policy_key: :InstancesRead}) == {:tenant_wide, :default}
      assert RouteScope.class_of(%{}) == {:tenant_wide, :default}
    end

    test "a declared class is returned with the source :declared" do
      assert RouteScope.class_of(%{policy_key: :InstancesRead, scope_class: :tenant_wide}) ==
               {:tenant_wide, :declared}

      assert RouteScope.class_of(%{policy_key: :InstancesRead, scope_class: :filter}) ==
               {:filter, :declared}

      assert RouteScope.class_of(%{policy_key: :InstancesRead, scope_class: :self_service}) ==
               {:self_service, :declared}

      resolver = {:resolver, {Letflow.Api.RouteScope, :class_of}}

      assert RouteScope.class_of(%{policy_key: :InstancesRead, scope_class: resolver}) ==
               {resolver, :declared}
    end

    test "every admin-plane key is :admin_plane from the key table, whatever the route declares (N12)" do
      for key <- @admin_keys,
          private <- [
            %{policy_key: key},
            %{policy_key: key, scope_class: :filter},
            %{policy_key: key, scope_class: :tenant_wide},
            %{policy_key: key, scope_class: :self_service},
            %{policy_key: key, scope_class: {:resolver, {RouteScope, :class_of}}}
          ] do
        assert RouteScope.class_of(private) == {:admin_plane, :key_table}, inspect(private)
      end
    end

    test "the key table is exactly the D11 set (13 keys), including the three 2a keys" do
      assert Enum.sort(RouteScope.admin_plane_keys()) == Enum.sort(@admin_keys)
      assert length(RouteScope.admin_plane_keys()) == 13
      assert length(Enum.uniq(RouteScope.admin_plane_keys())) == 13

      for key <- [:RoleScopeGrantsRead, :RoleScopeGrantsManage, :ServicePrincipalManage] do
        assert key in RouteScope.admin_plane_keys()
      end
    end
  end

  # --- audit_routes/2: the clean case ----------------------------------------------------------

  describe "audit_routes/2 passes a consistent table" do
    test "default rows listed in the snapshot, a declared route and an admin row give []" do
      routes = [
        row(%{}),
        row(%{method: "POST", path: "/instances", key: :InstancesStart}),
        declared_row(:tenant_wide, %{
          method: "POST",
          path: "/instances/:id/attachments/:attachment_id/link",
          key: :AttachmentLinksIssue
        }),
        row(%{
          method: "GET",
          path: "/identity/groups",
          key: :GroupsManage,
          class: :admin_plane,
          source: :key_table
        })
      ]

      snapshot = [line(Enum.at(routes, 0)), line(Enum.at(routes, 1))]
      assert RouteScope.audit_routes(routes, snapshot) == []
    end
  end

  # --- T-C1 :unclassified / T-C7 :stale_snapshot -----------------------------------------------

  describe ":unclassified and :stale_snapshot" do
    test "a default-sourced route that is not in the snapshot fails with :unclassified (T-C1)" do
      listed = row(%{})
      unlisted = row(%{method: "DELETE", path: "/instances/:id", key: :InstancesCancel})

      assert RouteScope.audit_routes([listed, unlisted], [line(listed)]) ==
               [{:unclassified, unlisted}]
    end

    test "an empty snapshot leaves every default row :unclassified (N2)" do
      routes = [row(%{}), row(%{path: "/definitions", key: :DefinitionsRead})]

      assert Enum.sort(RouteScope.audit_routes(routes, [])) ==
               Enum.sort(Enum.map(routes, &{:unclassified, &1}))
    end

    test "a snapshot line whose route is gone fails with :stale_snapshot (T-C7, N14)" do
      listed = row(%{})
      stale = "GET /gone/route InstancesRead"

      assert RouteScope.audit_routes([listed], [line(listed), stale]) ==
               [{:stale_snapshot, stale}]
    end

    test "a snapshot line whose route is no longer default-sourced is stale (REQ-518 must shrink it)" do
      now_declared = declared_row(:filter, %{path: "/entities/query", key: :EntitiesQuery})

      errors = RouteScope.audit_routes([now_declared], [line(now_declared)])
      assert {:stale_snapshot, line(now_declared)} in errors
    end

    test "a declared route is never :unclassified even when it is not in the snapshot" do
      declared = declared_row(:tenant_wide, %{path: "/x", key: :InstancesRead})
      assert RouteScope.audit_routes([declared], []) == []
    end
  end

  # --- T-C6 :declared_conflicts_with_key_table -------------------------------------------------

  describe ":declared_conflicts_with_key_table" do
    test "an admin key with a declared class other than :admin_plane fails (T-C6)" do
      conflicting =
        row(%{
          method: "GET",
          path: "/identity/groups",
          key: :GroupsManage,
          declared: :filter,
          class: :admin_plane,
          source: :key_table
        })

      assert RouteScope.audit_routes([conflicting], []) ==
               [{:declared_conflicts_with_key_table, conflicting}]
    end

    test "an admin key that declares :admin_plane itself is consistent" do
      consistent =
        row(%{
          key: :GroupsManage,
          path: "/identity/groups",
          declared: :admin_plane,
          class: :admin_plane,
          source: :key_table
        })

      assert RouteScope.audit_routes([consistent], []) == []
    end

    test "a non-admin key may declare any class without a conflict" do
      declared = declared_row(:tenant_wide, %{})
      assert RouteScope.audit_routes([declared], []) == []
    end
  end

  # --- T-C2 :resolver_not_exported -------------------------------------------------------------

  describe ":resolver_not_exported" do
    test "a resolver whose function/1 exists passes" do
      exported = declared_row({:resolver, {RouteScope, :class_of}}, %{})
      assert RouteScope.audit_routes([exported], []) == []
    end

    test "a missing function, a wrong arity and a missing module each fail" do
      missing_fun = declared_row({:resolver, {RouteScope, :no_such_resolver}}, %{path: "/a"})
      # snapshot_line/1 has arity 1 too; admin_plane_keys/0 is arity 0, so it is NOT a /1 resolver
      wrong_arity = declared_row({:resolver, {RouteScope, :admin_plane_keys}}, %{path: "/b"})

      missing_mod =
        declared_row({:resolver, {Letflow.Api.NoSuchResolverModule, :resolve}}, %{path: "/c"})

      errors = RouteScope.audit_routes([missing_fun, wrong_arity, missing_mod], [])

      for r <- [missing_fun, wrong_arity, missing_mod] do
        assert {:resolver_not_exported, r} in errors
      end

      assert length(errors) == 3
    end
  end

  # --- :admin_key_not_in_table (completeness) --------------------------------------------------

  describe ":admin_key_not_in_table" do
    test "a key whose permission is :UsersGroupsRolesManage but is not in the table fails (T-C3)" do
      # The identity fallback of required_permission/1 returns the key itself, so this key
      # derives :UsersGroupsRolesManage without being in the table.
      stray = declared_row(:tenant_wide, %{key: :UsersGroupsRolesManage, path: "/stray"})

      assert RouteScope.audit_routes([stray], []) ==
               [{:admin_key_not_in_table, :UsersGroupsRolesManage}]
    end

    test "every key in the table satisfies the completeness rule (no error for the 13 keys)" do
      routes =
        for {key, n} <- Enum.with_index(@admin_keys) do
          row(%{
            path: "/admin/#{n}",
            key: key,
            class: :admin_plane,
            source: :key_table
          })
        end

      assert RouteScope.audit_routes(routes, []) == []
    end

    test "the error is reported once per key, however many routes carry it" do
      one = declared_row(:tenant_wide, %{key: :UsersGroupsRolesManage, path: "/s1"})
      two = declared_row(:tenant_wide, %{key: :UsersGroupsRolesManage, path: "/s2"})

      assert RouteScope.audit_routes([one, two], []) ==
               [{:admin_key_not_in_table, :UsersGroupsRolesManage}]
    end
  end

  # --- AC 21 :link_route_reclassified ----------------------------------------------------------

  describe ":link_route_reclassified" do
    test "issue_time_parent_lookup?/0 is false in 2b (0051 M7)" do
      refute RouteScope.issue_time_parent_lookup?()
    end

    test "both link routes fail when reclassified to :filter or a resolver, a seeded reclassification" do
      issue_path = "/instances/:id/attachments/:attachment_id/link"
      content_path = "/instances/:id/attachments/:attachment_id/link-content"

      for {method, path, key} <- [
            {"POST", issue_path, :AttachmentLinksIssue},
            {"GET", content_path, :AttachmentsRead}
          ],
          class <- [:filter, {:resolver, {RouteScope, :class_of}}] do
        reclassified = declared_row(class, %{method: method, path: path, key: key})

        assert {:link_route_reclassified, reclassified} in RouteScope.audit_routes(
                 [reclassified],
                 []
               ),
               "#{method} #{path} as #{inspect(class)}"
      end
    end

    test "the link routes pass as :tenant_wide, declared or default" do
      issue =
        declared_row(:tenant_wide, %{
          method: "POST",
          path: "/instances/:id/attachments/:attachment_id/link",
          key: :AttachmentLinksIssue
        })

      content =
        row(%{
          method: "GET",
          path: "/instances/:id/attachments/:attachment_id/link-content",
          key: :AttachmentsRead
        })

      assert RouteScope.audit_routes([issue, content], [line(content)]) == []
    end

    test "an unrelated attachment route may be reclassified (only the two link routes are pinned)" do
      other =
        declared_row(:filter, %{
          method: "GET",
          path: "/instances/:id/attachments",
          key: :AttachmentsRead
        })

      errors = RouteScope.audit_routes([other], [])
      refute Enum.any?(errors, &match?({:link_route_reclassified, _}, &1))
    end
  end

  # --- SEC F-1: :self_service_not_allowed / :unexpected_filter_route ---------------------------

  describe "SEC F-1 restrictions on the pass-through classes" do
    test "a :self_service route that is not on the committed list fails (REQ-518 AC 21)" do
      route = declared_row(:self_service, %{path: "/me/unlisted", key: :MembershipsRead})

      assert RouteScope.audit_routes([route], []) == [
               {:self_service_not_listed, route},
               {:self_service_list_mismatch, route}
             ]
    end

    test "a :filter route that is not on the committed expectation fails with :unexpected_filter_route" do
      # the committed expectation holds the POST /entities/query line (REQ-518 2c-i-b); the same
      # path under GET is a DIFFERENT line, so it is not expected
      route = declared_row(:filter, %{path: "/entities/query", key: :EntitiesQuery})
      assert RouteScope.audit_routes([route], []) == [{:unexpected_filter_route, route}]

      unlisted_post =
        declared_row(:filter, %{method: "POST", path: "/entities/not-listed", key: :EntitiesQuery})

      assert RouteScope.audit_routes([unlisted_post], []) == [
               {:unexpected_filter_route, unlisted_post}
             ]
    end

    test "a LISTED :filter route mounted with another class fails with :unexpected_filter_route (REVIEWER step-13 F-2)" do
      listed = %{method: "POST", path: "/entities/query", key: :EntitiesQuery}

      # the listed route as :filter is clean ...
      assert RouteScope.audit_routes([declared_row(:filter, listed)], []) == []

      # ... and mounted as anything else it is reported with its own row
      for class <- [
            :tenant_wide,
            :self_service,
            :admin_plane,
            {:resolver, {RouteScope, :class_of}}
          ] do
        route = declared_row(class, listed)

        assert {:unexpected_filter_route, route} in RouteScope.audit_routes([route], []),
               inspect(class)
      end

      defaulted = row(listed)

      assert {:unexpected_filter_route, defaulted} in RouteScope.audit_routes([defaulted], [
               line(defaulted)
             ])
    end

    test "filter_routes/1 lists exactly the :filter rows" do
      filter = declared_row(:filter, %{path: "/entities/query", key: :EntitiesQuery})
      other = row(%{})
      resolver = declared_row({:resolver, {RouteScope, :class_of}}, %{path: "/r"})

      assert RouteScope.filter_routes([filter, other, resolver]) == [filter]
      assert RouteScope.filter_routes([other, resolver]) == []
    end

    test "a {:resolver, _} route is not restricted by these two rules" do
      resolver = declared_row({:resolver, {RouteScope, :class_of}}, %{path: "/r"})
      assert RouteScope.audit_routes([resolver], []) == []
    end
  end

  # --- SEC F-3: :unknown_permission ------------------------------------------------------------

  describe "SEC F-3 :unknown_permission" do
    test "a policy key that maps to no permission atom fails, once per key" do
      bogus_one = declared_row(:tenant_wide, %{key: :NoSuchPolicyKeyAtom, path: "/bogus/1"})
      bogus_two = declared_row(:tenant_wide, %{key: :NoSuchPolicyKeyAtom, path: "/bogus/2"})

      assert RouteScope.audit_routes([bogus_one, bogus_two], []) ==
               [{:unknown_permission, :NoSuchPolicyKeyAtom}]
    end

    test "a key with a real permission is not reported" do
      assert RouteScope.audit_routes([row(%{})], [line(row(%{}))]) == []
    end
  end

  # --- several errors at once ------------------------------------------------------------------

  test "audit_routes/2 returns every violation, not just the first" do
    unlisted = row(%{path: "/u", key: :InstancesRead})
    bogus = declared_row(:tenant_wide, %{key: :NoSuchPolicyKeyAtom, path: "/b"})
    filter = declared_row(:filter, %{path: "/f", key: :EntitiesQuery})

    errors = RouteScope.audit_routes([unlisted, bogus, filter], ["GET /old InstancesRead"])

    assert {:unclassified, unlisted} in errors
    assert {:stale_snapshot, "GET /old InstancesRead"} in errors
    assert {:unknown_permission, :NoSuchPolicyKeyAtom} in errors
    assert {:unexpected_filter_route, filter} in errors
    assert length(errors) == 4
  end

  test "snapshot_line/1 is METHOD FULL_PATH KEY" do
    assert RouteScope.snapshot_line(row(%{})) == "GET /instances InstancesRead"
  end
end
