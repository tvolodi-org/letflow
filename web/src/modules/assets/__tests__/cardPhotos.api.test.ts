/** P3-API — T-2042 (photos P3): the typed photo calls send exactly what the T-2041 routes accept. */
import { beforeEach, describe, expect, it, vi } from 'vitest'

const clientMock = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
  patch: vi.fn(),
  put: vi.fn(),
  delete: vi.fn(),
  getBlob: vi.fn(),
}))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

import { assetsApi } from '../assets.api'
import { photoErrorId } from '../cardPhotosModel'

const BASE = '/api/v1/modules/assets/cards'

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
})

describe('P3-API photo calls', () => {
  it('lists, reads content, patches, sets main, orders and deletes on the right paths', async () => {
    await assetsApi.listCardPhotos('c 1')
    expect(clientMock.get).toHaveBeenCalledWith(`${BASE}/c%201/photos`)
    await assetsApi.cardPhotoContent('c-1', 'p/1', 'thumbnail')
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${BASE}/c-1/photos/p%2F1/thumbnail`)
    await assetsApi.cardPhotoContent('c-1', 'p-1', 'original')
    expect(clientMock.getBlob).toHaveBeenLastCalledWith(`${BASE}/c-1/photos/p-1/original`)
    await assetsApi.setCardPhotoCaption('c-1', 'p-1', '')
    expect(clientMock.patch).toHaveBeenCalledWith(`${BASE}/c-1/photos/p-1`, { caption: '' })
    await assetsApi.setCardPhotoMain('c-1', 'p-1')
    expect(clientMock.post).toHaveBeenCalledWith(`${BASE}/c-1/photos/p-1/main`, {})
    await assetsApi.orderCardPhotos('c-1', ['b', 'a'])
    expect(clientMock.put).toHaveBeenCalledWith(`${BASE}/c-1/photos/order`, { photo_ids: ['b', 'a'] })
    await assetsApi.deleteCardPhoto('c-1', 'p-1')
    expect(clientMock.delete).toHaveBeenCalledWith(`${BASE}/c-1/photos/p-1`)
  })

  it('uploads one multipart request with original and thumbnail, no idempotency key, no JSON content type', async () => {
    const original = new Blob(['o'], { type: 'image/jpeg' })
    const thumbnail = new Blob(['t'], { type: 'image/jpeg' })
    await assetsApi.uploadCardPhoto('c-1', original, thumbnail, 'Front')
    const [path, body] = clientMock.post.mock.calls[0] as [string, FormData]
    expect(path).toBe(`${BASE}/c-1/photos`)
    expect(body).toBeInstanceOf(FormData)
    expect([...body.keys()].sort()).toEqual(['caption', 'original', 'thumbnail'])
    expect(body.has('idempotency_key')).toBe(false)
    expect(clientMock.post.mock.calls[0]).toHaveLength(2)
  })

  it('omits an empty caption', async () => {
    await assetsApi.uploadCardPhoto('c-1', new Blob(['o']), new Blob(['t']), '')
    const body = clientMock.post.mock.calls[0][1] as FormData
    expect(body.has('caption')).toBe(false)
  })
})

describe('P3-API error mapping', () => {
  const problem = (status: number, reason?: string) => ({ status, details: reason ? { reason } : {} })
  it('maps a lock, a full storage and a cap to their own messages, not the idempotency text', () => {
    expect(photoErrorId(problem(409, 'photo_locked'))).toBe('assets.photos.error.photo_locked')
    expect(photoErrorId(problem(409, 'storage_quota_exceeded'))).toBe('assets.photos.error.storage_quota_exceeded')
    expect(photoErrorId(problem(422, 'owner_cap_reached'))).toBe('assets.photos.error.owner_cap_reached')
    expect(photoErrorId(problem(429))).toBe('assets.photos.error.upload_rate_exceeded')
    expect(photoErrorId(problem(404))).toBe('assets.photos.error.notFound')
    expect(photoErrorId(new Error('network'))).toBe('assets.photos.error.generic')
  })
})
