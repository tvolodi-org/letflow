defmodule Letflow.Entities.Definition.DDLTest do
  @moduledoc """
  Unit tests for `Letflow.Entities.Definition.DDL` (REQ-296). See
  `lib/letflow/design/req296-entity-table-ddl-generator.md` §9 for the
  test-coverage plan each `describe` block below maps to.

  Most of this module is a pure function of `Definition.t()`, so most tests
  run `async: true` with no `Letflow.Repo`/Sandbox dependency. The one
  exception is the "real ephemeral Postgres" describe block, which uses
  `Letflow.DataCase` to get a real Postgres connection and creates/drops a
  throwaway schema within it.
  """

  use Letflow.DataCase, async: true

  alias Letflow.Entities.Definition.DDL

  # ---------------------------------------------------------------------------
  # AC1 -- exact output shape: FK-promoted field + queried:true-promoted field.
  # ---------------------------------------------------------------------------

  describe "generate_table_ddl/2 -- exact output shape" do
    test "produces structural columns plus both promoted columns, in field order, and nothing else" do
      definition = %{
        name: "invoice",
        display_name: "Invoice",
        fields: [
          %{name: "customer_id", type: :string},
          %{
            name: "amount",
            type: :decimal,
            decimal_precision: 10,
            decimal_scale: 2,
            queried: true
          },
          %{name: "internal_notes", type: :json}
        ],
        foreign_keys: [
          %{name: "customer_fk", field: "customer_id", references_entity: "customer"}
        ]
      }

      assert {:ok, sql} =
               DDL.generate_table_ddl(definition, "invoice_table", %{"customer" => "customer"})

      assert sql =~ ~s|CREATE TABLE "invoice_table" (|

      # Structural columns.
      assert sql =~ ~s|"id" uuid NOT NULL|
      assert sql =~ ~s|"record_id" uuid NOT NULL|
      assert sql =~ ~s|"field_values" jsonb NOT NULL DEFAULT '{}'::jsonb|
      assert sql =~ ~s|"deleted" boolean NOT NULL DEFAULT false|
      assert sql =~ ~s|"entity_def_version" bytea|
      refute sql =~ ~s|"entity_def_version" bytea NOT NULL|
      assert sql =~ ~s|"last_event_global_seq" bigint NOT NULL|
      assert sql =~ ~s|"inserted_at" timestamp(6) without time zone NOT NULL|
      assert sql =~ ~s|"updated_at" timestamp(6) without time zone NOT NULL|

      # Promoted columns: customer_id (FK, with its REQ-298 REFERENCES clause)
      # and amount (queried).
      assert sql =~
               ~s|"customer_id" uuid REFERENCES "customer"("record_id") ON DELETE RESTRICT|

      assert sql =~ ~s|"amount" numeric(10, 2)|

      # Not promoted / never promoted.
      refute sql =~ "internal_notes"

      # No entity_type column (dropped from the per-type table).
      refute sql =~ "entity_type"

      assert [customer_id, amount] = DDL.promoted_columns(definition)
      assert customer_id.name == "customer_id"
      assert customer_id.references_entity == "customer"
      assert amount.name == "amount"
      assert amount.references_entity == nil
    end

    test "returns {:error, {:missing_fk_target_table, _}} when fk_target_tables omits an entry" do
      definition = %{
        name: "invoice",
        display_name: "Invoice",
        fields: [%{name: "customer_id", type: :string}],
        foreign_keys: [
          %{name: "customer_fk", field: "customer_id", references_entity: "customer"}
        ]
      }

      assert {:error, {:missing_fk_target_table, entity_type: "customer"}} =
               DDL.generate_table_ddl(definition, "invoice_table")

      assert {:error, {:missing_fk_target_table, entity_type: "customer"}} =
               DDL.generate_table_ddl(definition, "invoice_table", %{})
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 -- type-mapping table, one test per type (except :json).
  # ---------------------------------------------------------------------------

  describe "field_type_to_pg_type/1 and generate_table_ddl/2 -- type mapping" do
    test ":string maps to text" do
      assert {:ok, "text"} = DDL.field_type_to_pg_type(%{type: :string})
      assert_column_type_in_ddl(%{name: "s", type: :string, queried: true}, "text")
    end

    test ":integer maps to bigint" do
      assert {:ok, "bigint"} = DDL.field_type_to_pg_type(%{type: :integer})
      assert_column_type_in_ddl(%{name: "i", type: :integer, queried: true}, "bigint")
    end

    test ":decimal with precision/scale maps to numeric(p, s)" do
      field = %{type: :decimal, decimal_precision: 12, decimal_scale: 4}
      assert {:ok, "numeric(12, 4)"} = DDL.field_type_to_pg_type(field)

      assert_column_type_in_ddl(
        %{name: "d", type: :decimal, decimal_precision: 12, decimal_scale: 4, queried: true},
        "numeric(12, 4)"
      )
    end

    test ":decimal without precision/scale falls back to bare numeric" do
      assert {:ok, "numeric"} = DDL.field_type_to_pg_type(%{type: :decimal})
      assert_column_type_in_ddl(%{name: "d", type: :decimal, queried: true}, "numeric")
    end

    test ":boolean maps to boolean" do
      assert {:ok, "boolean"} = DDL.field_type_to_pg_type(%{type: :boolean})
      assert_column_type_in_ddl(%{name: "b", type: :boolean, queried: true}, "boolean")
    end

    test ":date maps to date" do
      assert {:ok, "date"} = DDL.field_type_to_pg_type(%{type: :date})
      assert_column_type_in_ddl(%{name: "dt", type: :date, queried: true}, "date")
    end

    test ":datetime maps to timestamp(6) without time zone" do
      assert {:ok, "timestamp(6) without time zone"} =
               DDL.field_type_to_pg_type(%{type: :datetime})

      assert_column_type_in_ddl(
        %{name: "dtm", type: :datetime, queried: true},
        "timestamp(6) without time zone"
      )
    end

    test ":enum maps to text with a CHECK constraint enumerating the allowed values" do
      assert {:ok, "text"} = DDL.field_type_to_pg_type(%{type: :enum})

      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [
          %{name: "status", type: :enum, enum_values: ["active", "inactive"], queried: true}
        ]
      }

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "widget_table")
      assert sql =~ ~s|"status" text|
      assert sql =~ ~s|CHECK ("status" IN ('active', 'inactive'))|
    end

    test "an enum value containing a single quote is escaped by doubling it in the CHECK constraint" do
      # Defence-in-depth check (flagged by SECURITY-REVIEWER): enum_values are
      # free text from the definition document, not identifiers -- they are
      # SQL *string literals*, escaped by doubling embedded `'` characters
      # (`enum_literal/1`), not by the identifier allowlist regex. This
      # confirms the escaping actually runs rather than only being correct
      # by inspection.
      definition = %{
        name: "widget2",
        display_name: "Widget2",
        fields: [
          %{
            name: "status",
            type: :enum,
            enum_values: ["it's active", "inactive"],
            queried: true
          }
        ]
      }

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "widget2_table")
      assert sql =~ ~s|CHECK ("status" IN ('it''s active', 'inactive'))|
      refute sql =~ "it's active"
    end

    test "non-integer decimal_precision/decimal_scale falls back to bare numeric" do
      # Defence-in-depth check (flagged by SECURITY-REVIEWER): decimal_pg_type/1
      # guards with `is_integer/1` on both fields -- a non-integer value (e.g.
      # a string, from a malformed-but-somehow-past-Validator document) must
      # fall back to bare `numeric`, not be interpolated into the SQL text
      # unchecked.
      assert {:ok, "numeric"} =
               DDL.field_type_to_pg_type(%{
                 type: :decimal,
                 decimal_precision: "10",
                 decimal_scale: 2
               })

      assert {:ok, "numeric"} =
               DDL.field_type_to_pg_type(%{
                 type: :decimal,
                 decimal_precision: 10,
                 decimal_scale: "2"
               })

      assert_column_type_in_ddl(
        %{name: "d2", type: :decimal, decimal_precision: "10", decimal_scale: 2, queried: true},
        "numeric"
      )
    end

    defp assert_column_type_in_ddl(field, expected_pg_type) do
      definition = %{
        name: "typetest",
        display_name: "Type test",
        fields: [field]
      }

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "typetest_table")
      assert sql =~ ~s|"#{field.name}" #{expected_pg_type}|
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 (defence-in-depth) -- :json is NEVER promoted, even if queried: true.
  # ---------------------------------------------------------------------------

  describe ":json fields are never promoted (defence in depth)" do
    test "field_type_to_pg_type/1 returns :never_promoted for :json" do
      assert :never_promoted = DDL.field_type_to_pg_type(%{type: :json})
    end

    test "a :json field forced to queried: true is absent from promoted_columns/1 and from generated DDL" do
      # This definition would fail Validator.validate/1's Rule 3
      # (queried_json_violations/1) -- deliberately bypassing the Validator
      # here to prove this module's own independent defence-in-depth filter,
      # not merely relying on upstream validation never letting this through.
      definition = %{
        name: "leaky",
        display_name: "Leaky",
        fields: [
          %{name: "blob", type: :json, queried: true}
        ]
      }

      assert DDL.promoted_columns(definition) == []

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "leaky_table")
      refute sql =~ "blob"
    end

    test "a :json field that is also an fk_def field is still never promoted" do
      definition = %{
        name: "leaky2",
        display_name: "Leaky2",
        fields: [
          %{name: "blob", type: :json}
        ],
        foreign_keys: [
          %{name: "blob_fk", field: "blob", references_entity: "other"}
        ]
      }

      assert DDL.promoted_columns(definition) == []
    end
  end

  # ---------------------------------------------------------------------------
  # AC3 -- an attribute that is neither an fk_def field nor queried: true is
  # NOT promoted.
  # ---------------------------------------------------------------------------

  describe "an attribute with neither promotion trigger is not promoted" do
    test "queried: false and not an FK -> :not_promoted, absent from promoted_columns/1 and generated DDL" do
      field = %{name: "internal_note", type: :string, queried: false}
      assert DDL.promotion_trigger(field, MapSet.new()) == :not_promoted

      definition = %{
        name: "thing",
        display_name: "Thing",
        fields: [field]
      }

      assert DDL.promoted_columns(definition) == []

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "thing_table")
      refute sql =~ "internal_note"
    end

    test "queried key absent and not an FK -> :not_promoted" do
      field = %{name: "internal_note", type: :string}
      assert DDL.promotion_trigger(field, MapSet.new()) == :not_promoted
    end
  end

  # ---------------------------------------------------------------------------
  # AC4 -- an fk_def field IS promoted even when queried: false or absent.
  # ---------------------------------------------------------------------------

  describe "an fk_def field is promoted regardless of queried" do
    test "promotion_trigger/2 returns :fk when queried: false is explicit" do
      field = %{name: "customer_id", type: :string, queried: false}
      fk_field_names = MapSet.new(["customer_id"])

      assert DDL.promotion_trigger(field, fk_field_names) == :fk
    end

    test "the field is present in promoted_columns/1's result" do
      definition = %{
        name: "invoice2",
        display_name: "Invoice2",
        fields: [
          %{name: "customer_id", type: :string, queried: false}
        ],
        foreign_keys: [
          %{name: "customer_fk", field: "customer_id", references_entity: "customer"}
        ]
      }

      assert [%{name: "customer_id"}] = DDL.promoted_columns(definition)
    end
  end

  # ---------------------------------------------------------------------------
  # valid_identifier?/1 and the defence-in-depth identifier check.
  # ---------------------------------------------------------------------------

  describe "valid_identifier?/1 and generate_table_ddl/2's identifier check" do
    test "accepts lowercase snake_case identifiers" do
      assert DDL.valid_identifier?("customer")
      assert DDL.valid_identifier?("customer_records_v2")
    end

    test "rejects identifiers with SQL-injection-shaped content" do
      refute DDL.valid_identifier?("customer\"; DROP TABLE users; --")
      refute DDL.valid_identifier?("Customer")
      refute DDL.valid_identifier?("")
      refute DDL.valid_identifier?("1customer")
    end

    test "generate_table_ddl/2 rejects a malicious table_name" do
      definition = %{name: "x", display_name: "X", fields: []}

      assert {:error, {:invalid_identifier, field: :table_name, value: _}} =
               DDL.generate_table_ddl(definition, "x\"; DROP TABLE users; --")
    end

    test "generate_table_ddl/2 rejects a malformed promoted attribute name" do
      definition = %{
        name: "x",
        display_name: "X",
        fields: [%{name: "Bad Name", type: :string, queried: true}]
      }

      assert {:error, {:invalid_identifier, field: :attribute, value: "Bad Name"}} =
               DDL.generate_table_ddl(definition, "x_table")
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-298 AC1 -- unique_constraint_clauses/1, the shared clause-text
  # builder both the fresh CREATE TABLE path and
  # Letflow.TenantProvisioning.run_constraint_activation/1's retrofit path
  # (§7 test-coverage plan item 1's "N=1 works identically" case included).
  # ---------------------------------------------------------------------------

  describe "unique_constraint_clauses/1" do
    test "emits one named CONSTRAINT ... UNIQUE (...) clause per constraint_def, in order" do
      definition = %{
        name: "question_tags",
        display_name: "Question tags",
        fields: [],
        constraints: [
          %{name: "uq_pair", type: :unique, fields: ["question_id", "tag_id"]},
          %{name: "uq_single", type: :unique, fields: ["tag_id"]}
        ]
      }

      assert {:ok,
              [
                ~s|CONSTRAINT "uq_pair" UNIQUE ("question_id", "tag_id")|,
                ~s|CONSTRAINT "uq_single" UNIQUE ("tag_id")|
              ]} = DDL.unique_constraint_clauses(definition)
    end

    test "returns [] for a definition with no constraints" do
      assert {:ok, []} =
               DDL.unique_constraint_clauses(%{name: "x", display_name: "X", fields: []})
    end

    test "rejects a malformed constraint name" do
      definition = %{
        name: "x",
        display_name: "X",
        fields: [],
        constraints: [%{name: "Bad Name", type: :unique, fields: ["a"]}]
      }

      assert {:error, {:invalid_identifier, field: :constraint_name, value: "Bad Name"}} =
               DDL.unique_constraint_clauses(definition)
    end

    test "rejects a malformed constraint field name" do
      definition = %{
        name: "x",
        display_name: "X",
        fields: [],
        constraints: [%{name: "uq_x", type: :unique, fields: ["Bad Field"]}]
      }

      assert {:error, {:invalid_identifier, field: :constraint_field, value: "Bad Field"}} =
               DDL.unique_constraint_clauses(definition)
    end

    test "generate_table_ddl/3 folds the constraint clause into the CREATE TABLE's own constraint list" do
      definition = %{
        name: "question_tags",
        display_name: "Question tags",
        fields: [
          %{name: "question_id", type: :string},
          %{name: "tag_id", type: :string}
        ],
        foreign_keys: [
          %{name: "fk_question", field: "question_id", references_entity: "questions"},
          %{name: "fk_tag", field: "tag_id", references_entity: "tags"}
        ],
        constraints: [
          %{name: "uq_question_tag_pair", type: :unique, fields: ["question_id", "tag_id"]}
        ]
      }

      assert {:ok, sql} =
               DDL.generate_table_ddl(definition, "question_tags_table", %{
                 "questions" => "entity_questions",
                 "tags" => "entity_tags"
               })

      assert sql =~
               ~s|"question_id" uuid REFERENCES "entity_questions"("record_id") ON DELETE RESTRICT|

      assert sql =~
               ~s|"tag_id" uuid REFERENCES "entity_tags"("record_id") ON DELETE RESTRICT|

      assert sql =~ ~s|CONSTRAINT "uq_question_tag_pair" UNIQUE ("question_id", "tag_id")|
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-298 AC3 -- moduledoc cites 0025's ON DELETE RESTRICT decision by name.
  # ---------------------------------------------------------------------------

  describe "moduledoc cites 0025's ON DELETE RESTRICT decision (REQ-298 AC3)" do
    test "the moduledoc quotes the fixed clause and cites the decision record" do
      source = File.read!("lib/letflow/entities/definition/ddl.ex")

      assert source =~ "ON DELETE RESTRICT"
      assert source =~ "0025-promoted-fk-ondelete-and-localized-text-search-strategy.md"
    end
  end

  # ---------------------------------------------------------------------------
  # Moduledoc citation for REQ-301 (AC6) -- the generated-column-per-locale
  # mechanism is now implemented (see localized_text_column_specs/1 below);
  # this replaces the REQ-296-era placeholder that asserted the opposite
  # (extension point named, but deliberately not yet implemented).
  # ---------------------------------------------------------------------------

  describe "moduledoc cites REQ-301 and 0025's plain-vs-tsvector decision (AC6)" do
    test "the moduledoc names REQ-301, cites 0025 Sub-question 2, and does not re-derive it" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(DDL)

      assert moduledoc =~ "REQ-301"
      assert moduledoc =~ "locale"
      assert moduledoc =~ "search_strategy"
      assert moduledoc =~ "tsvector"

      assert moduledoc =~
               "docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md"

      assert moduledoc =~ "Sub-question 2"
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-301 AC4 -- a queried: true :localized_text field promotes to one
  # generated column per declared locale.
  # ---------------------------------------------------------------------------

  describe "REQ-301 AC4 -- :localized_text with queried: true generates one column per locale" do
    test "promoted_columns/1 and generate_table_ddl/2 produce one generated column per locale" do
      definition = %{
        name: "question",
        display_name: "Question",
        fields: [
          %{name: "stem", type: :localized_text, locales: ["kk", "ru"], queried: true}
        ]
      }

      assert [col_kk, col_ru] = DDL.promoted_columns(definition)
      assert col_kk.name == "stem_kk"
      assert col_ru.name == "stem_ru"
      assert col_kk.source_field == "stem"
      assert col_ru.source_field == "stem"

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "question_table")
      assert sql =~ ~s|"stem_kk" text GENERATED ALWAYS AS|
      assert sql =~ ~s|"stem_ru" text GENERATED ALWAYS AS|
      # The base field name never appears as its own column.
      refute sql =~ ~s|"stem" |
    end

    test "a third locale produces a third column, in declared order" do
      definition = %{
        name: "question2",
        display_name: "Question2",
        fields: [
          %{name: "stem", type: :localized_text, locales: ["kk", "ru", "en"], queried: true}
        ]
      }

      assert [col_kk, col_ru, col_en] = DDL.promoted_columns(definition)
      assert [col_kk.name, col_ru.name, col_en.name] == ["stem_kk", "stem_ru", "stem_en"]
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-301 AC6 -- plain-vs-tsvector generated-column shape, per field-level
  # search_strategy (docs/migration/decisions/0025 Sub-question 2).
  # ---------------------------------------------------------------------------

  describe "REQ-301 AC6 -- plain-vs-tsvector generated-column shape" do
    test ":plain (default) search_strategy generates a text column via a JSONB path-extract expression, no to_tsvector" do
      field = %{name: "stem", type: :localized_text, locales: ["kk"], queried: true}
      definition = %{name: "q1", display_name: "Q1", fields: [field]}

      assert [col] = DDL.promoted_columns(definition)
      assert col.pg_type == "text"
      assert col.generated_as == ~s{field_values->'stem'->>'kk'}
      refute col.generated_as =~ "to_tsvector"

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "q1_table")

      assert sql =~
               ~s|"stem_kk" text GENERATED ALWAYS AS (field_values->'stem'->>'kk') STORED|

      refute sql =~ "to_tsvector"
    end

    test ":fulltext search_strategy generates a tsvector column via to_tsvector('simple', coalesce(...))" do
      field = %{
        name: "stem",
        type: :localized_text,
        locales: ["kk"],
        queried: true,
        search_strategy: :fulltext
      }

      definition = %{name: "q2", display_name: "Q2", fields: [field]}

      assert [col] = DDL.promoted_columns(definition)
      assert col.pg_type == "tsvector"

      assert col.generated_as ==
               ~s{to_tsvector('simple', coalesce(field_values->'stem'->>'kk', ''))}

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "q2_table")

      assert sql =~
               ~s|"stem_kk" tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(field_values->'stem'->>'kk', ''))) STORED|
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-301 AC7 -- a :localized_text field NOT marked queried: true stays
  # entirely inside field_values -- no generated column at all.
  # ---------------------------------------------------------------------------

  describe "REQ-301 AC7 -- :localized_text NOT queried stays entirely inside field_values" do
    test "a :localized_text field without queried: true produces zero promoted columns and no trace in the DDL" do
      definition = %{
        name: "q3",
        display_name: "Q3",
        fields: [%{name: "stem", type: :localized_text, locales: ["kk", "ru"]}]
      }

      assert DDL.promoted_columns(definition) == []

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "q3_table")
      refute sql =~ "stem"
    end
  end

  # ---------------------------------------------------------------------------
  # valid_generated_as_expression?/1 -- the counterpart to valid_identifier?/1
  # for a SQL *expression*, used by TenantProvisioning.execute_add_column/3's
  # defensive re-validation.
  # ---------------------------------------------------------------------------

  describe "valid_generated_as_expression?/1" do
    test "accepts the two shapes localized_text_column_specs/1 ever emits" do
      assert DDL.valid_generated_as_expression?(~s{field_values->'stem'->>'kk'})

      assert DDL.valid_generated_as_expression?(
               ~s{to_tsvector('simple', coalesce(field_values->'stem'->>'kk', ''))}
             )
    end

    test "rejects a SQL-injection-shaped or otherwise malformed expression" do
      refute DDL.valid_generated_as_expression?(
               ~s{field_values->'stem'->>'kk'; DROP TABLE users; --}
             )

      refute DDL.valid_generated_as_expression?("not a valid generated_as expression at all")
      # Uppercase field name -- doesn't match the closed name-format regex.
      refute DDL.valid_generated_as_expression?(~s{field_values->'Stem'->>'kk'})
      # Uppercase locale -- doesn't match the closed locale-format regex.
      refute DDL.valid_generated_as_expression?(~s{field_values->'stem'->>'KK'})
      refute DDL.valid_generated_as_expression?("")
      refute DDL.valid_generated_as_expression?(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # AC5 -- run the generated DDL against a real ephemeral Postgres schema.
  # ---------------------------------------------------------------------------

  describe "generate_table_ddl/2 output runs against a real ephemeral Postgres schema" do
    test "creates the table with exactly the structural + promoted columns" do
      schema_name = "ddl_test_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
      table_name = "widget"

      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [
          %{name: "customer_id", type: :string},
          %{
            name: "amount",
            type: :decimal,
            decimal_precision: 10,
            decimal_scale: 2,
            queried: true
          },
          %{name: "status", type: :enum, enum_values: ["active", "inactive"], queried: true},
          %{name: "notes", type: :json, queried: false}
        ],
        foreign_keys: [
          %{name: "customer_fk", field: "customer_id", references_entity: "customer"}
        ],
        constraints: [
          %{name: "uq_widget_status", type: :unique, fields: ["status"]}
        ]
      }

      assert {:ok, sql} =
               DDL.generate_table_ddl(definition, table_name, %{"customer" => "customer"})

      # ExUnit runs on_exit callbacks LIFO, most-recently-registered first --
      # this one runs before Letflow.DataCase's own checkin/rollback, so the
      # connection here is still the same checked-out sandbox connection the
      # rest of this test uses; no separate checkout/mode switch is needed.
      on_exit(fn ->
        Repo.query!(~s|DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE|)
      end)

      Repo.query!(~s|CREATE SCHEMA "#{schema_name}"|)
      Repo.query!(~s|SET search_path TO "#{schema_name}"|)

      # The FK target table this widget table's REFERENCES clause points at
      # -- must exist before the generated CREATE TABLE below runs, since a
      # real REFERENCES constraint is checked by Postgres at creation time.
      Repo.query!(~s|CREATE TABLE "customer" (record_id uuid PRIMARY KEY)|)

      result = Repo.query!(sql)

      # Real, complete output of running the generated DDL -- this is the
      # `result` this test asserts against (Postgrex.Result struct from the
      # single CREATE TABLE statement, which carries the record_id UNIQUE
      # constraint as a table constraint rather than a separate statement).
      assert %Postgrex.Result{} = result

      columns_result =
        Repo.query!(
          """
          SELECT column_name, data_type
          FROM information_schema.columns
          WHERE table_schema = $1 AND table_name = $2
          """,
          [schema_name, table_name]
        )

      actual_columns =
        columns_result.rows
        |> Enum.map(fn [name, _type] -> name end)
        |> MapSet.new()

      expected_columns =
        (DDL.structural_columns() ++ DDL.promoted_columns(definition))
        |> Enum.map(& &1.name)
        |> MapSet.new()

      assert actual_columns == expected_columns

      # REQ-298 AC1/AC2 -- the fresh-CREATE-TABLE path's REFERENCES clause
      # and inline UNIQUE(...) constraint are real, Postgres-enforced
      # integrity rules, not merely present in the schema catalog.
      customer_record_id = Ecto.UUID.generate()

      Repo.query!(~s|INSERT INTO "customer" (record_id) VALUES (($1::text)::uuid)|, [
        customer_record_id
      ])

      insert_widget = fn record_id, customer_id, status ->
        Repo.query(
          """
          INSERT INTO "#{table_name}"
            (id, record_id, field_values, deleted, last_event_global_seq,
             inserted_at, updated_at, customer_id, amount, status)
          VALUES (($1::text)::uuid, ($2::text)::uuid, '{}'::jsonb, false, 1, now(), now(), ($3::text)::uuid, $4, $5)
          """,
          [Ecto.UUID.generate(), record_id, customer_id, Decimal.new("1.00"), status]
        )
      end

      assert {:ok, _result} = insert_widget.(Ecto.UUID.generate(), customer_record_id, "active")

      # AC1 -- a duplicate value for the constrained ("status") column is
      # rejected as a real unique_violation.
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               insert_widget.(Ecto.UUID.generate(), customer_record_id, "active")

      # AC2 -- a customer_id with no matching "customer" row is rejected as
      # a real foreign_key_violation.
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               insert_widget.(Ecto.UUID.generate(), Ecto.UUID.generate(), "inactive")

      Repo.query!(~s|SET search_path TO public|)
    end
  end

  # ---------------------------------------------------------------------------
  # ISS-0623 -- index_create_statements/2 (unit-level, pure, async: true).
  # See lib/letflow/design/iss0623-entity-index-ddl-emission.md §9.1.
  # ---------------------------------------------------------------------------

  describe "index_create_statements/2" do
    test "emits one CREATE INDEX statement per index_def, in declared order" do
      definition = %{
        name: "question",
        display_name: "Question",
        fields: [%{name: "status", type: :string}, %{name: "category_id", type: :string}],
        indexes: [
          %{name: "idx_question_status", fields: ["status"]},
          %{name: "idx_question_category_id", fields: ["category_id"]}
        ]
      }

      assert {:ok,
              [
                ~s|CREATE INDEX "idx_question_status" ON "question_table" ("status")|,
                ~s|CREATE INDEX "idx_question_category_id" ON "question_table" ("category_id")|
              ]} = DDL.index_create_statements(definition, "question_table")
    end

    test "emits CREATE UNIQUE INDEX when index_def.unique is true" do
      definition = %{
        name: "tag",
        display_name: "Tag",
        fields: [%{name: "name", type: :string}],
        indexes: [%{name: "uq_tag_name_idx", fields: ["name"], unique: true}]
      }

      assert {:ok, [~s|CREATE UNIQUE INDEX "uq_tag_name_idx" ON "tag_table" ("name")|]} =
               DDL.index_create_statements(definition, "tag_table")
    end

    test "preserves multi-field declared order without reordering or deduplicating" do
      definition = %{
        name: "question_tag",
        display_name: "Question tag",
        fields: [%{name: "tag_id", type: :string}, %{name: "question_id", type: :string}],
        indexes: [
          %{name: "idx_pair", fields: ["tag_id", "question_id"]}
        ]
      }

      assert {:ok,
              [~s|CREATE INDEX "idx_pair" ON "question_tag_table" ("tag_id", "question_id")|]} =
               DDL.index_create_statements(definition, "question_tag_table")
    end

    test "returns {:ok, []} when :indexes is absent" do
      assert {:ok, []} =
               DDL.index_create_statements(%{name: "x", display_name: "X", fields: []}, "x_table")
    end

    test "returns {:ok, []} when :indexes is []" do
      assert {:ok, []} =
               DDL.index_create_statements(
                 %{name: "x", display_name: "X", fields: [], indexes: []},
                 "x_table"
               )
    end

    test "rejects a malformed index name" do
      definition = %{
        name: "x",
        display_name: "X",
        fields: [%{name: "a", type: :string}],
        indexes: [%{name: "Bad Name", fields: ["a"]}]
      }

      assert {:error, {:invalid_identifier, field: :index_name, value: "Bad Name"}} =
               DDL.index_create_statements(definition, "x_table")
    end

    test "rejects a malformed index field name" do
      definition = %{
        name: "x",
        display_name: "X",
        fields: [%{name: "a", type: :string}],
        indexes: [%{name: "idx_x", fields: ["Bad Field"]}]
      }

      assert {:error, {:invalid_identifier, field: :index_field, value: "Bad Field"}} =
               DDL.index_create_statements(definition, "x_table")
    end

    test "rejects an index_def naming a :localized_text field" do
      definition = %{
        name: "question",
        display_name: "Question",
        fields: [%{name: "stem", type: :localized_text, locales: ["en"]}],
        indexes: [%{name: "idx_stem", fields: ["stem"]}]
      }

      assert {:error,
              {:unsupported_index_field_type,
               index_name: "idx_stem", field: "stem", type: :localized_text}} =
               DDL.index_create_statements(definition, "question_table")
    end
  end

  # ---------------------------------------------------------------------------
  # ISS-0623 -- index_create_statements/2 output runs against a real
  # ephemeral Postgres schema, asserted via pg_indexes (not DDL text alone).
  # See lib/letflow/design/iss0623-entity-index-ddl-emission.md §9.2.
  # ---------------------------------------------------------------------------

  describe "index_create_statements/2 output runs against a real ephemeral Postgres schema" do
    test "every declared index_def produces a real, matching pg_indexes row" do
      schema_name =
        "ddl_idx_test_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

      table_name = "widget"

      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [
          %{name: "status", type: :string, queried: true},
          %{name: "code", type: :string, queried: true}
        ],
        indexes: [
          %{name: "idx_widget_status", fields: ["status"]},
          %{name: "uq_widget_code_idx", fields: ["code"], unique: true}
        ]
      }

      on_exit(fn ->
        Repo.query!(~s|DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE|)
      end)

      Repo.query!(~s|CREATE SCHEMA "#{schema_name}"|)
      Repo.query!(~s|SET search_path TO "#{schema_name}"|)

      assert {:ok, create_table_sql} = DDL.generate_table_ddl(definition, table_name)
      Repo.query!(create_table_sql)

      assert {:ok, index_sqls} = DDL.index_create_statements(definition, table_name)
      assert length(index_sqls) == 2
      Enum.each(index_sqls, &Repo.query!(&1))

      pg_indexes_result =
        Repo.query!(
          "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
          [schema_name, table_name]
        )

      indexes_by_name =
        Map.new(pg_indexes_result.rows, fn [indexname, indexdef] -> {indexname, indexdef} end)

      assert Map.has_key?(indexes_by_name, "idx_widget_status")
      refute indexes_by_name["idx_widget_status"] =~ "CREATE UNIQUE INDEX"

      assert Map.has_key?(indexes_by_name, "uq_widget_code_idx")
      assert indexes_by_name["uq_widget_code_idx"] =~ "CREATE UNIQUE INDEX"

      Repo.query!(~s|SET search_path TO public|)
    end
  end

  # ---------------------------------------------------------------------------
  # GH #2532 -- range keys add no DB CHECK (design §1 D7, §6).
  # ---------------------------------------------------------------------------

  describe "GH #2532 bounds add no CHECK" do
    test "a promoted bounded integer/decimal gives the same DDL as the unbounded one" do
      unbounded = %{
        name: "stock",
        display_name: "Stock",
        fields: [
          %{name: "qty", type: :integer, queried: true},
          %{name: "price", type: :decimal, decimal_precision: 12, decimal_scale: 2, queried: true}
        ]
      }

      bounded =
        Map.update!(unbounded, :fields, fn [qty, price] ->
          [
            Map.merge(qty, %{min: 0, max: 100, non_negative: true}),
            Map.merge(price, %{min: 0.5, max: 99.5})
          ]
        end)

      assert {:ok, unbounded_sql} = DDL.generate_table_ddl(unbounded, "stock_table", %{})
      assert {:ok, bounded_sql} = DDL.generate_table_ddl(bounded, "stock_table", %{})
      assert bounded_sql == unbounded_sql
      refute bounded_sql =~ "CHECK"
    end
  end
end
