/** T-2738 (pilot gap G9c): the REAL page DefinitionEditorPage opens `platform.register_tenant` without the error
 *  boundary (React error 185, maximum update depth) and both panels render: the function picker of a platform_call
 *  step and the settings of the notify step.
 *
 *  jsdom cannot show this loop (the page tests of the same name stay green on the old code): it needs a real browser
 *  with measured React Flow layout. The spec drives the dev-only screen harness (/__harness/pd-register-tenant-page,
 *  no login, no backend), which mounts DefinitionEditorPage with write permission and the shipped graph.
 *  RED on the old `useDiagramText` (a new object on every render), GREEN on the memoised hook.
 *
 *  CI: workflow `.github/workflows/designer-e2e.yml` (job "Designer browser e2e (playwright)").
 *
 *    cd web && npx playwright test tests/e2e/pilot-register-tenant-page.e2e.spec.ts --config=playwright.config.ts
 */
import { expect, test } from '@playwright/test'

test.describe('the real designer page opens platform.register_tenant', () => {
  test('the diagram and the platform_call and notify panels render without the error boundary', async ({ page }) => {
    const errors: string[] = []
    page.on('pageerror', (e) => errors.push(e.message))
    await page.setViewportSize({ width: 1440, height: 900 })
    await page.goto('/__harness/pd-register-tenant-page')

    await page.getByTestId('definition-view-edit').click()
    const editor = page.getByTestId('diagram-editor')
    await expect(editor).toBeVisible()
    await expect(editor.locator('.react-flow__node')).toHaveCount(8)
    await expect(page.getByTestId('error-boundary-panel')).toHaveCount(0)

    // A platform_call step: the function picker.
    await editor.getByTestId('rf__node-validate').click()
    await expect(page.getByTestId('edit-platform-call')).toBeVisible()
    await expect(page.getByTestId('platform-call-function')).toBeVisible()
    await expect(page.getByTestId('error-boundary-panel')).toHaveCount(0)

    // The notify step: its settings.
    await editor.getByTestId('rf__node-notify').click()
    await expect(page.getByTestId('notify-step-editor')).toBeVisible()
    await expect(page.getByTestId('notify-step-template').locator('select')).toHaveValue('tenant_registered')

    // Give a render loop time to show itself, then check again.
    await page.waitForTimeout(1500)
    await expect(page.getByTestId('error-boundary-panel')).toHaveCount(0)
    expect(errors.filter((m) => /185|Maximum update depth/i.test(m))).toEqual([])
  })

  // T-2742 (pilot gap G9d): the shipped steps are named by their function, the read-only panel names the function
  // and the template, and a fresh open shows no "unsaved local draft" banner. The real-QA version is in
  // pilot-register-tenant-qa.e2e.spec.ts (BP-PLATFORM-01 step A).
  test('the steps carry the function names and a fresh open shows no draft banner', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 })
    await page.goto('/__harness/pd-register-tenant-page')
    const diagram = page.getByTestId('diagram-canvas')
    for (const fn of ['validate', 'create', 'provision', 'bind_realm', 'grant_first_admins', 'notify']) {
      await expect(diagram.getByTestId(`rf__node-${fn}`)).toContainText(fn)
    }
    await expect(diagram.getByTestId('rf__node-validate')).not.toContainText('Service task')
    await diagram.getByTestId('rf__node-validate').click()
    await expect(page.getByTestId('details-platform-function')).toContainText('tenant.validate')
    await diagram.getByTestId('rf__node-notify').click()
    await expect(page.getByTestId('details-notify-template')).toContainText('tenant_registered')
    await expect(page.getByTestId('draft-banner')).toHaveCount(0)
  })
})
