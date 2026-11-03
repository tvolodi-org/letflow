// @vitest-environment jsdom
/** L3, W3 — GH 3609 / REQ-669: the org unit tree screen. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { fakeServer, rec, renderOrg, writeCalls } from './orgTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-org' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const unit = (id: string, code: string, parent?: string) =>
  rec(id, 'org_unit', { code, name: `Unit ${code}`, legal_entity_id: 'le-1', site_id: 's-1', ...(parent ? { parent } : {}) })
const DATA = {
  org_unit: [unit('u-b2', 'B'), unit('u-a3', 'A1a', 'u-a2'), unit('u-a', 'A'), unit('u-a2', 'A1', 'u-a')],
  org_legal_entity: [rec('le-1', 'org_legal_entity', { code: 'LE1', name: 'Alpha LLP' })],
  org_site: [rec('s-1', 'org_site', { code: 'S1', name: 'Main site', legal_entity_id: 'le-1' })],
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => cleanup())

describe('L3 tree', () => {
  it('renders parents before children with aria-level 1, 2, 3 and the company and site names', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/units')
    await screen.findByTestId('org-row-A')
    const rows = screen.getAllByRole('row').filter((r) => r.hasAttribute('aria-level'))
    expect(rows.map((r) => [r.getAttribute('data-testid'), r.getAttribute('aria-level')])).toEqual([
      ['org-row-A', '1'], ['org-row-A1', '2'], ['org-row-A1a', '3'], ['org-row-B', '1'],
    ])
    expect(within(rows[0]).getByText('Alpha LLP')).toBeInTheDocument()
    expect(within(rows[0]).getByText('Main site')).toBeInTheDocument()
  })
})

describe('W3 writes', () => {
  it('creates a root without parent and a child with parent', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/units')
    await screen.findByTestId('org-row-A')

    fireEvent.click(screen.getByTestId('org-create'))
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'R' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Root' } })
    fireEvent.change(screen.getByLabelText('Legal company'), { target: { value: 'le-1' } })
    fireEvent.change(screen.getByLabelText('Site'), { target: { value: 's-1' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const root = writeCalls(clientMock)[0]
    expect(root.path).toBe('/api/v1/modules/org/units')
    expect(Object.keys(root.body).sort()).toEqual(['code', 'idempotency_key', 'legal_entity_id', 'name', 'site_id'])

    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    fireEvent.click(within(screen.getByTestId('org-row-B')).getByRole('button', { name: 'Add child' }))
    expect((screen.getByLabelText('Parent unit') as HTMLSelectElement).value).toBe('u-b2')
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'B1' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Child' } })
    fireEvent.change(screen.getByLabelText('Legal company'), { target: { value: 'le-1' } })
    fireEvent.change(screen.getByLabelText('Site'), { target: { value: 's-1' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    expect(writeCalls(clientMock)[1].body['parent']).toBe('u-b2')
  })

  it('edits, moves (also to the root) and retires', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/units')
    await screen.findByTestId('org-row-A')

    fireEvent.click(within(screen.getByTestId('org-row-B')).getByRole('button', { name: 'Edit' }))
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'B renamed' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const edit = writeCalls(clientMock)[0]
    expect(edit.method).toBe('PATCH')
    expect(edit.path).toBe('/api/v1/modules/org/units/u-b2')
    expect(Object.keys(edit.body).sort()).toEqual(['idempotency_key', 'legal_entity_id', 'name', 'site_id'])

    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    fireEvent.click(within(screen.getByTestId('org-row-A')).getByRole('button', { name: 'Move' }))
    const picker = screen.getByLabelText('New parent') as HTMLSelectElement
    // the unit and its descendants are not offered
    expect([...picker.options].map((o) => o.value).sort()).toEqual(['', 'u-b2'])
    fireEvent.change(picker, { target: { value: 'u-b2' } })
    fireEvent.click(screen.getByTestId('org-move-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    expect(writeCalls(clientMock)[1].path).toBe('/api/v1/modules/org/units/u-a/move')
    expect(writeCalls(clientMock)[1].body).toMatchObject({ parent_id: 'u-b2' })

    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    fireEvent.click(within(screen.getByTestId('org-row-A1')).getByRole('button', { name: 'Move' }))
    fireEvent.change(screen.getByLabelText('New parent'), { target: { value: '' } })
    fireEvent.click(screen.getByTestId('org-move-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(3))
    expect(writeCalls(clientMock)[2].body['parent_id']).toBeNull()

    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    fireEvent.click(within(screen.getByTestId('org-row-B')).getByRole('button', { name: 'Retire' }))
    fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(4))
    expect(writeCalls(clientMock)[3].path).toBe('/api/v1/modules/org/units/u-b2/retire')
    expect(Object.keys(writeCalls(clientMock)[3].body)).toEqual(['idempotency_key'])
  })
})
