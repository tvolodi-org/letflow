// @vitest-environment jsdom
/**
 * REQ-438 -- ProtectedRoute wiring: the realm-precedence table (one test per
 * row), zero signinRedirect calls on the email-first path, pre-redirect path
 * preservation through the page, and E2E pre-restored sessions never reaching
 * the redirect branch.
 *
 * Mocked: only the OIDC managers (the layer beneath ProtectedRoute/LoginPage)
 * and the discovery API. tenantConfig, buildRedirectArgs, safeRestorePath, the
 * real LoginPage and the real AuthProvider are exercised unmodified.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, screen, fireEvent, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

const { mockSigninRedirect, mockSlugSigninRedirect, mockLookup } = vi.hoisted(() => ({
  mockSigninRedirect: vi.fn(),
  mockSlugSigninRedirect: vi.fn(),
  mockLookup: vi.fn(),
}))

vi.mock('../OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({
    signinRedirect: mockSigninRedirect,
    signoutRedirect: vi.fn(),
    events: { addAccessTokenExpiring: vi.fn(), removeAccessTokenExpiring: vi.fn() },
    startSilentRenew: vi.fn(),
  })),
}))

vi.mock('../tenantOidcRegistry', () => ({
  getOrCreateManagerForTenant: vi.fn(async () => ({ signinRedirect: mockSlugSigninRedirect })),
  attemptSilentSwitch: vi.fn(),
}))

vi.mock('@/api/loginDiscovery', () => ({
  loginDiscoveryApi: { lookup: mockLookup },
}))

import { AuthContext } from '../AuthContext'
import type { AuthContextValue } from '../AuthContext'
import { AuthProvider } from '../AuthProvider'
import { ProtectedRoute } from '../ProtectedRoute'
import LoginPage from '@/pages/LoginPage'

function ctx(isAuthenticated: boolean): AuthContextValue {
  return {
    session: null,
    isAuthenticated,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  }
}

/** Sets the real jsdom URL (ProtectedRoute reads window.location) and mounts
 *  the same route shape router.tsx uses: /login public, everything else guarded. */
function renderAt(url: string, withAuth: 'context' | 'provider' = 'context') {
  window.history.pushState({}, '', url)
  const tree = (
    <MemoryRouter initialEntries={[url]}>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route
          path="*"
          element={
            <ProtectedRoute>
              <div data-testid="protected-content" />
            </ProtectedRoute>
          }
        />
      </Routes>
    </MemoryRouter>
  )
  if (withAuth === 'provider') {
    const qc = new QueryClient()
    return render(
      <QueryClientProvider client={qc}>
        <AuthProvider>{tree}</AuthProvider>
      </QueryClientProvider>,
    )
  }
  return render(<AuthContext.Provider value={ctx(false)}>{tree}</AuthContext.Provider>)
}

beforeEach(() => {
  sessionStorage.clear()
  mockSigninRedirect.mockReset()
  mockSlugSigninRedirect.mockReset()
  mockLookup.mockReset()
})

afterEach(() => {
  cleanup()
  vi.unstubAllEnvs()
  sessionStorage.clear()
  window.history.pushState({}, '', '/')
})

describe('flag on, no realm known', () => {
  it('renders the email-first page and makes ZERO signinRedirect calls', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    renderAt('/')
    expect(await screen.findByTestId('login-page')).toBeInTheDocument()
    // let any stray effect/microtask run
    await Promise.resolve()
    await new Promise((r) => setTimeout(r, 20))
    expect(mockSigninRedirect).not.toHaveBeenCalled()
    expect(mockSlugSigninRedirect).not.toHaveBeenCalled()
    expect(screen.queryByTestId('auth-loading')).toBeNull()
  })
})

describe('precedence table', () => {
  it('row 1: ?realm=a with stored slug b -> signinRedirect for a, stored updated to a, no email-first page', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    sessionStorage.setItem('bpm_realm_slug', 'realm-b')
    renderAt('/?realm=realm-a')
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalledTimes(1))
    expect(mockSigninRedirect.mock.calls[0][0].redirect_uri).toContain('?realm=realm-a')
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('realm-a')
    expect(screen.queryByTestId('login-page')).toBeNull()
  })

  it('row 2: stored slug only -> signinRedirect for it, no email-first page', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    sessionStorage.setItem('bpm_realm_slug', 'realm-b')
    renderAt('/')
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalledTimes(1))
    expect(mockSigninRedirect.mock.calls[0][0].redirect_uri).toContain('?realm=realm-b')
    expect(screen.queryByTestId('login-page')).toBeNull()
  })

  it('row 3: ?realm= only -> as before (redirect for it, stored)', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    renderAt('/?realm=realm-a')
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalledTimes(1))
    expect(mockSigninRedirect.mock.calls[0][0].redirect_uri).toContain('?realm=realm-a')
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('realm-a')
    expect(screen.queryByTestId('login-page')).toBeNull()
  })

  it('row 4: neither -> email-first page', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    renderAt('/')
    expect(await screen.findByTestId('login-page')).toBeInTheDocument()
    expect(mockSigninRedirect).not.toHaveBeenCalled()
  })

  it('row 5: flag off and neither -> today default-realm redirect (signinRedirect with no realm args)', async () => {
    renderAt('/')
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalledTimes(1))
    expect(mockSigninRedirect.mock.calls[0][0]).toBeUndefined()
    expect(screen.queryByTestId('login-page')).toBeNull()
  })

  it('flag off with a stored slug is also unchanged', async () => {
    sessionStorage.setItem('bpm_realm_slug', 'realm-b')
    renderAt('/')
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalledTimes(1))
    expect(mockSigninRedirect.mock.calls[0][0].redirect_uri).toContain('?realm=realm-b')
  })
})

describe('pre-redirect path preservation', () => {
  it('survives the email-first page and is handed to signinRedirect as state', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    mockLookup.mockResolvedValue({ kind: 'tenant', tenant: { slug: 'bilimbaga', display_name: 'B' } })
    renderAt('/instances/123?tab=x')
    await screen.findByTestId('login-page')

    fireEvent.change(screen.getByLabelText('Email address'), { target: { value: 'u@example.org' } })
    fireEvent.click(screen.getByTestId('login-submit'))

    await waitFor(() => expect(mockSlugSigninRedirect).toHaveBeenCalledTimes(1))
    const args = mockSlugSigninRedirect.mock.calls[0][0]
    expect(args.state).toBe('/instances/123?tab=x')
    expect(args.login_hint).toBe('u@example.org')
    expect(args.redirect_uri).toContain('?realm=bilimbaga')
    expect(mockSigninRedirect).not.toHaveBeenCalled()
  })

  it('drops an unsafe path (isSafeRestorePath) rather than carrying it', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    mockLookup.mockResolvedValue({ kind: 'tenant', tenant: { slug: 'bilimbaga', display_name: 'B' } })
    renderAt('/weird%20path')
    await screen.findByTestId('login-page')

    fireEvent.change(screen.getByLabelText('Email address'), { target: { value: 'u@example.org' } })
    fireEvent.click(screen.getByTestId('login-submit'))

    await waitFor(() => expect(mockSlugSigninRedirect).toHaveBeenCalledTimes(1))
    expect(mockSlugSigninRedirect.mock.calls[0][0]).not.toHaveProperty('state')
  })
})

describe('E2E pre-restored session', () => {
  it('never reaches the redirect branch or the email-first page, whatever the flag says', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    sessionStorage.setItem(
      '__e2e_session',
      JSON.stringify({ token: 'tok', display_name: 'E2E' }),
    )
    renderAt('/', 'provider')
    expect(await screen.findByTestId('protected-content')).toBeInTheDocument()
    expect(screen.queryByTestId('login-page')).toBeNull()
    expect(mockSigninRedirect).not.toHaveBeenCalled()
  })
})
