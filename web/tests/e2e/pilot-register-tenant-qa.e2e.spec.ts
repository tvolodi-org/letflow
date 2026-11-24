/** T-2744 (pilot G10a, step A4 of the UAT scenario BP-PLATFORM-01): the designer page of the shipped definition
 *  platform.register_tenant opens on a real build (QA): no error boundary, eight nodes, a node click opens the panel.
 *
 *  The UAT runner cannot drive a browser, so this is the one browser check of step A. It needs a signed-in
 *  platform administrator, so it runs only when the operator gives the page and a saved browser state:
 *
 *    QA_DESIGNER_URL=https://qa.bizdala.com/definitions/<id> QA_STORAGE_STATE=/abs/path/state.json \
 *      npx playwright test tests/e2e/pilot-register-tenant-qa.e2e.spec.ts --config=playwright.config.ts
 *
 *  <id> is the `definition_id` that step A1 of the scenario saves. Without the two variables the test is skipped.
 *  NO CI JOB RUNS THIS SPEC (the stock e2e job runs a fixed list of specs).
 */
import { expect, test } from '@playwright/test'

const url = process.env.QA_DESIGNER_URL
const state = process.env.QA_STORAGE_STATE

test.describe('BP-PLATFORM-01 A4: the designer page of platform.register_tenant on QA', () => {
  test.skip(!url || !state, 'QA_DESIGNER_URL and QA_STORAGE_STATE are not set')
  test.use({ storageState: state })

  test('opens without an error boundary, shows eight nodes, a node click opens the panel', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 })
    await page.goto(url as string)
    await expect(page.getByTestId('diagram-editor')).toBeVisible()
    await expect(page.getByTestId('page-header')).toContainText('platform.register_tenant')
    await expect(page.getByText(/something went wrong/i)).toHaveCount(0)
    const nodes = page.locator('.react-flow__node')
    await expect(nodes).toHaveCount(8)
    await nodes.nth(1).click()
    await expect(page.getByTestId('edit-node-panel').or(page.getByTestId('node-panel'))).toBeVisible()
  })
})
