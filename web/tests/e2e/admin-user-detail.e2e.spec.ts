/**
 * E2E -- BilimBaga study T3b, batch B1: admin user detail (`/admin/users/:userId`).
 *
 * Ported from the BilimBaga corpus (docs/migration/bilimbaga-e2e-remeasure.md section 4).
 * Adapted: deactivation lives on the detail page in Letflow (no row-level button).
 * Complements f5-admin-users.e2e.spec.ts (ADM-UI-03 edits several fields at once and
 * ADM-UI-04 only confirms; this file covers the Cancel path, the dialog itself, the
 * pre-populated display name and a display-name-only save with a reload).
 *
 * Needs a live instance (backend + Keycloak + admin session); it could not be run on
 * the host that wrote it.
 */
import { expect, test, type APIRequestContext, type Page } from '@playwright/test'
import { randomUUID } from 'crypto'
import { assertServiceReadiness, BPM_IDP_BASE_URL, BPM_IDP_CLIENT_ID, loginWithToken } from './helpers'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_TOKEN_URL = `${BPM_IDP_BASE_URL}/realms/bpm-default/protocol/openid-connect/token`

function envOrDefault(name: string, fallback: string): string {
  const value = process.env[name]
  return value && value.trim() ? value : fallback
}

function jwtSubject(token: string): string {
  const parts = token.split('.')
  if (parts.length !== 3) throw new Error('Invalid JWT format')
  const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')) as { sub?: string }
  if (!payload.sub) throw new Error('JWT does not contain sub claim')
  return payload.sub
}

async function getAdminToken(request: APIRequestContext): Promise<string> {
  const response = await request.post(KEYCLOAK_TOKEN_URL, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: {
      client_id: BPM_IDP_CLIENT_ID,
      username: envOrDefault('BPM_E2E_ADMIN_USERNAME', 'admin-user'),
      password: envOrDefault('BPM_E2E_ADMIN_PASSWORD', 'admin-pass'),
      grant_type: 'password',
    },
  })
  if (!response.ok()) throw new Error(`Failed to fetch token (${response.status()})`)
  return ((await response.json()) as { access_token: string }).access_token
}

async function navigateSpa(page: Page, targetPath: string): Promise<void> {
  await page.evaluate((nextPath) => {
    window.history.pushState({}, '', nextPath)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, { timeout: 10_000 })
}

async function createUserFixture(page: Page, label: string, displayName: string): Promise<{ id: string }> {
  const fixtureId = randomUUID()
  const username = `t3b-${label}-${fixtureId.slice(0, 12)}`
  await navigateSpa(page, '/admin/users')
  await page.getByTestId('admin-users-new').click()
  await page.getByLabel('Username').fill(username)
  await page.getByLabel('Display name').fill(displayName)
  await page.getByLabel('Email').fill(`${username}@example.com`)
  await page.getByLabel('Password').fill(`pw-${fixtureId.slice(0, 16)}`)
  await page.getByRole('button', { name: 'Create user' }).click()
  await page.waitForURL(/\/admin\/users\/.+/, { timeout: 15_000 })
  const id = (page.url().split('/admin/users/')[1] ?? '').split('?')[0].split('#')[0]
  if (!id) throw new Error('Failed to create fixture user (missing created id from URL)')
  return { id }
}

async function cleanupUserFixture(request: APIRequestContext, token: string, userId: string): Promise<void> {
  const response = await request.patch(`${API_BASE_URL}/api/v1/admin/users/${userId}`, {
    headers: { Authorization: `Bearer ${token}`, 'x-bpm-user-id': jwtSubject(token) },
    data: { status: 'INACTIVE', is_active: false },
  })
  if (!response.ok() && response.status() !== 404) {
    throw new Error(`Failed to cleanup fixture user ${userId} (${response.status()})`)
  }
}

test.describe('T3b B1 admin user detail', () => {
  let adminToken = ''
  let fixtureId = ''

  test.beforeEach(async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)
    adminToken = await getAdminToken(request)
    await loginWithToken(page, adminToken)
  })

  test.afterEach(async ({ request }) => {
    if (fixtureId) await cleanupUserFixture(request, adminToken, fixtureId)
    fixtureId = ''
  })

  test('the Deactivate button is visible for an active user', async ({ page }) => {
    fixtureId = (await createUserFixture(page, 'btn', 'T3b Button')).id
    await navigateSpa(page, `/admin/users/${fixtureId}`)
    await expect(page.getByTestId('admin-user-detail-form')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('admin-user-status')).toHaveValue('ACTIVE')
    await expect(page.getByTestId('admin-user-deactivate')).toBeVisible()
    await expect(page.getByTestId('admin-user-deactivate').getByRole('button')).toBeEnabled()
  })

  test('the Deactivate button opens the confirmation dialog with Cancel and Deactivate', async ({ page }) => {
    fixtureId = (await createUserFixture(page, 'dlg', 'T3b Dialog')).id
    await navigateSpa(page, `/admin/users/${fixtureId}`)
    await expect(page.getByTestId('admin-user-detail-form')).toBeVisible({ timeout: 15_000 })

    await page.getByTestId('admin-user-deactivate').click()
    const dialog = page.getByRole('dialog', { name: 'Deactivate user' })
    await expect(dialog).toBeVisible()
    await expect(dialog.getByRole('heading', { name: 'Deactivate user' })).toBeVisible()
    await expect(dialog.getByText('Reason (optional)')).toBeVisible()
    await expect(dialog.getByRole('button', { name: 'Cancel' })).toBeVisible()
    await expect(dialog.getByRole('button', { name: 'Deactivate', exact: true })).toBeVisible()
  })

  test('Cancel closes the dialog and keeps the user ACTIVE', async ({ page }) => {
    fixtureId = (await createUserFixture(page, 'cancel', 'T3b Cancel')).id
    await navigateSpa(page, `/admin/users/${fixtureId}`)
    await expect(page.getByTestId('admin-user-detail-form')).toBeVisible({ timeout: 15_000 })

    await page.getByTestId('admin-user-deactivate').click()
    const dialog = page.getByRole('dialog', { name: 'Deactivate user' })
    await dialog.getByRole('button', { name: 'Cancel' }).click()
    await expect(dialog).toHaveCount(0)
    await expect(page.getByTestId('admin-user-status')).toHaveValue('ACTIVE')

    // Persisted state, not just the local form value.
    await page.reload()
    await expect(page.getByTestId('admin-user-detail-form')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('admin-user-status')).toHaveValue('ACTIVE')
  })

  test('confirming with a reason deactivates the user and the status persists', async ({ page }) => {
    fixtureId = (await createUserFixture(page, 'confirm', 'T3b Confirm')).id
    await navigateSpa(page, `/admin/users/${fixtureId}`)
    await expect(page.getByTestId('admin-user-detail-form')).toBeVisible({ timeout: 15_000 })

    await page.getByTestId('admin-user-deactivate').click()
    const dialog = page.getByRole('dialog', { name: 'Deactivate user' })
    await dialog.getByLabel('Reason (optional)').fill('T3b e2e reason')
    await dialog.getByRole('button', { name: 'Deactivate', exact: true }).click()
    await expect(dialog).toHaveCount(0, { timeout: 10_000 })
    await expect(page.getByTestId('admin-user-status')).toHaveValue('INACTIVE', { timeout: 10_000 })

    await page.reload()
    await expect(page.getByTestId('admin-user-detail-form')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('admin-user-status')).toHaveValue('INACTIVE')
  })

  test('the display name field is pre-populated with the stored value', async ({ page }) => {
    fixtureId = (await createUserFixture(page, 'prefill', 'T3b Prefilled Name')).id
    await navigateSpa(page, `/admin/users/${fixtureId}`)
    await expect(page.getByTestId('admin-user-detail-form')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('admin-user-display-name')).toHaveValue('T3b Prefilled Name')
    await expect(page.getByTestId('admin-user-username')).toBeDisabled()
  })

  test('saving a changed display name persists across a reload', async ({ page }) => {
    fixtureId = (await createUserFixture(page, 'rename', 'T3b Before')).id
    await navigateSpa(page, `/admin/users/${fixtureId}`)
    await expect(page.getByTestId('admin-user-detail-form')).toBeVisible({ timeout: 15_000 })

    await page.getByTestId('admin-user-display-name').fill('T3b After')
    await page.getByTestId('admin-user-save').click()
    await expect(page.getByTestId('admin-user-submit-message')).toContainText('Saved', { timeout: 10_000 })

    await page.reload()
    await expect(page.getByTestId('admin-user-display-name')).toHaveValue('T3b After', { timeout: 15_000 })
  })
})
