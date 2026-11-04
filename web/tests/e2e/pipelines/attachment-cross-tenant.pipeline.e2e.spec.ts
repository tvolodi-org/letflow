/**
 * Pipeline: attachment-cross-tenant-probe (PW-09)
 *
 * Drives `test/fixtures/uat/scenarios/platform/attachment-cross-tenant-probe.yaml`'s
 * `pipeline_test:` key for UAT-RUNNER. Built per
 * `lib/letflow/design/req387-attachment-document-viewer.md` §4, following the
 * structural precedent `tenant-cache.pipeline.e2e.spec.ts` already established
 * for this suite (createPipeline/pl.step/pl.gate, real second-tenant
 * provisioning, navigateSpa, loginWithToken, shot).
 *
 * Two genuinely separate tenants are provisioned for real (own Keycloak
 * realm, own Postgres schema, real synchronous onboarding) — no seeded
 * "swiftroute"/"vortex" fixture tenant exists anywhere in this repo
 * (grepped `priv/keycloak/realms/*.json` and every existing e2e spec: only
 * `bpm-default` is pre-seeded), so both are onboarded fresh here, uniquely
 * named per run via `fixtureId`.
 *
 * SETUP-BUG CORRECTION (TEST-DESIGNER, 2026-09-23, against a real running
 * stack): the original `onboardTenantWithAdminToken()` below assumed
 * `POST /api/v1/onboarding`'s response carries an `admin_user_id` field.
 * Confirmed live it never does -- `Letflow.Routers.Onboarding.onboarding_map/1`
 * returns exactly `{id, tenant_id, slug, hostname, created_at}`, and that
 * router's own moduledoc ("What is deliberately NOT ported") states plainly
 * that Keycloak realm/client/admin-user provisioning is not part of this
 * flow at all -- confirmed live too: a tenant onboarded this way has
 * `idp_realm_id: nil` and no Keycloak realm of its own whatsoever (verified
 * against this run's own stack: `GET /admin/realms/<slug>` 404s right after
 * onboarding returns 201). So the fix is not just "read the admin user id
 * from a different field" -- there is no admin user, and no realm, for this
 * spec's `onboardTenantWithAdminToken()` to find one in. The corrected
 * function below does the same "no HTTP writer exists for this real gap"
 * thing this file's own `createSecondRealmUser()` already does for a second
 * user, extended one step further: it also creates the tenant's Keycloak
 * REALM itself (mirroring `priv/keycloak/realms/bpm-default.json`'s own
 * `letflow-web` client + protocol-mapper shape, real Admin API POST, not a
 * fixture file) and binds it onto the tenant row via
 * `bindTenantIdpRealm()` (`../db-exec.ts`) -- a direct `Letflow.Repo` write,
 * the same "no HTTP path exists, and by design never will" technique
 * `insertTenantMembershipSql` already established in this suite for
 * `tenant_memberships`, needed here because `idp_realm_id` is immutable
 * after a tenant's initial (Keycloak-less) creation
 * (`Letflow.Identity.Tenant`'s own moduledoc). The FIRST admin user is then
 * created in that realm directly via the Keycloak Admin API too --
 * `createFirstRealmUser()`, the same create/reset-password/role-assign shape
 * `createSecondRealmUser()` already established, just seeded with an
 * explicit `PLATFORM_ADMIN` realm role (fetched by name, not hard-coded as
 * an id) instead of copying an existing user's mappings, since there is no
 * existing user yet to copy from. Verified live end-to-end before this
 * spec's own run: a token from a realm created this way, for a user created
 * this way, is accepted by the real running backend
 * (`GET /api/v1/definitions` -> 200, real JIT-provisioned local user) once
 * `bindTenantIdpRealm()` has run.
 *
 * ENVIRONMENT NOTE (TEST-DESIGNER, 2026-09-23, live run against a real
 * stack): `config/dev.exs`'s `pool_size: 10` (-> `Letflow.Plugs.Admission`'s
 * `global_cap` of 8, `pool_size - reserved_headroom`) is comfortably enough
 * for one developer clicking through the SPA by hand, but is thin enough
 * relative to Playwright's fast, densely-concurrent automated pacing (this
 * pipeline's own AppShell sidebar alone fires 5-8 parallel requests per
 * navigation) that intermittent, EVERY-ENDPOINT-ALIKE 503 "server at
 * capacity, retry shortly" responses are a real, reproducible risk running
 * this spec against a `pool_size: 10` backend — confirmed by isolating it
 * from every other candidate cause across several live runs: not
 * REQ-387/REQ-386 attachment logic (every individual branch below was
 * independently observed correct whenever it wasn't hit by a 503), not this
 * spec's own realm/tenant fixtures (a probe against `bpm-default`'s own
 * long-lived realm hit the identical pattern), not a `POOL_SIZE` env var
 * (config/runtime.exs only reads `POOL_SIZE` under `config_env() == :prod`
 * -- inert for `MIX_ENV=dev`, confirmed live), and not a permanent
 * admission-ref leak (an idle burst of 15 sequential requests right after a
 * flaky run all returned 200 -- capacity fully self-heals once concurrent
 * load drops). A LOCAL, temporary `config/dev.exs` `pool_size: 40` bump
 * (reverted before this commit -- never shipped) made this exact spec pass
 * cleanly end-to-end with zero 503s across all eight steps. Not fixed here
 * -- `config/dev.exs`'s real, permanent pool sizing is outside TEST-DESIGNER's
 * mandate and affects every spec in this suite alike, not a REQ-387 concern
 * to loosen this file's own assertions around. If this spec (or any other
 * AppShell-heavy one) shows intermittent, error-generic (not not-found/
 * expired-specific) failures in CI, raising `config/dev.exs`'s `pool_size`
 * (or `Letflow.Plugs.Admission`'s `reserved_headroom`/global-cap math) is
 * the real fix to route to ELIXIR-DEV, not a retry loop bolted onto this file.
 *
 * SwiftRoute needs TWO distinct logged-in users (dispatcher + ops, matching
 * the scenario's own two-actor split within one company) — REQ-384's
 * onboarding path provisions exactly one admin user per tenant (as of the
 * correction above, exactly one admin user THIS SPEC provisions itself) and
 * ships no HTTP route to add a second Keycloak user to an existing realm, so
 * a second user is created directly via the Keycloak Admin REST API
 * (`POST /admin/realms/:realm/users`), with the SAME realm-role mappings as
 * the onboarded admin user copied onto it (role names are this deployment's
 * own detail, not hard-coded here) so it carries the same `:AttachmentsRead`/
 * `:AttachmentsManage` permissions without needing to know their names.
 *
 * EXPIRY (step 4): REQ-386's `AttachmentLinks.issue/3` `opts[:now]` clock
 * injection is Elixir-internal only — not reachable over HTTP (design §4
 * step 4 / §9 OQ-3) — so this spec pays a real ~300s wait for the shipped
 * `@link_expiry_seconds` to elapse, inside a generous `test.setTimeout`, the
 * same real-time cost class this suite's own tenant-onboarding specs already
 * accept. If that proves too expensive for CI, REQ-386 would need a
 * follow-up test-only expiry override (design §9 OQ-3) — not invented here.
 */

import { test, expect, type APIRequestContext } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  authHeaders,
  jwtSubject,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential, BPM_IDP_BASE_URL, getMasterAdminToken } from '../helpers'
import { bindTenantIdpRealm } from '../db-exec'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'

// A minimal, valid single-page PDF — enough for AttachmentSuccessView's
// `contentType.startsWith('application/pdf')` branch to render an <iframe>.
const MINIMAL_PDF_BYTES = Buffer.from(
  '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n' +
  '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF',
  'utf-8',
)
const FIXTURE_FILE_NAME = 'delivery-note-hamburg.pdf'

interface PipelineState {
  fixtureId: string
  masterToken: string

  swiftrouteSlug: string
  swiftrouteTenantId: string
  dispatcherToken: string
  opsToken: string

  vortexSlug: string
  vortexTenantId: string
  vortexToken: string

  processDefName: string
  swiftrouteInstanceId: string
  swiftrouteAttachmentId: string

  expiredLinkUrl: string
}

/** Creates a fresh Keycloak realm for a just-onboarded tenant, mirroring
 *  `priv/keycloak/realms/bpm-default.json`'s own `letflow-web` client shape
 *  (public, `directAccessGrantsEnabled` for the password-grant technique
 *  `getKeycloakToken`/env-fixture helpers across this suite already use,
 *  plus the `realm-roles` claim-name-"roles" protocol mapper the backend's
 *  own `Letflow.Oidc.ClaimMappingConfig.default/1` reads by default) and a
 *  single `PLATFORM_ADMIN` realm role (sufficient on its own --
 *  `Letflow.Api.Authorization.role_allows?(:PLATFORM_ADMIN, _permission)`
 *  is unconditionally `true`, covering `:AttachmentsManage`/`:AttachmentsRead`
 *  without this file needing to enumerate every permission name).
 *
 *  Exists because `POST /api/v1/onboarding` itself never provisions
 *  Keycloak at all (confirmed live -- see this file's own top-of-file
 *  SETUP-BUG CORRECTION note); nothing else in this codebase creates a
 *  realm for a self-service-onboarded tenant, so this spec must.
 *
 *  `accessTokenLifespan: 3600` (not Keycloak's own 300s realm default,
 *  confirmed live -- a fresh realm created without this override inherits
 *  a 300s token lifespan) is required, not cosmetic: step 07 below
 *  deliberately waits ~310s for REQ-386's OWN, separate 300s
 *  `@link_expiry_seconds` link-token expiry to elapse while staying
 *  logged in as `opsToken`. Confirmed live the hard way -- without this
 *  override, the Keycloak-issued BEARER token backing `opsToken` also
 *  expires at the ~300s mark (same default as the link token, pure
 *  coincidence of Keycloak's own realm default), so `AuthPipeline`'s
 *  token verification 401s the reload BEFORE the route handler ever
 *  reaches `AttachmentLinks.verify/2`'s own 410 check -- `client.ts`'s
 *  `throwOnErrorResponse` dispatches `auth:session-expired` on any 401,
 *  which forces a REAL top-level Keycloak login redirect (to `bpm-default`,
 *  this app's hardcoded fallback realm, since this fake injected session
 *  carries no real `tenantConfig.ts` realm-slug cache) instead of ever
 *  showing `AttachmentLinkExpiredScreen`. Not a REQ-386/REQ-387 defect --
 *  a fixture-realm setting this spec must control so its OWN two
 *  different 300s-scale clocks (Keycloak token lifespan vs. REQ-386 link
 *  expiry) don't race each other. */
async function createTenantRealm(request: APIRequestContext, masterToken: string, slug: string): Promise<void> {
  const createResp = await request.post(`${BPM_IDP_BASE_URL}/admin/realms`, {
    headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
    data: {
      realm: slug,
      enabled: true,
      accessTokenLifespan: 3600,
      roles: { realm: [{ name: 'PLATFORM_ADMIN' }] },
      clients: [
        {
          clientId: 'letflow-web',
          enabled: true,
          protocol: 'openid-connect',
          publicClient: true,
          directAccessGrantsEnabled: true,
          standardFlowEnabled: true,
          redirectUris: ['*'],
          webOrigins: ['*'],
          protocolMappers: [
            {
              name: 'realm-roles',
              protocol: 'openid-connect',
              protocolMapper: 'oidc-usermodel-realm-role-mapper',
              consentRequired: false,
              config: {
                multivalued: 'true',
                'userinfo.token.claim': 'true',
                'id.token.claim': 'true',
                'access.token.claim': 'true',
                'claim.name': 'roles',
                'jsonType.label': 'String',
              },
            },
            {
              name: 'letflow-web-audience',
              protocol: 'openid-connect',
              protocolMapper: 'oidc-audience-mapper',
              consentRequired: false,
              config: {
                'included.client.audience': 'letflow-web',
                'included.custom.audience': '',
                'id.token.claim': 'false',
                'access.token.claim': 'true',
              },
            },
          ],
        },
      ],
    },
  })
  if (!createResp.ok()) {
    throw new Error(`create realm ${slug} failed: ${createResp.status()} ${await createResp.text()}`)
  }
}

/** Creates the FIRST admin user in an already-created tenant realm, directly
 *  via the Keycloak Admin API, seeded with `roleNames` fetched by name (not
 *  hard-coded ids) -- the same create/reset-password/role-assign shape
 *  `createSecondRealmUser()` below already established for a second user in
 *  an existing realm, just without an existing user's mappings to copy
 *  (there is none yet): the roles are looked up and assigned directly. */
async function createFirstRealmUser(
  request: APIRequestContext,
  masterToken: string,
  realm: string,
  username: string,
  password: string,
  roleNames: string[],
): Promise<string> {
  const createResp = await request.post(`${BPM_IDP_BASE_URL}/admin/realms/${realm}/users`, {
    headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
    data: {
      username,
      email: `${username}@example.com`,
      enabled: true,
      emailVerified: true,
      firstName: 'Tenant',
      lastName: 'Admin',
    },
  })
  if (!createResp.ok()) {
    throw new Error(`create first realm user ${username} failed: ${createResp.status()} ${await createResp.text()}`)
  }
  const location = createResp.headers()['location'] ?? ''
  const userId = location.split('/').pop() ?? ''
  if (!userId) {
    throw new Error(`create first realm user ${username}: could not extract user id from Location header`)
  }

  const resetResp = await request.put(`${BPM_IDP_BASE_URL}/admin/realms/${realm}/users/${userId}/reset-password`, {
    headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
    data: { type: 'password', value: password, temporary: false },
  })
  if (resetResp.status() !== 204) {
    throw new Error(`password set for ${username} failed: ${resetResp.status()} ${await resetResp.text()}`)
  }

  for (const roleName of roleNames) {
    const roleResp = await request.get(`${BPM_IDP_BASE_URL}/admin/realms/${realm}/roles/${roleName}`, {
      headers: { Authorization: `Bearer ${masterToken}` },
    })
    if (!roleResp.ok()) {
      throw new Error(`lookup role ${roleName} in realm ${realm} failed: ${roleResp.status()} ${await roleResp.text()}`)
    }
    const roleRep = await roleResp.json()
    const assignResp = await request.post(`${BPM_IDP_BASE_URL}/admin/realms/${realm}/users/${userId}/role-mappings/realm`, {
      headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
      data: [roleRep],
    })
    if (!assignResp.ok()) {
      throw new Error(`assign role ${roleName} to ${username} failed: ${assignResp.status()} ${await assignResp.text()}`)
    }
  }

  return userId
}

/** Onboard a fresh, genuinely separate tenant: real Postgres schema via the
 *  real `POST /api/v1/onboarding` saga (provisioned+migrated synchronously —
 *  same shape tenant-cache.pipeline's own EO-001 step 02 already
 *  established), PLUS a real Keycloak realm + first admin user this spec
 *  creates itself (`createTenantRealm`/`createFirstRealmUser`/
 *  `bindTenantIdpRealm`, all above/imported) — `POST /api/v1/onboarding`
 *  never provisions either (confirmed live; see this file's top-of-file
 *  SETUP-BUG CORRECTION note). Returns the new tenant's id/slug and a real
 *  Keycloak token for its admin user, obtained the same reset-password +
 *  password-grant technique env04.e2e.spec.ts's `onboardTestTenantFixture`
 *  already established. */
async function onboardTenantWithAdminToken(
  request: APIRequestContext,
  bpmAdminToken: string,
  masterToken: string,
  slug: string,
  displayName: string,
): Promise<{ tenantId: string; adminToken: string; adminUserId: string; adminUsername: string; adminPassword: string }> {
  const adminUsername = `${slug}-admin`
  const adminPassword = `TestPass1!${slug}`

  const onboardResp = await request.post(`${API_BASE_URL}/api/v1/onboarding`, {
    headers: {
      Authorization: `Bearer ${bpmAdminToken}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': randomUUID(),
    },
    data: {
      slug,
      display_name: displayName,
      admin_email: `${adminUsername}@example.com`,
      admin_username: adminUsername,
      admin_display_name: `${displayName} Admin`,
      hostname: `${slug}.example.com`,
    },
  })
  if (!onboardResp.ok()) {
    throw new Error(`onboarding ${slug} failed: ${onboardResp.status()} ${await onboardResp.text()}`)
  }
  // Letflow.Routers.Onboarding.handle_create/1 provisions+migrates the
  // tenant's Postgres schema SYNCHRONOUSLY within this one POST (confirmed
  // by tenant-cache.pipeline's own step 02 comment, re-checked here) -- no
  // onboarding_id poll needed. It does NOT provision Keycloak at all
  // (confirmed live -- see top-of-file SETUP-BUG CORRECTION note), so the
  // response never carries an admin_user_id; that identity is created below
  // by this spec itself instead.
  const onboardBody = (await onboardResp.json()) as { tenant_id?: string }
  if (!onboardBody.tenant_id) {
    throw new Error(`onboarding ${slug} response missing tenant_id: ${JSON.stringify(onboardBody)}`)
  }
  const tenantId = onboardBody.tenant_id

  await createTenantRealm(request, masterToken, slug)
  bindTenantIdpRealm(tenantId, slug)
  const adminUserId = await createFirstRealmUser(
    request, masterToken, slug, adminUsername, adminPassword, ['PLATFORM_ADMIN'],
  )

  const adminToken = await getKeycloakToken(request, adminUsername, adminPassword, slug)
  return { tenantId, adminToken, adminUserId, adminUsername, adminPassword }
}

/** Create a SECOND Keycloak user in an already-onboarded tenant's realm,
 *  copying the first (admin) user's realm-role mappings verbatim so it
 *  carries the same platform-role permissions (:AttachmentsRead included)
 *  without this file needing to know this deployment's real role names.
 *  No HTTP route in this codebase creates a second user in an existing
 *  tenant realm (REQ-384's onboarding provisions exactly one) -- this is
 *  the Keycloak-admin-API equivalent of tenant-cache.pipeline's own
 *  direct-SQL techniques for a gap with no HTTP writer. */
async function createSecondRealmUser(
  request: APIRequestContext,
  masterToken: string,
  realm: string,
  firstAdminUserId: string,
  username: string,
  password: string,
): Promise<string> {
  const createResp = await request.post(`${BPM_IDP_BASE_URL}/admin/realms/${realm}/users`, {
    headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
    data: {
      username,
      email: `${username}@example.com`,
      enabled: true,
      emailVerified: true,
      firstName: 'Ops',
      lastName: 'User',
    },
  })
  if (!createResp.ok()) {
    throw new Error(`create second realm user ${username} failed: ${createResp.status()} ${await createResp.text()}`)
  }
  const location = createResp.headers()['location'] ?? ''
  const newUserId = location.split('/').pop() ?? ''
  if (!newUserId) {
    throw new Error(`create second realm user ${username}: could not extract user id from Location header`)
  }

  const resetResp = await request.put(`${BPM_IDP_BASE_URL}/admin/realms/${realm}/users/${newUserId}/reset-password`, {
    headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
    data: { type: 'password', value: password, temporary: false },
  })
  if (resetResp.status() !== 204) {
    throw new Error(`password set for ${username} failed: ${resetResp.status()} ${await resetResp.text()}`)
  }

  const roleMappingsResp = await request.get(
    `${BPM_IDP_BASE_URL}/admin/realms/${realm}/users/${firstAdminUserId}/role-mappings/realm`,
    { headers: { Authorization: `Bearer ${masterToken}` } },
  )
  if (roleMappingsResp.ok()) {
    const roles = await roleMappingsResp.json()
    if (Array.isArray(roles) && roles.length > 0) {
      await request.post(`${BPM_IDP_BASE_URL}/admin/realms/${realm}/users/${newUserId}/role-mappings/realm`, {
        headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
        data: roles,
      })
    }
  }

  return newUserId
}

async function deleteRealmBestEffort(request: APIRequestContext, masterToken: string, realm: string): Promise<void> {
  try {
    await request.delete(`${BPM_IDP_BASE_URL}/admin/realms/${realm}`, {
      headers: { Authorization: `Bearer ${masterToken}` },
    })
  } catch { /* best-effort cleanup only */ }
}

test.describe('Pipeline: attachment-cross-tenant-probe (PW-09)', () => {
  test('EO-001..EO-004: cross-tenant not-found folding, expiry, and fresh-link recovery through the real GUI', async ({ page, request }) => {
    // Two real tenant onboardings (own realm + own schema each) plus a real
    // ~300s expiry wait -- generous budget, same class of cost
    // tenant-cache.pipeline.e2e.spec.ts's own EO-001 test already accepts.
    test.setTimeout(600_000)

    await assertServiceReadiness(request, API_BASE_URL)

    const fixtureId = randomUUID().slice(0, 8)
    const pl = createPipeline<PipelineState>('attachment-cross-tenant-probe', { page, request })
    pl.state.fixtureId = fixtureId
    pl.state.swiftrouteSlug = `req387-swiftroute-${fixtureId}`
    pl.state.vortexSlug = `req387-vortex-${fixtureId}`
    pl.state.processDefName = `req387-shipment-approval-${fixtureId}`

    pl.onCleanup(async (s) => {
      if (!s.masterToken) return
      if (s.swiftrouteSlug) await deleteRealmBestEffort(request, s.masterToken, s.swiftrouteSlug)
      if (s.vortexSlug) await deleteRealmBestEffort(request, s.masterToken, s.vortexSlug)
    })

    await pl.step('01: onboard SwiftRoute and Vortex, each a genuinely separate tenant', async (s) => {
      const bpmAdminToken = await getKeycloakToken(
        request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
      )
      s.masterToken = await getMasterAdminToken(request)

      const swiftroute = await onboardTenantWithAdminToken(
        request, bpmAdminToken, s.masterToken, s.swiftrouteSlug, `SwiftRoute Fixture ${fixtureId}`,
      )
      s.swiftrouteTenantId = swiftroute.tenantId
      s.dispatcherToken = swiftroute.adminToken

      const opsUsername = `${s.swiftrouteSlug}-ops`
      const opsPassword = `TestPass1!${s.swiftrouteSlug}ops`
      // sub of the already-obtained dispatcher token -- avoids a second
      // Keycloak admin lookup-by-username round trip just to find the first
      // admin user's id.
      const dispatcherUserId = jwtSubject(s.dispatcherToken)
      await createSecondRealmUser(
        request, s.masterToken, s.swiftrouteSlug, dispatcherUserId, opsUsername, opsPassword,
      )
      s.opsToken = await getKeycloakToken(request, opsUsername, opsPassword, s.swiftrouteSlug)

      const vortex = await onboardTenantWithAdminToken(
        request, bpmAdminToken, s.masterToken, s.vortexSlug, `Vortex Fixture ${fixtureId}`,
      )
      s.vortexTenantId = vortex.tenantId
      s.vortexToken = vortex.adminToken

      pl.gate(!!s.dispatcherToken && !!s.opsToken && !!s.vortexToken, 'all three actor tokens must be obtained')
    })

    await pl.step('02: seed a shipment-approval definition and start an instance in SwiftRoute', async (s) => {
      const defResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.dispatcherToken),
        data: {
          name: s.processDefName,
          version: '1.0.0',
          description: `REQ-387 shipment approval fixture ${s.fixtureId}`,
          graph: {
            nodes: [
              { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
              {
                id: 'n2',
                node_type: 'HUMAN_TASK',
                label: 'Shipment Approval',
                attributes: { role: jwtSubject(s.dispatcherToken), assignee_type: 'USER', assignee_ref: jwtSubject(s.dispatcherToken) },
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
      pl.gate(defResp.ok(), `definition create failed: ${defResp.status()} ${await defResp.text()}`)
      const defBody = (await defResp.json()) as { id: string }

      // A freshly created definition is not startable -- `POST /instances`
      // 409s "only an ACTIVE definition can be started" (confirmed live)
      // until it's explicitly activated via `POST /definitions/:id/activate`
      // (`lib/letflow/routers/definitions.ex`, REQ-082). Not a REQ-387
      // concern; same activation step `createActiveDefinitionInSchema` in
      // `../db-exec.ts` already performs for its own direct-write fixture.
      const activateResp = await request.post(`${API_BASE_URL}/api/v1/definitions/${defBody.id}/activate`, {
        headers: authHeaders(s.dispatcherToken),
      })
      pl.gate(activateResp.ok(), `definition activate failed: ${activateResp.status()} ${await activateResp.text()}`)

      const startResp = await request.post(`${API_BASE_URL}/api/v1/instances`, {
        headers: authHeaders(s.dispatcherToken),
        // `initial_variables` is a required field on this endpoint
        // (`lib/letflow/routers/instances.ex`'s `@field_constraints`, `required: true`)
        // -- confirmed live: omitting it 422s with "field is required" before
        // this fix. Not a REQ-387 concern; an empty object is a valid,
        // meaningless payload this fixture's process graph never reads.
        data: { definition_id: defBody.id, correlation_key: `req387-${s.fixtureId}`, initial_variables: {} },
      })
      pl.gate(startResp.ok(), `instance start failed: ${startResp.status()} ${await startResp.text()}`)
      const startBody = (await startResp.json()) as { instance_id?: string; id?: string }
      s.swiftrouteInstanceId = startBody.instance_id ?? startBody.id ?? ''
      pl.gate(!!s.swiftrouteInstanceId, 'instance start response must include an id')
    })

    // ── Step 1 (scenario step 1): SwiftRoute dispatcher attaches the
    // delivery note via the real AttachmentPanel UI, captures the reference
    // the screen shows. ──────────────────────────────────────────────────
    await pl.step('03: dispatcher attaches the delivery note via the real upload UI', async (s) => {
      await loginWithToken(page, s.dispatcherToken)
      await navigateSpa(page, `/instances/${s.swiftrouteInstanceId}`)

      await expect(page.getByTestId('attachment-panel')).toBeVisible({ timeout: 15_000 })
      await page.getByTestId('attachment-file-input').setInputFiles({
        name: FIXTURE_FILE_NAME,
        mimeType: 'application/pdf',
        buffer: MINIMAL_PDF_BYTES,
      })
      await page.getByTestId('attachment-upload-button').click()

      const viewLink = page.getByTestId('attachment-view-link').first()
      await expect(viewLink).toBeVisible({ timeout: 15_000 })
      const href = await viewLink.getAttribute('href')
      pl.gate(!!href, 'uploaded attachment row must have a View link href')
      const parts = (href ?? '').split('/').filter(Boolean)
      // .../instances/:id/attachments/:attachmentId
      s.swiftrouteAttachmentId = parts[parts.length - 1]
      pl.gate(!!s.swiftrouteAttachmentId, 'attachment id must be extractable from the View link href')

      await shot(page, 'attachment-cross-tenant-probe', 'dispatcher-uploaded')
    })

    // ── Step 2 (scenario step 2, EO-001/EO-002): Vortex user opens the
    // foreign reference. ─────────────────────────────────────────────────
    let step2Text = ''
    await pl.step('04: Vortex user opens the SwiftRoute reference directly -- sees the not-found screen', async (s) => {
      await loginWithToken(page, s.vortexToken)
      await navigateSpa(page, `/instances/${s.swiftrouteInstanceId}/attachments/${s.swiftrouteAttachmentId}`)

      await expect(page.getByTestId('attachment-not-found')).toBeVisible({ timeout: 15_000 })
      step2Text = (await page.getByTestId('attachment-not-found').innerText()) ?? ''
      await shot(page, 'attachment-cross-tenant-probe', 'foreign-tenant-attachment')

      const bodyText = await page.locator('body').innerText()
      expect(bodyText).not.toContain(FIXTURE_FILE_NAME)
      // byte_size of MINIMAL_PDF_BYTES -- assert its digit sequence never
      // appears anywhere on the page either (EO-002's "no size" clause).
      expect(bodyText).not.toContain(String(MINIMAL_PDF_BYTES.length))
    })

    // ── Step 3 (scenario step 3, EO-001): Vortex user opens a never-issued
    // reference -- byte-identical screen, direct string equality. ──────────
    await pl.step('05: Vortex user opens a never-issued reference -- byte-identical to step 2', async () => {
      await navigateSpa(page, `/instances/${randomUUID()}/attachments/${randomUUID()}`)

      await expect(page.getByTestId('attachment-not-found')).toBeVisible({ timeout: 15_000 })
      const step3Text = (await page.getByTestId('attachment-not-found').innerText()) ?? ''
      await shot(page, 'attachment-cross-tenant-probe', 'never-issued-attachment')

      // The core EO-001 assertion: direct string equality, not "both show an
      // error" (design §5 / AC3's own literal wording).
      expect(step3Text).toBe(step2Text)
    })

    // ── Step 4 (scenario step 4, EO-003/EO-004 first half): SwiftRoute ops
    // opens the real document, then reuses the link after real expiry. ─────
    await pl.step('06: ops opens the real document on first attempt', async (s) => {
      await loginWithToken(page, s.opsToken)
      await navigateSpa(page, `/instances/${s.swiftrouteInstanceId}/attachments/${s.swiftrouteAttachmentId}`)

      await expect(page.getByTestId('attachment-content')).toBeVisible({ timeout: 15_000 })
      await shot(page, 'attachment-cross-tenant-probe', 'ops-first-open')

      const url = page.url()
      pl.gate(url.includes('link_token='), 'the page URL must carry the rewritten link_token query param (design §3.2 step 2)')
      s.expiredLinkUrl = url
    })

    await pl.step('07: wait for the real ~300s link expiry, then reuse the same link', async (s) => {
      // REQ-386's @link_expiry_seconds is 300s (design §0/§2.1); wait a
      // margin past it. No test-only clock injection is reachable over HTTP
      // (design §9 OQ-3) -- this is a real wait, not a mock.
      await page.waitForTimeout(310_000)

      await page.goto(s.expiredLinkUrl, { waitUntil: 'domcontentloaded' })

      await expect(page.getByTestId('attachment-link-expired')).toBeVisible({ timeout: 15_000 })
      await shot(page, 'attachment-cross-tenant-probe', 'ops-expired-link')
      await expect(page.getByTestId('attachment-content')).not.toBeVisible()
    })

    // ── Step 5 (scenario step 5, EO-004 second half): fresh link works. ────
    await pl.step('08: requesting a fresh link succeeds', async () => {
      await page.getByTestId('attachment-request-fresh-link').click()

      await expect(page.getByTestId('attachment-content')).toBeVisible({ timeout: 15_000 })
      await shot(page, 'attachment-cross-tenant-probe', 'ops-fresh-link')
    })

    // EO-005 (audit trail) is NOT re-verified here -- REQ-388 (status: done)
    // already ships and independently tests the audit write on the denied
    // branches server-side; steps 04/05 above incidentally exercise those
    // same denied branches, a reasonable side-confirmation but not this
    // spec's own assertion target (design §4, explicit scope statement).

    await pl.runCleanup()
  })
})
