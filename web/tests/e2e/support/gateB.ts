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

/** Open a route of the SPA inside the signed-in session (full load; the OIDC session is restored from storage). */
export async function openRoute(page: Page, path: string): Promise<void> {
  const wanted = new URL(path, page.url() === 'about:blank' ? ENV_BASE : page.url()).pathname
  // A full load may go through the OIDC callback, which lands on the dashboard before the route is open (seen on the
  // Vite dev server in CI, T-1448): ask again, the session is stored by then.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await page.goto(path, { waitUntil: 'domcontentloaded' })
    await expect(page.locator('#main-content')).toBeVisible({ timeout: 30_000 })
    try {
      await page.waitForURL((url) => url.pathname === wanted, { timeout: 8_000 })
      return
    } catch {
      // not there yet: load it again
    }
  }
  // Still on the dashboard: a full load of a deep link loses its path when no realm slug is resolvable (the CI stack sets
  // none; buildRedirectArgs then drops the OIDC state and the callback lands on "/", T-1736). The shell is up and signed
  // in, so move inside the SPA instead: push the path and let the router see a popstate.
  await page.evaluate((to) => {
    window.history.pushState({}, '', to)
    window.dispatchEvent(new PopStateEvent('popstate', { state: {} }))
  }, path)
  await expect(page).toHaveURL(new RegExp(`${wanted.replace(/[/]/g, '\\/')}$`))
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
