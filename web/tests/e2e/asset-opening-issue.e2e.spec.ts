/** T-1943: the real opening screen and API client, with browser-routed HTTP responses. No Keycloak stack required. */
import { expect, test } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

for (const width of [1440, 390]) {
  test(`T-1943 check then Issue sends a request and shows the issued opening at ${width}`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    // The harness provides the authenticated screen and lookup data. Preserve the native fetch so the action and
    // subsequent reads go through real browser requests (and Playwright routing), rather than the harness fetch.
    await page.addInitScript(() => {
      Object.defineProperty(window, '__openingNativeFetch', { value: window.fetch.bind(window), configurable: true })
    })
    await page.goto('/__harness/asset-document-op-draft?lang=en')
    await expect(page.getByTestId('document-header')).toBeVisible()
    const draft = await page.evaluate(async () => (await window.fetch('/api/v1/modules/assets/documents/op-draft')).json()) as Record<string, unknown>
    expect(draft).toMatchObject({ id: 'op-draft', kind: 'opening', state: 'draft', number: null })
    let current = draft
    let issues = 0
    const base = '/api/v1/modules/assets/documents'
    await page.route(`**${base}**`, async (route) => {
      const request = route.request()
      const path = new URL(request.url()).pathname
      if (request.method() === 'POST' && path === `${base}/op-draft/check`) {
        await route.fulfill({ json: { ok: true, header: [], lines: [] } })
      } else if (request.method() === 'POST' && path === `${base}/op-draft/issue`) {
        issues += 1
        expect(request.postData()).toBeNull()
        current = { ...draft, state: 'issued', number: 'AOP-2026-000001', issued_at: '2026-11-14T08:00:00Z' }
        await route.fulfill({ json: current })
      } else if (request.method() === 'GET' && path === `${base}/op-draft`) {
        await route.fulfill({ json: current })
      } else if (request.method() === 'GET' && path === base) {
        await route.fulfill({ json: { rows: [current], next_cursor: null } })
      } else {
        throw new Error(`Unexpected document request: ${request.method()} ${path}`)
      }
    })
    await page.evaluate(() => {
      window.fetch = Reflect.get(window, '__openingNativeFetch') as typeof window.fetch
      Reflect.deleteProperty(window, '__openingNativeFetch')
    })
    await page.getByRole('button', { name: 'Check all lines', exact: true }).click()
    await expect(page.getByTestId('check-result')).toHaveText('All lines pass the checks.')
    await expect(page.getByRole('link', { name: 'Open the inbox' })).toHaveCount(0)
    await page.getByTestId('document-actions').getByRole('button', { name: 'Issue', exact: true }).click()
    const dialog = page.getByRole('dialog')
    await expect(dialog).toContainText('A second person with posting rights approves it in Tasks')
    expect(issues).toBe(0)
    await expect(page.getByRole('link', { name: 'Open the inbox' })).toHaveCount(0)
    const response = page.waitForResponse(r => r.request().method() === 'POST' && r.url().endsWith('/op-draft/issue'))
    await dialog.getByRole('button', { name: 'Issue', exact: true }).click()
    expect((await response).status()).toBe(200)
    await expect(dialog).toHaveCount(0)
    await expect(page.getByTestId('document-header')).toContainText('AOP-2026-000001')
    await expect(page.locator('.lf-doc__bar')).toContainText('Issued')
    await expect(page.getByText('Waiting for a second person to approve the opening in Tasks.')).toBeVisible()
    await expect(page.getByText('The document is issued and waits for its post task in the inbox.')).toHaveCount(0)
    expect(issues).toBe(1)
    expect(current['state']).toBe('issued')
    await expect(page.getByRole('button', { name: 'Issue', exact: true })).toHaveCount(0)
  })
}
