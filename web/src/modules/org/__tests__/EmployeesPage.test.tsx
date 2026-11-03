// @vitest-environment jsdom
/** L1, L2, W2-W6, E1-E3 — GH 3608 / REQ-670, style S2: the employees screen (record in the detail panel, transfer in a dialog). */
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
const emp = (id: string, code: string, unitId: string, extra: Record<string, unknown> = {}) =>
  rec(id, 'org_employee', { code, full_name: `Emp ${code}`, org_unit_id: unitId, ...extra })
const DATA = {
  org_unit: [unit('u-1', 'U1'), unit('u-2', 'U2')],
  org_position: [pos('p-1', 'P1', 'u-1'), pos('p-2', 'P2', 'u-2'), pos('p-3', 'P3', 'u-1', false)],
  org_employee: [
    emp('e-1', 'E1', 'u-1', { position_id: 'p-1', user_id: 'usr-1' }),
    emp('e-2', 'E2', 'u-2'),
    emp('e-3', 'E3', 'u-1', { active: false }),
  ],
}
const USERS = [
  { id: 'usr-1', display_name: 'Ann', email: 'ann@x.kz' },
  { id: 'usr-2', display_name: 'Bob', email: 'bob@x.kz' },
]
const PATH = '/admin/org/employees'
const pick = (name: string) => fireEvent.click(within(screen.getByRole('tree')).getByText(name))
const dlg = () => within(screen.getByTestId('org-transfer'))
const row = (code: string) => screen.getByText(`Emp ${code}`).closest('.lf-tree__row') as HTMLElement

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
  clientMock.get.mockReset()
  clientMock.get.mockResolvedValue({ items: USERS, next_cursor: null })
})
afterEach(() => cleanup())

describe('L1 L2 list and unit filter', () => {
  it('lists employees with unit and personnel number; the panel shows position and user link', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Emp E1')
    expect(queryBodies(clientMock, 'org_employee').length).toBeGreaterThan(0)
    expect(within(row('E1')).getByText('Unit U1')).toBeInTheDocument()
    expect(within(row('E1')).getByText('E1')).toBeInTheDocument()
    expect(screen.queryByText('Emp E3')).not.toBeInTheDocument()
    expect(clientMock.get).not.toHaveBeenCalled()
    pick('Emp E1')
    expect(screen.getByTestId('detail-header')).toHaveTextContent('Unit U1 / Pos P1')
    expect(screen.getByLabelText('Position')).toHaveValue('Pos P1')
  })

  it('filters by unit on the server', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Emp E2')
    fireEvent.change(screen.getByLabelText('Filter by unit'), { target: { value: 'u-2' } })
    await waitFor(() => expect(screen.queryByText('Emp E1')).not.toBeInTheDocument())
    expect(await screen.findByText('Emp E2')).toBeInTheDocument()
    const last = queryBodies(clientMock, 'org_employee').at(-1) as { filters: unknown[] }
    expect(last.filters).toContainEqual({ field: 'org_unit_id', op: 'eq', value: 'u-2' })
  })
})

describe('W2 W3 W6 create', () => {
  it('offers only active positions of the chosen unit and clears the position on a unit change', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Emp E1')
    fireEvent.click(screen.getByTestId('org-create'))
    const position = () => screen.getByLabelText('Position') as HTMLSelectElement
    expect([...position().options].map((o) => o.value)).toEqual([''])
    fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u-1' } })
    expect([...position().options].map((o) => o.value)).toEqual(['', 'p-1'])
    fireEvent.change(position(), { target: { value: 'p-1' } })
    fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u-2' } })
    expect(position().value).toBe('')
    expect([...position().options].map((o) => o.value)).toEqual(['', 'p-2'])
  })

  it('sends only the keys it has: all of them, or none of position and user', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Emp E1')
    fireEvent.click(screen.getByTestId('org-create'))
    fireEvent.change(screen.getByLabelText('Personnel number'), { target: { value: 'E9' } })
    fireEvent.change(screen.getByLabelText('Full name'), { target: { value: 'Nine' } })
    fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u-1' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const bare = writeCalls(clientMock)[0]
    expect(bare.path).toBe('/api/v1/modules/org/employees')
    expect(Object.keys(bare.body).sort()).toEqual(['code', 'full_name', 'idempotency_key', 'org_unit_id'])

    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    fireEvent.click(screen.getByTestId('org-create'))
    fireEvent.change(screen.getByLabelText('Personnel number'), { target: { value: 'E10' } })
    fireEvent.change(screen.getByLabelText('Full name'), { target: { value: 'Ten' } })
    fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u-1' } })
    fireEvent.change(screen.getByLabelText('Position'), { target: { value: 'p-1' } })
    fireEvent.change(screen.getByLabelText('Search users'), { target: { value: 'bo' } })
    await waitFor(() =>
      expect(clientMock.get).toHaveBeenCalledWith('/api/v1/identity/users', expect.objectContaining({ search: 'bo' })),
    )
    await waitFor(() => expect(within(screen.getByLabelText('User account')).getByText('Bob — bob@x.kz')).toBeInTheDocument())
    fireEvent.change(screen.getByLabelText('User account'), { target: { value: 'usr-2' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    const full = writeCalls(clientMock)[1]
    expect(Object.keys(full.body).sort()).toEqual(['code', 'full_name', 'idempotency_key', 'org_unit_id', 'position_id', 'user_id'])
    expect(full.body['user_id']).toBe('usr-2')
  })

  it('degrades the user picker when the users call is refused', async () => {
    clientMock.get.mockRejectedValue(problem(403, {}))
    fakeServer(clientMock, DATA)
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Emp E1')
    expect(screen.queryByText(orgMessages.en['org.employees.usersUnavailable'])).not.toBeInTheDocument()
    fireEvent.click(screen.getByTestId('org-create'))
    expect(await screen.findByText(orgMessages.en['org.employees.usersUnavailable'])).toBeInTheDocument()
    expect(screen.getByText('Emp E1')).toBeInTheDocument()
  })
})

describe('W4 W5 edit transfer retire', () => {
  it('edits the name, keeps the link, and removes it with null', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Emp E1')
    pick('Emp E1')
    expect(screen.getByLabelText('Personnel number')).toHaveAttribute('readonly')
    fireEvent.change(screen.getByLabelText('Full name'), { target: { value: 'Ann Smith' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const edit = writeCalls(clientMock)[0]
    expect([edit.method, edit.path]).toEqual(['PATCH', '/api/v1/modules/org/employees/e-1'])
    expect(edit.body).toMatchObject({ full_name: 'Ann Smith', user_id: 'usr-1' })
    expect(Object.keys(edit.body).sort()).toEqual(['full_name', 'idempotency_key', 'user_id'])

    pick('Emp E1')
    fireEvent.click(screen.getByTestId('org-remove-user'))
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    expect(writeCalls(clientMock)[1].body['user_id']).toBeNull()
  })

  it('transfers with a position, then without one (null), and retires', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Emp E1')
    pick('Emp E2')
    fireEvent.click(screen.getByTestId('org-transfer-open'))
    fireEvent.change(dlg().getByLabelText('Org unit'), { target: { value: 'u-1' } })
    expect([...(dlg().getByLabelText('Position') as HTMLSelectElement).options].map((o) => o.value)).toEqual(['', 'p-1'])
    fireEvent.change(dlg().getByLabelText('Position'), { target: { value: 'p-1' } })
    fireEvent.click(screen.getByTestId('org-transfer-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const first = writeCalls(clientMock)[0]
    expect(first.path).toBe('/api/v1/modules/org/employees/e-2/transfer')
    expect(first.body).toMatchObject({ org_unit_id: 'u-1', position_id: 'p-1' })
    expect(Object.keys(first.body).sort()).toEqual(['idempotency_key', 'org_unit_id', 'position_id'])

    await waitFor(() => expect(screen.queryByTestId('org-transfer')).not.toBeInTheDocument())
    pick('Emp E1')
    fireEvent.click(screen.getByTestId('org-transfer-open'))
    fireEvent.change(dlg().getByLabelText('Position'), { target: { value: '' } })
    fireEvent.click(screen.getByTestId('org-transfer-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    expect(writeCalls(clientMock)[1].body['position_id']).toBeNull()

    await waitFor(() => expect(screen.queryByTestId('org-transfer')).not.toBeInTheDocument())
    pick('Emp E2')
    fireEvent.click(screen.getByTestId('org-retire'))
    fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(3))
    expect(writeCalls(clientMock)[2].path).toBe('/api/v1/modules/org/employees/e-2/retire')
    expect(Object.keys(writeCalls(clientMock)[2].body)).toEqual(['idempotency_key'])
  })
})

describe('E1 E2 E3 refusals', () => {
  for (const reason of ['position_not_in_unit', 'position_inactive', 'unit_inactive', 'employee_inactive', 'user_not_found']) {
    it(`shows ${reason} on transfer`, async () => {
      fakeServer(clientMock, DATA, () => {
        throw problem(422, { reason })
      })
      renderOrg(PATH, withEmployeesAtom)
      await screen.findByText('Emp E1')
      pick('Emp E2')
    fireEvent.click(screen.getByTestId('org-transfer-open'))
      fireEvent.change(dlg().getByLabelText('Org unit'), { target: { value: 'u-1' } })
      fireEvent.click(screen.getByTestId('org-transfer-confirm'))
      expect(await screen.findByRole('alert')).toHaveTextContent(orgMessages.en[`org.error.${reason}`])
    })
  }

  it('names the fields of a duplicate personnel number or user', async () => {
    fakeServer(clientMock, DATA, () => {
      throw problem(422, { reason: 'record_payload_invalid', fields: ['code', 'user_id'] })
    })
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Emp E1')
    pick('Emp E1')
    fireEvent.click(screen.getByTestId('org-save'))
    expect(await screen.findByRole('alert')).toHaveTextContent('Fields: code, user_id')
  })

  it('a 404 on a save with a user link names the user; without one it is the plain text; lists reload', async () => {
    fakeServer(clientMock, DATA, () => {
      throw problem(404, {})
    })
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Emp E1')
    const before = queryBodies(clientMock, 'org_employee').length
    pick('Emp E1')
    fireEvent.click(screen.getByTestId('org-save'))
    expect(await screen.findByRole('alert')).toHaveTextContent(orgMessages.en['org.error.user_not_found'])
    await waitFor(() => expect(queryBodies(clientMock, 'org_employee').length).toBeGreaterThan(before))

    pick('Emp E2')
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(orgMessages.en['org.error.notFound']))
  })

  it('shows the forbidden text on a 403', async () => {
    fakeServer(clientMock, DATA, () => {
      throw problem(403, {})
    })
    renderOrg(PATH, withEmployeesAtom)
    await screen.findByText('Emp E1')
    pick('Emp E2')
    fireEvent.click(screen.getByTestId('org-retire'))
    fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    expect(await screen.findByRole('alert')).toHaveTextContent(orgMessages.en['org.error.forbidden'])
  })
})
