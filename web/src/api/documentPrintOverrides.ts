/** REQ-614 — print-template override API client (decision 0068 D8 S4).
 *
 * Wraps the five `/api/v1/documents/print-overrides` routes of REQ-579
 * (`lib/letflow/routers/documents.ex`). No request carries a tenant id: the
 * tenant comes from the token. The list reply is `{overrides: [meta]}` and has
 * no layout; get, save (201) and activate/retire return meta plus `layout`.
 */
import { client } from './client'

export type PrintOverrideLocale = 'ru' | 'kk' | 'default'

export const PRINT_OVERRIDE_LOCALES: readonly PrintOverrideLocale[] = ['ru', 'kk', 'default']

export interface PrintOverrideMeta {
  id: string
  type_key: string
  locale: string
  version_no: number
  status: 'draft' | 'active' | 'retired' | string
  layout_hash?: string | null
  layout_schema_version?: number | null
  created_by?: string | null
  activated_by?: string | null
  activated_at?: string | null
  retired_at?: string | null
  reason_code?: string | null
  inserted_at?: string | null
  updated_at?: string | null
}

export interface PrintOverride extends PrintOverrideMeta {
  layout: unknown
}

export interface PrintOverrideFilters {
  type_key?: string
  locale?: string
}

export interface PrintOverrideSaveBody {
  type_key: string
  locale: PrintOverrideLocale
  layout: Record<string, unknown>
}

export interface PrintOverrideReasonBody {
  reason_code: string
}

const BASE = '/api/v1/documents/print-overrides'

/** Server format (`print_overrides.ex` `@reason_code_re`). */
const REASON_CODE_RE = /^[a-z][a-z0-9_]{0,63}$/

export function isValidReasonCode(value: string): boolean {
  return REASON_CODE_RE.test(value)
}

export const REASON_CODE_MESSAGE =
  'reason_code must start with a lower-case letter and use lower-case letters, digits or underscore, at most 64 characters'

export const documentPrintOverridesApi = {
  list: (filters?: PrintOverrideFilters) =>
    client.get<{ overrides: PrintOverrideMeta[] }>(BASE, filters as Record<string, unknown> | undefined),
  get: (id: string) => client.get<PrintOverride>(`${BASE}/${encodeURIComponent(id)}`),
  save: (body: PrintOverrideSaveBody) =>
    client.post<PrintOverride>(BASE, {
      type_key: body.type_key,
      locale: body.locale,
      layout: body.layout,
    } satisfies PrintOverrideSaveBody),
  activate: (id: string, reasonCode: string) =>
    client.post<PrintOverride>(`${BASE}/${encodeURIComponent(id)}/activate`, {
      reason_code: reasonCode,
    } satisfies PrintOverrideReasonBody),
  retire: (id: string, reasonCode: string) =>
    client.post<PrintOverride>(`${BASE}/${encodeURIComponent(id)}/retire`, {
      reason_code: reasonCode,
    } satisfies PrintOverrideReasonBody),
}

const GENERIC_ERROR = 'Something went wrong. Try again.'

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function renderPath(path: unknown): string {
  if (!Array.isArray(path)) return ''
  let out = ''
  for (const el of path) {
    if (typeof el === 'number' && Number.isFinite(el)) out += `[${el}]`
    else if (typeof el === 'string') out += out === '' ? el : `.${el}`
  }
  return out
}

/** Turns a failed request into safe lines. Never reads the submitted layout and
 *  never shows `err.message` or an unknown response body. */
export function describePrintOverrideError(err: unknown): string[] {
  const e = err as { status?: unknown; details?: unknown } | null | undefined
  if (!e || typeof e !== 'object' || typeof e.status !== 'number') return [GENERIC_ERROR]
  if (e.status === 404) return ['Not found']
  if (e.status === 422 && Array.isArray(e.details)) {
    const lines: string[] = []
    for (const item of e.details) {
      if (!isRecord(item) || typeof item.rule !== 'string') continue
      const path = renderPath(item.path)
      lines.push(path === '' ? item.rule : `${item.rule} at ${path}`)
    }
    return lines.length > 0 ? lines : [GENERIC_ERROR]
  }
  if ((e.status === 422 || e.status === 409) && isRecord(e.details) && typeof e.details.detail === 'string') {
    return [e.details.detail]
  }
  return [GENERIC_ERROR]
}
