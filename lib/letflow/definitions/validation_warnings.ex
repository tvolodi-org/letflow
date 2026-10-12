defmodule Letflow.Definitions.ValidationWarnings do
  @moduledoc """
  The single aggregator of advisory (never blocking) definition warnings
  (REQ-461, REQ-459 design section 1.4). Used by
  `Letflow.Definitions.validate_definition_graph/2` and by the solution-pack
  install result.

  Sources, concatenated in this fixed order (definitions in input order within
  each source), so the output is deterministic:

    1. `Letflow.Definitions.RoleBinding.warnings_for_definitions/2` -- the
       `unbound_task_role:` lines (one prefix-scoped read in total).
    2. `Letflow.Definitions.SemanticValidation.decision_key_warnings/2` -- the
       `decision_key_not_required:` lines (pure).

    3. `Letflow.Definitions.RoleBinding.single_member_warnings_for_definitions/2`
       -- the `distinct_from_single_member_role:` lines (REQ-464 check 4; one
       counts-only read, and none when no definition has a candidate pair).

  The warnings type stays `[String.t()]`.
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.RoleBinding
  alias Letflow.Definitions.SemanticValidation

  @doc """
  Warnings for `{definition_name, graph}` pairs. `opts` carries the tenant
  `:prefix` (needed by the role-binding read). `[]` when there is nothing to warn about.
  """
  @spec for_definitions([{String.t(), Graph.t()}], opts :: [prefix: String.t()]) :: [String.t()]
  def for_definitions(definitions, opts) do
    RoleBinding.warnings_for_definitions(definitions, opts) ++
      Enum.flat_map(definitions, fn {name, %Graph{} = graph} ->
        SemanticValidation.decision_key_warnings(graph, name)
      end) ++ RoleBinding.single_member_warnings_for_definitions(definitions, opts)
  end
end
