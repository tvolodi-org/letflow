defmodule Letflow.Modules.Exam.DefinitionDocument do
  @moduledoc """
  The lossless translation of a stored, string-keyed `definition_json` into the atom-keyed
  document `Letflow.Entities.Definitions.create_definition/3` takes, over the keys the Validator
  knows. Shared by the exam rollouts (`Snapshot.Rollout`, `ParentRollout`), which derive a new
  definition version from the tenant's own ACTIVE definition rather than from the pack.

  A key or value the whitelists do not know fails closed (`:unsupported_definition_key`,
  `:unsupported_definition_value`, `:unsupported_definition_shape`).
  """

  # Whitelists for the lossless string-key -> atom-key conversion of a stored definition_json.
  @top_keys %{
    "name" => :name,
    "display_name" => :display_name,
    "description" => :description,
    "fields" => :fields,
    "indexes" => :indexes,
    "foreign_keys" => :foreign_keys,
    "constraints" => :constraints,
    "append_only" => :append_only,
    "writable_by_process" => :writable_by_process
  }
  @field_keys %{
    "name" => :name,
    "type" => :type,
    "required" => :required,
    "queried" => :queried,
    "enum_values" => :enum_values,
    "decimal_precision" => :decimal_precision,
    "decimal_scale" => :decimal_scale,
    "default" => :default,
    "locales" => :locales,
    "search_strategy" => :search_strategy,
    "min" => :min,
    "max" => :max,
    "non_negative" => :non_negative
  }
  @field_types %{
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
  @strategies %{"plain" => :plain, "fulltext" => :fulltext}
  @index_keys %{"name" => :name, "fields" => :fields, "unique" => :unique}
  @fk_keys %{
    "name" => :name,
    "field" => :field,
    "references_entity" => :references_entity,
    "references_field" => :references_field
  }
  @constraint_keys %{"name" => :name, "type" => :type, "fields" => :fields}

  @doc "Translates a stored definition_json into the atom-keyed create_definition document."
  @spec from_stored(definition_json :: map()) :: {:ok, map()} | {:error, atom()}
  def from_stored(definition_json) when is_map(definition_json) do
    with {:ok, top} <- translate(definition_json, @top_keys),
         {:ok, top} <- translate_list(top, :fields, &translate_field/1),
         {:ok, top} <- translate_list(top, :indexes, &translate(&1, @index_keys)),
         {:ok, top} <- translate_list(top, :foreign_keys, &translate(&1, @fk_keys)),
         {:ok, top} <- translate_list(top, :constraints, &translate_constraint/1) do
      {:ok, top}
    end
  end

  defp translate(raw, whitelist) when is_map(raw) do
    # A JSON null value is treated as an ABSENT key (the same rule the definitions HTTP route
    # applies, `Letflow.Routers.Entities.maybe_put_optional/4`): `create_definition/2` stores
    # `search_strategy: null` and similar for every field built from a definition map. A
    # genuinely unsupported key or non-nil value still fails closed.
    Enum.reduce_while(raw, {:ok, %{}}, fn
      {key, nil}, {:ok, acc} ->
        if Map.has_key?(whitelist, key),
          do: {:cont, {:ok, acc}},
          else: {:halt, {:error, :unsupported_definition_key}}

      {key, value}, {:ok, acc} ->
        case Map.fetch(whitelist, key) do
          {:ok, atom_key} -> {:cont, {:ok, Map.put(acc, atom_key, value)}}
          :error -> {:halt, {:error, :unsupported_definition_key}}
        end
    end)
  end

  defp translate(_not_a_map, _whitelist), do: {:error, :unsupported_definition_shape}

  defp translate_list(map, key, translator) do
    case Map.get(map, key) do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
          case translator.(entry) do
            {:ok, translated} -> {:cont, {:ok, [translated | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Map.put(map, key, Enum.reverse(reversed))}
          {:error, _reason} = error -> error
        end

      nil ->
        if key == :fields, do: {:error, :unsupported_definition_shape}, else: {:ok, map}

      _not_a_list ->
        {:error, :unsupported_definition_shape}
    end
  end

  defp translate_field(raw) do
    with {:ok, field} <- translate(raw, @field_keys),
         {:ok, field} <- atom_value(field, :type, @field_types),
         {:ok, field} <- optional_atom_value(field, :search_strategy, @strategies) do
      {:ok, field}
    end
  end

  defp translate_constraint(raw) do
    with {:ok, constraint} <- translate(raw, @constraint_keys) do
      atom_value(constraint, :type, %{"unique" => :unique})
    end
  end

  defp atom_value(map, key, whitelist) do
    case Map.fetch(whitelist, Map.get(map, key)) do
      {:ok, atom} -> {:ok, Map.put(map, key, atom)}
      :error -> {:error, :unsupported_definition_value}
    end
  end

  defp optional_atom_value(map, key, whitelist) do
    if Map.has_key?(map, key), do: atom_value(map, key, whitelist), else: {:ok, map}
  end
end
