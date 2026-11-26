import { assertLocalTarget } from './helpers'

/**
 * T-2947: one central guard for every browser and pipeline spec (most of them write data).
 * Runs once before the suite: the backend URL (`BPM_TEST_URL`) and the web base URL
 * (`E2E_BASE_URL`) must be local, else the run fails at start.
 * QA runs (gate-b-* specs, pilot-register-tenant-qa) are deliberate: they set E2E_ALLOW_REMOTE=1.
 */
export default function globalSetup(): void {
  assertLocalTarget(process.env.BPM_TEST_URL)
}
