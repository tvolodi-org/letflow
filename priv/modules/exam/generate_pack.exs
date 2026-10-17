# Generates priv/modules/exam/pack.json from the sixteen entity-definition
# documents under priv/modules/exam/entity_definitions/: the ten AUTHORING types
# and (GH #2596) the six runtime/result types the exam manifest manages.
#
# REQ-328, provenance choice (a): pack.json IS committed, and this script is
# the only thing that may write it. See priv/packs/bilimbaga/README.md for why
# (a) was chosen over (b), and
# test/letflow/modules/exam/pack_install_test.exs's drift guard, which
# re-reads the source files and asserts each embedded definition_json is
# structurally equal to its source -- so a hand-edit of pack.json fails the
# suite.
#
# Run with:  MIX_ENV=test mix run --no-start priv/modules/exam/generate_pack.exs
#
# Pure content assembly. Reads no database and writes nothing but pack.json.

pack_dir = Path.join([File.cwd!(), "priv", "modules", "exam"])
definitions_dir = Path.join(pack_dir, "entity_definitions")

# Authoring order in the emitted array. This is NOT an install-ordering
# requirement -- install/3 writes :inactive metadata rows and emits no DDL, so
# it is order-insensitive. ACTIVATION order is what matters, and that is a
# separate concern documented in README.md and enforced by the install test's
# own @activation_order. This list is simply the dependency-sorted order, kept
# identical to the activation order so a reader of pack.json is not shown a
# second, conflicting ordering.
entity_types = ~w(
  category
  tag
  exam
  question
  exam_section
  answer_option
  question_tag
  exam_question_rule
  exam_question_rule_tag
  exam_manual_question
  session
  session_question
  session_answer
  session_event
  session_question_score
  certificate
)

# Mirrors solution_pack.ex's atomize_definition_json/1 whitelists, for the sole
# purpose of computing the real logical-shape digest the way
# Letflow.Entities.Definition.Shape.logical_shape_of/1 would. The install path
# does its own atomisation from the string-keyed definition_json this script
# emits verbatim; this atomisation never reaches pack.json.
top_level_keys = %{
  "name" => :name,
  "display_name" => :display_name,
  "description" => :description,
  "fields" => :fields,
  "indexes" => :indexes,
  "foreign_keys" => :foreign_keys,
  "constraints" => :constraints
}

# Mirrors Letflow.Definitions.SolutionPack's @field_keys, except the GH #2532
# range keys (min/max/non_negative): deliberately not mirrored -- exam types
# declare no bounds (lib/letflow/design/gh2532-field-min-max-non-negative.md §2.2).
field_keys = %{
  "name" => :name,
  "type" => :type,
  "required" => :required,
  "queried" => :queried,
  "enum_values" => :enum_values,
  "decimal_precision" => :decimal_precision,
  "decimal_scale" => :decimal_scale,
  "decimal_strict" => :decimal_strict,
  "default" => :default,
  "locales" => :locales,
  "search_strategy" => :search_strategy
}

field_types = %{
  "string" => :string,
  "integer" => :integer,
  "decimal" => :decimal,
  "boolean" => :boolean,
  "date" => :date,
  "datetime" => :datetime,
  "enum" => :enum,
  "json" => :json,
  "localized_text" => :localized_text
}

search_strategies = %{"plain" => :plain, "fulltext" => :fulltext}
index_keys = %{"name" => :name, "fields" => :fields, "unique" => :unique}

fk_keys = %{
  "name" => :name,
  "field" => :field,
  "references_entity" => :references_entity,
  "references_field" => :references_field
}

constraint_keys = %{"name" => :name, "type" => :type, "fields" => :fields}

translate = fn raw, whitelist ->
  Map.new(raw, fn {k, v} -> {Map.fetch!(whitelist, k), v} end)
end

atomize = fn raw ->
  top = translate.(raw, top_level_keys)

  top =
    case Map.fetch(top, :fields) do
      {:ok, fields} ->
        Map.put(
          top,
          :fields,
          Enum.map(fields, fn f ->
            f = translate.(f, field_keys)
            f = Map.update!(f, :type, &Map.fetch!(field_types, &1))

            case Map.fetch(f, :search_strategy) do
              {:ok, s} -> Map.put(f, :search_strategy, Map.fetch!(search_strategies, s))
              :error -> f
            end
          end)
        )

      :error ->
        top
    end

  top =
    case Map.fetch(top, :indexes) do
      {:ok, ix} -> Map.put(top, :indexes, Enum.map(ix, &translate.(&1, index_keys)))
      :error -> top
    end

  top =
    case Map.fetch(top, :foreign_keys) do
      {:ok, fks} -> Map.put(top, :foreign_keys, Enum.map(fks, &translate.(&1, fk_keys)))
      :error -> top
    end

  case Map.fetch(top, :constraints) do
    {:ok, cs} ->
      Map.put(
        top,
        :constraints,
        Enum.map(cs, fn c ->
          c = translate.(c, constraint_keys)

          case Map.fetch(c, :type) do
            {:ok, "unique"} -> Map.put(c, :type, :unique)
            :error -> c
          end
        end)
      )

    :error ->
      top
  end
end

packed =
  Enum.map(entity_types, fn entity_type ->
    path = Path.join(definitions_dir, "#{entity_type}.json")
    raw = path |> File.read!() |> Jason.decode!()

    atomised = atomize.(raw)
    :ok = Letflow.Entities.Definition.Validator.validate(atomised)

    logical_shape_version =
      atomised
      |> Letflow.Entities.Definition.Shape.logical_shape_of()
      |> Base.encode16(case: :lower)

    # A stable, content-derived id in UUID text shape (a raw SHA-256 prefix, not
    # a real RFC-4122 UUID -- install's fetch_string/2 only requires a
    # non-empty string), so regenerating this file
    # from unchanged sources produces byte-identical output. install/3 treats
    # entity_definition_id as source provenance only -- it never persists it as
    # the new row's id (create_definition/2 generates that) -- so it need only
    # be a stable string. Derived from the pack id plus the entity type name so
    # two packs never collide.
    entity_definition_id =
      :crypto.hash(:sha256, "bilimbaga-question-bank:" <> entity_type)
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)
      |> then(fn h ->
        Enum.join(
          [
            binary_part(h, 0, 8),
            binary_part(h, 8, 4),
            binary_part(h, 12, 4),
            binary_part(h, 16, 4),
            binary_part(h, 20, 12)
          ],
          "-"
        )
      end)

    %{
      "entity_definition_id" => entity_definition_id,
      "name" => Map.fetch!(raw, "name"),
      "display_name" => Map.fetch!(raw, "display_name"),
      "logical_shape_version" => logical_shape_version,
      # Verbatim, unmodified bytes-equivalent of the source document. Never
      # hand-copied -- this is the decoded source object re-encoded.
      "definition_json" => raw
    }
  end)

document = %{
  "pack_id" => "bilimbaga-question-bank",
  "version" => "1.0.0",
  "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
  # Carried for symmetry with export/3's output, which emits it.
  # parse_document/1 never reads this key -- a document omitting it still
  # parses. Fixed, not DateTime.utc_now/0, so regeneration from unchanged
  # sources is byte-identical and a spurious diff never appears.
  "exported_at" => "2026-09-13T00:00:00Z",
  # Process definitions are the next P2 deliverable, not this pack's.
  "definitions" => [],
  "variable_schemas" => [],
  # MUST stay []. decision 0027 makes a non-empty array permanently rejected by
  # check_unsupported_sections/1 with {:error, :unsupported_pack_section}.
  "service_catalog_entries" => [],
  "entity_definitions" => packed,
  # READ-ONLY ADVISORY. These are the source system's own role names
  # (008_categories_tags.up.sql's role_permissions INSERTs); none is one of
  # Letflow.Api.Authorization.roles()'s five platform roles, so every
  # role_mapping_checklist entry reports bound: false. That is today's correct
  # behaviour -- see README.md. Do NOT rename these to platform role names.
  "manifest" => %{
    "required_roles" => ["super_admin", "examiner", "department_admin"]
  }
}

output = Path.join(pack_dir, "pack.json")
File.write!(output, Jason.encode!(document, pretty: true) <> "\n")

IO.puts("wrote #{output} (#{length(packed)} entity definitions)")
