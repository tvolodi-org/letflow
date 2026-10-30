import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('@/api/client', () => ({
  client: { post: vi.fn(async () => ({ module_id: 'exam', status: 'uninstalled' })) },
}))

import { client } from '@/api/client'
import { tenantModulesApi as api } from '@/api/tenantModules'

const BASE = '/api/v1/tenant/modules'

beforeEach(() => vi.clearAllMocks())

describe('REQ-630 A1-A4 tenantModulesApi', () => {
  it('A1 uninstall posts exactly {rationale}', async () => {
    await api.uninstall('exam', 'closing the pilot')
    expect(client.post).toHaveBeenCalledWith(`${BASE}/exam/uninstall`, { rationale: 'closing the pilot' })
    const body = vi.mocked(client.post).mock.calls[0][1] as Record<string, unknown>
    expect(Object.keys(body)).toEqual(['rationale'])
  })

  it('A2 reactivate posts exactly {rationale}', async () => {
    await api.reactivate('exam', 'pilot resumed')
    expect(client.post).toHaveBeenCalledWith(`${BASE}/exam/reactivate`, { rationale: 'pilot resumed' })
  })

  it('A3 encodes the module id', async () => {
    await api.uninstall('a/b', 'x')
    await api.reactivate('a/b', 'x')
    expect(vi.mocked(client.post).mock.calls.map((c) => c[0])).toEqual([`${BASE}/a%2Fb/uninstall`, `${BASE}/a%2Fb/reactivate`])
  })

  it('A4 carries no tenant identifier', async () => {
    await api.uninstall('exam', 'x')
    await api.reactivate('exam', 'x')
    for (const call of vi.mocked(client.post).mock.calls) {
      expect(Object.keys(call[1] as object).some((k) => /tenant|prefix/.test(k))).toBe(false)
    }
  })
})
