defmodule Letflow.Modules.Org do
  @moduledoc """
  Foundation module `org` (GH #2661 / REQ-473, WMS foundation slice 0; decisions 0050 D1, 0052,
  0054 option A, 0057 D1): the shared organisation masters.

  Four entity types, shipped by the pack `priv/modules/org/pack.json` (generated from
  `priv/modules/org/entity_definitions/` by `priv/modules/org/generate_pack.exs`):

    * `org_legal_entity`, `org_site`, `org_unit` (a tree through the `parent` id string): the
      masters, each with a unique `code` and the nullable `external_ref_system` /
      `external_ref_id` import key (0057 D1);
    * `org_unit_membership`: a Letflow user id (text) in an org unit, unique per pair.

  All four are declared in `manages_entity_types`, so after install the generic entity routes
  answer 403 `entity_type_managed`. This skeleton ships no routes, no permissions, no role
  grants and no write functions: the unit functions (create, move, retire) are REQ-495 and the
  read API is REQ-506. References between the types are declarative strings (0050 D3.6), no
  foreign keys.

  `on_install/3` activates and promotes the four packed definitions inside the install
  transaction (decision 0052 D2) through `Letflow.Modules.EntityActivation`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.EntityActivation

  @types [
    "org_legal_entity",
    "org_site",
    "org_unit",
    "org_unit_membership"
  ]

  @impl true
  defmanifest(
    id: "org",
    version: "0.1.0",
    depends_on: [],
    pack: "modules/org/pack.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: [
      "org_legal_entity",
      "org_site",
      "org_unit",
      "org_unit_membership"
    ]
  )

  @doc "The four entity types this module's pack defines and manages."
  @spec entity_types() :: [String.t()]
  def entity_types, do: @types

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @types)
  end
end
