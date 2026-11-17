// @vitest-environment jsdom
/** P3-T1/T3 — T-2042: the Photos tab of the card (active and retired, not in create) and the pending-upload leave. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import type { AccessState } from '@/auth/access/types'
import { clearAllToasts } from '@/hooks/useToast'
import { fakeServer, rec, renderAssets } from './assetsTestKit'
import { assetsMessages } from '../assetsMessages'
import { listOf, photo } from './cardPhotosTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }) }))
vi.mock('@/i18n/uiLocaleStore', async (importOriginal) => ({ ...(await importOriginal<object>()), useUiLocale: () => 'en' }))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))
vi.mock('@/lib/photos/preparePhoto', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  preparePhoto: vi.fn(async () => ({ ok: true, original: new Blob(['o']), thumbnail: new Blob(['t']) })),
}))

const en = assetsMessages.en
const FULL: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['AssetsCardWrite', 'AssetsRead', 'AssetsPost'] } }
const PATH = '/admin/assets/cards'
const DATA = {
  assets_card: [
    rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'Asset FA-1', kind: 'fixed' }),
    rec('c-2', 'assets_card', { inventory_number: 'FA-2', name: 'Asset FA-2', kind: 'fixed' }),
    rec('c-8', 'assets_card', { inventory_number: 'FA-8', name: 'Asset FA-8', kind: 'fixed', active: false }),
  ],
}
const tab = (name: string) => screen.getByRole('tab', { name })

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  let n = 0
  vi.stubGlobal('URL', Object.assign(URL, { createObjectURL: vi.fn(() => `blob:t${++n}`), revokeObjectURL: vi.fn() }))
  clientMock.get.mockImplementation(async (p: string) => {
    if (p.endsWith('/photos')) return listOf([photo('p1', 1)])
    if (p.endsWith('/lock')) return { posted: false, held: true }
    return { rows: [], next_cursor: null }
  })
  clientMock.getBlob.mockResolvedValue({ blob: new Blob(['i'], { type: 'image/jpeg' }), contentType: 'image/jpeg', contentDisposition: null, headers: new Headers() })
  fakeServer(clientMock, DATA)
})
afterEach(() => {
  cleanup()
  clearAllToasts()
  vi.unstubAllGlobals()
})

describe('P3-T1 Photos tab', () => {
  it('an active card has Photos after Accounting, reached by keyboard selection; the form Save is replaced by a note', async () => {
    renderAssets(PATH, FULL)
    fireEvent.click(await screen.findByText('FA-1'))
    await screen.findByTestId('detail-tabs')
    const names = screen.getAllByRole('tab').map((x) => x.textContent)
    expect(names).toEqual(['Main', 'Accounting', 'Photos'])
    fireEvent.click(tab('Photos'))
    expect(await screen.findByTestId('photo-view')).toBeVisible()
    expect(screen.getByTestId('photos-form-note')).toBeInTheDocument()
    expect(screen.queryByTestId('asset-save')).toBeNull()
    fireEvent.click(tab('Main'))
    expect(screen.getByTestId('asset-save')).toBeInTheDocument()
  })
  it('a retired card has the same gallery with the server capabilities', async () => {
    renderAssets(PATH, FULL)
    fireEvent.click(await screen.findByText('Show retired'))
    fireEvent.click(await screen.findByText('FA-8'))
    await screen.findByTestId('detail-tabs')
    fireEvent.click(tab('Photos'))
    expect(await screen.findByTestId('card-photos')).toBeVisible()
    expect(clientMock.get).toHaveBeenCalledWith('/api/v1/modules/assets/cards/c-8/photos')
  })
  it('the create form has no gallery', async () => {
    renderAssets(PATH, FULL)
    fireEvent.click(await screen.findByTestId('asset-create'))
    await screen.findByLabelText(en['assets.page.createTitle'])
    expect(screen.queryByRole('tab', { name: 'Photos' })).toBeNull()
    expect(screen.queryByTestId('card-photos')).toBeNull()
  })
  it('the list rows carry a main-photo thumbnail or its placeholder, never the original', async () => {
    renderAssets(PATH, FULL)
    await screen.findByText('FA-1')
    await waitFor(() => expect(document.querySelector('img.lf-photo-thumb__img')).not.toBeNull())
    expect(clientMock.getBlob.mock.calls.every(([p]) => String(p).endsWith('/thumbnail'))).toBe(true)
  })
})

describe('P3-T3 pending upload', () => {
  async function stage() {
    renderAssets(PATH, FULL)
    fireEvent.click(await screen.findByText('FA-1'))
    await screen.findByTestId('detail-tabs')
    fireEvent.click(tab('Photos'))
    await screen.findByTestId('photo-view')
    fireEvent.change(screen.getByTestId('photo-file-input'), { target: { files: [new File(['x'], 'a.jpg', { type: 'image/jpeg' })] } })
    await waitFor(() => expect(screen.getByTestId('photo-upload')).toBeEnabled())
  }
  it('Stay keeps the card and the queue; Leave switches and uploads nothing', async () => {
    await stage()
    fireEvent.click(screen.getByText('FA-2'))
    const dialog = await screen.findByTestId('confirm-dialog')
    expect(dialog).toHaveTextContent('1 photos')
    fireEvent.click(within(dialog).getByRole('button', { name: en['assets.photos.pendingStay'] }))
    expect(screen.queryByTestId('confirm-dialog')).toBeNull()
    expect(screen.getAllByTestId('photo-staged')).toHaveLength(1)
    fireEvent.click(screen.getByText('FA-2'))
    fireEvent.click(within(await screen.findByTestId('confirm-dialog')).getByRole('button', { name: en['assets.photos.pendingLeave'] }))
    await waitFor(() => expect(screen.queryByTestId('photo-staged')).toBeNull())
    expect(clientMock.post.mock.calls.some(([p]) => String(p).endsWith('/photos'))).toBe(false)
    expect(clientMock.get).toHaveBeenCalledWith('/api/v1/modules/assets/cards/c-2/photos')
  })
  it('closing the panel asks the same way', async () => {
    await stage()
    fireEvent.click(screen.getAllByRole('button', { name: en['assets.common.close'] })[0])
    expect(await screen.findByTestId('confirm-dialog')).toHaveTextContent(en['assets.photos.pendingTitle'])
  })
})
