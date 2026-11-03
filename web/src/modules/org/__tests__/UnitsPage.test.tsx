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

const pick = (name: string) => fireEvent.click(within(screen.getByRole('tree')).getByText(name))

describe('L3 tree', () => {
  it('renders parents before children with levels 1, 2, 3; the panel shows the company, site and path', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/units')
    await screen.findByText('Unit A')
    const items = screen.getAllByRole('treeitem')
    expect(items.map((r) => [within(r).getAllByText(/^Unit /)[0].textContent, r.getAttribute('aria-level')])).toEqual([
      ['Unit A', '1'], ['Unit A1', '2'], ['Unit A1a', '3'], ['Unit B', '1'],
    ])
    pick('Unit A1a')
    const form = screen.getByRole('form')
    expect((within(form).getByLabelText('Legal company') as HTMLSelectElement).selectedOptions[0].textContent).toBe('Alpha LLP')
    expect((within(form).getByLabelText('Site') as HTMLSelectElement).selectedOptions[0].textContent).toBe('Main site')
    expect(screen.getByTestId('detail-header')).toHaveTextContent('Unit A / Unit A1')
    // the code is set once
    expect(within(form).getByLabelText('Code')).toHaveAttribute('readonly')
  })

  it('collapses a branch with the keyboard (Left) and shows retired units only after the switch', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/units')
    await screen.findByText('Unit A')
    const row = screen.getByText('Unit A').closest('.lf-tree__row') as HTMLElement
    row.focus()
    fireEvent.keyDown(row, { key: 'ArrowLeft' })
    expect(screen.queryByText('Unit A1')).not.toBeInTheDocument()
    fireEvent.keyDown(row, { key: 'ArrowRight' })
    expect(screen.getByText('Unit A1')).toBeInTheDocument()
  })
})

describe('W3 writes', () => {
  it('creates a root without parent and a child with parent', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/units')
    await screen.findByText('Unit A')

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
    pick('Unit B')
    fireEvent.click(screen.getByRole('button', { name: 'Add child' }))
    expect((screen.getByLabelText('Parent unit') as HTMLSelectElement).value).toBe('u-b2')
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'B1' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Child' } })
    fireEvent.change(screen.getByLabelText('Legal company'), { target: { value: 'le-1' } })
    fireEvent.change(screen.getByLabelText('Site'), { target: { value: 's-1' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    expect(writeCalls(clientMock)[1].body['parent']).toBe('u-b2')
  })

  it('edits in the panel, moves (also to the root) and retires', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/units')
    await screen.findByText('Unit A')

    pick('Unit B')
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'B renamed' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const edit = writeCalls(clientMock)[0]
    expect(edit.method).toBe('PATCH')
    expect(edit.path).toBe('/api/v1/modules/org/units/u-b2')
    expect(Object.keys(edit.body).sort()).toEqual(['idempotency_key', 'legal_entity_id', 'name', 'site_id'])

    pick('Unit A')
    fireEvent.click(screen.getByRole('button', { name: 'Move' }))
    const picker = screen.getByLabelText('New parent') as HTMLSelectElement
    // the unit and its descendants are not offered
    expect([...picker.options].map((o) => o.value).sort()).toEqual(['', 'u-b2'])
    fireEvent.change(picker, { target: { value: 'u-b2' } })
    fireEvent.click(screen.getByTestId('org-move-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    expect(writeCalls(clientMock)[1].path).toBe('/api/v1/modules/org/units/u-a/move')
    expect(writeCalls(clientMock)[1].body).toMatchObject({ parent_id: 'u-b2' })
    await waitFor(() => expect(screen.queryByTestId('org-move-confirm')).not.toBeInTheDocument())

    pick('Unit A1')
    fireEvent.click(screen.getByRole('button', { name: 'Move' }))
    fireEvent.change(screen.getByLabelText('New parent'), { target: { value: '' } })
    fireEvent.click(screen.getByTestId('org-move-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(3))
    expect(writeCalls(clientMock)[2].body['parent_id']).toBeNull()
    await waitFor(() => expect(screen.queryByTestId('org-move-confirm')).not.toBeInTheDocument())

    pick('Unit B')
    fireEvent.click(screen.getByRole('button', { name: 'Retire' }))
    fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(4))
    expect(writeCalls(clientMock)[3].path).toBe('/api/v1/modules/org/units/u-b2/retire')
    expect(Object.keys(writeCalls(clientMock)[3].body)).toEqual(['idempotency_key'])
  })
})

describe('T-1181 child starts with the parent company', () => {
  const two = {
    ...DATA,
    org_unit: [
      rec('u-p', 'org_unit', { code: 'P', name: 'Unit P', legal_entity_id: 'le-2', site_id: 's-2' }),
      rec('u-q', 'org_unit', { code: 'Q', name: 'Unit Q', legal_entity_id: 'le-1', site_id: 's-3' }),
    ],
    org_site: [
      rec('s-1', 'org_site', { code: 'S1', name: 'Main site', legal_entity_id: 'le-1' }),
      rec('s-2', 'org_site', { code: 'S2', name: 'Second site', legal_entity_id: 'le-2' }),
      rec('s-3', 'org_site', { code: 'S3', name: 'Third site', legal_entity_id: 'le-1' }),
    ],
    org_legal_entity: [
      rec('le-1', 'org_legal_entity', { code: 'LE1', name: 'Alpha LLP' }),
      rec('le-2', 'org_legal_entity', { code: 'LE2', name: 'Beta LLP' }),
    ],
  }
  const company = () => screen.getByLabelText('Legal company') as HTMLSelectElement
  const site = () => screen.getByLabelText('Site') as HTMLSelectElement

  it('pre-fills the parent company for a child, stays editable, saves the chosen value', async () => {
    fakeServer(clientMock, two)
    renderOrg('/admin/org/units')
    await screen.findByText('Unit P')
    pick('Unit P')
    fireEvent.click(screen.getByRole('button', { name: 'Add child' }))
    expect(company().value).toBe('le-2')
    expect(company()).toBeEnabled()
    expect(site().value).toBe('s-2')
    expect(site()).toBeEnabled()
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'P1' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Kid' } })
    fireEvent.change(screen.getByLabelText('Site'), { target: { value: 's-1' } })
    fireEvent.change(company(), { target: { value: 'le-1' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].body).toMatchObject({ parent: 'u-p', legal_entity_id: 'le-1', site_id: 's-1' })
  })

  it('saves the pre-filled company unchanged', async () => {
    fakeServer(clientMock, two)
    renderOrg('/admin/org/units')
    await screen.findByText('Unit P')
    pick('Unit P')
    fireEvent.click(screen.getByRole('button', { name: 'Add child' }))
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'P2' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Kid2' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].body['legal_entity_id']).toBe('le-2')
    expect(writeCalls(clientMock)[0].body['site_id']).toBe('s-2')
  })

  it('starts empty for a root, and an existing unit shows its own company', async () => {
    fakeServer(clientMock, two)
    renderOrg('/admin/org/units')
    await screen.findByText('Unit P')
    fireEvent.click(screen.getByTestId('org-create'))
    expect(company().value).toBe('')
    expect(site().value).toBe('')
    pick('Unit Q')
    expect(company().value).toBe('le-1')
    expect(site().value).toBe('s-3')
    pick('Unit P')
    expect(company().value).toBe('le-2')
    expect(site().value).toBe('s-2')
  })
})
