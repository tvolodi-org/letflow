// @vitest-environment jsdom
/** K5–K7 — T-1336 / C16: the draft form of a change of kind, create and edit, and a server refusal placed on its line
 *  in en, ru and kk (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { DOCS, LIST, MASTERS, assetDoc, fakeDocument, fakeMasters, refusal, rec, renderAssets, withAll, withPost } from './registerTestKit'
import { assetsMessages } from '../assetsMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const NEW = `${LIST}/new?kind=kind_change`
const DATA = {
  ...MASTERS,
  catalog_item: [rec('i1', 'catalog_item', { code: 'CH', name: 'Chair', base_uom_id: 'm1', tracking_policy: 'none' })],
  catalog_uom: [rec('m1', 'catalog_uom', { code: 'pcs' })],
  catalog_lot: [],
}
const created = (): [string, Record<string, unknown>][] => clientMock.post.mock.calls.filter(([p]) => p === DOCS) as [string, Record<string, unknown>][]
const replaced = (): [string, Record<string, unknown>][] => clientMock.put.mock.calls as [string, Record<string, unknown>][]

function serve(saved: Record<string, unknown> = assetDoc({ id: 'dn', kind: 'kind_change', lines: [] })) {
  fakeMasters(clientMock, DATA)
  const masters = clientMock.post.getMockImplementation()!
  clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => (p === DOCS ? saved : masters(p, b)))
  clientMock.put.mockResolvedValue(saved)
  fakeDocument(clientMock, saved)
}
beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  serve()
})
afterEach(() => cleanup())

const form = () => within(screen.getByTestId('document-form'))
// Waits for the form to render before the first sync access (slow shards).
const formReady = async () => within(await screen.findByTestId('document-form'))
const save = () => fireEvent.click(screen.getByRole('button', { name: 'Save' }))
async function fillHeader() {
  await (await formReady()).findAllByRole('option', { name: 'WH - Warehouse' })
  fireEvent.change(form().getByLabelText('Time, date'), { target: { value: '2026-11-04' } })
  fireEvent.change(form().getByLabelText('Time, time'), { target: { value: '10:00' } })
  fireEvent.change(form().getByLabelText(/^Org unit/), { target: { value: 'u1' } })
}
async function fillLine() {
  fireEvent.click(await screen.findByRole('button', { name: 'Add line' }))
  const row = (await screen.findAllByTestId('line-editor-row'))[0]
  await within(row).findAllByRole('option', { name: 'R1 - Room 1' })
  await waitFor(() => {
    const input = within(row).getByLabelText('Stock: item')
    fireEvent.change(input, { target: { value: 'CH' } })
    fireEvent.blur(input)
    expect((input as HTMLInputElement).value).toContain('CH')
  })
  const set = (label: string, value: string) => fireEvent.change(within(row).getByLabelText(label), { target: { value } })
  set('Stock: quantity', '5')
  set('Stock: location', 'l1')
  set('Stock: responsible', 'e1')
  set('Asset: inventory number', ' LV-1 ')
  set('Asset: name', 'Chair on desks')
  set('Asset: location', 'l1')
  set('Asset: holder', 'e2')
  return row
}

describe('K5 create', () => {
  it('the header is unit, time, reason and note; Save posts kind_change with the 13 line keys and no card id', async () => {
    renderAssets(NEW, withPost)
    await fillHeader()
    expect(form().getByLabelText(/^Reason details/)).toBeInTheDocument()
    expect(form().queryByLabelText(/^Location/)).not.toBeInTheDocument()
    fireEvent.change(form().getByLabelText(/^Reason details/), { target: { value: 'stock became assets' } })
    await fillLine()
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toEqual({
      kind: 'kind_change', org_unit_id: 'u1', reason_text: 'stock became assets', event_time: '2026-11-04T10:00:00+05:00',
      lines: [{
        catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '5', stock_location_id: 'l1', stock_responsible_id: 'e1', target_kind: 'low_value',
        asset_location_id: 'l1', material_responsible_id: 'e2', inventory_number: 'LV-1', asset_name: 'Chair on desks',
      }],
    })
  })
  it('an empty line is refused before the request', async () => {
    renderAssets(NEW, withPost)
    await fillHeader()
    save()
    expect(created()).toHaveLength(0)
  })
})

const SAVED = assetDoc({
  kind: 'kind_change', location_id: undefined, material_responsible_id: undefined, actual_user_id: undefined, reason_text: 'r', note: null,
  lines: [{
    line_id: 'x1', line_no: 1, quantity: '5.000000000', catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null, stock_location_id: 'l1',
    stock_responsible_id: 'e1', target_kind: 'low_value', asset_org_unit_id: 'u2', asset_location_id: 'l1', material_responsible_id: 'e2',
    actual_user_id: 'e1', inventory_number: 'LV-1', asset_name: 'Chair',
  }],
})

describe('K6 edit', () => {
  it('Save replaces the whole header and every line value, without the kind', async () => {
    serve(SAVED)
    renderAssets(`${LIST}/d1`, withAll)
    fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
    await (await formReady()).findByRole('option', { name: 'WH - Warehouse' })
    await waitFor(() => expect(form().getByLabelText(/^Org unit/)).toHaveValue('u1'))
    expect(form().getByLabelText(/^Org unit/)).toBeDisabled()
    save()
    await waitFor(() => expect(replaced()).toHaveLength(1))
    expect(replaced()[0][0]).toBe(`${DOCS}/d1`)
    expect(replaced()[0][1]).toEqual({
      org_unit_id: 'u1', reason_text: 'r', event_time: '2026-11-04T10:00:00+05:00',
      lines: [{
        catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '5', stock_location_id: 'l1', stock_responsible_id: 'e1', target_kind: 'low_value',
        asset_org_unit_id: 'u2', asset_location_id: 'l1', material_responsible_id: 'e2', actual_user_id: 'e1', inventory_number: 'LV-1', asset_name: 'Chair',
      }],
    })
    expect(created()).toHaveLength(0)
  })
})

describe('K7 refusal on a line', () => {
  it('inventory_number_taken shows its message on the line (en); the message exists in ru and kk', async () => {
    serve(SAVED)
    clientMock.put.mockRejectedValue(refusal(422, 'inventory_number_taken', { line_no: 1 }))
    renderAssets(`${LIST}/d1`, withAll)
    fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
    await waitFor(() => expect(form().getByLabelText(/^Org unit/)).toHaveValue('u1'))
    save()
    const row = await screen.findByTestId('line-editor-row')
    await waitFor(() => expect(row).toHaveClass('is-error'))
    fireEvent.focusIn(within(row).getByLabelText('Asset: inventory number'))
    expect((await screen.findAllByText(/This inventory number is already used\./)).length).toBeGreaterThan(0)
    for (const l of ['en', 'ru', 'kk'] as const) {
      for (const id of ['inventory_number_taken', 'not_linked_stock', 'not_linked_asset', 'lot_required']) {
        expect(assetsMessages[l][`assets.doc.error.${id}`], `${l} ${id}`).toBeTruthy()
      }
    }
  })
})
