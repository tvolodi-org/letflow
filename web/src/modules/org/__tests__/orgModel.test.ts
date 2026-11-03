/** P1 — GH 3609 / REQ-669: the pure helpers. */
import { describe, expect, it } from 'vitest'
import { ORG_REASONS, binValid, buildUnitTree, descendantIds, errorMessageId, moveTargets, positionsOfUnit, reasonOf, unitOptions } from '../orgModel'
import { rec } from './orgTestKit'

const u = (id: string, code: string, parent?: string, active = true) =>
  ({ ...rec(id, 'org_unit', { code, ...(parent ? { parent } : {}) }), field_values: { code, active, ...(parent ? { parent } : {}) } })

const rows = [u('c', 'A1.1', 'b'), u('b', 'A1', 'a'), u('a', 'A'), u('z', 'B'), u('orphan', 'C', 'gone')]

describe('P1 orgModel', () => {
  it('buildUnitTree orders parents before children and sorts siblings by code', () => {
    const tree = buildUnitTree(rows)
    expect(tree.map((r) => [r.record.record_id, r.depth])).toEqual([
      ['a', 0], ['b', 1], ['c', 2], ['z', 0], ['orphan', 0],
    ])
  })

  it('descendantIds and moveTargets exclude the unit and its subtree and retired rows', () => {
    expect([...descendantIds(rows, 'a')].sort()).toEqual(['b', 'c'])
    const withRetired = [...rows, u('r', 'R', undefined, false)]
    expect(moveTargets(withRetired, 'a').map((r) => r.record_id).sort()).toEqual(['orphan', 'z'])
  })

  it('does not loop on a cycle in loaded data', () => {
    expect(buildUnitTree([u('x', 'X', 'y'), u('y', 'Y', 'x')])).toEqual([])
  })

  it('binValid wants exactly 12 digits', () => {
    expect(binValid('123456789012')).toBe(true)
    expect(binValid('12345678901')).toBe(false)
    expect(binValid('12345678901a')).toBe(false)
  })

  it('errorMessageId maps status and reason', () => {
    const e = (status: number, details?: Record<string, unknown>) => ({ status, details })
    expect(errorMessageId(e(403))).toBe('org.error.forbidden')
    expect(errorMessageId(e(404))).toBe('org.error.notFound')
    expect(errorMessageId(e(409, { reason: 'idempotency_key_reuse' }))).toBe('org.error.idempotency_key_reuse')
    expect(errorMessageId(e(409))).toBe('org.error.idempotency_key_reuse')
    for (const reason of ORG_REASONS) expect(errorMessageId(e(422, { reason }))).toBe(`org.error.${reason}`)
    expect(errorMessageId(e(422, { reason: 'something_new' }))).toBe('org.error.unknown')
    expect(errorMessageId(new Error('network'))).toBe('org.error.generic')
    expect(errorMessageId(e(404), { userLinked: true })).toBe('org.error.user_not_found')
    expect(errorMessageId(e(404), { userLinked: false })).toBe('org.error.notFound')
    expect(errorMessageId(e(403), { userLinked: true })).toBe('org.error.forbidden')
    expect(reasonOf(e(422, { reason: 'record_payload_invalid', fields: ['code', 3] })).fields).toEqual(['code'])
  })

  it('positionsOfUnit keeps the active positions of one unit', () => {
    const p = (id: string, unit: string, active = true) => ({ ...u(id, id), field_values: { org_unit_id: unit, active } })
    const ps = [p('p1', 'a'), p('p2', 'a', false), p('p3', 'b')]
    expect(positionsOfUnit(ps, 'a').map((r) => r.record_id)).toEqual(['p1'])
    expect(positionsOfUnit(ps, '')).toEqual([])
  })

  it('unitOptions indents by depth in tree order', () => {
    const opts = unitOptions([u('a', 'A'), u('b', 'B', 'a')])
    expect(opts.map((o) => o.value)).toEqual(['a', 'b'])
    expect(opts[1].label.startsWith('  ')).toBe(true)
    expect(opts[0].label.startsWith(' ')).toBe(false)
  })
})
