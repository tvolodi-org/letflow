/** itemsModel — T-1402. Pure helpers of the Items screen: record to row, client-side search, tracking filter,
 *  retired switch, sort and paging. All filtering is client-side over the cursor-followed catalog_item query, so an
 *  item without `tracking_policy` counts as `none`. */
import type { EntityRecord } from '@/types/api'

export const TRACKING_POLICIES = ['none', 'lot', 'serial', 'expiry'] as const
export type TrackingPolicy = (typeof TRACKING_POLICIES)[number]

export interface ItemRow {
  id: string
  code: string
  name: string
  uomId: string
  kind: string
  tracking: TrackingPolicy
  active: boolean
  externalRef: string
}

export type ItemSortKey = 'code' | 'name' | 'status'
export type SortDir = 'asc' | 'desc'
export const ITEMS_PAGE_SIZE = 25

function str(v: unknown): string {
  return typeof v === 'string' ? v : ''
}

export function toItemRow(r: EntityRecord): ItemRow {
  const f = r.field_values
  const t = str(f['tracking_policy'])
  return {
    id: r.record_id,
    code: str(f['code']),
    name: str(f['name']),
    uomId: str(f['base_uom_id']),
    kind: str(f['kind']),
    tracking: (TRACKING_POLICIES as readonly string[]).includes(t) ? (t as TrackingPolicy) : 'none',
    active: f['active'] !== false,
    externalRef: [str(f['external_ref_system']), str(f['external_ref_id'])].filter(Boolean).join(' / '),
  }
}

export interface ItemFilters {
  q: string
  tracking: TrackingPolicy | ''
  showRetired: boolean
}

export function filterItems(rows: ItemRow[], f: ItemFilters): ItemRow[] {
  const q = f.q.trim().toLowerCase()
  return rows.filter(
    (r) =>
      (f.showRetired || r.active) &&
      (f.tracking === '' || r.tracking === f.tracking) &&
      (q === '' || r.code.toLowerCase().includes(q) || r.name.toLowerCase().includes(q)),
  )
}

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })

export function sortItems(rows: ItemRow[], key: ItemSortKey, dir: SortDir): ItemRow[] {
  const sign = dir === 'asc' ? 1 : -1
  const val = (r: ItemRow): string => (key === 'status' ? (r.active ? '0' : '1') : r[key])
  return [...rows].sort((a, b) => sign * collator.compare(val(a), val(b)) || collator.compare(a.code, b.code))
}

export function pageCountOf(total: number): number {
  return Math.max(1, Math.ceil(total / ITEMS_PAGE_SIZE))
}

export function pageOf<T>(rows: T[], page: number): { rows: T[]; page: number; from: number; to: number } {
  const p = Math.min(Math.max(1, page), pageCountOf(rows.length))
  const start = (p - 1) * ITEMS_PAGE_SIZE
  const part = rows.slice(start, start + ITEMS_PAGE_SIZE)
  return { rows: part, page: p, from: rows.length === 0 ? 0 : start + 1, to: start + part.length }
}

/** The tag of a movement cause for its message id; anything unknown is `other`. */
export function causeKey(cause: string): 'receipt' | 'issue' | 'transfer' | 'count' | 'reversal' | 'other' {
  const c = cause.toLowerCase()
  if (c.includes('revers')) return 'reversal'
  if (c.includes('count')) return 'count'
  if (c.includes('transfer')) return 'transfer'
  if (c.includes('receipt') || c.includes('receive') || c.includes('opening')) return 'receipt'
  if (c.includes('issue') || c.includes('write_off') || c.includes('writeoff')) return 'issue'
  return 'other'
}
