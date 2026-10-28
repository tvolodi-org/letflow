/**
 * Question editor E2E tests — GH 3423 / REQ-612, port of BilimBaga's question-editor.spec.ts (7 tests).
 *
 * Signed in as the BilimBaga demo tenant's admin (holds ExamAuthoringWrite). Selectors adapted to
 * Letflow's labels: button name "Save Draft", the stem placeholder, labelled selects, and data-testid
 * values (`question-stem`, `question-type`, `question-shorttext-notice`, `question-option-polarity-<n>`).
 * Test 4 follows assumption A1: short text shows a fixed examiner-grading notice, not an
 * "auto-grading" section. Tests 6 and 7 create their own question through the editor first and are
 * not conditional on seeded data.
 *
 * These specs need the full stack and do not run on the engine host.
 */

import { test, expect, type Page } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

async function createQuestion(page: Page, stem: string) {
  await page.goto('/admin/questions/new', { waitUntil: 'domcontentloaded' })
  await page.getByPlaceholder('Write the question text').fill(stem)
  await page.getByLabel('Category').selectOption({ index: 1 })
  await page.getByLabel('Option text 1').fill('Right')
  await page.getByLabel('Option text 2').fill('Wrong')
  await page.getByRole('radio').first().check()
  await page.getByRole('button', { name: 'Save Draft' }).click()
  await expect(page).toHaveURL(/\/admin\/questions\/[^/]+\/edit$/, { timeout: 15_000 })
}

test.describe('Question editor (REQ-612)', () => {
  let token: string

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
  })

  test.beforeEach(async ({ page }) => {
    await loginWithToken(page, token)
  })

  test('1. renders the editor with a Save Draft button', async ({ page }) => {
    await page.goto('/admin/questions/new', { waitUntil: 'domcontentloaded' })
    await expect(page.getByRole('button', { name: 'Save Draft' })).toBeVisible({ timeout: 15_000 })
  })

  test('2. the type selector offers all five types', async ({ page }) => {
    await page.goto('/admin/questions/new', { waitUntil: 'domcontentloaded' })
    const values = await page
      .getByTestId('question-type')
      .locator('option')
      .evaluateAll((os) => os.map((o) => (o as HTMLOptionElement).value))
    expect(values).toEqual(['single', 'multiple', 'truefalse', 'likert', 'shorttext'])
  })

  test('3. shows the stem text area', async ({ page }) => {
    await page.goto('/admin/questions/new', { waitUntil: 'domcontentloaded' })
    await expect(page.getByPlaceholder('Write the question text')).toBeVisible({ timeout: 15_000 })
  })

  test('4. switching to short text changes the answer section', async ({ page }) => {
    await page.goto('/admin/questions/new', { waitUntil: 'domcontentloaded' })
    await expect(page.getByTestId('question-options')).toBeVisible({ timeout: 15_000 })
    await page.getByLabel('Question type').selectOption('shorttext')
    await expect(page.getByTestId('question-options')).toHaveCount(0)
    await expect(page.getByTestId('question-shorttext-notice')).toBeVisible()
  })

  test('5. switching to likert shows the polarity choice for each option', async ({ page }) => {
    await page.goto('/admin/questions/new', { waitUntil: 'domcontentloaded' })
    await page.getByLabel('Question type').selectOption('likert')
    await expect(page.getByTestId('question-option-polarity-0')).toBeVisible()
    await expect(page.getByTestId('question-option-polarity-1')).toBeVisible()
  })

  test('6. navigates to the edit page of a question created through the editor', async ({ page }) => {
    await createQuestion(page, `E2E nav ${Date.now()}`)
    await expect(page).toHaveURL(/\/admin\/questions\/[^/]+\/edit$/)
    await expect(page.getByRole('button', { name: 'Save Draft' })).toBeVisible()
  })

  test('7. pre-populates the stem of an existing question', async ({ page }) => {
    const stem = `E2E prefill ${Date.now()}`
    await createQuestion(page, stem)
    await page.reload({ waitUntil: 'domcontentloaded' })
    await expect(page.getByTestId('question-stem')).toHaveValue(stem, { timeout: 15_000 })
  })
})
