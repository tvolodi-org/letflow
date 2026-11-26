// @vitest-environment jsdom
/**
 * Regression guard for GH issue 2436, updated by T-2704: a successful registration navigates to the page of the
 * id the backend returns. POST /api/v1/onboarding answers 202 with `instance_id` (the route starts the
 * `platform.register_tenant` process), so the page goes to /instances/:instance_id, never to an undefined path.
 *
 * The real api/onboarding module runs; only the HTTP client is mocked.
 */

import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
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
import { renderWithAccess } from '@/auth/access/testing'

// The 202 body as the backend returns it (lib/letflow/platform_processes/route_start.ex).
const BACKEND_ANSWER = { instance_id: 'inst-42', status: 'active', slug: 'newco' }

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
        <Route path="/instances/:id" element={<span>instance page</span>} />
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
  it('after a successful registration the page reaches the instance page of the id the backend returns', async () => {
    createOnboarding.mockResolvedValue(BACKEND_ANSWER)
    const user = userEvent.setup()
    renderRegister()
    await fillRequired(user)
    await user.click(screen.getByRole('button', { name: 'Register Tenant' }))

    await waitFor(() => expect(lastPath).toBe('/instances/inst-42'))
    expect(lastPath).not.toContain('undefined')
    expect(lastPath).not.toContain('/progress')
    expect(lastPath).not.toContain('/result')
  })
})
