// @vitest-environment jsdom
/** T-1657 / REQ-789: the reset button, the hints for refused users, the confirmation and the outcome texts. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { renderWithAccess } from '@/auth/access/testing'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { passwordResetMessages } from '../passwordResetMessages'
expect.extend(jestDomMatchers)

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useNavigate: () => vi.fn(), useParams: () => ({ userId: 'u1' }) }
})

const base = { id: 'u1', username: 'ann', display_name: 'Ann', email: 'ann@x.io', status: 'active', auth_source: 'oidc', inserted_at: '', updated_at: '' }
let user: Record<string, unknown> = base
const sendMutate = vi.fn()
const idle = { mutate: vi.fn(), isPending: false }

vi.mock('@/hooks/useAdminUsers', () => ({
  useAdminUser: () => ({ data: user, isLoading: false, isError: false, error: null, refetch: vi.fn() }),
  useAdminRoles: () => ({ data: { items: [] } }),
  useAdminGroups: () => ({ data: { items: [] } }),
  useUpdateAdminUser: () => idle,
  useDeactivateAdminUser: () => idle,
  useSendPasswordResetInstructions: () => ({ mutate: sendMutate, isPending: false }),
  useCreateUserSignIn: () => ({ mutate: vi.fn(), reset: vi.fn(), isPending: false }),
}))

import UserDetailPage from '../UserDetailPage'

const en = passwordResetMessages.en

beforeEach(() => {
  user = base
  sendMutate.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(cleanup)

describe('T-1657 UserDetailPage reset button', () => {
  it('P1 active oidc user with e-mail: button, no hint', () => {
    renderWithAccess(<MemoryRouter><UserDetailPage /></MemoryRouter>, 'tenantAdmin')
    expect(screen.getByRole('button', { name: en.button })).toBeInTheDocument()
    expect(screen.queryByTestId('admin-user-reset-hint')).toBeNull()
  })

  it.each([
    ['P2 inactive', { status: 'inactive' }, 'hintInactive'],
    ['P3 internal', { auth_source: 'internal' }, 'hintNoLogin'],
    ['P4 empty e-mail', { email: '' }, 'hintNoEmail'],
  ] as const)('%s: hint, no button', (_n, patch, key) => {
    user = { ...base, ...patch }
    renderWithAccess(<MemoryRouter><UserDetailPage /></MemoryRouter>, 'tenantAdmin')
    expect(screen.queryByRole('button', { name: en.button })).toBeNull()
    expect(screen.getByTestId('admin-user-reset-hint')).toHaveTextContent(en[key])
  })

  it('P5 without the manage permission: no button', () => {
    renderWithAccess(<MemoryRouter><UserDetailPage /></MemoryRouter>, 'taskWorker')
    expect(screen.queryByRole('button', { name: en.button })).toBeNull()
  })

  it('P6 cancel sends nothing', () => {
    renderWithAccess(<MemoryRouter><UserDetailPage /></MemoryRouter>, 'tenantAdmin')
    fireEvent.click(screen.getByRole('button', { name: en.button }))
    fireEvent.click(screen.getByRole('button', { name: en.cancel }))
    expect(sendMutate).not.toHaveBeenCalled()
  })

  it('P7 confirm names the stored e-mail and sends once', () => {
    renderWithAccess(<MemoryRouter><UserDetailPage /></MemoryRouter>, 'tenantAdmin')
    fireEvent.click(screen.getByRole('button', { name: en.button }))
    expect(screen.getByTestId('password-reset-dialog-body')).toHaveTextContent('ann@x.io')
    fireEvent.click(screen.getByRole('button', { name: en.confirm }))
    expect(sendMutate).toHaveBeenCalledTimes(1)
  })

  function confirmWith(run: (opts: { onSuccess: () => void; onError: (e: unknown) => void }) => void) {
    sendMutate.mockImplementation((_v, opts) => run(opts))
    renderWithAccess(<MemoryRouter><UserDetailPage /></MemoryRouter>, 'tenantAdmin')
    fireEvent.click(screen.getByRole('button', { name: en.button }))
    fireEvent.click(screen.getByRole('button', { name: en.confirm }))
  }

  it('P8 202 shows the sent message with the e-mail', () => {
    confirmWith((o) => o.onSuccess())
    const msg = screen.getByTestId('admin-user-reset-message')
    expect(within(msg).getByRole('status')).toBeInTheDocument()
    expect(msg).toHaveTextContent('ann@x.io')
  })

  it.each([
    ['P9', 'user_inactive', 'errorInactive'],
    ['P10', 'no_identity_provider_login', 'errorNoLogin'],
    ['P11', 'no_email', 'errorNoEmail'],
  ] as const)('%s 409 %s shows its text', (_n, detail, key) => {
    confirmWith((o) => o.onError({ status: 409, details: { detail } }))
    expect(screen.getByTestId('admin-user-reset-message')).toHaveTextContent(en[key])
  })

  it('P12 a 500 shows the generic save error, not the server text', () => {
    confirmWith((o) => o.onError({ status: 500, message: 'secret server text' }))
    const msg = screen.getByTestId('admin-user-reset-message')
    expect(msg).not.toHaveTextContent('secret server text')
    expect(msg.textContent?.length).toBeGreaterThan(0)
    expect(within(msg).getByRole('alert')).toBeInTheDocument()
  })

  it('M3 the page uses the ru text when the language is ru', () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    renderWithAccess(<MemoryRouter><UserDetailPage /></MemoryRouter>, 'tenantAdmin')
    expect(screen.getByRole('button', { name: passwordResetMessages.ru.button })).toBeInTheDocument()
  })
})
