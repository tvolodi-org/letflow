/**
 * Pipeline: Template Update Conflict Resolution (PW-01 / sys-definition-promotion)
 *
 * Drives `test/fixtures/uat/scenarios/platform/template-update-conflict-resolution.yaml`
 * against the real screens built by REQ-381
 * (`lib/letflow/design/req381-solution-pack-update-review-screen.md`), wired to
 * REQ-380's real `update-review`/`update-apply` endpoints and REQ-379's real
 * install-time base-snapshot write path. No mocks — real HTTP, real Postgres
 * state, matching REQ-381's own "wires to REQ-380's real endpoints" text.
 *
 * ## Fixture topology (design §8.1)
 *
 * Three process definitions installed as pack v1 (`unchanged-proc`,
 * `adapted-proc`, `untouched-proc`). The tenant then adapts ONLY
 * `adapted-proc` (a direct `PUT /definitions/:id`, the "existing
 * definitions-update path" design §8.1 step 3 names) — `unchanged-proc` and
 * `untouched-proc` are left exactly as installed. A pack v2 document is then
 * built naming the SAME tenant-local `definition_id`s the v1 install minted
 * (`installed_definitions[].new_definition_id` — the correlation key both
 * `solution_pack_artefact_bases` and this spec's own `theirs`/`incoming`
 * inputs are keyed by), changing `adapted-proc` (-> both_sides_conflict,
 * since the tenant independently changed it too) and `untouched-proc` (->
 * safe_to_update, the tenant never touched it) while leaving `unchanged-proc`
 * byte-identical (-> unchanged). This produces exactly the four-group split
 * EO-001 requires with the minimum fixture set.
 *
 * ## Chain topology
 *
 *   pre-check services -> login as PLATFORM_ADMIN
 *   -> 01: install pack v1 (API) -- unchanged-proc, adapted-proc, untouched-proc
 *   -> 02: adapt adapted-proc's live content (API)
 *   -> 03: EO-001 -- launcher + review screen (GUI), all four groups shown
 *   -> 04: EO-002 -- apply with no resolution is blocked, names adapted-proc
 *   -> 05: EO-003/EO-004 -- resolve keep-local on adapted-proc, apply (GUI)
 *   -> 06: EO-005 -- re-review the same v2 document does not re-flag adapted-proc
 *   -> cleanup: none required (matches the scenario's own
 *      `cleanup: cancel_open_instances: false` -- pack installs/resolutions
 *      are not instance state)
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  authHeaders,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential } from '../helpers'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'
const PACK_SCHEMA_VERSION = 'bpm/definition/v1'

interface TemplateUpdateConflictState {
  adminToken: string
  packId: string
  unchangedDefinitionId: string
  adaptedDefinitionId: string
  untouchedDefinitionId: string
}

function graphFor(fixtureId: string, label: string) {
  return {
    nodes: [
      { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
      { id: 'n2', node_type: 'HUMAN_TASK', label: `${label} ${fixtureId}`, attributes: { role: 'reviewer' } },
      { id: 'n3', node_type: 'END', label: 'End', attributes: null },
    ],
    edges: [
      { id: 'e1', source: 'n1', target: 'n2' },
      { id: 'e2', source: 'n2', target: 'n3' },
    ],
  }
}

function packDocument(
  packId: string,
  version: string,
  definitions: Array<{ definition_id: string; process_key: string; version: string; graph: unknown }>,
) {
  return {
    pack_id: packId,
    version,
    bpm_export_schema_version: PACK_SCHEMA_VERSION,
    exported_at: new Date().toISOString(),
    definitions,
    service_catalog_entries: [],
    variable_schemas: [],
    manifest: { required_roles: [] },
  }
}

test.describe('Pipeline: template-update-conflict-resolution (PW-01)', () => {
  test('own adaptations survive a pack update; unresolved conflicts block apply; resolutions are not re-flagged', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 8)
    const packId = `pl-pack-update-${fixtureId}`
    const unchangedKey = `pl-unchanged-${fixtureId}`
    const adaptedKey = `pl-adapted-${fixtureId}`
    const untouchedKey = `pl-untouched-${fixtureId}`

    const pl = createPipeline<TemplateUpdateConflictState>('template-update-conflict-resolution', { page, request })
    pl.state.adminToken = adminToken
    pl.state.packId = packId

    // ── Step 01: install pack v1 (API) ──────────────────────────────────────
    await pl.step('01: install pack v1 -- three fixture processes', async (s) => {
      const doc = packDocument(packId, '1.0.0', [
        { definition_id: randomUUID(), process_key: unchangedKey, version: '1.0.0', graph: graphFor(fixtureId, 'unchanged') },
        { definition_id: randomUUID(), process_key: adaptedKey, version: '1.0.0', graph: graphFor(fixtureId, 'adapted-v1') },
        { definition_id: randomUUID(), process_key: untouchedKey, version: '1.0.0', graph: graphFor(fixtureId, 'untouched-v1') },
      ])
      const installResp = await request.post(`${API_BASE_URL}/api/v1/solution-packs/install`, {
        headers: authHeaders(adminToken),
        data: doc,
      })
      pl.gate(installResp.ok(), `install failed: ${installResp.status()} ${await installResp.text()}`)
      const body = await installResp.json() as {
        installed_definitions: Array<{ process_key: string; new_definition_id: string }>
      }
      const byKey = new Map(body.installed_definitions.map((d) => [d.process_key, d.new_definition_id]))
      s.unchangedDefinitionId = byKey.get(unchangedKey) ?? ''
      s.adaptedDefinitionId = byKey.get(adaptedKey) ?? ''
      s.untouchedDefinitionId = byKey.get(untouchedKey) ?? ''
      pl.gate(!!s.unchangedDefinitionId && !!s.adaptedDefinitionId && !!s.untouchedDefinitionId, 'expected all three tenant-local definition ids from install')
    })

    // ── Step 02: adapt adapted-proc's live content (API) ────────────────────
    await pl.step('02: the tenant adapts adapted-proc, leaving the other two untouched', async (s) => {
      const putResp = await request.put(`${API_BASE_URL}/api/v1/definitions/${s.adaptedDefinitionId}`, {
        headers: authHeaders(adminToken),
        data: {
          name: adaptedKey,
          version: '1.0.0',
          graph: graphFor(fixtureId, 'adapted-BY-TENANT'),
        },
      })
      pl.gate(putResp.ok(), `adapt PUT failed: ${putResp.status()} ${await putResp.text()}`)
    })

    // ── Step 03: EO-001 -- launcher + review screen (GUI) ────────────────────
    let v2Document: ReturnType<typeof packDocument>
    await pl.step('03: EO-001 -- review shows all four groups', async (s) => {
      v2Document = packDocument(packId, '2.0.0', [
        { definition_id: s.unchangedDefinitionId, process_key: unchangedKey, version: '1.0.0', graph: graphFor(fixtureId, 'unchanged') },
        { definition_id: s.adaptedDefinitionId, process_key: adaptedKey, version: '2.0.0', graph: graphFor(fixtureId, 'adapted-v2-FROM-PACK') },
        { definition_id: s.untouchedDefinitionId, process_key: untouchedKey, version: '2.0.0', graph: graphFor(fixtureId, 'untouched-v2-FROM-PACK') },
      ])

      await navigateSpa(page, '/solution-packs')
      await page.getByTestId('solution-pack-id-input').fill(packId)
      await page.getByTestId('json-editor').locator('textarea').fill(JSON.stringify(v2Document))
      await shot(page, 'template-update-conflict-resolution', '03-launcher-filled')

      await expect(page.getByTestId('solution-pack-review-btn')).toBeEnabled({ timeout: 5_000 })
      await page.getByTestId('solution-pack-review-btn').click()

      await page.waitForURL((url) => url.pathname === `/solution-packs/${packId}/update-review`, { timeout: 15_000 })
      await page.getByTestId('update-review-group-list').waitFor({ timeout: 15_000 })
      await shot(page, 'template-update-conflict-resolution', '03-review-loaded')

      await expect(
        page.getByTestId('update-review-group-unchanged').getByTestId('update-review-entry').filter({ hasText: s.unchangedDefinitionId }),
      ).toBeVisible({ timeout: 10_000 })
      await expect(
        page.getByTestId('update-review-group-safe_to_update').getByTestId('update-review-entry').filter({ hasText: s.untouchedDefinitionId }),
      ).toBeVisible({ timeout: 10_000 })
      await expect(
        page
          .getByTestId('update-review-conflict-needs-decision')
          .locator('[data-testid="update-review-resolution-control"]')
          .filter({ hasText: s.adaptedDefinitionId }),
      ).toBeVisible({ timeout: 10_000 })
    })

    // ── Step 04: EO-002 -- blocked apply names the unresolved process ───────
    await pl.step('04: EO-002 -- blocked apply names adapted-proc', async (s) => {
      await expect(page.getByTestId('update-apply-btn')).toBeDisabled({ timeout: 5_000 })
      pl.gate(page.url().includes('/update-review'), 'expected to remain on the review page while blocked')
      // The client-side pre-block already disables Apply; confirm the
      // server-side block is ALSO real by driving the same 409 the button
      // would surface if a race let a click through (design §4.4) --
      // re-run update-review directly against the API with no resolutions,
      // then update-apply with none, proving the server itself refuses.
      const reviewResp = await request.post(`${API_BASE_URL}/api/v1/solution-packs/${packId}/update-review`, {
        headers: authHeaders(adminToken),
        data: {
          target_version: '2.0.0',
          theirs_artefacts: [
            { artefact_type: 'process_definition', artefact_id: s.adaptedDefinitionId, content: '{}' },
          ],
          incoming_artefacts: [
            { artefact_type: 'process_definition', artefact_id: s.adaptedDefinitionId, content: '{}' },
          ],
        },
      })
      pl.gate(reviewResp.ok(), `review re-check failed: ${reviewResp.status()}`)
      const applyResp = await request.post(`${API_BASE_URL}/api/v1/solution-packs/${packId}/update-apply`, {
        headers: authHeaders(adminToken),
        data: {
          target_version: '2.0.0',
          theirs_artefacts: [
            { artefact_type: 'process_definition', artefact_id: s.adaptedDefinitionId, content: '{}' },
          ],
          incoming_artefacts: [
            { artefact_type: 'process_definition', artefact_id: s.adaptedDefinitionId, content: '{}' },
          ],
          resolutions: [],
        },
      })
      pl.gate(applyResp.status() === 409, `expected 409 from an unresolved apply, got ${applyResp.status()}`)
      const detail = await applyResp.text()
      pl.gate(detail.includes(s.adaptedDefinitionId), 'the 409 must name the real unresolved artefact id')
    })

    // ── Step 05: EO-003/EO-004 -- resolve keep-local, apply (GUI) ───────────
    await pl.step('05: EO-003/EO-004 -- keep-local on adapted-proc, apply, verify', async (s) => {
      await page
        .locator('[data-testid="update-review-resolution-keep-local"]')
        .and(page.locator(`[data-artefact-id="${s.adaptedDefinitionId}"]`))
        .check()

      await expect(page.getByTestId('update-apply-btn')).toBeEnabled({ timeout: 5_000 })
      await shot(page, 'template-update-conflict-resolution', '05-resolved-before-apply')

      await page.getByTestId('update-apply-btn').click()
      await page.getByTestId('update-attribution-panel').waitFor({ timeout: 15_000 })
      await shot(page, 'template-update-conflict-resolution', '05-applied')

      // EO-003 -- adapted-proc shows under "Already resolved" with attribution.
      await expect(
        page
          .getByTestId('update-review-conflict-already-resolved')
          .locator('[data-testid="update-review-resolved-entry"]')
          .filter({ hasText: s.adaptedDefinitionId }),
      ).toBeVisible({ timeout: 10_000 })
      const attributionText = await page
        .getByTestId('update-review-conflict-already-resolved')
        .locator('[data-testid="update-review-resolved-attribution"]')
        .filter({ hasText: /Kept by/ })
        .first()
        .innerText()
      pl.gate(/Kept by .+ at /.test(attributionText), `expected attribution text naming who/when, got "${attributionText}"`)

      // EO-004 -- unchanged-proc still shows the same content/id after apply.
      await expect(
        page.getByTestId('update-review-group-unchanged').getByTestId('update-review-entry').filter({ hasText: s.unchangedDefinitionId }),
      ).toBeVisible({ timeout: 10_000 })
    })

    // ── Step 06: EO-005 -- re-review does not re-flag adapted-proc ──────────
    await pl.step('06: EO-005 -- same-version re-review shows adapted-proc as already resolved', async (s) => {
      await navigateSpa(page, '/solution-packs')
      await page.getByTestId('solution-pack-id-input').fill(packId)
      await page.getByTestId('json-editor').locator('textarea').fill(JSON.stringify(v2Document))
      await page.getByTestId('solution-pack-review-btn').click()

      await page.waitForURL((url) => url.pathname === `/solution-packs/${packId}/update-review`, { timeout: 15_000 })
      await page.getByTestId('update-review-group-list').waitFor({ timeout: 15_000 })
      await shot(page, 'template-update-conflict-resolution', '06-re-review')

      await expect(
        page
          .getByTestId('update-review-conflict-already-resolved')
          .locator('[data-testid="update-review-resolved-entry"]')
          .filter({ hasText: s.adaptedDefinitionId }),
      ).toBeVisible({ timeout: 10_000 })
      await expect(
        page
          .getByTestId('update-review-conflict-needs-decision')
          .locator('[data-testid="update-review-resolution-control"]')
          .filter({ hasText: s.adaptedDefinitionId }),
      ).toHaveCount(0)
    })

    await pl.runCleanup()
  })
})
