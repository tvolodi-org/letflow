// @vitest-environment jsdom
/** S1-S5: T-1732 / REQ-809, the "Create sign-in" action and its one-time password panel on the user page. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { renderWithAccess } from '@/auth/access/testing'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { SIGN_IN_REASONS, signInMessages } from '../signInMessages'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-1', tenant_slug: 't', tenant_display_name: 'T', tenant_type: 'production' } }),
}))
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useNavigate: () => vi.fn(), useParams: () => ({ userId: 'u1' }) }
})

const base = { id: 'u1', username: 'ann', display_name: 'Ann', email: 'ann@x.io', status: 'active', auth_source: 'internal', inserted_at: '', updated_at: '' }
let user: Record<string, unknown> = base
const api = vi.hoisted(() => ({ createSignIn: vi.fn() }))
vi.mock('@/api/identity', () => ({
  usersApi: {
    get: () => Promise.resolve(user),
    createSignIn: api.createSignIn,
    update: vi.fn(),
    sendPasswordResetInstructions: vi.fn(),
  },
  rolesApi: { list: () => Promise.resolve({ items: [] }) },
  groupsApi: { list: () => Promise.resolve({ items: [] }) },
}))

import UserDetailPage from '../UserDetailPage'

const en = signInMessages.en
const PW = 'Tmp-Secret-42'
let qc: QueryClient

function renderPage() {
  qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}><MemoryRouter><UserDetailPage /></MemoryRouter></QueryClientProvider>,
    'tenantAdmin',
  )
}
const action = () => screen.findByRole('button', { name: en.action })

beforeEach(() => {
  user = base
  api.createSignIn.mockReset()
  localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(cleanup)

describe('REQ-809 user page Create sign-in', () => {
  it('S1 an internal user shows the action', async () => {
    renderPage()
    expect(await action()).toBeInTheDocument()
  })

  it('S2 an oidc user does not', async () => {
    user = { ...base, auth_source: 'oidc' }
    renderPage()
    await screen.findByTestId('admin-user-detail-form')
    expect(screen.queryByRole('button', { name: en.action })).toBeNull()
  })

  it('S3 201 shows username and password; Close removes the password', async () => {
    api.createSignIn.mockResolvedValue({ user: { ...base, auth_source: 'oidc' }, temporary_password: PW })
    renderPage()
    fireEvent.click(await action())
    expect(await screen.findByTestId('sign-in-password')).toHaveTextContent(PW)
    expect(screen.getByTestId('sign-in-username')).toHaveTextContent('ann')
    expect(api.createSignIn).toHaveBeenCalledWith('u1')
    fireEvent.click(screen.getByRole('button', { name: en.close }))
    expect(screen.queryByTestId('sign-in-panel')).toBeNull()
    expect(document.body.textContent).not.toContain(PW)
  })

  it('S4 the password is in no storage and in no query or mutation cache', async () => {
    api.createSignIn.mockResolvedValue({ user: base, temporary_password: PW })
    renderPage()
    fireEvent.click(await action())
    await screen.findByTestId('sign-in-password')
    await waitFor(() => expect(qc.getMutationCache().getAll()).toHaveLength(0))
    expect(JSON.stringify(qc.getQueryCache().getAll().map((q) => [q.queryKey, q.state.data]))).not.toContain(PW)
    expect(JSON.stringify(qc.getMutationCache().getAll().map((m) => m.state))).not.toContain(PW)
    expect(JSON.stringify({ ...localStorage })).not.toContain(PW)
    expect(JSON.stringify({ ...sessionStorage })).not.toContain(PW)
  })

  it.each(SIGN_IN_REASONS.filter((r) => r !== 'not_attempted'))('S5 409 %s shows its plain text', async (reason) => {
    api.createSignIn.mockRejectedValue({ status: 409, message: 'x', code: '409', details: { detail: reason } })
    renderPage()
    fireEvent.click(await action())
    const live = await screen.findByTestId('admin-user-sign-in-live')
    await waitFor(() => expect(live).toHaveTextContent(en.reasons[reason]))
    expect(screen.queryByTestId('sign-in-panel')).toBeNull()
  })
})
