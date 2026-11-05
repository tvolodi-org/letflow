// @vitest-environment jsdom
/** O1–O8 — GH 3735 / REQ-702 criterion 2: count list, order form, issue and cancel. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { BASE, LIST, READ_ONLY, accessOf, fakeCounts, order, renderCounts, writes } from './countsTestKit'
import { queryBodies } from './stockTestKit'

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

describe('O1 list', () => {
  it('shows number, org unit, kind, planned start and status', async () => {
    fakeCounts(clientMock)
    renderCounts(LIST)
    const row = (await screen.findByText('CNT-0001')).closest('tr')!
    for (const text of ['Nov 10, 2026 09:00', 'Draft']) {
      await waitFor(() => expect(within(row).getByText(text)).toBeInTheDocument())
    }
    // the org unit and the kind share the muted second line of the Number cell (R7, wide list); the chair is in the detail
    await waitFor(() => expect(row).toHaveTextContent('Main store · Full'))
  })
})

describe('O2 filter and paging', () => {
  it('sends the status filter and follows next_cursor', async () => {
    fakeCounts(clientMock, { orderPages: [[order()], [order({ id: 'c2', number: 'CNT-0002' })]] })
    renderCounts(LIST)
    await screen.findByText('CNT-0001')
    await userEvent.click(screen.getByTestId('load-more'))
    expect(await screen.findByText('CNT-0002')).toBeInTheDocument()
    expect(clientMock.get).toHaveBeenCalledWith(BASE, { cursor: 'p1' })
    await userEvent.selectOptions(screen.getByLabelText('Status'), 'ordered')
    await waitFor(() => expect(clientMock.get).toHaveBeenCalledWith(BASE, { status: 'ordered' }))
  })
})

describe('O3 create', () => {
  it('posts the exact whole-draft body', async () => {
    fakeCounts(clientMock)
    renderCounts(LIST)
    await userEvent.click(await screen.findByTestId('count-new'))
    const form = await screen.findByTestId('count-order-form')
    await waitFor(() => expect(within(form).getByRole('option', { name: 'Main store' })).toBeInTheDocument())
    await userEvent.selectOptions(within(form).getByLabelText('Org unit'), 'u1')
    await userEvent.selectOptions(within(form).getByLabelText('Kind'), 'selective')
    fireEvent.change(within(form).getByLabelText('Planned start'), { target: { value: '2026-11-10T09:00' } })
    fireEvent.change(within(form).getByLabelText('Planned end'), { target: { value: '2026-11-11T18:30' } })
    await userEvent.selectOptions(within(form).getByLabelText('Chair of the commission'), 'e1')
    await userEvent.click(await within(screen.getByTestId('members')).findByLabelText('Marat K.'))
    await userEvent.click(await within(screen.getByTestId('locations')).findByLabelText('Shelf A'))
    await userEvent.click(screen.getByTestId('count-save'))
    await waitFor(() => expect(writes(clientMock)).toHaveLength(1))
    expect(writes(clientMock)[0]).toEqual(['POST', BASE, {
      org_unit_id: 'u1', kind: 'selective', planned_start: '2026-11-10T09:00:00+05:00', planned_end: '2026-11-11T18:30:00+05:00',
      chair_employee_id: 'e1', member_employee_ids: ['e2'], location_ids: ['l1'], note: null,
    }])
  })

  it('does not send an incomplete form', async () => {
    fakeCounts(clientMock)
    renderCounts(LIST)
    await userEvent.click(await screen.findByTestId('count-new'))
    await userEvent.click(await screen.findByTestId('count-save'))
    expect(await screen.findByText('Fill in the org unit, times, chair and at least one location root.')).toBeInTheDocument()
    expect(writes(clientMock)).toEqual([])
  })
})

describe('O4 edit', () => {
  it('removing one member PUTs the whole draft with the list one shorter', async () => {
    fakeCounts(clientMock)
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('count-edit'))
    const members = await screen.findByTestId('members')
    await userEvent.click(await within(members).findByLabelText('Dana S.'))
    await userEvent.click(screen.getByTestId('count-save'))
    await waitFor(() => expect(writes(clientMock)).toHaveLength(1))
    expect(writes(clientMock)[0]).toEqual(['PUT', `${BASE}/c1`, {
      org_unit_id: 'u1', kind: 'full', planned_start: '2026-11-10T09:00:00+05:00', planned_end: '2026-11-11T09:00:00+05:00',
      chair_employee_id: 'e1', member_employee_ids: ['e2'], location_ids: ['l1'], note: 'Year end',
    }])
  })
})

describe('O5 issue and cancel', () => {
  it('call their routes only after the confirm dialog', async () => {
    fakeCounts(clientMock)
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('count-issue'))
    await userEvent.click(within(await screen.findByTestId('confirm-dialog')).getByTestId('confirm-dialog-cancel'))
    expect(writes(clientMock)).toEqual([])
    await userEvent.click(screen.getByTestId('count-issue'))
    await userEvent.click(within(await screen.findByTestId('confirm-dialog')).getByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writes(clientMock)).toEqual([['POST', `${BASE}/c1/issue`, undefined]]))
    await waitFor(() => expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument())
    await userEvent.click(screen.getByTestId('count-cancel'))
    await userEvent.click(within(await screen.findByTestId('confirm-dialog')).getByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writes(clientMock)[1]).toEqual(['POST', `${BASE}/c1/cancel`, undefined]))
  })
})

describe('O6 no StockCountOrder', () => {
  it('shows no New, Edit, Issue or Cancel button', async () => {
    fakeCounts(clientMock)
    renderCounts(`${LIST}/c1`, READ_ONLY)
    await screen.findByTestId('count-facts')
    for (const id of ['count-new', 'count-edit', 'count-issue', 'count-cancel']) expect(screen.queryByTestId(id)).not.toBeInTheDocument()
    expect(screen.getByTestId('count-detail-close')).toBeInTheDocument()
  })
  it('with StockCountRecord only still shows no order button', async () => {
    fakeCounts(clientMock, { orders: [order({ status: 'ordered' })] })
    renderCounts(`${LIST}/c1`, accessOf('StockRead', 'StockCountRecord'))
    await screen.findByTestId('count-open')
    expect(screen.queryByTestId('count-cancel')).not.toBeInTheDocument()
  })
})

describe('O7 status not draft', () => {
  it.each(['ordered', 'counting', 'counted'])('has no Edit or Issue button in status %s', async (status) => {
    fakeCounts(clientMock, { orders: [order({ status })] })
    renderCounts(`${LIST}/c1`)
    await screen.findByTestId('count-cancel')
    expect(screen.queryByTestId('count-edit')).not.toBeInTheDocument()
    expect(screen.queryByTestId('count-issue')).not.toBeInTheDocument()
  })
  it('has no Cancel button once cancelled', async () => {
    fakeCounts(clientMock, { orders: [order({ status: 'cancelled' })] })
    renderCounts(`${LIST}/c1`)
    await screen.findByTestId('count-facts')
    expect(screen.queryByTestId('count-cancel')).not.toBeInTheDocument()
  })
})

describe('O8 pickers', () => {
  it('read org_unit, org_employee and location_node through the entity query route only', async () => {
    fakeCounts(clientMock)
    renderCounts(LIST)
    await userEvent.click(await screen.findByTestId('count-new'))
    await screen.findByTestId('count-order-form')
    await waitFor(() => {
      for (const type of ['org_unit', 'org_employee', 'location_node']) expect(queryBodies(clientMock, type).length).toBeGreaterThan(0)
    })
    const paths = clientMock.get.mock.calls.map(([p]) => p as string)
    expect(paths.every((p) => p.startsWith(BASE))).toBe(true)
  })
})

async function openForm() {
  fakeCounts(clientMock)
  renderCounts(LIST)
  await userEvent.click(await screen.findByTestId('count-new'))
  const form = await screen.findByTestId('count-order-form')
  await waitFor(() => expect(within(form).getByRole('option', { name: 'Main store' })).toBeInTheDocument())
  return form
}
async function fill(form: HTMLElement, skip: string[] = [], start = '2026-11-10T09:00:30') {
  if (!skip.includes('org_unit_id')) await userEvent.selectOptions(within(form).getByLabelText('Org unit'), 'u1')
  if (!skip.includes('planned_start')) fireEvent.change(within(form).getByLabelText('Planned start'), { target: { value: start } })
  if (!skip.includes('planned_end')) fireEvent.change(within(form).getByLabelText('Planned end'), { target: { value: '2026-11-11T18:30' } })
  if (!skip.includes('chair_employee_id')) await userEvent.selectOptions(within(form).getByLabelText('Chair of the commission'), 'e1')
  await userEvent.click(await within(screen.getByTestId('members')).findByLabelText('Marat K.'))
  if (!skip.includes('location_ids')) await userEvent.click(await within(screen.getByTestId('locations')).findByLabelText('Shelf A'))
}

describe('O9 owner case (T-1382)', () => {
  it('creates the order when the start carries seconds, as a browser can deliver it', async () => {
    const form = await openForm()
    await fill(form)
    await userEvent.click(screen.getByTestId('count-save'))
    await waitFor(() => expect(writes(clientMock)).toHaveLength(1))
    expect(writes(clientMock)[0]).toEqual(['POST', BASE, {
      org_unit_id: 'u1', kind: 'full', planned_start: '2026-11-10T09:00:00+05:00', planned_end: '2026-11-11T18:30:00+05:00',
      chair_employee_id: 'e1', member_employee_ids: ['e2'], location_ids: ['l1'], note: null,
    }])
    expect(screen.queryByText(/Fill in the org unit/)).toBeNull()
  })
})

describe('O10 each missing field is named', () => {
  it.each([
    ['org_unit_id', 'Org unit', 'This field is required: choose an org unit.'],
    ['planned_start', 'Planned start', 'Enter a valid planned start (date and time).'],
    ['planned_end', 'Planned end', 'Enter a valid planned end (date and time).'],
    ['chair_employee_id', 'Chair of the commission', 'Choose the chair of the commission.'],
  ])('%s', async (name, label, text) => {
    const form = await openForm()
    await fill(form, [name])
    await userEvent.click(screen.getByTestId('count-save'))
    expect(await within(form).findByText(text)).toBeInTheDocument()
    expect(within(form).getByLabelText(label)).toHaveAttribute('aria-invalid', 'true')
    expect(within(form).getByText(new RegExp(`Check: ${label}\\.`))).toBeInTheDocument()
    expect(writes(clientMock)).toEqual([])
  })

  it('location_ids', async () => {
    const form = await openForm()
    await fill(form, ['location_ids'])
    await userEvent.click(screen.getByTestId('count-save'))
    expect(await within(screen.getByTestId('locations')).findByText('Choose at least one location root.')).toBeInTheDocument()
    expect(within(form).getByText(/Check: Location roots\./)).toBeInTheDocument()
    expect(writes(clientMock)).toEqual([])
  })

  it('end before start is named on the end field', async () => {
    const form = await openForm()
    await fill(form, [], '2026-11-12T09:00')
    await userEvent.click(screen.getByTestId('count-save'))
    expect(await within(form).findByText('The planned end must be after the planned start.')).toBeInTheDocument()
    expect(writes(clientMock)).toEqual([])
  })
})

describe('O11 locales', () => {
  it.each([
    ['ru', 'Проверьте: Подразделение, Плановое начало.', 'Обязательное поле: выберите подразделение.'],
    ['kk', 'Тексеріңіз: Бөлімше, Жоспарлы басталуы.', 'Міндетті өріс: бөлімшені таңдаңыз.'],
  ] as const)('%s', async (loc, summary, fieldText) => {
    useUiLocaleStore.getState().setLocaleTransient(loc)
    fakeCounts(clientMock)
    renderCounts(LIST)
    await userEvent.click(await screen.findByTestId('count-new'))
    const form = await screen.findByTestId('count-order-form')
    await waitFor(() => expect(form.querySelectorAll('select')[0]!.querySelectorAll('option').length).toBeGreaterThan(1))
    await userEvent.selectOptions(form.querySelectorAll('select')[2]!, 'e1')
    fireEvent.change(form.querySelector('input[name="planned_end"]')!, { target: { value: '2026-11-11T18:30' } })
    await userEvent.click(await within(screen.getByTestId('locations')).findByLabelText('Shelf A'))
    await userEvent.click(screen.getByTestId('count-save'))
    expect(await within(form).findByText(new RegExp(summary.replace('.', '\\.')))).toBeInTheDocument()
    expect(within(form).getByText(fieldText)).toBeInTheDocument()
  })
})

describe('O12 error clears when fixed', () => {
  it('then the save posts', async () => {
    const form = await openForm()
    await fill(form, ['org_unit_id'])
    await userEvent.click(screen.getByTestId('count-save'))
    await within(form).findByText('This field is required: choose an org unit.')
    await userEvent.selectOptions(within(form).getByLabelText('Org unit'), 'u1')
    expect(within(form).queryByText('This field is required: choose an org unit.')).toBeNull()
    await userEvent.click(screen.getByTestId('count-save'))
    await waitFor(() => expect(writes(clientMock)).toHaveLength(1))
  })
})
