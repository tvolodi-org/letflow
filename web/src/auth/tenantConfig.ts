import { client } from '@/api/client'

/** Tenant OIDC configuration — fetched from backend by hostname, cached in memory */

const DEFAULT_AUTHORITY = (import.meta.env.VITE_OIDC_AUTHORITY as string) ?? 'http://localhost:8082/realms/bpm-default'
const DEFAULT_CLIENT_ID = (import.meta.env.VITE_OIDC_CLIENT_ID as string) ?? 'letflow-web'

const REALM_STORAGE_KEY = 'bpm_realm_slug'

/**
 * Closed branding shape returned by GET /api/tenant-config (REQ-281). Always
 * present with all three sub-keys when `branding` itself is present — see
 * lib/letflow/design/req283-branding-css-theming.md section 5.
 */
export interface Branding {
  app_name: string
  logo_url: string | null
  brand_colors: Record<string, string>
}

export interface TenantConfig {
  oidc_authority: string
  client_id: string
  branding?: Branding
  /** REQ-470: 'test' | 'production'; absent or null when the tenant is unknown. */
  tenant_type?: 'production' | 'test' | null
}

let _cachedConfig: TenantConfig | null = null

/**
 * Resolve a realm slug from URL/sessionStorage before falling back to hostname.
 *
 * Priority (REQ-438, design req434 section 11.2 -- an explicit `?realm=` wins):
 *   1. URL query parameter 'realm'  (e.g. http://localhost:8080/?realm=swiftroute)
 *      -- overwrites any stored value, so a stale slug cannot beat it
 *   2. sessionStorage key 'bpm_realm_slug' (set on a previous page load)
 *   3. null (caller falls back to hostname lookup, or the email-first screen)
 *
 * When only one of the two is present the behaviour is unchanged.
 *
 * Side effect: if the slug is found in the URL it is written to sessionStorage
 * so that subsequent navigations within the SPA retain the correct realm.
 */
export function resolveRealmFromUrl(): string | null {
  const urlRealm = new URLSearchParams(window.location.search).get('realm')
  if (urlRealm) {
    storeRealmSlug(urlRealm)
    return urlRealm
  }

  const stored = sessionStorage.getItem(REALM_STORAGE_KEY)
  if (stored) return stored

  return null
}

/** Persists the realm slug exactly as `resolveRealmFromUrl` does for a `?realm=`
 *  load. Also used by the email-first page when discovery names a tenant, so
 *  `buildRedirectArgs` embeds `?realm=<slug>` in the redirect_uri (ISS-0726). */
export function storeRealmSlug(slug: string): void {
  sessionStorage.setItem(REALM_STORAGE_KEY, slug)
}

export async function fetchTenantConfig(hostname: string): Promise<TenantConfig> {
  if (_cachedConfig) return _cachedConfig
  try {
    const realmSlug = resolveRealmFromUrl()
    const params = realmSlug ? { realm: realmSlug } : { host: hostname }
    const data = await client.get<TenantConfig>('/api/tenant-config', params)
    _cachedConfig = data
    return data
  } catch {
    const fallback = { oidc_authority: DEFAULT_AUTHORITY, client_id: DEFAULT_CLIENT_ID }
    _cachedConfig = fallback
    return fallback
  }
}

export function getCachedTenantConfig(): TenantConfig {
  return _cachedConfig ?? { oidc_authority: DEFAULT_AUTHORITY, client_id: DEFAULT_CLIENT_ID }
}

/**
 * REQ-384 §5.2 — per-slug-keyed tenant-config cache for the multi-realm
 * OIDC manager registry (`tenantOidcRegistry.ts`).
 *
 * Deliberately a SEPARATE `Map<string, TenantConfig>`, never reading or
 * writing this file's own `_cachedConfig` above. `_cachedConfig` is a
 * single module-level value that ignores its argument once populated — it
 * was written for, and is only correct under, the single-live-tenant-per-tab
 * precondition (destroyed and rebuilt fresh on every full-page reload).
 * Reusing it naively for a second, concurrently-live tenant would silently
 * return tenant A's already-cached config for tenant B's slug — exactly the
 * class of bug REQ-384 exists to prevent, relocated from the query cache
 * into the auth layer. This cache is genuinely keyed by slug, so tenant A's
 * and tenant B's configs can coexist.
 */
const _configBySlug = new Map<string, TenantConfig>()

export async function fetchTenantConfigForSlug(slug: string): Promise<TenantConfig> {
  const cached = _configBySlug.get(slug)
  if (cached) return cached

  try {
    const data = await client.get<TenantConfig>('/api/tenant-config', { realm: slug })
    _configBySlug.set(slug, data)
    return data
  } catch {
    const fallback = { oidc_authority: DEFAULT_AUTHORITY, client_id: DEFAULT_CLIENT_ID }
    _configBySlug.set(slug, fallback)
    return fallback
  }
}

/**
 * Clears every trace of "which company this browser tab is talking to" —
 * both the in-memory `TenantConfig` cache and the `bpm_realm_slug`
 * sessionStorage key `resolveRealmFromUrl` writes on a `?realm=` load.
 *
 * Security-relevant (tenant-switch-cache-isolation GUI review, EO-002):
 * `resolveRealmFromUrl`'s sessionStorage persistence is deliberate (OIDC-F-06
 * — so an in-SPA navigation doesn't need `?realm=` on every URL), but nothing
 * previously cleared it on sign-out. On a shared browser tab, a `bpm_realm_slug`
 * left behind by one tenant's session survived into the NEXT person's sign-in
 * on the same tab: the next OIDC login would resolve tenant-config (branding,
 * `oidc_authority`) for the PREVIOUS tenant's realm rather than the new
 * hostname/URL, in violation of "signing out leaves nothing behind." Call this
 * from `AuthProvider.logout()` — never from a mid-session tenant switch, since
 * no such in-app switcher exists (tenant identity is fixed for the life of an
 * OIDC session; changing company requires a fresh sign-in, which is exactly
 * the sign-out path this function guards).
 *
 * Also strips a `?realm=` query parameter from the CURRENT address bar (via
 * `history.replaceState`, no navigation) — found necessary while writing this
 * fix's own e2e regression test: `AuthProvider.logout()` sets the session to
 * `null` before this function's caller returns, which flips
 * `ProtectedRoute`'s `isAuthenticated` to `false` on the very next render,
 * whose own effect immediately calls `getOidcManager()` again (to build the
 * next `signinRedirect()`). If the tab's URL still literally reads
 * `?realm=<slug>` at that moment (a real possibility — nothing in this app
 * strips it from the address bar after the first load), THAT re-render's
 * `resolveRealmFromUrl()` call would silently re-derive the exact same slug
 * from the URL and write it straight back into sessionStorage, undoing this
 * function's own `removeItem` a tick later. Clearing the URL query string
 * too closes that path structurally, rather than relying on winning a race
 * against ProtectedRoute's own re-render.
 */
export function resetTenantConfigCache(): void {
  _cachedConfig = null
  sessionStorage.removeItem(REALM_STORAGE_KEY)

  if (new URLSearchParams(window.location.search).has('realm')) {
    const url = new URL(window.location.href)
    url.searchParams.delete('realm')
    window.history.replaceState(window.history.state, '', url.toString())
  }
}
