/**
 * Question Bank admin E2E tests — REQ-347 port of BilimBaga's question-bank.spec.ts, extended by
 * GH 3423 / REQ-612.
 *
 * PORT, NOT TRANSLITERATION: BilimBaga's tests target its own bespoke `/admin/questions` screen
 * (heading + table, New-Question button that navigates to a dedicated `/admin/questions/new` editor,
 * a search box, difficulty badges, Import/AI-Generate buttons).
 *
 *   Tests 1 and 2 (REQ-347) cover the generic `/admin/bilimbaga/question` screen (`EntityCrudPage`,
 *   REQ-343): the list renders, and the create action exists.
 *
 *   Tests 8 to 11 (REQ-612) cover the dedicated bank page `/admin/questions` (QuestionBankPage):
 *   8 the New Question action opens the editor, 9 difficulty badges by data-testid, 10 a search term
 *   filters the list, 11 a search that matches nothing shows the empty state. Each of 9 and 10
 *   creates its own question through the editor first, so none depends on seeded data.
 *
 *   The source row "Import and AI Generate buttons" is split to REQ-600 and is not built.
 *
 * Authentication: `web/tests/e2e/helpers.ts`'s `getKeycloakToken`/`loginWithToken`. These specs need
 * the full stack and do not run on the engine host.
 */

import { test, expect, type Page } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

const QUESTION_ROUTE = '/admin/bilimbaga/question'

async function gotoQuestions(page: Page) {
  await page.goto(QUESTION_ROUTE, { waitUntil: 'domcontentloaded' })
  await expect(page.getByTestId('entity-crud-page')).toBeVisible({ timeout: 15_000 })
  await expect(page.getByTestId('entity-crud-page')).toHaveAttribute('data-entity-type', 'question')
}

async function createQuestion(page: Page, stem: string, difficulty: string) {
  await page.goto('/admin/questions/new', { waitUntil: 'domcontentloaded' })
  await page.getByPlaceholder('Write the question text').fill(stem)
  await page.getByLabel('Difficulty').selectOption(difficulty)
  await page.getByLabel('Category').selectOption({ index: 1 })
  await page.getByLabel('Option text 1').fill('Right')
  await page.getByLabel('Option text 2').fill('Wrong')
  await page.getByRole('radio').first().check()
  await page.getByRole('button', { name: 'Save Draft' }).click()
  await expect(page).toHaveURL(/\/admin\/questions\/[^/]+\/edit$/, { timeout: 15_000 })
}

async function searchFor(page: Page, term: string) {
  await page.goto('/admin/questions', { waitUntil: 'domcontentloaded' })
  await page.getByPlaceholder('Search by question text').fill(term)
  await page.getByRole('button', { name: 'Search' }).click()
}

test.describe('Question Bank admin (REQ-347 port onto /admin/bilimbaga/question)', () => {
  let token: string

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
  })

  test.beforeEach(async ({ page }) => {
    await loginWithToken(page, token)
  })

  test('displays the question bank list without error', async ({ page }) => {
    await gotoQuestions(page)
    await expect(page.getByTestId('data-table')).toBeVisible()
    await expect(page.locator('body')).not.toContainText(/unexpected error|something went wrong/i)
  })

  test('shows the New Question button', async ({ page }) => {
    await gotoQuestions(page)
    await expect(page.getByTestId('entity-create-action')).toBeVisible()
  })

  test('8. the New Question action opens the editor', async ({ page }) => {
    await page.goto('/admin/questions', { waitUntil: 'domcontentloaded' })
    await page.getByTestId('question-new').click()
    await expect(page).toHaveURL(/\/admin\/questions\/new$/)
    await expect(page.getByRole('button', { name: 'Save Draft' })).toBeVisible()
  })

  test('9. difficulty badges are shown for the listed questions', async ({ page }) => {
    const stem = `E2E badge ${Date.now()}`
    await createQuestion(page, stem, 'hard')
    await searchFor(page, stem)
    await expect(page.locator('table tbody tr')).toHaveCount(1)
    await expect(page.getByTestId('difficulty-badge-hard')).toBeVisible()
  })

  test('10. a search term filters the list', async ({ page }) => {
    const stem = `E2E search ${Date.now()}`
    await createQuestion(page, stem, 'easy')
    await searchFor(page, stem)
    await expect(page.locator('table tbody tr')).toHaveCount(1)
    await expect(page.locator('table tbody')).toContainText(stem)
  })

  test('11. a search that matches nothing shows the empty state', async ({ page }) => {
    await searchFor(page, `no-such-question-${Date.now()}`)
    await expect(page.getByTestId('question-bank-empty')).toBeVisible()
    await expect(page.locator('table tbody tr')).toHaveCount(0)
  })
})
