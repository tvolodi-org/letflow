// @vitest-environment jsdom
/**
 * Unit tests for client.getBlob (REQ-387 §2.2) — the D1 load-bearing new API
 * surface: attachment bytes are fetched via an authenticated call through
 * this same window.fetch wrapper (same Authorization/x-bpm-user-id headers
 * request() attaches), never a raw <img src>/<a href>/<iframe src> pointed
 * directly at the backend. On a non-2xx response, getBlob throws the same
 * ApiError shape request() does — callers branch on err.status
 * (404/410/other), not a blob-specific type.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { client, setToken, clearToken } from '../client'

function mockFetchOnce(response: {
  ok: boolean
  status: number
  blob?: Blob
  contentType?: string | null
  contentDisposition?: string | null
  jsonBody?: unknown
}): void {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      ok: response.ok,
      status: response.status,
      statusText: 'status',
      blob: async () => response.blob ?? new Blob([]),
      json: async () => response.jsonBody ?? {},
      headers: {
        get: (name: string) =>
          name === 'Content-Type' ? (response.contentType ?? null) : name === 'Content-Disposition' ? (response.contentDisposition ?? null) : null,
      },
    }),
  )
}

describe('client.getBlob', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
    clearToken()
  })

  it('returns the Content-Disposition header (REQ-720 P3), null when absent', async () => {
    mockFetchOnce({ ok: true, status: 200, contentType: 'x', contentDisposition: 'attachment; filename="a.xlsx"' })
    expect((await client.getBlob('/x')).contentDisposition).toBe('attachment; filename="a.xlsx"')
    mockFetchOnce({ ok: true, status: 200, contentType: 'x' })
    expect((await client.getBlob('/x')).contentDisposition).toBeNull()
  })

  it('attaches Authorization/x-bpm-user-id headers, same as request()', async () => {
    // sub claim "user-123" base64url-encoded into a fake JWT
    const payload = Buffer.from(JSON.stringify({ sub: 'user-123' })).toString('base64url')
    const fakeToken = `header.${payload}.sig`
    setToken(fakeToken)

    const blob = new Blob(['bytes'], { type: 'application/pdf' })
    mockFetchOnce({ ok: true, status: 200, blob, contentType: 'application/pdf' })

    await client.getBlob('/api/v1/instances/i1/attachments/a1/link-content', { link_token: 'tok' })

    expect(fetch).toHaveBeenCalledTimes(1)
    const [url, init] = (fetch as ReturnType<typeof vi.fn>).mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/instances/i1/attachments/a1/link-content')
    expect(url).toContain('link_token=tok')
    const headers = init.headers as Record<string, string>
    expect(headers['Authorization']).toBe(`Bearer ${fakeToken}`)
    expect(headers['x-bpm-user-id']).toBe('user-123')
  })

  it('resolves { blob, contentType } on a 200 response', async () => {
    const blob = new Blob(['bytes'], { type: 'application/pdf' })
    mockFetchOnce({ ok: true, status: 200, blob, contentType: 'application/pdf' })

    const result = await client.getBlob('/api/v1/instances/i1/attachments/a1/link-content')

    expect(result.blob).toBe(blob)
    expect(result.contentType).toBe('application/pdf')
  })

  it('throws an ApiError with status 410 on an expired-link response', async () => {
    mockFetchOnce({ ok: false, status: 410, jsonBody: { title: 'expired' } })

    await expect(
      client.getBlob('/api/v1/instances/i1/attachments/a1/link-content'),
    ).rejects.toMatchObject({ status: 410 })
  })

  it('throws an ApiError with status 404 on a not-found response', async () => {
    mockFetchOnce({ ok: false, status: 404, jsonBody: {} })

    await expect(
      client.getBlob('/api/v1/instances/i1/attachments/a1/link-content'),
    ).rejects.toMatchObject({ status: 404 })
  })

  it('throws status 401 and dispatches auth:session-expired on an unauthenticated response', async () => {
    mockFetchOnce({ ok: false, status: 401, jsonBody: {} })
    const listener = vi.fn()
    window.addEventListener('auth:session-expired', listener)

    await expect(
      client.getBlob('/api/v1/instances/i1/attachments/a1/link-content'),
    ).rejects.toMatchObject({ status: 401 })
    expect(listener).toHaveBeenCalledTimes(1)
    window.removeEventListener('auth:session-expired', listener)
  })
})
