/** T-2607 (pilot gap G19): the designer opens the pilot's registration definition `platform.register_tenant`
 *  and adds the notification step -- the owner's acceptance item 6 of the "Register a tenant" pilot: "I add an
 *  e-mail notification after tenant registration by opening the process definition in the designer, not by asking
 *  for code".
 *
 *  It runs against the dev-only screen harness (/__harness/pd-register-tenant, no login, no backend), the way
 *  `process-designer-edit.e2e.spec.ts` does: the designer is a canvas, and the click-through is a pointer
 *  gesture jsdom cannot do. The screen carries the DOCUMENT the seed writes into the platform tenant
 *  (`Letflow.PlatformProcesses.Definition.graph()`), so the definition under the test is the pilot's one.
 *
 *  NO CI JOB RUNS THIS SPEC. The job "Stock browser e2e (playwright)" runs a FIXED list of specs
 *  (`gate-b-stock`, `gate-b-stock-print`, `gate-b-assets-print` -- `.github/workflows/stock-e2e.yml`), and the
 *  team does not edit the workflow. The proof is the local run:
 *
 *    cd web && npx playwright test tests/e2e/pilot-register-tenant-designer.e2e.spec.ts --config=playwright.config.ts
 */
import { expect, test, type Page } from '@playwright/test'

/** The canvas of the designer: one element per step of the graph. */
function nodes(page: Page) {
  return page.locator('.react-flow__node')
}

test.describe('the designer adds the notify step to platform.register_tenant', () => {
  test('the definition opens in the designer, a step is added and turned into a notification step', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 })
    await page.goto('/__harness/pd-register-tenant')

    // The definition is open: the pilot's registration definition, the chain of version 1.
    await expect(page.getByTestId('diagram-editor')).toBeVisible()
    await expect(page.getByTestId('page-header')).toContainText('platform.register_tenant')
    await expect(nodes(page)).toHaveCount(8)

    // A step is added: the toolbar's type is a service step, and the new step opens its panel.
    await page.getByTestId('edit-toolbar').locator('select').first().selectOption('SERVICE_TASK')
    await page.getByTestId('edit-add').click()
    await expect(nodes(page)).toHaveCount(9)

    const panel = page.getByTestId('edit-node-panel')
    await expect(panel).toBeVisible()
    await expect(panel).toContainText('n_service_task_1')

    // The step becomes a notification step: the panel offers the registered templates.
    await page.getByTestId('edit-use-notification').click()
    await expect(page.getByTestId('edit-notify-step')).toBeVisible()
    await expect(page.getByTestId('notify-step-editor')).toBeVisible()

    // The mail channel, the registered template of the pilot.
    await expect(page.getByTestId('notify-step-channel').locator('select')).toHaveValue('email')
    await expect(page.getByTestId('notify-step-template').locator('select')).toHaveValue('tenant_registered')

    // The recipient is a variable of the process, never a fixed address.
    await page.getByTestId('notify-step-recipient').fill('admin_email')
    await expect(page.getByTestId('notify-step-recipient')).toHaveValue('admin_email')

    // A value of the template is mapped to a variable of the process.
    await page.getByTestId('notify-value-source-tenant_name').locator('select').selectOption('var')
    await page.getByTestId('notify-value-var-tenant_name').fill('name')
    await expect(page.getByTestId('notify-value-var-tenant_name')).toHaveValue('name')

    // The definition is changed: the version may be saved (an ACTIVE definition becomes a NEW version).
    await expect(page.getByTestId('edit-save')).toBeEnabled()
  })

  // T-2805: the Guide entry of the designer page opens the guide inside the product (text from docs/designer-guide.md).
  test('the Guide entry opens the designer guide in a side panel', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 })
    await page.goto('/__harness/pd-register-tenant-page')
    await page.getByTestId('btn-guide').click()
    await expect(page.getByTestId('designer-guide-panel')).toBeVisible()
    await expect(page.getByTestId('guide-sec-notification-step')).toBeAttached()
    await page.getByTestId('designer-guide-close').click()
    await expect(page.getByTestId('designer-guide-panel')).toHaveCount(0)
  })
})
