// @vitest-environment jsdom
/** P3-G1..G6 — T-2042: the card gallery: states, upload with retry, caption, order, main, delete. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { clientMock, fakePhotoServer, listOf, photo, stubObjectUrls } from './cardPhotosTestKit'

expect.extend(jestDomMatchers)

const locale = vi.hoisted(() => ({ current: 'en' }))
vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }) }))
vi.mock('@/i18n/uiLocaleStore', async (importOriginal) => ({ ...(await importOriginal<object>()), useUiLocale: () => locale.current }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: (await import('./cardPhotosTestKit')).clientMock }))
vi.mock('@/lib/photos/preparePhoto', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  preparePhoto: vi.fn(async (f: File) =>
    f.name.endsWith('.gif') ? { ok: false, reason: 'type' } : { ok: true, original: new Blob(['o'], { type: 'image/jpeg' }), thumbnail: new Blob(['t'], { type: 'image/jpeg' }) },
  ),
}))

import { AssetsIntlProvider } from '../AssetsIntlProvider'
import { CardPhotoGallery } from '../CardPhotoGallery'
import { assetsMessages } from '../assetsMessages'

const en = assetsMessages.en
const problem = (status: number, reason: string) => ({ status, message: 'x', code: String(status), details: { reason } })
const state = { list: listOf([]) }

function mount(extra: { onPendingChange?: (n: number) => void; onModalChange?: (o: boolean) => void } = {}) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <AssetsIntlProvider>
        <CardPhotoGallery cardId="c-1" {...extra} />
      </AssetsIntlProvider>
    </QueryClientProvider>,
  )
}
const pick = (...names: string[]) => fireEvent.change(screen.getByTestId('photo-file-input'), { target: { files: names.map((n) => new File(['x'], n, { type: 'image/jpeg' })) } })

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  stubObjectUrls()
  locale.current = 'en'
  state.list = listOf([])
  fakePhotoServer(state)
})
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('P3-G1 states', () => {
  it('shows a skeleton first, then the empty state with the add actions and the limit', async () => {
    mount()
    expect(screen.queryByTestId('photo-choose')).toBeNull()
    expect(await screen.findByTestId('photos-empty')).toBeInTheDocument()
    expect(screen.getByTestId('photo-choose')).toBeEnabled()
    expect(screen.getByText(en['assets.photos.limits'].replace('{max}', '10'))).toBeInTheDocument()
  })
  it('a reader without can_add sees the photos, a reason and no add or edit controls', async () => {
    state.list = listOf([photo('p1', 1, { caption: 'Front', can_delete: false })], { can_add: false, can_delete_any: false })
    mount()
    await screen.findByTestId('photo-view')
    expect(screen.getByText(en['assets.photos.readOnly'])).toBeInTheDocument()
    expect(screen.queryByTestId('photo-choose')).toBeNull()
    expect(screen.queryByTestId('photo-caption-save')).toBeNull()
    expect(screen.queryByTestId('photo-delete')).toBeNull()
    expect(screen.getByTestId('photo-caption-read')).toHaveTextContent('Front')
  })
  it('at the returned cap the add controls are disabled with the count and the limit', async () => {
    state.list = listOf([photo('p1', 1), photo('p2', 2)])
    state.list.limits.max_photos = 2
    mount()
    await screen.findByTestId('photo-view')
    expect(screen.getByTestId('photo-choose')).toBeDisabled()
    expect(screen.getByTestId('photo-disabled-reason')).toHaveTextContent('2 of 2')
  })
  it('a load error shows Retry and Retry reloads', async () => {
    clientMock.get.mockRejectedValueOnce({ status: 500, message: 'x', code: '500', details: {} })
    mount()
    fireEvent.click(await screen.findByRole('button', { name: /retry|повтор/i }))
    expect(await screen.findByTestId('photos-empty')).toBeInTheDocument()
  })
  it('a 404 shows the unavailable text, not a retry loop', async () => {
    clientMock.get.mockRejectedValue({ status: 404, message: 'x', code: '404', details: {} })
    mount()
    expect(await screen.findByText(en['assets.photos.unavailable'])).toBeInTheDocument()
    expect(clientMock.get).toHaveBeenCalledTimes(1)
  })
})

describe('P3-G2 upload', () => {
  it('stages two images, uploads them one after the other, and refetches', async () => {
    const pending = vi.fn()
    mount({ onPendingChange: pending })
    await screen.findByTestId('photos-empty')
    pick('a.jpg', 'b.jpg')
    await waitFor(() => expect(screen.getAllByTestId('photo-staged')).toHaveLength(2))
    await waitFor(() => expect(screen.getByTestId('photo-upload')).toBeEnabled())
    expect(pending).toHaveBeenLastCalledWith(2)
    clientMock.post.mockResolvedValue(photo('new', 1))
    fireEvent.click(screen.getByTestId('photo-upload'))
    await waitFor(() => expect(clientMock.post).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(screen.queryAllByTestId('photo-staged')).toHaveLength(0))
    const calls = clientMock.post.mock.calls
    expect(calls.every(([p]) => p === '/api/v1/modules/assets/cards/c-1/photos')).toBe(true)
    expect(calls.every(([, b]) => b instanceof FormData)).toBe(true)
    expect(pending).toHaveBeenLastCalledWith(0)
  })
  it('a failed upload stays with a plain reason and Retry; the retry stores one photo and clears the item', async () => {
    mount()
    await screen.findByTestId('photos-empty')
    pick('a.jpg')
    await waitFor(() => expect(screen.getByTestId('photo-upload')).toBeEnabled())
    clientMock.post.mockRejectedValueOnce(problem(503, 'scan_unavailable'))
    fireEvent.click(screen.getByTestId('photo-upload'))
    expect(await screen.findByText(en['assets.photos.error.scan_unavailable'])).toBeInTheDocument()
    clientMock.post.mockResolvedValueOnce(photo('new', 1)) // 200 replay is a success as well
    fireEvent.click(screen.getByTestId('photo-retry'))
    await waitFor(() => expect(screen.queryAllByTestId('photo-staged')).toHaveLength(0))
    expect(clientMock.post).toHaveBeenCalledTimes(2)
  })
  it('a refusal stops the queue: the later item stays ready, not sent', async () => {
    mount()
    await screen.findByTestId('photos-empty')
    pick('a.jpg', 'b.jpg')
    await waitFor(() => expect(screen.getByTestId('photo-upload')).toHaveTextContent('(2)'))
    clientMock.post.mockRejectedValueOnce(problem(409, 'storage_quota_exceeded'))
    fireEvent.click(screen.getByTestId('photo-upload'))
    expect(await screen.findByText(en['assets.photos.error.storage_quota_exceeded'])).toBeInTheDocument()
    expect(clientMock.post).toHaveBeenCalledTimes(1)
    expect(screen.getAllByTestId('photo-staged')).toHaveLength(2)
  })
  it('an unsupported file is a local, translated failure with no request; Remove drops it', async () => {
    mount()
    await screen.findByTestId('photos-empty')
    pick('x.gif')
    expect(await screen.findByText(en['assets.photos.error.local_type'])).toBeInTheDocument()
    expect(screen.queryByTestId('photo-retry')).toBeNull()
    fireEvent.click(screen.getByTestId('photo-staged-remove'))
    expect(screen.queryAllByTestId('photo-staged')).toHaveLength(0)
    expect(clientMock.post).not.toHaveBeenCalled()
  })
  it('refuses images beyond the remaining room and says how many', async () => {
    state.list = listOf([photo('p1', 1)])
    state.list.limits.max_photos = 2
    mount()
    await screen.findByTestId('photo-view')
    pick('a.jpg', 'b.jpg', 'c.jpg')
    await waitFor(() => expect(screen.getAllByTestId('photo-staged')).toHaveLength(1))
    expect(screen.getByText('2 photos were not added: a card holds at most 2.')).toBeInTheDocument()
  })
})

describe('P3-G3 caption', () => {
  beforeEach(() => {
    state.list = listOf([photo('p1', 1, { caption: 'Old' })])
    state.list.limits.caption_max = 5
  })
  it('saves the trimmed text and clears with an empty string', async () => {
    mount()
    const box = (await screen.findByRole('textbox', { name: /caption/i })) as HTMLTextAreaElement
    expect(box.value).toBe('Old')
    clientMock.patch.mockResolvedValue(photo('p1', 1))
    fireEvent.change(box, { target: { value: '  Hi  ' } })
    fireEvent.click(screen.getByTestId('photo-caption-save'))
    await waitFor(() => expect(clientMock.patch).toHaveBeenCalledWith('/api/v1/modules/assets/cards/c-1/photos/p1', { caption: 'Hi' }))
    fireEvent.change(box, { target: { value: '' } })
    fireEvent.click(screen.getByTestId('photo-caption-save'))
    await waitFor(() => expect(clientMock.patch).toHaveBeenLastCalledWith('/api/v1/modules/assets/cards/c-1/photos/p1', { caption: '' }))
  })
  it('the limit counts code points: 5 characters pass, 6 are refused beside the field with no request', async () => {
    mount()
    const box = await screen.findByRole('textbox', { name: /caption/i })
    clientMock.patch.mockResolvedValue(photo('p1', 1))
    fireEvent.change(box, { target: { value: '😀😀😀😀😀' } })
    fireEvent.click(screen.getByTestId('photo-caption-save'))
    await waitFor(() => expect(clientMock.patch).toHaveBeenCalledTimes(1))
    fireEvent.change(box, { target: { value: '123456' } })
    fireEvent.click(screen.getByTestId('photo-caption-save'))
    expect(await screen.findByText(en['assets.photos.captionTooLong'].replace('{max}', '5'))).toBeInTheDocument()
    expect(clientMock.patch).toHaveBeenCalledTimes(1)
  })
  it('a server caption_invalid stays by the field', async () => {
    mount()
    const box = await screen.findByRole('textbox', { name: /caption/i })
    clientMock.patch.mockRejectedValue(problem(422, 'caption_invalid'))
    fireEvent.change(box, { target: { value: 'ok' } })
    fireEvent.click(screen.getByTestId('photo-caption-save'))
    const field = box.closest('.lf-field') as HTMLElement
    expect(await within(field).findByText(en['assets.photos.error.caption_invalid'])).toBeInTheDocument()
  })
})

describe('P3-G4 order', () => {
  beforeEach(() => {
    state.list = listOf([photo('a', 1), photo('b', 2), photo('c', 3)])
  })
  it('Move earlier sends the complete id list and uses the returned order', async () => {
    mount()
    fireEvent.click(await screen.findByTestId('photo-tile-b'))
    clientMock.put.mockResolvedValue(listOf([photo('b', 1), photo('a', 2), photo('c', 3)]))
    fireEvent.click(screen.getByTestId('photo-earlier'))
    await waitFor(() => expect(clientMock.put).toHaveBeenCalledWith('/api/v1/modules/assets/cards/c-1/photos/order', { photo_ids: ['b', 'a', 'c'] }))
    await waitFor(() => expect(screen.getByTestId('photo-tile-b').closest('ul')!.firstElementChild).toContainElement(screen.getByTestId('photo-tile-b')))
  })
  it('the first photo cannot move earlier, the last cannot move later', async () => {
    mount()
    await screen.findByTestId('photo-view')
    expect(screen.getByTestId('photo-earlier')).toBeDisabled()
    fireEvent.click(screen.getByTestId('photo-tile-c'))
    expect(screen.getByTestId('photo-later')).toBeDisabled()
  })
  it('a failed order keeps the old order and says so', async () => {
    mount()
    fireEvent.click(await screen.findByTestId('photo-tile-b'))
    clientMock.put.mockRejectedValue(problem(422, 'invalid_order'))
    fireEvent.click(screen.getByTestId('photo-earlier'))
    expect(await screen.findByText(en['assets.photos.error.invalid_order'])).toBeInTheDocument()
    expect(screen.getByTestId('photo-tile-a').closest('ul')!.firstElementChild).toContainElement(screen.getByTestId('photo-tile-a'))
  })
})

describe('P3-G5 main', () => {
  it('Make main posts an empty body and refetches, so the old main flag moves', async () => {
    state.list = listOf([photo('a', 1), photo('b', 2)])
    mount()
    fireEvent.click(await screen.findByTestId('photo-tile-b'))
    expect(screen.queryByText(en['assets.photos.main'], { selector: '.lf-pill, .lf-pill *' })).toBeNull()
    clientMock.post.mockImplementation(async () => {
      state.list = listOf([photo('a', 1, { is_main: false }), photo('b', 2, { is_main: true })])
      return photo('b', 2)
    })
    fireEvent.click(screen.getByTestId('photo-make-main'))
    await waitFor(() => expect(clientMock.post).toHaveBeenCalledWith('/api/v1/modules/assets/cards/c-1/photos/b/main', {}))
    await waitFor(() => expect(screen.queryByTestId('photo-make-main')).toBeNull())
  })
})

describe('P3-G6 delete', () => {
  it('asks first, deletes, promotes the next photo and keeps the gallery', async () => {
    state.list = listOf([photo('a', 1), photo('b', 2)])
    const modal = vi.fn()
    mount({ onModalChange: modal })
    await screen.findByTestId('photo-view')
    fireEvent.click(screen.getByTestId('photo-delete'))
    expect(modal).toHaveBeenLastCalledWith(true)
    expect(clientMock.delete).not.toHaveBeenCalled()
    clientMock.delete.mockImplementation(async () => {
      state.list = listOf([photo('b', 1)])
    })
    fireEvent.click(within(screen.getByTestId('confirm-dialog')).getByRole('button', { name: en['assets.photos.deleteConfirm'] }))
    await waitFor(() => expect(clientMock.delete).toHaveBeenCalledWith('/api/v1/modules/assets/cards/c-1/photos/a'))
    await waitFor(() => expect(screen.queryByTestId('photo-tile-a')).toBeNull())
    expect(screen.getByTestId('photo-tile-b')).toBeInTheDocument()
    expect(modal).toHaveBeenLastCalledWith(false)
  })
  it('hides Delete when the server says the photo cannot be deleted', async () => {
    state.list = listOf([photo('a', 1, { can_delete: false })])
    mount()
    await screen.findByTestId('photo-view')
    expect(screen.queryByTestId('photo-delete')).toBeNull()
    expect(screen.getByTestId('photo-caption-save')).toBeInTheDocument()
  })
  it('a locked photo has no edit or delete controls and says why', async () => {
    state.list = listOf([photo('a', 1, { locked: true, can_delete: false })])
    mount()
    await screen.findByTestId('photo-view')
    expect(screen.getByText(en['assets.photos.locked'])).toBeInTheDocument()
    expect(screen.queryByTestId('photo-caption-save')).toBeNull()
    expect(screen.queryByTestId('photo-earlier')).toBeNull()
  })
})

describe('P3-T2 locales', () => {
  it.each(['ru', 'kk'])('renders the gallery in %s with no English key left', async (loc) => {
    locale.current = loc
    state.list = listOf([photo('a', 1)])
    mount()
    await screen.findByTestId('photo-view')
    const text = screen.getByTestId('card-photos').textContent ?? ''
    expect(text).toContain(assetsMessages[loc as 'ru' | 'kk']['assets.photos.title'])
    expect(text).not.toContain('assets.photos')
    expect(text).not.toContain('Choose photos')
  })
})
