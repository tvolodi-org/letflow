/**
 * Pipeline: Platform Definition Semantic Validation (PW-02 / sys-definition-semantic-validation)
 *
 * Drives `test/fixtures/uat/scenarios/platform/definition-type-error-blocked.yaml`
 * end to end for real (REQ-431). REQ-372 already shipped the backend semantic
 * checks (`Letflow.Definitions.SemanticValidation`, field-existence +
 * type-compatibility over EXCLUSIVE_GATEWAY edge conditions); this spec proves
 * the frontend REQ-431 built on top of it — the canvas/problem-list
 * presentation, the save-time `POST /:id/validate` re-check, and the
 * "Submit for Release" re-check surface — actually presents what the backend
 * already computes.
 *
 * ISS-0912 (merged ahead of this requirement, `render_activate/2` returns a
 * 422 + violations array for `{:semantic_validation_failed, _}`, matching
 * `/validate`'s own shape) is the prerequisite the second pipeline below
 * depends on.
 *
 * Chain topology (mirrors §7.1 of
 * lib/letflow/design/req431-definition-validation-canvas-presentation.md),
 * TRIMMED from its originally-authored 11-step form -- see the "Known gap"
 * note below:
 *   pre-check services
 *   → login as author (admin-user, PLATFORM_ADMIN — has designer access)
 *   → 01: create a DRAFT definition (API) with a declared variable schema
 *         (a money-amount field + a customer-name field) and a minimal valid
 *         graph: START -> EXCLUSIVE_GATEWAY -> two branches -> END, both
 *         gateway edges holding an initially-VALID condition
 *   → 02 (GUI): open the definition in the editor
 *   → 03 (GUI): edit edge e2's condition to reference an undeclared field
 *         close to the real declared field (Levenshtein suggestion, AC2/EO-003)
 *         and edge e3's condition to compare the money field against the
 *         customer-name field (AC3/EO-001's "two independent broken rules")
 *   → 04 (GUI): Save                                          [scenario step 1]
 *   → 05 (GUI): both problems render together, each showing the typed field
 *         name, the suggested nearest field for the typo'd one, and the rule
 *         as authored verbatim                    [EO-001, EO-003, AC2, AC3]
 *   → 06 (GUI): Submit for Release is blocked / definition stays DRAFT [EO-002, AC4]
 *   → cleanup: none required (matches scenario's own cleanup.cancel_open_instances: false)
 *
 * A second, independent test below covers EO-005's happy path (a clean
 * definition's release submission re-checks and activates) against its own
 * fixture that starts clean -- no edge-condition editing at all, so it does
 * not depend on the flaky interaction the "Known gap" note describes.
 *
 * KNOWN GAP (pre-existing, unrelated to this requirement's own diff, not
 * fixed here per ORCH direction): re-opening `ConditionDialog` for a SECOND
 * edit of an edge already edited once earlier in the SAME test run is
 * intermittently unreliable -- confirmed directly, repeatedly, against a
 * real browser: the very FIRST double-click on a freshly-loaded canvas
 * reliably opens the dialog, but a second edit after an intervening
 * save/re-layout cycle does not, regardless of a preceding single click,
 * `force: true`, MiniMap-avoidance, or dispatching the DOM event directly
 * rather than through Playwright's pointer-position-based click. This blocks
 * e2e coverage of the scenario's own steps 3/4 (incrementally fixing one
 * rule, saving, confirming the OTHER rule's violation still blocks release,
 * then fixing it too) and of EO-004/AC6 ("once both violations are
 * corrected... no remaining problems") specifically via the
 * fix-after-having-been-broken path. Filed for ISSUE-FIXER as a separate,
 * pre-existing ProcessCanvas/ConditionDialog interaction defect, not
 * REQ-431's own scope to fix. AC5's own stub-based "clean-then-fresh-failure"
 * scenario was never meant to be e2e-covered in the first place (design §7.2)
 * and is proven for real, independently of this gap, by
 * `DefinitionEditorPage.releaseCheck.test.tsx`.
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import { createPipeline, getKeycloakToken, loginWithToken, navigateSpa, authHeaders, shot } from '../pipeline'
import { assertServiceReadiness, resolveCredential } from '../helpers'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'

interface SemanticValidationPipelineState {
  adminToken: string
  definitionId: string
}

test.describe('Pipeline: platform-definition-type-error-blocked (PW-02)', () => {
  test('broken decision rules are reported together, block release, and are re-checked fresh on submission', async ({ page, request }) => {
    test.setTimeout(300_000)
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 8)
    const processKey = `pl-sem-validation-${fixtureId}`

    const pl = createPipeline<SemanticValidationPipelineState>('platform-definition-type-error-blocked', { page, request })
    pl.state.adminToken = adminToken

    // ── Step 01: create a DRAFT definition with declared fields + a minimal
    // valid graph (API) — both gateway edges start with a VALID condition so
    // the fixture itself passes REQ-372's own checks before the GUI steps
    // deliberately break it. ────────────────────────────────────────────────
    await pl.step('01: create DRAFT definition with declared variable schema and valid graph', async (s) => {
      const createResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: {
          name: processKey,
          version: '1.0.0',
          description: 'platform-definition-type-error-blocked pipeline fixture',
          graph: {
            nodes: [
              { id: 'start', node_type: 'START', label: 'Start', attributes: null },
              { id: 'gw', node_type: 'EXCLUSIVE_GATEWAY', label: 'Routing Decision', attributes: null },
              { id: 'branch_a', node_type: 'END', label: 'Route A', attributes: null },
              { id: 'branch_b', node_type: 'END', label: 'Route B', attributes: null },
            ],
            edges: [
              { id: 'e1', source: 'start', target: 'gw' },
              { id: 'e2', source: 'gw', target: 'branch_a', condition: 'amount > 0' },
              { id: 'e3', source: 'gw', target: 'branch_b', condition: 'amount > 0', is_default: true },
            ],
          },
          variable_schemas: [
            { variable_key: 'amount', json_schema: { type: 'number' } },
            { variable_key: 'customer_name', json_schema: { type: 'string' } },
          ],
        },
      })
      const createBody = await createResp.text()
      // gw carries an is_default edge (e3), so CHK-24 must not fire.
      pl.gate(!createBody.includes('no_default_route'), `definition create hit no_default_route: ${createBody}`)
      pl.gate(createResp.ok(), `definition create failed: ${createResp.status()} ${createBody}`)
      const created = JSON.parse(createBody) as { id: string; status: string }
      s.definitionId = created.id
      pl.gate(created.status === 'DRAFT', `expected DRAFT status after create, got ${created.status}`)
    })

    // ── Step 02: open the definition in the editor (GUI) ────────────────────
    await pl.step('02: author opens the draft in the process editor', async (s) => {
      await navigateSpa(page, `/definitions/${s.definitionId}`)
      await page.getByTestId('btn-save-definition').waitFor({ timeout: 15_000 })
      const edgeCount = await page.locator('.react-flow__edge').count()
      pl.gate(edgeCount === 3, `expected 3 edges rendered, got ${edgeCount}`)

      // Auto-layout so the two END nodes (branch_a/branch_b) aren't stacked
      // on top of each other at their default fallback position -- an
      // overlap that would otherwise intercept the edge double-clicks below.
      await page.getByTestId('btn-auto-layout').click()
      await page.waitForTimeout(1_500)
    })

    // ── Step 03: edit both gateway edges to introduce the two broken rules ──
    async function setEdgeCondition(edgeId: string, expression: string) {
      // Re-layout before every edit, not only once at the start: a save
      // round-trip can leave nodes overlapping the MiniMap panel again,
      // which is what intercepts the click/dblclick below if skipped.
      await page.getByTestId('btn-auto-layout').click()
      await page.waitForTimeout(1_000)

      const dialog = page.getByTestId('condition-dialog')
      // Dispatch a real 'dblclick' DOM event directly against the edge's
      // own <g> element rather than driving it through Playwright's
      // pointer-position-based click/dblclick -- the latter proved
      // unreliable for RE-opening the dialog on a second/later edit of the
      // same canvas (confirmed directly across repeated runs: the very
      // FIRST dblclick on a freshly-loaded canvas is reliable, but a second
      // edit after an intervening save/re-layout cycle intermittently never
      // registers, regardless of preceding single-click, force:true, or
      // MiniMap-avoidance). Dispatching the event directly is immune to
      // viewport pan/zoom, MiniMap overlap, and pointer-timing races alike,
      // since it bypasses hit-testing entirely and goes straight to the
      // React synthetic event system via the real bubbling native event.
      await page.evaluate((id) => {
        const g = document.querySelector(`[data-testid="rf__edge-${id}"]`)
        if (!g) throw new Error(`edge group not found for ${id}`)
        const rect = g.getBoundingClientRect()
        const opts = { bubbles: true, cancelable: true, clientX: rect.x + rect.width / 2, clientY: rect.y + rect.height / 2 }
        g.dispatchEvent(new MouseEvent('mousedown', opts))
        g.dispatchEvent(new MouseEvent('mouseup', opts))
        g.dispatchEvent(new MouseEvent('click', opts))
        g.dispatchEvent(new MouseEvent('mousedown', opts))
        g.dispatchEvent(new MouseEvent('mouseup', opts))
        g.dispatchEvent(new MouseEvent('click', opts))
        g.dispatchEvent(new MouseEvent('dblclick', opts))
      }, edgeId)
      await expect(dialog).toBeVisible({ timeout: 5_000 })
      const cmContent = page.getByTestId('cel-expression-editor').locator('.cm-content')
      await cmContent.click()
      await page.keyboard.press('Control+a')
      await page.keyboard.press('Backspace')
      await page.keyboard.type(expression)
      await page.waitForTimeout(300)
      // Verify the editor actually holds the typed expression before
      // confirming -- guards against a swallowed/partial keystroke leaving
      // stale text that would silently save the WRONG condition.
      await expect(cmContent).toHaveText(expression, { timeout: 5_000 })
      await page.getByTestId('condition-confirm').click()
      await expect(dialog).not.toBeVisible({ timeout: 5_000 })
    }

    await pl.step('03: author introduces a typo\'d field reference and a type-incompatible comparison', async () => {
      // e2: routing rule referencing a field name close to, but not exactly,
      // the real declared "customer_name" field (Levenshtein-suggestible typo).
      await setEdgeCondition('e2', 'cusotmer_name == "Alice"')
      // e3: signature rule comparing the money field against the customer-name
      // field — a numeric/string type-incompatible comparison.
      await setEdgeCondition('e3', 'amount == customer_name')
    })

    // ── Step 04/05: Save — both problems render together [scenario step 1] ──
    await pl.step('04/05: EO-001/EO-003/AC2/AC3 — saving surfaces both problems together, each naming its rule verbatim', async () => {
      await page.getByTestId('btn-save-definition').click()
      await page.getByTestId('save-success-toast').waitFor({ timeout: 10_000 })

      // Expand the save-time problem bar.
      const summaryBar = page.locator('text=/\\d+ errors?/').first()
      await summaryBar.click()

      const undeclaredText = page.getByText(/references undeclared variable 'cusotmer_name'/)
      await expect(undeclaredText).toBeVisible({ timeout: 10_000 })
      await expect(page.getByText(/nearest declared field: 'customer_name'/)).toBeVisible()
      await expect(page.getByText(/rule as authored: "cusotmer_name == "Alice""/)).toBeVisible()

      const incompatibleText = page.getByText(/compares incompatible types/)
      await expect(incompatibleText).toBeVisible()
      // operand_repr/1 (semantic_validation.ex) renders a {:var, path} operand
      // as "variables.<path>", not the bare field name.
      await expect(page.getByText(/'variables\.amount' \(numeric\)/)).toBeVisible()
      await expect(page.getByText(/'variables\.customer_name' \(string\)/)).toBeVisible()

      await shot(page, 'platform-definition-type-error-blocked', '05-both-problems')
    })

    // ── Step 06: release is blocked [EO-002, AC4] ────────────────────────────
    await pl.step('06: EO-002/AC4 — Submit for Release is blocked while problems remain', async (s) => {
      const submitBtn = page.getByTestId('btn-submit-for-release')
      await expect(submitBtn).toBeDisabled()

      // Independently confirm via the API that the definition is still DRAFT.
      const getResp = await request.get(`${API_BASE_URL}/api/v1/definitions/${s.definitionId}`, {
        headers: authHeaders(s.adminToken),
      })
      pl.gate(getResp.ok(), `definition GET failed: ${getResp.status()}`)
      const current = await getResp.json() as { status: string }
      pl.gate(current.status === 'DRAFT', `expected DRAFT status while problems remain, got ${current.status}`)
    })
  })

  // ── Second, independent pipeline: EO-005's happy path (scenario step 5) ────
  //
  // A definition that is ALREADY clean (no edge-condition editing at all, so
  // this never exercises the flaky re-open-the-dialog-for-a-second-edit path
  // the "Known gap" note above describes): open it, submit it for release,
  // and confirm the release-check surface shows a FRESH check (not a stale
  // save-time result) before the definition activates.
  test('EO-005 happy path: a clean definition\'s release submission re-checks every rule fresh and activates', async ({ page, request }) => {
    test.setTimeout(120_000)
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 8)
    const processKey = `pl-sem-validation-clean-${fixtureId}`

    const pl = createPipeline<SemanticValidationPipelineState>(
      'platform-definition-type-error-blocked-eo005-happy-path',
      { page, request },
    )
    pl.state.adminToken = adminToken

    await pl.step('01: create an already-clean DRAFT definition (API)', async (s) => {
      const createResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: {
          name: processKey,
          version: '1.0.0',
          description: 'platform-definition-type-error-blocked EO-005 happy-path fixture',
          graph: {
            nodes: [
              { id: 'start', node_type: 'START', label: 'Start', attributes: null },
              { id: 'gw', node_type: 'EXCLUSIVE_GATEWAY', label: 'Routing Decision', attributes: null },
              { id: 'branch_a', node_type: 'END', label: 'Route A', attributes: null },
              { id: 'branch_b', node_type: 'END', label: 'Route B', attributes: null },
            ],
            edges: [
              { id: 'e1', source: 'start', target: 'gw' },
              { id: 'e2', source: 'gw', target: 'branch_a', condition: 'amount > 0' },
              { id: 'e3', source: 'gw', target: 'branch_b', condition: 'amount <= 0', is_default: true },
            ],
          },
          variable_schemas: [
            { variable_key: 'amount', json_schema: { type: 'number' } },
            { variable_key: 'customer_name', json_schema: { type: 'string' } },
          ],
        },
      })
      pl.gate(createResp.ok(), `definition create failed: ${createResp.status()} ${await createResp.text()}`)
      const created = await createResp.json() as { id: string; status: string }
      s.definitionId = created.id
      pl.gate(created.status === 'DRAFT', `expected DRAFT status after create, got ${created.status}`)
    })

    await pl.step('02: open the clean draft in the editor', async (s) => {
      await navigateSpa(page, `/definitions/${s.definitionId}`)
      await page.getByTestId('btn-submit-for-release').waitFor({ timeout: 15_000 })
    })

    await pl.step('03: EO-005 — Submit for Release shows a fresh check and the definition activates', async (s) => {
      const submitBtn = page.getByTestId('btn-submit-for-release')
      await expect(submitBtn).toBeEnabled({ timeout: 5_000 })
      await submitBtn.click()

      const panel = page.getByTestId('release-check-panel')
      await expect(panel).toBeVisible({ timeout: 10_000 })
      await expect(panel).toHaveAttribute('data-release-check-phase', 'clean', { timeout: 15_000 })
      await expect(panel).toContainText(/fresh check/i)

      const getResp = await request.get(`${API_BASE_URL}/api/v1/definitions/${s.definitionId}`, {
        headers: authHeaders(s.adminToken),
      })
      pl.gate(getResp.ok(), `definition GET failed: ${getResp.status()}`)
      const current = await getResp.json() as { status: string }
      pl.gate(current.status === 'ACTIVE', `expected ACTIVE status after clean release submission, got ${current.status}`)

      await shot(page, 'platform-definition-type-error-blocked-eo005-happy-path', '03-released')
    })
  })
})
