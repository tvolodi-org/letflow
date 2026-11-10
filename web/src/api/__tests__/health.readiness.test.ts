import { afterEach, describe, expect, it, vi } from 'vitest'
import { client } from '@/api/client'
import { backupStatus, readiness } from '@/api/health'

describe('readiness() (T-1607)', () => {
  afterEach(() => vi.restoreAllMocks())

  it('W1-7: reads the JSON body of a 503 and keeps the failing part', async () => {
    vi.spyOn(client, 'getPublic').mockResolvedValue({
      status: 503,
      body: {
        status: 'not_ready',
        failing: ['identity'],
        checks: { database: 'ok', migrations: 'ok', secrets_key: 'ok', identity: 'fail' },
      },
    })
    const result = await readiness()
    expect(result.ready).toBe(false)
    expect(result.parts.filter((p) => !p.ok).map((p) => p.part)).toEqual(['identity'])
  })

  it('W1-8: a 200 with all parts ok is ready', async () => {
    vi.spyOn(client, 'getPublic').mockResolvedValue({
      status: 200,
      body: { status: 'ready', checks: { database: 'ok', migrations: 'ok', secrets_key: 'ok', identity: 'ok' } },
    })
    expect((await readiness()).ready).toBe(true)
  })

  it('W1-9: a 404 or a body that is not the readiness shape rejects (older server)', async () => {
    vi.spyOn(client, 'getPublic').mockResolvedValue({ status: 404, body: { status: 404 } })
    await expect(readiness()).rejects.toThrow()
  })

  it('W1-10: backupStatus() calls the platform-status route', async () => {
    const get = vi.spyOn(client, 'get').mockResolvedValue({ configured: false, jobs: [] })
    await backupStatus()
    expect(get).toHaveBeenCalledWith('/api/v1/platform-status/backup')
  })
})
