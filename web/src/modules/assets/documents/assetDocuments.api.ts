/** assetDocuments.api — T-1334 / C14. Calls of the asset document routes (C10, C11): list, get, create, replace
 *  (T-1469: the draft forms), discard, issue and reverse. No call sends a tenant identifier; the
 *  document routes take no idempotency key. */
import { client } from '@/api/client'
import type { UiLocale } from '@/i18n/uiLocaleStore'

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
  /** The four kinds' line; a change of kind line carries the keys below instead. */
  asset_id: string
  quantity: string
  // Change of kind (REQ-759): stock side, then asset side. `asset_card_id` is server-set and never sent.
  catalog_item_id?: string
  catalog_uom_id?: string
  catalog_lot_id?: string | null
  stock_location_id?: string
  stock_responsible_id?: string
  target_kind?: string
  asset_org_unit_id?: string | null
  asset_location_id?: string
  material_responsible_id?: string
  actual_user_id?: string | null
  inventory_number?: string
  asset_name?: string
  asset_card_id?: string | null
  // Opening (decision 0083): the place is per line; the external pair is written by the import.
  location_id?: string | null
  external_ref_system?: string | null
  external_ref_id?: string | null
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
  external_ref_system?: string | null
  external_ref_id?: string | null
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

/** The answer of `POST /documents/:id/check` (opening drafts): header reasons and, per line, its reasons. `fields` names
 *  the employee fields of an `employee_not_active` reason. */
export interface OpeningCheckResult {
  ok: boolean
  header: string[]
  lines: { line_no: number; reasons: string[]; fields: string[] }[]
}

/** The body of create (with `kind`) and replace (the whole header and the whole line list). */
export type AssetDocumentBody = Record<string, unknown>

export const assetDocumentsApi = {
  list: (params: Record<string, string>) => client.get<AssetDocumentsPageBody>(BASE, params),
  get: (id: string) => client.get<AssetDocument>(`${BASE}/${encodeURIComponent(id)}`),
  create: (body: AssetDocumentBody) => client.post<AssetDocument>(BASE, body),
  replace: (id: string, body: AssetDocumentBody) => client.put<AssetDocument>(`${BASE}/${encodeURIComponent(id)}`, body),
  discard: (id: string) => client.delete<void>(`${BASE}/${encodeURIComponent(id)}`),
  issue: (id: string) => client.post<AssetDocument>(`${BASE}/${encodeURIComponent(id)}/issue`),
  check: (id: string) => client.post<OpeningCheckResult>(`${BASE}/${encodeURIComponent(id)}/check`),
  reverse: (id: string, body: { reason_code: string; reason_text?: string }) =>
    client.post<AssetDocument>(`${BASE}/${encodeURIComponent(id)}/reverse`, body),
  /** T-1915: the printed act (PDF) of an issued document; no tenant identifier is sent. */
  print: (id: string, lang: UiLocale) => client.getBlob(`${BASE}/${encodeURIComponent(id)}/print`, { lang }),
  /** T-1921: an official form (`form=da1`, .docx or PDF) of an issued commission or hand over; no tenant identifier. */
  printForm: (id: string, form: string, format: string, lang: string) =>
    client.getBlob(`${BASE}/${encodeURIComponent(id)}/print`, { form, format, lang }),
}
