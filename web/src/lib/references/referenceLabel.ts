/** referenceLabel — T-1378. The one rule for showing a reference field (a record id of another entity type): the
 *  record's "code - title", or what it has, and never the id itself. Pure; the hook and the component build on it. */
import type { EntityRecord } from '@/types/api'

export type ReferenceType =
  | 'catalog_item'
  | 'location_node'
  | 'org_unit'
  | 'org_employee'
  | 'catalog_lot'
  | 'catalog_uom'
  | 'catalog_counterparty'

/** The fields that make the label of a type: `code`, then `title` (either may be absent). A type with no title field
 *  shows the code only; `fallback` is used when the code is empty (a unit shows its name). */
export const REFERENCE_FIELDS: Record<ReferenceType, { code?: string; title?: string; fallback?: string }> = {
  catalog_item: { code: 'code', title: 'name' },
  org_unit: { code: 'code', title: 'name' },
  location_node: { code: 'code', title: 'name' },
  org_employee: { code: 'code', title: 'full_name' },
  catalog_counterparty: { code: 'code', title: 'name' },
  catalog_lot: { code: 'code' },
  catalog_uom: { code: 'code', fallback: 'name' },
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function isUuid(s: unknown): s is string {
  return typeof s === 'string' && UUID_RE.test(s)
}

function text(v: unknown): string {
  return typeof v === 'string' ? v.trim() : ''
}

/** "code - title"; the one that exists when only one does; `null` when neither (the id is never a label). */
export function labelOfRecord(type: ReferenceType, rec: Pick<EntityRecord, 'field_values'>): string | null {
  const spec = REFERENCE_FIELDS[type]
  const fv = rec.field_values ?? {}
  const code = spec.code ? text(fv[spec.code]) : ''
  const title = spec.title ? text(fv[spec.title]) : ''
  const fallback = spec.fallback ? text(fv[spec.fallback]) : ''
  const parts = [code || fallback, title].filter((p) => p !== '')
  if (parts.length === 2 && parts[0] === parts[1]) return parts[0]
  if (parts.length > 0) return parts.join(' - ')
  // a record with none of the declared fields: any readable name, still not the id
  const any = text(fv['name']) || text(fv['code'])
  return any === '' ? null : any
}
