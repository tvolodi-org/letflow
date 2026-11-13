/** T-1884: the expand control of a collapsed pane lies inside the viewport after a reload (1440x900, 1280x720), and double
 *  click, Escape, the Reset layout control, two tabs and 390 px work in a real browser. Dev screen harness, no backend.
 *  Not a CI gate; proof is the local run:
 *    cd web && LF_CHROMIUM=<chromium path> npx playwright test tests/e2e/splitter-viewport.e2e.spec.ts --config=playwright.config.ts
 *  (without LF_CHROMIUM the Playwright-pinned browser is used). */
import { expect, test, type Page } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

const SCREEN = '/__harness/stock-balances-shell'
const SIZES = [
  { width: 1440, height: 900 },
  { width: 1280, height: 720 },
]
const STORE = 'lf.prefs.ui.layout.v1'

const handle = (p: Page) => p.locator('.lf-split-layer .lf-splitter').first()
const expander = (p: Page) => p.locator('.lf-splitter.is-collapsed .lf-splitter__btn')
const stored = (p: Page) => p.evaluate((k) => Object.keys(localStorage).filter((x) => x.startsWith(k)).map((x) => localStorage.getItem(x)), STORE)

async function collapse(p: Page) {
  await handle(p).dispatchEvent('dblclick')
  await expect(expander(p)).toBeVisible()
}

async function expectExpanderInViewport(p: Page, label: string) {
  const vp = p.viewportSize()!
  const b = await expander(p).boundingBox()
  const topbar = (await p.locator('.lf-topbar').count()) ? await p.locator('.lf-topbar').first().boundingBox() : null
  const info = await p.evaluate(() => ({
    scrollY: window.scrollY,
    h: document.querySelector('.lf-splitter.is-collapsed')?.getBoundingClientRect().toJSON(),
    c: document.querySelector('.lf-split-layer')?.parentElement?.getBoundingClientRect().toJSON(),
  }))
  console.log(label, JSON.stringify({ btn: b, topbar, vp, ...info }))
  expect(b).not.toBeNull()
  const minY = topbar ? topbar.y + topbar.height - 1 : 0
  expect(b!.y).toBeGreaterThanOrEqual(minY)
  expect(b!.y + b!.height).toBeLessThanOrEqual(vp.height + 1)
  expect(b!.x).toBeGreaterThanOrEqual(0)
  expect(b!.x + b!.width).toBeLessThanOrEqual(vp.width + 1)
}

test.describe('collapsed pane expander stays in the viewport', () => {
  for (const size of SIZES) {
    test(`V1 ${size.width}x${size.height}: after collapse and reload the expander box is inside the viewport`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(SCREEN)
      await collapse(page)
      await expectExpanderInViewport(page, 'before reload')
      await page.reload()
      await expect(expander(page)).toBeVisible()
      await expectExpanderInViewport(page, 'after reload')
    })
  }

  test('V4 the strip starts below the fold (tall block above the grid): the expander is still inside the viewport', async ({ page }) => {
    await page.setViewportSize(SIZES[0]!)
    await page.goto('/__harness/stock-balances-shell-tall')
    await collapse(page)
    await expectExpanderInViewport(page, 'tall')
    await page.reload()
    await expect(expander(page)).toBeVisible()
    await expectExpanderInViewport(page, 'tall after reload')
  })

  test('V3 the expander stays inside the viewport after scrolling down and back', async ({ page }) => {
    await page.setViewportSize(SIZES[0]!)
    await page.goto(SCREEN)
    await collapse(page)
    await page.evaluate(() => window.scrollTo(0, 600))
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))
    await expectExpanderInViewport(page, 'scrolled')
    await page.evaluate(() => window.scrollTo(0, 0))
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))
    await expectExpanderInViewport(page, 'back')
  })

  test('D1 a real double click on the separator collapses and restores', async ({ page }) => {
    await page.setViewportSize(SIZES[0]!)
    await page.goto(SCREEN)
    const h = handle(page)
    const b = (await h.boundingBox())!
    await page.mouse.dblclick(b.x + b.width / 2, b.y + b.height / 2 + 100)
    await expect(expander(page)).toBeVisible()
    const b2 = (await h.boundingBox())!
    await page.mouse.dblclick(b2.x + b2.width / 2, b2.y + b2.height / 2 + 100)
    await expect(page.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
  })

  test('E1 Escape on the focused separator restores a collapsed pane and clears the stored layout', async ({ page }) => {
    await page.setViewportSize(SIZES[0]!)
    await page.goto(SCREEN)
    await collapse(page)
    await handle(page).focus()
    await page.keyboard.press('Escape')
    await expect(page.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
    await page.reload()
    await expect(handle(page)).toBeVisible()
    await expect(page.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
  })

  test('R1 the Reset layout control reopens the pane and the browser copy stays cleared after a reload', async ({ page }) => {
    await page.setViewportSize(SIZES[0]!)
    await page.goto(SCREEN)
    await collapse(page)
    await expect.poll(async () => (await stored(page)).join('')).toContain('collapsed')
    await page.getByTestId('reset-layout-all').click()
    await expect(page.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
    await expect.poll(async () => (await stored(page)).join('')).not.toContain('collapsed')
    await page.reload()
    await expect(handle(page)).toBeVisible()
    await expect(page.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
  })

  test('T1 two tabs: a collapse in tab A reaches tab B, a reset in B is followed by A, and a reset in A by B', async ({ context }) => {
    // Both tabs load first: the harness server is stateless (it answers an empty layout), and the store lets the
    // server's empty layout win over the local copy on load, so a tab opened later would start empty by design.
    const a = await context.newPage()
    const b = await context.newPage()
    for (const p of [a, b]) await p.setViewportSize(SIZES[0]!)
    await a.goto(SCREEN)
    await b.goto(SCREEN)
    await expect(handle(a)).toBeVisible()
    await expect(handle(b)).toBeVisible()
    await collapse(a)
    await expect.poll(async () => (await stored(a)).join('')).toContain('collapsed')
    await expect(expander(b)).toBeVisible() // the storage event moved the collapse over
    await b.getByTestId('reset-layout-all').click()
    await expect(b.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
    await expect(a.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
    expect((await stored(a)).join('')).not.toContain('collapsed')
    // a tab that is idle after the reset must not write the old layout back
    await a.waitForTimeout(700)
    expect((await stored(b)).join('')).not.toContain('collapsed')
    // the other way: collapse in B, reset in A
    await collapse(b)
    await expect.poll(async () => (await stored(b)).join('')).toContain('collapsed')
    await expect(expander(a)).toBeVisible()
    await a.getByTestId('reset-layout-all').click()
    await expect(a.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
    await expect(b.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
    await b.reload()
    await a.reload()
    await expect(handle(b)).toBeVisible()
    await expect(b.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
    await expect(a.locator('.lf-splitter.is-collapsed')).toHaveCount(0)
  })

  test('P1 390 px: no splitter layer, the list pane is visible, and a collapse saved at desktop width stays open', async ({ page }) => {
    await page.setViewportSize(SIZES[0]!)
    await page.goto(SCREEN)
    await collapse(page)
    await expect.poll(async () => (await stored(page)).join('')).toContain('collapsed')
    await page.setViewportSize({ width: 390, height: 844 })
    await page.reload()
    await expect(page.locator('.lf-reg__list').first()).toBeVisible()
    const lb = (await page.locator('.lf-reg__list').first().boundingBox())!
    expect(lb.height).toBeGreaterThan(40)
    expect(lb.width).toBeGreaterThan(200)
    await expect(page.locator('.lf-split-layer .lf-splitter:visible')).toHaveCount(0)
  })
})
