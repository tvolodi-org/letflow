defmodule Letflow.Modules.Procurement do
  @moduledoc """
  Application module `procurement` (GH #3162, REQ-544 part 1; `docs/WMS/WMS_Procurement_Requirements_Draft.md`
  PR-01): the purchase request as a versioned document.

  Part 1 ships the scaffold and the request itself: the manifest, the document type
  `purchase_request` (registered by `on_install/3` through `Letflow.Documents.register_type/3`),
  validation with exact decimal totals (`Letflow.Modules.Procurement.PurchaseRequest`) and the
  create, submit and revise operations (`Letflow.Modules.Procurement.PurchaseRequests`). It has no
  router, no BPM handler, no pack, no entity type and no tenant table; the reference data (units,
  departments) stays in `catalog_items` and `org`. Part 2 adds the routes, the decisions and the
  approval permission.

  The two permissions are declared with their route policies (the routes arrive with part 2: the
  permission-matrix classification pre-approves a new module atom only when the owner's own route
  policies name it) and with no `role_grants`: in this slice only TENANT_ADMIN and PLATFORM_ADMIN
  hold them. Giving requesters write access is a widening that needs per-tenant grant snapshots.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Documents

  # Same values the document service tests register (REQ-542).
  @type_attrs %{
    key: "purchase_request",
    owner_module: "procurement",
    numbering_scope: :year,
    number_prefix: "PR",
    number_pad: 4,
    legal_entity_required: false,
    declared_fields: %{}
  }

  @impl true
  defmanifest(
    id: "procurement",
    version: "0.1.0",
    depends_on: ["org", "catalog_items"],
    pack: nil,
    permissions: [:ProcurementRequestWrite, :ProcurementRequestRead],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [
      {"POST", "/purchase-requests", :ProcurementRequestWrite},
      {"GET", "/purchase-requests/:id", :ProcurementRequestRead}
    ]
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    case Documents.register_type(prefix, @type_attrs, ctx) do
      {:ok, _type} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
