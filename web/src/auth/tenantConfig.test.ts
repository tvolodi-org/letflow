// @vitest-environment jsdom
/**
 * Unit tests for tenantConfig.ts — resolveRealmFromUrl pure-logic tests.
 *
 * Covers: OIDC-F-06
 * Test cases: TC-OIDC-F06-01, TC-OIDC-F06-02
 *
 * DIRECTIVE T-2 note: these tests cover a pure URL/sessionStorage utility function
 * with no HTTP calls. No backend is required and no HTTP mocking is used.
 *
 * Environment: jsdom (required for sessionStorage + window.location)
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { mockClientGet } = vi.hoisted(() => ({ mockClientGet: vi.fn() }))

vi.mock('@/api/client', () => ({
  client: { get: (...args: unknown[]) => mockClientGet(...args) },
}))

import { resolveRealmFromUrl, resetTenantConfigCache, fetchTenantConfig, fetchTenantConfigForSlug, isTenantConfigCached } from './tenantConfig'

describe('resolveRealmFromUrl', () => {
  beforeEach(() => {
    // Clear sessionStorage before each test to ensure isolation.
    sessionStorage.clear()
    // Default: no realm in URL.
    vi.stubGlobal('location', { search: '' })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    sessionStorage.clear()
  })

  it('TC-OIDC-F06-01: returns slug from ?realm= URL param and writes to sessionStorage', () => {
    // Arrange: URL contains ?realm=swiftroute; sessionStorage is empty.
    vi.stubGlobal('location', { search: '?realm=swiftroute' })

    // Act
    const result = resolveRealmFromUrl()

    // Assert: slug returned and persisted
    expect(result).toBe('swiftroute')
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('swiftroute')
  })

  it('TC-OIDC-F06-02: returns slug from sessionStorage when key is already set', () => {
    // Arrange: sessionStorage already has the slug from a previous page load.
    sessionStorage.setItem('bpm_realm_slug', 'meridian')
    // URL has no ?realm= param.
    vi.stubGlobal('location', { search: '' })

    // Act
    const result = resolveRealmFromUrl()

    // Assert: sessionStorage key wins; URL is not consulted.
    expect(result).toBe('meridian')
  })
})

/**
 * gui-review-2026-09-20-tenant-switch-cache-isolation (EO-002): resolveRealmFromUrl's
 * sessionStorage persistence is deliberate (OIDC-F-06), but nothing previously cleared
 * it on sign-out -- a realm slug left behind by one company's session survived into the
 * next person's sign-in on the same browser tab. resetTenantConfigCache is the fix,
 * wired into AuthProvider.logout() (see AuthProvider.logout-clears-realm.test.tsx).
 */
describe('resetTenantConfigCache', () => {
  beforeEach(() => {
    sessionStorage.clear()
  })

  afterEach(() => {
    sessionStorage.clear()
  })

  it('TC-EO002-01: removes bpm_realm_slug from sessionStorage', () => {
    sessionStorage.setItem('bpm_realm_slug', 'swiftroute')

    resetTenantConfigCache()

    expect(sessionStorage.getItem('bpm_realm_slug')).toBeNull()
  })

  it('TC-EO002-02: a subsequent resolveRealmFromUrl call with no URL param and no prior sessionStorage falls through to null (fresh resolution, not the cleared value)', () => {
    sessionStorage.setItem('bpm_realm_slug', 'swiftroute')
    resetTenantConfigCache()
    vi.stubGlobal('location', { search: '' })

    const result = resolveRealmFromUrl()

    expect(result).toBeNull()
    vi.unstubAllGlobals()
  })

  it("TC-EO002-03: strips a ?realm= query param from the address bar via history.replaceState, so ProtectedRoute's own re-render (which fires the instant logout() sets isAuthenticated to false, per AuthProvider.tsx) cannot re-derive and re-write the same slug from the URL a tick later", () => {
    const originalUrl = window.location.href
    window.history.pushState({}, '', '/?realm=swiftroute-fixture')
    sessionStorage.setItem('bpm_realm_slug', 'swiftroute-fixture')

    resetTenantConfigCache()

    expect(new URLSearchParams(window.location.search).has('realm')).toBe(false)
    // resolveRealmFromUrl() must now fall through to null -- neither
    // sessionStorage (already cleared) nor the URL (just stripped) name a
    // realm any more.
    expect(resolveRealmFromUrl()).toBeNull()

    window.history.pushState({}, '', originalUrl)
  })

  it('TC-EO002-04: a call with no ?realm= query param present does nothing to the URL (no-op path)', () => {
    const originalUrl = window.location.href
    window.history.pushState({}, '', '/tasks')

    expect(() => resetTenantConfigCache()).not.toThrow()
    expect(window.location.pathname).toBe('/tasks')
    expect(window.location.search).toBe('')

    window.history.pushState({}, '', originalUrl)
  })
})

/**
 * REQ-384 §5.2 / TEST-DESIGNER audit gap: `fetchTenantConfigForSlug` is the
 * function CODE-DESIGN-VALIDATOR's rework specifically required to be
 * genuinely per-slug-keyed and to NEVER read or write this file's own
 * single-value `_cachedConfig` (the bug class this whole design exists to
 * prevent, relocated from the query cache into the auth layer -- see
 * tenantConfig.ts's own `fetchTenantConfigForSlug` moduledoc comment).
 * FRONTEND-DEV wrote no dedicated test for this property; these are new.
 */
describe('fetchTenantConfigForSlug — REQ-384 §5.2 (never touches _cachedConfig)', () => {
  beforeEach(() => {
    sessionStorage.clear()
    mockClientGet.mockReset()
    resetTenantConfigCache()
    vi.stubGlobal('location', { search: '' })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    sessionStorage.clear()
  })

  it('TC-REQ384-13: populating _cachedConfig via fetchTenantConfig for tenant A does NOT leak into fetchTenantConfigForSlug for tenant B', async () => {
    mockClientGet.mockResolvedValueOnce({ oidc_authority: 'https://idp/realms/tenant-a', client_id: 'client-a' })

    // Populate the SINGLE-VALUE _cachedConfig with tenant A's config, the way
    // a first sign-in / single-membership user's fetchTenantConfig() call
    // would.
    const configA = await fetchTenantConfig('tenant-a.example.com')
    expect(configA.oidc_authority).toBe('https://idp/realms/tenant-a')

    mockClientGet.mockResolvedValueOnce({ oidc_authority: 'https://idp/realms/tenant-b', client_id: 'client-b' })

    // Act: ask for tenant B's config via the per-slug path. If this
    // incorrectly read _cachedConfig, it would return tenant A's config
    // without ever calling client.get a second time.
    const configB = await fetchTenantConfigForSlug('tenant-b')

    expect(configB.oidc_authority).toBe('https://idp/realms/tenant-b')
    expect(configB).not.toEqual(configA)
    // A real network call was made for tenant B, not a cache hit off _cachedConfig.
    expect(mockClientGet).toHaveBeenCalledTimes(2)
    expect(mockClientGet).toHaveBeenNthCalledWith(2, '/api/tenant-config', { realm: 'tenant-b' })
  })

  it('TC-REQ384-14: fetchTenantConfigForSlug does not write into _cachedConfig (getCachedTenantConfig / fetchTenantConfig stay unaffected)', async () => {
    mockClientGet.mockResolvedValueOnce({ oidc_authority: 'https://idp/realms/tenant-c', client_id: 'client-c' })

    await fetchTenantConfigForSlug('tenant-c')

    // fetchTenantConfig has never been called, so _cachedConfig must still be
    // unpopulated -- a fresh fetchTenantConfig call must hit the network
    // again, not silently return tenant C's config.
    mockClientGet.mockResolvedValueOnce({ oidc_authority: 'https://idp/realms/tenant-default', client_id: 'client-default' })
    const configViaHostname = await fetchTenantConfig('some-other-host.example.com')

    expect(configViaHostname.oidc_authority).toBe('https://idp/realms/tenant-default')
    expect(mockClientGet).toHaveBeenCalledTimes(2)
  })

  it('TC-REQ384-15: two different slugs each get their own genuinely-cached (second call does not re-fetch) config, keyed independently', async () => {
    mockClientGet.mockResolvedValueOnce({ oidc_authority: 'https://idp/realms/tenant-x', client_id: 'client-x' })
    mockClientGet.mockResolvedValueOnce({ oidc_authority: 'https://idp/realms/tenant-y', client_id: 'client-y' })

    const x1 = await fetchTenantConfigForSlug('tenant-x')
    const y1 = await fetchTenantConfigForSlug('tenant-y')
    expect(mockClientGet).toHaveBeenCalledTimes(2)

    // Second call for tenant-x is a genuine cache hit (own Map, no 3rd network call)...
    const x2 = await fetchTenantConfigForSlug('tenant-x')
    expect(mockClientGet).toHaveBeenCalledTimes(2)
    expect(x2).toEqual(x1)

    // ...and tenant-y's cached value was never disturbed by tenant-x's fetch.
    const y2 = await fetchTenantConfigForSlug('tenant-y')
    expect(mockClientGet).toHaveBeenCalledTimes(2)
    expect(y2).toEqual(y1)
    expect(y2).not.toEqual(x2)
  })
})

describe('fetchTenantConfig failure handling (T-1400)', () => {
  beforeEach(() => {
    sessionStorage.clear()
    mockClientGet.mockReset()
    resetTenantConfigCache()
    vi.stubGlobal('location', { search: '' })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    sessionStorage.clear()
  })

  it('TC-05a: a failed read is not cached; the next call fetches again', async () => {
    mockClientGet.mockRejectedValueOnce(new Error('boom'))
    const real = { oidc_authority: 'https://idp/realms/real', client_id: 'real' }
    mockClientGet.mockResolvedValueOnce(real)

    const first = await fetchTenantConfig('h')
    expect(first.client_id).toBe('letflow-web')
    expect(isTenantConfigCached()).toBe(false)

    expect(await fetchTenantConfig('h')).toEqual(real)
    expect(isTenantConfigCached()).toBe(true)
    expect(mockClientGet).toHaveBeenCalledTimes(2)
  })

  it('TC-05b: concurrent calls share one request', async () => {
    const real = { oidc_authority: 'https://idp/realms/real', client_id: 'real' }
    mockClientGet.mockResolvedValue(real)
    const [a, b] = await Promise.all([fetchTenantConfig('h'), fetchTenantConfig('h')])
    expect(a).toBe(b)
    expect(mockClientGet).toHaveBeenCalledTimes(1)
  })

  it('TC-05c: fetchTenantConfigForSlug does not cache a failure either', async () => {
    mockClientGet.mockRejectedValueOnce(new Error('boom'))
    const real = { oidc_authority: 'https://idp/realms/x', client_id: 'x' }
    mockClientGet.mockResolvedValueOnce(real)
    await fetchTenantConfigForSlug('x')
    expect(await fetchTenantConfigForSlug('x')).toEqual(real)
  })
})
