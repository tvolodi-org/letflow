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
      atomised
      |> Letflow.Entities.Definition.Shape.logical_shape_of()
      |> Base.encode16(case: :lower)

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

# REQ-896: the life of a work order. maintenance_work is routed to the role label TENANT_ADMIN (the
# planner's inbox) and addressed to a user by create or assign; its form has one required text field.
# maintenance_close is completed by a TENANT_ADMIN. No distinct_from (four-eyes is not in slice 1).
#
# REQ-897 (version 1.1.0): each of the two tasks calls one write handler of module maintenance, so
# the order keeps what was done and who closed it. The order id is the instance variable
# `maintenance_order_id` (set when the instance starts); `work_done` is the text the technician
# typed in the task form, which the completion merges into the instance variables before the
# handler runs. Neither handler posts to a ledger, so no permission is needed to complete a task
# (only a posting line carries a run-time permission).
order_id_var = %{"var" => "maintenance_order_id"}

work_order_definition = %{
  "definition_id" => "00501000-0000-0040-0090-000000004804",
  "process_key" => "maintenance_work_order",
  "version" => "1.1.0",
  "graph" => %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "maintenance_work",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{
          "role" => "TENANT_ADMIN",
          "form_schema" => %{
            "type" => "object",
            "required" => ["work_done"],
            "properties" => %{
              "work_done" => %{"type" => "string", "minLength" => 1, "maxLength" => 2000}
            }
          },
          "module_writes" => [
            %{
              "module" => "maintenance",
              "handler" => "record_done",
              "args" => %{
                "order_id" => order_id_var,
                "work_done" => %{"var" => "work_done"}
              }
            }
          ]
        }
      },
      %{
        "id" => "maintenance_close",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{
          "role" => "TENANT_ADMIN",
          "module_writes" => [
            %{
              "module" => "maintenance",
              "handler" => "record_closed",
              "args" => %{"order_id" => order_id_var}
            }
          ]
        }
      },
      %{"id" => "end", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e1", "source" => "start", "target" => "maintenance_work"},
      %{"id" => "e2", "source" => "maintenance_work", "target" => "maintenance_close"},
      %{"id" => "e3", "source" => "maintenance_close", "target" => "end"}
    ]
  }
}

document = %{
  "pack_id" => "letflow-maintenance",
  "version" => "0.5.0",
  "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
  "exported_at" => "2026-11-20T00:00:00Z",
  "definitions" => [work_order_definition],
  "variable_schemas" => [],
  # MUST stay [] (decision 0027).
  "service_catalog_entries" => [],
  "entity_definitions" => packed,
  "manifest" => %{"required_roles" => []}
}

output = Path.join(pack_dir, "pack.json")
File.write!(output, Jason.encode!(document, pretty: true) <> "\n")
IO.puts("wrote #{output} (#{length(packed)} entity definitions)")
