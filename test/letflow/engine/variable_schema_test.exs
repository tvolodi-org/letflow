defmodule Letflow.Engine.VariableSchemaTest.NeverQueriedRepo do
  @moduledoc """
  A `repo` double for `Letflow.Engine.VariableSchema`'s AC7 fail-closed tests whose
  every callback **raises**.

  `VariableSchema.fetch_schemas/3` and `variable_validations/5` take `repo` as a plain
  module argument (guarded only by `is_atom/1`), so passing this module turns "issues
  no query" into something the test *proves* rather than argues: if the guard order
  ever regresses and a query is constructed, the call raises and the test fails.
  Reuses SECURITY-REVIEWER's own step-2b technique.
  """

  @raise_message "VariableSchema issued a query despite a fail-closed guard (AC7 / INV-VS-1)"

  def all(_queryable), do: raise(@raise_message)
  def all(_queryable, _opts), do: raise(@raise_message)
  def one(_queryable), do: raise(@raise_message)
  def one(_queryable, _opts), do: raise(@raise_message)
  def query(_sql), do: raise(@raise_message)
  def query(_sql, _params), do: raise(@raise_message)
  def query(_sql, _params, _opts), do: raise(@raise_message)
end

defmodule Letflow.Engine.VariableSchemaTest do
  @moduledoc """
  Storage-side and lookup-side tests for REQ-109's `Letflow.Engine.VariableSchema`:
  the migration (AC1), the table's columns and its `UNIQUE (definition_id,
  variable_key)` constraint (AC2), the every-incoming-key lookup rule (AC5, unit half —
  revised 2026-08-20, GH#300/ISS-0077, decision 0007), and the fail-closed
  prefix/`definition_id` guards (AC7).

  The end-to-end criteria — AC3's rejection driven through the real
  `Letflow.Engine.complete_task/3`, AC4's conforming overwrite, AC5's two
  `complete_task/3` scenarios and AC6's cross-tenant isolation — live in
  `test/letflow/engine_variable_schema_merge_test.exs`. See `test/specs/REQ-109.md`
  for the full per-test rationale, including why ACs 8-13 (documentation/source-state
  criteria) carry no ExUnit test.

  Real Postgres, no mocked database (`test_developer_guide.md` T-1); self-contained
  fixtures provisioning this file's own tenant schema (T-4), mirroring
  `engine_complete_task_test.exs`'s `provisioned_tenant/0` + Sandbox `:auto` +
  `async: false` pattern exactly.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Definitions
  alias Letflow.Engine.VariableSchema
  alias Letflow.Engine.VariableSchemaTest.NeverQueriedRepo
  alias Letflow.TenantFixture

  # The manifest version under test -- lib/letflow/tenant_provisioning.ex:361.
  @variable_schemas_migration_version 20_260_821_000_002

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  # The set of migration versions actually recorded against this tenant's schema --
  # read straight from the live catalog, not from TenantProvisioning.replay_migrations/2's
  # return value, since TenantFixture.provisioned_tenant!/1 does not surface that return
  # value to its caller. Equivalent under both of the fixture's provisioning paths:
  # `:replay` populates schema_migrations by actually running the migrations, and
  # `:clone` (the fixture's default) copies the fully-migrated template's
  # schema_migrations rows verbatim -- either way, a freshly provisioned tenant's
  # schema_migrations holds exactly the full registered set.
  defp applied_versions_in(schema_name) do
    %{rows: rows} = Repo.query!(~s(SELECT version FROM "#{schema_name}".schema_migrations))
    rows |> Enum.map(fn [version] -> version end) |> Enum.sort()
  end

  # Returns the schema name AND the versions actually applied -- AC1's manifest half
  # is asserted from that list rather than from a source grep.
  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req109-vs",
        display_name: "REQ-109 VariableSchema Test Tenant"
      )

    %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      applied_versions: applied_versions_in(schema_name)
    }
  end

  defp unique_name do
    "req109-vs-def-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Copied from test/letflow/definitions/migrations_test.exs:160-186 (the established
  # helper for this assertion class). `confdeltype` is pg_constraint's referential
  # action as a single byte -- 'a' NO ACTION, 'r' RESTRICT, 'c' CASCADE, 'n' SET NULL,
  # 'd' SET DEFAULT -- cast to text so Postgrex hands back a plain binary. This is the
  # ONLY place the referential action is observable: no DDL text distinguishes
  # `on_delete: :restrict` from a cascade.
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

  # START -> task(HUMAN_TASK) -> END. The plainest activatable graph; this file never
  # starts an instance, it only needs a real process_definitions row for the FK.
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp definition!(schema_name) do
    attrs = %{
      name: unique_name(),
      version: "1.0.0",
      graph: graph_human_task_end(),
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Definitions.create(attrs, prefix: schema_name)
    definition
  end

  # Direct Repo.insert against the provisioned tenant schema -- REQ-109 builds no
  # registration/INSERT path (REQ-078/REQ-082 own it, design section 9.1), so the
  # requirement's own acceptance criteria seed rows this way by construction.
  defp seed_schema_row(schema_name, definition_id, variable_key, json_schema, attrs \\ %{}) do
    %VariableSchema{}
    |> VariableSchema.changeset(
      Map.merge(
        %{
          definition_id: definition_id,
          variable_key: variable_key,
          json_schema: json_schema
        },
        attrs
      )
    )
    |> Repo.insert(prefix: schema_name)
  end

  defp seed_schema_row!(schema_name, definition_id, variable_key, json_schema, attrs \\ %{}) do
    assert {:ok, row} =
             seed_schema_row(schema_name, definition_id, variable_key, json_schema, attrs)

    row
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- the migration applies to a freshly provisioned tenant schema, and is
  # registered in @tenant_scoped_migration_manifest. Both halves proved by running
  # provisioning, not by reading the migration file.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- migration applies to a fresh tenant schema" do
    test "replay_migrations applies the version and the table reads back empty" do
      %{schema_name: schema_name, applied_versions: applied_versions} = provisioned_tenant()

      # Manifest half: replay_migrations/1 runs ONLY the manifest list
      # (tenant_provisioning.ex:238-263), so the version appearing here is direct
      # evidence the manifest entry is picked up by the runner -- a source grep would
      # only prove the tuple is typed there.
      assert @variable_schemas_migration_version in applied_versions

      # Apply half: the table exists inside the tenant schema and is empty.
      assert Repo.all(VariableSchema, prefix: schema_name) == []
    end

    test "the table lives in the tenant schema and not in public" do
      %{schema_name: schema_name} = provisioned_tenant()

      # What `if prefix() do` is for: with a nil prefix the migration is a no-op, so
      # `public.variable_schemas` must not exist while the tenant one does.
      assert %{rows: [[nil]]} =
               Repo.query!("SELECT to_regclass('public.variable_schemas')", [])

      assert %{rows: [[regclass]]} =
               Repo.query!("SELECT to_regclass($1)", ["#{schema_name}.variable_schemas"])

      refute is_nil(regclass)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- the columns, and the UNIQUE (definition_id, variable_key) constraint
  # demonstrated by actual failing inserts.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- columns and the unique constraint" do
    test "a seeded row reads back with every AC2-named column populated" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = definition!(schema_name)

      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"}, %{
        description: "the approved amount"
      })

      assert [row] = Repo.all(VariableSchema, prefix: schema_name)
      assert row.definition_id == definition.id
      assert row.variable_key == "amount"
      assert row.json_schema == %{"type" => "number"}
      assert row.description == "the approved amount"
      # created_at is a literal column with a DB-side default, read back after write.
      refute is_nil(row.created_at)
    end

    test "a duplicate pair through changeset/2 returns the mapped constraint error" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = definition!(schema_name)

      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"})

      assert {:error, changeset} =
               seed_schema_row(schema_name, definition.id, "amount", %{"type" => "string"})

      # Ecto attaches a multi-column unique_constraint to the first named field.
      assert {"has already been taken", _meta} = changeset.errors[:definition_id]

      # Nothing was written by the rejected insert.
      assert [_only_one] = Repo.all(VariableSchema, prefix: schema_name)
    end

    test "a duplicate pair inserted as a raw struct is rejected by Postgres itself" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = definition!(schema_name)

      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"})

      # No changeset, so no constraint declaration to map the 23505 -- Ecto raises
      # instead, naming the index Postgres actually rejected against. This proves the
      # UNIQUE index exists in the DATABASE, not merely that Elixir declares it, and
      # pins the index name the migration created.
      error =
        assert_raise Ecto.ConstraintError, fn ->
          Repo.insert!(
            %VariableSchema{
              definition_id: definition.id,
              variable_key: "amount",
              json_schema: %{"type" => "string"}
            },
            prefix: schema_name
          )
        end

      assert error.constraint == "uq_variable_schema_definition_key"
      assert error.type == :unique
    end

    test "definition_id's FK resolves to the tenant's own process_definitions, ON DELETE RESTRICT" do
      %{schema_name: schema_name} = provisioned_tenant()

      foreign_keys = foreign_keys_on(schema_name, "variable_schemas")

      assert [foreign_key] = foreign_keys,
             "expected exactly one foreign key on variable_schemas, got #{inspect(foreign_keys)}"

      assert foreign_key.column == "definition_id"
      assert foreign_key.referenced_column == "id"

      # The property is not "an FK exists" but WHICH process_definitions it resolves
      # to. A tenant-scoped migration whose FK bound to public.process_definitions
      # would be a cross-schema reference (INV-1) -- and would still satisfy every
      # other assertion in this test.
      assert foreign_key.referenced_table == "#{schema_name}.process_definitions",
             "the variable_schemas FK references #{foreign_key.referenced_table}, not the tenant's own process_definitions"

      # `on_delete: :restrict` is a stated, reasoned divergence from R-Co's ON DELETE
      # CASCADE, committed to in the migration header (design section 2.2). confdeltype
      # is the only place that choice is observable at all.
      assert foreign_key.on_delete == "r",
             "the variable_schemas FK's ON DELETE action is #{inspect(foreign_key.on_delete)}, expected \"r\" (RESTRICT) per the migration header"

      refute foreign_key.on_delete == "c",
             "the variable_schemas FK carries R-Co's ON DELETE CASCADE, which the migration header explicitly diverges from"
    end

    test "a definition_id matching no process_definitions row is rejected by the FK" do
      %{schema_name: schema_name} = provisioned_tenant()

      # AC2's preferred "actual failing insert" form, for the FK clause rather than the
      # UNIQUE clause: a well-formed UUID that simply has no referent.
      error =
        assert_raise Ecto.ConstraintError, fn ->
          seed_schema_row!(schema_name, Ecto.UUID.generate(), "amount", %{"type" => "number"})
        end

      assert error.type == :foreign_key
      assert error.constraint == "variable_schemas_definition_id_fkey"

      assert Repo.all(VariableSchema, prefix: schema_name) == []
    end

    test "a different variable_key for the same definition_id inserts fine" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = definition!(schema_name)

      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"})
      seed_schema_row!(schema_name, definition.id, "note", %{"type" => "string"})

      # The constraint is on the PAIR, not on definition_id alone.
      assert length(Repo.all(VariableSchema, prefix: schema_name)) == 2
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- fail-closed prefix and definition_id guards, with zero queries issued.
  # Every call below hands VariableSchema the NeverQueriedRepo double, so reaching a
  # query is a test failure by construction rather than something argued in prose.
  # ---------------------------------------------------------------------------------

  describe "AC7 -- fail-closed prefix guard" do
    test "fetch_schemas/3 rejects a missing, nil, empty or non-binary prefix" do
      id = Ecto.UUID.generate()

      assert {:error, :missing_prefix} = VariableSchema.fetch_schemas(NeverQueriedRepo, id, [])

      assert {:error, :missing_prefix} =
               VariableSchema.fetch_schemas(NeverQueriedRepo, id, prefix: nil)

      assert {:error, :missing_prefix} =
               VariableSchema.fetch_schemas(NeverQueriedRepo, id, prefix: "")

      assert {:error, :missing_prefix} =
               VariableSchema.fetch_schemas(NeverQueriedRepo, id, prefix: :not_a_binary)
    end

    test "variable_validations/5 rejects a missing, nil, empty or non-binary prefix" do
      id = Ecto.UUID.generate()
      current = %{"amount" => 100}
      incoming = %{"amount" => "not-a-number"}

      for opts <- [[], [prefix: nil], [prefix: ""], [prefix: :not_a_binary]] do
        assert {:error, :missing_prefix} =
                 VariableSchema.variable_validations(
                   NeverQueriedRepo,
                   id,
                   current,
                   incoming,
                   opts
                 )
      end
    end

    test "the prefix check precedes the empty-candidate fast path" do
      # Design section 4.5 orders step 1 (prefix) before step 3 (the "nothing to
      # validate" fast path) deliberately, so a bad prefix fails closed even when the
      # lookup would have been skipped anyway. Reordering them would still satisfy
      # every other AC7 assertion -- this test is the only guard on that ordering.
      assert {:error, :missing_prefix} =
               VariableSchema.variable_validations(
                 NeverQueriedRepo,
                 Ecto.UUID.generate(),
                 %{},
                 %{},
                 prefix: nil
               )
    end

    test "a nil or malformed definition_id fails closed with its own distinct error" do
      # Design section 6.4: instance_projection.ex:113 types definition_id as a
      # nullable Ecto.UUID, so nil is representable; a malformed value in a `where`
      # would raise Ecto.Query.CastError rather than return a typed error.
      assert {:error, :invalid_definition_id} =
               VariableSchema.fetch_schemas(NeverQueriedRepo, nil, prefix: "some_tenant_schema")

      assert {:error, :invalid_definition_id} =
               VariableSchema.fetch_schemas(NeverQueriedRepo, "not-a-uuid",
                 prefix: "some_tenant_schema"
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 (unit half) -- every incoming key reaches the lookup, new or overwrite alike
  # (revised 2026-08-20, GH#300/ISS-0077, decision 0007 -- previously only overwrite
  # candidates reached the lookup; a brand-new key short-circuited before any query),
  # and only a truly empty incoming_variables map issues zero queries (INV-VS-2,
  # INV-VS-3).
  # ---------------------------------------------------------------------------------

  describe "AC5 -- every incoming key, new or overwrite, at the lookup level" do
    test "an empty incoming_variables map yields no validations and issues no query" do
      # Nothing to validate -- the candidate set is empty regardless of what
      # current_variables holds, and the fast path returns without touching
      # the repo, which NeverQueriedRepo proves.
      assert {:ok, %{}} ==
               VariableSchema.variable_validations(
                 NeverQueriedRepo,
                 Ecto.UUID.generate(),
                 %{"a" => 1},
                 %{},
                 prefix: "some_tenant_schema"
               )
    end

    test "a brand-new key with a seeded row yields a {:rejected, _} outcome, same as an overwrite candidate would" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = definition!(schema_name)
      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"})

      # "amount" is absent from current_variables -- a brand-new key, not an
      # overwrite candidate -- but it still reaches the lookup and is still
      # validated against its seeded schema (decision 0007 adopts R-Co's
      # instance.zig:2389-2430 Phase 1: every output key is checked
      # unconditionally, collision detection is separate).
      assert {:ok, validations} =
               VariableSchema.variable_validations(
                 Repo,
                 definition.id,
                 %{},
                 %{"amount" => "not-a-number"},
                 prefix: schema_name
               )

      assert %{"amount" => {:rejected, [failure]}} = validations
      assert failure.field_path == "/amount"
    end

    test "an overwrite candidate with a seeded row yields a {:rejected, _} outcome" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = definition!(schema_name)
      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"})

      assert {:ok, validations} =
               VariableSchema.variable_validations(
                 Repo,
                 definition.id,
                 %{"amount" => 100},
                 %{"amount" => "not-a-number"},
                 prefix: schema_name
               )

      assert %{"amount" => {:rejected, [failure]}} = validations
      # The wrapper uses the variable's own key, so the failure names the real
      # variable (design section 4.3, superseding req049 section 7.1's "/value").
      assert failure.field_path == "/amount"
    end

    test "an overwrite candidate with no row is omitted from the map entirely" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = definition!(schema_name)
      # A row exists, but for a DIFFERENT key -- so the query really runs and really
      # returns rows, and omission is per-key rather than "the table was empty".
      seed_schema_row!(schema_name, definition.id, "other", %{"type" => "number"})

      assert {:ok, %{}} ==
               VariableSchema.variable_validations(
                 Repo,
                 definition.id,
                 %{"amount" => 100},
                 %{"amount" => "anything at all"},
                 prefix: schema_name
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # changeset/2 -- REQ-109's tests are its first consumer (zero callers in lib/).
  # ---------------------------------------------------------------------------------

  describe "changeset/2 -- REQ-109's tests are its first consumer" do
    test "definition_id, variable_key and json_schema are required" do
      changeset = VariableSchema.changeset(%VariableSchema{}, %{})

      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:definition_id]
      assert {"can't be blank", _} = changeset.errors[:variable_key]
      assert {"can't be blank", _} = changeset.errors[:json_schema]
    end

    test "description is optional and json_schema is cast as a map" do
      changeset =
        VariableSchema.changeset(%VariableSchema{}, %{
          definition_id: Ecto.UUID.generate(),
          variable_key: "amount",
          json_schema: %{"type" => "number", "minimum" => 0}
        })

      assert changeset.valid?

      assert Ecto.Changeset.get_change(changeset, :json_schema) == %{
               "type" => "number",
               "minimum" => 0
             }

      # Deliberately NOT asserted: that json_schema is a well-formed JSON Schema
      # document. The moduledoc states outright that changeset/2 does not check this
      # (design section 11.3, OQ-3) -- asserting it would certify a guarantee that
      # does not exist.
    end
  end

  # ---------------------------------------------------------------------------------
  # validations_for/3 -- UNIT TEST OF THE PURE FUNCTION ONLY.
  #
  # SCOPE, stated explicitly: this exercises validations_for/3's {:ok, _not_a_map}
  # branch by handing it a hand-built `schemas` map. It does NOT cover a production
  # failure mode. fetch_schemas/3 -- the branch's only production caller -- selects
  # json_schema as a typed :map field, so Ecto's :map loader runs first and returns
  # :error for every non-object jsonb value, which Ecto turns into a raise at load
  # time before validations_for/3 is ever reached. Verified by execution:
  # Ecto.Type.load(:map, %{"a" => 1}) -> {:ok, ...}; Ecto.Type.load(:map, [1,2] |
  # "str" | 42 | true) -> :error. The branch is therefore unreachable from production
  # (ISS-0089 / GH#306). A DB-seeded version of this test would certify a defence the
  # production path bypasses, so it is not written.
  # ---------------------------------------------------------------------------------

  describe "validations_for/3 unit -- a non-map json_schema" do
    test "is omitted rather than raising, and is logged naming only the key" do
      log =
        capture_log(fn ->
          assert VariableSchema.validations_for(
                   %{"amount" => [1, 2, 3]},
                   ["amount"],
                   %{"amount" => "not-a-number"}
                 ) == %{}
        end)

      assert log =~ "non-map json_schema"
      assert log =~ "amount"
      # Neither the stored document nor the variable's value is logged -- both are
      # tenant data (design section 6.3).
      refute log =~ "not-a-number"
    end

    test "map-valued entries alongside it are still evaluated normally" do
      result =
        VariableSchema.validations_for(
          %{"bad" => "not-a-schema", "amount" => %{"type" => "number"}},
          ["bad", "amount"],
          %{"bad" => 1, "amount" => 42}
        )

      assert result == %{"amount" => :ok}
    end
  end
end
