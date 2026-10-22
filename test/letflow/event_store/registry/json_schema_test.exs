defmodule Letflow.EventStore.Registry.JsonSchemaTest do
  @moduledoc """
  Unit tests for `Letflow.EventStore.Registry.JsonSchema.validate/2` (REQ-024,
  part of acceptance criterion 3). Pure module, no `Letflow.Repo`/`Ecto.Sandbox`
  dependency anywhere in this file — `async: true` is correct here, matching
  `test/letflow/definitions/graph_test.exs`'s (REQ-028) precedent for a pure,
  zero-I/O validator: one describe block per supported keyword/check, each
  asserting the exact violation list a minimal failing example produces. See
  `test/specs/REQ-024.md` for the full test-case rationale.

  Keyword-for-keyword coverage target, per
  `lib/letflow/design/req024-event-type-registry.md` section 1.1's table and
  `json_schema.ex`'s own moduledoc: `type`, `minimum`/`maximum`,
  `minLength`/`maxLength`, `enum`, `required`, `properties`, `items`,
  `additionalProperties` (literal `false` only) — plus the "unsupported
  keywords are permitted and inert" contract, RFC 6901 pointer construction
  (including `~0`/`~1` escaping), and the type-mismatch cascade-avoidance
  short-circuit.
  """

  use ExUnit.Case, async: true

  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.EventStore.Registry.ValidationFailure

  # A list of {field_path, constraint} pairs, in the exact order validate/2
  # returned them — the algorithm's check order (design doc section 4.4) is
  # deterministic (enum, then numeric, then string, then object, then array),
  # so asserting on order (not just an unordered set) is a strictly stronger
  # check, matching graph_test.exs's `codes/1` helper convention.
  defp failures(violations), do: Enum.map(violations, &{&1.field_path, &1.constraint})

  # ---------------------------------------------------------------------
  # AC1 (of this file's own coverage, not REQ-024's numbered ACs) — a fully
  # valid payload against a well-formed, multi-keyword schema passes clean.
  # ---------------------------------------------------------------------

  describe "validate/2 — fully valid payload" do
    test "a payload satisfying every keyword in a combined schema returns []" do
      schema = %{
        "type" => "object",
        "required" => ["name", "age"],
        "properties" => %{
          "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 10},
          "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
          "status" => %{"type" => "string", "enum" => ["active", "inactive"]},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "additionalProperties" => false
      }

      payload = %{
        "name" => "Ada",
        "age" => 36,
        "status" => "active",
        "tags" => ["x", "y"]
      }

      assert JsonSchema.validate(payload, schema) == []
    end

    test "the empty schema {} is fully permissive — anything passes" do
      assert JsonSchema.validate(%{"anything" => "goes", "n" => 1}, %{}) == []
    end
  end

  # ---------------------------------------------------------------------
  # "type" keyword
  # ---------------------------------------------------------------------

  describe "validate/2 — \"type\" keyword" do
    test "a value not matching a single string type produces exactly one \"type\" violation" do
      schema = %{"type" => "object", "properties" => %{"amount" => %{"type" => "number"}}}
      payload = %{"amount" => "not-a-number"}

      result = JsonSchema.validate(payload, schema)
      assert failures(result) == [{"/amount", "type"}]

      assert [
               %ValidationFailure{
                 field_path: "/amount",
                 constraint: "type",
                 actual: "not-a-number"
               }
             ] = result
    end

    test "a value matching one member of a type array is accepted" do
      schema = %{"type" => "object", "properties" => %{"v" => %{"type" => ["string", "null"]}}}

      assert JsonSchema.validate(%{"v" => "hello"}, schema) == []
      assert JsonSchema.validate(%{"v" => nil}, schema) == []
    end

    test "a value matching none of a type array's members produces a \"type\" violation" do
      schema = %{"type" => "object", "properties" => %{"v" => %{"type" => ["string", "null"]}}}

      result = JsonSchema.validate(%{"v" => 42}, schema)
      assert failures(result) == [{"/v", "type"}]
    end

    test "every scalar/composite type name matches its own runtime shape (round-trip over all 7)" do
      cases = [
        {"string", "hi"},
        {"number", 1.5},
        {"integer", 1},
        {"boolean", true},
        {"object", %{}},
        {"array", []},
        {"null", nil}
      ]

      for {type_name, value} <- cases do
        schema = %{"type" => "object", "properties" => %{"v" => %{"type" => type_name}}}

        assert JsonSchema.validate(%{"v" => value}, schema) == [],
               "expected #{type_name} to match #{inspect(value)}"
      end
    end

    test "a type mismatch at a given level short-circuits sibling keyword checks at that same level" do
      # "v" violates "type" (a string, not a number) AND would also violate
      # "minimum" if numeric checks ran anyway -- only the "type" violation is
      # returned, matching R-Co's collectInto cascade-avoidance exactly
      # (design doc section 4.4).
      schema = %{
        "type" => "object",
        "properties" => %{"v" => %{"type" => "number", "minimum" => 100}}
      }

      result = JsonSchema.validate(%{"v" => "not-a-number"}, schema)
      assert failures(result) == [{"/v", "type"}]
    end

    test "a type mismatch does not stop sibling subtrees from being checked" do
      # "a" violates type; "b" independently violates minLength. Both must be
      # reported -- the short-circuit is per-level, not global.
      schema = %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "number"},
          "b" => %{"type" => "string", "minLength" => 5}
        }
      }

      result = JsonSchema.validate(%{"a" => "nope", "b" => "hi"}, schema)
      assert failures(result) == [{"/a", "type"}, {"/b", "minLength"}]
    end

    test "an unrecognized type-name string is treated permissively (never fails) -- schema well-formedness is not this validator's concern" do
      schema = %{"type" => "object", "properties" => %{"v" => %{"type" => "integr"}}}

      assert JsonSchema.validate(%{"v" => "anything"}, schema) == []
    end

    test "a malformed \"type\" value (not a string or list) is treated as inert, not raised" do
      schema = %{"type" => "object", "properties" => %{"v" => %{"type" => 42}}}

      assert JsonSchema.validate(%{"v" => "anything"}, schema) == []
    end
  end

  # ---------------------------------------------------------------------
  # "minimum" / "maximum"
  # ---------------------------------------------------------------------

  describe "validate/2 — \"minimum\"/\"maximum\"" do
    test "a value below minimum produces a \"minimum\" violation" do
      schema = %{"type" => "object", "properties" => %{"n" => %{"minimum" => 10}}}

      result = JsonSchema.validate(%{"n" => 5}, schema)
      assert failures(result) == [{"/n", "minimum"}]
    end

    test "a value above maximum produces a \"maximum\" violation" do
      schema = %{"type" => "object", "properties" => %{"n" => %{"maximum" => 10}}}

      result = JsonSchema.validate(%{"n" => 15}, schema)
      assert failures(result) == [{"/n", "maximum"}]
    end

    test "a value both below minimum and above maximum is impossible, but boundary values are accepted (>=, <=, not >, <)" do
      schema = %{
        "type" => "object",
        "properties" => %{"n" => %{"minimum" => 0, "maximum" => 100}}
      }

      assert JsonSchema.validate(%{"n" => 0}, schema) == []
      assert JsonSchema.validate(%{"n" => 100}, schema) == []
    end

    test "minimum/maximum are ignored entirely for non-numeric values (guarded, not raised)" do
      schema = %{"type" => "object", "properties" => %{"n" => %{"minimum" => 10}}}

      # "n" has no "type" keyword at this level, so a string is accepted
      # structurally; minimum simply never applies to a non-number.
      assert JsonSchema.validate(%{"n" => "ten"}, schema) == []
    end
  end

  # ---------------------------------------------------------------------
  # "minLength" / "maxLength"
  # ---------------------------------------------------------------------

  describe "validate/2 — \"minLength\"/\"maxLength\"" do
    test "a string shorter than minLength produces a \"minLength\" violation" do
      schema = %{"type" => "object", "properties" => %{"s" => %{"minLength" => 3}}}

      result = JsonSchema.validate(%{"s" => "ab"}, schema)
      assert failures(result) == [{"/s", "minLength"}]
    end

    test "a string longer than maxLength produces a \"maxLength\" violation" do
      schema = %{"type" => "object", "properties" => %{"s" => %{"maxLength" => 3}}}

      result = JsonSchema.validate(%{"s" => "abcd"}, schema)
      assert failures(result) == [{"/s", "maxLength"}]
    end

    test "boundary lengths (== min, == max) are accepted" do
      schema = %{
        "type" => "object",
        "properties" => %{"s" => %{"minLength" => 2, "maxLength" => 4}}
      }

      assert JsonSchema.validate(%{"s" => "ab"}, schema) == []
      assert JsonSchema.validate(%{"s" => "abcd"}, schema) == []
    end

    test "length is counted in codepoints, not bytes -- a multi-byte-per-codepoint string is measured correctly" do
      # "café" is 4 codepoints but 5 bytes (é is 2 bytes in UTF-8). minLength: 4
      # must pass (codepoint count), which would fail under a byte-count
      # implementation only if it were < 4 -- so this instead pins the
      # opposite, sharper case: a 4-codepoint/5-byte string against
      # maxLength: 4 must PASS (codepoint count 4 <= 4), which a
      # byte-length-based implementation would incorrectly reject (5 > 4).
      schema = %{"type" => "object", "properties" => %{"s" => %{"maxLength" => 4}}}

      assert String.length("café") == 4
      assert byte_size("café") == 5
      assert JsonSchema.validate(%{"s" => "café"}, schema) == []
    end
  end

  # ---------------------------------------------------------------------
  # "enum"
  # ---------------------------------------------------------------------

  describe "validate/2 — \"enum\"" do
    test "a value not present in the enum list produces an \"enum\" violation" do
      schema = %{"type" => "object", "properties" => %{"status" => %{"enum" => ["a", "b", "c"]}}}

      result = JsonSchema.validate(%{"status" => "bogus"}, schema)
      assert failures(result) == [{"/status", "enum"}]
    end

    test "a value present in the enum list is accepted" do
      schema = %{"type" => "object", "properties" => %{"status" => %{"enum" => ["a", "b", "c"]}}}

      assert JsonSchema.validate(%{"status" => "b"}, schema) == []
    end

    test "enum uses deep-equality, not identity -- a structurally-equal map is accepted" do
      schema = %{
        "type" => "object",
        "properties" => %{"cfg" => %{"enum" => [%{"a" => 1}, %{"b" => 2}]}}
      }

      assert JsonSchema.validate(%{"cfg" => %{"a" => 1}}, schema) == []
    end

    test "a malformed \"enum\" value (not a list) is treated as inert, not raised" do
      schema = %{"type" => "object", "properties" => %{"v" => %{"enum" => "not-a-list"}}}

      assert JsonSchema.validate(%{"v" => "anything"}, schema) == []
    end
  end

  # ---------------------------------------------------------------------
  # "required"
  # ---------------------------------------------------------------------

  describe "validate/2 — \"required\"" do
    test "a missing required field produces a \"required\" violation whose field_path names the missing field" do
      schema = %{"type" => "object", "required" => ["order_id"]}

      result = JsonSchema.validate(%{}, schema)
      assert failures(result) == [{"/order_id", "required"}]

      assert [%ValidationFailure{field_path: "/order_id", constraint: "required", actual: nil}] =
               result
    end

    test "every missing required field gets its own violation, not just the first" do
      schema = %{"type" => "object", "required" => ["a", "b", "c"]}

      result = JsonSchema.validate(%{"b" => 1}, schema)
      assert failures(result) == [{"/a", "required"}, {"/c", "required"}]
    end

    test "a present required field (even if falsy, e.g. false/0/\"\") is not flagged missing" do
      schema = %{"type" => "object", "required" => ["flag"]}

      assert JsonSchema.validate(%{"flag" => false}, schema) == []
    end

    test "required is only evaluated for map values -- a non-map nested value does not raise" do
      # validate/2's own top-level guard requires a map payload (an
      # unconditional platform invariant enforced one layer up, in
      # Registry.validate_payload/3 -- design doc section 4.2 step 1), so
      # this exercises the guarded is_map(value) clause at a NESTED level
      # instead: no "type" keyword forces "nested" to be an object, and its
      # subschema carries "required" -- a string value there must not raise.
      schema = %{
        "type" => "object",
        "properties" => %{"nested" => %{"required" => ["x"]}}
      }

      assert JsonSchema.validate(%{"nested" => "not-an-object"}, schema) == []
    end

    test "a malformed \"required\" value (not a list) is treated as inert, not raised" do
      schema = %{"type" => "object", "required" => "not-a-list"}

      assert JsonSchema.validate(%{}, schema) == []
    end
  end

  # ---------------------------------------------------------------------
  # "properties" (recursive)
  # ---------------------------------------------------------------------

  describe "validate/2 — \"properties\" (recursive)" do
    test "a nested property violation reports a field_path joined to the parent pointer" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "address" => %{
            "type" => "object",
            "properties" => %{"zip" => %{"type" => "string", "minLength" => 5}}
          }
        }
      }

      result = JsonSchema.validate(%{"address" => %{"zip" => "12"}}, schema)
      assert failures(result) == [{"/address/zip", "minLength"}]
    end

    test "a property absent from the payload is not recursed into (only \"required\" governs absence)" do
      schema = %{
        "type" => "object",
        "properties" => %{"opt" => %{"type" => "string", "minLength" => 100}}
      }

      # "opt" is not present and not required -- properties-recursion only
      # applies to keys the payload actually has.
      assert JsonSchema.validate(%{}, schema) == []
    end

    test "a malformed \"properties\" value (not a map) is treated as inert, not raised" do
      schema = %{"type" => "object", "properties" => "not-a-map"}

      assert JsonSchema.validate(%{"anything" => 1}, schema) == []
    end

    test "a subschema that is itself not a map is treated as inert, not raised, even though \"properties\" itself is well-formed (ISS-0088/GH#305)" do
      # Confirmed by execution before the fix: this exact shape raised
      # FunctionClauseError -- properties_violations/3 checked that
      # schema["properties"] is a map but recursed into each subschema
      # unchecked, unlike array_violations/3's own items_schema guard.
      schema = %{"type" => "object", "properties" => %{"x" => "junk"}}

      assert JsonSchema.validate(%{"x" => 1}, schema) == []
    end

    test "a malformed subschema for one key does not suppress a real violation reported for a sibling key" do
      schema = %{
        "type" => "object",
        "properties" => %{"bad_schema" => "junk", "good" => %{"type" => "string"}}
      }

      result = JsonSchema.validate(%{"bad_schema" => 1, "good" => 42}, schema)
      assert failures(result) == [{"/good", "type"}]
    end
  end

  # ---------------------------------------------------------------------
  # "items" (uniform-subschema array recursion)
  # ---------------------------------------------------------------------

  describe "validate/2 — \"items\"" do
    test "each array element is validated against the single items subschema, with an indexed field_path" do
      schema = %{
        "type" => "object",
        "properties" => %{"tags" => %{"type" => "array", "items" => %{"type" => "string"}}}
      }

      result = JsonSchema.validate(%{"tags" => ["ok", 42, "also-ok"]}, schema)
      assert failures(result) == [{"/tags/1", "type"}]
    end

    test "multiple invalid elements each get their own violation, correctly indexed" do
      schema = %{
        "type" => "object",
        "properties" => %{"ns" => %{"type" => "array", "items" => %{"minimum" => 0}}}
      }

      result = JsonSchema.validate(%{"ns" => [-1, 5, -2]}, schema)
      assert failures(result) == [{"/ns/0", "minimum"}, {"/ns/2", "minimum"}]
    end

    test "tuple-form items (a list of subschemas) is NOT implemented -- treated as inert, matching R-Co" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "tup" => %{"type" => "array", "items" => [%{"type" => "string"}, %{"type" => "number"}]}
        }
      }

      # If tuple-form were implemented, index 0 (a number against
      # {"type": "string"}) would fail -- it must not, since only the
      # single-subschema form is supported.
      assert JsonSchema.validate(%{"tup" => [42, "x"]}, schema) == []
    end

    test "an empty array trivially satisfies items (nothing to recurse into)" do
      schema = %{
        "type" => "object",
        "properties" => %{"tags" => %{"type" => "array", "items" => %{"type" => "string"}}}
      }

      assert JsonSchema.validate(%{"tags" => []}, schema) == []
    end
  end

  # ---------------------------------------------------------------------
  # "additionalProperties" (literal false only)
  # ---------------------------------------------------------------------

  describe "validate/2 — \"additionalProperties\"" do
    test "additionalProperties: false flags every key not listed in properties" do
      schema = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}},
        "additionalProperties" => false
      }

      result = JsonSchema.validate(%{"a" => "x", "extra" => 1}, schema)
      assert failures(result) == [{"/extra", "additionalProperties"}]
    end

    test "additionalProperties: false with only listed keys present produces no violation" do
      schema = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}},
        "additionalProperties" => false
      }

      assert JsonSchema.validate(%{"a" => "x"}, schema) == []
    end

    test "additionalProperties absent entirely means no enforcement at all" do
      schema = %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}

      assert JsonSchema.validate(%{"a" => "x", "extra" => 1}, schema) == []
    end

    test "additionalProperties: true (or any non-false value) is not enforced -- only the literal false form is implemented" do
      schema = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}},
        "additionalProperties" => true
      }

      assert JsonSchema.validate(%{"a" => "x", "extra" => 1}, schema) == []

      subschema_form = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}},
        "additionalProperties" => %{"type" => "string"}
      }

      # The subschema form is not implemented -- a non-string "extra" value
      # here would fail under real draft-07 semantics; it must not here.
      assert JsonSchema.validate(%{"a" => "x", "extra" => 42}, subschema_form) == []
    end
  end

  # ---------------------------------------------------------------------
  # Unsupported keywords are "permitted and inert" (R-Co's documented
  # platform contract, section 1.1/1.2 of the design doc) -- not enforced,
  # not rejected as unknown, silently ignored.
  # ---------------------------------------------------------------------

  describe "validate/2 — dependentRequired (GH #2671)" do
    @dependent %{
      "type" => "object",
      "dependentRequired" => %{"a" => ["b", "c"], "b" => "not-a-list"}
    }

    test "a present key demands its dependents; an absent key demands nothing" do
      assert JsonSchema.validate(%{}, @dependent) == []
      assert JsonSchema.validate(%{"a" => 1, "b" => 2, "c" => 3}, @dependent) == []

      assert [%{constraint: "required"}, %{constraint: "required"}] =
               JsonSchema.validate(%{"a" => 1}, @dependent)
    end

    test "a malformed dependents value is inert" do
      assert JsonSchema.validate(%{"b" => 1}, @dependent) == []
      assert JsonSchema.validate(%{"a" => 1}, %{"dependentRequired" => "x"}) == []
    end
  end

  describe "validate/2 — unsupported keywords are permitted and inert" do
    test "$ref, pattern, format, allOf/anyOf/oneOf/not, patternProperties are all silently ignored" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "v" => %{
            "type" => "string",
            "$ref" => "#/definitions/something",
            "pattern" => "^[0-9]+$",
            "format" => "email",
            "allOf" => [%{"minLength" => 999}],
            "anyOf" => [%{"type" => "number"}],
            "oneOf" => [%{"enum" => ["never-matches"]}],
            "not" => %{"type" => "string"},
            "patternProperties" => %{"^x" => %{"type" => "number"}},
            "dependencies" => %{"v" => ["other"]},
            "title" => "irrelevant",
            "description" => "irrelevant"
          }
        }
      }

      # "not-a-number-string" satisfies "type": "string" and would VIOLATE
      # "pattern" (not all-digits) and "minLength" (from allOf, if enforced)
      # and "not" (which would reject any string) if any of those inert
      # keywords were actually enforced -- it is accepted, proving they are
      # genuinely inert, not silently enforced.
      assert JsonSchema.validate(%{"v" => "not-a-number-string"}, schema) == []
    end

    test "an unknown, made-up keyword name is also silently ignored" do
      schema = %{
        "type" => "object",
        "properties" => %{"v" => %{"type" => "string", "totallyMadeUp" => 42}}
      }

      assert JsonSchema.validate(%{"v" => "hi"}, schema) == []
    end
  end

  # ---------------------------------------------------------------------
  # RFC 6901 pointer construction, including ~0/~1 escaping
  # ---------------------------------------------------------------------

  describe "validate/2 — RFC 6901 field_path pointer construction" do
    test "the document root's own pointer renders as \"/\", not an empty string" do
      # A root-level "required" miss never happens via validate/2 itself
      # (Registry.validate_payload/3 owns the root-type-mismatch case
      # separately, per design doc section 4.2) -- but a root-level "type"
      # mismatch does exercise the render_pointer("") -> "/" path directly.
      schema = %{"type" => "string"}

      result = JsonSchema.validate(%{"not" => "a string"}, schema)
      assert failures(result) == [{"/", "type"}]
    end

    test "a field name containing '~' is escaped to '~0' in the pointer" do
      schema = %{"type" => "object", "required" => ["a~b"]}

      result = JsonSchema.validate(%{}, schema)
      assert failures(result) == [{"/a~0b", "required"}]
    end

    test "a field name containing '/' is escaped to '~1' in the pointer" do
      schema = %{"type" => "object", "required" => ["a/b"]}

      result = JsonSchema.validate(%{}, schema)
      assert failures(result) == [{"/a~1b", "required"}]
    end

    test "nested + indexed pointers compose correctly (properties then items)" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "items_list" => %{
            "type" => "array",
            "items" => %{"type" => "object", "required" => ["id"]}
          }
        }
      }

      result = JsonSchema.validate(%{"items_list" => [%{"id" => 1}, %{}]}, schema)
      assert failures(result) == [{"/items_list/1/id", "required"}]
    end
  end

  # ---------------------------------------------------------------------
  # Multiple simultaneous violations, all reported (ES-05: report EVERY
  # failure, not just the first -- matches R-Co's validateCollect).
  # ---------------------------------------------------------------------

  describe "validate/2 — reports every violation, not just the first" do
    test "a payload violating 3 independent constraints at once returns all 3, required always first" do
      schema = %{
        "type" => "object",
        "required" => ["missing_field"],
        "properties" => %{
          "n" => %{"minimum" => 10},
          "s" => %{"enum" => ["x", "y"]}
        }
      }

      result = JsonSchema.validate(%{"n" => 1, "s" => "z"}, schema)

      assert length(result) == 3

      # required_violations always runs before properties_violations within
      # a single level's object_violations (design doc section 4.4's fixed
      # check order: enum, numeric, string, object[required, properties,
      # additionalProperties], array) -- this ordering is structurally
      # guaranteed by the algorithm's control flow, not a map-iteration
      # accident, so it's safe to assert on directly. The relative order
      # between "n" and "s" below falls out of iterating a 2-entry Elixir
      # map (schema["properties"]) rather than a list, so it is compared as
      # a set instead of pinning a specific order between sibling
      # properties.
      assert hd(failures(result)) == {"/missing_field", "required"}

      assert MapSet.new(failures(result)) ==
               MapSet.new([
                 {"/missing_field", "required"},
                 {"/n", "minimum"},
                 {"/s", "enum"}
               ])
    end
  end
end
