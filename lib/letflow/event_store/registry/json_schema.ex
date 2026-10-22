defmodule Letflow.EventStore.Registry.JsonSchema do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Pure JSON Schema validator — no I/O, no `Repo` — implementing exactly the
  keyword subset `src/tools/json_schema.zig` specifies:
  `type`, `minimum`/`maximum`, `minLength`/`maxLength`, `enum`, `required`,
  `properties`, `items`, `additionalProperties` (only the literal `false`
  form — the subschema form is not implemented, matching R-Co exactly, and
  tuple-form `items` is not implemented either, also matching R-Co), plus one
  deliberate addition over R-Co, `dependentRequired` (GH #2671: a property map of
  name -> [names] that must be present whenever the name is; a non-map or non-list
  value is ignored like any malformed keyword).

  Every other keyword — explicitly including `$ref`, `allOf`/`anyOf`/`oneOf`/
  `not`, `patternProperties`, `pattern`, `format`, `dependencies`, `title`,
  `description` — is silently ignored. This is a deliberate, documented
  platform contract ("permitted and inert"), not an implementation gap: a
  schema using one of those keywords is accepted rather than spuriously
  rejected. See `lib/letflow/design/req024-event-type-registry.md` section
  1.1 for the full keyword table this module ports keyword-for-keyword, and
  `Letflow.EventStore.Registry`'s own moduledoc for why this project
  hand-rolls this validator instead of adopting `ex_json_schema` (or any
  other JSON Schema library).
  """

  alias Letflow.EventStore.Registry.ValidationFailure

  @doc """
  Validates `payload` (an already-decoded Elixir map) against `schema` (an
  already-decoded Elixir map). Returns the complete list of violations found
  — ES-05 requires reporting EVERY failure, not just the first, matching
  R-Co's collecting `validateCollect` (not its single-message `validate`
  sibling). An empty list means `payload` conforms.
  """
  @spec validate(payload :: map(), schema :: map()) :: [ValidationFailure.t()]
  def validate(payload, schema) when is_map(payload) and is_map(schema) do
    collect("", payload, schema)
  end

  # Recursive worker over (pointer, value, schema). A `type` mismatch at a
  # given level short-circuits every other keyword check at that same level
  # (avoiding a cascade of additional, misleading violations against a value
  # that already failed its basic type check) but does not stop sibling
  # subtrees from being checked, since each recursive call only ever returns
  # its own local violation list.
  defp collect(pointer, value, schema) do
    case type_violation(pointer, value, schema) do
      {:violation, violation} ->
        [violation]

      :ok ->
        enum_violations(pointer, value, schema) ++
          numeric_violations(pointer, value, schema) ++
          string_violations(pointer, value, schema) ++
          object_violations(pointer, value, schema) ++
          array_violations(pointer, value, schema)
    end
  end

  defp type_violation(pointer, value, schema) do
    case schema["type"] do
      nil ->
        :ok

      type when is_binary(type) ->
        type_check_result(pointer, value, matches_type?(value, type))

      types when is_list(types) ->
        type_check_result(pointer, value, Enum.any?(types, &matches_type?(value, &1)))

      _not_a_string_or_list ->
        # A malformed `type` keyword value is a schema well-formedness
        # concern (SPC-02), not something register_type/2 or this runtime
        # validator checks — see design doc section 1.3's scoping note.
        # Treated as inert here rather than raising.
        :ok
    end
  end

  defp type_check_result(_pointer, _value, true), do: :ok

  defp type_check_result(pointer, value, false),
    do: {:violation, violation(pointer, "type", value)}

  defp matches_type?(value, "string"), do: is_binary(value)
  defp matches_type?(value, "number"), do: is_number(value)
  defp matches_type?(value, "integer"), do: is_integer(value)
  defp matches_type?(value, "boolean"), do: is_boolean(value)
  defp matches_type?(value, "object"), do: is_map(value)
  defp matches_type?(value, "array"), do: is_list(value)
  defp matches_type?(value, "null"), do: is_nil(value)
  # An unrecognized type-name string is a schema well-formedness concern
  # (§1.1's own valid-value table), not something this runtime validator
  # enforces — treated permissively (never fails), consistent with this
  # module's general "unknown things are inert" stance.
  defp matches_type?(_value, _unrecognized_type_name), do: true

  defp enum_violations(pointer, value, schema) do
    case schema["enum"] do
      enum when is_list(enum) -> check(pointer, "enum", value, value not in enum)
      _not_a_list -> []
    end
  end

  defp numeric_violations(pointer, value, schema) when is_number(value) do
    check(pointer, "minimum", value, is_number(schema["minimum"]) and value < schema["minimum"]) ++
      check(pointer, "maximum", value, is_number(schema["maximum"]) and value > schema["maximum"])
  end

  defp numeric_violations(_pointer, _value, _schema), do: []

  defp string_violations(pointer, value, schema) when is_binary(value) do
    length = String.length(value)

    check(
      pointer,
      "minLength",
      value,
      is_integer(schema["minLength"]) and length < schema["minLength"]
    ) ++
      check(
        pointer,
        "maxLength",
        value,
        is_integer(schema["maxLength"]) and length > schema["maxLength"]
      )
  end

  defp string_violations(_pointer, _value, _schema), do: []

  defp object_violations(pointer, value, schema) when is_map(value) do
    required_violations(pointer, value, schema) ++
      dependent_required_violations(pointer, value, schema) ++
      properties_violations(pointer, value, schema) ++
      additional_properties_violations(pointer, value, schema)
  end

  defp object_violations(_pointer, _value, _schema), do: []

  defp required_violations(pointer, value, schema) do
    case schema["required"] do
      names when is_list(names) ->
        names
        |> Enum.reject(&Map.has_key?(value, &1))
        |> Enum.map(&violation(join_pointer(pointer, &1), "required", nil))

      _not_a_list ->
        []
    end
  end

  # GH #2671: for each present property with a list of dependents, every dependent not present
  # is a `required` violation at its own pointer.
  defp dependent_required_violations(pointer, value, schema) do
    case schema["dependentRequired"] do
      dependents when is_map(dependents) ->
        dependents
        |> Enum.filter(fn {name, names} -> Map.has_key?(value, name) and is_list(names) end)
        |> Enum.flat_map(fn {_name, names} -> names end)
        |> Enum.uniq()
        |> Enum.reject(&Map.has_key?(value, &1))
        |> Enum.map(&violation(join_pointer(pointer, &1), "required", nil))

      _not_a_map ->
        []
    end
  end

  # ISS-0088 / GH#305 fix: a subschema must itself be a map before recursing
  # into it -- mirrors array_violations/3's own `items_schema when is_map(...)`
  # guard below. `json_schema` is a jsonb column, which permits a non-map
  # value (array/string/number/boolean) nested at any depth, including inside
  # an otherwise well-formed `properties` object; recursing into one
  # unguarded reaches collect/3's clauses, all of which require a map, and
  # raises FunctionClauseError. A non-map subschema is treated as "no
  # constraint" for that key -- silently permissive, exactly like a non-map
  # `items` already is -- not a validation failure in its own right, since
  # this validator's job is reporting violations of well-formed schemas, not
  # policing the schema document itself (that is req109-variable-schemas.md
  # section 11.3 OQ-3's registration-time job, REQ-078/REQ-082, not this
  # function's).
  defp properties_violations(pointer, value, schema) do
    case schema["properties"] do
      properties when is_map(properties) ->
        properties
        |> Enum.filter(fn {name, subschema} ->
          Map.has_key?(value, name) and is_map(subschema)
        end)
        |> Enum.flat_map(fn {name, subschema} ->
          collect(join_pointer(pointer, name), value[name], subschema)
        end)

      _not_a_map ->
        []
    end
  end

  # Only the literal `false` form is enforced — the subschema form of
  # additionalProperties is not implemented, matching R-Co exactly (§1.1).
  defp additional_properties_violations(pointer, value, schema) do
    if schema["additionalProperties"] == false do
      allowed = schema |> Map.get("properties", %{}) |> Map.keys()

      value
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed))
      |> Enum.map(fn key ->
        violation(join_pointer(pointer, key), "additionalProperties", value[key])
      end)
    else
      []
    end
  end

  defp array_violations(pointer, value, schema) when is_list(value) do
    case schema["items"] do
      items_schema when is_map(items_schema) ->
        value
        |> Enum.with_index()
        |> Enum.flat_map(fn {element, index} ->
          collect(join_pointer(pointer, to_string(index)), element, items_schema)
        end)

      _not_a_map ->
        []
    end
  end

  defp array_violations(_pointer, _value, _schema), do: []

  defp check(pointer, constraint, actual, true), do: [violation(pointer, constraint, actual)]
  defp check(_pointer, _constraint, _actual, false), do: []

  defp violation(pointer, constraint, actual) do
    %ValidationFailure{
      field_path: render_pointer(pointer),
      constraint: constraint,
      actual: actual
    }
  end

  # The document root's own pointer is "" per RFC 6901 inside the recursion;
  # rendered as "/" at the point a violation is actually constructed, since
  # an empty `field_path` in a validation-failure report would read as
  # blank/missing rather than "the whole document".
  # Joined child pointers (required/properties/items/additionalProperties)
  # never hit this — join_pointer/2 always produces a non-empty string.
  defp render_pointer(""), do: "/"
  defp render_pointer(pointer), do: pointer

  # RFC 6901 section 3 escaping: `~` -> `~0` first, then `/` -> `~1`.
  defp join_pointer(pointer, segment) do
    pointer <> "/" <> escape_pointer_segment(to_string(segment))
  end

  defp escape_pointer_segment(segment) do
    segment
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end
end
