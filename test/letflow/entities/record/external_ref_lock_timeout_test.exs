defmodule Letflow.Entities.Record.ExternalRefLockTimeoutTest do
  @moduledoc """
  GH #2659 / REQ-505 PR-1, design section 12: migration (a) fails fast under a conflicting lock.

  The holder and the migrating session must be DIFFERENT database connections, otherwise a
  session never conflicts with its own lock. This file therefore enters sandbox `:auto` mode
  explicitly (`SandboxAutoMode.enter_auto_mode!/1`, restored last by `exit_auto_mode!/1`) so every
  process checks out its own real pool connection, and the test PROVES the two-connection shape
  instead of assuming it: it asserts the holder and migrator backend pids differ and that
  `pg_blocking_pids/1` of the waiting migrator contains the holder's pid.

  Everything is committed in `:auto` mode; the tenant fixture's own teardown drops the committed
  tenant, and the holder is released in `on_exit` so a mid-test failure cannot leak it.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.Test.SandboxAutoMode

  @cols_version 20_261_019_100_001
  @cols_migration Letflow.Repo.Migrations.AddExternalRefColumnsToEntityRecordLatest
  @idx_version 20_261_019_100_002
  @idx_migration Letflow.Repo.Migrations.AddExternalRefIndexToEntityRecordLatest

  setup do
    # Registered FIRST so it runs LAST (on_exit is LIFO): after the tenant teardown below.
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    SandboxAutoMode.enter_auto_mode!(Repo)

    # Loads every manifest migration module (they are not compiled into the application).
    _ = TenantProvisioning.tenant_scoped_migrations()
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2659-lock")
    {:ok, schema: tenant.schema_name}
  end

  defp migrate(schema, version, module, direction) do
    Ecto.Migrator.run(Repo, [{version, module}], direction,
      all: true,
      prefix: schema,
      log: false
    )
  end

  defp columns(schema) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name FROM information_schema.columns
         WHERE table_schema = $1 AND table_name = 'entity_record_latest'
           AND column_name IN ('external_system', 'external_id')
        """,
        [schema]
      )

    rows
  end

  defp constraint_count(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*)::int FROM pg_constraint
         WHERE conname = 'entity_record_latest_external_ref_pair_chk'
           AND connamespace = $1::text::regnamespace
        """,
        [schema]
      )

    n
  end

  # Waits (bounded) until some backend is waiting on a lock held by `holder_pid`.
  defp blocked_by(holder_pid, attempts \\ 100) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pid, pg_blocking_pids(pid)
          FROM pg_stat_activity
         WHERE wait_event_type = 'Lock' AND $1::int = ANY (pg_blocking_pids(pid))
        """,
        [holder_pid]
      )

    cond do
      rows != [] ->
        rows

      attempts == 0 ->
        []

      true ->
        Process.sleep(50)
        blocked_by(holder_pid, attempts - 1)
    end
  end

  test "a conflicting lock held from a second connection makes migration (a) fail within the timeout and leaves the table unchanged; after release it applies",
       %{schema: schema} do
    assert [@idx_version] == migrate(schema, @idx_version, @idx_migration, :down)
    assert [@cols_version] == migrate(schema, @cols_version, @cols_migration, :down)
    assert columns(schema) == []

    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          %{rows: [[holder_backend]]} = Repo.query!("SELECT pg_backend_pid()")
          Repo.query!(~s|LOCK TABLE "#{schema}".entity_record_latest IN ACCESS SHARE MODE|)
          send(test_pid, {:lock_held, holder_backend})

          receive do
            :release -> :ok
          after
            30_000 -> :timed_out
          end
        end)
      end)

    # A mid-test failure cannot leak the holder: it is released (and rolled back) on exit.
    on_exit(fn -> send(holder.pid, :release) end)

    assert_receive {:lock_held, holder_backend}, 10_000

    started = System.monotonic_time(:millisecond)

    migrator =
      Task.async(fn ->
        try do
          migrate(schema, @cols_version, @cols_migration, :up)
        rescue
          e in Postgrex.Error -> {:raised, e}
        end
      end)

    # The migrator's migration connection is a different one than the holder's, and it is
    # actually WAITING on a lock the holder owns (not merely slow).
    blocked = blocked_by(holder_backend)
    assert [[waiting_pid, blockers]] = Enum.take(blocked, 1)
    assert waiting_pid != holder_backend
    assert holder_backend in blockers

    assert {:raised, error} = Task.await(migrator, 20_000)
    elapsed = System.monotonic_time(:millisecond) - started

    IO.puts(
      "LOCKTIMEOUT_EVIDENCE holder_pid=#{holder_backend} waiting_migrator_pid=#{waiting_pid} " <>
        "blocking_pids=#{inspect(blockers)} elapsed_ms=#{elapsed} code=#{error.postgres.code}"
    )

    assert error.postgres.code == :lock_not_available
    assert elapsed >= 4_000 and elapsed < 20_000

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)

    # Rolled back whole: nothing recorded, table unchanged.
    assert columns(schema) == []
    assert constraint_count(schema) == 0

    assert %{rows: [[0]]} =
             Repo.query!(
               ~s|SELECT count(*)::int FROM "#{schema}".schema_migrations WHERE version = $1|,
               [@cols_version]
             )

    # After release the next run applies it.
    assert [@cols_version] == migrate(schema, @cols_version, @cols_migration, :up)
    assert [@idx_version] == migrate(schema, @idx_version, @idx_migration, :up)
    assert length(columns(schema)) == 2
    assert constraint_count(schema) == 1
  end
end
