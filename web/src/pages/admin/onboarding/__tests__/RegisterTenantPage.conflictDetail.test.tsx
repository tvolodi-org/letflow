// @vitest-environment jsdom
/**
 * GH 2438 (Q-1081): the register banner shows the server's detail for a 409 conflict.
 *
 * The server sets title to the fixed "Conflict" for every 409 and puts the specific reason in
 * detail (lib/letflow/api/error.ex conflict/1). The banner used to read title first, so every
 * conflict showed "Conflict". This pins that the banner shows the detail.
 *
 * The real api/onboarding module runs; only the HTTP client is mocked.
 */

import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(() => ({
    session: { token: 'tok', display_name: 'Op', roles: ['PLATFORM_ADMIN'] },
  })),
}))

const postWithHeaders = vi.fn()
vi.mock('@/api/client', () => ({
  client: {
    postWithHeaders: (...args: unknown[]) => postWithHeaders(...args),
    post: vi.fn(),
    get: vi.fn(),
  },
}))

import RegisterTenantPage from '../RegisterTenantPage'

function renderRegister() {
  return render(
    <MemoryRouter initialEntries={['/admin/onboarding/new']}>
      <Routes>
        <Route path="/admin/onboarding/new" element={<RegisterTenantPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

async function fillRequired(user: ReturnType<typeof userEvent.setup>) {
  await user.type(screen.getByLabelText('Slug'), 'newco')
  await user.type(screen.getByLabelText('Display Name'), 'Newco Corp')
  await user.type(screen.getByLabelText('Hostname'), 'newco.example.com')
  await user.type(screen.getByPlaceholderText('https://app.example.com/callback'), 'https://a.example.com/cb')
}

beforeEach(() => {
  postWithHeaders.mockReset()
})
afterEach(cleanup)

describe('GH 2438 -- the register banner shows the server detail for a 409', () => {
  it('a duplicate-slug 409 shows the specific detail, not the generic title "Conflict"', async () => {
    // The shape the client hands the onboarding module for a 409 problem+json body.
    postWithHeaders.mockRejectedValue({
      status: 409,
      message: 'Conflict',
      code: 'https://letflow.example/problems/conflict',
      details: {
        type: 'https://letflow.example/problems/conflict',
        title: 'Conflict',
        status: 409,
        detail: 'slug already exists',
      },
    })
    const user = userEvent.setup()
    renderRegister()
    await fillRequired(user)
    await user.click(screen.getByRole('button', { name: 'Register Tenant' }))

    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent('slug already exists')
    expect(alert.textContent).not.toBe('Conflict')
  })
})
