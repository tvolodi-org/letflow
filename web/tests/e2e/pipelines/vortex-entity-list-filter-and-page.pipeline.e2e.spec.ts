/**
 * Pipeline: vortex-entity-list-filter-and-page (GH #3120)
 *
 * Drives `test/fixtures/uat/scenarios/vortex/entity-list-filter-and-page.yaml`'s
 * `pipeline_test:` key. The BilimBaga spec `entity-list-query.pipeline.e2e.spec.ts`
 * (REQ-393) stays as it is: it uses the `tag` type as `admin-user` and cannot
 * check the vortex outcomes.
 *
 * Actors (vortex realm, QA): `actor-vortex-karl` (quality manager, no cost
 * clearance) and `actor-vortex-anna` (cost approver). Passwords come from
 * `UAT_QA_VORTEX_KARL_PASSWORD` / `UAT_QA_VORTEX_ANNA_PASSWORD`; there is no
 * local-dev fallback because these accounts exist on QA only.
 *
 * Data: the seeded `production_batch` and `shipment_manifest` types
 * (`scripts/seed_vortex_entities.sh`). The expected Nordmetall quarantined set is
 * read from `test/fixtures/qa/vortex_production_batch_records.json`, the same file
 * the seed loads, so the spec compares against what was seeded.
 *
 * Outcomes:
 *   EO-001 the quarantined Nordmetall set, oldest first, across pages (API
 *          paging with a small page_size so the set spans several pages; the
 *          screen is opened as Karl and must list the type)
 *   EO-002 cost_figure never delivered to Karl, delivered to Anna
 *   EO-004 the restricted `shipment_manifest` type looks like an empty list
 *   EO-005 as docs/uat/ba-decisions/3120.md decides: kept and checked over the
 *          API, `page_size=201` -> 400 whose message states the limit 200
 *          (the screen only offers sizes at or below the limit, so the GUI
 *          cannot request an oversize page). Until the backend message names
 *          the limit this test fails by design; do not loosen it.
 * EO-003 is not part of GH #3120 and is covered by the BilimBaga spec's variant.
 */

import { readFileSync } from 'node:fs'
import path from 'node:path'
import { test, expect, type APIRequestContext } from '@playwright/test'
import { getKeycloakToken, loginWithToken, navigateSpa, authHeaders } from '../pipeline'
import { assertServiceReadiness } from '../helpers'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const REALM = 'vortex'
const BATCH = 'production_batch'
const MANIFEST = 'shipment_manifest'
const PAGE_SIZE = 5

interface SeedRecord {
  record_id: string
  field_values: {
    batch_ref: string
    supplier: string
    status: string
    deviation_raised_at?: string
    cost_figure?: number
  }
}

interface Row {
  record_id?: string
  field_values: Record<string, unknown>
}
interface QueryPage {
  items: Row[]
  next_cursor: string | null
}

function requiredCredential(envVarName: string): string {
  const value = (process.env[envVarName] ?? '').trim()
  if (value.length === 0) {
    throw new Error(`${envVarName} is not set: the vortex UAT actors exist on QA only`)
  }
  return value
}

// Playwright runs with cwd = web/, the fixture sits one level up.
const seeded = (
  JSON.parse(
    readFileSync(
      path.resolve('..', 'test', 'fixtures', 'qa', 'vortex_production_batch_records.json'),
      'utf-8',
    ),
  ) as { records: SeedRecord[] }
).records

const expectedQuarantined = seeded
  .filter((r) => r.field_values.supplier === 'Nordmetall' && r.field_values.status === 'quarantined')
  .sort(
    (a, b) =>
      (a.field_values.deviation_raised_at ?? '').localeCompare(b.field_values.deviation_raised_at ?? '') ||
      a.field_values.batch_ref.localeCompare(b.field_values.batch_ref),
  )

const NORDMETALL_QUARANTINED_FILTERS = [
  { field: 'status', op: 'eq', value: 'quarantined' },
  { field: 'supplier', op: 'eq', value: 'Nordmetall' },
]

async function actorToken(request: APIRequestContext, user: string, envVar: string): Promise<string> {
  return getKeycloakToken(request, user, requiredCredential(envVar), REALM)
}

async function query(
  request: APIRequestContext,
  token: string,
  body: Record<string, unknown>,
) {
  return request.post(`${API_BASE_URL}/api/v1/entities/query`, {
    headers: { ...authHeaders(token), 'Content-Type': 'application/json' },
    data: body,
  })
}

/** Reads every page of the narrowed, sorted list; returns the pages in order. */
async function readAllPages(request: APIRequestContext, token: string): Promise<Row[][]> {
  const pages: Row[][] = []
  let cursor: string | null = null
  for (let guard = 0; guard < 200; guard++) {
    const resp = await query(request, token, {
      entity_type: BATCH,
      filters: NORDMETALL_QUARANTINED_FILTERS,
      sort: [{ field: 'deviation_raised_at', dir: 'asc' }],
      page_size: PAGE_SIZE,
      ...(cursor ? { cursor } : {}),
    })
    expect(resp.ok(), `page ${guard + 1} failed (${resp.status()}): ${await resp.text()}`).toBeTruthy()
    const body = (await resp.json()) as QueryPage
    pages.push(body.items)
    if (!body.next_cursor) return pages
    cursor = body.next_cursor
  }
  throw new Error('paging did not terminate within 200 pages')
}

const refOf = (row: Row) => String(row.field_values.batch_ref)

test.describe('Pipeline: vortex-entity-list-filter-and-page (GH #3120)', () => {
  test.beforeAll(async ({ request }) => {
    await assertServiceReadiness(request, API_BASE_URL)
    // Paging only means something if the set does not fit on one page.
    expect(expectedQuarantined.length).toBeGreaterThan(PAGE_SIZE)
  })

  test('EO-001: Karl sees exactly the quarantined Nordmetall batches, oldest first, once each across pages', async ({ page, request }) => {
    const token = await actorToken(request, 'actor-vortex-karl', 'UAT_QA_VORTEX_KARL_PASSWORD')

    // Karl opens the production batch list on the screen.
    await loginWithToken(page, token)
    await navigateSpa(page, `/entities/${BATCH}`)
    await expect(page.locator('[data-testid="filter-section"]')).toBeVisible({ timeout: 15_000 })

    const pages = await readAllPages(request, token)
    expect(pages.length).toBeGreaterThan(1)
    const seen = pages.flat().map(refOf)

    expect(new Set(seen).size, 'a batch appeared on more than one page').toBe(seen.length)
    expect(seen).toEqual(expectedQuarantined.map((r) => r.field_values.batch_ref))
  })

  test('EO-002: cost_figure is never delivered to Karl and is delivered to Anna', async ({ request }) => {
    const karl = await actorToken(request, 'actor-vortex-karl', 'UAT_QA_VORTEX_KARL_PASSWORD')
    const anna = await actorToken(request, 'actor-vortex-anna', 'UAT_QA_VORTEX_ANNA_PASSWORD')

    const karlPages = await readAllPages(request, karl)
    const annaPages = await readAllPages(request, anna)

    const costByRef = new Map(
      expectedQuarantined.map((r) => [r.field_values.batch_ref, r.field_values.cost_figure]),
    )

    // Karl: no cost figure in anything delivered (raw payload, not just the visible cells).
    const karlRaw = JSON.stringify(karlPages)
    for (const row of karlPages.flat()) {
      const cost = row.field_values.cost_figure
      expect(
        cost === undefined || cost === '__field_redacted__',
        `cost_figure delivered to Karl for ${refOf(row)}`,
      ).toBeTruthy()
    }
    for (const cost of costByRef.values()) {
      expect(karlRaw).not.toContain(String(cost))
    }

    // Anna sees the same list, with the figure.
    expect(annaPages.flat().map(refOf)).toEqual(karlPages.flat().map(refOf))
    for (const row of annaPages.flat()) {
      expect(Number(row.field_values.cost_figure)).toBeCloseTo(costByRef.get(refOf(row)) as number, 2)
    }
  })

  test('EO-004: the restricted shipment_manifest type looks the same as an empty one for Karl', async ({ page, request }) => {
    const token = await actorToken(request, 'actor-vortex-karl', 'UAT_QA_VORTEX_KARL_PASSWORD')

    const restricted = await query(request, token, { entity_type: MANIFEST, page_size: PAGE_SIZE })
    expect(restricted.status(), await restricted.text()).toBe(200)
    const restrictedBody = (await restricted.json()) as QueryPage
    expect(restrictedBody.items).toEqual([])
    expect(restrictedBody.next_cursor).toBeNull()

    // A genuinely empty list (a filter nothing matches) has the same shape.
    const empty = await query(request, token, {
      entity_type: BATCH,
      filters: [{ field: 'batch_ref', op: 'eq', value: 'no-such-batch-3120' }],
      page_size: PAGE_SIZE,
    })
    expect(empty.status()).toBe(200)
    expect(await empty.json()).toEqual(restrictedBody)

    // The screen shows no records for the restricted type.
    await loginWithToken(page, token)
    await navigateSpa(page, `/entities/${MANIFEST}`)
    await expect(page.locator('[data-testid="filter-section"]')).toBeVisible({ timeout: 15_000 })
    await expect(page.locator('[data-testid="data-table"] tbody tr')).toHaveCount(0)
  })

  test('EO-005: a page of 201 is refused with 400 and a message that states the limit of 200', async ({ request }) => {
    const token = await actorToken(request, 'actor-vortex-karl', 'UAT_QA_VORTEX_KARL_PASSWORD')

    const resp = await query(request, token, {
      entity_type: BATCH,
      filters: NORDMETALL_QUARANTINED_FILTERS,
      page_size: 201,
    })
    const text = await resp.text()
    expect(resp.status(), text).toBe(400)
    expect(text, 'the refusal must state the limit').toContain('200')
    expect(text, 'no partial list may come with the refusal').not.toContain('B-NM-')
  })
})
