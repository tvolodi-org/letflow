/** T-2006: local harness browser proof; general e2e specs are not run by the fixed Stock CI job. */
import { expect, test, type Page } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

async function noPageOverflow(page: Page) {
  const measured = await page.evaluate(() => ({
    viewport: innerWidth, scroll: document.documentElement.scrollWidth,
    outside: [...document.querySelectorAll('body *')].filter((el) => el.getBoundingClientRect().right > innerWidth + 1).slice(0, 20).map((el) => ({ tag: el.tagName, cls: el.className, right: el.getBoundingClientRect().right, width: el.getBoundingClientRect().width, parent: el.parentElement?.className })),
  }))
  expect(measured.scroll, JSON.stringify(measured)).toBeLessThanOrEqual(measured.viewport)
}

for (const family of ['stock', 'assets', 'stock-count']) {
  for (const lang of ['en', 'ru', 'kk']) {
    for (const layout of ['row', 'tabs']) {
      for (const width of [1440, 390]) {
        test(`${family} ${layout} ${lang} at ${width}: every document panel follows the layout`, async ({ page }) => {
          await page.setViewportSize({ width, height: 1000 })
          await page.goto(`/__harness/panels-${family}-${layout}?lang=${lang}`)
          const grid = page.locator('.lf-doc')
          await expect(grid).toHaveAttribute('data-layout', layout)
          // A nested panel cannot participate in the grid. This also catches a new screen bypassing DocLayout.
          for (const pane of ['list', 'header', 'lines']) {
            await expect(grid.locator(`:scope > .lf-doc__${pane}`)).toHaveCount(1)
            await expect(page.locator(`.lf-doc__${pane}`)).toHaveCount(1)
          }
          const header = grid.locator(':scope > .lf-doc__header')
          const lines = grid.locator(':scope > .lf-doc__lines')
          if (layout === 'tabs') {
            await expect(lines).toBeVisible()
            await expect(header).toBeHidden()
            await page.getByTestId('document-tab-header').click()
            await expect(header).toBeVisible()
            await expect(lines).toBeHidden()
            await page.getByTestId('document-tab-lines').click()
          } else {
            await expect(header).toBeVisible()
            await expect(lines).toBeVisible()
            const h = (await header.boundingBox())!
            const l = (await lines.boundingBox())!
            if (width === 1440) {
              const list = (await grid.locator(':scope > .lf-doc__list').boundingBox())!
              expect(h.x).toBeGreaterThanOrEqual(list.x + list.width)
              expect(l.x).toBeGreaterThanOrEqual(h.x + h.width)
              expect(Math.abs(l.y - h.y)).toBeLessThan(2)
              await expect(grid.locator('..').getByRole('separator')).toHaveCount(2)
            } else {
              expect(l.y).toBeGreaterThanOrEqual(h.y + h.height)
            }
          }
          if (width === 390) await expect(grid.locator(':scope > .lf-doc__list')).toBeHidden()
          await noPageOverflow(page)
        })
      }
    }
  }
}

for (const layout of ['row', 'tabs']) {
  for (const width of [1440, 390]) {
    test(`asset count order ${layout} at ${width}: its single shipped panel stays usable`, async ({ page }) => {
      await page.setViewportSize({ width, height: 1000 })
      await page.goto(`/__harness/panels-asset-count-${layout}`)
      const grid = page.locator('.lf-doc')
      await expect(grid).toHaveAttribute('data-layout', layout)
      await expect(grid.locator(':scope > .lf-doc__blank').getByTestId('count-facts')).toBeVisible()
      await expect(grid.locator(':scope > .lf-doc__list')).toHaveCount(1)
      if (width === 390) await expect(grid.locator(':scope > .lf-doc__list')).toBeHidden()
      else await expect(grid.locator(':scope > .lf-doc__list')).toBeVisible()
      await noPageOverflow(page)
    })
  }
}

for (const name of ['stock-document-draft-edit', 'asset-document-edit']) {
  test(`${name}: editing Row retains three desktop columns`, async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 1000 })
    await page.goto(`/__harness/${name}`)
    const grid = page.locator('.lf-doc')
    await expect(grid.locator('.lf-le[data-readonly="false"]')).toBeVisible()
    const list = grid.locator(':scope > .lf-doc__list')
    const header = grid.locator(':scope > .lf-doc__header')
    const lines = grid.locator(':scope > .lf-doc__lines')
    await expect(list).toBeVisible()
    const h = (await header.boundingBox())!
    const l = (await lines.boundingBox())!
    expect(l.x).toBeGreaterThanOrEqual(h.x + h.width)
    expect(Math.abs(l.y - h.y)).toBeLessThan(2)
  })
}

// Optional local review artifacts; use one server/browser run for the entire matrix.
const shotDir = process.env['LF_SHOT_DIR']
if (shotDir) {
  const screens = [
    ...['stock', 'assets', 'stock-count', 'asset-count'].flatMap((family) => ['row', 'tabs'].map((layout) => ({ name: `panels-${family}-${layout}` }))),
    ...['stock', 'assets', 'stock-count'].map((family) => ({ name: `panels-${family}-tabs`, state: 'header' })),
    ...['stock-document-draft-edit', 'stock-document-new-receipt', 'asset-document-edit', 'asset-document-new',
      'panels-stock-count-new', 'panels-stock-count-edit', 'panels-stock-count-validation', 'assets-counts-edit', 'assets-counts-new', 'assets-counts-invalid', 'assets-counts-readonly'].map((name) => ({ name })),
    ...['panels-stock-readonly', 'panels-assets-readonly', 'panels-stock-count-readonly', 'panels-stock-no-lines',
      'panels-assets-no-lines', 'panels-stock-count-no-lines', 'doc-layout-tabs-problems', 'asset-document-new-errors'].map((name) => ({ name })),
    ...['stock-documents', 'asset-documents', 'assets-counts-list', 'panels-stock-count-list'].flatMap((name) =>
      ['empty', 'loading', 'error'].map((state) => ({ name, state }))),
  ]
  for (const screen of screens) {
    const state = 'state' in screen ? screen.state : undefined
    test(`shot matrix ${screen.name} ${state ?? 'view'}`, async ({ page }) => {
      let first = true
      for (const lang of ['en', 'ru', 'kk']) {
        for (const theme of ['light', 'dark']) {
          for (const width of [1440, 390]) {
            await page.setViewportSize({ width, height: 1100 })
            const queryState = state && state !== 'header' ? `&state=${state}` : ''
            const url = `/__harness/${screen.name}?lang=${lang}&theme=${theme}${queryState}`
            if (first) {
              await page.goto(url)
              first = false
            } else {
              // Exercise the harness language/theme controls without rebuilding a browser context per shot.
              await page.evaluate((next) => {
                history.pushState(null, '', next)
                dispatchEvent(new PopStateEvent('popstate'))
              }, url)
            }
            await expect(page.locator('html')).toHaveAttribute('lang', lang)
            await expect(page.locator('html')).toHaveAttribute('data-theme', theme)
            await expect(page.locator('.lf-doc')).toBeVisible()
            if (state === 'header') await page.getByTestId('document-tab-header').click()
            await page.evaluate(() => document.fonts.ready)
            await noPageOverflow(page)
            const name = `${screen.name}${state ? `-${state}` : ''}${lang === 'en' ? '' : `-${lang}`}-${theme}-${width}.png`
            await page.screenshot({ path: `${shotDir}/${name}`, fullPage: true })
          }
        }
      }
    })
  }
}
