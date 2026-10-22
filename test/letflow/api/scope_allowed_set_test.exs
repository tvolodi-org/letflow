defmodule Letflow.Api.ScopeAllowedSetTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-a, AC 2 (the set the compiler is given) and the SEC code-gate
  conditions C-1 / C-2 (design `lib/letflow/design/req518-compiler-scope-filter.md` 3.3;
  spec `test/specs/REQ-518-2c-i-a.md`, T-C12, T-C13 (the `Scope`-level half; the HTTP half is
  2c-i-b), T-C14): `Letflow.Api.Scope.allowed_set/2`.

  Nothing calls `allowed_set/2` in production code until 2c-i-b (`ScopeGate`), so it is tested
  directly here (REVIEWER 2c-i-a F-5 (d)):

    * every row of the decision table (unknown permission, platform-scope permission, no role,
      platform admin, token, grants unavailable, tenant-wide, zero rows, scoped);
    * T-C12: for every node and every principal kind, `n in set` iff `allowed?/3` allows the
      node, and `:all` iff `allowed?/3` allows `:tenant_wide` (the fixture tree has a RETIRED
      INTERMEDIATE node `a2` with a LIVE child `a2x` under a grant on the live ancestor `a`, and a
      retired leaf `a3`: SEC C-2);
    * C-1: an expansion error raises `ScopeSetError` with only the reason atom after ONE constant
      log line; it is never `:all`, a partial set or a silent `:none`; a database error
      propagates; the 50,000 cap (lowered here) fails closed, never truncates, and a set exactly
      at the cap succeeds (T-C14);
    * cost: a token, tenant-wide or zero-row principal reads nothing, a scoped one reads the
      tree twice.

  `async: false`: real tenants, the VM-global cap application env.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.Grants
  alias Letflow.Api.Scope.Principal
  alias Letflow.Api.Scope.ScopeSetError
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture

  @perm :EntitiesQuery
  @cap_key :scope_allowed_ids_cap

  setup do
    {:ok, fx: F.provision!("req518-aset")}
  end

  defp ids(keys), do: keys |> Enum.map(&Map.fetch!(F.nodes(), &1)) |> Enum.sort()

  defp put_cap!(value) do
    original = Application.fetch_env(:letflow, @cap_key)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:letflow, @cap_key, v)
        :error -> Application.delete_env(:letflow, @cap_key)
      end
    end)

    Application.put_env(:letflow, @cap_key, value)
  end

  # A principal built in memory (no database) whose only grant row is `row`.
  defp handmade(prefix, rows) do
    user_id = Ecto.UUID.generate()

    %Principal{
      kind: :user,
      user_id: user_id,
      prefix: prefix,
      platform_tenant?: false,
      roles: [:TASK_WORKER],
      grants: %Grants{user_id: user_id, rows_by_role: %{F.role() => rows}}
    }
  end

  defp node_row(node_id),
    do: %{principal_type: :user, tenant_wide: false, scope_node_id: node_id}

  # the single ScopeSetError raised by `fun` (reason atom) plus the log it wrote
  defp raised_with_log(fun) do
    log =
      capture_log([level: :error], fn ->
        send(self(), {:raised, catch_error(fun.())})
      end)

    assert_received {:raised, error}
    {error, log}
  end

  # ===========================================================================================
  describe "decision table" do
    test "a permission outside Authorization.permissions/0 is :none for every principal", %{
      fx: fx
    } do
      for principal <- [
            F.principal(fx, :tenant_wide),
            F.principal(fx, {:nodes, [:a]}),
            F.token_principal(fx),
            F.platform_admin_principal(fx)
          ] do
        assert Scope.allowed_set(principal, :NotAPermission) == {:ok, :none}
      end
    end

    test "a platform-scope permission is :all only where the role holds it in the platform scope",
         %{fx: fx} do
      assert Scope.allowed_set(F.platform_admin_principal(fx), :TenantsManage) == {:ok, :all}
      assert Scope.allowed_set(F.principal(fx, {:nodes, [:a]}), :TenantsManage) == {:ok, :none}
      assert Scope.allowed_set(F.principal(fx, :tenant_wide), :TenantsManage) == {:ok, :none}
    end

    test "a user without a role that allows the permission is :none, a tenant-wide grant of another role does not help",
         %{fx: fx} do
      refute Letflow.Api.Authorization.role_allows?(:CANDIDATE, @perm)
      candidate = TokenMintFixture.role_holder!(fx.schema_name, ["CANDIDATE"])

      assert fx |> S.principal(candidate.id) |> Scope.allowed_set(@perm) == {:ok, :none}
    end

    test "PLATFORM_ADMIN of the platform tenant is :all; outside the platform tenant it needs a grant",
         %{fx: fx} do
      assert Scope.allowed_set(F.platform_admin_principal(fx), @perm) == {:ok, :all}

      not_platform = %{
        F.platform_admin_principal(fx)
        | platform_tenant?: false,
          grants: :not_loaded
      }

      assert Scope.allowed_set(not_platform, @perm) == {:ok, :none}
    end

    test "a token principal is tenant-wide (:all), design D1", %{fx: fx} do
      assert Scope.allowed_set(F.token_principal(fx), @perm) == {:ok, :all}
    end

    test "grants that failed to load are :none, never :all", %{fx: fx} do
      principal = %{
        F.platform_admin_principal(fx)
        | platform_tenant?: false,
          roles: [:TASK_WORKER],
          grants: :not_loaded
      }

      assert Scope.allowed_set(principal, @perm) == {:ok, :none}
    end

    test "a tenant-wide grant is :all, a role with no grant row is :none", %{fx: fx} do
      assert fx |> F.principal(:tenant_wide) |> Scope.allowed_set(@perm) == {:ok, :all}
      assert fx |> F.principal(:zero_rows) |> Scope.allowed_set(@perm) == {:ok, :none}
    end

    test "a scoped grant expands to the root and its LIVE descendants, sorted: the retired a2 and a3 are absent, a2x under the retired a2 is present (C-2, MU3, MU4)",
         %{fx: fx} do
      assert fx |> F.principal({:nodes, [:a]}) |> Scope.allowed_set(@perm) ==
               {:ok, {:nodes, ids([:a, :a1, :a2x])}}

      # a grant on the live descendant of the retired intermediate node
      assert fx |> F.principal({:nodes, [:a2x]}) |> Scope.allowed_set(@perm) ==
               {:ok, {:nodes, ids([:a2x])}}

      # two roots, one subtree each, overlap-free
      assert fx |> F.principal({:nodes, [:a1, :b]}) |> Scope.allowed_set(@perm) ==
               {:ok, {:nodes, ids([:a1, :b, :b1])}}

      # overlapping roots: no duplicates
      assert fx |> F.principal({:nodes, [:a, :a1]}) |> Scope.allowed_set(@perm) ==
               {:ok, {:nodes, ids([:a, :a1, :a2x])}}
    end

    test "grants naming no live node (a retired leaf, an unknown node) are :none, never an error",
         %{fx: fx} do
      assert fx |> F.principal({:nodes, [:a3]}) |> Scope.allowed_set(@perm) == {:ok, :none}

      ghost = handmade(fx.schema_name, [node_row("sf-ghost")])
      assert Scope.allowed_set(ghost, @perm) == {:ok, :none}
    end

    test "the producer never returns an empty node list: no result is {:nodes, []} (GH #2809)",
         %{fx: fx} do
      for principal <- [F.principal(fx, {:nodes, [:a3]}), handmade(fx.schema_name, [])] do
        assert {:ok, set} = Scope.allowed_set(principal, @perm)
        assert set == :none
        refute match?({:nodes, []}, set)
      end
    end
  end

  # ===========================================================================================
  describe "T-C12 agreement with allowed?/3 over the fixture tree" do
    test "for every principal kind and node: n in set iff allowed?/3 allows the node; :all iff :tenant_wide is allowed",
         %{fx: fx} do
      nodes = Map.values(F.nodes()) ++ ["sf-ghost"]

      scoped =
        for spec <- [{:nodes, [:a]}, {:nodes, [:a, :b1]}, {:nodes, [:a2x]}, {:nodes, [:b]}] do
          {spec, F.principal(fx, spec)}
        end

      for {spec, principal} <- scoped do
        {:ok, {:nodes, set}} = Scope.allowed_set(principal, @perm)

        for n <- nodes do
          allowed? = match?({:allow, _}, Scope.allowed?(principal, @perm, {:node, n}))

          assert n in set == allowed?,
                 "#{inspect(spec)} node #{n}: set=#{n in set} allowed?=#{allowed?}"
        end

        assert {:deny, _} = Scope.allowed?(principal, @perm, :tenant_wide)
      end

      for principal <- [
            F.principal(fx, :tenant_wide),
            F.token_principal(fx),
            F.platform_admin_principal(fx)
          ] do
        assert Scope.allowed_set(principal, @perm) == {:ok, :all}
        assert {:allow, _} = Scope.allowed?(principal, @perm, :tenant_wide)
      end

      candidate = TokenMintFixture.role_holder!(fx.schema_name, ["CANDIDATE"])

      for principal <- [
            F.principal(fx, :zero_rows),
            S.principal(fx, candidate.id)
          ] do
        assert Scope.allowed_set(principal, @perm) == {:ok, :none}

        for n <- nodes do
          assert {:deny, _} = Scope.allowed?(principal, @perm, {:node, n})
        end

        assert {:deny, _} = Scope.allowed?(principal, @perm, :tenant_wide)
      end
    end

    test "the retired intermediate node a2 is denied by allowed?/3 and absent from the set while its live child a2x is in both",
         %{fx: fx} do
      principal = F.principal(fx, {:nodes, [:a]})
      {:ok, {:nodes, set}} = Scope.allowed_set(principal, @perm)

      assert Scope.allowed?(principal, @perm, {:node, F.nodes().a2}) == {:deny, :unresolvable}
      refute F.nodes().a2 in set
      assert {:allow, :subtree} = Scope.allowed?(principal, @perm, {:node, F.nodes().a2x})
      assert F.nodes().a2x in set
      assert {:deny, :unresolvable} = Scope.allowed?(principal, @perm, {:node, F.nodes().a3})
      refute F.nodes().a3 in set
    end
  end

  # ===========================================================================================
  describe "C-1 fail closed: an expansion failure raises ScopeSetError (T-C13, Scope level)" do
    test ":invalid_node_id: raises with only the reason, one constant log line, no id in the log (MU40)",
         %{fx: fx} do
      hostile = "sf/not-a-node-id-xyz"
      principal = handmade(fx.schema_name, [node_row(hostile)])

      {error, log} = raised_with_log(fn -> Scope.allowed_set(principal, @perm) end)

      assert %ScopeSetError{reason: :invalid_node_id} = error
      assert Exception.message(error) == "scope_set_failed"

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "scope_set_failed"))
      assert [line] = lines
      assert line =~ "scope_set_failed reason=invalid_node_id"
      refute log =~ hostile
      refute log =~ fx.schema_name
    end

    test ":invalid_schema_name: a malformed prefix raises the same exception with its own reason",
         _context do
      principal = handmade("not-a-tenant-schema", [node_row(F.nodes().a)])

      {error, log} = raised_with_log(fn -> Scope.allowed_set(principal, @perm) end)

      assert %ScopeSetError{reason: :invalid_schema_name} = error
      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "scope_set_failed"))
      assert line =~ "scope_set_failed reason=invalid_schema_name"
      refute log =~ "not-a-tenant-schema"
    end

    test "one log line per occurrence: three failures, three lines", %{fx: fx} do
      principal = handmade(fx.schema_name, [node_row("bad/id")])

      log =
        capture_log([level: :error], fn ->
          for _ <- 1..3 do
            assert_raise ScopeSetError, fn -> Scope.allowed_set(principal, @perm) end
          end
        end)

      assert log |> String.split("\n") |> Enum.count(&(&1 =~ "scope_set_failed")) == 3
    end

    test "it never returns: not :all, not :none, not a partial set (the call has no non-raising error path)",
         %{fx: fx} do
      principal = handmade(fx.schema_name, [node_row(F.nodes().a), node_row("bad/id")])

      capture_log(fn ->
        assert_raise ScopeSetError, fn -> Scope.allowed_set(principal, @perm) end
      end)
    end

    test "a database error from the node reads propagates (it is not turned into :none or :all)",
         _context do
      missing_schema = "tenant_" <> String.duplicate("0", 32)
      principal = handmade(missing_schema, [node_row(F.nodes().a)])

      assert_raise Postgrex.Error, fn -> Scope.allowed_set(principal, @perm) end
    end
  end

  # ===========================================================================================
  describe "T-C14 the expanded set is capped, fail closed, never truncated" do
    test "a grant whose expanded set has 4 live nodes fails with a cap of 3: :too_many_ids at the node level, ScopeSetError at the Scope level (MU41)",
         %{fx: fx} do
      principal = F.principal(fx, {:nodes, [:a, :b1]})
      roots = [F.nodes().a, F.nodes().b1]

      # control: uncapped, the four live nodes
      assert {:ok, ids} = Letflow.ScopeNodePaths.allowed_node_ids(roots, fx.schema_name)
      assert ids == ids([:a, :a1, :a2x, :b1])

      put_cap!(3)

      assert Letflow.ScopeNodePaths.allowed_node_ids(roots, fx.schema_name) ==
               {:error, :too_many_ids}

      {error, log} = raised_with_log(fn -> Scope.allowed_set(principal, @perm) end)
      assert %ScopeSetError{reason: :too_many_ids} = error
      assert log =~ "scope_set_failed reason=too_many_ids"
    end

    test "exactly at the cap succeeds with the full set (no off-by-one, no truncation)", %{fx: fx} do
      principal = F.principal(fx, {:nodes, [:a, :b1]})

      put_cap!(4)
      assert Scope.allowed_set(principal, @perm) == {:ok, {:nodes, ids([:a, :a1, :a2x, :b1])}}

      put_cap!(3)
      # three live nodes fit a cap of three
      assert fx |> F.principal({:nodes, [:a]}) |> Scope.allowed_set(@perm) ==
               {:ok, {:nodes, ids([:a, :a1, :a2x])}}
    end

    test "the cap counts LIVE nodes only: retired nodes under the root do not use the budget", %{
      fx: fx
    } do
      # a has five descendants-or-self in the table (a, a1, a2, a2x, a3), three of them live
      put_cap!(3)
      assert {:ok, set} = Letflow.ScopeNodePaths.allowed_node_ids([F.nodes().a], fx.schema_name)
      assert set == ids([:a, :a1, :a2x])
    end
  end

  # ===========================================================================================
  describe "cost (AC 5): the tree is read twice for a scoped caller and not at all otherwise" do
    test "token, tenant-wide and zero-row principals issue no query; a scoped one issues exactly two",
         %{fx: fx} do
      scoped = F.principal(fx, {:nodes, [:a]})
      tenant_wide = F.principal(fx, :tenant_wide)
      zero = F.principal(fx, :zero_rows)
      token = F.token_principal(fx)

      for {label, principal, expected} <- [
            {:token, token, 0},
            {:tenant_wide, tenant_wide, 0},
            {:zero_rows, zero, 0},
            {:scoped, scoped, 2}
          ] do
        {{:ok, _set}, queries} =
          Fixture.capture_repo_queries(fn -> Scope.allowed_set(principal, @perm) end)

        assert length(queries) == expected, "#{label}: #{length(queries)} statements"
      end
    end

    test "two roots still cost two statements (one chunk)", %{fx: fx} do
      principal = F.principal(fx, {:nodes, [:a, :b]})

      {{:ok, _set}, queries} =
        Fixture.capture_repo_queries(fn -> Scope.allowed_set(principal, @perm) end)

      assert length(queries) == 2
      assert Enum.all?(queries, &(&1.query =~ "scope_node_paths"))
    end
  end
end
