import { defineConfig, devices } from '@playwright/test'

const baseURL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4173'
// Derive the dev-server port from baseURL so the spawned server and the tests
// always agree — overriding E2E_BASE_URL alone would otherwise start the server
// on the default port while the tests hit the overridden one.
const e2ePort = new URL(baseURL).port || '4173'

export default defineConfig({
  testDir: './tests/e2e',
  testMatch: '**/*.e2e.spec.ts',
  // REQ-362 TEST-DESIGNER finding (WF02-REQ362-20260916): the original
  // real-exercise proof spec (req362-visual-regression.e2e.spec.ts's
  // "real-exercise proof" describe block) writes through to the REAL,
  // committed baseline directory (test/fixtures/uat/visual-baselines/) —
  // correct for the one-time manual proof ELIXIR-DEV ran to satisfy
  // AC-2/AC-3/AC-4/AC-5 for real (see docs/issues/ISS-0691.yaml), but wrong
  // for a suite that runs on every CI invocation: it would rewrite that
  // committed PNG/sidecar with a fresh timestamp on every run. `@manual`-tagged
  // tests are excluded from the default `npm run test:e2e` run via that
  // script's own `--grep-invert @manual` flag (NOT set here in config,
  // deliberately — a config-level grepInvert would conflict with
  // `test:e2e:manual`'s `--grep @manual`, since Playwright ANDs a CLI
  // `--grep` against any config-level `grepInvert` rather than one replacing
  // the other) and are run deliberately via `npm run test:e2e:manual`
  // instead. The formal, CI-safe regression coverage lives in the same
  // file's non-`@manual` describe block, against a disposable scratch
  // baseline directory.
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [['list']],
  // REQ-362: route every expect(page).toHaveScreenshot() reference image to
  // this project's own UAT visual-baseline convention (design §1.1) instead
  // of Playwright's default <test file>-snapshots/ layout (design §3.2's
  // "Chosen" reconciliation option). `{arg}` is whatever name string the
  // call site passes (see tests/support/visual-baseline.ts's snapshotName())
  // and already encodes company/scenario/step/EO/environment, so no further
  // segments are added here. No other spec in this project calls
  // toHaveScreenshot today (verified via `grep -rn toHaveScreenshot
  // tests/e2e` — zero hits before this requirement), so this is a safe,
  // project-wide default rather than a narrowly-scoped override.
  snapshotPathTemplate: '../test/fixtures/uat/visual-baselines/{arg}{ext}',
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  // E2E_NO_WEBSERVER=1: the web app is already deployed (QA runs of the GATE B specs, E2E_BASE_URL points at it).
  webServer: process.env.E2E_NO_WEBSERVER
    ? undefined
    : {
        command: `npm run dev -- --host 127.0.0.1 --port ${e2ePort}`,
        url: baseURL,
        reuseExistingServer: true,
        timeout: 120_000,
      },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
})
