/** T-1946: the one save rule of list + detail screens in a real browser. Runs against the dev-only screen harness
 *  (/__harness/<screen>, stateful fake API, no login, no backend):
 *    CREATE (locations): after Save the new node is selected and its detail is open.
 *    EDIT (asset cards): after Save the same card stays selected and the list scroll position is unchanged.
 *  Local run: cd web && LF_CHROMIUM=<chromium path> npx playwright test tests/e2e/list-detail-save.e2e.spec.ts */
import { expect, test } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

const DESKTOP = { width: 1440, height: 900 }

test('S1 create: the new location is selected and its detail is open after Save', async ({ page }) => {
  await page.setViewportSize(DESKTOP)
  await page.goto('/__harness/list-detail-save-locations')
  await page.getByTestId('loc-create').click()
  await page.getByLabel('Code', { exact: true }).fill('WH-NEW')
  await page.getByLabel('Name', { exact: true }).fill('Brand new zone')
  await page.getByLabel('Kind').first().fill('zone')
  await page.getByTestId('loc-save').click()
  const details = page.getByTestId('registry-details')
  // the detail shows the saved record (edit form of the new node), not the empty state
  await expect(details.getByLabel('Name', { exact: true })).toHaveValue('Brand new zone')
  await expect(page.getByTestId('loc-pick-hint')).toHaveCount(0)
  await expect(page.getByTestId('registry')).toHaveAttribute('data-detail', 'open')
})

test('S2 edit: the same card stays selected and the list scroll position is unchanged after Save', async ({ page }) => {
  await page.setViewportSize(DESKTOP)
  await page.goto('/__harness/list-detail-save-cards')
  const row = page.getByRole('row').filter({ hasText: 'FA-0045' }).first()
  await row.scrollIntoViewIfNeeded()
  await row.click()
  const name = page.getByTestId('registry-details').getByLabel('Name', { exact: true })
  await expect(name).toHaveValue('Asset card 0045')
  const scrollTop = () =>
    page.evaluate(() => {
      const els = Array.from(document.querySelectorAll<HTMLElement>('.lf-reg__list *, .lf-reg__list'))
      return Math.max(0, ...els.map((e) => e.scrollTop))
    })
  const before = await scrollTop()
  expect(before).toBeGreaterThan(0)
  await name.fill('Asset card 0045 renamed')
  await page.getByTestId('asset-save').click()
  await expect(page.getByRole('row').filter({ hasText: 'Asset card 0045 renamed' }).first()).toBeVisible()
  await expect(name).toHaveValue('Asset card 0045 renamed')
  await expect(page.getByTestId('registry')).toHaveAttribute('data-detail', 'open')
  expect(await scrollTop()).toBe(before)
})

test('S3 open a directory: the first item is selected and its detail is open', async ({ page }) => {
  await page.setViewportSize(DESKTOP)
  await page.goto('/__harness/list-detail-save-cards')
  await expect(page.getByTestId('registry')).toHaveAttribute('data-detail', 'open')
  await expect(page.getByTestId('registry-details').getByLabel('Name', { exact: true })).toHaveValue('Asset card 0001')
})

test('S4 open at 390 px: the list is shown, no detail is opened', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/__harness/list-detail-save-cards')
  await expect(page.getByRole('row').filter({ hasText: 'FA-0001' }).first()).toBeVisible()
  await expect(page.getByTestId('registry')).toHaveAttribute('data-detail', 'closed')
})
