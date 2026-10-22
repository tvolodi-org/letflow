defmodule Letflow.Modules.Exam.PackInstallTest do
  @moduledoc """
  REQ-328 -- performs a REAL `Letflow.Definitions.SolutionPack.install/3` of
  `priv/modules/exam/pack.json` against a real provisioned tenant, then
  activates, writes real records, and reads them back.

  This is the test that makes S10 phase P2's exit condition ("a tenant with a
  working question bank and exam configuration, and zero exam-specific Elixir")
  testable. Its value is entirely in running the real install path -- nothing
  here asserts that an install *would* work.

  ## Two different things in two different places -- do not conflate them

  `install/3`'s RESULT map carries `status: "installed"` for every entity
  definition: `solution_pack.ex`'s `installed_entity_definition_maps/1`
  hardcodes that literal string unconditionally. The PERSISTED
  `Letflow.Entities.EntityDefinition` row's `status` is the atom `:inactive`
  (0026 section 2). Asserting `"inactive"` on the result map would fail against
  correct platform behaviour. Both are asserted below, separately.

  ## Activation order matters; install order does not

  `install/3` writes `:inactive` metadata rows and emits no DDL, so the order of
  `entity_definitions` in the pack document is irrelevant to it. Table creation
  is lazy and gated on the ACTIVE definition
  (`TenantProvisioning.ensure_entity_table/2`), and `resolve_fk_target_tables/1`
  is a pure `"entity_" <> name` concat with no existence check -- so creating a
  table for an entity type whose FK target table does not exist yet emits
  `REFERENCES` against a missing table and fails as an opaque Postgres 42P01.
  `@activation_order` below is the FK DAG's topological order; see
  `priv/modules/exam/README.md`.

  REQ-411: moved from `test/letflow/packs/bilimbaga_pack_install_test.exs`;
  paths updated to `priv/modules/exam/`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ExportImport
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @pack_path Path.join([File.cwd!(), "priv", "modules", "exam", "pack.json"])
  @definitions_dir Path.join([File.cwd!(), "priv", "modules", "exam", "entity_definitions"])
  @generator_path Path.join([File.cwd!(), "priv", "modules", "exam", "generate_pack.exs"])

  # The ten authoring types (activated and exercised below) ...
  @authoring_types ~w(
    category tag question answer_option question_tag
    exam exam_section exam_question_rule exam_question_rule_tag exam_manual_question
  )

  # ... plus the six runtime/result types GH #2596 added to the pack (the install check
  # requires every `manages_entity_types` name to be in the pack). Installed inactive, like
  # the ten; this test does not activate them.
  @runtime_types ~w(
    session session_question session_answer session_event session_question_score certificate
  )

  @entity_types @authoring_types ++ @runtime_types

  # Topological order over the ten documents' own `foreign_keys`:
  #   category, tag, exam       -- zero FKs
  #   question                  -> category
  #   exam_section              -> exam
  #   answer_option             -> question
  #   question_tag              -> question, tag
  #   exam_question_rule        -> exam, exam_section, category
  #   exam_question_rule_tag    -> exam_question_rule, tag
  #   exam_manual_question      -> exam_question_rule, question
  @activation_order ~w(
    category tag exam
    question exam_section
    answer_option question_tag exam_question_rule
    exam_question_rule_tag exam_manual_question
  )

  defp pack_document, do: @pack_path |> File.read!() |> Jason.decode!()

  defp tenant do
    fixture = Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "req328-pack-install")

    # The clone-from-template path does not copy event_type_registry CONTENTS
    # (see Letflow.Test.TenantTemplate's moduledoc), and Records.create_record/2
    # rejects a write into a tenant with no registered event types with
    # {:error, :unknown_event_type}. Seeded here, exactly as
    # test/letflow/entities/query_joins_test.exs's own fixture does.
    assert {:ok, _seed_result} = Letflow.Entities.EventTypes.seed!(fixture.schema_name)
    Letflow.ExamFixtures.mark_exam_installed!(fixture.schema_name)

    # `solution_pack_installs` is a GLOBAL table by REQ-041's own design (see
    # solution_pack.ex's "Tenant scoping (INV-1)" moduledoc section), and it
    # carries an FK to `tenants`. TenantFixture's own teardown deletes the
    # tenant row and knows nothing about pack installs, so without this the
    # tenant DELETE raises a foreign_key_violation in on_exit AFTER an
    # otherwise-passing test. Registered after the fixture's own on_exit, so
    # ExUnit runs it FIRST (callbacks run in reverse registration order).
    on_exit(fn ->
      Letflow.Repo.delete_all(
        from(i in Letflow.Definitions.SolutionPackInstall,
          where: i.tenant_id == ^fixture.tenant_id
        )
      )

      # REQ-379: capture_artefact_bases/4 now writes solution_pack_artefact_bases
      # rows carrying the same tenant_id -> tenants FK -- same class of
      # global-table FK as solution_pack_installs above.
      Letflow.Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^fixture.tenant_id)
      )

      # Same class of global-table FK: entity_column_promotions is global and
      # references tenants. query_joins_test.exs's own hand-rolled fixture
      # deletes it for exactly this reason.
      Letflow.Repo.delete_all(
        from(cp in ColumnPromotion, where: cp.tenant_id == ^fixture.tenant_id)
      )
    end)

    fixture
  end

  # REQ-297's promotion mechanism: registering + running a ColumnPromotion is
  # what creates the per-entity-type table (carrying the entity type's FULL
  # promoted-column set, FK REFERENCES clauses included) and what makes the live
  # `Records.create_record/2` dual-write populate that column. Activation alone
  # creates no table. See README.md's install -> activate -> promote sequence.
  # ISS-0648 fix note: `Letflow.Entities.Definitions.activate_definition/4`
  # now auto-registers+runs column promotion (landing at "ddl_applied") for
  # every attribute named by a `constraint_def.fields` entry, as part of
  # step 5's activation loop above -- so for an entity type declaring a
  # `constraints` entry (tag, question_tag, exam_question_rule,
  # exam_question_rule_tag), a `ColumnPromotion` row for one of its
  # constrained attributes may already exist (and already be "ddl_applied")
  # by the time this helper runs. Reuses the existing row instead of
  # assuming a fresh `register_column_promotion/4` call always succeeds (it
  # would hit the `entity_column_promotions` unique index otherwise) -- same
  # idempotent-lookup-then-run shape
  # `Letflow.Entities.Definitions.ensure_column_promotions/2` itself now
  # uses.
  defp promote!(tenant_id, entity_type, attribute, pg_type, opts \\ []) do
    spec =
      case Keyword.get(opts, :references_entity) do
        nil -> %{pg_type: pg_type, nullable: true}
        target -> %{pg_type: pg_type, nullable: true, references_entity: target}
      end

    row =
      case Repo.get_by(ColumnPromotion,
             tenant_id: tenant_id,
             entity_type: entity_type,
             attribute: attribute
           ) do
        nil ->
          assert {:ok, [row]} =
                   TenantProvisioning.register_column_promotion(entity_type, attribute, spec, [
                     tenant_id
                   ])

          row

        %ColumnPromotion{} = existing ->
          existing
      end

    assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
             TenantProvisioning.run_column_promotion(row.id)

    :ok
  end

  defp create_record!(schema, entity_type, field_values) do
    assert {:ok, %{record: record}} =
             Records.create_record(
               %{
                 entity_type: entity_type,
                 field_values: field_values,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )

    record
  end

  # ---------------------------------------------------------------------------
  # Provenance (AC1) -- pack.json IS committed, so drift from the ten source
  # files must fail the suite.
  # ---------------------------------------------------------------------------

  describe "provenance: the committed pack.json does not drift from its ten sources" do
    test "each embedded definition_json is structurally equal to its source file" do
      document = pack_document()

      for packed <- document["entity_definitions"] do
        source =
          @definitions_dir
          |> Path.join("#{packed["name"]}.json")
          |> File.read!()
          |> Jason.decode!()

        assert packed["definition_json"] == source,
               "pack.json's embedded #{packed["name"]} definition_json has drifted from " <>
                 "priv/modules/exam/entity_definitions/#{packed["name"]}.json -- " <>
                 "regenerate with: mix run priv/modules/exam/generate_pack.exs"
      end
    end

    test "the generator script that is the only permitted writer of pack.json exists" do
      assert File.exists?(@generator_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Document shape (AC2, AC3) -- asserted against the real module constants,
  # never a remembered string.
  # ---------------------------------------------------------------------------

  describe "pack-document shape" do
    test "carries all eight keys parse_document/1 fetches, plus exported_at" do
      document = pack_document()

      for key <- ~w(pack_id version bpm_export_schema_version definitions
                    service_catalog_entries variable_schemas entity_definitions manifest) do
        assert Map.has_key?(document, key), "missing key #{key}"
      end

      assert Map.has_key?(document, "exported_at")

      # Read from the module, not remembered.
      assert document["bpm_export_schema_version"] == ExportImport.export_schema_version()

      # Decision 0027: a non-empty array is permanently rejected.
      assert document["service_catalog_entries"] == []
      assert document["definitions"] == []
      assert document["variable_schemas"] == []
    end

    test "entity_definitions carries exactly the sixteen types (ten authoring + six runtime), correctly wrapped" do
      document = pack_document()
      packed = document["entity_definitions"]

      assert length(packed) == 16
      assert Enum.sort(Enum.map(packed, & &1["name"])) == Enum.sort(@entity_types)

      for entry <- packed do
        assert is_binary(entry["entity_definition_id"])
        assert is_binary(entry["name"])
        assert is_binary(entry["display_name"])
        assert is_binary(entry["logical_shape_version"])
        assert is_map(entry["definition_json"])

        # decode_logical_shape_version/1 calls Base.decode16(hex, case: :lower).
        assert {:ok, _raw} = Base.decode16(entry["logical_shape_version"], case: :lower)

        # Wrapper name/display_name must agree with the nested document's own.
        assert entry["name"] == entry["definition_json"]["name"]
        assert entry["display_name"] == entry["definition_json"]["display_name"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # THE REAL INSTALL, and everything that depends on it. One test, because the
  # tenant is expensive and every later step builds on the same install.
  # ---------------------------------------------------------------------------

  describe "a real SolutionPack.install/3 against a real provisioned tenant" do
    test "installs, does not activate, then activates and serves a working question bank" do
      %{tenant_id: tenant_id, schema_name: schema} = tenant()
      actor_id = Ecto.UUID.generate()

      # ---- 1. THE REAL INSTALL -------------------------------------------
      assert {:ok, install_result} =
               SolutionPack.install(pack_document(), actor_id, prefix: schema)

      # Quoted verbatim into the run output -- the requirement's evidence.
      IO.puts("\n=== REQ-328 install_result (verbatim) ===")
      IO.puts(inspect(install_result, pretty: true, limit: :infinity, printable_limit: :infinity))
      IO.puts("=== end install_result ===\n")

      assert install_result.pack_id == "bilimbaga-question-bank"
      assert install_result.version == "1.0.0"
      assert is_binary(install_result.install_id)
      assert install_result.installed_definitions == []
      assert install_result.variable_schemas_written == 0
      assert install_result.warnings == []

      # ---- 2. sixteen entries, each status "installed" -- the literal string
      #         installed_entity_definition_maps/1 hardcodes. NOT "inactive".
      installed = install_result.installed_entity_definitions
      assert length(installed) == 16
      assert Enum.sort(Enum.map(installed, & &1.name)) == Enum.sort(@entity_types)
      assert Enum.all?(installed, &(&1.status == "installed"))
      assert Enum.uniq(Enum.map(installed, & &1.status)) == ["installed"]

      # ---- 3. role_mapping_checklist: every declared role unbound ---------
      checklist = install_result.role_mapping_checklist

      assert checklist == [
               %{role_name: "super_admin", bound: false},
               %{role_name: "examiner", bound: false},
               %{role_name: "department_admin", bound: false}
             ]

      # ...because none of them is one of the five platform roles.
      known = MapSet.new(Letflow.Api.Authorization.roles(), &Atom.to_string/1)
      assert Enum.all?(checklist, &(not MapSet.member?(known, &1.role_name)))

      # ---- 4a. the PERSISTED rows are :inactive -- the other of the two
      #          different things, in the other of the two different places.
      for entity_type <- @entity_types do
        assert {:ok, %EntityDefinition{status: :inactive}} =
                 Definitions.get_definition_by_name(entity_type, schema)
      end

      # ---- 4b. the cheapest REAL proof of non-activation: a write before
      #          activation is rejected for want of an ACTIVE definition.
      assert {:error, {:definition_not_found, "category"}} =
               Records.create_record(
                 %{
                   entity_type: "category",
                   field_values: %{
                     "name" => %{"kk" => "a", "ru" => "a", "en" => "a"},
                     "sort_order" => 1
                   },
                   actor_id: actor_id,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      # ---- 5. ACTIVATE in FK-dependency order ----------------------------
      for entity_type <- @activation_order do
        assert {:ok, %EntityDefinition{status: :active}} =
                 Definitions.activate_definition(entity_type, actor_id, "REQ-328 go-live", schema)
      end

      # ---- 5b. PROMOTE, in the same dependency order. Promotion is what
      #          creates each per-entity-type table (with its FK REFERENCES
      #          clauses) and what makes the live dual-write populate the
      #          promoted columns. A target's table must exist before a
      #          referencing table is created -- same DAG, same reason.
      # A promotion on entity type E creates E's table carrying E's FULL
      # promoted-column set -- which includes a REFERENCES clause for EVERY
      # fk_def E declares, not just the attribute being promoted. So every one
      # of E's FK TARGET tables must already exist. Verified empirically: with
      # exam_section unpromoted, promoting exam_question_rule.exam_id emitted
      # REFERENCES against a missing entity_exam_section and failed as
      # ERROR 42P01 (undefined_table). Hence one promotion per entity type,
      # in @activation_order.
      promote!(tenant_id, "category", "sort_order", "bigint")
      promote!(tenant_id, "tag", "name", "text")
      promote!(tenant_id, "exam", "status", "text")

      promote!(tenant_id, "question", "category_id", "uuid", references_entity: "category")
      promote!(tenant_id, "question", "difficulty", "text")
      promote!(tenant_id, "exam_section", "sort_order", "bigint")

      promote!(tenant_id, "answer_option", "sort_order", "bigint")
      promote!(tenant_id, "question_tag", "question_id", "uuid", references_entity: "question")
      promote!(tenant_id, "question_tag", "tag_id", "uuid", references_entity: "tag")
      promote!(tenant_id, "exam_question_rule", "exam_id", "uuid", references_entity: "exam")
      promote!(tenant_id, "exam_question_rule", "sort_order", "bigint")

      promote!(tenant_id, "exam_question_rule_tag", "rule_id", "uuid",
        references_entity: "exam_question_rule"
      )

      promote!(tenant_id, "exam_manual_question", "sort_order", "bigint")

      # ---- 6a. ISS-0624 IS FIXED -- THE :localized_text WRITE PATH WORKS --
      #
      # ISS-0624 (raised by this requirement) used to make a record write
      # against ANY definition carrying a `:localized_text` field raise
      # FunctionClauseError out of
      # `Letflow.Entities.Record.Validator.field_subschema/1`, because
      # `lib/letflow/entities/records.ex`'s `field_document/1` rebuilt each
      # field from the persisted JSONB without `locales`. That converter now
      # carries `locales` through (see its own moduledoc comment), so the
      # writes below -- category.name, question.stem, exam.title, each with
      # all three of kk/ru/en -- are real, asserted successes, not a
      # documented crash.
      assert {:ok, %{record: category}} =
               Records.create_record(
                 %{
                   entity_type: "category",
                   field_values: %{
                     "name" => %{
                       "kk" => "Qauipsizdik sanasy",
                       "ru" => "Osoznannaya bezopasnost",
                       "en" => "Security Awareness"
                     },
                     "track" => "security",
                     "sort_order" => 1
                   },
                   actor_id: actor_id,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      IO.puts("\n=== REQ-328 category :localized_text write (verbatim) ===")
      IO.puts(inspect(category, pretty: true, limit: :infinity, printable_limit: :infinity))
      IO.puts("=== end category write ===\n")

      assert {:ok, read_category} = Latest.get(category.record_id, "category", schema)

      assert read_category.field_values["name"] == %{
               "kk" => "Qauipsizdik sanasy",
               "ru" => "Osoznannaya bezopasnost",
               "en" => "Security Awareness"
             }

      # ---- 6b. tag, question, question_tag, exam and exam_question_rule --
      # all exercised for real against the installed-and-activated
      # definitions.
      tag = create_record!(schema, "tag", %{"name" => "passwords"})
      other_tag = create_record!(schema, "tag", %{"name" => "unrelated"})

      assert {:ok, read_tag} = Latest.get(tag.record_id, "tag", schema)
      assert read_tag.field_values["name"] == "passwords"

      # ---- 6c. THE PROMOTED FK IS A REAL POSTGRES REFERENCES -------------
      # (i) a question naming category.record_id is accepted, its
      #     :localized_text stem round-trips with all three locales; (ii) a
      #     question naming a nonexistent category_id is REJECTED by the
      #     database, not merely by application validation.
      assert {:ok, %{record: question}} =
               Records.create_record(
                 %{
                   entity_type: "question",
                   field_values: %{
                     "category_id" => category.record_id,
                     "difficulty" => "easy",
                     "type" => "single",
                     "default_locale" => "kk",
                     "status" => "draft",
                     "version" => 1,
                     "stem" => %{
                       "kk" => "Qupiya soz degenimiz ne?",
                       "ru" => "Chto takoe parol?",
                       "en" => "What is a password?"
                     }
                   },
                   actor_id: actor_id,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      IO.puts("\n=== REQ-328 question :localized_text write (verbatim) ===")
      IO.puts(inspect(question, pretty: true, limit: :infinity, printable_limit: :infinity))
      IO.puts("=== end question write ===\n")

      assert {:ok, read_question} = Latest.get(question.record_id, "question", schema)
      assert read_question.field_values["category_id"] == category.record_id

      assert read_question.field_values["stem"] == %{
               "kk" => "Qupiya soz degenimiz ne?",
               "ru" => "Chto takoe parol?",
               "en" => "What is a password?"
             }

      orphan_category_id = Ecto.UUID.generate()

      question_category_fk_error =
        try do
          Records.create_record(
            %{
              entity_type: "question",
              field_values: %{
                "category_id" => orphan_category_id,
                "difficulty" => "easy",
                "type" => "single",
                "default_locale" => "kk",
                "status" => "draft",
                "version" => 1,
                "stem" => %{"kk" => "a", "ru" => "b", "en" => "c"}
              },
              actor_id: actor_id,
              idempotency_key: Ecto.UUID.generate()
            },
            schema
          )
        rescue
          exception -> {:raised, exception}
        end

      IO.puts("\n=== REQ-328 question category_id FK-violation (verbatim) ===")

      IO.puts(
        inspect(question_category_fk_error,
          pretty: true,
          limit: :infinity,
          printable_limit: :infinity
        )
      )

      IO.puts("=== end question category_id FK-violation ===\n")

      assert fk_violation?(question_category_fk_error),
             "expected a Postgres foreign_key_violation for a nonexistent category_id, got: " <>
               inspect(question_category_fk_error)

      # ---- 6d. THE FK CONSTRAINT ACTUALLY BITES (question_tag -> tag) ----
      # question_tag.tag_id is a promoted uuid column carrying a real Postgres
      # REFERENCES (REQ-298). A join row naming a tag that does not exist must
      # be rejected by the database, not merely by application validation.
      orphan_tag_id = Ecto.UUID.generate()
      real_question_id = Ecto.UUID.generate()

      fk_error =
        try do
          Records.create_record(
            %{
              entity_type: "question_tag",
              field_values: %{"question_id" => real_question_id, "tag_id" => orphan_tag_id},
              actor_id: actor_id,
              idempotency_key: Ecto.UUID.generate()
            },
            schema
          )
        rescue
          exception -> {:raised, exception}
        end

      IO.puts("\n=== REQ-328 FK-violation result (verbatim) ===")
      IO.puts(inspect(fk_error, pretty: true, limit: :infinity, printable_limit: :infinity))
      IO.puts("=== end FK-violation result ===\n")

      assert fk_violation?(fk_error),
             "expected a Postgres foreign_key_violation for a nonexistent tag_id, got: " <>
               inspect(fk_error)

      # Now the REAL join row, linking the real question created above to the
      # real "passwords" tag -- this is what section 6f's through-join query
      # resolves against.
      _question_tag =
        create_record!(schema, "question_tag", %{
          "question_id" => question.record_id,
          "tag_id" => tag.record_id
        })

      # ---- 6e. exam, and an exam_question_rule referencing it, plus the
      #          orphan-exam_id rejection (REQ-327's half) --------------
      assert {:ok, %{record: exam}} =
               Records.create_record(
                 %{
                   entity_type: "exam",
                   field_values: %{
                     "title" => %{
                       "kk" => "Qauipsizdik emtihany",
                       "ru" => "Ekzamen po bezopasnosti",
                       "en" => "Security Exam"
                     },
                     "status" => "draft",
                     "time_limit_minutes" => 60,
                     "passing_score_pct" => 70.0,
                     "max_attempts" => 3,
                     "shuffle_questions" => false,
                     "shuffle_options" => false,
                     "show_answers" => "after_completion",
                     "on_tab_switch" => "warn",
                     "certificate_enabled" => false
                   },
                   actor_id: actor_id,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      IO.puts("\n=== REQ-328 exam :localized_text write (verbatim) ===")
      IO.puts(inspect(exam, pretty: true, limit: :infinity, printable_limit: :infinity))
      IO.puts("=== end exam write ===\n")

      assert {:ok, read_exam} = Latest.get(exam.record_id, "exam", schema)

      assert read_exam.field_values["title"] == %{
               "kk" => "Qauipsizdik emtihany",
               "ru" => "Ekzamen po bezopasnosti",
               "en" => "Security Exam"
             }

      assert {:ok, %{record: exam_question_rule}} =
               Records.create_record(
                 %{
                   entity_type: "exam_question_rule",
                   field_values: %{
                     "exam_id" => exam.record_id,
                     "mode" => "random",
                     "count" => 5,
                     "sort_order" => 0
                   },
                   actor_id: actor_id,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert {:ok, read_rule} =
               Latest.get(exam_question_rule.record_id, "exam_question_rule", schema)

      assert read_rule.field_values["exam_id"] == exam.record_id

      orphan_exam_id = Ecto.UUID.generate()

      rule_fk_error =
        try do
          Records.create_record(
            %{
              entity_type: "exam_question_rule",
              field_values: %{
                "exam_id" => orphan_exam_id,
                "mode" => "random",
                "count" => 5,
                "sort_order" => 0
              },
              actor_id: actor_id,
              idempotency_key: Ecto.UUID.generate()
            },
            schema
          )
        rescue
          exception -> {:raised, exception}
        end

      IO.puts("\n=== REQ-328 exam_question_rule FK-violation (verbatim) ===")
      IO.puts(inspect(rule_fk_error, pretty: true, limit: :infinity))
      IO.puts("=== end exam_question_rule FK-violation ===\n")

      assert fk_violation?(rule_fk_error),
             "expected a foreign_key_violation for a nonexistent exam_id, got: " <>
               inspect(rule_fk_error)

      # ---- 6f. REQ-300's `through` many-to-many join RETURNS THE TAGGED
      #          QUESTION -- question -> question_tag -> tag, resolved
      #          against the installed definitions' own fk_defs and executed
      #          against the real promoted tables. A real question_tag join
      #          row now exists (6d), so this must return exactly the tagged
      #          question, with the "unrelated" tag excluded.
      request = %{
        entity_type: "question",
        filters: [%{field: "difficulty", op: :eq, value: "easy"}],
        join: [%{entity_type: "tag", through: "question_tag", fk: "fk_question_tag_tag_id"}]
      }

      assert {:ok, query} = Compiler.compile(request, schema, :all)
      rows = Repo.all(query, prefix: schema)

      IO.puts("\n=== REQ-328 through-join request + rows (verbatim) ===")
      IO.puts("request: " <> inspect(request, pretty: true))
      IO.puts("rows: " <> inspect(rows, pretty: true, limit: :infinity, printable_limit: 400))
      IO.puts("=== end through-join ===\n")

      assert [row] = rows
      assert row.primary.record_id == question.record_id
      assert row.primary.field_values["difficulty"] == "easy"
      assert row["tag"].record_id == tag.record_id
      assert row["tag"].field_values["name"] == "passwords"
      refute row["tag"].field_values["name"] == other_tag.field_values["name"]

      # And the same join over a tag-side filter, to show the far hop really is
      # wired to the tag table and not merely accepted by the compiler.
      tag_side_request = %{
        entity_type: "question",
        join: [%{entity_type: "tag", through: "question_tag", fk: "fk_question_tag_tag_id"}]
      }

      assert {:ok, tag_side_query} = Compiler.compile(tag_side_request, schema, :all)
      assert [tag_side_row] = Repo.all(tag_side_query, prefix: schema)
      assert tag_side_row["tag"].record_id == tag.record_id
    end
  end

  defp fk_violation?({:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}}),
    do: true

  defp fk_violation?({:raised, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}}),
    do: true

  defp fk_violation?(
         {:error, {_step, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}}}
       ),
       do: true

  # GH #2832: a tenant-wide write maps the database's foreign_key_violation to a
  # constant-message :reference violation (the constraint still did the rejecting).
  defp fk_violation?(
         {:error,
          {:record_payload_invalid,
           [%Letflow.Entities.Definition.Validator.Violation{rule: :reference}]}}
       ),
       do: true

  defp fk_violation?(_other), do: false
end
