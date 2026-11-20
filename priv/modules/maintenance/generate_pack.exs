# Generates priv/modules/maintenance/pack.json from the entity-definition documents under
# priv/modules/maintenance/entity_definitions/ (REQ-893), as priv/modules/assets/generate_pack.exs does.
# pack.json is committed and this script is the only thing that may write it.
#
# Run with:  MIX_ENV=test mix run --no-start priv/modules/maintenance/generate_pack.exs
#
# Pure content assembly. Reads no database and writes nothing but pack.json.

pack_dir = Path.join([File.cwd!(), "priv", "modules", "maintenance"])
definitions_dir = Path.join(pack_dir, "entity_definitions")

# The request first: the order's foreign key needs its table.
entity_types = ~w(maintenance_work_request maintenance_work_order)

top_level_keys = %{
  "name" => :name,
  "display_name" => :display_name,
  "description" => :description,
  "fields" => :fields,
  "indexes" => :indexes,
  "foreign_keys" => :foreign_keys,
  "constraints" => :constraints
}

field_keys = %{
  "name" => :name,
  "type" => :type,
  "required" => :required,
  "queried" => :queried,
  "enum_values" => :enum_values,
  "default" => :default
}

field_types = %{
  "string" => :string,
  "integer" => :integer,
  "boolean" => :boolean,
  "date" => :date,
  "datetime" => :datetime,
  "enum" => :enum
}

index_keys = %{"name" => :name, "fields" => :fields, "unique" => :unique}

fk_keys = %{
  "name" => :name,
  "field" => :field,
  "references_entity" => :references_entity,
  "references_field" => :references_field
}

translate = fn raw, whitelist ->
  Map.new(raw, fn {k, v} -> {Map.fetch!(whitelist, k), v} end)
end

atomize = fn raw ->
  top = translate.(raw, top_level_keys)

  top =
    Map.update!(top, :fields, fn fields ->
      Enum.map(fields, fn f ->
        f |> then(&translate.(&1, field_keys)) |> Map.update!(:type, &Map.fetch!(field_types, &1))
      end)
    end)

  top =
    case Map.fetch(top, :indexes) do
      {:ok, ix} -> Map.put(top, :indexes, Enum.map(ix, &translate.(&1, index_keys)))
      :error -> top
    end

  case Map.fetch(top, :foreign_keys) do
    {:ok, fks} -> Map.put(top, :foreign_keys, Enum.map(fks, &translate.(&1, fk_keys)))
    :error -> top
  end
end

packed =
  Enum.map(entity_types, fn entity_type ->
    raw = definitions_dir |> Path.join("#{entity_type}.json") |> File.read!() |> Jason.decode!()
    atomised = atomize.(raw)
    :ok = Letflow.Entities.Definition.Validator.validate(atomised)

    logical_shape_version =
      atomised |> Letflow.Entities.Definition.Shape.logical_shape_of() |> Base.encode16(case: :lower)

    # Stable content-derived id in UUID text shape (source provenance only, never persisted as the row id).
    h =
      :crypto.hash(:sha256, "letflow-maintenance:" <> entity_type)
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)

    entity_definition_id =
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

    %{
      "entity_definition_id" => entity_definition_id,
      "name" => Map.fetch!(raw, "name"),
      "display_name" => Map.fetch!(raw, "display_name"),
      "logical_shape_version" => logical_shape_version,
      "definition_json" => raw
    }
  end)

document = %{
  "pack_id" => "letflow-maintenance",
  "version" => "0.2.0",
  "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
  "exported_at" => "2026-11-19T00:00:00Z",
  "definitions" => [],
  "variable_schemas" => [],
  # MUST stay [] (decision 0027).
  "service_catalog_entries" => [],
  "entity_definitions" => packed,
  "manifest" => %{"required_roles" => []}
}

output = Path.join(pack_dir, "pack.json")
File.write!(output, Jason.encode!(document, pretty: true) <> "\n")
IO.puts("wrote #{output} (#{length(packed)} entity definitions)")
