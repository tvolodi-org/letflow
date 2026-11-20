// @vitest-environment jsdom
/** T-2350 -- unknown or refused company code: one page, same text, en/ru/kk, no signin redirect. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, screen, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

const { mockGet, mockSignin, mockCallback } = vi.hoisted(() => ({
  mockGet: vi.fn(),
  mockSignin: vi.fn(),
  mockCallback: vi.fn(),
}))

vi.mock('@/api/client', () => ({ client: { get: mockGet }, setToken: vi.fn() }))
vi.mock('../OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({ signinRedirect: mockSignin, signinRedirectCallback: mockCallback })),
  oidcManager: {},
}))
vi.mock('../AuthContext', () => ({
  useAuth: () => ({ isAuthenticated: false, isLoading: false, setSession: vi.fn() }),
}))

import { ProtectedRoute } from '../ProtectedRoute'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { isCompanyCodeUnknown } from '../tenantConfig'
import { loginMessages } from '@/i18n/loginMessages'

const DEFAULT_BODY = { oidc_authority: 'http://idp/realms/bpm-default', client_id: 'letflow-web' }

function setUrl(path: string) {
  window.history.replaceState({}, '', path)
}

beforeEach(() => {
  vi.clearAllMocks()
  sessionStorage.clear()
  localStorage.clear()
})
afterEach(() => cleanup())

// The mock answers like the server: the same default authority for a known default tenant and for
// an unknown code; only company_found tells them apart (review of T-2350 attempt 3).
function serverAnswers(found: Record<string, boolean>) {
  mockGet.mockImplementation(async (_u: string, p: Record<string, string>) => {
    if (p.realm && p.company_check === '1') return { ...DEFAULT_BODY, company_found: found[p.realm] === true }
    return DEFAULT_BODY
  })
}

describe('isCompanyCodeUnknown', () => {
  it('is true when the server says no company has the code', async () => {
    serverAnswers({})
    expect(await isCompanyCodeUnknown('nope')).toBe(true)
  })
  it('asks with the opt-in flag and the typed code', async () => {
    serverAnswers({})
    await isCompanyCodeUnknown('nope')
    expect(mockGet).toHaveBeenCalledWith('/api/tenant-config', { realm: 'nope', company_check: '1' })
  })
  it('is false for a company with its own realm', async () => {
    mockGet.mockResolvedValue({ ...DEFAULT_BODY, oidc_authority: 'http://idp/realms/known-co', company_found: true })
    expect(await isCompanyCodeUnknown('known-co')).toBe(false)
  })
  it('is false for the default tenant: its answer equals the default answer but it is a company', async () => {
    // A configured default slug (e.g. showroom) or a tenant on bpm-default typed explicitly.
    serverAnswers({ showroom: true })
    expect(await isCompanyCodeUnknown('showroom')).toBe(false)
  })
  it('is false when the key is absent (older server)', async () => {
    mockGet.mockResolvedValue(DEFAULT_BODY)
    expect(await isCompanyCodeUnknown('known-co')).toBe(false)
  })
  it('is false on a read failure', async () => {
    mockGet.mockRejectedValue(new Error('down'))
    expect(await isCompanyCodeUnknown('known-co')).toBe(false)
  })
})

describe.each(['en', 'ru', 'kk'] as const)('company not found in %s', (lang) => {
  const title = loginMessages[lang]['login.companyNotFound.title']
  const body = loginMessages[lang]['login.companyNotFound.body']

  it('unknown code: ProtectedRoute shows the page and never redirects', async () => {
    useUiLocaleStore.getState().setLocale(lang)
    setUrl('/?realm=nope')
    serverAnswers({})
    render(<ProtectedRoute><div>secret</div></ProtectedRoute>, { wrapper: MemoryRouter })
    expect(await screen.findByTestId('company-not-found')).toBeInTheDocument()
    expect(screen.getByRole('heading')).toHaveTextContent(title)
    expect(screen.getByRole('alert')).toHaveTextContent(body)
    expect(document.body.textContent).not.toMatch(/login\.[a-zA-Z.]+/)
    expect(mockSignin).not.toHaveBeenCalled()
    expect(sessionStorage.getItem('bpm_realm_slug')).toBeNull()
    expect(screen.getByLabelText(loginMessages[lang]['login.org.label'])).toBeInTheDocument()
  })

  it('refused return (error param): the callback shows the same page', async () => {
    useUiLocaleStore.getState().setLocale(lang)
    setUrl('/auth/callback?error=invalid_request')
    mockCallback.mockRejectedValue(new Error('invalid_request'))
    vi.resetModules()
    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />, { wrapper: MemoryRouter })
    expect(await screen.findByTestId('company-not-found')).toBeInTheDocument()
    expect(screen.getByRole('heading')).toHaveTextContent(title)
    expect(screen.getByRole('alert')).toHaveTextContent(body)
    expect(document.body.textContent).not.toMatch(/login\.[a-zA-Z.]+/)
  })
})

describe('company not found behaviour', () => {
  it('a known code goes on to the identity provider', async () => {
    setUrl('/?realm=known-co')
    serverAnswers({ 'known-co': true })
    render(<ProtectedRoute><div>secret</div></ProtectedRoute>, { wrapper: MemoryRouter })
    await waitFor(() => expect(mockSignin).toHaveBeenCalled())
    expect(screen.queryByTestId('company-not-found')).toBeNull()
  })

  it('the default tenant typed explicitly (answer equals the default answer) still redirects', async () => {
    setUrl('/?realm=showroom')
    serverAnswers({ showroom: true })
    render(<ProtectedRoute><div>secret</div></ProtectedRoute>, { wrapper: MemoryRouter })
    await waitFor(() => expect(mockSignin).toHaveBeenCalled())
    expect(screen.queryByTestId('company-not-found')).toBeNull()
  })

  it('an empty typed code is refused in the field', async () => {
    setUrl('/?realm=nope')
    serverAnswers({})
    render(<ProtectedRoute><div>x</div></ProtectedRoute>, { wrapper: MemoryRouter })
    fireEvent.click(await screen.findByTestId('company-not-found-submit'))
    expect(screen.getByTestId('company-not-found-invalid')).toBeInTheDocument()
  })
})
