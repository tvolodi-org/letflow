/** M1–M4 — GH 3735 / REQ-702: pure helpers of the count screens. */
import { describe, expect, it } from 'vitest'
import { COUNT_REASONS, buildOrderBody, formatInZone, isDecimalNonNegative, reasonMessageId, zonedToIso, isoToLocalInput, EMPTY_ORDER_FORM } from '../counts/countsModel'
import { countsEn, countsKk, countsRu } from '../counts/countsMessages'

describe('M1 isDecimalNonNegative', () => {
  it.each(['0', '0.5', '12', '3.250', '007'])('accepts %s', (s) => expect(isDecimalNonNegative(s)).toBe(true))
  it.each(['-1', '1e3', '1,5', ' ', '', 'abc', '1.', '.5', '+2', '1 2'])('refuses "%s"', (s) => expect(isDecimalNonNegative(s)).toBe(false))
})

describe('M2 tenant zone', () => {
  it('converts local input to an offset ISO string and back (Asia/Almaty, UTC+5)', () => {
    expect(zonedToIso('2026-11-10T09:30')).toBe('2026-11-10T09:30:00+05:00')
    expect(zonedToIso('')).toBe('')
    expect(formatInZone('2026-11-10T04:30:00Z')).toBe('2026-11-10 09:30')
    expect(isoToLocalInput('2026-11-10T04:30:00Z')).toBe('2026-11-10T09:30')
    expect(formatInZone(null)).toBe('')
  })
})

describe('M3 buildOrderBody', () => {
  it('has exactly the eight keys of the draft and sends an empty note as null', () => {
    const body = buildOrderBody({ ...EMPTY_ORDER_FORM, org_unit_id: 'u1', planned_start: '2026-11-10T09:00', planned_end: '2026-11-11T09:00', chair_employee_id: 'e1', location_ids: ['l1'], note: '  ' })
    expect(Object.keys(body).sort()).toEqual(['chair_employee_id', 'kind', 'location_ids', 'member_employee_ids', 'note', 'org_unit_id', 'planned_end', 'planned_start'])
    expect(body.note).toBeNull()
    expect(buildOrderBody({ ...EMPTY_ORDER_FORM, note: 'x' }).note).toBe('x')
  })
})

describe('M4 reasonMessageId', () => {
  it('maps each reason, forbidden, not found and unknown', () => {
    expect(COUNT_REASONS).toHaveLength(19)
    for (const r of COUNT_REASONS) expect(reasonMessageId({ status: 422, details: { reason: r } })).toBe(`counts.reason.${r}`)
    expect(reasonMessageId({ status: 422, details: { reason: 'new_thing' } })).toBe('counts.error.generic')
    expect(reasonMessageId({ status: 403 })).toBe('counts.error.forbidden')
    expect(reasonMessageId({ status: 404 })).toBe('counts.error.notFound')
    expect(reasonMessageId(new Error('x'))).toBe('counts.error.generic')
  })
  it('has a message for every reason in every language', () => {
    for (const cat of [countsEn, countsRu, countsKk]) for (const r of COUNT_REASONS) expect(cat[`counts.reason.${r}`]?.trim()).toBeTruthy()
  })
})
