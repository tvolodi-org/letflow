// @vitest-environment jsdom
/** L1, L2, W1, E1, E3 — GH 3608 / REQ-670, style S2: the positions screen (list left, record in the detail panel). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { fakeServer, problem, queryBodies, rec, renderOrg, withEmployeesAtom, writeCalls } from './orgTestKit'
import { orgMessages } from '../orgMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-org' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const unit = (id: string, code: string) => rec(id, 'org_unit', { code, name: `Unit ${code}`, legal_entity_id: 'le-1', site_id: 's-1' })
const pos = (id: string, code: string, unitId: string, active = true) =>
  rec(id, 'org_position', { code, name: `Pos ${code}`, org_unit_id: unitId, active })
const DATA = {
  org_unit: [unit('u-1', 'U1'), unit('u-2', 'U2')],
  org_position: [pos('p-1', 'P1', 'u-1'), pos('p-2', 'P2', 'u-2'), pos('p-3', 'P3', 'u-1', false)],
}
const PATH = '/admin/org/positions'
const pick = (name: string) => fireEvent.click(within(screen.getByRole('tree')).getByText(name))
const row = (code: string) => screen.getByText(`Pos ${code}`).closest('.lf-tree__row') as HTMLElement

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => cleanup())

describe('L1 L2 list and unit filter', () => {
  it('lists active positions with the unit name; the switch adds retired ones', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Pos P1')
    expect(queryBodies(clientMock, 'org_position').length).toBeGreaterThan(0)
    expect(within(row('P1')).getByText('Unit U1')).toBeInTheDocument()
    expect(within(row('P1')).getByText('P1')).toBeInTheDocument()
    expect(screen.queryByText('Pos P3')).not.toBeInTheDocument()
    fireEvent.click(screen.getByLabelText('Show retired'))
    const retired = await screen.findByText('Pos P3')
    expect(within(retired.closest('.lf-tree__row') as HTMLElement).getByText('Retired')).toBeInTheDocument()
    pick('Pos P3')
    expect(screen.queryByTestId('org-retire')).not.toBeInTheDocument()
    expect(screen.queryByTestId('org-save')).not.toBeInTheDocument()
  })

  it('filters by unit on the server', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Pos P2')
    fireEvent.change(screen.getByLabelText('Filter by unit'), { target: { value: 'u-2' } })
    await waitFor(() => expect(screen.queryByText('Pos P1')).not.toBeInTheDocument())
    expect(await screen.findByText('Pos P2')).toBeInTheDocument()
    const last = queryBodies(clientMock, 'org_position').at(-1) as { filters: unknown[] }
    expect(last.filters).toContainEqual({ field: 'org_unit_id', op: 'eq', value: 'u-2' })
  })
})

describe('W1 writes', () => {
  it('creates, edits the name and retires with exactly the route keys', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Pos P1')

    fireEvent.click(screen.getByTestId('org-create'))
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'P9' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Nine' } })
    fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u-2' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const create = writeCalls(clientMock)[0]
    expect(create.path).toBe('/api/v1/modules/org/positions')
    expect(Object.keys(create.body).sort()).toEqual(['code', 'idempotency_key', 'name', 'org_unit_id'])
    expect(create.body['org_unit_id']).toBe('u-2')

    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    pick('Pos P1')
    expect(screen.getByLabelText('Code')).toHaveAttribute('readonly')
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Renamed' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    const edit = writeCalls(clientMock)[1]
    expect([edit.method, edit.path]).toEqual(['PATCH', '/api/v1/modules/org/positions/p-1'])
    expect(Object.keys(edit.body).sort()).toEqual(['idempotency_key', 'name'])

    pick('Pos P2')
    fireEvent.click(screen.getByTestId('org-retire'))
    fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(3))
    expect(writeCalls(clientMock)[2].path).toBe('/api/v1/modules/org/positions/p-2/retire')
    expect(Object.keys(writeCalls(clientMock)[2].body)).toEqual(['idempotency_key'])
  })
})

describe('E1 E3 refusals', () => {
  it('shows position_in_use on retire', async () => {
    fakeServer(clientMock, DATA, () => {
      throw problem(422, { reason: 'position_in_use' })
    })
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Pos P1')
    pick('Pos P1')
    fireEvent.click(screen.getByTestId('org-retire'))
    fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    expect(await screen.findByRole('alert')).toHaveTextContent(orgMessages.en['org.error.position_in_use'])
  })

  it('names the fields of a duplicate code, 403 and 404', async () => {
    let err: unknown = problem(422, { reason: 'record_payload_invalid', fields: ['code'] })
    fakeServer(clientMock, DATA, () => {
      throw err
    })
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Pos P1')
    fireEvent.click(screen.getByTestId('org-create'))
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'P1' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Dup' } })
    fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u-1' } })
    fireEvent.click(screen.getByTestId('org-save'))
    expect(await screen.findByRole('alert')).toHaveTextContent('Fields: code')
    err = problem(403, {})
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(orgMessages.en['org.error.forbidden']))
    err = problem(404, {})
    const before = queryBodies(clientMock, 'org_position').length
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(orgMessages.en['org.error.notFound']))
    await waitFor(() => expect(queryBodies(clientMock, 'org_position').length).toBeGreaterThan(before))
  })
})
