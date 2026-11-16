/** taskParties — T-2019. From whom / to whom of a document, and the total of its lines, for the task row and the task
 *  panel (owner finding #13). Pure: the caller passes the reference-label function. A side is "org unit · location ·
 *  person"; a document with no second side (a receipt, an opening) has no "to" and shows only its own org unit/location. */
import type { ReferenceType } from '@/lib/references/referenceLabel'
import type { TaskDoc } from './useTaskDocument'

type Label = (type: ReferenceType, id: string | null | undefined) => string

const join = (parts: string[]) => parts.filter((x) => x !== '').join(' · ')

/** True when the document moves something between two sides (transfer, handover): a different place, unit or person. */
export function hasTwoSides(doc: TaskDoc): boolean {
  return !!(doc.fromLocationId || doc.toLocationId || doc.toOrgUnitId || doc.fromResponsibleId || doc.toResponsibleId)
}

export function fromSide(doc: TaskDoc, label: Label): string {
  return join([
    label('org_unit', doc.orgUnitId),
    label('location_node', doc.fromLocationId ?? doc.locationId),
    label('org_employee', doc.fromResponsibleId ?? doc.responsibleId),
  ])
}

export function toSide(doc: TaskDoc, label: Label): string {
  return join([label('org_unit', doc.toOrgUnitId), label('location_node', doc.toLocationId), label('org_employee', doc.toResponsibleId)])
}

const SCALE = 9
/** Sum of decimal quantity texts as a decimal text (BigInt on the scaled value, no float error); non-decimal text counts as 0. */
export function sumQuantities(values: string[]): string {
  let total = 0n
  for (const v of values) {
    const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(v)
    if (!m) continue
    const frac = (m[3] ?? '').slice(0, SCALE).padEnd(SCALE, '0')
    const n = BigInt(m[2] + frac)
    total += m[1] === '-' ? -n : n
  }
  const neg = total < 0n
  const digits = (neg ? -total : total).toString().padStart(SCALE + 1, '0')
  return `${neg ? '-' : ''}${digits.slice(0, -SCALE)}.${digits.slice(-SCALE)}`
}
