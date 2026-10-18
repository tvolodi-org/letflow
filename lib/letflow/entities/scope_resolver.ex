defmodule Letflow.Entities.ScopeResolver do
  @moduledoc """
  The resource scope of an entity record (REQ-518 PR 2c-ii / GH #2535; design
  `lib/letflow/design/req518-compiler-scope-filter.md` 5.6, decision 0051 D6).

  `record_scope/1` is the `{:resolver, {Letflow.Entities.ScopeResolver, :record_scope}}` function
  the route walk (`Letflow.Api.RouteScope`) requires to be exported for the record write and
  attachment routes, and the ONE place that reads a record's scope value out of its
  `field_values` (`Letflow.Entities.ScopedWrites` uses it, so the extraction is never repeated).
  It is pure: no database, no node read. Membership in the caller's already computed allowed set
  is the decision, never a per-row node lookup.
  """

  alias Letflow.Api.Scope
  alias Letflow.Entities.ScopeDeclaration

  @doc """
  `:tenant_wide` for a `:tenant_wide` declaration; `{:node, value}` for a `{:column, field}`
  declaration whose `field_values[field]` is a non-empty string; `:unresolvable` for everything
  else (an undeclared type, a missing, null or non-string value, a malformed argument).
  """
  @spec record_scope(%{
          required(:declaration) => ScopeDeclaration.declaration(),
          optional(:field_values) => map()
        }) :: Scope.resource_scope()
  def record_scope(%{declaration: :tenant_wide}), do: :tenant_wide

  def record_scope(%{declaration: {:column, field}, field_values: field_values})
      when is_binary(field) and is_map(field_values) do
    case Map.get(field_values, field) do
      node_id when is_binary(node_id) and node_id != "" -> {:node, node_id}
      _missing_null_or_not_a_string -> :unresolvable
    end
  end

  def record_scope(_other), do: :unresolvable
end
