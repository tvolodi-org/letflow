// @vitest-environment jsdom
/**
 * Regression guard for GH issue 2436: a successful registration navigates to the result page of the id the
 * backend returns (`id` in the 201 body). On 3344de22 the success path read `result.onboarding_id` and navigated
 * to .../progress; on main it navigates to .../result.
 *
 * The real api/onboarding module runs; only the HTTP client is mocked.
 */

import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import type { OnboardingRecord } from '@/api/onboarding'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(() => ({
    session: { token: 'tok', display_name: 'Op' },
  })),
}))

const createOnboarding = vi.fn()
const post = vi.fn()
vi.mock('@/api/client', () => ({
  client: {
    // create goes through client.post; the bind-realm call is the other client.post caller
    post: (path: string, ...rest: unknown[]) =>
      path === '/api/v1/onboarding' ? createOnboarding(path, ...rest) : post(path, ...rest),
    get: vi.fn(),
  },
}))

import RegisterTenantPage from '../RegisterTenantPage'
import OnboardingResultPage from '../OnboardingResultPage'
import { renderWithAccess } from '@/auth/access/testing'

// The 201 body as the backend returns it (lib/letflow/routers/onboarding.ex onboarding_map: "id").
const BACKEND_RECORD: OnboardingRecord = {
  id: 'ob-42',
  tenant_id: 't-42',
  slug: 'newco',
  hostname: 'newco.example.com',
  created_at: '2026-10-13T00:00:00Z',
  login: {
    loginable: false,
    status: 'not_yet_loginable',
    idp_realm_id: null,
    next_steps: ['Create the realm, then bind it.'],
  },
  administrator: { state: 'none', message: 'No administrator.', not_provisioned: [], next_steps: [] },
  ignored_fields: [],
}

let lastPath = ''
function LocationSpy() {
  lastPath = useLocation().pathname
  return null
}

function renderRegister() {
  return renderWithAccess(
    <MemoryRouter initialEntries={['/admin/onboarding/new']}>
      <LocationSpy />
      <Routes>
        <Route path="/admin/onboarding/new" element={<RegisterTenantPage />} />
        <Route path="/admin/onboarding/:onboardingId/result" element={<OnboardingResultPage />} />
      </Routes>
    </MemoryRouter>,
    'platformAdmin',
  )
}

async function fillRequired(user: ReturnType<typeof userEvent.setup>) {
  await user.type(screen.getByLabelText('Slug'), 'newco')
  await user.type(screen.getByLabelText('Display Name'), 'Newco Corp')
  await user.type(screen.getByLabelText('Hostname'), 'newco.example.com')
  await user.type(screen.getByLabelText(/^Admin Email/), 'admin@newco.example.com')
}

beforeEach(() => {
  createOnboarding.mockReset()
  post.mockReset()
  lastPath = ''
})
afterEach(cleanup)

describe('RegisterTenantPage success navigation (GH issue 2436)', () => {
  it('after a successful registration the page reaches the result page of the id the backend returns', async () => {
    createOnboarding.mockResolvedValue(BACKEND_RECORD)
    const user = userEvent.setup()
    renderRegister()
    await fillRequired(user)
    await user.click(screen.getByRole('button', { name: 'Register Tenant' }))

    await waitFor(() => expect(lastPath).toBe('/admin/onboarding/ob-42/result'))
    expect(lastPath).not.toContain('undefined')
    expect(lastPath).not.toContain('/progress')
  })
})
