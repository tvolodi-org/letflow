/** stockPickers — GH 3767 / REQ-724. Options of a filter picker: active records of a master type (all pages up to the shared cap). */
import { useQueries } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { loadPickerOptions, anyPickerTruncated, type PickerOption } from '@/lib/entities/pickerOptions'
import type { EntityQueryFilterClause } from '@/types/api'
import { stockQueryKeys } from './stockQueryKeys'
import type { MasterType } from './stockRegisterModel'

export type { PickerOption }
export { anyPickerTruncated }

export function usePickerOptions(type: MasterType, extra: EntityQueryFilterClause[] = [], enabled = true): PickerOption[] {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const scope = JSON.stringify(extra)
  // useQueries, not useQuery: a picker is an auxiliary lookup whose failure leaves the options empty; the state of the
  // page itself (loading, error, empty) is drawn by the page's own query and RegisterError.
  const [q] = useQueries({ queries: [{
    queryKey: stockQueryKeys.options(tenantId, type, scope),
    queryFn: () => loadPickerOptions(type, extra),
    // the list carries a `truncated` flag on the array itself; structural sharing would copy it away
    structuralSharing: false,
    enabled,
    retry: false,
  }] })
  return q.data ?? []
}
