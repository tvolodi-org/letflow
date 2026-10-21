/** Auth provider — OIDC-based login via Keycloak, in-memory session, role-aware navigation */

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { clearToken, setToken, tryRestoreE2eSession } from '@/api/client'
import { decodeTokenPayload, resolveDisplayName, resolveTenantSlug } from './tokenUtils'
import type { UserSession } from '@/types/api'
import { AuthContext, type AuthContextValue, type SwitchTenantOutcome } from './AuthContext'
import { getOidcManager } from './OidcManager'
import { attemptSilentSwitch } from './tenantOidcRegistry'
import { tenantRoot } from '@/api/queryKeys'
import { tenantsApi } from '@/api/tenants'
import { meApi } from '@/api/me'
import { canManageTenants } from './access/access'
import { resetTenantConfigCache, resolveRealmFromUrl } from './tenantConfig'
import { fetchTenantTypeForSlug } from './tenantType'
import { isEmailFirstLoginEnabled } from './emailFirstFlag'
import { buildRedirectArgs } from './oidcRedirectArgs'

/** Shared by `login()` (authorization-code-flow callback) and
 *  `switchTenant()` (§5.3 — silent-auth outcome) — both produce the SAME
 *  `UserSession` shape from a raw access token, just sourced differently. */
export async function buildSessionFromToken(token: string): Promise<UserSession> {
  const payload = decodeTokenPayload(token)
  if (payload === null) {
    throw { status: 400, message: 'Token format is invalid.', code: 'TOKEN_DECODE_INVALID', details: undefined }
  }
  if (!payload.roles || payload.roles.length === 0) {
    throw { status: 400, message: 'Token does not contain role assignments. Contact your administrator.', code: 'TOKEN_MISSING_ROLES', details: undefined }
  }

  const tenantSlug = resolveTenantSlug(payload)
  let tenantDisplayName: string | null = null
  let tenantId: string | null = null
  // Q-1074 / GH 2431: GET /api/v1/tenants/:slug is TENANTS_MANAGE (platform-only).
  // Only a session whose /me/access (not the token) grants platform tenant management asks
  // for the record; every other session skips the call and shows the slug as its display
  // name (same rule as OidcCallbackPage). A failed access call counts as no access: the
  // AccessProvider shows its own error state.
  const access = await meApi
    .getAccessWithToken(token)
    .then(info => ({ status: 'ready' as const, info }))
    .catch(() => ({ status: 'loading' as const }))
  if (tenantSlug && canManageTenants(access)) {
    try {
      const tenant = await tenantsApi.getBySlug(tenantSlug)
      tenantDisplayName = tenant.display_name
      tenantId = tenant.tenant_id ?? null
    } catch {
      console.error('[AuthProvider] Could not resolve tenant display name', tenantSlug)
      // a failed lookup leaves tenantDisplayName null, so the slug is shown below
    }
  }

  // REQ-470: tenant_type comes from the public tenant-config for every session.
  const tenantType = await fetchTenantTypeForSlug(tenantSlug)

  return {
    token,
    display_name: resolveDisplayName(payload),
    loginSource: 'oidc',
    tenant_slug: tenantSlug,
    tenant_display_name: tenantDisplayName ?? tenantSlug,
    tenant_id: tenantId,
    tenant_type: tenantType,
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const qc = useQueryClient()
  const [session, setSessionState] = useState<UserSession | null>(() => {
    // E2E support: restore session from sessionStorage if present (written by test runner)
    const e2e = tryRestoreE2eSession()
    if (e2e) {
      return {
        token: e2e.token,
        display_name: e2e.display_name,
        loginSource: 'oidc',
        tenant_slug: e2e.tenant_slug ?? null,
        tenant_display_name: e2e.tenant_display_name ?? null,
        tenant_id: (e2e as Record<string, unknown>).tenant_id as string | null ?? null,
        tenant_type: (e2e as Record<string, unknown>).tenant_type as 'production' | 'test' | null ?? null,
      }
    }
    return null
  })
  const isLoading = false
  const [switchingToTenantSlug, setSwitchingToTenantSlug] = useState<string | null>(null)

  // React to session-expired events dispatched by the API client.
  // Redirect to Keycloak login via OIDC.
  useEffect(() => {
    const handle = () => {
      clearToken()
      setSessionState(null)
      // REQ-438 (design req434 D4): with the email-first flag on and NO realm
      // known, do not sign in against the default realm. Clearing the session
      // above is the whole job: ProtectedRoute (which owns router context,
      // unlike this provider that sits above the router) re-renders
      // unauthenticated, finds no realm and navigates to /login, carrying the
      // current path. With a realm stored or in the URL -- or the flag off --
      // the behaviour is unchanged: re-login into that same realm.
      if (isEmailFirstLoginEnabled() && resolveRealmFromUrl() === null) return
      void getOidcManager().then(m => {
        void m.signinRedirect(buildRedirectArgs())
      })
    }
    window.addEventListener('auth:session-expired', handle)
    return () => window.removeEventListener('auth:session-expired', handle)
  }, [])

  // Start OIDC silent renew if OIDC authority is configured.
  // On token-expiring event, perform silent renew and update the in-memory token.
  useEffect(() => {
    if (!import.meta.env.VITE_OIDC_AUTHORITY) return
    const handler = async () => {
      try {
        const m = await getOidcManager()
        const newUser = await m.signinSilent()
        if (newUser?.access_token) {
          const newToken = newUser.access_token
          setToken(newToken)
          setSessionState(prev => (prev ? { ...prev, token: newToken } : null))
        }
      } catch {
        // silent renew failed; session-expired event will handle logout
      }
    }
    let cleanup: (() => void) | undefined
    void getOidcManager().then(m => {
      m.events.addAccessTokenExpiring(handler)
      m.startSilentRenew()
      cleanup = () => m.events.removeAccessTokenExpiring(handler)
    })
    return () => {
      if (cleanup) cleanup()
    }
  }, [])

  const login = useCallback(async (token: string) => {
    const newSession = await buildSessionFromToken(token)
    setToken(token)
    setSessionState(newSession)
  }, [])

  const logout = useCallback(() => {
    clearToken()
    setSessionState(null)
    // Security: clear same-tab tenant-selection residue (bpm_realm_slug in
    // sessionStorage, plus the in-memory TenantConfig cache) so the next
    // person to sign in on this browser tab resolves tenant-config fresh
    // from the URL/hostname rather than inheriting this session's company.
    // See tenantConfig.ts's resetTenantConfigCache moduledoc.
    resetTenantConfigCache()
    void getOidcManager().then(m => m.signoutRedirect())
  }, [])

  const setSession = useCallback((s: UserSession) => {
    setSessionState(s)
  }, [])

  /**
   * REQ-384 §5.3 — in-app tenant switch, no full-page OIDC re-authentication.
   * The step ORDER below is the mechanism behind AC3 (§7.3): the outgoing
   * tenant's cache subtree is removed BEFORE `setSessionState` runs, so no
   * component can re-render against the new `session.tenant_id` while a
   * tenant-A-keyed cache entry still exists — closing the placeholder-vs-
   * stale-row race §7.3 names explicitly.
   *
   * `switchingToTenantSlug` (and the `AuthenticatedShellRoot` unmount/remount
   * of `AppShell` — and therefore `TenantSwitcher` — it drives) is set ONLY
   * once a silent switch is actually confirmed ('silent_ok'), never merely
   * while attempting one. Setting it for the whole attempt (as this used to)
   * unmounted `TenantSwitcher` the instant a user clicked an option and
   * remounted a FRESH instance once the attempt settled — so on
   * 'interaction_required'/'error', the calling `TenantSwitcher` instance's
   * own `onSelect` (§6.1) was setting local state (`interactionRequiredSlug`/
   * `errorSlug`) on an already-unmounted component: a silent no-op, so
   * neither affordance ever rendered even though `switchTenant` itself had
   * resolved correctly (confirmed live: attemptSilentSwitch resolves
   * 'interaction_required' in well under a second, but the UI never showed
   * it). This also matches AC1's own boundary more precisely than the old
   * code did: interaction_required means NO switch happened at all — tenant
   * A's own screen (sidebar included) must stay exactly as it was, not swap
   * to a transition placeholder for an attempt that didn't pan out.
   */
  const switchTenant = useCallback(async (targetSlug: string): Promise<SwitchTenantOutcome> => {
    try {
      const result = await attemptSilentSwitch(targetSlug)

      if (result.outcome === 'interaction_required') return 'interaction_required'
      if (result.outcome === 'error') return 'error'

      setSwitchingToTenantSlug(targetSlug)
      try {
        const newToken = result.user.access_token
        const newSession = await buildSessionFromToken(newToken)

        // Step 1 (§7.3.1): cancel in-flight tenant-A fetches so a slow response
        // can't land after the switch and repopulate a tenant-A-keyed entry,
        // then REMOVE (not invalidate) the outgoing tenant's whole subtree in
        // one prefix-matched call.
        const outgoingTenantId = session?.tenant_id
        if (outgoingTenantId) {
          await qc.cancelQueries({ queryKey: tenantRoot(outgoingTenantId) })
          qc.removeQueries({ queryKey: tenantRoot(outgoingTenantId) })
        }

        setToken(newToken)
        setSessionState(newSession)
        return 'ok'
      } finally {
        setSwitchingToTenantSlug(null)
      }
    } catch {
      return 'error'
    }
  }, [qc, session?.tenant_id])

  const value: AuthContextValue = useMemo(
    () => ({
      session,
      isAuthenticated: session !== null,
      isLoading,
      loginSource: session?.loginSource ?? null,
      login,
      logout,
      setSession,
      switchTenant,
      switchingToTenantSlug,
    }),
    [session, isLoading, login, logout, setSession, switchTenant, switchingToTenantSlug],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
