defmodule Letflow.Entities.Definition.ValidatorTest do
  @moduledoc """
  Unit tests for `Letflow.Entities.Definition.Validator` (REQ-225). See
  `lib/letflow/design/req225-entity-definition-schema-validation.md` §3 for
  the rule specifications each test below maps to.

  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency -- `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Definition.Validator
  alias Letflow.Entities.Definition.Validator.Violation

  # ---------------------------------------------------------------------------
  # AC1 -- a conforming document passes with zero errors.
  # ---------------------------------------------------------------------------

  describe "AC1 -- a conforming definition document passes validation with no errors" do
    test "a fully-populated, internally-consistent definition validates as :ok" do
      definition = %{
        name: "customer",
        display_name: "Customer",
        description: "A customer entity",
        fields: [
          %{name: "id", type: :string, required: true, queried: true},
          %{name: "email", type: :string, required: true, queried: true},
          %{name: "age", type: :integer, queried: true},
          %{name: "balance", type: :decimal, decimal_precision: 10, decimal_scale: 2},
          %{name: "status", type: :enum, enum_values: ["active", "inactive"]},
          %{name: "notes", type: :json}
        ],
        indexes: [
          %{name: "email_idx", fields: ["email"], unique: true}
        ],
        foreign_keys: [
          %{name: "referred_by_fk", field: "id", references_entity: "referrer"}
        ],
        constraints: [
          %{name: "unique_email", type: :unique, fields: ["email"]}
        ]
      }

      assert Validator.validate(definition) == :ok
    end

    test "a minimal definition (name/display_name/one field only) validates as :ok" do
      assert Validator.validate(%{
               name: "widget",
               display_name: "Widget",
               fields: [%{name: "id", type: :string}]
             }) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 -- each of the 11 rules is independently exercised by a fixture that
  # violates ONLY that rule, and the reported violation identifies the rule.
  # ---------------------------------------------------------------------------

  describe "Rule 1 -- name format (:name_format)" do
    test "an uppercase name fails only :name_format" do
      definition = %{
        name: "Widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string}]
      }

      assert {:error, [%Violation{rule: :name_format, path: [:name]}]} =
               Validator.validate(definition)
    end

    test "a name longer than 64 characters fails only :name_format" do
      definition = %{
        name: String.duplicate("a", 65),
        display_name: "Widget",
        fields: [%{name: "id", type: :string}]
      }

      assert {:error, [%Violation{rule: :name_format}]} = Validator.validate(definition)
    end
  end

  describe "Rule 2 -- name uniqueness (:duplicate_name)" do
    test "two fields sharing a name fails only :duplicate_name (scope :fields)" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [
          %{name: "dup", type: :string},
          %{name: "dup", type: :integer}
        ]
      }

      assert {:error, [%Violation{rule: :duplicate_name, path: [:fields, "dup"]}]} =
               Validator.validate(definition)
    end

    test "two indexes sharing a name fails only :duplicate_name (scope :indexes)" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string, queried: true}],
        indexes: [
          %{name: "dup_idx", fields: ["id"]},
          %{name: "dup_idx", fields: ["id"]}
        ]
      }

      assert {:error, [%Violation{rule: :duplicate_name, path: [:indexes, "dup_idx"]}]} =
               Validator.validate(definition)
    end

    test "an FK and a constraint sharing a name fails only :duplicate_name (combined scope)" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string}],
        foreign_keys: [%{name: "dup_c", field: "id", references_entity: "other"}],
        constraints: [%{name: "dup_c", type: :unique, fields: ["id"]}]
      }

      assert {:error, [%Violation{rule: :duplicate_name, path: [:foreign_keys, "dup_c"]}]} =
               Validator.validate(definition)
    end
  end

  describe "Rule 3 -- queried + :json mutual exclusion (:queried_json_conflict)" do
    test "a :json field marked queried: true fails only :queried_json_conflict" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "data", type: :json, queried: true}]
      }

      assert {:error, [%Violation{rule: :queried_json_conflict, path: [:fields, "data"]}]} =
               Validator.validate(definition)
    end
  end

  describe "Rule 4 -- index field coverage" do
    test "an index referencing a nonexistent field fails only :index_field_not_found" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string, queried: true}],
        indexes: [%{name: "idx1", fields: ["missing"]}]
      }

      assert {:error,
              [
                %Violation{
                  rule: :index_field_not_found,
                  path: [:indexes, "idx1", :fields, "missing"]
                }
              ]} = Validator.validate(definition)
    end

    test "an index referencing a field that isn't queried fails only :index_field_not_queried" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string}],
        indexes: [%{name: "idx1", fields: ["id"]}]
      }

      assert {:error,
              [
                %Violation{
                  rule: :index_field_not_queried,
                  path: [:indexes, "idx1", :fields, "id"]
                }
              ]} = Validator.validate(definition)
    end
  end

  describe "Rule 5 -- FK field coverage (:fk_field_not_found)" do
    test "an FK referencing a nonexistent local field fails only :fk_field_not_found" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string}],
        foreign_keys: [%{name: "fk1", field: "missing", references_entity: "other"}]
      }

      assert {:error,
              [%Violation{rule: :fk_field_not_found, path: [:foreign_keys, "fk1", :field]}]} =
               Validator.validate(definition)
    end

    test "a constraint referencing a nonexistent local field fails only :fk_field_not_found" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string}],
        constraints: [%{name: "c1", type: :unique, fields: ["missing"]}]
      }

      assert {:error,
              [
                %Violation{
                  rule: :fk_field_not_found,
                  path: [:constraints, "c1", :fields, "missing"]
                }
              ]} = Validator.validate(definition)
    end
  end

  describe "Rule 6 -- enum validity (:invalid_enum)" do
    test "a :enum field with absent enum_values fails only :invalid_enum" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "status", type: :enum}]
      }

      assert {:error, [%Violation{rule: :invalid_enum, path: [:fields, "status", :enum_values]}]} =
               Validator.validate(definition)
    end

    test "a :enum field with duplicate enum_values fails only :invalid_enum" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "status", type: :enum, enum_values: ["a", "a"]}]
      }

      assert {:error, [%Violation{rule: :invalid_enum}]} = Validator.validate(definition)
    end

    test "a non-enum field carrying enum_values fails only :invalid_enum" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string, enum_values: ["a"]}]
      }

      assert {:error, [%Violation{rule: :invalid_enum}]} = Validator.validate(definition)
    end
  end

  describe "Rule 7 -- decimal-field validation (:invalid_decimal)" do
    test "a :decimal field missing precision/scale fails only :invalid_decimal" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "price", type: :decimal}]
      }

      assert {:error, [%Violation{rule: :invalid_decimal, path: [:fields, "price"]}]} =
               Validator.validate(definition)
    end

    test "a :decimal field with scale greater than precision fails only :invalid_decimal" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "price", type: :decimal, decimal_precision: 2, decimal_scale: 5}]
      }

      assert {:error, [%Violation{rule: :invalid_decimal}]} = Validator.validate(definition)
    end

    test "a non-decimal field carrying decimal_precision fails only :invalid_decimal" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string, decimal_precision: 2}]
      }

      assert {:error, [%Violation{rule: :invalid_decimal}]} = Validator.validate(definition)
    end
  end

  describe "Rule 8a -- field-count cardinality limit (:too_many_fields)" do
    test "201 fields fails only :too_many_fields" do
      fields = for i <- 1..201, do: %{name: "f#{i}", type: :string}

      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: fields
      }

      assert {:error, [%Violation{rule: :too_many_fields, path: [:fields]}]} =
               Validator.validate(definition)
    end
  end

  describe "Rule 8b -- index-count cardinality limit (:too_many_indexes)" do
    test "33 indexes fails only :too_many_indexes" do
      indexes = for i <- 1..33, do: %{name: "idx#{i}", fields: ["id"]}

      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string, queried: true}],
        indexes: indexes
      }

      assert {:error, [%Violation{rule: :too_many_indexes, path: [:indexes]}]} =
               Validator.validate(definition)
    end
  end

  describe "Rule 8c -- FK+constraint-count cardinality limit, combined (:too_many_fk_or_constraints)" do
    test "33 foreign keys (0 constraints) fails only :too_many_fk_or_constraints" do
      fks =
        for i <- 1..33,
            do: %{name: "fk#{i}", field: "id", references_entity: "other"}

      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string}],
        foreign_keys: fks
      }

      assert {:error, [%Violation{rule: :too_many_fk_or_constraints, path: [:foreign_keys]}]} =
               Validator.validate(definition)
    end

    test "a mixed split of foreign_keys and constraints summing past 32 fails only :too_many_fk_or_constraints" do
      fks = for i <- 1..20, do: %{name: "fk#{i}", field: "id", references_entity: "other"}
      constraints = for i <- 1..13, do: %{name: "c#{i}", type: :unique, fields: ["id"]}

      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string}],
        foreign_keys: fks,
        constraints: constraints
      }

      assert {:error, [%Violation{rule: :too_many_fk_or_constraints}]} =
               Validator.validate(definition)
    end
  end

  describe "Rule 9 (lifted, REQ-324) -- a foreign key MAY reference the definition's own name" do
    test "an FK whose references_entity equals the definition's own name validates as :ok" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string}],
        foreign_keys: [%{name: "fk1", field: "id", references_entity: "widget"}]
      }

      assert Validator.validate(definition) == :ok
    end

    test "a self-referential FK still enforces its other invariants -- an unknown local field still fails Rule 5 (:fk_field_not_found), not accepted just because the target is self" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string}],
        foreign_keys: [%{name: "fk1", field: "does_not_exist", references_entity: "widget"}]
      }

      assert {:error, [%Violation{rule: :fk_field_not_found}]} = Validator.validate(definition)
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-301 AC1 -- :localized_text is a new, valid field_type().
  # ---------------------------------------------------------------------------

  describe "REQ-301 AC1 -- :localized_text field type" do
    test "a definition with a :localized_text field (locales declared) validates as :ok" do
      definition = %{
        name: "question",
        display_name: "Question",
        fields: [
          %{name: "stem", type: :localized_text, locales: ["kk", "ru"]}
        ]
      }

      assert Validator.validate(definition) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-301 AC2 -- the supported-locale set is per-definition, not project-wide.
  # ---------------------------------------------------------------------------

  describe "REQ-301 AC2 -- per-definition locale sets" do
    test "two entity types declare different locale sets for their own :localized_text field, each validates independently" do
      definition_a = %{
        name: "question_a",
        display_name: "Question A",
        fields: [%{name: "stem", type: :localized_text, locales: ["kk", "ru"]}]
      }

      definition_b = %{
        name: "question_b",
        display_name: "Question B",
        fields: [%{name: "stem", type: :localized_text, locales: ["en", "fr", "de"]}]
      }

      assert Validator.validate(definition_a) == :ok
      assert Validator.validate(definition_b) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-301 AC3 -- :localized_text CAN be queried: true; :json still cannot
  # (Rule 3's own source text is byte-for-byte unchanged by this requirement).
  # ---------------------------------------------------------------------------

  describe "REQ-301 AC3 -- :localized_text CAN be queried: true; :json still cannot (Rule 3 unweakened)" do
    test "a :localized_text field with queried: true validates (no :queried_json_conflict)" do
      definition = %{
        name: "question",
        display_name: "Question",
        fields: [
          %{name: "stem", type: :localized_text, locales: ["kk", "ru"], queried: true}
        ]
      }

      assert Validator.validate(definition) == :ok
    end

    test "a :json field with queried: true still fails :queried_json_conflict (Rule 3 re-confirmed unweakened)" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "data", type: :json, queried: true}]
      }

      assert {:error, [%Violation{rule: :queried_json_conflict, path: [:fields, "data"]}]} =
               Validator.validate(definition)
    end
  end

  # ---------------------------------------------------------------------------
  # Rule 10 -- locale-set shape (:invalid_localized_text), new in REQ-301.
  # ---------------------------------------------------------------------------

  describe "Rule 10 -- locale-set shape (:invalid_localized_text)" do
    test "locales absent on a :localized_text field fails only :invalid_localized_text" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "stem", type: :localized_text}]
      }

      assert {:error,
              [%Violation{rule: :invalid_localized_text, path: [:fields, "stem", :locales]}]} =
               Validator.validate(definition)
    end

    test "locales as an empty list on a :localized_text field fails only :invalid_localized_text" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "stem", type: :localized_text, locales: []}]
      }

      assert {:error, [%Violation{rule: :invalid_localized_text}]} =
               Validator.validate(definition)
    end

    test "duplicate locales fails only :invalid_localized_text" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "stem", type: :localized_text, locales: ["kk", "kk"]}]
      }

      assert {:error, [%Violation{rule: :invalid_localized_text}]} =
               Validator.validate(definition)
    end

    test "a locale not matching ^[a-z]{2,8}$ fails only :invalid_localized_text" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "stem", type: :localized_text, locales: ["KK"]}]
      }

      assert {:error, [%Violation{rule: :invalid_localized_text}]} =
               Validator.validate(definition)
    end

    test "locales present on a non-:localized_text field fails only :invalid_localized_text" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string, locales: ["kk"]}]
      }

      assert {:error,
              [%Violation{rule: :invalid_localized_text, path: [:fields, "id", :locales]}]} =
               Validator.validate(definition)
    end
  end

  # ---------------------------------------------------------------------------
  # Rule 11 -- search_strategy shape (:invalid_search_strategy), new in REQ-301.
  # ---------------------------------------------------------------------------

  describe "Rule 11 -- search_strategy shape (:invalid_search_strategy)" do
    test "an invalid search_strategy value fails only :invalid_search_strategy" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [
          %{name: "stem", type: :localized_text, locales: ["kk"], search_strategy: :ranked}
        ]
      }

      assert {:error,
              [
                %Violation{
                  rule: :invalid_search_strategy,
                  path: [:fields, "stem", :search_strategy]
                }
              ]} =
               Validator.validate(definition)
    end

    test "search_strategy present on a non-:localized_text field fails only :invalid_search_strategy" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "id", type: :string, search_strategy: :plain}]
      }

      assert {:error, [%Violation{rule: :invalid_search_strategy}]} =
               Validator.validate(definition)
    end

    test "search_strategy absent on a :localized_text field is valid (defaults to :plain)" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "stem", type: :localized_text, locales: ["kk"]}]
      }

      assert Validator.validate(definition) == :ok
    end

    test "search_strategy explicitly :fulltext on a :localized_text field is valid" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [
          %{name: "stem", type: :localized_text, locales: ["kk"], search_strategy: :fulltext}
        ]
      }

      assert Validator.validate(definition) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed-shape precondition -- not one of the 11 rules, checked first.
  # ---------------------------------------------------------------------------

  describe "malformed-shape precondition" do
    test "a definition missing required top-level keys is rejected with :malformed, not a numbered rule" do
      assert {:error, [%Violation{rule: :malformed} | _]} = Validator.validate(%{})
    end

    test "a non-map input is rejected with :malformed" do
      assert {:error, [%Violation{rule: :malformed}]} = Validator.validate("not a map")
    end
  end

  describe "collects multiple violations when more than one rule fires" do
    test "two independent violations are both reported" do
      definition = %{
        name: "Widget",
        display_name: "Widget",
        fields: [%{name: "data", type: :json, queried: true}]
      }

      assert {:error, violations} = Validator.validate(definition)
      rules = Enum.map(violations, & &1.rule) |> Enum.sort()
      assert rules == [:name_format, :queried_json_conflict]
    end
  end

  # ---------------------------------------------------------------------------
  # GH #2529 -- optional top-level `append_only` boolean.
  # ---------------------------------------------------------------------------

  defp gh2529_definition(extra) do
    Map.merge(
      %{name: "ledger", display_name: "Ledger", fields: [%{name: "title", type: :string}]},
      extra
    )
  end

  describe "append_only" do
    test "true, false and absent are all :ok" do
      assert Validator.validate(gh2529_definition(%{append_only: true})) == :ok
      assert Validator.validate(gh2529_definition(%{append_only: false})) == :ok
      assert Validator.validate(gh2529_definition(%{})) == :ok
    end

    test "a present non-boolean (including nil) is malformed at [:append_only]" do
      for bad <- ["true", 1, "x", nil] do
        assert {:error, violations} = Validator.validate(gh2529_definition(%{append_only: bad})),
               "expected #{inspect(bad)} to be rejected"

        assert [%Violation{rule: :malformed, path: [:append_only]}] = violations
      end
    end
  end
end
