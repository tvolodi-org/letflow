/**
 * Pipeline: Platform Definition Rollback/Withdrawal (PW-01 / sys-definition-promotion)
 *
 * Drives `test/fixtures/uat/scenarios/platform/definition-promotion-rollback.yaml`
 * end to end, all five steps `via: gui` (confirmed by reading the scenario
 * file directly — unlike the sibling promotion-approved scenario, no step
 * here is `via: system`). See
 * `lib/letflow/design/req371-rollback-withdrawal-screen.md` §8.2 for the
 * validated design this spec implements, and
 * `test/uat-reports/gui-review-2026-09-19-definition-promotion-rollback.md`
 * for the pilot history.
 *
 * Chain topology:
 *   pre-check services
 *   → login as operator (admin-user, PLATFORM_ADMIN)
 *   → pre-step (API): create+activate version 1, then version 2           [establishes released_version/previous_version]
 *   → 01: GUI — confirm current/previous version on /definitions          [EO-... setup]
 *   → 02: GUI — start an in-flight case on the released version, leave it running
 *   → 03: GUI — withdraw the release with a reason (EO-005 setup)
 *   → 04: GUI — new case runs on the restored version; in-flight case undisturbed (EO-001/EO-002/EO-004)
 *   → 05: GUI — a version that never ran here is refused (EO-004)
 *   → cleanup: cancel both instances; leave live workspace on previous_version
 *
 * ## Known, disclosed gaps this spec does NOT assert (§8.3)
 *
 * 1. EO-003 ("does not affect any other company using the platform") — this
 *    spec runs against one tenant only; it cannot, by itself, prove
 *    platform-wide non-interference. Not asserted here — a manual/ops-level
 *    check, same disposition as the sibling promotion-approved spec's own
 *    EO-003/EO-004 disclosures.
 * 2. EO-005's durability — the change-history panel this spec reads back in
 *    step 3 is real and on-screen (a real HTTP response drives it), but it
 *    is this same browser page's local state, populated in the same test
 *    run that performed the rollback. It is NOT evidence the entry survives
 *    a reload, a different tab, or a different operator — no backend read
 *    path exists for that yet (design §7.3). Tracked as a disclosed,
 *    scoped-out gap, not silently ignored — see the design doc §7.3/§8.3
 *    (no ISS number minted for this by FRONTEND-DEV; route through
 *    ORCH/REQ-ANALYST if a durable audit trail becomes a real requirement).
 *
 * ## What this spec can and cannot prove (§8.4)
 *
 * A passing run proves the full withdrawal flow works against a real running
 * backend in CI/local-dev conditions, exercised entirely through real GUI
 * clicks (no API-bypass for any of the 5 scenario steps). It does NOT prove
 * the feature works against any specific deployed environment (e.g.
 * qa.bizdala.com) at any specific point in time — that requires a real
 * UAT-RUNNER pass against that environment.
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  authHeaders,
  resolveLocalUserId,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential } from '../helpers'
import { typeIntoTestIdInput } from '../type-into-input'

// Allow generous time for this 5-step GUI flow against a real backend —
// the default 30s Playwright test timeout is exceeded mid-flow (observed
// timing out inside step 01's click after processing steps 01's earlier
// waits/navigation), same rationale as the onboarding-wizard pipeline spec.
test.setTimeout(300_000)

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'

interface RollbackPipelineState {
  adminToken: string
  processKey: string
  definitionIdV1: string
  definitionIdV2: string
  releasedVersion: string
  previousVersion: string
  inFlightInstanceId: string
  newCaseInstanceId: string
}

function graphFor(fixtureId: string, version: string, adminSub: string) {
  return {
    nodes: [
      { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
      {
        id: 'n2',
        node_type: 'HUMAN_TASK',
        label: `Review ${fixtureId} ${version}`,
        attributes: { role: adminSub, assignee_type: 'USER', assignee_ref: adminSub },
      },
      { id: 'n3', node_type: 'END', label: 'End', attributes: null },
    ],
    edges: [
      { id: 'e1', source: 'n1', target: 'n2' },
      { id: 'e2', source: 'n2', target: 'n3' },
    ],
  }
}

test.describe('Pipeline: platform-definition-promotion-rollback (PW-01)', () => {
  test('operator withdraws a released version and work-in-progress is undisturbed', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 8)
    const processKey = `pl-rollback-${fixtureId}`

    const pl = createPipeline<RollbackPipelineState>('platform-definition-promotion-rollback', { page, request })
    pl.state.adminToken = adminToken
    pl.state.processKey = processKey

    pl.onCleanup(async (s) => {
      if (s.inFlightInstanceId) {
        await request.post(`${API_BASE_URL}/api/v1/instances/${s.inFlightInstanceId}/cancel`, {
          headers: authHeaders(s.adminToken),
          data: { reason: 'pipeline cleanup' },
        }).catch(() => undefined)
      }
      if (s.newCaseInstanceId) {
        await request.post(`${API_BASE_URL}/api/v1/instances/${s.newCaseInstanceId}/cancel`, {
          headers: authHeaders(s.adminToken),
          data: { reason: 'pipeline cleanup' },
        }).catch(() => undefined)
      }
      // Live workspace is intentionally left on s.previousVersion per the
      // scenario's own cleanup.description — no further rollback here.
    })

    // ── Pre-step (API): version 1 then version 2, both activated ────────────
    await pl.step('pre: create and activate version 1, then version 2', async (s) => {
      const adminLocalId = await resolveLocalUserId(request, API_BASE_URL, s.adminToken, 'admin-user')
      const v1Resp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: { name: processKey, version: '1.0.0', description: 'rollback pipeline fixture v1', graph: graphFor(fixtureId, '1.0.0', adminLocalId) },
      })
      pl.gate(v1Resp.ok(), `v1 create failed: ${v1Resp.status()} ${await v1Resp.text()}`)
      const v1 = await v1Resp.json() as { id: string }
      s.definitionIdV1 = v1.id
      const v1Activate = await request.post(`${API_BASE_URL}/api/v1/definitions/${v1.id}/activate`, { headers: authHeaders(s.adminToken) })
      pl.gate(v1Activate.ok(), `v1 activate failed: ${v1Activate.status()}`)

      const v2Resp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: { name: processKey, version: '2.0.0', description: 'rollback pipeline fixture v2', graph: graphFor(fixtureId, '2.0.0', adminLocalId) },
      })
      pl.gate(v2Resp.ok(), `v2 create failed: ${v2Resp.status()} ${await v2Resp.text()}`)
      const v2 = await v2Resp.json() as { id: string }
      s.definitionIdV2 = v2.id
      const v2Activate = await request.post(`${API_BASE_URL}/api/v1/definitions/${v2.id}/activate`, { headers: authHeaders(s.adminToken) })
      pl.gate(v2Activate.ok(), `v2 activate failed: ${v2Activate.status()}`)

      s.releasedVersion = '2.0.0'
      s.previousVersion = '1.0.0'
    })

    // ── Step 1 (GUI) ──────────────────────────────────────────────────────────
    await pl.step('01: operator confirms current/previous version on process detail', async (s) => {
      await navigateSpa(page, '/definitions')
      await typeIntoTestIdInput(page, 'definition-search', s.processKey)
      // Both v1.0.0 and v2.0.0 rows match on processKey alone (both are rows
      // for this process), so filtering on hasText: processKey resolves to 2
      // elements and Playwright's strict mode refuses to proceed. Scope to
      // the row that actually contains the v2 definition's own name cell —
      // the one row that is unambiguously the released/ACTIVE version.
      const row = page.getByTestId('datatable-row').filter({ has: page.getByTestId(`def-name-${s.definitionIdV2}`) })
      await row.waitFor({ timeout: 15_000 })
      await expect(row).toContainText(s.releasedVersion)
      await expect(row).toContainText('ACTIVE')

      await page.getByTestId(`def-name-${s.definitionIdV2}`).click()
      const historyRow = page.getByTestId('version-history-row')
      await historyRow.waitFor({ timeout: 10_000 })
      await expect(historyRow).toContainText(s.previousVersion)
      await expect(historyRow).toContainText('DEPRECATED')
    })

    // ── Step 2 (GUI, required — the scenario's own step 2 is `via: gui`) ─────
    await pl.step('02: start an in-flight case on the released version', async (s) => {
      await navigateSpa(page, '/instances')
      await page.getByTestId('start-instance-button').click()
      await page.getByTestId('start-instance-dialog').waitFor({ timeout: 10_000 })
      await typeIntoTestIdInput(page, 'start-definition-name', s.processKey)
      await expect(page.getByTestId('start-definition-version')).toHaveValue(s.releasedVersion, { timeout: 10_000 })
      await page.getByTestId('submit-start-instance').click()
      await page.waitForURL(/\/instances\/.+/, { timeout: 15_000 })
      s.inFlightInstanceId = page.url().split('/instances/')[1]
      pl.gate(!!s.inFlightInstanceId, 'must capture the in-flight instance id from the URL')

      // Navigate away, leaving the case part-way through (not completed/cancelled).
      await navigateSpa(page, '/definitions')
    })

    // ── Step 3 (GUI) — EO-005 setup ──────────────────────────────────────────
    await pl.step('03: EO-005 setup — operator withdraws the release with a reason', async (s) => {
      // Reach the rollback screen by clicking `btn-rollback-${id}` on the
      // definitions list, not by navigating straight to the URL — this is
      // what actually exercises AC1's "reachable from the process detail /
      // version-history view" claim end to end.
      await navigateSpa(page, '/definitions')
      await typeIntoTestIdInput(page, 'definition-search', s.processKey)
      // Same ambiguity as step 01 — scope to the v2 row specifically.
      const row = page.getByTestId('datatable-row').filter({ has: page.getByTestId(`def-name-${s.definitionIdV2}`) })
      await row.waitFor({ timeout: 15_000 })
      await page.getByTestId(`btn-rollback-${s.definitionIdV2}`).click()
      await page.waitForURL(`**/definitions/${s.definitionIdV2}/rollback`, { timeout: 10_000 })

      await page.getByTestId('rollback-target-version-select').selectOption(s.previousVersion)
      await typeIntoTestIdInput(
        page,
        'rollback-reason-input',
        'Released version routes high-value requests to the wrong reviewer.',
      )
      await page.getByTestId('rollback-continue-btn').click()
      await page.getByTestId('rollback-confirm-dialog').waitFor({ timeout: 5_000 })
      await page.getByTestId('rollback-confirm-btn').click()
      await page.getByTestId('rollback-success-banner').waitFor({ timeout: 15_000 })

      const historyEntry = page.getByTestId('rollback-history-entry').first()
      await expect(historyEntry).toContainText(s.previousVersion)
      await expect(historyEntry).toContainText(s.releasedVersion)
      await shot(page, 'platform-definition-promotion-rollback', '03-withdrawn')
    })

    // ── Step 4 (GUI) — EO-001/EO-004(part)/EO-002 ────────────────────────────
    await pl.step('04: EO-001/EO-002 — new case runs on restored version, in-flight case undisturbed', async (s) => {
      await navigateSpa(page, '/instances')
      await page.getByTestId('start-instance-button').click()
      await page.getByTestId('start-instance-dialog').waitFor({ timeout: 10_000 })
      await typeIntoTestIdInput(page, 'start-definition-name', s.processKey)
      await expect(page.getByTestId('start-definition-version')).toHaveValue(s.previousVersion, { timeout: 10_000 })
      await page.getByTestId('submit-start-instance').click()
      await page.waitForURL(/\/instances\/.+/, { timeout: 15_000 })
      s.newCaseInstanceId = page.url().split('/instances/')[1]
      pl.gate(!!s.newCaseInstanceId, 'must capture the new-case instance id from the URL')

      // Reopen the step-2 in-flight case and confirm it is unaffected.
      await navigateSpa(page, `/instances/${s.inFlightInstanceId}`)
      const definitionRow = page.getByTestId('datatable-row').filter({ hasText: 'Definition' })
      await expect(definitionRow).toContainText(`v${s.releasedVersion}`)
      const statusRow = page.getByTestId('datatable-row').filter({ hasText: 'Status' })
      await expect(statusRow).toContainText('ACTIVE')
    })

    // ── Step 5 (GUI) — EO-004 ─────────────────────────────────────────────────
    await pl.step('05: EO-004 — a version that never ran here is refused', async (s) => {
      const neverActiveVersion = `9.9.9-${fixtureId}-never-existed`
      await navigateSpa(page, `/definitions/${s.definitionIdV2}/rollback`)
      await page.getByTestId('rollback-target-version-select').selectOption('__other__')
      await typeIntoTestIdInput(page, 'rollback-target-version-manual', neverActiveVersion)
      await typeIntoTestIdInput(page, 'rollback-reason-input', 'Testing EO-004 refusal path.')
      await page.getByTestId('rollback-continue-btn').click()
      await page.getByTestId('rollback-confirm-dialog').waitFor({ timeout: 5_000 })
      await page.getByTestId('rollback-confirm-btn').click()

      const errorBlock = page.getByTestId('rollback-error-version-never-active')
      await errorBlock.waitFor({ timeout: 15_000 })
      await expect(errorBlock).toContainText(neverActiveVersion)

      // The refusal made no change — the live version is still s.previousVersion.
      await navigateSpa(page, '/definitions')
      await typeIntoTestIdInput(page, 'definition-search', s.processKey)
      // By this point the rollback in step 03 has made v1 the live/ACTIVE
      // version — scope to the v1 row specifically (same ambiguity as step 01).
      const row = page.getByTestId('datatable-row').filter({ has: page.getByTestId(`def-name-${s.definitionIdV1}`) })
      await row.waitFor({ timeout: 10_000 })
      await expect(row).toContainText(s.previousVersion)
      await expect(row).toContainText('ACTIVE')
      await shot(page, 'platform-definition-promotion-rollback', '05-refused')
    })

    await pl.runCleanup()
  })
})
