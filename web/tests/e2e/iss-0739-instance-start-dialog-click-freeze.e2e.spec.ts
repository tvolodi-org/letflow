/**
 * E2E regression guard — ISS-0739: real trusted click on InstanceBoardPage's
 * `start-instance-button` froze the renderer's main thread intermittently
 * (~1/3 hit rate, per ISSUE-FIXER's diagnosis while investigating REQ-371's
 * `platform-definition-promotion-rollback.pipeline.e2e.spec.ts` step 02).
 *
 * Root cause (see `lib/letflow/design/iss-0739-instanceboardpage-start-dialog-click-freeze-fix.md`):
 * `InstanceBoardPage.tsx`'s `openStartDialog` fired 7 synchronous `setState`
 * calls inside the same native click event-dispatch turn as a real
 * UA-trusted click — the same trigger class already confirmed and fixed for
 * ISS-0662 (`EntityCrudPage.tsx`), ISS-0729/ISS-0737/ISS-0738
 * (`DefinitionListPage.tsx`), via `web/src/utils/deferClickState.ts`. The fix
 * wraps `openStartDialog`, `closeStartDialog`, and `submitStartInstance`'s
 * pre-`await` validation-branch `setState` calls in `deferClickState`.
 * Controlled-input `onChange` handlers are deliberately NOT wrapped (design
 * doc §1/OQ-1) — not covered by this spec's assertions.
 *
 * WHY THIS TEST USES `hover()` + `mouse.down()` + `mouse.up()`, NOT
 * `Locator.click()` OR `Locator.dispatchEvent('click')`: matching
 * ISS-0662/ISS-0737's own finding that only a real UA-trusted gesture
 * reproduces the freeze — `.click()`'s dispatch-event shortcut does not.
 *
 * FAIL-THEN-PASS (WF-03 Step 4): this file must fail against the pre-fix
 * tree (the `deferClickState` wraps in `InstanceBoardPage.tsx` reverted) and
 * pass post-fix — see this run's FRONTEND-DEV handoff for the real quoted
 * hit/miss counts both ways (the bug is intermittent at ~1/3 hit rate, so a
 * single clean/failing run is not sufficient evidence either way).
 *
 * Covers, per the design doc §3 / §1's handler audit:
 *  - `openStartDialog` (start-instance-button click opens the dialog)
 *  - `closeStartDialog` via the Cancel button
 *  - `closeStartDialog` via the backdrop click
 *  - `submitStartInstance`'s early-return validation branch (deferred
 *    `setStartValidationError`)
 *  - `submitStartInstance`'s success path (deferred pre-await resets, then
 *    the post-await dialog-close + navigation)
 */

import { test, expect, type Locator, type Page } from '@playwright/test'
import { getKeycloakToken, loginWithToken, assertServiceReadiness, resolveCredential } from './helpers'
import { typeIntoTestIdInput } from './type-into-input'

const API_PREFIX = '/api/v1'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'
// Generous above the fix's measured ~1s resolution, tight enough that a
// genuine sustained freeze reliably trips it — same bound and reasoning as
// the ISS-0662/ISS-0729/ISS-0737 sibling specs use.
const BOUND_MS = 5_000

/**
 * Drives a REAL, UA-trusted click (hover -> mousedown -> mouseup) raced
 * against `boundMs`. If the freeze regresses, `mouse.up()` never resolves
 * and this rejects with a clear message well before Playwright's own
 * (much longer) default action/test timeout would trip.
 */
async function trustedClickBounded(locator: Locator, label: string, boundMs = BOUND_MS): Promise<void> {
  await locator.hover()
  await locator.page().mouse.down()
  const upPromise = locator.page().mouse.up()
  upPromise.catch(() => {
    // Swallow a late rejection/resolution racing past the bound below —
    // already handled via the timeout branch below.
  })
  let timer: ReturnType<typeof setTimeout>
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`ISS-0739 regression: trusted click on "${label}" did not resolve within ${boundMs}ms (froze the renderer)`)),
      boundMs,
    )
  })
  try {
    await Promise.race([upPromise, timeout])
  } finally {
    clearTimeout(timer!)
  }
}

// `typeIntoTestIdInput` (the sandbox `.fill()`-hang workaround — see its own
// doc comment in `./type-into-input.ts`) now lives in a shared plain module
// so other spec files can reuse it without importing this spec file (which
// would re-run this file's own `test()`/`test.describe()` registrations as
// an import side effect).
async function typeIntoDefinitionNameInput(page: Page, value: string): Promise<void> {
  await typeIntoTestIdInput(page, 'start-definition-name', value)
}

async function createAndActivateDefinition(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  name: string,
  version: string,
): Promise<{ id: string; name: string; version: string }> {
  // Hit the backend directly (API_BASE_URL), NOT the vite dev-server proxy
  // that fronts the browser-driven /api/* paths — matching
  // platform-definition-promotion-rollback.pipeline.e2e.spec.ts's own
  // convention. This sidesteps the unrelated, already-tracked intermittent
  // empty-body HTTP 500 the dev proxy surfaces for some /api/v1/definitions*
  // requests (see docs/issues/ISS-0739.yaml, filed by a concurrent
  // CODE-DESIGNER for a different backend defect — not this fix's concern;
  // this test's own trusted-click assertions are unaffected either way,
  // since only the GUI's own page navigation and clicks — never this
  // setup helper — go through the proxied path).
  const response = await request.post(`${API_BASE_URL}${API_PREFIX}/definitions`, {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: {
      name,
      version,
      description: '',
      graph: {
        nodes: [
          { id: 'start', node_type: 'START', label: null, attributes: null },
          { id: 'end', node_type: 'END', label: null, attributes: null },
        ],
        edges: [
          { id: 'e1', source: 'start', target: 'end', condition: null, is_default: false },
        ],
      },
      stage: null,
    },
  })
  if (!response.ok()) {
    throw new Error(`POST /definitions failed (${response.status()}): ${await response.text()}`)
  }
  const def = await response.json() as { id: string; name: string; version: string }

  const activate = await request.post(`${API_BASE_URL}${API_PREFIX}/definitions/${def.id}/activate`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  if (!activate.ok()) {
    throw new Error(`POST /definitions/${def.id}/activate failed (${activate.status()}): ${await activate.text()}`)
  }
  return def
}

async function cancelInstance(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  instanceId: string,
): Promise<void> {
  await request.post(`${API_BASE_URL}${API_PREFIX}/instances/${instanceId}/cancel`, {
    headers: { Authorization: `Bearer ${token}` },
    data: { reason: 'ISS-0739 e2e cleanup' },
  }).catch(() => undefined)
}

async function gotoInstances(page: Page): Promise<void> {
  await page.goto('/instances', { waitUntil: 'domcontentloaded' })
  await expect(page.getByTestId('start-instance-button')).toBeVisible({ timeout: 15_000 })
}

test.describe('ISS-0739 — InstanceBoardPage start-instance-button click renderer-freeze regression', () => {
  let token: string
  const createdInstanceIds: string[] = []

  test.beforeAll(async ({ request }) => {
    await assertServiceReadiness(request, API_BASE_URL)
    token = await getKeycloakToken(request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'))
  })

  test.beforeEach(async ({ page }) => {
    await loginWithToken(page, token)
  })

  test.afterAll(async ({ request }) => {
    for (const id of createdInstanceIds) {
      await cancelInstance(request, token, id)
    }
  })

  test('TC-ISS-0739-01: real click on start-instance-button opens the dialog, Cancel and backdrop close it, within 5s each', async ({ page, request }) => {
    const unique = `ISS-0739-open-${Date.now()}`
    const def = await createAndActivateDefinition(request, token, unique, '1.0.0')

    await gotoInstances(page)

    // openStartDialog — the confirmed culprit handler.
    await trustedClickBounded(page.getByTestId('start-instance-button'), 'start-instance-button (open)')
    await expect(page.getByTestId('start-instance-dialog')).toBeVisible({ timeout: BOUND_MS })

    // closeStartDialog via the Cancel button.
    const cancelButton = page.getByRole('button', { name: 'Cancel' })
    await trustedClickBounded(cancelButton, 'start-instance-dialog Cancel button')
    await expect(page.getByTestId('start-instance-dialog')).not.toBeVisible({ timeout: BOUND_MS })

    // Reopen, then closeStartDialog via the backdrop click.
    await trustedClickBounded(page.getByTestId('start-instance-button'), 'start-instance-button (reopen)')
    await expect(page.getByTestId('start-instance-dialog')).toBeVisible({ timeout: BOUND_MS })

    const dialog = page.getByTestId('start-instance-dialog')
    // Click near the top-left corner of the overlay, outside the inner card,
    // so it lands on the backdrop's own onClick, not the card's
    // stopPropagation wrapper.
    const box = await dialog.boundingBox()
    if (!box) throw new Error('start-instance-dialog has no bounding box')
    await page.mouse.move(box.x + 10, box.y + 10)
    await page.mouse.down()
    const upPromise = page.mouse.up()
    upPromise.catch(() => undefined)
    let timer: ReturnType<typeof setTimeout>
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error('ISS-0739 regression: backdrop click did not resolve within 5000ms (froze the renderer)')), BOUND_MS)
    })
    try {
      await Promise.race([upPromise, timeout])
    } finally {
      clearTimeout(timer!)
    }
    await expect(page.getByTestId('start-instance-dialog')).not.toBeVisible({ timeout: BOUND_MS })

    // Definition never started an instance — nothing to clean up beyond the
    // definition itself, which this suite intentionally leaves (matching
    // sibling specs' convention of not deleting ACTIVE definitions mid-fixture).
    void def
  })

  test('TC-ISS-0739-02: submitStartInstance early-return validation branch defers state under a real click, within 5s', async ({ page }) => {
    await gotoInstances(page)

    await trustedClickBounded(page.getByTestId('start-instance-button'), 'start-instance-button')
    await expect(page.getByTestId('start-instance-dialog')).toBeVisible({ timeout: BOUND_MS })

    // Leave startDefinitionName unresolved (no matching definition, so
    // definitionId stays undefined) — exercises the early-return branch's
    // deferred setStartValidationError call.
    await typeIntoDefinitionNameInput(page, `ISS-0739-unresolved-${Date.now()}`)

    await trustedClickBounded(page.getByTestId('submit-start-instance'), 'submit-start-instance (validation early-return)')
    await expect(page.getByText('Select a valid active definition name.')).toBeVisible({ timeout: BOUND_MS })
    // Dialog must still be open — an early return, not a submit.
    await expect(page.getByTestId('start-instance-dialog')).toBeVisible()
  })

  test('TC-ISS-0739-03: submitStartInstance success path (real click) closes the dialog and navigates within 5s', async ({ page, request }) => {
    const unique = `ISS-0739-submit-${Date.now()}`
    const def = await createAndActivateDefinition(request, token, unique, '1.0.0')

    await gotoInstances(page)

    await trustedClickBounded(page.getByTestId('start-instance-button'), 'start-instance-button')
    await expect(page.getByTestId('start-instance-dialog')).toBeVisible({ timeout: BOUND_MS })

    await typeIntoDefinitionNameInput(page, def.name)
    await expect(page.getByTestId('start-definition-version')).toHaveValue(def.version, { timeout: 10_000 })

    await trustedClickBounded(page.getByTestId('submit-start-instance'), 'submit-start-instance (success path)')
    await expect(page.getByTestId('start-instance-dialog')).not.toBeVisible({ timeout: BOUND_MS })
    await page.waitForURL(/\/instances\/.+/, { timeout: 15_000 })

    const instanceId = page.url().split('/instances/')[1]
    if (instanceId) createdInstanceIds.push(instanceId)
  })
})
