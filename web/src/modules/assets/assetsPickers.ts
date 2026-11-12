/** assetsPickers — T-1334 / C14. Options of a filter picker: active records of a master type (all pages up to the shared cap). */
import { useQueries } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { loadPickerOptions, anyPickerTruncated, type PickerOption } from '@/lib/entities/pickerOptions'
import type { EntityQueryFilterClause } from '@/types/api'
import { assetsQueryKeys } from './assetsQueryKeys'
import type { MasterType } from './register/registerModel'

export type { PickerOption }
export { anyPickerTruncated }

/** One shared empty list: a new [] on every render while loading would change every memo keyed on the options. */
const NO_OPTIONS: PickerOption[] = []

export type PickerStatus = 'loading' | 'error' | 'ready'

export function usePickerOptions(type: MasterType, extra: EntityQueryFilterClause[] = [], enabled = true): PickerOption[] {
  return usePickerState(type, extra, enabled).options
}

/** The options and whether they are loading, failed or ready (a first-use notice must not flash while loading). */
export function usePickerState(type: MasterType, extra: EntityQueryFilterClause[] = [], enabled = true): { options: PickerOption[]; status: PickerStatus } {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const scope = JSON.stringify(extra)
  // useQueries, not useQuery: a picker is an auxiliary lookup whose failure leaves the options empty; the state of the
  // page itself (loading, error, empty) is drawn by the page's own query and RegisterError.
  const [q] = useQueries({ queries: [{
    queryKey: assetsQueryKeys.options(tenantId, type, scope),
    queryFn: () => loadPickerOptions(type, extra),
    // the list carries a `truncated` flag on the array itself; structural sharing would copy it away
    structuralSharing: false,
    enabled,
    retry: false,
  }] })
  const status: PickerStatus = q.isError ? 'error' : q.isSuccess ? 'ready' : 'loading'
  return { options: q.data ?? NO_OPTIONS, status }
}
