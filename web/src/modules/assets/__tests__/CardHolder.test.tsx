// @vitest-environment jsdom
/** W3–W6 — T-1488 / G1-a: the card panel's holder section is read from the register (balances?asset=<id>), absent
 *  without AssetsRead, says "not commissioned" for no rows, and shows the register error on a failed read. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { clearAllToasts } from '@/hooks/useToast'
import type { AccessState } from '@/auth/access/types'
import { fakeServer, problem, rec, renderAssets, withAtom } from './assetsTestKit'
import { assetsMessages } from '../assetsMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const en = assetsMessages.en
const withRead: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['AssetsCardWrite', 'AssetsRead'] },
}
const DATA = {
  assets_card: [
    rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'Asset FA-1', kind: 'fixed' }),
    rec('c-4', 'assets_card', { inventory_number: 'FA-4', name: 'Asset FA-4', kind: 'fixed', active: false }),
  ],
  org_unit: [rec('u-1', 'org_unit', { code: 'U1', name: 'Head office' })],
  location_node: [rec('l-1', 'location_node', { code: 'L1', name: 'Main hall' })],
  org_employee: [
    rec('e-1', 'org_employee', { code: 'E1', full_name: 'Aigul Responsible', name: 'Aigul Responsible' }),
    rec('e-2', 'org_employee', { code: 'E2', full_name: 'Bolat User', name: 'Bolat User' }),
  ],
}
const ROW = { asset: 'c-1', org_unit: 'u-1', location: 'l-1', material_responsible: 'e-1', actual_user: 'e-2', unit_ref: 'pcs', quantity: '1' }

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
  clientMock.get.mockReset()
})
afterEach(() => {
  cleanup()
  clearAllToasts()
})

const PATH = '/admin/assets/cards'
const balanceCalls = () => clientMock.get.mock.calls.filter(([p]) => String(p).endsWith('/balances'))

describe('card holder section', () => {
  it('W3 reads the balance rows of the card and shows org unit, location, responsible and user as names', async () => {
    fakeServer(clientMock, DATA)
    clientMock.get.mockResolvedValue({ rows: [ROW], next_cursor: null })
    renderAssets(PATH, withRead)
    fireEvent.click(await screen.findByText('FA-1'))
    const section = await screen.findByTestId('asset-holder')
    await waitFor(() => expect(section).toHaveTextContent('Head office'))
    expect(section).toHaveTextContent('Main hall')
    expect(section).toHaveTextContent('Aigul Responsible')
    expect(section).toHaveTextContent('Bolat User')
    expect(balanceCalls()).toHaveLength(1)
    expect(balanceCalls()[0][0]).toBe('/api/v1/modules/assets/balances')
    expect(balanceCalls()[0][1]).toEqual({ asset: 'c-1' })
  })

  it('W4 no balance rows: says the card is not commissioned yet', async () => {
    fakeServer(clientMock, DATA)
    clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
    renderAssets(PATH, withRead)
    fireEvent.click(await screen.findByText('FA-1'))
    expect(await screen.findByTestId('asset-holder-none')).toHaveTextContent(en['assets.holder.none'])
  })

  it('W5 without AssetsRead the section is absent and no balances call is made', async () => {
    fakeServer(clientMock, DATA)
    clientMock.get.mockResolvedValue({ rows: [ROW], next_cursor: null })
    renderAssets(PATH, withAtom)
    fireEvent.click(await screen.findByText('FA-1'))
    await screen.findByRole('form')
    expect(screen.queryByTestId('asset-holder')).not.toBeInTheDocument()
    expect(balanceCalls()).toHaveLength(0)
  })

  it('W6 a failed read shows the register error with a retry', async () => {
    fakeServer(clientMock, DATA)
    clientMock.get.mockRejectedValue(problem(500, {}))
    renderAssets(PATH, withRead)
    fireEvent.click(await screen.findByText('FA-1'))
    expect(await screen.findByText(en['assets.reg.error.generic'])).toBeInTheDocument()
    expect(screen.getByRole('button', { name: en['assets.reg.retry'] })).toBeInTheDocument()
  })
})
