defmodule Letflow.Entities.ScopeBearingField do
  @moduledoc """
  REQ-570 (GH #3248) -- whether a field of an entity type is scope-bearing: named by the
  `:entity_writes_scope_keys` seam (`Letflow.Entities.StepWrites.scope_column_field?/2`) or declared
  as the scope column of the type (`Letflow.Entities.ScopeDeclaration`). A thin read-only wrapper, so
  that callers outside `lib/letflow/entities/` need not name the step-write port holders (pinned by
  `Letflow.Engine.EntityPortBoundaryTest`).
  """

  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Entities.StepWrites

  @doc "True when `field` of the type `definition` describes is scope-bearing in `prefix`."
  @spec scope_bearing?(EntityDefinition.t(), String.t(), String.t()) :: boolean()
  def scope_bearing?(%EntityDefinition{name: type} = definition, field, prefix)
      when is_binary(field) and is_binary(prefix) do
    StepWrites.scope_column_field?(definition, field) or
      ScopeDeclaration.for_type(type, prefix) == {:column, field}
  end
end
