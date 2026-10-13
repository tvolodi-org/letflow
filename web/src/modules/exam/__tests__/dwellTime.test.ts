/**
 * Q-1075 / GH 2432: client-reported time per question. Pins the accumulation across a
 * revisit, the removed 0 default, the base-plus-measured total, and monotonicity.
 */

import { describe, expect, it } from 'vitest'
import { createDwellClock, recordSaveTotal, switchQuestion } from '@/modules/exam/dwellTime'

describe('Q-1075 / GH 2432 -- dwellTime', () => {
  it('accumulates time across a revisit, reported as whole seconds', () => {
    const clock = createDwellClock(0)
    switchQuestion(clock, 'q1', 0)
    switchQuestion(clock, 'q2', 3_000) // q1 was shown for 3s
    switchQuestion(clock, 'q1', 10_000) // q2 was shown for 7s
    // Revisit q1 for 2s, then save.
    expect(recordSaveTotal(clock, 'q1', 0, 12_000)).toBe(5) // 3s + 2s
  })

  it('reports a non-zero total on the first save after a delay (the 0 default is gone)', () => {
    const clock = createDwellClock(0)
    switchQuestion(clock, 'q1', 0)
    expect(recordSaveTotal(clock, 'q1', 0, 1_500)).toBe(1)
  })

  it('adds the seconds stored at the first save of this mount, and the first base wins', () => {
    const clock = createDwellClock(0)
    switchQuestion(clock, 'q1', 0)
    expect(recordSaveTotal(clock, 'q1', 7, 2_000)).toBe(9) // stored 7 + 2s
    // A later save with a different stored value keeps the first base: 7 + 4s.
    expect(recordSaveTotal(clock, 'q1', 999, 4_000)).toBe(11)
  })

  it('never decreases when the clock goes backwards', () => {
    const clock = createDwellClock(5_000)
    switchQuestion(clock, 'q1', 5_000)
    const first = recordSaveTotal(clock, 'q1', 0, 8_000) // 3s
    const second = recordSaveTotal(clock, 'q1', 0, 6_000) // clock went back: no negative charge
    expect(second).toBeGreaterThanOrEqual(first)
  })
})
