// @vitest-environment jsdom
/**
 * T-1952 -- My Tasks for an asset opening: the line shows the card's inventory number and name (and the location in
 * the panel), never the card id. Real api client and hooks; only window.fetch is a fake backend.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderWithAccess } from '@/auth/access/testing'
import { accessState } from '@/auth/access/fixtures'
import { noUuidInDom } from '@/test-utils/noUuidInDom'

expect.extend(jestDomMatchers)

const ME = '11111111-2222-4333-8444-555555555555'

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: { token: 'h.' + btoa(JSON.stringify({ sub: ME })) + '.s', display_name: 'U', loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null, tenant_id: 'tenant-1', tenant_type: null },
      isAuthenticated: true, isLoading: false, loginSource: 'oidc' as const, login: vi.fn(), logout: vi.fn(), setSession: vi.fn(),
    }),
  }
})

import TaskInboxPage from '@/pages/tasks/TaskInboxPage'

const T1 = 'cccccccc-0000-4000-8000-0000000000a1'
const I1 = 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000a1'
const D1 = 'dddddddd-1111-4222-8333-0000000000a1'
const ORG = 'bbbbbbbb-1111-4222-8333-0000000000a1'
const LOC = 'bbbbbbbb-1111-4222-8333-0000000000a2'
const CARD1 = 'c1410ee1-22ac-4d2f-b180-98447bf9e940'
const CARD2 = 'c1410ee1-22ac-4d2f-b180-98447bf9e941'

const task = { id: T1, instance_id: I1, token_id: 't', node_id: 'approve', node_name: 'approve', status: 'PENDING', assignee_type: 'ROLE', assignee_ref: 'asset_approver', definition_name: 'Asset opening flow', created_at: new Date(Date.now() - 3 * 60_000).toISOString() }
const doc = {
  id: D1, kind: 'opening', state: 'issued', number: 'AOP-2026-000001', org_unit_id: ORG,
  lines: [
    { line_no: 1, asset_id: CARD1, quantity: '1.000000000', location_id: LOC },
    { line_no: 2, asset_id: CARD2, quantity: '4.000000000', location_id: LOC },
  ],
}
const MASTER: Record<string, Record<string, unknown>> = {
  [ORG]: { code: 'WH-1', name: 'Warehouse team' },
  [LOC]: { code: 'A-01', name: 'Rack A' },
  [CARD1]: { inventory_number: 'FA-0101', name: 'Delivery van' },
  [CARD2]: { inventory_number: 'LV-0201', name: 'Monitor' },
}

const reply = (status: number, body: unknown) => ({ ok: status < 400, status, statusText: String(status), json: async () => body, text: async () => JSON.stringify(body), headers: { get: () => null } })

function installBackend() {
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    const path = String(url).split('?')[0].replace(/^.*\/api\/v1/, '/api/v1')
    if (path === '/api/v1/tasks/inbox') return reply(200, { items: [task], next_cursor: null, count: 1 })
    if (path === `/api/v1/tasks/${T1}`) return reply(200, task)
    if (/\/history$/.test(path)) return reply(200, [{ actor_id: ME }])
    if (path.startsWith('/api/v1/instances/')) return reply(200, { id: I1, variables: { document_id: D1, document_type: 'assets_opening' } })
    if (path === `/api/v1/modules/assets/documents/${D1}`) return reply(200, doc)
    if (path === '/api/v1/entities/query') {
      const b = JSON.parse(String(init?.body)) as { entity_type: string; filters: { value: string[] }[] }
      const items = b.filters[0].value.filter((id) => MASTER[id]).map((id) => ({ record_id: id, entity_type: b.entity_type, field_values: MASTER[id], deleted: false }))
      return reply(200, { items, next_cursor: null })
    }
    return reply(200, { items: [], next_cursor: null, count: 0 })
  }))
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('My Tasks, asset opening (T-1952)', () => {
  it('the row and the panel show the card number and name, and the location, not the card id', async () => {
    installBackend()
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    const { container } = renderWithAccess(
      <QueryClientProvider client={qc}><MemoryRouter><TaskInboxPage /></MemoryRouter></QueryClientProvider>,
      accessState('tenantAdmin', ME),
    )
    await waitFor(() => expect(screen.getAllByTestId('task-lines-summary')[0]).toHaveTextContent('2 lines: FA-0101 - Delivery van × 1, +1 more'))
    const user = userEvent.setup()
    await user.click((await screen.findAllByTestId('task-row'))[0])
    const lines = await screen.findByTestId('task-document-lines')
    await waitFor(() => expect(within(lines).getByText('FA-0101 - Delivery van')).toBeInTheDocument())
    expect(within(lines).getByText('LV-0201 - Monitor')).toBeInTheDocument()
    expect(within(lines).getAllByText('A-01 - Rack A')).toHaveLength(2)
    expect(container.textContent).not.toContain(CARD1)
    expect(noUuidInDom(container)).toBe(true)
  })
})
