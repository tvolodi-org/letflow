// @vitest-environment jsdom
/**
 * T-1400 MG-01/MG-02: getOidcManager() hands every concurrent caller ONE manager.
 * Only fetchTenantConfig is mocked; the REAL getOidcManager runs (the old renewal tests
 * mocked getOidcManager itself, which is why the two-managers race was never seen).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { mockFetch, state } = vi.hoisted(() => ({ mockFetch: vi.fn(), state: { cached: true } }))

vi.mock('../tenantConfig', () => ({
  fetchTenantConfig: (...a: unknown[]) => mockFetch(...a),
  isTenantConfigCached: () => state.cached,
}))

import { buildOidcSettings, getOidcManager, resetOidcManager } from '../OidcManager'

const cfg = (realm: string) => ({ oidc_authority: `http://idp.test/realms/${realm}`, client_id: 'c' })

beforeEach(() => {
  mockFetch.mockReset()
  state.cached = true
  resetOidcManager()
})

afterEach(() => { vi.unstubAllGlobals() })

describe('getOidcManager', () => {
  it('W2 host-only and silent settings match the registered plain callback', () => {
    vi.stubGlobal('location', { origin: 'https://acme.demo.example.test' })
    expect(buildOidcSettings('https://auth.qa.bizdala.com/realms/t-0a1b2c3d4e5f4a6b8c7d', 'bpm-web').redirect_uri)
      .toBe('https://acme.demo.example.test/auth/callback')
  })

  it('MG-01: two concurrent calls (and a later one) resolve to the same manager', async () => {
    let resolve!: (v: unknown) => void
    mockFetch.mockReturnValue(new Promise(r => (resolve = r)))
    const a = getOidcManager()
    const b = getOidcManager()
    resolve(cfg('r'))
    const [ma, mb] = await Promise.all([a, b])
    expect(ma).toBe(mb)
    expect(await getOidcManager()).toBe(ma)
    expect(mockFetch).toHaveBeenCalledTimes(1)
  })

  it('MG-02: a failure fallback is shared by concurrent callers but not sticky', async () => {
    state.cached = false
    mockFetch.mockResolvedValueOnce(cfg('default'))
    const [a, b] = await Promise.all([getOidcManager(), getOidcManager()])
    expect(a).toBe(b)
    expect(a.settings.authority).toContain('/realms/default')

    state.cached = true
    mockFetch.mockResolvedValueOnce(cfg('real'))
    const c = await getOidcManager()
    expect(c).not.toBe(a)
    expect(c.settings.authority).toContain('/realms/real')
    expect(await getOidcManager()).toBe(c)
  })
})
