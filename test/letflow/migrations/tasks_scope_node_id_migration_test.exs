defmodule Letflow.Migrations.TasksScopeNodeIdMigrationTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2d, T-F1 (AC 12; design
  `lib/letflow/design/req518-compiler-scope-filter.md` C.1, 10.3; spec `test/specs/REQ-518-2d.md`;
  SEC code-gate step-24 MERGE CONDITION: "migration up, down, replay ... the down path has never
  been run"): the tenant-scoped migration `20261019200001_add_scope_node_id_to_tasks.exs`.

    * a CLONED tenant and a REPLAYED tenant carry the nullable `text` column
      `tasks.scope_node_id`, the foreign key `tasks_scope_node_id_fkey` to
      `scope_node_paths (node_id)` with `ON DELETE RESTRICT` (`confdeltype = 'r'`) and the
      PARTIAL index `tasks_scope_node_id_idx` (`WHERE scope_node_id IS NOT NULL`);
    * the manifest holds the migration (version `20_261_019_200_001`, NOT the design's
      `20261019100001`, which GH #2659 owns), in order, with exactly one file of that
      version on disk and the mandatory `if prefix() do` guard;
    * the foreign key does its job: an unknown node is refused, a referenced node cannot be
      deleted, NULL is accepted;
    * `down` removes index, constraint and column, is repeatable (every statement guarded) and
      is a no-op when the `tasks` table is absent (`to_regclass` guard); a replay after `down`
      restores the exact shape; a replay of a migrated tenant is a no-op;
    * no new table: a replayed tenant's table set equals `expected_tenant_tables/0` (the oracle
      is unchanged by this migration).

  Real Postgres, dedicated tenant schemas, raw DDL: `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.Support.TaskScopeFixture, as: T
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_019_200_001
  @file_name "20261019200001_add_scope_node_id_to_tasks.exs"
  @fk "tasks_scope_node_id_fkey"
  @index "tasks_scope_node_id_idx"

  # the migration module lives in priv/ and is loaded by the manifest, not compiled into the app
  defp migration, do: Module.concat(Letflow.Repo.Migrations, AddScopeNodeIdToTasks)

  setup do
    migrations = TenantProvisioning.tenant_scoped_migrations()
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r518-2d-mig")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id, migrations: migrations}
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp migrate(schema, direction) do
    Ecto.Migrator.run(Repo, [{@version, migration()}], direction,
      all: true,
      prefix: schema,
      log: false
    )
  end

  defp column(schema) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, is_nullable, column_default, character_maximum_length
          FROM information_schema.columns
         WHERE table_schema = $1 AND table_name = 'tasks' AND column_name = 'scope_node_id'
        """,
        [schema]
      )

    rows
  end

  defp fk(schema) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.confdeltype, c.confupdtype, c.convalidated, ref.relname, pg_get_constraintdef(c.oid)
          FROM pg_constraint c
          JOIN pg_namespace n ON n.oid = c.connamespace
          JOIN pg_class ref ON ref.oid = c.confrelid
         WHERE n.nspname = $1 AND c.conname = $2 AND c.contype = 'f'
        """,
        [schema, @fk]
      )

    rows
  end

  defp index_def(schema) do
    case Repo.query!("SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND indexname = $2", [
           schema,
           @index
         ]) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  defp assert_migrated(schema) do
    # nullable text, no default, no length limit
    assert [["text", "YES", nil, nil]] = column(schema)

    # ON DELETE RESTRICT ('r'), default ON UPDATE ('a'), validated, to scope_node_paths(node_id)
    assert [["r", "a", true, "scope_node_paths", definition]] = fk(schema)
    assert definition =~ "FOREIGN KEY (scope_node_id) REFERENCES"
    assert definition =~ "scope_node_paths(node_id)"
    assert definition =~ "ON DELETE RESTRICT"

    index = index_def(schema)
    assert index =~ "CREATE INDEX #{@index}"
    assert index =~ "(scope_node_id)"
    assert index =~ "WHERE (scope_node_id IS NOT NULL)"
  end

  defp assert_removed(schema) do
    assert column(schema) == []
    assert fk(schema) == []
    assert index_def(schema) == nil
  end

  # a minimal pending task (instance projection and token rows first, as the FKs need)
  defp raw_task(schema), do: T.insert_task!(%{schema_name: schema}, nil)

  defp tables(schema) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name FROM information_schema.tables
         WHERE table_schema = $1 AND table_type = 'BASE TABLE' AND table_name <> 'schema_migrations'
         ORDER BY table_name
        """,
        [schema]
      )

    rows
    |> List.flatten()
    |> Enum.reject(&TenantFixture.req376_partition_management_table?/1)
  end

  # --- the shape on a cloned and on a replayed tenant ----------------------------------------------

  describe "AC 12 shape" do
    test "a CLONED tenant has the column, the RESTRICT foreign key and the partial index", %{
      schema: schema
    } do
      assert_migrated(schema)
    end

    test "a REPLAYED tenant (the real manifest replay, no clone) has the identical shape and no new table" do
      replayed = TenantFixture.provisioned_tenant!(slug_prefix: "r518-2d-rep", template: :replay)
      assert_migrated(replayed.schema_name)

      # no new table: the oracle `expected_tenant_tables/0` is unchanged by this migration
      assert tables(replayed.schema_name) == Enum.sort(TenantFixture.expected_tenant_tables())
    end

    test "the migration is registered in order, once, and the file carries the prefix guard",
         %{migrations: migrations} do
      assert {@version, migration()} in migrations

      versions = Enum.map(migrations, &elem(&1, 0))
      assert versions == Enum.sort(versions)
      assert versions == Enum.uniq(versions)

      on_disk =
        "priv/repo/migrations"
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "20261019200001"))

      assert on_disk == [@file_name]

      source = File.read!(Path.join("priv/repo/migrations", @file_name))
      assert source =~ "if prefix() do"
      # the foreign key name fits Postgres's 63-byte identifier limit
      assert byte_size(@fk) <= 63
      assert byte_size(@index) <= 63
    end
  end

  # --- the foreign key does its job ---------------------------------------------------------------

  describe "AC 12 the foreign key" do
    test "NULL and a live node are accepted; an unknown node is a foreign_key_violation on the named constraint",
         %{schema: schema} do
      nodes = Letflow.Support.ScopeSetFixture.nodes()
      :ok = Letflow.Support.ScopeSetFixture.build_tree!(schema)

      task = raw_task(schema)
      assert T.stored_scope_node(task.id, schema) == nil

      :ok = T.set_scope_node!(task.id, nodes.a1, schema)
      assert T.stored_scope_node(task.id, schema) == nodes.a1

      :ok = T.set_scope_node!(task.id, nil, schema)
      assert T.stored_scope_node(task.id, schema) == nil

      assert_raise Postgrex.Error, ~r/foreign_key_violation|tasks_scope_node_id_fkey/, fn ->
        T.set_scope_node!(task.id, "no-such-node", schema)
      end
    end

    test "a node a task names can never be deleted (ON DELETE RESTRICT); an unreferenced node can",
         %{schema: schema} do
      nodes = Letflow.Support.ScopeSetFixture.nodes()
      :ok = Letflow.Support.ScopeSetFixture.build_tree!(schema)

      task = raw_task(schema)
      :ok = T.set_scope_node!(task.id, nodes.b1, schema)

      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation, constraint: @fk}}} =
               Repo.query(~s|DELETE FROM "#{schema}".scope_node_paths WHERE node_id = $1|, [
                 nodes.b1
               ])

      # the task still names the node
      assert T.stored_scope_node(task.id, schema) == nodes.b1

      # an unreferenced leaf is not blocked by the new constraint
      assert {:ok, %{num_rows: 1}} =
               Repo.query(~s|DELETE FROM "#{schema}".scope_node_paths WHERE node_id = $1|, [
                 nodes.a3
               ])
    end
  end

  # --- down, repeatable, guarded; replay ------------------------------------------------------------

  describe "AC 12 down and replay (the down path had never been run)" do
    test "down removes index, constraint and column; a replay restores the exact shape", %{
      schema: schema,
      tenant_id: tenant_id
    } do
      assert [@version] == migrate(schema, :down)
      assert_removed(schema)

      assert {:ok, [@version]} = TenantProvisioning.replay_migrations(tenant_id)
      assert_migrated(schema)

      # an already-migrated tenant: a whole-manifest replay is a no-op
      assert {:ok, []} = TenantProvisioning.replay_migrations(tenant_id)
      assert_migrated(schema)
    end

    test "down is repeatable: every statement is guarded (second run with the version row restored)",
         %{schema: schema} do
      assert [@version] == migrate(schema, :down)

      Repo.query!(
        ~s|INSERT INTO "#{schema}".schema_migrations (version, inserted_at) VALUES ($1, now())|,
        [
          @version
        ]
      )

      assert [@version] == migrate(schema, :down)
      assert_removed(schema)
    end

    test "down is a no-op when the tasks table is absent (to_regclass guard)", %{schema: schema} do
      Repo.query!(~s|ALTER TABLE "#{schema}".tasks RENAME TO tasks_r518_aside|)

      try do
        assert [@version] == migrate(schema, :down)
      after
        Repo.query!(~s|ALTER TABLE "#{schema}".tasks_r518_aside RENAME TO tasks|)
      end

      # the renamed table kept its column (the guarded block never ran), so it is still there
      assert [["text", "YES", nil, nil]] = column(schema)
    end

    test "down then up leaves tasks with the column NULL (no backfill; no row gets a node)", %{
      schema: schema,
      tenant_id: tenant_id
    } do
      task = raw_task(schema)

      assert [@version] == migrate(schema, :down)
      assert {:ok, [@version]} = TenantProvisioning.replay_migrations(tenant_id)

      assert T.stored_scope_node(task.id, schema) == nil
    end
  end
end
