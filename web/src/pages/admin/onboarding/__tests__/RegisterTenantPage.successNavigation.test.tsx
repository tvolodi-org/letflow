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
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import type { OnboardingRecord } from '@/api/onboarding'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(() => ({
    session: { token: 'tok', display_name: 'Op', roles: ['PLATFORM_ADMIN'] },
  })),
}))

const postWithHeaders = vi.fn()
const post = vi.fn()
vi.mock('@/api/client', () => ({
  client: {
    postWithHeaders: (...args: unknown[]) => postWithHeaders(...args),
    post: (...args: unknown[]) => post(...args),
    get: vi.fn(),
  },
}))

import RegisterTenantPage from '../RegisterTenantPage'
import OnboardingResultPage from '../OnboardingResultPage'

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
  return render(
    <MemoryRouter initialEntries={['/admin/onboarding/new']}>
      <LocationSpy />
      <Routes>
        <Route path="/admin/onboarding/new" element={<RegisterTenantPage />} />
        <Route path="/admin/onboarding/:onboardingId/result" element={<OnboardingResultPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

// The admin fields are optional on main (ISS-1030) but required on the pre-fix form, so they are filled too.
// Filling them is valid on both, and it lets the pre-fix page reach submit for the fail-first run. The labels
// differ by an "(optional)" suffix between the two, so the match is on the prefix.
async function fillRequired(user: ReturnType<typeof userEvent.setup>) {
  await user.type(screen.getByLabelText('Slug'), 'newco')
  await user.type(screen.getByLabelText('Display Name'), 'Newco Corp')
  await user.type(screen.getByLabelText('Hostname'), 'newco.example.com')
  await user.type(screen.getByPlaceholderText('https://app.example.com/callback'), 'https://a.example.com/cb')
  await user.type(screen.getByLabelText(/^Admin Email/), 'admin@newco.example.com')
  await user.type(screen.getByLabelText(/^Admin Username/), 'newco-admin')
  await user.type(screen.getByLabelText(/^Admin Display Name/), 'Newco Admin')
}

beforeEach(() => {
  postWithHeaders.mockReset()
  post.mockReset()
  lastPath = ''
})
afterEach(cleanup)

describe('RegisterTenantPage success navigation (GH issue 2436)', () => {
  it('after a successful registration the page reaches the result page of the id the backend returns', async () => {
    postWithHeaders.mockResolvedValue(BACKEND_RECORD)
    const user = userEvent.setup()
    renderRegister()
    await fillRequired(user)
    await user.click(screen.getByRole('button', { name: 'Register Tenant' }))

    await waitFor(() => expect(lastPath).toBe('/admin/onboarding/ob-42/result'))
    expect(lastPath).not.toContain('undefined')
    expect(lastPath).not.toContain('/progress')
  })
})
