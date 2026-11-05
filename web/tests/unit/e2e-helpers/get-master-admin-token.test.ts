/**
 * Unit tests -- GH #1995 / ISS-0896: the e2e helpers hold no hard-coded Keycloak
 * master admin credential, and `getRealmAdminToken` uses the per-realm
 * `uat-seed-admin` client (client_credentials) read from the environment.
 *
 *   TC-1: getRealmAdminToken POSTs client_credentials with the env client id/secret to the realm's token URL
 *   TC-2: getRealmAdminToken throws, without a request, when the env pair is missing
 *   TC-3: a failed token request throws without echoing the secret
 *   TC-4: getMasterAdminToken has no default: it throws without a request when KC_ADMIN_* are unset
 *   TC-5: no 'admin/admin' pair and no 'admin' fallback literal is left in e2e/ or the helper tests
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'
import type { APIRequestContext } from '@playwright/test'

const KEYS = ['UAT_KC_ADMIN_CLIENT_ID', 'UAT_KC_ADMIN_CLIENT_SECRET', 'KC_ADMIN_USER', 'KC_ADMIN_PASSWORD']

function fakeRequest(response: { ok: boolean; status: number; json?: unknown; text?: string }) {
  const post = vi.fn(async () => ({
    ok: () => response.ok,
    status: () => response.status,
    json: async () => response.json,
    text: async () => response.text ?? '',
  }))
  return { request: { post } as unknown as APIRequestContext, post }
}

describe('GH #1995 — e2e admin tokens', () => {
  const saved: Record<string, string | undefined> = {}
  beforeEach(() => {
    for (const k of KEYS) { saved[k] = process.env[k]; delete process.env[k] }
  })
  afterEach(() => {
    for (const k of KEYS) {
      if (saved[k] === undefined) delete process.env[k]
      else process.env[k] = saved[k]
    }
  })

  it('TC-1: client_credentials with the env client to the realm token URL', async () => {
    process.env.UAT_KC_ADMIN_CLIENT_ID = 'uat-seed-admin'
    process.env.UAT_KC_ADMIN_CLIENT_SECRET = 's3cret-value'
    const { getRealmAdminToken } = await import('../../e2e/helpers')
    const { request, post } = fakeRequest({ ok: true, status: 200, json: { access_token: 'tok' } })

    expect(await getRealmAdminToken(request, 'swiftroute')).toBe('tok')

    const [url, options] = post.mock.calls[0] as unknown as [string, { form: Record<string, string> }]
    expect(url).toMatch(/\/realms\/swiftroute\/protocol\/openid-connect\/token$/)
    expect(options.form).toEqual({
      grant_type: 'client_credentials',
      client_id: 'uat-seed-admin',
      client_secret: 's3cret-value',
    })
  })

  it('TC-2: missing env pair -> throws, no request', async () => {
    const { getRealmAdminToken } = await import('../../e2e/helpers')
    const { request, post } = fakeRequest({ ok: true, status: 200, json: { access_token: 'tok' } })
    await expect(getRealmAdminToken(request, 'vortex')).rejects.toThrow(/UAT_KC_ADMIN_CLIENT_ID/)
    expect(post).not.toHaveBeenCalled()
  })

  it('TC-3: failed request -> error without the secret', async () => {
    process.env.UAT_KC_ADMIN_CLIENT_ID = 'uat-seed-admin'
    process.env.UAT_KC_ADMIN_CLIENT_SECRET = 's3cret-value'
    const { getRealmAdminToken } = await import('../../e2e/helpers')
    const { request } = fakeRequest({ ok: false, status: 401, text: 'unauthorized_client' })
    const err = await getRealmAdminToken(request, 'vortex').catch((e: Error) => e)
    expect((err as Error).message).toMatch(/401/)
    expect((err as Error).message).not.toContain('s3cret-value')
  })

  it('TC-4: getMasterAdminToken has no default credential', async () => {
    const { getMasterAdminToken } = await import('../../e2e/helpers')
    const { request, post } = fakeRequest({ ok: true, status: 200, json: { access_token: 'tok' } })
    await expect(getMasterAdminToken(request)).rejects.toThrow(/KC_ADMIN_USER/)
    expect(post).not.toHaveBeenCalled()
  })

  it('TC-5: no admin/admin literal left in the e2e sources', () => {
    const roots = [resolve(__dirname, '../../e2e'), __dirname]
    const files: string[] = []
    const walk = (d: string) => {
      for (const n of readdirSync(d)) {
        const p = join(d, n)
        if (statSync(p).isDirectory()) walk(p)
        else if (/\.tsx?$/.test(n) && p !== __filename) files.push(p)
      }
    }
    roots.forEach(walk)
    const offenders = files.filter(f => {
      const t = readFileSync(f, 'utf8')
      return /admin\/admin/.test(t) || /resolveCredential\('KC_ADMIN_(USER|PASSWORD)', 'admin'\)/.test(t)
    })
    expect(offenders).toEqual([])
  })
})
