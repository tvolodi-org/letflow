/** Client rings of a problem report (T-1950): the last 20 actions and the last 10 API calls.
 *
 *  Module-level state, not React state, so the rings survive the crash of the shell subtree and the crash
 *  report still has them. Fed from two places only: one capture-phase click listener (installed by AppShell)
 *  and one hook in api/client.ts. An action is named only by data-testid, ARIA role or tag; text, labels and
 *  field values are never read. A request entry holds method, path pattern, status, trace id and error code:
 *  no bodies. Every function here is safe to call from a request path: none throws. */
import { normalizeName, normalizePath } from './redact'

export type ActionEntry = { at: string; kind: 'click' | 'nav'; name: string }
export type RequestEntry = {
  at: string
  method: string
  path: string
  status?: number
  trace_id?: string
  error_code?: string
}

export const MAX_ACTIONS = 20
export const MAX_REQUESTS = 10

const REPORT_PATH = '/api/v1/me/problem-reports'
const METHODS = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE'])
const TRACE_RE = /^[A-Za-z0-9_-]{1,64}$/
const CODE_RE = /^[A-Za-z0-9_.:/-]{1,80}$/
const INPUT_SELECTOR = 'input, textarea, select, [contenteditable=""], [contenteditable="true"]'
const CLICKABLE_SELECTOR =
  'button, a, [role=button], [role=menuitem], [role=tab], [role=option], [role=treeitem], [role=checkbox], [role=switch]'

let actions: ActionEntry[] = []
let requests: RequestEntry[] = []
let entryByResponse = new WeakMap<object, RequestEntry>()

const isError = (e: RequestEntry): boolean => e.status === undefined || e.status === 0 || e.status >= 400

export function recordAction(kind: 'click' | 'nav', name: string): void {
  try {
    const clean = kind === 'nav' ? normalizePath(name).slice(0, 80) : normalizeName(name)
    const last = actions[actions.length - 1]
    if (kind === 'nav' && last && last.kind === 'nav' && last.name === clean) return
    actions.push({ at: new Date().toISOString(), kind, name: clean })
    if (actions.length > MAX_ACTIONS) actions = actions.slice(actions.length - MAX_ACTIONS)
  } catch {
    /* capture must never break the app */
  }
}

/** Keeps errors: a repeat of a successful call replaces its older twin; a full ring drops the oldest success first. */
function pushRequest(entry: RequestEntry): void {
  if (!isError(entry)) {
    requests = requests.filter((e) => isError(e) || e.method !== entry.method || e.path !== entry.path || e.status !== entry.status)
  }
  requests.push(entry)
  while (requests.length > MAX_REQUESTS) {
    const i = requests.findIndex((e) => !isError(e))
    requests.splice(i === -1 ? 0 : i, 1)
  }
}

export function recordRequest(
  response: Response | null,
  method: string,
  url: string,
  status: number,
  traceId: string | null,
): void {
  try {
    const pathname = new URL(url, window.location.origin).pathname
    if (!pathname.startsWith('/api/') || pathname === REPORT_PATH) return
    const m = method.toUpperCase()
    if (!METHODS.has(m)) return
    const entry: RequestEntry = { at: new Date().toISOString(), method: m, path: normalizePath(pathname), status }
    if (traceId && TRACE_RE.test(traceId)) entry.trace_id = traceId
    pushRequest(entry)
    if (response) entryByResponse.set(response, entry)
  } catch {
    /* capture must never break a request */
  }
}

/** Adds the error code (and a body trace id when the header had none) to the entry of this response, if it is still in the ring. */
export function noteRequestError(response: Response, errorCode: string | undefined, traceId: string | undefined): void {
  try {
    const entry = entryByResponse.get(response)
    if (!entry) return
    if (errorCode && CODE_RE.test(errorCode)) entry.error_code = errorCode
    if (!entry.trace_id && traceId && TRACE_RE.test(traceId)) entry.trace_id = traceId
  } catch {
    /* capture must never break a request */
  }
}

export function snapshot(): { actions: ActionEntry[]; requests: RequestEntry[] } {
  return {
    actions: actions.map((a) => ({ ...a })),
    requests: requests.map((r) => ({ ...r })),
  }
}

export function resetCapture(): void {
  actions = []
  requests = []
  entryByResponse = new WeakMap()
}

/** Installs the click listener; returns the remover. */
export function installActionCapture(doc: Document = document): () => void {
  const handler = (e: Event): void => {
    try {
      const target = e.target
      if (!(target instanceof Element)) return
      if (target.closest(INPUT_SELECTOR)) return
      const el = target.closest(CLICKABLE_SELECTOR)
      if (!el) return
      if (el.closest('[data-testid="report-dialog"]')) return
      const name = el.getAttribute('data-testid') ?? el.getAttribute('role') ?? el.tagName.toLowerCase()
      recordAction('click', name)
    } catch {
      /* capture must never break a click */
    }
  }
  doc.addEventListener('click', handler, true)
  return () => doc.removeEventListener('click', handler, true)
}
