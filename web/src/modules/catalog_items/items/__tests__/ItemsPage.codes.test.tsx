// @vitest-environment jsdom
/** T-1960: the Codes section of the Items screen, through the real route and ListDetail (I1..I4). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { fakeServer, rec, renderLots } from '../../__tests__/catalogItemsTestKit'
import type { AccessState } from '@/auth/access/types'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-items' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const UOM = '11111111-1111-4111-8111-111111111111'
const I1 = '55555555-5555-4555-8555-555555555551'
const I2 = '55555555-5555-4555-8555-555555555552'
const access = (...extra: string[]): AccessState => ({ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['CatalogLotsWrite', 'StockRead', ...extra] } })
const ITEMS = '/admin/catalog/items'

function setup() {
  clientMock.get.mockReset().mockImplementation(async (path: string) => {
    if (path === '/api/v1/me/modules') return { installed_modules: [{ module_id: 'codes', version: '0.4.0' }] }
    return { rows: [], next_cursor: null }
  })
  clientMock.post.mockReset()
  fakeServer(clientMock, {
    catalog_item: [
      rec(I1, 'catalog_item', { code: 'BOLT', name: 'Steel bolt', base_uom_id: UOM, kind: 'material' }),
      rec(I2, 'catalog_item', { code: 'NUT', name: 'Hex nut', base_uom_id: UOM, kind: 'material' }),
    ],
    catalog_uom: [rec(UOM, 'catalog_uom', { code: 'PCS', name: 'Piece' })],
    code_assignment: [rec('a-1', 'code_assignment', { code_id: 'c-1', target_type: 'catalog_item', target_id: I1, assigned_at: '2026-11-14T07:00:00Z' })],
    code_tag: [rec('c-1', 'code_tag', { value: 'BOLT-BC-1', kind: 'barcode', status: 'assigned' })],
  }, (_m, path) => (path.endsWith('/receive') ? [{ code_id: 'c-new' }] : {}))
}
beforeEach(setup)
afterEach(cleanup)

const open = async (code: string) => fireEvent.click((await screen.findByText(code, { selector: 'td' })).closest('tr') as HTMLElement)
const writes = () => clientMock.post.mock.calls.filter(([p]) => p !== '/api/v1/entities/query')

describe('T-1960 Items codes', () => {
  it('I1 the selected item lists its codes in a Codes section with a count', async () => {
    renderLots(ITEMS, access('CodesRead', 'CodesWrite'))
    await open('BOLT')
    const section = await screen.findByTestId('record-codes')
    expect(await within(section).findByText('BOLT-BC-1')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /Codes/ })).toBeInTheDocument()
    expect(within(section).getByText('Barcode')).toBeInTheDocument()
  })

  it('I2 without CodesRead the section is absent and no code is read', async () => {
    renderLots(ITEMS, access())
    await open('BOLT')
    await screen.findByRole('heading', { level: 2, name: /BOLT/ })
    expect(screen.queryByTestId('record-codes')).not.toBeInTheDocument()
    expect(clientMock.post.mock.calls.some(([, b]) => String((b as { entity_type?: string }).entity_type).startsWith('code_'))).toBe(false)
  })

  it('I3 New code receives then attaches the value to this item', async () => {
    renderLots(ITEMS, access('CodesRead', 'CodesWrite'))
    await open('NUT')
    fireEvent.click(await screen.findByTestId('record-codes-new'))
    fireEvent.change(screen.getByTestId('record-codes-value'), { target: { value: 'NUT-1' } })
    fireEvent.click(screen.getByTestId('record-codes-dialog-confirm'))
    await waitFor(() => expect(writes()).toHaveLength(2))
    expect(writes()[0][0]).toBe('/api/v1/modules/codes/receive')
    expect(writes()[1][0]).toBe('/api/v1/modules/codes/c-new/assign')
    expect(writes()[1][1]).toMatchObject({ target_type: 'catalog_item', target_id: I2 })
  })

  it('I4 Escape in the New code dialog closes the dialog, not the item; a second Escape closes the item', async () => {
    renderLots(ITEMS, access('CodesRead', 'CodesWrite'))
    await open('NUT')
    fireEvent.click(await screen.findByTestId('record-codes-new'))
    const input = screen.getByTestId('record-codes-value')
    fireEvent.keyDown(input, { key: 'Escape' })
    await waitFor(() => expect(screen.queryByTestId('record-codes-value')).not.toBeInTheDocument())
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'open')
    fireEvent.keyDown(screen.getByTestId('registry'), { key: 'Escape' })
    await waitFor(() => expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed'))
  })
})
