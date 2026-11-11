// @vitest-environment jsdom
/** D1-D3: T-1732 / REQ-809, the "Create sign-in now" checkbox of the new-user form. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { renderWithAccess } from '@/auth/access/testing'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { fillReason, signInMessages } from '../signInMessages'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-1', tenant_slug: 't', tenant_display_name: 'T', tenant_type: 'production' } }),
}))
const navigate = vi.hoisted(() => vi.fn())
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useNavigate: () => navigate }
})
const api = vi.hoisted(() => ({ create: vi.fn(), createSignIn: vi.fn() }))
vi.mock('@/api/identity', () => ({
  usersApi: { list: () => Promise.resolve({ items: [] }), create: api.create, createSignIn: api.createSignIn },
  rolesApi: { list: () => Promise.resolve({ items: [] }) },
}))

import UsersPage from '../UsersPage'

const en = signInMessages.en
const CREATED = { id: 'u9', username: 'bob', display_name: 'Bob', email: 'bob@x.io', status: 'active', auth_source: 'internal' }

function openForm() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  renderWithAccess(<QueryClientProvider client={qc}><MemoryRouter><UsersPage /></MemoryRouter></QueryClientProvider>, 'tenantAdmin')
  fireEvent.click(screen.getByText(/New user|Create user/i, { selector: 'button, button *' }))
}
const submit = () => fireEvent.click(screen.getAllByRole('button', { name: /Create user/i }).pop() as HTMLElement)

beforeEach(() => {
  api.create.mockReset().mockResolvedValue(CREATED)
  api.createSignIn.mockReset()
  navigate.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(cleanup)

describe('REQ-809 new-user checkbox', () => {
  it('D1 unchecked by default: no sign-in call, navigates to the user page as before', async () => {
    openForm()
    expect((screen.getByTestId('admin-users-create-sign-in') as HTMLInputElement).checked).toBe(false)
    submit()
    await waitFor(() => expect(navigate).toHaveBeenCalledWith('/admin/users/u9'))
    expect(api.createSignIn).not.toHaveBeenCalled()
  })

  it('D2 checked: sign-in called once with the created id, panel shown, no navigation', async () => {
    api.createSignIn.mockResolvedValue({ user: CREATED, temporary_password: 'Tmp-D2' })
    openForm()
    fireEvent.click(screen.getByTestId('admin-users-create-sign-in'))
    submit()
    expect(await screen.findByTestId('sign-in-password')).toHaveTextContent('Tmp-D2')
    expect(api.createSignIn).toHaveBeenCalledTimes(1)
    expect(api.createSignIn).toHaveBeenCalledWith('u9')
    expect(navigate).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: en.openUser }))
    expect(navigate).toHaveBeenCalledWith('/admin/users/u9')
  })

  it('D3 checked and refused (409): the user stays created, the reason is shown', async () => {
    api.createSignIn.mockRejectedValue({ status: 409, message: 'x', code: '409', details: { detail: 'no_email' } })
    openForm()
    fireEvent.click(screen.getByTestId('admin-users-create-sign-in'))
    submit()
    const live = screen.getByTestId('admin-users-sign-in-live')
    await waitFor(() => expect(live).toHaveTextContent(fillReason(en.createdNoSignIn, en.reasons.no_email)))
    expect(screen.queryByTestId('sign-in-panel')).toBeNull()
    expect(navigate).not.toHaveBeenCalled()
  })
})
