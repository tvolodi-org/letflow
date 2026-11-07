/** T-1431 — read, save and reset the remembered screen layout (`ui.layout` user preference).
 *  Same shape as `useInstalledModules`: tenant-scoped query key, enabled only when authenticated.
 *  No debounce here: the splitter/column components own the write cadence. */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  UI_LAYOUT_KEY,
  parseUiLayout,
  preferencesApi,
  serializeUiLayout,
  type UiLayout,
} from '@/api/preferences'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { useAuth } from '@/auth/AuthContext'

export function useUiLayout() {
  const { isAuthenticated } = useAuth()
  const key = useTenantScopedQueryKeys().me.preferences()
  const qc = useQueryClient()

  const query = useQuery({
    queryKey: key,
    queryFn: () => preferencesApi.get(),
    enabled: isAuthenticated,
    select: (data) => parseUiLayout(data.preferences[UI_LAYOUT_KEY]),
  })

  const write = useMutation({
    mutationFn: (value: string | null) => preferencesApi.put({ [UI_LAYOUT_KEY]: value }),
    onSuccess: (data) => qc.setQueryData(key, data),
  })

  return {
    layout: query.data,
    isLoading: query.isLoading,
    save: (layout: UiLayout) => write.mutateAsync(serializeUiLayout(layout)),
    reset: () => write.mutateAsync(null),
  }
}
