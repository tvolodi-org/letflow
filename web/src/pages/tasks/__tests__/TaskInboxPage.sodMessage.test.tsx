// @vitest-environment jsdom
/**
 * GH 2355 / ISS-1034 -- the REQ-463 separation-of-duties refusal on task
 * complete / claim renders a worker-readable alert in TaskDetailPanel.
 * Harness follows TaskInboxPage.test.tsx (mock @/api/tasks, mount the page).
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import {
  SEPARATION_OF_DUTIES_MESSAGE,
  SEPARATION_OF_DUTIES_CLAIM_MESSAGE,
} from '@/api/client'

expect.extend(jestDomMatchers)

const inbox = vi.fn()
const getTask = vi.fn()
const events = vi.fn()
const completeFn = vi.fn()
const assignFn = vi.fn()

vi.mock('@/api/tasks', () => ({
  tasksApi: {
    inbox: (...args: unknown[]) => inbox(...args),
    list: (...args: unknown[]) => inbox(...args),
    get: (...args: unknown[]) => getTask(...args),
    complete: (...args: unknown[]) => completeFn(...args),
    assign: (...args: unknown[]) => assignFn(...args),
    reassign: vi.fn(),
  },
}))

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
        roles: ['PLATFORM_ADMIN'],
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-1',
        tenant_type: null,
        production_tenant_display_name: null,
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

function renderPage() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <TaskInboxPage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

async function openPanel(task: ReturnType<typeof row>) {
  inbox.mockResolvedValue({ items: [task], next_cursor: null, count: 1 })
  getTask.mockResolvedValue(task)
  events.mockResolvedValue({ items: [], next_cursor: null, count: 0 })
  renderPage()
  const user = userEvent.setup()
  await waitFor(() => expect(screen.getByTestId('task-row')).toBeInTheDocument())
  await user.click(screen.getByTestId('task-row'))
  await waitFor(() => expect(screen.getByTestId('task-detail-panel')).toBeInTheDocument())
  return user
}

const sodError = {
  status: 403,
  code: 'SEPARATION_OF_DUTIES',
  message: SEPARATION_OF_DUTIES_MESSAGE,
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('TaskDetailPanel -- separation-of-duties refusal (GH 2355)', () => {
  it('complete refused with SoD shows the alert with the message', async () => {
    completeFn.mockRejectedValue(sodError)
    const user = await openPanel(row('marco-id', 'USER'))
    await user.click(await screen.findByTestId('task-complete-button'))
    const alert = await screen.findByTestId('task-sod-error')
    expect(alert).toHaveAttribute('role', 'alert')
    expect(alert).toHaveTextContent(SEPARATION_OF_DUTIES_MESSAGE)
  })

  it('claim refused with SoD shows the claim-specific alert', async () => {
    assignFn.mockRejectedValue(sodError)
    const user = await openPanel(row('some-group', 'GROUP'))
    await user.click(await screen.findByTestId('task-claim-button'))
    const alert = await screen.findByTestId('task-sod-error')
    expect(alert).toHaveTextContent(SEPARATION_OF_DUTIES_CLAIM_MESSAGE)
  })

  it('a plain 403 Forbidden shows no SoD alert', async () => {
    completeFn.mockRejectedValue({ status: 403, code: '403', message: 'Forbidden' })
    const user = await openPanel(row('marco-id', 'USER'))
    await user.click(await screen.findByTestId('task-complete-button'))
    await waitFor(() => expect(completeFn).toHaveBeenCalled())
    expect(screen.queryByTestId('task-sod-error')).not.toBeInTheDocument()
  })

  it('a successful complete shows no SoD alert', async () => {
    completeFn.mockResolvedValue(row('marco-id', 'USER'))
    const user = await openPanel(row('marco-id', 'USER'))
    await user.click(await screen.findByTestId('task-complete-button'))
    await waitFor(() => expect(completeFn).toHaveBeenCalled())
    expect(screen.queryByTestId('task-sod-error')).not.toBeInTheDocument()
  })
})
