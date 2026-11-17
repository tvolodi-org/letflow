// @vitest-environment jsdom
/** REQ-855: quick count screen — C1 nav guard, C2 core flow, C3 validation, C4 error codes, C5 four-eyes, C6 reference. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { clearAllToasts, getToastSnapshot } from '@/hooks/useToast'
import { MASTERS } from './stockTestKit'
import { qcEn } from '../quickCount/quickCountMessages'
import { REFERENCE_MESSAGES } from '@/lib/references/referenceMessages'
import { stockRouteObjects } from '../stockRoutes'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-qc' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const withQC: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['StockQuickCount'] },
}
const withoutQC: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: [] },
}

const QC_PATH = '/admin/stock/quick-count'
const DOC_ID = 'qc-doc-1'
const TASK_ID = 'task-1'

function renderQC(access: AccessState = withQC) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  function Routes() {
    return useRoutes(stockRouteObjects)
  }
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[QC_PATH]}>
          <Routes />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

function refusal(status: number, reason?: string, extra: Record<string, unknown> = {}) {
  return { status, message: 'x', code: String(status), details: reason ? { reason, ...extra } : {} }
}

/** POST mock returning MASTERS data for /entities/query. */
function setupMastersMock() {
  clientMock.post.mockImplementation(async (path: string, body?: Record<string, unknown>) => {
    if (path !== '/api/v1/entities/query') return {}
    const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; op: string; value?: unknown }[] }
    const filters = b.filters ?? []
    const ids = filters.find((f) => f.field === 'record_id' && f.op === 'in')?.value as string[] | undefined
    const itemId = filters.find((f) => f.field === 'item_id' && f.op === 'eq')?.value
    const items = (MASTERS[b.entity_type ?? ''] ?? []).filter(
      (r) => (!ids || ids.includes(r.record_id)) && (itemId === undefined || r.field_values['item_id'] === itemId),
    )
    return { items, next_cursor: null }
  })
}

function setupCombinedPostMock(opts: { failQuickCount?: unknown } = {}) {
  const doc = quickCountDoc()
  const task = { id: TASK_ID, instance_id: DOC_ID, status: 'COMPLETED', assignee_type: 'USER', assignee_ref: 'u1', created_at: '2026-11-18T02:00:00Z' }
  const mastersImpl = clientMock.post.getMockImplementation()!
  clientMock.post.mockImplementation(async (path: string, body?: Record<string, unknown>) => {
    if (path === '/api/v1/entities/query') return mastersImpl(path, body)
    if (path === '/api/v1/modules/stock/quick-counts') {
      if (opts.failQuickCount) throw opts.failQuickCount
      return doc
    }
    if (path.startsWith('/api/v1/tasks/') && path.endsWith('/complete')) return task
    return {}
  })
}

function setupGetMock(opts: { balance?: string; selfApprovalAllowed?: boolean } = {}) {
  const task = { id: TASK_ID, instance_id: DOC_ID, token_id: 't1', node_id: 'approve', status: 'PENDING', assignee_type: 'USER', assignee_ref: 'u1', created_at: '2026-11-18T02:00:00Z' }
  clientMock.get.mockImplementation(async (path: string, params?: Record<string, string>) => {
    if (path === '/api/v1/modules/stock/balances') {
      if (opts.balance !== undefined) {
        return { rows: [{ sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null, unit_ref: 'm1', quantity: opts.balance }], next_cursor: null }
      }
      return { rows: [], next_cursor: null }
    }
    if (path === '/api/v1/tasks' && params?.['instance_id'] === DOC_ID) {
      return { items: [task], next_cursor: null }
    }
    if (path === `/api/v1/tasks/${TASK_ID}`) {
      return { ...task, self_approval_allowed: opts.selfApprovalAllowed ?? false }
    }
    return { rows: [], next_cursor: null }
  })
}

function quickCountDoc() {
  return {
    id: DOC_ID, kind: 'quick_count', state: 'issued', number: 'QCT-2026-000001',
    org_unit_id: 'u1', location_id: 'l1', responsible_id: null, counterparty_id: null,
    event_time: '2026-11-18T02:00:00Z',
    lines: [{ line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null, quantity: '7', book_quantity: '10', counted_quantity: '7', difference: '-3' }],
    posted_at: null, posted_by: null, reversed_at: null, reversed_by: null, posting_check: null,
  }
}

/** Select all three required fields by waiting for each option to appear in the DOM. */
async function selectFields() {
  // Wait for options to load, then select
  await waitFor(() => expect(screen.getByRole('combobox', { name: /item/i }).querySelectorAll('option').length).toBeGreaterThan(1))
  fireEvent.change(screen.getByRole('combobox', { name: /item/i }), { target: { value: 'i1' } })

  await waitFor(() => expect(screen.getByRole('combobox', { name: /location/i }).querySelectorAll('option').length).toBeGreaterThan(1))
  fireEvent.change(screen.getByRole('combobox', { name: /location/i }), { target: { value: 'l1' } })

  await waitFor(() => expect(screen.getByRole('combobox', { name: /org unit/i }).querySelectorAll('option').length).toBeGreaterThan(1))
  fireEvent.change(screen.getByRole('combobox', { name: /org unit/i }), { target: { value: 'u1' } })
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.get.mockReset()
  setupMastersMock()
  setupGetMock()
  clearAllToasts()
})
afterEach(() => cleanup())

// --- C1: Navigation guard ---
describe('C1 navigation guard', () => {
  it('shows forbidden page without StockQuickCount', async () => {
    renderQC(withoutQC)
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
  })

  it('renders the form with StockQuickCount', async () => {
    renderQC(withQC)
    expect(await screen.findByTestId('quick-count-form')).toBeInTheDocument()
  })
})

// --- C2: Core flow ---
describe('C2 core flow', () => {
  it('shows balance and difference after selecting item/location/org, then submits and shows result', async () => {
    setupGetMock({ balance: '10', selfApprovalAllowed: false })
    setupCombinedPostMock()
    renderQC()

    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()

    // Wait for balance to load
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toHaveTextContent('10'))

    // No difference yet (quantity empty)
    expect(screen.queryByTestId('difference-display')).not.toBeInTheDocument()

    // Type counted quantity
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })

    // Shows difference
    expect(screen.getByTestId('difference-display')).toHaveTextContent('-3')

    // Submit
    fireEvent.click(screen.getByTestId('submit-quick-count'))

    // Shows result
    await waitFor(() => expect(screen.getByTestId('quick-count-result')).toBeInTheDocument())
    expect(screen.getByTestId('result-number')).toHaveTextContent('QCT-2026-000001')
    expect(screen.getByTestId('result-book')).toHaveTextContent('10')
    expect(screen.getByTestId('result-counted')).toHaveTextContent('7')
    expect(screen.getByTestId('result-difference')).toHaveTextContent('-3')
    // State is a StatusPill (not raw code)
    expect(screen.getByTestId('result-state').querySelector('[class*="status-pill"], [class*="StatusPill"], [data-testid]') ?? screen.getByTestId('result-state')).not.toHaveTextContent('issued')

    // Verify post body
    const postCall = clientMock.post.mock.calls.find(([p]: string[]) => p === '/api/v1/modules/stock/quick-counts')
    expect(postCall).toBeDefined()
    const body = postCall![1] as Record<string, unknown>
    expect(body).toMatchObject({ catalog_item_id: 'i1', location_id: 'l1', org_unit_id: 'u1', counted_quantity: '7', reason_code: 'recount' })
    expect(body).not.toHaveProperty('catalog_lot_id')
  })
})

// --- C3: Quantity validation ---
describe('C3 quantity validation', () => {
  it('accepts 0', async () => {
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('counted-quantity-input')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '0' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
    // No quantity-related error shown for 0
    await waitFor(() => {
      expect(screen.queryByText(qcEn['stock.qc.err.quantity_negative'])).not.toBeInTheDocument()
      expect(screen.queryByText(qcEn['stock.qc.err.quantity_invalid'])).not.toBeInTheDocument()
      expect(screen.queryByText(qcEn['stock.qc.err.quantity_decimals'])).not.toBeInTheDocument()
    })
  })

  it('refuses -1 without sending', async () => {
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('counted-quantity-input')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '-1' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
    expect(await screen.findByText(qcEn['stock.qc.err.quantity_negative'])).toBeInTheDocument()
    expect(clientMock.post.mock.calls.filter(([p]: string[]) => p === '/api/v1/modules/stock/quick-counts').length).toBe(0)
  })

  it('refuses 10 decimals without sending', async () => {
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('counted-quantity-input')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '1.0000000001' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
    expect(await screen.findByText(qcEn['stock.qc.err.quantity_decimals'])).toBeInTheDocument()
    expect(clientMock.post.mock.calls.filter(([p]: string[]) => p === '/api/v1/modules/stock/quick-counts').length).toBe(0)
  })

  it('refuses reason other without text without sending', async () => {
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByRole('combobox', { name: /reason/i })).toBeInTheDocument())
    fireEvent.change(screen.getByRole('combobox', { name: /reason/i }), { target: { value: 'other' } })
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '5' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
    expect(await screen.findByText(qcEn['stock.qc.err.reason_text_required'])).toBeInTheDocument()
    expect(clientMock.post.mock.calls.filter(([p]: string[]) => p === '/api/v1/modules/stock/quick-counts').length).toBe(0)
  })
})

// --- C4: Error codes ---
describe('C4 error codes', () => {
  async function setupAndSubmit(err: unknown) {
    setupCombinedPostMock({ failQuickCount: err })
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '5' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
  }

  it('count_in_progress shows order number', async () => {
    await setupAndSubmit(refusal(422, 'count_in_progress', { held_by: 'QCT-2026-000001' }))
    await waitFor(() => expect(screen.getByTestId('submit-error-banner')).toBeInTheDocument())
    expect(screen.getByTestId('submit-error-banner').textContent).toContain('QCT-2026-000001')
  })

  it('location_frozen shows order number', async () => {
    await setupAndSubmit(refusal(409, 'location_frozen', { held_by: 'QCT-2026-000001' }))
    await waitFor(() => expect(screen.getByTestId('submit-error-banner')).toBeInTheDocument())
    expect(screen.getByTestId('submit-error-banner').textContent).toContain('QCT-2026-000001')
  })

  it('quick_count_stale shows balance changed message', async () => {
    await setupAndSubmit(refusal(422, 'quick_count_stale'))
    await waitFor(() => expect(screen.getByTestId('submit-error-banner')).toBeInTheDocument())
    expect(screen.getByTestId('submit-error-banner').textContent).toContain('balance changed')
  })

  it('unknown 422 shows generic message', async () => {
    await setupAndSubmit(refusal(422, 'totally_unknown_reason'))
    await waitFor(() => expect(screen.getByTestId('submit-error-banner')).toBeInTheDocument())
    expect(screen.getByTestId('submit-error-banner').textContent).toContain(
      qcEn['stock.qc.error.generic']
    )
  })
})

// --- C5: Four eyes ---
describe('C5 four eyes', () => {
  it('shows Approve button when self_approval_allowed is true', async () => {
    setupGetMock({ balance: '10', selfApprovalAllowed: true })
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toBeInTheDocument())

    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))

    await waitFor(() => expect(screen.getByTestId('approve-button')).toBeInTheDocument())

    fireEvent.click(screen.getByTestId('approve-button'))
    await waitFor(() => {
      const completeCalls = clientMock.post.mock.calls.filter(([p]: string[]) => p === `/api/v1/tasks/${TASK_ID}/complete`)
      expect(completeCalls.length).toBeGreaterThan(0)
    })
  })

  it('fires toast and shows New count button after approval', async () => {
    setupGetMock({ balance: '10', selfApprovalAllowed: true })
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
    await waitFor(() => expect(screen.getByTestId('approve-button')).toBeInTheDocument())

    fireEvent.click(screen.getByTestId('approve-button'))
    await waitFor(() => expect(screen.getByTestId('approved-actions')).toBeInTheDocument())

    // Toast was fired with the approved message
    const toasts = getToastSnapshot()
    expect(toasts.some((t) => t.message === qcEn['stock.qc.result.approved'])).toBe(true)

    // New count button is visible; Approve button is gone
    expect(screen.getByTestId('new-count-button')).toBeInTheDocument()
    expect(screen.queryByTestId('approve-button')).not.toBeInTheDocument()
  })

  it('New count resets form but keeps location and org unit', async () => {
    setupGetMock({ balance: '10', selfApprovalAllowed: false })
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
    await waitFor(() => expect(screen.getByTestId('four-eyes-hint')).toBeInTheDocument())

    // Click new-count
    fireEvent.click(screen.getByTestId('new-count-button'))

    // Form is shown again
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())

    // Location and org unit selects still have values
    expect(screen.getByRole('combobox', { name: /location/i })).toHaveValue('l1')
    expect(screen.getByRole('combobox', { name: /org unit/i })).toHaveValue('u1')
    // Item is reset
    expect(screen.getByRole('combobox', { name: /item/i })).toHaveValue('')
  })

  it('shows four-eyes hint with My Tasks link when self_approval_allowed is false', async () => {
    setupGetMock({ balance: '10', selfApprovalAllowed: false })
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toBeInTheDocument())

    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))

    await waitFor(() => expect(screen.getByTestId('four-eyes-hint')).toBeInTheDocument())
    expect(screen.queryByTestId('approve-button')).not.toBeInTheDocument()
    // My Tasks link is present
    expect(screen.getByTestId('my-tasks-link')).toBeInTheDocument()
    expect(screen.getByTestId('my-tasks-link')).toHaveAttribute('href', '/tasks')
  })
})

// --- C6: Reference messages ---
describe('C6 reference messages', () => {
  it('stock_quick_count has names in en, ru, kk', () => {
    expect(REFERENCE_MESSAGES.en.docType['stock_quick_count']).toBe('Quick count')
    expect(REFERENCE_MESSAGES.ru.docType['stock_quick_count']).toBe('Быстрый пересчёт')
    expect(REFERENCE_MESSAGES.kk.docType['stock_quick_count']).toBe('Жылдам санақ')
  })
})
