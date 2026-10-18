defmodule Letflow.Api.ScopeForRoleTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2d, T-F16 and the unit half of AC 13 (approver rule F1; design
  `lib/letflow/design/req518-compiler-scope-filter.md` C.2, C.3, 10.3; spec
  `test/specs/REQ-518-2d.md`; SEC code-gate step-24 and REVIEWER step-25 notes):

    * `Letflow.Api.Scope.allowed_for_role?/3` and `allowed_set_for_role/2`: ONLY the effective
      scope of the ONE named role counts (never the union of the roles that allow some
      permission): the decision table, the contrast with `allowed?/3`'s union, and the T-F16
      agreement property over the fixture tree (a node is in the role's set iff the role's
      decision allows it; `:all` iff the role is allowed `:tenant_wide`);
    * `Letflow.Api.ScopeGate.scope_set_for_role/3` and `f1_principal/2`: not `on` -> `:all` /
      `:off` with ZERO statements; `on` -> the RA-13 exemption (exactly
      `Scope.allowed?(principal, permission, :tenant_wide)`, nothing role-name based), else the
      role's set; the memo is per permission AND role; `on` without a principal is `:none` for the
      set and a loud `ScopeSetError` for `f1_principal/2` (REVIEWER F-2, SEC F-2);
    * `Letflow.Tasks.f1_allowed?/3`: the rule of C.3 over a task row.

  `async: false`: a real tenant (the node tree is read from the database), VM-global log capture.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.Grants
  alias Letflow.Api.Scope.Principal
  alias Letflow.Api.Scope.ScopeSetError
  alias Letflow.Api.ScopeGate
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TaskScopeFixture, as: T
  alias Letflow.Tasks

  @tw "TASK_WORKER"
  @po "PROCESS_OPERATOR"

  setup do
    {:ok, fx: T.provision!("r518-2d-role")}
  end

  # ---- helpers -------------------------------------------------------------------------------

  defp ids(keys), do: keys |> Enum.map(&Map.fetch!(F.nodes(), &1)) |> Enum.sort()

  defp node_row(key),
    do: %{principal_type: :user, tenant_wide: false, scope_node_id: F.nodes()[key]}

  defp wide_row, do: %{principal_type: :user, tenant_wide: true, scope_node_id: nil}

  # A principal built in memory (no database for the grants): `roles` claimed, `rows` a map
  # role => [row].
  defp principal(fx, roles, rows) do
    user_id = Ecto.UUID.generate()

    %Principal{
      kind: :user,
      user_id: user_id,
      prefix: fx.schema_name,
      platform_tenant?: false,
      roles: Enum.map(roles, &String.to_atom/1),
      grants: %Grants{user_id: user_id, rows_by_role: rows}
    }
  end

  defp tw_at(fx, keys), do: principal(fx, [@tw], %{@tw => Enum.map(keys, &node_row/1)})

  defp conn_for(fx, caller, mode, credential \\ :oidc) do
    ctx =
      fx
      |> S.ctx(caller.id, caller.roles, credential)
      |> put_mode(mode)

    :get
    |> Fixture.router_conn("/", fx, caller.roles, nil)
    |> assign(:auth_context, ctx)
    |> assign(:scoped_opts, prefix: fx.schema_name)
  end

  defp put_mode(ctx, :absent), do: ctx
  defp put_mode(ctx, mode), do: Map.put(ctx, :scope_enforcement, mode)

  defp count(queries, table), do: Enum.count(queries, &(&1.query =~ table))

  # ===========================================================================================
  describe "allowed_for_role?/3 decision table" do
    test "a role the principal does not hold is {:deny, :role_not_held}, whatever the resource",
         %{
           fx: fx
         } do
      p = principal(fx, [@po], %{@po => [wide_row()]})

      for resource <- [{:node, F.nodes().a}, :tenant_wide] do
        assert Scope.allowed_for_role?(p, @tw, resource) == {:deny, :role_not_held}
      end
    end

    test "an unresolvable resource is denied first, even for a tenant-wide grant of the role", %{
      fx: fx
    } do
      p = principal(fx, [@tw], %{@tw => [wide_row()]})
      assert Scope.allowed_for_role?(p, @tw, :unresolvable) == {:deny, :unresolvable}
    end

    test "a tenant-wide row of the role allows every node, the tenant-wide resource, and a node that does not exist",
         %{fx: fx} do
      p = principal(fx, [@tw], %{@tw => [wide_row()]})

      for resource <- [
            {:node, F.nodes().a1},
            {:node, F.nodes().b},
            {:node, "sf-ghost"},
            :tenant_wide
          ] do
        assert Scope.allowed_for_role?(p, @tw, resource) == {:allow, :tenant_wide}
      end
    end

    test "a scoped row allows the node, its live descendants (also under a retired intermediate node) and nothing else",
         %{fx: fx} do
      p = tw_at(fx, [:a])
      n = F.nodes()

      for key <- [:a, :a1, :a2x] do
        assert Scope.allowed_for_role?(p, @tw, {:node, n[key]}) == {:allow, :subtree}, "#{key}"
      end

      # retired nodes are denied as unresolvable (a retired leaf and a retired intermediate)
      for key <- [:a2, :a3] do
        assert Scope.allowed_for_role?(p, @tw, {:node, n[key]}) == {:deny, :unresolvable},
               "#{key}"
      end

      # a sibling subtree, the shared root, an unknown node, the tenant-wide resource
      for key <- [:b, :b1, :root] do
        assert Scope.allowed_for_role?(p, @tw, {:node, n[key]}) == {:deny, :out_of_scope},
               "#{key}"
      end

      assert Scope.allowed_for_role?(p, @tw, {:node, "sf-ghost"}) == {:deny, :unresolvable}
      assert Scope.allowed_for_role?(p, @tw, :tenant_wide) == {:deny, :not_tenant_wide}
    end

    test "a role held with no applicable row is {:deny, :no_grant_rows}; grants not loaded is :grants_unavailable",
         %{fx: fx} do
      zero = principal(fx, [@tw], %{})
      assert Scope.allowed_for_role?(zero, @tw, {:node, F.nodes().a}) == {:deny, :no_grant_rows}

      unloaded = %{zero | grants: :not_loaded}

      assert Scope.allowed_for_role?(unloaded, @tw, {:node, F.nodes().a}) ==
               {:deny, :grants_unavailable}

      # a malformed resource for a scoped principal is unresolvable, never an allow
      scoped = tw_at(fx, [:a])
      assert Scope.allowed_for_role?(scoped, @tw, {:node, 5}) == {:deny, :unresolvable}
    end

    test "a TOKEN principal that holds the role is {:allow, :token}; one that does not is {:deny, :role_not_held}",
         %{fx: fx} do
      token = F.token_principal(fx)
      assert Scope.allowed_for_role?(token, @tw, {:node, F.nodes().b}) == {:allow, :token}
      assert Scope.allowed_for_role?(token, @po, {:node, F.nodes().b}) == {:deny, :role_not_held}
    end

    test "PLATFORM_ADMIN is not TASK_WORKER: the role function never auto-allows it (the exemption is the route permission's, not this function's)",
         %{fx: fx} do
      admin = F.platform_admin_principal(fx)
      assert Scope.allowed_for_role?(admin, @tw, {:node, F.nodes().a}) == {:deny, :role_not_held}
      assert Scope.allowed?(admin, :TasksRead, :tenant_wide) == {:allow, :platform}
    end

    test "ONLY the named role counts: allowed?/3 takes the UNION of the roles that allow the permission, allowed_for_role?/3 does not (MU36)",
         %{fx: fx} do
      n = F.nodes()
      # TASK_WORKER at b, PROCESS_OPERATOR at a. Both allow :TasksRead.
      p = principal(fx, [@tw, @po], %{@tw => [node_row(:b)], @po => [node_row(:a)]})

      assert {:allow, _} = Scope.allowed?(p, :TasksRead, {:node, n.a1})
      assert Scope.allowed_for_role?(p, @tw, {:node, n.a1}) == {:deny, :out_of_scope}
      assert Scope.allowed_for_role?(p, @po, {:node, n.a1}) == {:allow, :subtree}
      assert Scope.allowed_for_role?(p, @tw, {:node, n.b1}) == {:allow, :subtree}

      # a TENANT-WIDE grant of another role does not widen the named role either
      q = principal(fx, [@tw, @po], %{@tw => [node_row(:b)], @po => [wide_row()]})
      assert {:allow, _} = Scope.allowed?(q, :TasksRead, :tenant_wide)
      assert Scope.allowed_for_role?(q, @tw, {:node, n.a1}) == {:deny, :out_of_scope}
      assert Scope.allowed_for_role?(q, @tw, :tenant_wide) == {:deny, :not_tenant_wide}
    end
  end

  # ===========================================================================================
  describe "allowed_set_for_role/2 decision table" do
    test "role not held, grants unavailable, zero rows: :none", %{fx: fx} do
      assert Scope.allowed_set_for_role(principal(fx, [@po], %{@po => [wide_row()]}), @tw) ==
               {:ok, :none}

      unloaded = %{principal(fx, [@tw], %{}) | grants: :not_loaded}
      assert Scope.allowed_set_for_role(unloaded, @tw) == {:ok, :none}
      assert Scope.allowed_set_for_role(principal(fx, [@tw], %{}), @tw) == {:ok, :none}
    end

    test "token holding the role is :all, token not holding it is :none", %{fx: fx} do
      assert Scope.allowed_set_for_role(F.token_principal(fx), @tw) == {:ok, :all}
      assert Scope.allowed_set_for_role(F.token_principal(fx), @po) == {:ok, :none}
    end

    test "a tenant-wide row is :all; a scoped row is the root plus its LIVE descendants, sorted; overlapping roots have no duplicates",
         %{fx: fx} do
      assert Scope.allowed_set_for_role(principal(fx, [@tw], %{@tw => [wide_row()]}), @tw) ==
               {:ok, :all}

      assert Scope.allowed_set_for_role(tw_at(fx, [:a]), @tw) ==
               {:ok, {:nodes, ids([:a, :a1, :a2x])}}

      assert Scope.allowed_set_for_role(tw_at(fx, [:a, :a1]), @tw) ==
               {:ok, {:nodes, ids([:a, :a1, :a2x])}}

      assert Scope.allowed_set_for_role(tw_at(fx, [:a1, :b]), @tw) ==
               {:ok, {:nodes, ids([:a1, :b, :b1])}}
    end

    test "rows naming no live node (a retired leaf, an unknown node) are :none, never an error",
         %{fx: fx} do
      assert Scope.allowed_set_for_role(tw_at(fx, [:a3]), @tw) == {:ok, :none}

      ghost =
        principal(fx, [@tw], %{
          @tw => [%{principal_type: :user, tenant_wide: false, scope_node_id: "sf-ghost"}]
        })

      assert Scope.allowed_set_for_role(ghost, @tw) == {:ok, :none}
    end

    test "only the named role's rows count: another role's rows (scoped or tenant-wide) never change the set (MU36)",
         %{fx: fx} do
      p = principal(fx, [@tw, @po], %{@tw => [node_row(:b)], @po => [node_row(:a)]})
      assert Scope.allowed_set_for_role(p, @tw) == {:ok, {:nodes, ids([:b, :b1])}}
      assert Scope.allowed_set_for_role(p, @po) == {:ok, {:nodes, ids([:a, :a1, :a2x])}}

      q = principal(fx, [@tw, @po], %{@tw => [node_row(:b)], @po => [wide_row()]})
      assert Scope.allowed_set_for_role(q, @tw) == {:ok, {:nodes, ids([:b, :b1])}}
      assert Scope.allowed_set_for_role(q, @po) == {:ok, :all}

      only_po = principal(fx, [@po, @tw], %{@po => [wide_row()]})
      assert Scope.allowed_set_for_role(only_po, @tw) == {:ok, :none}
    end

    test "an expansion failure raises ScopeSetError (fail closed), never :all, a partial set or :none",
         %{fx: fx} do
      Application.put_env(:letflow, :scope_allowed_ids_cap, 2)
      on_exit(fn -> Application.delete_env(:letflow, :scope_allowed_ids_cap) end)

      log =
        capture_log([level: :error], fn ->
          assert_raise ScopeSetError, fn -> Scope.allowed_set_for_role(tw_at(fx, [:a]), @tw) end
        end)

      assert log =~ "scope_set_failed reason=too_many_ids"
    end
  end

  # ===========================================================================================
  describe "T-F16 agreement over the fixture tree" do
    test "for every grant selection, role and node: n in allowed_set_for_role iff allowed_for_role? allows the node; :all iff :tenant_wide is allowed",
         %{fx: fx} do
      nodes = Map.values(F.nodes()) ++ ["sf-ghost"]
      keys = Map.keys(F.nodes())

      # every single node, every pair of nodes, tenant-wide, nothing, and the mixed-role shapes
      selections =
        [[]] ++
          Enum.map(keys, &[&1]) ++
          for(a <- keys, b <- keys, a < b, do: [a, b])

      principals =
        for sel <- selections do
          {{@tw, sel}, tw_at(fx, sel)}
        end ++
          [
            {:tenant_wide, principal(fx, [@tw], %{@tw => [wide_row()]})},
            {:role_not_held, principal(fx, [@po], %{@po => [wide_row()]})},
            {:mixed, principal(fx, [@tw, @po], %{@tw => [node_row(:b)], @po => [node_row(:a)]})},
            {:token, F.token_principal(fx)}
          ]

      checked =
        for {label, p} <- principals, reduce: 0 do
          acc ->
            {:ok, set} = Scope.allowed_set_for_role(p, @tw)

            for n <- nodes do
              allowed? = match?({:allow, _}, Scope.allowed_for_role?(p, @tw, {:node, n}))

              member? =
                case set do
                  :all -> true
                  :none -> false
                  {:nodes, list} -> n in list
                end

              assert member? == allowed?,
                     "#{inspect(label)} node #{n}: in set=#{member?} allowed_for_role?=#{allowed?}"
            end

            wide? = match?({:allow, _}, Scope.allowed_for_role?(p, @tw, :tenant_wide))
            assert wide? == (set == :all), "#{inspect(label)}: :all iff :tenant_wide allowed"
            acc + length(nodes) + 1
        end

      # the loop is live: it compared a lot of decisions
      assert checked == length(principals) * (length(nodes) + 1)
      assert length(principals) == 41
    end
  end

  # ===========================================================================================
  describe "ScopeGate.scope_set_for_role/3 and f1_principal/2" do
    test "not on (off, shadow, key absent): :all / :off, ZERO statements, the marker is set", %{
      fx: fx
    } do
      caller = T.caller!(fx, grants: [{@tw, :a}])

      for mode <- [:off, :shadow, :absent] do
        conn = conn_for(fx, caller, mode)

        {{returned, set}, queries} =
          Fixture.capture_repo_queries(fn ->
            ScopeGate.scope_set_for_role(conn, :TasksList, @tw)
          end)

        assert set == :all
        assert queries == [], "#{mode}"
        assert ScopeGate.applied?(returned)

        {{returned, f1}, queries} =
          Fixture.capture_repo_queries(fn -> ScopeGate.f1_principal(conn, :TasksComplete) end)

        assert f1 == :off
        assert queries == [], "#{mode}"
        assert ScopeGate.applied?(returned)
      end
    end

    test "on: a scoped TASK_WORKER gets the node set; a tenant-wide one gets :all; a role with no grant gets :none",
         %{fx: fx} do
      scoped = T.caller!(fx, grants: [{@tw, :a}])
      wide = T.caller!(fx, grants: [{@tw, :tenant_wide}])
      rowless = T.caller!(fx, roles: [@tw])

      assert {_, {:nodes, got}} =
               ScopeGate.scope_set_for_role(conn_for(fx, scoped, :on), :TasksList, @tw)

      assert got == ids([:a, :a1, :a2x])

      assert {_, :all} = ScopeGate.scope_set_for_role(conn_for(fx, wide, :on), :TasksList, @tw)

      assert {_, :none} =
               ScopeGate.scope_set_for_role(conn_for(fx, rowless, :on), :TasksList, @tw)
    end

    test "on: a scoped PROCESS_OPERATOR or TENANT_ADMIN WITHOUT a TASK_WORKER grant gets :none; with a covering TASK_WORKER grant it gets the set",
         %{fx: fx} do
      for role <- [@po, "TENANT_ADMIN"] do
        no_tw = T.caller!(fx, roles: [role], grants: [{role, :a}])

        assert {_, :none} =
                 ScopeGate.scope_set_for_role(conn_for(fx, no_tw, :on), :TasksList, @tw)

        with_tw = T.caller!(fx, roles: [role, @tw], grants: [{role, :a}, {@tw, :a}])

        assert {_, {:nodes, set}} =
                 ScopeGate.scope_set_for_role(conn_for(fx, with_tw, :on), :TasksList, @tw)

        assert set == ids([:a, :a1, :a2x])
      end
    end

    test "on, RA-13 exemption: holding the route permission TENANT-WIDE (any role) gives :all, per route permission (case d3 and variants)",
         %{fx: fx} do
      # scoped TASK_WORKER not covering the task area + tenant-wide PROCESS_OPERATOR
      mixed = T.caller!(fx, roles: [@tw, @po], grants: [{@tw, :b}, {@po, :tenant_wide}])

      for key <- [:TasksList, :TasksGetById, :TasksComplete] do
        assert {_, :all} = ScopeGate.scope_set_for_role(conn_for(fx, mixed, :on), key, @tw),
               "#{key}"
      end

      # a tenant-wide TENANT_ADMIN with no TASK_WORKER role at all
      admin = T.caller!(fx, roles: ["TENANT_ADMIN"], grants: [{"TENANT_ADMIN", :tenant_wide}])
      assert {_, :all} = ScopeGate.scope_set_for_role(conn_for(fx, admin, :on), :TasksList, @tw)

      # tenant-wide on ANOTHER permission is not the exemption: TASK_WORKER does not hold
      # :TasksAssign, so a tenant-wide TASK_WORKER row gives no exemption for it
      tw_wide = T.caller!(fx, grants: [{@tw, :tenant_wide}])
      assert {_, :all} = ScopeGate.scope_set_for_role(conn_for(fx, tw_wide, :on), :TasksList, @tw)

      scoped_po = T.caller!(fx, roles: [@po], grants: [{@po, :a}])

      assert {_, :none} =
               ScopeGate.scope_set_for_role(conn_for(fx, scoped_po, :on), :TasksList, @tw)
    end

    test "on: a token principal is :all (tenant-wide by design D1) without a scope statement",
         %{fx: fx} do
      token_caller = T.caller!(fx, roles: [@tw], routing: false)
      conn = conn_for(fx, token_caller, :on, :api_token)

      {{_conn, set}, queries} =
        Fixture.capture_repo_queries(fn ->
          ScopeGate.scope_set_for_role(conn, :TasksList, @tw)
        end)

      assert set == :all
      assert count(queries, "role_scope_grants") == 0
      assert count(queries, "scope_node_paths") == 0
    end

    test "on, no principal: the set is :none with no statement; f1_principal/2 raises ScopeSetError after ONE constant log line",
         %{fx: fx} do
      conn =
        :get
        |> Fixture.router_conn("/", fx, [@tw], nil)
        |> assign(:auth_context, %{scope_enforcement: :on, roles: [@tw]})
        |> assign(:scoped_opts, prefix: fx.schema_name)

      {{_c, set}, queries} =
        Fixture.capture_repo_queries(fn ->
          ScopeGate.scope_set_for_role(conn, :TasksList, @tw)
        end)

      assert set == :none
      assert queries == []

      log =
        capture_log([level: :error], fn ->
          assert_raise ScopeSetError, fn -> ScopeGate.f1_principal(conn, :TasksComplete) end
        end)

      # refute only on OUR constant line: the captured log also holds the Ecto debug QUERY lines
      assert length(String.split(log, "scope_set_failed")) - 1 == 1
      assert log =~ "scope_set_failed reason=no_principal"
    end

    test "on: f1_principal/2 hands over the principal built from the claimed roles and the database",
         %{
           fx: fx
         } do
      caller = T.caller!(fx, grants: [{@tw, :a}])

      assert {conn, {:enforce, %Principal{} = p}} =
               ScopeGate.f1_principal(conn_for(fx, caller, :on), :TasksComplete)

      assert p.kind == :user and p.user_id == caller.id and p.prefix == fx.schema_name
      assert p.roles == [:TASK_WORKER]
      assert %Grants{rows_by_role: %{@tw => [_row]}} = p.grants
      assert ScopeGate.applied?(conn)
    end

    test "the memo is per permission AND role: a second call issues no statement; another role is computed separately",
         %{fx: fx} do
      caller = T.caller!(fx, roles: [@tw, @po], grants: [{@tw, :a}, {@po, :b}])
      conn = conn_for(fx, caller, :on)

      {{conn, tw_set}, first} =
        Fixture.capture_repo_queries(fn ->
          ScopeGate.scope_set_for_role(conn, :TasksList, @tw)
        end)

      assert first != []
      assert tw_set == {:nodes, ids([:a, :a1, :a2x])}

      {{conn, again}, second} =
        Fixture.capture_repo_queries(fn ->
          ScopeGate.scope_set_for_role(conn, :TasksList, @tw)
        end)

      assert again == tw_set
      assert second == []

      # same permission, another role: its own set (not served from the TASK_WORKER memo)
      {{_conn, po_set}, third} =
        Fixture.capture_repo_queries(fn ->
          ScopeGate.scope_set_for_role(conn, :TasksList, @po)
        end)

      assert po_set == {:nodes, ids([:b, :b1])}
      assert count(third, "scope_node_paths") > 0
    end
  end

  # ===========================================================================================
  describe "Tasks.f1_allowed?/3 (design C.3)" do
    defp task(node), do: %EngineTask{id: Ecto.UUID.generate(), scope_node_id: node}

    test "(1) the exemption: a principal allowed the route permission tenant-wide needs no grant, whatever the node, even NULL",
         %{fx: fx} do
      n = F.nodes()
      exempt = principal(fx, [@po], %{@po => [wide_row()]})

      for node <- [n.a, n.b, n.a3, nil] do
        assert Tasks.f1_allowed?(task(node), exempt, :TasksComplete)
      end

      assert Tasks.f1_allowed?(task(nil), F.token_principal(fx), :TasksComplete)
      assert Tasks.f1_allowed?(task(n.a), F.platform_admin_principal(fx), :TasksComplete)
    end

    test "(2) a scoped caller needs a TASK_WORKER grant covering the task's node: ancestor allowed, sibling refused, NULL refused, retired refused",
         %{fx: fx} do
      n = F.nodes()
      p = tw_at(fx, [:a])

      assert Tasks.f1_allowed?(task(n.a), p, :TasksComplete)
      assert Tasks.f1_allowed?(task(n.a1), p, :TasksComplete)
      assert Tasks.f1_allowed?(task(n.a2x), p, :TasksComplete)
      refute Tasks.f1_allowed?(task(n.b), p, :TasksComplete)
      refute Tasks.f1_allowed?(task(n.root), p, :TasksComplete)
      refute Tasks.f1_allowed?(task(nil), p, :TasksComplete)
      refute Tasks.f1_allowed?(task(n.a2), p, :TasksComplete)
      refute Tasks.f1_allowed?(task(n.a3), p, :TasksComplete)
      refute Tasks.f1_allowed?(task("sf-ghost"), p, :TasksComplete)
    end

    test "a scoped PROCESS_OPERATOR or TENANT_ADMIN WITHOUT a TASK_WORKER grant is refused even on its own node (MU36)",
         %{fx: fx} do
      n = F.nodes()

      for role <- [@po, "TENANT_ADMIN"] do
        p = principal(fx, [role], %{role => [node_row(:a)]})
        refute Tasks.f1_allowed?(task(n.a1), p, :TasksComplete), role
        refute Tasks.f1_allowed?(task(nil), p, :TasksComplete), role
      end
    end

    test "case d3: a scoped TASK_WORKER NOT covering the task plus a tenant-wide PROCESS_OPERATOR is exempt",
         %{
           fx: fx
         } do
      n = F.nodes()
      p = principal(fx, [@tw, @po], %{@tw => [node_row(:b)], @po => [wide_row()]})
      assert Tasks.f1_allowed?(task(n.a1), p, :TasksComplete)
      assert Tasks.f1_allowed?(task(nil), p, :TasksComplete)
    end
  end
end
