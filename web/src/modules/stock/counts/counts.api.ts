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
  sheet_document_id?: string | null
  document_id?: string | null
  sheet_signed_at?: string | null
  differences_document_id?: string | null
  differences_issued_at?: string | null
  differences_signed_at?: string | null
  differences_number?: string | null
  /** REQ-718: present while the status is signed or posted. */
  posting_state?: 'none' | 'pending' | 'posted' | 'reversed'
  post_pending?: boolean
  reverse_pending?: boolean
  entry_id?: string | null
  posted_at?: string | null
  posted_by?: string | null
  reversed_at?: string | null
  reversed_by?: string | null
  posting_check?: 'ok' | 'mismatch' | null
  posting_document_id?: string | null
  posting_number?: string | null
}
export interface ReverseBody {
  reason_code: string
  reason_text?: string
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
export interface ScanBody {
  scanned_text: string
  location_id: string
  scan_id: string
}
/** The answer of a scan: a location code (kind location) or the counted line, `duplicate` true on a retry. */
export type ScanAnswer = (Partial<CountLine> & { kind?: string | null; scanned_text?: string; duplicate?: boolean })
export interface DifferenceLine {
  line_no: number
  kind?: string | null
  location_id: string
  catalog_item_id: string
  catalog_lot_id?: string | null
  responsible_employee_id?: string | null
  unit_ref: string
  book_quantity: string
  counted_quantity: string
  difference: string
  direction: 'surplus' | 'shortage' | string
}
export interface Differences {
  number: string | null
  version_no: number
  issued_at: string | null
  content_hash: string
  lines: DifferenceLine[]
}
export interface SignatureRow {
  document_kind: string
  version_no: number
  employee_id: string
  signer_role: string
  marked_at: string
}
export type PaperworkKind = 'order' | 'sheet' | 'differences'
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
  scan: (id: string, body: ScanBody) => client.post<ScanAnswer>(`${BASE}/${id}/scan`, body),
  signSheet: (id: string, ids: string[]) => client.post<CountOrder>(`${BASE}/${id}/sheet-signatures`, { signer_employee_ids: ids }),
  issueDifferences: (id: string) => client.post<CountOrder>(`${BASE}/${id}/differences`),
  signDifferences: (id: string, ids: string[]) =>
    client.post<CountOrder>(`${BASE}/${id}/differences-signatures`, { signer_employee_ids: ids }),
  differences: (id: string) => client.get<Differences>(`${BASE}/${id}/differences`),
  signatures: (id: string) => client.get<{ rows: SignatureRow[] }>(`${BASE}/${id}/signatures`),
  post: (id: string) => client.post<CountOrder>(`${BASE}/${id}/post`),
  reverse: (id: string, body: ReverseBody) => client.post<CountOrder>(`${BASE}/${id}/reverse`, body),
  postingRecord: (id: string) => client.post<CountOrder>(`${BASE}/${id}/posting-record`),
  paperwork: (id: string, kind: PaperworkKind) => client.getBlob(`${BASE}/${id}/paperwork/${kind}`),
  entries: (id: string, params: Record<string, string>) => client.get<CountPage<CountEntry>>(`${BASE}/${id}/entries`, params),
}
