/**
 * Pipeline: tenant-branding-applied (PW-14 / sys-shared-ui-component-layer)
 *
 * Drives `test/fixtures/uat/scenarios/platform/tenant-branding-applied.yaml`'s
 * `pipeline_test:` key for UAT-RUNNER, against the real screen REQ-383 built:
 * `web/src/pages/admin/AppearanceSettingsPage.tsx`, which calls REQ-382's
 * `PATCH /api/v1/tenant/settings` (merged, `lib/letflow/routers/tenant_settings.ex`).
 *
 * Four tests, one per acceptance-relevant outcome:
 *   - EO-001/AC1 (BLOCKER): a tenant admin applies a new brand colour, sees a
 *     confirmation, and the colour takes effect on the same screen without a
 *     page reload.
 *   - EO-003/AC2 (MAJOR): a contrast-refused colour shows the endpoint's
 *     plain-language message and leaves the previous colour visibly in effect.
 *   - EO-005 (MINOR, documented not fixed): the first-drawn frame shows the
 *     platform-default colour before swapping to the tenant's colour once
 *     BrandingProvider's post-paint useEffect resolves — see
 *     lib/letflow/design/req383-appearance-settings-screen.md §8 and the
 *     scenario's own EO-005 (`suggested_action: none`).
 *   - Contract regression guard (ISS-0887): a real GUI save through this
 *     screen must actually persist, not just report success client-side.
 *     None of the three tests above ever reads back a persisted value — they
 *     only read the client-side `--tenant-current` DOM custom property,
 *     which `applyBrandingColors` writes on the mutation's `onSuccess`
 *     regardless of whether the PATCH body was recognized by the router.
 *     That gap is exactly why ISS-0887 (the web client sending a
 *     `{settings: {brand_colors: {...}}}`-wrapped body against a router that
 *     expects the flat `{brand_colors: {...}}` shape) shipped uncaught: the
 *     wrapped body was silently treated as an unrecognized top-level key,
 *     the router no-op'd and returned 200, and every existing assertion in
 *     this file was satisfied anyway. The fourth test below closes that gap
 *     by asserting `GET /api/tenant-config` reflects the colour actually
 *     submitted through the GUI.
 *
 * Fixture colours mirror test/letflow/routers/tenant_settings_test.exs's own
 * REQ-382 AC2 test exactly, so this spec's pass/fail boundary matches the
 * backend's real WCAG 4.5:1 computation rather than an independently-guessed
 * value: `#1864AB` passes AA contrast against tokens.css's reference
 * backgrounds, `#228be6` passes the hex-format check but fails it
 * (~3.37:1/~3.56:1, pinned in color_contrast_test.exs).
 */

import { test, expect } from '@playwright/test'
import {
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  authHeaders,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential } from '../helpers'

const APP_BASE_URL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4173'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'

const PASSING_COLOR = '#1864ab' // matches tenant_settings_test.exs's AC2 setup colour
const FAILING_COLOR = '#228be6' // matches tenant_settings_test.exs's AC2 reject colour

async function readAppliedPrimary(page: import('@playwright/test').Page): Promise<string> {
  return page.evaluate(() =>
    getComputedStyle(document.documentElement).getPropertyValue('--tenant-current').trim(),
  )
}

async function seedBrandColor(request: import('@playwright/test').APIRequestContext, token: string, primary: string): Promise<void> {
  const resp = await request.patch(`${API_BASE_URL}/api/v1/tenant/settings`, {
    headers: authHeaders(token),
    data: { brand_colors: { primary } },
  })
  expect(resp.ok(), `seed PATCH /api/v1/tenant/settings failed: ${resp.status()} ${await resp.text()}`).toBeTruthy()
}

test.describe('Pipeline: tenant-branding-applied (PW-14)', () => {
  test('EO-001/AC1: tenant admin applies a new brand colour, sees confirmation and immediate effect', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )

    // Deterministic starting point, independent of any other test's order.
    await seedBrandColor(request, adminToken, PASSING_COLOR)

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/appearance')

    await expect(page.getByTestId('appearance-settings-page')).toBeVisible()

    const newColor = '#0b4f8a' // distinct passing colour, so the swap is observable
    await page.getByTestId('appearance-settings-primary-color-input').fill(newColor)
    await page.getByTestId('appearance-settings-save').getByRole('button').click()

    await expect(page.getByTestId('appearance-settings-confirmation')).toBeVisible({ timeout: 10_000 })

    // No page.reload() here, deliberately -- a reload would also happen to
    // show the right colour via BrandingProvider's own effect, which would
    // stop this test from proving AC1's actual "no full reload" requirement.
    // Reading the SAME --tenant-current custom property the preview swatch
    // itself renders from is the direct proof AC1 requires: "reflected
    // somewhere on the same screen" without a reload.
    await expect.poll(() => readAppliedPrimary(page)).toBe(newColor)
    await expect(page.getByTestId('appearance-settings-preview-swatch')).toBeVisible()

    await shot(page, 'tenant-branding-applied', 'ac1-confirmation-and-live-swatch')
  })

  test('EO-003/AC2: a contrast-refused colour is refused, shows the plain-language message, and leaves the previous colour in effect', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )

    // Fresh, known-good baseline via API -- independent of test 1's own
    // browser-driven state, so this test never depends on execution order.
    await seedBrandColor(request, adminToken, PASSING_COLOR)

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/appearance')

    const baselineColor = await readAppliedPrimary(page)
    expect(baselineColor.toLowerCase()).toBe(PASSING_COLOR)

    await page.getByTestId('appearance-settings-primary-color-input').fill(FAILING_COLOR)
    await page.getByTestId('appearance-settings-save').getByRole('button').click()

    const errorBanner = page.getByTestId('appearance-settings-error')
    await expect(errorBanner).toBeVisible({ timeout: 10_000 })
    const errorText = (await errorBanner.textContent()) ?? ''
    expect(errorText.length).toBeGreaterThan(0)
    // Belt-and-braces against EO-003's "never a raw validation-error blob".
    expect(errorText).not.toMatch(/%\{|Ecto\.Changeset|"errors":|changeset/i)
    expect(errorText).toMatch(/4\.5|contrast|WCAG/i)

    // The previous colour remains in effect -- nothing overwrote the DOM
    // custom property on this failed request.
    await expect.poll(() => readAppliedPrimary(page)).toBe(baselineColor)
    await expect(page.getByTestId('appearance-settings-confirmation')).toHaveCount(0)

    await shot(page, 'tenant-branding-applied', 'ac2-contrast-refused-error-and-unchanged-colour')
  })

  test('EO-005: first-paint vs. settled-frame colour flash is present and documented (MINOR, not fixed)', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )

    // Ensure the tenant has a non-platform-default colour applied before the
    // fresh session below loads -- otherwise there is nothing to flash from.
    await seedBrandColor(request, adminToken, PASSING_COLOR)

    // Fresh browser session/page (new addInitScript registration + goto),
    // matching the scenario's own step 2 ("signs in fresh in a new browser
    // session, watching the screen from the very first moment it appears").
    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/tasks')

    // Capture as close to first paint as Playwright allows: immediately
    // after the navigation settles, before waiting on any branding-dependent
    // selector or the fetchTenantConfig round-trip. This is EXPECTED to show
    // the platform-default colour (BrandingProvider's useEffect runs after
    // first paint; main.tsx does not await the pre-warmed fetchTenantConfig
    // promise -- lib/letflow/design/req383-appearance-settings-screen.md's
    // EO-005 note).
    await page.goto(`${APP_BASE_URL}/tasks`, { waitUntil: 'domcontentloaded' })
    const firstPaintColor = await readAppliedPrimary(page)
    await shot(page, 'tenant-branding-applied', 'eo005-first-paint')

    // Wait for the branding fetch to settle: poll until the computed colour
    // stops being the platform default (or, if it never was, until it
    // stabilises at the tenant colour) -- then capture the settled frame.
    await expect.poll(() => readAppliedPrimary(page), { timeout: 10_000 }).toBe(PASSING_COLOR)
    const settledColor = await readAppliedPrimary(page)
    await shot(page, 'tenant-branding-applied', 'eo005-settled-frame')

    // This test PINS the known, accepted MINOR flash -- it asserts the flash
    // EXISTS, not that it's fixed. A future fix to EO-005 would need to flip
    // this assertion's polarity, not just delete the test.
    expect(
      firstPaintColor !== settledColor,
      `EO-005 flash expected: first-paint colour ("${firstPaintColor}") should differ from the settled-frame colour ("${settledColor}") ` +
      'per BrandingProvider.tsx applying branding post-paint. If this now passes with equal colours, EO-005 may have been fixed -- ' +
      'update this test and the scenario fixture/severity accordingly rather than deleting the assertion.',
    ).toBe(true)
  })

  test('contract: GET /api/tenant-config reflects the colour saved via the GUI (regression guard for ISS-0887)', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )

    // Deterministic starting point, independent of any other test's order.
    await seedBrandColor(request, adminToken, PASSING_COLOR)

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/appearance')

    // A fourth, distinct passing colour -- not PASSING_COLOR, not EO-001's
    // '#0b4f8a' -- so this test's own state is unambiguous in any
    // shared-tenant test-order diagnosis.
    const contractColor = '#0a3d91'
    await page.getByTestId('appearance-settings-primary-color-input').fill(contractColor)
    await page.getByTestId('appearance-settings-save').getByRole('button').click()

    // Same client-side-success proof EO-001 already uses -- establishes the
    // GUI itself believes the save succeeded, the same starting condition
    // that let ISS-0887 go uncaught.
    await expect(page.getByTestId('appearance-settings-confirmation')).toBeVisible({ timeout: 10_000 })

    // The assertion absent from every other test in this file: read back the
    // actual persisted value through the real read-side endpoint. With the
    // wrapped-body bug in place, this call would return PASSING_COLOR (or
    // the platform default), not contractColor, because nothing persisted.
    const configResp = await request.get(`${API_BASE_URL}/api/tenant-config?realm=bpm-default`)
    expect(configResp.ok(), `GET /api/tenant-config failed: ${configResp.status()} ${await configResp.text()}`).toBeTruthy()
    const configBody = await configResp.json()
    expect(configBody.branding.brand_colors.primary.toLowerCase()).toBe(contractColor.toLowerCase())
  })
})
