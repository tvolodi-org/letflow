defmodule Letflow.Migrations.InstanceProjectionsScopeNodeIdMigrationTest do
  @moduledoc """
  REQ-531 / GH #3092, T-1a..T-1c (AC 1): the tenant-scoped migration
  `20261024100001_add_scope_node_id_to_instance_projections.exs`.

    * a CLONED and a REPLAYED tenant carry the nullable `text` column
      `instance_projections.scope_node_id`, the foreign key
      `instance_projections_scope_node_id_fkey` to `scope_node_paths (node_id)` with
      `ON DELETE RESTRICT` and the PARTIAL index `instance_projections_scope_node_id_idx`;
    * the manifest holds it in order, exactly one file of that version exists, the file carries
      the `if prefix() do` guard; no new table;
    * rows that exist before `up` read NULL after it (no backfill); the foreign key refuses an
      unknown node and restricts deleting a referenced one;
    * `down` removes index, constraint and column, is repeatable and a no-op when the table is
      absent; a replay after `down` restores the shape.

  Real Postgres, dedicated tenant schemas, raw DDL: `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.Support.ScopeSetFixture
  alias Letflow.Support.TaskScopeFixture, as: T
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_024_100_001
  @file_name "20261024100001_add_scope_node_id_to_instance_projections.exs"
  @fk "instance_projections_scope_node_id_fkey"
  @index "instance_projections_scope_node_id_idx"

  defp migration, do: Module.concat(Letflow.Repo.Migrations, AddScopeNodeIdToInstanceProjections)

  setup do
    migrations = TenantProvisioning.tenant_scoped_migrations()
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r531-mig")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id, migrations: migrations}
  end

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
         WHERE table_schema = $1 AND table_name = 'instance_projections'
           AND column_name = 'scope_node_id'
        """,
        [schema]
      )

    rows
  end

  defp fk(schema) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.confdeltype, c.convalidated, ref.relname, pg_get_constraintdef(c.oid)
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
    assert [["text", "YES", nil, nil]] = column(schema)
    assert [["r", true, "scope_node_paths", definition]] = fk(schema)
    assert definition =~ "FOREIGN KEY (scope_node_id) REFERENCES"
    assert definition =~ "ON DELETE RESTRICT"

    index = index_def(schema)
    assert index =~ "CREATE INDEX #{@index}"
    assert index =~ "WHERE (scope_node_id IS NOT NULL)"
  end

  defp assert_removed(schema) do
    assert column(schema) == []
    assert fk(schema) == []
    assert index_def(schema) == nil
  end

  # a minimal projection row, inserted by the task fixture (it needs the instance row first)
  defp raw_instance(schema) do
    task = T.insert_task!(%{schema_name: schema}, nil)
    task.instance_id
  end

  defp stored(schema, instance_id) do
    %{rows: [[node]]} =
      Repo.query!(
        ~s|SELECT scope_node_id FROM "#{schema}".instance_projections WHERE instance_id = $1|,
        [Ecto.UUID.dump!(instance_id)]
      )

    node
  end

  describe "T-1a / T-1b shape" do
    test "a CLONED tenant has the column, the RESTRICT foreign key and the partial index", %{
      schema: schema
    } do
      assert_migrated(schema)
    end

    test "a REPLAYED tenant has the identical shape and no new table" do
      replayed = TenantFixture.provisioned_tenant!(slug_prefix: "r531-rep", template: :replay)
      assert_migrated(replayed.schema_name)

      %{rows: rows} =
        Repo.query!(
          """
          SELECT table_name FROM information_schema.tables
           WHERE table_schema = $1 AND table_type = 'BASE TABLE'
             AND table_name <> 'schema_migrations'
           ORDER BY table_name
          """,
          [replayed.schema_name]
        )

      tables =
        rows
        |> List.flatten()
        |> Enum.reject(&TenantFixture.req376_partition_management_table?/1)

      assert tables == Enum.sort(TenantFixture.expected_tenant_tables())
    end

    test "registered in order, once, with the prefix guard", %{migrations: migrations} do
      assert {@version, migration()} in migrations

      versions = Enum.map(migrations, &elem(&1, 0))
      assert versions == Enum.sort(versions)
      assert versions == Enum.uniq(versions)

      on_disk =
        "priv/repo/migrations"
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "20261024100001"))

      assert on_disk == [@file_name]
      assert File.read!(Path.join("priv/repo/migrations", @file_name)) =~ "if prefix() do"
      assert byte_size(@fk) <= 63
      assert byte_size(@index) <= 63
    end
  end

  describe "T-1c the foreign key and existing rows" do
    test "an unknown node is refused; a referenced node cannot be deleted", %{schema: schema} do
      :ok = ScopeSetFixture.build_tree!(schema)
      nodes = ScopeSetFixture.nodes()
      instance_id = raw_instance(schema)
      assert stored(schema, instance_id) == nil

      set = fn node ->
        Repo.query(
          ~s|UPDATE "#{schema}".instance_projections SET scope_node_id = $1 WHERE instance_id = $2|,
          [node, Ecto.UUID.dump!(instance_id)]
        )
      end

      assert {:ok, %{num_rows: 1}} = set.(nodes.b1)
      assert stored(schema, instance_id) == nodes.b1

      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation, constraint: @fk}}} =
               set.("no-such-node")

      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation, constraint: @fk}}} =
               Repo.query(~s|DELETE FROM "#{schema}".scope_node_paths WHERE node_id = $1|, [
                 nodes.b1
               ])

      # an unreferenced leaf is not blocked by the new constraint
      assert {:ok, %{num_rows: 1}} =
               Repo.query(~s|DELETE FROM "#{schema}".scope_node_paths WHERE node_id = $1|, [
                 nodes.a3
               ])
    end

    test "rows that exist before up read NULL after it (no backfill)", %{
      schema: schema,
      tenant_id: tenant_id
    } do
      instance_id = raw_instance(schema)

      assert [@version] == migrate(schema, :down)
      assert {:ok, [@version]} = TenantProvisioning.replay_migrations(tenant_id)

      assert stored(schema, instance_id) == nil
    end
  end

  describe "T-1c down and replay" do
    test "down removes index, constraint and column; a replay restores the shape", %{
      schema: schema,
      tenant_id: tenant_id
    } do
      assert [@version] == migrate(schema, :down)
      assert_removed(schema)

      assert {:ok, [@version]} = TenantProvisioning.replay_migrations(tenant_id)
      assert_migrated(schema)

      assert {:ok, []} = TenantProvisioning.replay_migrations(tenant_id)
    end

    test "down is repeatable (second run with the version row restored)", %{schema: schema} do
      assert [@version] == migrate(schema, :down)

      Repo.query!(
        ~s|INSERT INTO "#{schema}".schema_migrations (version, inserted_at) VALUES ($1, now())|,
        [@version]
      )

      assert [@version] == migrate(schema, :down)
      assert_removed(schema)
    end

    test "down is a no-op when the table is absent (to_regclass guard)", %{schema: schema} do
      Repo.query!(
        ~s|ALTER TABLE "#{schema}".instance_projections RENAME TO instance_projections_r531|
      )

      try do
        assert [@version] == migrate(schema, :down)
      after
        Repo.query!(
          ~s|ALTER TABLE "#{schema}".instance_projections_r531 RENAME TO instance_projections|
        )
      end

      assert [["text", "YES", nil, nil]] = column(schema)
    end
  end
end
