/** T-1915: click the print button of the asset document screen through real screens and check the PDF. QA/CI only
 *  (Stock browser e2e job; the host cannot run the Keycloak stack). A fresh card is made per run, so a re-run never
 *  meets `asset_already_in_register`. */
import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Page } from '@playwright/test'
import { ENV, SKIP_REASON, hasAdmin, signIn, setPrefs, openRoute, choose, localDateTime,
  headerNumber, issueDocument, claimAndComplete } from './support/gateB'
import { pdfTextItems } from './support/pdfText'

test.describe.configure({ mode: 'serial', timeout: 120_000 })
test.skip(!hasAdmin, SKIP_REASON)
let context: BrowserContext
let page: Page
let number = ''
const inventoryNumber = `E2E-${ENV.runTag}`

async function download(click: () => Promise<void>) {
  const [response, file] = await Promise.all([
    page.waitForResponse(r => /\/modules\/assets\/documents\/[^/]+\/print/.test(r.url())),
    page.waitForEvent('download'), click(),
  ])
  expect(response.status()).toBe(200)
  expect(response.headers()['content-type']).toContain('application/pdf')
  expect(file.suggestedFilename()).toMatch(/\.pdf$/)
  const path = await file.path()
  expect(path).toBeTruthy()
  const bytes = readFileSync(path!)
  expect(bytes.subarray(0, 4).toString()).toBe('%PDF')
  return pdfTextItems(bytes).join('\n')
}
async function reopen() {
  await openRoute(page, '/admin/assets/documents')
  await page.getByTestId('document-row').filter({ hasText: number }).first().click()
  await expect(page.getByTestId('document-header')).toBeVisible()
}

test.beforeAll(async ({ browser }) => {
  context = await browser.newContext()
  page = await context.newPage()
  await signIn(page, ENV.admin, ENV.adminPw)
  await setPrefs(page, { lang: 'en' })
})
test.afterAll(async () => {
  await context?.close()
})

test('E1 a card, a commission started from it, issued', async () => {
  await openRoute(page, '/admin/assets/cards')
  await page.getByTestId('asset-create').first().click()
  await page.getByLabel('Inventory number').fill(inventoryNumber)
  await page.getByLabel('Name', { exact: true }).fill(`Print test ${ENV.runTag}`)
  await page.getByTestId('asset-save').click()
  await page.getByTestId('card-op-commission').click()
  const form = page.getByTestId('document-form')
  await expect(form).toBeVisible()
  await choose(form.getByLabel(/^Org unit/).first(), 'Warehouse team')
  await choose(form.getByLabel(/^Material responsible/).first(), 'Saule Zhumabek')
  await form.getByLabel('Time').fill(localDateTime(-1))
  await page.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(page.getByTestId('document-header')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByTestId('document-actions')).toBeVisible()
  await issueDocument(page)
  number = await headerNumber(page)
  expect(number).not.toBe('')
})

test('E2 the issued commission prints a PDF with the title and the inventory number', async () => {
  const text = await download(() => page.getByTestId('document-print').click())
  expect(text).toContain('Act of commissioning')
  expect(text).toContain(inventoryNumber)
})

test('E3 the posted commission prints too', async () => {
  await claimAndComplete(page, number)
  await expect(async () => {
    await reopen()
    await expect(page.getByTestId('document-header')).toContainText('Posted')
  }).toPass({ timeout: 60_000 })
  const text = await download(() => page.getByTestId('document-print').click())
  expect(text).toContain('Act of commissioning')
})

test('E4 in Russian the act is Russian', async () => {
  await setPrefs(page, { lang: 'ru' })
  await reopen()
  const text = await download(() => page.getByTestId('document-print').click())
  expect(text).toContain('Акт ввода в эксплуатацию')
  await setPrefs(page, { lang: 'en' })
})

test('E5 a draft has no print button', async () => {
  await openRoute(page, '/admin/assets/documents/new?kind=writeoff')
  await expect(page.getByTestId('document-form')).toBeVisible()
  await expect(page.getByTestId('document-print')).toHaveCount(0)
})
