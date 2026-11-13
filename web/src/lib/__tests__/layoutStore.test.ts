// @vitest-environment jsdom
/** T-1873 T11 — a reset must stay reset: ordered server writes, the unsynced marker, an empty server value wins, other tabs follow. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createLayoutStore, type LayoutStore } from '../layoutStore'
import { emptyLayout } from '../layoutPrefs'

const KEY = 'test.t11'
const stores: LayoutStore[] = []
const mk = (o: Partial<Parameters<typeof createLayoutStore>[0]> = {}) => {
  const s = createLayoutStore({ storageKey: KEY, debounceMs: 100, ...o })
  stores.push(s)
  return s
}
const storageEvent = (newValue: string | null) => window.dispatchEvent(new StorageEvent('storage', { key: KEY, newValue }))

beforeEach(() => {
  localStorage.clear()
  vi.useFakeTimers()
})
afterEach(() => {
  stores.splice(0).forEach((s) => s.dispose())
  vi.useRealTimers()
})

describe('layoutStore reset ordering', () => {
  it('T11(i) another tab reset (storage null) cancels the pending write: no save, nothing stored', async () => {
    const save = vi.fn(async () => undefined)
    const a = mk({ save })
    a.setCollapsed('s', 'x', [0])
    localStorage.removeItem(KEY)
    storageEvent(null)
    await vi.advanceTimersByTimeAsync(1000)
    expect(save).not.toHaveBeenCalled()
    expect(localStorage.getItem(KEY)).toBeNull()
    expect(a.getCollapsed('s', 'x')).toEqual([])
  })

  it('T11(ii) flush after a reset writes nothing', async () => {
    const save = vi.fn(async () => undefined)
    const a = mk({ save, reset: async () => undefined })
    a.setCollapsed('s', 'x', [0])
    a.resetAll()
    a.flush()
    await vi.advanceTimersByTimeAsync(1000)
    expect(save).not.toHaveBeenCalled()
    expect(localStorage.getItem(KEY)).toBeNull()
  })

  it('T11(iii) an empty server value beats a stale local copy; an unsynced marker keeps the local copy', () => {
    const stale = JSON.stringify({ v: 1, shell: {}, screens: { s: { collapsed: { x: [0] } } } })
    localStorage.setItem(KEY, stale)
    const a = mk()
    expect(a.getCollapsed('s', 'x')).toEqual([0])
    expect(a.adoptServer(emptyLayout())).toBe(true)
    expect(a.getCollapsed('s', 'x')).toEqual([])
    expect(localStorage.getItem(KEY)).toBeNull()

    localStorage.setItem(KEY, stale)
    localStorage.setItem(`${KEY}.unsynced`, '1')
    const b = mk()
    expect(b.adoptServer(emptyLayout())).toBe(false)
    expect(b.getCollapsed('s', 'x')).toEqual([0])
  })

  it('T11(iv) a reset call starts only after an earlier save settled', async () => {
    const log: string[] = []
    let release: () => void = () => undefined
    const save = vi.fn(() => new Promise<void>((r) => (release = () => { log.push('save done'); r() })))
    const reset = vi.fn(async () => void log.push('reset'))
    const a = mk({ save, reset })
    a.setCollapsed('s', 'x', [0])
    await vi.advanceTimersByTimeAsync(200)
    expect(save).toHaveBeenCalledTimes(1)
    a.resetAll()
    await vi.advanceTimersByTimeAsync(10)
    expect(reset).not.toHaveBeenCalled()
    release()
    await vi.advanceTimersByTimeAsync(10)
    expect(log).toEqual(['save done', 'reset'])
  })

  it('T11(v) an empty server value is applied again on a later refetch', () => {
    const a = mk()
    expect(a.adoptServer(emptyLayout())).toBe(false)
    a.setCollapsed('s', 'x', [0])
    a.flush()
    expect(a.adoptServer(emptyLayout())).toBe(true)
    expect(a.getCollapsed('s', 'x')).toEqual([])
  })

  it('T11(vi) edit, save resolves, then the empty server value arrives: doc empty, key gone, no later save', async () => {
    const save = vi.fn(async () => undefined)
    const a = mk({ save })
    a.setCollapsed('s', 'x', [0])
    await vi.advanceTimersByTimeAsync(200)
    expect(save).toHaveBeenCalledTimes(1)
    expect(localStorage.getItem(`${KEY}.unsynced`)).toBeNull()
    expect(a.adoptServer(emptyLayout())).toBe(true)
    expect(a.getCollapsed('s', 'x')).toEqual([])
    expect(localStorage.getItem(KEY)).toBeNull()
    await vi.advanceTimersByTimeAsync(1000)
    expect(save).toHaveBeenCalledTimes(1)
  })

  it('T11(vii) a pending edit, a save in flight or a rejected save keeps the local doc; a storage value is not taken over a pending edit', async () => {
    const a = mk({ save: () => new Promise<void>(() => undefined) })
    a.setCollapsed('s', 'x', [0])
    expect(a.adoptServer(emptyLayout())).toBe(false) // pending timer
    await vi.advanceTimersByTimeAsync(200)
    expect(a.adoptServer(emptyLayout())).toBe(false) // save in flight
    expect(a.getCollapsed('s', 'x')).toEqual([0])

    localStorage.clear()
    const b = mk({ save: async () => Promise.reject(new Error('offline')) })
    b.setCollapsed('s', 'x', [0])
    await vi.advanceTimersByTimeAsync(200)
    await vi.advanceTimersByTimeAsync(10)
    expect(b.adoptServer(emptyLayout())).toBe(false) // unsynced marker stays after a failed save
    expect(b.getCollapsed('s', 'x')).toEqual([0])

    localStorage.clear()
    const c = mk()
    c.setCollapsed('s', 'x', [0])
    storageEvent(JSON.stringify({ v: 1, shell: {}, screens: {} }))
    expect(c.getCollapsed('s', 'x')).toEqual([0]) // own pending edit kept (last writer wins)
  })
})
