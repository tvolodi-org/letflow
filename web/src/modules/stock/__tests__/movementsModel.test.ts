/** S1–S6 — T-1422 (GATE B R12): status, quantity cell and document text of the movement rows. */
import { describe, expect, it } from 'vitest'
import { absQuantity, documentText, signOf, statusOf, toJournalOps, type MovementsMapContext } from '../register/movementsModel'
import type { MovementLeg, MovementRow } from '../register/stock.api'

const NAMES: Record<string, string> = { i1: 'ITM-1 - Bolt', i2: 'ITM-2 - Nut', l1: 'WH - Main', l2: 'DOCK - Dock', m1: 'pcs' }
const MSG: Record<string, string> = {
  'stock.journal.lines': '{n} lines', 'stock.journal.status.posted': 'Posted', 'stock.journal.status.reversed': 'Reversed',
  'stock.journal.status.reversal': 'Reversal', 'stock.journal.reversalOf': 'Reversal of {d}', 'stock.journal.reversedBy': 'Reversed by {d}',
  'stock.docType.stock_receipt': 'Receipt', 'stock.cause.receipt': 'Receipt', 'stock.cause.transfer': 'Transfer',
}
const ctx: MovementsMapContext = {
  name: (_t, id) => (id ? NAMES[id] ?? '' : ''),
  t: (id, v) => (MSG[id] ?? id).replace(/\{(\w+)\}/g, (_m, k) => String(v?.[k])),
  when: (iso) => iso ?? '-',
  kindIcon: () => null,
}
const leg = (n: number, q: string, over: Partial<MovementLeg> = {}): MovementLeg => ({ leg_no: n, quantity: q, unit_ref: 'm1', sku: 'i1', location: 'l1', ...over })
const row = (id: string, legs: MovementLeg[], over: Partial<MovementRow> = {}): MovementRow => ({ entry_id: id, posting_seq: 1, cause: 'receipt', legs, ...over })

describe('S1-S3 status', () => {
  it('reversal when it points at an entry; reversed when a loaded row points at it; else posted', () => {
    const a = row('a', [leg(1, '5')], { document_number: 'RCP-1' })
    const r = row('r', [leg(1, '-5')], { reverses_entry_id: 'a', document_number: 'REV-1' })
    expect(statusOf(a, [a, r])).toBe('reversed')
    expect(statusOf(r, [a, r])).toBe('reversal')
    expect(statusOf(a, [a])).toBe('posted')
    const ops = toJournalOps([r, a], ctx)
    expect(ops[0].statusNote).toBe('Reversal of RCP-1')
    expect(ops[1].statusNote).toBe('Reversed by REV-1')
    expect(toJournalOps([a], ctx)[0].statusNote).toBe('')
  })
})

describe('S4-S6 quantity cell', () => {
  it('S4 single item: signed total with unit', () => {
    expect(toJournalOps([row('a', [leg(1, '12.500000000')])], ctx)[0]).toMatchObject({ qty: '12.5 pcs', qtySign: 'pos' })
    expect(toJournalOps([row('a', [leg(1, '-3')])], ctx)[0]).toMatchObject({ qty: '3 pcs', qtySign: 'neg' })
  })
  it('S5 a move between places has no sign and shows the item once', () => {
    const o = toJournalOps([row('a', [leg(1, '-5'), leg(2, '5', { location: 'l2' })])], ctx)[0]
    expect(o).toMatchObject({ qty: '5 pcs', qtySign: '', item: 'ITM-1 - Bolt', itemMore: 0 })
  })
  it('S6 several items: "n lines" and the +n count', () => {
    const o = toJournalOps([row('a', [leg(1, '2'), leg(2, '3', { sku: 'i2' })])], ctx)[0]
    expect(o).toMatchObject({ qty: '2 lines', itemMore: 1 })
  })
  it('masked leg: quantity and unit only, no names', () => {
    const o = toJournalOps([row('a', [{ leg_no: 1, quantity: '-4', unit_ref: 'm1', masked: true }])], ctx)[0]
    expect(o.legs[0]).toMatchObject({ hidden: true, location: '', item: '', qty: '4 pcs', sign: 'neg' })
    expect(o.item).toBe('')
  })
})

describe('J3-7 location column', () => {
  it('first place, +n for the other places, empty when masked', () => {
    expect(toJournalOps([row('a', [leg(1, '2')])], ctx)[0]).toMatchObject({ location: 'WH - Main', locationMore: 0 })
    const two = toJournalOps([row('a', [leg(1, '-2'), leg(2, '2', { location: 'l2' })])], ctx)[0]
    expect(two).toMatchObject({ location: 'WH - Main', locationMore: 1 })
    const same = toJournalOps([row('a', [leg(1, '2'), leg(2, '3', { sku: 'i2' })])], ctx)[0]
    expect(same).toMatchObject({ location: 'WH - Main', locationMore: 0 })
    const m = toJournalOps([row('a', [{ leg_no: 1, quantity: '-4', unit_ref: 'm1', masked: true }])], ctx)[0]
    expect(m).toMatchObject({ location: '', locationMore: 0 })
  })
})

describe('helpers', () => {
  it('signOf / absQuantity / documentText', () => {
    expect(signOf('-0.000')).toBe('')
    expect(signOf('-1')).toBe('neg')
    expect(absQuantity('-12.5000')).toBe('12.5')
    expect(documentText(row('a', [], { document_type: 'stock_receipt', document_number: 'RCP-2026-000001' }), ctx.t)).toBe('RCP-2026-000001 - Receipt')
    expect(documentText(row('a', [], { document_type: 'stock_receipt' }), ctx.t)).toBe('Receipt')
    expect(documentText(row('a', []), ctx.t)).toBe('')
  })
})
