/** assetDocuments.api — T-1334 / C14. Calls of the asset document routes (C10, C11): list, get, discard, issue and
 *  reverse. Create and replace come with the draft forms (follow-up task). No call sends a tenant identifier; the
 *  document routes take no idempotency key. */
import { client } from '@/api/client'

const BASE = '/api/v1/modules/assets/documents'

export interface AssetDocumentRow {
  id: string
  kind: string
  state: string
  number: string | null
  issued_at?: string | null
  org_unit_id: string | null
  event_time: string | null
}
export interface AssetDocumentsPageBody {
  next_cursor: string | null
  rows: AssetDocumentRow[]
}
export interface AssetDocumentLine {
  line_id?: string
  line_no: number
  asset_id: string
  quantity: string
}
/** A document view: the union of the header keys of the four kinds (`Kinds.header_keys`); a kind carries its own. */
export interface AssetDocument {
  id: string
  kind: string
  state: string
  number: string | null
  issued_at?: string | null
  event_time: string | null
  note?: string | null
  org_unit_id?: string | null
  location_id?: string | null
  material_responsible_id?: string | null
  actual_user_id?: string | null
  from_material_responsible_id?: string | null
  from_actual_user_id?: string | null
  to_material_responsible_id?: string | null
  to_actual_user_id?: string | null
  from_location_id?: string | null
  to_org_unit_id?: string | null
  to_location_id?: string | null
  reason_code?: string | null
  reason_text?: string | null
  lines: AssetDocumentLine[]
  posted_at?: string | null
  posted_by?: string | null
  posted_by_label?: string | null
  reversed_at?: string | null
  reversed_by?: string | null
  reversed_by_label?: string | null
  entry_id?: string | null
  posting_check?: string | null
}

export const assetDocumentsApi = {
  list: (params: Record<string, string>) => client.get<AssetDocumentsPageBody>(BASE, params),
  get: (id: string) => client.get<AssetDocument>(`${BASE}/${encodeURIComponent(id)}`),
  discard: (id: string) => client.delete<void>(`${BASE}/${encodeURIComponent(id)}`),
  issue: (id: string) => client.post<AssetDocument>(`${BASE}/${encodeURIComponent(id)}/issue`),
  reverse: (id: string, body: { reason_code: string; reason_text?: string }) =>
    client.post<AssetDocument>(`${BASE}/${encodeURIComponent(id)}/reverse`, body),
}
