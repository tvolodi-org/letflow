/** T-1442 — in-memory store of the remembered layout with a debounced write.
 *  The document lives here; localStorage is always written (fallback when the API is down or the user is anonymous),
 *  and `save` (the server PUT) is called with the same JSON when the debounce fires. Last writer wins: one timer.
 *  No React in this file, so the components and the provider share it and tests need no DOM tree. */
import type { UiLayout } from '@/api/preferences'
import * as L from './layoutPrefs'

export const LAYOUT_STORAGE_KEY = 'lf.prefs.ui.layout.v1'
export const LAYOUT_DEBOUNCE_MS = 400

export interface LayoutStoreOptions {
  /** Full localStorage key (the provider suffixes the tenant id, so two tenants in one browser do not share). */
  storageKey: string
  /** Server write; a rejection is swallowed (the localStorage copy stays, the next change tries again). */
  save?: (json: string) => Promise<unknown> | void
  /** Server reset (PUT null) for `resetAll`. */
  reset?: () => Promise<unknown> | void
  debounceMs?: number
}

export interface LayoutStore {
  get(): UiLayout
  getPanes(sid: string, split: string): (number | null)[] | null
  setPanes(sid: string, split: string, arr: (number | null)[]): void
  getCollapsed(sid: string, split: string): number[]
  setCollapsed(sid: string, split: string, arr: number[]): void
  getCols(sid: string, table: string): Record<string, number> | null
  setCols(sid: string, table: string, obj: Record<string, number> | null): void
  getShell(): UiLayout['shell']['sidenav']
  setShell(patch: { w?: number | null; collapsed?: boolean | null }): void
  resetScreen(sid: string): void
  resetAll(): void
  /** Write now (unmount, pagehide). */
  flush(): void
  /** The server value arrived: applied once, and only when nothing was changed locally. Returns whether it was applied. */
  adoptServer(doc: UiLayout): boolean
  /** Fires after `adoptServer` or `resetAll` replaced the document (not on ordinary edits). */
  subscribe(fn: () => void): () => void
}

function readStorage(key: string): UiLayout {
  try {
    return L.parseLayoutJson(localStorage.getItem(key))
  } catch {
    return L.emptyLayout()
  }
}

export function createLayoutStore(o: LayoutStoreOptions): LayoutStore {
  const ms = o.debounceMs ?? LAYOUT_DEBOUNCE_MS
  let doc = readStorage(o.storageKey)
  let timer: ReturnType<typeof setTimeout> | null = null
  let pending = false
  let dirty = false
  let adopted = false
  const subs = new Set<() => void>()

  const notify = () => subs.forEach((f) => f())
  const write = () => {
    timer = null
    pending = false
    doc = L.sanitizeUiLayout(doc)
    const json = JSON.stringify(doc)
    try {
      localStorage.setItem(o.storageKey, json)
    } catch {
      /* storage blocked: sizes last for this page only */
    }
    try {
      void Promise.resolve(o.save?.(json)).catch(() => undefined)
    } catch {
      /* a failed save never breaks the page (INV-8) */
    }
  }
  const change = (next: UiLayout) => {
    doc = next
    dirty = true
    pending = true
    if (timer) clearTimeout(timer)
    timer = setTimeout(write, ms)
  }

  return {
    get: () => doc,
    getPanes: (s, k) => L.getPanes(doc, s, k),
    setPanes: (s, k, a) => change(L.setPanes(doc, s, k, a)),
    getCollapsed: (s, k) => L.getCollapsed(doc, s, k),
    setCollapsed: (s, k, a) => change(L.setCollapsed(doc, s, k, a)),
    getCols: (s, t) => L.getCols(doc, s, t),
    setCols: (s, t, c) => change(L.setCols(doc, s, t, c)),
    getShell: () => doc.shell.sidenav,
    setShell: (p) => change(L.setShell(doc, p)),
    resetScreen: (s) => change(L.resetScreen(doc, s)),
    resetAll: () => {
      if (timer) clearTimeout(timer)
      timer = null
      pending = false
      dirty = true
      doc = L.emptyLayout()
      try {
        localStorage.removeItem(o.storageKey)
      } catch {
        /* ignore */
      }
      try {
        void Promise.resolve(o.reset?.()).catch(() => undefined)
      } catch {
        /* ignore */
      }
      notify()
    },
    flush: () => {
      if (pending) {
        if (timer) clearTimeout(timer)
        write()
      }
    },
    adoptServer: (server) => {
      if (adopted || dirty) return false
      adopted = true
      // An empty server document (never saved) must not wipe what the fallback copy remembers.
      if (JSON.stringify(server) === JSON.stringify(L.emptyLayout())) return false
      doc = server
      notify()
      return true
    },
    subscribe: (fn) => {
      subs.add(fn)
      return () => subs.delete(fn)
    },
  }
}
