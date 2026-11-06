/** balanceHistoryModel — T-1430 (GATE B R14). Pure helpers of the history panel behind a stock balance: the slot
 *  params that select exactly the row's key, the leg match and the lines shown (one per matching leg). */
import type { BalanceRow, MovementLeg, MovementRow } from './stock.api'

/** All five slots of the row; a null responsible/lot is the empty string (the route reads it as "the leg has none"). */
export function slotParams(row: BalanceRow): Record<string, string> {
  return {
    sku: row.sku,
    location: row.location,
    org_unit: row.org_unit,
    responsible: row.responsible ?? '',
    lot: row.lot ?? '',
  }
}

/** A leg belongs to the balance when its five slots equal the row's (null equals ''); a masked leg never matches. */
export function legMatches(leg: MovementLeg, row: BalanceRow): boolean {
  if (leg.masked === true) return false
  return (
    leg.sku === row.sku &&
    leg.location === row.location &&
    leg.org_unit === row.org_unit &&
    (leg.responsible ?? '') === (row.responsible ?? '') &&
    (leg.lot ?? '') === (row.lot ?? '')
  )
}

export interface HistoryLine {
  key: string
  seq: number
  time: string | null
  cause: string
  documentId: string | null
  documentType: string | null
  documentNumber: string | null
  quantity: string
  isIn: boolean
  isOut: boolean
}

const isZero = (q: string) => /^-?0*(\.0*)?$/.test(q.trim())

export function toHistoryLines(rows: MovementRow[], balanceRow: BalanceRow): HistoryLine[] {
  const out: HistoryLine[] = []
  for (const r of rows) {
    for (const leg of r.legs) {
      if (!legMatches(leg, balanceRow)) continue
      const negative = leg.quantity.trim().startsWith('-')
      const zero = isZero(leg.quantity)
      out.push({
        key: `${r.entry_id}|${leg.leg_no}`,
        seq: r.posting_seq,
        time: r.event_time ?? null,
        cause: r.cause,
        documentId: r.document_id ?? null,
        documentType: r.document_type ?? null,
        documentNumber: r.document_number ?? null,
        quantity: leg.quantity,
        isIn: !zero && !negative,
        isOut: !zero && negative,
      })
    }
  }
  return out
}
