// @vitest-environment jsdom
/**
 * REQ-392 AC5 — the approval/decision screen renders the reviewed
 * attachment's `file_name` for a COMPLETED task, sourced from the
 * TASK_COMPLETED history event's `attachments_at_decision` snapshot.
 *
 * `TaskDetailPanel` (design §7, lib/letflow/design/req392-attachment-management-ui.md)
 * is the approval/decision screen -- it is a module-local function inside
 * `TaskInboxPage.tsx`, not separately exported, so this test mounts the
 * page's default export and drives it through the task list the same way a
 * real user would (click a task row to open the detail panel).
 *
 * Mocks @/api/tasks and @/api/instances directly (same
 * mock-the-api-client-not-the-hook pattern AttachmentPanel.test.tsx already
 * established) -- `useTask` calls `tasksApi.get`, and
 * `useTaskCompletionAttachments` calls `instancesApi.events` (design §7.1,
 * reusing the already-shipped, mistyped-but-working client function and its
 * `.items`-unwrap runtime pattern).
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor } from '@testing-library/react'
import { renderWithAccess } from '@/auth/access/testing'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

expect.extend(jestDomMatchers)

const inbox = vi.fn()
const getTask = vi.fn()
const events = vi.fn()

vi.mock('@/api/tasks', () => ({
  tasksApi: {
    inbox: (...args: unknown[]) => inbox(...args),
    list: (...args: unknown[]) => inbox(...args),
    get: (...args: unknown[]) => getTask(...args),
    complete: vi.fn(),
    assign: vi.fn(),
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

const INSTANCE_ID = 'inst-shipment-1'
const TASK_ID = 'task-review-1'

function taskRow(status: 'PENDING' | 'COMPLETED') {
  return {
    id: TASK_ID,
    instance_id: INSTANCE_ID,
    token_id: 'tok-1',
    node_id: 'node-review',
    node_name: 'Ops review',
    status,
    assignee_ref: 'marco-id',
    assignee_type: 'USER',
    created_at: '2026-09-24T08:00:00Z',
  }
}

function taskCompletedEvent(attachmentsAtDecision: Array<{ attachment_id: string; file_name: string }>) {
  return {
    event_id: 'evt-completed-1',
    event_type: 'TASK_COMPLETED',
    instance_id: INSTANCE_ID,
    sequence_number: 9,
    global_seq: 9,
    idempotency_key: 'idem-1',
    metadata: {},
    created_at: '2026-09-24T09:00:00Z',
    payload: {
      task_id: TASK_ID,
      attachments_at_decision: attachmentsAtDecision,
    },
  }
}

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <TaskInboxPage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('TaskDetailPanel — AC5 reviewed-attachment file_name on a COMPLETED task', () => {
  it('renders the reviewed attachment file_name for a COMPLETED task, sourced from attachments_at_decision', async () => {
    inbox.mockResolvedValue({ items: [taskRow('COMPLETED')], next_cursor: null, count: 1 })
    getTask.mockResolvedValue(taskRow('COMPLETED'))
    events.mockResolvedValue({
      items: [taskCompletedEvent([{ attachment_id: 'att-9', file_name: 'delivery-note-hamburg-signed-corrected.pdf' }])],
      next_cursor: null,
      count: 1,
    })

    renderPage()

    const user = userEvent.setup()
    await waitFor(() => expect(screen.getByTestId('task-row')).toBeInTheDocument())
    await user.click(screen.getByTestId('task-row'))

    await waitFor(() => expect(screen.getByTestId('task-detail-panel')).toBeInTheDocument())

    const decisionBlock = await screen.findByTestId('task-decision-attachments')
    expect(decisionBlock).toHaveTextContent('delivery-note-hamburg-signed-corrected.pdf')
    expect(decisionBlock).toHaveTextContent('Reviewed document:')

    // Sourced from the TASK_COMPLETED event's own payload.task_id match --
    // not any other event.
    expect(events).toHaveBeenCalledWith(INSTANCE_ID, { event_type: 'TASK_COMPLETED' })
  })

  it('renders nothing for a PENDING task (no decision yet, no premature fetch of the completion snapshot)', async () => {
    inbox.mockResolvedValue({ items: [taskRow('PENDING')], next_cursor: null, count: 1 })
    getTask.mockResolvedValue(taskRow('PENDING'))

    renderPage()

    const user = userEvent.setup()
    await waitFor(() => expect(screen.getByTestId('task-row')).toBeInTheDocument())
    await user.click(screen.getByTestId('task-row'))

    await waitFor(() => expect(screen.getByTestId('task-detail-panel')).toBeInTheDocument())

    expect(screen.queryByTestId('task-decision-attachments')).not.toBeInTheDocument()
    // The completion-snapshot fetch is `enabled` only for a COMPLETED task
    // (design §7.1) -- a PENDING task must not trigger it at all.
    expect(events).not.toHaveBeenCalled()
  })
})
