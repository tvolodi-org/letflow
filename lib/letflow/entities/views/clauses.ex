defmodule Letflow.Entities.Views.Clauses do
  @moduledoc """
  Write-time validation of a saved view body (REQ-555, decision 0066 D2).

  `parse_body/2` checks the shape (pure, no I/O). `check/3` then validates the filter and sort with
  the rules `POST /entities/query` uses: `Types.parse_filter_op/1` and `Types.parse_sort_dir/1` for
  the closed vocabularies, then a dry `Compiler.compile/3` (nothing is run, the query is discarded)
  for the field, operator-type, arity and decimal rules, so there is no second copy of them. The
  query route answers 400 for an unknown operator or direction; a view write answers 422.

  Every failure is `{:error, {:unprocessable, code}}` with a fixed `code` (no submitted value is
  echoed), or `{:error, :not_found}` when the entity type does not resolve (INV-5). Request input
  is never turned into an atom (INV-7); the stored clauses stay string-keyed maps.
  """

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.Types

  @allowed_keys ~w(entity_type name columns filter sort)
  @max_columns 100
  @max_filter 50
  @max_sort 10

  @type shaped :: %{
          optional(:entity_type) => String.t(),
          name: String.t(),
          columns: [String.t()],
          filter: [map()],
          sort: [map()]
        }

  @doc """
  Shape-checks a request body. `mode` is `:create` (needs `entity_type`, `name`, `columns`) or
  `:update` (needs `name` and `columns`; `entity_type` is optional and checked by the caller
  against the stored one). Absent `filter` and `sort` are `[]`.
  """
  @spec parse_body(map(), :create | :update) ::
          {:ok, shaped()} | {:error, {:unprocessable, String.t()}}
  def parse_body(body, mode) when is_map(body) and mode in [:create, :update] do
    with :ok <- check_keys(body),
         {:ok, entity_type} <- entity_type(body, mode),
         {:ok, name} <- name(body),
         {:ok, columns} <- columns(body),
         {:ok, filter} <- filter(Map.get(body, "filter", [])),
         {:ok, sort} <- sort(Map.get(body, "sort", [])) do
      shaped = %{name: name, columns: columns, filter: filter, sort: sort}
      {:ok, if(entity_type, do: Map.put(shaped, :entity_type, entity_type), else: shaped)}
    end
  end

  @doc """
  Validates the filter and sort of `shaped` against `entity_type`, then every column against the
  type's declared fields plus the system columns.
  """
  @spec check(String.t(), String.t(), shaped()) ::
          :ok | {:error, :not_found} | {:error, {:unprocessable, String.t()}}
  def check(prefix, entity_type, %{filter: filter, sort: sort, columns: columns})
      when is_binary(prefix) and is_binary(entity_type) do
    with {:ok, filters} <- parse_ops(filter),
         {:ok, sorts} <- parse_dirs(sort),
         :ok <- dry_compile(prefix, entity_type, filters, sorts) do
      check_columns(prefix, entity_type, columns)
    end
  end

  # ── shape ──────────────────────────────────────────────────────────────────

  defp check_keys(body) do
    if Enum.all?(Map.keys(body), &(&1 in @allowed_keys)),
      do: :ok,
      else: invalid("unknown_key")
  end

  defp entity_type(body, mode) do
    case Map.get(body, "entity_type") do
      type when is_binary(type) and type != "" -> {:ok, type}
      nil when mode == :update -> {:ok, nil}
      _other -> invalid("entity_type_invalid")
    end
  end

  defp name(body) do
    case Map.get(body, "name") do
      name when is_binary(name) ->
        if String.length(name) in 1..120, do: {:ok, name}, else: invalid("name_invalid")

      _other ->
        invalid("name_invalid")
    end
  end

  defp columns(body) do
    case Map.get(body, "columns") do
      columns when is_list(columns) and columns != [] and length(columns) <= @max_columns ->
        if Enum.all?(columns, &(is_binary(&1) and &1 != "")) and
             length(Enum.uniq(columns)) == length(columns),
           do: {:ok, columns},
           else: invalid("columns_invalid")

      _other ->
        invalid("columns_invalid")
    end
  end

  defp filter(list) when is_list(list) and length(list) <= @max_filter do
    map_while(list, "filter_invalid", fn
      %{"field" => field, "op" => op} = clause when is_binary(field) and is_binary(op) ->
        # Map.has_key?/2, not Map.get/2: an omitted value must stay distinguishable from a JSON
        # null so the arity rule is not hidden (same discipline as the query route).
        base = %{"field" => field, "op" => op}

        {:ok,
         if(Map.has_key?(clause, "value"),
           do: Map.put(base, "value", clause["value"]),
           else: base
         )}

      _other ->
        :error
    end)
  end

  defp filter(_other), do: invalid("filter_invalid")

  defp sort(list) when is_list(list) and length(list) <= @max_sort do
    map_while(list, "sort_invalid", fn
      %{"field" => field, "dir" => dir} when is_binary(field) and is_binary(dir) ->
        {:ok, %{"field" => field, "dir" => dir}}

      _other ->
        :error
    end)
  end

  defp sort(_other), do: invalid("sort_invalid")

  defp map_while(list, code, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        :error -> {:halt, invalid(code)}
      end
    end)
    |> case do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      error -> error
    end
  end

  # ── operators, directions, clause rules ─────────────────────────────────────

  defp parse_ops(filter) do
    map_while(filter, "unknown_operator", fn clause ->
      case Types.parse_filter_op(clause["op"]) do
        {:ok, op} ->
          parsed = %{field: clause["field"], op: op}

          {:ok,
           if(Map.has_key?(clause, "value"),
             do: Map.put(parsed, :value, clause["value"]),
             else: parsed
           )}

        {:error, _unknown} ->
          :error
      end
    end)
  end

  defp parse_dirs(sort) do
    map_while(sort, "unknown_sort_dir", fn clause ->
      case Types.parse_sort_dir(clause["dir"]) do
        {:ok, dir} -> {:ok, %{field: clause["field"], dir: dir}}
        {:error, _unknown} -> :error
      end
    end)
  end

  defp dry_compile(prefix, entity_type, filters, sorts) do
    request = %{entity_type: entity_type, filters: filters, sort: sorts, join: []}

    # scope-all: write-time validation only, no rows are read (the compiled query is discarded)
    case Compiler.compile(request, prefix, :all) do
      {:ok, _query} -> :ok
      {:error, :entity_type_not_found} -> {:error, :not_found}
      {:error, reason} -> invalid(compile_code(reason))
    end
  end

  defp compile_code({:field_not_allowed, _field}), do: "field_not_allowed"
  defp compile_code({:value_arity_mismatch, _op}), do: "value_arity_mismatch"
  defp compile_code({:invalid_in_value, _field}), do: "invalid_in_value"
  defp compile_code({:invalid_decimal_value, _field}), do: "invalid_decimal_value"
  defp compile_code({:operator_not_valid_for_type, _op, _type}), do: "operator_not_valid_for_type"
  defp compile_code(_other), do: "view_invalid"

  # ── columns ────────────────────────────────────────────────────────────────

  defp check_columns(prefix, entity_type, columns) do
    case Definitions.get_active_definition_by_name(entity_type, prefix) do
      {:ok, definition} ->
        declared =
          definition.definition_json
          |> Map.get("fields", [])
          |> Enum.flat_map(fn
            %{"name" => name} when is_binary(name) -> [name]
            _other -> []
          end)
          |> MapSet.new()
          |> MapSet.union(MapSet.new(Map.keys(Allowlist.typed_columns())))

        if Enum.all?(columns, &MapSet.member?(declared, &1)),
          do: :ok,
          else: invalid("column_not_on_type")

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp invalid(code), do: {:error, {:unprocessable, code}}
end
