/** T-1913: click every stock document/count print button through real screens. QA/CI only. */
import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Page } from '@playwright/test'
import { ENV, SKIP_REASON, hasAdmin, signIn, setPrefs, openRoute, choose, localDateTime,
  headerNumber, saveDocument, issueDocument, claimAndComplete } from './support/gateB'
import { pdfTextItems } from './support/pdfText'

test.describe.configure({ mode: 'serial', timeout: 120_000 })
test.skip(!hasAdmin, SKIP_REASON)
let context: BrowserContext
let page: Page
let countNumber = ''
let receiptNumber = ''
let receiptPosted = false
const pending = new Set<string>()

const MIME = {
  pdf: 'application/pdf',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
}
async function expectDownload(click: () => Promise<void>, ext: keyof typeof MIME, urlPart: string, title?: string): Promise<Buffer> {
  const [response, download] = await Promise.all([
    page.waitForResponse(r => r.url().includes(urlPart)),
    page.waitForEvent('download'), click(),
  ])
  expect(response.status()).toBe(200)
  expect(response.headers()['content-type']).toContain(MIME[ext])
  expect(download.suggestedFilename()).toMatch(new RegExp(`\\.${ext}$`))
  const path = await download.path()
  expect(path).toBeTruthy()
  const bytes = readFileSync(path!)
  expect(bytes.subarray(0, ext === 'pdf' ? 4 : 2).toString()).toBe(ext === 'pdf' ? '%PDF' : 'PK')
  if (title) expect(pdfTextItems(bytes).join('\n')).toContain(title)
  return bytes
}
async function formDownloads(form: string, title?: string) {
  for (const ext of ['pdf', 'docx'] as const) {
    await expectDownload(async () => {
      await page.getByTestId('official-form-menu').click()
      await page.getByTestId(`form-${form}-${ext}`).click()
    }, ext, `form=${form}`, ext === 'pdf' ? title : undefined)
  }
}
async function reopen(number: string) {
  await openRoute(page, '/admin/stock/documents')
  await page.getByTestId('document-row').filter({ hasText: number }).first().click()
  await expect(page.getByTestId('document-header')).toBeVisible()
}
async function cancelDocument(number: string) {
  await reopen(number)
  await page.getByRole('button', { name: 'Cancel document', exact: true }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByLabel('Reason text').fill(`e2e ${ENV.runTag}`)
  await dialog.getByRole('button', { name: 'Cancel document', exact: true }).click()
  await expect(page.getByTestId('document-header')).toContainText('Cancelled')
  await expect(page.getByTestId('document-print')).toHaveCount(0)
  await expect(page.getByTestId('official-form-menu')).toHaveCount(0)
  pending.delete(number)
}
async function createDocument(kind: string) {
  await openRoute(page, '/admin/stock/documents')
  await page.getByTestId('document-new').click()
  await page.getByRole('menuitem', { name: kind, exact: true }).click()
  const form = page.getByTestId('document-form')
  await choose(form.getByLabel('Kind'), kind)
  if (['Receipt', 'Issue', 'Write off'].includes(kind)) {
    await choose(form.getByLabel('Org unit'), 'Warehouse')
    await choose(form.getByLabel('Location'), 'Central')
    await choose(form.getByLabel('Responsible'), 'Saule')
    if (kind === 'Write off') await choose(form.getByLabel('Reason', { exact: true }), 'Damaged')
  } else {
    const from = form.getByTestId('side-from')
    const to = form.getByTestId('side-to')
    await choose(from.getByLabel('Org unit'), kind === 'Return' ? 'Sales' : 'Warehouse')
    await choose(from.getByLabel('Location'), kind === 'Return' ? 'Showroom' : 'Rack 01')
    await choose(from.getByLabel('Responsible'), kind === 'Return' ? 'Dana' : 'Saule')
    await choose(to.getByLabel('Org unit'), 'Warehouse')
    await choose(to.getByLabel('Location'), kind === 'Return' ? 'Central' : kind === 'Transfer' ? 'Rack 02' : 'Rack 01')
    await choose(to.getByLabel('Responsible'), 'Yerlan')
  }
  await form.getByLabel('Note').fill(`print ${kind} ${ENV.runTag}`)
  await page.getByRole('button', { name: 'Add line' }).click()
  const row = page.getByTestId('line-editor-row').first()
  await row.getByLabel('Item').fill('Laptop')
  await page.getByRole('option', { name: /Laptop/ }).first().click()
  await row.getByLabel('Quantity').fill(kind === 'Receipt' ? '5' : '1')
  if (kind === 'Receipt') await row.getByLabel('Unit price').fill('100')
  await saveDocument(page)
  await issueDocument(page)
  const number = await headerNumber(page) // a draft has no number: it is allocated at Issue (T-1964)
  if (kind !== 'Receipt') pending.add(number)
  await reopen(number)
  return number
}
async function cancelCount() {
  await openRoute(page, '/admin/stock/counts')
  await page.getByRole('row').filter({ hasText: countNumber }).first().click()
  await expect(page.getByTestId('detail-header')).toContainText(countNumber)
  const cancel = page.getByTestId('count-cancel')
  if (await cancel.isVisible()) {
    await cancel.click()
    await page.getByRole('dialog').getByRole('button', { name: 'Cancel count', exact: true }).click()
    await expect(page.getByTestId('detail-header')).toContainText('Cancelled')
  }
}
test.beforeAll(async ({ browser }) => {
  context = await browser.newContext()
  page = await context.newPage()
  await signIn(page, ENV.admin, ENV.adminPw)
  await setPrefs(page, { lang: 'en' })
})
test.afterAll(async () => {
  try {
    for (const number of pending) await cancelDocument(number)
    if (receiptNumber && !receiptPosted) await claimAndComplete(page, receiptNumber)
  } finally {
    try { if (countNumber) await cancelCount() }
    finally { await context?.close() }
  }
})
test('P1 receipt act and Z-1, then posted act', async () => {
  test.setTimeout(120_000)
  receiptNumber = await createDocument('Receipt')
  await expectDownload(() => page.getByTestId('document-print').click(), 'pdf', '/print', 'Act of receipt')
  await formDownloads('z1')
  await claimAndComplete(page, receiptNumber)
  receiptPosted = true
  await expect(async () => {
    await reopen(receiptNumber)
    await expect(page.getByTestId('document-header')).toContainText('Posted')
  }).toPass({ timeout: 60_000 })
  await expectDownload(() => page.getByTestId('document-print').click(), 'pdf', '/print')
})
for (const [step, kind, title, official] of [
  ['P2', 'Issue', 'Act of issue', 'z2'],
  ['P3', 'Write off', 'Act of write-off', 'z6'],
  ['P4', 'Transfer', 'Act of transfer', 'z5'],
  ['P5', 'Hand over', 'Act of hand over', ''],
  ['P6', 'Return', 'Act of return', ''],
]) {
  test(`${step} ${kind} print buttons`, async () => {
    test.setTimeout(120_000)
    const number = await createDocument(kind)
    await expectDownload(() => page.getByTestId('document-print').click(), 'pdf', '/print', title)
    if (official) await formDownloads(official, official === 'z6' ? 'АКТ списания запасов' : undefined)
    else await expect(page.getByTestId('official-form-menu')).toHaveCount(0)
    await cancelDocument(number)
  })
}
async function countDownloads(kind: string) {
  await expectDownload(() => page.getByTestId(`paperwork-${kind}`).click(), 'xlsx', `/paperwork/${kind}`)
  await expectDownload(() => page.getByTestId(`print-${kind}`).click(), 'pdf', `/print/${kind}`)
}
test('P7 count order xlsx and pdf', async () => {
  await openRoute(page, '/admin/stock/counts')
  await page.getByTestId('count-new').first().click()
  const form = page.getByTestId('count-order-form')
  await choose(form.getByLabel('Org unit'), 'Warehouse')
  await form.getByLabel('Planned start').fill(localDateTime(1))
  await form.getByLabel('Planned end').fill(localDateTime(3))
  await choose(form.getByLabel('Chair of the commission'), 'Saule')
  await form.locator('fieldset', { hasText: 'Location roots' }).getByRole('checkbox', { name: /Central warehouse/ }).check()
  await form.getByLabel('Note').fill(`print count ${ENV.runTag}`)
  await form.getByTestId('count-save').click()
  await expect(page.getByTestId('count-facts')).toBeVisible()
  await page.getByTestId('count-issue').click()
  await page.getByRole('dialog').getByRole('button', { name: 'Issue', exact: true }).click()
  await expect(page.getByTestId('count-open')).toBeVisible()
  countNumber = await page.getByTestId('detail-header').getByRole('heading').innerText()
  expect(countNumber).toMatch(/\d/)
  await openRoute(page, '/admin/stock/counts')
  await page.getByRole('row').filter({ hasText: countNumber }).first().click()
  await countDownloads('order')
})
test('P8 count sheet xlsx/pdf and Inv-10', async () => {
  await page.getByTestId('count-open').click()
  const inputs = page.locator('input[data-testid^="count-input-"]')
  await expect(inputs.first()).toBeVisible()
  for (const input of await inputs.all()) {
    const row = input.locator('xpath=ancestor::tr')
    const book = await row.locator('td').nth(5).innerText()
    const counted = String(Number(book.replace(/[\s,]/g, '')) + 1)
    const saved = page.waitForResponse(r => r.request().method() === 'PUT' && /\/lines\/\d+\/count/.test(r.url()))
    await input.fill(counted)
    await input.press('Enter')
    expect((await saved).status()).toBe(200)
  }
  await page.getByTestId('count-close').click()
  await page.getByRole('dialog').getByRole('button', { name: 'Close sheet', exact: true }).click()
  await countDownloads('sheet')
  await formDownloads('inv10')
})
test('P9 differences xlsx/pdf and Inv-18', async () => {
  await page.getByTestId('sign-sheet').click()
  const dialog = page.getByRole('dialog')
  for (const checkbox of await dialog.locator('input[type="checkbox"]').all()) await checkbox.check()
  await dialog.getByRole('button', { name: 'Mark signed', exact: true }).click()
  await page.getByTestId('issue-differences').click()
  await countDownloads('differences')
  await formDownloads('inv18')
  await cancelCount()
})

// T-1925: Z-7 balances sheet from the balances screen. The period is typed from the tenant's own day (the zone the
// balances read states), so the run does not depend on the runner's clock zone; the dialog default is checked first.
test('P10 balances sheet Z-7', async () => {
  test.setTimeout(120_000)
  const balances = page.waitForResponse(r => r.url().includes('/modules/stock/balances') && r.status() === 200)
  await openRoute(page, '/admin/stock/balances')
  const zone: string = (await (await balances).json()).timezone ?? 'Asia/Almaty'
  await choose(page.getByLabel('Location', { exact: true }), 'Central')
  await expect(page.getByTestId('ledger-seq')).toBeVisible()
  const day = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d)
  const tenantToday = day(new Date())
  const before = new Date(`${tenantToday}T00:00:00Z`)
  before.setUTCDate(before.getUTCDate() - 1)
  const dayBefore = before.toISOString().slice(0, 10)
  for (const ext of ['pdf', 'docx'] as const) {
    await page.getByTestId('official-form-menu').click()
    await page.getByTestId(`form-z7-${ext}`).click()
    const dialog = page.getByTestId('sheet-period-dialog')
    await expect(dialog).toBeVisible()
    await expect(dialog.getByLabel('Period to', { exact: true })).toHaveValue(tenantToday)
    await dialog.getByLabel('Period to', { exact: true }).fill(tenantToday)
    await dialog.getByLabel('Period from', { exact: true }).fill(dayBefore)
    const bytes = await expectDownload(
      () => dialog.getByRole('button', { name: 'Print', exact: true }).click(),
      ext, '/stock-sheet/print', ext === 'pdf' ? 'Ведомость учета остатков' : undefined,
    )
    if (ext === 'pdf') expect(pdfTextItems(bytes).join('\n')).toContain('Laptop')
  }
})
