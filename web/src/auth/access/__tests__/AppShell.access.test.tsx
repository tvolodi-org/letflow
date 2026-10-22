// @vitest-environment jsdom
/**
 * AppShell navigation from a mocked GET /me/access (REQ-450 slices 1 and 2b): entries per role and
 * the three sidebar groups (Work, Tenant administration, Platform) for each of the eight roles.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AccessStateProvider } from '../AccessContext'
import { accessState, ACCESS_FIXTURES, ERROR_STATE, LOADING_STATE, type AccessFixtureName } from '../fixtures'
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

function groupLabels(): string[] {
  return screen.queryAllByRole('group').map(g => g.getAttribute('aria-label') ?? '')
}

function linksIn(group: string): string[] {
  return Array.from(screen.getByRole('group', { name: group }).querySelectorAll('a')).map(a => a.textContent ?? '')
}

// Expected sidebar groups for each fixture role (the grant matrix in fixtures.ts decides).
const WORK = 'Work'
const TENANT_ADMIN = 'Tenant administration'
const PLATFORM = 'Platform'
const GROUPS_BY_ROLE: Record<AccessFixtureName, string[]> = {
  platformAdmin: [WORK, TENANT_ADMIN, PLATFORM],
  tenantAdmin: [WORK, TENANT_ADMIN],
  designer: [WORK],
  operator: [WORK, TENANT_ADMIN],
  taskWorker: [WORK],
  auditor: [WORK, TENANT_ADMIN],
  agentRunner: [],
  candidate: [],
}

describe('AppShell nav groups from /me/access (GH 2238 slice 2b)', () => {
  it.each(Object.keys(ACCESS_FIXTURES) as AccessFixtureName[])('%s: renders exactly the expected groups', (name) => {
    renderShell(accessState(name))
    expect(groupLabels()).toEqual(GROUPS_BY_ROLE[name])
  })

  it('non-platform tenant admin: Tenant administration, no Platform group or entry', () => {
    renderShell(accessState('tenantAdmin'))
    expect(groupLabels()).not.toContain(PLATFORM)
    expect(linksIn(TENANT_ADMIN)).toEqual(expect.arrayContaining(['Users', 'Groups', 'Tokens', 'Audit']))
    for (const l of PLATFORM_ENTRIES) expect(navLabels()).not.toContain(l)
  })

  it('platform-tenant platform admin: all three groups with their entries', () => {
    renderShell(accessState('platformAdmin'))
    expect(linksIn(WORK)).toEqual(['Instances', 'My Tasks', 'Definitions'])
    expect(linksIn(TENANT_ADMIN)).toEqual(expect.arrayContaining(['Users', 'Tokens', 'Audit', 'Promotion Reviews']))
    expect(linksIn(PLATFORM)).toEqual(expect.arrayContaining(PLATFORM_ENTRIES))
  })

  it('auditor: read pages only (no write-surface entries, no Platform group)', () => {
    renderShell(accessState('auditor'))
    expect(linksIn(WORK)).toEqual(['Instances', 'My Tasks', 'Definitions'])
    expect(linksIn(TENANT_ADMIN)).toEqual(['Promotion Reviews', 'Audit', 'Metrics'])
  })

  it('task worker: neither admin group', () => {
    renderShell(accessState('taskWorker'))
    expect(groupLabels()).not.toContain(TENANT_ADMIN)
    expect(groupLabels()).not.toContain(PLATFORM)
  })

  it.each([
    ['loading', LOADING_STATE],
    ['error', ERROR_STATE],
  ])('while /me/access is %s no group renders', (_name, state) => {
    renderShell(state)
    expect(groupLabels()).toEqual([])
  })
})
