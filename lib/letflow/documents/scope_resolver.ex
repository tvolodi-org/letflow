defmodule Letflow.Documents.ScopeResolver do
  @moduledoc """
  The resource scope of a document (REQ-536 / GH #3106; decision 0051 D9, 0063 S7).

  `document_scope/1` is the `{:resolver, {Letflow.Documents.ScopeResolver, :document_scope}}`
  function the route walk (`Letflow.Api.RouteScope`) requires to be exported for the two hold
  routes. It is pure (no database): the document's `issuing_org_unit_id` is the scope node.
  The hold handlers apply the caller's scope inside their one locked query
  (`Letflow.Documents.Hold`), so they do not call it with a loaded row.
  """

  alias Letflow.Api.Scope
  alias Letflow.Documents.Document

  @doc """
  `{:node, id}` for a document whose `issuing_org_unit_id` is a non-empty string;
  `:unresolvable` for a document with no org unit (fail closed) and for anything else.
  """
  @spec document_scope(struct() | term()) :: Scope.resource_scope()
  def document_scope(%Document{issuing_org_unit_id: node_id})
      when is_binary(node_id) and node_id != "",
      do: {:node, node_id}

  def document_scope(_no_node_or_not_a_document), do: :unresolvable
end
