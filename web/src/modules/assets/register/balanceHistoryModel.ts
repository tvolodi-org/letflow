/** balanceHistoryModel — T-1334 / C14. Pure helpers of the history panel behind an asset balance row. The movements
 *  route has no slot keys (`@movement_keys` of the router), so the panel pages the unfiltered movements and keeps the
 *  legs whose five slots equal the row's: the match is made here, one line per matching leg. */
import type { AssetBalanceRow, AssetMovementLeg, AssetMovementRow } from './assetRegister.api'

/** A leg belongs to the balance when its five slots equal the row's (null equals ''); a masked leg never matches. */
export function legMatches(leg: AssetMovementLeg, row: AssetBalanceRow): boolean {
  if (leg.masked === true) return false
  return (
    leg.asset === row.asset &&
    leg.org_unit === row.org_unit &&
    (leg.location ?? '') === (row.location ?? '') &&
    leg.material_responsible === row.material_responsible &&
    (leg.actual_user ?? '') === (row.actual_user ?? '')
  )
}

export interface HistoryLine {
  key: string
  seq: number
  time: string | null
  cause: string
  documentId: string | null
  documentType: string | null
  quantity: string
  isIn: boolean
  isOut: boolean
}

const isZero = (q: string) => /^-?0*(\.0*)?$/.test(q.trim())

export function toHistoryLines(rows: AssetMovementRow[], balanceRow: AssetBalanceRow): HistoryLine[] {
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
        quantity: leg.quantity,
        isIn: !zero && !negative,
        isOut: !zero && negative,
      })
    }
  }
  return out
}
