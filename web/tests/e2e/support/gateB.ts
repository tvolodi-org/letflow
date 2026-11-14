/**
 * Shared helpers of the GATE B browser specs (gate-b-stock, gate-b-relogin). Everything comes from the environment so the
 * same specs run against the local CI stack and against QA:
 *   E2E_BASE_URL (web, default http://127.0.0.1:4173)   E2E_REALM (optional ?realm= for hosts that need it)
 *   E2E_ADMIN_USER / E2E_ADMIN_PASSWORD                 E2E_ADMIN2_USER / E2E_ADMIN2_PASSWORD (second approver)
 *   E2E_RUN_TAG (default e2e<timestamp>)                E2E_SHOTS_DIR (default test-results/gate-b-shots)
 * No credential has a default here; the CI stack script writes its throwaway ones into the environment.
 */
import { expect, type Locator, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

export const ENV = {
  admin: process.env.E2E_ADMIN_USER ?? '',
  adminPw: process.env.E2E_ADMIN_PASSWORD ?? '',
  admin2: process.env.E2E_ADMIN2_USER ?? '',
  admin2Pw: process.env.E2E_ADMIN2_PASSWORD ?? '',
  realm: process.env.E2E_REALM ?? '',
  runTag: process.env.E2E_RUN_TAG ?? `e2e${Date.now().toString(36)}`,
  shotsDir: process.env.E2E_SHOTS_DIR ?? 'test-results/gate-b-shots',
}

const ENV_BASE = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4173'

export const SKIP_REASON = 'E2E_ADMIN_USER / E2E_ADMIN_PASSWORD are not set (no stack to run against)'
export const hasAdmin = ENV.admin !== '' && ENV.adminPw !== ''

/** Sign in through the real Keycloak hosted login page and wait for the app shell. */
export async function signIn(page: Page, user: string, password: string): Promise<void> {
  await page.goto(ENV.realm ? `/?realm=${encodeURIComponent(ENV.realm)}` : '/', { waitUntil: 'domcontentloaded' })
  const appOrigin = new URL(page.url()).origin
  await page.waitForURL((url) => url.origin !== appOrigin, { timeout: 30_000 })
  await page.fill('#username', user)
  await page.fill('#password', password)
  await Promise.all([
    page.waitForURL((url) => url.origin === appOrigin, { timeout: 30_000 }),
    page.locator('#kc-login, input[type="submit"]').first().click(),
  ])
  await expect(page.locator('#main-content')).toBeVisible({ timeout: 30_000 })
}

/** Set the saved language and theme (same keys as the app: lf-locale, lf-theme) and reload so they apply. */
export async function setPrefs(page: Page, prefs: { lang?: 'en' | 'ru' | 'kk'; theme?: 'light' | 'dark' }): Promise<void> {
  await page.evaluate((p) => {
    if (p.lang) window.localStorage.setItem('lf-locale', p.lang)
    if (p.theme) window.localStorage.setItem('lf-theme', p.theme)
  }, prefs)
  await page.reload({ waitUntil: 'domcontentloaded' })
  await expect(page.locator('#main-content')).toBeVisible({ timeout: 30_000 })
}

/**
 * Open a route (a path, or a full URL of the app) of the SPA inside the signed-in session.
 * A full load of a deep link loses its path when no realm slug is resolvable (the CI stack sets none; buildRedirectArgs
 * then drops the OIDC state and the callback lands on "/", T-1736). So: when the shell is already up, move inside the
 * SPA (pushState plus a popstate, which the router listens to) without any reload; for the first open, load once, and if
 * the path was lost, move inside the SPA the same way. Every deep link of the specs goes through here.
 */
export async function openRoute(page: Page, path: string): Promise<void> {
  const base = page.url() === 'about:blank' ? ENV_BASE : page.url()
  const target = new URL(path, base)
  const rel = `${target.pathname}${target.search}${target.hash}`
  const shellUp = page.url() !== 'about:blank' && new URL(page.url()).origin === target.origin
    && (await page.locator('#main-content').isVisible().catch(() => false))
  if (!shellUp) {
    await page.goto(rel, { waitUntil: 'domcontentloaded' })
    await expect(page.locator('#main-content')).toBeVisible({ timeout: 30_000 })
    try {
      await page.waitForURL((url) => url.pathname === target.pathname, { timeout: 8_000 })
      return
    } catch {
      // landed on the dashboard: continue inside the SPA
    }
  }
  await page.evaluate((to) => {
    window.history.pushState({}, '', to)
    window.dispatchEvent(new PopStateEvent('popstate', { state: {} }))
  }, rel)
  await expect(page).toHaveURL((url) => url.pathname === target.pathname)
}

/** Pick an option of a native select by (part of) its text; no text = the first real option. */
export async function choose(select: Locator, text?: string): Promise<void> {
  await expect(select).toBeVisible()
  if (text) {
    // options load asynchronously (pickers read the first 200 records): wait for the one we want
    await expect(select.locator('option', { hasText: text }).first()).toBeAttached({ timeout: 20_000 })
    const label = await select.locator('option', { hasText: text }).first().textContent()
    await select.selectOption({ label: label ?? text })
    return
  }
  await expect.poll(async () => select.locator('option').count(), { timeout: 20_000 }).toBeGreaterThan(1)
  const value = await select.locator('option:not([value=""])').first().getAttribute('value')
  await select.selectOption(value ?? '')
}

export function shotPath(name: string): string {
  mkdirSync(ENV.shotsDir, { recursive: true })
  return `${ENV.shotsDir}/${name}.png`
}

/** Local `YYYY-MM-DDTHH:mm` offset from now by `hours` (value of a datetime-local input). */
export function localDateTime(hours: number): string {
  const d = new Date(Date.now() + hours * 3_600_000)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`
}

/** Per-role accounts of the sidebar walk (nav-role-walk.e2e.spec.ts, T-1522); each live test skips when its pair is unset. */
export const ROLE_ENV = {
  storekeeper: { user: process.env.E2E_STOREKEEPER_USER ?? '', pw: process.env.E2E_STOREKEEPER_PASSWORD ?? '' },
  worker: { user: process.env.E2E_WORKER_USER ?? '', pw: process.env.E2E_WORKER_PASSWORD ?? '' },
  scoped: { user: process.env.E2E_SCOPED_USER ?? '', pw: process.env.E2E_SCOPED_PASSWORD ?? '' },
}

/** The document number from the header card (the value after the "Number" label). */
export async function headerNumber(p: Page): Promise<string> {
  const text = (await p.getByTestId('document-header').innerText()).replace(/\s+/g, ' ')
  return /([A-Z]{1,6}[-/]?\d[\w-]*)/.exec(text)?.[1] ?? ''
}

export async function saveDocument(p: Page): Promise<void> {
  await p.getByRole('button', { name: 'Save draft' }).click()
  await expect(p.getByTestId('document-header')).toBeVisible({ timeout: 30_000 })
  await expect(p.getByTestId('document-actions')).toBeVisible()
}

export async function issueDocument(p: Page): Promise<void> {
  await p.getByTestId('document-actions').getByRole('button', { name: 'Issue', exact: true }).click()
  await p.getByRole('dialog').getByRole('button', { name: 'Issue', exact: true }).click()
  await expect(p.getByTestId('document-header')).toContainText(/Issued|Posted/i, { timeout: 30_000 })
}

/** Claim then complete the task row that matches `hint` (document number or item name). */
export async function claimAndComplete(p: Page, hint: string): Promise<void> {
  // The approval task of a freshly issued document is created after the issue call returns, so it can be missing from
  // the first load of the list. Wait (reloading) for the row of THIS document; never fall back to the first row: that is
  // another document's task, and completing it leaves this one unposted.
  const own = p.getByTestId('task-row').filter({ hasText: hint })
  await expect(async () => {
    await openRoute(p, '/tasks')
    await expect(own.first()).toBeVisible({ timeout: 5_000 })
  }).toPass({ timeout: 60_000, intervals: [1_000, 2_000, 4_000] })
  await own.first().click()
  await expect(p.getByTestId('task-detail-panel')).toBeVisible()
  const claim = p.getByTestId('task-claim-button')
  if (await claim.isVisible().catch(() => false)) await claim.click()
  // R11: Complete appears after the claim
  await expect(p.getByTestId('task-complete-button')).toBeVisible({ timeout: 20_000 })
  const done = p.waitForResponse(r => r.request().method() === 'POST' && /complete/.test(r.url()) && r.ok(), { timeout: 30_000 })
  await p.getByTestId('task-complete-button').click()
  // Wait for the completion to reach the server before the caller navigates away (a cancelled request leaves it open).
  await done
}
