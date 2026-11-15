/** problemReportsModel -- T-2007: pure rules of the owner inbox screen for problem reports (no React, no network).
 *  The server stays the authority for every rule here (`Letflow.ProblemReports.Inbox`); these only keep a request
 *  from being sent that it would refuse, and turn its answers into message keys. */
import type { StatusGlyph, StatusTone } from '@/components/ui/StatusPill'
import type { DecisionAction, InboxDetail, InboxFilter } from '@/api/platformProblemReports'
import type { ApiError } from '@/types/api'

export interface Look {
  tone: StatusTone
  glyph: StatusGlyph
}
export const STATUS_LOOK: Record<string, Look> = {
  received: { tone: 'info', glyph: 'ring' },
  in_work: { tone: 'info', glyph: 'half' },
  answered: { tone: 'success', glyph: 'dot' },
  fixed: { tone: 'success', glyph: 'dot' },
  not_done: { tone: 'neutral', glyph: 'dash' },
}
export const UNKNOWN_LOOK: Look = { tone: 'neutral', glyph: 'ring' }

/** A decision can be sent only from these two statuses; an unknown status counts as closed. */
export function isOpen(status: string): boolean {
  return status === 'received' || status === 'in_work'
}

/** Header buttons, left to right; `answer` is the one primary button and comes last. */
export const ACTIONS: readonly DecisionAction[] = ['develop', 'ask', 'reject', 'fixed', 'answer']

/** Text caps in code points (server: develop 2000, the rest 4000). */
export const CAPS: Record<DecisionAction, number> = { answer: 4000, ask: 4000, reject: 4000, develop: 2000, fixed: 4000 }

export type TextCheck = 'ok' | 'empty' | 'tooLong'

export function checkDecisionText(action: DecisionAction, text: string): TextCheck {
  const trimmed = text.trim()
  if (trimmed === '') return action === 'fixed' ? 'ok' : 'empty'
  return [...trimmed].length > CAPS[action] ? 'tooLong' : 'ok'
}

export type DecisionErrorKind = 'closed' | 'copies' | 'secret' | 'invalid' | 'gone' | 'unavailable' | 'failed'

export function decisionErrorKind(err: Pick<ApiError, 'status' | 'details'>): DecisionErrorKind {
  if (err.status === 409) return 'closed'
  if (err.status === 404) return 'gone'
  if (err.status === 503) return 'unavailable'
  if (err.status === 422) {
    const detail = err.details?.detail
    const text = typeof detail === 'string' ? detail : ''
    if (text.startsWith('The summary must be in your own words')) return 'copies'
    if (text.startsWith('The text looks like it holds a secret')) return 'secret'
    return 'invalid'
  }
  return 'failed'
}

export function normalizeFilter(raw: string | null): InboxFilter {
  return raw === 'closed' || raw === 'all' ? raw : 'open'
}

const KNOWN_CONTEXT = new Set(['route', 'browser', 'ui_language', 'actions', 'requests', 'crash'])

export interface FactRow {
  id: string
  /** Catalog key under `problemReports.fact.`; `null` for a row of an unknown context key (shown by its own name). */
  label: string | null
  name?: string
  value: string
  mono: boolean
  /** A formatted date: the page formats it. */
  date?: boolean
}
export interface ActionRow {
  at: string
  kind: string
  name: string
}
export interface RequestRow {
  at: string
  method: string
  path: string
  status: string
  error_code: string
  trace_id: string
}
export interface Facts {
  rows: FactRow[]
  actions: ActionRow[]
  requests: RequestRow[]
}

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const str = (v: unknown): string => (typeof v === 'string' ? v : typeof v === 'number' ? String(v) : '')
const flat = (v: unknown): string => (typeof v === 'string' ? v : Array.isArray(v) || isRecord(v) ? JSON.stringify(v) : String(v))

/** The facts of one report as plain strings (rendered only as React text). Never reads an identifier of a tenant or user. */
export function reportFacts(detail: InboxDetail): Facts {
  const ctx = isRecord(detail.context) ? detail.context : {}
  const browser = isRecord(ctx.browser) ? ctx.browser : {}
  const crash = isRecord(ctx.crash) ? ctx.crash : {}
  const rows: FactRow[] = []
  const add = (id: string, value: string, mono = false, date = false) => {
    if (value !== '') rows.push({ id, label: id, value, mono, date })
  }
  add('received', detail.received_at ?? '', false, true)
  add('company', detail.reporter?.tenant_name ?? '')
  add('user', detail.reporter?.name ?? '')
  add('roles', (detail.reporter?.roles ?? []).join(', '))
  add('route', str(ctx.route), true)
  add('uiLanguage', str(ctx.ui_language))
  add('browser', str(browser.user_agent))
  add('viewport', str(browser.viewport), true)
  add('browserLanguage', str(browser.language))
  add('version', detail.server_version ?? '', true)
  add('trace', detail.trace_id ?? '', true)
  const crashText = [str(crash.name), str(crash.message)].filter(Boolean).join(': ')
  add('error', crashText)
  add('decided', detail.decided_at ?? '', false, true)
  for (const [key, value] of Object.entries(ctx)) {
    if (KNOWN_CONTEXT.has(key) || value == null) continue
    if (isRecord(value)) {
      for (const [k, v] of Object.entries(value)) rows.push({ id: `other:${key}.${k}`, label: null, name: k, value: flat(v), mono: true })
    } else {
      rows.push({ id: `other:${key}`, label: null, name: key, value: flat(value), mono: true })
    }
  }
  const actions = (Array.isArray(ctx.actions) ? ctx.actions : []).filter(isRecord).map((a) => ({ at: str(a.at), kind: str(a.kind), name: str(a.name) }))
  const requests = (Array.isArray(ctx.requests) ? ctx.requests : []).filter(isRecord).map((r) => ({
    at: str(r.at),
    method: str(r.method),
    path: str(r.path),
    status: str(r.status),
    error_code: str(r.error_code),
    trace_id: str(r.trace_id),
  }))
  return { rows, actions, requests }
}
