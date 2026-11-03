// @vitest-environment jsdom
/** L1–L3 — GH 3607 / REQ-671: the links screen. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { fakeServer, queryBodies, rec, renderLocations, writeCalls } from './locationsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-loc' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const DATA = {
  org_unit: [
    rec('u-1', 'org_unit', { code: 'U1', name: 'Unit one' }),
    rec('u-2', 'org_unit', { code: 'U2', name: 'Unit two', parent: 'u-1' }),
  ],
  location_node: [
    rec('l-1', 'location_node', { code: 'L1', name: 'Loc one', address: 'A-1' }),
    rec('l-2', 'location_node', { code: 'L2', name: 'Loc two' }),
    rec('l-3', 'location_node', { code: 'L3', name: 'Loc three', active: false }),
  ],
  location_org_unit_link: [
    rec('k-1', 'location_org_unit_link', { org_unit_id: 'u-1', location_id: 'l-1' }),
    rec('k-2', 'location_org_unit_link', { org_unit_id: 'u-2', location_id: 'l-1' }),
  ],
}
const BASE = '/api/v1/modules/locations'

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => cleanup())

/** The table row that holds a text (DataTable rows carry no test id). */
function rowWith(text: string): HTMLElement {
  const row = screen.getAllByText(text).map((e) => e.closest('tr')).find(Boolean)
  if (!row) throw new Error(`no row with ${text}`)
  return row
}

async function openPage() {
  fakeServer(clientMock, DATA)
  renderLocations('/admin/locations/links')
  await screen.findByLabelText('Org unit')
}

describe('L1 by unit', () => {
  it('lists the locations of the chosen unit, querying by org_unit_id', async () => {
    await openPage()
    expect(queryBodies(clientMock, 'location_org_unit_link')).toHaveLength(0)
    fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u-1' } })
    await screen.findAllByText('Loc one')
    const row = rowWith('Loc one')
    expect(within(row).getByText('Loc one')).toBeInTheDocument()
    expect(within(row).getByText('A-1')).toBeInTheDocument()
    const filters = queryBodies(clientMock, 'location_org_unit_link')[0]['filters'] as { field: string; value: unknown }[]
    expect(filters).toContainEqual({ field: 'org_unit_id', op: 'eq', value: 'u-1' })
  })
})

describe('L2 by location', () => {
  it('lists the units of the chosen location, querying by location_id', async () => {
    await openPage()
    fireEvent.click(screen.getByRole('tab', { name: 'By location' }))
    fireEvent.change(screen.getByLabelText('Location'), { target: { value: 'l-1' } })
    await screen.findByText('Unit one')
    expect(screen.getByText('Unit two')).toBeInTheDocument()
    const filters = queryBodies(clientMock, 'location_org_unit_link')[0]['filters'] as { field: string; value: unknown }[]
    expect(filters).toContainEqual({ field: 'location_id', op: 'eq', value: 'l-1' })
  })
})

describe('L3 link and unlink', () => {
  it('posts both keys and the idempotency key and nothing else; offers only active, unlinked ends', async () => {
    await openPage()
    fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u-1' } })
    await screen.findAllByText('Loc one')
    const add = screen.getByLabelText('Location to link') as HTMLSelectElement
    // l-1 is linked already and l-3 is retired
    expect([...add.options].map((o) => o.value)).toEqual(['', 'l-2'])
    fireEvent.change(add, { target: { value: 'l-2' } })
    fireEvent.click(screen.getByTestId('link-add'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].path).toBe(`${BASE}/links`)
    expect(Object.keys(writeCalls(clientMock)[0].body).sort()).toEqual(['idempotency_key', 'location_id', 'org_unit_id'])
    expect(writeCalls(clientMock)[0].body).toMatchObject({ org_unit_id: 'u-1', location_id: 'l-2' })

    fireEvent.click(within(rowWith('Loc one')).getByRole('button', { name: 'Unlink' }))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    expect(writeCalls(clientMock)[1].path).toBe(`${BASE}/links/retire`)
    expect(Object.keys(writeCalls(clientMock)[1].body).sort()).toEqual(['idempotency_key', 'location_id', 'org_unit_id'])
    expect(writeCalls(clientMock)[1].body).toMatchObject({ org_unit_id: 'u-1', location_id: 'l-1' })
  })
})
