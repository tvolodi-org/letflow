// @vitest-environment jsdom
/**
 * T-1380 / GATE B R3 -- My Tasks for the stock flows, through the REAL path (D-098): the real api client, tasksApi and
 * hooks; only window.fetch is a stateful fake backend answering the routes by URL with uuid-shaped data. Two sessions
 * (the issuer and a second administrator) work the same document.
 *
 * T1 default view lists the open post / approve tasks (was empty)   T2 row content, no uuid
 * T3 detail: document header and lines, read-only                   T4 claim posts /claim, then Post; complete; toasts
 * T5 issuer: hint + SoD refusal readable (en/ru/kk)                 T6 second user claims and completes (full flow)
 * T7 insufficient_stock refusal readable                            T8 empty state   T9 loading   T10 error + retry
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderWithAccess } from '@/auth/access/testing'
import { accessState, type AccessFixtureName } from '@/auth/access/fixtures'
import { noUuidInDom } from '@/test-utils/noUuidInDom'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { ToastContainer } from '@/components/ui/Toast'

expect.extend(jestDomMatchers)

const ISSUER = '11111111-2222-4333-8444-555555555555'
const SECOND = '66666666-7777-4888-8999-000000000000'
let currentSub = ISSUER

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: { token: 'h.' + btoa(JSON.stringify({ sub: currentSub })) + '.s', display_name: 'U', loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null, tenant_id: 'tenant-1', tenant_type: null },
      isAuthenticated: true, isLoading: false, loginSource: 'oidc' as const, login: vi.fn(), logout: vi.fn(), setSession: vi.fn(),
    }),
  }
})

import TaskInboxPage from '@/pages/tasks/TaskInboxPage'
import { TASK_MESSAGES } from '@/pages/tasks/taskMessages'
import { tasksApi } from '@/api/tasks'

const T_POST = 'cccccccc-0000-4000-8000-000000000001'
const T_APPROVE = 'cccccccc-0000-4000-8000-000000000002'
const I_POST = 'aaaaaaaa-bbbb-4ccc-8ddd-000000000001'
const I_APPROVE = 'aaaaaaaa-bbbb-4ccc-8ddd-000000000002'
const D_POST = 'dddddddd-1111-4222-8333-000000000001'
const D_APPROVE = 'dddddddd-1111-4222-8333-000000000002'
const ORG = 'bbbbbbbb-1111-4222-8333-000000000001'
const LOC = 'bbbbbbbb-1111-4222-8333-000000000002'
const ITEM = 'bbbbbbbb-1111-4222-8333-000000000003'
const UOM = 'bbbbbbbb-1111-4222-8333-000000000004'

interface World {
  tasks: Record<string, Record<string, unknown>>
  claimRefusal: { status: number; body: unknown } | null
  completeRefusal: { status: number; body: unknown } | null
  inboxFails: boolean
  calls: string[]
}

function task(id: string, instance: string, node: string, over: Record<string, unknown> = {}) {
  return {
    id, instance_id: instance, token_id: 't', node_id: node, node_name: node, status: 'PENDING', assignee_type: 'ROLE', assignee_ref: 'stock_keeper',
    definition_name: 'Stock document flow', created_at: new Date(Date.now() - 3 * 60_000).toISOString(), ...over,
  }
}

let world: World
function freshWorld(): World {
  return {
    tasks: { [T_POST]: task(T_POST, I_POST, 'post', { assignee_type: undefined, assignee_ref: undefined }), [T_APPROVE]: task(T_APPROVE, I_APPROVE, 'approve') },
    claimRefusal: null, completeRefusal: null, inboxFails: false, calls: [],
  }
}

const doc = (id: string, number: string) => ({
  id, kind: 'issue', state: 'draft', number, org_unit_id: ORG, location_id: LOC, event_time: '2026-11-05T08:00:00Z',
  lines: [{ line_no: 1, catalog_item_id: ITEM, catalog_uom_id: UOM, catalog_lot_id: null, quantity: '2.000000000' }, { line_no: 2, catalog_item_id: ITEM, catalog_uom_id: UOM, catalog_lot_id: null, quantity: '1.000' }],
})
const MASTER: Record<string, Record<string, unknown>> = {
  [ORG]: { code: 'WH-1', name: 'Warehouse team' }, [LOC]: { code: 'A-01', name: 'Rack A' }, [ITEM]: { code: 'LAP-01', name: 'Laptop' }, [UOM]: { code: 'pcs' },
}

function reply(status: number, body: unknown) {
  return { ok: status < 400, status, statusText: String(status), json: async () => body, text: async () => JSON.stringify(body), headers: { get: () => null } }
}

function installBackend() {
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    const method = init?.method ?? 'GET'
    const path = String(url).split('?')[0].replace(/^.*\/api\/v1/, '/api/v1')
    world.calls.push(`${method} ${path}`)
    if (method === 'GET' && path === '/api/v1/tasks/inbox') {
      return world.inboxFails ? reply(500, { title: 'boom' }) : reply(200, { items: Object.values(world.tasks), next_cursor: null, count: 2 })
    }
    let m = path.match(/^\/api\/v1\/tasks\/([^/]+)(?:\/(claim|complete))?$/)
    if (m) {
      const t = world.tasks[m[1]]
      if (method === 'GET') return reply(200, t)
      if (m[2] === 'claim') {
        if (world.claimRefusal) return reply(world.claimRefusal.status, world.claimRefusal.body)
        world.tasks[m[1]] = { ...t, assignee_type: 'USER', assignee_ref: currentSub }
        return reply(200, world.tasks[m[1]])
      }
      if (m[2] === 'complete') {
        if (world.completeRefusal) return reply(world.completeRefusal.status, world.completeRefusal.body)
        world.tasks[m[1]] = { ...t, status: 'COMPLETED' }
        return reply(200, world.tasks[m[1]])
      }
    }
    m = path.match(/^\/api\/v1\/instances\/([^/]+)(\/history)?$/)
    if (m) {
      if (m[2]) return reply(200, [{ actor_id: ISSUER }])
      const isPost = m[1] === I_POST
      return reply(200, { id: m[1], variables: { document_id: isPost ? D_POST : D_APPROVE, document_type: 'stock_issue' } })
    }
    m = path.match(/^\/api\/v1\/modules\/stock\/documents\/([^/]+)$/)
    if (m) return reply(200, m[1] === D_POST ? doc(D_POST, 'ISS-2026-0001') : doc(D_APPROVE, 'ISS-2026-0002'))
    if (path === '/api/v1/entities/query') {
      const b = JSON.parse(String(init?.body)) as { entity_type: string; filters: { value: string[] }[] }
      const ids = b.filters[0].value
      return reply(200, { items: ids.filter((id) => MASTER[id]).map((id) => ({ record_id: id, entity_type: b.entity_type, field_values: MASTER[id], deleted: false })), next_cursor: null })
    }
    return reply(200, { items: [], next_cursor: null, count: 0 })
  }))
}

function renderPage(sub = ISSUER, access: AccessFixtureName = 'tenantAdmin', tokenSub = sub) {
  currentSub = tokenSub
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter><TaskInboxPage /><ToastContainer /></MemoryRouter>
    </QueryClientProvider>,
    accessState(access, sub),
  )
}

beforeEach(() => {
  world = freshWorld()
  installBackend()
})
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
  useUiLocaleStore.getState().setLocaleTransient('en')
})

describe('My Tasks, stock flows (GATE B R3)', () => {
  it('T1 the default view of a tenant admin lists the unassigned post task and the role approve task, with counts', async () => {
    renderPage()
    const rows = await screen.findAllByTestId('task-row')
    expect(rows).toHaveLength(2)
    expect(screen.getAllByTestId('task-name').map((e) => e.textContent).sort()).toEqual(['Approve', 'Post'])
    expect(screen.getByTestId('task-filter-count-me')).toHaveTextContent('2')
    expect(screen.getByTestId('task-filter-count-group')).toHaveTextContent('2')
  })

  it('T2 a row shows document, org unit and location as code - title, issuer, age and lines; no uuid', async () => {
    const { container } = renderPage()
    await waitFor(() => expect(screen.getAllByTestId('task-instance-id')[0]).toHaveTextContent(/ISS-2026-000\d - Issue/))
    await waitFor(() => expect(container.textContent).toContain('WH-1 - Warehouse team'))
    expect(container.textContent).toContain('A-01 - Rack A')
    await waitFor(() => expect(screen.getAllByTestId('task-issuer')[0]).toHaveTextContent('You'))
    expect(screen.getAllByTestId('task-age')[0]).toHaveTextContent(/3 minutes ago/)
    await waitFor(() => expect(screen.getAllByTestId('task-lines-summary')[0]).toHaveTextContent('2 lines: LAP-01 - Laptop × 2 pcs, +1 more'))
    expect(noUuidInDom(container)).toBe(true)
  })

  it('T3 the detail shows the document header and lines read-only, no uuid', async () => {
    const { container } = renderPage()
    const user = userEvent.setup()
    await user.click((await screen.findAllByTestId('task-row')).find((r) => r.getAttribute('data-task-id') === T_APPROVE)!)
    const lines = await screen.findByTestId('task-document-lines')
    await waitFor(() => expect(within(lines).getAllByText('LAP-01 - Laptop')).toHaveLength(2))
    expect(within(screen.getByTestId('task-document-header')).getByText('ISS-2026-0002')).toBeInTheDocument()
    expect(within(screen.getByTestId('task-detail-panel')).queryAllByRole('textbox')).toHaveLength(0)
    expect(noUuidInDom(container)).toBe(true)
  })

  it('T4 Claim posts to /claim (not /assign), the button becomes Post, Post completes; a toast for each', async () => {
    renderPage()
    const user = userEvent.setup()
    await user.click((await screen.findAllByTestId('task-row')).find((r) => r.getAttribute('data-task-id') === T_POST)!)
    await user.click(await screen.findByTestId('task-claim-button'))
    await waitFor(() => expect(world.calls).toContain(`POST /api/v1/tasks/${T_POST}/claim`))
    expect(world.calls.some((c) => c.endsWith('/assign'))).toBe(false)
    expect(await screen.findByText(TASK_MESSAGES.en.claimed)).toBeInTheDocument()
    const complete = await screen.findByTestId('task-complete-button')
    expect(complete).toHaveTextContent('Post')
    await user.click(complete)
    await waitFor(() => expect(world.calls).toContain(`POST /api/v1/tasks/${T_POST}/complete`))
    expect(await screen.findByText('Posted')).toBeInTheDocument()
  })

  it.each([['en'], ['ru'], ['kk']] as const)('T5 the issuer sees the hint, and the claim refusal reads "a different person must approve" (%s)', async (lang) => {
    useUiLocaleStore.getState().setLocaleTransient(lang)
    const m = TASK_MESSAGES[lang]
    world.claimRefusal = { status: 403, body: { detail: 'separation of duties', status: 403 } }
    renderPage(ISSUER)
    const user = userEvent.setup()
    await user.click((await screen.findAllByTestId('task-row')).find((r) => r.getAttribute('data-task-id') === T_APPROVE)!)
    expect(await screen.findByTestId('task-sod-hint')).toHaveTextContent(m.sodHint.approve)
    await user.click(await screen.findByTestId('task-claim-button'))
    expect(await screen.findByTestId('task-sod-error')).toHaveTextContent(m.sod.approve)
  })

  it('T6 a second administrator claims and approves the same document: the full flow', async () => {
    renderPage(SECOND)
    const user = userEvent.setup()
    await user.click((await screen.findAllByTestId('task-row')).find((r) => r.getAttribute('data-task-id') === T_APPROVE)!)
    await screen.findByTestId('task-claim-button')
    expect(screen.queryByTestId('task-sod-hint')).not.toBeInTheDocument()
    await user.click(screen.getByTestId('task-claim-button'))
    const approve = await screen.findByTestId('task-complete-button')
    expect(approve).toHaveTextContent('Approve')
    await user.click(approve)
    await waitFor(() => expect(world.calls).toContain(`POST /api/v1/tasks/${T_APPROVE}/complete`))
    expect(await screen.findByText('Approved')).toBeInTheDocument()
    expect(screen.queryByTestId('task-error')).not.toBeInTheDocument()
  })

  it('T7 an insufficient_stock refusal on complete is a readable message and the task stays', async () => {
    world.tasks[T_POST] = { ...(world.tasks[T_POST] as object), assignee_type: 'USER', assignee_ref: ISSUER }
    world.completeRefusal = { status: 409, body: { error: 'insufficient_stock' } }
    renderPage()
    const user = userEvent.setup()
    await user.click((await screen.findAllByTestId('task-row')).find((r) => r.getAttribute('data-task-id') === T_POST)!)
    await user.click(await screen.findByTestId('task-complete-button'))
    expect(await screen.findByTestId('task-error')).toHaveTextContent(TASK_MESSAGES.en.errInsufficientStock)
    expect(screen.getByTestId('task-complete-button')).toBeInTheDocument()
  })

  it('T7b a location_frozen refusal (REQ-765) on complete is a readable message and the task stays', async () => {
    world.tasks[T_POST] = { ...(world.tasks[T_POST] as object), assignee_type: 'USER', assignee_ref: ISSUER }
    world.completeRefusal = { status: 409, body: { error: 'location_frozen', details: { held_by: 'CO-2026-0001' } } }
    renderPage()
    const user = userEvent.setup()
    await user.click((await screen.findAllByTestId('task-row')).find((r) => r.getAttribute('data-task-id') === T_POST)!)
    await user.click(await screen.findByTestId('task-complete-button'))
    expect(await screen.findByTestId('task-error')).toHaveTextContent(TASK_MESSAGES.en.errLocationFrozen)
    expect(screen.getByTestId('task-complete-button')).toBeInTheDocument()
  })

  it('T-1412 a task claimed by the signed-in user (tenant user id, not the token sub) stays in My Tasks with Complete', async () => {
    world.tasks[T_POST] = { ...(world.tasks[T_POST] as object), assignee_type: 'USER', assignee_ref: ISSUER }
    renderPage(ISSUER, 'tenantAdmin', SECOND)
    const user = userEvent.setup()
    const rows = await screen.findAllByTestId('task-row')
    const row = rows.find((r) => r.getAttribute('data-task-id') === T_POST)!
    await user.click(row)
    expect(await screen.findByTestId('task-complete-button')).toBeInTheDocument()
    expect(screen.queryByTestId('task-claim-button')).not.toBeInTheDocument()
  })

  it('T-1412 a token sub equal to another id never makes a task mine', async () => {
    world.tasks[T_POST] = { ...(world.tasks[T_POST] as object), assignee_type: 'USER', assignee_ref: SECOND }
    renderPage(ISSUER, 'tenantAdmin', SECOND)
    const user = userEvent.setup()
    const rows = await screen.findAllByTestId('task-row')
    await user.click(rows.find((r) => r.getAttribute('data-task-id') === T_POST)!)
    await new Promise((r) => setTimeout(r, 50))
    expect(screen.queryByTestId('task-complete-button')).not.toBeInTheDocument()
  })

  it('T-1412 times are shown in the tenant zone (Asia/Almaty), not the browser zone', async () => {
    world.tasks[T_POST] = { ...(world.tasks[T_POST] as object), created_at: '2026-11-05T16:35:00Z' }
    renderPage()
    const row = (await screen.findAllByTestId('task-row')).find((r) => r.getAttribute('data-task-id') === T_POST)!
    expect(within(row).getByTestId('task-age').getAttribute('title')).toContain('21:35')
  })

  it('T8 an empty inbox shows "No pending tasks"', async () => {
    world.tasks = {}
    renderPage()
    expect(await screen.findByText('No pending tasks')).toBeInTheDocument()
  })

  it('T9 loading shows the skeleton, not an empty state', async () => {
    vi.stubGlobal('fetch', vi.fn(() => new Promise(() => undefined)))
    renderPage()
    await waitFor(() => expect(screen.queryByText('No pending tasks')).not.toBeInTheDocument())
    expect(screen.queryByTestId('task-row')).not.toBeInTheDocument()
  })

  it('T10 an inbox load error shows a retry that reloads', async () => {
    world.inboxFails = true
    renderPage()
    const retry = await screen.findByRole('button', { name: /retry/i })
    world.inboxFails = false
    await userEvent.setup().click(retry)
    expect(await screen.findAllByTestId('task-row')).toHaveLength(2)
  })

  it('a user without TasksComplete sees the task but no Claim button', async () => {
    renderPage(ISSUER, 'auditor')
    const user = userEvent.setup()
    await user.click((await screen.findAllByTestId('task-row'))[0])
    await screen.findByTestId('task-detail-panel')
    expect(screen.queryByTestId('task-claim-button')).not.toBeInTheDocument()
  })
})

describe('tasksApi.claim (T13)', () => {
  it('posts to /claim with an empty body', async () => {
    const calls: string[] = []
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      calls.push(`${init?.method} ${String(url).replace(/^.*\/api\/v1/, '/api/v1')}`)
      return reply(200, { task_id: T_POST, created_at: '2026-11-05T08:00:00Z' })
    }))
    const t = await tasksApi.claim(T_POST)
    expect(calls).toEqual([`POST /api/v1/tasks/${T_POST}/claim`])
    expect(t.id).toBe(T_POST)
  })
})
