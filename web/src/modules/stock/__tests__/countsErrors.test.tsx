// @vitest-environment jsdom
/** E1–E5 — GH 3735 / REQ-702 criterion 4: each refusal reason has its message, a 404 is the not-found state,
 *  every screen has its loading, empty and error state. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { COUNT_REASONS } from '../counts/countsModel'
import { countsEn } from '../counts/countsMessages'
import { BASE, LIST, fakeCounts, line, order, problem, renderCounts } from './countsTestKit'

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

async function issueWith(error: unknown) {
  fakeCounts(clientMock, { fail: { 'POST /c1/issue': error } })
  renderCounts(`${LIST}/c1`)
  await userEvent.click(await screen.findByTestId('count-issue'))
  await userEvent.click(within(await screen.findByTestId('confirm-dialog')).getByTestId('confirm-dialog-confirm'))
  return screen.findByTestId('confirm-dialog-error')
}

describe('E1 reasons', () => {
  it('lists the 19 reasons of REQ-702 criterion 4 and the 15 of REQ-720', () => {
    expect([...COUNT_REASONS].sort()).toEqual([
      'chair_without_user', 'count_line_exists', 'count_not_due', 'count_scope_incomplete', 'count_scope_not_linked',
      'count_scope_overlaps', 'count_state_invalid', 'count_too_long', 'employee_inactive', 'field_invalid', 'item_inactive',
      'line_not_found', 'lines_uncounted', 'location_not_in_count', 'lot_invalid', 'not_chair', 'not_commission_member',
      'org_unit_inactive', 'unit_invalid',
      'code_retired', 'code_assignment_conflict', 'code_not_assigned', 'code_not_countable', 'scan_no_line', 'scan_ambiguous',
      'scan_id_conflict', 'signers_incomplete', 'sheet_already_signed', 'sheet_not_signed', 'differences_already_issued',
      'differences_not_issued', 'differences_too_many', 'count_window_expired', 'document_not_issued', 'no_differences', 'reason_invalid',
    ].sort())
  })
  it.each(COUNT_REASONS)('%s shows its own message', async (reason) => {
    const box = await issueWith(problem(422, reason))
    expect(box).toHaveTextContent(countsEn[`counts.reason.${reason}`])
    expect(countsEn[`counts.reason.${reason}`]).toBeTruthy()
  })
})

describe('E2 other failures', () => {
  it('an unknown reason shows the generic message, 403 the forbidden one', async () => {
    expect(await issueWith(problem(422, 'brand_new'))).toHaveTextContent(countsEn['counts.error.generic'])
    cleanup()
    expect(await issueWith(problem(403))).toHaveTextContent(countsEn['counts.error.forbidden'])
  })
  it('field_invalid with a field shows the message next to the field of the form', async () => {
    fakeCounts(clientMock, { fail: { 'PUT /c1': problem(422, 'field_invalid', 'note') } })
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('count-edit'))
    await userEvent.click(await screen.findByTestId('count-save'))
    const field = (await screen.findByLabelText('Note', { exact: false })).closest('.lf-field')!
    expect(await within(field as HTMLElement).findByText(countsEn['counts.reason.field_invalid'])).toBeInTheDocument()
  })
})

describe('E3 not found', () => {
  it('a 404 on the detail shows the not-found state and the list stays usable', async () => {
    fakeCounts(clientMock)
    renderCounts(`${LIST}/missing`)
    expect(await screen.findByText(countsEn['counts.error.notFound'])).toBeInTheDocument()
    expect(await screen.findByText('CNT-0001')).toBeInTheDocument()
  })
})

describe('E4 list states', () => {
  it('shows loading, then the empty state with its action', async () => {
    fakeCounts(clientMock, { orders: [] })
    renderCounts(LIST)
    expect(screen.getAllByTestId('datatable-skeleton-row').length).toBeGreaterThan(0)
    expect(await screen.findByText(countsEn['counts.empty'])).toBeInTheDocument()
    expect(screen.getAllByText(countsEn['counts.new']).length).toBeGreaterThan(1)
  })
  it('shows the error banner with a retry that reloads', async () => {
    fakeCounts(clientMock, { fail: { 'GET ': problem(500) } })
    renderCounts(LIST)
    expect(await screen.findByText(countsEn['stock.error.generic'] ?? 'Something went wrong. Try again.')).toBeInTheDocument()
    clientMock.get.mockClear()
    await userEvent.click(screen.getByRole('button', { name: 'Retry' }))
    await waitFor(() => expect(clientMock.get).toHaveBeenCalledWith(BASE, {}))
  })
  it('shows the loading state and the load error of the detail', async () => {
    fakeCounts(clientMock, { fail: { 'GET /c1': problem(500) } })
    renderCounts(`${LIST}/c1`)
    expect(await screen.findByText('Something went wrong loading this content.')).toBeInTheDocument()
  })
})

describe('E5 sheet and entry states', () => {
  it('shows the empty states of lines and entries', async () => {
    fakeCounts(clientMock, { orders: [order({ status: 'counting' })], linePages: [[]], entryPages: [[]] })
    renderCounts(`${LIST}/c1`)
    expect(await screen.findByText(countsEn['counts.sheet.empty'])).toBeInTheDocument()
    expect(await screen.findByText(countsEn['counts.entries.empty'])).toBeInTheDocument()
  })
  it('shows the error banners of lines and entries', async () => {
    fakeCounts(clientMock, { orders: [order({ status: 'counting' })], linePages: [[line(1)]], fail: { 'GET /c1/lines': problem(500), 'GET /c1/entries': problem(500) } })
    renderCounts(`${LIST}/c1`)
    await waitFor(() => expect(screen.getAllByRole('button', { name: 'Retry' }).length).toBeGreaterThanOrEqual(2))
  })
})
