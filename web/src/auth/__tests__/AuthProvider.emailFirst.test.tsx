// @vitest-environment jsdom
/**
 * REQ-438 (design req434 D4) -- AuthProvider paths under the email-first flag:
 *   - session-expired with a stored realm: re-logs into that realm (unchanged)
 *   - session-expired with NO realm and the flag on: no signinRedirect; the
 *     user lands on /login (ProtectedRoute owns the navigation)
 *   - flag off: unchanged
 *   - logout (flag on): clears the realm and the next unauthenticated render
 *     reaches the email-first page
 * The unmodified AuthProvider.logout-clears-realm test covers logout itself.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, screen, act, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

const { mockSigninRedirect, mockSignoutRedirect, mockClearToken } = vi.hoisted(() => ({
  mockSigninRedirect: vi.fn(),
  mockSignoutRedirect: vi.fn(),
  mockClearToken: vi.fn(),
}))

vi.mock('@/api/client', () => ({
  clearToken: mockClearToken,
  setToken: vi.fn(),
  tryRestoreE2eSession: vi.fn(() => ({
    token: 'tok',
    display_name: 'U',
  })),
}))

vi.mock('../OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({
    signinRedirect: mockSigninRedirect,
    signoutRedirect: mockSignoutRedirect,
    events: { addAccessTokenExpiring: vi.fn(), removeAccessTokenExpiring: vi.fn() },
    startSilentRenew: vi.fn(),
  })),
}))

vi.mock('../tenantOidcRegistry', () => ({
  getOrCreateManagerForTenant: vi.fn(),
  attemptSilentSwitch: vi.fn(),
}))

import { AuthProvider } from '../AuthProvider'
import { AuthContext } from '../AuthContext'
import type { AuthContextValue } from '../AuthContext'
import { ProtectedRoute } from '../ProtectedRoute'

let captured: AuthContextValue | undefined

function Capture() {
  return (
    <AuthContext.Consumer>
      {(value) => {
        captured = value
        return null
      }}
    </AuthContext.Consumer>
  )
}

function renderApp() {
  const qc = new QueryClient()
  return render(
    <QueryClientProvider client={qc}>
      <AuthProvider>
        <Capture />
        <MemoryRouter initialEntries={['/tasks']}>
          <Routes>
            <Route path="/login" element={<div data-testid="login-stub" />} />
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
      </AuthProvider>
    </QueryClientProvider>,
  )
}

function expireSession() {
  act(() => {
    window.dispatchEvent(new CustomEvent('auth:session-expired'))
  })
}

async function settle() {
  await act(async () => {
    await new Promise((r) => setTimeout(r, 20))
  })
}

beforeEach(() => {
  sessionStorage.clear()
  window.history.pushState({}, '', '/tasks')
  mockSigninRedirect.mockReset()
  mockSignoutRedirect.mockReset()
  mockClearToken.mockReset()
  captured = undefined
})

afterEach(() => {
  cleanup()
  vi.unstubAllEnvs()
  sessionStorage.clear()
  window.history.pushState({}, '', '/')
})

describe('session-expired', () => {
  it('with a stored realm (flag on): still re-logs into that realm', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    sessionStorage.setItem('bpm_realm_slug', 'realm-s')
    renderApp()
    expect(screen.getByTestId('protected-content')).toBeInTheDocument()

    expireSession()
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalled())
    await settle()
    expect(mockSigninRedirect.mock.calls[0][0].redirect_uri).toContain('?realm=realm-s')
    expect(screen.queryByTestId('login-stub')).toBeNull()
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('realm-s')
  })

  it('with NO realm and the flag on: no signinRedirect and navigates to /login', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    renderApp()
    expect(screen.getByTestId('protected-content')).toBeInTheDocument()

    expireSession()
    expect(await screen.findByTestId('login-stub')).toBeInTheDocument()
    await settle()
    expect(mockSigninRedirect).not.toHaveBeenCalled()
    expect(mockClearToken).toHaveBeenCalled()
  })

  it('with NO realm and the flag off: unchanged default-realm re-login', async () => {
    renderApp()
    expireSession()
    // Today's behaviour: both AuthProvider and ProtectedRoute redirect (twice).
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalled())
    for (const call of mockSigninRedirect.mock.calls) expect(call[0]).toBeUndefined()
    expect(screen.queryByTestId('login-stub')).toBeNull()
  })

  it('with a ?realm= in the URL and no stored slug (flag on): re-logs into that realm', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    window.history.pushState({}, '', '/tasks?realm=realm-u')
    renderApp()
    expireSession()
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalled())
    expect(mockSigninRedirect.mock.calls[0][0].redirect_uri).toContain('?realm=realm-u')
  })
})

describe('logout with the flag on', () => {
  it('clears the stored realm and the next unauthenticated render reaches the email-first route', async () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    sessionStorage.setItem('bpm_realm_slug', 'realm-s')
    renderApp()
    expect(screen.getByTestId('protected-content')).toBeInTheDocument()

    await act(async () => {
      captured!.logout()
      await Promise.resolve()
    })

    expect(sessionStorage.getItem('bpm_realm_slug')).toBeNull()
    expect(mockSignoutRedirect).toHaveBeenCalled()
    expect(await screen.findByTestId('login-stub')).toBeInTheDocument()
    expect(mockSigninRedirect).not.toHaveBeenCalled()
  })
})
