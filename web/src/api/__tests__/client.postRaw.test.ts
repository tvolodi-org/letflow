// @vitest-environment jsdom
/** GH 3650 / REQ-675: client.postRaw (raw bytes, caller content type) and client.postBlob (JSON body, binary answer). */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { client, setToken, clearToken } from '../client'

function stubFetch(status: number, body: unknown = {}) {
  const fn = vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    statusText: 'status',
    blob: async () => new Blob(['xlsx']),
    json: async () => body,
    headers: { get: (name: string) => (name === 'Content-Type' ? 'application/x' : null) },
  })
  vi.stubGlobal('fetch', fn)
  return fn
}

afterEach(() => {
  vi.unstubAllGlobals()
  clearToken()
})

describe('client.postRaw', () => {
  it('sends the bytes unencoded with the given content type and the auth headers', async () => {
    const payload = Buffer.from(JSON.stringify({ sub: 'user-1' })).toString('base64url')
    setToken(`h.${payload}.s`)
    const fetchFn = stubFetch(200, { results: [] })
    const file = new Blob([new Uint8Array([1, 2, 3])])
    await client.postRaw('/p?q=1', file, 'application/vnd.test')
    const [url, init] = fetchFn.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/p?q=1')
    expect(init.method).toBe('POST')
    expect(init.body).toBe(file)
    const headers = init.headers as Record<string, string>
    expect(headers['Content-Type']).toBe('application/vnd.test')
    expect(headers['Authorization']).toBe(`Bearer h.${payload}.s`)
    expect(headers['x-bpm-user-id']).toBe('user-1')
  })

  it('throws an ApiError whose details keep the problem body (422)', async () => {
    stubFetch(422, { title: 'Unprocessable', detail: 'xlsx file has no header row' })
    await expect(client.postRaw('/p', new Blob([]), 'x')).rejects.toMatchObject({
      status: 422,
      details: { detail: 'xlsx file has no header row' },
    })
  })

  it('throws status 413 even when the body is not JSON', async () => {
    const fn = vi.fn().mockResolvedValue({
      ok: false,
      status: 413,
      statusText: 'Payload Too Large',
      json: async () => {
        throw new Error('not json')
      },
      headers: { get: () => null },
    })
    vi.stubGlobal('fetch', fn)
    await expect(client.postRaw('/p', new Blob([]), 'x')).rejects.toMatchObject({ status: 413 })
  })
})

describe('client.postBlob', () => {
  it('posts JSON and returns the blob', async () => {
    const fetchFn = stubFetch(200)
    const { blob, contentType } = await client.postBlob('/export', { entity_type: 't' })
    const [, init] = fetchFn.mock.calls[0] as [string, RequestInit]
    expect(init.body).toBe('{"entity_type":"t"}')
    expect((init.headers as Record<string, string>)['Content-Type']).toBe('application/json')
    expect(blob.size).toBe(4)
    expect(contentType).toBe('application/x')
  })

  it('throws the same ApiError on a non-2xx answer', async () => {
    stubFetch(403, { title: 'Forbidden' })
    await expect(client.postBlob('/export', {})).rejects.toMatchObject({ status: 403 })
  })
})
