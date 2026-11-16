/** The body of a problem report (T-1950): exactly what `Capture.parse/1` of the server accepts. The dialog shows
 *  this object as JSON before sending and posts the same object (one snapshot, one builder). */
import type { ActionEntry, RequestEntry } from './capture'
import { maskText, normalizePath, oneLine } from './redact'
import type { ReportImage } from './images'

export type ReportContext = {
  route: string
  entity_ids?: Record<string, string>
  ui_language: 'en' | 'ru' | 'kk'
  browser: { user_agent: string; viewport: string; language?: string }
  actions: ActionEntry[]
  requests: RequestEntry[]
  crash?: { name: string; message: string }
}
export type ReportBody = {
  text: string
  consent: true
  context: ReportContext
  images?: { data_base64: string; content_type: string }[]
}

const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
const ID_VALUE = /^[A-Za-z0-9_-]{1,64}$/

/** SR-1: the ids of the entity on screen. A path segment that `normalizePath` turns into `:id` is the id; the
 *  segment before it names it (`documents/<uuid>` -> `documents`). Query keys `id` / `*_id` / `*Id` count too.
 *  Ids only: a value that is not one plain id token is skipped, never sent as text. */
export function extractEntityIds(pathname: string, search: string): Record<string, string> {
  const out: Record<string, string> = {}
  const put = (rawKey: string, value: string) => {
    const key = rawKey.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase().replace(/[^a-z0-9_]/g, '_').replace(/^[^a-z]+/, '').slice(0, 40)
    if (key && ID_VALUE.test(value) && !(key in out) && Object.keys(out).length < 8) out[key] = value
  }
  const segments = pathname.split('/')
  segments.forEach((seg, i) => {
    if (UUID.test(seg) || (seg.length <= 40 && (seg.match(/[0-9]/g) ?? []).length >= 3 && ID_VALUE.test(seg))) {
      put(segments[i - 1] || 'id', seg)
    }
  })
  new URLSearchParams(search).forEach((value, key) => {
    if (/^id$|_id$|[a-z]Id$/.test(key)) put(key, value)
  })
  return out
}

export function buildReportBody(
  text: string,
  snap: { actions: ActionEntry[]; requests: RequestEntry[] },
  opts: { uiLanguage: 'en' | 'ru' | 'kk'; crash?: Error | null; images?: ReportImage[] },
): ReportBody {
  const language = typeof navigator.language === 'string' && /^[A-Za-z-]{2,16}$/.test(navigator.language) ? navigator.language : undefined
  const context: ReportContext = {
    route: maskText(normalizePath(window.location.pathname)),
    ui_language: opts.uiLanguage,
    ...entityIdsField(),
    browser: {
      user_agent: oneLine(navigator.userAgent).slice(0, 300),
      viewport: `${window.innerWidth}x${window.innerHeight}`,
      ...(language ? { language } : {}),
    },
    actions: snap.actions,
    requests: snap.requests,
  }
  if (opts.crash) {
    context.crash = {
      name: maskText(oneLine(opts.crash.name)).slice(0, 80),
      message: maskText(oneLine(opts.crash.message)).slice(0, 300),
    }
  }
  const body: ReportBody = { text: maskText(text.trim()), consent: true, context }
  if (opts.images && opts.images.length > 0) {
    body.images = opts.images.map((img) => ({ data_base64: img.dataBase64, content_type: img.contentType }))
  }
  return body
}

function entityIdsField(): { entity_ids?: Record<string, string> } {
  const ids = extractEntityIds(window.location.pathname, window.location.search)
  return Object.keys(ids).length > 0 ? { entity_ids: ids } : {}
}
