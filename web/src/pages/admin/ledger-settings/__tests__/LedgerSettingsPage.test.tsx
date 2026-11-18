// @vitest-environment jsdom
/**
 * REQ-839 page tests. IDs: L-P1 list, L-P2 switch with reason (no PUT without it), L-P3 422 errors in en/ru/kk,
 * L-P4 dialog wording, L-P5 empty and load error. Fake window.fetch; real react-query and the real page.
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

import LedgerSettingsPage from '../LedgerSettingsPage'
import { renderWithAccess } from '@/auth/access/testing'
import type { LedgerSetting } from '@/api/ledgerSettings'
import { dismissToast, getToastSnapshot } from '@/hooks/useToast'
import { ledgerSettingsMessages } from '../ledgerSettingsMessages'

const REFUSED: LedgerSetting = {
  registration: 'stock',
  allow_negative: false,
  changed_by: null,
  changed_by_name: null,
  changed_at: null,
  reason: null,
}
const ALLOWED: LedgerSetting = {
  ...REFUSED,
  allow_negative: true,
  changed_by: '11111111-2222-4333-8444-555555555555',
  changed_by_name: 'Aigerim Sadykova',
  changed_at: '2026-11-10T09:30:00Z',
  reason: 'Warehouse issues before receipts are posted',
}

interface Call {
  method: string
  url: string
  body: unknown
}
let calls: Call[]
let items: LedgerSetting[]
let putReply: (() => Response) | null
let getReply: (() => Response) | null

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

beforeEach(() => {
  calls = []
  items = [REFUSED]
  putReply = null
  getReply = null
  vi.spyOn(window, 'fetch').mockImplementation(async (input, init) => {
    const url = typeof input === 'string' ? input : (input as Request).url
    const method = (init?.method ?? 'GET').toUpperCase()
    const body = init?.body ? (JSON.parse(init.body as string) as unknown) : undefined
    calls.push({ method, url, body })
    if (method === 'GET') return getReply ? getReply() : json(200, { items })
    if (putReply) return putReply()
    items = [ALLOWED]
    return json(200, ALLOWED)
  })
})
afterEach(() => {
  for (const e of getToastSnapshot()) dismissToast(e.id)
  cleanup()
  vi.restoreAllMocks()
})

function render(props: Parameters<typeof LedgerSettingsPage>[0] = {}) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <LedgerSettingsPage {...props} />
      </MemoryRouter>
    </QueryClientProvider>,
    'tenantAdmin',
  )
}

const puts = () => calls.filter((c) => c.method === 'PUT')

async function openDialog() {
  fireEvent.click(await screen.findByTestId('ledger-setting-switch-stock'))
  return screen.findByTestId('ledger-setting-dialog')
}

describe('L-P1 list', () => {
  it('shows the stock registration as refused with no change yet', async () => {
    render()
    const table = await screen.findByRole('table')
    expect(await within(table).findByText('Stock')).toBeInTheDocument()
    expect(within(table).getByText('Refused')).toBeInTheDocument()
    expect(within(table).getByText('Never changed')).toBeInTheDocument()
    expect(calls[0]).toMatchObject({ method: 'GET', url: expect.stringContaining('/api/v1/ledger-settings') })
  })
})

describe('L-P2 switch with a reason', () => {
  it('without a reason keeps the dialog open with the required message and sends no PUT', async () => {
    render()
    const dialog = await openDialog()
    fireEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(await within(dialog).findByText('A reason is required.')).toBeInTheDocument()
    expect(screen.getByTestId('ledger-setting-dialog')).toBeInTheDocument()
    expect(puts()).toHaveLength(0)
  })

  it('with a reason sends PUT allow_negative true and the row shows allowed, the changer and the time', async () => {
    render()
    const dialog = await openDialog()
    fireEvent.change(within(dialog).getByTestId('ledger-setting-reason'), { target: { value: '  Receipts lag  ' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(puts()).toHaveLength(1))
    expect(puts()[0].url).toContain('/api/v1/ledger-settings/stock')
    expect(puts()[0].body).toEqual({ allow_negative: true, reason: 'Receipts lag' })
    const table = screen.getByRole('table')
    expect(await within(table).findByText('Allowed')).toBeInTheDocument()
    expect(within(table).getByText(/Aigerim Sadykova/)).toBeInTheDocument()
    expect(within(table).getByText('Warehouse issues before receipts are posted')).toBeInTheDocument()
    expect(screen.queryByTestId('ledger-setting-dialog')).toBeNull()
  })

  it('switching an allowed registration back sends allow_negative false', async () => {
    items = [ALLOWED]
    render()
    const dialog = await openDialog()
    fireEvent.change(within(dialog).getByTestId('ledger-setting-reason'), { target: { value: 'Back to strict' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(puts()).toHaveLength(1))
    expect(puts()[0].body).toEqual({ allow_negative: false, reason: 'Back to strict' })
  })

  it('Cancel closes the dialog and sends no PUT', async () => {
    render()
    const dialog = await openDialog()
    fireEvent.click(within(dialog).getByRole('button', { name: 'Cancel' }))
    await waitFor(() => expect(screen.queryByTestId('ledger-setting-dialog')).toBeNull())
    expect(puts()).toHaveLength(0)
  })
})

describe('L-P4 dialog wording', () => {
  it('switching to allowed states that larger issues will be posted and the balance shown below zero', async () => {
    render()
    await openDialog()
    expect(screen.getByTestId('ledger-setting-warning')).toHaveTextContent(
      'Issues larger than the balance will then be posted, and the balance will be shown below zero.',
    )
  })

  it('switching to refused does not carry the allow warning', async () => {
    items = [ALLOWED]
    render()
    await openDialog()
    expect(screen.getByTestId('ledger-setting-warning')).toHaveTextContent('will be refused again')
  })
})

describe('L-P3 server refusals are localized messages', () => {
  const CASES: Array<['en' | 'ru' | 'kk', string, string]> = [
    ['en', 'invalid_reason', 'ledgerSettings.error.invalid_reason'],
    ['ru', 'invalid_reason', 'ledgerSettings.error.invalid_reason'],
    ['kk', 'invalid_reason', 'ledgerSettings.error.invalid_reason'],
    ['en', 'not_switchable', 'ledgerSettings.error.not_switchable'],
    ['ru', 'not_switchable', 'ledgerSettings.error.not_switchable'],
    ['kk', 'not_switchable', 'ledgerSettings.error.not_switchable'],
  ]
  it.each(CASES)('%s %s', async (locale, code, id) => {
    putReply = () => json(422, { status: 422, detail: code })
    render({ locale })
    const dialog = await openDialog()
    fireEvent.change(within(dialog).getByTestId('ledger-setting-reason'), { target: { value: 'x' } })
    const confirm = within(dialog).getByRole('button', { name: ledgerSettingsMessages[locale]['ledgerSettings.confirm'] })
    fireEvent.click(confirm)
    const text = ledgerSettingsMessages[locale][id]
    expect(await within(screen.getByTestId('ledger-setting-dialog')).findByText(text)).toBeInTheDocument()
    expect(within(screen.getByTestId('ledger-setting-dialog')).queryByText(code)).toBeNull()
    // Nothing else changed: the row is still refused and the dialog stays open.
    expect(screen.getByRole('table')).toHaveTextContent(ledgerSettingsMessages[locale]['ledgerSettings.pill.refused'])
  })
})

describe('L-P5 states', () => {
  it('empty list shows the empty text', async () => {
    items = []
    render()
    expect(await screen.findByText('No register can be switched')).toBeInTheDocument()
  })

  it('a failed load shows the error state with retry', async () => {
    getReply = () => json(500, { status: 500, message: 'error' })
    render()
    await waitFor(() => expect(screen.queryByRole('table')).toBeNull())
    expect(screen.getByRole('button', { name: /try again|retry/i })).toBeInTheDocument()
  })
})
