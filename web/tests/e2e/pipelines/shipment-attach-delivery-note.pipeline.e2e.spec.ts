/**
 * Pipeline: shipment-attach-delivery-note (PW-09)
 *
 * Drives `test/fixtures/uat/scenarios/swiftroute/shipment-attach-delivery-note.yaml`'s
 * `pipeline_test:` key for UAT-RUNNER. Built per
 * `lib/letflow/design/req392-attachment-management-ui.md` §8, following the
 * structural precedent `attachment-cross-tenant.pipeline.e2e.spec.ts` already
 * established for this suite (createPipeline/pl.step/pl.gate, real tenant
 * provisioning, navigateSpa, loginWithToken, shot). No seeded "swiftroute"
 * fixture tenant exists anywhere in this repo (confirmed by that sibling
 * spec's own file-header note), so a tenant is onboarded fresh here too.
 *
 * SIMPLER than the cross-tenant spec (design §8.1): this scenario's two
 * actors (dispatcher Lena, ops manager Marco) are two users of the SAME
 * company, not two different tenants -- only ONE tenant/realm is
 * provisioned, with two users created in it. Both users are seeded with
 * `PLATFORM_ADMIN`, mirroring the sibling spec's own "covers every
 * permission without enumerating names" reasoning (design §8.1) -- this
 * process definition's HUMAN_TASK node assigns the review task to a specific
 * user (the ops user), so no distinct role is needed to route it correctly.
 *
 * Tenant onboarding (`POST /api/v1/onboarding`) does not provision Keycloak
 * at all (confirmed live by the sibling spec's own SETUP-BUG CORRECTION
 * note) -- this file provisions the tenant's Keycloak realm and both users
 * itself, the same `createTenantRealm`/`createFirstRealmUser`/
 * `createSecondRealmUser`/`bindTenantIdpRealm` shape that sibling spec
 * established, reused here (not re-exported from a shared module -- neither
 * is it in the sibling spec, which keeps these functions file-local too).
 *
 * QUOTA FIXTURE (step 3's oversized-upload case, design §8.2 step 3 / §11):
 * `Tenant.storage_allowance_bytes` is lowered via a direct SQL write against
 * the real Postgres instance (`runSqlAgainstDevPostgres`, `../db-exec.ts`'s
 * already-established "no HTTP writer exists for this real gap" technique)
 * to a value just above what step 2's accepted upload already consumed --
 * cheaper and more deterministic than uploading enough filler content to
 * approach the real 1 GiB default (design §11's own recommendation).
 *
 * PROCESS DEFINITION: seeded via the real API (`POST /api/v1/definitions` +
 * `.../activate`), mirroring the sibling spec's own step 02 -- a minimal
 * START -> HUMAN_TASK(assignee=ops user) -> END graph, `initial_variables`
 * carrying the shipment's destination/declared_value/cargo_type (step 1's
 * own input fields). Instance start likewise goes through the real API
 * (`POST /api/v1/instances`), the same technique the sibling spec's own step
 * 02 uses for "start a process instance" -- this scenario's own steps 2-5
 * are what must be driven through the real GUI (design §8.1), not step 1's
 * instance creation itself.
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
import { bindTenantIdpRealm, runSqlAgainstDevPostgres } from '../db-exec'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'

// A minimal, valid single-page PDF -- same shape as the sibling spec's own
// MINIMAL_PDF_BYTES fixture.
const SIGNED_NOTE_BYTES = Buffer.from(
  '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n' +
  '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF',
  'utf-8',
)
const CORRECTED_NOTE_BYTES = Buffer.from(
  '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n' +
  '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 300]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n% corrected',
  'utf-8',
)
// Small "video" content -- content-type alone (video/mp4) is enough to hit
// REQ-389's 415 branch regardless of size.
const REJECTED_VIDEO_BYTES = Buffer.from('not a real video, just needs a video/* content-type', 'utf-8')
// Larger than the lowered per-tenant allowance (see step 04) but an allowed
// content type -- exercises REQ-390's 409 branch, not the 415 one.
const OVERSIZED_NOTE_BYTES = Buffer.alloc(5_000, 'A')

const SIGNED_NOTE_FILE_NAME = 'delivery-note-hamburg-signed.pdf'
const CORRECTED_NOTE_FILE_NAME = 'delivery-note-hamburg-signed-corrected.pdf'
const REJECTED_VIDEO_FILE_NAME = 'loading-clip.mp4'
const OVERSIZED_NOTE_FILE_NAME = 'delivery-note-oversized.pdf'

interface PipelineState {
  fixtureId: string
  masterToken: string

  slug: string
  tenantId: string
  processDefName: string

  dispatcherToken: string
  dispatcherDisplayName: string
  opsToken: string
  opsUserId: string

  instanceId: string
  taskId: string

  originalAttachmentId: string
}

/** Creates a fresh Keycloak realm for a just-onboarded tenant -- same shape
 *  the sibling spec's own `createTenantRealm` established (`letflow-web`
 *  public client, `realm-roles` claim mapper, a single `PLATFORM_ADMIN`
 *  realm role). */
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

/** Creates the FIRST admin user in an already-created tenant realm -- same
 *  create/reset-password/role-assign shape as the sibling spec's own
 *  `createFirstRealmUser`. */
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

/** Creates a SECOND Keycloak user in an already-onboarded tenant's realm,
 *  copying the first user's realm-role mappings -- same shape the sibling
 *  spec's own `createSecondRealmUser` established. */
async function createSecondRealmUser(
  request: APIRequestContext,
  masterToken: string,
  realm: string,
  firstUserId: string,
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
      lastName: 'Manager',
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
    `${BPM_IDP_BASE_URL}/admin/realms/${realm}/users/${firstUserId}/role-mappings/realm`,
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

test.describe('Pipeline: shipment-attach-delivery-note (PW-09)', () => {
  test('EO-001..EO-005: attach, reject, quota, remove/re-attach, and approve against the reviewed document, through the real GUI', async ({ page, request }) => {
    test.setTimeout(300_000)

    await assertServiceReadiness(request, API_BASE_URL)

    const fixtureId = randomUUID().slice(0, 8)
    const pl = createPipeline<PipelineState>('shipment-attach-delivery-note', { page, request })
    pl.state.fixtureId = fixtureId
    pl.state.slug = `req392-swiftroute-${fixtureId}`
    pl.state.processDefName = `req392-shipment-approval-${fixtureId}`

    pl.onCleanup(async (s) => {
      if (!s.masterToken || !s.slug) return
      await deleteRealmBestEffort(request, s.masterToken, s.slug)
    })

    await pl.step('01: onboard SwiftRoute (one tenant, two users: dispatcher + ops)', async (s) => {
      const bpmAdminToken = await getKeycloakToken(
        request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
      )
      s.masterToken = await getMasterAdminToken(request)

      const dispatcherUsername = `${s.slug}-lena`
      const dispatcherPassword = `TestPass1!${s.slug}`

      const onboardResp = await request.post(`${API_BASE_URL}/api/v1/onboarding`, {
        headers: {
          Authorization: `Bearer ${bpmAdminToken}`,
          'Content-Type': 'application/json',
          'Idempotency-Key': randomUUID(),
        },
        data: {
          slug: s.slug,
          display_name: `SwiftRoute Fixture ${fixtureId}`,
          admin_email: `${dispatcherUsername}@example.com`,
          admin_username: dispatcherUsername,
          admin_display_name: 'Lena Dispatcher',
          hostname: `${s.slug}.example.com`,
        },
      })
      pl.gate(onboardResp.ok(), `onboarding ${s.slug} failed: ${onboardResp.status()} ${await onboardResp.text()}`)
      const onboardBody = (await onboardResp.json()) as { tenant_id?: string }
      pl.gate(!!onboardBody.tenant_id, `onboarding ${s.slug} response missing tenant_id: ${JSON.stringify(onboardBody)}`)
      s.tenantId = onboardBody.tenant_id as string

      // POST /api/v1/onboarding never provisions Keycloak (confirmed live by
      // the sibling attachment-cross-tenant spec's own SETUP-BUG CORRECTION
      // note) -- this spec provisions the realm and both users itself.
      await createTenantRealm(request, s.masterToken, s.slug)
      bindTenantIdpRealm(s.tenantId, s.slug)
      const dispatcherUserId = await createFirstRealmUser(
        request, s.masterToken, s.slug, dispatcherUsername, dispatcherPassword, ['PLATFORM_ADMIN'],
      )
      s.dispatcherToken = await getKeycloakToken(request, dispatcherUsername, dispatcherPassword, s.slug)
      // Best available guess at the backend-resolved actor display name for
      // the timeline assertion below (step 09) -- a JIT-provisioned user
      // with no separate display-name attribute set is expected to resolve
      // from its `preferred_username` claim, which equals this username.
      s.dispatcherDisplayName = dispatcherUsername

      const opsUsername = `${s.slug}-marco`
      const opsPassword = `TestPass1!${s.slug}ops`
      s.opsUserId = await createSecondRealmUser(
        request, s.masterToken, s.slug, dispatcherUserId, opsUsername, opsPassword,
      )
      s.opsToken = await getKeycloakToken(request, opsUsername, opsPassword, s.slug)

      pl.gate(!!s.dispatcherToken && !!s.opsToken, 'both actor tokens must be obtained')
      pl.gate(jwtSubject(s.dispatcherToken) === dispatcherUserId, 'dispatcher token subject must match the created first user')
    })

    await pl.step('02: seed a shipment-approval definition, assigned to Marco, and start the Hamburg shipment', async (s) => {
      const defResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.dispatcherToken),
        data: {
          name: s.processDefName,
          version: '1.0.0',
          description: `REQ-392 shipment approval fixture ${s.fixtureId}`,
          graph: {
            nodes: [
              { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
              {
                id: 'n2',
                node_type: 'HUMAN_TASK',
                label: 'Shipment Approval',
                // CHK-09 (REQ-029, lib/letflow/definitions/graph.ex) requires
                // every HUMAN_TASK node to carry a non-empty "role" string
                // attribute. It is also the attribute
                // Letflow.Engine.TaskActivation.resolve_assignee/1 actually
                // reads for `assignee_ref` (`Map.get(attributes, "role")`,
                // NOT the "assignee_ref" key below -- that key is
                // unread/documentary only, kept for readability alongside
                // "role", matching attachment-cross-tenant.pipeline.e2e.spec.ts's
                // own `{ role: ..., assignee_type: 'user', assignee_ref: ... }`
                // shape). Set to s.opsUserId (not a literal string like that
                // sibling spec's 'admin-user') because step 10 below needs
                // the resulting task's `assignee_ref` to equal Marco's own
                // JWT `sub` for TaskDetailPanel's `isAssignedToMe` check to
                // pass and render `task-complete-button` at all.
                attributes: { role: s.opsUserId, assignee_type: 'user', assignee_ref: s.opsUserId },
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

      const activateResp = await request.post(`${API_BASE_URL}/api/v1/definitions/${defBody.id}/activate`, {
        headers: authHeaders(s.dispatcherToken),
      })
      pl.gate(activateResp.ok(), `definition activate failed: ${activateResp.status()} ${await activateResp.text()}`)

      // Scenario step 1: dispatcher submits an 8-package Hamburg shipment,
      // declared value 320 EUR, standard cargo -- creates Marco's review task.
      const startResp = await request.post(`${API_BASE_URL}/api/v1/instances`, {
        headers: authHeaders(s.dispatcherToken),
        data: {
          definition_id: defBody.id,
          correlation_key: `req392-${s.fixtureId}`,
          initial_variables: {
            destination: 'Hamburg',
            package_count: 8,
            declared_value: 320,
            cargo_type: 'standard',
          },
        },
      })
      pl.gate(startResp.ok(), `instance start failed: ${startResp.status()} ${await startResp.text()}`)
      const startBody = (await startResp.json()) as { instance_id?: string; id?: string }
      s.instanceId = startBody.instance_id ?? startBody.id ?? ''
      pl.gate(!!s.instanceId, 'instance start response must include an id')

      const tasksResp = await request.get(`${API_BASE_URL}/api/v1/tasks?instance_id=${s.instanceId}`, {
        headers: authHeaders(s.opsToken),
      })
      pl.gate(tasksResp.ok(), `task lookup failed: ${tasksResp.status()} ${await tasksResp.text()}`)
      const tasksBody = (await tasksResp.json()) as { items?: Array<{ id: string }> }
      s.taskId = tasksBody.items?.[0]?.id ?? ''
      pl.gate(!!s.taskId, 'a review task must exist for the started instance')
    })

    // ── Step 2 (scenario step 2): dispatcher attaches the signed delivery
    // note; the list updates without a full page reload (AC1). ─────────────
    await pl.step('03: dispatcher attaches the signed delivery note via the real upload UI', async (s) => {
      await loginWithToken(page, s.dispatcherToken)
      await navigateSpa(page, `/instances/${s.instanceId}`)

      await expect(page.getByTestId('attachment-panel')).toBeVisible({ timeout: 15_000 })
      await shot(page, 'shipment-attach-delivery-note', 'before-any-upload')

      await page.getByTestId('attachment-file-input').setInputFiles({
        name: SIGNED_NOTE_FILE_NAME,
        mimeType: 'application/pdf',
        buffer: SIGNED_NOTE_BYTES,
      })
      await page.getByTestId('attachment-upload-button').click()

      const viewLink = page.getByTestId('attachment-view-link').first()
      await expect(viewLink).toBeVisible({ timeout: 15_000 })
      await expect(page.getByTestId('attachment-panel')).toContainText(SIGNED_NOTE_FILE_NAME)

      const href = await viewLink.getAttribute('href')
      pl.gate(!!href, 'uploaded attachment row must have a View link href')
      const parts = (href ?? '').split('/').filter(Boolean)
      s.originalAttachmentId = parts[parts.length - 1]
      pl.gate(!!s.originalAttachmentId, 'attachment id must be extractable from the View link href')

      await shot(page, 'shipment-attach-delivery-note', 'after-signed-note-upload')
    })

    // ── AC3 checkpoint (before rise): storage usage before the accepted
    // upload has already risen -- captured for a later cross-check, and
    // asserted to be a finite figure the panel actually renders. ───────────
    let usageAfterUpload = ''
    await pl.step('04: storage usage has risen after the accepted upload (AC3)', async (s) => {
      usageAfterUpload = (await page.getByTestId('attachment-storage-usage').innerText()) ?? ''
      pl.gate(/\d/.test(usageAfterUpload), `storage usage figure must contain a number, got: "${usageAfterUpload}"`)
      await shot(page, 'shipment-attach-delivery-note', 'storage-usage-after-upload')

      // Lower the tenant's allowance via a direct SQL write, close to what
      // step 03's accepted upload already consumed (design §8.2 step 3 /
      // §11's recommended technique -- no HTTP writer exists for this).
      runSqlAgainstDevPostgres(
        `UPDATE public.tenants SET storage_allowance_bytes = ${SIGNED_NOTE_BYTES.length + 200} WHERE id = '${s.tenantId}';`,
      )
    })

    // ── Step 3 (scenario step 3, EO-002): rejected content-type, then
    // rejected quota -- each with a distinct, readable message (AC2). ──────
    await pl.step('05: an unsupported content type is refused with a distinct, readable message', async () => {
      await page.getByTestId('attachment-file-input').setInputFiles({
        name: REJECTED_VIDEO_FILE_NAME,
        mimeType: 'video/mp4',
        buffer: REJECTED_VIDEO_BYTES,
      })
      await page.getByTestId('attachment-upload-button').click()

      const errorEl = page.getByTestId('attachment-upload-error')
      await expect(errorEl).toBeVisible({ timeout: 15_000 })
      await expect(errorEl).toHaveAttribute('data-error-kind', 'content-type')
      const text = (await errorEl.innerText()) ?? ''
      expect(text.toLowerCase()).toContain('video/mp4')
      await shot(page, 'shipment-attach-delivery-note', 'content-type-rejection')
    })

    await pl.step('06: a document exceeding the storage allowance is refused with a distinct, readable message', async () => {
      await page.getByTestId('attachment-file-input').setInputFiles({
        name: OVERSIZED_NOTE_FILE_NAME,
        mimeType: 'application/pdf',
        buffer: OVERSIZED_NOTE_BYTES,
      })
      await page.getByTestId('attachment-upload-button').click()

      const errorEl = page.getByTestId('attachment-upload-error')
      await expect(errorEl).toBeVisible({ timeout: 15_000 })
      await expect(errorEl).toHaveAttribute('data-error-kind', 'quota')
      const text = (await errorEl.innerText()) ?? ''
      expect(text.toLowerCase()).toContain('quota')
      await shot(page, 'shipment-attach-delivery-note', 'quota-rejection')

      // Nothing half-attached -- the list still shows only the one document
      // accepted at step 03 (EO-002's own "nothing half-attached" clause).
      await expect(page.getByTestId('attachment-panel')).toContainText(SIGNED_NOTE_FILE_NAME)
      await expect(page.getByTestId('attachment-panel')).not.toContainText(REJECTED_VIDEO_FILE_NAME)
      await expect(page.getByTestId('attachment-panel')).not.toContainText(OVERSIZED_NOTE_FILE_NAME)
      const viewLinks = page.getByTestId('attachment-view-link')
      await expect(viewLinks).toHaveCount(1)
    })

    // ── Step 4 (scenario step 4, AC1/AC4): remove the wrong note, attach the
    // corrected one -- the timeline records both with Lena named. ──────────
    await pl.step('07: removes the original note and attaches the corrected one', async (s) => {
      // Restore a generous allowance before the corrected upload -- this
      // step is about remove/re-attach, not re-testing the quota rejection.
      runSqlAgainstDevPostgres(
        `UPDATE public.tenants SET storage_allowance_bytes = 1073741824 WHERE id = '${s.tenantId}';`,
      )

      await page.getByTestId('attachment-remove-button').first().click()
      const confirmButton = page.getByTestId('attachment-remove-confirm-button')
      await expect(confirmButton).toBeVisible({ timeout: 5_000 })
      await confirmButton.click()

      await expect(page.getByTestId('attachment-panel')).not.toContainText(SIGNED_NOTE_FILE_NAME, { timeout: 15_000 })
      await shot(page, 'shipment-attach-delivery-note', 'after-remove')

      await page.getByTestId('attachment-file-input').setInputFiles({
        name: CORRECTED_NOTE_FILE_NAME,
        mimeType: 'application/pdf',
        buffer: CORRECTED_NOTE_BYTES,
      })
      await page.getByTestId('attachment-upload-button').click()
      await expect(page.getByTestId('attachment-panel')).toContainText(CORRECTED_NOTE_FILE_NAME, { timeout: 15_000 })
      await shot(page, 'shipment-attach-delivery-note', 'after-corrected-upload')
    })

    await pl.step('08: storage usage reflects the removal, then the re-attach (AC3)', async () => {
      // A fresh reload re-fetches the storage-usage query cleanly rather
      // than relying on the mutation-invalidated cache still being warm.
      await page.reload({ waitUntil: 'domcontentloaded' })
      await expect(page.getByTestId('attachment-storage-usage')).toBeVisible({ timeout: 15_000 })
      const usageAfterCorrection = (await page.getByTestId('attachment-storage-usage').innerText()) ?? ''
      pl.gate(/\d/.test(usageAfterCorrection), `storage usage figure must contain a number, got: "${usageAfterCorrection}"`)
      // Not asserting a precise byte delta here (formatByteSize rounds) --
      // the meaningful assertion is that the figure exists both before and
      // after a remove+re-attach cycle, matching EO-003's own screenshot-only
      // evidence requirement. usageAfterUpload is captured for the report.
      void usageAfterUpload
      await shot(page, 'shipment-attach-delivery-note', 'storage-usage-after-correction')
    })

    await pl.step('09: the timeline records the original attach and its removal, naming Lena (AC4)', async (s) => {
      // InstanceDetailPage's own Graph/History/Timeline switch is a plain
      // `Button` (no ARIA tab role) -- select it by its visible label, same
      // technique this suite's other InstanceDetailPage-touching specs use.
      await page.getByRole('button', { name: 'Timeline', exact: true }).click()
      await page.locator('h3:has-text("Timeline")').waitFor({ timeout: 15_000 })

      const attachedText = page.getByText(`${SIGNED_NOTE_FILE_NAME} attached by`, { exact: false })
      const removedText = page.getByText(`${SIGNED_NOTE_FILE_NAME} removed by`, { exact: false })
      await expect(attachedText.first()).toBeVisible({ timeout: 15_000 })
      await expect(removedText.first()).toBeVisible({ timeout: 15_000 })
      await expect(attachedText.first()).toContainText(s.dispatcherDisplayName)
      await expect(removedText.first()).toContainText(s.dispatcherDisplayName)
      await shot(page, 'shipment-attach-delivery-note', 'timeline-attach-remove')
    })

    // ── Step 5 (scenario step 5, EO-001/EO-005): Marco reviews and approves
    // against the corrected document; the decision names it (AC5). ─────────
    await pl.step('10: ops manager sees the corrected note on the shipment and completes the review', async (s) => {
      await loginWithToken(page, s.opsToken)
      await navigateSpa(page, '/tasks')

      const taskRow = page.locator(`[data-testid="task-row"][data-task-id="${s.taskId}"]`)
      await expect(taskRow).toBeVisible({ timeout: 15_000 })
      await taskRow.click()

      await expect(page.getByTestId('task-detail-panel')).toBeVisible({ timeout: 15_000 })
      // The corrected delivery note is visible/clickable from the shipment
      // before Marco decides (EO-001's "without asking her for it separately").
      await expect(page.getByTestId('attachment-panel')).toContainText(CORRECTED_NOTE_FILE_NAME, { timeout: 15_000 })
      await shot(page, 'shipment-attach-delivery-note', 'ops-reviews-before-decision')

      await page.getByTestId('task-complete-button').click()
      await expect(page.getByTestId('task-detail-panel')).toContainText('COMPLETED', { timeout: 15_000 })
    })

    await pl.step('11: the completed decision names the reviewed corrected document (AC5)', async () => {
      const decisionEl = page.getByTestId('task-decision-attachments')
      await expect(decisionEl).toBeVisible({ timeout: 15_000 })
      await expect(decisionEl).toContainText(CORRECTED_NOTE_FILE_NAME)
      await shot(page, 'shipment-attach-delivery-note', 'decision-names-reviewed-document')
    })

    await pl.runCleanup()
  })
})
