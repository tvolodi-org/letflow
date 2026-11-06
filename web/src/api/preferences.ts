/** (T-1431 adds the typed `ui.layout` key below; the server sanitizes it, see `Letflow.UserPreferences.sanitize_layout/1`.)
 *  Preferences API — `GET/PUT /api/v1/me/preferences` (T-1389). GET answers `{ preferences, effective,
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

export const UI_LAYOUT_KEY = 'ui.layout' as const

export interface UiLayout {
  v: 1
  shell: { sidenav: { collapsed?: boolean; w?: number } }
  screens: Record<
    string,
    {
      panes?: Record<string, (number | null)[]>
      collapsed?: Record<string, number[]>
      cols?: Record<string, Record<string, number>>
    }
  >
}

export function emptyUiLayout(): UiLayout {
  return { v: 1, shell: { sidenav: {} }, screens: {} }
}

/** Tolerant parse of the stored value: anything that is not a JSON object string gives the empty layout. */
export function parseUiLayout(raw: unknown): UiLayout {
  if (typeof raw !== 'string') return emptyUiLayout()
  try {
    const doc: unknown = JSON.parse(raw)
    if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return emptyUiLayout()
    const d = doc as Partial<UiLayout>
    return {
      v: 1,
      shell: { sidenav: { ...(d.shell?.sidenav ?? {}) } },
      screens: d.screens && typeof d.screens === 'object' ? d.screens : {},
    }
  } catch {
    return emptyUiLayout()
  }
}

export function serializeUiLayout(layout: UiLayout): string {
  return JSON.stringify(layout)
}

export const preferencesApi = {
  get: () => client.get<PreferencesAnswer>('/api/v1/me/preferences'),
  put: (preferences: Record<string, unknown>) => client.put<PreferencesAnswer>('/api/v1/me/preferences', { preferences }),
}
