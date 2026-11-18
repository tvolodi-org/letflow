// @vitest-environment jsdom
/**
 * Unit tests for buildRedirectArgs (oidcRedirectArgs.ts).
 *
 * Covers: OIDC-F-02
 * Spec: tests/specs/OIDC-F-02-callback-realm.md
 * Test cases: TC-OIDC-F02-01, TC-OIDC-F02-02, TC-OIDC-F02-03
 *
 * DIRECTIVE T-2 note: buildRedirectArgs is a pure utility with no HTTP calls.
 * No backend is required and no HTTP mocking is used.
 *
 * Environment: jsdom (required for window.location.origin)
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// Must be hoisted before the module-under-test is imported so that vi.mock
// intercepts the tenantConfig dependency.
vi.mock('@/auth/tenantConfig', () => ({
  resolveRealmFromUrl: vi.fn(),
}))

import { resolveRealmFromUrl } from '@/auth/tenantConfig'
import { buildRedirectArgs } from './oidcRedirectArgs'

const mockResolveRealmFromUrl = resolveRealmFromUrl as ReturnType<typeof vi.fn>

describe('buildRedirectArgs', () => {
  it('W1 matches the exact full-slug callback registered by the provisioner', () => {
    vi.stubGlobal('location', { origin: 'https://acme.demo.example.test', search: '' })
    mockResolveRealmFromUrl.mockReturnValue('t-0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4d')
    expect(buildRedirectArgs()?.redirect_uri).toBe(
      'https://acme.demo.example.test/auth/callback?realm=t-0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4d',
    )
  })

  beforeEach(() => {
    vi.stubGlobal('location', {
      origin: 'https://app.example.com',
      search: '',
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    vi.clearAllMocks()
  })

  it('TC-OIDC-F02-01: returns realm-qualified redirect_uri when slug is present', () => {
    // Arrange
    mockResolveRealmFromUrl.mockReturnValue('swiftroute')

    // Act
    const result = buildRedirectArgs()

    // Assert
    expect(result).toBeDefined()
    expect(result!.redirect_uri).toBe(
      'https://app.example.com/auth/callback?realm=swiftroute',
    )
  })

  it('TC-OIDC-F02-02: returns undefined when no realm slug is resolvable', () => {
    // Arrange
    mockResolveRealmFromUrl.mockReturnValue(null)

    // Act
    const result = buildRedirectArgs()

    // Assert: undefined so UserManager falls back to its configured redirect_uri
    expect(result).toBeUndefined()
  })

  it('TC-OIDC-F02-03: percent-encodes special characters in the realm slug', () => {
    // Arrange — slug contains a space and a forward slash
    mockResolveRealmFromUrl.mockReturnValue('my realm/test')

    // Act
    const result = buildRedirectArgs()

    // Assert
    expect(result).toBeDefined()
    expect(result!.redirect_uri).toContain('my%20realm%2Ftest')
    expect(result!.redirect_uri).toBe(
      'https://app.example.com/auth/callback?realm=my%20realm%2Ftest',
    )
  })

  // ISS-0726 — capture-side `state` handling. See
  // lib/letflow/design/iss-0726-oidc-redirect-path-restore.md §2.3/§6.1.

  it('TC-ISS0726-01: a safe capturePath is carried as state alongside redirect_uri', () => {
    // Arrange
    mockResolveRealmFromUrl.mockReturnValue('swiftroute')

    // Act
    const result = buildRedirectArgs('/exam')

    // Assert
    expect(result).toBeDefined()
    expect(result!.state).toBe('/exam')
    expect(result!.redirect_uri).toBe(
      'https://app.example.com/auth/callback?realm=swiftroute',
    )
  })

  it('TC-ISS0726-02: an unsafe capturePath (open-redirect-shaped) is rejected — state key is absent', () => {
    // Arrange
    mockResolveRealmFromUrl.mockReturnValue('swiftroute')

    // Act
    const result = buildRedirectArgs('//evil.com')

    // Assert: redirect_uri is still produced, but the unsafe value never
    // reaches the returned object's state field.
    expect(result).toBeDefined()
    expect(result!.state).toBeUndefined()
    expect('state' in result!).toBe(false)
    expect(result!.redirect_uri).toBe(
      'https://app.example.com/auth/callback?realm=swiftroute',
    )
  })

  it('TC-ISS0726-03: omitting capturePath entirely omits the state key (backward compatible with TC-OIDC-F02-01)', () => {
    // Arrange
    mockResolveRealmFromUrl.mockReturnValue('swiftroute')

    // Act
    const result = buildRedirectArgs()

    // Assert
    expect(result).toBeDefined()
    expect('state' in result!).toBe(false)
  })
})
