/** T-1875: the document list card of the `.lf-doc` screens (asset and stock documents) is visible and usable at every
 *  desktop width: taller than its tools block, with the New buttons and the first row inside it. jsdom has no layout.
 *  Runs against the dev-only screen harness (/__harness/<screen>, no login, no backend). Not a CI gate (ci.yml does not
 *  run the general e2e suite); its proof is the local run:
 *    cd web && LF_CHROMIUM=<chromium path> npx playwright test tests/e2e/doc-list-layout.e2e.spec.ts --config=playwright.config.ts
 *  LF_CHROMIUM (test-only) points at an installed browser when the Playwright-pinned build is not on the host. */
import { expect, test, type Locator, type Page, type TestInfo } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

interface Box { x: number; y: number; width: number; height: number }
const SIZES = [
  { width: 1024, height: 768 },
  { width: 1280, height: 800 },
  { width: 1440, height: 900 },
  { width: 1920, height: 1080 },
  { width: 390, height: 844 },
]
const box = async (l: Locator): Promise<Box> => {
  const b = await l.first().boundingBox()
  if (!b) throw new Error('no box')
  return b
}
const inside = (a: Box, b: Box) => a.x >= b.x - 1 && a.y >= b.y - 1 && a.x + a.width <= b.x + b.width + 1 && a.y + a.height <= b.y + b.height + 1
const intersects = (a: Box, b: Box) => a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height

async function shoot(page: Page, info: TestInfo, name: string) {
  const path = info.outputPath(`${name}.png`)
  await page.screenshot({ path })
  await info.attach(name, { path, contentType: 'image/png' })
}

const SCREENS = [
  { screen: 'asset-documents', open: false, newButtons: 5 },
  { screen: 'stock-documents', open: false, newButtons: 0 },
  { screen: 'asset-document-draft', open: true, newButtons: 5 },
  { screen: 'stock-document-draft', open: true, newButtons: 0 },
]

test.describe('document list card layout', () => {
  for (const size of SIZES) {
    for (const s of SCREENS) {
      test(`E1 ${s.screen} at ${size.width}x${size.height}: the list card is visible, taller than its tools, with buttons and a row inside`, async ({ page }, info) => {
        // one column (<= 900 px): an open document replaces the list, so there is no list card to measure
        test.skip(s.open && size.width <= 900, 'an open document replaces the list on one column')
        await page.setViewportSize(size)
        await page.goto(`/__harness/${s.screen}`)
        const list = page.locator('.lf-doc__list').first()
        await expect(list).toBeVisible()
        await expect(page.locator('.lf-doc__item').first()).toBeVisible()
        const lb = await box(list)
        const tools = await box(page.locator('.lf-doc__tools'))
        expect(lb.height).toBeGreaterThanOrEqual(tools.height + 40)
        if (size.width > 900 && s.open) expect(lb.height).toBeGreaterThanOrEqual(Math.min(640, size.height - 32) - 1)
        const buttons = page.locator('[data-testid="document-new"] button')
        await expect(buttons).toHaveCount(s.newButtons)
        for (let i = 0; i < s.newButtons; i++) {
          await expect(buttons.nth(i)).toBeVisible()
          expect(inside(await box(buttons.nth(i)), lb)).toBe(true)
        }
        expect(inside(await box(page.locator('.lf-doc__item')), lb)).toBe(true)
        if (s.open && size.width > 900) {
          for (const other of ['.lf-doc__header', '.lf-doc__lines']) {
            const o = page.locator(other)
            if (await o.count()) expect(intersects(lb, await box(o))).toBe(false)
          }
        }
        await shoot(page, info, `${s.screen}-${size.width}`)
      })
    }
  }

  test('E2 the empty state stays clear: the first-use text and all five New buttons sit inside the list card', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 })
    await page.goto('/__harness/asset-documents?state=empty')
    const lb = await box(page.locator('.lf-doc__list'))
    await expect(page.getByTestId('empty-first')).toBeVisible()
    expect(inside(await box(page.getByTestId('empty-first')), lb)).toBe(true)
    const buttons = page.locator('[data-testid="document-new"] button')
    await expect(buttons).toHaveCount(5)
    for (let i = 0; i < 5; i++) expect(inside(await box(buttons.nth(i)), lb)).toBe(true)
  })

  for (const size of [{ width: 1024, height: 768 }, { width: 1280, height: 800 }]) {
    test(`E3 a saved list width (16 %) is clamped to the splitter minimum at ${size.width}`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto('/__harness/stock-docs-layout-remembered')
      await expect(page.locator('.lf-doc__list')).toBeVisible()
      expect((await box(page.locator('.lf-doc__list'))).width).toBeGreaterThanOrEqual(199.5)
    })
  }

  test('E3 a collapsed list stays collapsed and does not push the header down to the floor', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 })
    await page.goto('/__harness/stock-docs-layout-collapsed')
    await expect(page.locator('.lf-doc__header')).toBeVisible()
    expect((await box(page.locator('.lf-doc__list'))).width).toBeLessThanOrEqual(4)
    expect((await box(page.locator('.lf-doc__header'))).y).toBeLessThan(300)
  })
})
