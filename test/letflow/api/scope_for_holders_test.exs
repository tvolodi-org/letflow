defmodule Letflow.Api.ScopeForHoldersTest do
  @moduledoc """
  Roles stage 0, slice S0-2 (decision 0088): `Scope.allowed_for_holders?/3`,
  `Scope.allowed_set_for_holders/2`, `ScopeGate.scope_set_for_holders/3` and the permission-based
  `Tasks.f1_allowed?/3` must answer exactly what the role-name form
  (`allowed_for_role?/3`, `allowed_set_for_role/2`, `scope_set_for_role/3` with "TASK_WORKER")
  answered, for every principal shape (design `T-1854/design.md` 2.1):

    * H1 tuple-for-tuple agreement over the T-F16 grid plus the admin shapes;
    * H2 both branches: a scoped TENANT_ADMIN grant is refused, a covering TASK_WORKER grant allowed;
    * H3 the gate function equals the role function (`on`), and is `:all` with no query when not `on`;
    * H4 `Tasks.f1_allowed?/3` refuses a scoped TENANT_ADMIN grant and allows a TASK_WORKER one.

  `async: false`: a real tenant (the node tree is read from the database).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.Grants
  alias Letflow.Api.Scope.Principal
  alias Letflow.Api.ScopeGate
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TaskScopeFixture, as: T
  alias Letflow.Tasks

  @tw "TASK_WORKER"
  @po "PROCESS_OPERATOR"
  @ta "TENANT_ADMIN"
  @perm :TasksWorkInScope

  setup do
    {:ok, fx: T.provision!("s02-holders")}
  end

  defp ids(keys), do: keys |> Enum.map(&Map.fetch!(F.nodes(), &1)) |> Enum.sort()

  defp node_row(key),
    do: %{principal_type: :user, tenant_wide: false, scope_node_id: F.nodes()[key]}

  defp wide_row, do: %{principal_type: :user, tenant_wide: true, scope_node_id: nil}

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

  defp conn_for(fx, caller, mode) do
    ctx = fx |> S.ctx(caller.id, caller.roles, :oidc) |> put_mode(mode)

    :get
    |> Fixture.router_conn("/", fx, caller.roles, nil)
    |> assign(:auth_context, ctx)
    |> assign(:scoped_opts, prefix: fx.schema_name)
  end

  defp put_mode(ctx, :absent), do: ctx
  defp put_mode(ctx, mode), do: Map.put(ctx, :scope_enforcement, mode)

  defp task(node), do: %EngineTask{id: Ecto.UUID.generate(), scope_node_id: node}

  @tag timeout: 120_000
  test "H1 the holder form equals the role form for every principal shape and resource", %{
    fx: fx
  } do
    keys = Map.keys(F.nodes())
    selections = [[]] ++ Enum.map(keys, &[&1]) ++ for(a <- keys, b <- keys, a < b, do: [a, b])

    principals =
      Enum.map(selections, fn sel ->
        principal(fx, [@tw], %{@tw => Enum.map(sel, &node_row/1)})
      end) ++
        [
          principal(fx, [@tw], %{@tw => [wide_row()]}),
          principal(fx, [@po], %{@po => [wide_row()]}),
          principal(fx, [@ta], %{@ta => [node_row(:a)]}),
          principal(fx, [@ta], %{@ta => [wide_row()]}),
          principal(fx, [@po], %{@po => [node_row(:a)]}),
          principal(fx, [@ta, @tw], %{@ta => [node_row(:a)], @tw => [node_row(:b)]}),
          principal(fx, [@tw, @po], %{@tw => [node_row(:b)], @po => [node_row(:a)]}),
          %{principal(fx, [@tw], %{}) | grants: :not_loaded},
          F.token_principal(fx),
          F.platform_admin_principal(fx)
        ]

    resources =
      Enum.map(Map.values(F.nodes()) ++ ["sf-ghost"], &{:node, &1}) ++
        [:tenant_wide, :unresolvable]

    checked =
      for p <- principals, reduce: 0 do
        acc ->
          assert Scope.allowed_set_for_holders(p, @perm) == Scope.allowed_set_for_role(p, @tw)

          for r <- resources do
            assert Scope.allowed_for_holders?(p, @perm, r) == Scope.allowed_for_role?(p, @tw, r)
          end

          acc + length(resources)
      end

    assert checked == length(principals) * length(resources)
    assert checked > 500
  end

  test "H2 a scoped TENANT_ADMIN grant is refused; with a covering TASK_WORKER grant it is allowed",
       %{fx: fx} do
    n = F.nodes()
    admin_only = principal(fx, [@ta], %{@ta => [node_row(:a)]})

    assert Scope.allowed_for_holders?(admin_only, @perm, {:node, n.a1}) ==
             {:deny, :role_not_held}

    assert Scope.allowed_set_for_holders(admin_only, @perm) == {:ok, :none}

    both = principal(fx, [@ta, @tw], %{@ta => [node_row(:b)], @tw => [node_row(:a)]})
    assert Scope.allowed_for_holders?(both, @perm, {:node, n.a1}) == {:allow, :subtree}
    # the TENANT_ADMIN row on :b never counts
    assert {:deny, :out_of_scope} = Scope.allowed_for_holders?(both, @perm, {:node, n.b})
    assert Scope.allowed_set_for_holders(both, @perm) == {:ok, {:nodes, ids([:a, :a1, :a2x])}}
  end

  test "H3 scope_set_for_holders/3 equals scope_set_for_role/3; not on is :all with no query", %{
    fx: fx
  } do
    callers = [
      T.caller!(fx, grants: [{@tw, :a}]),
      T.caller!(fx, grants: [{@tw, :tenant_wide}]),
      T.caller!(fx, roles: [@tw]),
      T.caller!(fx, roles: [@ta], grants: [{@ta, :a}]),
      T.caller!(fx, roles: [@ta, @tw], grants: [{@ta, :a}, {@tw, :a}]),
      T.caller!(fx, roles: [@tw, @po], grants: [{@tw, :b}, {@po, :tenant_wide}]),
      T.caller!(fx, roles: [@ta], grants: [{@ta, :tenant_wide}]),
      T.caller!(fx, roles: [@po], grants: [{@po, :a}])
    ]

    for caller <- callers, key <- [:TasksList, :TasksGetById, :TasksComplete] do
      {_, by_holders} =
        ScopeGate.scope_set_for_holders(conn_for(fx, caller, :on), key, @perm)

      {_, by_role} = ScopeGate.scope_set_for_role(conn_for(fx, caller, :on), key, @tw)
      assert by_holders == by_role, "#{inspect(caller.roles)} #{key}"
    end

    # refused and allowed answers are really different shapes
    scoped_admin = T.caller!(fx, roles: [@ta], grants: [{@ta, :a}])
    scoped_tw = T.caller!(fx, grants: [{@tw, :a}])

    assert {_, :none} =
             ScopeGate.scope_set_for_holders(conn_for(fx, scoped_admin, :on), :TasksList, @perm)

    assert {_, {:nodes, _}} =
             ScopeGate.scope_set_for_holders(conn_for(fx, scoped_tw, :on), :TasksList, @perm)

    for mode <- [:off, :shadow, :absent] do
      conn = conn_for(fx, scoped_tw, mode)

      {{returned, set}, queries} =
        Fixture.capture_repo_queries(fn ->
          ScopeGate.scope_set_for_holders(conn, :TasksList, @perm)
        end)

      assert set == :all
      assert queries == [], "#{mode}"
      assert ScopeGate.applied?(returned)
    end
  end

  test "H4 Tasks.f1_allowed?/3 refuses a scoped TENANT_ADMIN grant and allows a TASK_WORKER one",
       %{fx: fx} do
    n = F.nodes()
    admin = principal(fx, [@ta], %{@ta => [node_row(:a)]})
    refute Tasks.f1_allowed?(task(n.a1), admin, :TasksComplete)

    worker = principal(fx, [@tw], %{@tw => [node_row(:a)]})
    assert Tasks.f1_allowed?(task(n.a1), worker, :TasksComplete)
    refute Tasks.f1_allowed?(task(n.b), worker, :TasksComplete)

    # RA-13 exemption, unchanged: the platform administrator holds the route permission tenant-wide
    assert Tasks.f1_allowed?(task(n.a1), F.platform_admin_principal(fx), :TasksComplete)
  end
end
