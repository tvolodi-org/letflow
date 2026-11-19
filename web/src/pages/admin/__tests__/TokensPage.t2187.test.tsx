// @vitest-environment jsdom
/** T-2187 / GH #4712: the admin Tokens page follows the UI language (ru, kk), nothing is hard-coded. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, fireEvent } from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 'header.' + btoa(JSON.stringify({ sub: 'admin-id' })) + '.sig',
        display_name: 'Admin',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-1',
        tenant_type: null,
      },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import TokensPage from '@/pages/admin/TokensPage'
import { renderWithAccess } from '@/auth/access/testing'
import { useUiLocaleStore, type UiLocale } from '@/i18n/uiLocaleStore'
import { tokensMessages } from '../tokensMessages'

const TOKEN = {
  id: 'tok-1',
  user_id: 'u-1',
  issuer_user_id: null,
  roles: ['SOME_ROLE'],
  status: 'active',
  created_at: '2026-10-01T00:00:00Z',
  expires_at: null,
  revoked_at: null,
}
const USER = { id: 'u-1', username: 'u-1', display_name: 'Owner', email: 'o@example.com', status: 'active', auth_source: 'internal' }

function stubNetwork(items: unknown[]) {
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string) => {
      const path = String(url).split('?')[0]
      const body = path.endsWith('/identity/tokens') ? { items } : { items: [USER], next_cursor: null, count: 1 }
      return { ok: true, status: 200, statusText: 'OK', json: async () => body, text: async () => JSON.stringify(body), headers: { get: () => null } }
    }),
  )
}

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <TokensPage />
      </MemoryRouter>
    </QueryClientProvider>,
    'tenantAdmin',
  )
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  useUiLocaleStore.getState().setLocale('en')
})

describe('T-2187 TokensPage language', () => {
  it('K1 en/ru/kk carry the same keys and none is empty', () => {
    const keys = Object.keys(tokensMessages.en).sort()
    for (const l of ['ru', 'kk'] as const) expect(Object.keys(tokensMessages[l]).sort()).toEqual(keys)
    for (const l of ['en', 'ru', 'kk'] as const) for (const v of Object.values(tokensMessages[l])) expect(v.trim()).not.toBe('')
  })

  it('K2 ru and kk texts differ from the English ones for the visible strings', () => {
    for (const l of ['ru', 'kk'] as const) {
      for (const k of ['title', 'issueAction', 'colName', 'colStatus', 'colActions', 'empty', 'revoke'] as const) {
        expect(tokensMessages[l][k]).not.toBe(tokensMessages.en[k])
      }
    }
  })

  for (const l of ['ru', 'kk'] as UiLocale[]) {
    it(`K3 ${l}: heading, action, headers, status and revoke button are translated`, async () => {
      const m = tokensMessages[l]
      useUiLocaleStore.getState().setLocale(l)
      stubNetwork([TOKEN])
      renderPage()
      await waitFor(() => expect(screen.getAllByTestId('datatable-row')).toHaveLength(1))
      expect(screen.getByRole('heading', { name: m.title })).toBeInTheDocument()
      expect(screen.getByText(m.issueAction)).toBeInTheDocument()
      expect(screen.getByTestId('datatable-header-name')).toHaveTextContent(m.colName)
      expect(screen.getByTestId('datatable-header-issuer')).toHaveTextContent(m.colIssuedBy)
      expect(screen.getByTestId('token-status')).toHaveTextContent(m.statusActive)
      expect(screen.getByRole('button', { name: m.revoke })).toBeInTheDocument()
      expect(screen.queryByText('API Tokens')).not.toBeInTheDocument()
      expect(screen.queryByText('Active')).not.toBeInTheDocument()
    })

    it(`K4 ${l}: empty state, issue form and revoke dialog are translated`, async () => {
      const m = tokensMessages[l]
      useUiLocaleStore.getState().setLocale(l)
      stubNetwork([])
      renderPage()
      await waitFor(() => expect(screen.getByText(m.empty)).toBeInTheDocument())
      fireEvent.click(screen.getByText(m.issueAction))
      expect(screen.getByText(m.targetUser)).toBeInTheDocument()
      expect(screen.getByText(m.selectUser)).toBeInTheDocument()
      expect(screen.getByText(m.generatedOnce)).toBeInTheDocument()
      expect(screen.getByPlaceholderText(m.rolesPlaceholder)).toBeInTheDocument()
      fireEvent.click(screen.getByRole('button', { name: m.issueSubmit }))
      expect(await screen.findByText(m.selectUserError)).toBeInTheDocument()
    })
  }

  it('K5 ru: the revoke dialog is translated', async () => {
    const m = tokensMessages.ru
    useUiLocaleStore.getState().setLocale('ru')
    stubNetwork([TOKEN])
    renderPage()
    await waitFor(() => expect(screen.getAllByTestId('datatable-row')).toHaveLength(1))
    fireEvent.click(screen.getByRole('button', { name: m.revoke }))
    expect(screen.getByRole('dialog', { name: m.revokeDialog })).toBeInTheDocument()
    expect(screen.getByText(m.revokeTitle)).toBeInTheDocument()
    expect(screen.getByText(m.revokeText)).toBeInTheDocument()
  })

  it('K6 no user-facing English literal is left in TokensPage.tsx', () => {
    const src = readFileSync(resolve(process.cwd(), 'src/pages/admin/TokensPage.tsx'), 'utf8')
    for (const lit of [
      "'API Tokens'", '>API Tokens<', 'Issue token', 'Select a user', 'Target user', 'Role set', 'Expiry date',
      'Comma-separated', 'No API tokens found', 'Revoke token', 'Copy token', "'Never'", "'Unknown user'",
      "header: '", 'Revoking this API token', 'will not be shown again', 'Select a target user', 'at least one role',
    ]) {
      expect(src, lit).not.toContain(lit)
    }
  })
})
