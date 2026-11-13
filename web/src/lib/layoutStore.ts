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
  /** The server value arrived. A non-empty one is applied once, and only when nothing was changed locally. An empty one
   *  (a reset) is applied every time while nothing is pending, in flight or unsynced (T-1873). Returns whether it was applied. */
  adoptServer(doc: UiLayout): boolean
  /** Listen to the other tabs of this browser (done at creation; idempotent, the provider calls it again after a remount). */
  connect(): void
  /** Stop listening to other tabs (provider cleanup). */
  dispose(): void
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
  /** Server calls (saves and resets) queued or running; one queue keeps a reset behind an older save. */
  let inflight = 0
  let chain: Promise<unknown> = Promise.resolve()
  let seq = 0
  const unsyncedKey = `${o.storageKey}.unsynced`
  const subs = new Set<() => void>()

  const notify = () => subs.forEach((f) => f())
  const lsSet = (k: string, v: string) => {
    try {
      localStorage.setItem(k, v)
    } catch {
      /* storage blocked */
    }
  }
  const lsRemove = (k: string) => {
    try {
      localStorage.removeItem(k)
    } catch {
      /* storage blocked */
    }
  }
  const unsynced = () => {
    try {
      return localStorage.getItem(unsyncedKey) !== null
    } catch {
      return false
    }
  }
  /** Run a server call after every earlier one settled (immediately when idle); a rejection is swallowed (INV-8). */
  const enqueue = (call: () => Promise<unknown> | void, onOk?: () => void) => {
    const idle = inflight === 0
    inflight++
    const run = async () => {
      try {
        await call()
        onOk?.()
      } catch {
        /* the localStorage copy stays; the next change tries again */
      } finally {
        inflight--
      }
    }
    chain = idle ? run() : chain.then(run)
  }
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
    const save = o.save
    if (save) {
      const mine = ++seq
      lsSet(unsyncedKey, '1')
      enqueue(
        () => save(json),
        () => {
          if (seq === mine) lsRemove(unsyncedKey)
        },
      )
    }
  }
  const change = (next: UiLayout) => {
    doc = next
    dirty = true
    pending = true
    if (timer) clearTimeout(timer)
    timer = setTimeout(write, ms)
  }

  /** Another tab of this browser wrote or removed the shared copy: follow it (a reset in tab B must not be undone by tab A). */
  const onStorage = (e: StorageEvent) => {
    if (e.key !== o.storageKey) return
    if (e.newValue === null) {
      if (timer) clearTimeout(timer)
      timer = null
      pending = false
      doc = L.emptyLayout()
      notify()
    } else if (!pending) {
      doc = L.parseLayoutJson(e.newValue)
      notify()
    }
  }
  if (typeof window !== 'undefined') window.addEventListener('storage', onStorage)

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
    // notify: the screen's splitters and column handles re-read the (now empty) layout at once
    resetScreen: (s) => {
      change(L.resetScreen(doc, s))
      notify()
    },
    resetAll: () => {
      if (timer) clearTimeout(timer)
      timer = null
      pending = false
      dirty = true
      doc = L.emptyLayout()
      seq++
      lsRemove(o.storageKey)
      lsRemove(unsyncedKey)
      const reset = o.reset
      if (reset) enqueue(() => reset())
      notify()
    },
    flush: () => {
      if (pending) {
        if (timer) clearTimeout(timer)
        write()
      }
    },
    adoptServer: (server) => {
      if (JSON.stringify(server) === JSON.stringify(L.emptyLayout())) {
        // The server was reset (or never saved): that wins over a stale local copy, unless an edit is pending, a call is
        // in flight or an earlier write never reached the server (offline edits win).
        if (pending || inflight > 0 || unsynced()) return false
        if (JSON.stringify(doc) === JSON.stringify(L.emptyLayout())) {
          lsRemove(o.storageKey)
          return false
        }
        doc = L.emptyLayout()
        lsRemove(o.storageKey)
        notify()
        return true
      }
      if (adopted || dirty) return false
      adopted = true
      doc = server
      notify()
      return true
    },
    connect: () => {
      if (typeof window !== 'undefined') window.addEventListener('storage', onStorage)
    },
    dispose: () => {
      if (typeof window !== 'undefined') window.removeEventListener('storage', onStorage)
    },
    subscribe: (fn) => {
      subs.add(fn)
      return () => subs.delete(fn)
    },
  }
}
