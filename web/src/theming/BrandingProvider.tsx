
import { useEffect, useState, type ReactNode } from 'react'
import { fetchTenantConfig, fetchTenantConfigForSlug } from '@/auth/tenantConfig'
import { useAuth } from '@/auth/AuthContext'
import { resolveApiUrl } from '@/api/client'
import { applyBrandingColors } from './applyBranding'
import { BrandingContext } from './BrandingContext'
import { DEFAULT_BRANDING_CONTEXT_VALUE, PLATFORM_DEFAULT_APP_NAME, type BrandingContextValue } from './brandingDefaults'

/** The signed-in session's tenant slug, or null when unauthenticated or rendered
 *  outside an <AuthProvider> (useAuth throws there; branding must still render). */
function useSessionTenantSlug(): string | null {
  try {
    return useAuth().session?.tenant_slug ?? null
  } catch {
    return null
  }
}

/**
 * Mounted once at the app root (web/src/main.tsx), wrapping <RouterProvider>.
 *
 * On mount, calls the EXISTING fetchTenantConfig(window.location.hostname) —
 * the same module-level cache main.tsx's pre-warm call already populates, so
 * this never issues a duplicate network request (see design doc section 2).
 *
 * fetchTenantConfig never rejects (it catches internally and resolves to its
 * own fallback object), so no .catch() is needed here — every one of the three
 * fallback cases in design doc section 4 is already handled by fetchTenantConfig
 * itself plus this component's `?.`/`??` reads.
 *
 * ISS-0937 (Q-937): the backend has NO host->tenant binding, so
 * `?host=<hostname>` always yields the DEFAULT config and a normal load never
 * shows tenant branding. Once a session exists, branding is therefore re-fetched
 * for the session's own tenant (`?realm=<tenant_slug>`, per-slug cache). This
 * provider sits INSIDE <AuthProvider> (main.tsx); it tolerates
 * being rendered outside one (see useSessionTenantSlug).
 */
export function BrandingProvider({ children }: { children: ReactNode }) {
  const [value, setValue] = useState<BrandingContextValue>(DEFAULT_BRANDING_CONTEXT_VALUE)
  const sessionTenantSlug = useSessionTenantSlug()

  useEffect(() => {
    let cancelled = false

    const configPromise = sessionTenantSlug
      ? fetchTenantConfigForSlug(sessionTenantSlug)
      : fetchTenantConfig(window.location.hostname)

    void configPromise.then((config) => {
      applyBrandingColors(config.branding?.brand_colors)

      if (cancelled) return
      setValue({
        appName: config.branding?.app_name ?? PLATFORM_DEFAULT_APP_NAME,
        logoUrl: config.branding?.logo_url ? resolveApiUrl(config.branding.logo_url) : null,
      })
    })

    return () => {
      cancelled = true
    }
  }, [sessionTenantSlug])

  return <BrandingContext.Provider value={value}>{children}</BrandingContext.Provider>
}
