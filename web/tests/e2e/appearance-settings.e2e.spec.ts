/**
 * E2E -- BilimBaga study T3b, batch B2: appearance settings (`/admin/appearance`).
 *
 * Ported from the BilimBaga branding tests (docs/migration/bilimbaga-e2e-remeasure.md
 * section 4). Read-only checks of the form; nothing is saved, so no tenant setting
 * changes. Needs a live instance and an admin session with tenant.settings.manage;
 * it could not be run on the host that wrote it.
 */
import { expect, test } from '@playwright/test'
import { assertServiceReadiness, BPM_IDP_BASE_URL, BPM_IDP_CLIENT_ID, loginWithToken } from './helpers'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_TOKEN_URL = `${BPM_IDP_BASE_URL}/realms/bpm-default/protocol/openid-connect/token`

function envOrDefault(name: string, fallback: string): string {
  const value = process.env[name]
  return value && value.trim() ? value : fallback
}

test.describe('T3b B2 appearance settings', () => {
  test.beforeEach(async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)
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
    const token = ((await response.json()) as { access_token: string }).access_token
    await loginWithToken(page, token)
    await page.evaluate(() => {
      window.history.pushState({}, '', '/admin/appearance')
      window.dispatchEvent(new PopStateEvent('popstate'))
    })
    await page.waitForURL((url) => url.pathname === '/admin/appearance', { timeout: 10_000 })
  })

  test('the appearance form renders', async ({ page }) => {
    await expect(page.getByTestId('appearance-settings-page')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByRole('heading', { name: 'Appearance' })).toBeVisible()
    await expect(page.getByTestId('appearance-settings-form')).toBeVisible()
  })

  test('the primary colour field is a labelled colour input with a preview swatch', async ({ page }) => {
    const input = page.getByTestId('appearance-settings-primary-color-input')
    await expect(input).toBeVisible({ timeout: 15_000 })
    await expect(input).toHaveAttribute('type', 'color')
    await expect(page.getByLabel('Primary brand colour')).toBeVisible()
    await expect(page.getByTestId('appearance-settings-preview-swatch')).toBeVisible()
  })

  test('the Save button is present and enabled', async ({ page }) => {
    const save = page.getByTestId('appearance-settings-save').getByRole('button', { name: 'Save' })
    await expect(save).toBeVisible({ timeout: 15_000 })
    await expect(save).toBeEnabled()
  })
})
