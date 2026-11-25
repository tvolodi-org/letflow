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
    await expect(page.getByRole('heading', { name: 'platform.register_tenant', exact: true })).toBeVisible()
    await expect(page.getByTestId('error-boundary-panel')).toHaveCount(0)

    // An ACTIVE definition opens on its read-only diagram. The editable diagram is mounted only after this switch.
    await page.getByTestId('definition-view-edit').click()
    const editor = page.getByTestId('diagram-editor')
    await expect(editor).toBeVisible()
    await expect(editor.locator('.react-flow__node')).toHaveCount(8)
    await editor.getByTestId('rf__node-validate').click()
    await expect(page.getByTestId('edit-node-panel')).toBeVisible()
    await expect(page.getByTestId('error-boundary-panel')).toHaveCount(0)
  })
})
