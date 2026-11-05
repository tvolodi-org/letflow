// @vitest-environment jsdom
/**
 * gui-review-2026-09-20-tenant-switch-cache-isolation (EO-002 — "signing out
 * leaves nothing behind"): AuthProvider.logout() must clear the same-tab
 * tenant-selection residue (bpm_realm_slug in sessionStorage) a previous
 * session's `?realm=` load may have written, so the next person to sign in
 * on this browser tab resolves tenant-config fresh rather than inheriting
 * the departing user's company. See web/src/auth/tenantConfig.ts's
 * resetTenantConfigCache moduledoc and docs/issues (filed alongside this fix)
 * for the full defect trace.
 *
 * TC-EO002-03: logout() removes bpm_realm_slug from sessionStorage.
 * TC-EO002-04: logout() still clears the in-memory token/session and
 *   triggers signoutRedirect — this fix must not regress the existing path.
 */

import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, act } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const { mockClearToken, mockSignoutRedirect } = vi.hoisted(() => ({
  mockClearToken: vi.fn(),
  mockSignoutRedirect: vi.fn(),
}))

vi.mock('@/api/client', () => ({
  clearToken: mockClearToken,
  setToken: vi.fn(),
  tryRestoreE2eSession: vi.fn(() => null),
}))

vi.mock('../OidcManager', () => ({
  resetOidcManager: vi.fn(),
  getOidcManager: vi.fn(async () => ({
    signoutRedirect: mockSignoutRedirect,
    events: { addAccessTokenExpiring: vi.fn(), removeAccessTokenExpiring: vi.fn() },
    startSilentRenew: vi.fn(),
  })),
}))

import { AuthProvider } from '../AuthProvider'
import { AuthContext } from '../AuthContext'

// REQ-384: AuthProvider now reads useQueryClient() (for switchTenant's
// cache-clear step, §5.3), so it must be rendered under a QueryClientProvider.
function renderWithQueryClient(ui: React.ReactElement) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(<QueryClientProvider client={queryClient}>{ui}</QueryClientProvider>)
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  sessionStorage.clear()
})

// A synthetic, non-real slug — deliberately not one of the platform's known
// tenant slugs (see tests/guards/forbidlist.ts's tenant-slug-in-source rule,
// which this file is not on the allowlist for since it's not a
// tenant/company-page test). The exact string value is irrelevant to what
// this test asserts (that logout() clears the key, whatever it holds).
const FIXTURE_REALM_SLUG = 'gui-review-fixture-realm'

describe('AuthProvider.logout — EO-002 realm residue', () => {
  it('TC-EO002-03: clears bpm_realm_slug from sessionStorage on logout', async () => {
    sessionStorage.setItem('bpm_realm_slug', FIXTURE_REALM_SLUG)

    let captured: { logout: () => void } | null | undefined = null

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

    renderWithQueryClient(
      <AuthProvider>
        <Capture />
      </AuthProvider>,
    )

    expect(sessionStorage.getItem('bpm_realm_slug')).toBe(FIXTURE_REALM_SLUG)

    await act(async () => {
      captured!.logout()
    })

    expect(sessionStorage.getItem('bpm_realm_slug')).toBeNull()
  })

  it('TC-EO002-04: logout still clears the token and triggers signoutRedirect (no regression)', async () => {
    let captured: { logout: () => void } | null | undefined = null

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

    renderWithQueryClient(
      <AuthProvider>
        <Capture />
      </AuthProvider>,
    )

    await act(async () => {
      captured!.logout()
      // flush the getOidcManager().then(...) microtask
      await Promise.resolve()
    })

    expect(mockClearToken).toHaveBeenCalled()
    expect(mockSignoutRedirect).toHaveBeenCalled()
  })
})
