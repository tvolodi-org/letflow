defmodule Letflow.Api.ScopeGateTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-b, AC 5 and the gate half of AC 2 / T-C13 (design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.5, 3.9; spec
  `test/specs/REQ-518-2c-i-b.md`; SEC code-gate step-12 and step-07 F-1): the ONE conn-level
  entry `Letflow.Api.ScopeGate`.

    * mode: `on`, `shadow`, `off`, key absent, no auth context;
    * not `on`: `{conn, :all}` / `{conn, true}`, ZERO repository statements, the marker is set;
    * `on`: the expanded node set per permission; tenant-wide `:all`, zero-row `:none`, no principal
      `:none` (no statement), a token principal `:all` (no scope statement);
    * AC 5 statement counts: the node set is computed ONCE per request per permission (a second
      call on the returned conn issues no statement), the grants are read once however many
      permissions are asked, a pipeline-loaded grants memo costs no grants read, token and OIDC
      shapes;
    * the memo is per permission (a permission the role lacks does not poison one it holds, in
      either order) and per request (two principals never see each other's set);
    * `applied?/1` is true only on the conn a gate call returned;
    * failure is loud (SEC C-1, F-1): a database fault in the node read, a `:too_many_ids` cap
      failure and a corrupt grants memo each raise `ScopeSetError` with exactly ONE
      `scope_set_failed` log line (no ids), never a set.

  `async: false`: real tenants with committed data and one DDL fault (a renamed table, restored).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.ScopeSetError
  alias Letflow.Api.ScopeGate
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @role "TASK_WORKER"
  @held :EntitiesQuery
  # TASK_WORKER holds :EntitiesQuery and :EntitiesAggregate, not :EntitiesRecordsExport
  @not_held :EntitiesRecordsExport

  setup do
    fx = S.tenant!("r518-gate")
    {:ok, fx: fx, scoped: On.scoped_holder!(fx, @role)}
  end

  # ---- helpers ------------------------------------------------------------------------------

  defp conn_for(fx, user_id, mode, credential \\ :oidc) do
    ctx = fx |> S.ctx(user_id, [@role], credential) |> put_mode(mode)

    :post
    |> Fixture.router_conn("/query", fx, [@role], nil)
    |> assign(:auth_context, ctx)
    |> assign(:scoped_opts, prefix: fx.schema_name)
  end

  defp put_mode(ctx, :absent), do: ctx
  defp put_mode(ctx, mode), do: Map.put(ctx, :scope_enforcement, mode)

  defp tables(queries, table), do: Enum.count(queries, &(&1.query =~ table))

  # the same principal the gate builds from the claimed role and the user's grant rows
  defp oracle(fx, user_id, permission) do
    Scope.allowed_set(
      %Scope.Principal{
        kind: :user,
        user_id: user_id,
        prefix: fx.schema_name,
        platform_tenant?: false,
        roles: [:TASK_WORKER],
        grants: Scope.load_grants(user_id, fx.schema_name)
      },
      permission
    )
  end

  # ===========================================================================================
  describe "mode/1" do
    test "reads auth_context.scope_enforcement; anything else (absent key, absent context) is off",
         %{fx: fx, scoped: scoped} do
      assert ScopeGate.mode(conn_for(fx, scoped.id, :on)) == :on
      assert ScopeGate.mode(conn_for(fx, scoped.id, :shadow)) == :shadow
      assert ScopeGate.mode(conn_for(fx, scoped.id, :off)) == :off
      assert ScopeGate.mode(conn_for(fx, scoped.id, :absent)) == :off
      assert ScopeGate.mode(conn_for(fx, scoped.id, :bogus)) == :off
      assert ScopeGate.mode(Plug.Test.conn(:get, "/")) == :off
    end
  end

  # ===========================================================================================
  describe "not on: the neutral answer with no statement" do
    test "scope_set/2 gives :all and resource_allowed?/3 gives true, with zero repository statements, in off, shadow and key-absent",
         %{fx: fx, scoped: scoped} do
      for mode <- [:off, :shadow, :absent] do
        conn = conn_for(fx, scoped.id, mode)

        {{set_conn, set}, queries} =
          Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(conn, @held) end)

        assert set == :all, "#{mode}"
        assert queries == [], "#{mode}"
        assert ScopeGate.applied?(set_conn), "#{mode}"

        {{allowed_conn, allowed}, queries} =
          Fixture.capture_repo_queries(fn ->
            ScopeGate.resource_allowed?(conn, @held, {:node, "x"})
          end)

        assert allowed == true, "#{mode}"
        assert queries == [], "#{mode}"
        assert ScopeGate.applied?(allowed_conn), "#{mode}"
      end
    end

    test "a request with no auth context at all is also neutral and issues no statement" do
      conn = Plug.Test.conn(:post, "/query")

      {{_conn, set}, queries} =
        Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(conn, @held) end)

      assert set == :all
      assert queries == []
    end
  end

  # ===========================================================================================
  describe "applied?/1" do
    test "false on a fresh conn and on the INPUT conn of a gate call; true on the conn a call returns, in every mode",
         %{fx: fx, scoped: scoped} do
      for mode <- [:off, :shadow, :on] do
        conn = conn_for(fx, scoped.id, mode)
        refute ScopeGate.applied?(conn), "#{mode}"

        {returned, _set} = ScopeGate.scope_set(conn, @held)
        assert ScopeGate.applied?(returned), "#{mode}"
        refute ScopeGate.applied?(conn), "#{mode}: the input conn must not be mutated"

        {returned, _allowed} = ScopeGate.resource_allowed?(conn, @held, :tenant_wide)
        assert ScopeGate.applied?(returned), "#{mode}"
      end
    end

    test "a hand-set marker of the wrong value does not count", %{fx: fx, scoped: scoped} do
      conn = fx |> conn_for(scoped.id, :on) |> put_private(:letflow_scope_applied, :yes)
      refute ScopeGate.applied?(conn)
    end
  end

  # ===========================================================================================
  describe "on: the caller's node set" do
    test "a scoped caller gets the expanded node set, equal to Scope.allowed_set/2 of the same principal",
         %{fx: fx, scoped: scoped} do
      {_conn, set} = ScopeGate.scope_set(conn_for(fx, scoped.id, :on), @held)

      assert {:nodes, [_one]} = set
      assert {:ok, set} == oracle(fx, scoped.id, @held)
    end

    test "tenant-wide gives :all, a role-holding user with no grant row gives :none, a token principal gives :all",
         %{fx: fx} do
      wide = RSG.user!(fx.schema_name)
      :ok = RSG.raw_user_row!(fx.schema_name, wide.id, @role, nil)
      zero = On.rowless_holder!(fx)

      assert {_, :all} = ScopeGate.scope_set(conn_for(fx, wide.id, :on), @held)
      assert {_, :none} = ScopeGate.scope_set(conn_for(fx, zero.id, :on), @held)

      token_conn = conn_for(fx, Ecto.UUID.generate(), :on, :api_token)

      {{_conn, token_set}, queries} =
        Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(token_conn, @held) end)

      assert token_set == :all
      assert tables(queries, "scope_node_paths") == 0
      assert tables(queries, "role_scope_grants") == 0
    end

    test "a request with no principal is :none under on (fail closed) and reads nothing" do
      conn = Plug.Test.conn(:post, "/query") |> assign(:auth_context, %{scope_enforcement: :on})

      {{returned, set}, queries} =
        Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(conn, @held) end)

      assert set == :none
      assert queries == []
      assert ScopeGate.applied?(returned)

      {_conn, allowed} = ScopeGate.resource_allowed?(conn, @held, :tenant_wide)
      assert allowed == false
    end
  end

  # ===========================================================================================
  describe "AC 5 statement counts" do
    test "the node set of a request is computed ONCE: a second scope_set/2 call on the returned conn issues no statement and returns the same set",
         %{fx: fx, scoped: scoped} do
      conn = conn_for(fx, scoped.id, :on)

      {{conn1, set1}, first} =
        Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(conn, @held) end)

      {{_conn2, set2}, second} =
        Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(conn1, @held) end)

      assert set1 == set2
      assert tables(first, "scope_node_paths") >= 1
      assert second == []
    end

    test "a hand-built OIDC context reads the grants exactly once; a pipeline-loaded grants memo costs no grants read at all",
         %{fx: fx, scoped: scoped} do
      conn = conn_for(fx, scoped.id, :on)

      {{conn1, _}, first} =
        Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(conn, @held) end)

      assert tables(first, "role_scope_grants") == 1

      # the grants are now memoised in the returned conn's auth_context: another permission asked
      # on that conn reads the node set but NOT the grants again
      {{_conn2, _}, second} =
        Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(conn1, :EntitiesAggregate) end)

      assert tables(second, "role_scope_grants") == 0
      assert tables(second, "scope_node_paths") >= 1

      # what the real AuthPipeline stores: the grants of the user in auth_context.scope_grants
      ctx =
        Map.put(
          conn.assigns.auth_context,
          :scope_grants,
          Scope.load_grants(scoped.id, fx.schema_name)
        )

      preloaded = assign(conn, :auth_context, ctx)

      {{_conn3, set}, third} =
        Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(preloaded, @held) end)

      assert {:nodes, [_]} = set
      assert tables(third, "role_scope_grants") == 0
    end

    test "the node-set statements do not grow with the number of gate calls on one conn, whatever the mix of scope_set/2 and resource_allowed?/3",
         %{fx: fx, scoped: scoped} do
      conn = conn_for(fx, scoped.id, :on)

      {_, once} =
        Fixture.capture_repo_queries(fn ->
          ScopeGate.scope_set(conn, @held)
        end)

      {_, many} =
        Fixture.capture_repo_queries(fn ->
          {c, _} = ScopeGate.scope_set(conn, @held)
          {c, _} = ScopeGate.scope_set(c, @held)
          {c, _} = ScopeGate.scope_set(c, @held)
          ScopeGate.scope_set(c, @held)
        end)

      assert tables(many, "scope_node_paths") == tables(once, "scope_node_paths")
      assert tables(many, "role_scope_grants") == tables(once, "role_scope_grants")
    end

    test "the token shape: no scope statement and the set is :all; the OIDC shape adds exactly the grants read and the node reads over the token shape",
         %{fx: fx, scoped: scoped} do
      token_conn = conn_for(fx, Ecto.UUID.generate(), :on, :api_token)
      oidc_conn = conn_for(fx, scoped.id, :on)

      {{_, :all}, token} =
        Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(token_conn, @held) end)

      {{_, {:nodes, _}}, oidc} =
        Fixture.capture_repo_queries(fn -> ScopeGate.scope_set(oidc_conn, @held) end)

      assert tables(token, "role_scope_grants") + tables(token, "scope_node_paths") == 0
      assert tables(oidc, "role_scope_grants") == 1
      assert length(oidc) > length(token)
    end
  end

  # ===========================================================================================
  describe "the memo is per permission and per request" do
    test "a permission the role lacks (:none) does not poison one it holds, in either order, and a second ask of each is free",
         %{fx: fx, scoped: scoped} do
      {:ok, expected} = oracle(fx, scoped.id, @held)
      assert {:nodes, [_]} = expected

      for order <- [[@not_held, @held], [@held, @not_held]] do
        conn = conn_for(fx, scoped.id, :on)

        {final, sets} =
          Enum.reduce(order, {conn, %{}}, fn permission, {c, acc} ->
            {c, set} = ScopeGate.scope_set(c, permission)
            {c, Map.put(acc, permission, set)}
          end)

        assert sets[@held] == expected, inspect(order)
        assert sets[@not_held] == :none, inspect(order)

        {_, again} =
          Fixture.capture_repo_queries(fn ->
            ScopeGate.scope_set(final, @held)
            ScopeGate.scope_set(final, @not_held)
          end)

        assert again == [], inspect(order)
      end
    end

    test "two principals never share a set, even when their requests are interleaved in one process",
         %{fx: fx} do
      node_a = RSG.node!(fx.schema_name)
      node_b = RSG.node!(fx.schema_name)
      user_a = RSG.user!(fx.schema_name)
      user_b = RSG.user!(fx.schema_name)
      :ok = RSG.raw_user_row!(fx.schema_name, user_a.id, @role, node_a)
      :ok = RSG.raw_user_row!(fx.schema_name, user_b.id, @role, node_b)

      conn_a = conn_for(fx, user_a.id, :on)
      conn_b = conn_for(fx, user_b.id, :on)

      {conn_a, set_a} = ScopeGate.scope_set(conn_a, @held)
      {conn_b, set_b} = ScopeGate.scope_set(conn_b, @held)
      {_conn_a, set_a_again} = ScopeGate.scope_set(conn_a, @held)
      {_conn_b, set_b_again} = ScopeGate.scope_set(conn_b, @held)

      assert set_a == {:nodes, [node_a]}
      assert set_b == {:nodes, [node_b]}
      assert set_a_again == set_a
      assert set_b_again == set_b
    end
  end

  # ===========================================================================================
  describe "resource_allowed?/3 under on" do
    test "a scoped caller is allowed only inside its subtree; a tenant-wide caller everywhere; no tenant-wide resource for a scoped caller",
         %{fx: fx} do
      node = RSG.node!(fx.schema_name)
      other = RSG.node!(fx.schema_name)
      scoped = RSG.user!(fx.schema_name)
      wide = RSG.user!(fx.schema_name)
      :ok = RSG.raw_user_row!(fx.schema_name, scoped.id, @role, node)
      :ok = RSG.raw_user_row!(fx.schema_name, wide.id, @role, nil)

      conn = conn_for(fx, scoped.id, :on)
      assert {_, true} = ScopeGate.resource_allowed?(conn, @held, {:node, node})
      assert {_, false} = ScopeGate.resource_allowed?(conn, @held, {:node, other})
      assert {_, false} = ScopeGate.resource_allowed?(conn, @held, :tenant_wide)
      assert {_, false} = ScopeGate.resource_allowed?(conn, @held, :unresolvable)
      assert {_, false} = ScopeGate.resource_allowed?(conn, @not_held, {:node, node})

      wide_conn = conn_for(fx, wide.id, :on)
      assert {_, true} = ScopeGate.resource_allowed?(wide_conn, @held, {:node, other})
      assert {_, true} = ScopeGate.resource_allowed?(wide_conn, @held, :tenant_wide)
    end
  end

  # ===========================================================================================
  describe "T-C13 failure is loud: ScopeSetError, one constant log line, never a set" do
    test "a database fault in the node read raises ScopeSetError with exactly one scope_set_failed line that names no id or schema",
         %{fx: fx, scoped: scoped} do
      conn = conn_for(fx, scoped.id, :on)
      # build the grants memo first so the ONLY failing read is the node read
      {conn, _set} = ScopeGate.scope_set(conn, :EntitiesAggregate)

      log =
        capture_log(fn ->
          with_renamed_node_paths(fx, fn ->
            assert_raise ScopeSetError, fn -> ScopeGate.scope_set(conn, @held) end
          end)
        end)

      assert count(log, "scope_set_failed") == 1
      refute log =~ fx.schema_name or log =~ "rsg-node"
    end

    test "a cap failure (:too_many_ids) raises ScopeSetError with exactly ONE line: the gate does not log it a second time",
         %{fx: fx, scoped: scoped} do
      previous = Application.get_env(:letflow, :scope_allowed_ids_cap)
      Application.put_env(:letflow, :scope_allowed_ids_cap, 0)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:letflow, :scope_allowed_ids_cap, previous),
          else: Application.delete_env(:letflow, :scope_allowed_ids_cap)
      end)

      log =
        capture_log(fn ->
          error =
            assert_raise ScopeSetError, fn ->
              ScopeGate.scope_set(conn_for(fx, scoped.id, :on), @held)
            end

          assert error.reason == :too_many_ids
        end)

      assert count(log, "scope_set_failed") == 1
      assert log =~ "reason=too_many_ids"
    end

    test "any other raise inside the gate (a corrupt grants memo) is re-raised as ScopeSetError with one read_failed line, from scope_set/2 and from resource_allowed?/3",
         %{fx: fx, scoped: scoped} do
      corrupt = %Scope.Grants{user_id: scoped.id, rows_by_role: :corrupt}
      ctx = Map.put(S.ctx(fx, scoped.id, [@role], :oidc), :scope_enforcement, :on)
      ctx = Map.put(ctx, :scope_grants, corrupt)

      conn =
        :post
        |> Fixture.router_conn("/query", fx, [@role], nil)
        |> assign(:auth_context, ctx)
        |> assign(:scoped_opts, prefix: fx.schema_name)

      log =
        capture_log(fn ->
          error = assert_raise ScopeSetError, fn -> ScopeGate.scope_set(conn, @held) end
          assert error.reason == :read_failed
        end)

      assert count(log, "scope_set_failed") == 1
      assert log =~ "reason=read_failed"

      log =
        capture_log(fn ->
          assert_raise ScopeSetError, fn ->
            ScopeGate.resource_allowed?(conn, @held, {:node, "x"})
          end
        end)

      assert count(log, "scope_set_failed") == 1
    end

    test "a failed read leaves no memo behind: once the fault is repaired the same permission yields its set",
         %{fx: fx, scoped: scoped} do
      conn = conn_for(fx, scoped.id, :on)
      {conn, _} = ScopeGate.scope_set(conn, :EntitiesAggregate)

      capture_log(fn ->
        with_renamed_node_paths(fx, fn ->
          assert_raise ScopeSetError, fn -> ScopeGate.scope_set(conn, @held) end
        end)
      end)

      assert {_, {:nodes, [_]}} = ScopeGate.scope_set(conn, @held)
    end
  end

  # ---- fault injection ------------------------------------------------------------------------

  defp count(log, needle), do: length(String.split(log, needle)) - 1

  # Renames the tenant's scope_node_paths table (committed DDL; the fixtures run in sandbox
  # :auto), runs `fun`, and ALWAYS restores the name.
  defp with_renamed_node_paths(fx, fun) do
    schema = fx.schema_name
    Repo.query!(~s|ALTER TABLE "#{schema}".scope_node_paths RENAME TO scope_node_paths_fault|)

    try do
      fun.()
    after
      Repo.query!(~s|ALTER TABLE "#{schema}".scope_node_paths_fault RENAME TO scope_node_paths|)
    end
  end
end
