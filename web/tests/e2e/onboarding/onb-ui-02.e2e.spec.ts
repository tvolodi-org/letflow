/**
 * ONB-UI-02 — Tenant registration form
 *
 * Tests:
 *   1. Submitting empty form shows validation errors on all required fields.
 *   2. Invalid slug format (contains uppercase / special chars) shows slug error.
 *   3. Invalid email (no @) shows email validation error.
 *   4. Hostname with protocol prefix shows hostname validation error.
 *   5. (removed, GH 2463: the wizard no longer collects redirect URIs)
 *   6. Valid form submission navigates to progress screen.
 *
 * No mocks. No MSW. Real Keycloak tokens. Real backend for test 6.
 * Verdict: screen shows the error message text or navigates to /progress.
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
} from '../pipeline'
import { assertServiceReadiness } from '../helpers'

const API_BASE_URL       = process.env.BPM_TEST_URL     ?? 'http://127.0.0.1:8080'

async function loginAsAdmin(page: Parameters<typeof loginWithToken>[0], request: Parameters<typeof getKeycloakToken>[0]) {
  const token = await getKeycloakToken(request)
  await loginWithToken(page, token)
  await navigateSpa(page, '/admin/onboarding/new')
  await page.waitForSelector('form', { timeout: 15_000 })
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test.describe('ONB-UI-02 — Tenant registration form', () => {

  test('submitting empty form shows validation errors on required fields', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)
    await loginAsAdmin(page, request)

    await page.screenshot({ path: 'scratch/onb-ui-02-empty-form.png', fullPage: true })

    // Click submit with all fields empty
    await page.getByRole('button', { name: /register tenant/i }).click()

    await page.screenshot({ path: 'scratch/onb-ui-02-empty-form-errors.png', fullPage: true })

    // Screen shows inline error messages for required fields
    // Use exact:true where the message text is a prefix of another error message
    await expect(page.getByText('Slug is required')).toBeVisible()
    await expect(page.getByText('Display name is required', { exact: true })).toBeVisible()
    await expect(page.getByText('Admin email is required')).toBeVisible()
    await expect(page.getByText('Admin username is required')).toBeVisible()
    await expect(page.getByText('Admin display name is required')).toBeVisible()
    await expect(page.getByText('Hostname is required')).toBeVisible()

    // Verify we stayed on the form (no navigation)
    expect(page.url()).toContain('/admin/onboarding/new')
  })

  test('invalid slug format shows slug validation error', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)
    await loginAsAdmin(page, request)

    // Fill slug with invalid value (uppercase + special char)
    await page.locator('#slug').fill('My Slug!')

    await page.getByRole('button', { name: /register tenant/i }).click()

    await page.screenshot({ path: 'scratch/onb-ui-02-slug-error.png', fullPage: true })

    // Screen shows the slug-format error message
    await expect(
      page.getByText('Slug may only contain lowercase letters, digits, and hyphens')
    ).toBeVisible()

    // Verify we stayed on the form
    expect(page.url()).toContain('/admin/onboarding/new')
  })

  test('invalid email shows email validation error', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)
    await loginAsAdmin(page, request)

    const uid = randomUUID().slice(0, 8)

    // Fill just enough fields so only email fails
    await page.locator('#slug').fill(`test-${uid}`)
    await page.locator('#display_name').fill(`Test Tenant ${uid}`)
    await page.locator('#admin_email').fill('notanemail')
    await page.locator('#hostname').fill(`tenant-${uid}.example.com`)

    await page.getByRole('button', { name: /register tenant/i }).click()

    await page.screenshot({ path: 'scratch/onb-ui-02-email-error.png', fullPage: true })

    // Screen shows the email error message
    await expect(page.getByText('Enter a valid email address')).toBeVisible()

    expect(page.url()).toContain('/admin/onboarding/new')
  })

  test('hostname with protocol prefix shows hostname validation error', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)
    await loginAsAdmin(page, request)

    const uid = randomUUID().slice(0, 8)

    await page.locator('#slug').fill(`test-${uid}`)
    await page.locator('#display_name').fill(`Test Tenant ${uid}`)
    await page.locator('#admin_email').fill(`admin@test-${uid}.example.com`)
    // Provide hostname WITH a protocol prefix — must be rejected
    await page.locator('#hostname').fill(`https://tenant-${uid}.example.com`)

    await page.getByRole('button', { name: /register tenant/i }).click()

    await page.screenshot({ path: 'scratch/onb-ui-02-hostname-error.png', fullPage: true })

    // Screen shows the hostname error message
    await expect(page.getByText('Enter a hostname only (no protocol or path)')).toBeVisible()

    expect(page.url()).toContain('/admin/onboarding/new')
  })

  test('valid form submission navigates to progress screen', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)
    await loginAsAdmin(page, request)

    const uid = randomUUID().slice(0, 8)
    const slug = `test-${uid}`

    // Fill all required fields with valid values
    await page.locator('#slug').fill(slug)
    await page.locator('#display_name').fill(`Test Tenant ${uid}`)
    await page.locator('#admin_email').fill(`admin@test-${uid}.example.com`)
    await page.locator('#hostname').fill(`tenant-${uid}.example.com`)

    await page.screenshot({ path: 'scratch/onb-ui-02-filled-form.png', fullPage: true })

    // Submit the form
    await page.getByRole('button', { name: /register tenant/i }).click()

    // Screen must show the progress page (URL changes to /progress)
    await page.waitForURL(/\/admin\/onboarding\/.+\/progress/, { timeout: 30_000 })

    await page.screenshot({ path: 'scratch/onb-ui-02-after-submit-progress.png', fullPage: true })

    // Screen shows the progress heading or spinner
    const progressHeading = page.getByRole('heading', { name: /onboarding in progress/i })
    const spinner = page.locator('[role="status"]')

    const headingVisible = await progressHeading.isVisible().catch(() => false)
    const spinnerVisible  = await spinner.isVisible().catch(() => false)

    expect(
      headingVisible || spinnerVisible,
      'Screen must show either "Onboarding in Progress" heading or a status spinner after form submission'
    ).toBe(true)
  })

})
