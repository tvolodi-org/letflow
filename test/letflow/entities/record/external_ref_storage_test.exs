defmodule Letflow.Entities.Record.ExternalRefStorageTest do
  @moduledoc """
  GH #2659 / REQ-505 PR-1 (design `lib/letflow/design/gh2659-external-ref-idempotent-import.md`):

    * T16 + section 12: migrations (a) columns + both-or-neither CHECK and (b) the partial
      unique index exist on a FRESH (cloned) tenant and on an UPGRADED tenant (migrated down,
      then replayed up), are registered in order, are idempotent (guarded DDL), and migration
      (a) fails fast under a conflicting lock (`lock_timeout`) leaving the table unchanged.
    * T5 (direct index parts): the unique index and the pair CHECK are enforced.
    * T9: `ENTITY_RECORD_CREATED` is registered at v2 only (in place) in a fresh tenant AND in
      an upgraded tenant (v1 -> v2 through `replay_migrations/2`); UPDATED / DELETED stay v1;
      re-seeding is a no-op; a ref-carrying payload validates under v2 and not under UPDATED.
    * T10: the projector carries the ref (replay, rebuild through `write_snapshots/3`) across
      UPDATED and DELETED.

  Real Postgres, dedicated tenant schemas, raw DDL, so `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Record.Projector
  alias Letflow.Entities.Records
  alias Letflow.EventStore
  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @cols_version 20_261_019_100_001
  @cols_migration Letflow.Repo.Migrations.AddExternalRefColumnsToEntityRecordLatest
  @idx_version 20_261_019_100_002
  @idx_migration Letflow.Repo.Migrations.AddExternalRefIndexToEntityRecordLatest
  @prev_version 20_261_018_100_002
  @check "entity_record_latest_external_ref_pair_chk"
  @index "entity_record_latest_external_ref_idx"

  setup do
    # Loads every manifest migration module (they are not compiled into the application).
    migrations = TenantProvisioning.tenant_scoped_migrations()
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2659-store")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id, migrations: migrations}
  end

  # --- helpers -------------------------------------------------------------------------------

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
        SELECT column_name, data_type, character_maximum_length, is_nullable, column_default
          FROM information_schema.columns
         WHERE table_schema = $1 AND table_name = 'entity_record_latest'
           AND column_name IN ('external_system', 'external_id')
         ORDER BY column_name
        """,
        [schema]
      )

    rows
  end

  defp check_def(schema) do
    case Repo.query!(
           """
           SELECT pg_get_constraintdef(c.oid), c.convalidated
             FROM pg_constraint c
             JOIN pg_namespace n ON n.oid = c.connamespace
            WHERE n.nspname = $1 AND c.conname = $2 AND c.contype = 'c'
           """,
           [schema, @check]
         ) do
      %{rows: [[definition, validated]]} -> {definition, validated}
      %{rows: []} -> nil
    end
  end

  defp index_def(schema) do
    case Repo.query!(
           "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND indexname = $2",
           [schema, @index]
         ) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  defp assert_migrated(schema) do
    assert [
             ["external_id", "character varying", 255, "YES", nil],
             ["external_system", "character varying", 64, "YES", nil]
           ] = columns(schema)

    assert {definition, true} = check_def(schema)
    assert definition =~ "external_system IS NULL"
    assert definition =~ "external_id IS NULL"

    definition = index_def(schema)
    assert definition =~ "CREATE UNIQUE INDEX"
    assert definition =~ "(entity_type, external_system, external_id)"
    assert definition =~ "WHERE (external_id IS NOT NULL)"
  end

  defp raw_insert(schema, entity_type, system, id) do
    Repo.query(
      ~s|INSERT INTO "#{schema}".entity_record_latest | <>
        ~s|(id, entity_type, record_id, field_values, deleted, entity_def_version, | <>
        ~s|last_event_global_seq, external_system, external_id, inserted_at, updated_at) | <>
        ~s|VALUES (gen_random_uuid(), $1, gen_random_uuid(), '{}', false, '\\x00', 1, $2, $3, now(), now())|,
      [entity_type, system, id]
    )
  end

  defp create_active_definition!(schema, name) do
    definition = %{
      name: name,
      display_name: name,
      fields: [%{name: "customer_name", type: :string, required: true}]
    }

    assert {:ok, entity_definition} =
             Definitions.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, activated} =
             Definitions.activate_definition(
               entity_definition.name,
               Ecto.UUID.generate(),
               "go-live",
               schema
             )

    activated
  end

  defp append_event!(schema, instance_id, event_type, payload_map) do
    attrs = %{
      instance_id: instance_id,
      event_type: event_type,
      payload: Jason.encode!(payload_map),
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    assert {:ok, multi} = EventStore.append_multi(Ecto.Multi.new(), attrs, prefix: schema)
    assert {:ok, _changes} = Repo.transaction(multi)
  end

  defp created_payload(record_id, extra \\ %{}) do
    Map.merge(
      %{
        "entity_type" => "customer",
        "entity_def_version" => "aaaaaaaaaaaaaaaa",
        "record_id" => record_id,
        "field_values" => %{"customer_name" => "Acme"}
      },
      extra
    )
  end

  # --- T16: fresh tenant, upgraded tenant, registration --------------------------------------

  describe "T16 migrations (a) and (b)" do
    test "a fresh (cloned) tenant has the columns, the validated CHECK and the partial unique index",
         %{schema: schema} do
      assert_migrated(schema)
    end

    test "an upgraded tenant gets the same shape: down (b) then (a), then replayed up", %{
      schema: schema
    } do
      assert [@idx_version] == migrate(schema, @idx_version, @idx_migration, :down)
      assert [@cols_version] == migrate(schema, @cols_version, @cols_migration, :down)

      assert columns(schema) == []
      assert check_def(schema) == nil
      assert index_def(schema) == nil

      assert [@cols_version] == migrate(schema, @cols_version, @cols_migration, :up)
      assert [@idx_version] == migrate(schema, @idx_version, @idx_migration, :up)

      assert_migrated(schema)
    end

    test "the whole-manifest replay of an already-migrated tenant is a no-op, and the guarded DDL is idempotent",
         %{schema: schema, tenant_id: tenant_id} do
      assert {:ok, []} = TenantProvisioning.replay_migrations(tenant_id)

      # Force both migrations to run again over an already-migrated table: every statement is
      # guarded (ADD COLUMN IF NOT EXISTS, pg_constraint check, CREATE INDEX IF NOT EXISTS).
      Repo.query!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version IN ($1, $2)|, [
        @cols_version,
        @idx_version
      ])

      assert {:ok, [@cols_version, @idx_version]} =
               TenantProvisioning.replay_migrations(tenant_id)

      assert_migrated(schema)
    end

    test "a hand-prepared large tenant (NOT VALID CHECK, concurrent-style index) makes both migrations no-ops",
         %{schema: schema} do
      assert [@idx_version] == migrate(schema, @idx_version, @idx_migration, :down)
      assert [@cols_version] == migrate(schema, @cols_version, @cols_migration, :down)

      # The runbook's manual route: columns + NOT VALID check + the index under the same name.
      Repo.query!(
        ~s|ALTER TABLE "#{schema}".entity_record_latest | <>
          ~s|ADD COLUMN external_system varchar(64), ADD COLUMN external_id varchar(255)|
      )

      Repo.query!(
        ~s|ALTER TABLE "#{schema}".entity_record_latest ADD CONSTRAINT #{@check} | <>
          ~s|CHECK ((external_system IS NULL) = (external_id IS NULL)) NOT VALID|
      )

      Repo.query!(
        ~s|CREATE UNIQUE INDEX #{@index} ON "#{schema}".entity_record_latest | <>
          ~s|(entity_type, external_system, external_id) WHERE external_id IS NOT NULL|
      )

      assert [@cols_version] == migrate(schema, @cols_version, @cols_migration, :up)
      assert [@idx_version] == migrate(schema, @idx_version, @idx_migration, :up)

      # Still the operator's NOT VALID constraint: the migration did not touch it.
      assert {_definition, false} = check_def(schema)
    end

    test "both migrations are registered, in order, after AddAdminFlaggedServicePrincipalToUsers",
         %{migrations: migrations} do
      assert {@cols_version, @cols_migration} in migrations
      assert {@idx_version, @idx_migration} in migrations

      versions = Enum.map(migrations, &elem(&1, 0))
      index = fn v -> Enum.find_index(versions, &(&1 == v)) end

      assert index.(@prev_version) < index.(@cols_version)
      assert index.(@cols_version) < index.(@idx_version)
    end

    # A source-text check on purpose: the BEHAVIOURAL lock_timeout proof is migration (a)'s, in
    # external_ref_lock_timeout_test.exs. Migration (b) shares the identical first statement, and
    # forcing its lock wait needs the same two-connection harness for no extra signal, so its
    # ordering (lock_timeout before any DDL, prefix guard present) is pinned by reading the file.
    test "the migrations carry the prefix guard and SET LOCAL lock_timeout as their first statement" do
      for file <- [
            "20261019100001_add_external_ref_columns_to_entity_record_latest.exs",
            "20261019100002_add_external_ref_index_to_entity_record_latest.exs"
          ] do
        source = File.read!(Path.join(["priv", "repo", "migrations", file]))
        assert source =~ "if prefix() do"
        assert source =~ ~s|execute("SET LOCAL lock_timeout = '5s'")|

        # lock_timeout precedes any DDL statement.
        {lock_at, _} = :binary.match(source, "SET LOCAL lock_timeout")
        {ddl_at, _} = :binary.match(source, ~s|execute("""|)
        assert lock_at < ddl_at
      end
    end
  end

  # --- T5 (direct index parts) ---------------------------------------------------------------

  describe "the index and the pair CHECK (direct SQL)" do
    test "the same (type, system, id) twice is a unique violation on the named index; the same pair in another type is fine; NULL/NULL rows never collide",
         %{schema: schema} do
      assert {:ok, %{num_rows: 1}} = raw_insert(schema, "item", "1c", "42")

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: @index}}} =
               raw_insert(schema, "item", "1c", "42")

      assert {:ok, %{num_rows: 1}} = raw_insert(schema, "location", "1c", "42")
      assert {:ok, %{num_rows: 1}} = raw_insert(schema, "item", "sap", "42")
      assert {:ok, %{num_rows: 1}} = raw_insert(schema, "item", nil, nil)
      assert {:ok, %{num_rows: 1}} = raw_insert(schema, "item", nil, nil)
    end

    test "the pair CHECK rejects (NULL, 'x') and ('x', NULL)", %{schema: schema} do
      for {system, id} <- [{nil, "x"}, {"x", nil}] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: @check}}} =
                 raw_insert(schema, "item", system, id)
      end
    end

    test "Latest.insert_changeset/2 maps the index violation to an error on the changeset, and the pair CHECK to :external_id",
         %{schema: schema} do
      attrs = fn system, id ->
        %{
          entity_type: "item",
          record_id: Ecto.UUID.generate(),
          field_values: %{},
          entity_def_version: <<0>>,
          last_event_global_seq: 1,
          external_system: system,
          external_id: id
        }
      end

      assert {:ok, %Latest{external_system: "1c", external_id: "42"}} =
               %Latest{}
               |> Latest.insert_changeset(attrs.("1c", "42"))
               |> Repo.insert(prefix: schema)

      assert {:error, changeset} =
               %Latest{}
               |> Latest.insert_changeset(attrs.("1c", "42"))
               |> Repo.insert(prefix: schema)

      assert [
               {:entity_type,
                {_,
                 [constraint: :unique, constraint_name: "entity_record_latest_external_ref_idx"]}}
             ] = changeset.errors

      assert {:error, changeset} =
               %Latest{}
               |> Latest.insert_changeset(attrs.(nil, "x"))
               |> Repo.insert(prefix: schema)

      assert [{:external_id, {_, [constraint: :check, constraint_name: @check]}}] =
               changeset.errors

      # Optional: a ref-less insert still works and reads back nil/nil.
      assert {:ok, %Latest{external_system: nil, external_id: nil}} =
               %Latest{}
               |> Latest.insert_changeset(attrs.(nil, nil))
               |> Repo.insert(prefix: schema)
    end

    test "a soft-deleted row keeps holding its reference: re-inserting the same triple is a unique violation",
         %{schema: schema} do
      assert {:ok, %{num_rows: 1}} = raw_insert(schema, "item", "1c", "42")

      Repo.update_all(
        from(l in Latest, where: l.entity_type == "item" and l.external_id == "42"),
        [set: [deleted: true]],
        prefix: schema
      )

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: @index}}} =
               raw_insert(schema, "item", "1c", "42")
    end

    test "the same (type, system, id) in two tenant schemas does not collide", %{schema: schema} do
      other = TenantFixture.provisioned_tenant!(slug_prefix: "gh2659-two")

      assert {:ok, %{num_rows: 1}} = raw_insert(schema, "item", "1c", "42")
      assert {:ok, %{num_rows: 1}} = raw_insert(other.schema_name, "item", "1c", "42")

      assert {:ok, a} = Latest.get_by_external_ref("item", "1c", "42", schema)
      assert {:ok, b} = Latest.get_by_external_ref("item", "1c", "42", other.schema_name)
      refute a.record_id == b.record_id
    end

    test "get_by_external_ref/4 answers :not_found, without a query, for a non-binary type, system or id",
         %{schema: schema} do
      for args <- [[nil, "1c", "42"], ["item", nil, "42"], ["item", "1c", 42], [:item, "1c", "x"]] do
        assert {:error, :not_found} = apply(Latest, :get_by_external_ref, args ++ [schema])
      end
    end

    test "migration (b) accepts a VALID pre-existing index and refuses an INVALID one",
         %{schema: schema} do
      assert [@idx_version] == migrate(schema, @idx_version, @idx_migration, :down)

      create_index = fn ->
        Repo.query!(
          ~s|CREATE UNIQUE INDEX #{@index} ON "#{schema}".entity_record_latest | <>
            ~s|(entity_type, external_system, external_id) WHERE external_id IS NOT NULL|
        )
      end

      # A VALID pre-existing index (the runbook's manual route) is accepted: no-op.
      create_index.()
      assert [@idx_version] == migrate(schema, @idx_version, @idx_migration, :up)
      assert [@idx_version] == migrate(schema, @idx_version, @idx_migration, :down)

      create_index.()

      # Simulate a failed CREATE INDEX CONCURRENTLY.
      Repo.query!(
        ~s|UPDATE pg_index SET indisvalid = false | <>
          ~s|WHERE indexrelid = '"#{schema}".#{@index}'::regclass|
      )

      error =
        assert_raise Postgrex.Error, fn -> migrate(schema, @idx_version, @idx_migration, :up) end

      assert error.postgres.code == :raise_exception
      assert error.postgres.message =~ "INVALID"
      refute error.postgres.message =~ schema
    end

    test "Latest.update_changeset/2 never casts the ref (immutable once set)", %{schema: schema} do
      row =
        %Latest{}
        |> Latest.insert_changeset(%{
          entity_type: "item",
          record_id: Ecto.UUID.generate(),
          field_values: %{},
          entity_def_version: <<0>>,
          last_event_global_seq: 1,
          external_system: "1c",
          external_id: "42"
        })
        |> Repo.insert!(prefix: schema)

      changeset =
        Latest.update_changeset(row, %{
          field_values: %{"a" => 1},
          deleted: false,
          entity_def_version: <<0>>,
          last_event_global_seq: 2,
          external_system: "other",
          external_id: "99"
        })

      refute Map.has_key?(changeset.changes, :external_system)
      refute Map.has_key?(changeset.changes, :external_id)
    end

    test "Latest.get_by_external_ref/4 finds a row (deleted too) by prefix; another tenant cannot see it",
         %{schema: schema} do
      row =
        %Latest{}
        |> Latest.insert_changeset(%{
          entity_type: "item",
          record_id: Ecto.UUID.generate(),
          field_values: %{},
          entity_def_version: <<0>>,
          last_event_global_seq: 1,
          external_system: "1c",
          external_id: "42"
        })
        |> Repo.insert!(prefix: schema)

      assert {:ok, %Latest{id: id}} = Latest.get_by_external_ref("item", "1c", "42", schema)
      assert id == row.id

      Repo.update_all(from(l in Latest, where: l.id == ^row.id), [set: [deleted: true]],
        prefix: schema
      )

      assert {:ok, %Latest{deleted: true}} =
               Latest.get_by_external_ref("item", "1c", "42", schema)

      assert {:error, :not_found} = Latest.get_by_external_ref("item", "1c", "43", schema)
      assert {:error, :not_found} = Latest.get_by_external_ref("other", "1c", "42", schema)
      assert {:error, :not_found} = Latest.get_by_external_ref("item", "sap", "42", schema)

      other = TenantFixture.provisioned_tenant!(slug_prefix: "gh2659-other")

      assert {:error, :not_found} =
               Latest.get_by_external_ref("item", "1c", "42", other.schema_name)

      assert {:error, :invalid_schema_name} =
               Latest.get_by_external_ref("item", "1c", "42", "no_such_schema")
    end
  end

  # --- T9: the registered event schema ---------------------------------------------------------

  describe "T9 ENTITY_RECORD_CREATED v2" do
    # A cloned tenant carries no entity event types (the template seeds none); a REPLAYED
    # tenant is the production provisioning path that registers them.
    setup do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2659-t9", template: :replay)
      {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
    end

    defp rows(tenant_schema, name) do
      Repo.all(
        from(e in EventType,
          where: e.name == ^name,
          order_by: e.schema_version,
          select: e.schema_version
        ),
        prefix: tenant_schema
      )
    end

    defp validate(type, payload, tenant_id),
      do: Registry.validate_payload(type, Jason.encode!(payload), tenant_id)

    test "a fresh tenant registers CREATED at v2 only (in place, no v1 row beside it); UPDATED and DELETED stay v1",
         %{schema: schema} do
      assert rows(schema, "ENTITY_RECORD_CREATED") == [2]
      assert rows(schema, "ENTITY_RECORD_UPDATED") == [1]
      assert rows(schema, "ENTITY_RECORD_DELETED") == [1]

      assert Registry.max_schema_version("ENTITY_RECORD_CREATED", schema) == 2
      assert Registry.max_schema_version("ENTITY_RECORD_UPDATED", schema) == 1
      assert Registry.max_schema_version("ENTITY_RECORD_DELETED", schema) == 1
    end

    test "a ref-carrying create validates under v2; a v1-shaped payload still does; bad shapes are rejected",
         %{tenant_id: tenant_id} do
      record_id = Ecto.UUID.generate()
      ref = %{"system" => "1c", "id" => "42"}

      assert :ok = validate("ENTITY_RECORD_CREATED", created_payload(record_id), tenant_id)

      assert :ok =
               validate(
                 "ENTITY_RECORD_CREATED",
                 created_payload(record_id, %{"external_ref" => ref}),
                 tenant_id
               )

      for bad <- [
            %{"external_ref" => %{"system" => "1c"}},
            %{"external_ref" => %{"system" => "1c", "id" => "42", "extra" => "x"}},
            %{"external_ref" => %{"system" => 1, "id" => "42"}},
            %{"external_ref" => "1c:42"},
            %{"something_else" => 1}
          ] do
        assert {:error, {:payload_validation_failed, [_ | _]}} =
                 validate("ENTITY_RECORD_CREATED", created_payload(record_id, bad), tenant_id)
      end
    end

    test "the v2 schema bounds system and id (length); a poisoned oversize ref cannot be appended",
         %{tenant_id: tenant_id} do
      record_id = Ecto.UUID.generate()

      check = fn ref ->
        validate(
          "ENTITY_RECORD_CREATED",
          created_payload(record_id, %{"external_ref" => ref}),
          tenant_id
        )
      end

      assert :ok =
               check.(%{
                 "system" => String.duplicate("a", 64),
                 "id" => String.duplicate("x", 255)
               })

      for bad <- [
            %{"system" => String.duplicate("a", 65), "id" => "1"},
            %{"system" => "", "id" => "1"},
            %{"system" => "a", "id" => ""},
            %{"system" => "a", "id" => String.duplicate("x", 256)},
            # maxLength counts characters while the parser counts bytes: 256 characters fail too.
            %{"system" => "a", "id" => String.duplicate("ž", 256)}
          ] do
        assert {:error, {:payload_validation_failed, [_ | _]}} = check.(bad)
      end

      # Odd-but-within-length values pass the schema (its `pattern` is inert in the platform's
      # JSON Schema subset); the parser and the projector are the gate for those.
      assert :ok = check.(%{"system" => "SAP", "id" => "1"})
    end

    test "UPDATED payloads carry no ref: the v1 schema rejects an external_ref key", %{
      tenant_id: tenant_id
    } do
      payload =
        created_payload(Ecto.UUID.generate(), %{"external_ref" => %{"system" => "a", "id" => "1"}})

      assert {:error, {:payload_validation_failed, [_ | _]}} =
               validate("ENTITY_RECORD_UPDATED", payload, tenant_id)

      assert :ok =
               validate("ENTITY_RECORD_UPDATED", created_payload(Ecto.UUID.generate()), tenant_id)
    end

    test "an upgraded tenant (CREATED at v1 only) is replayed to v2 by replay_migrations/2; UPDATED/DELETED stay 1; re-seeding is a no-op",
         %{schema: schema, tenant_id: tenant_id} do
      v1_schema = %{
        "type" => "object",
        "required" => ["entity_type", "entity_def_version", "record_id", "field_values"],
        "properties" => %{
          "entity_type" => %{"type" => "string"},
          "entity_def_version" => %{"type" => "string"},
          "record_id" => %{"type" => "string"},
          "field_values" => %{"type" => "object"}
        },
        "additionalProperties" => false
      }

      # Put the tenant back at the pre-change state: CREATED registered at v1 only.
      Repo.delete_all(from(e in EventType, where: e.name == "ENTITY_RECORD_CREATED"),
        prefix: schema
      )

      assert {:ok, _} =
               Registry.register_type(
                 %{
                   name: "ENTITY_RECORD_CREATED",
                   schema_version: 1,
                   json_schema: v1_schema,
                   description: "pre-change v1"
                 },
                 tenant_id
               )

      assert rows(schema, "ENTITY_RECORD_CREATED") == [1]

      payload =
        created_payload(Ecto.UUID.generate(), %{"external_ref" => %{"system" => "a", "id" => "1"}})

      assert {:error, {:payload_validation_failed, [_ | _]}} =
               validate("ENTITY_RECORD_CREATED", payload, tenant_id)

      assert {:ok, _applied} = TenantProvisioning.replay_migrations(tenant_id)

      assert rows(schema, "ENTITY_RECORD_CREATED") == [1, 2]
      assert Registry.max_schema_version("ENTITY_RECORD_CREATED", schema) == 2
      assert Registry.max_schema_version("ENTITY_RECORD_UPDATED", schema) == 1
      assert Registry.max_schema_version("ENTITY_RECORD_DELETED", schema) == 1
      assert :ok = validate("ENTITY_RECORD_CREATED", payload, tenant_id)

      # Re-seeding the upgraded tenant hits the duplicate case: nothing registered.
      assert {:ok, %{registered: [], skipped: skipped}} = EventTypes.seed!(schema)

      assert Enum.sort(skipped) ==
               ~w(ENTITY_RECORD_CREATED ENTITY_RECORD_DELETED ENTITY_RECORD_UPDATED)

      assert rows(schema, "ENTITY_RECORD_CREATED") == [1, 2]
    end

    test "a ref-carrying create is appended through the event store under v2", %{schema: schema} do
      {:ok, instance_id} = EntityTypeInstance.get_or_create("customer", schema)
      record_id = Ecto.UUID.generate()

      append_event!(
        schema,
        instance_id,
        "ENTITY_RECORD_CREATED",
        created_payload(record_id, %{"external_ref" => %{"system" => "1c", "id" => "42"}})
      )

      assert [%{payload: %{"external_ref" => %{"system" => "1c", "id" => "42"}}}] =
               Repo.all(
                 from(e in EventStore.Event, where: e.event_type == "ENTITY_RECORD_CREATED"),
                 prefix: schema
               )
    end
  end

  # --- T10: projector carries the ref ----------------------------------------------------------

  describe "T10 projector" do
    setup %{schema: schema} do
      assert {:ok, _seed_result} = EventTypes.seed!(schema)
      :ok
    end

    defp seed_stream!(schema) do
      {:ok, instance_id} = EntityTypeInstance.get_or_create("customer", schema)
      v = "aaaaaaaaaaaaaaaa"
      ref = %{"system" => "1c", "id" => "42"}

      kept = Ecto.UUID.generate()
      updated = Ecto.UUID.generate()
      deleted = Ecto.UUID.generate()
      plain = Ecto.UUID.generate()

      append_event!(
        schema,
        instance_id,
        "ENTITY_RECORD_CREATED",
        created_payload(kept, %{"external_ref" => ref})
      )

      append_event!(
        schema,
        instance_id,
        "ENTITY_RECORD_CREATED",
        created_payload(updated, %{"external_ref" => %{"system" => "1c", "id" => "43"}})
      )

      append_event!(
        schema,
        instance_id,
        "ENTITY_RECORD_CREATED",
        created_payload(deleted, %{"external_ref" => %{"system" => "sap", "id" => "42"}})
      )

      append_event!(schema, instance_id, "ENTITY_RECORD_CREATED", created_payload(plain))

      for _ <- 1..2 do
        append_event!(schema, instance_id, "ENTITY_RECORD_UPDATED", %{
          "entity_type" => "customer",
          "entity_def_version" => v,
          "record_id" => updated,
          "field_values" => %{"customer_name" => "Changed #{System.unique_integer([:positive])}"}
        })
      end

      append_event!(schema, instance_id, "ENTITY_RECORD_DELETED", %{
        "entity_type" => "customer",
        "entity_def_version" => v,
        "record_id" => deleted
      })

      %{kept: kept, updated: updated, deleted: deleted, plain: plain}
    end

    test "replay_record/3 sets the ref on CREATED and carries it across UPDATED (twice) and DELETED; a ref-less record is nil/nil",
         %{schema: schema} do
      ids = seed_stream!(schema)

      assert {:ok, %{external_system: "1c", external_id: "42"}} =
               Projector.replay_record("customer", ids.kept, schema)

      assert {:ok,
              %{
                external_system: "1c",
                external_id: "43",
                last_event_type: "ENTITY_RECORD_UPDATED"
              }} =
               Projector.replay_record("customer", ids.updated, schema)

      assert {:ok, %{external_system: "sap", external_id: "42", deleted: true}} =
               Projector.replay_record("customer", ids.deleted, schema)

      assert {:ok, %{external_system: nil, external_id: nil}} =
               Projector.replay_record("customer", ids.plain, schema)
    end

    test "rebuild_projection/2 (write_snapshots/3) overwrites stale refs with the ones folded from the events",
         %{schema: schema} do
      ids = seed_stream!(schema)

      # Pre-populate STALE rows (wrong refs, including a ref on the ref-less record) so the
      # assertions below can only pass if write_snapshots/3 passes the folded pair through.
      for {record_id, n} <- Enum.with_index(Map.values(ids)) do
        %Latest{}
        |> Latest.insert_changeset(%{
          entity_type: "customer",
          record_id: record_id,
          field_values: %{"stale" => true},
          entity_def_version: <<0>>,
          last_event_global_seq: 1,
          external_system: "stale",
          external_id: "stale-#{n}"
        })
        |> Repo.insert!(prefix: schema)
      end

      assert {:ok, row} = Latest.get_by_external_ref("customer", "stale", "stale-0", schema)
      assert row.field_values == %{"stale" => true}

      expected = %{
        ids.kept => {"1c", "42"},
        ids.updated => {"1c", "43"},
        ids.deleted => {"sap", "42"},
        ids.plain => {nil, nil}
      }

      assert {:ok, %{records_rebuilt: 4}} =
               Projector.rebuild_projection(schema, entity_type: "customer")

      for {record_id, pair} <- expected do
        assert {:ok, row} = Latest.get(record_id, "customer", schema)
        assert {row.external_system, row.external_id} == pair
      end

      # The rebuilt index serves the lookup, deleted rows included.
      assert {:ok, %{record_id: record_id, deleted: true}} =
               Latest.get_by_external_ref("customer", "sap", "42", schema)

      assert record_id == ids.deleted
    end

    test "external_ref_pair/2: absent is NULL/NULL; a valid ref is the pair; a malformed or invalid one is an explicit corrupt-stream error" do
      id = Ecto.UUID.generate()
      error = {:error, {:corrupt_event_stream, {:invalid_external_ref, id}}}

      assert Projector.external_ref_pair(%{}, id) == {:ok, {nil, nil}}

      assert Projector.external_ref_pair(
               %{"external_ref" => %{"system" => "1c", "id" => "42"}},
               id
             ) == {:ok, {"1c", "42"}}

      for bad <- [
            "1c:42",
            nil,
            [],
            %{"system" => "1c"},
            %{"id" => "42"},
            %{"system" => "SAP", "id" => "1"},
            %{"system" => "1c", "id" => "a\u200Bb"},
            %{"system" => "1c", "id" => "1", "extra" => "x"}
          ] do
        assert Projector.external_ref_pair(%{"external_ref" => bad}, id) == error
      end
    end

    test "a stream whose CREATED carries a schema-valid but unparseable ref fails replay and rebuild explicitly",
         %{schema: schema} do
      {:ok, instance_id} = EntityTypeInstance.get_or_create("customer", schema)
      record_id = Ecto.UUID.generate()

      # Within the schema's length bounds (so it is appended) but not a valid system slug.
      append_event!(
        schema,
        instance_id,
        "ENTITY_RECORD_CREATED",
        created_payload(record_id, %{"external_ref" => %{"system" => "SAP", "id" => "1"}})
      )

      assert {:error, {:corrupt_event_stream, {:invalid_external_ref, ^record_id}}} =
               Projector.replay_record("customer", record_id, schema)

      assert {:error, {:corrupt_event_stream, {:invalid_external_ref, ^record_id}}} =
               Projector.rebuild_projection(schema, entity_type: "customer")
    end

    test "a record written through Records.create_record/2 and updated stays NULL/NULL; live and rebuilt agree",
         %{schema: schema} do
      create_active_definition!(schema, "widget")

      attrs = fn extra ->
        Map.merge(
          %{
            entity_type: "widget",
            field_values: %{"customer_name" => "A"},
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate()
          },
          extra
        )
      end

      assert {:ok, %{record: record}} = Records.create_record(attrs.(%{}), schema)
      assert {record.external_system, record.external_id} == {nil, nil}

      assert {:ok, %{record: updated}} =
               Records.update_record(attrs.(%{record_id: record.record_id}), schema)

      assert {updated.external_system, updated.external_id} == {nil, nil}

      assert {:ok, _} = Projector.rebuild_projection(schema, entity_type: "widget")
      assert {:ok, rebuilt} = Latest.get(record.record_id, "widget", schema)
      assert {rebuilt.external_system, rebuilt.external_id} == {nil, nil}
    end
  end
end
