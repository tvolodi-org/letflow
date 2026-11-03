// @vitest-environment jsdom
/** T1–T6 — GH 3607 / REQ-671: the location tree screen. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { fakeServer, queryBodies, rec, renderLocations, writeCalls } from './locationsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-loc' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const node = (id: string, code: string, parent?: string, extra: Record<string, unknown> = {}) =>
  rec(id, 'location_node', { code, name: `Loc ${code}`, node_kind: 'zone', ...(parent ? { parent_id: parent } : {}), ...extra })
const DATA = {
  location_node: [
    node('n-b', 'B'),
    node('n-a4', 'A1a1', 'n-a3', { node_kind: 'bin' }),
    node('n-a', 'A'),
    node('n-a3', 'A1a', 'n-a2'),
    node('n-a2', 'A1', 'n-a', { address: 'A-1', location_type: 'pick', segment: '1' }),
  ],
}
const BASE = '/api/v1/modules/locations'

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => cleanup())

async function openPage() {
  fakeServer(clientMock, DATA)
  renderLocations('/admin/locations')
  await screen.findByTitle('A')
}

/** Select a node by its code: the tree row carries the code in a `title`. */
function selectRow(code: string) {
  fireEvent.click(screen.getByTitle(code))
}

describe('T1 tree', () => {
  it('renders four levels in parent order with aria-level 1..4, siblings by code', async () => {
    await openPage()
    const items = screen.getAllByRole('treeitem')
    expect(
      items.map((r) => [r.querySelector('.lf-tree__code')?.textContent, r.getAttribute('aria-level')]),
    ).toEqual([['A', '1'], ['A1', '2'], ['A1a', '3'], ['A1a1', '4'], ['B', '1']])
    const filters = queryBodies(clientMock, 'location_node')[0]['filters'] as { field: string }[]
    expect(filters.map((f) => f.field)).toEqual(['deleted', 'active'])
  })
})

describe('T2 T3 create', () => {
  it('compose mode sends address_pattern and segment and no address key', async () => {
    await openPage()
    fireEvent.click(screen.getByTestId('loc-create'))
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'N1' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'New' } })
    fireEvent.change(screen.getByLabelText('Kind'), { target: { value: 'shelf' } })
    fireEvent.change(screen.getByLabelText('Segment'), { target: { value: '7' } })
    fireEvent.click(screen.getByLabelText('Compose the address from the segments'))
    expect(screen.queryByLabelText('Address', { selector: 'input[type=text], input:not([type])' })).not.toBeInTheDocument()
    fireEvent.click(screen.getByTestId('loc-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const call = writeCalls(clientMock)[0]
    expect(call.path).toBe(`${BASE}/nodes`)
    expect(Object.keys(call.body).sort()).toEqual(['address_pattern', 'code', 'idempotency_key', 'name', 'node_kind', 'segment'])
    expect(call.body['address_pattern']).toBe('segments')
  })

  it('free mode sends address only when filled; a child sends parent_id', async () => {
    await openPage()
    fireEvent.click(screen.getByTestId('loc-create'))
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'R' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Root' } })
    fireEvent.change(screen.getByLabelText('Kind'), { target: { value: 'zone' } })
    fireEvent.click(screen.getByTestId('loc-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(Object.keys(writeCalls(clientMock)[0].body).sort()).toEqual(['code', 'idempotency_key', 'name', 'node_kind'])

    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    selectRow('B')
    fireEvent.click(screen.getByRole('button', { name: 'Add child' }))
    expect((screen.getByLabelText('Parent') as HTMLSelectElement).value).toBe('n-b')
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'B1' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Child' } })
    fireEvent.change(screen.getByLabelText('Kind'), { target: { value: 'bin' } })
    fireEvent.change(screen.getByLabelText('Address'), { target: { value: 'B-1' } })
    fireEvent.change(screen.getByLabelText('Location type'), { target: { value: 'ship' } })
    fireEvent.click(screen.getByTestId('loc-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    const body = writeCalls(clientMock)[1].body
    expect(body).toMatchObject({ parent_id: 'n-b', address: 'B-1', location_type: 'ship' })
    expect(body).not.toHaveProperty('address_pattern')
  })
})

describe('T4 move', () => {
  it('offers neither the node nor its descendants, offers Root, and sends parent_id', async () => {
    await openPage()
    selectRow('A1')
    fireEvent.click(screen.getByRole('button', { name: 'Move' }))
    const picker = screen.getByLabelText('New parent') as HTMLSelectElement
    expect([...picker.options].map((o) => o.value).sort()).toEqual(['', 'n-a', 'n-b'])
    fireEvent.change(picker, { target: { value: 'n-b' } })
    fireEvent.click(screen.getByTestId('loc-move-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].path).toBe(`${BASE}/nodes/n-a2/move`)
    expect(writeCalls(clientMock)[0].body).toMatchObject({ parent_id: 'n-b' })

    await waitFor(() => expect(screen.queryByTestId('loc-move')).not.toBeInTheDocument())
    fireEvent.click(screen.getByRole('button', { name: 'Move' }))
    fireEvent.change(screen.getByLabelText('New parent'), { target: { value: '' } })
    fireEvent.click(screen.getByTestId('loc-move-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    expect(writeCalls(clientMock)[1].body['parent_id']).toBeNull()
  })
})

describe('T5 edit and retire', () => {
  it('edit sends exactly the five fields; retire sends its route after confirm; the list reloads', async () => {
    await openPage()
    const before = queryBodies(clientMock, 'location_node').length
    selectRow('A1')
    expect((screen.getByLabelText('Code') as HTMLInputElement).readOnly).toBe(true)
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Renamed' } })
    fireEvent.change(screen.getByLabelText('Address'), { target: { value: '' } })
    fireEvent.click(screen.getByTestId('loc-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const edit = writeCalls(clientMock)[0]
    expect(edit.method).toBe('PATCH')
    expect(edit.path).toBe(`${BASE}/nodes/n-a2`)
    expect(Object.keys(edit.body).sort()).toEqual(['address', 'idempotency_key', 'location_type', 'name', 'node_kind', 'segment'])
    expect(edit.body).toMatchObject({ name: 'Renamed', address: null, location_type: 'pick', segment: '1' })
    await waitFor(() => expect(queryBodies(clientMock, 'location_node').length).toBeGreaterThan(before))

    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    selectRow('B')
    fireEvent.click(screen.getByRole('button', { name: 'Retire' }))
    fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    expect(writeCalls(clientMock)[1].path).toBe(`${BASE}/nodes/n-b/retire`)
    expect(Object.keys(writeCalls(clientMock)[1].body)).toEqual(['idempotency_key'])
  })
})

describe('T6 kinds', () => {
  it('offers the kinds used in the loaded nodes as datalist options', async () => {
    await openPage()
    fireEvent.click(screen.getByTestId('loc-create'))
    const list = document.getElementById('locations-kinds') as HTMLDataListElement
    expect([...list.options].map((o) => o.value)).toEqual(['bin', 'zone'])
    expect(screen.getByLabelText('Kind')).toHaveAttribute('list', 'locations-kinds')
  })
})
