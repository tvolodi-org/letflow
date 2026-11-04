/** stockPickers — GH 3767 / REQ-724. Options of a filter picker: active records of a master type (one page). */
import { useQueries } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { entitiesApi } from '@/api/entities'
import type { EntityQueryFilterClause } from '@/types/api'
import { stockQueryKeys } from './stockQueryKeys'
import { LABEL_FIELD, type MasterType } from './stockRegisterModel'

export interface PickerOption {
  value: string
  label: string
}

export function usePickerOptions(type: MasterType, extra: EntityQueryFilterClause[] = [], enabled = true): PickerOption[] {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const scope = JSON.stringify(extra)
  // useQueries, not useQuery: a picker is an auxiliary lookup whose failure leaves the options empty; the state of the
  // page itself (loading, error, empty) is drawn by the page's own query and RegisterError.
  const [q] = useQueries({ queries: [{
    queryKey: stockQueryKeys.options(tenantId, type, scope),
    queryFn: async () => {
      const res = await entitiesApi.queryRecords(type, {
        filters: [
          { field: 'active', op: 'eq', value: true },
          { field: 'deleted', op: 'eq', value: false },
          ...extra,
        ],
        page_size: 200,
      })
      return res.items.map((r) => {
        const v = r.field_values[LABEL_FIELD[type]] ?? r.field_values['name'] ?? r.field_values['code']
        return { value: r.record_id, label: typeof v === 'string' && v !== '' ? v : r.record_id }
      })
    },
    enabled,
    retry: false,
  }] })
  return q.data ?? []
}
