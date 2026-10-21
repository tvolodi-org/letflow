// @vitest-environment jsdom
/**
 * AppShell navigation from a mocked GET /me/access (REQ-450 slice 1). The group structure and the
 * remaining roles' shells are the remainder of GH #2238.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AccessStateProvider } from '../AccessContext'
import { accessState, ERROR_STATE, LOADING_STATE } from '../fixtures'
import type { AccessState } from '../types'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({ useQuery: vi.fn(() => ({ data: undefined })) }))
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 'tok',
      display_name: 'Test User',
      loginSource: null,
      tenant_slug: 'fixture-co',
      tenant_display_name: 'Fixture Co',
      tenant_id: 'tid-fixture-co',
      tenant_type: 'production',
      production_tenant_display_name: null,
    },
    logout: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  }),
}))
vi.mock('@/hooks/useInstalledModules', () => ({ useInstalledModules: () => ({ data: [] }) }))
vi.mock('@/api/client', () => ({ client: { get: vi.fn(() => Promise.resolve({ items: [] })) } }))

import { AppShell } from '@/components/layout/AppShell'

afterEach(cleanup)

const PLATFORM_ENTRIES = ['Tenants', 'Register Tenant', 'Services', 'Health', 'Platform Migrations', 'Event Retention']
const ADMIN_ENTRIES = ['Users', 'Groups', 'Tokens', 'Webhooks', 'DLQ', 'Audit', 'Metrics', 'Definitions', 'Instances', 'My Tasks']

function renderShell(state: AccessState) {
  return render(
    <MemoryRouter initialEntries={['/instances']}>
      <AccessStateProvider state={state}>
        <AppShell />
      </AccessStateProvider>
    </MemoryRouter>,
  )
}

function navLabels(): string[] {
  return screen.queryAllByRole('link').map(a => a.textContent ?? '')
}

describe('AppShell nav from /me/access', () => {
  it('tenant admin (not the platform tenant): admin entries, no platform entries', () => {
    renderShell(accessState('tenantAdmin'))
    const labels = navLabels()
    for (const l of ADMIN_ENTRIES) expect(labels).toContain(l)
    for (const l of PLATFORM_ENTRIES) expect(labels).not.toContain(l)
  })

  it('platform admin: platform entries are shown too', () => {
    renderShell(accessState('platformAdmin'))
    const labels = navLabels()
    for (const l of [...ADMIN_ENTRIES, ...PLATFORM_ENTRIES]) expect(labels).toContain(l)
  })

  it('auditor: read entries only', () => {
    renderShell(accessState('auditor'))
    const labels = navLabels()
    expect(labels).toContain('Audit')
    expect(labels).toContain('Metrics')
    for (const l of ['Users', 'Groups', 'Tokens', 'Webhooks', 'DLQ', ...PLATFORM_ENTRIES]) expect(labels).not.toContain(l)
  })

  it('task worker: no admin entries', () => {
    renderShell(accessState('taskWorker'))
    const labels = navLabels()
    expect(labels).toContain('My Tasks')
    for (const l of ['Users', 'Groups', 'Tokens', 'Webhooks', 'DLQ', 'Audit', ...PLATFORM_ENTRIES]) {
      expect(labels).not.toContain(l)
    }
  })

  it.each([
    ['loading', LOADING_STATE],
    ['error', ERROR_STATE],
  ])('while /me/access is %s no nav entry renders, but the shell chrome does', (_name, state) => {
    renderShell(state)
    expect(navLabels()).toEqual([])
    expect(screen.getByTestId('logout-button')).toBeInTheDocument()
    expect(screen.getByTestId('user-roles')).toHaveTextContent('')
  })
})
