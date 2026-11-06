/** catalogItemsStock.api — T-1402. The two stock read calls the Items screen needs (Related: balances, History:
 *  movements). A thin client of the same two URLs the stock module uses; this module may not import the stock
 *  module (ESLint boundary), so the row types are declared here with only the fields the screen reads.
 *  No call sends a tenant identifier. */
import { client } from '@/api/client'

const STOCK_BASE = '/api/v1/modules/stock'

export interface ItemBalanceRow {
  sku: string
  location: string
  org_unit: string
  lot: string | null
  unit_ref: string
  quantity: string
}
export interface ItemBalancesBody {
  next_cursor?: string | null
  rows: ItemBalanceRow[]
}
export interface ItemMovementRow {
  entry_id: string
  posting_seq: number
  cause: string
  document_type?: string | null
  document_number?: string | null
  event_time?: string | null
}
export interface ItemMovementsBody {
  next_cursor: string | null
  rows: ItemMovementRow[]
}

export const catalogItemsStockApi = {
  balances: (params: Record<string, string>) => client.get<ItemBalancesBody>(`${STOCK_BASE}/balances`, params),
  movements: (params: Record<string, string>) => client.get<ItemMovementsBody>(`${STOCK_BASE}/movements`, params),
}
