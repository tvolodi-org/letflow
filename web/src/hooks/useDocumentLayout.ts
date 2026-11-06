/** useDocumentLayout — the EFFECTIVE layout of the document form (user choice, else tenant default, else row) from
 *  `GET /api/v1/me/preferences`. Non-critical: loading, a failed read, a malformed answer or a layout name this build
 *  does not know all give `row`; the screen stays usable. */
import { useQuery } from '@tanstack/react-query'
import { DEFAULT_DOC_LAYOUT, isDocLayoutName, type DocLayoutName } from '@/components/ui/doc/docLayouts'
import { DOCUMENT_LAYOUT_KEY, preferencesApi } from '@/api/preferences'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { useAuth } from '@/auth/AuthContext'

const FIVE_MINUTES = 5 * 60 * 1000

/** The shared preferences read (also used by the settings screens). */
export function usePreferences() {
  const { isAuthenticated } = useAuth()
  const meKeys = useTenantScopedQueryKeys().me
  return useQuery({
    queryKey: meKeys.preferences(),
    queryFn: () => preferencesApi.get(),
    enabled: isAuthenticated,
    staleTime: FIVE_MINUTES,
    refetchOnWindowFocus: false,
    retry: false,
  })
}

export function layoutFromAnswer(data: unknown, key: string = DOCUMENT_LAYOUT_KEY, mapKey: 'effective' | 'tenant_defaults' = 'effective'): DocLayoutName {
  const map = (data as Record<string, unknown> | null | undefined)?.[mapKey]
  const v = map && typeof map === 'object' ? (map as Record<string, unknown>)[key] : undefined
  return isDocLayoutName(v) ? v : DEFAULT_DOC_LAYOUT
}

export function useDocumentLayout(): DocLayoutName {
  const q = usePreferences()
  return layoutFromAnswer(q.data)
}
