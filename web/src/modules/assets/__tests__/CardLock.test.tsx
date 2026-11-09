// @vitest-environment jsdom
/** W1–W5 — T-1490 / G3: after the first posted document the card form shows the inventory number read-only with a
 *  hint and never sends it; an unposted card stays editable; while the lock is unknown or failed the number stays
 *  disabled; a new card never asks. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { clearAllToasts } from '@/hooks/useToast'
import type { AccessState } from '@/auth/access/types'
import { fakeServer, problem, rec, renderAssets } from './assetsTestKit'
import { assetsMessages } from '../assetsMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const en = assetsMessages.en
const withRead: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['AssetsCardWrite', 'AssetsRead'] },
}
const withoutRead: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['AssetsCardWrite'] },
}
const DATA = {
  assets_card: [rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'Asset FA-1', kind: 'fixed' })],
  org_unit: [rec('u-1', 'org_unit', { code: 'U1', name: 'Head office' })],
}
const PATH = '/admin/assets/cards'
const field = (name: string) => document.querySelector(`[name="${name}"]`) as HTMLInputElement
const lockCalls = () => clientMock.get.mock.calls.filter(([p]) => String(p).endsWith('/lock'))

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
  clientMock.get.mockReset()
})
afterEach(() => {
  cleanup()
  clearAllToasts()
})

async function openCard() {
  fireEvent.click(await screen.findByText('FA-1'))
  await screen.findByRole('form')
}

describe('card lock in the form', () => {
  it('W1 a posted card: inventory number and kind disabled, hint shown, the lock route is asked', async () => {
    fakeServer(clientMock, DATA)
    clientMock.get.mockResolvedValue({ posted: true })
    renderAssets(PATH, withRead)
    await openCard()
    expect(await screen.findByTestId('asset-locked-hint')).toHaveTextContent(en['assets.card.lockedHint'])
    expect(field('inventory_number')).toBeDisabled()
    expect(field('kind')).toBeDisabled()
    expect(lockCalls()[0][0]).toBe('/api/v1/modules/assets/cards/c-1/lock')
  })

  it('W2 an unposted card: inventory number editable and sent when changed', async () => {
    fakeServer(clientMock, DATA)
    clientMock.get.mockResolvedValue({ posted: false })
    renderAssets(PATH, withRead)
    await openCard()
    await waitFor(() => expect(field('inventory_number')).not.toBeDisabled())
    expect(screen.queryByTestId('asset-locked-hint')).not.toBeInTheDocument()
    fireEvent.change(field('inventory_number'), { target: { value: 'FA-9' } })
    fireEvent.click(screen.getByTestId('asset-save'))
    await waitFor(() => expect(clientMock.patch).toHaveBeenCalled())
    expect(clientMock.patch.mock.calls[0][1]).toMatchObject({ inventory_number: 'FA-9' })
  })

  it('W3 while the lock is pending or failed the inventory number stays disabled', async () => {
    fakeServer(clientMock, DATA)
    clientMock.get.mockReturnValue(new Promise(() => undefined))
    renderAssets(PATH, withRead)
    await openCard()
    expect(field('inventory_number')).toBeDisabled()
    cleanup()
    clientMock.get.mockReset()
    clientMock.get.mockRejectedValue(problem(500, {}))
    renderAssets(PATH, withRead)
    await openCard()
    await waitFor(() => expect(lockCalls().length).toBeGreaterThan(0))
    expect(field('inventory_number')).toBeDisabled()
  })

  it('W4 a posted card: changing the name sends no inventory number or kind', async () => {
    fakeServer(clientMock, DATA)
    clientMock.get.mockResolvedValue({ posted: true })
    renderAssets(PATH, withRead)
    await openCard()
    await screen.findByTestId('asset-locked-hint')
    fireEvent.change(field('name'), { target: { value: 'Renamed' } })
    fireEvent.click(screen.getByTestId('asset-save'))
    await waitFor(() => expect(clientMock.patch).toHaveBeenCalled())
    expect(Object.keys(clientMock.patch.mock.calls[0][1] as object).sort()).toEqual(['idempotency_key', 'name'])
  })

  it('W5 a new card and a writer without AssetsRead make no lock call', async () => {
    fakeServer(clientMock, { assets_card: [], org_unit: DATA.org_unit })
    renderAssets(PATH, withRead)
    fireEvent.click(await screen.findByRole('button', { name: en['assets.common.create'] }))
    await screen.findByRole('form', { name: en['assets.page.createTitle'] })
    expect(lockCalls()).toHaveLength(0)
    cleanup()
    fakeServer(clientMock, DATA)
    renderAssets(PATH, withoutRead)
    await openCard()
    expect(field('inventory_number')).not.toBeDisabled()
    expect(lockCalls()).toHaveLength(0)
  })
})
