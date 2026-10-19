defmodule Letflow.Support.BreakGlassFixture do
  @moduledoc """
  Test support for GH #2883 (the operator break-glass, design
  `lib/letflow/design/gh2883-scope-enforcement-break-glass.md` section 5; spec
  `test/specs/GH2883-break-glass.md`): tenants stored `on` that clean up after themselves, the
  held-lock helpers of the lock-order tests, a row snapshot for the "changes only the flag"
  proof, and the two ways to make the audit write fail.

    * `on_tenant!/1` -- `OnGateFixture.admin_tenant!/1` flipped `off -> shadow` through the
      REAL `flip/4` (a genuine shadow start T0 and a valid audit chain), then stored `on` by a
      direct SQL update. An `on_exit` puts the stored mode back to `off` BEFORE the tenant
      fixture teardown, so a failing test never leaves a committed `on` tenant behind (the
      migration-down tests refuse to roll back while any tenant is `on`);
    * `bare_on_tenant!/1` -- a provisioned tenant with NO user at all, stored `on`;
    * `register_cleanup/1`, `hold_lock_a!/1`, `hold_tenant_row!/1`, `queue_two!/3`;
    * `snapshot/1` -- a content hash and row count of every identity table the break-glass must
      not touch, plus the `tenants` row without its flag and `updated_at`;
    * `with_unwritable_audit/2` -- the audit insert returns `{:error, _}` (not a raise);
    * `with_env/3` re-exported from `OnGateFixture`.

  The tenant fixture leaves the sandbox in `:auto` mode (real commits), so every caller is
  `async: false`. Nothing here is compiled outside `:test`.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.LockOrderHelpers, as: Locks
  alias Letflow.Repo
  alias Letflow.Support.EnforcedWritersFixture, as: EW
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.ScopeEnforcementFixture

  @slug_prefix "gh2883-"
  @tables ~w(users groups group_members tenant_role role_scope_grants api_tokens scope_node_paths)

  @doc "The slug prefix of every tenant of the GH #2883 tests (for the stale-tenant purge)."
  @spec slug_prefix() :: String.t()
  def slug_prefix, do: @slug_prefix

  @doc "Heals the committed `on` leftovers of an earlier KILLED run of these tests."
  @spec purge_stale!() :: :ok
  def purge_stale! do
    _ = EW.purge_stale_enforced_tenants!(@slug_prefix)
    :ok
  end

  @doc "An admin tenant with a real shadow start, stored `on`; cleaned up by an `on_exit`."
  @spec on_tenant!(String.t()) :: map()
  def on_tenant!(slug_suffix) do
    fx = F.admin_tenant!(@slug_prefix <> slug_suffix)
    _ = F.flip!(fx, :shadow, nil)
    :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)
    register_cleanup(fx)
  end

  @doc "A provisioned tenant with NO user, stored `on`; cleaned up by an `on_exit`."
  @spec bare_on_tenant!(String.t()) :: map()
  def bare_on_tenant!(slug_suffix) do
    fx = EW.tenant!(@slug_prefix <> slug_suffix, :on)
    register_cleanup(fx)
  end

  @doc "Registers the `on_exit` that stores the tenant `off` again (idempotent, never raises)."
  @spec register_cleanup(map()) :: map()
  def register_cleanup(%{tenant_id: tenant_id} = fx) do
    on_exit(fn ->
      try do
        {:ok, id} = Ecto.UUID.dump(tenant_id)

        Repo.query!(
          "UPDATE tenants SET scope_enforcement = 'off' WHERE id = $1 AND scope_enforcement = 'on'",
          [id]
        )
      rescue
        _exception -> :ok
      end
    end)

    fx
  end

  @doc "The stored mode as the raw string."
  @spec mode(map()) :: String.t()
  def mode(fx), do: EW.stored_mode(fx)

  @doc "The number of audit entries of the tenant schema."
  @spec entry_count(map()) :: non_neg_integer()
  def entry_count(fx), do: Repo.aggregate(Entry, :count, prefix: fx.schema_name)

  @doc "The raw `updated_at` of the `tenants` row (a dry run must leave it alone)."
  @spec updated_at(map()) :: term()
  def updated_at(%{tenant_id: tenant_id}) do
    {:ok, id} = Ecto.UUID.dump(tenant_id)
    %{rows: [[updated_at]]} = Repo.query!("SELECT updated_at FROM tenants WHERE id = $1", [id])
    updated_at
  end

  @doc "Runs `fun` with the application key set (`:unset` removes it) and restores it afterwards."
  @spec with_env(atom(), term(), (-> term())) :: term()
  def with_env(key, value, fun), do: F.with_env(key, value, fun)

  @doc """
  A content snapshot of everything the break-glass must NOT change: per identity table of the
  tenant schema an md5 over the row texts and the row count; the `tenants` row without
  `scope_enforcement` and `updated_at`; the registration row.
  """
  @spec snapshot(map()) :: map()
  def snapshot(fx) do
    {:ok, id} = Ecto.UUID.dump(fx.tenant_id)

    tables =
      Map.new(@tables, fn table ->
        %{rows: [[hash, count]]} =
          Repo.query!(
            ~s|SELECT coalesce(md5(string_agg(x::text, ';' ORDER BY x::text)), ''), count(*) | <>
              ~s|FROM "#{fx.schema_name}"."#{table}" x|
          )

        {table, {hash, count}}
      end)

    %{rows: [[tenant_row]]} =
      Repo.query!(
        "SELECT (to_jsonb(t) - 'scope_enforcement' - 'updated_at')::text FROM tenants t WHERE t.id = $1",
        [id]
      )

    %{rows: registration} =
      Repo.query!("SELECT schema_name FROM tenant_schemas WHERE tenant_id = $1", [id])

    # no GLOBAL row count (a concurrent session may add or drop other tenants)
    %{tables: tables, tenant_row: tenant_row, registration: registration}
  end

  @doc "The row count of one identity table of the tenant schema."
  @spec count(map(), String.t()) :: non_neg_integer()
  def count(fx, table) when table in @tables do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{fx.schema_name}"."#{table}"|)
    n
  end

  @doc "A transaction on its own connection that holds lock A until `:release` is sent to it."
  @spec hold_lock_a!(String.t()) :: {Task.t(), pos_integer()}
  def hold_lock_a!(schema) do
    hold(fn -> Identity.lock_tenant_admins!(schema) end)
  end

  @doc "A transaction on its own connection that holds the `tenants` row `FOR UPDATE`."
  @spec hold_tenant_row!(Ecto.UUID.t()) :: {Task.t(), pos_integer()}
  def hold_tenant_row!(tenant_id) do
    {:ok, id} = Ecto.UUID.dump(tenant_id)

    hold(fn ->
      %{num_rows: 1} = Repo.query!("SELECT 1 FROM tenants WHERE id = $1 FOR UPDATE", [id])
    end)
  end

  @doc """
  Like `hold_tenant_row!/1`, but the holder also stores `mode` (`"off"` or `"shadow"`) on the
  row WITHOUT committing: the new mode becomes visible only when `release!/1` commits it.
  """
  @spec hold_tenant_row_setting!(Ecto.UUID.t(), String.t()) :: {Task.t(), pos_integer()}
  def hold_tenant_row_setting!(tenant_id, mode) when mode in ["off", "shadow"] do
    {:ok, id} = Ecto.UUID.dump(tenant_id)

    hold(fn ->
      %{num_rows: 1} =
        Repo.query!("UPDATE tenants SET scope_enforcement = $2 WHERE id = $1", [id, mode])
    end)
  end

  defp hold(acquire) do
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          acquire.()
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(test_pid, {:bg_held, backend})

          receive do
            :release -> :ok
          after
            20_000 -> :timeout
          end
        end)
      end)

    on_exit(fn -> send(holder.pid, :release) end)
    assert_receive {:bg_held, backend}, 10_000
    {holder, backend}
  end

  @doc "Releases a holder from `hold_lock_a!/1`, `hold_tenant_row!/1` or `LockOrderHelpers.hold_row/2`."
  @spec release!(Task.t()) :: :ok
  def release!(holder) do
    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, Locks.await_ms())
    :ok
  end

  @doc """
  Queues two workers behind lock A (held by a barrier) in a fixed order: starts `first`, waits
  until it is blocked, starts `second`, waits until both are blocked, releases the barrier and
  returns both results (`{first_result, second_result}`).
  """
  @spec queue_two!(String.t(), (-> term()), (-> term())) :: {term(), term()}
  def queue_two!(schema, first, second) do
    {holder, barrier_pid} = hold_lock_a!(schema)

    {t1, pid1} = Locks.start_worker(first)
    Locks.wait_for_blocked([pid1], 1)
    assert barrier_pid in Locks.blockers(pid1)

    {t2, pid2} = Locks.start_worker(second)
    Locks.wait_for_blocked([pid1, pid2], 2)
    assert Enum.any?(Locks.blockers(pid2), &(&1 in [barrier_pid, pid1]))

    release!(holder)

    {r1, _done1} = Task.await(t1, Locks.await_ms())
    {r2, _done2} = Task.await(t2, Locks.await_ms())
    {r1, r2}
  end

  @doc """
  Makes `Letflow.Audit.insert_entry/3` answer `{:error, :invalid_schema_name}` (a returned error,
  not a raise) for the tenant: the schema is renamed to a name that is not `tenant_<32 hex>` and
  the registration row is pointed at it (raw SQL, committed). Both are restored afterwards and by
  an `on_exit` (a killed test process must not leave a renamed schema behind).
  """
  @spec with_unwritable_audit(map(), (-> term())) :: term()
  def with_unwritable_audit(fx, fun) do
    plain = "gh2883_plain_#{System.unique_integer([:positive])}"
    {:ok, id} = Ecto.UUID.dump(fx.tenant_id)

    Repo.query!(~s|ALTER SCHEMA "#{fx.schema_name}" RENAME TO "#{plain}"|)

    Repo.query!("UPDATE tenant_schemas SET schema_name = $1 WHERE tenant_id = $2", [plain, id])

    on_exit(fn -> restore_schema(plain, fx.schema_name, id) end)

    try do
      fun.()
    after
      restore_schema(plain, fx.schema_name, id)
    end
  end

  defp restore_schema(plain, schema_name, id) do
    %{rows: rows} = Repo.query!("SELECT 1 FROM pg_namespace WHERE nspname = $1", [plain])
    if rows != [], do: Repo.query!(~s|ALTER SCHEMA "#{plain}" RENAME TO "#{schema_name}"|)

    Repo.query!("UPDATE tenant_schemas SET schema_name = $1 WHERE tenant_id = $2", [
      schema_name,
      id
    ])

    :ok
  end
end
