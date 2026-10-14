defmodule Letflow.Entities.Record.Validator do
  @moduledoc """
  Validates one entity record's `field_values` payload against the
  JSON-Schema-shaped constraint set derived from its REQ-225
  `Letflow.Entities.Definition.t()` document (REQ-227). See
  `lib/letflow/design/req227-entity-record-payload-validation.md` for the
  full design this module implements.

  ## Reuses `Letflow.EventStore.Registry.JsonSchema` -- no second engine

  This module performs **no constraint-checking logic of its own**.
  `build_record_schema/1` only reshapes a REQ-225 definition's `fields` list
  into a plain, string-keyed JSON-Schema-shaped map (data reshaping, not
  evaluation); `validate_record_payload/2` then delegates the actual
  checking to the existing `Letflow.EventStore.Registry.JsonSchema.validate/2`
  (REQ-024), returning its violation list unchanged. See the design doc §5.1
  for why this cross-namespace reach is accepted as-is rather than extracting
  a shared top-level module: `JsonSchema` is already a pure, dependency-free
  leaf module with an existing cross-namespace caller
  (`Letflow.Definitions.JsonSchemaShape`), and extraction now would touch
  `Letflow.EventStore.Registry`'s own call site and tests for zero behavior
  change.

  ## Scope boundary

  This module validates only a record's `field_values` map against its
  definition's derived schema (the **inner** check). It does not validate
  the outer event envelope (`Letflow.EventStore.Registry.validate_payload/3`,
  a separate, pre-existing concern) and defines no route, controller, event
  registration, or command function -- all REQ-228's job (design doc §3/§7).

  ## Malformed-shape precondition (design §4 preamble)

  `definition` is expected to have already passed
  `Letflow.Entities.Definition.Validator.validate/1` (`:ok`) -- same divide
  of responsibility `Letflow.Entities.Definition.Shape` already documents.
  `build_record_schema/1` does not re-run those structural rules.
  """

  alias Letflow.Entities.Definition
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.EventStore.Registry.ValidationFailure

  @typedoc "A record's already-decoded field name -> value map."
  @type field_values :: %{required(String.t()) => term()}

  @typedoc "A plain, string-keyed, JSON-Schema-shaped map -- `JsonSchema.validate/2`'s `schema` argument shape."
  @type record_schema :: map()

  @typedoc "The complete list of violations found. Empty means the payload conforms."
  @type violations :: [ValidationFailure.t()]

  @doc """
  Translates `definition`'s `fields` list into a JSON-Schema-shaped
  constraint map: `"type" => "object"`, one per-field subschema under
  `"properties"`, the `"required"` list (fields with `required: true`), and
  `"additionalProperties" => false`. See the design doc §4.1 for the full
  per-field-type keyword mapping. `:integer`/`:decimal` subschemas carry
  `"minimum"`/`"maximum"` when the field declares `min`/`max`/`non_negative`
  (GH #2532, `lib/letflow/design/gh2532-field-min-max-non-negative.md` §4;
  the effective minimum is `max(min, 0)` under `non_negative: true`), and are
  exactly `%{"type" => "integer"}`/`%{"type" => "number"}` when it declares
  none. A non-number stored bound is ignored, never a crash (INV-8).
  `"maxLength"` is still never emitted -- `field_def()` carries no length
  attribute to translate.
  """
  @spec build_record_schema(definition :: Definition.t()) :: record_schema()
  def build_record_schema(definition) do
    fields = Map.get(definition, :fields, [])

    %{
      "type" => "object",
      "properties" => Map.new(fields, &{Map.get(&1, :name), field_subschema(&1)}),
      "required" =>
        fields |> Enum.filter(&Map.get(&1, :required)) |> Enum.map(&Map.get(&1, :name)),
      "additionalProperties" => false
    }
  end

  @doc """
  Builds `definition`'s derived schema via `build_record_schema/1`, then
  validates `field_values` against it via
  `Letflow.EventStore.Registry.JsonSchema.validate/2`, returning its
  complete violation list unchanged (every violation, not just the first --
  inherited from `JsonSchema.validate/2` itself).
  """
  @spec validate_record_payload(definition :: Definition.t(), field_values :: field_values()) ::
          violations()
  def validate_record_payload(definition, field_values) do
    schema = build_record_schema(definition)
    JsonSchema.validate(field_values, schema)
  end

  # GH #2532: the effective JSON Schema "minimum" for a field's `min` and
  # `non_negative`. Only a literal `true` turns `non_negative` on; a
  # non-number `min` (a corrupt stored definition) is ignored, never
  # compared or computed with (INV-8). Tested through `build_record_schema/1`.
  @spec effective_minimum(min :: term(), non_negative :: term()) :: number() | nil
  defp effective_minimum(min, true) when is_number(min), do: max(min, 0)
  defp effective_minimum(min, _non_negative) when is_number(min), do: min
  defp effective_minimum(_min, true), do: 0
  defp effective_minimum(_min, _non_negative), do: nil

  # --- per-field type mapping (design §4.1) -----------------------------------

  defp field_subschema(%{type: :string}), do: %{"type" => "string"}
  defp field_subschema(%{type: :integer} = field), do: put_range(%{"type" => "integer"}, field)
  defp field_subschema(%{type: :decimal} = field), do: put_range(%{"type" => "number"}, field)
  defp field_subschema(%{type: :boolean}), do: %{"type" => "boolean"}
  defp field_subschema(%{type: :date}), do: %{"type" => "string"}
  defp field_subschema(%{type: :datetime}), do: %{"type" => "string"}

  defp field_subschema(%{type: :enum, enum_values: enum_values}),
    do: %{"type" => "string", "enum" => enum_values}

  defp field_subschema(%{type: :json}), do: %{}

  # ISS-0617 / GH#1294 fix: `:localized_text` (REQ-301) was declarable,
  # DDL-supported (`Letflow.Entities.Definition.Ddl.localized_text_column_specs/1`),
  # and queryable, but had no clause here -- a definition with a
  # `:localized_text` field validated cleanly (Definition.Validator has no
  # opinion on record-payload shape) yet every record write raised
  # `FunctionClauseError` out of this function, an INV-8-shaped
  # crash-on-realistic-input defect in the same family as the
  # `properties_violations/3` fix at `JsonSchema` ISS-0088/GH#305 (see that
  # module's comment): realistic, schema-declared input reaching an
  # unguarded clause set.
  #
  # Storage shape (`ddl.ex` `localized_text_column_specs/1`, which reads
  # `field_values["<name>"]["<locale>"]` via
  # `field_values->'<name>'->>'<locale>'`) requires the field's value to be
  # a JSON object keyed by locale code with string values -- hence
  # `"type" => "object"` with one string-typed property per declared
  # locale, not a flat scalar like the other seven types.
  #
  # `additionalProperties: false` is set here explicitly, not inherited:
  # the outer schema's own `additionalProperties: false` (`build_record_schema/1`)
  # only governs top-level field NAMES against `field_values`'s
  # `"properties"` map (see `JsonSchema.additional_properties_violations/2`,
  # which reads `schema["additionalProperties"]`/`schema["properties"]` at
  # whatever level it is called from) -- it does not cascade into a nested
  # object subschema. Without setting it again here, a payload could smuggle
  # an undeclared locale key (e.g. `"fr"` on a field declared with only
  # `["kk", "ru"]`) past validation with no rejection.
  #
  # Deliberately no `"required" => locales`: every per-locale generated
  # column `localized_text_column_specs/1` emits is `nullable: true` (ddl.ex
  # `localized_text_column_specs/1`'s `column_spec()`), i.e. the DDL layer
  # already treats a missing/absent locale as a legitimate, queryable state
  # (`NULL`), not an error condition -- forcing every declared locale to be
  # present on every write here would reject storage-legitimate partial
  # writes the DDL was deliberately built to allow (e.g. a record whose
  # `"ru"` translation is filled in first, `"kk"` added later). Declared,
  # present locale keys are still constrained to `"type" => "string"`, and
  # `additionalProperties: false` still rejects any undeclared locale key --
  # only per-locale *presence* is optional, not the value's type or the
  # locale-key set itself.
  defp field_subschema(%{type: :localized_text, locales: locales}) do
    %{
      "type" => "object",
      "properties" => Map.new(locales, &{&1, %{"type" => "string"}}),
      "additionalProperties" => false
    }
  end

  # GH #2532: adds "minimum"/"maximum" only for number bounds; with no range
  # keys the subschema is returned unchanged (byte-identical to pre-#2532).
  @spec put_range(map(), Definition.field_def()) :: map()
  defp put_range(subschema, field) do
    max = Map.get(field, :max)

    subschema
    |> then(fn acc ->
      case effective_minimum(Map.get(field, :min), Map.get(field, :non_negative)) do
        nil -> acc
        minimum -> Map.put(acc, "minimum", minimum)
      end
    end)
    |> then(fn acc -> if is_number(max), do: Map.put(acc, "maximum", max), else: acc end)
  end
end
