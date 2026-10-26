/**
 * E2E -- REQ-438: email-first login against a real Keycloak with two tenants'
 * realms. A user of one tenant types only their email on /login and arrives at
 * THAT tenant's realm login with the username field pre-filled (login_hint).
 *
 * Prerequisites (this suite uses no mocks or stubs and fails fast, like the
 * sibling ISS-0063/ISS-0726 suites, when they are missing):
 *   - the SPA under test was BUILT with VITE_EMAIL_FIRST_LOGIN=true;
 *   - the backend runs with LETFLOW_LOGIN_DISCOVERY_ENABLED=true and the
 *     directory populated (REQ-435/REQ-440 write path or backfill);
 *   - E2E_EMAIL_FIRST_EMAIL: the email of a user who belongs to exactly one
 *     tenant, and E2E_EMAIL_FIRST_REALM_SLUG: that tenant's slug (the realm
 *     the browser must land on), in a deployment with at least two tenant
 *     realms;
 *   - that realm has "Login with email" enabled (design req434 section 8.3).
 *
 * KNOWN INFRASTRUCTURE GAP (the ISS-0727 class): this repository's local stack
 * does not provision two tenant realms plus a populated directory, so this spec
 * could not be executed by the author. It is recorded, not run.
 */
import { test, expect } from '@playwright/test'
import { BPM_IDP_BASE_URL } from './helpers'

function requireEnv(name: string, value: string | undefined): string {
  if (!value) {
    throw new Error(`REQ-438 prerequisite not satisfied: ${name} is missing`)
  }
  return value
}

test.describe('REQ-438 email-first login', () => {
  // BilimBaga study T3b (B3): "unauthenticated visitor lands on /login". Needs only the
  // flag-on build from the prerequisites above, no tenant email or realm.
  test('an unauthenticated visitor to a protected route lands on /login', async ({ page }) => {
    await page.goto('/instances')
    await expect(page).toHaveURL(/\/login$/, { timeout: 15_000 })
    await expect(page.getByTestId('login-page')).toBeVisible()
    await expect(page.getByTestId('login-email-form')).toBeVisible()
  })

  test('a single-tenant user lands on their own realm login with the username pre-filled', async ({ page }) => {
    const email = requireEnv('E2E_EMAIL_FIRST_EMAIL', process.env.E2E_EMAIL_FIRST_EMAIL)
    const slug = requireEnv('E2E_EMAIL_FIRST_REALM_SLUG', process.env.E2E_EMAIL_FIRST_REALM_SLUG)
    const idpBase = requireEnv('BPM_IDP_BASE_URL', BPM_IDP_BASE_URL)

    // Unauthenticated, no realm known: the screen, not a default-realm redirect.
    await page.goto('/')
    await expect(page).toHaveURL(/\/login$/)
    await expect(page.getByTestId('login-page')).toBeVisible()
    await expect(page.locator('input[type=password]')).toHaveCount(0)

    await page.getByTestId('login-page').locator('input[name="email"]').fill(email)
    await page.getByTestId('login-submit').click()

    // Keycloak's hosted login for that tenant's realm, username pre-filled.
    await page.waitForURL(new RegExp(`^${idpBase.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/realms/`), {
      timeout: 20_000,
    })
    const realmInUrl = new URL(page.url()).pathname.split('/realms/')[1]?.split('/')[0]
    expect(realmInUrl).toBeTruthy()
    const usernameInput = page.locator('input#username, input[name="username"]').first()
    await expect(usernameInput).toBeVisible({ timeout: 20_000 })
    await expect(usernameInput).toHaveValue(email)

    // The redirect carried the realm so the callback can identify it (ISS-0726).
    const authUrl = new URL(page.url())
    expect(authUrl.searchParams.get('login_hint')).toBe(email)
    expect(decodeURIComponent(authUrl.searchParams.get('redirect_uri') ?? '')).toContain(`?realm=${slug}`)
  })
})
