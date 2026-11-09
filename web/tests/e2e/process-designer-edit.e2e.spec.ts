/** T-1563 (process designer, slice 2): a real pointer drag from a step's handle to another step's handle creates a
 *  connection (H3). jsdom cannot do this. It runs against the dev-only screen harness (/__harness/<screen>, no login, no
 *  backend). Not a CI gate (ci.yml does not run the general e2e suite); its proof is the local run:
 *    cd web && npx playwright test tests/e2e/process-designer-edit.e2e.spec.ts --config=playwright.config.ts */
import { expect, test, type Page } from '@playwright/test'

async function center(page: Page, selector: string) {
  const box = await page.locator(selector).first().boundingBox()
  if (!box) throw new Error(`no box for ${selector}`)
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 }
}

test.describe('process designer edit: pointer connection', () => {
  test('dragging from a source handle to a target handle adds a connection; a self-loop adds none', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 })
    await page.goto('/__harness/pd-edit')
    await expect(page.getByTestId('diagram-editor')).toBeVisible()
    const edges = page.locator('.react-flow__edge')
    await expect(edges.first()).toBeAttached()
    const before = await edges.count()

    // submit → approve is not drawn yet in the fixture (submit → check → amount → approve).
    const src = await center(page, '.react-flow__node[data-id="submit"] .react-flow__handle.source')
    const dst = await center(page, '.react-flow__node[data-id="approve"] .react-flow__handle.target')
    await page.mouse.move(src.x, src.y)
    await page.mouse.down()
    await page.mouse.move((src.x + dst.x) / 2, (src.y + dst.y) / 2, { steps: 8 })
    await page.mouse.move(dst.x, dst.y, { steps: 8 })
    await page.mouse.up()

    await expect(edges).toHaveCount(before + 1)
    await expect(page.getByTestId('edit-live')).toContainText('Connected')

    // the same drag onto the same node (a self-loop) is refused and says so
    const own = await center(page, '.react-flow__node[data-id="approve"] .react-flow__handle.target')
    const ownSrc = await center(page, '.react-flow__node[data-id="approve"] .react-flow__handle.source')
    await page.mouse.move(ownSrc.x, ownSrc.y)
    await page.mouse.down()
    await page.mouse.move(own.x, own.y, { steps: 8 })
    await page.mouse.up()
    await expect(edges).toHaveCount(before + 1)

    // undo (keyboard) removes the new connection
    await page.getByTestId('diagram-editor').press('Control+z')
    await expect(edges).toHaveCount(before)
  })
})
