/** OIDC Callback Page — processes the authorization code callback from Keycloak */

import { useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { getOidcManager, oidcManager } from '@/auth/OidcManager'
import { useAuth } from '@/auth/AuthContext'
import { setToken } from '@/api/client'
import { decodeTokenPayload, resolveDisplayName } from '@/auth/tokenUtils'
import { resolveRealmFromUrl } from '@/auth/tenantConfig'
import { tenantsApi } from '@/api/tenants'
import { isSafeRestorePath } from '@/auth/safeRestorePath'

/**
 * Module-level guard: prevent double-invocation of signinRedirectCallback().
 *
 * In development, React StrictMode fires useEffect twice (mount → unmount → remount).
 * An PKCE authorization code is single-use — the second call would receive
 * "Code not valid" from Keycloak and erroneously trigger a re-login attempt.
 *
 * This flag is set before the async call begins. Because it lives at module scope it
 * survives the StrictMode remount. It is reset to false on each full page load (the
 * module is re-imported when Keycloak redirects back to /auth/callback).
 */
let _callbackStarted = false

export default function OidcCallbackPage() {
  const { setSession } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    if (_callbackStarted) return
    _callbackStarted = true

    // REQ-384 fix: this route doubles as oidc-client-ts's silent_redirect_uri
    // target when AuthProvider.switchTenant() (via attemptSilentSwitch() in
    // tenantOidcRegistry.ts) calls signinSilent() -- tenantOidcRegistry never
    // sets a distinct silent_redirect_uri, so oidc-client-ts defaults it to
    // the same redirect_uri used for the normal top-level login flow.
    // signinSilent() opens a HIDDEN IFRAME at that URI and blocks on
    // something inside it calling signinSilentCallback(). Previously this
    // page unconditionally ran the top-level signinRedirectCallback() flow no
    // matter where it loaded, so nothing ever relayed the iframe's callback
    // URL back to the parent window -- the pending signinSilent() promise
    // hung forever, in every environment, regardless of whether the target
    // realm actually had an SSO session to find.
    //
    // oidc-client-ts's IFrameNavigator.callback() (invoked by
    // signinSilentCallback()) is a stateless postMessage relay to
    // window.parent -- it doesn't touch this window's manager state at all --
    // so any UserManager instance works here; no need to resolve the
    // tenant-specific manager or thread a separate silent_redirect_uri
    // through the registry. Detect "I'm the hidden iframe" and relay instead
    // of running the full sign-in flow (which would also be wrong here: this
    // iframe is a throwaway document, and this app never expects a redirect
    // callback to load inside a frame in any other legitimate flow).
    if (window.self !== window.top) {
      oidcManager.signinSilentCallback().catch(() => {
        // The relay itself may throw (e.g. malformed callback URL) but that's
        // independent of whether the parent window's pending signinSilent()
        // promise settles -- oidc-client-ts resolves/rejects it based on what
        // was actually relayed, or its own timeout. Nothing more to do here.
      })
      return
    }

    (async () => {
      try {
        const m = await getOidcManager()
        const user = await m.signinRedirectCallback()
        const token = user.access_token
        const payload = decodeTokenPayload(token)
        if (!payload || !payload.roles || payload.roles.length === 0) {
          // Invalid token — redirect to root which triggers Keycloak login
          window.location.replace('/')
          return
        }
        setToken(token)
        const realmSlug = resolveRealmFromUrl() ?? sessionStorage.getItem('bpm_realm_slug') ?? null
        let tenantDisplayName: string | null = null
        let tenantId: string | null = null
        let tenantType: 'production' | 'test' | null = null
        let productionTenantDisplayName: string | null = null
        // Q-1074 / GH 2431: GET /api/v1/tenants/:slug is TENANTS_MANAGE (platform-only).
        // Only a PLATFORM_ADMIN login asks for the record; every other login skips the
        // call and shows the slug as its display name.
        if (realmSlug && payload.roles.includes('PLATFORM_ADMIN')) {
          try {
            const tenantData = await tenantsApi.getBySlug(realmSlug)
            tenantDisplayName = tenantData?.display_name ?? null
            tenantId = tenantData?.tenant_id ?? null
            tenantType = tenantData?.tenant_type ?? null
            productionTenantDisplayName = tenantData?.production_tenant_display_name ?? null
          } catch {
            // non-fatal: a failed lookup leaves tenantDisplayName null, so the slug is shown below
          }
        }
        setSession({
          token,
          display_name: resolveDisplayName(payload),
          roles: payload.roles,
          loginSource: 'oidc',
          tenant_slug: realmSlug,
          tenant_display_name: tenantDisplayName ?? realmSlug,
          tenant_id: tenantId,
          tenant_type: tenantType,
          production_tenant_display_name: productionTenantDisplayName,
        })
        const restoredPath = isSafeRestorePath(user.state) ? user.state : null
        const destination =
          restoredPath ?? (payload.roles.includes('PLATFORM_ADMIN') ? '/platform-dashboard' : '/')
        navigate(destination, { replace: true })
      } catch {
        // OIDC callback failed — redirect to root which triggers Keycloak login
        window.location.replace('/')
      }
    })()
  }, [navigate, setSession])

  return (
    <div data-testid="page-oidc-callback">
      <span data-testid="oidc-callback-status">Completing sign-in...</span>
    </div>
  )
}
