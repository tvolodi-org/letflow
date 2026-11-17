// @vitest-environment jsdom
/** P3-L1..L4 — T-2042: the list thumbnail is lazy, main-only, thumbnail-only, with a placeholder. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { clientMock, fakePhotoServer, listOf, photo, stubObjectUrls } from './cardPhotosTestKit'

expect.extend(jestDomMatchers)
vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }) }))
vi.mock('@/i18n/uiLocaleStore', async (importOriginal) => ({ ...(await importOriginal<object>()), useUiLocale: () => 'en' }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: (await import('./cardPhotosTestKit')).clientMock }))

import { AssetsIntlProvider } from '../AssetsIntlProvider'
import { CardMainPhoto } from '../CardMainPhoto'
import { assetsQueryKeys } from '../assetsQueryKeys'

const state = { list: listOf([]) }
let triggers: Array<() => void>
const READ = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['AssetsRead'] } } as const

function mount(cards: string[], access: typeof READ | { status: 'ready'; info: { roles: never[]; platform_tenant: boolean; permissions: never[] } } = READ, qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })) {
  const view = render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={access as never}>
        <AssetsIntlProvider>
          {cards.map((c) => (
            <CardMainPhoto key={c} cardId={c} />
          ))}
        </AssetsIntlProvider>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
  return { ...view, qc }
}

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  stubObjectUrls()
  triggers = []
  vi.stubGlobal(
    'IntersectionObserver',
    class {
      private cb: IntersectionObserverCallback
      constructor(cb: IntersectionObserverCallback) {
        this.cb = cb
        triggers.push(() => this.cb([{ isIntersecting: true } as IntersectionObserverEntry], this as never))
      }
      observe() {}
      disconnect() {}
      unobserve() {}
    },
  )
  state.list = listOf([photo('a', 1), photo('b', 2, { is_main: false })])
  fakePhotoServer(state)
})
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('P3-L1 lazy', () => {
  it('asks nothing before a row is near the viewport, then one metadata read for that row only', async () => {
    mount(['c-1', 'c-2', 'c-3'])
    expect(clientMock.get).not.toHaveBeenCalled()
    act(() => triggers[1]())
    await waitFor(() => expect(clientMock.get).toHaveBeenCalledTimes(1))
    expect(clientMock.get).toHaveBeenCalledWith('/api/v1/modules/assets/cards/c-2/photos')
  })
  it('makes no read at all without AssetsRead', async () => {
    mount(['c-1'], { status: 'ready', info: { roles: [], platform_tenant: false, permissions: [] } })
    act(() => triggers[0]())
    await screen.findByTestId('card-main-photo-none')
    expect(clientMock.get).not.toHaveBeenCalled()
  })
})

describe('P3-L2 main thumbnail only', () => {
  it('reads the thumbnail of the main photo and never an original', async () => {
    mount(['c-1'])
    act(() => triggers[0]())
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledTimes(1))
    expect(clientMock.getBlob).toHaveBeenCalledWith('/api/v1/modules/assets/cards/c-1/photos/a/thumbnail')
    expect(clientMock.getBlob.mock.calls.some(([p]) => String(p).endsWith('/original'))).toBe(false)
    await waitFor(() => expect(document.querySelector('img.lf-photo-thumb__img')).not.toBeNull())
    expect(document.querySelector('img')).toHaveAttribute('alt', '')
  })
  it('shows the new main after the gallery cache is refreshed', async () => {
    const { qc } = mount(['c-1'])
    act(() => triggers[0]())
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledTimes(1))
    state.list = listOf([photo('a', 1, { is_main: false }), photo('b', 2, { is_main: true })])
    await act(async () => {
      await qc.invalidateQueries({ queryKey: assetsQueryKeys.cardPhotos('tid-assets', 'c-1') })
    })
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenLastCalledWith('/api/v1/modules/assets/cards/c-1/photos/b/thumbnail'))
  })
})

describe('P3-L3 placeholder', () => {
  it('a main photo without a thumbnail shows the placeholder and reads no content', async () => {
    state.list = listOf([photo('a', 1, { has_thumbnail: false })])
    mount(['c-1'])
    act(() => triggers[0]())
    await waitFor(() => expect(clientMock.get).toHaveBeenCalled())
    expect(screen.getByTestId('card-main-photo-none')).toHaveAttribute('aria-label', 'No photo')
    expect(clientMock.getBlob).not.toHaveBeenCalled()
  })
  it('a card with no photos, and a failed read, show the placeholder', async () => {
    mount(['c-1'])
    state.list = listOf([])
    clientMock.get.mockRejectedValue({ status: 404, message: 'x', code: '404', details: {} })
    act(() => triggers[0]())
    await waitFor(() => expect(clientMock.get).toHaveBeenCalled())
    expect(screen.getByTestId('card-main-photo-none')).toBeInTheDocument()
  })
  it('a thumbnail that cannot be read shows the failed placeholder, not a broken image', async () => {
    clientMock.getBlob.mockRejectedValue({ status: 404, message: 'x', code: '404', details: {} })
    mount(['c-1'])
    act(() => triggers[0]())
    expect(await screen.findByTestId('photo-failed')).toBeInTheDocument()
  })
})

describe('P3-L4 object URLs', () => {
  it('revokes the object URL on unmount', async () => {
    const { unmount } = mount(['c-1'])
    act(() => triggers[0]())
    await waitFor(() => expect(document.querySelector('img')).not.toBeNull())
    unmount()
    expect(URL.revokeObjectURL).toHaveBeenCalled()
  })
})
