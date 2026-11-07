/** assetLinesCatalog — T-1469. The asset catalog of the lines editor built from the picker options of `assets_card`
 *  (one query for the whole screen). Matching is on the client over the loaded page (200 cards). Pure, so it is tested
 *  alone. A small copy of the stock catalog logic: the assets module does not import modules/stock. */
import type { LeCatalog, LeItem } from '@/components/ui/lines/types'
import type { PickerOption } from '../assetsPickers'

const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '')

export interface AssetLeItem extends LeItem {
  /** The card kind (`fixed`, `intangible`, ...) when the card carries it. */
  cardKind: string
}

export function toLeItem(o: PickerOption): AssetLeItem {
  const f = o.fields ?? {}
  const code = str(f['inventory_number'])
  const title = str(f['name']) || (code === '' ? o.label : '')
  return { id: o.value, code, title: title || code, barcode: str(f['barcode']), cardKind: str(f['kind']) }
}

const norm = (s: string) => s.trim().toLowerCase()
export const assetLabel = (i: LeItem): string => (i.code ? `${i.code} – ${i.title}` : i.title)

export interface AssetCatalog extends Omit<LeCatalog, 'byId'> {
  byId: (id: string) => AssetLeItem | null
}

export function buildAssetCatalog(options: readonly PickerOption[]): AssetCatalog {
  const items = options.map(toLeItem)
  const byIdMap = new Map(items.map((i) => [i.id, i]))
  return {
    byId: (id) => byIdMap.get(id) ?? null,
    resolve: (text) => {
      const q = norm(text)
      if (q === '') return null
      const exact = items.find((i) => norm(i.code) === q || norm(assetLabel(i)) === q || norm(i.code ? `${i.code} - ${i.title}` : i.title) === q || (i.barcode !== '' && i.barcode !== undefined && norm(i.barcode) === q))
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
