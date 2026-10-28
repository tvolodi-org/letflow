import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('@/api/client', () => ({
  client: { get: vi.fn(async () => ({})), post: vi.fn(async () => ({})) },
}))

import { client } from '@/api/client'
import {
  describePrintOverrideError,
  documentPrintOverridesApi as api,
  isValidReasonCode,
} from '@/api/documentPrintOverrides'

const BASE = '/api/v1/documents/print-overrides'

beforeEach(() => vi.clearAllMocks())

describe('REQ-614 A1 documentPrintOverridesApi', () => {
  it('list passes filters', async () => {
    await api.list({ type_key: 'invoice', locale: 'ru' })
    expect(client.get).toHaveBeenCalledWith(BASE, { type_key: 'invoice', locale: 'ru' })
  })

  it('get encodes the id', async () => {
    await api.get('a/b')
    expect(client.get).toHaveBeenCalledWith(`${BASE}/a%2Fb`)
  })

  it('save sends exactly type_key, locale, layout', async () => {
    await api.save({ type_key: 'invoice', locale: 'kk', layout: { blocks: [] }, extra: 1 } as never)
    expect(client.post).toHaveBeenCalledWith(BASE, { type_key: 'invoice', locale: 'kk', layout: { blocks: [] } })
    const body = vi.mocked(client.post).mock.calls[0][1] as Record<string, unknown>
    expect(Object.keys(body).sort()).toEqual(['layout', 'locale', 'type_key'])
  })

  it('activate and retire send exactly reason_code', async () => {
    await api.activate('x1', 'ok_code')
    await api.retire('x1', 'done_1')
    expect(client.post).toHaveBeenNthCalledWith(1, `${BASE}/x1/activate`, { reason_code: 'ok_code' })
    expect(client.post).toHaveBeenNthCalledWith(2, `${BASE}/x1/retire`, { reason_code: 'done_1' })
  })
})

describe('reason code and error mapper', () => {
  it('validates reason codes', () => {
    for (const bad of ['Bad', '1x', '', 'a'.repeat(65), 'a-b']) expect(isValidReasonCode(bad)).toBe(false)
    expect(isValidReasonCode('ok_code1')).toBe(true)
    expect(isValidReasonCode('a'.repeat(64))).toBe(true)
  })

  it('maps statuses to safe text', () => {
    expect(
      describePrintOverrideError({ status: 422, message: 'layout failed validation', details: [{ rule: 'unknown_key', path: ['blocks', 1, 'x', '_key'] }, 5] }),
    ).toEqual(['unknown_key at blocks[1].x._key'])
    expect(describePrintOverrideError({ status: 409, details: { detail: 'second administrator' } })).toEqual(['second administrator'])
    expect(describePrintOverrideError({ status: 404 })).toEqual(['Not found'])
    expect(describePrintOverrideError({ status: 500, message: 'SECRET', details: { detail: 'SECRET' } })).toEqual([
      'Something went wrong. Try again.',
    ])
    expect(describePrintOverrideError(new Error('SECRET'))).toEqual(['Something went wrong. Try again.'])
  })
})
