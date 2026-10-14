defmodule Letflow.ScopeNodePaths.MigrationTest do
  @moduledoc """
  REQ-496 / GH #2530 AC9, design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md`
  §2.1, §5 and §9 T-31 (spec `test/specs/REQ-496.md`): both REQ-496 tenant-scoped migrations
  apply and roll back on a POPULATED tenant schema.

    * `CreateScopeNodePaths`: with rows in the table, `:down` drops it, `:up` recreates it, and
      `pg_indexes` shows the `node_id` primary key and the UNIQUE `path text_pattern_ops` index.
    * `AddManagedByToEntityDefinitions`: on a schema holding a stamped and an unstamped definition,
      `:down` removes the column, the partial index, both triggers and the guard function (the
      definition rows stay), and `:up` restores them.

  Runs `Ecto.Migrator.run/4` with the tenant prefix, as `TenantProvisioning.replay_migrations/2`
  does; `TenantProvisioning.tenant_scoped_migrations/0` loads the migration modules first. Raw DDL
  against one real tenant schema, so `async: false`; the schema is dropped by the fixture's
  teardown either way.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ManagedTypes
  alias Letflow.ScopeNodePaths
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @managed_by_version 20_261_014_100_001
  @scope_version 20_261_014_100_002
  @managed_by_migration Letflow.Repo.Migrations.AddManagedByToEntityDefinitions
  @scope_migration Letflow.Repo.Migrations.CreateScopeNodePaths

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req496-mig")

    # Loads every manifest migration module (they are not compiled into the app) and proves both
    # REQ-496 migrations are registered for tenant schemas.
    migrations = TenantProvisioning.tenant_scoped_migrations()
    assert {@managed_by_version, @managed_by_migration} in migrations
    assert {@scope_version, @scope_migration} in migrations

    {:ok, schema: tenant.schema_name}
  end

  defp migrate(schema, version, module, direction) do
    Ecto.Migrator.run(Repo, [{version, module}], direction,
      all: true,
      prefix: schema,
      log: false
    )
  end

  defp regclass(schema, name) do
    %{rows: [[value]]} = Repo.query!("SELECT to_regclass($1)::text", [~s|"#{schema}".#{name}|])
    value
  end

  defp indexes(schema, table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [schema, table]
      )

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  defp column?(schema, table, column) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        """,
        [schema, table, column]
      )

    n == 1
  end

  defp triggers(schema) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT t.tgname FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = 'entity_definitions'
          AND t.tgname LIKE 'entity_definitions_managed_by_%'
        """,
        [schema]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp guard_function?(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = $1 AND p.proname = 'entity_definitions_managed_by_guard'
        """,
        [schema]
      )

    n == 1
  end

  defp assert_scope_indexes!(schema) do
    idx = indexes(schema, "scope_node_paths")

    assert idx["scope_node_paths_pkey"] =~ "(node_id)"
    assert idx["scope_node_paths_path_pattern_idx"] =~ "text_pattern_ops"
    assert idx["scope_node_paths_path_pattern_idx"] =~ "UNIQUE"
    assert idx["scope_node_paths_path_pattern_idx"] =~ "(path"
  end

  test "scope_node_paths: indexes exist; down on a populated table drops it; up recreates it", %{
    schema: schema
  } do
    assert regclass(schema, "scope_node_paths") != nil
    assert_scope_indexes!(schema)

    for {id, parent} <- [{"r", nil}, {"a", "r"}, {"b", "a"}] do
      {:ok, _} = ScopeNodePaths.write({:insert, id, parent}, schema)
    end

    %{rows: [[3]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".scope_node_paths|)

    assert migrate(schema, @scope_version, @scope_migration, :down) == [@scope_version]
    assert regclass(schema, "scope_node_paths") == nil

    assert migrate(schema, @scope_version, @scope_migration, :up) == [@scope_version]
    assert regclass(schema, "scope_node_paths") != nil
    assert_scope_indexes!(schema)

    # Usable again (and empty) after the round trip.
    %{rows: [[0]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".scope_node_paths|)
    assert {:ok, %{path: "/r/"}} = ScopeNodePaths.write({:insert, "r", nil}, schema)
  end

  test "managed_by: down on a schema with stamped and unstamped definitions removes column, index, triggers and function; up restores them",
       %{schema: schema} do
    owner = ManagedTypes.module_owner(Letflow.Modules.FixtureManaged)

    {:ok, stamped} =
      Definitions.create_definition(definition_attrs("org_unit"), schema, owner)

    {:ok, _plain} = Definitions.create_definition(definition_attrs("fxm_plain"), schema)
    assert stamped.managed_by == "fixture_managed"

    present = [
      "entity_definitions_managed_by_no_delete",
      "entity_definitions_managed_by_no_update"
    ]

    assert column?(schema, "entity_definitions", "managed_by")

    assert Map.has_key?(
             indexes(schema, "entity_definitions"),
             "entity_definitions_managed_by_name_idx"
           )

    assert triggers(schema) == present
    assert guard_function?(schema)

    assert migrate(schema, @managed_by_version, @managed_by_migration, :down) ==
             [@managed_by_version]

    refute column?(schema, "entity_definitions", "managed_by")

    refute Map.has_key?(
             indexes(schema, "entity_definitions"),
             "entity_definitions_managed_by_name_idx"
           )

    assert triggers(schema) == []
    refute guard_function?(schema)

    %{rows: [[2]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".entity_definitions|)

    assert migrate(schema, @managed_by_version, @managed_by_migration, :up) ==
             [@managed_by_version]

    assert column?(schema, "entity_definitions", "managed_by")

    assert Map.has_key?(
             indexes(schema, "entity_definitions"),
             "entity_definitions_managed_by_name_idx"
           )

    assert triggers(schema) == present
    assert guard_function?(schema)

    # Rows survived; the re-added column starts NULL everywhere.
    assert Repo.all(from(d in EntityDefinition, select: d.managed_by), prefix: schema) == [
             nil,
             nil
           ]
  end

  defp definition_attrs(name) do
    %{
      definition: %{
        name: name,
        display_name: "REQ-496 #{name}",
        fields: [%{name: "name", type: :string, required: true}]
      },
      created_by: Ecto.UUID.generate()
    }
  end
end
