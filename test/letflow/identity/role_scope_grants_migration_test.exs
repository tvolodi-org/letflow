defmodule Letflow.Identity.RoleScopeGrantsMigrationTest do
  @moduledoc """
  REQ-497 / GH #2533 PR 1a, AC1: the tenant-scoped migration `CreateRoleScopeGrants`
  (`priv/repo/migrations/20261015025331_create_role_scope_grants.exs`; design
  `lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` sections 1 and 6.1,
  T-M1..T-M6; spec `test/specs/REQ-497-1a.md`).

  T-M1 and T-M5 are the only proof of the POPULATED-tenant backfill and its audit entry: a fixture
  tenant already has the table (it was migrated with 0 bindings), so the test rolls the migration
  `:down`, seeds bindings the way pre-release data holds them (raw `tenant_role` rows, no writer),
  and runs it `:up` again, exactly as `TenantProvisioning.replay_migrations/2` would on deploy.

  Runs `Ecto.Migrator.run/4` with the tenant prefix and raw DDL against a dedicated (never pooled)
  tenant schema, so `async: false`; the fixture teardown drops the schema either way.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Audit
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.TenantRole
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @gap_version 99_991_015_025_331
  @gap_migration Letflow.Test.RoleScopeGrantsGapMigration
  @platform_names ["PROCESS_DESIGNER", "TASK_WORKER", "TENANT_ADMIN"]
  @routing_names ["rsg-route-a", "rsg-route-b"]
  @after_state_keys [
    "bindings_without_row_after",
    "group_rows_inserted",
    "migration_version",
    "platform_role_bindings",
    "process_routing_bindings_skipped",
    "source",
    "user_rows_inserted"
  ]

  setup do
    # Loads every manifest migration module (they are not compiled into the app).
    migrations = TenantProvisioning.tenant_scoped_migrations()
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req497-mig")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id, migrations: migrations}
  end

  # Rolls the migration down and seeds 3 platform + 2 routing bindings RAW, with members in a
  # platform group and a routing group: a tenant as it stood before this deploy.
  defp populate_pre_release!(schema) do
    assert migrate!(schema, :down) == [version()]
    assert regclass(schema, "role_scope_grants") == nil

    platform =
      for name <- @platform_names do
        g = fresh_group!(schema)
        raw_binding!(schema, name, :platform_role, g.id)
      end

    routing =
      for name <- @routing_names do
        g = fresh_group!(schema)
        raw_binding!(schema, name, :process_routing_role, g.id)
      end

    member!(schema, hd(platform).group_id, user!(schema))
    member!(schema, hd(platform).group_id, user!(schema))
    member!(schema, hd(routing).group_id, user!(schema))

    %{platform: platform, routing: routing}
  end

  defp tenant_role_snapshot(schema) do
    Repo.all(from(t in TenantRole, order_by: t.id, select: {t.id, t.name, t.kind, t.group_id}),
      prefix: schema
    )
  end

  defp expected_rows(platform),
    do: platform |> Enum.map(&tw(&1.group_id, &1.name)) |> Enum.sort()

  defp schema_migration_versions(schema) do
    Repo.all(from(m in "schema_migrations", select: m.version), prefix: schema)
  end

  defp raw_insert(schema, type, group_id, role, node, tenant_wide) do
    Repo.query(
      ~s|INSERT INTO "#{schema}".role_scope_grants | <>
        ~s|(id, principal_type, principal_id, role, scope_node_id, tenant_wide, | <>
        ~s|inserted_at, updated_at) | <>
        ~s|VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, now(), now())|,
      [type, Ecto.UUID.dump!(group_id), role, node, tenant_wide]
    )
  end

  defp constraint_count(schema, contype) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
         WHERE n.nspname = $1 AND t.relname = 'role_scope_grants' AND c.contype = $2
        """,
        [schema, contype]
      )

    n
  end

  defp indexes(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [schema, "role_scope_grants"]
      )

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  # ===========================================================================================
  describe "T-M1 / T-M5 / T-M6: populated tenant backfill, audit and reversibility" do
    test "N platform bindings become N tenant-wide group rows, 0 user rows, 0 routing rows; one counts-only audit entry; down/up restores the same set",
         %{schema: schema, tenant_id: tenant_id} do
      %{platform: platform, routing: routing} = populate_pre_release!(schema)
      roles_before = tenant_role_snapshot(schema)
      assert entries(schema, "scope.backfill_completed") == []

      assert migrate!(schema, :up) == [version()]

      # T-M1: exactly one tenant-wide GROUP row per :platform_role binding.
      rows = rows(schema)
      assert length(rows) == 3
      assert rows == expected_rows(platform)

      assert Enum.all?(rows, fn {type, _, _, node, tw?} ->
               type == :group and node == nil and tw?
             end)

      assert RoleScopeGrants.user_row_count(schema) == 0
      routing_names = Enum.map(routing, & &1.name)
      refute Enum.any?(rows, fn {_, _, role, _, _} -> role in routing_names end)
      routing_groups = Enum.map(routing, & &1.group_id)
      refute Enum.any?(rows, fn {_, pid, _, _, _} -> pid in routing_groups end)
      assert_t9_zero!(schema)
      assert tenant_role_snapshot(schema) == roles_before

      # T-M5: exactly one entry, counts and a version only.
      assert [entry] = entries(schema, "scope.backfill_completed")
      assert entry.actor_id == nil
      assert entry.resource_type == "role_scope_grants"
      assert entry.resource_id == tenant_id
      assert entry.before_state == nil
      assert entry.trace_id == nil
      assert entry.after_state |> Map.keys() |> Enum.sort() == @after_state_keys

      assert entry.after_state == %{
               "source" => "migration",
               "migration_version" => 20_261_015_025_331,
               "platform_role_bindings" => 3,
               "group_rows_inserted" => 3,
               "user_rows_inserted" => 0,
               "process_routing_bindings_skipped" => 2,
               "bindings_without_row_after" => 0
             }

      # INV-4: no role name or group id anywhere in the entry's state.
      text = inspect(entry.after_state)
      for b <- platform ++ routing, do: refute(text =~ b.name or text =~ b.group_id)
      assert {:ok, :valid} = Audit.verify_chain(schema)

      # T-M6: down drops the table and leaves the bindings; up restores exactly the same set.
      assert migrate!(schema, :down) == [version()]
      assert regclass(schema, "role_scope_grants") == nil
      assert tenant_role_snapshot(schema) == roles_before

      assert migrate!(schema, :up) == [version()]
      assert rows(schema) == expected_rows(platform)
      assert_t9_zero!(schema)
      assert {:ok, :valid} = Audit.verify_chain(schema)
    end

    test "a re-applied backfill is idempotent: the insert is ON CONFLICT DO NOTHING", %{
      schema: schema
    } do
      %{platform: platform} = populate_pre_release!(schema)
      assert migrate!(schema, :up) == [version()]

      # Re-run the backfill inside one transaction under lock A (as the migration does).
      {:ok, counts} =
        Repo.transaction(fn ->
          :ok = migration().lock_tenant_admins_in_migration!(schema)
          migration().run_backfill!(schema)
        end)

      assert counts.platform_role_bindings == 3
      assert counts.group_rows_inserted == 0
      assert counts.user_rows_inserted == 0
      assert counts.bindings_without_row_after == 0
      assert rows(schema) == expected_rows(platform)
    end

    test "T-M5: a tenant provisioned by a REAL replay (0 bindings at replay) has the empty table and no backfill entry" do
      replayed =
        TenantFixture.provisioned_tenant!(slug_prefix: "req497-replay", template: :replay)

      assert regclass(replayed.schema_name, "role_scope_grants") != nil
      assert rows(replayed.schema_name) == []
      assert entries(replayed.schema_name, "scope.backfill_completed") == []
      assert version() in schema_migration_versions(replayed.schema_name)
    end

    test "T-M6: the manifest registers the migration and stays sorted by version", %{
      migrations: migrations
    } do
      assert {version(), migration()} in migrations
      versions = Enum.map(migrations, &elem(&1, 0))
      assert versions == Enum.sort(versions)
      assert versions == Enum.uniq(versions)
    end
  end

  # ===========================================================================================
  describe "T-M2: the frozen T9 assert" do
    test "T-M2a: assert_no_gap!/1 raises with the count only, inside a transaction that then rolls back",
         %{schema: schema} do
      %{platform: [first | _] = platform} = populate_pre_release!(schema)
      assert migrate!(schema, :up) == [version()]

      assert {:error, :checked} =
               Repo.transaction(fn ->
                 assert raw_delete_rows!(schema, first.group_id, first.name) == 1

                 error =
                   assert_raise RuntimeError, fn -> migration().assert_no_gap!(schema) end

                 assert String.starts_with?(error.message, "role_scope_grants backfill gap:")
                 assert error.message == "role_scope_grants backfill gap: 1"

                 for b <- platform do
                   refute error.message =~ b.name
                   refute error.message =~ b.group_id
                 end

                 Repo.rollback(:checked)
               end)

      # Rolled back: the row is back.
      assert rows(schema) == expected_rows(platform)
      assert migration().assert_no_gap!(schema) == :ok
    end

    test "T-M2b: a gap inside the migration transaction aborts it whole: no table, no version, bindings unchanged, no audit entry",
         %{schema: schema} do
      %{platform: platform} = populate_pre_release!(schema)
      roles_before = tenant_role_snapshot(schema)

      error =
        assert_raise RuntimeError, fn ->
          Ecto.Migrator.run(Repo, [{@gap_version, @gap_migration}], :up,
            all: true,
            prefix: schema,
            log: false
          )
        end

      assert error.message == "role_scope_grants backfill gap: 1"

      # The DDL, the rows and the audit entry written by the real run_backfill!/1 are all gone.
      assert regclass(schema, "role_scope_grants") == nil
      refute @gap_version in schema_migration_versions(schema)
      refute version() in schema_migration_versions(schema)
      assert tenant_role_snapshot(schema) == roles_before
      assert entries(schema, "scope.backfill_completed") == []

      # The tenant is made whole by the real migration.
      assert migrate!(schema, :up) == [version()]
      assert rows(schema) == expected_rows(platform)
      assert_t9_zero!(schema)
    end
  end

  # ===========================================================================================
  describe "T-M3 / T-M4: constraints and indexes" do
    test "T-M3: the tenant_wide XOR node CHECK, the principal_type CHECK, the tenant-wide unique index; the scope-node FK arrived with REQ-517 PR 2a",
         %{schema: schema} do
      node = node!(schema)
      gid = Ecto.UUID.generate()

      # (a) tenant_wide + node set
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation} = pg}} =
               raw_insert(schema, "group", gid, "TASK_WORKER", node, true)

      assert pg.constraint == "role_scope_grants_tenant_wide_xor_node"

      # (b) not tenant_wide + NULL node
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation} = pg}} =
               raw_insert(schema, "group", gid, "TASK_WORKER", nil, false)

      assert pg.constraint == "role_scope_grants_tenant_wide_xor_node"

      # (c) positive control: scoped at an existing node
      assert {:ok, %{num_rows: 1}} = raw_insert(schema, "group", gid, "TASK_WORKER", node, false)

      # (d) principal_type outside {user, group}
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation} = pg}} =
               raw_insert(schema, "token", gid, "TASK_WORKER", nil, true)

      assert pg.constraint == "role_scope_grants_principal_type_check"

      # (e) REQ-517 PR 2a (#2535) added the one FOREIGN KEY (scope_node_id -> scope_node_paths,
      # ON DELETE RESTRICT); the two CHECKs are still there.
      assert constraint_count(schema, "f") == 1
      assert constraint_count(schema, "c") == 2
      # A node id that does not exist is now refused by the FK.
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation} = pg}} =
               raw_insert(schema, "group", gid, "TASK_WORKER", "rsg-no-such-node", false)

      assert pg.constraint == "role_scope_grants_scope_node_id_fkey"

      # (f) a second tenant-wide row for the same (principal, role)
      assert {:ok, %{num_rows: 1}} = raw_insert(schema, "group", gid, "TENANT_ADMIN", nil, true)

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation} = pg}} =
               raw_insert(schema, "group", gid, "TENANT_ADMIN", nil, true)

      assert pg.constraint == "role_scope_grants_tenant_wide_uniq"

      # The same principal and role at the same node twice is refused too.
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation} = pg}} =
               raw_insert(schema, "group", gid, "TASK_WORKER", node, false)

      assert pg.constraint == "role_scope_grants_scoped_uniq"

      # tenant_wide has no default: a writer must state it.
      assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
               Repo.query(
                 ~s|INSERT INTO "#{schema}".role_scope_grants | <>
                   ~s|(id, principal_type, principal_id, role, inserted_at, updated_at) | <>
                   ~s|VALUES (gen_random_uuid(), 'group', $1, 'CANDIDATE', now(), now())|,
                 [Ecto.UUID.dump!(gid)]
               )
    end

    test "T-M4: the D3 lookup index and both partial unique indexes exist with their definitions",
         %{schema: schema} do
      idx = indexes(schema)

      assert idx["role_scope_grants_principal_role_idx"] =~ "(principal_type, principal_id, role)"
      refute idx["role_scope_grants_principal_role_idx"] =~ "UNIQUE"

      assert idx["role_scope_grants_tenant_wide_uniq"] =~ "UNIQUE"
      assert idx["role_scope_grants_tenant_wide_uniq"] =~ "(principal_type, principal_id, role)"
      assert idx["role_scope_grants_tenant_wide_uniq"] =~ "WHERE tenant_wide"

      assert idx["role_scope_grants_scoped_uniq"] =~ "UNIQUE"

      assert idx["role_scope_grants_scoped_uniq"] =~
               "(principal_type, principal_id, role, scope_node_id)"

      assert idx["role_scope_grants_scoped_uniq"] =~ "NOT tenant_wide"

      assert idx["role_scope_grants_scope_node_id_idx"] =~ "(scope_node_id)"
      assert idx["role_scope_grants_scope_node_id_idx"] =~ "scope_node_id IS NOT NULL"
    end
  end
end
