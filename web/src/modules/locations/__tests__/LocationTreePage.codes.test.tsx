// @vitest-environment jsdom
/** T-1960: the Codes tab of the Locations panel, through the real route and ListDetail (L1..L4). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { fakeServer, rec, renderLocations } from './locationsTestKit'
import type { AccessState } from '@/auth/access/types'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-loc' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const access = (...extra: string[]): AccessState => ({ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['LocationsWrite', ...extra] } })

function setup() {
  clientMock.get.mockReset().mockImplementation(async () => ({ installed_modules: [{ module_id: 'codes', version: '0.4.0' }] }))
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
  fakeServer(clientMock, {
    location_node: [
      rec('n-a', 'location_node', { code: 'A', name: 'Loc A', node_kind: 'zone' }),
      rec('n-b', 'location_node', { code: 'B', name: 'Loc B', node_kind: 'zone' }),
    ],
    code_assignment: [rec('a-1', 'code_assignment', { code_id: 'c-1', target_type: 'location_node', target_id: 'n-a', assigned_at: '2026-11-14T07:00:00Z' })],
    code_tag: [rec('c-1', 'code_tag', { value: 'LOC-A-QR', kind: 'qr', status: 'assigned' })],
  }, (_m, path) => (path.endsWith('/receive') ? [{ code_id: 'c-new' }] : {}))
}
beforeEach(setup)
afterEach(cleanup)

async function openCodes(code = 'A') {
  renderLocations('/admin/locations', access('CodesRead', 'CodesWrite'))
  fireEvent.click(await screen.findByTitle(code))
  fireEvent.click(await screen.findByRole('tab', { name: /Codes/ }))
}
const writes = () => clientMock.post.mock.calls.filter(([p]) => p !== '/api/v1/entities/query')

describe('T-1960 Locations codes', () => {
  it('L1 the Codes tab lists the codes of the selected location', async () => {
    await openCodes()
    expect(await within(await screen.findByTestId('record-codes')).findByText('LOC-A-QR')).toBeInTheDocument()
    expect(screen.getByRole('tab', { name: /Details/ })).toBeInTheDocument()
  })

  it('L2 without CodesRead there are no tabs and no code read', async () => {
    renderLocations('/admin/locations', access())
    fireEvent.click(await screen.findByTitle('A'))
    await screen.findByRole('heading', { level: 2 })
    expect(screen.queryByRole('tab', { name: /Codes/ })).not.toBeInTheDocument()
    expect(clientMock.post.mock.calls.some(([, b]) => String((b as { entity_type?: string }).entity_type).startsWith('code_'))).toBe(false)
  })

  it('L3 New code receives then attaches the value to this location', async () => {
    await openCodes('B')
    fireEvent.click(await screen.findByTestId('record-codes-new'))
    fireEvent.change(screen.getByTestId('record-codes-value'), { target: { value: 'LOC-B-1' } })
    fireEvent.click(screen.getByTestId('record-codes-dialog-confirm'))
    await waitFor(() => expect(writes()).toHaveLength(2))
    expect(writes()[1][0]).toBe('/api/v1/modules/codes/c-new/assign')
    expect(writes()[1][1]).toMatchObject({ target_type: 'location_node', target_id: 'n-b' })
  })

  it('L4 Escape in the New code dialog closes only the dialog; a second Escape closes the panel', async () => {
    await openCodes('B')
    fireEvent.click(await screen.findByTestId('record-codes-new'))
    fireEvent.keyDown(screen.getByTestId('record-codes-value'), { key: 'Escape' })
    await waitFor(() => expect(screen.queryByTestId('record-codes-value')).not.toBeInTheDocument())
    expect(screen.getByTestId('record-codes')).toBeInTheDocument()
    fireEvent.keyDown(screen.getByTestId('record-codes'), { key: 'Escape' })
    await waitFor(() => expect(screen.queryByTestId('record-codes')).not.toBeInTheDocument())
  })
})
