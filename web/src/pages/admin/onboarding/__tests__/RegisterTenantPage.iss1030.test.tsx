// @vitest-environment jsdom
/**
 * ISS-1030 (web part of PR 1): the wizard no longer requires administrator
 * details, offers an optional realm id, omits blank optional fields from the
 * request, and the result view shows the server's administrator / login /
 * ignored-field notices as plain text.
 *
 * The real api/onboarding module runs; only the HTTP client is mocked.
 */

import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import React from 'react'
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
import type { OnboardingStatusCompleted } from '@/api/onboarding'

const RECORD = {
  id: 'ob-1',
  tenant_id: 't-1',
  slug: 'acme',
  hostname: 'acme.example.com',
  created_at: '2026-10-08T00:00:00Z',
  login: {
    loginable: false,
    status: 'not_yet_loginable',
    idp_realm_id: null,
    next_steps: ['Create the realm, then bind it.'],
  },
  administrator: { state: 'none', message: 'No administrator.', not_provisioned: [], next_steps: [] },
  ignored_fields: [],
}

function renderRegister() {
  return render(
    <MemoryRouter initialEntries={['/admin/onboarding/new']}>
      <Routes>
        <Route path="/admin/onboarding/new" element={<RegisterTenantPage />} />
        <Route path="/admin/onboarding/:onboardingId/result" element={<OnboardingResultPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

async function fillRequired(user: ReturnType<typeof userEvent.setup>) {
  await user.type(screen.getByLabelText('Slug'), 'acme')
  await user.type(screen.getByLabelText('Display Name'), 'Acme Corp')
  await user.type(screen.getByLabelText('Hostname'), 'acme.example.com')
  await user.type(screen.getByPlaceholderText('https://app.example.com/callback'), 'https://a.example.com/cb')
}

async function submit(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: 'Register Tenant' }))
}

beforeEach(() => {
  postWithHeaders.mockReset()
  post.mockReset()
})
afterEach(cleanup)

describe('RegisterTenantPage ISS-1030', () => {
  it('admin fields are optional and the form submits without them', async () => {
    postWithHeaders.mockResolvedValue(RECORD)
    const user = userEvent.setup()
    renderRegister()
    await fillRequired(user)
    await submit(user)
    await waitFor(() => expect(postWithHeaders).toHaveBeenCalledTimes(1))
    expect(screen.queryByText(/is required/)).toBeNull()
    expect(await screen.findByText(/not yet loginable/i, { selector: '[role="status"]' })).toBeInTheDocument()
  })

  it('a filled admin_email must be a valid address', async () => {
    const user = userEvent.setup()
    renderRegister()
    await fillRequired(user)
    await user.type(screen.getByLabelText(/Admin Email/), 'not-an-email')
    await submit(user)
    expect(screen.getByText('Enter a valid email address')).toBeInTheDocument()
    expect(postWithHeaders).not.toHaveBeenCalled()
  })

  it('the optional realm field is sent when filled', async () => {
    postWithHeaders.mockResolvedValue({
      ...RECORD,
      login: { loginable: true, status: 'realm_bound', idp_realm_id: 'acme-realm', next_steps: [] },
    })
    const user = userEvent.setup()
    renderRegister()
    await fillRequired(user)
    await user.type(screen.getByLabelText(/Identity Realm ID/), '  acme-realm  ')
    await submit(user)
    await waitFor(() => expect(postWithHeaders).toHaveBeenCalledTimes(1))
    const body = postWithHeaders.mock.calls[0]![1] as Record<string, unknown>
    expect(body['idp_realm_id']).toBe('acme-realm')
    expect(await screen.findByText('Tenant created and ready to log into.')).toBeInTheDocument()
  })

  it('blocks an obviously malformed realm id client-side (server stays authoritative)', async () => {
    const user = userEvent.setup()
    renderRegister()
    await fillRequired(user)
    await user.type(screen.getByLabelText(/Identity Realm ID/), 'bad realm!')
    await submit(user)
    expect(screen.getByText(/starting with a letter or digit/)).toBeInTheDocument()
    expect(postWithHeaders).not.toHaveBeenCalled()
  })

  it('blank admin and realm fields are omitted from the request body', async () => {
    postWithHeaders.mockResolvedValue(RECORD)
    const user = userEvent.setup()
    renderRegister()
    await fillRequired(user)
    await user.type(screen.getByLabelText(/Admin Username/), '   ')
    await submit(user)
    await waitFor(() => expect(postWithHeaders).toHaveBeenCalledTimes(1))
    const body = postWithHeaders.mock.calls[0]![1] as Record<string, unknown>
    for (const key of ['admin_email', 'admin_username', 'admin_display_name', 'idp_realm_id']) {
      expect(Object.prototype.hasOwnProperty.call(body, key)).toBe(false)
    }
    expect(body['slug']).toBe('acme')
  })
})

describe('OnboardingResultPage ISS-1030', () => {
  function renderResult(result: OnboardingStatusCompleted) {
    return render(
      <MemoryRouter
        initialEntries={[{ pathname: '/admin/onboarding/ob-1/result', state: { sagaResult: result } }]}
      >
        <Routes>
          <Route path="/admin/onboarding/:onboardingId/result" element={<OnboardingResultPage />} />
        </Routes>
      </MemoryRouter>,
    )
  }

  const BASE: OnboardingStatusCompleted = {
    state: 'completed',
    onboarding_id: 'ob-1',
    tenant_id: 't-1',
    hostname: 'acme.example.com',
    slug: 'acme',
    login: RECORD.login as OnboardingStatusCompleted['login'],
  }

  it('administrator values and ignored field names are rendered as text, never as HTML', () => {
    const payload = '<img src=x onerror=alert(1)>'
    renderResult({
      ...BASE,
      administrator: {
        state: 'not_provisioned',
        message: payload,
        not_provisioned: [{ field: 'admin_username', value: payload }],
        next_steps: [],
      },
      ignored_fields: [payload],
    })
    expect(document.querySelector('img')).toBeNull()
    expect(screen.getAllByText(payload, { exact: false }).length).toBeGreaterThanOrEqual(3)
  })

  it('the result view lists not-provisioned fields, ignored fields and the not yet loginable next steps', () => {
    renderResult({
      ...BASE,
      administrator: {
        state: 'not_provisioned',
        message: 'The administrator details you entered were NOT used.',
        not_provisioned: [{ field: 'admin_email', value: 'a@b.example' }],
        next_steps: ['Follow the runbook.'],
      },
      ignored_fields: ['client_config', 'redirect_uris'],
    })
    expect(screen.getByText(/Tenant created, but not yet loginable/)).toBeInTheDocument()
    expect(screen.getByText('Create the realm, then bind it.')).toBeInTheDocument()
    expect(screen.getByText('The administrator details you entered were NOT used.')).toBeInTheDocument()
    expect(screen.getByText('admin_email')).toBeInTheDocument()
    expect(screen.getByText('client_config')).toBeInTheDocument()
    expect(screen.getByText('redirect_uris')).toBeInTheDocument()
  })

  it('bind-realm posts the trimmed realm and switches the view to loginable', async () => {
    post.mockResolvedValue({
      ...RECORD,
      login: { loginable: true, status: 'realm_bound', idp_realm_id: 'acme-realm', next_steps: [] },
    })
    const user = userEvent.setup()
    renderResult({ ...BASE, ignored_fields: ['client_config'] })
    await user.type(screen.getByLabelText('Realm ID'), ' acme-realm ')
    await user.click(screen.getByRole('button', { name: 'Bind realm' }))
    await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
    expect(post.mock.calls[0]![0]).toBe('/api/v1/onboarding/ob-1/bind-realm')
    expect(post.mock.calls[0]![1]).toEqual({ idp_realm_id: 'acme-realm' })
    expect(await screen.findByText('Tenant created and ready to log into.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Bind realm' })).toBeNull()
    // notices from the create response survive the bind
    expect(screen.getByText('client_config')).toBeInTheDocument()
  })

  it('bind-realm shows a fixed message for a server refusal and stays unbound', async () => {
    post.mockRejectedValue({ status: 422, code: '422', message: 'validation failed', details: [
      { field: 'idp_realm_id', constraint: 'not_found', message: 'realm not found' },
    ] })
    const user = userEvent.setup()
    renderResult(BASE)
    await user.type(screen.getByLabelText('Realm ID'), 'ghost')
    await user.click(screen.getByRole('button', { name: 'Bind realm' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('The identity provider does not know this realm.')
    expect(screen.getByText(/Tenant created, but not yet loginable/)).toBeInTheDocument()
  })
})
