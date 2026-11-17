/** Shared helpers of the card photo tests (T-2042): a fake photo server over the mocked client, a photo builder. */
import { vi } from 'vitest'
import type { CardPhoto, CardPhotoList } from '../cardPhotosModel'

export const clientMock = {
  get: vi.fn(),
  post: vi.fn(),
  patch: vi.fn(),
  put: vi.fn(),
  delete: vi.fn(),
  getBlob: vi.fn(),
}

export const photo = (id: string, position: number, extra: Partial<CardPhoto> = {}): CardPhoto => ({
  id,
  position,
  is_main: position === 1,
  caption: null,
  has_thumbnail: true,
  inserted_at: '2026-11-01T10:00:00Z',
  locked: false,
  can_delete: true,
  ...extra,
})

export const listOf = (photos: CardPhoto[], extra: Partial<CardPhotoList> = {}): CardPhotoList => ({
  photos,
  can_add: true,
  can_delete_any: true,
  limits: {
    max_photos: 10,
    original_max_bytes: 5_000_000,
    original_max_px: 4096,
    thumbnail_max_bytes: 200_000,
    thumbnail_max_px: 512,
    caption_max: 200,
  },
  ...extra,
})

/** The photo routes over the mocked client; `state.list` is what a GET answers and is replaced by the caller. */
export function fakePhotoServer(state: { list: CardPhotoList }) {
  clientMock.get.mockImplementation(async (path: string) => {
    if (path.endsWith('/photos')) return structuredClone(state.list)
    if (path.endsWith('/lock')) return { posted: false, held: true }
    return { rows: [], next_cursor: null }
  })
  clientMock.getBlob.mockImplementation(async () => ({ blob: new Blob(['img'], { type: 'image/jpeg' }), contentType: 'image/jpeg', contentDisposition: null, headers: new Headers() }))
}

export function stubObjectUrls() {
  let n = 0
  vi.stubGlobal('URL', Object.assign(URL, { createObjectURL: vi.fn(() => `blob:t${++n}`), revokeObjectURL: vi.fn() }))
}
