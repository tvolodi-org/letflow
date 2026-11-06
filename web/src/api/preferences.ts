/** T-1431 — `GET`/`PUT /api/v1/me/preferences` and the typed `ui.layout` key.
 *
 *  `ui.layout` is one JSON document per user (side nav state, per screen pane percentages, collapsed
 *  panes and column widths), sent as a STRING of at most 8192 bytes. The server sanitizes it
 *  (`Letflow.UserPreferences.sanitize_layout/1`, the twin of `LFPrefs.sanitize`) and returns the
 *  sanitized string, so the client parses tolerantly and does not sanitize again. */
import { client } from './client'

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

export interface PreferencesResponse {
  preferences: Record<string, unknown>
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
  get: () => client.get<PreferencesResponse>('/api/v1/me/preferences'),
  /** `null` as a value resets that key. */
  put: (preferences: Record<string, string | null>) =>
    client.put<PreferencesResponse>('/api/v1/me/preferences', { preferences }),
}
