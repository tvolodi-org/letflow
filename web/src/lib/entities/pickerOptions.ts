/** pickerOptions — the one loader of the filter and document-form pickers (stock and assets). It reads every page up to
 *  the cap of fetchAllRecords, so record 201+ can be chosen, and carries `truncated` on the array when the cap cut the
 *  list, so a screen can say that the picker is partial (T-1804). */
import type { EntityQueryFilterClause } from '@/types/api'
import { labelOfRecord, type ReferenceType } from '@/lib/references/referenceLabel'
import { fetchAllRecords } from './fetchAllRecords'

export interface PickerOption {
  value: string
  label: string
  /** The record's field_values (the document form reads the item's base_uom_id from it). */
  fields?: Record<string, unknown>
}

/** The options; `truncated` is true when the page cap was reached with more records on the server. */
export type PickerOptions = PickerOption[] & { truncated?: boolean }

export async function loadPickerOptions(type: ReferenceType, extra: EntityQueryFilterClause[]): Promise<PickerOptions> {
  // No sort: pickers have always been served in the server's default order.
  const rows = await fetchAllRecords(
    type,
    [{ field: 'active', op: 'eq', value: true }, { field: 'deleted', op: 'eq', value: false }, ...extra],
    null,
  )
  const out: PickerOptions = rows.map((r) => ({ value: r.record_id, label: labelOfRecord(type, r) ?? '', fields: r.field_values }))
  if (rows.truncated) out.truncated = true
  return out
}

/** True when any of the lists was cut at the cap. */
export function anyPickerTruncated(...lists: (PickerOption[] | undefined)[]): boolean {
  return lists.some((l) => (l as PickerOptions | undefined)?.truncated === true)
}
