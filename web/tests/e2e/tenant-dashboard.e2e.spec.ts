/**
 * E2E tests — TD-UI-01 (Tenant-scoped landing page), TD-UI-02 (Tenant identity indicator),
 *             TD-UI-03 (Tenant realm routing).
 * Run: WF02-tenant-dashboard-20260616
 *
 * DIRECTIVE T-2 compliance:
 *   - No MSW, no axios-mock-adapter, no manual fetch intercepts, no page.route() stubs.
 *   - Tenant display_name is fetched via real GET /api/v1/tenants/:slug API call before
 *     each test that needs it. No value is hard-coded; it comes from the live backend.
 *   - Authentication uses Keycloak password grant (real token, real realm).
 *   - Session is injected via sessionStorage (the documented E2E bridge in AuthProvider).
 *
 * DIRECTIVE T-3 compliance:
 *   - After every significant UI action a screenshot is taken.
 *   - Verdicts are stated as "screen shows X after Y" — never "no error was thrown".
 *
 * Infrastructure:
 *   - Frontend: http://127.0.0.1:4173 (Vite dev server, playwright.config.ts)
 *   - Backend API: http://127.0.0.1:8080 (env BPM_TEST_URL)
 *   - Keycloak: http://localhost:8082 (env BPM_IDP_BASE_URL)
 *   - Test user: admin-user / admin-pass (PLATFORM_ADMIN, bpm-default realm)
 */

import { test, expect } from '@playwright/test'
import type { APIRequestContext, Page } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'
import { getKeycloakToken, assertServiceReadiness } from './helpers'
import { navigateSpa } from './pipeline'

// ── Config ────────────────────────────────────────────────────────────────────

const SCREENSHOTS_DIR = 'tests/screenshots'
const TEST_ADMIN_USER = process.env.TEST_ADMIN_USER ?? 'admin-user'
const TEST_ADMIN_PASSWORD = process.env.TEST_ADMIN_PASSWORD ?? 'admin-pass'
const API_BASE_URL = (process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080').replace(/\/$/, '')

// ── Screenshot helper ─────────────────────────────────────────────────────────

function shotPath(name: string): string {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, `TD-${name}.png`)
}

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: shotPath(name), fullPage: true })
}

// ── Login helpers ─────────────────────────────────────────────────────────────

/**
 * Decode JWT payload without verification (E2E use only).
 */
function decodeJwt(token: string): {
  sub: string
  iss?: string
  preferred_username?: string
  name?: string
  email?: string
} {
  return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf-8'))
}

/**
 * Log in to the app with full tenant context injected into sessionStorage.
 *
 * Makes a real GET /api/v1/tenants/:slug API call to resolve the tenant display_name.
 * DIRECTIVE T-2 compliant — no hard-coded display names, all values from the live backend.
 *
 * @param page        - Playwright Page
 * @param request     - Playwright API request context (for real API calls)
 * @param token       - Keycloak access token (from password grant)
 * @param tenantSlug  - Tenant slug (e.g. 'default', 'swiftroute')
 * @returns           - Resolved { tenantDisplayName }
 */
async function loginWithTenantToken(
  page: Page,
  request: APIRequestContext,
  token: string,
  tenantSlug: string,
): Promise<{ tenantDisplayName: string }> {
  // Real API call — DIRECTIVE T-2 compliant
  const tenantResp = await request.get(`${API_BASE_URL}/api/v1/tenants/${tenantSlug}`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  if (!tenantResp.ok()) {
    throw new Error(
      `Tenant lookup failed for slug '${tenantSlug}' (${tenantResp.status()}). ` +
      `Ensure the tenant is onboarded before running this test.`,
    )
  }
  const tenantData = await tenantResp.json() as { display_name: string; tenant_id: string }
  const tenantDisplayName = tenantData.display_name

  const payload = decodeJwt(token)
  const displayName = payload.preferred_username ?? payload.name ?? payload.email ?? payload.sub

  await page.addInitScript(
    (args: {
      token: string
      displayName: string
      tenantSlug: string
      tenantDisplayName: string
    }) => {
      sessionStorage.setItem(
        '__e2e_session',
        JSON.stringify({
          token: args.token,
          display_name: args.displayName,
          loginSource: 'oidc' as const,
          tenant_slug: args.tenantSlug,
          tenant_display_name: args.tenantDisplayName,
        }),
      )
    },
    { token, displayName, tenantSlug, tenantDisplayName },
  )

  await page.goto('/', { waitUntil: 'domcontentloaded' })
  // Wait for AppShell to render (proves the authenticated session was accepted)
  await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 }).catch(() => {})

  return { tenantDisplayName }
}

/**
 * Log in without injecting tenant context — simulates a session where
 * `tenant_display_name` is null (isUnknown === true in useTenantContext).
 *
 * Used by TC-TD-UI-01-02 to verify the "Unknown workspace" fallback path.
 */
async function loginWithoutTenantContext(page: Page, token: string): Promise<void> {
  const payload = decodeJwt(token)
  const displayName = payload.preferred_username ?? payload.name ?? payload.email ?? payload.sub

  await page.addInitScript(
    (args: { token: string; displayName: string }) => {
      // Intentionally omit tenant_slug and tenant_display_name
      sessionStorage.setItem(
        '__e2e_session',
        JSON.stringify({
          token: args.token,
          display_name: args.displayName,
          loginSource: 'oidc' as const,
        }),
      )
    },
    { token, displayName },
  )

  await page.goto('/', { waitUntil: 'domcontentloaded' })
  await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 }).catch(() => {})
}

// ── TD-UI-01: Tenant-scoped landing page ─────────────────────────────────────

test.describe('TD-UI-01 — Tenant-scoped landing page', () => {

  /**
   * TC-TD-UI-01-01
   * Verify that after login the dashboard heading shows the tenant display_name
   * fetched from the real backend (not a hard-coded value).
   */
  test('TC-TD-UI-01-01: dashboard heading shows tenant display_name after login', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const token = await getKeycloakToken(request, TEST_ADMIN_USER, TEST_ADMIN_PASSWORD)
    const { tenantDisplayName } = await loginWithTenantToken(page, request, token, 'default')

    await navigateSpa(page, '/dashboard')
    await shot(page, 'UI-01-01-dashboard-heading')

    // VERDICT: Screen shows the tenant display_name as the dashboard <h1> heading.
    const heading = page.getByTestId('tenant-dashboard-heading')
    await expect(heading).toBeVisible()
    await expect(heading).toContainText(tenantDisplayName)

    // Dashboard data tiles must be visible (tenant-scoped content rendered)
    await expect(page.getByTestId('tile-definitions')).toBeVisible()
    await expect(page.getByTestId('tile-instances')).toBeVisible()
    await expect(page.getByTestId('tile-tasks')).toBeVisible()
  })

  /**
   * TC-TD-UI-01-02
   * Verify that when the session lacks tenant_display_name the dashboard shows
   * "Unknown workspace" and the amber warning banner (isUnknown === true path).
   */
  test('TC-TD-UI-01-02: unknown workspace shows fallback heading and banner when tenant_display_name is absent', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const token = await getKeycloakToken(request, TEST_ADMIN_USER, TEST_ADMIN_PASSWORD)
    // Login without tenant context — tenant_display_name is null in session
    await loginWithoutTenantContext(page, token)

    await navigateSpa(page, '/dashboard')
    await shot(page, 'UI-01-02-unknown-workspace-fallback')

    // VERDICT: Screen shows "Unknown workspace" as the heading, plus the amber warning banner.
    const heading = page.getByTestId('tenant-dashboard-heading')
    await expect(heading).toBeVisible()
    await expect(heading).toContainText('Unknown workspace')

    const banner = page.getByTestId('tenant-unknown-banner')
    await expect(banner).toBeVisible()

    // The sidebar shows the "unknown" variant (not the normal tenant-display-name)
    await expect(page.getByTestId('tenant-display-name-unknown')).toBeVisible()
    await expect(page.getByTestId('tenant-display-name')).not.toBeVisible()
  })

  /**
   * TC-TD-UI-01-03
   * Verify that the first authenticated route rendered after a successful OIDC login
   * is /dashboard, not any intermediate or alternate page.
   *
   * REQUIRES_FULL_STACK: requires backend + Keycloak running. Session injection
   * (via __e2e_session) simulates the state AuthProvider reaches immediately after
   * the real OIDC callback succeeds.
   */
  test('TC-TD-UI-01-03: dashboard is the first route rendered after OIDC login', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const token = await getKeycloakToken(request, TEST_ADMIN_USER, TEST_ADMIN_PASSWORD)
    await loginWithTenantToken(page, request, token, 'default')

    // After session injection the AuthProvider should redirect the authenticated
    // user from ’/’ to ’/dashboard’. Wait for that navigation to settle.
    await page.waitForURL('**/dashboard', { timeout: 10_000 })
    await shot(page, 'UI-01-03-first-route-after-callback')

    // VERDICT: First screenshot after login shows the /dashboard route with tenant heading.
    expect(page.url()).toContain('/dashboard')
    const heading = page.getByTestId('tenant-dashboard-heading')
    await expect(heading).toBeVisible()
  })

  /**
   * TC-TD-UI-01-04
   * Verify that the dashboard data tiles are scoped to the logged-in tenant.
   *
   * PREREQUISITE: The 'swiftroute' tenant must exist in the database for the
   * cross-tenant isolation assertion. Fails with a clear message otherwise —
   * if swiftroute is not provisioned, the leakage assertion cannot run and the
   * test must not report a false pass. Run the swiftroute tenant onboarding
   * pipeline (sim-company-onboarding.pipeline.e2e.spec.ts) before this test.
   */
  test('TC-TD-UI-01-04: dashboard data tiles show only tenant-scoped results', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const token = await getKeycloakToken(request, TEST_ADMIN_USER, TEST_ADMIN_PASSWORD)
    const { tenantDisplayName } = await loginWithTenantToken(page, request, token, 'default')

    await navigateSpa(page, '/dashboard')
    await shot(page, 'UI-01-04-dashboard-scoped-tiles')

    // VERDICT: Heading shows only the logged-in tenant (default), not a foreign tenant.
    const heading = page.getByTestId('tenant-dashboard-heading')
    await expect(heading).toBeVisible()
    await expect(heading).toContainText(tenantDisplayName)

    // Cross-tenant leakage check: resolve swiftroute's display_name and assert it does
    // NOT appear anywhere in the data tiles. Hard-fails if swiftroute isn't provisioned —
    // silently skipping this assertion would prove nothing about cross-tenant isolation.
    const swiftResp = await request.get(`${API_BASE_URL}/api/v1/tenants/swiftroute`, {
      headers: { Authorization: `Bearer ${token}` },
    })
    if (!swiftResp.ok()) {
      throw new Error(
        `TC-TD-UI-01-04 prerequisite not satisfied: GET /api/v1/tenants/swiftroute returned ` +
        `${swiftResp.status()}. Run the swiftroute tenant onboarding pipeline ` +
        `(sim-company-onboarding.pipeline.e2e.spec.ts) before this test.`,
      )
    }
    const swiftData = await swiftResp.json() as { display_name: string }
    const tiles = page.locator('[data-testid^="tile-"]')
    const tilesText = await tiles.allTextContents()
    const joined = tilesText.join(' ')
    // No tile should contain the other tenant’s display name.
    expect(joined).not.toContain(swiftData.display_name)

    // Own tenant’s tiles must be present
    await expect(page.getByTestId('tile-definitions')).toBeVisible()
    await expect(page.getByTestId('tile-instances')).toBeVisible()
    await expect(page.getByTestId('tile-tasks')).toBeVisible()
  })
})

// ── TD-UI-02: Tenant identity indicator ──────────────────────────────────────

test.describe('TD-UI-02 — Tenant identity indicator', () => {

  /**
   * TC-TD-UI-02-01
   * Verify that the tenant display_name is visible in the sidebar header on every
   * authenticated route (tested on /instances and /definitions).
   */
  test('TC-TD-UI-02-01: tenant display_name visible in sidebar on multiple authenticated routes', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const token = await getKeycloakToken(request, TEST_ADMIN_USER, TEST_ADMIN_PASSWORD)
    const { tenantDisplayName } = await loginWithTenantToken(page, request, token, 'default')

    // Route 1: /instances
    await navigateSpa(page, '/instances')
    await shot(page, 'UI-02-01-instances-sidebar')
    // VERDICT: Screen at /instances shows tenant name in data-testid=tenant-display-name.
    await expect(page.getByTestId('tenant-display-name')).toBeVisible()
    await expect(page.getByTestId('tenant-display-name')).toContainText(tenantDisplayName)

    // Route 2: /definitions
    await navigateSpa(page, '/definitions')
    await shot(page, 'UI-02-01-definitions-sidebar')
    // VERDICT: Screen at /definitions shows the same tenant name in the sidebar.
    await expect(page.getByTestId('tenant-display-name')).toBeVisible()
    await expect(page.getByTestId('tenant-display-name')).toContainText(tenantDisplayName)
  })

  /**
   * TC-TD-UI-02-02
   * Verify that the login page (unauthenticated state) does NOT render any tenant
   * name element in the DOM.
   */
  test('TC-TD-UI-02-02: login page does not show any tenant name', async ({ page }) => {
    // No session injection — navigate as unauthenticated user.
    await page.goto('/', { waitUntil: 'domcontentloaded' })
    await shot(page, 'UI-02-02-login-page-no-tenant-name')

    // VERDICT: Login page screenshot shows no tenant name in any region.
    await expect(page.getByTestId('tenant-display-name')).not.toBeAttached()
    await expect(page.getByTestId('tenant-display-name-unknown')).not.toBeAttached()
  })

  /**
   * TC-TD-UI-02-03
   * Verify that clicking Sign Out navigates to the Keycloak end-session endpoint
   * and the BPM app's tenant-display-name element is no longer present.
   */
  test('TC-TD-UI-02-03: tenant display_name cleared from sidebar after logout', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const token = await getKeycloakToken(request, TEST_ADMIN_USER, TEST_ADMIN_PASSWORD)
    await loginWithTenantToken(page, request, token, 'default')

    // Pre-logout: verify tenant indicator is visible
    await expect(page.getByTestId('tenant-display-name')).toBeVisible()
    await shot(page, 'UI-02-02-before-logout')

    // Click Sign out and capture the Keycloak end-session navigation
    const [logoutRequest] = await Promise.all([
      page.waitForRequest(
        (req) => req.url().includes('openid-connect/logout'),
        { timeout: 10_000 },
      ),
      page.getByTestId('logout-button').click(),
    ])

    await shot(page, 'UI-02-02-after-logout')

    // VERDICT: Logout navigates to Keycloak end-session endpoint.
    //          The BPM app's tenant-display-name element is no longer visible —
    //          the authenticated shell has been left.
    expect(logoutRequest.url()).toContain('openid-connect/logout')
    await expect(page.getByTestId('tenant-display-name')).not.toBeVisible()
  })

  /**
   * TC-TD-UI-02-04
   * Verify that the tenant name element contains non-empty text (not image-only),
   * satisfying WCAG 2.1 AA accessible text requirement (FNFR-03).
   */
  test('TC-TD-UI-02-04: tenant name is rendered as accessible text', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const token = await getKeycloakToken(request, TEST_ADMIN_USER, TEST_ADMIN_PASSWORD)
    const { tenantDisplayName } = await loginWithTenantToken(page, request, token, 'default')

    await navigateSpa(page, '/dashboard')

    const el = page.getByTestId('tenant-display-name')
    await expect(el).toBeVisible()

    // VERDICT: data-testid=tenant-display-name has non-empty textContent.
    //          Tenant name is not embedded exclusively in an img alt or SVG title.
    const textContent = await el.textContent()
    expect(textContent?.trim().length).toBeGreaterThan(0)
    expect(textContent?.trim()).toContain(tenantDisplayName)
  })

})

// ── TD-UI-03: Tenant realm routing ───────────────────────────────────────────

test.describe('TD-UI-03 — Tenant realm routing', () => {

  /**
   * TC-TD-UI-03-01
   * Verify that after login with a known tenant context the dashboard shows the
   * tenant's display_name with no "choose organisation" or "select tenant" prompt.
   *
   * Uses the SwiftRoute tenant if provisioned; fails with a clear message otherwise.
   * Tenant context is resolved via real GET /api/v1/tenants/swiftroute API call.
   *
   * PREREQUISITE: The 'swiftroute' tenant must exist in the database.
   *   If not: run the tenant onboarding pipeline first (sim-company-onboarding).
   */
  test('TC-TD-UI-03-01: no "choose organisation" prompt shown after login with resolved tenant context', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const token = await getKeycloakToken(request, TEST_ADMIN_USER, TEST_ADMIN_PASSWORD)

    // Real API call — resolves swiftroute display_name from the live backend.
    // If swiftroute tenant is not provisioned, this fails with a clear diagnostic.
    const tenantResp = await request.get(`${API_BASE_URL}/api/v1/tenants/swiftroute`, {
      headers: { Authorization: `Bearer ${token}` },
    })
    if (!tenantResp.ok()) {
      throw new Error(
        `TC-TD-UI-03-01 prerequisite not satisfied: GET /api/v1/tenants/swiftroute returned ` +
        `${tenantResp.status()}. Run the swiftroute tenant onboarding pipeline ` +
        `(sim-company-onboarding.pipeline.e2e.spec.ts) before this test.`,
      )
    }
    const tenantData = await tenantResp.json() as { display_name: string; tenant_id: string }
    const swiftRouteDisplayName = tenantData.display_name

    // Inject a full tenant-aware session (simulating the post-OIDC-callback state
    // where AuthProvider has resolved the tenant from the token iss claim).
    await loginWithTenantToken(page, request, token, 'swiftroute')

    await navigateSpa(page, '/dashboard')
    await shot(page, 'UI-03-01-swiftroute-dashboard-no-orgpicker')

    // VERDICT: Screen shows the SwiftRoute tenant display_name in the dashboard heading.
    //          No "choose organisation", "select tenant", or "choose your workspace" prompt is visible.
    const heading = page.getByTestId('tenant-dashboard-heading')
    await expect(heading).toBeVisible()
    await expect(heading).toContainText(swiftRouteDisplayName)

    // Confirm no organisation picker exists in the DOM
    await expect(page.getByText(/choose organisation/i)).not.toBeVisible()
    await expect(page.getByText(/select tenant/i)).not.toBeVisible()
    await expect(page.getByText(/choose your workspace/i)).not.toBeVisible()

    // Sidebar also reflects SwiftRoute identity
    await expect(page.getByTestId('tenant-display-name')).toBeVisible()
    await expect(page.getByTestId('tenant-display-name')).toContainText(swiftRouteDisplayName)
  })

})
