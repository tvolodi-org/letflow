// @vitest-environment jsdom
/** A1..A3 — T-1528: the signed-in user's linked employee is proposed as the From responsible (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import type { AccessState } from '@/auth/access/types'
import { DOCS, LIST, MASTERS, assetDoc, fakeDocument, fakeMasters, renderAssets, rec } from './registerTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const NEW = `${LIST}/new`
const asUser = (userId: string): AccessState => ({
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['AssetsRead', 'AssetsPost'], user_id: userId },
})
const DATA = {
  ...MASTERS,
  org_employee: [
    rec('e1', 'org_employee', { full_name: 'Aigul B.' }),
    rec('e2', 'org_employee', { full_name: 'Marat K.', user_id: 'user-9' }),
  ],
}
const created = (): [string, Record<string, unknown>][] => clientMock.post.mock.calls.filter(([p]) => p === DOCS) as [string, Record<string, unknown>][]

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock, DATA)
  const masters = clientMock.post.getMockImplementation()!
  const saved = assetDoc({ id: 'dn' })
  clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => (p === DOCS ? saved : masters(p, b)))
  fakeDocument(clientMock, saved)
})
afterEach(() => cleanup())

const form = () => within(screen.getByTestId('document-form'))
const responsible = (scope: { getByLabelText: (l: RegExp) => HTMLElement } = form()) => scope.getByLabelText(/^Material responsible/) as HTMLSelectElement
async function ready() {
  await form().findAllByRole('option', { name: 'Marat K.' })
}

describe('T-1528 asset form proposes the linked employee', () => {
  it('A1 commission: preselected, and sent', async () => {
    renderAssets(NEW, asUser('user-9'))
    await ready()
    await waitFor(() => expect(responsible().value).toBe('e2'))
    fireEvent.change(form().getByLabelText('Time, date'), { target: { value: '2026-11-04' } })
    fireEvent.change(form().getByLabelText('Time, time'), { target: { value: '10:00' } })
    fireEvent.change(form().getByLabelText(/^Org unit/), { target: { value: 'u1' } })
    fireEvent.change(form().getByLabelText(/^Location/), { target: { value: 'l1' } })
    fireEvent.click(await screen.findByRole('button', { name: 'Add line' }))
    const row = (await screen.findAllByTestId('line-editor-row'))[0]
    await waitFor(() => {
      const input = within(row).getByLabelText('Asset')
      fireEvent.change(input, { target: { value: 'FA-0001' } })
      fireEvent.blur(input)
      expect((input as HTMLInputElement).value).toContain('FA-0001')
    })
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]['material_responsible_id']).toBe('e2')
  })
  it('A2 hand over: only From is proposed, To stays empty and required', async () => {
    renderAssets(`${NEW}?kind=handover`, asUser('user-9'))
    await ready()
    const from = within(screen.getByTestId('side-from'))
    const to = within(screen.getByTestId('side-to'))
    await waitFor(() => expect(responsible(from).value).toBe('e2'))
    expect(responsible(to).value).toBe('')
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    expect(created()).toHaveLength(0)
  })
  it('A3 no linked employee: empty; a changed or cleared proposal is kept', async () => {
    const first = renderAssets(NEW, asUser('nobody'))
    await ready()
    expect(responsible().value).toBe('')
    first.unmount()
    cleanup()
    renderAssets(NEW, asUser('user-9'))
    await ready()
    await waitFor(() => expect(responsible().value).toBe('e2'))
    fireEvent.change(responsible(), { target: { value: 'e1' } })
    expect(responsible().value).toBe('e1')
    fireEvent.change(responsible(), { target: { value: '' } })
    await new Promise((r) => setTimeout(r, 20))
    expect(responsible().value).toBe('')
  })
})
