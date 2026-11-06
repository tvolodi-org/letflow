/** Preferences API — `GET/PUT /api/v1/me/preferences` (T-1389). GET answers `{ preferences, effective,
 *  tenant_defaults }`; PUT takes `{ preferences: { key: value | null } }` and merges (`null` resets a key).
 *  No tenant id is sent: the route takes the tenant from the auth context (INV-10). */
import { client } from './client'

export const DOCUMENT_LAYOUT_KEY = 'ui.document_layout'
export const DOCUMENT_LAYOUT_DEFAULT_KEY = 'ui.document_layout_default'

export interface PreferencesAnswer {
  preferences: Record<string, unknown>
  effective: Record<string, unknown>
  tenant_defaults: Record<string, unknown>
}

export const preferencesApi = {
  get: () => client.get<PreferencesAnswer>('/api/v1/me/preferences'),
  put: (preferences: Record<string, unknown>) => client.put<PreferencesAnswer>('/api/v1/me/preferences', { preferences }),
}
