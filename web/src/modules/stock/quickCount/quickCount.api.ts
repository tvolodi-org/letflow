/** quickCount.api — REQ-855. Calls of the stock quick count route. */
import { client } from '@/api/client'
import type { DocumentLine, StockDocument } from '../documents/documents.api'

const BASE = '/api/v1/modules/stock'

export interface QuickCountLine extends DocumentLine {
  book_quantity?: string | null
  counted_quantity?: string | null
  difference?: string | null
}

export interface QuickCountDocument extends StockDocument {
  lines: QuickCountLine[]
}

export interface QuickCountBody {
  catalog_item_id: string
  location_id: string
  org_unit_id: string
  catalog_lot_id?: string
  counted_quantity: string
  reason_code: string
  reason_text?: string
}

export const quickCountApi = {
  create: (body: QuickCountBody) =>
    client.post<QuickCountDocument>(`${BASE}/quick-counts`, body),
}
