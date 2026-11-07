/** T-1442 — pure helpers for the remembered layout (`ui.layout` user preference).
 *  `sanitizeUiLayout` is the TypeScript twin of `LFPrefs.sanitize` (design repo) and of the server's
 *  `Letflow.UserPreferences.sanitize_layout/1`: same ids, ranges, caps and the 8192-byte limit. Where the two ever
 *  disagree the server wins. Only `panes`, `collapsed`, `cols` and `linesMode` (T-1448, exactly "grid" or "form") are kept per screen.
 *  All setters are immutable: they return a new document, the caller decides when to store it. */
import type { UiLayout } from '@/api/preferences'

export const LAYOUT_MAX_BYTES = 8192
const SCREEN_ID = /^[a-z0-9.-]{1,48}$/
const SPLIT_ID = /^[a-z0-9-]{1,24}$/

export function emptyLayout(): UiLayout {
  return { v: 1, shell: { sidenav: {} }, screens: {} }
}

/** Clamp first, then round to 0.1 (the server's order). Non-numbers give null. */
function num(v: unknown, lo: number, hi: number): number | null {
  if (typeof v !== 'number' || !Number.isFinite(v)) return null
  const x = Math.min(hi, Math.max(lo, v))
  return Math.floor(x * 10 + 0.5) / 10
}

function isObj(o: unknown): o is Record<string, unknown> {
  return !!o && typeof o === 'object' && !Array.isArray(o)
}

/** The first `n` keys in sorted order (the server sorts too, so both keep the same ones). */
function keys(o: unknown, n: number): string[] {
  return isObj(o) ? Object.keys(o).sort().slice(0, n) : []
}

type Screen = UiLayout['screens'][string]

function sanitizeScreen(s: Record<string, unknown>): Screen {
  const r: Screen = {}
  const panes = s.panes as Record<string, unknown> | undefined
  for (const k of keys(panes, 12)) {
    const raw = panes?.[k]
    if (!SPLIT_ID.test(k) || !Array.isArray(raw)) continue
    const a = raw.slice(0, 12).map((x) => (x == null ? null : num(x, 5, 85)))
    if (a.some((x) => x != null)) (r.panes ??= {})[k] = a
  }
  const collapsed = s.collapsed as Record<string, unknown> | undefined
  for (const k of keys(collapsed, 12)) {
    const raw = collapsed?.[k]
    if (!SPLIT_ID.test(k) || !Array.isArray(raw)) continue
    const a = raw.slice(0, 12).filter((x): x is number => typeof x === 'number' && Number.isInteger(x) && x >= 0 && x < 12)
    if (a.length) (r.collapsed ??= {})[k] = a
  }
  const cols = s.cols as Record<string, unknown> | undefined
  for (const t of keys(cols, 24)) {
    if (!SPLIT_ID.test(t)) continue
    const cs = cols?.[t] as Record<string, unknown>
    const c: Record<string, number> = {}
    for (const cid of keys(cs, 40)) {
      if (!SPLIT_ID.test(cid)) continue
      const v = num(cs[cid], 3, 80)
      if (v != null) c[cid] = v
    }
    if (Object.keys(c).length) (r.cols ??= {})[t] = c
  }
  if (s.linesMode === 'grid' || s.linesMode === 'form') r.linesMode = s.linesMode
  return r
}

export function sanitizeUiLayout(doc: unknown): UiLayout {
  const out = emptyLayout()
  if (!isObj(doc)) return out
  const shell = doc.shell
  const sn = isObj(shell) ? shell.sidenav : undefined
  if (isObj(sn)) {
    if (typeof sn.collapsed === 'boolean') out.shell.sidenav.collapsed = sn.collapsed
    const w = num(sn.w, 160, 420)
    if (w != null) out.shell.sidenav.w = Math.floor(w + 0.5)
  }
  const screens = doc.screens as Record<string, unknown> | undefined
  for (const sid of keys(screens, 40)) {
    const s = screens?.[sid]
    if (!SCREEN_ID.test(sid) || !isObj(s)) continue
    const r = sanitizeScreen(s)
    if (Object.keys(r).length) out.screens[sid] = r
  }
  if (JSON.stringify(out).length > LAYOUT_MAX_BYTES) out.screens = {}
  return out
}

/** Tolerant parse of a stored JSON string (server value or localStorage). */
export function parseLayoutJson(raw: unknown): UiLayout {
  if (typeof raw !== 'string') return emptyLayout()
  try {
    return sanitizeUiLayout(JSON.parse(raw))
  } catch {
    return emptyLayout()
  }
}

function withScreen(doc: UiLayout, sid: string, fn: (s: Screen) => void): UiLayout {
  const next = structuredClone(doc)
  const s = (next.screens[sid] ??= {})
  fn(s)
  if (Object.keys(s).length === 0) delete next.screens[sid]
  return next
}

export function getPanes(doc: UiLayout, sid: string, split: string): (number | null)[] | null {
  return doc.screens[sid]?.panes?.[split] ?? null
}
export function setPanes(doc: UiLayout, sid: string, split: string, arr: (number | null)[]): UiLayout {
  return withScreen(doc, sid, (s) => {
    if (arr.some((x) => x != null)) (s.panes ??= {})[split] = arr
    else if (s.panes) {
      delete s.panes[split]
      if (Object.keys(s.panes).length === 0) delete s.panes
    }
  })
}
export function getCollapsed(doc: UiLayout, sid: string, split: string): number[] {
  return doc.screens[sid]?.collapsed?.[split] ?? []
}
export function setCollapsed(doc: UiLayout, sid: string, split: string, arr: number[]): UiLayout {
  return withScreen(doc, sid, (s) => {
    if (arr.length) (s.collapsed ??= {})[split] = arr
    else if (s.collapsed) {
      delete s.collapsed[split]
      if (Object.keys(s.collapsed).length === 0) delete s.collapsed
    }
  })
}
export function getCols(doc: UiLayout, sid: string, table: string): Record<string, number> | null {
  return doc.screens[sid]?.cols?.[table] ?? null
}
export function setCols(doc: UiLayout, sid: string, table: string, obj: Record<string, number> | null): UiLayout {
  return withScreen(doc, sid, (s) => {
    if (obj && Object.keys(obj).length) (s.cols ??= {})[table] = obj
    else if (s.cols) {
      delete s.cols[table]
      if (Object.keys(s.cols).length === 0) delete s.cols
    }
  })
}
export function setShell(doc: UiLayout, patch: { w?: number | null; collapsed?: boolean | null }): UiLayout {
  const next = structuredClone(doc)
  const sn = next.shell.sidenav
  if (patch.w !== undefined) {
    if (patch.w == null) delete sn.w
    else sn.w = patch.w
  }
  if (patch.collapsed !== undefined) {
    if (patch.collapsed == null) delete sn.collapsed
    else sn.collapsed = patch.collapsed
  }
  return next
}
export function resetScreen(doc: UiLayout, sid: string): UiLayout {
  const next = structuredClone(doc)
  delete next.screens[sid]
  return next
}
