/**
 * E2E -- BilimBaga study T3b batch 2: public certificate verification (`/verify/:handle`).
 *
 * Ported from BilimBaga's `certificates.spec.ts` (3 PORTABLE-NOW rows of
 * docs/migration/bilimbaga-e2e-new-files-classification.md). The page is VerifyCertificatePage,
 * outside ProtectedRoute, reading `GET /api/public/certificate/:handle`.
 *
 * Overlap with src/pages/__tests__/VerifyCertificatePage.test.tsx (jsdom): that file covers the
 * component with a mocked fetch. These run in a real browser through the real router, which is
 * what proves the route needs no login (no redirect to Keycloak/login) and that the browser sends
 * no Authorization header. The valid-fields and not-valid cases repeat the unit assertions on
 * purpose at that level; they are merged into one test each, not duplicated further.
 *
 * Adaptations: the response is a bare projection (`candidate_name`, `exam_title`, `score_pct`,
 * `issued_on`), not `{data:{valid,...}}`; any non-200 renders the one identical "not valid" view
 * (`verify-invalid`), there is no Retry or "unavailable" state. The API is stubbed with
 * page.route, so no live backend and no login are needed; the SPA still has to be served.
 */
import { expect, test } from '@playwright/test'

const CERT_API = /\/api\/public\/certificate\/[^/]+$/

const VALID = {
  candidate_name: 'E2E Certificate Holder',
  exam_title: 'E2E Certified Exam',
  score_pct: 87.5,
  issued_on: '2026-03-15',
}

test.describe('Public certificate verification (T3b batch 2)', () => {
  test('unknown / malformed code renders the not-valid view without an error body', async ({ page }) => {
    await page.route(CERT_API, (route) =>
      route.fulfill({ status: 404, contentType: 'application/json', body: JSON.stringify({ title: 'SECRET-DETAIL' }) }),
    )
    await page.goto('/verify/not-a-real-code')
    await expect(page.getByTestId('verify-invalid')).toBeVisible({ timeout: 20_000 })
    await expect(page.getByTestId('verify-invalid')).toContainText('Certificate not valid')
    await expect(page.getByTestId('verify-valid')).toHaveCount(0)
    await expect(page.getByText('SECRET-DETAIL')).toHaveCount(0)
  })

  test('is public: sends no Authorization header, does not redirect to login', async ({ page }) => {
    const apiRequests: Array<{ url: string; auth: string | undefined }> = []
    page.on('request', (r) => {
      if (r.url().includes('/api/')) apiRequests.push({ url: r.url(), auth: r.headers()['authorization'] })
    })
    await page.route(CERT_API, (route) =>
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(VALID) }),
    )
    await page.goto('/verify/E2E-PUBLIC-CODE')
    await expect(page.getByTestId('verify-valid')).toBeVisible({ timeout: 20_000 })
    await expect(page).toHaveURL(/\/verify\/E2E-PUBLIC-CODE$/)

    expect(apiRequests.some((r) => /\/api\/public\/certificate\/E2E-PUBLIC-CODE$/.test(r.url))).toBe(true)
    expect(apiRequests.filter((r) => r.auth)).toEqual([])
  })

  test('valid certificate shows holder, exam, score and issue date', async ({ page }) => {
    await page.route(CERT_API, (route) =>
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(VALID) }),
    )
    await page.goto('/verify/E2E-VALID-CODE')

    await expect(page.getByTestId('verify-valid')).toContainText('Certificate valid', { timeout: 20_000 })
    await expect(page.getByTestId('verify-candidate-name')).toHaveText('E2E Certificate Holder')
    await expect(page.getByTestId('verify-exam-title')).toHaveText('E2E Certified Exam')
    await expect(page.getByTestId('verify-score')).toHaveText('87.5%')
    await expect(page.getByTestId('verify-issued-on')).toHaveText('2026-03-15')
  })
})
