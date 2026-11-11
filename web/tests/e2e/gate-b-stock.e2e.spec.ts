/**
 * T-1383 — GATE B browser click-through: the stock screens driven by a real browser against a real backend and the real
 * Keycloak sign-in (no stubs, no session injection). Runs locally (scripts/e2e/stack_up.sh), in CI (job "Stock browser e2e
 * (playwright)") and against QA (E2E_BASE_URL + credentials from env; see docs/testing/gate-b-browser-e2e.md).
 *
 * Steps: S1 count order, S2 receipt -> issue -> My Tasks claim + complete, S3 opening balance approved by a second
 * user, S4 Balances + Movements rows and no uuid on any screen (the R1 helper), S5 document screen wide and narrow
 * (layout asserts + screenshots), S6 dates in ru as DD-MM-YYYY.
 * Every record made here carries E2E_RUN_TAG so reruns on one tenant do not collide.
 */
import { test, expect, type Browser, type BrowserContext, type Page } from '@playwright/test'
import { assertNoUuid } from './support/noUuid'
import { choose, ENV, hasAdmin, localDateTime, openRoute, setPrefs, shotPath, signIn, SKIP_REASON } from './support/gateB'

test.describe.configure({ mode: 'serial' })
test.skip(!hasAdmin, SKIP_REASON)

let ctx: BrowserContext
let page: Page
const state = { receiptNumber: '', receiptUrl: '', openingUrl: '' }

async function newSession(browser: Browser, user: string, pw: string) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  const p = await context.newPage()
  await signIn(p, user, pw)
  return { context, page: p }
}

/** The document number from the header card (the value after the "Number" label). */
async function headerNumber(p: Page): Promise<string> {
  const text = (await p.getByTestId('document-header').innerText()).replace(/\s+/g, ' ')
  return /([A-Z]{1,6}[-/]?\d[\w-]*)/.exec(text)?.[1] ?? ''
}

async function saveDocument(p: Page): Promise<void> {
  await p.getByRole('button', { name: 'Save draft' }).click()
  await expect(p.getByTestId('document-header')).toBeVisible({ timeout: 30_000 })
  await expect(p.getByTestId('document-actions')).toBeVisible()
}

async function issueDocument(p: Page): Promise<void> {
  await p.getByTestId('document-actions').getByRole('button', { name: 'Issue', exact: true }).click()
  await p.getByRole('dialog').getByRole('button', { name: 'Issue', exact: true }).click()
  await expect(p.getByTestId('document-header')).toContainText(/Issued|Posted/i, { timeout: 30_000 })
}

/** Claim then complete the task row that matches `hint` (document number or item name). */
async function claimAndComplete(p: Page, hint: string): Promise<void> {
  await openRoute(p, '/tasks')
  const rows = p.getByTestId('task-row')
  await expect(rows.first()).toBeVisible({ timeout: 30_000 })
  const own = rows.filter({ hasText: hint })
  await ((await own.count()) > 0 ? own.first() : rows.first()).click()
  await expect(p.getByTestId('task-detail-panel')).toBeVisible()
  const claim = p.getByTestId('task-claim-button')
  if (await claim.isVisible().catch(() => false)) await claim.click()
  // R11: Complete appears after the claim
  await expect(p.getByTestId('task-complete-button')).toBeVisible({ timeout: 20_000 })
  await p.getByTestId('task-complete-button').click()
}

test.beforeAll(async ({ browser }) => {
  const s = await newSession(browser, ENV.admin, ENV.adminPw)
  ctx = s.context
  page = s.page
})

test.afterAll(async () => {
  await ctx?.close()
})

test('G1 S1 count order', async () => {
  await openRoute(page, '/admin/stock/counts')
  await page.getByTestId('count-new').first().click()
  const form = page.getByTestId('count-order-form')
  await expect(form).toBeVisible()
  await choose(form.getByLabel('Org unit'), 'Warehouse')
  await form.getByLabel('Planned start').fill(localDateTime(1))
  await form.getByLabel('Planned end').fill(localDateTime(3))
  await choose(form.getByLabel('Chair of the commission'))
  await form.locator('fieldset', { hasText: 'Location roots' }).getByRole('checkbox').first().check()
  await form.getByLabel('Note').fill(`count ${ENV.runTag}`)
  await form.getByTestId('count-save').click()
  await expect(page.getByTestId('count-facts')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByTestId('count-facts')).toContainText('Warehouse')
  await expect(page.getByTestId('count-facts')).toContainText(ENV.runTag)
  await assertNoUuid(page, 'Counts')
})

test('G2 S2 receipt issue claim complete', async () => {
  await openRoute(page, '/admin/stock/documents/new')
  const form = page.getByTestId('document-form')
  await expect(form).toBeVisible()
  await choose(form.getByLabel('Kind'), 'Receipt')
  await choose(form.getByLabel('Org unit'), 'Warehouse')
  await choose(form.getByLabel('Location'), 'Central')
  await choose(form.getByLabel('Responsible'))
  await form.getByLabel('Note').fill(`receipt ${ENV.runTag}`)
  // T-1448: a new draft shows the empty state of the lines editor; the item cell is a typed picker with a list.
  await page.getByRole('button', { name: 'Add line' }).click()
  const row = page.getByTestId('line-editor-row').first()
  await row.getByLabel('Item').fill('Laptop')
  await page.getByRole('option', { name: /Laptop/ }).first().click()
  await row.getByLabel('Quantity').fill('5')
  await row.getByLabel('Unit price').fill('100')
  await saveDocument(page)
  state.receiptUrl = page.url()
  state.receiptNumber = await headerNumber(page)
  await issueDocument(page)

  await claimAndComplete(page, state.receiptNumber || 'Laptop')
  await openRoute(page, state.receiptUrl)
  await expect(page.getByTestId('document-header')).toContainText(/Posted/i, { timeout: 60_000 })
  await assertNoUuid(page, 'Document')
})

test('G3 S3 opening approve and G3b separation of duties', async ({ browser }) => {
  test.skip(ENV.admin2 === '' || ENV.admin2Pw === '', 'E2E_ADMIN2_USER / E2E_ADMIN2_PASSWORD are not set (a second approver is needed)')
  await openRoute(page, '/admin/stock/documents/new')
  const form = page.getByTestId('document-form')
  await choose(form.getByLabel('Kind'), 'Opening balance')
  await choose(form.getByLabel('Org unit'), 'Sales')
  await form.getByLabel('Note').fill(`opening ${ENV.runTag}`)
  // T-1448: a new draft shows the empty state of the lines editor; the item cell is a typed picker with a list.
  await page.getByRole('button', { name: 'Add line' }).click()
  const row = page.getByTestId('line-editor-row').first()
  await row.getByLabel('Item').fill('Laptop')
  await page.getByRole('option', { name: /Laptop/ }).first().click()
  await row.getByLabel('Quantity').fill('2')
  await choose(row.getByLabel('Location'), 'Showroom')
  await choose(row.getByLabel('Responsible'))
  const received = row.getByLabel(/Received/)
  await received.first().fill(new Date(Date.now() - 86_400_000).toISOString().slice(0, 10))
  await saveDocument(page)
  state.openingUrl = page.url()
  const number = await headerNumber(page)
  await issueDocument(page)

  // G3b: the issuer may not approve their own document
  await openRoute(page, '/tasks')
  await page.getByTestId('task-row').filter({ hasText: number || 'Laptop' }).first().click()
  const claim = page.getByTestId('task-claim-button')
  if (await claim.isVisible().catch(() => false)) await claim.click()
  const complete = page.getByTestId('task-complete-button')
  if (await complete.isVisible().catch(() => false)) await complete.click()
  await expect(page.getByTestId('task-sod-error').or(page.getByTestId('task-sod-hint'))).toBeVisible({ timeout: 20_000 })

  // G3: the second user approves
  const second = await newSession(browser, ENV.admin2, ENV.admin2Pw)
  try {
    await claimAndComplete(second.page, number || 'Laptop')
    await openRoute(second.page, state.openingUrl)
    await expect(second.page.getByTestId('document-header')).toContainText(/Posted/i, { timeout: 60_000 })
  } finally {
    await second.context.close()
  }
  await openRoute(page, state.openingUrl)
  await expect(page.getByTestId('document-header')).toContainText(/Posted/i, { timeout: 30_000 })
})

test('G4 S4 registers show rows and no uuid', async () => {
  await openRoute(page, '/admin/stock/balances')
  await expect(page.locator('table tbody tr').first()).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('main, #main-content').first()).toContainText('Laptop')
  await expect(page.locator('main, #main-content').first()).toContainText(/Central warehouse|Showroom/)
  await assertNoUuid(page, 'Balances')

  await openRoute(page, '/admin/stock/movements')
  await expect(page.locator('table tbody tr').first()).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('main, #main-content').first()).toContainText('Laptop')
  await assertNoUuid(page, 'Movements')

  for (const [name, path] of [
    ['Documents', '/admin/stock/documents'],
    ['Counts', '/admin/stock/counts'],
    ['My Tasks', '/tasks'],
  ] as const) {
    await openRoute(page, path)
    await expect(page.locator('#main-content')).toBeVisible()
    await page.waitForLoadState('networkidle')
    await assertNoUuid(page, name)
  }
  if (state.receiptUrl) {
    await openRoute(page, state.receiptUrl)
    await expect(page.getByTestId('document-header')).toBeVisible({ timeout: 30_000 })
    await assertNoUuid(page, 'Document view')
  }
})

test('G5 S5 document screen wide and narrow', async () => {
  test.skip(!state.receiptUrl, 'no document made by G2')
  const path = new URL(state.receiptUrl).pathname
  for (const theme of ['light', 'dark'] as const) {
    for (const lang of ['en', 'ru'] as const) {
      await page.setViewportSize({ width: 1440, height: 900 })
      await openRoute(page, path)
      await setPrefs(page, { lang, theme })
      await expect(page.getByTestId('document-header')).toBeVisible({ timeout: 30_000 })
      await page.screenshot({ path: shotPath(`document-${lang === 'en' ? '' : `${lang}-`}${theme}-1440`), fullPage: true })

      // G5: wide = list and detail side by side (MasterDetail rule 2a)
      if (theme === 'light' && lang === 'en') {
        const list = await page.getByTestId('document-list').boundingBox()
        const head = await page.getByTestId('document-header').boundingBox()
        expect(list && head && head.x >= list.x + list.width - 1).toBeTruthy()
      }

      await page.setViewportSize({ width: 390, height: 844 })
      await page.reload({ waitUntil: 'domcontentloaded' })
      await expect(page.getByTestId('document-header')).toBeVisible({ timeout: 30_000 })
      await page.screenshot({ path: shotPath(`document-${lang === 'en' ? '' : `${lang}-`}${theme}-390`), fullPage: true })
      // G5b: narrow = no horizontal page overflow
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
      expect(overflow, `horizontal overflow at 390 px (${lang}, ${theme})`).toBeLessThanOrEqual(1)
    }
  }
  // count form with long labels in Kazakh
  await page.setViewportSize({ width: 1440, height: 900 })
  await openRoute(page, '/admin/stock/counts')
  await setPrefs(page, { lang: 'kk', theme: 'light' })
  await page.getByTestId('count-new').first().click()
  await expect(page.getByTestId('count-order-form')).toBeVisible()
  await page.screenshot({ path: shotPath('count-form-kk-light-1440'), fullPage: true })
  await page.setViewportSize({ width: 390, height: 844 })
  await page.screenshot({ path: shotPath('count-form-kk-light-390'), fullPage: true })
  await page.setViewportSize({ width: 1440, height: 900 })
  await setPrefs(page, { lang: 'en', theme: 'light' })
})

test('G6 S6 dates in ru are DD-MM-YYYY', async () => {
  await openRoute(page, '/admin/stock/balances')
  await setPrefs(page, { lang: 'ru', theme: 'light' })
  const screens: [string, string][] = [
    ['Documents', '/admin/stock/documents'],
    ['Movements', '/admin/stock/movements'],
    ['Counts', '/admin/stock/counts'],
    ['My Tasks', '/tasks'],
  ]
  if (state.receiptUrl) screens.push(['Document', new URL(state.receiptUrl).pathname])
  let dayFirst = 0
  try {
    for (const [name, path] of screens) {
      await openRoute(page, path)
      await page.waitForLoadState('networkidle')
      const text = await page.locator('#main-content').innerText()
      expect(text, `${name}: ISO date visible in ru`).not.toMatch(/\b\d{4}-\d{2}-\d{2}\b/)
      expect(text, `${name}: slash date visible in ru`).not.toMatch(/\b\d{1,2}\/\d{1,2}\/\d{4}\b/)
      if (/\b\d{2}-\d{2}-\d{4}\b/.test(text)) dayFirst += 1
    }
    expect(dayFirst, 'at least one screen shows a DD-MM-YYYY date').toBeGreaterThan(0)
  } finally {
    await setPrefs(page, { lang: 'en' })
  }
})
