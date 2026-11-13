/** U1, U3 — T-1880 / D-135: the card action rule (every cell of the status x action table of docs/assets/card-actions.md)
 *  and the pre-fill of a document started from cards. Pure, no network. */
import { describe, expect, it } from 'vitest'
import { CARD_ACTIONS, cardActionState, cardHref, cardStatus, newDocumentHref, selectionActionState, type CardActionId, type CardActionState, type CardFacts } from '../cardActions'
import { assetParams, prefillForm } from '../cardPrefill'
import type { AssetBalanceRow } from '../register/assetRegister.api'

const row = (over: Partial<AssetBalanceRow> = {}): AssetBalanceRow => ({
  asset: 'c-1', org_unit: 'u-1', location: 'l-1', material_responsible: 'e-1', actual_user: 'e-2', unit_ref: 'pcs', quantity: '1.000000000', ...over,
})
const facts = (over: Partial<CardFacts> = {}): CardFacts => ({ active: true, kind: 'fixed', held: false, rows: [], canRead: true, ...over })
const IDS: CardActionId[] = ['commission', 'change', 'handover', 'writeoff']
const R = 'assets.cardActions.reason.'
const no = (r: string): CardActionState => ({ allowed: false, reasonId: R + r })
const yes: CardActionState = { allowed: true }

describe('U1 status x action', () => {
  const cases: [string, CardFacts, ReturnType<typeof cardActionState>[]][] = [
    ['retired', facts({ active: false, rows: [row()] }), [no('retired'), no('retired'), no('retired'), no('retired')]],
    ['new (never commissioned)', facts(), [yes, no('notInRegister'), no('notInRegister'), no('notInRegister')]],
    ['held_pending (issued, not posted)', facts({ held: true }), [no('held'), no('pendingPosting'), no('pendingPosting'), no('pendingPosting')]],
    ['in_register, fixed', facts({ held: true, rows: [row()] }), [no('held'), yes, yes, yes]],
    ['in_register, intangible', facts({ kind: 'intangible', held: true, rows: [row()] }), [no('held'), yes, yes, yes]],
    ['in_register, fixed, held read as false (stale lock)', facts({ held: false, rows: [row()] }), [yes, yes, yes, yes]],
    ['in_register, held unknown (older server)', facts({ held: undefined, rows: [row()] }), [yes, yes, yes, yes]],
    ['in_register, low value', facts({ kind: 'low_value', held: true, rows: [row(), row({ org_unit: 'u-2' })] }), [yes, yes, yes, yes]],
    ['no AssetsRead', facts({ canRead: false, rows: undefined }), [no('noRead'), no('noRead'), no('noRead'), no('noRead')]],
    ['facts still loading', facts({ rows: undefined, held: undefined }), [no('loading'), no('loading'), no('loading'), no('loading')]],
    ['a read failed', facts({ rows: undefined, held: undefined, failed: true }), [no('noRead'), no('noRead'), no('noRead'), no('noRead')]],
  ]
  for (const [name, f, expected] of cases) {
    it(name, () => expect(IDS.map((id) => cardActionState(id, f))).toEqual(expected))
  }

  it('derives the status in the documented order', () => {
    expect(cardStatus(facts({ active: false }))).toBe('retired')
    expect(cardStatus(facts({ held: true }))).toBe('held_pending')
    expect(cardStatus(facts({ kind: 'low_value', held: true }))).toBe('new')
    expect(cardStatus(facts({ rows: [row()] }))).toBe('in_register')
    expect(cardStatus(facts({ canRead: false }))).toBe('unknown')
  })

  it('lists exactly the four document kinds, all behind AssetsPost, and names no role', () => {
    expect(CARD_ACTIONS.map((a) => [a.id, a.kind, a.permission])).toEqual(IDS.map((id) => [id, id, 'AssetsPost']))
  })

  it('builds the addresses', () => {
    expect(newDocumentHref('change', ['c-1'])).toBe('/admin/assets/documents/new?kind=change&asset=c-1')
    expect(newDocumentHref('kind_change', [])).toBe('/admin/assets/documents/new?kind=kind_change')
    expect(cardHref('c 1')).toBe('/admin/assets/cards?card=c+1')
  })
})

describe('U3 pre-fill', () => {
  const fixed = { id: 'c-1', kind: 'fixed', orgUnitId: '' }
  const T = '2026-11-13T10:00'
  it('commission: one line of 1; the unit of the card when all cards share one', () => {
    const { form, manyHolders } = prefillForm('commission', [{ ...fixed, orgUnitId: 'u-9' }], {}, T)
    expect(form.lines).toEqual([{ assetId: 'c-1', quantity: '1' }])
    expect(form.from.orgUnitId).toBe('u-9')
    expect(form.from.locationId).toBe('')
    expect(manyHolders).toBe(false)
    expect(prefillForm('commission', [fixed], {}, T).form.from.orgUnitId).toBe('')
    expect(prefillForm('commission', [{ ...fixed, orgUnitId: 'a' }, { id: 'c-2', kind: 'fixed', orgUnitId: 'b' }], {}, T).form.from.orgUnitId).toBe('')
  })
  it('change and write off: the From side is the single holder row', () => {
    for (const kind of ['change', 'writeoff'] as const) {
      const { form, manyHolders } = prefillForm(kind, [fixed], { 'c-1': [row()] }, T)
      expect(form.from).toEqual({ orgUnitId: 'u-1', locationId: 'l-1', responsibleId: 'e-1', userId: 'e-2' })
      expect(form.to).toEqual({ orgUnitId: '', locationId: '', responsibleId: '', userId: '' })
      expect(form.lines).toEqual([{ assetId: 'c-1', quantity: '1' }])
      expect(manyHolders).toBe(false)
    }
  })
  it('hand over: To unit and place copy From, To people stay empty', () => {
    const { form } = prefillForm('handover', [fixed], { 'c-1': [row()] }, T)
    expect(form.to).toEqual({ orgUnitId: 'u-1', locationId: 'l-1', responsibleId: '', userId: '' })
  })
  it('a low value card takes the quantity of its holder row', () => {
    const { form } = prefillForm('change', [{ id: 'c-2', kind: 'low_value', orgUnitId: '' }], { 'c-2': [row({ quantity: '12.500000000' })] }, T)
    expect(form.lines).toEqual([{ assetId: 'c-2', quantity: '12.5' }])
  })
  it('several holder rows: lines filled, header empty, manyHolders', () => {
    const card = { id: 'c-2', kind: 'low_value', orgUnitId: '' }
    const { form, manyHolders } = prefillForm('handover', [card], { 'c-2': [row(), row({ org_unit: 'u-2' })] }, T)
    expect(manyHolders).toBe('card')
    expect(form.lines).toEqual([{ assetId: 'c-2', quantity: '1' }])
    expect(form.from.orgUnitId).toBe('')
    expect(form.to.orgUnitId).toBe('')
  })
  it('an unknown card keeps its line with quantity 1 and no header', () => {
    const { form } = prefillForm('change', [{ id: 'zz', kind: '', orgUnitId: '' }], {}, T)
    expect(form.lines).toEqual([{ assetId: 'zz', quantity: '1' }])
    expect(form.from.orgUnitId).toBe('')
  })
  it('kind_change ignores the cards', () => {
    const { form } = prefillForm('kind_change', [fixed], { 'c-1': [row()] }, T)
    expect(form.lines).toEqual([{ assetId: '', quantity: '1' }])
  })
  it('assetParams: drops empty and repeated values, caps at 100', () => {
    const p = new URLSearchParams('asset=a&asset=&asset=a&asset=b')
    expect(assetParams(p)).toEqual(['a', 'b'])
    const many = new URLSearchParams(Array.from({ length: 130 }, (_, i) => `asset=c${i}`).join('&'))
    expect(assetParams(many)).toHaveLength(100)
  })
})

describe('S1 selectionActionState', () => {
  it('all allowed → allowed', () => {
    const items = [
      { number: 'FA-1', facts: facts({ held: true, rows: [row()] }) },
      { number: 'FA-5', facts: facts({ held: true, rows: [row()] }) },
    ]
    expect(selectionActionState('change', items)).toEqual({ allowed: true })
    expect(selectionActionState('commission', items)).toEqual({ allowed: false, reasonId: R + 'held', number: 'FA-1' })
  })
  it('first blocker in list order', () => {
    const items = [
      { number: 'FA-5', facts: facts({ held: true, rows: [row()] }) },
      { number: 'FA-3', facts: facts({ held: false, rows: [] }) },
    ]
    expect(selectionActionState('change', items)).toEqual({ allowed: false, reasonId: R + 'notInRegister', number: 'FA-3' })
    expect(selectionActionState('commission', items)).toEqual({ allowed: false, reasonId: R + 'held', number: 'FA-5' })
  })
  it('empty list → noneSelected', () => {
    expect(selectionActionState('change', [])).toEqual({ allowed: false, reasonId: 'assets.cardActions.reason.noneSelected', number: '' })
  })
  it('one loading → loading', () => {
    const items = [
      { number: 'FA-1', facts: facts({ rows: undefined, held: undefined }) },
      { number: 'FA-5', facts: facts({ held: true, rows: [row()] }) },
    ]
    expect(selectionActionState('change', items)).toEqual({ allowed: false, reasonId: R + 'loading', number: 'FA-1' })
  })
  it('manyHolders: cards variant when multiple cards differ', () => {
    const T2 = '2026-11-13T10:00'
    const c1 = { id: 'c-1', kind: 'fixed', orgUnitId: '' }
    const c2 = { id: 'c-2', kind: 'fixed', orgUnitId: '' }
    const { manyHolders } = prefillForm('change', [c1, c2], { 'c-1': [row()], 'c-2': [row({ org_unit: 'u-2' })] }, T2)
    expect(manyHolders).toBe('cards')
  })
})
