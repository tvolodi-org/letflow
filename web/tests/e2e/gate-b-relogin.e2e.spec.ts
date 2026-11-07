/**
 * T-1383 (operator note for T-1400) — the session survives access-token expiry, checked in a real browser against the
 * REAL identity provider (the T-1400 spec relogin-token-expiry stubs the IdP and the API).
 *
 *  R1  a refresh_token grant is POSTed to the token endpoint before the access token expires, and during 3 token lifespans
 *      of read-only activity the browser never navigates to the IdP's authorize page again.
 *  R2  one 401 from the API leads to exactly one renew and a replay of the request, not to a logout.
 *
 * Needs a realm with a short access token lifespan: the CI stack sets 90 s (scripts/e2e/stack_up.sh; 90 and not 60 because
 * oidc-client-ts renews 60 s before expiry, so 60 s would refresh at once and show nothing). On QA use a realm with the
 * Keycloak default (5 min), NOT the gate-b3 realm (30 min): the spec then takes 3 x 5 min. Opt-in: E2E_RELOGIN=1.
 * E2E_TOKEN_LIFESPAN tells the spec how long to budget (default 90); the real lifespan is read from the first token response.
 * The network log (no tokens, no passwords) goes to test-results/gate-b-relogin.log.
 */
import { test, expect, type Page } from '@playwright/test'
import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { ENV, hasAdmin, signIn, SKIP_REASON } from './support/gateB'

const LOG = 'test-results/gate-b-relogin.log'
const LIFESPANS = Number(process.env.E2E_RELOGIN_LIFESPANS ?? 3)
const BUDGET_L = Number(process.env.E2E_TOKEN_LIFESPAN ?? 90)
const MAX_LIFESPAN_S = 600

test.skip(!hasAdmin, SKIP_REASON)
test.skip(process.env.E2E_RELOGIN !== '1', 'set E2E_RELOGIN=1 to run the real-IdP relogin check (it takes about 3 token lifespans)')

interface Net {
  t0: number
  lifespan: number
  grants: { type: string; atS: number }[]
  authorizeNav: number
  api401: number
  replayOk: number
}

function watch(page: Page): Net {
  mkdirSync('test-results', { recursive: true })
  writeFileSync(LOG, '')
  const log = (line: string) => appendFileSync(LOG, `${new Date().toISOString()} ${line}\n`)
  const net: Net = { t0: Date.now(), lifespan: 0, grants: [], authorizeNav: 0, api401: 0, replayOk: 0 }
  page.on('request', (req) => {
    if (req.method() === 'POST' && req.url().includes('/protocol/openid-connect/token')) {
      const type = new URLSearchParams(req.postData() ?? '').get('grant_type') ?? '?'
      net.grants.push({ type, atS: Math.round((Date.now() - net.t0) / 1000) })
      log(`IDP token grant=${type}`)
    }
  })
  page.on('response', async (res) => {
    const url = res.url()
    if (res.request().method() === 'POST' && url.includes('/protocol/openid-connect/token')) {
      const body = (await res.json().catch(() => ({}))) as { expires_in?: number }
      if (net.lifespan === 0 && typeof body.expires_in === 'number') net.lifespan = body.expires_in
      log(`IDP token -> ${res.status()} expires_in=${body.expires_in ?? '?'}`)
    } else if (url.includes('/api/')) {
      if (res.status() === 401) net.api401 += 1
      log(`API ${res.request().method()} ${new URL(url).pathname} -> ${res.status()}`)
    }
  })
  page.on('framenavigated', (f) => {
    if (f !== page.mainFrame()) return
    const u = f.url()
    log(`NAVIGATE ${u.split('?')[0]}`)
    if (u.includes('/protocol/openid-connect/auth')) net.authorizeNav += 1
  })
  return net
}

const ROUTES = ['/admin/stock/balances', '/admin/stock/movements', '/admin/stock/documents']

/** A client-side navigation: fresh list GETs without a page reload (the token stays in memory). */
async function goClientSide(page: Page, path: string): Promise<void> {
  await page.evaluate((p) => {
    window.history.pushState({}, '', p)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, path)
}

test.describe('GATE B relogin on the real IdP', () => {
  test('R1 real refresh before expiry, no redirect in 3 lifespans', async ({ page }) => {
    test.setTimeout(BUDGET_L * LIFESPANS * 1000 + 240_000)
    const net = watch(page)
    await signIn(page, ENV.admin, ENV.adminPw)
    net.t0 = Date.now()
    net.grants.length = 0
    await expect.poll(() => net.lifespan, { timeout: 15_000 }).toBeGreaterThan(0)
    test.skip(net.lifespan > MAX_LIFESPAN_S, `access token lifespan is ${net.lifespan} s: too long to show a refresh in reasonable time`)
    const authorizeBefore = net.authorizeNav

    const until = Date.now() + net.lifespan * LIFESPANS * 1000
    for (let i = 0; Date.now() < until; i++) {
      await goClientSide(page, ROUTES[i % ROUTES.length])
      await expect(page.locator('#main-content')).toBeVisible()
      await page.waitForTimeout(10_000) // the intended soak: read-only activity across token lifespans
    }

    const refreshes = net.grants.filter((g) => g.type === 'refresh_token')
    expect(refreshes.length, 'refresh grants over the soak').toBeGreaterThanOrEqual(LIFESPANS - 1)
    expect(refreshes[0].atS, 'first refresh before the access token expires').toBeLessThan(net.lifespan)
    expect(net.authorizeNav - authorizeBefore, 'navigations to the IdP authorize page after sign-in').toBe(0)
    expect(page.url()).not.toContain('/login')
    await expect(page.locator('#main-content')).toBeVisible()
  })

  test('R2 one 401 one renew and replay, no logout', async ({ page }) => {
    test.setTimeout(BUDGET_L * 1000 + 240_000)
    const net = watch(page)
    await signIn(page, ENV.admin, ENV.adminPw)
    await expect.poll(() => net.lifespan, { timeout: 15_000 }).toBeGreaterThan(0)
    test.skip(net.lifespan > MAX_LIFESPAN_S, `access token lifespan is ${net.lifespan} s: too long`)
    const authorizeBefore = net.authorizeNav

    // arm right after the scheduled renew, so the next one is a lifespan - 60 s away and cannot be mistaken for the replay's
    await expect.poll(() => net.grants.filter((g) => g.type === 'refresh_token').length, { timeout: net.lifespan * 1000 }).toBeGreaterThan(0)
    let rejected = 0
    await page.route('**/api/v1/**', async (route) => {
      if (rejected === 0 && route.request().method() === 'GET') {
        rejected += 1
        return route.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ title: 'unauthorized' }) })
      }
      return route.continue()
    })
    const grantsBefore = net.grants.filter((g) => g.type === 'refresh_token').length
    await goClientSide(page, '/admin/stock/movements')
    await expect.poll(() => rejected, { timeout: 15_000 }).toBe(1)
    await expect.poll(() => net.grants.filter((g) => g.type === 'refresh_token').length, { timeout: 20_000 }).toBe(grantsBefore + 1)
    await page.waitForTimeout(3_000)

    expect(net.grants.filter((g) => g.type === 'refresh_token').length - grantsBefore, 'renews for one 401').toBe(1)
    expect(net.authorizeNav - authorizeBefore, 'navigations to the IdP after the 401').toBe(0)
    await expect(page.locator('#main-content')).toBeVisible()
    // the replayed request answered, the screen shows data (not the error banner)
    await expect(page.locator('main, #main-content').first()).not.toContainText(/sign in again|session expired/i)
  })
})
