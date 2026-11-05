/** OIDC Manager — singleton UserManager for authorization code flow via oidc-client-ts */

import { UserManager, InMemoryWebStorage, WebStorageStateStore } from 'oidc-client-ts'
import type { UserManagerSettings } from 'oidc-client-ts'
import { fetchTenantConfig, isTenantConfigCached } from './tenantConfig'

/** Exported for `tenantOidcRegistry.ts` (REQ-384 §5.2) — the per-tenant
 *  registry builds `UserManagerSettings` the same way this file's own
 *  `getOidcManager()` does, just per-slug instead of once. */
export function buildOidcSettings(authority: string, clientId: string): UserManagerSettings {
  const normalizedAuthority = authority.replace(/\/+$/, '')
  return {
    authority: normalizedAuthority,
    client_id: clientId,
    redirect_uri: window.location.origin + '/auth/callback',
    response_type: 'code',
    scope: 'openid profile',
    // Keep endpoint URLs pinned to configured authority. Some local Keycloak setups
    // advertise discovery metadata without the exposed host port.
    metadata: {
      issuer: normalizedAuthority,
      authorization_endpoint: `${normalizedAuthority}/protocol/openid-connect/auth`,
      token_endpoint: `${normalizedAuthority}/protocol/openid-connect/token`,
      userinfo_endpoint: `${normalizedAuthority}/protocol/openid-connect/userinfo`,
      end_session_endpoint: `${normalizedAuthority}/protocol/openid-connect/logout`,
      jwks_uri: `${normalizedAuthority}/protocol/openid-connect/certs`,
    },
    // FNFR-06 / OIDC-F-02: keep oidc-client-ts internal state (ID token,
    // refresh token, PKCE verifier) in memory only — never in sessionStorage
    // or localStorage. InMemoryWebStorage is the in-memory Storage backend;
    // WebStorageStateStore wraps it to satisfy the StateStore interface.
    userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
    automaticSilentRenew: false,
  }
}

const _defaultSettings: UserManagerSettings = buildOidcSettings(
  (import.meta.env.VITE_OIDC_AUTHORITY as string) ?? 'http://localhost:8082/realms/bpm-default',
  (import.meta.env.VITE_OIDC_CLIENT_ID as string) ?? 'letflow-web',
)

/** Backward-compat sync export using default (env-var) config. */
export const oidcManager = new UserManager(_defaultSettings)

/** Lazy-resolved manager using dynamic tenant config from /api/tenant-config.
 *
 *  The PROMISE is cached, not the resolved value (T-1400): on /auth/callback
 *  OidcCallbackPage and AuthProvider both call getOidcManager() while the config
 *  request is pending. Caching after the await gave each its own UserManager, so the
 *  one that received the token was not the one watching its expiry and background
 *  renewal never ran. */
let _managerPromise: Promise<UserManager> | null = null

export function getOidcManager(): Promise<UserManager> {
  if (_managerPromise) return _managerPromise
  let p!: Promise<UserManager>
  // eslint-disable-next-line prefer-const -- the async body compares against p
  p = (async () => {
    const config = await fetchTenantConfig(window.location.hostname)
    if (!isTenantConfigCached()) {
      // Failure fallback: this round's callers share one manager, the next call retries.
      console.warn('[auth] tenant-config unavailable, using defaults')
      if (_managerPromise === p) _managerPromise = null
    }
    return new UserManager(buildOidcSettings(config.oidc_authority, config.client_id))
  })()
  _managerPromise = p
  p.catch(() => {
    if (_managerPromise === p) _managerPromise = null
  })
  return p
}

/** Drops the shared manager (sign-out: the next sign-in builds a fresh one). */
export function resetOidcManager(): void {
  _managerPromise = null
}

/** Start the automatic silent renew loop. Call once after a successful OIDC login. */
export function startOidcSilentRenew(): void {
  oidcManager.startSilentRenew()
}
