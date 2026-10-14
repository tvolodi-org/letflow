// @vitest-environment jsdom
/**
 * GH 2355 / ISS-1034 -- the REQ-463 distinct-person refusal body
 * {"detail":"separation of duties","status":403} maps to a worker-readable
 * message. Match is EXACT on `detail` (+ status 403); a `title` alongside it
 * does not change that (detail match wins, documented in test d).
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  client,
  clearToken,
  isSeparationOfDuties,
  SEPARATION_OF_DUTIES_MESSAGE,
} from '../client'

function stub(status: number, body: unknown, statusText = 'Forbidden'): void {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      ok: false,
      status,
      statusText,
      json: async () => body,
      headers: { get: () => null },
    }),
  )
}

async function failure(): Promise<unknown> {
  try {
    await client.post('/api/v1/tasks/t1/complete', {})
  } catch (e) {
    return e
  }
  throw new Error('expected rejection')
}

afterEach(() => {
  vi.unstubAllGlobals()
  clearToken()
})

describe('client separation-of-duties mapping', () => {
  it('(a) 403 with the exact backend body maps to the SoD message and code', async () => {
    stub(403, { detail: 'separation of duties', status: 403 })
    const err = await failure()
    expect(err).toMatchObject({
      status: 403,
      code: 'SEPARATION_OF_DUTIES',
      message: SEPARATION_OF_DUTIES_MESSAGE,
      details: { detail: 'separation of duties', status: 403 },
    })
    expect(isSeparationOfDuties(err)).toBe(true)
  })

  it('(b) plain 403 with title keeps message and code', async () => {
    stub(403, { title: 'Forbidden', status: 403 })
    const err = await failure()
    expect(err).toMatchObject({ status: 403, message: 'Forbidden', code: '403' })
    expect(isSeparationOfDuties(err)).toBe(false)
  })

  it.each(['separation of duties ', 'Separation of duties', 'separation of duties: x'])(
    '(c) detail %j is not mapped (exact match)',
    async (detail) => {
      stub(403, { detail, status: 403 })
      const err = await failure()
      expect(err).toMatchObject({ status: 403, message: 'Forbidden', code: '403' })
      expect(isSeparationOfDuties(err)).toBe(false)
    },
  )

  it('(d) exact detail plus a title still maps (detail match is what counts)', async () => {
    stub(403, { detail: 'separation of duties', title: 'Forbidden', status: 403 })
    const err = await failure()
    expect(err).toMatchObject({ code: 'SEPARATION_OF_DUTIES', message: SEPARATION_OF_DUTIES_MESSAGE })
  })

  it('(e) 500 with that detail is unchanged', async () => {
    stub(500, { detail: 'separation of duties' }, 'Internal Server Error')
    const err = await failure()
    expect(err).toMatchObject({ status: 500, message: 'Internal Server Error', code: '500' })
    expect(isSeparationOfDuties(err)).toBe(false)
  })

  it('guard rejects non-errors', () => {
    expect(isSeparationOfDuties(null)).toBe(false)
    expect(isSeparationOfDuties('x')).toBe(false)
    expect(isSeparationOfDuties({ status: 403, code: '403' })).toBe(false)
  })
})
