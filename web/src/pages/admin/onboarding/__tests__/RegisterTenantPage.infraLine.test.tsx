// @vitest-environment jsdom
/**
 * ISS-1093 / GH 2463 (ADR 0044 Phase 1): the wizard no longer collects client_config,
 * realm_config or redirect URIs. One read-only line says the realm and client are created by
 * infra, and the submit body carries none of those keys. The admin_* fields are as before.
 */

import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(() => ({
    session: { token: 'tok', display_name: 'Op' },
  })),
}))

const createOnboarding = vi.fn()
vi.mock('@/api/client', () => ({
  client: {
    post: (...args: unknown[]) => createOnboarding(...args),
    get: vi.fn(),
  },
}))

import RegisterTenantPage from '../RegisterTenantPage'
import { renderWithAccess } from '@/auth/access/testing'

const RECORD = {
  id: 'ob-1',
  tenant_id: 't-1',
  slug: 'newco',
  hostname: 'newco.example.com',
  created_at: '2026-10-13T00:00:00Z',
  login: { loginable: false, status: 'not_yet_loginable', idp_realm_id: null, next_steps: [] },
  administrator: { state: 'none', message: 'No administrator.', not_provisioned: [], next_steps: [] },
  ignored_fields: [],
}

function renderRegister() {
  return renderWithAccess(
    <MemoryRouter initialEntries={['/admin/onboarding/new']}>
      <Routes>
        <Route path="/admin/onboarding/new" element={<RegisterTenantPage />} />
        <Route path="/admin/onboarding/:onboardingId/result" element={<div>result page</div>} />
      </Routes>
    </MemoryRouter>,
    'platformAdmin',
  )
}

beforeEach(() => createOnboarding.mockReset())
afterEach(cleanup)

describe('RegisterTenantPage ISS-1093', () => {
  it('shows one read-only line that realm and client are created by infra, and no inputs for them', () => {
    renderRegister()
    expect(screen.getByTestId('realm-client-infra-note')).toHaveTextContent(
      /realm and the client for this tenant are created by infra \(ADR 0044 Phase 1\)/,
    )
    expect(screen.queryByText(/Realm Config/)).toBeNull()
    expect(screen.queryByText(/Client Config/)).toBeNull()
    expect(screen.queryByText(/Redirect URIs/)).toBeNull()
    expect(screen.queryByLabelText(/Service Account/)).toBeNull()
  })

  it('submits without client_config, realm_config or redirect_uris, and sends only the optional admin_email', async () => {
    createOnboarding.mockResolvedValue(RECORD)
    const user = userEvent.setup()
    renderRegister()
    await user.type(screen.getByLabelText('Slug'), 'newco')
    await user.type(screen.getByLabelText('Display Name'), 'Newco Corp')
    await user.type(screen.getByLabelText('Hostname'), 'newco.example.com')
    await user.type(screen.getByLabelText(/^Admin Email/), 'admin@newco.example.com')
    await user.click(screen.getByRole('button', { name: 'Register Tenant' }))
    await waitFor(() => expect(createOnboarding).toHaveBeenCalledTimes(1))
    const body = createOnboarding.mock.calls[0]![1] as Record<string, unknown>
    expect(Object.keys(body).sort()).toEqual(
      ['admin_email', 'display_name', 'hostname', 'slug'].sort(),
    )
    expect(body['admin_email']).toBe('admin@newco.example.com')
  })
})
