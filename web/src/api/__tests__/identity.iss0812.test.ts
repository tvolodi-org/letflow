// @vitest-environment jsdom
/**
 * ISS-0812/ISS-0813 — regression coverage for the full identity.ts audit.
 *
 * ISS-0782 corrected usersApi.list/get/create/update and rolesApi.list.
 * ISS-0813 found and corrected the remaining dead call sites:
 *   - rolesApi.create: /api/v1/admin/roles → /api/v1/identity/roles
 *   - tokensApi.*: /api/v1/auth/tokens → /api/v1/identity/tokens
 *   - usersApi.resetPassword: /api/v1/users/ → /api/v1/identity/users/
 *     (route still unimplemented on backend, but prefix corrected)
 *   - usersApi.delete / rolesApi.get/update/delete/grant/revoke: removed,
 *     no backend route exists at any prefix (noted in identity.ts)
 *
 * Authority: Letflow.Routers.Identity.__authz_routes__/0
 * (lib/letflow/routers/identity.ex — authz_post "/roles", authz_post "/tokens",
 *  authz_get "/tokens", authz_delete "/tokens/:id")
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { rolesApi, tokensApi } from '../identity'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

function jsonResponse(body: unknown, init: { status?: number } = {}) {
  return Promise.resolve(
    new Response(JSON.stringify(body), {
      status: init.status ?? 200,
      headers: { 'Content-Type': 'application/json' },
    }),
  )
}

beforeEach(() => setToken('test-token'))
afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  vi.restoreAllMocks()
})

describe('ISS-0812/ISS-0813 — full identity.ts audit (ISS-0782 follow-up)', () => {
  describe('rolesApi', () => {
    it('rolesApi.create -> POST /api/v1/identity/roles (was /api/v1/admin/roles in ISS-0782 gap)', async () => {
      const spy = vi.fn().mockImplementation(() => jsonResponse({ id: 'r-1' }, { status: 201 }))
      window.fetch = spy as unknown as typeof window.fetch

      await rolesApi.create({ name: 'SOME_ROLE' })

      const [url, init] = spy.mock.calls[0] as [string, RequestInit]
      // Use exact pathname check so a suffix-corrupted path (e.g. /roles-WRONG)
      // is caught as well as an admin/ prefix regression.
      expect(new URL(url, 'http://localhost').pathname).toBe('/api/v1/identity/roles')
      expect(url).not.toContain('/api/v1/admin/roles')
      expect(init).toEqual(expect.objectContaining({ method: 'POST' }))
    })
  })

  describe('tokensApi', () => {
    it('tokensApi.list -> GET /api/v1/identity/tokens (was /api/v1/auth/tokens)', async () => {
      const spy = vi.fn().mockImplementation(() => jsonResponse({ items: [] }))
      window.fetch = spy as unknown as typeof window.fetch

      await tokensApi.list()

      const [url] = spy.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/v1/identity/tokens')
      expect(url).not.toContain('/api/v1/auth/tokens')
    })

    it('tokensApi.create -> POST /api/v1/identity/tokens (was /api/v1/auth/tokens)', async () => {
      const spy = vi.fn().mockImplementation(() =>
        jsonResponse({ id: 't-1', token: 'raw-tok', user_id: 'u-1', roles: [], expires_at: null }, { status: 201 }),
      )
      window.fetch = spy as unknown as typeof window.fetch

      await tokensApi.create({ user_id: 'u-1', roles: ['SOME_ROLE'] })

      const [url, init] = spy.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/v1/identity/tokens')
      expect(url).not.toContain('/api/v1/auth/tokens')
      expect(init).toEqual(expect.objectContaining({ method: 'POST' }))
    })

    it('tokensApi.revoke -> DELETE /api/v1/identity/tokens/:id (was /api/v1/auth/tokens/:id)', async () => {
      const spy = vi.fn().mockImplementation(() => jsonResponse({}, { status: 200 }))
      window.fetch = spy as unknown as typeof window.fetch

      await tokensApi.revoke('tok-123')

      const [url, init] = spy.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/v1/identity/tokens/tok-123')
      expect(url).not.toContain('/api/v1/auth/tokens')
      expect(init).toEqual(expect.objectContaining({ method: 'DELETE' }))
    })
  })
})
