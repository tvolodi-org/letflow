/** T-1969: real inbox and API client, HTTP 409 refused through browser routing. */
import { expect, test } from '@playwright/test'
import { TASK_MESSAGES } from '../../src/pages/tasks/taskMessages'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

for (const lang of ['en', 'ru', 'kk'] as const) {
  for (const width of [1440, 390]) {
    test(`upgrade refusal wraps in ${lang} at ${width}`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 })
      await page.addInitScript(() => {
        Object.defineProperty(window, '__taskNativeFetch', { value: window.fetch.bind(window) })
      })
      await page.goto(`/__harness/tasks-upgrade-required?lang=${lang}`)
      await expect(page.getByTestId('task-error')).toHaveText(TASK_MESSAGES[lang].errModuleUpgrade)
      await page.getByTestId('toast-close').click()
      await page.route('**/api/v1/tasks/*/complete', (route) => route.fulfill({
        status: 409,
        contentType: 'application/problem+json',
        json: {
          type: 'https://letflow.dev/problems/module-upgrade-required',
          status: 409,
          code: 'upgrade_required',
        },
      }))
      await page.evaluate(() => {
        const fixtureFetch = window.fetch
        const nativeFetch = Reflect.get(window, '__taskNativeFetch') as typeof window.fetch
        window.fetch = (input, init) => String(input).endsWith('/complete')
          ? nativeFetch(input, init) : fixtureFetch(input, init)
      })
      const response = page.waitForResponse((r) => r.url().endsWith('/complete'))
      await page.getByTestId('task-complete-button').click()
      expect((await response).status()).toBe(409)
      const alert = page.getByTestId('task-error')
      const toast = page.getByTestId('toast-item')
      await expect(alert).toHaveText(TASK_MESSAGES[lang].errModuleUpgrade)
      await expect(toast).toContainText(TASK_MESSAGES[lang].errModuleUpgrade)
      await expect(alert).not.toContainText(TASK_MESSAGES[lang].errGeneric)
      for (const element of [alert, toast]) {
        const fits = await element.evaluate((el) => {
          const rect = el.getBoundingClientRect()
          return el.scrollWidth <= el.clientWidth && rect.left >= 0 && rect.right <= innerWidth
        })
        expect(fits).toBe(true)
      }
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    })
  }
}
