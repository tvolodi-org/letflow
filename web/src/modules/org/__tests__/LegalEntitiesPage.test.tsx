// @vitest-environment jsdom
/** L1, W1 — GH 3609 / REQ-669: the legal companies screen (list, switch, create, edit, retire). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { fakeServer, queryBodies, rec, renderOrg, writeCalls } from './orgTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-org' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const ACTIVE = rec('le-1', 'org_legal_entity', { code: 'LE1', name: 'Alpha LLP', bin: '123456789012' })
const RETIRED = { ...rec('le-2', 'org_legal_entity', { code: 'LE2', name: 'Old LLP', bin: '210987654321' }), field_values: { code: 'LE2', name: 'Old LLP', bin: '210987654321', active: false } }

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => cleanup())

describe('L1 list', () => {
  it('queries active, not deleted rows first and the retired ones after the switch', async () => {
    fakeServer(clientMock, { org_legal_entity: [ACTIVE, RETIRED] })
    renderOrg('/admin/org/legal-entities')
    expect(await screen.findByText('Alpha LLP')).toBeInTheDocument()
    expect(screen.queryByText('Old LLP')).not.toBeInTheDocument()
    const first = queryBodies(clientMock, 'org_legal_entity')[0]
    expect(first['filters']).toEqual(
      expect.arrayContaining([
        { field: 'active', op: 'eq', value: true },
        { field: 'deleted', op: 'eq', value: false },
      ]),
    )
    fireEvent.click(screen.getByRole('checkbox', { name: 'Show retired' }))
    expect(await screen.findByText('Old LLP')).toBeInTheDocument()
    const last = queryBodies(clientMock, 'org_legal_entity').at(-1) as { filters: { field: string }[] }
    expect(last.filters.some((f) => f.field === 'active')).toBe(false)
  })
})

describe('W1 writes', () => {
  it('create, edit and retire send exactly the accepted keys and reload the list', async () => {
    fakeServer(clientMock, { org_legal_entity: [ACTIVE] })
    renderOrg('/admin/org/legal-entities')
    await screen.findByText('Alpha LLP')
    const listCalls = () => queryBodies(clientMock, 'org_legal_entity').length

    fireEvent.click(screen.getByTestId('org-create'))
    fireEvent.change(screen.getByLabelText('Code'), { target: { value: 'LE9' } })
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'New LLP' } })
    fireEvent.change(screen.getByLabelText('BIN'), { target: { value: '111111111111' } })
    const before = listCalls()
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    let call = writeCalls(clientMock)[0]
    expect(call.method).toBe('POST')
    expect(call.path).toBe('/api/v1/modules/org/legal-entities')
    expect(Object.keys(call.body).sort()).toEqual(['bin', 'code', 'idempotency_key', 'name'])
    expect(call.body['idempotency_key']).toBeTruthy()
    await waitFor(() => expect(listCalls()).toBeGreaterThan(before))
    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())

    fireEvent.click(screen.getByRole('button', { name: 'Edit' }))
    expect(screen.getByLabelText('Code')).toHaveAttribute('readonly')
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Alpha 2' } })
    fireEvent.click(screen.getByTestId('org-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    call = writeCalls(clientMock)[1]
    expect(call.method).toBe('PATCH')
    expect(call.path).toBe('/api/v1/modules/org/legal-entities/le-1')
    expect(Object.keys(call.body).sort()).toEqual(['bin', 'idempotency_key', 'name'])

    fireEvent.click(screen.getByRole('button', { name: 'Retire' }))
    fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(3))
    call = writeCalls(clientMock)[2]
    expect(call.path).toBe('/api/v1/modules/org/legal-entities/le-1/retire')
    expect(Object.keys(call.body)).toEqual(['idempotency_key'])
    for (const c of writeCalls(clientMock)) expect(Object.keys(c.body).some((k) => k.includes('tenant'))).toBe(false)
  })

  it('blocks an 11-digit BIN on the client without a call', async () => {
    fakeServer(clientMock, { org_legal_entity: [] })
    renderOrg('/admin/org/legal-entities')
    fireEvent.click(await screen.findByTestId('org-create'))
    fireEvent.change(screen.getByLabelText('BIN'), { target: { value: '12345678901' } })
    fireEvent.click(screen.getByTestId('org-save'))
    expect(await screen.findByText('The BIN must be 12 digits.')).toBeInTheDocument()
    expect(writeCalls(clientMock)).toHaveLength(0)
  })
})
