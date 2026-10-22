defmodule Letflow.TenantProvisioning.ConstraintFkActivationTest do
  @moduledoc """
  Integration tests for REQ-298's `constraint_def` unique-index activation
  and `fk_def` referential-integrity activation -- the DDL generator
  extensions (`Letflow.Entities.Definition.DDL.generate_table_ddl/3`,
  `unique_constraint_clauses/1`) and the two new
  `Letflow.TenantProvisioning` functions
  (`register_constraint_activation/3`, `run_constraint_activation/1`), on
  top of REQ-297's `execute_add_column/4`. See
  `lib/letflow/design/req298-constraint-fk-activation.md` §7 for the
  test-coverage plan each `describe` block below maps to.

  Uses `Letflow.DataCase` (real Postgres), `async: false` -- every test
  provisions at least one real tenant schema and runs real DDL against it.
  Every assertion against a constraint/FK violation is against a genuine
  `Postgrex.Error`, not a schema-catalog inspection -- per AC1/AC2's own
  explicit requirement.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Records
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.ConstraintActivation
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  # ---------------------------------------------------------------------------------
  # Fixtures -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366),
  # teardown: false because this file's own on_exit also deletes its
  # domain-specific ColumnPromotion/ConstraintActivation rows before the
  # Tenant row (needed: both entity_column_promotions.tenant_id and
  # entity_constraint_activations.tenant_id have on_delete: :nothing, so
  # they must be cleared before Tenant is deleted or the standard fixture
  # teardown's own Tenant delete would violate the FK).
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req298-constraint-fk",
        display_name: "REQ-298 Constraint/FK Activation Test Tenant",
        teardown: false
      )

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
      Repo.delete_all(from(ca in ConstraintActivation, where: ca.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)

    assert {:ok, _seed_result} = Letflow.Entities.EventTypes.seed!(schema_name)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp create_active_definition!(schema, definition) do
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

  defp create_record!(schema, entity_type, field_values) do
    attrs = %{
      entity_type: entity_type,
      field_values: field_values,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    assert {:ok, %{record: record}} = Records.create_record(attrs, schema)
    record
  end

  # Promotes+runs one attribute for `entity_type`, creating (and, for the
  # very first promotion, backfilling) its per-entity-type table -- the
  # exact REQ-297 mechanism this requirement extends, never a hand-rolled
  # CREATE TABLE.
  # ISS-0648 fix note: `Letflow.Entities.Definitions.activate_definition/4`
  # now auto-registers+runs column promotion (landing at "ddl_applied") for
  # every attribute named by a `constraint_def.fields` entry, as part of
  # `create_active_definition!/2` above -- so for an entity type declaring a
  # `constraints` entry, a `ColumnPromotion` row for one of its constrained
  # attributes may already exist (and already be "ddl_applied") by the time
  # a test calls this helper. Reuses the existing row instead of assuming a
  # fresh `register_column_promotion/4` call always succeeds (it would hit
  # the `entity_column_promotions` unique index otherwise) -- same
  # idempotent-lookup-then-run shape
  # `Letflow.Entities.Definitions.ensure_column_promotions/2` itself now
  # uses.
  defp promote_and_create_table!(_schema, tenant_id, entity_type, attribute, pg_type) do
    row =
      case Repo.get_by(ColumnPromotion,
             tenant_id: tenant_id,
             entity_type: entity_type,
             attribute: attribute
           ) do
        nil ->
          assert {:ok, [row]} =
                   TenantProvisioning.register_column_promotion(
                     entity_type,
                     attribute,
                     %{pg_type: pg_type, nullable: true},
                     [tenant_id]
                   )

          row

        %ColumnPromotion{} = existing ->
          existing
      end

    assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
             TenantProvisioning.run_column_promotion(row.id)

    assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type(entity_type)
    table_name
  end

  # Raw INSERT against a real per-entity-type table -- `extra_columns` is a
  # list of `{column_name, cast}` pairs (`cast` one of `:uuid`, `:jsonb`,
  # `:text`, `:integer`), so each promoted column's parameter is bound with
  # the correct Postgres type regardless of whether that column happens to
  # be `uuid` (an FK-promoted column, REQ-298) or a plain scalar type. The
  # `($n::text)::<type>` double-cast idiom mirrors
  # `Letflow.Entities.Records.placeholder_list/1`'s own established pattern
  # for `id`/`record_id`/`field_values`, generalized here to any promoted
  # column REQ-298 might create as `uuid`.
  defp insert_row!(schema, table_name, record_id, extra_columns, extra_values, opts \\ []) do
    field_values = Keyword.get(opts, :field_values, "{}")

    columns =
      ["id", "record_id", "field_values", "deleted", "last_event_global_seq"] ++
        ["inserted_at", "updated_at"] ++ Enum.map(extra_columns, &elem(&1, 0))

    base_placeholders = [
      "($1::text)::uuid",
      "($2::text)::uuid",
      "($3::text)::jsonb",
      "$4",
      "$5",
      "now()",
      "now()"
    ]

    extra_placeholders =
      extra_columns
      |> Enum.with_index(6)
      |> Enum.map(fn {{_name, cast}, i} -> placeholder_for(cast, i) end)

    column_list = Enum.map_join(columns, ", ", &~s("#{&1}"))

    sql = """
    INSERT INTO "#{schema}"."#{table_name}" (#{column_list})
    VALUES (#{Enum.join(base_placeholders ++ extra_placeholders, ", ")})
    """

    values = [Ecto.UUID.generate(), record_id, field_values, false, 1] ++ extra_values

    Repo.query(sql, values)
  end

  # Reads a promoted column back as text, regardless of its real pg_type --
  # for a `uuid`-typed column this avoids needing to `Ecto.UUID.load!/1` the
  # raw 16-byte binary a plain `Repo.query/2` (no Ecto type layer) would
  # otherwise hand back, letting the test assert directly against the
  # 36-character text-form record_id the rest of this suite already deals
  # in.
  defp entity_table_column_as_text(schema, table_name, record_id, column_name) do
    sql =
      ~s|SELECT ("#{column_name}")::text FROM "#{schema}"."#{table_name}" WHERE record_id = ($1::text)::uuid|

    case Repo.query!(sql, [record_id]) do
      %Postgrex.Result{rows: [[value]]} -> value
      %Postgrex.Result{rows: []} -> :no_row
    end
  end

  defp placeholder_for(:uuid, i), do: "($#{i}::text)::uuid"
  defp placeholder_for(:jsonb, i), do: "($#{i}::text)::jsonb"
  defp placeholder_for(:text, i), do: "$#{i}"
  defp placeholder_for(:integer, i), do: "$#{i}"

  defp assert_fk_violation({:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}}),
    do: :ok

  defp assert_unique_violation({:error, %Postgrex.Error{postgres: %{code: :unique_violation}}}),
    do: :ok

  # ---------------------------------------------------------------------------------
  # AC1 -- constraint_def -> real Postgres unique index, both paths.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- constraint_def unique index rejects a real duplicate" do
    test "fresh CREATE TABLE path: N=2 fields, inline UNIQUE(...) in the same statement" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "pair_fresh",
        display_name: "Pair fresh",
        fields: [
          %{name: "left_val", type: :string, queried: true},
          %{name: "right_val", type: :string, queried: true}
        ],
        constraints: [
          %{name: "uq_pair_fresh", type: :unique, fields: ["left_val", "right_val"]}
        ]
      })

      table_name =
        promote_and_create_table!(schema, tenant_id, "pair_fresh", "left_val", "text")

      assert {:ok, _} =
               insert_row!(
                 schema,
                 table_name,
                 Ecto.UUID.generate(),
                 [{"left_val", :text}, {"right_val", :text}],
                 ["a", "b"]
               )

      insert_row!(
        schema,
        table_name,
        Ecto.UUID.generate(),
        [{"left_val", :text}, {"right_val", :text}],
        ["a", "b"]
      )
      |> assert_unique_violation()
    end

    test "N=1 field works identically" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "single_fresh",
        display_name: "Single fresh",
        fields: [%{name: "code", type: :string, queried: true}],
        constraints: [%{name: "uq_single_fresh", type: :unique, fields: ["code"]}]
      })

      table_name = promote_and_create_table!(schema, tenant_id, "single_fresh", "code", "text")

      assert {:ok, _} =
               insert_row!(schema, table_name, Ecto.UUID.generate(), [{"code", :text}], ["x"])

      insert_row!(schema, table_name, Ecto.UUID.generate(), [{"code", :text}], ["x"])
      |> assert_unique_violation()
    end

    test "retrofit path: ConstraintActivation fires once all fields exist as real columns" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "pair_retrofit",
        display_name: "Pair retrofit",
        fields: [
          %{name: "left_val", type: :string, queried: true},
          %{name: "right_val", type: :string, queried: false}
        ]
      })

      table_name =
        promote_and_create_table!(schema, tenant_id, "pair_retrofit", "left_val", "text")

      # right_val is not yet a real column -- registering the activation now
      # and running it must report columns_not_ready, not crash.
      assert {:ok, [activation]} =
               TenantProvisioning.register_constraint_activation(
                 "pair_retrofit",
                 %{name: "uq_pair_retrofit", type: :unique, fields: ["left_val", "right_val"]},
                 [tenant_id]
               )

      assert {:error, {:columns_not_ready, ["right_val"]}} =
               TenantProvisioning.run_constraint_activation(activation.id)

      assert %ConstraintActivation{status: "ddl_failed"} =
               Repo.get!(ConstraintActivation, activation.id)

      # Now promote right_val for real (a second, independent ColumnPromotion
      # row/ADD COLUMN, per the design's own "each field may be promoted at
      # a different time" reasoning).
      assert {:ok, [right_val_row]} =
               TenantProvisioning.register_column_promotion(
                 "pair_retrofit",
                 "right_val",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(right_val_row.id)

      assert {:ok, %ConstraintActivation{status: "ddl_applied"}} =
               TenantProvisioning.run_constraint_activation(activation.id)

      assert {:ok, _} =
               insert_row!(
                 schema,
                 table_name,
                 Ecto.UUID.generate(),
                 [{"left_val", :text}, {"right_val", :text}],
                 ["a", "b"]
               )

      insert_row!(
        schema,
        table_name,
        Ecto.UUID.generate(),
        [{"left_val", :text}, {"right_val", :text}],
        ["a", "b"]
      )
      |> assert_unique_violation()

      # Idempotent re-run: constraint already exists -> skip, still ddl_applied.
      assert {:ok, %ConstraintActivation{status: "ddl_applied"}} =
               TenantProvisioning.run_constraint_activation(activation.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- fk_def -> real Postgres REFERENCES, both paths.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- fk_def rejects a nonexistent target" do
    test "fresh CREATE TABLE path: REFERENCES rides the same ADD COLUMN's own CREATE TABLE" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "customer_ac2",
        display_name: "Customer AC2",
        fields: [%{name: "name", type: :string, queried: true}]
      })

      customer_table =
        promote_and_create_table!(schema, tenant_id, "customer_ac2", "name", "text")

      customer_record = create_record!(schema, "customer_ac2", %{"name" => "Ada"})

      create_active_definition!(schema, %{
        name: "invoice_ac2",
        display_name: "Invoice AC2",
        fields: [%{name: "customer_id", type: :string}],
        foreign_keys: [
          %{name: "fk_customer", field: "customer_id", references_entity: "customer_ac2"}
        ]
      })

      invoice_table =
        promote_and_create_table!(schema, tenant_id, "invoice_ac2", "customer_id", "uuid")

      assert {:ok, _} =
               insert_row!(
                 schema,
                 invoice_table,
                 Ecto.UUID.generate(),
                 [{"customer_id", :uuid}],
                 [customer_record.record_id]
               )

      insert_row!(schema, invoice_table, Ecto.UUID.generate(), [{"customer_id", :uuid}], [
        Ecto.UUID.generate()
      ])
      |> assert_fk_violation()

      # sanity: the referenced table really is a distinct physical table.
      assert customer_table != invoice_table
    end

    test "retrofit path: ADD COLUMN carries its own REFERENCES clause" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "customer_ac2b",
        display_name: "Customer AC2b",
        fields: [%{name: "name", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, "customer_ac2b", "name", "text")
      customer_record = create_record!(schema, "customer_ac2b", %{"name" => "Grace"})

      create_active_definition!(schema, %{
        name: "invoice_ac2b",
        display_name: "Invoice AC2b",
        fields: [%{name: "misc", type: :string, queried: true}]
      })

      invoice_table =
        promote_and_create_table!(schema, tenant_id, "invoice_ac2b", "misc", "text")

      # customer_id does not exist on invoice_ac2b's table yet -- registered
      # directly with references_entity, independent of the live
      # definition's own foreign_keys (matches register_column_promotion/4's
      # own caller-supplied-pg_type/target contract).
      assert {:ok, [row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice_ac2b",
                 "customer_id",
                 %{pg_type: "uuid", nullable: true, references_entity: "customer_ac2b"},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(row.id)

      assert {:ok, _} =
               insert_row!(
                 schema,
                 invoice_table,
                 Ecto.UUID.generate(),
                 [{"customer_id", :uuid}],
                 [customer_record.record_id]
               )

      insert_row!(schema, invoice_table, Ecto.UUID.generate(), [{"customer_id", :uuid}], [
        Ecto.UUID.generate()
      ])
      |> assert_fk_violation()
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- ON DELETE RESTRICT (0025's decision, implemented verbatim).
  # ---------------------------------------------------------------------------------

  describe "AC3 -- ON DELETE RESTRICT" do
    test "a hard DELETE against a referenced row is rejected while a referencing row exists" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "customer_ac3",
        display_name: "Customer AC3",
        fields: [%{name: "name", type: :string, queried: true}]
      })

      customer_table =
        promote_and_create_table!(schema, tenant_id, "customer_ac3", "name", "text")

      customer_record = create_record!(schema, "customer_ac3", %{"name" => "Restrict Me"})

      create_active_definition!(schema, %{
        name: "invoice_ac3",
        display_name: "Invoice AC3",
        fields: [%{name: "customer_id", type: :string}],
        foreign_keys: [
          %{name: "fk_customer", field: "customer_id", references_entity: "customer_ac3"}
        ]
      })

      invoice_table =
        promote_and_create_table!(schema, tenant_id, "invoice_ac3", "customer_id", "uuid")

      assert {:ok, _} =
               insert_row!(
                 schema,
                 invoice_table,
                 Ecto.UUID.generate(),
                 [{"customer_id", :uuid}],
                 [customer_record.record_id]
               )

      # Genuine out-of-band hard DELETE -- never through
      # Letflow.Entities.Records.delete_record/2, which this test
      # deliberately does not exercise (0025's own scope boundary).
      delete_result =
        Repo.query(
          ~s|DELETE FROM "#{schema}"."#{customer_table}" WHERE record_id = ($1::text)::uuid|,
          [customer_record.record_id]
        )

      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} = delete_result

      # The referenced row is still present -- the statement failed outright,
      # no partial effect.
      %Postgrex.Result{rows: [[count]]} =
        Repo.query!(
          ~s|SELECT count(*) FROM "#{schema}"."#{customer_table}" WHERE record_id = ($1::text)::uuid|,
          [customer_record.record_id]
        )

      assert count == 1
    end

    test "DDL's moduledoc cites 0025's ON DELETE RESTRICT decision by name" do
      source = File.read!("lib/letflow/entities/definition/ddl.ex")

      assert source =~ "ON DELETE RESTRICT"
      assert source =~ "0025-promoted-fk-ondelete-and-localized-text-search-strategy.md"
    end
  end

  # ---------------------------------------------------------------------------------
  # Many-to-many worked example (0023's own question_tags-shaped case).
  # ---------------------------------------------------------------------------------

  describe "many-to-many worked example (question_tags-shaped)" do
    defp seed_questions_and_tags!(schema, tenant_id, suffix) do
      questions_type = "questions_#{suffix}"
      tags_type = "tags_#{suffix}"

      create_active_definition!(schema, %{
        name: questions_type,
        display_name: "Questions #{suffix}",
        fields: [%{name: "stem", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, questions_type, "stem", "text")
      question_record = create_record!(schema, questions_type, %{"stem" => "2+2=?"})

      create_active_definition!(schema, %{
        name: tags_type,
        display_name: "Tags #{suffix}",
        fields: [%{name: "label", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, tags_type, "label", "text")
      tag_record = create_record!(schema, tags_type, %{"label" => "math"})

      %{
        questions_type: questions_type,
        tags_type: tags_type,
        question_record: question_record,
        tag_record: tag_record
      }
    end

    test "fresh-table path: duplicate pair rejected, either-side FK violation rejected, extra attribute accepted" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      %{
        questions_type: questions_type,
        tags_type: tags_type,
        question_record: question_record,
        tag_record: tag_record
      } = seed_questions_and_tags!(schema, tenant_id, "fresh")

      join_type = "question_tags_fresh"

      create_active_definition!(schema, %{
        name: join_type,
        display_name: "Question tags fresh",
        fields: [
          %{name: "question_id", type: :string},
          %{name: "tag_id", type: :string},
          %{name: "sort_order", type: :integer}
        ],
        foreign_keys: [
          %{name: "fk_question", field: "question_id", references_entity: questions_type},
          %{name: "fk_tag", field: "tag_id", references_entity: tags_type}
        ],
        constraints: [
          %{name: "uq_question_tag_pair_fresh", type: :unique, fields: ["question_id", "tag_id"]}
        ]
      })

      # Only question_id is individually promoted -- the freshly-created
      # table already carries BOTH REFERENCES clauses and the inline
      # UNIQUE(...) constraint from the full current definition (design §5
      # step 2's fresh-table path -- no separate registration for tag_id).
      join_table =
        promote_and_create_table!(schema, tenant_id, join_type, "question_id", "uuid")

      # (a) a duplicate pair is rejected.
      assert {:ok, _} =
               insert_row!(
                 schema,
                 join_table,
                 Ecto.UUID.generate(),
                 [{"question_id", :uuid}, {"tag_id", :uuid}],
                 [question_record.record_id, tag_record.record_id],
                 field_values: ~s({"sort_order":1})
               )

      insert_row!(
        schema,
        join_table,
        Ecto.UUID.generate(),
        [{"question_id", :uuid}, {"tag_id", :uuid}],
        [question_record.record_id, tag_record.record_id]
      )
      |> assert_unique_violation()

      # (b) a pair referencing a non-existent record on EITHER side is
      # rejected.
      insert_row!(
        schema,
        join_table,
        Ecto.UUID.generate(),
        [{"question_id", :uuid}, {"tag_id", :uuid}],
        [Ecto.UUID.generate(), tag_record.record_id]
      )
      |> assert_fk_violation()

      insert_row!(
        schema,
        join_table,
        Ecto.UUID.generate(),
        [{"question_id", :uuid}, {"tag_id", :uuid}],
        [question_record.record_id, Ecto.UUID.generate()]
      )
      |> assert_fk_violation()

      # (c) a DISTINCT valid pair, plus a field_values blob carrying
      # sort_order, succeeds -- the relationship's own attribute has a real
      # home and is not constrained by the FK/unique machinery at all.
      other_tag_record = create_record!(schema, tags_type, %{"label" => "science"})

      assert {:ok, _} =
               insert_row!(
                 schema,
                 join_table,
                 Ecto.UUID.generate(),
                 [{"question_id", :uuid}, {"tag_id", :uuid}],
                 [question_record.record_id, other_tag_record.record_id],
                 field_values: ~s({"sort_order":3})
               )
    end

    test "retrofit path: same three assertions, via ConstraintActivation" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      %{
        questions_type: questions_type,
        tags_type: tags_type,
        question_record: question_record,
        tag_record: tag_record
      } = seed_questions_and_tags!(schema, tenant_id, "retrofit")

      join_type = "question_tags_retrofit"

      create_active_definition!(schema, %{
        name: join_type,
        display_name: "Question tags retrofit",
        fields: [
          %{name: "question_id", type: :string},
          %{name: "tag_id", type: :string}
        ],
        foreign_keys: [
          %{name: "fk_question", field: "question_id", references_entity: questions_type}
        ]
      })

      # question_id promotes and creates the table; tag_id is NOT declared
      # as an fk_def yet, so it is not promoted at all here -- the retrofit
      # scenario design §5 step 2 describes ("its table already exists with
      # only question_id promoted").
      join_table =
        promote_and_create_table!(schema, tenant_id, join_type, "question_id", "uuid")

      refute Enum.any?(
               Repo.query!(
                 "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2",
                 [schema, join_table]
               ).rows,
               fn [name] -> name == "tag_id" end
             )

      # Promote tag_id directly with its own references_entity -- rides its
      # own ADD COLUMN statement.
      assert {:ok, [tag_id_row]} =
               TenantProvisioning.register_column_promotion(
                 join_type,
                 "tag_id",
                 %{pg_type: "uuid", nullable: true, references_entity: tags_type},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(tag_id_row.id)

      # Register + run the constraint activation -- ADD CONSTRAINT.
      assert {:ok, [activation]} =
               TenantProvisioning.register_constraint_activation(
                 join_type,
                 %{
                   name: "uq_question_tag_pair_retrofit",
                   type: :unique,
                   fields: ["question_id", "tag_id"]
                 },
                 [tenant_id]
               )

      assert {:ok, %ConstraintActivation{status: "ddl_applied"}} =
               TenantProvisioning.run_constraint_activation(activation.id)

      # (a) duplicate pair rejected.
      assert {:ok, _} =
               insert_row!(
                 schema,
                 join_table,
                 Ecto.UUID.generate(),
                 [{"question_id", :uuid}, {"tag_id", :uuid}],
                 [question_record.record_id, tag_record.record_id]
               )

      insert_row!(
        schema,
        join_table,
        Ecto.UUID.generate(),
        [{"question_id", :uuid}, {"tag_id", :uuid}],
        [question_record.record_id, tag_record.record_id]
      )
      |> assert_unique_violation()

      # (b) either-side FK violation rejected.
      insert_row!(
        schema,
        join_table,
        Ecto.UUID.generate(),
        [{"question_id", :uuid}, {"tag_id", :uuid}],
        [Ecto.UUID.generate(), tag_record.record_id]
      )
      |> assert_fk_violation()

      insert_row!(
        schema,
        join_table,
        Ecto.UUID.generate(),
        [{"question_id", :uuid}, {"tag_id", :uuid}],
        [question_record.record_id, Ecto.UUID.generate()]
      )
      |> assert_fk_violation()

      # (c) extra field_values attribute accepted alongside a distinct pair.
      other_tag_record = create_record!(schema, tags_type, %{"label" => "history"})

      assert {:ok, _} =
               insert_row!(
                 schema,
                 join_table,
                 Ecto.UUID.generate(),
                 [{"question_id", :uuid}, {"tag_id", :uuid}],
                 [question_record.record_id, other_tag_record.record_id],
                 field_values: ~s({"sort_order":5})
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # Array-of-references anti-pattern absence (test-coverage plan item 5).
  # ---------------------------------------------------------------------------------

  describe "no array-of-references shape anywhere in this requirement's diff" do
    test "grep across every file this requirement touches finds zero {:array, hits used for a relationship" do
      files = [
        "lib/letflow/entities/definition/ddl.ex",
        "lib/letflow/tenant_provisioning.ex",
        "lib/letflow/tenant_provisioning/column_promotion.ex",
        "lib/letflow/tenant_provisioning/constraint_activation.ex"
      ]

      # The ONE known {:array, hit in this diff --
      # `ConstraintActivation.fields :: {:array, :string}` -- is a list of
      # plain column-NAME strings (bookkeeping metadata for which columns a
      # constraint spans), never a list of record references. It is
      # identified by content, not by a hard-coded line number, so this
      # test does not silently rot if the file is reformatted.
      allowed_content = "field(:fields, {:array, :string})"

      hits =
        for file <- files,
            {contents, line} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            String.contains?(contents, "{:array,"),
            not String.contains?(contents, allowed_content) do
          {file, line, contents}
        end

      assert hits == [],
             "found {:array, occurrences beyond the one allowed column-name-list use: " <>
               inspect(hits)

      # Confirm the allowed line actually exists (so a refactor that removes
      # it doesn't silently widen the allowance above into "everything is
      # allowed").
      assert "lib/letflow/tenant_provisioning/constraint_activation.ex"
             |> File.read!() =~ allowed_content
    end

    test "no array( SQL literal for a relationship shape in this diff" do
      files = [
        "lib/letflow/entities/definition/ddl.ex",
        "lib/letflow/tenant_provisioning.ex",
        "lib/letflow/tenant_provisioning/column_promotion.ex",
        "lib/letflow/tenant_provisioning/constraint_activation.ex"
      ]

      hits =
        for file <- files,
            {contents, line} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            String.contains?(String.downcase(contents), "array(") do
          {file, line, contents}
        end

      assert hits == [], "found array( occurrences: #{inspect(hits)}"
    end
  end

  # ---------------------------------------------------------------------------------
  # Rework 1 -- SECURITY-REVIEWER-flagged bug: an FK-promoted `uuid` column
  # written through the REAL production paths (not this file's own
  # `insert_row!` helper, which manually applies the `($n::text)::uuid` cast
  # itself and therefore never exercised the gap). Both real write paths are
  # covered: the live dual-write Multi step
  # (`Letflow.Entities.Records.create_record/2`) and the backfill/replay
  # path (`Letflow.TenantProvisioning.backfill_column_promotion/1` ->
  # `Letflow.Entities.Record.Projector.rebuild_projection/2`). Before the
  # fix, both crashed with a `DBConnection.EncodeError` on any real
  # tenant-triggered write to an FK-promoted column:
  # `Letflow.TenantProvisioning.cast_promoted_value/2` had no `"uuid"`
  # clause, and both `Letflow.Entities.Records.placeholder_list/1` and
  # `Letflow.Entities.Record.Projector`'s own inline placeholder builder
  # only special-cased the hardcoded structural `"id"`/`"record_id"`
  # columns, never a promoted column whose own pg_type happens to be
  # `"uuid"`.
  # ---------------------------------------------------------------------------------

  describe "REQ-298 fix -- real production paths handle an FK-promoted uuid column" do
    test "live dual-write path: Records.create_record/2 succeeds and lands the correct value" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "customer_castfix",
        display_name: "Customer Castfix",
        fields: [%{name: "name", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, "customer_castfix", "name", "text")
      customer_record = create_record!(schema, "customer_castfix", %{"name" => "Dual Write"})

      create_active_definition!(schema, %{
        name: "invoice_castfix",
        display_name: "Invoice Castfix",
        fields: [%{name: "customer_id", type: :string}],
        foreign_keys: [
          %{name: "fk_customer", field: "customer_id", references_entity: "customer_castfix"}
        ]
      })

      # promote_and_create_table! runs run_column_promotion/1, landing the
      # promotion at status "ddl_applied" -- one of the
      # column_promotions_for_table_write/2 statuses, so the very next
      # create_record!/3 call below dual-writes through
      # Records.dual_write_promoted_columns/3, the real production Multi
      # step, not a test-only shortcut.
      invoice_table =
        promote_and_create_table!(schema, tenant_id, "invoice_castfix", "customer_id", "uuid")

      # THE bug this test closes: before the fix, this call raised a
      # DBConnection.EncodeError from inside the dual-write Multi step --
      # cast_promoted_value/2 passed the 36-character text-form record_id
      # through unchanged, and placeholder_list/1 bound it with a bare "$n"
      # against the invoice table's real uuid-typed "customer_id" column.
      invoice_record =
        create_record!(schema, "invoice_castfix", %{"customer_id" => customer_record.record_id})

      assert entity_table_column_as_text(
               schema,
               invoice_table,
               invoice_record.record_id,
               "customer_id"
             ) == customer_record.record_id
    end

    test "backfill/replay path: backfill_column_promotion/1 rebuilds a pre-existing record's FK-promoted uuid column" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "customer_backfillfix",
        display_name: "Customer Backfillfix",
        fields: [%{name: "name", type: :string, queried: true}]
      })

      promote_and_create_table!(schema, tenant_id, "customer_backfillfix", "name", "text")

      customer_record =
        create_record!(schema, "customer_backfillfix", %{"name" => "Backfill Target"})

      # "customer_id" IS declared as an fk_def field from the start -- per
      # `Letflow.Entities.Definition.DDL.promoted_columns/1`, an fk field
      # always promotes (regardless of `queried`) as pg_type "uuid" the
      # moment ANY field on this entity type gets its first CREATE TABLE, so
      # the physical column already exists once "misc" is promoted below.
      # It is NOT yet tracked by its own `ColumnPromotion` row, though --
      # `column_promotions_for_table_write/2` only returns rows individually
      # registered via `register_column_promotion/4`, so the live dual-write
      # this test's own `create_record!/3` call triggers (for "misc") does
      # NOT also write "customer_id" -- it stays NULL on the physical row
      # despite being present in `field_values`, exactly this test's needed
      # "genuine pre-existing row with an unpromoted attribute" setup,
      # mirroring the many-to-many fresh-table test's own "tag_id" case
      # above (physically present, untracked, until separately registered).
      create_active_definition!(schema, %{
        name: "invoice_backfillfix",
        display_name: "Invoice Backfillfix",
        fields: [
          %{name: "misc", type: :string, queried: true},
          %{name: "customer_id", type: :string}
        ],
        foreign_keys: [
          %{
            name: "fk_customer",
            field: "customer_id",
            references_entity: "customer_backfillfix"
          }
        ]
      })

      invoice_table =
        promote_and_create_table!(schema, tenant_id, "invoice_backfillfix", "misc", "text")

      invoice_record =
        create_record!(schema, "invoice_backfillfix", %{
          "misc" => "pre-existing",
          "customer_id" => customer_record.record_id
        })

      # The pre-existing row's "customer_id" column is NULL -- it exists
      # physically but was never dual-written (no ColumnPromotion row for
      # it yet).
      assert entity_table_column_as_text(
               schema,
               invoice_table,
               invoice_record.record_id,
               "customer_id"
             ) == nil

      # Registering + running its own ColumnPromotion now finds the column
      # already physically present with a matching type -- the existing
      # `check_additive_only/3` idempotent-skip path -- and marks it
      # "ddl_applied" without issuing a second ADD COLUMN.
      assert {:ok, [customer_id_row]} =
               TenantProvisioning.register_column_promotion(
                 "invoice_backfillfix",
                 "customer_id",
                 %{pg_type: "uuid", nullable: true, references_entity: "customer_backfillfix"},
                 [tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(customer_id_row.id)

      # THE bug this test closes on the backfill/replay path: before the
      # fix, this call raised a DBConnection.EncodeError from inside
      # Letflow.Entities.Record.Projector's write_entity_table_snapshots/4
      # -> insert_entity_table_row/4 -- the same cast_promoted_value/2 gap,
      # plus the identical missing-uuid-column gap in that module's own
      # inline placeholder builder.
      assert {:ok, %ColumnPromotion{status: "backfilled"}} =
               TenantProvisioning.backfill_column_promotion(customer_id_row.id)

      assert entity_table_column_as_text(
               schema,
               invoice_table,
               invoice_record.record_id,
               "customer_id"
             ) == customer_record.record_id
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0649 -- once a ColumnPromotion reaches "active", Records.create_record/2
  # must keep writing full rows to the promoted per-entity-type table, and its
  # UNIQUE constraint must keep rejecting a duplicate. Before this fix,
  # TenantProvisioning.column_promotions_in_flight/2's status filter excluded
  # "active", so Records.dual_write_promoted_columns/3 returned {:ok, :skipped}
  # for every write once a promotion completed, silently disabling the
  # per-entity-type table's own constraint enforcement (and leaving the table's
  # rows stale) for that entity type forever after. Decision record 0024 §3
  # step 3 only retires the entity_record_latest.field_values blob dual-write
  # at "active" -- it does not say to stop writing the per-entity-type table's
  # own row (0024 §3 step 1: that write is unconditional/single, not zero).
  # ---------------------------------------------------------------------------------

  describe "ISS-0649 -- promoted per-entity-type table keeps being written once ColumnPromotion is active" do
    test "create_record/2 still writes full rows post-activation, and the unique constraint still rejects a duplicate" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "sku_activefix",
        display_name: "SKU Activefix",
        fields: [%{name: "code", type: :string, queried: true}],
        constraints: [%{name: "uq_sku_activefix_code", type: :unique, fields: ["code"]}]
      })

      table_name =
        promote_and_create_table!(schema, tenant_id, "sku_activefix", "code", "text")

      assert %ColumnPromotion{id: promotion_id, status: "ddl_applied"} =
               Repo.get_by!(ColumnPromotion,
                 tenant_id: tenant_id,
                 entity_type: "sku_activefix",
                 attribute: "code"
               )

      # Drive the promotion all the way to "active" -- the exact production
      # lifecycle (register -> ddl_applied -> backfilled -> active), not a
      # hand-set status.
      assert {:ok, %ColumnPromotion{status: "backfilled"}} =
               TenantProvisioning.backfill_column_promotion(promotion_id)

      assert {:ok, %ColumnPromotion{status: "active", query_eligible: true}} =
               TenantProvisioning.activate_column_promotion(promotion_id)

      # A create_record/2 call made AFTER activation must still land a full
      # row (structural columns + the promoted "code" column) in the
      # per-entity-type table -- not only in entity_record_latest.field_values.
      first_record = create_record!(schema, "sku_activefix", %{"code" => "SKU-1"})

      assert entity_table_column_as_text(schema, table_name, first_record.record_id, "code") ==
               "SKU-1"

      # And the per-entity-type table's own UNIQUE constraint must still be
      # enforced against a live write through the real create_record/2 path
      # -- this is the regression ISS-0648 fixed, reintroduced at a later
      # lifecycle stage if column_promotions_for_table_write/2 ever excludes
      # "active" again.
      assert {:error, {:record_payload_invalid, _reason}} =
               Records.create_record(
                 %{
                   entity_type: "sku_activefix",
                   field_values: %{"code" => "SKU-1"},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      # Sanity: the duplicate was rejected before a second row was ever
      # inserted into the per-entity-type table (not merely rejected at the
      # entity_record_latest layer, which has no such constraint).
      sql = ~s|SELECT count(*) FROM "#{schema}"."#{table_name}" WHERE "code" = 'SKU-1'|
      assert %Postgrex.Result{rows: [[1]]} = Repo.query!(sql)
    end
  end
end
