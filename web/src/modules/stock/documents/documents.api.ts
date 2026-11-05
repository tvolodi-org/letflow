/** documents.api — GH 3769 / REQ-722. Calls of the stock document routes (REQ-712, REQ-713). No call sends a tenant
 *  identifier; a body never carries a server-set value (line_id, line_no, header_id, number, state). */
import { client } from '@/api/client'

const BASE = '/api/v1/modules/stock/documents'

export interface DocumentRow {
  id: string
  kind: string
  state: string
  number: string | null
  issued_at?: string | null
  org_unit_id: string | null
  event_time: string | null
}
export interface DocumentsPageBody {
  next_cursor: string | null
  rows: DocumentRow[]
}
export interface DocumentLine {
  line_id?: string
  line_no: number
  catalog_item_id: string
  catalog_uom_id: string
  catalog_lot_id?: string | null
  quantity: string
  unit_price?: string | null
  line_value?: string | null
  /** Opening balance (REQ-725). */
  location_id?: string | null
  responsible_id?: string | null
  received_on?: string | null
  /** Opening balance: the pair an xlsx import set (carried back on an edit). */
  external_ref_system?: string | null
  external_ref_id?: string | null
}
export interface StockDocument {
  id: string
  kind: string
  state: string
  number: string | null
  issued_at?: string | null
  org_unit_id: string | null
  location_id: string | null
  responsible_id: string | null
  counterparty_id?: string | null
  /** REQ-721: the sides of a transfer, hand over or return (a return keeps its to org unit in `org_unit_id`). */
  from_org_unit_id?: string | null
  from_location_id?: string | null
  from_responsible_id?: string | null
  to_org_unit_id?: string | null
  to_location_id?: string | null
  to_responsible_id?: string | null
  event_time: string | null
  note?: string | null
  supplier_document_ref?: string | null
  received_on?: string | null
  reason_code?: string | null
  reason_text?: string | null
  /** Opening balance: the external reference an xlsx import names the draft by. */
  external_ref_system?: string | null
  external_ref_id?: string | null
  lines: DocumentLine[]
  posted_at?: string | null
  posted_by?: string | null
  reversed_at?: string | null
  reversed_by?: string | null
  posting_check?: string | null
}
export interface CheckResult {
  ok: boolean
  lines: { line_no: number; reasons: string[] }[]
}
/** The body of a create (POST) and of an edit (PUT, the whole document). */
export type DocumentBody = Record<string, unknown>

export const documentsApi = {
  list: (params: Record<string, string>) => client.get<DocumentsPageBody>(BASE, params),
  get: (id: string) => client.get<StockDocument>(`${BASE}/${encodeURIComponent(id)}`),
  create: (body: DocumentBody) => client.post<StockDocument>(BASE, body),
  replace: (id: string, body: DocumentBody) => client.put<StockDocument>(`${BASE}/${encodeURIComponent(id)}`, body),
  discard: (id: string) => client.delete<void>(`${BASE}/${encodeURIComponent(id)}`),
  issue: (id: string) => client.post<StockDocument>(`${BASE}/${encodeURIComponent(id)}/issue`),
  post: (id: string) => client.post<StockDocument>(`${BASE}/${encodeURIComponent(id)}/post`),
  reverse: (id: string, body: { reason_code: string; reason_text?: string }) =>
    client.post<StockDocument>(`${BASE}/${encodeURIComponent(id)}/reverse`, body),
  /** REQ-726: dry check of a draft opening balance, nothing is written. */
  check: (id: string) => client.post<CheckResult>(`${BASE}/${encodeURIComponent(id)}/check`),
  /** The server reads the key `reason` (Posting.cancel/5). */
  cancel: (id: string, body: { reason: string }) => client.post<StockDocument>(`${BASE}/${encodeURIComponent(id)}/cancel`, body),
}
