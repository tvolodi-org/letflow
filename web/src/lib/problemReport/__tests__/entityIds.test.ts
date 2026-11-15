// @vitest-environment jsdom
import { describe, expect, it } from 'vitest'
import { buildReportBody, extractEntityIds } from '../payload'

describe('extractEntityIds (SR-1)', () => {
  it('takes a uuid path segment, named by the segment before it', () => {
    const id = '0b9e4c1a-1111-4222-8333-444455556666'
    expect(extractEntityIds(`/stock/documents/${id}`, '')).toEqual({ documents: id })
  })
  it('takes query ids and skips non-id values', () => {
    expect(extractEntityIds('/assets', '?card_id=abc123&cardId=x&q=hello&id=a%20b')).toEqual({ card_id: 'abc123' })
  })
  it('returns nothing for a route without ids', () => {
    expect(extractEntityIds('/tasks', '')).toEqual({})
  })
  it('sends entity_ids in the built payload', () => {
    const id = '0b9e4c1a-1111-4222-8333-444455556666'
    window.history.pushState({}, '', `/stock/documents/${id}`)
    const body = buildReportBody('x', { actions: [], requests: [] }, { uiLanguage: 'en' })
    expect(body.context.entity_ids).toEqual({ documents: id })
    expect(body.context.route).toContain(':id')
  })
})
