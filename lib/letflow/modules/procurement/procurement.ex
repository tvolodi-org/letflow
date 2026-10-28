defmodule Letflow.Modules.Procurement do
  @moduledoc """
  Application module `procurement` (GH #3162, REQ-544 part 1; `docs/WMS/WMS_Procurement_Requirements_Draft.md`
  PR-01): the purchase request as a versioned document.

  Part 1 ships the scaffold and the request itself: the manifest, the document type
  `purchase_request` (registered by `on_install/3` through `Letflow.Documents.register_type/3`),
  validation with exact decimal totals (`Letflow.Modules.Procurement.PurchaseRequest`) and the
  create, submit and revise operations (`Letflow.Modules.Procurement.PurchaseRequests`). Part 2
  adds the BPM operations (`PurchaseRequests.submit_for_bpm/3`, `Letflow.Modules.Procurement.Decisions`:
  approve, reject, return bound to one issued version), the decision table `procurement_decisions`,
  the router and the approval permission `ProcurementRequestDecide`. There is no pack and no entity
  type; the reference data (units, departments) stays in `catalog_items` and `org`. The module has
  no approval route, threshold, assignee or delegation: a process definition owns those.

  REQ-558 / GH #3188 part 1 adds the line events of an approved request (officer, supplier, PO or
  contract reference: `Letflow.Modules.Procurement.LineEvents`, tables `procurement_line_events` and
  `procurement_lines`) behind the permission `ProcurementLineRecord`. Its `role_grants` stay empty as
  well: the tenant role that holds it is TENANT_ADMIN (via core), PLATFORM_ADMIN only through the
  platform clause; a test asserts exactly that.

  The three permissions are declared with their route policies (the permission-matrix
  classification pre-approves a new module atom only when the owner's own route policies name it)
  and with no `role_grants`: in this slice only TENANT_ADMIN and PLATFORM_ADMIN hold them, so the
  requester/approver split rests on the permission gate and the self-decision check (a requester
  never decides their own request). Giving requesters write access or approvers the decide
  permission is a widening that needs per-tenant grant snapshots.
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
    permissions: [
      :ProcurementRequestWrite,
      :ProcurementRequestRead,
      :ProcurementRequestDecide,
      :ProcurementLineRecord
    ],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [
      {"POST", "/purchase-requests", :ProcurementRequestWrite},
      {"GET", "/purchase-requests/:id", :ProcurementRequestRead},
      {"POST", "/purchase-requests/:id/submit", :ProcurementRequestWrite},
      {"POST", "/purchase-requests/:id/revise", :ProcurementRequestWrite},
      {"POST", "/purchase-requests/:id/decisions", :ProcurementRequestDecide},
      {"GET", "/purchase-requests/:id/lines/:line_no", :ProcurementRequestRead},
      {"POST", "/purchase-requests/:id/lines/:line_no/officer", :ProcurementLineRecord},
      {"POST", "/purchase-requests/:id/lines/:line_no/supplier", :ProcurementLineRecord},
      {"POST", "/purchase-requests/:id/lines/:line_no/reference", :ProcurementLineRecord}
    ]
  )

  @impl true
  def router, do: Letflow.Modules.Procurement.Router

  @impl true
  def on_install(prefix, _settings, ctx) do
    case Documents.register_type(prefix, @type_attrs, ctx) do
      {:ok, _type} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
