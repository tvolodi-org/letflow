/** T-1953: the header "New" menu of the two document screens (asset and stock documents) in a real browser. The menu
 *  sits in the page header, not in the list card; every kind is reachable by mouse and by keyboard and leads to
 *  `documents/new?kind=<kind>`. Runs against the dev-only screen harness (/__harness/<screen>, no login, no backend);
 *  the harness has no router for the create route, so the URL reached is the proof, and the form that URL opens is
 *  shown by its own harness screen.
 *  Not a CI gate (ci.yml does not run the general e2e suite); its proof is the local run:
 *    cd web && LF_CHROMIUM=<chromium path> npx playwright test tests/e2e/page-header-new-menu.e2e.spec.ts --config=playwright.config.ts
 *  LF_CHROMIUM (test-only) points at an installed browser when the Playwright-pinned build is not on the host. */
import { expect, test, type Locator, type Page } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

const DESKTOP = { width: 1440, height: 900 }
const PHONE = { width: 390, height: 844 }

interface Box { x: number; y: number; width: number; height: number }
const box = async (l: Locator): Promise<Box> => {
  const b = await l.first().boundingBox()
  if (!b) throw new Error('no box')
  return b
}
function trackUrls(page: Page): string[] {
  const urls: string[] = []
  page.on('framenavigated', (f) => {
    if (f === page.mainFrame()) urls.push(f.url())
  })
  return urls
}
const reached = (urls: string[], path: string) => urls.some((u) => u.endsWith(path))

const SCREENS = [
  { name: 'asset-documents', items: 6, base: '/admin/assets/documents', pick: 'Opening', kind: 'opening', form: 'asset-document-op-new' },
  { name: 'stock-documents', items: 7, base: '/admin/stock/documents', pick: 'Transfer', kind: 'transfer', form: 'stock-document-new-transfer' },
] as const

for (const s of SCREENS) {
  for (const size of [DESKTOP, PHONE]) {
    test(`B1/B2 ${s.name} at ${size.width}: the trigger is in the header, the menu has ${s.items} kinds inside the viewport`, async ({ page }) => {
      await page.setViewportSize(size)
      await page.goto(`/__harness/${s.name}`)
      const header = page.getByTestId('page-header-actions')
      const trigger = header.getByTestId('document-new')
      await expect(trigger).toBeVisible()
      await expect(page.locator('.lf-doc__list [data-testid="document-new"]')).toHaveCount(0)
      const tb = await box(trigger)
      const hb = await box(header)
      const lb = await box(page.locator('.lf-doc__list'))
      expect(tb.y).toBeLessThanOrEqual(lb.y)
      if (size.width === DESKTOP.width) expect(Math.abs(tb.x + tb.width - (hb.x + hb.width))).toBeLessThanOrEqual(2)
      await trigger.click()
      const items = page.getByRole('menuitem')
      await expect(items).toHaveCount(s.items)
      for (let i = 0; i < s.items; i++) {
        const b = await box(items.nth(i))
        expect(b.x).toBeGreaterThanOrEqual(0)
        expect(b.x + b.width).toBeLessThanOrEqual(size.width)
      }
    })
  }

  test(`B1/B2 ${s.name}: the mouse path chooses ${s.pick} and the keyboard path chooses the second kind`, async ({ page }) => {
    await page.setViewportSize(DESKTOP)
    await page.goto(`/__harness/${s.name}`)
    const urls = trackUrls(page)
    await page.getByTestId('document-new').click()
    await page.getByRole('menuitem', { name: s.pick, exact: true }).click()
    await expect.poll(() => reached(urls, `${s.base}/new?kind=${s.kind}`)).toBe(true)
    await page.goto(`/__harness/${s.name}`)
    const urls2 = trackUrls(page)
    await page.getByTestId('document-new').focus()
    await page.keyboard.press('ArrowDown')
    await page.keyboard.press('ArrowDown')
    await page.keyboard.press('Enter')
    await expect.poll(() => urls2.some((u) => /\/new\?kind=[a-z_]+$/.test(u))).toBe(true)
  })

  test(`B3 ${s.name}: Escape closes the open menu and focus returns to the trigger`, async ({ page }) => {
    await page.setViewportSize(DESKTOP)
    await page.goto(`/__harness/${s.name}`)
    const trigger = page.getByTestId('document-new')
    await trigger.focus()
    await page.keyboard.press('ArrowDown')
    await expect(page.getByRole('menu')).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(page.getByRole('menu')).toHaveCount(0)
    await expect(trigger).toBeFocused()
  })

  test(`B1/B2 ${s.name}: the form of the chosen address is the create form`, async ({ page }) => {
    await page.setViewportSize(DESKTOP)
    await page.goto(`/__harness/${s.form}`)
    await expect(page.getByTestId('document-form')).toBeVisible()
  })
}
