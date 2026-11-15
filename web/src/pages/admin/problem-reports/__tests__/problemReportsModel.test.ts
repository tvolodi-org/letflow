/** T-2007: pure rules of the owner inbox. PR-U1 statuses and actions, PR-U2 text checks, PR-U3 error kinds, PR-U4 facts. */
import { describe, expect, it } from 'vitest'
import type { InboxDetail } from '@/api/platformProblemReports'
import { ACTIONS, STATUS_LOOK, checkDecisionText, decisionErrorKind, isOpen, normalizeFilter, reportFacts } from '../problemReportsModel'

const detail = (over: Partial<InboxDetail> = {}): InboxDetail => ({
  id: 'r1', number: 'SR-14', class: 'problem', status: 'received', last_action: null,
  received_at: '2026-11-15T09:00:00Z', decided_at: null, decided_by_user_id: 'decider-uuid',
  reporter: { tenant_id: 'tenant-uuid', tenant_name: 'Acme', user_id: 'user-uuid', name: 'Aida', roles: ['role-a', 'role-b'], permissions: ['A', 'B'] },
  text: 'It broke', server_version: '1.4.0', trace_id: 'tr-1', reply_text: null, dev_summary: null,
  context: {
    route: '/admin/assets', ui_language: 'ru',
    browser: { user_agent: 'UA/1', viewport: '1440x900', language: 'ru-RU' },
    actions: [{ at: 't1', kind: 'click', name: 'Save' }],
    requests: [{ at: 't2', method: 'POST', path: '/api/x', status: 500, error_code: 'boom', trace_id: 'tr-2' }],
    crash: { name: 'TypeError', message: 'x is undefined' },
  },
  ...over,
})

describe('PR-U1 statuses and actions', () => {
  it('covers the five statuses; only received and in_work are open; answer is last', () => {
    expect(Object.keys(STATUS_LOOK).sort()).toEqual(['answered', 'fixed', 'in_work', 'not_done', 'received'])
    expect(isOpen('received')).toBe(true)
    expect(isOpen('in_work')).toBe(true)
    for (const s of ['answered', 'fixed', 'not_done', 'something_new']) expect(isOpen(s)).toBe(false)
    expect(ACTIONS[ACTIONS.length - 1]).toBe('answer')
    expect([...ACTIONS].sort()).toEqual(['answer', 'ask', 'develop', 'fixed', 'reject'])
    expect(normalizeFilter('closed')).toBe('closed')
    expect(normalizeFilter('bogus')).toBe('open')
    expect(normalizeFilter(null)).toBe('open')
  })
})

describe('PR-U2 checkDecisionText', () => {
  it('refuses empty text except for fixed', () => {
    for (const a of ['answer', 'ask', 'reject', 'develop'] as const) {
      expect(checkDecisionText(a, '')).toBe('empty')
      expect(checkDecisionText(a, '   \n')).toBe('empty')
    }
    expect(checkDecisionText('fixed', '  ')).toBe('ok')
  })
  it('counts code points: develop 2000, answer 4000', () => {
    const astral = '\u{1D538}'
    expect(checkDecisionText('develop', astral.repeat(2000))).toBe('ok')
    expect(checkDecisionText('develop', astral.repeat(2001))).toBe('tooLong')
    expect(checkDecisionText('answer', 'a'.repeat(4000))).toBe('ok')
    expect(checkDecisionText('answer', 'a'.repeat(4001))).toBe('tooLong')
  })
})

describe('PR-U3 decisionErrorKind', () => {
  it('maps every server answer', () => {
    expect(decisionErrorKind({ status: 409 })).toBe('closed')
    expect(decisionErrorKind({ status: 404 })).toBe('gone')
    expect(decisionErrorKind({ status: 503 })).toBe('unavailable')
    expect(decisionErrorKind({ status: 422, details: { detail: 'The summary must be in your own words, not a copy.' } })).toBe('copies')
    expect(decisionErrorKind({ status: 422, details: { detail: 'The text looks like it holds a secret.' } })).toBe('secret')
    expect(decisionErrorKind({ status: 422, details: { detail: 'other' } })).toBe('invalid')
    expect(decisionErrorKind({ status: 422 })).toBe('invalid')
    expect(decisionErrorKind({ status: 500 })).toBe('failed')
  })
})

describe('PR-U4 reportFacts', () => {
  it('builds the key facts, actions and requests', () => {
    const f = reportFacts(detail())
    const byId = Object.fromEntries(f.rows.map((r) => [r.id, r.value]))
    expect(byId.route).toBe('/admin/assets')
    expect(byId.browser).toBe('UA/1')
    expect(byId.viewport).toBe('1440x900')
    expect(byId.version).toBe('1.4.0')
    expect(byId.trace).toBe('tr-1')
    expect(byId.roles).toBe('role-a, role-b')
    expect(byId.error).toBe('TypeError: x is undefined')
    expect(f.actions).toEqual([{ at: 't1', kind: 'click', name: 'Save' }])
    expect(f.requests[0]).toMatchObject({ method: 'POST', status: '500', error_code: 'boom' })
  })
  it('shows an unknown context key generically (entity_ids)', () => {
    const d = detail()
    d.context = { ...(d.context as object), entity_ids: { document_id: 'abc' }, note: ['x'] }
    const rows = reportFacts(d).rows
    expect(rows.find((r) => r.name === 'document_id')?.value).toBe('abc')
    expect(rows.find((r) => r.name === 'note')?.value).toBe('["x"]')
  })
  it('never exposes tenant, user or decider ids', () => {
    const values = reportFacts(detail({ decided_at: '2026-11-15T10:00:00Z' })).rows.map((r) => r.value)
    for (const secret of ['tenant-uuid', 'user-uuid', 'decider-uuid', 'r1']) expect(values).not.toContain(secret)
  })
  it('survives a missing context', () => {
    const f = reportFacts(detail({ context: {} }))
    expect(f.actions).toEqual([])
    expect(f.requests).toEqual([])
    expect(() => reportFacts(detail({ context: null }))).not.toThrow()
  })
})
