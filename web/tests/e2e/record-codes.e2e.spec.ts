/** T-1960: the Codes section of Items and Locations in a real browser, on the dev-only screen harness
 *  (/__harness/<screen>, no login, no backend; the fixture keeps one store for Items, Locations and Codes).
 *  Not a CI gate; its proof is the local run:
 *    cd web && LF_CHROMIUM=<chromium path> npx playwright test tests/e2e/record-codes.e2e.spec.ts --config=playwright.config.ts */
import { expect, test } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })
const DESKTOP = { width: 1440, height: 900 }
const PHONE = { width: 390, height: 844 }

async function addCode(page: import('@playwright/test').Page, value: string) {
  await page.getByTestId('record-codes-new').click()
  await page.getByTestId('record-codes-value').fill(value)
  await page.getByTestId('record-codes-dialog-confirm').click()
}

test('E1 an item lists its codes, a new code shows there and then on the Codes screen', async ({ page }) => {
  await page.setViewportSize(DESKTOP)
  await page.goto('/__harness/codes-roundtrip')
  const section = page.getByTestId('record-codes')
  await expect(section.getByText('GATEA-BC-0001')).toBeVisible()
  await addCode(page, 'GATEA-NEW-0100')
  await expect(section.getByText('GATEA-NEW-0100')).toBeVisible()
  await page.getByTestId('roundtrip-codes').click()
  await expect(page.getByText('GATEA-NEW-0100').first()).toBeVisible()
})

test('E2 a code received on the Codes screen is picked from the item', async ({ page }) => {
  await page.setViewportSize(DESKTOP)
  await page.goto('/__harness/item-codes-pick')
  await expect(page.getByTestId('record-codes-dialog')).toBeVisible()
  await page.getByRole('combobox', { name: 'Received code' }).selectOption({ label: 'GATEA-FREE-0004 · Barcode' })
  await page.getByTestId('record-codes-dialog-confirm').click()
  await expect(page.getByTestId('record-codes-table').getByText('GATEA-FREE-0004')).toBeVisible()
})

test('E3 release removes the code from the record', async ({ page }) => {
  await page.setViewportSize(DESKTOP)
  await page.goto('/__harness/item-codes')
  const table = page.getByTestId('record-codes-table')
  await expect(table.getByText('GATEA-BC-0001')).toBeVisible()
  await page.getByTestId('record-codes-release-c-1').click()
  await expect(table.getByText('GATEA-BC-0001')).toHaveCount(0)
})

test('E4 a location lists its codes in the Codes tab and takes a new one', async ({ page }) => {
  await page.setViewportSize(DESKTOP)
  await page.goto('/__harness/location-codes')
  const section = page.getByTestId('record-codes')
  await expect(section.getByText('GATEA-EPC-0003')).toBeVisible()
  await addCode(page, 'GATEA-LOC-0200')
  await expect(section.getByText('GATEA-LOC-0200')).toBeVisible()
})

test('E5 at 390 px the item codes fit the page without horizontal scroll', async ({ page }) => {
  await page.setViewportSize(PHONE)
  await page.goto('/__harness/item-codes')
  await expect(page.getByTestId('record-codes').getByText('GATEA-BC-0001')).toBeVisible()
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
  expect(overflow).toBeLessThanOrEqual(0)
})

test('E6 a value that is already taken is reported next to the field', async ({ page }) => {
  await page.setViewportSize(DESKTOP)
  await page.goto('/__harness/item-codes')
  await addCode(page, 'GATEA-FREE-0004')
  await expect(page.getByTestId('record-codes-dialog')).toBeVisible()
  await expect(page.getByTestId('record-codes-dialog').getByText(/already exists/)).toBeVisible()
  await expect(page.getByTestId('record-codes-value')).toHaveAttribute('aria-invalid', 'true')
})

for (const screen of ['item-codes', 'location-codes']) {
  test(`E7 ${screen}: Escape closes the dialog first, the record second`, async ({ page }) => {
    await page.setViewportSize(DESKTOP)
    await page.goto(`/__harness/${screen}`)
    await page.getByTestId('record-codes-new').click()
    await page.getByTestId('record-codes-value').press('Escape')
    await expect(page.getByTestId('record-codes-dialog')).toHaveCount(0)
    await expect(page.getByTestId('record-codes')).toBeVisible()
  })
}
