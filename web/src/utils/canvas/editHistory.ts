/**
 * editHistory — T-1563. A bounded undo/redo stack of whole-graph snapshots. Edits with the same `coalesceKey` as the
 * previous push (a burst of label keystrokes, one drag) replace the top entry instead of adding a step.
 */
export const HISTORY_LIMIT = 100

export interface History<T> {
  past: T[]
  present: T
  future: T[]
  key: string | null
}

export const initialHistory = <T>(present: T): History<T> => ({ past: [], present, future: [], key: null })

export function push<T>(h: History<T>, next: T, coalesceKey?: string): History<T> {
  if (Object.is(next, h.present)) return h
  if (coalesceKey && h.key === coalesceKey && h.past.length > 0) {
    return { ...h, present: next, future: [] }
  }
  const past = [...h.past, h.present]
  return {
    past: past.length > HISTORY_LIMIT ? past.slice(past.length - HISTORY_LIMIT) : past,
    present: next,
    future: [],
    key: coalesceKey ?? null,
  }
}

export function undo<T>(h: History<T>): History<T> {
  if (h.past.length === 0) return h
  const present = h.past[h.past.length - 1] as T
  return { past: h.past.slice(0, -1), present, future: [h.present, ...h.future], key: null }
}

export function redo<T>(h: History<T>): History<T> {
  if (h.future.length === 0) return h
  const [present, ...future] = h.future as [T, ...T[]]
  return { past: [...h.past, h.present], present, future, key: null }
}

/** Forget all steps and make `present` the new base (after a save or a discard). */
export const reset = <T>(present: T): History<T> => initialHistory(present)
export const canUndo = <T>(h: History<T>) => h.past.length > 0
export const canRedo = <T>(h: History<T>) => h.future.length > 0
