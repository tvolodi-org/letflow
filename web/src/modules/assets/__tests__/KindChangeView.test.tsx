// @vitest-environment jsdom
/** K8 — T-1336 / C16: the view of a change of kind document: header, both line groups, the card column, the actions
 *  (no Reverse: the server refuses it until the pair reversal exists). Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, within } from '@testing-library/react'
import { LIST, MASTERS, assetDoc, fakeDocument, fakeMasters, rec, renderAssets, withAll, withRead } from './registerTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const DATA = {
  ...MASTERS,
  catalog_item: [rec('i1', 'catalog_item', { code: 'CH', name: 'Chair', base_uom_id: 'm1', tracking_policy: 'none' })],
  catalog_uom: [rec('m1', 'catalog_uom', { code: 'pcs' })],
  catalog_lot: [rec('lot1', 'catalog_lot', { code: 'LOT-7' })],
  assets_card: [...MASTERS['assets_card']!, rec('c9', 'assets_card', { inventory_number: 'LV-1', name: 'Chair' })],
}
const KC_LINE = {
  line_id: 'x1', line_no: 1, quantity: '5.000000000', catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 'lot1',
  stock_location_id: 'l1', stock_responsible_id: 'e1', target_kind: 'low_value', asset_org_unit_id: null, asset_location_id: 'l1',
  material_responsible_id: 'e2', actual_user_id: null, inventory_number: 'LV-1', asset_name: 'Chair on desks',
}
const kcDoc = (over: Record<string, unknown> = {}) =>
  assetDoc({ kind: 'kind_change', location_id: undefined, material_responsible_id: undefined, actual_user_id: undefined, reason_text: 'Stock became assets', lines: [KC_LINE], ...over })

function serve(doc: Record<string, unknown>) {
  fakeMasters(clientMock, DATA)
  fakeDocument(clientMock, doc)
}
beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
})
afterEach(() => cleanup())

describe('K8 view of a change of kind', () => {
  it('draft: header (unit, reason), both line groups in one table, Edit / Issue / Discard, no Reverse', async () => {
    serve(kcDoc())
    renderAssets(`${LIST}/d1`, withAll)
    const header = await screen.findByTestId('document-header')
    expect(await within(header).findByText('WH - Warehouse')).toBeInTheDocument()
    expect(within(header).getByText('Stock became assets')).toBeInTheDocument()
    // no sides, no per-document location or people
    expect(within(header).queryByText('Location')).not.toBeInTheDocument()
    expect(screen.queryByTestId('view-side-from')).not.toBeInTheDocument()
    const lines = await screen.findByTestId('document-lines')
    for (const label of ['Stock: item', 'Stock: lot', 'Stock: quantity', 'Asset: kind', 'Asset: inventory number', 'Asset: holder', 'Asset card']) {
      expect(await within(lines).findAllByText(label)).not.toHaveLength(0)
    }
    expect(await within(lines).findAllByText('CH - Chair')).not.toHaveLength(0)
    expect(within(lines).getAllByText('LV-1').length).toBeGreaterThan(0)
    expect(within(lines).getAllByText('Low value').length).toBeGreaterThan(0)
    for (const name of ['Edit', 'Issue', 'Discard']) expect(screen.getByRole('button', { name })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Reverse' })).not.toBeInTheDocument()
  })
  it('issued: the waiting banner and the card column is a dash', async () => {
    serve(kcDoc({ state: 'issued', number: 'AKC-1', issued_at: '2026-11-04T05:00:00Z' }))
    renderAssets(`${LIST}/d1`, withAll)
    expect(await screen.findByText('The document is issued and waits for its post task in the inbox.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Issue' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Reverse' })).not.toBeInTheDocument()
  })
  it('posted: the asset card is named; no Reverse even with AssetsReverse; the movements link stays', async () => {
    serve(kcDoc({ state: 'posted', number: 'AKC-1', posted_at: '2026-11-04T06:00:00Z', lines: [{ ...KC_LINE, asset_card_id: 'c9' }] }))
    renderAssets(`${LIST}/d1`, withAll)
    const lines = await screen.findByTestId('document-lines')
    expect(await within(lines).findByText('LV-1 - Chair')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Reverse' })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Movements' })).toBeInTheDocument()
  })
  it('without AssetsPost there are no actions', async () => {
    serve(kcDoc())
    renderAssets(`${LIST}/d1`, withRead)
    await screen.findByTestId('document-lines')
    expect(screen.queryByTestId('document-actions')).not.toBeInTheDocument()
  })
  it('a posted document of another kind keeps Reverse', async () => {
    serve(assetDoc({ state: 'posted', number: 'ACM-1' }))
    renderAssets(`${LIST}/d1`, withAll)
    expect(await screen.findByRole('button', { name: 'Reverse' })).toBeInTheDocument()
  })
})
