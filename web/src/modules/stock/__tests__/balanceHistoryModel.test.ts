/** M1 — T-1430: pure helpers of the balance history panel. */
import { describe, expect, it } from 'vitest'
import { legMatches, slotParams, toHistoryLines } from '../register/balanceHistoryModel'
import type { BalanceRow, MovementRow } from '../register/stock.api'

const ROW: BalanceRow = { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null, unit_ref: 'm1', quantity: '5' }
const leg = (over: Record<string, unknown> = {}) => ({ leg_no: 1, quantity: '5', unit_ref: 'm1', sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null, ...over })
const entry = (id: string, legs: ReturnType<typeof leg>[], over: Partial<MovementRow> = {}): MovementRow =>
  ({ entry_id: id, posting_seq: 1, cause: 'receipt', legs, ...over }) as MovementRow

describe('M1 balance history model', () => {
  it('sends all five slots, null as the empty string', () => {
    expect(slotParams(ROW)).toEqual({ sku: 'i1', location: 'l1', org_unit: 'u1', responsible: '', lot: '' })
    expect(slotParams({ ...ROW, responsible: 'e1', lot: 't1' })).toMatchObject({ responsible: 'e1', lot: 't1' })
  })

  it('matches null with empty and never a masked or other leg', () => {
    expect(legMatches(leg(), ROW)).toBe(true)
    expect(legMatches(leg({ responsible: '' }), ROW)).toBe(true)
    expect(legMatches(leg({ lot: 't1' }), ROW)).toBe(false)
    expect(legMatches(leg({ location: 'l2' }), ROW)).toBe(false)
    expect(legMatches(leg({ masked: true }), ROW)).toBe(false)
  })

  it('makes one line per matching leg, in/out by sign, zero neither', () => {
    const rows = [
      entry('a', [leg({ quantity: '10' })]),
      entry('b', [leg({ quantity: '-3', leg_no: 1 }), leg({ location: 'l2', quantity: '3', leg_no: 2 })], { posting_seq: 2, cause: 'transfer' }),
      entry('c', [leg({ quantity: '0.000' })], { posting_seq: 3 }),
    ]
    const lines = toHistoryLines(rows, ROW)
    expect(lines.map((l) => [l.key, l.isIn, l.isOut])).toEqual([
      ['a|1', true, false],
      ['b|1', false, true],
      ['c|1', false, false],
    ])
  })
})
