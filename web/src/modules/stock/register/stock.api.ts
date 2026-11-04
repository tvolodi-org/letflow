/** stock.api — GH 3767 / REQ-724. Calls of the stock read routes (REQ-687). No call sends a tenant identifier. */
import { client } from '@/api/client'

const BASE = '/api/v1/modules/stock'

export interface BalanceRow {
  sku: string
  location: string
  org_unit: string
  responsible: string | null
  lot: string | null
  unit_ref: string
  quantity: string
  last_posting_seq?: number
}
export interface BalancesPageBody {
  ledger_seq?: number | null
  next_cursor: string | null
  rows: BalanceRow[]
}
export interface MovementLeg {
  leg_no: number
  quantity: string
  unit_ref: string
  sku?: string
  location?: string
  org_unit?: string
  responsible?: string | null
  lot?: string | null
  masked?: boolean
}
export interface MovementRow {
  entry_id: string
  posting_seq: number
  cause: string
  reason_code?: string | null
  document_type?: string | null
  document_id?: string | null
  event_time?: string | null
  legs: MovementLeg[]
}
export interface MovementsPageBody {
  next_cursor: string | null
  rows: MovementRow[]
}

export const stockApi = {
  balances: (params: Record<string, string>) => client.get<BalancesPageBody>(`${BASE}/balances`, params),
  movements: (params: Record<string, string>) => client.get<MovementsPageBody>(`${BASE}/movements`, params),
}
