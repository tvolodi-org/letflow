/** maintenanceCardAction — REQ-898 (GH 4802). The card action of the maintenance module: "Report a problem" opens
 *  the form of a new work request with the card set.
 *
 *  The assets module may not import the maintenance module (the module boundary of decision 0039 D3: the
 *  maintenance module depends on the assets one, not the other way round), so the module id, the permission atom
 *  and the route are named here as literals. The maintenance module owns the screens; the server stays the
 *  authority at the create. */
export const MAINTENANCE_MODULE_ID = 'maintenance'
/** The permission atom of reporting a problem (`Letflow.Modules.Maintenance.Access`). */
export const MAINTENANCE_REQUEST_CREATE = 'MaintenanceRequestCreate'

/** The form of a new work request with the card set. */
export const maintenanceNewRequestHref = (cardId: string): string =>
  `/admin/maintenance/requests/new?card=${encodeURIComponent(cardId)}`
