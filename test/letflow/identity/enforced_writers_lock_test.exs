defmodule Letflow.Identity.EnforcedWritersLockTest do
  @moduledoc """
  REQ-519 slice 2e-a (GH #2535), AC 6 (lock A serialisation, the mode read after A) and the SEC
  code-gate merge conditions F-1 and C-2 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 3.2, 3.2a, 3.7, tests
  T-L1..T-L8; spec `test/specs/REQ-519-2e-a.md`):

    * T-L1 `ScopeEnforcement.mode_under_lock!/1`: raises `ArgumentError` outside a transaction,
      returns the stored mode inside one, and raises `ModeUnavailableError` when the read itself
      fails (the `tenants` table renamed inside the transaction), key set or not;
    * T-L4 production shape: the PRODUCTION configuration leaves the test-only key
      `:scope_mode_lenient_for_tests` unset, and with it unset a malformed prefix and a
      well-formed prefix with no `tenants` row RAISE (never `:off`);
    * T-L5 the key text occurs in no config file but `config/test.exs` (and `mix.exs`, `rel/`),
      is never read from the OS environment, and lib reads it in exactly one place and sets it
      nowhere;
    * T-L6 with the key set (the test configuration) the same two cases return `:off` and log
      the constant line `scope_mode_read_lenient`, which names no prefix;
    * T-L7 (C-2) a raised mode read leaves NO binding, NO row and NO audit entry and never
      proceeds as `off`: a writer, a repair, a rebind, the seeding and a `Backfill` run, each
      against a tenant schema whose name is well formed but has no `tenants` row (key unset);
    * T-L8 removal never reads the mode: the same unreadable tenant still lets a removal
      through;
    * T-L2 / T-L3 serialisation with the flip on lock A, with a REAL held lock and queue order
      detected through `pg_locks` (no sleeps): a writer queued FIRST commits its binding and its
      row before the flip, which then sees them; a flip queued first commits `on`, and the
      writer, acquiring A afterwards, sees `on` and refuses. No route can set `on` yet, so the
      "flip" here is a transaction that does what `flip/4` does at its core, in `flip/4`'s
      order: lock A, read the facts, set the stored mode.

  `async: false`: real tenant schemas, committed DDL and writes, VM-global application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Letflow.Support.EnforcedWritersFixture
  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Identity
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.RoleScopeGrants.Backfill
  alias Letflow.Identity.TenantRole
  alias Letflow.LockOrderHelpers, as: Locks
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.ModeUnavailableError
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Test.RuntimeConfigEval

  @key :scope_mode_lenient_for_tests
  @key_text "scope_mode_lenient_for_tests"

  # --- helpers ---------------------------------------------------------------------------------

  # Runs `fun` with the application key set to `value` (:unset removes it), restoring it after.
  defp with_key(value, fun) do
    original = Application.fetch_env(:letflow, @key)

    case value do
      :unset -> Application.delete_env(:letflow, @key)
      other -> Application.put_env(:letflow, @key, other)
    end

    try do
      fun.()
    after
      case original do
        {:ok, v} -> Application.put_env(:letflow, @key, v)
        :error -> Application.delete_env(:letflow, @key)
      end
    end
  end

  defp random_tenant_schema,
    do: "tenant_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  # Renames the fixture schema to a well-formed name that has NO `tenants` row (committed DDL,
  # restored in `after`), so the mode read answers "unregistered".
  defp with_unregistered_schema(fx, fun) do
    renamed = random_tenant_schema()
    Repo.query!(~s|ALTER SCHEMA "#{fx.schema_name}" RENAME TO "#{renamed}"|)

    try do
      fun.(renamed)
    after
      Repo.query!(~s|ALTER SCHEMA "#{renamed}" RENAME TO "#{fx.schema_name}"|)
    end
  end

  defp prod_config do
    vars =
      Map.put(
        RuntimeConfigEval.valid_base(),
        "DATABASE_URL",
        "ecto://u:p@localhost/letflow_prod"
      )

    {outcome, _stderr} = RuntimeConfigEval.evaluate(vars, :prod)

    case outcome do
      {:ok, runtime} ->
        RuntimeConfigEval.merged(runtime, :prod)

      {:raised, message, _formatted} ->
        flunk("the production configuration did not evaluate: #{message}")
    end
  end

  # ===========================================================================================
  describe "T-L1 mode_under_lock!/1" do
    test "raises ArgumentError outside a transaction" do
      fx = tenant!("req519-l1a", :on)
      refute Repo.in_transaction?()

      assert_raise ArgumentError, fn -> ScopeEnforcement.mode_under_lock!(fx.schema_name) end
    end

    test "returns the stored mode inside a transaction, for each of the three modes" do
      fx = tenant!("req519-l1b", :off)

      for mode <- [:off, :shadow, :on, :shadow, :off] do
        set_mode!(fx, mode)

        assert {:ok, ^mode} =
                 Repo.transaction(fn -> ScopeEnforcement.mode_under_lock!(fx.schema_name) end)
      end
    end

    test "a read that FAILS raises ModeUnavailableError (tenants table renamed inside the transaction), key set or not" do
      fx = tenant!("req519-l1c", :on)

      for key <- [true, :unset] do
        with_key(key, fn ->
          assert {:error, :done} =
                   Repo.transaction(fn ->
                     Repo.query!("ALTER TABLE tenants RENAME TO tenants_req519_renamed")

                     error =
                       assert_raise ModeUnavailableError, fn ->
                         ScopeEnforcement.mode_under_lock!(fx.schema_name)
                       end

                     # constant message, no fields: nothing about the tenant can leak
                     assert error.message == "scope enforcement mode unavailable"
                     refute error.message =~ fx.schema_name
                     Repo.rollback(:done)
                   end)
        end)
      end

      # the rename was rolled back
      assert {:ok, :on} =
               Repo.transaction(fn -> ScopeEnforcement.mode_under_lock!(fx.schema_name) end)
    end
  end

  # ===========================================================================================
  describe "T-L4 production shape (SEC C-1, F-1)" do
    setup do
      RuntimeConfigEval.isolate_env()
      :ok
    end

    test "the PRODUCTION configuration (config.exs + prod.exs + runtime.exs) leaves the key unset" do
      refute prod_config() |> Keyword.get(:letflow, []) |> Keyword.has_key?(@key)
    end

    test "the dev configuration leaves the key unset; the test configuration sets it to exactly true" do
      refute RuntimeConfigEval.merged([], :dev)
             |> Keyword.get(:letflow, [])
             |> Keyword.has_key?(@key)

      test_config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
      assert get_in(test_config, [:letflow, @key]) == true
      assert Application.get_env(:letflow, @key) == true
    end

    test "with the key unset (production shape) a malformed prefix and a prefix with no tenants row RAISE, never :off" do
      fx = tenant!("req519-l4", :off)

      with_key(:unset, fn ->
        for prefix <- [
              "rsg_" <> String.duplicate("a", 32),
              "not_a_tenant",
              random_tenant_schema()
            ] do
          assert {:error, :done} =
                   Repo.transaction(fn ->
                     assert_raise ModeUnavailableError, fn ->
                       ScopeEnforcement.mode_under_lock!(prefix)
                     end

                     Repo.rollback(:done)
                   end)
        end

        # control: a registered tenant still answers its stored mode with the key unset
        assert {:ok, :off} =
                 Repo.transaction(fn -> ScopeEnforcement.mode_under_lock!(fx.schema_name) end)
      end)
    end
  end

  describe "T-L5 the key lives in config/test.exs only" do
    test "its text occurs in no config file but test.exs, in no mix.exs / rel file, and in no OS-environment read" do
      files = Path.wildcard("config/*.exs") ++ ["mix.exs"] ++ Path.wildcard("rel/**/*.exs")
      carriers = for f <- files, File.read!(f) =~ @key_text, do: Path.basename(f)
      assert carriers == ["test.exs"]

      refute File.read!("config/runtime.exs") =~
               ~r/System\.(get_env|fetch_env)[^\n]*scope_mode_lenient/i
    end

    test "under lib/ the key is READ in exactly one place and SET nowhere" do
      holders = for f <- Path.wildcard("lib/**/*.ex"), File.read!(f) =~ @key_text, do: f

      assert holders == ["lib/letflow/scope_enforcement.ex"]

      source = File.read!("lib/letflow/scope_enforcement.ex")
      refute source =~ ~r/put_env\([^)]*#{@key_text}/
      refute source =~ ~r/Application\.put_env\(:letflow, :#{@key_text}/
      assert length(Regex.scan(~r/Application\.get_env\(:letflow, :#{@key_text}/, source)) == 1
    end
  end

  # ===========================================================================================
  describe "T-L6 with the key set the same two cases return :off and log the constant line" do
    setup do
      # The constant line is Logger.warning; make the assertion independent of LOG_LEVEL.
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    test "malformed prefix and unregistered prefix: :off, one scope_mode_read_lenient line, no prefix in it" do
      fx = tenant!("req519-l6", :on)
      assert Application.get_env(:letflow, @key) == true
      unregistered = random_tenant_schema()

      for prefix <- ["rsg_" <> String.duplicate("b", 32), unregistered] do
        log =
          capture_log(fn ->
            assert {:ok, :off} =
                     Repo.transaction(fn -> ScopeEnforcement.mode_under_lock!(prefix) end)
          end)

        lines = log |> String.split(~r/\R/) |> Enum.filter(&(&1 =~ "scope_mode_read_lenient"))
        assert length(lines) == 1

        for line <- lines do
          refute line =~ prefix
          refute line =~ String.replace_prefix(unregistered, "tenant_", "")
        end
      end

      # A REGISTERED tenant is never lenient: its stored mode wins and nothing is logged.
      log =
        capture_log(fn ->
          assert {:ok, :on} =
                   Repo.transaction(fn -> ScopeEnforcement.mode_under_lock!(fx.schema_name) end)
        end)

      refute log =~ "scope_mode_read_lenient"
    end
  end

  # ===========================================================================================
  describe "T-L7 (C-2) a raised mode read rolls the write back and never proceeds as off" do
    test "upsert_role: no binding, no row, no audit entry, a detail-free transaction_failed" do
      fx = tenant!("req519-l7a", :off)
      s = fx.schema_name
      g = group!(fx)
      ids = entry_ids(s)

      with_unregistered_schema(fx, fn renamed ->
        with_key(:unset, fn ->
          assert {:error, {:transaction_failed, %ModeUnavailableError{}}} =
                   RoleRegistry.upsert_role_report("PROCESS_DESIGNER", :platform_role, g.id,
                     prefix: renamed
                   )
        end)
      end)

      assert binding(s, "PROCESS_DESIGNER") == nil
      assert rows(s) == []
      assert new_entries(s, ids) == []
    end

    test "the repair of a binding with no row does NOT insert one (not off), and nothing is written" do
      fx = seeded_tenant!("req519-l7b", :off)
      s = fx.schema_name
      g = group_of!(s, "TASK_WORKER")
      assert raw_delete_rows!(s, g, "TASK_WORKER") == 1
      ids = entry_ids(s)

      with_unregistered_schema(fx, fn renamed ->
        with_key(:unset, fn ->
          assert {:error, {:transaction_failed, %ModeUnavailableError{}}} =
                   RoleRegistry.upsert_role_report("TASK_WORKER", :platform_role, g,
                     prefix: renamed
                   )
        end)
      end)

      refute tw(g, "TASK_WORKER") in rows(s)
      assert RoleScopeGrants.bindings_without_row_count(s) == 1
      assert new_entries(s, ids) == []
    end

    test "rebind_role: the binding stays on its group, no row written, no audit entry" do
      fx = tenant!("req519-l7c", :off)
      s = fx.schema_name
      g = group!(fx)
      target = group!(fx)
      role = raw_binding!(s, "PROCESS_DESIGNER", :platform_role, g.id)
      ids = entry_ids(s)

      with_unregistered_schema(fx, fn renamed ->
        with_key(:unset, fn ->
          assert {:error, {:transaction_failed, %ModeUnavailableError{}}} =
                   RoleRegistry.rebind_role_report(
                     role.id,
                     target.id,
                     %{actor_id: nil, reason: "REQ-519 C-2"},
                     prefix: renamed
                   )
        end)
      end)

      assert %TenantRole{group_id: group_id} = binding(s, "PROCESS_DESIGNER")
      assert group_id == g.id
      assert rows(s) == []
      assert new_entries(s, ids) == []
    end

    test "seeding: the error is returned, no binding and no row exists for the failing name" do
      fx = tenant!("req519-l7d", :off)
      s = fx.schema_name
      ids = entry_ids(s)

      with_unregistered_schema(fx, fn renamed ->
        with_key(:unset, fn ->
          assert {:error, {:transaction_failed, %ModeUnavailableError{}}} =
                   RoleRegistry.seed_default_platform_role_groups_report(prefix: renamed)
        end)
      end)

      assert Repo.aggregate(TenantRole, :count, prefix: s) == 0
      assert rows(s) == []
      assert new_entries(s, ids) == []
    end

    test "Backfill.run_tenant: raises, inserts no row although a gap exists, writes no audit entry" do
      fx = seeded_tenant!("req519-l7e", :off)
      s = fx.schema_name
      g = group_of!(s, "TENANT_AUDITOR")
      assert raw_delete_rows!(s, g, "TENANT_AUDITOR") == 1
      ids = entry_ids(s)

      with_unregistered_schema(fx, fn renamed ->
        with_key(:unset, fn ->
          assert_raise ModeUnavailableError, fn -> Backfill.run_tenant(renamed, []) end
        end)
      end)

      assert RoleScopeGrants.bindings_without_row_count(s) == 1
      refute tw(g, "TENANT_AUDITOR") in rows(s)
      assert new_entries(s, ids) == []
    end
  end

  describe "T-L7f Backfill reads the mode itself, not only through its inner repair" do
    test "a tenant WITHOUT a gap still raises on an unreadable mode (kills a rescue-to-off at the sweep level)" do
      fx = seeded_tenant!("req519-l7f", :off)
      s = fx.schema_name
      assert_t9_zero!(s)
      ids = entry_ids(s)

      with_unregistered_schema(fx, fn renamed ->
        with_key(:unset, fn ->
          assert_raise ModeUnavailableError, fn -> Backfill.run_tenant(renamed, []) end
        end)
      end)

      assert new_entries(s, ids) == []
    end
  end

  describe "T-L8 removal never reads the mode" do
    test "with an unreadable mode a platform -> routing removal and a P -> nil reconcile still go through" do
      fx = tenant!("req519-l8", :off)
      s = fx.schema_name
      g = group!(fx)
      other = group!(fx)

      {:ok, _role, :in_place} =
        RoleRegistry.upsert_role_report("AGENT_RUNNER", :platform_role, g.id, prefix: s)

      pa = raw_binding!(s, "PROCESS_DESIGNER", :platform_role, other.id)
      :ok = raw_tenant_wide_row!(s, other.id, "PROCESS_DESIGNER")

      with_unregistered_schema(fx, fn renamed ->
        with_key(:unset, fn ->
          assert {:ok, %TenantRole{kind: :process_routing_role}, :in_place} =
                   RoleRegistry.upsert_role_report("AGENT_RUNNER", :process_routing_role, g.id,
                     prefix: renamed
                   )

          assert {:ok, :ok} =
                   Repo.transaction(fn ->
                     RoleScopeGrants.reconcile_binding!(pa, nil, renamed)
                   end)
        end)
      end)

      assert rows(s) == []
    end
  end

  # ===========================================================================================
  describe "T-L2 / T-L3 serialisation with the flip on lock A (AC 6)" do
    setup do
      Locks.attach_error_handler(:req519_lock)
      :ok
    end

    # A transaction on its own connection that holds lock A until released.
    defp hold_lock_a!(schema) do
      test_pid = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            :ok = Identity.lock_tenant_admins!(schema)
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(test_pid, {:lock_a_held, backend})

            receive do
              :release -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)

      on_exit(fn -> send(holder.pid, :release) end)
      assert_receive {:lock_a_held, backend}, 10_000
      {holder, backend}
    end

    # The flip's core, in flip/4's order: lock A, read the facts, set the stored mode.
    defp flipper(fx) do
      fn ->
        Repo.transaction(fn ->
          :ok = Identity.lock_tenant_admins!(fx.schema_name)
          report = ScopeEnforcement.preconditions(fx.schema_name)

          seen =
            Repo.exists?(
              from(t in TenantRole, where: t.name == "PROCESS_DESIGNER"),
              prefix: fx.schema_name
            )

          :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)
          %{bindings_without_row: report.bindings_without_row, binding_visible: seen}
        end)
      end
    end

    defp writer(fx, group_id) do
      fn ->
        RoleRegistry.upsert_role_report("PROCESS_DESIGNER", :platform_role, group_id,
          prefix: fx.schema_name
        )
      end
    end

    defp queue_two!(fx, first, second) do
      {holder, barrier_pid} = hold_lock_a!(fx.schema_name)

      {t1, pid1} = Locks.start_worker(first)
      Locks.wait_for_blocked([pid1], 1)
      assert barrier_pid in Locks.blockers(pid1)

      {t2, pid2} = Locks.start_worker(second)
      Locks.wait_for_blocked([pid1, pid2], 2)
      # the second worker is queued behind the barrier or behind the first
      assert Enum.any?(Locks.blockers(pid2), &(&1 in [barrier_pid, pid1]))

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, Locks.await_ms())
      {r1, _} = Task.await(t1, Locks.await_ms())
      {r2, _} = Task.await(t2, Locks.await_ms())
      refute_receive {:deadlock_detected, _}, 0
      {r1, r2}
    end

    test "T-L2 the writer queued FIRST: its binding and row are committed before the flip, which sees them" do
      fx = tenant!("req519-l2", :off)
      s = fx.schema_name
      g = group!(fx)

      {write_result, flip_result} = queue_two!(fx, writer(fx, g.id), flipper(fx))

      assert {:ok, %TenantRole{}, :in_place} = write_result
      assert {:ok, %{bindings_without_row: 0, binding_visible: true}} = flip_result
      assert stored_mode(fx) == "on"
      assert rows(s) == [tw(g.id, "PROCESS_DESIGNER")]
      assert_t9_zero!(s)
      assert entries(s, "binding.refused") == []
    end

    test "T-L3 the flip queued FIRST: the writer acquires A afterwards, sees on and refuses" do
      fx = tenant!("req519-l3", :off)
      s = fx.schema_name
      g = group!(fx)

      {flip_result, write_result} = queue_two!(fx, flipper(fx), writer(fx, g.id))

      assert {:ok, %{bindings_without_row: 0, binding_visible: false}} = flip_result
      assert write_result == {:error, :scope_required}
      assert stored_mode(fx) == "on"
      assert binding(s, "PROCESS_DESIGNER") == nil
      assert rows(s) == []
      assert [_refusal] = entries(s, "binding.refused")
    end
  end
end
