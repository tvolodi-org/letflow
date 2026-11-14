// @vitest-environment jsdom
/**
 * T-1969 -- a 409 module-upgrade-required on task complete shows the real reason, never 'Try again'.
 *
 * End to end: @/api/tasks and the api client are REAL; only window.fetch is
 * stubbed (URL router returning the backend's literal 409 body), so these
 * tests fail if the task error mapping is removed. (vi.mock is file-wide, so
 * the earlier isolated cases that mocked @/api/tasks were dropped.)
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { TASK_MESSAGES } from '@/pages/tasks/taskMessages'

expect.extend(jestDomMatchers)

const events = vi.fn()

vi.mock('@/api/instances', () => ({
  instancesApi: {
    events: (...args: unknown[]) => events(...args),
    list: vi.fn(),
    get: vi.fn(),
    start: vi.fn(),
    cancel: vi.fn(),
  },
}))

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 'header.' + btoa(JSON.stringify({ sub: 'marco-id' })) + '.sig',
        display_name: 'Marco',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-1',
        tenant_type: null,
      },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import TaskInboxPage from '@/pages/tasks/TaskInboxPage'
import { renderWithAccess } from '@/auth/access/testing'
import { accessState, type AccessFixtureName } from '@/auth/access/fixtures'

const TASK_ID = 'task-sod-1'

function row(assignee_ref: string, assignee_type: string) {
  return {
    id: TASK_ID,
    instance_id: 'inst-1',
    token_id: 'tok-1',
    node_id: 'node-1',
    node_name: 'Approve',
    status: 'PENDING',
    assignee_ref,
    assignee_type,
    created_at: '2026-09-24T08:00:00Z',
  }
}

type Route = { ok: boolean; status: number; statusText: string; body: unknown }
type PostRoute = { suffix: string; response: Route }

const ok200 = (body: unknown): Route => ({ ok: true, status: 200, statusText: 'OK', body })
function stubFetch(task: ReturnType<typeof row>, postRoute: PostRoute) {
  const calls: string[] = []
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string, init?: RequestInit) => {
      const method = init?.method ?? 'GET'
      const path = String(url).split('?')[0]
      calls.push(`${method} ${path}`)
      let r: Route
      if (method === 'POST' && path.endsWith(postRoute.suffix)) {
        r = postRoute.response
      } else if (method === 'GET' && path.endsWith('/api/v1/tasks/inbox')) {
        r = ok200({ items: [task], next_cursor: null, count: 1 })
      } else if (method === 'GET' && path.endsWith(`/api/v1/tasks/${TASK_ID}`)) {
        r = ok200(task)
      } else {
        r = ok200({ items: [], next_cursor: null, count: 0 })
      }
      return {
        ok: r.ok,
        status: r.status,
        statusText: r.statusText,
        json: async () => r.body,
        text: async () => JSON.stringify(r.body),
        headers: { get: () => null },
      }
    }),
  )
  return calls
}

function renderPage(access: AccessFixtureName = 'platformAdmin') {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <TaskInboxPage />
      </MemoryRouter>
    </QueryClientProvider>,
    accessState(access, 'marco-id'),
  )
}

async function openPanel(
  task: ReturnType<typeof row>,
  postRoute: PostRoute,
  access: AccessFixtureName = 'platformAdmin',
) {
  const calls = stubFetch(task, postRoute)
  events.mockResolvedValue({ items: [], next_cursor: null, count: 0 })
  renderPage(access)
  const user = userEvent.setup()
  await waitFor(() => expect(screen.getByTestId('task-row')).toBeInTheDocument())
  await user.click(screen.getByTestId('task-row'))
  await waitFor(() => expect(screen.getByTestId('task-detail-panel')).toBeInTheDocument())
  return { user, calls }
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.clearAllMocks()
})

const UPGRADE_BODY = {
  type: 'https://letflow.dev/problems/module-upgrade-required',
  title: 'Module Upgrade Required',
  status: 409,
  detail: 'the installed module differs from the current version; upgrade it instead',
  code: 'upgrade_required',
}

describe('task complete refused with 409 module-upgrade-required (T-1969)', () => {
  it('shows the upgrade reason and not the generic retry text', async () => {
    const { user } = await openPanel(row('marco-id', 'USER'), {
      suffix: `/api/v1/tasks/${TASK_ID}/complete`,
      response: { ok: false, status: 409, statusText: 'Conflict', body: UPGRADE_BODY },
    })
    await user.click(await screen.findByTestId('task-complete-button'))
    const alert = await screen.findByTestId('task-error')
    expect(alert).toHaveTextContent(TASK_MESSAGES.en.errModuleUpgrade)
    expect(alert).not.toHaveTextContent(TASK_MESSAGES.en.errGeneric)
  })
})
