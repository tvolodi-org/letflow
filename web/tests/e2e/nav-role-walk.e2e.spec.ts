/**
 * T-1522 / D-114(1) — live-backend sidebar walk: sign in as each role through the real Keycloak login, open every link the
 * sidebar shows and fail on a permission-denied page, an access-error page, a not-found page, or any /api/ response with
 * status 403 fired by the page. Accounts come from E2E_ADMIN_USER/PASSWORD (tenant admin, as Gate B) and
 * E2E_STOREKEEPER_*, E2E_WORKER_*, E2E_SCOPED_* (user and password); a role whose pair is unset is skipped, and the
 * skip reason names the variables. The no-backend twin runs in the unit suite (navRoleWalk.test.tsx).
 */
import { test, expect, type Page } from '@playwright/test'
import { ENV, ROLE_ENV, signIn } from './support/gateB'

async function walk(page: Page): Promise<string[]> {
  const hrefs = await page.locator('nav[aria-label="Main"] a').evaluateAll((as) => as.map((a) => a.getAttribute('href') ?? ''))
  expect(hrefs.length).toBeGreaterThan(0)
  const forbidden: string[] = []
  page.on('response', (r) => {
    if (r.url().includes('/api/') && r.status() === 403) forbidden.push(`${r.status()} ${r.url()}`)
  })
  for (const href of hrefs) {
    await page.locator(`nav[aria-label="Main"] a[href="${href}"]`).click()
    await expect(page.locator('#main-content')).toBeVisible()
    await page.waitForLoadState('networkidle')
    for (const id of ['permission-denied', 'access-error', 'not-found-page']) {
      await expect(page.getByTestId(id), `${href} shows ${id}`).toHaveCount(0)
    }
  }
  return forbidden
}

const ROLES = [
  { name: 'tenant admin', user: ENV.admin, pw: ENV.adminPw, vars: 'E2E_ADMIN_USER / E2E_ADMIN_PASSWORD' },
  { name: 'storekeeper', user: ROLE_ENV.storekeeper.user, pw: ROLE_ENV.storekeeper.pw, vars: 'E2E_STOREKEEPER_USER / E2E_STOREKEEPER_PASSWORD' },
  { name: 'task worker', user: ROLE_ENV.worker.user, pw: ROLE_ENV.worker.pw, vars: 'E2E_WORKER_USER / E2E_WORKER_PASSWORD' },
  { name: 'scoped user', user: ROLE_ENV.scoped.user, pw: ROLE_ENV.scoped.pw, vars: 'E2E_SCOPED_USER / E2E_SCOPED_PASSWORD' },
]

for (const role of ROLES) {
  test(`sidebar walk, ${role.name}: no visible entry is refused`, async ({ page }) => {
    test.skip(role.user === '' || role.pw === '', `${role.vars} are not set`)
    await signIn(page, role.user, role.pw)
    const forbidden = await walk(page)
    expect(forbidden, 'API answers with 403 after a click').toEqual([])
  })
}
