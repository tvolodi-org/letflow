/** T-1887 (master-detail slice 1b): the movement journal (`lf-jrn`) keeps its shell, but its divider now collapses the
 *  operations list like the other list + record screens. Checked at the five design widths: list and legs visible, the
 *  divider above 900 px and not at 390, collapse then reload with the restore control inside the viewport, and at 390
 *  the legs replace the list and Back returns. Runs against the dev-only screen harness (no login, no backend).
 *  Not a CI gate; proof is the local run:
 *    cd web && LF_CHROMIUM=<chromium path> npx playwright test tests/e2e/journal-layout.e2e.spec.ts --config=playwright.config.ts */
import { expect, test, type Page } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

const SIZES = [
  { width: 1920, height: 1080 },
  { width: 1440, height: 900 },
  { width: 1280, height: 800 },
  { width: 1024, height: 768 },
  { width: 390, height: 844 },
]
/** The rule is about the work area, not the viewport: the side nav takes ~250 px, so a 1024 px window has a work area of
 *  ~780 px and behaves as narrow (the first test asserts that with the measured width). */
const WIDE_SIZES = SIZES.filter((s) => s.width >= 1280)
const NARROW_SIZES = SIZES.filter((s) => s.width < 1280)

/** The real AppShell with the stock journal and one operation selected. */
const SCREEN = '/__harness/stock-journal-layout'

const list = (p: Page) => p.locator('.lf-jrn__list').first()
const details = (p: Page) => p.locator('.lf-jrn__details').first()
// scoped to the journal's own layer: the side nav has a divider of its own
const divider = (p: Page) => p.locator('.lf-splitwrap:has([data-testid="journal"]) .lf-splitter').first()
const expander = (p: Page) => p.locator('.lf-splitwrap:has([data-testid="journal"]) .lf-splitter.is-collapsed .lf-splitter__btn').first()
const workArea = async (p: Page) => (await p.locator('[data-testid="journal"]').first().boundingBox())!.width

test.describe('J1 list and legs visible at each wide design width', () => {
  for (const size of WIDE_SIZES) {
    test(`J1 ${size.width}x${size.height}: operations and legs both visible`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(SCREEN)
      await expect(list(page)).toBeVisible()
      await expect(details(page)).toBeVisible()
      expect(await workArea(page)).toBeGreaterThan(900)
    })
  }
})

test.describe('J2 divider present above 900 px of work area, absent below', () => {
  for (const size of WIDE_SIZES) {
    test(`J2 ${size.width}: the divider is present`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(SCREEN)
      await expect(list(page)).toBeVisible()
      await expect(divider(page)).toBeVisible()
    })
  }
  for (const size of NARROW_SIZES) {
    test(`J2 ${size.width}: no divider at narrow work area`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(SCREEN)
      await expect(list(page)).toBeVisible()
      expect(await workArea(page)).toBeLessThanOrEqual(900)
      await expect(divider(page)).toHaveCount(0)
    })
  }
})

test.describe('J3 collapse and restore: the control stays inside the viewport', () => {
  for (const size of WIDE_SIZES) {
    test(`J3 ${size.width}x${size.height}: collapse, expander in viewport, reload, still in viewport, restore`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(SCREEN)
      await expect(list(page)).toBeVisible()
      await divider(page).dispatchEvent('dblclick')
      const vp = page.viewportSize()!
      const inViewport = async () => {
        await expect(expander(page)).toBeVisible()
        const b = await expander(page).boundingBox()
        expect(b).not.toBeNull()
        expect(b!.x).toBeGreaterThanOrEqual(0)
        expect(b!.x + b!.width).toBeLessThanOrEqual(vp.width + 1)
        expect(b!.y).toBeGreaterThanOrEqual(0)
        expect(b!.y + b!.height).toBeLessThanOrEqual(vp.height + 1)
      }
      await inViewport()
      await expect(details(page)).toBeVisible()
      await page.reload()
      await inViewport()
      await expander(page).click()
      await expect(list(page)).toBeVisible()
      await expect(page.locator('.lf-splitwrap:has([data-testid="journal"]) .lf-splitter.is-collapsed')).toHaveCount(0)
    })
  }
})

test.describe('J4 narrow: the legs replace the list, Back returns', () => {
  for (const size of NARROW_SIZES) {
    test(`J4 ${size.width}: Details opens the legs view, Back returns to the list`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(SCREEN)
      const jrn = page.locator('[data-testid="journal"]').first()
      await expect(jrn).toHaveAttribute('data-detail', 'closed')
      await page.locator('[data-testid="journal-expand"]').first().click()
      await page.locator('[data-testid="journal-details-btn"]').first().click()
      await expect(jrn).toHaveAttribute('data-detail', 'open')
      await expect(list(page)).toBeHidden()
      await expect(page.locator('[data-testid="journal-back"]')).toBeVisible()
      await page.locator('[data-testid="journal-back"]').click()
      await expect(jrn).toHaveAttribute('data-detail', 'closed')
      await expect(list(page)).toBeVisible()
    })
  }
})
