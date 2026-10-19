defmodule Letflow.Modules.CatalogItems do
  @moduledoc """
  Foundation module `catalog_items` (GH #2663 / REQ-474, WMS foundation slice 0; decisions 0050
  D1, 0052, 0054 option A, 0057 D1): the shared item and unit-of-measure masters. The manifest
  id is `catalog_items` because `catalog` collides with `Letflow.Modules.Catalog`.

  Two entity types, shipped by the pack `priv/modules/catalog_items/pack.json` (generated from
  `priv/modules/catalog_items/entity_definitions/` by
  `priv/modules/catalog_items/generate_pack.exs`):

    * `catalog_uom`: a unit of measure, unique `code`;
    * `catalog_item`: an item, unique `code`, with a `base_uom_id` (the record id of a
      `catalog_uom`, a declarative string) and a `kind` enum (`material | service`).

  Both carry the nullable `external_ref_system` / `external_ref_id` import key (0057 D1) with a
  unique constraint over the pair.

  Both are declared in `manages_entity_types`, so after install the generic entity routes answer
  403 `entity_type_managed`. This skeleton ships no routes, no permissions, no role grants and
  no write functions; the read API is REQ-507. The unit scale and conversion factors are
  REQ-504 (#2660), not here. References between the types are declarative strings (0050 D3.6),
  no foreign keys.

  `on_install/3` activates and promotes the two packed definitions inside the install
  transaction (decision 0052 D2) through `Letflow.Modules.EntityActivation`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.EntityActivation

  # Must stay equal to `manages_entity_types` in the manifest below (defmanifest takes literals).
  @types [
    "catalog_uom",
    "catalog_item"
  ]

  @impl true
  defmanifest(
    id: "catalog_items",
    version: "0.1.0",
    depends_on: [],
    pack: "modules/catalog_items/pack.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: [
      "catalog_uom",
      "catalog_item"
    ]
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @types)
  end
end
