// @vitest-environment jsdom
/**
 * T-1989 page tests. IDs: W-P1 list, W-P2 toggle with reason, W-P3 path encoding, W-P4 warning (both branches),
 * W-P5 selection after Save, W-P6 write errors, W-P7 load states, W-P8 orphans, W-P9 readable names, W-P10 ru.
 * Fake window.fetch; real react-query and the real page.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 'header.' + btoa(JSON.stringify({ sub: 'admin-id' })) + '.sig',
        display_name: 'Admin',
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

import ApprovalRulesPage from '../ApprovalRulesPage'
import { renderWithAccess } from '@/auth/access/testing'
import type { ApprovalRule } from '@/api/approvalRules'
import { dismissToast, getToastSnapshot } from '@/hooks/useToast'

const UUID = '11111111-2222-4333-8444-555555555555'

function rule(over: Partial<ApprovalRule>): ApprovalRule {
  return {
    definition_name: 'assets_opening',
    node_id: 'approve',
    node_label: null,
    four_eyes: true,
    in_active_definition: true,
    changed_by: null,
    changed_by_name: null,
    changed_at: null,
    reason: null,
    ...over,
  }
}

const ON = rule({})
const OFF = rule({
  definition_name: 'stock_opening',
  four_eyes: false,
  changed_by: UUID,
  changed_by_name: 'Aigerim Sadykova',
  changed_at: '2026-11-10T09:30:00Z',
  reason: 'One-person company',
})
const ORPHAN_OFF = rule({ definition_name: 'old_v0', four_eyes: false, in_active_definition: false })
const ORPHAN_ON = rule({ definition_name: 'old_v1', four_eyes: true, in_active_definition: false })

interface Call {
  method: string
  url: string
  body: unknown
}
let calls: Call[]
let items: ApprovalRule[]
let putReply: (() => Response) | null
let getReply: (() => Response) | null

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

let widthSpy: ReturnType<typeof vi.spyOn> | null = null

beforeEach(() => {
  // jsdom reports width 0: pretend a wide host so ListDetail selects the first row by default.
  widthSpy = vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockReturnValue(1400)
  calls = []
  items = [ON, OFF]
  putReply = null
  getReply = null
  vi.spyOn(window, 'fetch').mockImplementation(async (input, init) => {
    const url = typeof input === 'string' ? input : (input as Request).url
    const method = (init?.method ?? 'GET').toUpperCase()
    const body = init?.body ? (JSON.parse(init.body as string) as unknown) : undefined
    calls.push({ method, url, body })
    if (method === 'GET') return getReply ? getReply() : json(200, { items })
    if (putReply) return putReply()
    return json(200, items[0])
  })
})
afterEach(() => {
  widthSpy?.mockRestore()
  for (const e of getToastSnapshot()) dismissToast(e.id)
  cleanup()
  vi.restoreAllMocks()
})

function render(props: Parameters<typeof ApprovalRulesPage>[0] = {}) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <ApprovalRulesPage {...props} />
      </MemoryRouter>
    </QueryClientProvider>,
    'tenantAdmin',
  )
}

const puts = () => calls.filter((c) => c.method === 'PUT')
const gets = () => calls.filter((c) => c.method === 'GET')

async function ready() {
  await screen.findByTestId('approval-rule-switch')
}

describe('W-P1 list', () => {
  it('shows process name, step name and an On / Off word; the first row is selected', async () => {
    render()
    await ready()
    const table = screen.getByRole('table')
    expect(within(table).getByText('Asset opening')).toBeInTheDocument()
    expect(within(table).getByText('Stock opening balances')).toBeInTheDocument()
    expect(within(table).getAllByText('Approval')).toHaveLength(2)
    expect(within(table).getByText('On')).toBeInTheDocument()
    expect(within(table).getByText('Off')).toBeInTheDocument()
    expect(screen.getByTestId('detail-header')).toHaveTextContent('Asset opening')
  })
})

describe('W-P2 / W-P3 toggle with reason', () => {
  it('Save is disabled until a reason, then PUTs the exact body', async () => {
    render()
    await ready()
    expect(screen.queryByTestId('approval-rule-reason')).toBeNull()
    fireEvent.click(screen.getByTestId('approval-rule-switch'))
    const save = screen.getByTestId('approval-rule-save')
    expect(save).toBeDisabled()
    fireEvent.change(screen.getByTestId('approval-rule-reason'), { target: { value: '  one person firm ' } })
    expect(save).toBeEnabled()
    fireEvent.click(save)
    await waitFor(() => expect(puts()).toHaveLength(1))
    expect(puts()[0].url).toContain('/api/v1/approval-rules/assets_opening/approve')
    expect(puts()[0].body).toEqual({ four_eyes: false, reason: 'one person firm' })
  })

  it('encodes a definition name with a slash', async () => {
    items = [rule({ definition_name: 'a/b' })]
    render()
    await ready()
    fireEvent.click(screen.getByTestId('approval-rule-switch'))
    fireEvent.change(screen.getByTestId('approval-rule-reason'), { target: { value: 'r' } })
    fireEvent.click(screen.getByTestId('approval-rule-save'))
    await waitFor(() => expect(puts()).toHaveLength(1))
    expect(puts()[0].url).toContain('/api/v1/approval-rules/a%2Fb/approve')
  })

  it('Cancel resets the draft', async () => {
    render()
    await ready()
    fireEvent.click(screen.getByTestId('approval-rule-switch'))
    fireEvent.click(screen.getByTestId('approval-rule-cancel'))
    expect(screen.queryByTestId('approval-rule-reason')).toBeNull()
    expect(screen.getByTestId('approval-rule-switch')).toBeChecked()
  })
})

describe('W-P4 warning', () => {
  it('shows the warning when going OFF, not when going ON', async () => {
    render()
    await ready()
    expect(screen.queryByTestId('approval-rule-warning')).toBeNull()
    fireEvent.click(screen.getByTestId('approval-rule-switch'))
    expect(screen.getByTestId('approval-rule-warning')).toHaveTextContent(/audit log/)
    cleanup()
    render({ initialSelectedKey: JSON.stringify(['stock_opening', 'approve']) })
    await waitFor(() => expect(screen.getByTestId('detail-header')).toHaveTextContent('Stock opening balances'))
    fireEvent.click(screen.getByTestId('approval-rule-switch'))
    expect(screen.getByTestId('approval-rule-reason')).toBeInTheDocument()
    expect(screen.queryByTestId('approval-rule-warning')).toBeNull()
  })
})

describe('W-P5 selection after Save', () => {
  it('keeps the row selected, toasts and shows the refetched value', async () => {
    render()
    await ready()
    fireEvent.click(screen.getByTestId('approval-rule-switch'))
    fireEvent.change(screen.getByTestId('approval-rule-reason'), { target: { value: 'r' } })
    items = [{ ...ON, four_eyes: false, changed_by_name: 'Admin', changed_at: '2026-11-11T08:00:00Z', reason: 'r' }, OFF]
    fireEvent.click(screen.getByTestId('approval-rule-save'))
    await waitFor(() => expect(gets().length).toBeGreaterThanOrEqual(2))
    await waitFor(() => expect(screen.getByTestId('approval-rule-last-reason')).toHaveTextContent('r'))
    expect(screen.getByTestId('detail-header')).toHaveTextContent('Asset opening')
    expect(screen.getByTestId('approval-rule-switch')).not.toBeChecked()
    expect(getToastSnapshot().map((t) => t.message)).toContain('Approval rule saved')
  })
})

describe('W-P6 write errors', () => {
  async function submit() {
    render()
    await ready()
    fireEvent.click(screen.getByTestId('approval-rule-switch'))
    fireEvent.change(screen.getByTestId('approval-rule-reason'), { target: { value: 'r' } })
    fireEvent.click(screen.getByTestId('approval-rule-save'))
  }

  it('invalid_reason shows next to the field', async () => {
    putReply = () => json(422, { status: 422, detail: 'invalid_reason' })
    await submit()
    await screen.findByText(/1 to 500 characters/)
    expect(screen.queryByTestId('approval-rule-save-error')).toBeNull()
  })

  it('409 shows the conflict banner and refetches', async () => {
    putReply = () => json(409, { status: 409, detail: 'concurrent_change' })
    await submit()
    await screen.findByText(/Someone else changed this rule/)
    await waitFor(() => expect(gets().length).toBeGreaterThanOrEqual(2))
  })

  it('not_a_four_eyes_step shows its banner and refetches', async () => {
    putReply = () => json(422, { status: 422, detail: 'not_a_four_eyes_step' })
    await submit()
    await screen.findByText(/no longer needs approval/)
    await waitFor(() => expect(gets().length).toBeGreaterThanOrEqual(2))
  })

  it('500 shows the generic banner', async () => {
    putReply = () => json(500, { status: 500, message: 'internal_error' })
    await submit()
    await screen.findByText(/could not be saved/)
  })
})

describe('W-P7 load states', () => {
  it('empty list', async () => {
    items = []
    render()
    expect(await screen.findByText('No approval needs a second person')).toBeInTheDocument()
    expect(screen.getByTestId('approval-rules-pick')).toBeInTheDocument()
  })

  it('loading skeleton while the request is pending', () => {
    getReply = () => new Response(null) // never awaited below: the first render is the loading state
    render()
    expect(screen.queryByTestId('approval-rule-switch')).toBeNull()
  })

  it('500 shows the error with a retry that refetches', async () => {
    getReply = () => json(500, { status: 500, message: 'x' })
    render()
    const retry = await screen.findByRole('button', { name: /retry|try again/i })
    const before = gets().length
    fireEvent.click(retry)
    await waitFor(() => expect(gets().length).toBeGreaterThan(before))
  })

  it('403 shows permission denied', async () => {
    getReply = () => json(403, { status: 403, detail: 'insufficient permissions' })
    render()
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
  })
})

describe('W-P8 orphans', () => {
  it('an ON orphan has a disabled switch with its reason; an OFF orphan can be switched', async () => {
    items = [ORPHAN_ON, ORPHAN_OFF]
    render()
    await ready()
    expect(screen.getByTestId('approval-rule-orphan')).toBeInTheDocument()
    expect(screen.getByTestId('approval-rule-switch')).toBeDisabled()
    expect(screen.getByText(/Cannot be switched off/)).toBeInTheDocument()
    cleanup()
    render({ initialSelectedKey: JSON.stringify(['old_v0', 'approve']) })
    await waitFor(() => expect(screen.getByTestId('approval-rule-orphan')).toBeInTheDocument())
    expect(screen.getByTestId('approval-rule-switch')).toBeEnabled()
    expect(screen.queryByText(/Cannot be switched off/)).toBeNull()
  })
})

describe('W-P9 readable names', () => {
  it('shows the changer name and never the user id; unknown user when the name is missing', async () => {
    render({ initialSelectedKey: JSON.stringify(['stock_opening', 'approve']) })
    await waitFor(() => expect(screen.getByTestId('approval-rule-last-change')).toHaveTextContent('Aigerim Sadykova'))
    expect(screen.queryByText(new RegExp(UUID))).toBeNull()
    cleanup()
    items = [{ ...OFF, changed_by_name: null }]
    render()
    await waitFor(() => expect(screen.getByTestId('approval-rule-last-change')).toHaveTextContent('Unknown user'))
    expect(screen.queryByText(new RegExp(UUID))).toBeNull()
  })

  it('a never-changed rule says so', async () => {
    render()
    await ready()
    expect(screen.getByTestId('approval-rule-last-change')).toHaveTextContent('Never changed')
  })
})

describe('W-P10 Russian', () => {
  it('renders the ru title, pill words and names', async () => {
    render({ locale: 'ru' })
    await ready()
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Правила утверждения')
    expect(screen.getAllByText('Ввод остатков активов').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Включено').length).toBeGreaterThan(0)
    expect(screen.queryByText('Approval rules')).toBeNull()
  })
})
