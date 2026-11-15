/** T-2007: the owner inbox of problem reports on the dev screen harness (no login, no backend): the report text beside the
 *  captured facts at 1440 and stacked at 390, a decision, customer text shown escaped, the Tabs layout, ru and kk.
 *  Not a CI gate; proof is the local run:
 *    cd web && LF_CHROMIUM=<chromium path> npx playwright test tests/e2e/problem-reports-inbox.e2e.spec.ts --config=playwright.config.ts */
import { expect, test, type Page } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

const SHELL = '/__harness/problem-reports-shell'
const box = async (p: Page, id: string) => (await p.locator(`[data-testid="${id}"]`).first().boundingBox())!
const divider = (p: Page) => p.locator('.lf-splitwrap:has([data-testid="registry"]) .lf-splitter').first()

test('PR-E1 1440: list, record and divider; facts box right of the text box', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto(SHELL)
  await expect(page.locator('[data-testid="pr-list"]')).toBeVisible()
  await expect(page.locator('[data-testid="pr-detail"]')).toBeVisible()
  await expect(divider(page)).toBeVisible()
  const text = await box(page, 'pr-text')
  const facts = await box(page, 'pr-facts')
  expect(facts.x).toBeGreaterThan(text.x + text.width / 2)
  expect(Math.abs(facts.y - text.y)).toBeLessThan(8)
})

test('PR-E2 390: list first, then the record stacks text over facts, no horizontal scroll, Back returns', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  // The harness pins the screen's location, so a click cannot change the URL: the list state and the open state are two fixtures.
  await page.goto('/__harness/problem-reports-shell-list')
  await expect(page.locator('[data-testid="pr-list"]')).toContainText('SR-14')
  await expect(page.locator('[data-testid="pr-detail"]')).toHaveCount(0)
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
  await page.goto(SHELL)
  await expect(page.locator('[data-testid="pr-detail"]')).toBeVisible()
  await expect(page.locator('[data-testid="pr-list"]')).toBeHidden()
  const text = await box(page, 'pr-text')
  const facts = await box(page, 'pr-facts')
  expect(facts.y).toBeGreaterThan(text.y + text.height - 1)
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
  await expect(page.locator('[data-testid="list-detail-back"]')).toBeVisible()
})

test('PR-E3 1440: Answer saves, the pill reads Answered, the buttons go, the row stays selected', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto(SHELL)
  await page.locator('[data-testid="pr-action-answer"]').click()
  await page.locator('[data-testid="pr-decision-text"]').fill('Open the card and press Print.')
  await page.getByRole('button', { name: 'Save decision' }).click()
  await expect(page.locator('[data-testid="pr-detail"] [data-testid="pr-status-answered"]')).toBeVisible()
  await expect(page.locator('[data-testid="pr-action-answer"]')).toHaveCount(0)
  await expect(page.locator('[data-testid="pr-list"] tr[aria-current="true"]')).toContainText('SR-14')
})

test('PR-E4 1440: customer markup is shown as text and runs nothing', async ({ page }) => {
  page.on('dialog', () => {
    throw new Error('a dialog opened: customer text was executed')
  })
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto('/__harness/problem-reports-xss')
  await expect(page.locator('[data-testid="pr-text"]')).toContainText('<script>window.__pwned=2</script>')
  await expect(page.locator('[data-testid="pr-text"] img')).toHaveCount(0)
  await expect(page.locator('[data-testid="pr-text"] b')).toHaveCount(0)
  expect(await page.evaluate(() => (window as unknown as { __pwned?: number }).__pwned)).toBeUndefined()
})

test('PR-E5 1440: the Tabs layout gives Report and Facts their own tabs', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto('/__harness/problem-reports-tabs')
  const tablist = page.locator('[data-testid="pr-detail"] [role="tablist"]')
  await expect(tablist).toBeVisible()
  await expect(page.locator('#pr-tab-report')).toHaveAttribute('aria-selected', 'true')
  await page.locator('#pr-tab-facts').click()
  await expect(page.locator('[data-testid="pr-facts"]')).toBeVisible()
})

for (const [lang, title, answer] of [['ru', 'Сообщения о проблемах', 'Ответить'], ['kk', 'Мәселе туралы хабарламалар', 'Жауап беру']] as const) {
  test(`PR-E6 1440 ${lang}: title and the Answer button are translated`, async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 })
    await page.goto(`${SHELL}?lang=${lang}`)
    await expect(page.getByRole('heading', { name: title, level: 1 })).toBeVisible()
    await expect(page.locator('[data-testid="pr-action-answer"]')).toHaveText(answer)
  })
}
