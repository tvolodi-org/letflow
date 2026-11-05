// @vitest-environment jsdom
/** T-1378 — My Tasks shows what a task is about (document number and kind) and who has it, never an id. Real-shaped data:
 *  uuid instance and assignee ids, the instance's process variables carry the document id, the document answers its number. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { renderWithAccess } from '@/auth/access/testing'
import { accessState } from '@/auth/access/fixtures'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { noUuidInDom } from '@/test-utils/noUuidInDom'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'

expect.extend(jestDomMatchers)

const inbox = vi.fn()
const getTask = vi.fn()
const getInstance = vi.fn()
const getDocument = vi.fn()

vi.mock('@/api/tasks', () => ({
  tasksApi: {
    inbox: (...a: unknown[]) => inbox(...a),
    list: (...a: unknown[]) => inbox(...a),
    get: (...a: unknown[]) => getTask(...a),
    complete: vi.fn(), assign: vi.fn(), reassign: vi.fn(),
  },
}))
vi.mock('@/api/instances', () => ({
  instancesApi: { events: vi.fn().mockResolvedValue({ items: [], next_cursor: null }), get: (...a: unknown[]) => getInstance(...a), list: vi.fn(), start: vi.fn(), cancel: vi.fn() },
}))
vi.mock('@/api/client', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  client: { get: (path: string) => getDocument(path) },
}))

const ME = '11111111-2222-4333-8444-555555555555'
const OTHER = '66666666-7777-4888-8999-000000000000'
const INST = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
const INST2 = 'aaaaaaaa-bbbb-4ccc-8ddd-ffffffffffff'
const DOC = 'dddddddd-1111-4222-8333-444444444444'

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 'header.' + btoa(JSON.stringify({ sub: '11111111-2222-4333-8444-555555555555' })) + '.sig',
        display_name: 'Me', loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null, tenant_id: 'tenant-1', tenant_type: null,
      },
      isAuthenticated: true, isLoading: false, loginSource: 'oidc' as const, login: vi.fn(), logout: vi.fn(), setSession: vi.fn(),
    }),
  }
})

import TaskInboxPage from '@/pages/tasks/TaskInboxPage'

const task = (id: string, instance: string, assignee: string) => ({
  id, instance_id: instance, token_id: 't', node_id: 'n', node_name: 'Post document', status: 'PENDING',
  assignee_ref: assignee, assignee_type: 'USER', created_at: '2026-11-05T08:00:00Z',
})

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={['/?filter=all']}><TaskInboxPage /></MemoryRouter>
    </QueryClientProvider>,
    accessState('platformAdmin', '11111111-2222-4333-8444-555555555555'),
  )
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  useUiLocaleStore.getState().setLocaleTransient('en')
})

describe('My Tasks subjects', () => {
  it('shows "number - kind" and You / Another user; no uuid in the list or the panel', async () => {
    const t1 = task('cccccccc-0000-4000-8000-000000000001', INST, ME)
    const t2 = task('cccccccc-0000-4000-8000-000000000002', INST2, OTHER)
    inbox.mockResolvedValue({ items: [t1, t2], next_cursor: null, count: 2 })
    getTask.mockResolvedValue(t1)
    getInstance.mockImplementation(async (id: string) =>
      id === INST ? { id, variables: { document_id: DOC, document_type: 'stock_receipt' } } : { id, variables: {} })
    getDocument.mockResolvedValue({ id: DOC, number: 'RC-2026-0007' })
    const { container } = renderPage()
    await waitFor(() => expect(screen.getAllByTestId('task-instance-id')[0]).toHaveTextContent('RC-2026-0007 - Receipt'))
    expect(getDocument).toHaveBeenCalledWith(`/api/v1/modules/stock/documents/${DOC}`)
    const assignees = screen.getAllByTestId('task-assignee').map((e) => e.textContent)
    expect(assignees).toEqual(['You', 'Another user'])
    // a process with no document: the unknown text, not the instance id
    await waitFor(() => expect(screen.getAllByTestId('task-instance-id')[1]).toHaveTextContent('Unknown record'))
    expect(noUuidInDom(container)).toBe(true)
    await userEvent.click(screen.getAllByTestId('task-row')[0])
    await screen.findByTestId('task-detail-panel')
    await waitFor(() => expect(screen.getByTestId('instance-id')).toHaveTextContent('RC-2026-0007 - Receipt'))
    expect(noUuidInDom(container)).toBe(true)
  })

  it('a failing lookup shows "Unknown record" (ru: Запись недоступна)', async () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    inbox.mockResolvedValue({ items: [task('cccccccc-0000-4000-8000-000000000003', INST, ME)], next_cursor: null, count: 1 })
    getInstance.mockRejectedValue({ status: 500 })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('task-instance-id')).toHaveTextContent('Запись недоступна'))
    expect(screen.getByTestId('task-assignee')).toHaveTextContent('Вы')
  })
})
