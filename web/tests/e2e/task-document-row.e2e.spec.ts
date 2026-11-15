/** T-1994: the real inbox, hooks and API client against harness HTTP fixtures. */
import { expect, test } from '@playwright/test'

test.use({ video: 'off', launchOptions: process.env['LF_CHROMIUM'] ? { executablePath: process.env['LF_CHROMIUM'] } : {} })

for (const width of [1440, 390]) {
  test(`asset opening Approve row names its document, assignee and author at ${width}`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await page.goto('/__harness/tasks-assets-named?lang=en')
    const row = page.getByTestId('task-row')
    // This is a colleague's assignment, visible in All Tasks, not My Tasks.
    await expect(page.getByTestId('task-filter-count-me')).toHaveText('0')
    await expect(page.getByTestId('task-filter-count-all')).toHaveText('1')
    await expect(row.getByTestId('task-name')).toHaveText('Approve')
    await expect(row.getByTestId('task-instance-id')).toHaveText('AOP-2026-000001 - Asset opening')
    await expect(row).toContainText('WH-1 - Warehouse team')
    await expect(row.getByTestId('task-lines-summary')).toContainText('FA-0101 - Delivery van Gazelle Next × 1')
    await expect(row.getByTestId('task-assignee')).toHaveText('gate-b6-admin2')
    await expect(row.getByTestId('task-issuer')).toHaveText('Issued by: gate-b6-admin')
    await expect(row.getByTestId('task-doc-date')).toHaveText('Created: Nov 15, 2026 13:00')
    await expect(row).not.toContainText('Another user')
    expect(await page.locator('.lf-table-wrap').first().evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true)
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await row.click()
    await expect(page.getByTestId('instance-id')).toContainText('AOP-2026-000001')
    await expect(page.getByTestId('task-document-header')).toContainText('gate-b6-admin')
  })
}
