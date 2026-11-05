/**
 * T-1400 — the session survives access-token expiry: no redirect to the IdP, no re-login.
 *
 * The identity provider is a STUB (page.route): authorize -> 302 to /auth/callback, token endpoint ->
 * a fresh unsigned JWT with `expires_in: 70`, so the first refresh is due 10 s after sign-in
 * (oidc-client-ts raises accessTokenExpiring 60 s before expiry). The API stub answers 200 only to the
 * most recently issued access token and 401 to any older one, like a real resource server.
 *
 * Red proof of the root cause (getOidcManager race): with web/src/auth/OidcManager.ts reverted the
 * manager that receives the token has no expiry handler, so NO refresh grant appears and the first
 * test fails on the "first refresh" assertion.
 *
 * Writes the network log (requests to the IdP, API statuses, 401s, navigations; never tokens) to
 * tests/screenshots/relogin-network.log.
 */
import { test, expect, type Page } from '@playwright/test'
import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs'

const LOG = 'tests/screenshots/relogin-network.log'
const IDP = 'http://localhost:8082/realms/bpm-default'
const EXPIRES_IN = 70

function b64(o: unknown): string {
  return Buffer.from(JSON.stringify(o)).toString('base64url')
}

interface Idp {
  authorizeCount: number
  grants: { type: string; atMs: number }[]
  issued: string[]
  api401: number
  navigations: string[]
  rejectCurrentOnce: boolean
  t0: number
}

async function installStubs(page: Page): Promise<Idp> {
  mkdirSync('tests/screenshots', { recursive: true })
  writeFileSync(LOG, '')
  const log = (line: string) => appendFileSync(LOG, `${new Date().toISOString()} ${line}\n`)
  const idp: Idp = { authorizeCount: 0, grants: [], issued: [], api401: 0, navigations: [], rejectCurrentOnce: false, t0: Date.now() }

  const issue = () => {
    const token = `${b64({ alg: 'none' })}.${b64({ sub: 'u1', roles: ['TENANT_ADMIN'], n: idp.issued.length })}.sig`
    idp.issued.push(token)
    return token
  }

  await page.route('**/api/tenant-config*', r =>
    r.fulfill({ json: { oidc_authority: IDP, client_id: 'letflow-web' } }),
  )
  await page.route(`${IDP}/protocol/openid-connect/auth*`, r => {
    idp.authorizeCount += 1
    const url = new URL(r.request().url())
    const state = url.searchParams.get('state') ?? ''
    log(`IDP authorize #${idp.authorizeCount}`)
    return r.fulfill({ status: 302, headers: { Location: `http://127.0.0.1:4173/auth/callback?code=c1&state=${state}` } })
  })
  await page.route(`${IDP}/protocol/openid-connect/token`, r => {
    const body = r.request().postData() ?? ''
    const type = new URLSearchParams(body).get('grant_type') ?? '?'
    idp.grants.push({ type, atMs: Date.now() - idp.t0 })
    log(`IDP token grant=${type} -> 200`)
    return r.fulfill({
      headers: { 'Access-Control-Allow-Origin': '*' },
      json: {
        access_token: issue(),
        token_type: 'Bearer',
        expires_in: EXPIRES_IN,
        refresh_token: `r${idp.issued.length}`,
      },
    })
  })
  await page.route('**/api/**', r => {
    const url = new URL(r.request().url())
    if (url.pathname.endsWith('/tenant-config')) return r.fallback()
    const auth = r.request().headers()['authorization'] ?? ''
    const current = idp.issued[idp.issued.length - 1]
    const ok = auth === `Bearer ${current}` && !idp.rejectCurrentOnce
    if (idp.rejectCurrentOnce && auth === `Bearer ${current}`) idp.rejectCurrentOnce = false
    log(`API ${r.request().method()} ${url.pathname} -> ${ok ? 200 : 401}`)
    if (!ok) {
      idp.api401 += 1
      return r.fulfill({ status: 401, json: { title: 'unauthorized' } })
    }
    if (url.pathname.endsWith('/me/access')) {
      return r.fulfill({ json: { roles: [], permissions: [], platform_tenant: false } })
    }
    return r.fulfill({ json: {} })
  })
  page.on('framenavigated', f => {
    if (f === page.mainFrame()) {
      idp.navigations.push(f.url())
      log(`NAVIGATE ${f.url()}`)
    }
  })
  return idp
}

test.describe('T-1400 session survives token expiry', () => {
  test('E2E-01: refreshes ~60 s before expiry, repeatedly, with no redirect', async ({ page }) => {
    test.setTimeout(120_000)
    const idp = await installStubs(page)
    await page.goto('/instances')
    await expect(page.locator('#main-content')).toBeVisible({ timeout: 20_000 })
    const signedInAt = Date.now()
    const urlAfterLogin = page.url()

    await page.waitForTimeout(45_000)

    const refreshes = idp.grants.filter(g => g.type === 'refresh_token')
    // first refresh about expires_in - 60 s (= 10 s) after sign-in, +-5 s
    const loginGrantAt = idp.grants.find(g => g.type === 'authorization_code')!.atMs
    expect(refreshes.length).toBeGreaterThanOrEqual(3)
    const first = (refreshes[0].atMs - loginGrantAt) / 1000
    expect(first).toBeGreaterThan(5)
    expect(first).toBeLessThan(15)
    expect(idp.authorizeCount).toBe(1)
    expect(page.url()).toBe(urlAfterLogin)
    await expect(page.locator('#main-content')).toBeVisible()
    expect(Date.now() - signedInAt).toBeGreaterThan(44_000)
  })

  test('E2E-02: one 401 is refreshed and replayed, the user stays signed in', async ({ page }) => {
    test.setTimeout(60_000)
    const idp = await installStubs(page)
    await page.goto('/instances')
    await expect(page.locator('#main-content')).toBeVisible({ timeout: 20_000 })
    expect(idp.authorizeCount).toBe(1)
    const grantsBefore = idp.grants.length

    idp.rejectCurrentOnce = true
    // client-side navigation: fires fresh API calls without a page reload
    await page.evaluate(() => {
      window.history.pushState({}, '', '/tasks')
      window.dispatchEvent(new PopStateEvent('popstate'))
    })
    await expect.poll(() => idp.api401, { timeout: 15_000 }).toBeGreaterThanOrEqual(1)
    await expect.poll(() => idp.grants.length, { timeout: 15_000 }).toBeGreaterThan(grantsBefore)
    await page.waitForTimeout(2_000)

    expect(idp.authorizeCount).toBe(1)
    await expect(page.locator('#main-content')).toBeVisible()
  })
})
