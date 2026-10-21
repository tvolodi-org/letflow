/**
 * Shared E2E test helpers — login via Keycloak token injection.
 *
 * Since the token-based login page has been removed, tests authenticate by:
 *   1. Obtaining a JWT from Keycloak's token endpoint (password grant)
 *   2. Storing the session in sessionStorage via addInitScript
 *   3. The app reads it on startup and restores the session
 */

import type { Page, APIRequestContext } from '@playwright/test'
import { ACCESS_FIXTURES, type AccessFixtureName } from '../../src/auth/access/fixtures'

export function normalizeIdpBaseUrl(raw: string | undefined): string {
  const fallback = 'http://localhost:8082'
  const value = (raw ?? fallback).trim()
  if (value.length == 0) return fallback
  // Keep issuer/authority host consistent with backend expectations.
  return value.replace('://127.0.0.1', '://localhost').replace(/\/$/, '')
}

// Use localhost (not 127.0.0.1) so that issued JWT tokens have iss=http://localhost:8082/...
// which matches the backend's configured BPM_IDP_BASE_URL.
export const BPM_IDP_BASE_URL =
  normalizeIdpBaseUrl(process.env.BPM_IDP_BASE_URL)
const KEYCLOAK_TOKEN_URL = `${BPM_IDP_BASE_URL}/realms/bpm-default/protocol/openid-connect/token`
export const BPM_IDP_CLIENT_ID = process.env.BPM_IDP_CLIENT_ID ?? 'letflow-web'

/**
 * Resolve a credential from an env var, falling back to a local-dev literal.
 *
 * Returns `process.env[envVarName]` when set and non-empty (trimmed);
 * otherwise returns `localDevFallback` unchanged. An unset env var is the
 * expected local-dev case, not an error — this never throws.
 */
export function resolveCredential(envVarName: string, localDevFallback: string): string {
  const raw = process.env[envVarName]
  const value = (raw ?? '').trim()
  if (value.length == 0) return localDevFallback
  return value
}

const TRANSIENT_NETWORK_ERROR = /ECONNRESET|ECONNREFUSED|EPIPE|socket hang up/i

/**
 * ISS-0921 (Q-912): the Windows/WSL2 host intermittently resets the first
 * connection to `localhost:8094` (Keycloak) because `wslrelay.exe` owns
 * `::1:8094` while Docker publishes `0.0.0.0`; the next attempt succeeds.
 * The URL must stay `localhost` (JWT `iss` must match the backend), so the
 * spec side cannot pick IPv4 -- retry the transient connection-level failure
 * instead. Only thrown network errors are retried; any HTTP response
 * (including 4xx/5xx) is returned to the caller untouched.
 */
export async function retryTransientNetworkError<T>(
  attempt: () => Promise<T>,
  retries = 3,
  delayMs = 500,
): Promise<T> {
  for (let n = 0; ; n++) {
    try {
      return await attempt()
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      if (n >= retries || !TRANSIENT_NETWORK_ERROR.test(message)) throw err
      await new Promise((resolve) => setTimeout(resolve, delayMs * (n + 1)))
    }
  }
}

/** Obtain a JWT access token from Keycloak via password grant. */
export async function getKeycloakToken(
  request: APIRequestContext,
  username = 'admin-user',
  password = resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
): Promise<string> {
  const response = await retryTransientNetworkError(() =>
    request.post(KEYCLOAK_TOKEN_URL, {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      form: {
        client_id: BPM_IDP_CLIENT_ID,
        username,
        password,
        grant_type: 'password',
      },
    }),
  )

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(
      `Keycloak token request failed (${response.status()}): ${body}\n` +
      `Ensure Keycloak is running at ${KEYCLOAK_TOKEN_URL.replace('/protocol/openid-connect/token', '')}\n` +
      `and user ${username} exists.`,
    )
  }

  const body = await response.json() as { access_token: string }
  return body.access_token
}

/**
 * Obtain a JWT access token from Keycloak's MASTER realm via the built-in
 * admin-cli client (password grant). Distinct from `getKeycloakToken`, which
 * authenticates against the `bpm-default`/tenant realm as an application user.
 *
 * Username/password resolve via `resolveCredential`:
 *   - `KC_ADMIN_USER`     (fallback: 'admin')
 *   - `KC_ADMIN_PASSWORD` (fallback: 'admin')
 *
 * Throws (does not return a boolean/undefined) when the token request does
 * not return 2xx.
 */
export async function getMasterAdminToken(request: APIRequestContext): Promise<string> {
  const masterTokenUrl = `${BPM_IDP_BASE_URL}/realms/master/protocol/openid-connect/token`
  const response = await request.post(masterTokenUrl, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: {
      client_id: 'admin-cli',
      username: resolveCredential('KC_ADMIN_USER', 'admin'),
      password: resolveCredential('KC_ADMIN_PASSWORD', 'admin'),
      grant_type: 'password',
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Keycloak master token request failed: ${response.status()} ${body}`)
  }

  const body = await response.json() as { access_token: string }
  return body.access_token
}

/** Decode a JWT payload without verification. */
function decodeJwtPayload(token: string): { sub: string; preferred_username?: string; name?: string; email?: string } {
  return JSON.parse(Buffer.from(token.split('.')[1], 'base64').toString('utf-8'))
}

/**
 * Answer GET /api/v1/me/access with a fixture instead of the real server, so a spec can run as a
 * given role without a token for it. Call BEFORE page.goto(). The default stays the real server.
 */
export async function mockMeAccess(page: Page, fixture: AccessFixtureName): Promise<void> {
  await page.route('**/api/v1/me/access', route =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(ACCESS_FIXTURES[fixture]) }),
  )
}

/**
 * Log in to the app by injecting a Keycloak token via sessionStorage bridge.
 *
 * This must be called BEFORE page.goto(). It uses addInitScript to write the
 * session to sessionStorage before any page JS runs, so the app's AuthProvider
 * picks it up on initial render and treats the user as authenticated.
 *
 * Usage:
 *   const token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
 *   await loginWithToken(page, token)
 *   // page is now authenticated at /
 */
export async function loginWithToken(page: Page, token: string): Promise<void> {
  const payload = decodeJwtPayload(token)
  const displayName =
    payload.preferred_username ??
    payload.name ??
    payload.email ??
    payload.sub

  // Set up a script that runs before any page JS to inject the session
  await page.addInitScript((args: { token: string; displayName: string }) => {
    const session = {
      token: args.token,
      display_name: args.displayName,
      loginSource: 'oidc' as const,
    }
    sessionStorage.setItem('__e2e_session', JSON.stringify(session))
  }, { token, displayName })

  // Navigate to the app root
  await page.goto('/', { waitUntil: 'domcontentloaded' })

  // Wait for the app shell to render (proves we're authenticated)
  await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 }).catch(() => {
    // Fallback: just wait for any main content to appear
  })
}

/**
 * Log in to the app by driving Keycloak's real hosted-login-page redirect.
 *
 * Unlike `loginWithToken`, this does NOT inject a session via
 * `addInitScript`/`sessionStorage` — it navigates with no pre-existing
 * session, waits for the app's own auth guard to redirect off-origin to
 * Keycloak, fills Keycloak's own login form, submits, and waits for the
 * browser to land back on `expectedUrl` after the app's `/auth/callback`
 * exchange completes. This is what actually exercises
 * `OidcCallbackPage.tsx`'s role-conditional `navigate()` — session injection
 * structurally cannot reach that code path (see ISS-0712).
 *
 * NOTE: the exact Keycloak submit-control selector (`#kc-login` /
 * `input[type=submit]`) is Keycloak's own markup, not app markup, and is
 * assumed here as Keycloak's standard default theme selector. It was not
 * confirmed against a live Keycloak instance in this environment — see
 * ISS-0712's design doc §4.1 for the flagged open question.
 */
export async function loginViaRealOidcRedirect(
  page: Page,
  username: string,
  password: string,
  expectedUrl: string,
): Promise<void> {
  // 1. Navigate with no pre-seeded session — the app's own guard must run.
  await page.goto('/', { waitUntil: 'domcontentloaded' })

  // 2. Wait for the app's ProtectedRoute/AuthProvider guard to redirect
  // off-origin to Keycloak's hosted login page (same technique as this
  // spec file's unauthenticated-redirect case).
  const appOrigin = new URL(page.url()).origin
  await page.waitForURL((url) => url.origin !== appOrigin, { timeout: 20_000 })

  // 3. Fill Keycloak's own login form fields and submit.
  await page.fill('#username', username)
  await page.fill('#password', password)
  await Promise.all([
    page.waitForURL((url) => url.origin === appOrigin, { timeout: 20_000 }),
    page.locator('#kc-login, input[type="submit"]').first().click(),
  ])

  // 4. (Optional intermediate checkpoint) The browser passes back through
  // the app's own /auth/callback route here; not asserted on directly since
  // OidcCallbackPage.tsx renders only a transient status before navigating.

  // 5. Wait for the final post-callback destination — proves
  // OidcCallbackPage.tsx's role-conditional navigate() chose expectedUrl.
  await page.waitForURL(expectedUrl, { timeout: 15_000 })
}

/**
 * Backend liveness precondition — real `GET /health` check.
 *
 * NOTE (ISS-0532 / ISS-0706): a true per-subsystem readiness endpoint
 * (`GET /health/ready`) does not exist on the backend — `lib/letflow/router.ex`
 * deliberately does not port R-Co's readiness route; it requires S6
 * observability probes that do not exist yet (see that router's moduledoc).
 * Every e2e spec that polled `/health/ready` as a precondition was throwing
 * on every run, before reaching its own assertions. `web/src/api/health.ts`
 * had the identical bug in application code and was fixed under ISS-0532 by
 * pointing at the real `GET /health` liveness endpoint instead; this function
 * mirrors that resolution for the test suite (ISS-0706). This checks liveness
 * only — it is not a full subsystem-readiness probe.
 *
 * Never returns a boolean; resolves on 2xx, throws otherwise.
 */
export async function assertBackendHealthy(
  request: APIRequestContext,
  apiBaseUrl: string,
): Promise<void> {
  const backendHealth = await request.fetch(`${apiBaseUrl}/health`)
  if (!backendHealth.ok()) {
    throw new Error(
      `Backend not live (${backendHealth.status()}) at ${apiBaseUrl}/health.\n` +
      'Ensure the BPM backend is running before executing these tests.\n' +
      '(This checks liveness, not full readiness — see the ISS-0532/ISS-0706 note ' +
      'on assertBackendHealthy in helpers.ts.)',
    )
  }
}

/**
 * Combined backend + Keycloak readiness precondition used by most e2e specs.
 *
 * Checks backend liveness first (see `assertBackendHealthy`); if that throws,
 * the Keycloak check never runs and the error propagates unchanged. Then
 * checks Keycloak's OIDC discovery document is reachable.
 */
export async function assertServiceReadiness(
  request: APIRequestContext,
  apiBaseUrl: string,
): Promise<void> {
  await assertBackendHealthy(request, apiBaseUrl)

  const keycloakDiscoveryUrl = `${BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`
  const idpHealth = await retryTransientNetworkError(() => request.fetch(keycloakDiscoveryUrl))
  if (!idpHealth.ok()) {
    throw new Error(
      `Keycloak not ready (${idpHealth.status()}) at ${keycloakDiscoveryUrl}.\n` +
      'Ensure Keycloak is running before executing these tests.',
    )
  }
}
