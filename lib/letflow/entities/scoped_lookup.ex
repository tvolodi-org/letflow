defmodule Letflow.Entities.ScopedLookup do
  @moduledoc """
  The by-id scope lookup of the record write and attachment routes (REQ-518 PR 2c-ii / GH #2535;
  design `lib/letflow/design/req518-compiler-scope-filter.md` 5.2, decision 0051 D5 and D7).

  `fetch_in_scope/5` answers ONE question for a scoped caller: is the record visible through the
  caller's allowed node set? It issues at most one predicate statement (`record_id = $1 AND
  <declared column> = ANY($ids)`), so an out-of-scope record and a nonexistent one are
  indistinguishable by answer, by statement count and by timing shape. `deleted` is deliberately
  NOT part of the predicate: `Letflow.Entities.Records` keeps its own already-deleted answers.

  | declaration (scoped caller)                        | statement | answer |
  |---|---|---|
  | `{:column, f}` on a per-type table with column `f` | one       | `{:ok, declaration}` or `:not_found` |
  | `:tenant_wide` (writes to masters are refused, R-6) | none      | `:not_found` |
  | `:undeclared`, `:latest` source, column absent, `:none` | none   | `:not_found` |

  The column name comes from a format-validated module declaration and is bound as a field
  reference; the id list is ONE bound text array (INV-7). The caller computes the set once through
  `Letflow.Api.ScopeGate` BEFORE calling here, so every case pays the same set read.

  ## Telemetry (decision 0051 D8: counted, not audited)

  Every refusal emits `[:letflow, :scope, :not_found]` with measurements `%{count: 1}` and metadata
  `%{policy: policy_key, kind: kind}` (closed atoms; no id, node, set or tenant). It is emitted
  identically for a nonexistent and an out-of-scope id, so it is a count of both, never an oracle.
  `emit_not_found/2` is the single owner of the event; `Letflow.Entities.ScopedWrites` and the
  router use it for their own refusals.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Repo

  @event [:letflow, :scope, :not_found]

  @type kind :: :by_id | :write_value | :import | :attachment_parent | :task

  @doc """
  The caller's visibility of `record_id` of `entity_type` under `scope` (see the moduledoc).
  `telemetry` is `{policy_key, kind}` for the refusal event. Scope `:all` is visible without a
  statement (the routers do not call this for an unscoped caller).
  """
  @spec fetch_in_scope(
          entity_type :: String.t(),
          record_id :: Ecto.UUID.t(),
          Types.scope_set(),
          prefix :: String.t(),
          telemetry :: {atom(), kind()}
        ) :: {:ok, ScopeDeclaration.declaration() | :unscoped} | :not_found
  def fetch_in_scope(_entity_type, _record_id, :all, _prefix, _telemetry), do: {:ok, :unscoped}

  def fetch_in_scope(entity_type, record_id, scope, prefix, {policy, kind}) do
    case lookup(entity_type, record_id, scope, prefix) do
      {:ok, _declaration} = visible ->
        visible

      :not_found ->
        emit_not_found(policy, kind)
        :not_found
    end
  end

  @doc """
  Whether EVERY id of `ids` (UUID strings, already cast) is a record of `entity_type` that is
  visible through `scope` (REQ-518 SEC ruling BUG-1: a reference payload is resolved through the
  scope of the REFERENCED type, so an out-of-scope and a nonexistent target are one answer).

  Exactly ONE bound statement for a non-empty list, whether the ids exist, are out of scope or
  do not exist (`record_id = ANY($ids)` counted against the distinct ids). By the target's
  declaration: `{:column, f}` -> the record's column must be in the set; `:tenant_wide` -> the
  record must exist (tenant-wide data is readable by a scoped caller); `:undeclared`, scope
  `:none`, a `:latest` source or an absent column -> `false` with no lookup statement. `deleted`
  is not in the predicate (as in `fetch_in_scope/5` and the database foreign key). Scope `:all`
  and an empty list are `true` with no statement.
  """
  @spec all_in_scope?(String.t(), [Ecto.UUID.t()], Types.scope_set(), String.t()) :: boolean()
  def all_in_scope?(_entity_type, [], _scope, _prefix), do: true
  def all_in_scope?(_entity_type, _ids, :all, _prefix), do: true
  def all_in_scope?(_entity_type, _ids, :none, _prefix), do: false

  def all_in_scope?(entity_type, ids, {:nodes, set}, prefix) when is_list(set) do
    distinct = Enum.uniq(ids)

    case ScopeDeclaration.for_type(entity_type, prefix) do
      :undeclared ->
        false

      :tenant_wide ->
        count_visible(entity_type, distinct, nil, prefix) == length(distinct)

      {:column, column} ->
        count_visible(entity_type, distinct, {column, set}, prefix) == length(distinct)
    end
  end

  defp count_visible(entity_type, ids, column_and_set, prefix) do
    with {:ok, source} <- Compiler.resolve_binding_source(entity_type, prefix),
         {:ok, base} <- visible_base(source, entity_type, column_and_set, prefix) do
      query =
        from(r in base,
          where: fragment("? = ANY(?)", r.record_id, type(^ids, {:array, Ecto.UUID})),
          select: count(r.record_id)
        )

      query |> column_predicate(column_and_set) |> Repo.one(prefix: prefix)
    else
      _no_statement -> -1
    end
  end

  defp visible_base({:per_type_table, table}, _entity_type, column_and_set, prefix) do
    if column_present?(column_and_set, prefix, table), do: {:ok, table}, else: :closed
  end

  defp visible_base(:latest, entity_type, nil, _prefix),
    do: {:ok, from(l in Latest, where: l.entity_type == ^entity_type)}

  defp visible_base(:latest, _entity_type, _column_and_set, _prefix), do: :closed

  defp column_present?(nil, _prefix, _table), do: true

  defp column_present?({column, _set}, prefix, table),
    do: Compiler.relation_column_exists?(prefix, table, column)

  defp column_predicate(query, nil), do: query

  defp column_predicate(query, {column, set}) do
    from(r in query,
      where: fragment("? = ANY(?)", literal(^column), type(^set, {:array, :string}))
    )
  end

  @doc "Emits `[:letflow, :scope, :not_found]` (see the moduledoc). Always returns `:ok`."
  @spec emit_not_found(policy :: atom(), kind()) :: :ok
  def emit_not_found(policy, kind) when is_atom(policy) and is_atom(kind),
    do: :telemetry.execute(@event, %{count: 1}, %{policy: policy, kind: kind})

  defp lookup(_entity_type, _record_id, :none, _prefix), do: :not_found

  defp lookup(entity_type, record_id, {:nodes, ids}, prefix) when is_list(ids) do
    case ScopeDeclaration.for_type(entity_type, prefix) do
      {:column, column} = declaration ->
        column_lookup(declaration, entity_type, column, record_id, ids, prefix)

      _tenant_wide_or_undeclared ->
        :not_found
    end
  end

  # The physical table comes from the compiler's one resolver; a type that is not on a per-type
  # table (`:latest`) fails closed (no JSON fallback).
  defp column_lookup(declaration, entity_type, column, record_id, ids, prefix) do
    with {:ok, record_uuid} <- Ecto.UUID.cast(record_id),
         {:ok, {:per_type_table, table_name}} <-
           Compiler.resolve_binding_source(entity_type, prefix),
         true <- Compiler.relation_column_exists?(prefix, table_name, column) do
      query =
        from(r in table_name,
          where:
            r.record_id == type(^record_uuid, Ecto.UUID) and
              fragment("? = ANY(?)", literal(^column), type(^ids, {:array, :string})),
          select: 1,
          limit: 1
        )

      case Repo.one(query, prefix: prefix) do
        1 -> {:ok, declaration}
        nil -> :not_found
      end
    else
      _not_visible -> :not_found
    end
  end
end
