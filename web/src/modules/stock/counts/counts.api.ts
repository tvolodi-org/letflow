/** counts.api — GH 3735 / REQ-702. Calls of the count order (REQ-700) and count sheet (REQ-701) routes.
 *  No call sends a tenant identifier. issue/cancel/open/close take an empty body (a body is 422 field_not_allowed). */
import { client } from '@/api/client'

const BASE = '/api/v1/modules/stock/counts'

export interface CountOrder {
  id: string
  org_unit_id: string
  kind: 'full' | 'selective'
  status: string
  planned_start: string | null
  planned_end: string | null
  chair_employee_id: string | null
  member_employee_ids: string[]
  location_ids: string[]
  note: string | null
  number?: string | null
  issued_at?: string | null
  cancelled_at?: string | null
}
export interface CountOrderBody {
  org_unit_id: string
  kind: string
  planned_start: string
  planned_end: string
  chair_employee_id: string
  member_employee_ids: string[]
  location_ids: string[]
  note: string | null
}
export interface CountLine {
  line_no: number
  kind?: string | null
  location_id: string
  catalog_item_id: string
  catalog_lot_id: string | null
  responsible_employee_id: string | null
  unit_ref: string
  book_quantity: string | null
  counted_quantity: string | null
}
export interface CountEntry {
  entry_no: number
  line_no: number
  method?: string | null
  quantity_before: string | null
  quantity_after: string | null
  entered_by?: string | null
  entered_by_employee_id?: string | null
  entered_at: string | null
}
export interface SurplusBody {
  location_id: string
  catalog_item_id: string
  unit_ref: string
  counted_quantity: string
  catalog_lot_id?: string
  responsible_employee_id?: string
}
export interface CountPage<T> {
  rows: T[]
  next_cursor: string | null
}

export const countsApi = {
  list: (params: Record<string, string>) => client.get<CountPage<CountOrder>>(BASE, params),
  get: (id: string) => client.get<CountOrder>(`${BASE}/${id}`),
  create: (body: CountOrderBody) => client.post<CountOrder>(BASE, body),
  update: (id: string, body: CountOrderBody) => client.put<CountOrder>(`${BASE}/${id}`, body),
  issue: (id: string) => client.post<CountOrder>(`${BASE}/${id}/issue`),
  cancel: (id: string) => client.post<CountOrder>(`${BASE}/${id}/cancel`),
  open: (id: string) => client.post<CountOrder>(`${BASE}/${id}/open`),
  close: (id: string) => client.post<CountOrder>(`${BASE}/${id}/close`),
  lines: (id: string, params: Record<string, string>) => client.get<CountPage<CountLine>>(`${BASE}/${id}/lines`, params),
  recordCount: (id: string, lineNo: number, quantity: string) =>
    client.put<CountLine>(`${BASE}/${id}/lines/${lineNo}/count`, { counted_quantity: quantity }),
  addSurplus: (id: string, body: SurplusBody) => client.post<CountLine>(`${BASE}/${id}/surplus-lines`, body),
  entries: (id: string, params: Record<string, string>) => client.get<CountPage<CountEntry>>(`${BASE}/${id}/entries`, params),
}
