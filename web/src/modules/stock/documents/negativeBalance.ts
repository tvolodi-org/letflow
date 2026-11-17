/** REQ-838: the balance keys and decimal comparison behind the non-blocking negative-balance warning.
 *  Only the lowering side of a document is read: the header of an issue/write off, the From side of a two-side kind. */
import type { BalanceRow } from '../register/stock.api'
import { isTwoSide, type FormState, type LineForm } from './documentsModel'

export const NEGATIVE_BALANCE_KINDS = ['issue', 'write_off', 'transfer', 'hand_over', 'return'] as const

export interface StockBalanceKey {
  sku: string
  location: string
  org_unit: string
  responsible: string
  lot: string
  unit_ref: string
}

export interface StockBalanceGroup {
  id: string
  key: StockBalanceKey
  params: Record<string, string>
  lineIndexes: number[]
  quantities: string[]
}

/** A key is read only once all its required route filters exist. Empty responsible and lot are real filters: they mean none. */
export function stockBalanceGroups(form: FormState): StockBalanceGroup[] {
  if (!(NEGATIVE_BALANCE_KINDS as readonly string[]).includes(form.kind)) return []
  const side = isTwoSide(form.kind)
    ? form.from
    : { orgUnitId: form.orgUnitId, locationId: form.locationId, responsibleId: form.responsibleId }
  const groups = new Map<string, StockBalanceGroup>()
  form.lines.forEach((line: LineForm, index) => {
    if (line.itemId === '' || side.locationId === '' || side.orgUnitId === '') return
    const key: StockBalanceKey = {
      sku: line.itemId,
      location: side.locationId,
      org_unit: side.orgUnitId,
      responsible: side.responsibleId,
      lot: line.lotId,
      unit_ref: line.uomId,
    }
    const id = JSON.stringify(key)
    const group = groups.get(id) ?? {
      id,
      key,
      params: {
        sku: key.sku,
        location: key.location,
        org_unit: key.org_unit,
        responsible: key.responsible,
        lot: key.lot,
        limit: '1',
      },
      lineIndexes: [],
      quantities: [],
    }
    group.lineIndexes.push(index)
    group.quantities.push(line.quantity)
    groups.set(id, group)
  })
  return [...groups.values()]
}

interface DecimalPart {
  value: bigint
  scale: number
}

function decimalPart(raw: string, signed: boolean): DecimalPart | null {
  const match = signed ? /^([+-]?)(\d+)(?:\.(\d+))?$/.exec(raw.trim()) : /^()(\d+)(?:\.(\d+))?$/.exec(raw.trim())
  if (!match) return null
  const [, sign = '', whole = '', fraction = ''] = match
  const value = BigInt(whole + fraction)
  return { value: sign === '-' ? -value : value, scale: fraction.length }
}

/** Exact decimal arithmetic: invalid/negative document quantities contribute nothing; an absent balance is zero. */
export function quantitiesExceedBalance(quantities: readonly string[], onHand: string): boolean {
  const parts = quantities.map((q) => decimalPart(q, false)).filter((p): p is DecimalPart => p !== null)
  const balance = decimalPart(onHand, true) ?? { value: 0n, scale: 0 }
  if (parts.length === 0) return false
  const scale = Math.max(balance.scale, ...parts.map((p) => p.scale))
  const atScale = (p: DecimalPart) => p.value * 10n ** BigInt(scale - p.scale)
  const total = parts.reduce((sum, p) => sum + atScale(p), 0n)
  return total > atScale(balance)
}

/** Trust the route's filters, but match the complete returned row too (including the item's base unit). */
export function groupOnHand(group: StockBalanceGroup, rows: readonly BalanceRow[]): string {
  const row = rows.find((r) =>
    r.sku === group.key.sku &&
    r.location === group.key.location &&
    r.org_unit === group.key.org_unit &&
    (r.responsible ?? '') === group.key.responsible &&
    (r.lot ?? '') === group.key.lot &&
    r.unit_ref === group.key.unit_ref,
  )
  return row?.quantity ?? '0'
}
