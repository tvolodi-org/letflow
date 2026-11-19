// @vitest-environment jsdom
/**
 * GH 4835 -- My Tasks: after a stock post / approval / reversal task is completed, the open panel shows the NEW document
 * state (Posted / Reversed) without a reload. Real api client and hooks; only window.fetch is a fake backend whose document
 * flips state when the completion is received.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderWithAccess } from '@/auth/access/testing'
import { accessState } from '@/auth/access/fixtures'

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

const reply = (status: number, body: unknown) => ({ ok: status < 400, status, statusText: String(status), json: async () => body, text: async () => JSON.stringify(body), headers: { get: () => null } })

function installBackend(node: string, before: string, after: string) {
  let completed = false
  const task = () => ({ id: T1, instance_id: I1, token_id: 't', node_id: node, node_name: node, status: completed ? 'COMPLETED' : 'PENDING', assignee_type: 'USER', assignee_ref: ME, definition_name: 'Stock flow', created_at: new Date(Date.now() - 3 * 60_000).toISOString() })
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    const path = String(url).split('?')[0].replace(/^.*\/api\/v1/, '/api/v1')
    if (path === `/api/v1/tasks/${T1}/complete` && init?.method === 'POST') { completed = true; return reply(200, task()) }
    if (path === '/api/v1/tasks/inbox') return reply(200, { items: [task()], next_cursor: null, count: 1 })
    if (path === `/api/v1/tasks/${T1}`) return reply(200, task())
    if (/\/history$/.test(path)) return reply(200, [{ actor_id: 'someone-else' }])
    if (path.startsWith('/api/v1/instances/')) return reply(200, { id: I1, variables: { document_id: D1, document_type: 'stock_receipt' } })
    if (path === `/api/v1/modules/stock/documents/${D1}`) return reply(200, { id: D1, kind: 'receipt', state: completed ? after : before, number: 'RCP-2026-000009', lines: [] })
    return reply(200, { items: [], next_cursor: null, count: 0 })
  }))
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('My Tasks, document state after completion (GH 4835)', () => {
  it.each([
    ['post', 'issued', 'posted', 'Posted'],
    ['approve', 'issued', 'posted', 'Posted'],
    ['reverse', 'posted', 'reversed', 'Reversed'],
  ])('a %s task: the open panel shows the new state without a reload', async (node, before, after, word) => {
    installBackend(node, before, after)
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    renderWithAccess(
      <QueryClientProvider client={qc}><MemoryRouter><TaskInboxPage /></MemoryRouter></QueryClientProvider>,
      accessState('tenantAdmin', ME),
    )
    const user = userEvent.setup()
    await user.click((await screen.findAllByTestId('task-row'))[0])
    const header = await screen.findByTestId('task-document-header')
    await waitFor(() => expect(within(header).getByText(before === 'issued' ? 'Issued' : 'Posted')).toBeInTheDocument())
    await user.click(await screen.findByTestId('task-complete-button'))
    await waitFor(() => expect(within(screen.getByTestId('task-document-header')).getByText(word)).toBeInTheDocument())
  })
})
