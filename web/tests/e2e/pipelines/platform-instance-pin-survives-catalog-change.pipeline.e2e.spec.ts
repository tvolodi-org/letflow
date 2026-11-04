/**
 * Pipeline: Platform Instance Pin Survives Catalog Change (PW-03 /
 * sys-instance-version-pinning)
 *
 * Drives `test/fixtures/uat/scenarios/platform/instance-pin-survives-catalog-change.yaml`
 * end to end for real — REQ-432. Filed from ISS-0898/GH-2044: the scenario's
 * own read-only provenance screen was built by REQ-399, but two operator
 * ACTIONS its steps exercise (publish/retire a service_catalog version,
 * rebind a running case's pin) had no UI anywhere until this requirement.
 *
 * ── Setup done via API, not GUI (matches
 * platform-definition-promotion-approved.pipeline.e2e.spec.ts's own
 * precedent of doing non-target-action setup via API) ──
 *   - Register a fresh service_catalog entry (the "shared connection").
 *     Registration itself isn't one of REQ-432's target actions (publish/
 *     retire/rebind are); the real, already-shipped `register/1` route is
 *     used to create the fixture's starting state (version "1", ACTIVE).
 *   - Create + activate a process definition whose graph is
 *     START -> HUMAN_TASK -> SERVICE_TASK(service_id: <the entry above>) -> END.
 *     `Letflow.Engine.PinResolver.resolve/4` freezes a `catalog_entry` pin
 *     for every SERVICE_TASK's `service_id` attribute across the WHOLE
 *     graph at instance-start time, structurally — not only for nodes the
 *     token has reached (`pin_resolver.ex`'s own "freezes every versioned
 *     dependency... at case-start time"). The long-running
 *     case's human task is never completed in this spec: it stays parked there
 *     for the scenario's entire "left part-way through" duration, and its pin
 *     is already frozen the moment it started regardless. (A second in-flight
 *     case's task IS completed in step 04b - see the ISS-0917 note below.)
 *
 * ── Step-2 ordering: RETIRE then PUBLISH, not publish-then-retire ──
 * The scenario's own prose is "publishes the newer version... and retires
 * the version the running case is using." Read literally in publish-then-
 * retire order against the REAL shipped model
 * (`lib/letflow/service_catalog.ex` — a SINGLE live/current row per
 * `service_id`, not a composite-key versioned table), that would retire
 * the version case B is supposed to pick up next (EO-002), not the version
 * case A is using. `service_catalog.ex`'s own `retire/1` moduledoc confirms
 * retiring first and publishing second is exactly as supported as the
 * reverse ("a publish following a bare retire archives the retired row
 * exactly as a publish following an active one archives that one") — so
 * this spec retires the entry's only-existing version 1 (literally "the
 * version the running case is using," since it is still the only version
 * at that point), THEN publishes version 2. This achieves every expected
 * outcome the naive reading would break: case A's frozen pin still reads
 * "1" throughout (EO-001/EO-004 — pins are never re-read from a live
 * catalog, see `pin_resolver.ex`'s "No fallback, ever"), and case B, started
 * after, resolves against the CURRENT row (now version 2, ACTIVE) (EO-002).
 * Both actions are still performed from the GUI exactly once each (AC2/AC3).
 *
 * ── SERVICE_TASK dispatch IS exercised (ISS-0917, step 04b) ──
 * This header used to record that SERVICE_TASK dispatch was deliberately NOT
 * exercised, because a catalog-referencing SERVICE_TASK could not execute
 * (`catalog_lookup_stub/2` was an unconditional `{:error, :not_registered}`,
 * so completing the preceding HUMAN_TASK ended in EXECUTION_ERROR and HTTP
 * 500). ISS-0917 fixed that: the engine now resolves the node's `service_id`
 * through the instance's PINNED catalog version at activation and freezes
 * the rendered endpoint into the dispatch row. Design:
 * `lib/letflow/design/iss0917-catalog-service-task-pinned-dispatch.md`
 * section 6.4. Step 04b therefore completes a SECOND in-flight case's
 * HUMAN_TASK AFTER v1 was retired and v2 published, and asserts:
 *   - UNCONDITIONAL (no network, no poller): HTTP 200, `instance_status`
 *     ACTIVE, history holds TASK_COMPLETED and no EXECUTION_ERROR.
 *   - ENFORCED BY DEFAULT: the case reaches COMPLETED. The registered v1
 *     endpoint answers 2xx JSON; the published v2 endpoint is a TRAP that
 *     answers non-2xx. Reaching COMPLETED therefore proves the dispatch used
 *     the PINNED v1 endpoint (the e2e cannot read `rendered_url` directly; no
 *     HTTP route exposes `service_task_dispatches`).
 * Endpoints (both must be public https; UrlValidator blocks loopback and
 * `example.test` does not resolve):
 *   v1   = <SERVICE_TASK_MOCK_BASE_URL, default https://httpbin.org/anything>/shared-connection/v1
 *   trap = new URL(base).origin + SERVICE_TASK_MOCK_TRAP_PATH (default /status/503)
 * The trap is built from the ORIGIN, not base + path: httpbin `/anything/...`
 * answers 200 for any suffix, which would make the trap succeed and hide a
 * wrong-version dispatch. A non-httpbin mock needs a SERVICE_TASK_MOCK_TRAP_PATH
 * on the same origin that answers non-2xx (and v1's path must answer 2xx JSON
 * object). If none exists, set E2E_SKIP_SERVICE_TASK_POLL=1: that skips ONLY
 * the COMPLETED-poll assertion, with a loud console.warn and a
 * `skipped-assertion` test annotation; the unconditional assertions still run.
 * The dispatcher poller defaults ON outside test config
 * (`start_service_task_dispatcher`; only config/test.exs sets false), and the
 * target needs outbound HTTPS to the mock host. The endpoint-identity proof at
 * data level stays in ExUnit (T1/T2). The pre-existing long-running case is
 * NOT completed here: step 06 rebinds it and needs it non-terminal.
 *
 * Chain topology:
 *   pre-check services → login as platform-admin
 *   → 01: register the shared-connection service (API) + create/activate
 *         the process definition (API)
 *   → 02: start the long-running case + a second in-flight case (GUI) [step 1]
 *   → 03: retire v1, then publish v2 of the shared connection (GUI) [step 2]
 *   → 04: long-running case's pins panel still shows v1/resolved  [EO-001/EO-004]
 *   → 04b: complete the second in-flight case's task; pinned v1 dispatch
 *          succeeds, no EXECUTION_ERROR (API) [scenario step 3, EO-001/EO-004, ISS-0917]
 *   → 05: start the new case (GUI); both cases show distinct pinned
 *         versions                                            [step 4, EO-002/EO-003]
 *   → 06: rebind the long-running case's pin onto v2, with a reason (GUI) [step 5]
 *   → 07: History tab shows the rebind with the operator's resolved name,
 *         prior/new version, and the reason verbatim               [EO-005]
 *   → cleanup: cancel every started instance
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  authHeaders,
  extractIdFromUrl,
  resolveLocalUserId,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential } from '../helpers'
import { typeIntoTestIdInput } from '../type-into-input'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'

// ISS-0917: controllable, public-https SERVICE_TASK endpoints (see header).
const SERVICE_TASK_MOCK_BASE_URL = (process.env.SERVICE_TASK_MOCK_BASE_URL ?? 'https://httpbin.org/anything').replace(/\/+$/, '')
const SERVICE_TASK_MOCK_TRAP_PATH = process.env.SERVICE_TASK_MOCK_TRAP_PATH ?? '/status/503'
const V1_ENDPOINT_URL = `${SERVICE_TASK_MOCK_BASE_URL}/shared-connection/v1`
// Built from the ORIGIN on purpose: `<base>/status/503` under httpbin /anything is a 200.
const V2_TRAP_ENDPOINT_URL = new URL(SERVICE_TASK_MOCK_BASE_URL).origin + SERVICE_TASK_MOCK_TRAP_PATH
const SKIP_SERVICE_TASK_POLL = process.env.E2E_SKIP_SERVICE_TASK_POLL === '1'

interface PinSurvivesPipelineState {
  adminToken: string
  adminSub: string
  serviceId: string
  definitionId: string
  definitionName: string
  definitionVersion: string
  longRunningCaseId: string
  pinDispatchCaseId: string
  newCaseId: string
  rebindReason: string
}

/**
 * Starts an instance from `/instances` via the real GUI dialog.
 *
 * `InstanceBoardPage.tsx` reads its `definitionName`/`definitionId` page
 * filter state directly from the URL's `definitionName`/`definitionId`
 * query params (`searchParams.get(...)`, lines 50-51) — the SAME params
 * the board's own name-filter input (`onDefinitionInputChange`) and
 * datalist-resolution (`onResolveDefinition`) write on blur. Navigating
 * straight to `/instances?definitionName=...&definitionId=...` reaches the
 * identical resolved state a real operator would land in after typing the
 * name and having it resolve from the datalist — deterministically, without
 * depending on this shared dev database's unfiltered first-page typeahead
 * (which, on a database carrying many pre-existing ACTIVE definitions,
 * would not reliably include a definition this test just created) or on
 * blur-event timing. `openStartDialog` then pre-fills the dialog's version
 * field from `useDefinition(definitionId)`, the same real GET the board
 * itself already issues for this filter state.
 */
async function startInstanceViaGui(page: import('@playwright/test').Page, definitionId: string, definitionName: string, definitionVersion: string): Promise<string> {
  await navigateSpa(page, `/instances?definitionName=${encodeURIComponent(definitionName)}&definitionId=${encodeURIComponent(definitionId)}`)

  // `openStartDialog` reads `activeDefinitionByName` (from `useDefinition`)
  // at click time — wait for that real GET to resolve (surfaced by the
  // board's own "using active version ..." text) before opening the
  // dialog, or the dialog pre-fills from a still-undefined query result.
  await expect(page.getByText(`using active version ${definitionVersion}`)).toBeVisible({ timeout: 15_000 })

  await page.getByTestId('start-instance-button').dispatchEvent('click')
  await expect(page.getByTestId('start-instance-dialog')).toBeVisible({ timeout: 10_000 })
  await expect(page.getByTestId('start-definition-version')).toHaveValue(definitionVersion, { timeout: 10_000 })

  await page.getByTestId('submit-start-instance').dispatchEvent('click')
  await expect(page.getByTestId('start-instance-dialog')).not.toBeVisible({ timeout: 10_000 })
  await page.waitForURL(/\/instances\/.+/, { timeout: 15_000 })

  return extractIdFromUrl(page.url(), 'instances')
}

test.describe('Pipeline: platform-instance-pin-survives-catalog-change (PW-03)', () => {
  test('a case in progress keeps its pinned version through publish/retire, a later case gets the new one, and a deliberate rebind is recorded with who/what/why', async ({ page, request }) => {
    // Step 04b polls for the SERVICE_TASK to advance (dispatcher poll interval ~5s).
    test.setTimeout(300_000)
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 8)
    const serviceId = `svc-pin-rebind-${fixtureId}`
    const definitionName = `pl-pin-rebind-${fixtureId}`
    const rebindReason = 'External system retires the old endpoint at month end.'

    const pl = createPipeline<PinSurvivesPipelineState>('platform-instance-pin-survives-catalog-change', { page, request })
    pl.state.adminToken = adminToken
    pl.state.adminSub = await resolveLocalUserId(request, API_BASE_URL, adminToken, 'admin-user')
    pl.state.serviceId = serviceId
    pl.state.definitionName = definitionName
    pl.state.rebindReason = rebindReason

    // Cleanup: cancel both instances (scenario's own cleanup block).
    pl.onCleanup(async (s) => {
      for (const id of [s.longRunningCaseId, s.pinDispatchCaseId, s.newCaseId]) {
        if (!id) continue
        await request.post(`${API_BASE_URL}/api/v1/instances/${id}/cancel`, {
          headers: authHeaders(s.adminToken),
          data: { reason: 'platform-instance-pin-survives-catalog-change e2e cleanup' },
        }).catch(() => undefined)
      }
    })

    // ── Step 01: register the shared connection + activate the process (API) ──
    await pl.step('01: register shared-connection service and activate a process definition using it', async (s) => {
      const registerResp = await request.post(`${API_BASE_URL}/api/v1/admin/services`, {
        headers: authHeaders(s.adminToken),
        data: {
          service_id: s.serviceId,
          endpoint_url: V1_ENDPOINT_URL,
          scope: 'global',
          auth_method: 'NONE',
          timeout_ms: 5000,
          request_schema: '{}',
          response_schema: '{}',
        },
      })
      pl.gate(registerResp.ok(), `service register failed: ${registerResp.status()} ${await registerResp.text()}`)
      const registered = await registerResp.json() as { version?: string; status?: string }
      pl.gate(registered.version === '1', `freshly registered service must start at version "1", got ${registered.version}`)
      pl.gate(registered.status === 'ACTIVE', `freshly registered service must start ACTIVE, got ${registered.status}`)

      const createResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: {
          name: s.definitionName,
          version: '1.0.0',
          description: 'platform-instance-pin-survives-catalog-change pipeline fixture',
          graph: {
            nodes: [
              { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
              {
                id: 'n2',
                node_type: 'HUMAN_TASK',
                label: 'Hold before shared connection',
                // ISS-0917 6.4 item 6: `role` is what the engine reads for the assignee ref;
                // UPPERCASE 'USER' matches Tasks.apply_completion_authz/3's USER clause, which
                // compares against the caller's actor id (= the LOCAL users.id, ISS-0936 -- NOT the token `sub`).
                attributes: { role: s.adminSub, assignee_type: 'USER', assignee_ref: s.adminSub },
              },
              {
                id: 'n3',
                node_type: 'SERVICE_TASK',
                label: 'Use shared connection',
                attributes: { service_id: s.serviceId, timeout_ms: 30000 },
              },
              { id: 'n4', node_type: 'END', label: 'End', attributes: null },
            ],
            edges: [
              { id: 'e1', source: 'n1', target: 'n2' },
              { id: 'e2', source: 'n2', target: 'n3' },
              { id: 'e3', source: 'n3', target: 'n4' },
            ],
          },
        },
      })
      pl.gate(createResp.ok(), `definition create failed: ${createResp.status()} ${await createResp.text()}`)
      const created = await createResp.json() as { id: string; version: string }
      s.definitionId = created.id
      s.definitionVersion = created.version

      const activateResp = await request.post(
        `${API_BASE_URL}/api/v1/definitions/${s.definitionId}/activate`,
        { headers: authHeaders(s.adminToken) },
      )
      pl.gate(activateResp.ok(), `definition activate failed: ${activateResp.status()} ${await activateResp.text()}`)
    })

    // ── Step 02: start the long-running case (GUI) — scenario step 1 ──────────
    await pl.step('02: start the long-running case, left before the shared-connection step', async (s) => {
      await navigateSpa(page, '/instances')
      s.longRunningCaseId = await startInstanceViaGui(page, s.definitionId, s.definitionName, s.definitionVersion)
      pl.gate(!!s.longRunningCaseId, 'long-running case ID must be present in URL after start')
      await shot(page, 'platform-instance-pin-survives-catalog-change', '02-long-running-case-started')

      // ISS-0917: a SECOND in-flight case, started from the same definition so it
      // pins v1 exactly like the long-running case. Completed in step 04b.
      await navigateSpa(page, '/instances')
      s.pinDispatchCaseId = await startInstanceViaGui(page, s.definitionId, s.definitionName, s.definitionVersion)
      pl.gate(!!s.pinDispatchCaseId, 'pin-dispatch case ID must be present in URL after start')
      pl.gate(s.pinDispatchCaseId !== s.longRunningCaseId, 'pin-dispatch case must be a distinct instance from the long-running one')
    })

    // ── Step 03: retire v1, then publish v2 (GUI) — scenario step 2 ───────────
    await pl.step('03: retire the shared connection, then publish its newer version', async (s) => {
      await navigateSpa(page, '/admin/services')
      await expect(page.getByRole('heading', { name: 'Services' })).toBeVisible({ timeout: 15_000 })

      const searchInput = page.getByPlaceholder('service ID or endpoint')
      await searchInput.click()
      await page.evaluate((value) => {
        const el = document.querySelector('input[placeholder="service ID or endpoint"]') as HTMLInputElement | null
        if (!el) throw new Error('search input not found')
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')!.set!
        setter.call(el, value)
        el.dispatchEvent(new Event('input', { bubbles: true }))
      }, s.serviceId)

      const row = page.getByTestId('datatable-row').filter({ hasText: s.serviceId })
      await row.waitFor({ timeout: 10_000 })

      // Retire — the entry's only version so far ("1"), literally "the
      // version the running case is using" (see this file's header note).
      await row.getByRole('button', { name: 'Retire' }).dispatchEvent('click')
      await expect(page.getByTestId('retire-confirm-dialog')).toBeVisible({ timeout: 8_000 })
      await page.getByTestId('retire-confirm-submit').dispatchEvent('click')
      await expect(page.getByTestId('retire-confirm-dialog')).not.toBeVisible({ timeout: 10_000 })

      // Confirm the retire really landed against the real backend: the row's
      // own Retire button must now be disabled (status refetched as RETIRED).
      await expect(row.getByRole('button', { name: 'Retire' })).toBeDisabled({ timeout: 10_000 })

      // Publish version "2" of the same connection.
      await row.getByRole('button', { name: 'Publish new version' }).dispatchEvent('click')
      await expect(page.getByTestId('publish-version-dialog')).toBeVisible({ timeout: 8_000 })
      await typeIntoTestIdInput(page, 'publish-version-input', '2')
      await typeIntoTestIdInput(page, 'publish-endpoint-url-input', V2_TRAP_ENDPOINT_URL)
      await typeIntoTestIdInput(page, 'publish-timeout-ms-input', '5000')
      await page.getByTestId('publish-version-submit').dispatchEvent('click')
      await expect(page.getByTestId('publish-version-dialog')).not.toBeVisible({ timeout: 10_000 })

      // Confirm via the real backend too: the current row is now ACTIVE
      // again (status flipped back by publish) at version "2".
      const listResp = await request.get(`${API_BASE_URL}/api/v1/admin/services`, {
        headers: authHeaders(s.adminToken),
      })
      pl.gate(listResp.ok(), `admin services list failed: ${listResp.status()}`)
      const listBody = await listResp.json() as { items: Array<{ service_id: string; version?: string; status?: string }> }
      const entry = listBody.items.find((i) => i.service_id === s.serviceId)
      pl.gate(!!entry, 'the service must still be listed after retire+publish')
      pl.gate(entry?.version === '2', `service must be at version "2" after publish, got ${entry?.version}`)
      pl.gate(entry?.status === 'ACTIVE', `service must be ACTIVE after publish, got ${entry?.status}`)

      await shot(page, 'platform-instance-pin-survives-catalog-change', '03-retired-then-published')
    })

    // ── Step 04: EO-001/EO-004 — the long-running case's pin is unaffected ────
    await pl.step('04: EO-001/EO-004 — long-running case still shows the version it started with', async (s) => {
      await navigateSpa(page, `/instances/${s.longRunningCaseId}`)
      const panel = page.getByTestId('instance-pins-panel')
      await panel.waitFor({ timeout: 15_000 })

      const pinRow = panel.getByTestId('datatable-row').filter({ hasText: s.serviceId })
      await pinRow.waitFor({ timeout: 10_000 })
      // Precise per-column cell checks — not a substring match on the whole
      // row, since `s.serviceId` (containing random hex digits) could itself
      // contain a stray "1".
      await expect(pinRow.getByTestId('datatable-cell-version')).toHaveText('1')
      await expect(pinRow.getByTestId('datatable-cell-source')).toHaveText('Chosen automatically')

      // The case itself must still be non-terminal (retiring never errors or
      // blocks the already-running case — EO-004/AC7).
      const instResp = await request.get(`${API_BASE_URL}/api/v1/instances/${s.longRunningCaseId}`, {
        headers: authHeaders(s.adminToken),
      })
      pl.gate(instResp.ok(), `instance fetch failed: ${instResp.status()}`)
      const inst = await instResp.json() as { status: string }
      pl.gate(inst.status === 'ACTIVE', `long-running case must remain ACTIVE, got ${inst.status}`)

      await shot(page, 'platform-instance-pin-survives-catalog-change', '04-long-running-case-pin-unaffected')
    })

    // ── Step 04b: ISS-0917 — complete the in-flight task AFTER retire+publish ──
    await pl.step('04b: scenario step 3 / EO-001/EO-004 — the in-flight step completes without error and dispatches the PINNED version', async (s) => {
      const tasksResp = await request.get(
        `${API_BASE_URL}/api/v1/tasks?instance_id=${s.pinDispatchCaseId}`,
        { headers: authHeaders(s.adminToken) },
      )
      pl.gate(tasksResp.ok(), `task lookup failed: ${tasksResp.status()} ${await tasksResp.text()}`)
      const tasksBody = (await tasksResp.json()) as { items?: Array<{ id: string }> }
      const taskId = tasksBody.items?.[0]?.id ?? ''
      pl.gate(!!taskId, 'a pending HUMAN_TASK must exist for the pin-dispatch case')

      // Same admin token the HUMAN_TASK was assigned to (assignee_ref = its local users.id).
      const completeResp = await request.post(`${API_BASE_URL}/api/v1/tasks/${taskId}/complete`, {
        headers: { ...authHeaders(s.adminToken), 'Content-Type': 'application/json' },
        data: { output_variables: {} },
      })
      // (a) the ISS-0917 acceptance: no 500 when the next node is a catalog SERVICE_TASK.
      pl.gate(
        completeResp.status() === 200,
        `task complete must return HTTP 200 (ISS-0917), got ${completeResp.status()} ${await completeResp.text()}`,
      )
      const completed = await completeResp.json() as { instance_status?: string }
      pl.gate(
        String(completed.instance_status).toUpperCase() === 'ACTIVE',
        `instance_status right after completion must be active (SERVICE_TASK dispatch is asynchronous), got ${completed.instance_status}`,
      )

      const fetchEventTypes = async (): Promise<string[]> => {
        const histResp = await request.get(
          `${API_BASE_URL}/api/v1/instances/${s.pinDispatchCaseId}/history?page_size=200`,
          { headers: authHeaders(s.adminToken) },
        )
        pl.gate(histResp.ok(), `instance history fetch failed: ${histResp.status()}`)
        const hist = await histResp.json() as { items?: Array<{ event_type: string }> }
        return (hist.items ?? []).map((e) => e.event_type)
      }

      // (c-immediate) TASK_COMPLETED present, no EXECUTION_ERROR - no network, no poller needed.
      const eventsNow = await fetchEventTypes()
      pl.gate(!eventsNow.includes('EXECUTION_ERROR'), `history must hold no EXECUTION_ERROR after completion, got ${eventsNow.join(',')}`)
      pl.gate(eventsNow.includes('TASK_COMPLETED'), `history must hold TASK_COMPLETED after completion, got ${eventsNow.join(',')}`)

      // (b) ENFORCED by default: the case reaches COMPLETED. v1 answers 2xx JSON, the
      // v2 trap answers non-2xx, so COMPLETED proves the PINNED v1 endpoint was used.
      if (SKIP_SERVICE_TASK_POLL) {
        const msg =
          'E2E_SKIP_SERVICE_TASK_POLL=1: SKIPPING the COMPLETED-poll assertion of step 04b. ' +
          'Lost coverage: proof that the SERVICE_TASK dispatched the PINNED v1 endpoint (not the v2 trap) and advanced to END. ' +
          'Unconditional assertions (HTTP 200, ACTIVE, TASK_COMPLETED, no EXECUTION_ERROR) still ran.'
        console.warn(`\n!!! ${msg}\n`)
        test.info().annotations.push({ type: 'skipped-assertion', description: msg })
      } else {
        const deadline = Date.now() + 120_000
        let status = ''
        while (Date.now() < deadline) {
          const instResp = await request.get(`${API_BASE_URL}/api/v1/instances/${s.pinDispatchCaseId}`, {
            headers: authHeaders(s.adminToken),
          })
          pl.gate(instResp.ok(), `instance fetch failed: ${instResp.status()}`)
          status = ((await instResp.json()) as { status: string }).status
          if (status === 'COMPLETED' || status === 'ERROR') break
          await new Promise((r) => setTimeout(r, 2_000))
        }
        const eventsAfter = await fetchEventTypes()
        pl.gate(
          status === 'COMPLETED',
          `pin-dispatch case must reach COMPLETED via the pinned v1 endpoint (${V1_ENDPOINT_URL}); the v2 trap (${V2_TRAP_ENDPOINT_URL}) must not be used. ` +
            `Last status "${status}" (ERROR or timeout). Events: ${eventsAfter.join(',')}. ` +
            'If the mock host is unreachable or not httpbin-compatible, see the header (SERVICE_TASK_MOCK_BASE_URL / SERVICE_TASK_MOCK_TRAP_PATH / E2E_SKIP_SERVICE_TASK_POLL).',
        )
        pl.gate(!eventsAfter.includes('EXECUTION_ERROR'), `history must hold no EXECUTION_ERROR, got ${eventsAfter.join(',')}`)
      }
    })

    // ── Step 05: start the new case; both cases show distinct versions ────────
    await pl.step('05: EO-002/EO-003 — new case picks up the newer version', async (s) => {
      await navigateSpa(page, '/instances')
      s.newCaseId = await startInstanceViaGui(page, s.definitionId, s.definitionName, s.definitionVersion)
      pl.gate(!!s.newCaseId, 'new case ID must be present in URL after start')
      pl.gate(s.newCaseId !== s.longRunningCaseId, 'new case must be a distinct instance from the long-running one')

      const newPanel = page.getByTestId('instance-pins-panel')
      await newPanel.waitFor({ timeout: 15_000 })
      const newPinRow = newPanel.getByTestId('datatable-row').filter({ hasText: s.serviceId })
      await newPinRow.waitFor({ timeout: 10_000 })
      await expect(newPinRow.getByTestId('datatable-cell-version')).toHaveText('2')
      await expect(newPinRow.getByTestId('datatable-cell-source')).toHaveText('Chosen automatically')

      await shot(page, 'platform-instance-pin-survives-catalog-change', '05-new-case-newer-version')
    })

    // ── Step 06: rebind the long-running case's pin — scenario step 5 ─────────
    await pl.step('06: deliberately rebind the long-running case onto the newer version', async (s) => {
      await navigateSpa(page, `/instances/${s.longRunningCaseId}`)
      const panel = page.getByTestId('instance-pins-panel')
      await panel.waitFor({ timeout: 15_000 })

      const pinRow = panel.getByTestId('datatable-row').filter({ hasText: s.serviceId })
      await pinRow.waitFor({ timeout: 10_000 })
      await pinRow.getByRole('button', { name: 'Rebind' }).dispatchEvent('click')

      const dialog = page.getByTestId('rebind-pin-dialog')
      await dialog.waitFor({ timeout: 8_000 })
      await typeIntoTestIdInput(page, 'rebind-target-version', '2')
      await typeIntoTestIdInput(page, 'rebind-reason', s.rebindReason)
      await page.getByTestId('rebind-confirm').dispatchEvent('click')
      await expect(dialog).not.toBeVisible({ timeout: 10_000 })

      await expect(pinRow.getByTestId('datatable-cell-version')).toHaveText('2', { timeout: 10_000 })
      await expect(pinRow.getByTestId('datatable-cell-source')).toHaveText('Changed via rebind')

      await shot(page, 'platform-instance-pin-survives-catalog-change', '06-rebind-confirmed')
    })

    // ── Step 07: EO-005 — History shows actor name, prior/new version, reason ─
    await pl.step('07: EO-005 — History tab shows who rebound it, the versions, and the reason', async (s) => {
      await navigateSpa(page, `/instances/${s.longRunningCaseId}`)
      await expect(page.getByRole('heading', { name: 'Event history' })).toBeVisible({ timeout: 15_000 })

      const rebindRow = page.getByRole('row', { name: /INSTANCE_PINS_REBOUND/ })
      await rebindRow.waitFor({ timeout: 15_000 })

      const details = rebindRow.getByTestId('rebind-event-details')
      await details.waitFor({ timeout: 10_000 })
      await expect(details).toContainText(`1 -> 2`)
      await expect(details).toContainText(s.rebindReason)

      // Actor cell must show a resolved display name, not a raw UUID
      // prefix — EO-005's own wording, "the operator's name."
      const actorCell = rebindRow.getByRole('cell').nth(2)
      const actorText = (await actorCell.innerText()).trim()
      pl.gate(
        !/^[0-9a-f]{8}$/i.test(actorText) && actorText !== 'system' && actorText.length > 0,
        `Actor cell must show a resolved display name, not a raw id/system fallback — got "${actorText}"`,
      )

      await shot(page, 'platform-instance-pin-survives-catalog-change', '07-history-rebind-details')
    })

    await pl.runCleanup()
  })
})
