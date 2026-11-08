// @vitest-environment jsdom
/**
 * REQ-438 (design req434 section 11.2) -- resolveRealmFromUrl precedence at the
 * unit level: an explicit ?realm= wins and overwrites the stored value; with
 * only one present the behaviour is unchanged; buildRedirectArgs' optional
 * login hint is additive. The pre-existing tenantConfig / buildRedirectArgs
 * tests stay unmodified and cover the single-source rows.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fetchTenantConfig, resetTenantConfigCache, resolveRealmFromUrl } from '../tenantConfig'
import { client } from '@/api/client'
import { buildRedirectArgs } from '../oidcRedirectArgs'

vi.mock('@/api/client', () => ({ client: { get: vi.fn() } }))

beforeEach(() => {
  resetTenantConfigCache()
  vi.mocked(client.get).mockReset()
  sessionStorage.clear()
  window.history.pushState({}, '', '/')
})

afterEach(() => {
  sessionStorage.clear()
  window.history.pushState({}, '', '/')
})

describe('resolveRealmFromUrl precedence', () => {
  it('?realm=a with stored b returns a and overwrites the stored value', () => {
    sessionStorage.setItem('bpm_realm_slug', 'realm-b')
    window.history.pushState({}, '', '/?realm=realm-a')
    expect(resolveRealmFromUrl()).toBe('realm-a')
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('realm-a')
  })

  it('stored only returns the stored slug', () => {
    sessionStorage.setItem('bpm_realm_slug', 'realm-b')
    expect(resolveRealmFromUrl()).toBe('realm-b')
  })

  it('?realm= only returns it and stores it', () => {
    window.history.pushState({}, '', '/?realm=realm-a')
    expect(resolveRealmFromUrl()).toBe('realm-a')
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('realm-a')
  })

  it('neither returns null', () => {
    expect(resolveRealmFromUrl()).toBeNull()
  })
})

describe('buildRedirectArgs login hint', () => {
  it('adds login_hint only when given, alongside redirect_uri and state', () => {
    sessionStorage.setItem('bpm_realm_slug', 'realm-a')
    const withHint = buildRedirectArgs('/tasks', { loginHint: 'u@example.org' })
    expect(withHint).toEqual({
      redirect_uri: `${window.location.origin}/auth/callback?realm=realm-a`,
      state: '/tasks',
      login_hint: 'u@example.org',
    })
    expect(buildRedirectArgs('/tasks')).not.toHaveProperty('login_hint')
    expect(buildRedirectArgs(undefined, { loginHint: '' })).not.toHaveProperty('login_hint')
  })

  it('still returns undefined with no realm, even with a hint', () => {
    expect(buildRedirectArgs(undefined, { loginHint: 'u@example.org' })).toBeUndefined()
  })
})

describe('default tenant selection order (T-1481)', () => {
  const cfg = { oidc_authority: 'https://idp/realms/x', client_id: 'c' }

  it('?realm=a with stored b asks the backend for realm a', async () => {
    vi.mocked(client.get).mockResolvedValue(cfg)
    sessionStorage.setItem('bpm_realm_slug', 'realm-b')
    window.history.pushState({}, '', '/?realm=realm-a')
    await fetchTenantConfig('demo.example.org')
    expect(client.get).toHaveBeenCalledWith('/api/tenant-config', { realm: 'realm-a' })
  })

  it('stored slug only asks for the stored realm', async () => {
    vi.mocked(client.get).mockResolvedValue(cfg)
    sessionStorage.setItem('bpm_realm_slug', 'realm-b')
    await fetchTenantConfig('demo.example.org')
    expect(client.get).toHaveBeenCalledWith('/api/tenant-config', { realm: 'realm-b' })
  })

  it('neither sends only the host so the backend configured default decides', async () => {
    vi.mocked(client.get).mockResolvedValue(cfg)
    await fetchTenantConfig('demo.example.org')
    expect(client.get).toHaveBeenCalledWith('/api/tenant-config', { host: 'demo.example.org' })
  })
})
