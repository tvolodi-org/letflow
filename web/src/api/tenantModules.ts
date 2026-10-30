/** REQ-630 — tenant module lifecycle API client (decision 0066 D8 slice 5).
 *
 * Wraps `POST /api/v1/tenant/modules/:module_id/uninstall|reactivate` (REQ-578).
 * The body is exactly `{rationale}`; the tenant comes from the token.
 */
import { client } from './client'

export interface TenantModuleTransitionResult {
  module_id: string
  status: string
}

const BASE = '/api/v1/tenant/modules'

function path(moduleId: string, action: 'uninstall' | 'reactivate'): string {
  return `${BASE}/${encodeURIComponent(moduleId)}/${action}`
}

export const tenantModulesApi = {
  uninstall: (moduleId: string, rationale: string) =>
    client.post<TenantModuleTransitionResult>(path(moduleId, 'uninstall'), { rationale }),
  reactivate: (moduleId: string, rationale: string) =>
    client.post<TenantModuleTransitionResult>(path(moduleId, 'reactivate'), { rationale }),
}
