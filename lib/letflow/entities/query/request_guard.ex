defmodule Letflow.Entities.Query.RequestGuard do
  @moduledoc """
  Pure request-side walker for restricted fields (GH #2697, INV-2).

  `field_refs/3` walks a whole query request (row or aggregate shape) and
  returns every field reference it contains, each tagged with the entity type
  whose restriction set governs it. `check/2` / `restricted_refs/2` compare
  those references with already-loaded restriction sets. Loading the sets and
  composing the two is `Letflow.Entities.FieldPolicy.check_request/4`'s job.

  ## Fail closed on unknown request keys

  The walker holds a closed registry of the request keys it knows how to
  walk, one per request kind. A request carrying ANY other key returns
  `{:error, :request_clause_unwalked}` before a reference is produced, so a
  clause added to a request builder without a matching walk is refused, never
  silently ignored.

  ## Entity-aware by construction

  A `field_ref` always names its governing `entity_type`; `restricted_refs/2`
  has no "default to the primary set" fallback and treats a reference whose
  entity type has no loaded set as restricted.

  The walker builds no SQL. The only I/O is the definition read behind
  `Compiler.join_relations/3` for a request with a `join` clause.
  """

  alias Letflow.Entities.Query.Compiler

  @type request_kind :: :row | :aggregate
  @type clause :: :filter | :sort | :group_by | :aggregate_measure | :join_on
  @type field_ref :: %{entity_type: String.t(), field: String.t(), clause: clause()}
  @type restriction_sets :: %{String.t() => MapSet.t(String.t())}
  @type guard_ok :: %{sets: restriction_sets(), exempted: [field_ref()]}
  @type guard_error ::
          :request_field_restricted
          | :request_clause_unwalked
          | :invalid_schema_name
          | Compiler.join_relations_error()
  @type join_relations_error :: Compiler.join_relations_error()

  # The closed registry: every key a request of each kind may carry.
  # test/letflow/entities/query_request_guard_test.exs compares these with the
  # request typespecs and the router builders' output.
  @registry %{
    row: [:entity_type, :filters, :sort, :join],
    aggregate: [:entity_type, :aggregates, :group_by, :filters, :join]
  }

  @doc "The registered request keys for `kind`."
  @spec registry_keys(request_kind()) :: [atom()]
  def registry_keys(kind) when kind in [:row, :aggregate], do: Map.fetch!(@registry, kind)

  @doc """
  Walks `request` and returns every field reference it contains.

  Elements are read by ATOM keys only (the router builds them that way); a
  string-keyed or otherwise malformed element fails closed as
  `{:error, :request_clause_unwalked}`.
  """
  @spec field_refs(map(), request_kind(), String.t()) ::
          {:ok, [field_ref()]} | {:error, :request_clause_unwalked} | join_relations_error()
  def field_refs(%{entity_type: entity_type} = request, kind, prefix)
      when kind in [:row, :aggregate] and is_binary(entity_type) and is_binary(prefix) do
    if Enum.all?(Map.keys(request), &(&1 in @registry[kind])) do
      with {:ok, filters} <- refs(request, :filters, entity_type, :filter),
           {:ok, sorts} <- refs(request, :sort, entity_type, :sort),
           {:ok, group_bys} <- refs(request, :group_by, entity_type, :group_by),
           {:ok, measures} <- measure_refs(request, entity_type),
           {:ok, join_ons} <- join_refs(request, entity_type, prefix) do
        {:ok, filters ++ sorts ++ group_bys ++ measures ++ join_ons}
      end
    else
      {:error, :request_clause_unwalked}
    end
  end

  def field_refs(_request, _kind, _prefix), do: {:error, :request_clause_unwalked}

  @doc """
  The distinct entity types whose restriction sets are needed: the primary,
  every reference's governing entity, and every join target (the response
  redaction reuses the same sets).
  """
  @spec restriction_entity_types([field_ref()], map()) :: [String.t()]
  def restriction_entity_types(refs, %{entity_type: primary} = request) do
    join_targets =
      request |> Map.get(:join, []) |> List.wrap() |> Enum.flat_map(&join_target/1)

    Enum.uniq([primary | Enum.map(refs, & &1.entity_type)] ++ join_targets)
  end

  @doc """
  The references that are restricted. A reference whose governing entity type
  has no loaded set counts as restricted (fail closed).
  """
  @spec restricted_refs([field_ref()], restriction_sets()) :: [field_ref()]
  def restricted_refs(refs, sets) do
    Enum.filter(refs, fn %{entity_type: entity_type, field: field} ->
      case Map.fetch(sets, entity_type) do
        {:ok, set} -> MapSet.member?(set, field)
        :error -> true
      end
    end)
  end

  @doc "`:ok` only if no reference is restricted (exact string membership)."
  @spec check([field_ref()], restriction_sets()) :: :ok | {:error, :request_field_restricted}
  def check(refs, sets) do
    case restricted_refs(refs, sets) do
      [] -> :ok
      [_ | _] -> {:error, :request_field_restricted}
    end
  end

  # -- walking ----------------------------------------------------------

  defp join_target(%{entity_type: entity_type}) when is_binary(entity_type), do: [entity_type]
  defp join_target(_), do: []

  defp refs(request, key, entity_type, clause) do
    case Map.get(request, key) do
      nil -> {:ok, []}
      list when is_list(list) -> element_refs(list, entity_type, clause)
      _other -> {:error, :request_clause_unwalked}
    end
  end

  # An aggregate `count` target carries no :field and contributes no ref.
  defp measure_refs(request, entity_type) do
    case Map.get(request, :aggregates) do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        present = Enum.filter(list, &(is_map(&1) and Map.has_key?(&1, :field)))

        if Enum.all?(list, &is_map/1) do
          element_refs(present, entity_type, :aggregate_measure)
        else
          {:error, :request_clause_unwalked}
        end

      _other ->
        {:error, :request_clause_unwalked}
    end
  end

  defp element_refs(list, entity_type, clause) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{field: field}, {:ok, acc} when is_binary(field) ->
        {:cont, {:ok, [%{entity_type: entity_type, field: field, clause: clause} | acc]}}

      _other, _acc ->
        {:halt, {:error, :request_clause_unwalked}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp join_refs(request, entity_type, prefix) do
    case Map.get(request, :join) do
      nil ->
        {:ok, []}

      [] ->
        {:ok, []}

      joins when is_list(joins) ->
        with {:ok, relations} <- Compiler.join_relations(joins, entity_type, prefix) do
          {:ok,
           for relation <- relations,
               %{owner_entity_type: owner, fk_field: fk_field} <- relation.hops,
               length(relation.hops) > 1 do # MUTANT M4: direct join fk ignored
             %{entity_type: owner, field: fk_field, clause: :join_on}
           end}
        end

      _other ->
        {:error, :request_clause_unwalked}
    end
  end
end
