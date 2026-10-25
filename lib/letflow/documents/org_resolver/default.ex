defmodule Letflow.Documents.OrgResolver.Default do
  @moduledoc """
  The resolver used when no module declares one (REQ-542, GH #3164). It fails closed: a unit is
  active when the core scope tree (`Letflow.ScopeNodePaths`) holds it and it is not retired, and
  no unit has a legal entity, so a type that requires one can neither register nor take a draft.
  """

  @behaviour Letflow.Documents.OrgResolver

  alias Letflow.ScopeNodePaths

  @impl true
  def unit_exists?(prefix, org_unit_id) when is_binary(prefix) and is_binary(org_unit_id) do
    match?({:ok, %{node: %{retired_at: nil}}}, ScopeNodePaths.resolve(org_unit_id, prefix))
  end

  def unit_exists?(_prefix, _org_unit_id), do: false

  @impl true
  def legal_entity_of(_prefix, _org_unit_id), do: {:error, :no_legal_entity}
end
