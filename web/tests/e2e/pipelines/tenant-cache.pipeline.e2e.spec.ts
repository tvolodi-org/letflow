/**
 * Pipeline: tenant-switch-cache-isolation (PW-15 / sys-tenant-scoped-client-cache)
 *
 * Drives `test/fixtures/uat/scenarios/platform/tenant-switch-cache-isolation.yaml`'s
 * `pipeline_test:` key for UAT-RUNNER, following this GUI-review sweep's own process:
 * every real screen was read from source before any test was written (see
 * test/uat-reports/gui-review-2026-09-20-tenant-switch-cache-isolation.md for the
 * full trace this spec's scope decisions come from).
 *
 * What the source investigation found, and why this spec covers what it covers:
 *
 *   - EO-001 (mid-session company switch via a selector, without reload) had NO
 *     underlying feature when this file was first authored (2026-09-20) — see
 *     the historical note this replaces, preserved in git history at commit
 *     `2b7f4a28`'s parent. REQ-384 has since shipped (`TenantSwitcher.tsx`,
 *     `AuthProvider.switchTenant`, tenant-keyed React Query cache) and this
 *     file now drives it for real below: provisions a second, genuinely
 *     separate tenant (its own real Postgres schema, migrated synchronously)
 *     via the real onboarding saga, grants the acting admin a
 *     `tenant_memberships` row into it (no HTTP write path ships with REQ-384
 *     for that table — design SS1.1, OQ-2 — so this is done via direct SQL,
 *     the same real-DDL-direct technique `db-exec.ts`'s own moduledoc already
 *     established for a different fixture need), seeds a tenant-B-owned
 *     marker process definition directly in that schema (no Keycloak
 *     realm/admin-user is provisioned for a self-service-onboarded tenant —
 *     confirmed by reading `Letflow.Routers.Onboarding`'s own moduledoc — so
 *     no HTTP credential scoped to tenant B exists either; same direct-write
 *     technique, see `createActiveDefinitionInSchema` in db-exec.ts), then
 *     clicks the real `TenantSwitcher` control and asserts the four-way
 *     isolation guarantee AC1-AC3 describe. Proof-of-isolation surface is
 *     `/definitions` (design §7.1 names `definitions` explicitly), NOT
 *     `/admin/users` — that screen was tried first and found to depend on a
 *     real, separate, pre-existing production bug (`web/src/api/identity.ts`'s
 *     `GET /api/v1/users` misses the `/identity` prefix the backend actually
 *     mounts under; filed ISS-0782/GH-1722) unrelated to REQ-384 and out of
 *     this spec's scope to fix.
 *
 *     LIVE RUN FINDING (TEST-DESIGNER, 2026-09-22, against a real running
 *     backend+Vite+Keycloak+Postgres stack): EO-001 currently FAILS, and not
 *     on a setup bug — a genuine REQ-384 implementation defect.
 *     `AuthProvider.switchTenant`'s `attemptSilentSwitch` (`tenantOidcRegistry.ts`)
 *     calls oidc-client-ts's `UserManager.signinSilent()`, which opens a
 *     hidden iframe at the SAME `redirect_uri` as the top-level login flow
 *     (`OidcManager.ts` sets no distinct `silent_redirect_uri`) and expects
 *     whatever loads in that iframe to call `manager.signinSilentCallback()`
 *     to post the result back to the pending promise. `OidcCallbackPage.tsx`
 *     — the one and only component mounted at that route — unconditionally
 *     calls `manager.signinRedirectCallback()` instead, with no branch for
 *     being loaded inside that hidden iframe. Confirmed live: the network
 *     trace shows Keycloak's `/protocol/openid-connect/auth?...&prompt=none`
 *     genuinely completing (302 to `/auth/callback?error=login_required` —
 *     expected here, since `loginWithToken`'s token-injection technique never
 *     established a real Keycloak SSO cookie for this browser to authenticate
 *     that iframe against), but neither `tenant-switcher-interaction-required`
 *     nor `tenant-switcher-error` (TenantSwitcher.tsx's own third, error-path
 *     testid) nor a completed switch ever appears — `switchTenant()`'s
 *     returned promise never settles within this spec's 30s budget, because
 *     nothing ever calls back into it. This is not specific to this sandbox's
 *     inability to establish a real SSO cookie: since NOTHING loaded in that
 *     iframe ever calls `signinSilentCallback()`, `signinSilent()` cannot
 *     resolve in ANY environment, including one where the target realm truly
 *     does have an active federated SSO session (the "silent_ok" branch could
 *     never fire either) — this is a mechanical wiring gap, independent of
 *     and strictly worse than the open OQ-3 question below (SS10 asks
 *     whether realms are federated enough for a silent switch to succeed;
 *     this defect means it structurally cannot succeed OR cleanly fall back,
 *     regardless of federation). Not fixed here (TEST-DESIGNER does not
 *     implement fixes) — reported for ORCH to route to FRONTEND-DEV. This
 *     spec is left asserting the real, intended behavior (a red test against
 *     the real defect), not loosened to pass around it.
 *
 *     Both prior claims in this comment block's earlier revisions —
 *     "TEST-DESIGNER could not run this test live" and "tenant B gets its
 *     own Keycloak realm" — were themselves inaccurate and are corrected
 *     above: this spec DID run live once the environment's actual Keycloak
 *     port (8092, not the 8082 default baked into some helpers'
 *     documentation) and dev-DB-write confirmation gate were accounted for,
 *     and REQ-384's self-service onboarding path (`Letflow.Routers.Onboarding`)
 *     deliberately does not provision Keycloak at all (its own moduledoc,
 *     "What is deliberately NOT ported") — tenant B is a real, separate
 *     Postgres schema with no realm of its own.
 *
 *   - EO-002 (signing out leaves nothing behind) IS the real, supported flow —
 *     and a genuine defect was found and fixed in this same change:
 *     `web/src/auth/tenantConfig.ts`'s `bpm_realm_slug` sessionStorage key
 *     (deliberate, OIDC-F-06) was never cleared by `AuthProvider.logout()`,
 *     letting one tenant's realm selection survive into the next sign-in on the
 *     same browser tab. Fixed via `resetTenantConfigCache()`, filed as ISS-0737.
 *     This spec proves the fix holds through a REAL sign-out click, not just the
 *     unit-level coverage in tenantConfig.test.ts / AuthProvider.logout-clears-realm.test.tsx.
 *
 *   - EO-003 (a task shows the form it was created against, not a later published
 *     version) is already satisfied by construction — REQ-126 (status: done) pins
 *     `form_id`/`form_version` from `instance_definition_snapshots.definition_ver`,
 *     frozen at instance-start time, and `TaskActivation.resolve_form_schema/1`
 *     freezes `form_schema` itself onto the `tasks` row at activation time. What
 *     had NOT been verified anywhere was that the real SPA screen (not just the
 *     JSON body, which test/letflow/routers/tasks_test.exs's REQ-126 AC3 test
 *     already covers) renders the pinned fields rather than the newly-promoted
 *     ones. This spec proves that end to end: create v1, start an instance, open
 *     the real Task Inbox screen, promote v2 with different form fields, reopen
 *     the same task and prove the screen still shows v1's fields only.
 *
 *   - EO-004 (explicit "out of date" fallback when a version can't be confirmed)
 *     has no implementation anywhere — filed as REQ-385, since REQ-126's
 *     frozen-at-creation design has no live version-resolution step that could
 *     even fail to confirm a match. Not attempted here; see REQ-385.
 *
 *   - EO-005 (frequently-changing lists refetch on return) already has working,
 *     independently-verified coverage via `usePolling` (interval + visibility-
 *     change refetch, read from source) — out of scope for this spec's own
 *     regression focus (MINOR severity, `suggested_action: none` in the scenario
 *     itself).
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  authHeaders,
  resolveTenantContext,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential, BPM_IDP_BASE_URL, getMasterAdminToken } from '../helpers'
import {
  runSqlAgainstDevPostgres,
  insertTenantMembershipSql,
  deleteTenantMembershipSql,
  createActiveDefinitionInSchema,
  tenantSchemaName,
} from '../db-exec'
import { typeIntoTestIdInput } from '../type-into-input'

const APP_BASE_URL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4173'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'

// Seeded verbatim in priv/keycloak/realms/bpm-default.json -- the "admin-user"
// account's own email, used as this test's tenant_memberships subject_key.
const BPM_DEFAULT_ADMIN_EMAIL = 'admin@letflow.local'

interface TenantCachePipelineState {
  adminToken: string
  processKey: string
  v1Label: string
  v2FieldLabel: string
  taskId: string
}

interface Eo001State {
  adminToken: string
  fixtureId: string
  tenantAMarkerDefName: string
  tenantAMarkerDefId: string
  tenantBSlug: string
  tenantBMarkerDefName: string
  tenantBId: string
  tenantBDisplayLabel: string
  membershipId: string
}

test.describe('Pipeline: tenant-switch-cache-isolation (PW-15)', () => {
  test('EO-001: switching tenants via the in-app control never shows stale tenant-A data', async ({ page, request }) => {
    // Onboarding a real second tenant (its own Keycloak realm, own schema
    // migration) can genuinely take ~60-120s in this suite's other specs
    // (see onboarding-wizard.pipeline.e2e.spec.ts / env04.e2e.spec.ts's Suite
    // C fixture) -- generous budget for the same reason.
    test.setTimeout(300_000)

    await assertServiceReadiness(request, API_BASE_URL)

    const fixtureId = randomUUID().slice(0, 8)
    const pl = createPipeline<Eo001State>('tenant-switch-cache-isolation-eo001', { page, request })
    pl.state.fixtureId = fixtureId
    pl.state.tenantAMarkerDefName = `req384-eo001-a-def-${fixtureId}`
    pl.state.tenantBSlug = `req384-eo001-b-${fixtureId}`
    pl.state.tenantBMarkerDefName = `req384-eo001-b-def-${fixtureId}`
    pl.state.tenantBDisplayLabel = `Tenant B Fixture [${fixtureId}]`

    // ── Cleanup: delete the membership row, best-effort delete tenant B's
    // Keycloak realm (mirrors env04.e2e.spec.ts's own
    // cleanupOnboardedTestTenantFixture -- there is no tenant-record DELETE
    // endpoint in this API version either, same gap onboarding-wizard's own
    // pipeline spec already documents). The tenant-A/tenant-B marker
    // DEFINITIONS are deliberately NOT cleaned up here — same disclosed,
    // scoped-out gap platform-definition-promotion-rollback.pipeline.e2e.spec.ts's
    // own cleanup already accepts (no definition-DELETE endpoint exists;
    // fixtureId keeps every run's rows unique, so nothing collides). ────────
    pl.onCleanup(async (s) => {
      if (s.membershipId) {
        runSqlAgainstDevPostgres(deleteTenantMembershipSql(s.membershipId))
      }
      if (s.tenantBSlug) {
        try {
          const masterToken = await getMasterAdminToken(request)
          await request.delete(`${BPM_IDP_BASE_URL}/admin/realms/${s.tenantBSlug}`, {
            headers: { Authorization: `Bearer ${masterToken}` },
          })
        } catch { /* best-effort cleanup only */ }
      }
    })

    // ── Step 01: tenant A = bpm-default (already provisioned); seed a
    // distinctive tenant-A-only marker process definition so a later "no
    // stale tenant-A content" assertion has something concrete to look for.
    // Uses the real `POST /api/v1/definitions` write path (unlike
    // tenant_memberships, this one ships an HTTP writer for tenant A's own
    // token) — the same technique EO-003 below already exercises in this
    // same file. ───────────────────────────────────────────────────────────
    await pl.step('01: resolve tenant A, seed a distinctive tenant-A marker definition', async (s) => {
      s.adminToken = await getKeycloakToken(
        request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
      )
      await resolveTenantContext(request, 'bpm-default', s.adminToken) // sanity: tenant A really resolves

      const markerResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: {
          name: s.tenantAMarkerDefName,
          version: '1.0.0',
          description: `REQ-384 EO-001 Tenant-A Marker ${s.fixtureId}`,
          graph: {
            nodes: [
              { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
              {
                id: 'n2',
                node_type: 'HUMAN_TASK',
                label: 'Task',
                attributes: { role: 'admin-user', assignee_type: 'user', assignee_ref: 'admin-user' },
              },
              { id: 'n3', node_type: 'END', label: 'End', attributes: null },
            ],
            edges: [
              { id: 'e1', source: 'n1', target: 'n2' },
              { id: 'e2', source: 'n2', target: 'n3' },
            ],
          },
        },
      })
      pl.gate(markerResp.ok(), `tenant-A marker definition create failed: ${markerResp.status()} ${await markerResp.text()}`)
      const markerBody = await markerResp.json() as { id?: string }
      s.tenantAMarkerDefId = markerBody.id ?? ''
      pl.gate(!!s.tenantAMarkerDefId, 'tenant-A marker definition response must include an id')
    })

    // ── Step 02: onboard tenant B for real (own schema, migrated
    // synchronously) — the same technique env04.e2e.spec.ts's Suite C
    // fixture already established. ────────────────────────────────────────
    await pl.step('02: onboard a genuinely separate tenant B', async (s) => {
      const onboardResp = await request.post(`${API_BASE_URL}/api/v1/onboarding`, {
        headers: {
          Authorization: `Bearer ${s.adminToken}`,
          'Content-Type': 'application/json',
          'Idempotency-Key': randomUUID(),
        },
        data: {
          slug: s.tenantBSlug,
          display_name: `REQ-384 EO-001 Tenant B ${s.fixtureId}`,
          admin_email: `req384-eo001-b-admin-${s.fixtureId}@example.com`,
          admin_username: `req384-eo001-b-admin-${s.fixtureId}`,
          admin_display_name: `Tenant B Admin ${s.fixtureId}`,
          hostname: `${s.tenantBSlug}.example.com`,
        },
      })
      pl.gate(onboardResp.ok(), `tenant B onboarding request failed: ${onboardResp.status()} ${await onboardResp.text()}`)
      // The real Letflow.Routers.Onboarding.handle_create/1
      // (lib/letflow/routers/onboarding.ex) provisions and migrates tenant B
      // SYNCHRONOUSLY within this one POST -- TenantOnboarding.provision_and_migrate/1
      // completes before the response is sent, and onboarding_map/1 returns
      // exactly 5 keys (id/tenant_id/slug/hostname/created_at), no "state"
      // field at all (confirmed by direct inspection, UAT-RUNNER 2026-09-22).
      // The original onboarding_id + poll-for-state==='completed' shape this
      // step copied from env04.e2e.spec.ts's Suite C fixture does not match
      // this router's real response shape or its real (synchronous)
      // semantics.
      const onboardBody = await onboardResp.json() as { id: string; tenant_id?: string }
      pl.gate(!!onboardBody.tenant_id, `tenant B onboarding response must include tenant_id: ${JSON.stringify(onboardBody)}`)
      s.tenantBId = onboardBody.tenant_id as string
    })

    // ── Step 03: grant admin-user (tenant A's own admin, by email) a
    // membership into tenant B, then seed a distinctive tenant-B-only marker
    // process definition DIRECTLY inside tenant B's real schema. Neither
    // write path has an HTTP route usable here: tenant_memberships ships no
    // HTTP writer at all (design SS1.1/OQ-2), and tenant B has no Keycloak
    // realm/admin-user this test could authenticate as (REQ-384's onboarding
    // deliberately does not provision one — see
    // createActiveDefinitionInSchema's own doc comment in db-exec.ts). Direct
    // SQL / direct `mix run` are the only real, non-mocked ways to create
    // either row. ─────────────────────────────────────────────────────────
    await pl.step('03: grant tenant-B membership + seed tenant-B marker definition (no HTTP write path exists for either)', async (s) => {
      s.membershipId = randomUUID()
      runSqlAgainstDevPostgres(
        insertTenantMembershipSql(s.membershipId, BPM_DEFAULT_ADMIN_EMAIL, s.tenantBId, s.tenantBDisplayLabel),
      )
      createActiveDefinitionInSchema(tenantSchemaName(s.tenantBId), s.tenantBMarkerDefName, '1.0.0')
    })

    // ── Step 04: drive the real switcher, assert whichever real outcome this
    // environment actually produces. Proof-of-isolation surface is
    // `/definitions` (design §7.1 names `definitions` explicitly as one of
    // the tenant-scoped query-key groups AC2 requires) — NOT `/admin/users`.
    // `/admin/users` was tried first and rejected: it renders through
    // `web/src/api/identity.ts`'s `GET /api/v1/users` (missing the
    // `/identity` prefix `lib/letflow/plugs/api_pipeline.ex` actually mounts
    // under), a real, separate, pre-existing production bug (ISS-0782 /
    // GH-1722) unrelated to REQ-384 — fixing it is out of this spec's scope,
    // so this spec proves the same isolation property on a screen whose own
    // API calls (`web/src/api/definitions.ts`) are correct. ─────────────────
    await pl.step('04: switch tenants via the real UI control, assert isolation', async (s) => {
      await loginWithToken(page, s.adminToken)
      await navigateSpa(page, '/definitions')

      await typeIntoTestIdInput(page, 'definition-search', s.tenantAMarkerDefName)
      await expect(page.getByTestId('datatable-row').filter({ hasText: s.tenantAMarkerDefName }))
        .toBeVisible({ timeout: 10_000 })

      // AC1: the render gate — a user with >1 membership (home tenant A +
      // the tenant-B row seeded in step 03) sees the control at all.
      await expect(page.getByTestId('tenant-switcher')).toBeVisible({ timeout: 10_000 })
      await page.getByTestId('tenant-switcher-trigger').click()

      const option = page.getByTestId(`tenant-switcher-option-${s.tenantBSlug}`)
      await expect(option).toBeVisible({ timeout: 10_000 })
      // display_label (seeded above) must be preferred over tenant_display_name
      // — the same property TC-REQ384-18 proves at the unit level, here proven
      // through a real GET /me/memberships response.
      await expect(option).toHaveText(s.tenantBDisplayLabel)

      await option.click()

      // Poll the live DOM from the instant the option is clicked. Any
      // snapshot in this window that shows the REAL (non-transition) shell
      // — i.e. contains a rendered data table row — while still carrying
      // tenant-A's marker text would be exactly the mid-transition stale-row
      // bug AC3 exists to catch. Wrapped in try/catch: a remount
      // (AuthenticatedShellRoot's `key={session.tenant_id}` swap) can destroy
      // the execution context mid-read, the same lesson EO-002 above already
      // documents for a different navigation.
      const domSnapshots: string[] = []
      let polling = true
      const pollLoop = (async () => {
        while (polling) {
          try { domSnapshots.push(await page.content()) } catch { /* context torn down mid-remount; skip this tick */ }
          await new Promise((r) => setTimeout(r, 50))
        }
      })()

      // Real outcome branches on infra this design doc's own OQ-3 leaves
      // unresolved (lib/letflow/design/req384-tenant-switcher-cache-isolation.md
      // SS10): a silent cross-realm switch (`manager.signinSilent()`) only
      // succeeds if tenant A's and tenant B's Keycloak realms are federated to
      // a shared upstream IdP with a shared SSO session — not something this
      // test controls or can assume either way. Both real, correctly-
      // implemented outcomes are asserted below; whichever this live
      // environment actually produces is itself a legitimate finding on
      // OQ-3, not a test bug in either branch. `tenant-switcher-error`
      // (TenantSwitcher.tsx's third, error-path testid) is polled for too —
      // NOT as a third accepted outcome (it isn't one; `pl.gate` below still
      // fails if it's the one that fired), only so a failure here names which
      // of the three real branches actually happened instead of leaving the
      // reader to guess.
      await Promise.race([
        page.getByTestId('tenant-switcher-interaction-required').waitFor({ state: 'visible', timeout: 30_000 }),
        page.getByTestId('tenant-switcher-error').waitFor({ state: 'visible', timeout: 30_000 }),
        page.getByTestId('datatable-row').filter({ hasText: s.tenantBMarkerDefName }).waitFor({ state: 'visible', timeout: 30_000 }),
      ]).catch(() => { /* none settled within budget — surfaced by the gate below */ })

      polling = false
      await pollLoop

      const interactionRequired = await page.getByTestId('tenant-switcher-interaction-required').isVisible().catch(() => false)
      const switchedToB = await page.getByTestId('datatable-row').filter({ hasText: s.tenantBMarkerDefName }).isVisible().catch(() => false)
      const erroredOut = await page.getByTestId('tenant-switcher-error').isVisible().catch(() => false)
      pl.gate(
        interactionRequired || switchedToB,
        'switching must produce one of the two real, implemented outcomes (interaction_required fallback, or a completed silent switch) within 30s'
          + (erroredOut ? ' -- got tenant-switcher-error instead (switchTenant() resolved \'error\')' : ' -- got neither (switchTenant() likely never resolved at all)'),
      )

      if (interactionRequired) {
        // AC1's exact boundary: no automatic full-page re-auth happened —
        // tenant A's own data is still authoritative on screen — but an
        // explicit, user-initiated sign-in affordance is offered, and
        // clicking it drives a real navigation toward tenant B's own realm
        // (never a silent/automatic one).
        await expect(page.getByTestId('datatable-row').filter({ hasText: s.tenantAMarkerDefName }))
          .toBeVisible()
        await expect(page.getByTestId('tenant-switcher-sign-in')).toBeVisible()

        const navigatedTowardTenantB = await Promise.race([
          page.waitForURL((url) => url.href.includes(`/realms/${s.tenantBSlug}/`), { timeout: 15_000 }).then(() => true),
          page.getByTestId('tenant-switcher-sign-in').click().then(() => false as boolean),
        ]).catch(() => false)
        void navigatedTowardTenantB // best-effort — signinRedirect's real target depends on live OIDC config this test does not control end-to-end; the affordance's presence and click-ability above is the load-bearing assertion.
        await shot(page, 'tenant-switch-cache-isolation', 'eo001-interaction-required-fallback')
      } else {
        // Full silent switch succeeded — assert the four-way isolation
        // guarantee AC1-AC3 describe together.
        await expect(page.getByTestId('datatable-row').filter({ hasText: s.tenantBMarkerDefName }))
          .toBeVisible({ timeout: 10_000 })
        await expect(page.getByTestId('datatable-row').filter({ hasText: s.tenantAMarkerDefName }))
          .toHaveCount(0)

        const transitionSeen = domSnapshots.some((html) => html.includes('tenant-switch-transition'))
        pl.gate(transitionSeen, 'the dedicated TenantSwitchTransitionScreen (data-testid="tenant-switch-transition") must have appeared at least once during the switch')

        const staleFrames = domSnapshots.filter(
          (html) => html.includes('datatable-row') && html.includes(s.tenantAMarkerDefName),
        )
        pl.gate(
          staleFrames.length === 0,
          `no polled DOM frame between click and settle may show tenant-A's marker row inside the real (non-transition) shell — found ${staleFrames.length} such frame(s)`,
        )

        await shot(page, 'tenant-switch-cache-isolation', 'eo001-switched-to-tenant-b-clean')
      }
    })

    await pl.runCleanup()
  })

  test('EO-002: sign-out clears same-tab tenant-selection residue (bpm_realm_slug)', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )

    // Log in FIRST (loginWithToken registers its session-injecting
    // addInitScript, which survives every later navigation on this page,
    // then does its own goto('/')) — an unauthenticated first load would
    // otherwise race ProtectedRoute's own signinRedirect() against the
    // ?realm= navigation below (net::ERR_ABORTED, confirmed while writing
    // this spec). Order doesn't change what's under test: what matters is
    // that bpm_realm_slug survives into the post-login session and is then
    // cleared by logout.
    await loginWithToken(page, adminToken)

    // Seed the same-tab tenant-selection residue exactly the way a real
    // multi-realm login flow does — resolveRealmFromUrl() writes ?realm=
    // into sessionStorage on load (OIDC-F-06). A full page.goto reruns
    // main.tsx from scratch (fresh fetchTenantConfig() call), same as any
    // real full-page navigation; the addInitScript session survives it.
    await page.goto(`${APP_BASE_URL}/?realm=swiftroute-fixture`, { waitUntil: 'domcontentloaded' })
    await expect.poll(() => page.evaluate(() => sessionStorage.getItem('bpm_realm_slug')))
      .toBe('swiftroute-fixture')
    await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 })

    await expect(page.getByTestId('logout-button')).toBeVisible({ timeout: 15_000 })

    // resetTenantConfigCache() runs synchronously as the first lines of
    // AuthProvider.logout() — strictly before the async
    // getOidcManager().then(m => m.signoutRedirect()) chain that eventually
    // navigates the browser off-origin to Keycloak. Read sessionStorage back
    // with a SINGLE, immediate evaluate right after the click — not a
    // polling/retrying assertion — because the subsequent off-origin
    // navigation destroys this page's JS execution context within a couple
    // of ticks (confirmed: an earlier version of this test used
    // expect.poll() here and intermittently hit "Execution context was
    // destroyed, most likely because of a navigation" once the real
    // signoutRedirect() navigation won the race against a slower retry
    // loop). A single evaluate() immediately after click() reliably lands
    // inside the synchronous window before that navigation begins.
    await page.getByTestId('logout-button').click()
    const realmAfterLogout = await page.evaluate(() => sessionStorage.getItem('bpm_realm_slug'))
    expect(realmAfterLogout, 'bpm_realm_slug must be cleared by AuthProvider.logout() before any next sign-in on this tab').toBeNull()
  })

  test('EO-003: a task shows the form it was created against, not a later published version', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )

    const fixtureId = randomUUID().slice(0, 8)
    const processKey = `pl-tenant-cache-form-pin-${fixtureId}`
    const v1Label = `Review ${fixtureId}`
    const v1FieldName = `reviewNotesV1_${fixtureId}`
    const v2FieldName = `approvalDecisionV2_${fixtureId}`

    const pl = createPipeline<TenantCachePipelineState>('tenant-switch-cache-isolation', { page, request })
    pl.state.adminToken = adminToken
    pl.state.processKey = processKey
    pl.state.v1Label = v1Label
    pl.state.v2FieldLabel = v2FieldName

    const graphWithForm = (formSchema: Record<string, unknown>) => ({
      nodes: [
        { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
        {
          id: 'task',
          node_type: 'HUMAN_TASK',
          label: v1Label,
          attributes: {
            role: 'admin-user',
            assignee_type: 'USER',
            form_schema: formSchema,
          },
        },
        { id: 'n3', node_type: 'END', label: 'End', attributes: null },
      ],
      edges: [
        { id: 'e1', source: 'n1', target: 'task' },
        { id: 'e2', source: 'task', target: 'n3' },
      ],
    })

    // ── Step 01: create + activate v1, with a form field unique to v1 ────────
    await pl.step('01: create + activate v1, start an instance, locate the activated task', async (s) => {
      const createResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: {
          name: processKey,
          version: '1.0.0',
          description: 'tenant-switch-cache-isolation EO-003 pipeline fixture (v1)',
          graph: graphWithForm({
            properties: { [v1FieldName]: { type: 'string', title: 'Review Notes (v1)' } },
            required: [],
          }),
        },
      })
      pl.gate(createResp.ok(), `v1 definition create failed: ${createResp.status()} ${await createResp.text()}`)
      const v1 = await createResp.json() as { id: string }

      const activateResp = await request.post(
        `${API_BASE_URL}/api/v1/definitions/${v1.id}/activate`,
        { headers: authHeaders(s.adminToken) },
      )
      pl.gate(activateResp.ok(), `v1 activate failed: ${activateResp.status()} ${await activateResp.text()}`)

      const startResp = await request.post(`${API_BASE_URL}/api/v1/instances`, {
        headers: authHeaders(s.adminToken),
        data: { definition_name: processKey, initial_variables: {} },
      })
      pl.gate(startResp.ok(), `instance start failed: ${startResp.status()} ${await startResp.text()}`)
      const instance = await startResp.json() as { id?: string; instance_id?: string }
      const instanceId = instance.instance_id ?? instance.id
      pl.gate(!!instanceId, 'instance id must be present after start')

      const tasksResp = await request.get(`${API_BASE_URL}/api/v1/tasks`, {
        headers: authHeaders(s.adminToken),
        params: { instance_id: instanceId as string },
      })
      pl.gate(tasksResp.ok(), `task list failed: ${tasksResp.status()} ${await tasksResp.text()}`)
      const tasksBody = await tasksResp.json() as { items: Array<{ id: string; form_version?: string }> }
      pl.gate(tasksBody.items.length === 1, `expected exactly 1 activated task, got ${tasksBody.items.length}`)
      s.taskId = tasksBody.items[0].id
      pl.gate(tasksBody.items[0].form_version === '1.0.0', `expected form_version "1.0.0" right after v1 start, got "${tasksBody.items[0].form_version}"`)
    })

    // ── Step 02: open the real Task Inbox screen — the v1 field renders ──────
    await pl.step('02: EO-003 (before promotion) — Task Inbox renders the v1 field', async (s) => {
      await loginWithToken(page, s.adminToken)
      await navigateSpa(page, '/tasks')

      const row = page.getByTestId('task-row').filter({ has: page.getByTestId('task-name').getByText(v1Label) })
      await expect(row).toBeVisible({ timeout: 15_000 })
      await row.click()

      await expect(page.getByTestId('task-detail-panel')).toBeVisible()
      await expect(page.getByTestId(`form-field-${v1FieldName}`)).toBeVisible({ timeout: 10_000 })
      await expect(page.getByTestId(`form-field-${v2FieldName}`)).toHaveCount(0)

      await shot(page, 'tenant-switch-cache-isolation', 'eo003-v1-form-before-promotion')
    })

    // ── Step 03: promote v2 under the SAME process name with a DIFFERENT form ──
    await pl.step('03: activate v2 (same process name, different form field)', async (s) => {
      const createV2Resp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: {
          name: processKey,
          version: '2.0.0',
          description: 'tenant-switch-cache-isolation EO-003 pipeline fixture (v2)',
          graph: graphWithForm({
            properties: { [v2FieldName]: { type: 'string', title: 'Approval Decision (v2)' } },
            required: [],
          }),
        },
      })
      pl.gate(createV2Resp.ok(), `v2 definition create failed: ${createV2Resp.status()} ${await createV2Resp.text()}`)
      const v2 = await createV2Resp.json() as { id: string }

      const activateV2Resp = await request.post(
        `${API_BASE_URL}/api/v1/definitions/${v2.id}/activate`,
        { headers: authHeaders(s.adminToken) },
      )
      pl.gate(activateV2Resp.ok(), `v2 activate failed: ${activateV2Resp.status()} ${await activateV2Resp.text()}`)
    })

    // ── Step 04: the SAME already-open task must still show v1's field only ──
    await pl.step('04: EO-003 (after promotion) — the same task still shows only the v1 field', async (s) => {
      // Force a real refetch, not a stale in-memory render — reload the SPA
      // route so useTaskInbox/useTask re-query the backend from scratch.
      await page.reload({ waitUntil: 'domcontentloaded' })

      const row = page.getByTestId('task-row').filter({ has: page.getByTestId('task-name').getByText(v1Label) })
      await expect(row).toBeVisible({ timeout: 15_000 })
      await row.click()

      await expect(page.getByTestId('task-detail-panel')).toBeVisible()
      // The pin must hold: still v1's field, never v2's — proving the SPA
      // renders task.form_schema (frozen at activation) and never silently
      // re-resolves against the now-current process_definitions row.
      await expect(page.getByTestId(`form-field-${v1FieldName}`)).toBeVisible({ timeout: 10_000 })
      await expect(page.getByTestId(`form-field-${v2FieldName}`)).toHaveCount(0)

      // And the API body itself still names v1 — belt-and-braces against the
      // exact regression REQ-126 AC3 exists to prevent.
      const taskResp = await page.request.get(`${API_BASE_URL}/api/v1/tasks/${s.taskId}`, {
        headers: authHeaders(s.adminToken),
      })
      const taskBody = await taskResp.json() as { form_version?: string }
      expect(taskBody.form_version).toBe('1.0.0')

      await shot(page, 'tenant-switch-cache-isolation', 'eo003-v1-form-after-v2-promotion')
    })
  })
})
