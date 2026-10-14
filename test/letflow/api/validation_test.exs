defmodule Letflow.Api.ValidationTest do
  @moduledoc """
  Tests for `Letflow.Api.Validation` (REQ-068). No database — pure module,
  plain `ExUnit.Case`, same convention as `test/letflow/api/error_test.exs`.

  Includes the four INV-8 crash-class cases the requirement's acceptance
  criteria names explicitly (invalid-shape body, non-object body, a
  10-level-nested object, a NUL-byte-containing string), the
  three-simultaneous-field-errors case, and adversarial inputs beyond what
  the acceptance criteria lists (malformed UTF-8, a very deep structure, SQL
  metacharacters) to back the security self-review this run performed.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.{FieldConstraint, FieldError}

  # ── validate_field/2 — single constraint, single value ────────────────────

  describe "validate_field/2 — required" do
    test "missing required field -> required error" do
      c = %FieldConstraint{name: "x", required: true}

      assert %FieldError{field: "x", constraint: "required"} =
               Validation.validate_field(c, :missing)
    end

    test "present required field, no other constraints -> nil" do
      c = %FieldConstraint{name: "x", required: true}
      assert Validation.validate_field(c, "anything") == nil
    end

    test "missing optional field -> nil (no other checks run)" do
      c = %FieldConstraint{name: "x", required: false, type: :string, min_length: 5}
      assert Validation.validate_field(c, :missing) == nil
    end

    test "JSON null on a required field is treated as absent, per validation.zig:162" do
      c = %FieldConstraint{name: "x", required: true}
      assert %FieldError{constraint: "required"} = Validation.validate_field(c, nil)
    end
  end

  describe "validate_field/2 — reject_empty_string" do
    test "empty string on a required field with reject_empty_string -> required" do
      c = %FieldConstraint{name: "x", required: true, reject_empty_string: true}
      assert %FieldError{constraint: "required"} = Validation.validate_field(c, "")
    end

    test "empty string on an optional field with reject_empty_string -> not_empty" do
      c = %FieldConstraint{name: "x", required: false, reject_empty_string: true}
      assert %FieldError{constraint: "not_empty"} = Validation.validate_field(c, "")
    end

    test "empty string allowed when reject_empty_string is false (the default)" do
      c = %FieldConstraint{name: "x", required: false}
      assert Validation.validate_field(c, "") == nil
    end
  end

  describe "validate_field/2 — type checks, never raise on the wrong shape" do
    test "string expected, got integer" do
      c = %FieldConstraint{name: "x", type: :string}

      assert %FieldError{constraint: "type.string", received: 42} =
               Validation.validate_field(c, 42)
    end

    test "string expected, got a map (the '10-level-nested object under a flat schema' shape)" do
      c = %FieldConstraint{name: "x", type: :string}
      nested = deep_map(10)
      assert %FieldError{constraint: "type.string"} = Validation.validate_field(c, nested)
    end

    test "string expected, got a list -> type error, not a crash" do
      c = %FieldConstraint{name: "x", type: :string}
      assert %FieldError{constraint: "type.string"} = Validation.validate_field(c, [1, 2, 3])
    end

    test "integer expected, float rejected (integer is a strict subtype)" do
      c = %FieldConstraint{name: "x", type: :integer}
      assert %FieldError{constraint: "type.integer"} = Validation.validate_field(c, 1.5)
    end

    test "number accepts both integer and float" do
      c = %FieldConstraint{name: "x", type: :number}
      assert Validation.validate_field(c, 1) == nil
      assert Validation.validate_field(c, 1.5) == nil
    end

    test "boolean, object, array type checks" do
      assert Validation.validate_field(%FieldConstraint{name: "x", type: :boolean}, true) == nil
      assert Validation.validate_field(%FieldConstraint{name: "x", type: :object}, %{}) == nil
      assert Validation.validate_field(%FieldConstraint{name: "x", type: :array}, []) == nil

      assert %FieldError{constraint: "type.boolean"} =
               Validation.validate_field(%FieldConstraint{name: "x", type: :boolean}, "true")
    end
  end

  describe "validate_field/2 — :uuid (design doc §0.6, not ported from R-Co — a real addition)" do
    test "a canonical UUID string passes" do
      c = %FieldConstraint{name: "id", type: :uuid}
      assert Validation.validate_field(c, Ecto.UUID.generate()) == nil
    end

    test "a non-UUID string is rejected with a typed error, not a crash" do
      c = %FieldConstraint{name: "id", type: :uuid}
      assert %FieldError{constraint: "type.uuid"} = Validation.validate_field(c, "not-a-uuid")
    end

    test "a non-string value against a :uuid constraint does not raise" do
      c = %FieldConstraint{name: "id", type: :uuid}
      assert %FieldError{constraint: "type.uuid"} = Validation.validate_field(c, 12_345)
      assert %FieldError{constraint: "type.uuid"} = Validation.validate_field(c, %{"a" => 1})
      assert %FieldError{constraint: "type.uuid"} = Validation.validate_field(c, [1, 2])
    end
  end

  describe "validate_field/2 — string length bounds" do
    test "below min_length" do
      c = %FieldConstraint{name: "x", type: :string, min_length: 3}
      assert %FieldError{constraint: "min_length"} = Validation.validate_field(c, "ab")
    end

    test "above max_length" do
      c = %FieldConstraint{name: "x", type: :string, max_length: 3}
      assert %FieldError{constraint: "max_length"} = Validation.validate_field(c, "abcd")
    end

    test "within bounds -> nil" do
      c = %FieldConstraint{name: "x", type: :string, min_length: 1, max_length: 5}
      assert Validation.validate_field(c, "abc") == nil
    end
  end

  describe "validate_field/2 — numeric range" do
    test "below min_value / above max_value" do
      c = %FieldConstraint{name: "x", type: :integer, min_value: 1, max_value: 10}
      assert %FieldError{constraint: "min_value"} = Validation.validate_field(c, 0)
      assert %FieldError{constraint: "max_value"} = Validation.validate_field(c, 11)
      assert Validation.validate_field(c, 5) == nil
    end
  end

  describe "validate_field/2 — array size" do
    test "below min_items / above max_items" do
      c = %FieldConstraint{name: "x", type: :array, min_items: 1, max_items: 2}
      assert %FieldError{constraint: "min_items"} = Validation.validate_field(c, [])
      assert %FieldError{constraint: "max_items"} = Validation.validate_field(c, [1, 2, 3])
      assert Validation.validate_field(c, [1]) == nil
    end
  end

  describe "validate_field/2 — enum membership (design doc §0.8, not in R-Co's stubbed pattern)" do
    test "value not in allowed_values" do
      c = %FieldConstraint{name: "status", type: :string, allowed_values: ["open", "closed"]}
      assert %FieldError{constraint: "enum_membership"} = Validation.validate_field(c, "pending")
    end

    test "value in allowed_values -> nil" do
      c = %FieldConstraint{name: "status", type: :string, allowed_values: ["open", "closed"]}
      assert Validation.validate_field(c, "open") == nil
    end
  end

  # ── validate/2 — whole-body validation ─────────────────────────────────────

  describe "validate/2 — structural safety (INV-8, design doc §0.9)" do
    test "a JSON array where an object is required -> typed (root)/type.object error, not a crash" do
      assert {:errors, [%FieldError{field: "(root)", constraint: "type.object"}]} =
               Validation.validate([], [1, 2, 3])
    end

    test "a JSON scalar (string) body -> same typed error" do
      assert {:errors, [%FieldError{field: "(root)", constraint: "type.object"}]} =
               Validation.validate([], "just a string")
    end

    test "a JSON scalar (number) body -> same typed error, no crash on is_map/1 guard" do
      assert {:errors, [%FieldError{constraint: "type.object"}]} = Validation.validate([], 42)
    end

    test "a JSON null body -> same typed error" do
      assert {:errors, [%FieldError{constraint: "type.object"}]} = Validation.validate([], nil)
    end

    test "a 10-level-nested object, validated against a schema expecting a flat string field, is a typed rejection not a crash" do
      schema = [%FieldConstraint{name: "name", type: :string}]
      body = %{"name" => deep_map(10)}

      assert {:errors, [%FieldError{field: "name", constraint: "type.string"}]} =
               Validation.validate(schema, body)
    end

    test "a string field containing a NUL byte is rejected structurally, before any FieldConstraint runs" do
      schema = [%FieldConstraint{name: "name", type: :string, min_length: 100}]
      body = %{"name" => "ab\0cd"}

      # min_length: 100 would ALSO fail if reached — asserting the specific
      # no_null_byte constraint proves the structural check ran first and
      # short-circuited, matching validate/4's own object-check early return.
      assert {:errors, [%FieldError{field: "(root).name", constraint: "no_null_byte"}]} =
               Validation.validate(schema, body)
    end

    test "a NUL byte nested inside an array inside the body is still found" do
      body = %{"items" => ["ok", ["nested\0value"]]}

      assert {:errors, [%FieldError{field: path, constraint: "no_null_byte"}]} =
               Validation.validate([], body)

      assert path == "(root).items[1][0]"
    end

    test "a NUL byte in a key not declared by the schema is still caught (design doc §0.9 point 3)" do
      schema = [%FieldConstraint{name: "declared", type: :string}]
      body = %{"declared" => "fine", "undeclared" => "bad\0value"}

      assert {:errors, [%FieldError{constraint: "no_null_byte"}]} =
               Validation.validate(schema, body)
    end

    # GH #2528 mixed-version safety: an old server (POST's @record_write_schema)
    # receiving the new expected_last_event_global_seq key ignores it.
    test "GH #2528: an unknown body key does not break validate/2 and is dropped from the result" do
      schema = [%FieldConstraint{name: "field_values", required: true, type: :object}]
      body = %{"field_values" => %{}, "expected_last_event_global_seq" => 7}

      assert {:ok, %{"field_values" => %{}} = attrs} = Validation.validate(schema, body)
      refute Map.has_key?(attrs, "expected_last_event_global_seq")
    end

    test "SQL metacharacters in a string value are ordinary values, not rejected (design doc §0.9 point 5)" do
      schema = [%FieldConstraint{name: "name", type: :string}]
      body = %{"name" => "Robert'); DROP TABLE students;--"}

      assert {:ok, %{"name" => "Robert'); DROP TABLE students;--"}} =
               Validation.validate(schema, body)
    end

    test "malformed/invalid UTF-8 byte sequences do not crash the NUL-byte walk or type checks" do
      # A lone continuation byte — not valid UTF-8, but still a legal Elixir
      # binary Jason can hand back for a string field via unicode escapes in
      # some decoders; validate/2 must not raise regardless.
      schema = [%FieldConstraint{name: "name", type: :string, max_length: 1000}]
      bad_utf8 = <<"prefix-", 0x80, 0x81, "-suffix">>
      body = %{"name" => bad_utf8}

      assert {:ok, %{"name" => ^bad_utf8}} = Validation.validate(schema, body)
    end

    test "a very deep structure (500 levels) does not crash the NUL-byte walk" do
      body = %{"root" => deep_map(500)}
      assert {:ok, _} = Validation.validate([], body)
    end
  end

  describe "validate/2 — collects ALL field errors, never stops at the first (design doc §0.1, AC4)" do
    test "three simultaneously invalid fields produce one error list naming all three" do
      schema = [
        %FieldConstraint{name: "name", required: true},
        %FieldConstraint{name: "age", type: :integer},
        %FieldConstraint{name: "email", type: :string, min_length: 5}
      ]

      body = %{"age" => "not a number", "email" => "ab"}

      assert {:errors, errors} = Validation.validate(schema, body)
      fields = Enum.map(errors, & &1.field) |> Enum.sort()

      assert fields == ["age", "email", "name"]
    end
  end

  describe "validate/2 — success path" do
    test "all constraints pass -> {:ok, map} containing exactly the schema's fields" do
      schema = [
        %FieldConstraint{name: "name", required: true, type: :string},
        %FieldConstraint{name: "age", type: :integer}
      ]

      body = %{"name" => "Ada", "age" => 30, "extra" => "dropped"}

      assert {:ok, %{"name" => "Ada", "age" => 30} = result} = Validation.validate(schema, body)
      refute Map.has_key?(result, "extra")
    end

    test "an empty schema against an empty object body succeeds" do
      assert {:ok, %{}} = Validation.validate([], %{})
    end
  end

  # ── problem/1 ───────────────────────────────────────────────────────────

  describe "problem/1" do
    test "builds a 422 Letflow.Api.Error carrying the field errors" do
      errors = [%FieldError{field: "x", constraint: "required", message: "field is required"}]
      problem = Validation.problem(errors)

      assert %Letflow.Api.Error{status: 422, errors: ^errors} = problem
    end

    test "serialised via Letflow.Api.Error.serialise/1 includes the errors array" do
      errors = [%FieldError{field: "x", constraint: "required", message: "field is required"}]
      json = errors |> Validation.problem() |> Letflow.Api.Error.serialise() |> Jason.decode!()

      assert json["status"] == 422
      assert [%{"field" => "x", "constraint" => "required"}] = json["errors"]
    end
  end

  defp deep_map(0), do: "leaf"
  defp deep_map(n), do: %{"nested" => deep_map(n - 1)}
end
