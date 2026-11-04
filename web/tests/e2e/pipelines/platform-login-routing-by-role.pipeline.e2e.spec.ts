/**
 * Pipeline: Platform login routing by role
 *
 * Drives `test/fixtures/uat/scenarios/platform/platform-login-routing-by-role.yaml`'s
 * `pipeline_test:` key (ISS-0702) for UAT-RUNNER.
 *
 * Covers the scenario's three mutually-exclusive branches, each with its own
 * single EO-001. These are independent alternatives of the same login flow —
 * not a sequential chain — so each is modelled as its own self-contained
 * `test()` case rather than forced through `createPipeline()`'s
 * forward-state-accumulation shape (see
 * lib/letflow/design/iss-0702-uat-runner-pipeline-test-gap-fix.md §1.3):
 *
 *   1. PLATFORM_ADMIN lands on the distinct /platform-dashboard route (§1.4)
 *      -- updated for REQ-369 (PlatformDashboardPage); see that requirement's
 *      AC7 and its close-out note for the re-verification discipline this
 *      update follows. Was originally "lands on workspace root with admin
 *      nav" against the pre-REQ-369 shared-'/'-root behaviour.
 *   2. Tenant-scoped role (TASK_WORKER) lands on workspace root, narrower nav (§1.5)
 *   3. Unauthenticated visitor sees auth-loading, then redirects off-origin (§1.6)
 *
 * Uses `helpers.ts`'s two-arg `getKeycloakToken`/`loginWithToken` (always
 * `bpm-default` realm) — NOT `pipeline.ts`'s three-arg realm-taking overload,
 * per the design's §1.1: every credential this spec needs (`admin-user`,
 * `worker-user`) lives in `bpm-default`.
 *
 * Each branch's `gui_screen` EO-001 is checked via hard, deterministic
 * `expect()` assertions rather than REQ-362's two-phase pixel-baseline
 * mechanism — see design §1.7 for the reasoned decision. The
 * `page.screenshot()` call in each branch is supplementary evidence attached
 * to a PASS/FAIL already decided by assertion, same convention as
 * `req133-ac2-ac5.e2e.spec.ts` and `uat-alice-login.e2e.spec.ts`.
 */

import * as fs from 'fs'
import * as path from 'path'
import { test, expect } from '@playwright/test'
import { getKeycloakToken, loginWithToken, loginViaRealOidcRedirect, resolveCredential, BPM_IDP_BASE_URL } from '../helpers'

const APP_BASE_URL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4173'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'

const SCREENSHOTS_DIR = 'tests/screenshots/pipelines'

async function shot(page: import('@playwright/test').Page, stepName: string): Promise<void> {
  fs.mkdirSync(path.resolve(SCREENSHOTS_DIR), { recursive: true })
  await page.screenshot({
    path: path.join(SCREENSHOTS_DIR, `platform-login-routing-by-role-${stepName}.png`),
    fullPage: true,
  })
}

test.describe('Pipeline: platform-login-routing-by-role', () => {
  test.beforeAll(async ({ request }) => {
    // Reachability precheck, mirroring admin-user-lifecycle.pipeline.e2e.spec.ts.
    const idpOk = await request.fetch(
      `${BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`,
    )
    if (!idpOk.ok()) throw new Error(`Keycloak not reachable: ${idpOk.status()}`)

    // No backend call is required by this scenario (login/routing is IdP + SPA
    // only), but the precheck is included anyway for convention parity with
    // other pipeline specs — see design §1.2.
    const backendOk = await request.fetch(`${API_BASE_URL}/health/ready`).catch(() => null)
    if (backendOk && !backendOk.ok()) {
      console.warn(`[platform-login-routing-by-role] backend not ready: ${backendOk.status()} (non-blocking)`)
    }
  })

  test('EO-001: PLATFORM_ADMIN lands on the distinct platform dashboard', async ({ page }) => {
    await loginViaRealOidcRedirect(
      page,
      'admin-user',
      resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
      '/platform-dashboard',
    )

    // Core routing claim (REQ-369): PLATFORM_ADMIN no longer lands on the
    // shared tenant-branded workspace root — OidcCallbackPage.tsx's
    // role-conditional navigate() (line 72) sends it to the new, distinct
    // PlatformDashboardPage route instead.
    await expect(page).toHaveURL('/platform-dashboard')

    // PlatformDashboardPage.tsx's own content — fixed, non-tenant-branded
    // heading (never a tenant name; see PlatformDashboardPage.tsx's
    // `data-testid="platform-dashboard-heading"` <h1> reading "Platform
    // Overview"), the tenant-count tile sourced from tenantsApi.list(), and
    // the platform admin quick-links nav. These are REQ-369 AC1/AC2's own
    // testids (docs/requirements.yaml REQ-369), not TenantDashboardPage's.
    await expect(page.getByTestId('platform-dashboard-heading')).toBeVisible()
    await expect(page.getByTestId('platform-dashboard-heading')).toHaveText('Platform Overview')
    await expect(page.getByTestId('tile-tenant-count')).toBeVisible()
    await expect(page.getByTestId('platform-quick-links')).toBeVisible()

    // Quick-links nav entries into the existing admin routes.
    for (const name of ['Tenants', 'Services', 'Health', 'Metrics', 'Users']) {
      await expect(page.getByTestId('platform-quick-links').getByRole('link', { name })).toBeVisible()
    }

    await shot(page, 'admin')
  })

  test('EO-001: tenant-scoped role (TASK_WORKER) lands on workspace root with narrower nav', async ({ page, request }) => {
    const token = await getKeycloakToken(request, 'worker-user', resolveCredential('UAT_QA_WORKER_PASSWORD', 'worker-pass'))
    await loginWithToken(page, token)

    // Core routing claim: tenant-scoped roles land on the SAME root, not a
    // different route.
    await expect(page).toHaveURL('/')

    // The nav entry a TASK_WORKER needs.
    await expect(page.getByRole('link', { name: 'My Tasks' })).toBeVisible()

    // PLATFORM_ADMIN-only entries must NOT be visible — proves the nav is
    // narrower than PLATFORM_ADMIN's, per EO-001's "narrower nav" wording.
    for (const name of ['Users', 'Tenants', 'Register Tenant', 'Audit', 'Health', 'Metrics']) {
      await expect(page.getByRole('link', { name })).not.toBeVisible()
    }

    // EO-001's dashboard-tile sub-claim, tenant-scoped side (ISS-0702 gap).
    // NOTE (REQ-369): this branch's own comparison target used to be an
    // identical assertion in the PLATFORM_ADMIN branch above, back when both
    // roles landed on the same TenantDashboardPage workspace root. REQ-369
    // moved PLATFORM_ADMIN to its own distinct /platform-dashboard route
    // with its own tile set (tile-tenant-count, not these three), so that
    // comparison no longer holds — these three tiles are now specific to
    // TenantDashboardPage / tenant-scoped roles only. Left asserting here
    // regardless: it still proves TenantDashboardPage's own tile set renders
    // for a tenant-scoped role, which is this branch's own claim regardless
    // of what PLATFORM_ADMIN's separate page does.
    for (const testid of ['tile-definitions', 'tile-instances', 'tile-tasks']) {
      await expect(page.getByTestId(testid)).toBeVisible()
    }

    // The "reflect this tenant's own data only" half of EO-001's detail text
    // is a cross-tenant-isolation claim. This environment has only one
    // seeded tenant reachable via `worker-user`, so there is no second
    // tenant's data available here to prove non-leakage against (a bare
    // "no PLATFORM_ADMIN nav" check above doesn't touch tile *content*
    // scoping at all). Verified by hand while writing this assertion (real
    // run against a local stack) that `tenant-unknown-banner` is NOT a
    // usable proxy here: tenant resolution in this environment is by HTTP
    // Host header (`/api/tenant-config?host=...`, see TenantDashboardPage's
    // `useTenantContext`), and the local stack is reached over a bare
    // loopback IP with no tenant subdomain, so the banner renders identically
    // for PLATFORM_ADMIN and TASK_WORKER alike — it is a host-routing signal,
    // not a role/data-scoping one, so asserting on it here would be
    // measuring the wrong thing. The minimal thing this branch CAN prove
    // without a second tenant: the count tiles actually render live data (not
    // stuck on their loading skeleton, not replaced by the QueryStateBoundary
    // error state), confirming the scoped list queries
    // (queryKeys.instances.list/tasks.list, both filtered by the
    // authenticated tenant context) genuinely executed and resolved for this
    // token/role rather than being skipped or erroring.
    // The deeper claim — tenant A's data never appears in tenant B's
    // tiles — currently has NO working coverage anywhere in this repo.
    // web/tests/e2e/tenant-dashboard.e2e.spec.ts's 'TC-TD-UI-01-04' looks
    // like the obvious candidate (it does assert swiftroute's display_name
    // never appears in the default tenant's tiles) but it cannot actually
    // run against Letflow: its assertServiceReadiness() precondition polls
    // GET /health/ready, which lib/letflow/router.ex's moduledoc documents
    // as a deliberate, permanent non-port (only GET /health, liveness,
    // exists) — confirmed by directly running the test. It also gates its
    // leakage assertion behind `if (swiftResp.ok())`, so even with a
    // reachable backend it would silently no-op rather than reliably prove
    // isolation if the second tenant weren't provisioned. This is a
    // pre-existing gap (the /health/ready pattern is shared by 11 e2e spec
    // files repo-wide, filed separately as ISS-0706 — see
    // docs/issues/ISS-0706.yaml) that this fix did not create and is not
    // in scope to solve here (ISS-0702 is a UAT-RUNNER tooling/doc gap, not
    // a general e2e-suite health sweep). Same honest treatment already
    // given to the still-BLOCKED
    // test/fixtures/uat/scenarios/platform/attachment-cross-tenant-probe.yaml:
    // documented as uncoverable rather than citing a test that cannot pass.
    await expect(page.getByTestId('tile-instances-count')).toBeVisible()
    await expect(page.getByTestId('tile-tasks-count')).toBeVisible()

    await shot(page, 'tenant-scoped')
  })

  test('EO-001: unauthenticated visitor sees auth-loading then redirects off-origin to Keycloak', async ({ page }) => {
    // Deliberately no loginWithToken/getKeycloakToken call — matches the
    // scenario's own precondition ("no token, no cookie").
    //
    // Real, verified-against-QA timing finding: on both a local loopback
    // stack AND the real https://qa.bizdala.com deployment, the
    // ProtectedRoute → signinRedirect() chain completes so fast that any
    // observation attempted from OUTSIDE the page (an external CDP poll
    // started after `page.goto()` resolves, or even one started just before
    // it, per Playwright's own `waitForSelector`) consistently loses the race
    // to the redirect — confirmed by driving this exact spec against real
    // QA. The fix is to observe from INSIDE the page, at native JS speed: an
    // `addInitScript` MutationObserver watches for the placeholder and
    // records the fact in `window.name`, which (unlike page-level JS state)
    // survives a cross-origin navigation, so it can be read back after the
    // browser has landed on Keycloak's page. This is pure observation, not a
    // mock — it changes nothing about what the app does, only how reliably
    // we can see a transition too fast for external polling to catch.
    await page.addInitScript(() => {
      const mark = () => {
        if (document.querySelector('[data-testid="auth-loading"]')) {
          window.name = 'auth-loading-seen'
        }
      }
      // Observe `document` itself, not `document.documentElement` — this
      // script runs at document-start (before HTML parsing), so
      // `documentElement` does not exist yet and would make `.observe()`
      // throw. `document` always exists.
      new MutationObserver(mark).observe(document, { childList: true, subtree: true })
      mark()
    })
    await page.goto(APP_BASE_URL, { waitUntil: 'commit' })

    // "redirected off-origin to the configured OIDC authority's own hosted
    // login page" — the browser's URL origin changes away from the app's own
    // origin within a bounded wait.
    const appOrigin = new URL(APP_BASE_URL).origin
    await page.waitForURL((url) => url.origin !== appOrigin, { timeout: 20_000 })
    expect(new URL(page.url()).origin).not.toBe(appOrigin)

    // "briefly shows... the placeholder" — this IS the assertion, not a soft
    // check: a false result here is a real failure, not swallowed.
    const authLoadingSeen = await page.evaluate(() => window.name)
    expect(authLoadingSeen, 'expected the auth-loading placeholder to have rendered before the off-origin redirect').toBe('auth-loading-seen')

    await shot(page, 'unauthenticated')
  })
})
