/**
 * Pipeline: Platform Migration Partial-Failure Resume (PW-04 / sys-tenant-migration-fanout)
 *
 * Drives `test/fixtures/uat/scenarios/platform/migration-partial-failure-resume.yaml`
 * end to end against the real, shipped REQ-374 backend
 * (`Letflow.Platform.MigrationRollout`, `Letflow.Routers.PlatformMigrations`,
 * merged `eaa8abe6`, PR #1693) and the real REQ-375 screen
 * (`PlatformMigrationConsolePage.tsx`). See
 * `lib/letflow/design/req375-rollout-status-screen.md` §8 for the outline
 * this spec implements, and `test/uat-reports/gui-review-2026-09-20-migration-partial-failure-resume.md`
 * for the gap trace that originally filed REQ-374/REQ-375.
 *
 * ## Two real infra additions this spec needed (read before touching auth)
 *
 * 1. REQ-374's `start_rollout/3` has NO per-company scope parameter (confirmed
 * by reading `lib/letflow/platform/migration_rollout.ex`'s
 * `active_company_tenant_ids/0` and `lib/letflow/routers/platform_migrations.ex`'s
 * request body — every call targets EVERY :active, provisioned tenant on the
 * environment, unconditionally). There is therefore no real HTTP-only way to
 * make exactly one company's schema fail the real `check_additive_only/3`
 * `information_schema.columns` check while every other company succeeds —
 * the thing this scenario's own precondition 2 requires. The backend's own
 * ExUnit suite (`test/letflow/platform/migration_rollout_test.exs`
 * `poison_company_schema!/3`) solves this with a direct `Repo.query!/2`
 * CREATE TABLE. `../db-exec.ts`'s `runSqlAgainstDevPostgres` is the
 * Playwright-side equivalent of that exact technique (shelling into the
 * already-running `docker compose` `postgres` service's own `psql` — no new
 * npm DB-client dependency), not a mock or substitute for it: the DDL
 * conflict this produces is real, and `check_additive_only/3` detects it via
 * a genuine `information_schema.columns` read.
 *
 * 2. UAT-RUNNER's first live run (against the ISS-0777-fixed backend)
 * surfaced a second real gap: `do_run_column_promotion/2` calls
 * `ensure_entity_table/2` BEFORE `check_additive_only/3`, and that function's
 * table-doesn't-exist-yet branch (`create_and_populate_entity_table/3`)
 * requires a real, ACTIVE `Letflow.Entities.EntityDefinition` for the target
 * `entity_type` to already exist in that tenant's schema — with none
 * registered, `Definitions.get_active_definition_by_name/2` genuinely returns
 * `{:error, :not_found}` and the company FAILS instead of succeeding. This
 * spec's own poisoned company (bilimbaga) never hits that branch at all — its
 * `entity_<entity_type>` table already exists (via the poison step above), so
 * `entity_table_exists?/2` short-circuits straight to `check_additive_only/3`
 * — but the two HEALTHY companies (bpm-default, swiftroute) do need a real,
 * active entity definition registered first, or they fail too, for an
 * unrelated reason, breaking the whole scenario at step 02.
 * `../db-exec.ts`'s `createActiveEntityDefinition` calls the real
 * `Letflow.Entities.Definitions.create_definition/2` +
 * `.activate_definition/4` context functions directly via
 * `mix run --no-start -e` (same repo checkout backing the server under
 * test) — the exact functions `migration_rollout_test.exs`'s own
 * `create_active_definition!/3` fixture calls, not a raw-SQL reimplementation
 * of entity-definition persistence. No HTTP endpoint could do this instead:
 * `POST /entities/definitions`/`.../activate` resolve their target tenant
 * from the CALLING TOKEN's own Keycloak realm, and no known
 * `:EntitiesDefinitionsWrite`-permission fixture user exists in bilimbaga's
 * or swiftroute's own realms for this pair.
 *
 * Login/session setup uses the SAME `loginWithToken`
 * (`sessionStorage.__e2e_session` injection after a real Keycloak
 * password-grant token) every other pipeline spec in this directory already
 * uses — no new auth mechanism invented here, matching
 * `platform-definition-promotion-rollback.pipeline.e2e.spec.ts`'s own
 * pattern exactly.
 *
 * ## Chain topology
 *
 *   pre-check services
 *   → login as admin-user (PLATFORM_ADMIN)
 *   → resolve 3 real tenant contexts (bpm-default, bilimbaga, swiftroute —
 *     the same fixture tenants `platform-definition-promotion-rollback` and
 *     `platform-definition-promotion-conflict-rejected` already resolve),
 *     designating bilimbaga as the one poisoned company (precondition 1/2)
 *   → pre-step: register + activate a real EntityDefinition for the target
 *     entity_type in the two HEALTHY companies (bpm-default, swiftroute), so
 *     they can genuinely succeed; poison bilimbaga's schema with a
 *     same-named, conflicting-type ("bigint" vs. the rollout's own "text")
 *     column, so it genuinely fails (precondition 2/3)
 *   → 01 (GUI): operator starts the rollout targeting every active company
 *   → 02 (system, asserted from step 01's own response): failure isolation —
 *     bilimbaga FAILED with a reason, bpm-default/swiftroute SUCCEEDED
 *   → 03 (GUI): resume control is visible (outstanding company present)
 *   → 04 (GUI): cure bilimbaga's schema, then click resume
 *   → 05 (system, asserted from step 04's own response): resume touched only
 *     the outstanding company; already-succeeded companies' completed_at is
 *     byte-identical to before
 *   → 06 (GUI): starting the identical rollout again renders the EO-005
 *     no-op banner, distinguishable from the fresh-run banner, altering
 *     nothing
 *   → 07 (GUI): the screen is unreachable to a non-PLATFORM_ADMIN role
 *   → cleanup: none for the rollout itself (per the scenario's own
 *     `cleanup.description` — "the change remains applied to every company;
 *     that is the intended end state"); the poisoned company's schema is
 *     left in its post-resume (cured, column-added) state for the same
 *     reason.
 *
 * ## Known, disclosed gaps this spec does NOT assert (mirrors design §8's own disclosure block)
 *
 * 1. This spec runs against whatever set of tenants is :active on the target
 *    environment at run time (REQ-374 has no scope parameter — see above).
 *    On a shared dev/CI environment with more :active tenants than the 3
 *    fixture tenants this spec resolves, those other tenants are also
 *    targeted by both rollout calls below and will pick up the same
 *    fixture-unique `entity_type`/`attribute` pair harmlessly (fresh column,
 *    additive, never reused) — this spec's own assertions only ever read the
 *    three tenant_ids it resolved, never the full outcome-array length or
 *    set (same ">= not ==" discipline `migration_rollout_test.exs`'s own
 *    "queryable outcome record" describe block already documents for the
 *    identical reason).
 * 2. It does not re-verify OQ-1 of the REQ-374 design (scope-drift on a
 *    repeat `start_rollout/3` call against a newly-onboarded tenant) — no
 *    tenant is onboarded mid-scenario here.
 * 3. It does not re-verify §9 OQ-1 of the REQ-375 design (tenant-name
 *    pagination) — asserts against `rollout-outcome-row-{tenant_id}` testids
 *    directly, not against resolved display names.
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  resolveTenantContext,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential } from '../helpers'
import { typeIntoTestIdInput } from '../type-into-input'
import {
  runSqlAgainstDevPostgres,
  tenantSchemaName,
  poisonCompanySchemaSql,
  cureCompanySchemaSql,
  createActiveEntityDefinition,
} from '../db-exec'

// Multi-step real-backend GUI flow, same rationale as the sibling
// platform-definition-promotion-rollback spec's own 300s budget.
test.setTimeout(300_000)

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'

interface RolloutPipelineState {
  adminToken: string
  targetEntityType: string
  targetAttribute: string
  tableName: string
  poisonedTenantId: string
  poisonedSchema: string
  healthyTenantIds: string[]
  rolloutId: string
  firstPassCompletedAt: Record<string, string>
}

test.describe('Pipeline: platform-migration-partial-failure-resume (PW-04)', () => {
  test('one company failing a platform-wide change does not stop the others, and the rollout can be resumed', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 8)
    // ISS-0777: entity_type/attribute now go straight into a Postgres
    // table/column name (`Letflow.TenantProvisioning.table_name_for_entity_type/1`
    // -- "entity_" <> entity_type) and the backend enforces identifier
    // format (lowercase letters/digits/underscores only, no hyphens) via a
    // real 422 rather than crashing. A UUID-derived fixture id is pure hex
    // (no hyphen appears within the first 8 chars of a v4 UUID's own first
    // block), but the SEPARATOR joining it to a literal prefix must be an
    // underscore too, not a hyphen, or the backend correctly rejects this
    // spec's own fixture. `pl_rollout_${fixtureId}` — same uniqueness
    // guarantee as before, just a valid identifier.
    const targetEntityType = `pl_rollout_${fixtureId}`
    const targetAttribute = 'tax_id'

    const pl = createPipeline<RolloutPipelineState>('platform-migration-partial-failure-resume', { page, request })
    pl.state.adminToken = adminToken
    pl.state.targetEntityType = targetEntityType
    pl.state.targetAttribute = targetAttribute
    pl.state.tableName = `entity_${targetEntityType}`
    pl.state.firstPassCompletedAt = {}

    pl.onCleanup(async () => {
      // Per the scenario's own cleanup.description: "The change remains
      // applied to every company; that is the intended end state." No
      // rollback of the rollout or the poisoned company's now-cured schema.
    })

    // ── Pre-step (preconditions 1-3): resolve >= 3 real active companies,
    //    make the two healthy ones ABLE to succeed, make the one poisoned
    //    company UNABLE to ────────────────────────────────────────────────
    await pl.step('pre: resolve 3 real active companies; register+activate the target entity for the healthy two; poison the third with a real conflicting-type column', async (s) => {
      const bpmDefault = await resolveTenantContext(request, 'bpm-default', adminToken)
      const bilimbaga = await resolveTenantContext(request, 'bilimbaga', adminToken)
      const swiftroute = await resolveTenantContext(request, 'swiftroute', adminToken)

      s.poisonedTenantId = bilimbaga.tenantId
      s.healthyTenantIds = [bpmDefault.tenantId, swiftroute.tenantId]
      s.poisonedSchema = tenantSchemaName(s.poisonedTenantId)

      // Precondition 3: fresh, never-used-before entity_type/attribute pair
      // -- fixtureId guarantees this, so "no rollout exists yet for this
      // pair" holds without a separate GET/check.

      // The two HEALTHY companies must have a real, ACTIVE EntityDefinition
      // for the target entity_type BEFORE the rollout runs, or
      // ensure_entity_table/2's create-branch fails them for an unrelated
      // reason (UAT-RUNNER's live-run finding — see this file's own header
      // comment, "Two real infra additions"). The poisoned company must NOT
      // get one: its table already exists (poisoned below), so
      // ensure_entity_table/2 never reaches that branch for it either way.
      for (const tenantId of s.healthyTenantIds) {
        createActiveEntityDefinition(tenantSchemaName(tenantId), s.targetEntityType)
      }

      runSqlAgainstDevPostgres(poisonCompanySchemaSql(s.poisonedSchema, s.tableName, s.targetAttribute))
    })

    // ── Step 1 (GUI) — scenario step 1, produces rollout_id ─────────────────
    await pl.step('01: operator starts the rollout targeting every active company', async (s) => {
      await navigateSpa(page, '/admin/platform-migrations')
      await typeIntoTestIdInput(page, 'rollout-entity-type-input', s.targetEntityType)
      await typeIntoTestIdInput(page, 'rollout-attribute-input', s.targetAttribute)
      await typeIntoTestIdInput(page, 'rollout-pg-type-input', 'text')
      await page.getByTestId('rollout-start-btn').click()

      await page.getByTestId('rollout-id-display').waitFor({ timeout: 20_000 })
      s.rolloutId = (await page.getByTestId('rollout-id-display').innerText()).trim()
      pl.gate(!!s.rolloutId, 'must capture the rollout id from RolloutSummaryHeader')

      // AC3 precondition for step 6 later: this is a FRESH run, so the
      // fresh-run banner (not the no-op banner) must be showing now.
      await page.getByTestId('rollout-fresh-run-banner').waitFor({ timeout: 10_000 })
      await expect(page.getByTestId('rollout-noop-banner')).toHaveCount(0)

      await shot(page, 'platform-migration-partial-failure-resume', '01-started')
    })

    // ── Step 2 (system) — EO-001/EO-002, asserted off step 1's own response render ──
    await pl.step('02: EO-001/EO-002 -- the poisoned company failed with a reason; the healthy companies succeeded', async (s) => {
      const poisonedRow = page.getByTestId(`rollout-outcome-row-${s.poisonedTenantId}`)
      await poisonedRow.waitFor({ timeout: 10_000 })
      const poisonedStatus = page.getByTestId(`rollout-outcome-status-${s.poisonedTenantId}`).getByTestId('status-badge')
      await expect(poisonedStatus).toHaveAttribute('data-status', 'failed')
      const poisonedReason = await page.getByTestId(`rollout-outcome-reason-${s.poisonedTenantId}`).innerText()
      pl.gate(poisonedReason.trim().length > 0, 'the poisoned company must show a non-empty reason (EO-003)')
      // NOT the em-dash placeholder: REQ-374's record_outcome_result/2 sets
      // completed_at the instant an outcome leaves 'pending', for 'failed'
      // exactly as much as for 'succeeded' (migration_rollout_test.exs
      // asserts a non-nil completed_at for every outcome, including the one
      // it deliberately poisons). The em-dash is reserved for a genuinely
      // still-pending outcome, which this poisoned company never is by the
      // time step 1's response renders. See commit 29a72762's own finding
      // (UAT-RUNNER, "new_finding_2") for the prior wrong assumption this
      // corrects.
      const poisonedCompletedAtFirstPass = await page.getByTestId(`rollout-outcome-completed-${s.poisonedTenantId}`).innerText()
      pl.gate(
        poisonedCompletedAtFirstPass.trim() !== '—' && poisonedCompletedAtFirstPass.trim().length > 0,
        'the poisoned (failed) company must show a real completed-at, not the em-dash placeholder',
      )

      for (const tenantId of s.healthyTenantIds) {
        const status = page.getByTestId(`rollout-outcome-status-${tenantId}`).getByTestId('status-badge')
        await expect(status).toHaveAttribute('data-status', 'succeeded')
        const completedAt = await page.getByTestId(`rollout-outcome-completed-${tenantId}`).innerText()
        pl.gate(completedAt.trim() !== '—' && completedAt.trim().length > 0, `healthy company ${tenantId} must show a real completed-at`)
        s.firstPassCompletedAt[tenantId] = completedAt
        // A succeeded row renders no reason text (§7 field mapping).
        await expect(page.getByTestId(`rollout-outcome-reason-${tenantId}`)).toHaveText('')
      }
    })

    // ── Step 3 (GUI) — scenario step 3: operator reads the status screen; resume visible ──
    await pl.step('03: resume control is visible while the poisoned company is outstanding (AC2)', async () => {
      await expect(page.getByTestId('rollout-resume-btn')).toBeVisible({ timeout: 10_000 })
      await shot(page, 'platform-migration-partial-failure-resume', '03-status-resume-visible')
    })

    // ── Step 4 (GUI) — scenario step 4: cure the poisoned schema, then resume ──
    await pl.step('04: EO-004 -- cure the poisoned schema, then resume the rollout', async (s) => {
      runSqlAgainstDevPostgres(cureCompanySchemaSql(s.poisonedSchema, s.tableName, s.targetAttribute))

      await page.getByTestId('rollout-resume-btn').click()
      // A NEW status panel render (the mutation's own response, §4) — wait
      // for the resume button to disappear (every outcome now succeeded).
      await expect(page.getByTestId('rollout-resume-btn')).toHaveCount(0, { timeout: 20_000 })
      await shot(page, 'platform-migration-partial-failure-resume', '04-resumed')
    })

    // ── Step 5 (system) — EO-004, asserted off step 4's own response render ──
    await pl.step('05: EO-004 -- resume touched only the outstanding company; healthy companies are untouched', async (s) => {
      const poisonedStatus = page.getByTestId(`rollout-outcome-status-${s.poisonedTenantId}`).getByTestId('status-badge')
      await expect(poisonedStatus).toHaveAttribute('data-status', 'succeeded')
      const poisonedCompletedAt = await page.getByTestId(`rollout-outcome-completed-${s.poisonedTenantId}`).innerText()
      pl.gate(poisonedCompletedAt.trim() !== '—' && poisonedCompletedAt.trim().length > 0, 'the previously-poisoned company must now show a real completed-at')

      for (const tenantId of s.healthyTenantIds) {
        const completedAt = await page.getByTestId(`rollout-outcome-completed-${tenantId}`).innerText()
        pl.gate(
          completedAt === s.firstPassCompletedAt[tenantId],
          `healthy company ${tenantId}'s completed-at must be byte-identical to the first pass (was "${s.firstPassCompletedAt[tenantId]}", now "${completedAt}") -- resume must not re-touch an already-succeeded company`,
        )
      }
    })

    // ── Step 6 (GUI) — scenario step 6: EO-005, the identical rollout again ──
    await pl.step('06: EO-005 -- starting the same rollout again renders the no-op banner, alters nothing', async (s) => {
      // The form's own values are retained since the last submit (design
      // §6/§1.1) -- press Start again with nothing retyped.
      await page.getByTestId('rollout-start-btn').click()

      await page.getByTestId('rollout-noop-banner').waitFor({ timeout: 20_000 })
      await expect(page.getByTestId('rollout-fresh-run-banner')).toHaveCount(0)
      await shot(page, 'platform-migration-partial-failure-resume', '06-noop')

      // Every row's completed-at is unchanged from post-step-5 -- the
      // re-run altered nothing (EO-005's own "and alters nothing").
      const poisonedCompletedAfterNoop = await page.getByTestId(`rollout-outcome-completed-${s.poisonedTenantId}`).innerText()
      pl.gate(poisonedCompletedAfterNoop.trim() !== '—' && poisonedCompletedAfterNoop.trim().length > 0, 'previously-poisoned company must still show a real completed-at after the no-op re-run')
      for (const tenantId of s.healthyTenantIds) {
        const completedAt = await page.getByTestId(`rollout-outcome-completed-${tenantId}`).innerText()
        pl.gate(
          completedAt === s.firstPassCompletedAt[tenantId],
          `healthy company ${tenantId}'s completed-at must remain byte-identical after the no-op re-run (was "${s.firstPassCompletedAt[tenantId]}", now "${completedAt}")`,
        )
      }
    })

    // ── Step 7 (GUI) — AC4: the screen is unreachable to a non-PLATFORM_ADMIN role ──
    await pl.step('07: AC4 -- a non-PLATFORM_ADMIN role cannot reach the rollout-status screen', async () => {
      // `worker-user` (TASK_WORKER) is the same established tenant-scoped
      // fixture `platform-login-routing-by-role.pipeline.e2e.spec.ts` already
      // uses for "not PLATFORM_ADMIN" assertions — reused here rather than
      // inventing a new fixture credential.
      const nonAdminToken = await getKeycloakToken(
        request, 'worker-user', resolveCredential('UAT_QA_WORKER_PASSWORD', 'worker-pass'),
      )
      await loginWithToken(page, nonAdminToken)

      await page.goto('/admin/platform-migrations', { waitUntil: 'domcontentloaded' })
      await page.waitForURL(/\/instances/, { timeout: 10_000 })
      await expect(page.getByTestId('rollout-start-btn')).toHaveCount(0)
      await shot(page, 'platform-migration-partial-failure-resume', '07-non-admin-redirected')
    })

    await pl.runCleanup()
  })
})
