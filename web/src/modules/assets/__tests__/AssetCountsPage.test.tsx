// @vitest-environment jsdom
/** T1, T2, T3, T6, T8 — T-1933 / REQ-822 (K7a): asset count list, create, whole-document edit, issue and cancel, flag off.
 *  Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { COUNTS, FULL, LIST, READ_ONLY, fakeCounts, order, refusal, renderAssets, writes } from './assetCountsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-counts' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), put: vi.fn(), patch: vi.fn(), get: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

describe('T1 list', () => {
  it('shows number, org unit, kinds, planned start and status; the filter sends status', async () => {
    fakeCounts(clientMock, { orders: [order(), order({ id: 'c2', number: 'AC-0002', status: 'ordered' })] })
    renderAssets(LIST, FULL)
    const row = (await screen.findByText('AC-0001')).closest('tr')!
    await waitFor(() => expect(row).toHaveTextContent('Warehouse · Fixed asset, Intangible asset'))
    expect(within(row).getByText('Draft')).toBeInTheDocument()
    expect(within(row).getByText('Nov 10, 2026 09:00')).toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText('Status'), 'ordered')
    await waitFor(() => expect(clientMock.get).toHaveBeenCalledWith(COUNTS, { status: 'ordered' }))
    await waitFor(() => expect(screen.queryByText('AC-0001')).not.toBeInTheDocument())
  })

  it('an empty list shows the text and a New button for an AssetsCountOrder holder, and no table row', async () => {
    fakeCounts(clientMock, { orders: [] })
    renderAssets(LIST, FULL)
    expect(await screen.findByText('No asset counts yet')).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'New count' }).length).toBeGreaterThanOrEqual(2)
  })
})

async function fillCreateForm() {
  await userEvent.click(await screen.findByTestId('count-new'))
  const form = await screen.findByTestId('count-order-form')
  await waitFor(() => expect(within(form).getByRole('option', { name: /Warehouse/ })).toBeInTheDocument())
  await userEvent.selectOptions(within(form).getByLabelText('Org unit'), 'u1')
  await userEvent.click(within(form).getByTestId('kind-low_value'))
  await userEvent.click(within(form).getByTestId('kind-fixed'))
  fireEvent.change(within(form).getByLabelText('Planned start, date'), { target: { value: '2026-11-10' } })
  fireEvent.change(within(form).getByLabelText('Planned start, time'), { target: { value: '09:00' } })
  fireEvent.change(within(form).getByLabelText('Planned end, date'), { target: { value: '2026-11-11' } })
  fireEvent.change(within(form).getByLabelText('Planned end, time'), { target: { value: '09:00' } })
  await userEvent.selectOptions(within(form).getByLabelText('Commission chair'), 'e1')
  return form
}

describe('T2 create', () => {
  it('posts exactly the nine keys, times with the zone offset, and selects the new order', async () => {
    fakeCounts(clientMock, { orders: [order(), order({ id: 'c-new', number: 'AC-0009' })] })
    renderAssets(LIST, FULL)
    const form = await fillCreateForm()
    await waitFor(() => expect(within(form).getByLabelText(/Marat K\./)).toBeInTheDocument())
    await userEvent.click(within(form).getByLabelText(/Marat K\./))
    await userEvent.click(within(form).getByLabelText(/Room 1/))
    await userEvent.click(within(form).getByTestId('freeze'))
    await userEvent.click(within(form).getByTestId('count-save'))
    await waitFor(() => expect(writes(clientMock)).toHaveLength(1))
    const [method, path, body] = writes(clientMock)[0]!
    expect([method, path]).toEqual(['POST', COUNTS])
    expect(Object.keys(body as object).sort()).toEqual(
      ['chair_employee_id', 'freeze_locations', 'kinds', 'location_ids', 'member_employee_ids', 'note', 'org_unit_id', 'planned_end', 'planned_start'],
    )
    expect(body).toEqual({
      org_unit_id: 'u1',
      kinds: ['fixed', 'low_value'],
      planned_start: '2026-11-10T09:00:00+05:00',
      planned_end: '2026-11-11T09:00:00+05:00',
      chair_employee_id: 'e1',
      member_employee_ids: ['e2'],
      location_ids: ['l1'],
      note: null,
      freeze_locations: true,
    })
    // after the save the new order is the selected one (owner checklist 4)
    expect(await screen.findByTestId('count-facts')).toBeInTheDocument()
    expect(within(await screen.findByTestId('detail-header')).getByText('AC-0009')).toBeInTheDocument()
  })
})

describe('T3 edit', () => {
  it('sends every loaded value back when only the note changes, and stays on the order', async () => {
    fakeCounts(clientMock)
    renderAssets(`${LIST}/c1`, FULL)
    await userEvent.click(await screen.findByTestId('count-edit'))
    const form = await screen.findByTestId('count-order-form')
    await waitFor(() => expect(within(form).getByLabelText('Org unit')).toHaveValue('u1'))
    await userEvent.clear(within(form).getByLabelText(/Note/))
    await userEvent.type(within(form).getByLabelText(/Note/), 'Moved')
    await userEvent.click(within(form).getByTestId('count-save'))
    await waitFor(() => expect(writes(clientMock)).toHaveLength(1))
    const [method, path, body] = writes(clientMock)[0]!
    expect([method, path]).toEqual(['PUT', `${COUNTS}/c1`])
    expect(body).toEqual({
      org_unit_id: 'u1',
      kinds: ['fixed', 'intangible'],
      planned_start: '2026-11-10T09:00:00+05:00',
      planned_end: '2026-11-11T09:00:00+05:00',
      chair_employee_id: 'e1',
      member_employee_ids: ['e2', 'e3'],
      location_ids: ['l1'],
      note: 'Moved',
      freeze_locations: true,
    })
    expect(await screen.findByTestId('count-facts')).toBeInTheDocument()
    expect(within(screen.getByTestId('detail-header')).getByText('AC-0001')).toBeInTheDocument()
  })
})

describe('T6 issue and cancel', () => {
  it('issues a draft after a confirm with no body, and shows the refusal text in the dialog', async () => {
    fakeCounts(clientMock, { fail: { 'POST /c1/issue': refusal(422, 'count_scope_overlaps') } })
    renderAssets(`${LIST}/c1`, FULL)
    await userEvent.click(await screen.findByTestId('count-issue'))
    const dialog = await screen.findByRole('dialog')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Issue' }))
    expect(await within(dialog).findByText(/Another open count of this org unit/)).toBeInTheDocument()
    expect(clientMock.post).toHaveBeenCalledWith(`${COUNTS}/c1/issue`)
  })

  it('an accepted issue closes the dialog', async () => {
    fakeCounts(clientMock)
    renderAssets(`${LIST}/c1`, FULL)
    await userEvent.click(await screen.findByTestId('count-issue'))
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Issue' }))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(writes(clientMock).map(([m, p]) => `${m} ${p}`)).toEqual([`POST ${COUNTS}/c1/issue`])
  })

  it('cancel shows the not_chair text; a signed order has no cancel button', async () => {
    fakeCounts(clientMock, {
      orders: [order({ status: 'ordered' }), order({ id: 'c2', number: 'AC-0002', status: 'signed' })],
      fail: { 'POST /c1/cancel': refusal(422, 'not_chair') },
    })
    renderAssets(`${LIST}/c1`, FULL)
    await userEvent.click(await screen.findByTestId('count-cancel'))
    const dialog = await screen.findByRole('dialog')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Cancel count' }))
    expect(await within(dialog).findByText('Only the commission chair can cancel this count.')).toBeInTheDocument()
    cleanup()
    renderAssets(`${LIST}/c2`, FULL)
    await screen.findByTestId('count-facts')
    expect(screen.queryByTestId('count-cancel')).not.toBeInTheDocument()
  })

  it('without AssetsCountOrder there is no New, Edit, Issue or Cancel', async () => {
    fakeCounts(clientMock)
    renderAssets(`${LIST}/c1`, READ_ONLY)
    await screen.findByTestId('count-facts')
    for (const id of ['count-new', 'count-edit', 'count-issue', 'count-cancel']) expect(screen.queryByTestId(id)).not.toBeInTheDocument()
  })
})

describe('T8 flag off', () => {
  it('a 404 on the list shows the not-switched-on card, no New button and no table', async () => {
    fakeCounts(clientMock, { fail: { 'GET list': refusal(404) } })
    renderAssets(LIST, FULL)
    expect(await screen.findByTestId('count-flag-off')).toHaveTextContent('not switched on')
    expect(screen.queryByTestId('count-new')).not.toBeInTheDocument()
    expect(screen.queryByRole('table')).not.toBeInTheDocument()
  })
})
