import { describe, it, expect } from 'vitest'
import { actionKind, ageText, classify, counts, matchesFilter } from '../taskInboxModel'
import { TASK_MESSAGES } from '../taskMessages'

const ME = '11111111-2222-4333-8444-555555555555'
const base = { status: 'PENDING' as const }

describe('taskInboxModel (T12)', () => {
  it('classifies own, open and other tasks', () => {
    expect(classify({ ...base, assignee_ref: ME, assignee_type: 'USER' }, ME)).toBe('mine')
    expect(classify({ ...base }, ME)).toBe('available')
    expect(classify({ ...base, assignee_ref: 'stock_keeper', assignee_type: 'ROLE' }, ME)).toBe('available')
    expect(classify({ ...base, assignee_ref: 'ops', assignee_type: 'GROUP' }, ME)).toBe('available')
    expect(classify({ ...base, assignee_ref: '66666666-7777-4888-8999-000000000000', assignee_type: 'USER' }, ME)).toBe('other')
    expect(classify({ status: 'COMPLETED', assignee_ref: 'r', assignee_type: 'ROLE' }, ME)).toBe('other')
  })
  it('filters and counts', () => {
    const tasks = [
      { ...base, assignee_ref: ME, assignee_type: 'USER' },
      { ...base },
      { ...base, assignee_ref: 'x-user', assignee_type: 'USER' },
    ]
    expect(tasks.filter((t) => matchesFilter(t, 'me', ME))).toHaveLength(2)
    expect(counts(tasks, ME)).toEqual({ me: 2, group: 1, all: 3 })
  })
  it('names the action', () => {
    expect(actionKind({ node_id: 'n1', node_name: 'post' })).toBe('post')
    expect(actionKind({ node_id: 'approve_doc', node_name: 'Approve' })).toBe('approve')
    expect(actionKind({ node_id: 'x', node_name: 'Reverse' })).toBe('reverse')
    expect(actionKind({ node_id: 'x', node_name: 'Check shipment' })).toBe('other')
  })
  it('writes the age', () => {
    const now = Date.parse('2026-11-05T12:00:00Z')
    expect(ageText('2026-11-05T11:57:00Z', now, 'en')).toBe('3 minutes ago')
    expect(ageText('2026-11-03T12:00:00Z', now, 'en')).toBe('2 days ago')
    expect(ageText(undefined, now, 'en')).toBe('')
  })
})

describe('task message catalog (T11)', () => {
  it('has the same keys in en, ru and kk', () => {
    const keys = (o: object, p = ''): string[] =>
      Object.entries(o).flatMap(([k, v]) => (typeof v === 'object' && v !== null ? keys(v, `${p}${k}.`) : [`${p}${k}`])).sort()
    expect(keys(TASK_MESSAGES.ru)).toEqual(keys(TASK_MESSAGES.en))
    expect(keys(TASK_MESSAGES.kk)).toEqual(keys(TASK_MESSAGES.en))
  })
})
