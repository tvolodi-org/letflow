/**
 * E2E -- GH 3650 / REQ-675: the master data import screen.
 *
 * A TENANT_ADMIN of a tenant with catalog_items installed downloads the catalog_uom template, uploads a file of
 * two units under an external_ref_system unique to the run (a re-run on the same tenant creates new records),
 * sees two created rows in the dry run, imports, sees the summary with two created rows, and finds both units
 * through the query route. The frontend gate does not run tests/e2e; the run is an operator or UAT step.
 */

import { test, expect } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'
import { buildXlsx } from './xlsxFixture'

test('master data import: template, dry run, import, summary, query', async ({ page, request }) => {
  const token = await getKeycloakToken(request)
  await loginWithToken(page, token)

  const system = `e2e-${Date.now()}`
  const codes = [`${system}-A`, `${system}-B`]

  await page.goto('/admin/import')
  await page.getByTestId('import-type').selectOption('catalog_uom')

  const [download] = await Promise.all([page.waitForEvent('download'), page.getByTestId('import-template').click()])
  expect(download.suggestedFilename()).toBe('catalog_uom-template.xlsx')

  const file = buildXlsx([
    ['code', 'name', 'external_ref_system', 'external_ref_id'],
    [codes[0], `Unit ${codes[0]}`, system, 'A'],
    [codes[1], `Unit ${codes[1]}`, system, 'B'],
  ])
  await page.getByTestId('import-file').setInputFiles({
    name: 'uoms.xlsx',
    mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    buffer: file,
  })

  await page.getByTestId('import-check').click()
  await expect(page.getByTestId('import-dry-run')).toBeVisible()
  await expect(page.getByTestId('import-counts')).toContainText('Created: 2')
  await expect(page.getByTestId('import-result-row')).toHaveCount(2)

  await expect(page.getByTestId('import-confirm')).toBeEnabled()
  await page.getByTestId('import-confirm').click()
  await expect(page.getByTestId('import-summary')).toBeVisible()
  await expect(page.getByTestId('import-counts')).toContainText('Created: 2')
  await expect(page.getByTestId('import-result-row')).toHaveCount(2)

  const response = await request.post('/api/v1/entities/query', {
    headers: { Authorization: `Bearer ${token}` },
    data: {
      entity_type: 'catalog_uom',
      filters: [{ field: 'external_ref_system', op: 'eq', value: system }],
    },
  })
  expect(response.ok()).toBe(true)
  const body = (await response.json()) as { items: { field_values: { code: string } }[] }
  expect(body.items.map((r) => r.field_values.code).sort()).toEqual(codes)
})
