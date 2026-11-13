/** T-1886: list + detail layout (ListDetail component) at the five design widths; collapse/restore; narrow Back.
 *  Tests the balances screens migrated to ListDetail. Dev screen harness, no backend.
 *  Not a CI gate; proof is the local run:
 *    cd web && LF_CHROMIUM=<chromium path> npx playwright test tests/e2e/list-detail-layout.e2e.spec.ts --config=playwright.config.ts
 *  (without LF_CHROMIUM the Playwright-pinned browser is used). */
import { expect, test, type Page } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

const SIZES = [
  { width: 1920, height: 1080 },
  { width: 1440, height: 900 },
  { width: 1280, height: 800 },
  { width: 1024, height: 768 },
  { width: 390, height: 844 },
]
const WIDE_SIZES = SIZES.filter(s => s.width > 900)
const NARROW_SIZES = SIZES.filter(s => s.width <= 900)

/** Screen with a row already selected (uses stock-balances-layout-open fixture). */
const OPEN_SCREEN = '/__harness/stock-balances-layout-open'
/** Screen with no selection (uses stock-balances-layout fixture). */
const CLOSED_SCREEN = '/__harness/stock-balances-layout'
/** Screen with the real AppShell for collapse/reload tests. */
const SHELL_SCREEN = '/__harness/stock-balances-shell'

const list = (p: Page) => p.locator('.lf-reg__list').first()
const details = (p: Page) => p.locator('.lf-reg__details').first()
const divider = (p: Page) => p.locator('.lf-split-layer .lf-splitter').first()
const expander = (p: Page) => p.locator('.lf-splitter.is-collapsed .lf-splitter__btn').first()
const backBtn = (p: Page) => p.locator('[data-testid="list-detail-back"]')

test.describe('L1 list and record visible at each design width', () => {
  for (const size of WIDE_SIZES) {
    test(`L1 ${size.width}x${size.height}: list and record (empty-state) both visible`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(OPEN_SCREEN)
      await expect(list(page)).toBeVisible()
      await expect(details(page)).toBeVisible()
    })
  }
})

test.describe('L2 divider present above 900 px, absent at 390', () => {
  for (const size of WIDE_SIZES) {
    test(`L2 ${size.width}: the split-layer divider is present`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(CLOSED_SCREEN)
      await expect(list(page)).toBeVisible()
      await expect(divider(page)).toBeVisible()
    })
  }

  for (const size of NARROW_SIZES) {
    test(`L2 ${size.width}: no split-layer divider at narrow width`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(CLOSED_SCREEN)
      await expect(list(page)).toBeVisible()
      await expect(divider(page)).not.toBeVisible()
    })
  }
})

test.describe('L3 collapse and restore: control stays inside the viewport', () => {
  for (const size of WIDE_SIZES) {
    test(`L3 ${size.width}x${size.height}: collapse → expander in viewport → reload → still in viewport`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(SHELL_SCREEN)
      await expect(list(page)).toBeVisible()
      // collapse via double-click
      await divider(page).dispatchEvent('dblclick')
      await expect(expander(page)).toBeVisible()
      const vp = page.viewportSize()!
      const b = await expander(page).boundingBox()
      expect(b).not.toBeNull()
      expect(b!.y).toBeGreaterThanOrEqual(0)
      expect(b!.y + b!.height).toBeLessThanOrEqual(vp.height + 1)
      // reload
      await page.reload()
      await expect(expander(page)).toBeVisible()
      const b2 = await expander(page).boundingBox()
      expect(b2).not.toBeNull()
      expect(b2!.y).toBeGreaterThanOrEqual(0)
      expect(b2!.y + b2!.height).toBeLessThanOrEqual(vp.height + 1)
    })
  }
})

test.describe('L4 narrow: record replaces list, Back returns to list', () => {
  for (const size of NARROW_SIZES) {
    test(`L4 ${size.width}: clicking a row shows the detail; Back returns to the list`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(CLOSED_SCREEN)
      // list visible, no details pane (CSS hides it)
      const reg = page.locator('[data-testid="registry"]').first()
      await expect(reg).toHaveAttribute('data-detail', 'closed')
      // click a row
      await page.locator('[data-testid="datatable-row"]').first().click()
      await expect(reg).toHaveAttribute('data-detail', 'open')
      // list pane is hidden (CSS), back button is visible
      await expect(backBtn(page)).toBeVisible()
      // Back returns to list
      await backBtn(page).click()
      await expect(reg).toHaveAttribute('data-detail', 'closed')
    })
  }
})
