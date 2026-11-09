// @vitest-environment jsdom
/** S1..S4 — T-1528: the signed-in user's linked employee is proposed as the responsible (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import type { AccessState } from '@/auth/access/types'
import { DOCS, LIST, MASTERS, fakeMasters, rec, renderStock } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const NEW = `${LIST}/new`
const asUser = (userId: string): AccessState => ({
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['StockRead', 'StockPost'], user_id: userId },
})
const DATA = {
  ...MASTERS,
  org_employee: [rec('e1', { full_name: 'Aigul B.' }), rec('e2', { full_name: 'Marat K.', user_id: 'user-9' })],
}
const created = () => clientMock.post.mock.calls.filter(([p]) => p === DOCS)

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock, DATA)
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
})
afterEach(() => cleanup())

const form = () => within(screen.getByTestId('document-form'))
const resp = (scope: { getByLabelText: (l: string) => HTMLElement } = form()) => scope.getByLabelText('Responsible') as HTMLSelectElement
async function ready() {
  await form().findAllByRole('option', { name: 'Marat K.' })
}

describe('T-1528 stock form proposes the linked employee', () => {
  it('S1 receipt: preselected, can be changed', async () => {
    renderStock(`${NEW}?kind=receipt`, asUser('user-9'))
    await ready()
    await waitFor(() => expect(resp().value).toBe('e2'))
    fireEvent.change(resp(), { target: { value: 'e1' } })
    expect(resp().value).toBe('e1')
  })
  it('S2 transfer: only From is proposed, To stays empty and required', async () => {
    renderStock(`${NEW}?kind=transfer`, asUser('user-9'))
    await ready()
    await waitFor(() => expect(resp(within(screen.getByTestId('side-from'))).value).toBe('e2'))
    expect(resp(within(screen.getByTestId('side-to'))).value).toBe('')
    fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
    expect(created()).toHaveLength(0)
  })
  it('S3 opening: no responsible field, nothing proposed', async () => {
    renderStock(`${NEW}?kind=opening`, asUser('user-9'))
    await form().findAllByRole('option', { name: 'Main store' })
    expect(form().queryByLabelText('Responsible')).toBeNull()
  })
  it('S4 no linked employee: empty', async () => {
    renderStock(`${NEW}?kind=receipt`, asUser('nobody'))
    await ready()
    expect(resp().value).toBe('')
  })
})
