/** T-1888 (master-detail slice 2): asset cards and stock counts on ListDetail, at the five design widths: list and record
 *  visible, divider above 900 px of work area and not at narrow, collapse then reload with the restore control inside the
 *  viewport, and at narrow the record replaces the list and Back returns. Dev screen harness, no login, no backend.
 *  Not a CI gate; proof is the local run:
 *    cd web && LF_CHROMIUM=<chromium path> npx playwright test tests/e2e/list-detail-slice2.e2e.spec.ts --config=playwright.config.ts */
import { expect, test, type Page } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

const SIZES = [
  { width: 1920, height: 1080 },
  { width: 1440, height: 900 },
  { width: 1280, height: 800 },
  { width: 1024, height: 768 },
  { width: 390, height: 844 },
]
/** The rule is about the work area, not the viewport: the side nav takes ~250 px, so a 1024 px window is narrow. */
const WIDE_SIZES = SIZES.filter((s) => s.width >= 1280)
const NARROW_SIZES = SIZES.filter((s) => s.width < 1280)

const SCREENS = [
  { name: 'asset cards', closed: '/__harness/asset-cards-shell', open: '/__harness/asset-cards-shell-open' },
  { name: 'stock counts', closed: '/__harness/stock-counts-shell', open: '/__harness/stock-counts-shell-open' },
]

const reg = (p: Page) => p.locator('[data-testid="registry"]').first()
const list = (p: Page) => p.locator('.lf-reg__list').first()
const details = (p: Page) => p.locator('.lf-reg__details').first()
// scoped to the screen's own layer: the side nav has a divider of its own
const divider = (p: Page) => p.locator('.lf-splitwrap:has([data-testid="registry"]) .lf-splitter').first()
const expander = (p: Page) => p.locator('.lf-splitwrap:has([data-testid="registry"]) .lf-splitter.is-collapsed .lf-splitter__btn').first()
const backBtn = (p: Page) => p.locator('[data-testid="list-detail-back"]')
const workArea = async (p: Page) => (await reg(p).boundingBox())!.width

for (const scr of SCREENS) {
  test.describe(`${scr.name}`, () => {
    for (const size of WIDE_SIZES) {
      test(`S1 ${size.width}: list and record both visible, divider present`, async ({ page }) => {
        await page.setViewportSize(size)
        await page.goto(scr.open)
        await expect(list(page)).toBeVisible()
        await expect(details(page)).toBeVisible()
        await expect(divider(page)).toBeVisible()
        expect(await workArea(page)).toBeGreaterThan(900)
      })
    }

    for (const size of NARROW_SIZES) {
      test(`S2 ${size.width}: no divider at narrow work area`, async ({ page }) => {
        await page.setViewportSize(size)
        await page.goto(scr.closed)
        await expect(list(page)).toBeVisible()
        expect(await workArea(page)).toBeLessThanOrEqual(900)
        await expect(divider(page)).toHaveCount(0)
      })
    }

    for (const size of WIDE_SIZES) {
      test(`S3 ${size.width}: collapse, reload, restore control inside the viewport`, async ({ page }) => {
        await page.setViewportSize(size)
        await page.goto(scr.closed)
        await expect(list(page)).toBeVisible()
        await divider(page).dispatchEvent('dblclick')
        const vp = page.viewportSize()!
        for (const step of ['collapsed', 'reloaded']) {
          if (step === 'reloaded') await page.reload()
          await expect(expander(page)).toBeVisible()
          const b = await expander(page).boundingBox()
          expect(b).not.toBeNull()
          expect(b!.x).toBeGreaterThanOrEqual(0)
          expect(b!.x + b!.width).toBeLessThanOrEqual(vp.width + 1)
          expect(b!.y).toBeGreaterThanOrEqual(0)
          expect(b!.y + b!.height).toBeLessThanOrEqual(vp.height + 1)
        }
      })
    }

    for (const size of NARROW_SIZES) {
      test(`S4 ${size.width}: the record replaces the list, Back returns`, async ({ page }) => {
        await page.setViewportSize(size)
        await page.goto(scr.open)
        await expect(reg(page)).toHaveAttribute('data-detail', 'open')
        await expect(details(page)).toBeVisible()
        await expect(list(page)).not.toBeVisible()
        await expect(backBtn(page)).toBeVisible()
        await backBtn(page).click()
        // the counts record is the route's :id, so Back navigates to the list URL, which is outside the harness's own route:
        // there the proof is that the record (and its Back button) is gone; the cards screen returns to its list in place
        if (scr.name === 'stock counts') await expect(backBtn(page)).toHaveCount(0)
        else await expect(list(page)).toBeVisible()
      })
    }
  })
}
