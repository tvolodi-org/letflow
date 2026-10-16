defmodule Letflow.Entities.FieldPolicy do
  @moduledoc """
  The one rule for "which fields are restricted for this caller" (GH #2697).

  A field is restricted for a principal when an `entity_field_restrictions`
  row exists for it and the principal's user holds no `user_entity_grants` row
  for that field; roles play no part. The rule itself lives in
  `Letflow.Entities.Query.FieldGrants.load_restrictions/3` (REQ-231), and
  `restriction_set/2` is the single entry point to it.

  Two faces share the same loaded sets, so a field refused in a request is
  also redacted in a response:

    * request side: `check_request/4` walks a query request with
      `Letflow.Entities.Query.RequestGuard` and refuses any restricted field;
    * response side: `redact/3` (loads the set) and `redact_with_sets/3`
      (pure, given sets) apply the `:__field_redacted__` sentinel. The router
      shapes whole pages with `FieldGrants.redact_page/2` /
      `redact_joined_page/2` from the sets `check_request/4` returned.

  `principal` is built only from the auth context and the request's resolved
  tenant prefix, never from a request body (INV-1).
  """

  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Query.RequestGuard

  @type principal :: %{user_id: String.t(), prefix: String.t()}
  @type restriction_sets :: RequestGuard.restriction_sets()

  @doc "The restriction set of `entity_type` for `principal`."
  @spec restriction_set(principal(), String.t()) ::
          {:ok, MapSet.t(String.t())} | {:error, :invalid_schema_name}
  def restriction_set(%{user_id: user_id, prefix: prefix}, entity_type)
      when is_binary(entity_type),
      do: FieldGrants.load_restrictions(user_id, entity_type, prefix)

  @doc """
  One `restriction_set/2` per distinct entity type, keyed by entity type name.
  Any loader error propagates (never treated as "no restrictions").
  """
  @spec load_sets(principal(), [String.t()]) ::
          {:ok, restriction_sets()} | {:error, :invalid_schema_name}
  def load_sets(principal, entity_types) when is_list(entity_types) do
    entity_types
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn entity_type, {:ok, acc} ->
      case restriction_set(principal, entity_type) do
        {:ok, set} -> {:cont, {:ok, Map.put(acc, entity_type, set)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Refuses a request that names a restricted field in any walked position
  (filter, sort, group_by, aggregate measure, join `on`).

  `opts.exempt?` is REQUIRED (no default). With `exempt?: true` the restricted
  references are returned in `exempted` instead of refused; only the export
  route passes it, and only after the unredacted-export permission check.
  """
  @spec check_request(
          principal(),
          RequestGuard.request_kind(),
          map(),
          %{required(:exempt?) => boolean()}
        ) :: {:ok, RequestGuard.guard_ok()} | {:error, RequestGuard.guard_error()}
  def check_request(%{prefix: prefix} = principal, kind, request, %{exempt?: exempt?})
      when is_boolean(exempt?) do
    # MUTANT M7: the request side loads sets for a user with no grants
    nogrant_principal = %{principal | user_id: Ecto.UUID.generate()}

    with {:ok, refs} <- RequestGuard.field_refs(request, kind, prefix),
         {:ok, sets} <-
           load_sets(nogrant_principal, RequestGuard.restriction_entity_types(refs, request)) do
      case {RequestGuard.restricted_refs(refs, sets), exempt?} do
        {[], _} -> {:ok, %{sets: sets, exempted: []}}
        {restricted, true} -> {:ok, %{sets: sets, exempted: restricted}}
        {_restricted, false} -> {:error, :request_field_restricted}
      end
    end
  end

  @doc "Loads the set and redacts `field_values` (sentinel semantics unchanged)."
  @spec redact(principal(), String.t(), map()) :: {:ok, map()} | {:error, :invalid_schema_name}
  def redact(principal, entity_type, field_values) when is_map(field_values) do
    with {:ok, set} <- restriction_set(principal, entity_type) do
      {:ok, FieldGrants.redact_field_values(field_values, set)}
    end
  end

  @doc "Pure: redacts `field_values` with the already-loaded set for `entity_type`."
  @spec redact_with_sets(restriction_sets(), String.t(), map()) :: map()
  def redact_with_sets(sets, entity_type, field_values)
      when is_map(sets) and is_map(field_values) do
    FieldGrants.redact_field_values(field_values, Map.fetch!(sets, entity_type))
  end
end
