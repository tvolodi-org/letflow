defmodule Letflow.Documents.OrgResolver do
  @moduledoc """
  How the document service learns about org units and their legal entity (REQ-542, GH #3164,
  decision 0056 D1). The core knows no org structure; the module that does (REQ-544) declares
  one resolver in its manifest (`:document_org_resolver`, read by
  `Letflow.Modules.Catalog.document_org_resolver/0`). With none declared the fail-closed
  `Letflow.Documents.OrgResolver.Default` applies.

  Contract:

    * `unit_exists?/2` is true only for an active unit; an unknown, malformed or retired unit is
      false. A document already issued keeps its unit and legal entity regardless.
    * `legal_entity_of/2` answers `{:ok, entity_id}`, `{:error, :no_legal_entity}` or
      `{:error, :unit_not_found}`. A retired unit must NOT answer `:unit_not_found` (it still
      resolves, so a new draft derived from an issued document is not blocked, 0056 D1).
  """

  @callback unit_exists?(prefix :: String.t(), org_unit_id :: String.t()) :: boolean()
  @callback legal_entity_of(prefix :: String.t(), org_unit_id :: String.t()) ::
              {:ok, Ecto.UUID.t()} | {:error, :no_legal_entity | :unit_not_found}
end
