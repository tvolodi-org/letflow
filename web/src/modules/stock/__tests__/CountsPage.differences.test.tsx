// @vitest-environment jsdom
/** D1–D5 — GH 3761 / REQ-720 criterion 2: signer marks, the differences sheet and the signatures. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { countsEn } from '../counts/countsMessages'
import { BASE, LIST, READ_ONLY, fakeCounts, line, order, problem, renderCounts, writes } from './countsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-counts' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), put: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

const COUNTED = order({ status: 'counted', sheet_document_id: 'd1' })
// e1 chair, e2 and e3 members; lines are answered by e1 (chair) and e3 (member): no extra responsible. One more: e4 not a member.
const LINES = [[line(1, { counted_quantity: '8' }), line(2, { counted_quantity: '10', responsible_employee_id: 'e3' })]]
const DIFF = {
  number: 'DIF-0001', version_no: 1, issued_at: '2026-11-10T10:00:00Z', content_hash: 'h',
  lines: [
    { line_no: 1, location_id: 'l1', catalog_item_id: 'i1', catalog_lot_id: 't1', responsible_employee_id: 'e1', unit_ref: 'm1', book_quantity: '10', counted_quantity: '8', difference: '-2', direction: 'shortage' },
    { line_no: 3, location_id: 'l1', catalog_item_id: 'i1', unit_ref: 'm1', book_quantity: '0', counted_quantity: '4', difference: '4', direction: 'surplus' },
  ],
}

describe('D1 sheet signers', () => {
  it('lists chair, members once each; sends exactly the checked ids', async () => {
    fakeCounts(clientMock, { orders: [COUNTED], linePages: LINES })
    renderCounts(`${LIST}/c1`)
    await waitFor(() => expect(screen.getByTestId('sign-sheet')).not.toHaveClass('is-loading'))
    await userEvent.click(screen.getByTestId('sign-sheet'))
    const dlg = await screen.findByTestId('signers-list')
    const boxes = within(dlg).getAllByRole('checkbox')
    expect(boxes).toHaveLength(3)
    boxes.forEach((b) => expect(b).not.toBeChecked())
    expect(within(dlg).getByTestId('signer-e1').closest('label')).toHaveTextContent('Aigul B. — Chair')
    await userEvent.click(within(dlg).getByTestId('signer-e1'))
    await userEvent.click(within(dlg).getByTestId('signer-e2'))
    await userEvent.click(screen.getByTestId('signers-dialog-confirm'))
    await waitFor(() => expect(writes(clientMock)).toEqual([['POST', `${BASE}/c1/sheet-signatures`, { signer_employee_ids: ['e1', 'e2'] }]]))
  })
  it('shows a responsible employee who is not on the commission, and the refusal message', async () => {
    fakeCounts(clientMock, {
      orders: [COUNTED], linePages: [[line(1, { responsible_employee_id: 'e4' })]],
      fail: { 'POST /c1/sheet-signatures': problem(422, 'signers_incomplete') },
    })
    renderCounts(`${LIST}/c1`)
    await waitFor(() => expect(screen.getByTestId('sign-sheet')).toBeEnabled())
    await userEvent.click(screen.getByTestId('sign-sheet'))
    const dlg = await screen.findByTestId('signers-list')
    expect(within(dlg).getAllByRole('checkbox')).toHaveLength(4)
    await userEvent.click(screen.getByTestId('signers-dialog-confirm'))
    expect(await screen.findByText(countsEn['counts.reason.signers_incomplete'])).toBeInTheDocument()
  })
})

describe('D2 buttons follow the state', () => {
  it('sign sheet when unsigned; issue differences when signed; sign differences when issued; none read-only', async () => {
    fakeCounts(clientMock, { orders: [COUNTED], linePages: LINES })
    renderCounts(`${LIST}/c1`)
    await screen.findByTestId('sign-sheet')
    expect(screen.queryByTestId('issue-differences')).toBeNull()
    cleanup()

    fakeCounts(clientMock, { orders: [{ ...COUNTED, sheet_signed_at: '2026-11-10T09:00:00Z' }], linePages: LINES })
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('issue-differences'))
    await waitFor(() => expect(writes(clientMock)).toEqual([['POST', `${BASE}/c1/differences`, undefined]]))
    expect(screen.queryByTestId('sign-sheet')).toBeNull()
    cleanup()

    fakeCounts(clientMock, { orders: [{ ...COUNTED, sheet_signed_at: 'x', differences_document_id: 'd2' }], linePages: LINES, differences: DIFF })
    renderCounts(`${LIST}/c1`)
    await screen.findByTestId('sign-differences')
    expect(screen.queryByTestId('issue-differences')).toBeNull()
    cleanup()

    fakeCounts(clientMock, { orders: [{ ...COUNTED, sheet_signed_at: 'x', differences_document_id: 'd2', differences_signed_at: 'y' }], linePages: LINES, differences: DIFF })
    renderCounts(`${LIST}/c1`)
    await screen.findByTestId('differences-table')
    expect(screen.queryByTestId('sign-differences')).toBeNull()
    cleanup()

    fakeCounts(clientMock, { orders: [COUNTED], linePages: LINES })
    renderCounts(`${LIST}/c1`, READ_ONLY)
    await screen.findByTestId('count-facts')
    expect(screen.queryByTestId('sign-sheet')).toBeNull()
  })
})

describe('D3 differences panel', () => {
  it('shows the columns, lot and responsible, and surplus / shortage as words', async () => {
    fakeCounts(clientMock, { orders: [{ ...COUNTED, sheet_signed_at: 'x', differences_document_id: 'd2' }], linePages: LINES, differences: DIFF })
    renderCounts(`${LIST}/c1`)
    const table = await screen.findByTestId('differences-table')
    for (const h of ['Line', 'Location', 'Item', 'Lot', 'Responsible', 'Unit', 'Book', 'Counted', 'Difference', 'Direction']) {
      expect(within(table).getByRole('columnheader', { name: h })).toBeInTheDocument()
    }
    expect(await within(table).findByText('LOT-7')).toBeInTheDocument()
    expect(within(table).getByText('Shortage')).toBeInTheDocument()
    expect(within(table).getByText('Surplus')).toBeInTheDocument()
    expect(screen.getByTestId('differences-head')).toHaveTextContent('DIF-0001')
  })
  it('shows an empty state when the sheet has no differences', async () => {
    fakeCounts(clientMock, {
      orders: [{ ...COUNTED, sheet_signed_at: 'x', differences_document_id: 'd2' }], linePages: LINES,
      differences: { ...DIFF, lines: [] },
    })
    renderCounts(`${LIST}/c1`)
    expect(await screen.findByText(countsEn['counts.differences.empty'])).toBeInTheDocument()
  })
})

describe('D4 differences signers', () => {
  it('lists the signers of the difference lines and sends the checked ids', async () => {
    fakeCounts(clientMock, { orders: [{ ...COUNTED, sheet_signed_at: 'x', differences_document_id: 'd2' }], linePages: LINES, differences: DIFF })
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('sign-differences'))
    const dlg = await screen.findByTestId('signers-list')
    // chair e1, members e2 e3; the difference lines add no one else.
    expect(within(dlg).getAllByRole('checkbox')).toHaveLength(3)
    await userEvent.click(within(dlg).getByTestId('signer-e3'))
    await userEvent.click(screen.getByTestId('signers-dialog-confirm'))
    await waitFor(() => expect(writes(clientMock)).toEqual([['POST', `${BASE}/c1/differences-signatures`, { signer_employee_ids: ['e3'] }]]))
  })
})

describe('D5 signatures', () => {
  it('lists the signature rows with names', async () => {
    fakeCounts(clientMock, {
      orders: [{ ...COUNTED, sheet_signed_at: 'x' }], linePages: LINES,
      signatures: [{ document_kind: 'sheet', version_no: 1, employee_id: 'e2', signer_role: 'member', marked_at: '2026-11-10T09:00:00Z' }],
    })
    renderCounts(`${LIST}/c1`)
    const table = await screen.findByTestId('signatures-table')
    expect(await within(table).findByText('Marat K.')).toBeInTheDocument()
    expect(within(table).getByText('Member')).toBeInTheDocument()
    expect(within(table).getByText('Count sheet')).toBeInTheDocument()
  })
})
