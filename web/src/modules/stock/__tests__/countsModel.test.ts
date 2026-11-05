/** M1–M4 — GH 3735 / REQ-702: pure helpers of the count screens. */
import { describe, expect, it } from 'vitest'
import { COUNT_CONFLICTS, COUNT_REASONS, canIssueDifferences, canIssuePostingRecord, canPost, canReverse, canSignDifferences, canSignSheet, paperworkAvailable, parseFilename, requiredSigners, buildOrderBody, formatInZone, isDecimalNonNegative, reasonMessageId, zonedToIso, isoToLocalInput, EMPTY_ORDER_FORM } from '../counts/countsModel'
import type { CountOrder } from '../counts/counts.api'
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
    expect(COUNT_REASONS).toHaveLength(37)
    for (const r of COUNT_REASONS) expect(reasonMessageId({ status: 422, details: { reason: r } })).toBe(`counts.reason.${r}`)
    expect(reasonMessageId({ status: 422, details: { reason: 'new_thing' } })).toBe('counts.error.generic')
    // REQ-718: the 409 reasons of the posting routes have their own messages; a 409 with another reason is generic
    for (const r of COUNT_CONFLICTS) expect(reasonMessageId({ status: 409, details: { reason: r } })).toBe(`counts.reason.${r}`)
    expect(reasonMessageId({ status: 409, details: { reason: 'new_thing' } })).toBe('counts.error.generic')
    expect(reasonMessageId({ status: 422, details: { reason: 'count_not_posted' } })).toBe('counts.reason.count_not_posted')
    expect(reasonMessageId({ status: 403 })).toBe('counts.error.forbidden')
    expect(reasonMessageId({ status: 404 })).toBe('counts.error.notFound')
    expect(reasonMessageId(new Error('x'))).toBe('counts.error.generic')
  })
  it('has a message for every reason in every language', () => {
    for (const cat of [countsEn, countsRu, countsKk]) {
      for (const r of [...COUNT_REASONS, ...COUNT_CONFLICTS]) expect(cat[`counts.reason.${r}`]?.trim()).toBeTruthy()
    }
  })
})

describe('M5 REQ-720 helpers', () => {
  const o: CountOrder = { id: 'c', org_unit_id: 'u', kind: 'full', status: 'counted', planned_start: null, planned_end: null, chair_employee_id: 'e1', member_employee_ids: ['e2', 'e1'], location_ids: [], note: null }
  it('requiredSigners: chair, members, responsibles once each; no chair row without a chair', () => {
    const lines = [{ responsible_employee_id: 'e2' }, { responsible_employee_id: 'e4' }, { responsible_employee_id: null }, { responsible_employee_id: 'e4' }]
    expect(requiredSigners(o, lines)).toEqual([
      { id: 'e1', role: 'chair' }, { id: 'e2', role: 'member' }, { id: 'e4', role: 'responsible' },
    ])
    expect(requiredSigners({ ...o, chair_employee_id: null, member_employee_ids: [] }, [])).toEqual([])
  })
  it('parseFilename reads filename, filename* and falls back', () => {
    expect(parseFilename('attachment; filename="a b.xlsx"', 'f.xlsx')).toBe('a b.xlsx')
    expect(parseFilename("attachment; filename*=UTF-8''%D0%B0.xlsx", 'f.xlsx')).toBe('а.xlsx')
    expect(parseFilename(null, 'f.xlsx')).toBe('f.xlsx')
    expect(parseFilename('attachment', 'f.xlsx')).toBe('f.xlsx')
  })
  it('paperworkAvailable and the can* helpers follow the order fields', () => {
    const rec = () => true
    expect(paperworkAvailable({ ...o, member_employee_ids: [] }, 'sheet')).toBe(false)
    expect(paperworkAvailable({ ...o, member_employee_ids: [], sheet_document_id: 'd' }, 'sheet')).toBe(true)
    expect(canSignSheet({ ...o, member_employee_ids: [] }, rec)).toBe(true)
    expect(canSignSheet({ ...o, member_employee_ids: [], sheet_signed_at: 'x' }, rec)).toBe(false)
    expect(canIssueDifferences({ ...o, member_employee_ids: [], sheet_signed_at: 'x' }, rec)).toBe(true)
    expect(canSignDifferences({ ...o, member_employee_ids: [], differences_document_id: 'd' }, rec)).toBe(true)
    expect(canSignDifferences({ ...o, member_employee_ids: [], differences_document_id: 'd' }, () => false)).toBe(false)
  })
})

describe('M6 REQ-718 posting buttons', () => {
  const signed: CountOrder = { id: 'c', org_unit_id: 'u', kind: 'full', status: 'signed', planned_start: null, planned_end: null, chair_employee_id: 'e1', member_employee_ids: [], location_ids: [], note: null, differences_document_id: 'd', posting_state: 'none' }
  const only = (atom: string) => (p: string) => p === atom
  it('canPost: StockPost, signed, nothing posted, a differences sheet', () => {
    expect(canPost(signed, only('StockPost'))).toBe(true)
    expect(canPost(signed, only('StockRead'))).toBe(false)
    expect(canPost({ ...signed, posting_state: 'pending' }, only('StockPost'))).toBe(false)
    expect(canPost({ ...signed, posting_state: 'posted' }, only('StockPost'))).toBe(false)
    expect(canPost({ ...signed, status: 'counted' }, only('StockPost'))).toBe(false)
    expect(canPost({ ...signed, differences_document_id: null }, only('StockPost'))).toBe(false)
  })
  it('canReverse: StockReverse, posted, no reversal waiting', () => {
    const posted = { ...signed, posting_state: 'posted' as const }
    expect(canReverse(posted, only('StockReverse'))).toBe(true)
    expect(canReverse(posted, only('StockPost'))).toBe(false)
    expect(canReverse({ ...posted, reverse_pending: true }, only('StockReverse'))).toBe(false)
    expect(canReverse(signed, only('StockReverse'))).toBe(false)
    expect(canReverse({ ...posted, posting_state: 'reversed' }, only('StockReverse'))).toBe(false)
  })
  it('canIssuePostingRecord: StockCountRecord, signed + posted, no record yet', () => {
    const posted = { ...signed, posting_state: 'posted' as const }
    expect(canIssuePostingRecord(posted, only('StockCountRecord'))).toBe(true)
    expect(canIssuePostingRecord({ ...posted, posting_document_id: 'p' }, only('StockCountRecord'))).toBe(false)
    expect(canIssuePostingRecord({ ...posted, status: 'posted' }, only('StockCountRecord'))).toBe(false)
    expect(canIssuePostingRecord(signed, only('StockCountRecord'))).toBe(false)
  })
  it('W1 canIssuePostingRecord: a signed empty sheet with no pending post can be closed', () => {
    const empty = { ...signed, posting_state: 'none' as const, differences_empty: true, post_pending: false }
    expect(canIssuePostingRecord(empty, only('StockCountRecord'))).toBe(true)
    expect(canIssuePostingRecord(empty, only('StockPost'))).toBe(false)
    expect(canIssuePostingRecord({ ...empty, post_pending: true }, only('StockCountRecord'))).toBe(false)
    expect(canIssuePostingRecord({ ...empty, posting_document_id: 'p' }, only('StockCountRecord'))).toBe(false)
    expect(canIssuePostingRecord({ ...empty, differences_empty: false }, only('StockCountRecord'))).toBe(false)
    expect(canIssuePostingRecord({ ...empty, posting_state: 'reversed' }, only('StockCountRecord'))).toBe(false)
  })
})
