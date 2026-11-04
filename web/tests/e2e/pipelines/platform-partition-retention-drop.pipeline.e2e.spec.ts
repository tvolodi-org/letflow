/**
 * Pipeline: Platform Partition Retention Drop (PW-06 / sys-event-log-partitioning)
 *
 * Drives `test/fixtures/uat/scenarios/platform/partition-retention-drop.yaml`
 * end to end against the real, shipped REQ-376 backend mechanism
 * (`Letflow.EventStore.PartitionMaintenance.retire_month/3`) and the real
 * REQ-377 screen/API (`Letflow.Routers.EventRetention`,
 * `EventRetentionPage.tsx`). See
 * `lib/letflow/design/req377-history-retirement-screen.md` §3.7 for the
 * outline this spec implements, and
 * `test/uat-reports/gui-review-2026-09-20-partition-retention-drop.md` for
 * the gap trace that originally filed REQ-376/REQ-377.
 *
 * ## The "real eligible-for-retirement month" fixture problem (read before touching this spec)
 *
 * `Letflow.EventStore.PartitionMaintenance.eligible_months/1` only reports a
 * month eligible once `today >= last_day(month) + min_partition_age_days`,
 * and the real, shipped default for `min_partition_age_days/0` is 400 days
 * (`Application.get_env(:letflow, :event_retention, [])`, no override
 * anywhere in `config/`). Unlike the backend's own ExUnit suite
 * (`test/letflow/event_store/partition_maintenance_test.exs`,
 * `test/letflow/routers/event_retention_test.exs`), which overrides that
 * config value down to `1` from INSIDE the same BEAM node the test runs in,
 * this spec drives a SEPARATE, already-running server process over real
 * HTTP (`BPM_TEST_URL`) -- there is no supported HTTP surface to change that
 * server's own `Application` env at runtime, and restarting the server
 * mid-suite would be a far riskier fixture technique than the one used here.
 *
 * Also, `ensure_future_partitions/2` only ever creates `events` partitions
 * looking FORWARD from "now" (its own moduledoc, §3) -- nothing in the
 * running system would ever auto-create a partition old enough to already
 * be eligible.
 *
 * The fix (`../db-exec.ts`'s `pickEligibleBackdatedMonth` /
 * `createBackdatedEventPartitionSql` / `seedHistoricalEventSql`, REQ-377
 * additions): fabricate a REAL partition, attached to the real `events`
 * parent table, whose calendar-month range genuinely IS more than 400 days
 * in the past -- the exact same real-DDL technique
 * `poisonCompanySchemaSql` already established in this file for a different
 * fixture need (a genuine schema-state precondition an HTTP-only setup
 * cannot produce). `eligible?/2`'s real, unmodified aging check then finds
 * this month eligible on its own -- no server-side config change of any
 * kind, and nothing about `retire_month/3`/`RetentionOperations` is
 * mocked, stubbed, or bypassed. One real event row is seeded inside that
 * partition (`seedHistoricalEventSql`) so this is a genuine month of
 * history being retired, not an empty partition. The target month is
 * derived deterministically from this run's own fixture id
 * (`pickEligibleBackdatedMonth`), spread across ~8 years of possible
 * months, so a repeat run against the same long-lived dev/CI Postgres
 * instance targets a fresh, never-previously-retired month rather than
 * colliding with one an earlier run already detached (a month, once
 * retired, can never become "eligible" again -- it is no longer attached to
 * `events` at all).
 *
 * EO-003 (replay of a retired month's process instance) is explicitly NOT
 * this spec's responsibility to newly prove (design §3.7 point 7) --
 * `EventStore.read/2`'s `events`/`events_archive` union is already covered
 * under REQ-376's own ExUnit suite. This spec only needs to confirm the
 * retirement completes without error, which -- since `retire_month/3` never
 * deletes a row, only reparents a whole partition -- is sufficient evidence
 * no row was dropped.
 *
 * ## Chain topology
 *
 *   pre-check services
 *   → login as admin-user (PLATFORM_ADMIN)
 *   → resolve one real active company (bpm-default)
 *   → pre-step: fabricate a real, backdated, genuinely-eligible `events`
 *     month partition in that company's schema, with one real seeded event
 *     row inside it
 *   → 01 (GUI): navigate to /admin/event-retention, capture the "before"
 *     protected-record count (AC2/EO-002)
 *   → 02 (GUI): click "Retire oldest eligible month"; assert the rest of the
 *     console (header/nav) stays interactive immediately after, not gated
 *     behind a full-page blocking overlay (EO-001)
 *   → 03 (GUI, polled): wait for the retirement to reach "completed"; assert
 *     the outcome table shows this company's row (AC1)
 *   → 04 (GUI): re-read the protected-record count; assert it is unchanged
 *     from step 01 (AC2/EO-002)
 *   → 05 (GUI): a non-PLATFORM_ADMIN session is redirected away from
 *     /admin/event-retention (AC3)
 *   → cleanup: none for the retirement itself -- per the scenario's own
 *     `cleanup.description` ("Retirement is not reversible... run only
 *     against a test environment holding disposable history"), the same
 *     precedent `platform-migration-partial-failure-resume`'s own
 *     `onCleanup` no-op establishes for an intentionally-irreversible
 *     platform action.
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
import {
  runSqlAgainstDevPostgres,
  tenantSchemaName,
  pickEligibleBackdatedMonth,
  createBackdatedEventPartitionSql,
  seedHistoricalEventSql,
  type BackdatedMonth,
} from '../db-exec'

// Real-backend, multi-step GUI flow that polls an async retirement to
// completion -- same budget class as the sibling
// platform-migration-partial-failure-resume spec's own 300s budget.
test.setTimeout(300_000)

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'

interface RetentionPipelineState {
  adminToken: string
  tenantId: string
  schemaName: string
  targetMonth: BackdatedMonth
  beforeProtectedCount: number
  retirementId: string
}

test.describe('Pipeline: platform-partition-retention-drop (PW-06)', () => {
  test('an operator retires the oldest eligible month of history in one action, without blocking the rest of the console, and no protected record is lost', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID()

    const pl = createPipeline<RetentionPipelineState>('platform-partition-retention-drop', { page, request })
    pl.state.adminToken = adminToken

    pl.onCleanup(async () => {
      // Per the scenario's own cleanup.description: retirement is not
      // reversible, and the scenario is meant to be run only against
      // disposable test history. No rollback attempted here -- same
      // precedent as the sibling migration-rollout spec's no-op cleanup.
    })

    // ── Pre-step (scenario preconditions 1-2): fabricate a REAL, genuinely
    //    eligible, backdated month of history in one real company's schema ──
    await pl.step('pre: resolve a real active company; fabricate a real backdated eligible-to-retire events partition with one seeded event', async (s) => {
      const bpmDefault = await resolveTenantContext(request, 'bpm-default', adminToken)
      s.tenantId = bpmDefault.tenantId
      s.schemaName = tenantSchemaName(s.tenantId)
      s.targetMonth = pickEligibleBackdatedMonth(fixtureId)

      runSqlAgainstDevPostgres(createBackdatedEventPartitionSql(s.schemaName, s.targetMonth))

      const eventId = randomUUID()
      const instanceId = randomUUID()
      runSqlAgainstDevPostgres(seedHistoricalEventSql(s.schemaName, s.targetMonth, eventId, instanceId))
    })

    // ── Step 1 (GUI) — scenario step: navigate, capture "before" (AC2/EO-002) ──
    await pl.step('01: navigate to the retention screen and capture the "before" protected-record count', async (s) => {
      await navigateSpa(page, '/admin/event-retention')

      await page.getByTestId('retention-summary-card').waitFor({ timeout: 15_000 })
      const beforeText = await page.getByTestId('retention-summary-protected-count').innerText()
      s.beforeProtectedCount = parseInt(beforeText.trim(), 10)
      pl.gate(Number.isFinite(s.beforeProtectedCount), 'must capture a numeric "before" protected-record count')

      await shot(page, 'platform-partition-retention-drop', '01-before')
    })

    // ── Step 2 (GUI) — scenario step 2: retire the oldest eligible month (AC1) ──
    await pl.step('02: EO-001 -- retiring the oldest eligible month does not block the rest of the console', async () => {
      const retireButton = page.getByTestId('retire-oldest-month-btn')
      await expect(retireButton).toBeEnabled({ timeout: 10_000 })
      await retireButton.click()

      // Immediately after the click -- the mutation's own POST is a fast
      // 202-returning call (§1's async design), not held open for the
      // retirement itself -- assert the rest of the console (the app
      // header, always rendered outside this page's own state) is still
      // visible and interactive, not hidden behind a full-page blocking
      // overlay tied to the retirement's own duration.
      await expect(page.getByTestId('user-display-name')).toBeVisible({ timeout: 5_000 })
      await expect(page.getByTestId('logout-button')).toBeEnabled({ timeout: 5_000 })
      await expect(page.getByTestId('retention-summary-card')).toBeVisible()

      await shot(page, 'platform-partition-retention-drop', '02-retiring')
    })

    // ── Step 3 (GUI, polled) — AC1: the retirement reaches "completed" with a real outcome record ──
    await pl.step('03: AC1 -- poll until the retirement completes; the outcome table shows this company\'s retirement record', async (s) => {
      await page.getByTestId('retirement-id-display').waitFor({ timeout: 20_000 })
      s.retirementId = (await page.getByTestId('retirement-id-display').innerText()).trim()
      pl.gate(!!s.retirementId, 'must capture the retirement id from RetirementStatusPanel')

      // Playwright's own polling (expect.poll), NOT this page's own
      // 2000ms internal poll -- verifies the real end-to-end state
      // transition independently of the frontend's own polling mechanism.
      await expect
        .poll(
          async () => {
            const badge = page.getByTestId('retirement-status-badge').getByTestId('status-badge')
            return await badge.getAttribute('data-status')
          },
          { timeout: 120_000, intervals: [1000, 2000, 3000] },
        )
        .toBe('completed')

      const outcomeRow = page.getByTestId(`retirement-outcome-row-${s.tenantId}`)
      await outcomeRow.waitFor({ timeout: 10_000 })
      const outcomeStatus = page.getByTestId(`retirement-outcome-status-${s.tenantId}`).getByTestId('status-badge')
      await expect(outcomeStatus).toHaveAttribute('data-status', 'succeeded')

      const retiredPartition = await page.getByTestId(`retirement-outcome-partition-${s.tenantId}`).innerText()
      pl.gate(
        retiredPartition.trim() === s.targetMonth.partitionName,
        `expected the retired partition to be ${s.targetMonth.partitionName}, got "${retiredPartition}"`,
      )

      await shot(page, 'platform-partition-retention-drop', '03-completed')
    })

    // ── Step 4 (GUI) — AC2/EO-002: protected-record count is unchanged ──
    await pl.step('04: AC2/EO-002 -- the protected-record count after retirement equals the count captured before it', async (s) => {
      // RetirementStatusPanel's own effect invalidates the summary query on
      // completion (design §3.4) -- re-read the on-screen count directly
      // rather than re-navigating, so this exercises that real
      // invalidation path, not just a fresh page load.
      await expect
        .poll(
          async () => {
            const text = await page.getByTestId('retention-summary-protected-count').innerText()
            return parseInt(text.trim(), 10)
          },
          { timeout: 15_000 },
        )
        .toBe(s.beforeProtectedCount)

      await shot(page, 'platform-partition-retention-drop', '04-after')
    })

    // ── Step 5 (GUI) — AC3: unreachable to a non-PLATFORM_ADMIN role ──
    await pl.step('05: AC3 -- a non-PLATFORM_ADMIN role cannot reach the retention screen', async () => {
      // `worker-user` (TASK_WORKER) -- same established "not PLATFORM_ADMIN"
      // fixture credential `platform-migration-partial-failure-resume` and
      // `platform-login-routing-by-role` already use.
      const nonAdminToken = await getKeycloakToken(
        request, 'worker-user', resolveCredential('UAT_QA_WORKER_PASSWORD', 'worker-pass'),
      )
      await loginWithToken(page, nonAdminToken)

      await page.goto('/admin/event-retention', { waitUntil: 'domcontentloaded' })
      await page.waitForURL(/\/instances/, { timeout: 10_000 })
      await expect(page.getByTestId('retire-oldest-month-btn')).toHaveCount(0)

      await shot(page, 'platform-partition-retention-drop', '05-non-admin-redirected')
    })

    await pl.runCleanup()
  })
})
