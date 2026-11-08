/** assetsPickers — T-1334 / C14. Options of a filter picker: active records of a master type (one page). */
import { useQueries } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { entitiesApi } from '@/api/entities'
import type { EntityQueryFilterClause } from '@/types/api'
import { assetsQueryKeys } from './assetsQueryKeys'
import { labelOfRecord } from '@/lib/references/referenceLabel'
import type { MasterType } from './register/registerModel'

export interface PickerOption {
  value: string
  label: string
  /** The record's field_values (the document form reads the item's base_uom_id from it). */
  fields?: Record<string, unknown>
}

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
        return { value: r.record_id, label: labelOfRecord(type, r) ?? '', fields: r.field_values }
      })
    },
    enabled,
    retry: false,
  }] })
  const status: PickerStatus = q.isError ? 'error' : q.isSuccess ? 'ready' : 'loading'
  return { options: q.data ?? NO_OPTIONS, status }
}
