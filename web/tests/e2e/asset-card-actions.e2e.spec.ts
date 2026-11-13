/** T-1880 / D-135: the asset card actions in a real browser. Each of Commission, Change responsible, Hand over and
 *  Write off is started from the card panel (Operations button and header Actions menu) and from a card-list row, at
 *  desktop width and on a phone (390 px, touch); the document form opened from a card carries the card as its line and
 *  the holder as its From side. Runs against the dev-only screen harness (/__harness/<screen>, no login, no backend).
 *  Not a CI gate (ci.yml does not run the general e2e suite); its proof is the local run:
 *    cd web && LF_CHROMIUM=<chromium path> npx playwright test tests/e2e/asset-card-actions.e2e.spec.ts --config=playwright.config.ts
 *  LF_CHROMIUM (test-only) points at an installed browser when the Playwright-pinned build is not on the host.
 *  Multi-select is a later part of D-135 and has no test here. */
import { expect, test, type Page } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

const KINDS = ['commission', 'change', 'handover', 'writeoff'] as const
// commission needs a card that is not in the register, the others one that is
const CARD_OF = { commission: 'c-3', change: 'c-1', handover: 'c-1', writeoff: 'c-1' } as const
const PANEL = { commission: 'asset-card-actions-new', change: 'asset-card-actions', handover: 'asset-card-actions', writeoff: 'asset-card-actions' } as const
const DESKTOP = { width: 1440, height: 900 }
const PHONE = { width: 390, height: 844 }

/** The addresses the app navigates to (the harness has no router for them, so the URL is the proof). */
function trackUrls(page: Page): string[] {
  const urls: string[] = []
  page.on('framenavigated', (f) => {
    if (f === page.mainFrame()) urls.push(f.url())
  })
  return urls
}
const expected = (kind: string, card: string) => `/admin/assets/documents/new?kind=${kind}&asset=${card}`
const reached = (urls: string[], path: string) => urls.some((u) => u.endsWith(path))

test.describe('P1 P2 card panel: Operations buttons and header Actions menu', () => {
  for (const kind of KINDS) {
    test(`P1 ${kind}: the Operations button opens the form address with the card`, async ({ page }) => {
      await page.setViewportSize(DESKTOP)
      await page.goto(`/__harness/${PANEL[kind]}`)
      const button = page.getByTestId(`card-op-${kind}`)
      await expect(button).toBeEnabled()
      const urls = trackUrls(page)
      await button.click()
      await expect.poll(() => reached(urls, expected(kind, CARD_OF[kind]))).toBe(true)
    })

    test(`P2 ${kind}: the header Actions menu item opens the form address with the card`, async ({ page }) => {
      await page.setViewportSize(DESKTOP)
      await page.goto(`/__harness/${PANEL[kind]}`)
      await page.getByTestId(`card-actions-panel-${CARD_OF[kind]}`).click()
      const item = page.getByTestId(`card-action-${kind}`)
      await expect(item).toBeVisible()
      await expect(item).not.toHaveAttribute('aria-disabled', 'true')
      const urls = trackUrls(page)
      await item.click()
      await expect.poll(() => reached(urls, expected(kind, CARD_OF[kind]))).toBe(true)
    })
  }

  test('P1 the rule shows: Commission is disabled on a card in the register, with its reason as visible text', async ({ page }) => {
    await page.setViewportSize(DESKTOP)
    await page.goto('/__harness/asset-card-actions')
    await expect(page.getByTestId('card-op-change')).toBeEnabled()
    await expect(page.getByTestId('card-op-commission')).toBeDisabled()
    await expect(page.getByTestId('card-op-reason-commission')).toBeVisible()
  })
})

test.describe('P2 card list rows', () => {
  for (const kind of KINDS) {
    test(`P2 ${kind}: the row menu opens the form address with the card, and the panel stays closed`, async ({ page }) => {
      await page.setViewportSize(DESKTOP)
      await page.goto('/__harness/asset-card-rows')
      // c-1 is in the register, c-3 is not: Commission is offered on c-3 only
      const card = CARD_OF[kind]
      await page.getByTestId(`card-actions-${card}`).click()
      const item = page.getByTestId(`card-action-${kind}`)
      await expect(item).toBeVisible()
      await expect(item).not.toHaveAttribute('aria-disabled', 'true')
      await expect(page.getByTestId('asset-pick-hint')).toBeVisible()
      const urls = trackUrls(page)
      await item.click()
      await expect.poll(() => reached(urls, expected(kind, card))).toBe(true)
    })
  }
})

test.describe('P3 the form opened from a card', () => {
  test('commission: the card is the line, the unit of the card is the header', async ({ page }) => {
    await page.setViewportSize(DESKTOP)
    await page.goto('/__harness/asset-doc-from-card-commission')
    await expect(page.getByTestId('document-form')).toBeVisible()
    await expect(page.getByTestId('line-editor-row').first().getByLabel('Asset')).toHaveValue(/FA-0003/)
    await expect(page.getByTestId('document-form').getByLabel(/^Org unit/).first()).toHaveValue('u-wh')
  })
  for (const kind of ['change', 'handover', 'writeoff']) {
    test(`${kind}: the card is the line, the holder of the register is the From side`, async ({ page }) => {
      await page.setViewportSize(DESKTOP)
      await page.goto(`/__harness/asset-doc-from-card-${kind}`)
      await expect(page.getByTestId('document-form')).toBeVisible()
      await expect(page.getByTestId('line-editor-row').first().getByLabel('Asset')).toHaveValue(/FA-0001/)
      await expect(page.getByTestId('document-form').getByLabel(/^Org unit/).first()).toHaveValue('u-wh')
      await expect(page.getByTestId('doc-prefill-notice')).toHaveCount(0)
    })
  }
  test('a card held in several places: the notice shows and the header is empty', async ({ page }) => {
    await page.setViewportSize(DESKTOP)
    await page.goto('/__harness/asset-doc-from-card-many')
    await expect(page.getByTestId('doc-prefill-notice')).toBeVisible()
    await expect(page.getByTestId('document-form').getByLabel(/^Org unit/).first()).toHaveValue('')
  })
  test('Back to card shows on the saved document', async ({ page }) => {
    await page.setViewportSize(DESKTOP)
    await page.goto('/__harness/asset-doc-back-to-card')
    const urls = trackUrls(page)
    await page.getByTestId('doc-back-to-card').click()
    await expect.poll(() => reached(urls, '/admin/assets/cards?card=c-1')).toBe(true)
  })
})

test.describe('P4 phone: touch at 390 px', () => {
  test.use({ hasTouch: true, viewport: PHONE })

  test('the row menu opens by tap, stays inside the viewport and the reason of a disabled item is visible text', async ({ page }) => {
    await page.goto('/__harness/asset-card-rows')
    await page.getByTestId('card-actions-c-1').tap()
    const menu = page.getByRole('menu')
    await expect(menu).toBeVisible()
    const box = await menu.boundingBox()
    expect(box).not.toBeNull()
    expect(box!.x).toBeGreaterThanOrEqual(-1)
    expect(box!.x + box!.width).toBeLessThanOrEqual(PHONE.width + 1)
    await expect(page.getByTestId('card-action-commission')).toHaveAttribute('aria-disabled', 'true')
    await expect(page.getByTestId('card-action-commission')).toContainText('Already in the register')
    const urls = trackUrls(page)
    await page.getByTestId('card-action-change').tap()
    await expect.poll(() => reached(urls, expected('change', 'c-1'))).toBe(true)
  })

  test('the Operations buttons on the card panel can be tapped', async ({ page }) => {
    await page.goto('/__harness/asset-card-actions')
    const button = page.getByTestId('card-op-handover')
    await expect(button).toBeVisible()
    const urls = trackUrls(page)
    await button.tap()
    await expect.poll(() => reached(urls, expected('handover', 'c-1'))).toBe(true)
  })
})
