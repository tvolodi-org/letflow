/** assetRegister.api — T-1334 / C14. Calls of the assets ledger read routes (C8). No call sends a tenant identifier;
 *  the scoped read (REQ-682) is the server's: the UI only shows `coverage` and `masked`. */
import { client } from '@/api/client'

const BASE = '/api/v1/modules/assets'

export interface AssetBalanceRow {
  asset: string
  org_unit: string
  location: string | null
  material_responsible: string
  actual_user: string | null
  unit_ref: string
  quantity: string
  last_posting_seq?: number
}
export interface AssetBalancesBody {
  /** Set when the read was made for a day (`as_of_date`): the day, the tenant time zone and the cutoff the server used. */
  as_of_date?: string | null
  timezone?: string | null
  cutoff_seq?: number | null
  ledger_seq?: number | null
  next_cursor: string | null
  /** `visible_only`: the caller reads the rows of its own org units only (REQ-682). */
  coverage?: 'complete' | 'visible_only' | null
  rows: AssetBalanceRow[]
}
export interface AssetMovementLeg {
  leg_no: number
  quantity: string
  unit_ref: string
  asset?: string
  org_unit?: string
  location?: string | null
  material_responsible?: string
  actual_user?: string | null
  masked?: boolean
}
export interface AssetMovementRow {
  entry_id: string
  posting_seq: number
  cause: string
  reverses_entry_id?: string | null
  reason_code?: string | null
  document_type?: string | null
  document_id?: string | null
  event_time?: string | null
  posting_time?: string | null
  legs: AssetMovementLeg[]
}
export interface AssetMovementsBody {
  next_cursor: string | null
  rows: AssetMovementRow[]
}

export const assetRegisterApi = {
  balances: (params: Record<string, string>) => client.get<AssetBalancesBody>(`${BASE}/balances`, params),
  /** The xlsx file of the first page of the balances; same filters and day as the screen. */
  balancesXlsx: (params: Record<string, string>) => client.getBlob(`${BASE}/balances`, { ...params, format: 'xlsx' }),
  movements: (params: Record<string, string>) => client.get<AssetMovementsBody>(`${BASE}/movements`, params),
}
