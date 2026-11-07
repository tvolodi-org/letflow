/** linesCatalog — T-1448. The item catalog of the lines editor built from the picker options of `catalog_item` (one query
 *  for the whole screen). Matching is on the client over the loaded page; no server fallback yet (same 200-item page as the
 *  old picker). Pure, so it is tested alone. */
import type { LeCatalog, LeItem } from '@/components/ui/lines/types'
import type { PickerOption } from '../register/stockPickers'

const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '')

export function toLeItem(o: PickerOption): LeItem {
  const f = o.fields ?? {}
  const code = str(f['code'])
  const title = str(f['name']) || (code === '' ? o.label : '')
  return {
    id: o.value,
    code,
    title: title || code,
    unitId: str(f['base_uom_id']),
    // The policy `none` is the only one with no lots; an unknown policy keeps the lot cell (the server decides).
    lotTracked: str(f['tracking_policy']) !== 'none',
    barcode: str(f['barcode']),
  }
}

const norm = (s: string) => s.trim().toLowerCase()
export const itemLabel = (i: LeItem): string => (i.code ? `${i.code} – ${i.title}` : i.title)

export function buildCatalog(options: readonly PickerOption[]): LeCatalog {
  const items = options.map(toLeItem)
  const byIdMap = new Map(items.map((i) => [i.id, i]))
  return {
    byId: (id) => byIdMap.get(id) ?? null,
    resolve: (text) => {
      const q = norm(text)
      if (q === '') return null
      const exact = items.find((i) => norm(i.code) === q || norm(itemLabel(i)) === q || norm(i.code ? `${i.code} - ${i.title}` : i.title) === q || (i.barcode !== '' && i.barcode !== undefined && norm(i.barcode) === q))
      if (exact) return exact
      const byTitle = items.filter((i) => norm(i.title) === q)
      return byTitle.length === 1 ? byTitle[0]! : null
    },
    suggest: (text) => {
      const q = norm(text)
      const starts: LeItem[] = []
      const has: LeItem[] = []
      for (const i of items) {
        if (q === '') starts.push(i)
        else if (norm(i.code).startsWith(q)) starts.push(i)
        else if (norm(i.code).includes(q) || norm(i.title).includes(q)) has.push(i)
      }
      return [...starts, ...has].slice(0, 8)
    },
  }
}
