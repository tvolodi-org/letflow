defmodule Letflow.Modules.MesCore do
  @moduledoc """
  Module `mes_core` (T-1841, MES phase 1 task M1; plan `docs/design/mes/13-phase1-plan.md` sections 3, 9
  and 11; decision draft 0087): the empty shell of the manufacturing execution module.

  It declares the id, the version, the dependencies (`catalog_items`, `locations`, `org`, `stock`: the
  item, lot, location, org and stock masters that M2..M4 build on) and an empty pack. It has no
  permissions, no role grants, no routes, no handlers, no ledger and no `on_install`. No tenant gets it
  installed by this change; installing it is a tenant admin's own act, as for every module.

  Every later MES task (M2..M11) extends this module and bumps `:version` (pack content is not part of
  the manifest hash, plan section 10).
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "mes_core",
    version: "0.1.0",
    depends_on: ["catalog_items", "locations", "org", "stock"],
    pack: "modules/mes_core/pack.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: []
  )
end
