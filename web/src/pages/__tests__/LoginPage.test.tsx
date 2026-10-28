// @vitest-environment jsdom
/**
 * REQ-438 -- the public email-first login page. Mocks only the two layers
 * directly beneath it: the discovery API module and the per-slug OIDC manager
 * registry. Everything else (page, i18n, buildRedirectArgs, tenantConfig,
 * sessionStorage) is real.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AuthContextValue } from '@/auth/AuthContext'
import { AuthContext } from '@/auth/AuthContext'
import type { LoginDiscoveryOutcome } from '@/api/loginDiscovery'
expect.extend(jestDomMatchers)

const { mockLookup, mockSigninRedirect, mockGetManager } = vi.hoisted(() => {
  const signin = vi.fn()
  return {
    mockLookup: vi.fn(),
    mockSigninRedirect: signin,
    mockGetManager: vi.fn(async () => ({ signinRedirect: signin })),
  }
})

vi.mock('@/api/loginDiscovery', () => ({
  loginDiscoveryApi: { lookup: mockLookup },
}))

vi.mock('@/auth/tenantOidcRegistry', () => ({
  getOrCreateManagerForTenant: mockGetManager,
}))

import LoginPage from '../LoginPage'

const EMAIL = 'someone@example.org'
const accepted: LoginDiscoveryOutcome = { kind: 'accepted' }

function authValue(isAuthenticated = false): AuthContextValue {
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

function renderPage(opts: { isAuthenticated?: boolean; from?: string } = {}) {
  const entry = opts.from !== undefined ? { pathname: '/login', state: { from: opts.from } } : '/login'
  return render(
    <AuthContext.Provider value={authValue(opts.isAuthenticated)}>
      <MemoryRouter initialEntries={[entry]}>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route path="/" element={<div data-testid="home" />} />
        </Routes>
      </MemoryRouter>
    </AuthContext.Provider>,
  )
}

function typeEmail(value: string) {
  fireEvent.change(screen.getByLabelText('Email address'), { target: { value } })
}

async function submitEmail(value = EMAIL) {
  typeEmail(value)
  fireEvent.click(screen.getByTestId('login-submit'))
}

let assignSpy: ReturnType<typeof vi.fn>

beforeEach(() => {
  sessionStorage.clear()
  mockLookup.mockReset()
  mockSigninRedirect.mockReset()
  mockGetManager.mockClear()
  assignSpy = vi.fn()
  vi.stubGlobal('location', {
    ...window.location,
    assign: assignSpy,
    search: '',
    origin: 'https://app.example.test',
    href: 'https://app.example.test/login',
  })
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  sessionStorage.clear()
})

describe('LoginPage structure', () => {
  it('has an email field, no password input anywhere, and the organisation-code control', () => {
    const { container } = renderPage()
    expect(screen.getByLabelText('Email address')).toBeInTheDocument()
    expect(screen.getByLabelText('Organisation code')).toBeInTheDocument()
    expect(container.querySelectorAll('input[type=password]')).toHaveLength(0)
  })

  it('sends an already-authenticated visitor to /', () => {
    renderPage({ isAuthenticated: true })
    expect(screen.getByTestId('home')).toBeInTheDocument()
  })

  it('rejects a malformed address client-side without calling discovery', async () => {
    renderPage()
    await submitEmail('not-an-email')
    expect(await screen.findByTestId('login-email-invalid')).toBeInTheDocument()
    expect(mockLookup).not.toHaveBeenCalled()
  })
})

describe('LoginPage single-tenant outcome', () => {
  it('stores the slug, then calls signinRedirect once with ?realm=<slug> and login_hint = typed email', async () => {
    mockLookup.mockResolvedValue({ kind: 'tenant', tenant: { slug: 'bilimbaga', display_name: 'BilimBaga' } })
    const { container } = renderPage()
    await submitEmail()

    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalledTimes(1))
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('bilimbaga')
    expect(mockGetManager).toHaveBeenCalledWith('bilimbaga')
    const args = mockSigninRedirect.mock.calls[0][0] as { redirect_uri: string; login_hint: string }
    expect(args.redirect_uri).toContain('?realm=bilimbaga')
    expect(args.login_hint).toBe(EMAIL)
    expect(container.querySelectorAll('input[type=password]')).toHaveLength(0)
    expect(mockLookup).toHaveBeenCalledTimes(1)
  })

  it('does not submit twice while a hand-off is in flight', async () => {
    mockLookup.mockResolvedValue({ kind: 'tenant', tenant: { slug: 'bilimbaga', display_name: 'B' } })
    renderPage()
    typeEmail(EMAIL)
    fireEvent.click(screen.getByTestId('login-submit'))
    fireEvent.click(screen.getByTestId('login-submit'))
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalledTimes(1))
    expect(mockLookup).toHaveBeenCalledTimes(1)
  })

  it('shows the network error state if the hand-off itself fails', async () => {
    mockLookup.mockResolvedValue({ kind: 'tenant', tenant: { slug: 'bilimbaga', display_name: 'B' } })
    mockSigninRedirect.mockRejectedValue(new Error('boom'))
    renderPage()
    await submitEmail()
    expect(await screen.findByTestId('login-error-network')).toBeInTheDocument()
  })

  it('carries a safe pre-redirect path as OIDC state and drops an unsafe one', async () => {
    mockLookup.mockResolvedValue({ kind: 'tenant', tenant: { slug: 'bilimbaga', display_name: 'B' } })
    renderPage({ from: '/instances/123?tab=x' })
    await submitEmail()
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalledTimes(1))
    expect(mockSigninRedirect.mock.calls[0][0]).toMatchObject({ state: '/instances/123?tab=x' })

    cleanup()
    mockSigninRedirect.mockReset()
    renderPage({ from: '//evil.example/path' })
    await submitEmail()
    await waitFor(() => expect(mockSigninRedirect).toHaveBeenCalledTimes(1))
    expect(mockSigninRedirect.mock.calls[0][0]).not.toHaveProperty('state')
  })
})

describe('LoginPage neutral outcome', () => {
  it('renders one fixed neutral message and never calls signinRedirect', async () => {
    mockLookup.mockResolvedValue(accepted)
    renderPage()
    await submitEmail()
    expect(await screen.findByTestId('login-neutral')).toHaveTextContent(
      'If this address is registered, instructions have been sent to it.',
    )
    expect(mockSigninRedirect).not.toHaveBeenCalled()
    expect(sessionStorage.getItem('bpm_realm_slug')).toBeNull()
  })

  it('unknown-address and multi-tenant (and uniform-tenant) replies are the same 202 and give identical DOM, organisation-code control included', async () => {
    const snapshots: string[] = []
    // The API layer collapses all three server cases into the one accepted outcome;
    // each run feeds a freshly built response object, as a separate request would.
    for (let i = 0; i < 3; i++) {
      mockLookup.mockResolvedValue({ kind: 'accepted' })
      const { container } = renderPage()
      await submitEmail()
      await screen.findByTestId('login-neutral')
      snapshots.push(container.innerHTML)
      cleanup()
    }
    expect(snapshots[1]).toBe(snapshots[0])
    expect(snapshots[2]).toBe(snapshots[0])
    expect(snapshots[0]).toContain('login-org-form')
  })

  it('the neutral DOM does not depend on the typed address text beyond the input value', async () => {
    mockLookup.mockResolvedValue(accepted)
    renderPage()
    await submitEmail('first@example.org')
    const neutral = (await screen.findByTestId('login-neutral')).outerHTML
    expect(neutral).not.toContain('first@example.org')
  })
})

describe('LoginPage error states', () => {
  const cases: Array<[string, LoginDiscoveryOutcome, string, string]> = [
    ['network', { kind: 'network_error' }, 'login-error-network', 'could not reach'],
    ['429', { kind: 'rate_limited' }, 'login-error-rate-limited', 'Too many attempts'],
    ['malformed', { kind: 'malformed' }, 'login-error-malformed', 'unexpected reply'],
  ]

  for (const [label, outcome, testId, text] of cases) {
    it(`${label}: distinct non-leaking state with a retry affordance and the organisation-code control`, async () => {
      mockLookup.mockResolvedValue(outcome)
      renderPage()
      await submitEmail()
      const box = await screen.findByTestId(testId)
      expect(box).toHaveTextContent(text)
      expect(box.textContent).not.toContain(EMAIL)
      expect(box.textContent?.toLowerCase()).not.toMatch(/registered|exists|unknown|not found/)
      expect(screen.getByTestId('login-retry')).toBeInTheDocument()
      expect(screen.getByLabelText('Organisation code')).toBeInTheDocument()
      // the other two error states are absent
      for (const [, , otherId] of cases) {
        if (otherId !== testId) expect(screen.queryByTestId(otherId)).toBeNull()
      }
    })
  }

  it('the three error states render different text', async () => {
    const texts: string[] = []
    for (const [, outcome, testId] of cases) {
      mockLookup.mockResolvedValue(outcome)
      renderPage()
      await submitEmail()
      texts.push((await screen.findByTestId(testId)).textContent ?? '')
      cleanup()
    }
    expect(new Set(texts).size).toBe(3)
  })

  it('retry re-submits the same address and can reach a different outcome', async () => {
    mockLookup.mockResolvedValueOnce({ kind: 'rate_limited' }).mockResolvedValueOnce(accepted)
    renderPage()
    await submitEmail()
    fireEvent.click(await screen.findByTestId('login-retry'))
    expect(await screen.findByTestId('login-neutral')).toBeInTheDocument()
    expect(mockLookup).toHaveBeenCalledTimes(2)
    expect(mockLookup).toHaveBeenNthCalledWith(2, EMAIL)
  })
})

describe('LoginPage out-of-pattern server slug', () => {
  const badSlugs = ['', 'a'.repeat(256), 'a/b', 'a?b', 'a#b', 'a&b', 'a b', '<b>', 'café', '..']

  for (const slug of badSlugs) {
    it(`slug ${JSON.stringify(slug.slice(0, 12))} (len ${slug.length}): malformed, nothing stored, no redirect, retry + org code offered`, async () => {
      const actual = await vi.importActual<typeof import('@/api/loginDiscovery')>('@/api/loginDiscovery')
      vi.stubGlobal(
        'fetch',
        vi.fn().mockResolvedValue({
          status: 200,
          ok: true,
          statusText: 'OK',
          json: async () => ({ result: 'tenant', tenant: { slug, display_name: 'D' } }),
          headers: { get: () => null },
        }),
      )
      mockLookup.mockImplementation((address: string) => actual.loginDiscoveryApi.lookup(address))
      renderPage()
      await submitEmail()
      expect(await screen.findByTestId('login-error-malformed')).toBeInTheDocument()
      expect(sessionStorage.getItem('bpm_realm_slug')).toBeNull()
      expect(mockGetManager).not.toHaveBeenCalled()
      expect(mockSigninRedirect).not.toHaveBeenCalled()
      expect(assignSpy).not.toHaveBeenCalled()
      expect(screen.getByTestId('login-retry')).toBeInTheDocument()
      expect(screen.getByLabelText('Organisation code')).toBeInTheDocument()
    })
  }
})

describe('LoginPage organisation-code control', () => {
  it('is present in the idle state and submitting navigates to /?realm=<encoded> with no discovery call', () => {
    renderPage()
    fireEvent.change(screen.getByLabelText('Organisation code'), { target: { value: 'my org/1' } })
    fireEvent.click(screen.getByTestId('login-org-submit'))
    expect(assignSpy).toHaveBeenCalledWith('/?realm=my%20org%2F1')
    expect(mockLookup).not.toHaveBeenCalled()
    expect(mockSigninRedirect).not.toHaveBeenCalled()
  })

  it('is usable from the 429, network and malformed states', async () => {
    for (const kind of ['rate_limited', 'network_error', 'malformed'] as const) {
      assignSpy.mockClear()
      mockLookup.mockResolvedValue({ kind })
      renderPage()
      await submitEmail()
      await waitFor(() => expect(screen.getByTestId('login-retry')).toBeInTheDocument())
      mockLookup.mockClear()
      fireEvent.change(screen.getByLabelText('Organisation code'), { target: { value: 'code-1' } })
      fireEvent.click(screen.getByTestId('login-org-submit'))
      expect(assignSpy).toHaveBeenCalledWith('/?realm=code-1')
      expect(mockLookup).not.toHaveBeenCalled()
      cleanup()
    }
  })

  it('is usable from the neutral state', async () => {
    mockLookup.mockResolvedValue(accepted)
    renderPage()
    await submitEmail()
    await screen.findByTestId('login-neutral')
    fireEvent.change(screen.getByLabelText('Organisation code'), { target: { value: 'code-2' } })
    fireEvent.click(screen.getByTestId('login-org-submit'))
    expect(assignSpy).toHaveBeenCalledWith('/?realm=code-2')
  })

  it('validates non-empty and length <= 255 only', () => {
    renderPage()
    const input = screen.getByLabelText('Organisation code')
    fireEvent.click(screen.getByTestId('login-org-submit'))
    expect(screen.getByTestId('login-org-invalid')).toBeInTheDocument()

    fireEvent.change(input, { target: { value: 'x'.repeat(256) } })
    fireEvent.click(screen.getByTestId('login-org-submit'))
    expect(screen.getByTestId('login-org-invalid')).toBeInTheDocument()
    expect(assignSpy).not.toHaveBeenCalled()

    fireEvent.change(input, { target: { value: 'x'.repeat(255) } })
    fireEvent.click(screen.getByTestId('login-org-submit'))
    expect(assignSpy).toHaveBeenCalledTimes(1)
  })
})

describe('LoginPage skip link (REQ-608)', () => {
  it('main is the single #main-content with tabindex -1', () => {
    renderPage()
    expect(document.querySelectorAll('#main-content')).toHaveLength(1)
    const main = screen.getByTestId('login-page')
    expect(main.id).toBe('main-content')
    expect(main).toHaveAttribute('tabindex', '-1')
  })

  it('first Tab focuses the skip link; click moves focus to main', () => {
    renderPage()
    const link = screen.getByRole('link', { name: 'Skip to main content' })
    expect(link).toHaveAttribute('href', '#main-content')
    link.focus()
    fireEvent.click(link)
    expect(screen.getByTestId('login-page')).toHaveFocus()
  })
})
