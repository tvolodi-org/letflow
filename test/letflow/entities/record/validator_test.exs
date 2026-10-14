defmodule Letflow.Entities.Record.ValidatorTest do
  @moduledoc """
  Unit tests for `Letflow.Entities.Record.Validator` (REQ-227). See
  `lib/letflow/design/req227-entity-record-payload-validation.md` §9 for the
  acceptance-criteria traceability each test group below maps to.

  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency -- `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Record.Validator
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.EventStore.Registry.ValidationFailure

  @definition %{
    name: "customer",
    display_name: "Customer",
    fields: [
      %{name: "customer_name", type: :string, required: true},
      %{name: "age", type: :integer, required: true},
      %{name: "balance", type: :decimal, decimal_precision: 10, decimal_scale: 2},
      %{name: "active", type: :boolean},
      %{name: "signed_up_on", type: :date},
      %{name: "last_login_at", type: :datetime},
      %{name: "status", type: :enum, enum_values: ["open", "closed"], required: true},
      %{name: "notes", type: :json}
    ]
  }

  # ---------------------------------------------------------------------------
  # AC1 -- a conforming payload passes validation with zero violations.
  # ---------------------------------------------------------------------------

  describe "AC1 -- a conforming record payload passes with zero violations" do
    test "a fully-populated, conforming field_values map returns []" do
      field_values = %{
        "customer_name" => "Acme",
        "age" => 42,
        "balance" => 12.50,
        "active" => true,
        "signed_up_on" => "2026-01-01",
        "last_login_at" => "2026-09-06T12:00:00Z",
        "status" => "open",
        "notes" => %{"any" => ["json", "shape", 1, true, nil]}
      }

      assert Validator.validate_record_payload(@definition, field_values) == []
    end

    test "a minimal payload with only required fields set returns []" do
      field_values = %{"customer_name" => "Acme", "age" => 42, "status" => "open"}

      assert Validator.validate_record_payload(@definition, field_values) == []
    end

    test ":json field accepts any JSON value (object, array, string, number, boolean, null)" do
      base = %{"customer_name" => "Acme", "age" => 42, "status" => "open"}

      for notes <- [%{"a" => 1}, [1, 2, 3], "a string", 5, true, nil] do
        field_values = Map.put(base, "notes", notes)
        assert Validator.validate_record_payload(@definition, field_values) == []
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 -- a payload violating 3+ distinct fields returns ALL violations, not
  # only the first.
  # ---------------------------------------------------------------------------

  describe "AC2 -- multiple independent field violations in one submission are all reported" do
    test "a payload violating 3 distinct fields' constraints returns all 3 (plus the missing-required) violations" do
      field_values = %{
        # wrong type (string instead of integer)
        "age" => "not-a-number",
        # not in enum
        "status" => "archived",
        # additionalProperties: false violation
        "unexpected_field" => "surprise"
        # "customer_name" (required) is missing entirely
      }

      violations = Validator.validate_record_payload(@definition, field_values)

      constraints = Enum.map(violations, & &1.constraint)
      field_paths = Enum.map(violations, & &1.field_path)

      assert "type" in constraints
      assert "enum" in constraints
      assert "additionalProperties" in constraints
      assert "required" in constraints

      assert "/age" in field_paths
      assert "/status" in field_paths
      assert "/unexpected_field" in field_paths
      assert "/customer_name" in field_paths

      # exactly one violation for each of the 4 distinct problems above --
      # confirms nothing short-circuited on the first failure.
      assert length(violations) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # AC3 -- each violation carries a correct (field_path, constraint, actual)
  # triple.
  # ---------------------------------------------------------------------------

  describe "AC3 -- each violation carries the correct field_path/constraint/actual triple" do
    test "a type violation reports the offending field's pointer, constraint name, and actual value" do
      field_values = %{"customer_name" => "Acme", "age" => "forty-two", "status" => "open"}

      assert [violation] = Validator.validate_record_payload(@definition, field_values)

      assert %ValidationFailure{
               field_path: "/age",
               constraint: "type",
               actual: "forty-two"
             } == violation
    end

    test "a required violation reports the missing field's pointer with actual: nil" do
      field_values = %{"age" => 42, "status" => "open"}

      assert [violation] = Validator.validate_record_payload(@definition, field_values)

      assert %ValidationFailure{
               field_path: "/customer_name",
               constraint: "required",
               actual: nil
             } == violation
    end

    test "an enum violation reports the offending field's pointer and the rejected value" do
      field_values = %{"customer_name" => "Acme", "age" => 42, "status" => "pending"}

      assert [violation] = Validator.validate_record_payload(@definition, field_values)

      assert %ValidationFailure{
               field_path: "/status",
               constraint: "enum",
               actual: "pending"
             } == violation
    end
  end

  # ---------------------------------------------------------------------------
  # AC4 -- the validation engine used is Letflow.EventStore.Registry.JsonSchema,
  # not a hand-rolled one.
  # ---------------------------------------------------------------------------

  describe "AC4 -- delegates to Letflow.EventStore.Registry.JsonSchema, not a hand-rolled engine" do
    test "validate_record_payload/2's result is identical to calling JsonSchema.validate/2 directly on the derived schema" do
      field_values = %{"customer_name" => "Acme", "age" => "bad", "status" => "nope"}

      schema = Validator.build_record_schema(@definition)

      assert Validator.validate_record_payload(@definition, field_values) ==
               JsonSchema.validate(field_values, schema)
    end

    test "build_record_schema/1 produces a plain string-keyed map consumable by JsonSchema.validate/2 directly" do
      schema = Validator.build_record_schema(@definition)

      assert schema == %{
               "type" => "object",
               "properties" => %{
                 "customer_name" => %{"type" => "string"},
                 "age" => %{"type" => "integer"},
                 "balance" => %{"type" => "number"},
                 "active" => %{"type" => "boolean"},
                 "signed_up_on" => %{"type" => "string"},
                 "last_login_at" => %{"type" => "string"},
                 "status" => %{"type" => "string", "enum" => ["open", "closed"]},
                 "notes" => %{}
               },
               "required" => ["customer_name", "age", "status"],
               "additionalProperties" => false
             }
    end
  end

  # ---------------------------------------------------------------------------
  # Design §4.2's worked example, exercised directly.
  # ---------------------------------------------------------------------------

  describe "design doc §4.2 worked example" do
    test "matches the design doc's literal derived-schema shape" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [
          %{name: "customer_name", type: :string, required: true},
          %{name: "status", type: :enum, enum_values: ["open", "closed"], required: false},
          %{name: "notes", type: :json}
        ]
      }

      assert Validator.build_record_schema(definition) == %{
               "type" => "object",
               "properties" => %{
                 "customer_name" => %{"type" => "string"},
                 "status" => %{"type" => "string", "enum" => ["open", "closed"]},
                 "notes" => %{}
               },
               "required" => ["customer_name"],
               "additionalProperties" => false
             }
    end
  end

  # ---------------------------------------------------------------------------
  # ISS-0617 / GH#1294 -- `:localized_text` had no `field_subschema/1` clause,
  # so any record write against a definition with a `:localized_text` field
  # raised `FunctionClauseError` instead of returning a clean violation list
  # (an INV-8-shaped crash-on-realistic-input defect). These tests cover the
  # fix's shape: an object subschema keyed by declared locale, partial-locale
  # writes accepted (DDL's per-locale generated columns are `nullable: true`
  # -- see `Letflow.Entities.Definition.Ddl.localized_text_column_specs/1`),
  # and an undeclared locale key rejected via the subschema's own
  # `additionalProperties: false` rather than crashing.
  # ---------------------------------------------------------------------------

  describe "ISS-0617 -- :localized_text field_subschema/1 clause" do
    @localized_definition %{
      name: "article",
      display_name: "Article",
      fields: [
        %{name: "title", type: :string, required: true},
        %{name: "stem", type: :localized_text, locales: ["kk", "ru"]}
      ]
    }

    test "build_record_schema/1 emits an object subschema keyed by each declared locale" do
      assert Validator.build_record_schema(@localized_definition) == %{
               "type" => "object",
               "properties" => %{
                 "title" => %{"type" => "string"},
                 "stem" => %{
                   "type" => "object",
                   "properties" => %{
                     "kk" => %{"type" => "string"},
                     "ru" => %{"type" => "string"}
                   },
                   "additionalProperties" => false
                 }
               },
               "required" => ["title"],
               "additionalProperties" => false
             }
    end

    test "a write with every declared locale present returns []" do
      field_values = %{
        "title" => "Kitap",
        "stem" => %{"kk" => "мәтін", "ru" => "текст"}
      }

      assert Validator.validate_record_payload(@localized_definition, field_values) == []
    end

    test "a write with only some declared locales present (partial-locale write) also returns [] -- no crash, no violation" do
      field_values = %{
        "title" => "Kitap",
        "stem" => %{"kk" => "мәтін"}
      }

      assert Validator.validate_record_payload(@localized_definition, field_values) == []
    end

    test "a write with the localized_text field omitted entirely returns [] -- field itself is not required" do
      field_values = %{"title" => "Kitap"}

      assert Validator.validate_record_payload(@localized_definition, field_values) == []
    end

    test "a write with an undeclared locale key is rejected cleanly via additionalProperties, not a crash" do
      field_values = %{
        "title" => "Kitap",
        "stem" => %{"kk" => "мәтін", "fr" => "texte"}
      }

      assert [violation] = Validator.validate_record_payload(@localized_definition, field_values)

      assert %ValidationFailure{
               field_path: "/stem/fr",
               constraint: "additionalProperties",
               actual: "texte"
             } == violation
    end

    test "a non-string value for a declared locale is rejected with a type violation, matching other types' failure shape" do
      field_values = %{
        "title" => "Kitap",
        "stem" => %{"kk" => 123}
      }

      assert [violation] = Validator.validate_record_payload(@localized_definition, field_values)

      assert %ValidationFailure{
               field_path: "/stem/kk",
               constraint: "type",
               actual: 123
             } == violation
    end

    test "a non-object value for the localized_text field itself is rejected with a type violation, not a crash" do
      field_values = %{"title" => "Kitap", "stem" => "not an object"}

      assert [violation] = Validator.validate_record_payload(@localized_definition, field_values)

      assert %ValidationFailure{
               field_path: "/stem",
               constraint: "type",
               actual: "not an object"
             } == violation
    end
  end

  # ---------------------------------------------------------------------------
  # GH #2532 -- "minimum"/"maximum" from min/max/non_negative.
  # See lib/letflow/design/gh2532-field-min-max-non-negative.md §4.
  # ---------------------------------------------------------------------------

  defp gh2532_definition(qty_field) do
    %{name: "stock", display_name: "Stock", fields: [Map.put(qty_field, :name, "qty")]}
  end

  defp gh2532_qty_subschema(qty_field) do
    gh2532_definition(qty_field)
    |> Validator.build_record_schema()
    |> get_in(["properties", "qty"])
  end

  describe "GH #2532 range keywords" do
    test ~s({integer, min 1, max 5} yields "minimum" => 1, "maximum" => 5) do
      assert gh2532_qty_subschema(%{type: :integer, min: 1, max: 5}) ==
               %{"type" => "integer", "minimum" => 1, "maximum" => 5}
    end

    test ~s(non_negative yields "minimum" => 0) do
      assert gh2532_qty_subschema(%{type: :integer, non_negative: true}) ==
               %{"type" => "integer", "minimum" => 0}

      assert gh2532_qty_subschema(%{type: :decimal, non_negative: true, max: 9.5}) ==
               %{"type" => "number", "minimum" => 0, "maximum" => 9.5}
    end

    test "key-less subschema is exactly the type map" do
      assert gh2532_qty_subschema(%{type: :integer}) == %{"type" => "integer"}

      assert gh2532_qty_subschema(%{type: :decimal, decimal_precision: 10, decimal_scale: 2}) ==
               %{"type" => "number"}
    end

    test "0 with min 1 gives minimum at /qty, 6 with max 5 gives maximum, 1 and 5 pass" do
      definition = gh2532_definition(%{type: :integer, min: 1, max: 5})

      assert [%ValidationFailure{field_path: "/qty", constraint: "minimum", actual: 0}] =
               Validator.validate_record_payload(definition, %{"qty" => 0})

      assert [%ValidationFailure{field_path: "/qty", constraint: "maximum", actual: 6}] =
               Validator.validate_record_payload(definition, %{"qty" => 6})

      assert Validator.validate_record_payload(definition, %{"qty" => 1}) == []
      assert Validator.validate_record_payload(definition, %{"qty" => 5}) == []
    end

    test "decimal 0.5 with min 0.1 passes; 0.05 does not; 0.1 itself passes" do
      definition = gh2532_definition(%{type: :decimal, min: 0.1})

      assert Validator.validate_record_payload(definition, %{"qty" => 0.5}) == []
      assert Validator.validate_record_payload(definition, %{"qty" => 0.1}) == []

      assert [%ValidationFailure{constraint: "minimum"}] =
               Validator.validate_record_payload(definition, %{"qty" => 0.05})
    end

    test "effective_minimum/2 table, through build_record_schema/1" do
      # (number m, true) -> max(m, 0)
      assert gh2532_qty_subschema(%{type: :decimal, min: 2.5, non_negative: true})["minimum"] ==
               2.5

      assert gh2532_qty_subschema(%{type: :integer, min: 7, non_negative: true})["minimum"] == 7
      # the clamp: a negative min with non_negative (corrupt stored data; Rule 12
      # rejects it at definition time) still yields 0
      assert gh2532_qty_subschema(%{type: :integer, min: -3, non_negative: true})["minimum"] == 0
      # (number m, not true) -> m
      assert gh2532_qty_subschema(%{type: :integer, min: -4})["minimum"] == -4

      assert gh2532_qty_subschema(%{type: :integer, min: -4, non_negative: false})["minimum"] ==
               -4

      assert gh2532_qty_subschema(%{type: :integer, min: -4, non_negative: "yes"})["minimum"] ==
               -4

      # (non-number, true) -> 0
      assert gh2532_qty_subschema(%{type: :integer, min: "a", non_negative: true})["minimum"] == 0
      # (non-number, not true) -> no "minimum"
      refute Map.has_key?(gh2532_qty_subschema(%{type: :integer, min: "a"}), "minimum")
      refute Map.has_key?(gh2532_qty_subschema(%{type: :integer, non_negative: "yes"}), "minimum")
      refute Map.has_key?(gh2532_qty_subschema(%{type: :integer, min: nil}), "minimum")
    end

    test "a non-number stored bound is ignored, never a crash (INV-8)" do
      definition = gh2532_definition(%{type: :integer, min: "a", max: "b", non_negative: "yes"})

      assert Validator.build_record_schema(definition)["properties"]["qty"] ==
               %{"type" => "integer"}

      assert Validator.validate_record_payload(definition, %{"qty" => -1}) == []
    end
  end
end
