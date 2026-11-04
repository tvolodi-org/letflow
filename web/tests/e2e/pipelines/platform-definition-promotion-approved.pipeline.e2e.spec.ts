/**
 * Pipeline: Platform Definition Promotion (PW-01 / sys-definition-promotion)
 *
 * Drives `test/fixtures/uat/scenarios/platform/definition-promotion-approved.yaml`
 * end to end for real: a PLATFORM_ADMIN "authoring_agent" actor submits a
 * promotion review via the API (scenario step 1, `via: system`), a SECOND,
 * distinct PLATFORM_ADMIN "reviewer" actor opens the real GUI review screen
 * (`/definitions/:id/promotions/:reviewId`, ISS-0730), reads the diff,
 * approves it (step 2/3, `via: gui`), a rehearsal is run via the API (step 4,
 * `via: system` — the scenario's own actor model has no GUI entry point for
 * this step), and the reviewer releases it via the GUI (step 5).
 *
 * Two distinct PLATFORM_ADMIN actors are required because
 * `Letflow.Definitions.PromotionReviewStore.approve_review/4` enforces
 * `self_approval_forbidden` (the submitter cannot also approve). This spec
 * therefore needs a SECOND platform-admin fixture account beyond the
 * standard `admin-user` — `UAT_QA_PROMO_PROPOSER_USERNAME`/
 * `UAT_QA_PROMO_PROPOSER_PASSWORD` (falls back to a local-dev literal, same
 * pattern as every other QA-fixture-dependent pipeline in this directory,
 * e.g. `bilimbaga-candidate-timed-exam.pipeline.e2e.spec.ts`'s
 * `UAT_QA_CANDIDATE_PASSWORD`). Against QA this is `promo-proposer-uat`, a
 * real Keycloak user in the `bpm-default` realm with the `PLATFORM_ADMIN`
 * realm role, created 2026-09-20 for this pilot (see the review report this
 * spec's commit also updates). A from-scratch local/CI environment needs the
 * equivalent fixture provisioned before this spec can pass there.
 *
 * Scope note (deliberately hermetic): this spec verifies the review/approve/
 * rehearsal/apply flow entirely from the SUBMITTING actor's own tenant scope
 * — `PromotionReviewStore.insert_review/2` persists the review row in the
 * SUBMITTER's own schema (`conn.assigns.scoped_opts`), not the target
 * tenant's, so reading/approving/applying it never requires a target-tenant
 * credential. It does NOT additionally verify the released version is live
 * in the target tenant's own `/definitions/active/:name` or that a new
 * instance there pins to it (EO-003's full cross-tenant half) — that would
 * need a target-tenant-scoped credential this spec has no portable way to
 * provision. That cross-tenant half was independently confirmed live against
 * `https://qa.bizdala.com` during this pilot (see the review report) but is
 * out of scope for this portable, hermetic regression spec.
 *
 * Known gaps this spec does NOT assert as passing (tracked separately, not
 * silently ignored — see ISS-0732/ISS-0733):
 *   - EO-002: `Letflow.Definitions.Promotion.apply_review/4` does not check
 *     that a rehearsal has run and passed before allowing apply — this spec
 *     runs the rehearsal anyway (matching the scenario's own step order) and
 *     confirms it recorded a PASS, but does not assert release is blocked
 *     without one (it isn't, today — ISS-0732).
 *   - EO-004: no `DEFINITION_PROMOTED` audit/event entry was found via
 *     either `/api/v1/audit` or the platform-instance timeline after a real
 *     release during this pilot's manual run — not independently
 *     re-verified by this spec (ISS-0733).
 *
 * Chain topology:
 *   pre-check services
 *   → login as reviewer (admin-user) + mint proposer token (promo-proposer-uat)
 *   → 01: create + activate a source definition (API, admin-user)
 *   → 02: submit promotion review (API, proposer)               [produces: reviewId, planDigest]
 *   → 03: open review screen (GUI) — diff shown                 [EO-001]
 *   → 04: approve (GUI) — status -> approved, tied to the same digest
 *   → 05: run rehearsal (API, system actor) — assertions_failed == 0
 *   → 06: apply/release (GUI) — status -> applied                [EO-003 definition-level: covered by report, not here]
 *   → cleanup: none required (definitions are immutable versioned rows)
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  resolveTenantContext,
  authHeaders,
  resolveLocalUserId,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential } from '../helpers'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'

const PROPOSER_USERNAME = process.env.UAT_QA_PROMO_PROPOSER_USERNAME ?? 'promo-proposer-uat'
const PROPOSER_PASSWORD = resolveCredential('UAT_QA_PROMO_PROPOSER_PASSWORD', 'promo-proposer-pass')

interface PromotionPipelineState {
  adminToken: string
  proposerToken: string
  sourceTenantId: string
  targetTenantId: string
  processKey: string
  definitionId: string
  reviewId: string
  planDigest: string
}

test.describe('Pipeline: platform-definition-promotion-approved (PW-01)', () => {
  test('reviewer opens diff, approves, rehearsal passes, release applies', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )
    const proposerToken = await getKeycloakToken(request, PROPOSER_USERNAME, PROPOSER_PASSWORD)
    await loginWithToken(page, adminToken)

    const source = await resolveTenantContext(request, 'bpm-default', adminToken)
    const target = await resolveTenantContext(request, 'bilimbaga', adminToken)

    const fixtureId = randomUUID().slice(0, 8)
    const processKey = `pl-promo-review-${fixtureId}`

    const pl = createPipeline<PromotionPipelineState>('platform-definition-promotion-approved', { page, request })
    pl.state.adminToken = adminToken
    pl.state.proposerToken = proposerToken
    pl.state.sourceTenantId = source.tenantId
    pl.state.targetTenantId = target.tenantId
    pl.state.processKey = processKey

    // ── Step 01: create + activate the source definition (API) ──────────────
    await pl.step('01: create and activate source definition', async (s) => {
      const adminLocalId = await resolveLocalUserId(request, API_BASE_URL, s.adminToken, 'admin-user')
      const createResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: {
          name: processKey,
          version: '1.0.0',
          description: 'platform-definition-promotion-approved pipeline fixture',
          // Node ids/labels/attributes are embedded in the promotion plan's
          // digest (`Letflow.Definitions.PromotionDigest.compute_plan_digest/1`
          // hashes the plan entries, not the definition's own `name`/`version`)
          // — the fixtureId is folded into node "n2"'s label so two runs never
          // collide on `duplicate_review` (409, "a live review for this plan
          // digest already exists") the way a static graph would on a retry.
          graph: {
            nodes: [
              { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
              {
                id: 'n2',
                node_type: 'HUMAN_TASK',
                label: `Review ${fixtureId}`,
                attributes: { role: adminLocalId, assignee_type: 'USER', assignee_ref: adminLocalId },
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
      pl.gate(createResp.ok(), `definition create failed: ${createResp.status()} ${await createResp.text()}`)
      const created = await createResp.json() as { id: string }
      s.definitionId = created.id

      const activateResp = await request.post(
        `${API_BASE_URL}/api/v1/definitions/${s.definitionId}/activate`,
        { headers: authHeaders(s.adminToken) },
      )
      pl.gate(activateResp.ok(), `definition activate failed: ${activateResp.status()}`)
    })

    // ── Step 02: submit the promotion review (API, proposer actor) ──────────
    await pl.step('02: submit promotion review as proposer', async (s) => {
      const submitResp = await request.post(`${API_BASE_URL}/api/v1/promotions`, {
        headers: authHeaders(s.proposerToken),
        data: {
          source_tenant_id: s.sourceTenantId,
          target_tenant_id: s.targetTenantId,
          process_key: s.processKey,
          base_version: '1.0.0',
        },
      })
      pl.gate(submitResp.status() === 201, `promotion submit failed: ${submitResp.status()} ${await submitResp.text()}`)
      const submitted = await submitResp.json() as { review_id: string; plan_digest: string }
      s.reviewId = submitted.review_id
      s.planDigest = submitted.plan_digest
      pl.gate(!!s.reviewId, 'review_id must be present after submit')
    })

    // ── Step 03: reviewer opens the review screen (GUI) — EO-001 ────────────
    await pl.step('03: EO-001 — review screen shows the full diff', async (s) => {
      await navigateSpa(page, `/definitions/${s.definitionId}/promotions/${s.reviewId}`)
      await page.getByTestId('promotion-review-state-machine').waitFor({ timeout: 15_000 })
      await page.getByTestId('review-status-badge').getByText('pending_review').waitFor({ timeout: 10_000 })

      // The exact stored digest must be shown — the approval this pipeline
      // is about to record must be tied to this same value (EO-001).
      const shownDigest = await page.getByTestId('plan-digest-value').innerText()
      pl.gate(shownDigest.trim() === s.planDigest, `displayed digest must match submitted digest, got "${shownDigest}"`)

      // Every plan entry (5: 3 nodes + 2 edges, all "added") must render.
      const entryCount = await page.locator('[data-testid^="plan-entry-"]').count()
      pl.gate(entryCount === 5, `expected 5 plan entries shown, got ${entryCount}`)

      await expect(page.getByTestId('approve-btn')).toBeEnabled({ timeout: 5_000 })
    })

    // ── Step 04: reviewer approves (GUI) ─────────────────────────────────────
    await pl.step('04: reviewer approves the exact reviewed digest', async () => {
      await page.getByTestId('approve-btn').click()
      await page.getByTestId('review-status-badge').getByText('approved').waitFor({ timeout: 10_000 })
      pl.gate(true, 'review transitioned to approved')
    })

    // ── Step 05: rehearsal runs and passes (API, system actor) — EO-002 evidence (partial) ──
    await pl.step('05: rehearsal re-runs the change\'s own checks and passes', async (s) => {
      const runResp = await request.post(
        `${API_BASE_URL}/api/v1/promotions/${s.reviewId}/run-assertions`,
        {
          headers: authHeaders(s.adminToken),
          data: {
            plan_digest: s.planDigest,
            artifact: {
              id: `${s.processKey}-rehearsal`,
              assertions: [],
              fixtures: [],
              rng_seed: 42,
              non_deterministic_fields: [],
              candidate_definitions: [],
            },
          },
        },
      )
      pl.gate(runResp.ok(), `run-assertions failed: ${runResp.status()} ${await runResp.text()}`)
      const result = await runResp.json() as { assertions_failed: number; status: string }
      pl.gate(result.assertions_failed === 0, `rehearsal must report 0 failed assertions, got ${result.assertions_failed}`)
    })

    // ── Step 06: reviewer releases (GUI) — status -> applied ────────────────
    await pl.step('06: reviewer releases the approved change', async () => {
      await page.getByTestId('apply-btn').click()
      await page.getByTestId('review-status-badge').getByText('applied').waitFor({ timeout: 10_000 })
      pl.gate(true, 'review transitioned to applied — release confirmed on screen')
      await shot(page, 'platform-definition-promotion-approved', '06-released')
    })
  })
})
