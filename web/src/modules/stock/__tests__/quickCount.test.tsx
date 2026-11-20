// @vitest-environment jsdom
/** REQ-855: quick count screen — C1 nav guard, C2 core flow (item search/scan, exact difference), C3 validation,
 *  C4 error codes in en/ru/kk, C5 four-eyes, C6 reference, C7 field widths. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { clearAllToasts, getToastSnapshot } from '@/hooks/useToast'
import { MASTERS, rec } from './stockTestKit'
import { qcEn, qcKk, qcRu } from '../quickCount/quickCountMessages'
import { docEn, docKk, docRu } from '../documents/documentsMessages'
import { subtractDecimal, validateQuantity } from '../quickCount/quickCountModel'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
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

/** Items with codes and tracking policies (the catalog_item fields the item field and the lot field read). */
const QC_MASTERS: typeof MASTERS = {
  ...MASTERS,
  catalog_item: [
    rec('i1', { code: 'BLT-M8', name: 'Bolt M8', base_uom_id: 'm1', tracking_policy: 'none', barcode: '4600001' }),
    rec('i2', { code: 'NUT-M8', name: 'Nut M8', base_uom_id: 'm1', tracking_policy: 'lot' }),
  ],
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
    const items = (QC_MASTERS[b.entity_type ?? ''] ?? []).filter(
      (r) => (!ids || ids.includes(r.record_id)) && (itemId === undefined || r.field_values['item_id'] === itemId),
    )
    return { items, next_cursor: null }
  })
}

function setupCombinedPostMock(opts: { failQuickCount?: unknown; doc?: Record<string, unknown> } = {}) {
  const doc = { ...quickCountDoc(), ...opts.doc }
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

/** The route's own key set (router.ex @balance_keys): any other query key is a 422 invalid_filter there. */
const BALANCE_KEYS = ['basis', 'cutoff_seq', 'as_of', 'as_of_date', 'limit', 'cursor', 'format', 'scope_subtree', 'sku', 'location', 'org_unit', 'responsible', 'lot']

function setupGetMock(opts: { balance?: string; selfApprovalAllowed?: boolean; tasks?: unknown[]; extraRows?: unknown[] } = {}) {
  const task = { id: TASK_ID, instance_id: DOC_ID, token_id: 't1', node_id: 'approve', status: 'PENDING', assignee_type: 'USER', assignee_ref: 'u1', created_at: '2026-11-18T02:00:00Z' }
  // The counter's own submit task of the same instance, already completed: never the one to approve.
  const submitTask = { ...task, id: 'task-submit', node_id: 'submit', status: 'COMPLETED' }
  clientMock.get.mockImplementation(async (path: string, params?: Record<string, string>) => {
    if (path === '/api/v1/modules/stock/balances') {
      if (Object.keys(params ?? {}).some((k) => !BALANCE_KEYS.includes(k))) throw refusal(422, 'invalid_filter')
      if (opts.balance !== undefined) {
        return { rows: [...(opts.extraRows ?? []), { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null, unit_ref: 'm1', quantity: opts.balance }], next_cursor: null }
      }
      return { rows: [], next_cursor: null }
    }
    if (path === '/api/v1/tasks' && params?.['instance_id'] === DOC_ID) {
      return { items: opts.tasks ?? [submitTask, task], next_cursor: null }
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
    reason_code: 'recount',
    reason_text: null,
    lines: [{ line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null, quantity: '7', book_quantity: '10', counted_quantity: '7', difference: '-3' }],
    posted_at: null, posted_by: null, reversed_at: null, reversed_by: null, posting_check: null,
  }
}

const sel = (name: string) => document.querySelector(`select[name="${name}"]`) as HTMLSelectElement
const itemInput = () => document.getElementById('qc-item') as HTMLInputElement

/** Types into the item field as a keyboard scanner does (the text, then Enter), once the catalog has loaded. */
async function pickItem(text = 'BLT-M8', title = 'Bolt M8') {
  await waitFor(() => expect(itemInput()).not.toBeNull())
  fireEvent.change(itemInput(), { target: { value: text } })
  await within(await screen.findByRole('listbox')).findByText(title)
  fireEvent.keyDown(itemInput(), { key: 'Enter' })
}

async function pickSelect(name: string, value: string) {
  await waitFor(() => expect(sel(name).querySelectorAll('option').length).toBeGreaterThan(1))
  fireEvent.change(sel(name), { target: { value } })
}

/** Select all three required fields: the item by its code, place and org unit from their lists. */
async function selectFields() {
  await pickItem()
  await waitFor(() => expect(itemInput()).toHaveValue('BLT-M8 – Bolt M8'))
  await pickSelect('location_id', 'l1')
  await pickSelect('org_unit_id', 'u1')
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.get.mockReset()
  setupMastersMock()
  setupGetMock()
  clearAllToasts()
})
afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

it('counts the selected responsible employee exact key', async () => {
  setupGetMock({ balance: '0', extraRows: [
    { responsible: 'e1', lot: null, unit_ref: 'm1', quantity: '96.500000000' },
    { responsible: 'e2', lot: null, unit_ref: 'm1', quantity: '12' },
  ] })
  setupCombinedPostMock()
  renderQC()
  await selectFields()
  await pickSelect('responsible_id', 'e1')
  expect(await screen.findByTestId('book-quantity')).toHaveTextContent('96.500000000')
  fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '97.5' } })
  expect(screen.getByTestId('difference-display').textContent).toBe('1')
  expect(clientMock.get).toHaveBeenCalledWith('/api/v1/modules/stock/balances', { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1' })
  fireEvent.click(screen.getByTestId('submit-quick-count'))
  await waitFor(() => expect(clientMock.post).toHaveBeenCalledWith(
    '/api/v1/modules/stock/quick-counts', expect.objectContaining({ responsible_id: 'e1' }),
  ))
})

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
    // Exactly the form fields plus the item's base unit (quick_count_shape.ex @required has catalog_uom_id).
    expect(body).toEqual({ catalog_item_id: 'i1', catalog_uom_id: 'm1', location_id: 'l1', org_unit_id: 'u1', counted_quantity: '7', reason_code: 'recount' })

    // The balance was read with the route's slot keys for this item, place and org unit
    const balanceCall = clientMock.get.mock.calls.find(([p]: string[]) => p === '/api/v1/modules/stock/balances')
    expect(balanceCall![1]).toEqual({ sku: 'i1', location: 'l1', org_unit: 'u1' })
  })

  it('GH 4874: the result panel shows the chosen location when the document header carries none', async () => {
    setupGetMock({ balance: '10' })
    const line = { ...quickCountDoc().lines[0], location_id: 'l1' }
    setupCombinedPostMock({ doc: { location_id: null, lines: [line] } })
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toHaveTextContent('10'))
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
    await waitFor(() => expect(screen.getByTestId('quick-count-result')).toBeInTheDocument())
    const loc = screen.getByTestId('result-location')
    expect(loc).not.toHaveTextContent('—')
    expect(loc.textContent?.trim()).not.toBe('')
  })

  it('books against the slot with no responsible, not another slot of the same key', async () => {
    setupGetMock({
      balance: '10',
      extraRows: [{ sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'r9', lot: null, unit_ref: 'm1', quantity: '99' }],
    })
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toHaveTextContent('10'))
  })
})

// --- C2b: item search and keyboard scanner ---
describe('C2b item search and scanner', () => {
  it('a scanned code + Enter selects the item and fires the balance query', async () => {
    setupGetMock({ balance: '10' })
    renderQC()
    await pickItem('BLT-M8')
    expect(itemInput()).toHaveValue('BLT-M8 – Bolt M8')
    await pickSelect('location_id', 'l1')
    await pickSelect('org_unit_id', 'u1')
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toHaveTextContent('10'))
    const balanceCall = clientMock.get.mock.calls.find(([p]: string[]) => p === '/api/v1/modules/stock/balances')
    expect(balanceCall![1]).toEqual({ sku: 'i1', location: 'l1', org_unit: 'u1' })
  })

  it('a scanned barcode + Enter selects its item', async () => {
    renderQC()
    fireEvent.change(await waitFor(() => itemInput()), { target: { value: '4600001' } })
    await waitFor(() => expect(screen.getByRole('listbox')).toBeInTheDocument())
    await waitFor(() => {
      fireEvent.keyDown(itemInput(), { key: 'Enter' })
      expect(itemInput()).toHaveValue('BLT-M8 – Bolt M8')
    })
  })

  it('search by part of the name lists the item and Enter picks it', async () => {
    renderQC()
    await pickItem('nut', 'Nut M8')
    expect(itemInput()).toHaveValue('NUT-M8 – Nut M8')
    // A lot-tracked item (tracking_policy lot) shows the lot field; the first item (none) did not.
    expect(sel('catalog_lot_id')).not.toBeNull()
  })

  it('an item with tracking_policy none has no lot field', async () => {
    renderQC()
    await pickItem()
    await waitFor(() => expect(itemInput()).toHaveValue('BLT-M8 – Bolt M8'))
    expect(sel('catalog_lot_id')).toBeNull()
  })
})

// --- C2c: exact difference ---
describe('C2c exact difference', () => {
  it('book 10.1 and counted 10.3 shows 0.2, not a float artefact', async () => {
    setupGetMock({ balance: '10.1' })
    renderQC()
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toHaveTextContent('10.1'))
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '10.3' } })
    expect(screen.getByTestId('difference-display').textContent).toBe('0.2')
  })

  it('a 9-decimal count beyond float precision is exact', async () => {
    setupGetMock({ balance: '0.000000001' })
    renderQC()
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toHaveTextContent('0.000000001'))
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '12345678901.123456789' } })
    expect(screen.getByTestId('difference-display').textContent).toBe('12345678901.123456788')
  })

  it('subtractDecimal is exact and trims trailing zeros', () => {
    expect(subtractDecimal('7', '10')).toBe('-3')
    expect(subtractDecimal('10.3', '10.1')).toBe('0.2')
    expect(subtractDecimal('5', '5.000000000')).toBe('0')
    expect(subtractDecimal('0.1', '0.3')).toBe('-0.2')
    expect(subtractDecimal('1.5', '10.000000000')).toBe('-8.5')
    expect(subtractDecimal('1e3', '1')).toBeNull()
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

  it('refuses 1e3, 0x10 and a padded number as not a number without sending', async () => {
    for (const v of ['1e3', '0x10', ' 5 ', '1.', '.5']) expect(validateQuantity(v)).toBe('stock.qc.err.quantity_invalid')
    for (const v of ['0', '7', '10.3', '1.123456789']) expect(validateQuantity(v)).toBeUndefined()
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('counted-quantity-input')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '1e3' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
    expect(await screen.findByText(qcEn['stock.qc.err.quantity_invalid'])).toBeInTheDocument()
    expect(clientMock.post.mock.calls.filter(([p]: string[]) => p === '/api/v1/modules/stock/quick-counts').length).toBe(0)
  })

  it('refuses reason other without text without sending', async () => {
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(sel('reason_code')).not.toBeNull())
    fireEvent.change(sel('reason_code'), { target: { value: 'other' } })
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '5' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
    expect(await screen.findByText(qcEn['stock.qc.err.reason_text_required'])).toBeInTheDocument()
    expect(clientMock.post.mock.calls.filter(([p]: string[]) => p === '/api/v1/modules/stock/quick-counts').length).toBe(0)
  })
})

// --- C4: Error codes ---
const CATALOGS = { en: qcEn, ru: qcRu, kk: qcKk } as const
const DOC_CATALOGS = { en: docEn, ru: docRu, kk: docKk } as const
const HELD = 'CNT-2026-000017'
/** Refusal codes: the HTTP status the route answers, and whether the message carries held_by. */
const CODES = [
  { reason: 'definition_not_active', status: 409, heldBy: false },
  { reason: 'count_in_progress', status: 422, heldBy: true },
  { reason: 'location_frozen', status: 409, heldBy: true },
  { reason: 'quick_count_stale', status: 422, heldBy: false },
  { reason: 'balance_in_other_rows', status: 422, heldBy: false },
  { reason: 'unknown_kind', status: 422, heldBy: false },
] as const

describe('C4 error codes', () => {
  async function setupAndSubmit(err: unknown) {
    setupCombinedPostMock({ failQuickCount: err })
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '5' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
  }

  for (const code of CODES) {
    for (const lang of ['en', 'ru', 'kk'] as const) {
      it(`${code.reason} shows its own message in ${lang}`, async () => {
        useUiLocaleStore.getState().setLocaleTransient(lang)
        const text = CATALOGS[lang][`stock.qc.error.${code.reason}`]
        expect(text).toBeTruthy()
        await setupAndSubmit(refusal(code.status, code.reason, code.heldBy ? { held_by: HELD } : {}))
        const banner = await screen.findByTestId('submit-error-banner')
        expect(banner.textContent).toContain(text!.replace('{held_by}', HELD))
        expect(banner.textContent).not.toContain(CATALOGS[lang]['stock.qc.error.generic'])
        if (code.heldBy) expect(banner.textContent).toContain(HELD)
        else expect(text).not.toContain('{held_by}')
      })
    }
  }

  it('the refusal messages differ from each other and from the generic one in every language', () => {
    for (const cat of Object.values(CATALOGS)) {
      const texts = [...CODES.map((c) => cat[`stock.qc.error.${c.reason}`]), cat['stock.qc.error.generic']]
      expect(new Set(texts).size).toBe(texts.length)
    }
  })

  it('an unknown reason shows the generic message', async () => {
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

  it('shows approve-failed banner when approval API call fails', async () => {
    setupGetMock({ balance: '10', selfApprovalAllowed: true })
    setupCombinedPostMock()
    // Override task complete to fail
    const mastersImpl = clientMock.post.getMockImplementation()!
    clientMock.post.mockImplementation(async (path: string, body?: Record<string, unknown>) => {
      if (path === '/api/v1/entities/query') return mastersImpl(path, body)
      if (path === '/api/v1/modules/stock/quick-counts') return quickCountDoc()
      if (path.startsWith('/api/v1/tasks/') && path.endsWith('/complete'))
        throw { status: 500, message: 'Internal error', code: '500', details: {} }
      return {}
    })
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))
    await waitFor(() => expect(screen.getByTestId('approve-button')).toBeInTheDocument())

    fireEvent.click(screen.getByTestId('approve-button'))
    await waitFor(() => expect(screen.getByTestId('approve-error-banner')).toBeInTheDocument())
    expect(screen.getByTestId('approve-error-banner').textContent).toContain(qcEn['stock.qc.error.approve_failed'])
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
    expect(sel('location_id')).toHaveValue('l1')
    expect(sel('org_unit_id')).toHaveValue('u1')
    // Item is reset
    expect(itemInput()).toHaveValue('')
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

// --- C5b: no approve task found ---
describe('C5b no approve task', () => {
  it('says the count waits for approval and links My Tasks when the task list is empty', async () => {
    setupGetMock({ balance: '10', tasks: [] })
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))

    await waitFor(() => expect(screen.getByTestId('no-task-hint')).toBeInTheDocument())
    expect(screen.getByTestId('no-task-hint')).toHaveTextContent(qcEn['stock.qc.four_eyes_hint'])
    expect(qcEn['stock.qc.four_eyes_hint']).not.toMatch(/Open My Tasks/)
    expect(screen.getByTestId('my-tasks-link')).toHaveAttribute('href', '/tasks')
    expect(screen.queryByTestId('approve-button')).not.toBeInTheDocument()
    expect(screen.queryByTestId('four-eyes-hint')).not.toBeInTheDocument()
  })

  for (const lang of ['en', 'ru', 'kk'] as const) {
    it(`labels a confirmed count (zero difference) from the catalog in ${lang}`, async () => {
      useUiLocaleStore.getState().setLocaleTransient(lang)
      const label = DOC_CATALOGS[lang]['stock.doc.state.confirmed']
      expect(label).toBeTruthy()
      setupGetMock({ balance: '7', tasks: [] })
      setupCombinedPostMock({ doc: { state: 'confirmed' } })
      renderQC()
      await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
      await selectFields()
      await waitFor(() => expect(screen.getByTestId('book-quantity')).toBeInTheDocument())
      fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })
      fireEvent.click(screen.getByTestId('submit-quick-count'))

      const state = await screen.findByTestId('result-state')
      expect(state).toHaveTextContent(label!)
      expect(state.textContent).not.toContain('stock.doc.state')
      expect(within(state).getByTestId('status-pill')).toHaveAttribute('data-tone', 'success')
    })
  }

  it('shows no approval hint for a confirmed count (zero difference starts no instance)', async () => {
    setupGetMock({ balance: '7', tasks: [] })
    setupCombinedPostMock({ doc: { state: 'confirmed' } })
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))

    await waitFor(() => expect(screen.getByTestId('quick-count-result')).toBeInTheDocument())
    await waitFor(() => expect(clientMock.get.mock.calls.some(([p]: string[]) => p === '/api/v1/tasks')).toBe(true))
    expect(screen.queryByTestId('no-task-hint')).not.toBeInTheDocument()
    expect(screen.getByTestId('new-count-button')).toBeInTheDocument()
  })

  it('does not offer the completed submit task for approval', async () => {
    setupGetMock({ balance: '10', selfApprovalAllowed: true, tasks: [{ id: 'task-submit', instance_id: DOC_ID, token_id: 't1', node_id: 'submit', status: 'COMPLETED', created_at: '2026-11-18T02:00:00Z' }] })
    setupCombinedPostMock()
    renderQC()
    await waitFor(() => expect(screen.getByTestId('quick-count-form')).toBeInTheDocument())
    await selectFields()
    await waitFor(() => expect(screen.getByTestId('book-quantity')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('counted-quantity-input'), { target: { value: '7' } })
    fireEvent.click(screen.getByTestId('submit-quick-count'))

    await waitFor(() => expect(screen.getByTestId('no-task-hint')).toBeInTheDocument())
    expect(screen.queryByTestId('approve-button')).not.toBeInTheDocument()
    expect(clientMock.get.mock.calls.some(([p]: string[]) => p === '/api/v1/tasks/task-submit')).toBe(false)
  })
})

// --- C7: Field widths (design system README, Forms: size fields by content, never stretch) ---
describe('C7 field widths', () => {
  const box = (el: Element | null) => el?.closest('.lf-field') as HTMLElement
  it('sizes every field by its content and sets the count in mono', async () => {
    renderQC()
    await pickItem('nut', 'Nut M8')
    await waitFor(() => expect(sel('catalog_lot_id')).not.toBeNull())
    expect(screen.getByTestId('item-field')).toHaveClass('lf-field--l')
    for (const name of ['location_id', 'org_unit_id', 'catalog_lot_id', 'reason_code']) {
      expect(box(sel(name))).toHaveClass('lf-field--m')
    }
    const counted = screen.getByTestId('counted-quantity-input')
    expect(box(counted)).toHaveClass('lf-field--s')
    expect(counted.closest('.lf-control')).toHaveClass('lf-control--mono')
    fireEvent.change(sel('reason_code'), { target: { value: 'other' } })
    expect(box(await screen.findByTestId('reason-text-input'))).toHaveClass('lf-field--l')
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
