/** stockRegisterModel — GH 3767 / REQ-724. Pure helpers of the balances and movements screens: query keys of the
 *  routes, the cause and document-type words, the posting range check, error classes. */
import type { BalanceRow, MovementLeg, MovementRow } from './stock.api'

/** Tenant time zone until the tenant setting exists (REQ-703): assumption, owner may change at GATE B. */
export const STOCK_TIME_ZONE = 'Asia/Almaty'

export const CAUSES = ['receipt', 'issue', 'write_off', 'transfer', 'hand_over', 'return', 'reversal'] as const
export const DOCUMENT_TYPES = [
  'stock_receipt',
  'stock_issue',
  'stock_writeoff',
  'stock_transfer',
  'stock_handover',
  'stock_return',
  'stock_reversal',
] as const

/** Master entity types read for names. */
export type MasterType = 'catalog_item' | 'location_node' | 'org_unit' | 'org_employee' | 'catalog_lot' | 'catalog_uom'

export interface BalanceFilters {
  sku: string
  location: string
  org_unit: string
  responsible: string
  lot: string
}
export interface MovementFilters {
  cause: string
  document_id: string
  from_seq: string
  to_seq: string
}

export const EMPTY_BALANCE_FILTERS: BalanceFilters = { sku: '', location: '', org_unit: '', responsible: '', lot: '' }

function nonEmpty(entries: [string, string][]): Record<string, string> {
  return Object.fromEntries(entries.filter(([, v]) => v.trim() !== '').map(([k, v]) => [k, v.trim()]))
}

/** Exactly the keys the route takes from a filter: never basis, cutoff_seq, as_of or a tenant. */
export function balanceParams(f: BalanceFilters): Record<string, string> {
  return nonEmpty([
    ['sku', f.sku],
    ['location', f.location],
    ['org_unit', f.org_unit],
    ['responsible', f.responsible],
    ['lot', f.lot],
  ])
}

/** True when both bounds are numbers and from is above to: the range is not sent and the field is marked. */
export function rangeError(from: string, to: string): boolean {
  return /^\d+$/.test(from) && /^\d+$/.test(to) && BigInt(from) > BigInt(to)
}

export function movementParams(f: MovementFilters): Record<string, string> {
  const bad = rangeError(f.from_seq, f.to_seq)
  return nonEmpty([
    ['cause', f.cause],
    ['document_id', f.document_id],
    ['from_seq', bad ? '' : f.from_seq],
    ['to_seq', bad ? '' : f.to_seq],
  ])
}

/** The Movements screen narrowed to one document (used by the document view of REQ-722). */
export function movementsLinkFor(documentId: string): string {
  return `/admin/stock/movements?document_id=${encodeURIComponent(documentId)}`
}

export function isMasked(leg: MovementLeg): boolean {
  return leg.masked === true
}

export type RegisterErrorKind = 'invalid' | 'notFound' | 'forbidden' | 'generic'

export function errorKind(err: unknown): RegisterErrorKind {
  const status = (err as { status?: unknown } | null | undefined)?.status
  if (status === 422) return 'invalid'
  if (status === 404) return 'notFound'
  if (status === 403) return 'forbidden'
  return 'generic'
}

export type NameIds = Partial<Record<MasterType, string[]>>

function add(out: NameIds, type: MasterType, id: string | null | undefined) {
  if (typeof id === 'string' && id !== '') (out[type] ??= []).push(id)
}

export function balanceNameIds(rows: BalanceRow[]): NameIds {
  const out: NameIds = {}
  for (const r of rows) {
    add(out, 'catalog_item', r.sku)
    add(out, 'location_node', r.location)
    add(out, 'org_unit', r.org_unit)
    add(out, 'org_employee', r.responsible)
    add(out, 'catalog_lot', r.lot)
    add(out, 'catalog_uom', r.unit_ref)
  }
  return out
}

export function movementNameIds(rows: MovementRow[]): NameIds {
  const out: NameIds = {}
  for (const row of rows) {
    for (const l of row.legs) {
      add(out, 'catalog_uom', l.unit_ref)
      if (isMasked(l)) continue
      add(out, 'catalog_item', l.sku)
      add(out, 'location_node', l.location)
      add(out, 'org_unit', l.org_unit)
      add(out, 'org_employee', l.responsible)
      add(out, 'catalog_lot', l.lot)
    }
  }
  return out
}

/** Label field per master type; the code is the fallback. */
export const LABEL_FIELD: Record<MasterType, string> = {
  catalog_item: 'name',
  location_node: 'name',
  org_unit: 'name',
  org_employee: 'full_name',
  catalog_lot: 'code',
  catalog_uom: 'name',
}
