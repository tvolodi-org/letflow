/** assetCounts.api — T-1933 / REQ-822 (K7a). Calls of the asset count order routes (REQ-816). No call sends a tenant
 *  identifier. issue and cancel take an empty body (a body is 422 field_not_allowed). */
import { client } from '@/api/client'

const BASE = '/api/v1/modules/assets/counts'

export interface AssetCountOrder {
  id: string
  org_unit_id: string
  kinds: string[]
  status: string
  planned_start: string | null
  planned_end: string | null
  chair_employee_id: string | null
  member_employee_ids: string[]
  location_ids: string[]
  note: string | null
  freeze_locations?: boolean
  freeze_state?: 'none' | 'active' | 'ended' | 'expired' | null
  freeze_started_at?: string | null
  freeze_until?: string | null
  number?: string | null
  document_id?: string | null
  issued_at?: string | null
  cancelled_at?: string | null
}

/** The nine keys of REQ-816 criterion 1; PUT replaces the whole draft. */
export interface AssetCountOrderBody {
  org_unit_id: string
  kinds: string[]
  planned_start: string
  planned_end: string
  chair_employee_id: string
  member_employee_ids: string[]
  location_ids: string[]
  note: string | null
  freeze_locations: boolean
}

export interface CountPage<T> {
  rows: T[]
  next_cursor: string | null
}

export const assetCountsApi = {
  list: (params: Record<string, string> = {}) => client.get<CountPage<AssetCountOrder>>(BASE, params),
  get: (id: string) => client.get<AssetCountOrder>(`${BASE}/${id}`),
  create: (body: AssetCountOrderBody) => client.post<AssetCountOrder>(BASE, body),
  update: (id: string, body: AssetCountOrderBody) => client.put<AssetCountOrder>(`${BASE}/${id}`, body),
  issue: (id: string) => client.post<AssetCountOrder>(`${BASE}/${id}/issue`),
  cancel: (id: string) => client.post<AssetCountOrder>(`${BASE}/${id}/cancel`),
}
