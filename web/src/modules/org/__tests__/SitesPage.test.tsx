// @vitest-environment jsdom
/** L2, W2 — GH 3609 / REQ-669: the sites screen. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { fakeServer, queryBodies, rec, renderOrg, writeCalls } from './orgTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-org' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const COMPANY = rec('le-1', 'org_legal_entity', { code: 'LE1', name: 'Alpha LLP', bin: '123456789012' })
const OLD_COMPANY = { ...rec('le-2', 'org_legal_entity', { code: 'LE2', name: 'Old LLP' }), field_values: { code: 'LE2', name: 'Old LLP', active: false } }
const SITE = rec('s-1', 'org_site', { code: 'S1', name: 'Main site', legal_entity_id: 'le-1' })
const RETIRED_SITE = { ...rec('s-2', 'org_site', {}), field_values: { code: 'S2', name: 'Closed site', legal_entity_id: 'le-2', active: false } }

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => cleanup())

describe('L2 list', () => {
  it('shows active sites with the company name and the retired ones after the switch', async () => {
    fakeServer(clientMock, { org_site: [SITE, RETIRED_SITE], org_legal_entity: [COMPANY, OLD_COMPANY] })
    renderOrg('/admin/org/sites')
    const row = await screen.findByTestId('org-row-S1')
    expect(within(row).getByText('Alpha LLP')).toBeInTheDocument()
    expect(screen.queryByText('Closed site')).not.toBeInTheDocument()
    expect(queryBodies(clientMock, 'org_site')[0]['filters']).toEqual(
      expect.arrayContaining([{ field: 'active', op: 'eq', value: true }]),
    )
    fireEvent.click(screen.getByRole('checkbox', { name: 'Show retired' }))
    const retired = await screen.findByTestId('org-row-S2')
    expect(within(retired).getByText('Old LLP')).toBeInTheDocument()
  })
})

describe('W2 writes', () => {
  it('create, edit and retire send the accepted keys; the picker offers active companies only', async () => {
    fakeServer(clientMock, { org_site: [SITE], org_legal_entity: [COMPANY, OLD_COMPANY] })
    renderOrg('/admin/org/sites')
    await screen.findByTestId('org-row-S1')

    fireEvent.click(screen.getByTestId('org-create'))
    const picker = screen.getByLabelText('Legal company') as HTMLSelectElement
    expect([...picker.options].map((o) => o.textContent)).toEqual(['Choose...', 'Alpha LLP'])
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'S9' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'North' } })
    fireEvent.change(picker, { target: { value: 'le-1' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    let call = writeCalls(clientMock)[0]
    expect(call.path).toBe('/api/v1/modules/org/sites')
    expect(Object.keys(call.body).sort()).toEqual(['code', 'idempotency_key', 'legal_entity_id', 'name'])
    expect(call.body['legal_entity_id']).toBe('le-1')

    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    fireEvent.click(screen.getByRole('button', { name: 'Edit' }))
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Main 2' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    call = writeCalls(clientMock)[1]
    expect(call.method).toBe('PATCH')
    expect(call.path).toBe('/api/v1/modules/org/sites/s-1')
    expect(Object.keys(call.body).sort()).toEqual(['idempotency_key', 'legal_entity_id', 'name'])

    fireEvent.click(screen.getByRole('button', { name: 'Retire' }))
    fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(3))
    expect(writeCalls(clientMock)[2].path).toBe('/api/v1/modules/org/sites/s-1/retire')
  })
})
