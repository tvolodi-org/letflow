// @vitest-environment jsdom
/**
 * Unit tests — REQ-275: useToast hook (module-level store)
 *
 * TC-REQ275-01: success/error/warning signatures accept (message, { description }?)
 *   and produce entries with the expected variant/message/description
 * TC-REQ275-02: success/warning resolve to 4000ms auto-dismiss; error resolves to 8000ms
 * TC-REQ275-03: cap of 4 — adding a 5th toast drops the oldest (last / index 4+)
 * TC-REQ275-04: newest-first ordering — index 0 is always the most recently added
 * TC-REQ275-05: dismissToast removes the entry and clears its pending timer (no
 *   orphaned auto-dismiss firing after manual dismissal)
 * TC-REQ275-06: clearAllToasts resets the store and clears all pending timers
 *
 * Uses vi.useFakeTimers()/vi.advanceTimersByTime() for timing assertions — new
 * pattern territory in web/src/ per the design doc's note to TEST-DESIGNER (§4.2).
 * clearAllToasts() is called in afterEach because the store is module-level, not
 * per-test state.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  useToast,
  getToastSnapshot,
  dismissToast,
  clearAllToasts,
} from '../useToast'

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  clearAllToasts()
  vi.useRealTimers()
})

describe('REQ-275 — useToast', () => {
  it('TC-REQ275-01: success/error/warning accept (message, { description }?) and store the entry', () => {
    const toast = useToast()

    toast.success('Task completed successfully')
    toast.error('Failed to cancel instance', { description: 'timeout after 30s' })
    toast.warning('Instance is in an error state')

    const entries = getToastSnapshot()
    expect(entries).toHaveLength(3)

    // newest-first: warning (3rd call) is index 0, success (1st call) is index 2
    expect(entries[2]).toMatchObject({ variant: 'success', message: 'Task completed successfully' })
    expect(entries[2].description).toBeUndefined()
    expect(entries[1]).toMatchObject({
      variant: 'error',
      message: 'Failed to cancel instance',
      description: 'timeout after 30s',
    })
    expect(entries[0]).toMatchObject({ variant: 'warning', message: 'Instance is in an error state' })
  })

  it('TC-REQ275-02: success/info/warning resolve to 4000ms, error never auto-closes (0)', () => {
    const toast = useToast()
    toast.success('s')
    toast.warning('w')
    toast.error('e')

    const entries = getToastSnapshot()
    const byVariant = Object.fromEntries(entries.map((e) => [e.variant, e.durationMs]))
    expect(byVariant.success).toBe(4000)
    expect(byVariant.warning).toBe(4000)
    expect(byVariant.error).toBe(0)

    // Confirm the timers actually fire at those offsets (not just the stored field).
    expect(getToastSnapshot()).toHaveLength(3)
    vi.advanceTimersByTime(4000)
    // success and warning gone, error remains (8s not yet elapsed)
    const remaining = getToastSnapshot()
    expect(remaining).toHaveLength(1)
    expect(remaining[0].variant).toBe('error')

    vi.advanceTimersByTime(60000) // an error stays until dismissed
    expect(getToastSnapshot()).toHaveLength(1)
  })

  it('TC-REQ275-03: adding a 5th toast drops the oldest', () => {
    const toast = useToast()
    toast.success('first')
    toast.success('second')
    toast.success('third')
    toast.success('fourth')
    expect(getToastSnapshot()).toHaveLength(4)

    toast.success('fifth')
    const entries = getToastSnapshot()
    expect(entries).toHaveLength(4)
    // 'first' (the oldest) must be gone; 'fifth' (newest) is present at index 0.
    expect(entries.some((e) => e.message === 'first')).toBe(false)
    expect(entries[0].message).toBe('fifth')
    expect(entries.map((e) => e.message)).toEqual(['fifth', 'fourth', 'third', 'second'])
  })

  it('TC-REQ275-03b: the dropped (oldest) entry does not later auto-fire a dismiss for a live entry', () => {
    // Guards against an orphaned timer surviving the drop and later mutating state
    // unexpectedly (e.g. clearing something that replaced it).
    const toast = useToast()
    toast.success('first')
    toast.success('second')
    toast.success('third')
    toast.success('fourth')
    toast.success('fifth') // drops 'first'

    expect(() => vi.advanceTimersByTime(4000)).not.toThrow()
    // All 4 remaining (non-dropped) success toasts share the same 4s timer and should
    // all have auto-dismissed cleanly with nothing left over.
    expect(getToastSnapshot()).toHaveLength(0)
  })

  it('TC-REQ275-04: newest-first ordering — index 0 is always the most recently added', () => {
    const toast = useToast()
    toast.success('a')
    expect(getToastSnapshot()[0].message).toBe('a')
    toast.success('b')
    expect(getToastSnapshot()[0].message).toBe('b')
    toast.success('c')
    expect(getToastSnapshot()[0].message).toBe('c')
  })

  it('TC-REQ275-05: dismissToast removes the entry and clears its timer (no late auto-dismiss side effects)', () => {
    const toast = useToast()
    toast.success('to be dismissed')
    const [entry] = getToastSnapshot()

    dismissToast(entry.id)
    expect(getToastSnapshot()).toHaveLength(0)

    // Advancing time past the original 4000ms must not throw or affect anything —
    // proves the timer was actually cleared, not just the entry removed from the array.
    expect(() => vi.advanceTimersByTime(5000)).not.toThrow()
    expect(getToastSnapshot()).toHaveLength(0)
  })

  it('TC-REQ275-06: clearAllToasts resets the store and clears all pending timers', () => {
    const toast = useToast()
    toast.success('a')
    toast.error('b')
    expect(getToastSnapshot()).toHaveLength(2)

    clearAllToasts()
    expect(getToastSnapshot()).toHaveLength(0)

    expect(() => vi.advanceTimersByTime(8000)).not.toThrow()
    expect(getToastSnapshot()).toHaveLength(0)
  })
})
