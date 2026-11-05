// @vitest-environment jsdom
/** T1..T5 — GH 3853 / REQ-723: the draft forms of transfer, hand over and return, with a From and a To side (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { stockMessages } from '../stockMessages'
import { DOCS, LIST, MASTERS, fakeMasters, refusal, rec, renderStock, stockDoc, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const NEW = `${LIST}/new`
const TWO = {
  ...MASTERS,
  org_unit: [rec('u1', { name: 'Main store' }), rec('u2', { name: 'Branch store' })],
  location_node: [rec('l1', { name: 'Shelf A' }), rec('l2', { name: 'Shelf B' })],
  org_employee: [rec('e1', { full_name: 'Aigul B.' }), rec('e2', { full_name: 'Marat K.' })],
}
const created = (): [string, Record<string, unknown>][] =>
  clientMock.post.mock.calls.filter(([p]) => p === DOCS) as [string, Record<string, unknown>][]

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock, TWO)
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
  window.localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  window.localStorage.clear()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

const group = (side: 'from' | 'to') => screen.getByTestId(`side-${side}`)
const pick = (side: 'from' | 'to', label: string, value: string) =>
  fireEvent.change(within(group(side)).getByLabelText(label), { target: { value } })
const save = () => fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
const firstRow = () => screen.getAllByTestId('line-editor-row')[0]

async function ready() {
  await screen.findAllByRole('option', { name: 'Branch store' })
  await screen.findAllByRole('option', { name: 'Shelf B' })
  await screen.findAllByRole('option', { name: 'Marat K.' })
  fireEvent.change(screen.getByLabelText('Event time'), { target: { value: '2026-11-04T10:00' } })
}
async function fillSides(from: [string, string, string], to: [string, string, string]) {
  for (const [side, v] of [['from', from], ['to', to]] as const) {
    pick(side, 'Org unit', v[0])
    pick(side, 'Location', v[1])
    pick(side, 'Responsible', v[2])
  }
}
async function fillLine() {
  const row = firstRow()
  await within(row).findByRole('option', { name: 'Bolt M8' })
  fireEvent.change(within(row).getByLabelText('Item'), { target: { value: 'i1' } })
  fireEvent.change(within(row).getByLabelText('Quantity'), { target: { value: '2' } })
  await waitFor(() => expect(within(row).getByLabelText('Unit')).toHaveValue('pcs'))
}
const LINES = [{ catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '2' }]

describe('T1 create per kind', () => {
  it('T1a transfer: exact body', async () => {
    renderStock(`${NEW}?kind=transfer`, withPost)
    await ready()
    await fillSides(['u1', 'l1', 'e1'], ['u2', 'l2', 'e2'])
    await fillLine()
    pick('from', 'Org unit', 'u1')
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toEqual({
      kind: 'transfer', event_time: '2026-11-04T10:00:00+05:00', org_unit_id: 'u1', from_location_id: 'l1', from_responsible_id: 'e1',
      to_org_unit_id: 'u2', to_location_id: 'l2', to_responsible_id: 'e2', lines: LINES,
    })
  })
  it('T1b hand over: exact body', async () => {
    renderStock(`${NEW}?kind=hand_over`, withPost)
    await ready()
    await fillSides(['u1', 'l1', 'e1'], ['u1', 'l1', 'e2'])
    await fillLine()
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toEqual({
      kind: 'hand_over', event_time: '2026-11-04T10:00:00+05:00', org_unit_id: 'u1', from_location_id: 'l1', from_responsible_id: 'e1',
      to_org_unit_id: 'u1', to_location_id: 'l1', to_responsible_id: 'e2', lines: LINES,
    })
  })
  it('T1c return: exact body, the document org unit is the To one', async () => {
    renderStock(`${NEW}?kind=return`, withPost)
    await ready()
    fireEvent.change(screen.getByLabelText(/^Note/), { target: { value: 'back' } })
    await fillSides(['u2', 'l2', 'e2'], ['u1', 'l1', 'e1'])
    await fillLine()
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toEqual({
      kind: 'return', event_time: '2026-11-04T10:00:00+05:00', from_org_unit_id: 'u2', from_location_id: 'l2', from_responsible_id: 'e2',
      org_unit_id: 'u1', to_location_id: 'l1', to_responsible_id: 'e1', note: 'back', lines: LINES,
    })
  })
  it('T1d shows event time, note, From and To groups and no counterparty, price or reason field', async () => {
    renderStock(`${NEW}?kind=transfer`, withPost)
    await ready()
    expect(screen.getByLabelText('Event time')).toBeInTheDocument()
    expect(screen.getByLabelText(/^Note/)).toBeInTheDocument()
    expect(group('from')).toHaveAccessibleName('From')
    expect(group('to')).toHaveAccessibleName('To')
    for (const side of ['from', 'to'] as const) {
      for (const l of ['Org unit', 'Location', 'Responsible']) expect(within(group(side)).getByLabelText(l)).toBeInTheDocument()
    }
    for (const l of [/^Counterparty/, /^Supplier document/, /^Received on/, /^Reason/]) expect(screen.queryByLabelText(l)).not.toBeInTheDocument()
    expect(within(firstRow()).queryByLabelText(/^Unit price/)).not.toBeInTheDocument()
    expect(within(firstRow()).getByLabelText('Unit')).toHaveAttribute('readonly')
  })
  it('T1e hand over copies From org unit and location into To until To is touched', async () => {
    renderStock(`${NEW}?kind=hand_over`, withPost)
    await ready()
    pick('from', 'Org unit', 'u2')
    pick('from', 'Location', 'l2')
    expect(within(group('to')).getByLabelText('Org unit')).toHaveValue('u2')
    expect(within(group('to')).getByLabelText('Location')).toHaveValue('l2')
    expect(within(group('to')).getByLabelText('Responsible')).toHaveValue('')
    pick('to', 'Location', 'l1')
    pick('from', 'Location', 'l2')
    expect(within(group('to')).getByLabelText('Location')).toHaveValue('l1')
    pick('from', 'Responsible', 'e1')
    pick('to', 'Responsible', 'e2')
    await fillLine()
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toMatchObject({ org_unit_id: 'u2', from_location_id: 'l2', to_org_unit_id: 'u2', to_location_id: 'l1', to_responsible_id: 'e2' })
  })
  it('a transfer does not copy From into To', async () => {
    renderStock(`${NEW}?kind=transfer`, withPost)
    await ready()
    pick('from', 'Org unit', 'u2')
    expect(within(group('to')).getByLabelText('Org unit')).toHaveValue('')
  })
  it('edit of a return keeps the document org unit fixed on the To side and sends the whole header', async () => {
    const doc = stockDoc({
      id: 'd9', kind: 'return', org_unit_id: 'u1', to_location_id: 'l1', to_responsible_id: 'e1',
      from_org_unit_id: 'u2', from_location_id: 'l2', from_responsible_id: 'e2',
      lines: [{ line_id: 'a', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '2' }],
    })
    clientMock.get.mockImplementation(async (p: string) => (p === `${DOCS}/d9` ? doc : { rows: [], next_cursor: null }))
    clientMock.put.mockResolvedValue(doc)
    renderStock(`${LIST}/d9`, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
    await screen.findByTestId('document-form')
    await screen.findAllByRole('option', { name: 'Branch store' })
    expect(within(group('to')).getByLabelText('Org unit')).toBeDisabled()
    expect(within(group('from')).getByLabelText('Org unit')).not.toBeDisabled()
    expect(within(group('from')).getByLabelText('Org unit')).toHaveValue('u2')
    save()
    await waitFor(() => expect(clientMock.put).toHaveBeenCalledTimes(1))
    expect(clientMock.put.mock.calls[0][1]).toEqual({
      kind: 'return', event_time: '2026-11-04T10:00:00+05:00', from_org_unit_id: 'u2', from_location_id: 'l2', from_responsible_id: 'e2',
      org_unit_id: 'u1', to_location_id: 'l1', to_responsible_id: 'e1', lines: LINES,
    })
  })
})

describe('T2 equal sides', () => {
  const SAME = 'The From and To sides are the same. Change the org unit, the location or the responsible.'
  it('T2a equal sides are not sent and say why', async () => {
    renderStock(`${NEW}?kind=transfer`, withPost)
    await ready()
    await fillSides(['u1', 'l1', 'e1'], ['u1', 'l1', 'e1'])
    await fillLine()
    save()
    expect(await screen.findByText(SAME)).toBeInTheDocument()
    expect(created()).toHaveLength(0)
  })
  it('T2b the server sides_equal shows the same text', async () => {
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
      if (p === DOCS) throw refusal(422, 'sides_equal')
      return { items: TWO[(b as { entity_type: string }).entity_type] ?? [], next_cursor: null }
    })
    renderStock(`${NEW}?kind=transfer`, withPost)
    await ready()
    await fillSides(['u1', 'l1', 'e1'], ['u2', 'l2', 'e2'])
    await fillLine()
    save()
    expect(await screen.findByText(SAME)).toBeInTheDocument()
  })
  it('T2c sides that differ only in the responsible are sent', async () => {
    renderStock(`${NEW}?kind=transfer`, withPost)
    await ready()
    await fillSides(['u1', 'l1', 'e1'], ['u1', 'l1', 'e2'])
    await fillLine()
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
  })
  it('a missing side value is marked and nothing is sent', async () => {
    renderStock(`${NEW}?kind=transfer`, withPost)
    await ready()
    await fillLine()
    save()
    expect(within(group('from')).getAllByText('This field is required.').length).toBe(3)
    expect(within(group('to')).getAllByText('This field is required.').length).toBe(3)
    expect(created()).toHaveLength(0)
  })
})

describe('T4 side refusals', () => {
  async function refused(reason: string, side: 'from' | 'to') {
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
      if (p === DOCS) throw refusal(422, reason, { side })
      return { items: TWO[(b as { entity_type: string }).entity_type] ?? [], next_cursor: null }
    })
    renderStock(`${NEW}?kind=hand_over`, withPost)
    await ready()
    await fillSides(['u1', 'l1', 'e1'], ['u1', 'l1', 'e2'])
    await fillLine()
    save()
  }
  it('T4a not_linked on the from side shows on the From group only', async () => {
    await refused('not_linked', 'from')
    expect(await within(group('from')).findByText(stockMessages.en['stock.doc.error.not_linked'])).toBeInTheDocument()
    expect(within(group('to')).queryByText(stockMessages.en['stock.doc.error.not_linked'])).not.toBeInTheDocument()
  })
  it('T4b employee_not_active on the to side shows on the To group only', async () => {
    await refused('employee_not_active', 'to')
    expect(await within(group('to')).findByText(stockMessages.en['stock.doc.error.employee_not_active'])).toBeInTheDocument()
    expect(within(group('from')).queryByText(stockMessages.en['stock.doc.error.employee_not_active'])).not.toBeInTheDocument()
  })
})

describe('T5 languages', () => {
  for (const locale of ['ru', 'kk'] as const) {
    it(`${locale}: the groups, the kind and the equal-sides text are translated`, async () => {
      useUiLocaleStore.getState().setLocaleTransient(locale)
      renderStock(`${NEW}?kind=transfer`, withPost)
      await screen.findByTestId('side-from')
      expect(group('from')).toHaveAccessibleName(stockMessages[locale]['stock.doc.side.from'])
      expect(group('to')).toHaveAccessibleName(stockMessages[locale]['stock.doc.side.to'])
      expect(screen.getByText(stockMessages[locale]['stock.doc.kind.transfer'], { selector: 'p' })).toBeInTheDocument()
      await act(async () => undefined)
    })
  }
})
