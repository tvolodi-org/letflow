// @vitest-environment jsdom
/**
 * Unit tests — REQ-369 AC5: OidcCallbackPage.tsx's post-login `navigate()`
 * call becomes role-conditional. platform-admin lands on
 * `/platform-dashboard`; every other role's destination is unchanged (`/`).
 * See lib/letflow/design/req369-platform-dashboard-page.md §3/§3.1 (this file
 * had no pre-existing test — Open Q3 flagged this for TEST-DESIGNER to create
 * one, following this codebase's `__tests__/` colocation convention, e.g.
 * router.iss-0289.test.tsx under web/src/__tests__/).
 *
 * TC-REQ369-05: platform-admin role in the decoded token payload -> navigate
 *   called with ('/platform-dashboard', { replace: true }).
 * TC-REQ369-06: a non-platform access (the operator fixture) -> navigate
 *   called with ('/', { replace: true }), the pre-existing unchanged behavior.
 */

import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'
expect.extend(jestDomMatchers)

const mockNavigate = vi.fn()
const mockSetSession = vi.fn()
const mockGetAccess = vi.fn()
const mockSigninRedirectCallback = vi.fn()
const mockSigninSilentCallback = vi.fn()

vi.mock('react-router-dom', () => ({
  useNavigate: () => mockNavigate,
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ setSession: mockSetSession }),
}))

vi.mock('@/auth/OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({
    signinRedirectCallback: mockSigninRedirectCallback,
  })),
  // REQ-384 fix: the page also imports the module-level `oidcManager`
  // singleton directly (used only by the hidden-iframe relay branch, never
  // by the top-level signinRedirectCallback flow) -- see
  // OidcCallbackPage.tsx's `window.self !== window.top` branch.
  oidcManager: {
    signinSilentCallback: mockSigninSilentCallback,
  },
}))

vi.mock('@/api/client', () => ({
  setToken: vi.fn(),
}))

vi.mock('@/auth/tenantConfig', () => ({
  resolveRealmFromUrl: vi.fn(() => null),
}))

vi.mock('@/api/me', () => ({
  meApi: { getAccessWithToken: (...args: unknown[]) => mockGetAccess(...args) },
}))

vi.mock('@/api/tenants', () => ({
  tenantsApi: {
    getBySlug: vi.fn(),
  },
}))

// Real decodeTokenPayload is pure and safe to use unmocked -- it only needs
// a well-formed JWT-shaped string, built below via base64Url helpers
// matching the module's own atob-based decode.

function fakeToken(): string {
  const header = { alg: 'none', typ: 'JWT' }
  const payload = { roles: ['claimed'], sub: 'user-1', preferred_username: 'tester' }
  const b64 = (obj: unknown) => btoa(JSON.stringify(obj)).replace(/=+$/, '')
  return `${b64(header)}.${b64(payload)}.sig`
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-369 AC5 — OidcCallbackPage role-conditional navigation', () => {
  // OidcCallbackPage.tsx guards against React StrictMode's double-invoked
  // effect with a MODULE-SCOPE `let _callbackStarted` flag (see the file's
  // own comment above it) that only resets on a fresh module load. Each test
  // below therefore resets the module registry and re-imports the component
  // fresh, so the second test's render is not silently a no-op because the
  // first test already flipped that flag.
  it('TC-REQ369-05: a platform-admin access navigates to /platform-dashboard', async () => {
    vi.resetModules()
    const token = fakeToken()
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.platformAdmin)
    // Sanity: confirm this test's fixture actually decodes the way the
    // component itself will decode it (same helper, same token string).

    mockSigninRedirectCallback.mockResolvedValue({ access_token: token })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/platform-dashboard', { replace: true })
    })
    expect(mockNavigate).not.toHaveBeenCalledWith('/', { replace: true })
  })

  it('TC-REQ369-06: a non-platform access (the operator fixture) navigates to / unchanged', async () => {
    vi.resetModules()
    const token = fakeToken()
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.operator)

    mockSigninRedirectCallback.mockResolvedValue({ access_token: token })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/', { replace: true })
    })
    expect(mockNavigate).not.toHaveBeenCalledWith('/platform-dashboard', { replace: true })
  })
})

/**
 * ISS-0726 — restore-side priority logic in OidcCallbackPage.tsx: a
 * validated `user.state` (round-tripped through oidc-client-ts's `state`
 * option) wins over the access-based fallback, including for platform-admin.
 * See lib/letflow/design/iss-0726-oidc-redirect-path-restore.md §3.1, §6.1
 * and test/specs/ISS-0726.md.
 */
describe('ISS-0726 — OidcCallbackPage restore-priority navigation', () => {
  it('TC-ISS0726-04: a validated user.state wins over the operator fallback', async () => {
    vi.resetModules()
    const token = fakeToken()
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.operator)

    mockSigninRedirectCallback.mockResolvedValue({ access_token: token, state: '/exam' })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/exam', { replace: true })
    })
    expect(mockNavigate).not.toHaveBeenCalledWith('/', { replace: true })
  })

  it('TC-ISS0726-05: a validated user.state wins over platform-admin\'s dashboard fallback', async () => {
    vi.resetModules()
    const token = fakeToken()
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.platformAdmin)

    mockSigninRedirectCallback.mockResolvedValue({ access_token: token, state: '/exam' })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/exam', { replace: true })
    })
    expect(mockNavigate).not.toHaveBeenCalledWith('/platform-dashboard', { replace: true })
  })

  it('TC-ISS0726-06: an unsafe user.state (open-redirect-shaped) is rejected — falls back to access-based destination', async () => {
    vi.resetModules()
    const token = fakeToken()
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.operator)

    mockSigninRedirectCallback.mockResolvedValue({ access_token: token, state: '//evil.com' })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/', { replace: true })
    })
    expect(mockNavigate).not.toHaveBeenCalledWith('//evil.com', { replace: true })
  })
})

/**
 * REQ-384 fix regression coverage (REVIEWER gap, WF02-REQ384-20260922) --
 * OidcCallbackPage.tsx doubles as oidc-client-ts's `silent_redirect_uri`
 * target when AuthProvider.switchTenant() -> attemptSilentSwitch() calls
 * `signinSilent()`, which opens this SAME route inside a hidden iframe.
 * Before the fix, the page unconditionally ran the top-level
 * `signinRedirectCallback()` flow regardless of where it loaded, so the
 * iframe's callback URL was never relayed back to the parent window and the
 * pending `signinSilent()` promise hung forever. The fix branches on
 * `window.self !== window.top` and relays via `signinSilentCallback()`
 * instead, skipping the top-level flow entirely in that case.
 *
 * TC-REQ384-23: loaded inside a frame (window.top !== window.self) ->
 *   `oidcManager.signinSilentCallback()` is called and
 *   `getOidcManager()`/`signinRedirectCallback()` is never invoked.
 * TC-REQ384-24: loaded at top level (the default jsdom topology,
 *   window.top === window.self, matching every test above) ->
 *   `signinRedirectCallback()` runs and `signinSilentCallback()` is never
 *   invoked -- the two branches are mutually exclusive.
 */
describe('REQ-384 — OidcCallbackPage hidden-iframe relay branch', () => {
  const realTop = window.top

  afterEach(() => {
    // Restore jsdom's default topology (window.top === window.self) so this
    // describe block's frame simulation never leaks into another test file
    // or a later test in this one.
    Object.defineProperty(window, 'top', { value: realTop, configurable: true })
  })

  it('TC-REQ384-23: inside a hidden iframe, relays via signinSilentCallback and never runs the top-level redirect-callback flow', async () => {
    vi.resetModules()
    Object.defineProperty(window, 'top', { value: {}, configurable: true })
    expect(window.top).not.toBe(window.self)

    mockSigninSilentCallback.mockResolvedValue(undefined)

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockSigninSilentCallback).toHaveBeenCalledTimes(1)
    })
    expect(mockSigninRedirectCallback).not.toHaveBeenCalled()
    expect(mockNavigate).not.toHaveBeenCalled()
    expect(mockSetSession).not.toHaveBeenCalled()
  })

  it('TC-REQ384-24: at the top level (not framed), runs signinRedirectCallback and never touches signinSilentCallback', async () => {
    vi.resetModules()
    // window.top already === window.self here (jsdom default, restored by
    // this describe block's own afterEach) -- asserted explicitly so this
    // test fails loudly if that assumption ever stops holding.
    expect(window.top).toBe(window.self)

    const token = fakeToken()
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.operator)
    mockSigninRedirectCallback.mockResolvedValue({ access_token: token })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/', { replace: true })
    })
    expect(mockSigninSilentCallback).not.toHaveBeenCalled()
  })
})
