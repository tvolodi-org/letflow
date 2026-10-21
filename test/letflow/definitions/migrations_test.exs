defmodule Letflow.Definitions.MigrationsTest do
  @moduledoc """
  Integration tests for REQ-027's two
  `priv/repo/migrations/20260816193001..193002_*.exs` migrations, run against real
  Postgres through REQ-022's provision-then-replay mechanism. See
  `test/specs/REQ-027.md` for the full test-case rationale and the WF-02 Step 3
  scope-test verdict.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file.

  Like `test/letflow/event_store/migrations_test.exs` and
  `test/letflow/tenant_provisioning_test.exs`, and for the same empirically established
  reason, the describe block below does NOT run inside DataCase's normal rolled-back
  sandbox transaction: `Ecto.Migrator` needs a second, genuinely independent database
  connection beyond the one this process has checked out (it takes a lock on
  `schema_migrations`), which a sandboxed pool will not hand out -- the call fails with
  `DBConnection.ConnectionError ... :queue_timeout`. It therefore switches
  `Letflow.Repo` to `Ecto.Adapters.SQL.Sandbox` `:auto` mode and cleans up the real
  schemas and rows it creates in `on_exit/1` instead of relying on rollback. The
  `on_exit/1` is registered BEFORE anything that can fail, so every tenant schema this
  file creates is dropped on the failure path as well as the passing one.

  `async: false` for the whole module (ExUnit's `async` setting is module-wide, not
  per-test): ExUnit fully drains every `async: true` module before starting any sync
  module and runs sync modules strictly one at a time, so the `:auto`-mode switch has no
  other test's connection to disturb. The pure, no-I/O half of REQ-027's coverage lives
  in `test/letflow/definitions/schemas_test.exs`, which is `async: true`.

  Every structural claim below is read from the LIVE system catalog (`pg_indexes`,
  `pg_constraint`, `information_schema.columns`) after the migrations have actually run
  -- never from the migration source text, which is exactly what the two silent-
  correctness carry-forwards (the FK's referential action and the partial index's
  predicate) require.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # table name => the Ecto.Schema module that reads it (design section 5.1).
  @req027_tables %{
    "process_definitions" => Letflow.Definitions.ProcessDefinition,
    "instance_definition_snapshots" => Letflow.Definitions.InstanceDefinitionSnapshot
  }

  @req027_migration_modules [
    Letflow.Repo.Migrations.CreateProcessDefinitions,
    Letflow.Repo.Migrations.CreateInstanceDefinitionSnapshots
  ]

  # Fixed literals, never DateTime.utc_now/0 -- no test in this project may depend on
  # wall-clock time (docs/guides/test_developer_guide.md principle 3). Uniqueness of
  # these values is irrelevant: every test that uses them does so inside a tenant schema
  # no other test can see.
  #
  # NaiveDateTime, not DateTime: created_at/updated_at are `timestamp(6) without time
  # zone`, which is what Postgrex encodes a NaiveDateTime into.
  @fixed_naive_timestamp ~N[2026-01-02 03:04:05.000000]

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp table_exists_in_schema?(schema_name, table_name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)",
        [schema_name, table_name]
      )

    exists?
  end

  defp columns_in(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2",
        [schema_name, table_name]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  # {is_nullable, column_default} for one column, straight out of information_schema.
  defp column_facts(schema_name, table_name, column_name) do
    %{rows: [[is_nullable, column_default]]} =
      Repo.query!(
        """
        SELECT is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        """,
        [schema_name, table_name, column_name]
      )

    {is_nullable, column_default}
  end

  # {index_name, index_definition} for every index on a table. pg_indexes, not
  # information_schema.table_constraints: Ecto's `create unique_index(...)` emits
  # CREATE UNIQUE INDEX, not ALTER TABLE ... ADD CONSTRAINT UNIQUE, so the constraint
  # views do not list it at all and a test written against them would pass vacuously.
  defp indexes_on(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [schema_name, table_name]
      )

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  # The btree column list of an index definition, e.g. "name, version".
  defp indexed_columns(definition) do
    [_, columns] = Regex.run(~r/USING btree \(([^)]*)\)/, definition)
    columns
  end

  # Everything after the first " WHERE " in an index definition, or nil for a total
  # index. Postgres renders the predicate in its own normalised form -- a varchar
  # comparison comes back as `((status)::text = 'active'::text)`, NOT as the migration's
  # literal `status = 'active'` -- so assertions are made against this substring rather
  # than against the migration's source text.
  defp index_predicate(definition) do
    case String.split(definition, " WHERE ", parts: 2) do
      [_definition] -> nil
      [_definition, predicate] -> predicate
    end
  end

  # Every foreign key on a table, read from pg_constraint. `confdeltype` is the ON DELETE
  # referential action as a single byte -- 'a' NO ACTION, 'r' RESTRICT, 'c' CASCADE,
  # 'n' SET NULL, 'd' SET DEFAULT -- cast to text so Postgrex hands back a plain binary.
  # This is the ONLY place the referential action is observable: `on_delete: :nothing`
  # emits no ON DELETE clause at all, so nothing in the DDL text distinguishes it from a
  # cascade.
  defp foreign_keys_on(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.conname,
               c.confdeltype::text,
               c.confrelid::regclass::text,
               (SELECT a.attname FROM pg_attribute a
                 WHERE a.attrelid = c.conrelid AND a.attnum = c.conkey[1]),
               (SELECT a.attname FROM pg_attribute a
                 WHERE a.attrelid = c.confrelid AND a.attnum = c.confkey[1])
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = $1 AND t.relname = $2 AND c.contype = 'f'
        """,
        [schema_name, table_name]
      )

    Enum.map(rows, fn [name, on_delete, referenced_table, column, referenced_column] ->
      %{
        name: name,
        on_delete: on_delete,
        referenced_table: referenced_table,
        column: column,
        referenced_column: referenced_column
      }
    end)
  end

  # The set of migration versions actually recorded against this tenant's schema --
  # read straight from the live catalog (moduledoc's own stated principle), not from
  # TenantProvisioning.replay_migrations/2's return value, since
  # TenantFixture.provisioned_tenant!/1 does not surface that return value to its
  # caller. Equivalent under both of the fixture's provisioning paths: `:replay`
  # populates schema_migrations by actually running the migrations, and `:clone`
  # (the fixture's default) copies the fully-migrated template's schema_migrations
  # rows verbatim (test/support/tenant_template.ex step 8) -- either way, a freshly
  # provisioned tenant's schema_migrations holds exactly the full registered set.
  defp applied_versions_in(schema_name) do
    %{rows: rows} = Repo.query!(~s(SELECT version FROM "#{schema_name}".schema_migrations))
    rows |> Enum.map(fn [version] -> version end) |> Enum.sort()
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp insert_definition!(schema_name, attrs) do
    base = %{
      version: "1.0.0",
      graph: %{"nodes" => [], "edges" => []},
      created_by: Ecto.UUID.generate()
    }

    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(Map.merge(base, attrs))
    |> Repo.insert!(prefix: schema_name)
  end

  # A raw INSERT that supplies ONLY the NOT NULL columns with no default, so `graph`,
  # `status` and `stage` are filled by the DATABASE -- which is the whole point: a
  # changeset insert would send the schema module's own literals and could never detect a
  # disagreement between the two.
  defp raw_insert_minimal_definition!(schema_name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      ~s(INSERT INTO "#{schema_name}"."process_definitions" ) <>
        "(id, name, version, created_by, created_at, updated_at) " <>
        "VALUES ($1, $2, $3, $4, $5, $5)",
      [
        Ecto.UUID.dump!(id),
        "req027-raw-#{System.unique_integer([:positive, :monotonic])}",
        "1.0.0",
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        @fixed_naive_timestamp
      ]
    )

    id
  end

  # The guarded, single-statement UPDATE REQ-030's activate/1 will use. Deliberately raw
  # SQL and not a changeset: neither changeset casts :status (design INV-DEF-8), and that
  # WHERE clause is the concurrency control.
  defp activate(schema_name, id) do
    Repo.query(
      ~s(UPDATE "#{schema_name}"."process_definitions" SET status = 'active' ) <>
        "WHERE id = $1 AND status = 'draft'",
      [Ecto.UUID.dump!(id)]
    )
  end

  # ---------------------------------------------------------------------------------
  # Each test gets its own tenant, its own physical schema and its own Registration row
  # -- no identifier is shared between tests, and on_exit drops everything, because these
  # tests genuinely commit (see this module's moduledoc).
  # ---------------------------------------------------------------------------------

  describe "REQ-027's two definition migrations replayed into a provisioned tenant schema" do
    setup do
      %{schema_name: schema_name, tenant: tenant} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "req027",
          display_name: "REQ-027 Test Tenant"
        )

      %{
        tenant: tenant,
        schema_name: schema_name,
        applied_versions: applied_versions_in(schema_name)
      }
    end

    # -------------------------------------------------------------------------------
    # Acceptance criterion 1: "priv/repo/migrations gains process_definitions and
    # instance_definition_snapshots migrations, both schema-per-tenant via REQ-022's
    # :prefix mechanism, applying cleanly"
    # -------------------------------------------------------------------------------

    test "replay_migrations/2 applies both REQ-027 migrations and both definition tables land in the tenant's own schema",
         %{tenant: tenant, schema_name: schema_name, applied_versions: applied_versions} do
      registered_versions =
        TenantProvisioning.tenant_scoped_migrations() |> Enum.map(&elem(&1, 0))

      assert applied_versions == registered_versions

      for {table, _module} <- @req027_tables do
        # The table exists under the tenant's own schema.
        assert table_exists_in_schema?(schema_name, table),
               "#{table} is missing from tenant schema #{schema_name}"
      end

      # REQ-022's own observable that the replay ran to completion rather than partially.
      assert %Registration{migrations_applied_at: %NaiveDateTime{}} =
               Repo.get_by(Registration, tenant_id: tenant.id)
    end

    test "tenant_scoped_migrations/0 registers both REQ-027 definition migrations" do
      # req022-tenant-schema-provisioning.md section 4: both halves are mandatory and
      # independent. A guarded-but-unregistered migration is inert forever (never
      # selected by replay_migrations/2, so no tenant schema ever gets the table) and no
      # other test in this file would notice, since they all run through
      # replay_migrations/2. The section 4 guard test in
      # test/letflow/event_store/migrations_test.exs covers the other half, and now
      # iterates these two modules automatically.
      registered_modules =
        TenantProvisioning.tenant_scoped_migrations() |> Enum.map(&elem(&1, 1))

      for module <- @req027_migration_modules do
        assert module in registered_modules,
               "#{inspect(module)} is not registered in tenant_scoped_migrations/0 -- it would never reach any tenant schema"
      end
    end

    test "each definition table's real column set in the tenant schema matches its Ecto.Schema module's field list exactly",
         %{schema_name: schema_name} do
      # "Applies cleanly" is necessary but not sufficient: a migration can apply cleanly
      # and still disagree with the schema module that reads it, which surfaces much
      # later as a runtime Postgrex error in REQ-030/REQ-033. Equality, not subset -- an
      # extra column on either side is drift too. This is also the structural guard on
      # both moduledocs' "builds schema only" scope claim: if REQ-030's or REQ-033's
      # columns ever leaked into these migrations, the claim would silently become false
      # and this assertion is what catches it.
      for {table, module} <- @req027_tables do
        expected = module.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()

        assert columns_in(schema_name, table) == expected,
               "#{table}'s columns disagree with #{inspect(module)}.__schema__(:fields)"
      end
    end

    # -------------------------------------------------------------------------------
    # Acceptance criterion 2: "process_definitions has a unique index on (name, version)
    # and a partial unique index on name WHERE status = 'active'"
    # -------------------------------------------------------------------------------

    test "uq_definition_version is a total UNIQUE index over exactly (name, version)",
         %{schema_name: schema_name} do
      indexes = indexes_on(schema_name, "process_definitions")

      assert Map.has_key?(indexes, "uq_definition_version"),
             "uq_definition_version is missing, found: #{inspect(Map.keys(indexes))}"

      definition = Map.fetch!(indexes, "uq_definition_version")

      assert String.starts_with?(definition, "CREATE UNIQUE INDEX"),
             "uq_definition_version is not UNIQUE: #{definition}"

      assert indexed_columns(definition) == "name, version",
             "uq_definition_version does not cover exactly (name, version): #{definition}"

      # A PARTIAL variant of this index would enforce a strictly weaker rule while still
      # being named uq_definition_version and still being unique -- and definition.md's
      # uq_definition_version is unconditional.
      assert index_predicate(definition) == nil,
             "uq_definition_version carries a WHERE clause, so it does not enforce (name, version) uniqueness for every row: #{definition}"
    end

    test "a second definition with the same (name, version) is rejected by uq_definition_version",
         %{schema_name: schema_name} do
      # Asserts the index actually bites, against real Postgres, through the real
      # create_changeset/2 path with :prefix threaded through -- exactly how REQ-030's
      # create/1 will hit it. The error SHAPE matters too: if the changeset's declared
      # constraint name and the real index name ever drift apart, this raises
      # Ecto.ConstraintError instead of returning {:error, changeset}.
      name = "req027-dup-#{System.unique_integer([:positive, :monotonic])}"

      assert %ProcessDefinition{} =
               insert_definition!(schema_name, %{name: name, version: "1.0.0"})

      assert {:error, changeset} =
               %ProcessDefinition{}
               |> ProcessDefinition.create_changeset(%{
                 name: name,
                 version: "1.0.0",
                 graph: %{"nodes" => [], "edges" => []},
                 created_by: Ecto.UUID.generate()
               })
               |> Repo.insert(prefix: schema_name)

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    # -------------------------------------------------------------------------------
    # Carry-forward (a.2), structural half. PD-03's single-active-per-name invariant
    # lives ENTIRELY in this index's predicate. If the Ecto.Enum ever dumped a different
    # case than the predicate's literal, the index would match ZERO rows, the invariant
    # would be silently unenforced, and every other test in this project would still
    # pass. The expected literal is DERIVED from Ecto.Enum's own mapping rather than
    # hard-coded, so a case change on EITHER side fails here.
    # -------------------------------------------------------------------------------

    test "uq_active_definition is a PARTIAL unique index over (name) whose predicate matches the literal Ecto.Enum actually dumps for :active",
         %{schema_name: schema_name} do
      indexes = indexes_on(schema_name, "process_definitions")

      assert Map.has_key?(indexes, "uq_active_definition"),
             "uq_active_definition is missing, found: #{inspect(Map.keys(indexes))}"

      definition = Map.fetch!(indexes, "uq_active_definition")

      assert String.starts_with?(definition, "CREATE UNIQUE INDEX"),
             "uq_active_definition is not UNIQUE: #{definition}"

      assert indexed_columns(definition) == "name",
             "uq_active_definition does not cover exactly (name): #{definition}"

      predicate = index_predicate(definition)

      refute is_nil(predicate),
             "uq_active_definition has no WHERE clause -- it is a TOTAL unique index on name, which forbids versioning entirely: #{definition}"

      assert predicate =~ "status",
             "uq_active_definition's predicate does not mention status: #{predicate}"

      # The load-bearing assertion. Ecto.Enum.mappings/2 is the single source of truth
      # for what :active is actually STORED as; the predicate must be written against
      # that same literal or it matches nothing.
      active_literal = ProcessDefinition |> Ecto.Enum.mappings(:status) |> Keyword.fetch!(:active)

      assert predicate =~ "'#{active_literal}'",
             "uq_active_definition's predicate is #{predicate}, but Ecto.Enum dumps :active as #{inspect(active_literal)} -- the index would match ZERO rows and PD-03 would be silently unenforced"
    end

    test "a second definition activated under a name that already has an active definition is rejected by uq_active_definition (PD-03)",
         %{schema_name: schema_name} do
      # The behavioural companion to the structural assertion above, and the one that
      # actually catches a zero-row-matching index: under a predicate whose literal
      # disagreed with the stored enum value, the second activation below would simply
      # SUCCEED.
      name = "req027-active-#{System.unique_integer([:positive, :monotonic])}"

      first = insert_definition!(schema_name, %{name: name, version: "1.0.0"})
      second = insert_definition!(schema_name, %{name: name, version: "2.0.0"})

      # Discriminator: two DRAFT rows sharing a name coexist. Without this, the index
      # would be indistinguishable from a total unique index on name -- and a suite that
      # only checked "duplicates are rejected" would pass against the wrong index
      # entirely.
      assert first.status == :draft
      assert second.status == :draft

      # The value really is stored as the predicate's literal, read straight out of the
      # column with no Ecto load step in between.
      %{rows: [[stored_status]]} =
        Repo.query!(
          ~s(SELECT status FROM "#{schema_name}"."process_definitions" WHERE id = $1),
          [Ecto.UUID.dump!(first.id)]
        )

      assert stored_status == "draft"
      assert stored_status == String.downcase(stored_status)

      assert {:ok, %{num_rows: 1}} = activate(schema_name, first.id),
             "the guarded UPDATE did not activate the first definition"

      # ...and it loads back as the enum atom, closing the dump/load round trip.
      assert %ProcessDefinition{status: :active} =
               Repo.get(ProcessDefinition, first.id, prefix: schema_name)

      assert {:error, %Postgrex.Error{postgres: postgres}} = activate(schema_name, second.id),
             "a second active definition under the name #{name} was accepted -- PD-03's single-active-per-name invariant is unenforced"

      assert postgres.code == :unique_violation
      assert postgres.constraint == "uq_active_definition"
    end

    # -------------------------------------------------------------------------------
    # Acceptance criterion 3: "process_definitions has a nullable stage column and a
    # partial index on stage WHERE stage IS NOT NULL, per definition.md's PD-07 section
    # (migrations/014_definition_stage.sql)"
    # -------------------------------------------------------------------------------

    test "stage is a nullable column and an omitted stage lands as SQL NULL, which is what idx_def_stage's predicate depends on",
         %{schema_name: schema_name} do
      {is_nullable, _default} = column_facts(schema_name, "process_definitions", "stage")

      assert is_nullable == "YES",
             "process_definitions.stage is NOT NULL -- PD-07 requires it nullable so existing rows need no back-fill"

      # The round trip is what proves the nullability is reachable rather than merely
      # declared: if an omitted stage landed as '' instead of NULL, idx_def_stage's
      # WHERE stage IS NOT NULL predicate would index every row and PD-07's compactness
      # rationale would be silently false.
      id = raw_insert_minimal_definition!(schema_name)

      %{rows: [[stage_is_null]]} =
        Repo.query!(
          ~s(SELECT stage IS NULL FROM "#{schema_name}"."process_definitions" WHERE id = $1),
          [Ecto.UUID.dump!(id)]
        )

      assert stage_is_null, "an omitted stage did not land as SQL NULL"
      assert %ProcessDefinition{stage: nil} = Repo.get(ProcessDefinition, id, prefix: schema_name)
    end

    test "idx_def_stage is a non-unique PARTIAL index over (stage) predicated on stage IS NOT NULL",
         %{schema_name: schema_name} do
      indexes = indexes_on(schema_name, "process_definitions")

      assert Map.has_key?(indexes, "idx_def_stage"),
             "idx_def_stage is missing, found: #{inspect(Map.keys(indexes))}"

      definition = Map.fetch!(indexes, "idx_def_stage")

      # NON-unique, asserted explicitly: a unique index here would silently forbid two
      # definitions sharing a stage label, which PD-07's open-ended free-text labels
      # explicitly permit.
      refute String.contains?(definition, "UNIQUE"),
             "idx_def_stage is UNIQUE, which would forbid two definitions sharing a stage label: #{definition}"

      assert indexed_columns(definition) == "stage",
             "idx_def_stage does not cover exactly (stage): #{definition}"

      predicate = index_predicate(definition)

      refute is_nil(predicate),
             "idx_def_stage has no WHERE clause -- it indexes NULL entries too, which PD-07's compactness rationale rules out: #{definition}"

      assert predicate =~ "stage IS NOT NULL",
             "idx_def_stage's predicate is #{predicate}, expected stage IS NOT NULL (definition.md PD-07 / migrations/014_definition_stage.sql)"
    end

    # -------------------------------------------------------------------------------
    # Acceptance criterion 4: "instance_definition_snapshots.definition_id references
    # process_definitions.id with no ON DELETE CASCADE, and the moduledoc states this is
    # deliberate per PD-08"
    #
    # Carry-forward (a.1), structural half. `on_delete: :nothing` emits NO ON DELETE
    # clause at all, so nothing in the DDL text says "NO ACTION" and nothing
    # distinguishes it from a cascade without asking pg_constraint directly. The
    # moduledoc half is asserted in schemas_test.exs.
    # -------------------------------------------------------------------------------

    test "the snapshot FK's referential action in the live catalog is NO ACTION ('a'), not CASCADE ('c')",
         %{schema_name: schema_name} do
      foreign_keys = foreign_keys_on(schema_name, "instance_definition_snapshots")

      assert [foreign_key] = foreign_keys,
             "expected exactly one foreign key on instance_definition_snapshots, got #{inspect(foreign_keys)}"

      # The FK exists AND points where PD-08 says -- asserted rather than assumed, so
      # "confdeltype is 'a'" cannot be satisfied by a foreign key onto the wrong table.
      assert foreign_key.name == "instance_definition_snapshots_definition_id_fkey"
      assert foreign_key.column == "definition_id"
      assert foreign_key.referenced_column == "id"

      assert foreign_key.referenced_table == "#{schema_name}.process_definitions",
             "the snapshot FK references #{foreign_key.referenced_table}, not the tenant's own process_definitions"

      assert foreign_key.on_delete == "a",
             "the snapshot FK's ON DELETE action is #{inspect(foreign_key.on_delete)}, expected \"a\" (NO ACTION) per PD-08"

      # Stated explicitly as well as implied by the equality above, so a failure reads
      # against the criterion's own wording ("with no ON DELETE CASCADE").
      refute foreign_key.on_delete == "c",
             "the snapshot FK carries ON DELETE CASCADE, which would destroy exactly the rows PD-08 exists to preserve"
    end

    test "deleting a definition that has a snapshot row is rejected, and the snapshot survives with its captured graph (PD-08)",
         %{schema_name: schema_name} do
      # Per Step 2d carry-forward (e) and ISS-0024: the rejection IS the designed PD-08
      # behaviour. This test asserts it and changes nothing -- `on_delete: :nothing` must
      # not be "fixed" into a CASCADE. Under CASCADE this delete would succeed and
      # silently destroy the snapshot, which is REQ-033's fourth acceptance criterion.
      captured_graph = %{
        "nodes" => [%{"id" => "start", "node_type" => "start"}],
        "edges" => []
      }

      definition =
        insert_definition!(schema_name, %{
          name: "req027-fk-#{System.unique_integer([:positive, :monotonic])}",
          graph: captured_graph
        })

      instance_id = Ecto.UUID.generate()

      assert {:ok, _snapshot} =
               %InstanceDefinitionSnapshot{}
               |> InstanceDefinitionSnapshot.create_changeset(%{
                 instance_id: instance_id,
                 definition_id: definition.id,
                 definition_name: definition.name,
                 definition_ver: definition.version,
                 graph: captured_graph
               })
               |> Repo.insert(prefix: schema_name)

      exception =
        assert_raise Ecto.ConstraintError, fn ->
          Repo.delete(definition, prefix: schema_name)
        end

      assert exception.message =~ "instance_definition_snapshots_definition_id_fkey"

      # The snapshot is intact AND still carries the graph it captured -- the whole point
      # of PD-08's "snapshot rows persist with their captured graph".
      assert %InstanceDefinitionSnapshot{graph: ^captured_graph} =
               Repo.get(InstanceDefinitionSnapshot, instance_id, prefix: schema_name)

      # ...and the definition itself is still there, since the delete was rejected.
      assert Repo.get(ProcessDefinition, definition.id, prefix: schema_name)
    end

    test "a snapshot referencing a nonexistent definition is rejected as {:error, changeset}, not a raised error",
         %{schema_name: schema_name} do
      # Proves the FK exists at all, and that the name create_changeset/2 declares
      # matches Ecto's real default constraint name -- which is what lets REQ-033 return
      # DefinitionNotFound rather than crashing.
      assert {:error, changeset} =
               %InstanceDefinitionSnapshot{}
               |> InstanceDefinitionSnapshot.create_changeset(%{
                 instance_id: Ecto.UUID.generate(),
                 definition_id: Ecto.UUID.generate(),
                 definition_name: "req027-dangling",
                 definition_ver: "1.0.0",
                 graph: %{"nodes" => [], "edges" => []}
               })
               |> Repo.insert(prefix: schema_name)

      assert %{definition_id: ["does not exist"]} = errors_on(changeset)
    end

    # -------------------------------------------------------------------------------
    # Carry-forward (b), database half (Step 2d): the `graph` default is written twice as
    # independent literals -- migration line 82 and schema module line 98 -- with nothing
    # keeping them in sync. Same hazard class as the two above: a divergence ships green,
    # and only surfaces as a definition created through raw SQL disagreeing with one
    # created through the changeset.
    # -------------------------------------------------------------------------------

    test "the DB column default for graph and the schema module's struct default are the same value",
         %{schema_name: schema_name} do
      {_is_nullable, column_default} = column_facts(schema_name, "process_definitions", "graph")

      # Guards against both sides being absent, which would make the equality below pass
      # vacuously.
      refute is_nil(column_default),
             "process_definitions.graph has no DB default at all -- the migration's default: %{\"nodes\" => [], \"edges\" => []} is missing"

      # The row is inserted by raw SQL that omits `graph` entirely, so the DATABASE
      # default is what fills the column; reading it back through the schema module and
      # comparing against the struct default is a direct comparison of the two
      # independent literals.
      id = raw_insert_minimal_definition!(schema_name)

      assert %ProcessDefinition{graph: db_default_graph} =
               Repo.get(ProcessDefinition, id, prefix: schema_name)

      assert db_default_graph == %ProcessDefinition{}.graph,
             "the migration's graph default (#{inspect(db_default_graph)}) and Letflow.Definitions.ProcessDefinition's struct default (#{inspect(%ProcessDefinition{}.graph)}) have drifted apart"

      # ...and it really is definition.md's DefinitionGraph shape, so both agreeing on a
      # WRONG value still fails.
      assert db_default_graph == %{"nodes" => [], "edges" => []}
    end

    test "the DB column default for status is the same literal Ecto.Enum dumps for the schema's :draft default",
         %{schema_name: schema_name} do
      # The same hazard as the graph default, on the column whose literal
      # uq_active_definition's predicate is written against.
      {is_nullable, column_default} = column_facts(schema_name, "process_definitions", "status")

      assert is_nullable == "NO"
      refute is_nil(column_default), "process_definitions.status has no DB default"

      draft_literal = ProcessDefinition |> Ecto.Enum.mappings(:status) |> Keyword.fetch!(:draft)

      assert column_default =~ "'#{draft_literal}'",
             "process_definitions.status defaults to #{column_default}, but Ecto.Enum dumps :draft as #{inspect(draft_literal)}"

      id = raw_insert_minimal_definition!(schema_name)

      assert %ProcessDefinition{status: :draft} =
               Repo.get(ProcessDefinition, id, prefix: schema_name)
    end
  end
end
