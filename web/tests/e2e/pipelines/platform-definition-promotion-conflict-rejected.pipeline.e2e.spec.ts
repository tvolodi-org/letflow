/**
 * Pipeline: Platform Definition Promotion — Conflict Rejected (PW-01 / sys-definition-promotion)
 *
 * Drives `test/fixtures/uat/scenarios/platform/definition-promotion-conflict-rejected.yaml`
 * as far as the real system allows, following the same "review real screens
 * before writing a blind spec" process used for
 * `platform-definition-promotion-approved.yaml`
 * (`test/uat-reports/gui-review-2026-09-20-definition-promotion-approved.md`).
 * See `test/uat-reports/gui-review-2026-09-20-definition-promotion-conflict-rejected.md`
 * for the full review report this spec's commit accompanies.
 *
 * ## What's real (confirmed live against https://qa.bizdala.com)
 *
 * `POST /api/v1/promotions` (submit, R1) and `POST /api/v1/promotions/:id/apply`
 * (release, R7) BOTH re-check `Letflow.Definitions.PromotionConflict.reject_if_conflicts/4`
 * against the target tenant's CURRENT active version before doing anything —
 * at submit time (`lib/letflow/routers/promotions.ex` `do_submit/3`) and again
 * at apply time (`Letflow.Definitions.Promotion.do_promote_definition/7`, inside
 * `apply_review/4`'s orchestration). Both return a real 409
 * `.../problems/promotion-conflict` naming `process_key`/`base_version`/
 * `target_active_version`/`target_definition_id` (EO-001's core assertion) and
 * leave the live workspace untouched (EO-002) — confirmed by re-submitting with
 * the conflict's own reported `target_active_version` as the new `base_version`
 * and getting a clean 201 back.
 *
 * The apply-time recheck is what makes EO-004 real: an approval recorded
 * against one target-tenant snapshot cannot be used to release once that
 * snapshot has moved on — apply returns the same 409 `promotion-conflict`
 * shape, and the review's own status transitions `approved -> failed`
 * (`PromotionReviewStore.mark_review_failed/2`), never touching the target.
 *
 * ## What's NOT real — this scenario's own step 2 cannot be driven via GUI
 *
 * The scenario's step 2 (`via: gui`, `expected_screen: "refused change review
 * detail"`) has no reachable screen today, for two independent reasons, both
 * confirmed by reading `web/src/router.tsx` and the promotion conflict-check
 * code path:
 *
 *   1. A submit-time conflict is rejected BEFORE `PromotionReviewStore.insert_review/2`
 *      ever runs (`do_submit/3`'s `with` chain short-circuits on
 *      `reject_if_conflicts/4`'s error) — no review row exists for a refused
 *      submission, so there is nothing a "queue" screen could list even if one
 *      existed.
 *   2. No such queue/list screen exists anyway: `web/src/router.tsx` has only
 *      the single `definitions/:id/promotions/:reviewId` direct-URL detail
 *      route (ISS-0730) — no `GET /promotions` list endpoint, no nav entry, by
 *      design (see `lib/letflow/design/iss0730-promotion-review-page-routing.md`).
 *      `web/src/components/promotions/ConflictRejectionAlert.tsx` — a fully-built
 *      component clearly intended for exactly this — has zero callers anywhere
 *      in `web/src` (confirmed by grep), i.e. built but never wired to a route
 *      or triggering action.
 *
 * Filed as ISS-0734 (properly-sized gap: a review-queue/conflict-visibility
 * surface, not a same-session fix). This spec therefore drives the scenario's
 * conflict checks at the system/API level (matching the scenario's own `step
 * 1`/`step 5`, both `authoring_agent`, both effectively `via: system`), and
 * drives only the ONE reviewer-facing GUI screen that genuinely exists and
 * matters here: opening and approving the rebuilt (non-conflicting) review
 * (scenario step 4).
 *
 * Also filed: ISS-0735 (small, real, FIXED in this same commit) —
 * `NonSkippableApprovalGate.tsx`'s apply-error handler classified ANY HTTP 409
 * from `/apply` as a digest mismatch (`err2.status === 409` with no `code`/
 * `type` check), so a real promotion-conflict refusal at apply time displayed
 * the wrong message ("Plan digest mismatch...") instead of naming the
 * conflict. Fixed to distinguish the RFC 9457 `type` suffix
 * (`/promotion-conflict` vs `/conflict`).
 *
 * Known gap NOT fixed (too large for this pass, tracked separately):
 *   - EO-005: no audit/event entry was found for either refusal (submit-time
 *     or apply-time conflict) in this pilot's manual run — same root cause as
 *     ISS-0733 (no `DEFINITION_PROMOTED`-family event append on any
 *     non-success promotion path). `on_fail.suggested_action` for EO-005 in
 *     the scenario itself is `none`, so this is recorded, not routed to WF-03.
 *
 * Chain topology:
 *   pre-check services
 *   → login as reviewer (admin-user) + mint proposer token (fixture user, see below)
 *   → 01: create+activate v1.0.0 in source, full-cycle-promote it -> target ACTIVE 1.0.0
 *   → 02: create+activate v2.0.0 in source, full-cycle-promote it (base=1.0.0) -> target ACTIVE 2.0.0
 *   → 03: create+activate v3.0.0 in source (NOT promoted — "today's" unreviewed change)
 *   → 04: STALE submit (API, base_version=1.0.0, target is really 2.0.0)   [EO-001]
 *   → 05: rebuild + resubmit using the refusal's own target_active_version  [EO-002 + scenario step 3]
 *   → 06: reviewer opens the rebuilt review (GUI) and approves it           [scenario step 4]
 *   → 07: an independent v4.0.0 promotion lands first (target moves again, API)
 *   → 08: attempt to apply the now-stale approval (API)                     [scenario step 5]
 *   → 09: EO-004 — review status is `failed`, target untouched by it
 *   → cleanup: none required (definitions are immutable versioned rows; the
 *     `failed` review row is left in place, same as R-Co/Letflow's other
 *     terminal-state promotion fixtures)
 *
 * ## Fixture credential
 *
 * Needs a second PLATFORM_ADMIN actor distinct from `admin-user` (same
 * `self_approval_forbidden` reason as the sibling approved-scenario spec).
 * That spec's own `promo-proposer-uat` fixture turned out to have no
 * discoverable password (created in an earlier session, never recorded to
 * `ai-dala-infra`'s seeded-users.env) — this spec uses a fresh, dedicated
 * fixture, `uat-promo-conflict-proposer` (`bpm-default` realm, PLATFORM_ADMIN),
 * created for this pilot. Read via `UAT_QA_PROMO_CONFLICT_PROPOSER_USERNAME`/
 * `UAT_QA_PROMO_CONFLICT_PROPOSER_PASSWORD`, same env-var pattern as every
 * other QA-fixture-dependent pipeline in this directory.
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
  jwtSubject,
  resolveLocalUserId,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential } from '../helpers'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'

const PROPOSER_USERNAME = process.env.UAT_QA_PROMO_CONFLICT_PROPOSER_USERNAME ?? 'uat-promo-conflict-proposer'
const PROPOSER_PASSWORD = resolveCredential('UAT_QA_PROMO_CONFLICT_PROPOSER_PASSWORD', 'promo-conflict-proposer-pass')

interface ConflictPipelineState {
  adminToken: string
  proposerToken: string
  sourceTenantId: string
  targetTenantId: string
  processKey: string
  definitionId: string
  reviewId: string
  planDigest: string
}

function graphFor(fixtureId: string, label: string, adminSub: string) {
  return {
    nodes: [
      { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
      {
        id: 'n2',
        node_type: 'HUMAN_TASK',
        // The plan digest hashes entry content (id/label/attributes), NOT
        // process_key or tenant — a label that repeats across runs/fixtures
        // (e.g. a bare "Review 2.0.0") can collide with an unrelated review's
        // digest and trip the real `uq_promotion_review_active_digest`
        // constraint (`a live review for this plan digest already exists`,
        // discovered during this spec's own authoring). Always fold the
        // fixtureId into the label so every run's diff content is unique.
        label: `${label} ${fixtureId}`,
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

test.describe('Pipeline: platform-definition-promotion-conflict-rejected (PW-01)', () => {
  test('an out-of-date proposal is refused, rebuilt cleanly, and a stale approval cannot release a moved target', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )
    const proposerToken = await getKeycloakToken(request, PROPOSER_USERNAME, PROPOSER_PASSWORD)
    await loginWithToken(page, adminToken)

    const source = await resolveTenantContext(request, 'bpm-default', adminToken)
    const target = await resolveTenantContext(request, 'bilimbaga', adminToken)

    const fixtureId = randomUUID().slice(0, 8)
    const processKey = `pl-promo-conflict-${fixtureId}`

    const pl = createPipeline<ConflictPipelineState>('platform-definition-promotion-conflict-rejected', { page, request })
    pl.state.adminToken = adminToken
    pl.state.proposerToken = proposerToken
    pl.state.sourceTenantId = source.tenantId
    pl.state.targetTenantId = target.tenantId
    pl.state.processKey = processKey

    async function createAndActivate(version: string, label: string): Promise<string> {
      const createResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(adminToken),
        data: {
          name: processKey,
          version,
          description: `platform-definition-promotion-conflict-rejected fixture ${processKey}@${version}`,
          graph: graphFor(fixtureId, label, await resolveLocalUserId(request, API_BASE_URL, adminToken, 'admin-user')),
        },
      })
      pl.gate(createResp.ok(), `create ${version} failed: ${createResp.status()} ${await createResp.text()}`)
      const created = await createResp.json() as { id: string }
      const activateResp = await request.post(
        `${API_BASE_URL}/api/v1/definitions/${created.id}/activate`,
        { headers: authHeaders(adminToken) },
      )
      pl.gate(activateResp.ok(), `activate ${version} failed: ${activateResp.status()}`)
      return created.id
    }

    async function fullCycle(baseVersion: string): Promise<{ reviewId: string; planDigest: string }> {
      const submitResp = await request.post(`${API_BASE_URL}/api/v1/promotions`, {
        headers: authHeaders(proposerToken),
        data: {
          source_tenant_id: source.tenantId,
          target_tenant_id: target.tenantId,
          process_key: processKey,
          base_version: baseVersion,
        },
      })
      pl.gate(submitResp.status() === 201, `submit failed: ${submitResp.status()} ${await submitResp.text()}`)
      const { review_id: reviewId, plan_digest: planDigest } = await submitResp.json() as { review_id: string; plan_digest: string }

      const approveResp = await request.post(`${API_BASE_URL}/api/v1/promotions/${reviewId}/approve`, {
        headers: authHeaders(adminToken),
        data: { plan_digest: planDigest, approved_by: jwtSubject(adminToken) },
      })
      pl.gate(approveResp.ok(), `approve failed: ${approveResp.status()} ${await approveResp.text()}`)

      const assertResp = await request.post(`${API_BASE_URL}/api/v1/promotions/${reviewId}/run-assertions`, {
        headers: authHeaders(adminToken),
        data: {
          plan_digest: planDigest,
          artifact: { id: `${processKey}-rehearsal`, assertions: [], fixtures: [], rng_seed: 42, non_deterministic_fields: [], candidate_definitions: [] },
        },
      })
      pl.gate(assertResp.ok(), `run-assertions failed: ${assertResp.status()}`)

      const applyResp = await request.post(`${API_BASE_URL}/api/v1/promotions/${reviewId}/apply`, {
        headers: authHeaders(adminToken),
        data: { plan_digest: planDigest },
      })
      pl.gate(applyResp.ok(), `apply failed: ${applyResp.status()} ${await applyResp.text()}`)
      return { reviewId, planDigest }
    }

    // ── Step 01: v1.0.0 -> full cycle -> target ACTIVE 1.0.0 ────────────────
    await pl.step('01: v1.0.0 promoted cleanly, target now ACTIVE 1.0.0', async () => {
      await createAndActivate('1.0.0', 'v1')
      await fullCycle('1.0.0')
    })

    // ── Step 02: v2.0.0 -> full cycle (base=1.0.0) -> target ACTIVE 2.0.0 ───
    await pl.step('02: v2.0.0 promoted cleanly, target now ACTIVE 2.0.0', async () => {
      await createAndActivate('2.0.0', 'v2')
      await fullCycle('1.0.0')
    })

    // ── Step 03: v3.0.0 created in source, deliberately NOT promoted ────────
    await pl.step('03: v3.0.0 exists in source, unreviewed', async (s) => {
      s.definitionId = await createAndActivate('3.0.0', 'v3')
    })

    // ── Step 04: scenario step 1 — STALE submit, EO-001 ──────────────────────
    let conflictTargetVersion = ''
    await pl.step('04: EO-001 — stale submit (base=1.0.0) is refused, naming the real conflict', async () => {
      const staleResp = await request.post(`${API_BASE_URL}/api/v1/promotions`, {
        headers: authHeaders(proposerToken),
        data: {
          source_tenant_id: source.tenantId,
          target_tenant_id: target.tenantId,
          process_key: processKey,
          base_version: '1.0.0',
        },
      })
      pl.gate(staleResp.status() === 409, `expected 409, got ${staleResp.status()}`)
      const body = await staleResp.json() as { type: string; conflicts: Array<{ process_key: string; base_version: string; target_active_version: string }> }
      pl.gate(body.type.endsWith('/promotion-conflict'), `expected a promotion-conflict problem type, got ${body.type}`)
      pl.gate(Array.isArray(body.conflicts) && body.conflicts.length === 1, 'expected exactly one named conflict')
      pl.gate(body.conflicts[0].process_key === processKey, 'conflict must name this process_key')
      pl.gate(body.conflicts[0].base_version === '1.0.0', 'conflict must echo the stale base_version submitted')
      conflictTargetVersion = body.conflicts[0].target_active_version
      pl.gate(!!conflictTargetVersion, 'conflict must name the real target_active_version')
    })

    // ── Step 05: EO-002 + scenario step 3 — rebuild on the version the refusal itself named ──
    await pl.step('05: EO-002 — target untouched; rebuild on the refusal\'s own target_active_version succeeds', async (s) => {
      pl.gate(conflictTargetVersion === '2.0.0', `expected the refusal to name target_active_version 2.0.0, got ${conflictTargetVersion}`)
      const rebuiltResp = await request.post(`${API_BASE_URL}/api/v1/promotions`, {
        headers: authHeaders(proposerToken),
        data: {
          source_tenant_id: source.tenantId,
          target_tenant_id: target.tenantId,
          process_key: processKey,
          base_version: conflictTargetVersion,
        },
      })
      pl.gate(rebuiltResp.status() === 201, `rebuild submit failed: ${rebuiltResp.status()} ${await rebuiltResp.text()}`)
      const rebuilt = await rebuiltResp.json() as { review_id: string; plan_digest: string }
      s.reviewId = rebuilt.review_id
      s.planDigest = rebuilt.plan_digest
    })

    // ── Step 06: scenario step 4 — reviewer opens + approves the rebuilt review (GUI) ──
    await pl.step('06: reviewer opens the rebuilt review and approves it (GUI)', async (s) => {
      await navigateSpa(page, `/definitions/${s.definitionId}/promotions/${s.reviewId}`)
      await page.getByTestId('promotion-review-state-machine').waitFor({ timeout: 15_000 })
      await page.getByTestId('review-status-badge').getByText('pending_review').waitFor({ timeout: 10_000 })

      const shownDigest = await page.getByTestId('plan-digest-value').innerText()
      pl.gate(shownDigest.trim() === s.planDigest, `displayed digest must match submitted digest, got "${shownDigest}"`)

      await shot(page, 'platform-definition-promotion-conflict-rejected', '06-rebuilt-review-pending')

      await expect(page.getByTestId('approve-btn')).toBeEnabled({ timeout: 5_000 })
      await page.getByTestId('approve-btn').click()
      await page.getByTestId('review-status-badge').getByText('approved').waitFor({ timeout: 10_000 })
      await shot(page, 'platform-definition-promotion-conflict-rejected', '06-rebuilt-review-approved')
    })

    // ── Step 07: an independent v4.0.0 promotion lands first (API) ──────────
    await pl.step('07: an independent v4.0.0 promotion lands first, moving the target past review\'s base again', async () => {
      await createAndActivate('4.0.0', 'v4')
      await fullCycle('2.0.0')
    })

    // ── Step 08: scenario step 5 — attempt to release with the now-stale approval ──
    await pl.step('08: EO-004 — the stale approval cannot release; refused with the same named-conflict shape', async (s) => {
      // The rehearsal gate (assertion_run_missing) comes before the conflict re-check, so
      // record a passing assertion run for the stale review first, as the happy-path helper does.
      const assertResp = await request.post(`${API_BASE_URL}/api/v1/promotions/${s.reviewId}/run-assertions`, {
        headers: authHeaders(adminToken),
        data: {
          plan_digest: s.planDigest,
          artifact: { id: `${processKey}-rehearsal`, assertions: [], fixtures: [], rng_seed: 42, non_deterministic_fields: [], candidate_definitions: [] },
        },
      })
      pl.gate(assertResp.ok(), `run-assertions failed: ${assertResp.status()} ${await assertResp.text()}`)

      const applyResp = await request.post(`${API_BASE_URL}/api/v1/promotions/${s.reviewId}/apply`, {
        headers: authHeaders(adminToken),
        data: { plan_digest: s.planDigest },
      })
      pl.gate(applyResp.status() === 409, `expected 409, got ${applyResp.status()}`)
      const body = await applyResp.json() as { type: string; conflicts: Array<{ target_active_version: string }> }
      pl.gate(body.type.endsWith('/promotion-conflict'), `expected a promotion-conflict problem type, got ${body.type}`)
      pl.gate(body.conflicts?.[0]?.target_active_version === '4.0.0', 'refusal must name the target\'s real current version (4.0.0)')
    })

    // ── Step 09: EO-004 — review lands in `failed`, never `applied` ──────────
    await pl.step('09: EO-004 — review status is failed, the release never took effect', async (s) => {
      const contextResp = await request.get(`${API_BASE_URL}/api/v1/promotions/${s.reviewId}/context`, {
        headers: authHeaders(adminToken),
      })
      pl.gate(contextResp.ok(), `context fetch failed: ${contextResp.status()}`)
      const context = await contextResp.json() as { status: string }
      pl.gate(context.status === 'failed', `expected review status "failed", got "${context.status}"`)
    })
  })
})
