/** lineColumns — T-1334 / C14. The columns of the lines table of an asset document. A line holds the asset and the
 *  quantity only (`Documents.line_view/1`). */
import type { DocColumn } from '@/components/ui/doc/DocLines'
import type { ColSpec } from '@/components/ui/layout/ColumnResize'

/** Layout-screen id of the document screens in the remembered layout (`ui.layout`). */
export const ASSET_DOCUMENTS_LAYOUT_SCREEN = 'assets.documents'

export function lineColumns(t: (id: string) => string): DocColumn[] {
  return [
    { key: 'asset', label: t('assets.reg.col.asset'), cls: 'item', colId: 'item' },
    { key: 'quantity', label: t('assets.reg.col.quantity'), num: true, cls: 'qty', colId: 'qty' },
  ]
}

/** Default widths (percent of the table) and smallest widths (px); the last column is the flexible one. */
export function lineColumnSpecs(): ColSpec[] {
  return [
    { id: 'item', w: 70, min: 160 },
    { id: 'qty', w: 30, min: 90 },
  ]
}

// ---- change of kind (T-1336 / C16): 13 line fields, stock side then asset side, plus the card once posted ----------

/** Column keys of a change of kind line in table order; the form field of the same name is on `KindChangeLine`. */
export const KC_COLUMNS = [
  ['item', 'item', 11], ['unit', 'unit', 4], ['lot', 'lot', 6], ['quantity', 'qty', 5], ['stockLocation', 'sloc', 8],
  ['stockResponsible', 'sresp', 8], ['targetKind', 'tkind', 7], ['inventoryNumber', 'invno', 8], ['assetName', 'aname', 9],
  ['assetOrgUnit', 'aunit', 8], ['assetLocation', 'aloc', 8], ['materialResponsible', 'holder', 8], ['actualUser', 'auser', 5],
] as const

/** `withCard`: the read-only table adds the asset card column (server-set, shown once the document is posted). */
export function kindChangeLineColumns(t: (id: string) => string, withCard = false): DocColumn[] {
  const cols: DocColumn[] = KC_COLUMNS.map(([key, colId]) => ({ key, colId, label: t(`assets.doc.kc.col.${key}`), num: key === 'quantity' }))
  if (withCard) cols.push({ key: 'assetCard', colId: 'acard', label: t('assets.doc.kc.col.assetCard') })
  return cols
}

export function kindChangeColumnSpecs(withCard = false): ColSpec[] {
  const specs: ColSpec[] = KC_COLUMNS.map(([, id, w]) => ({ id, w, min: 120 }))
  if (withCard) specs.push({ id: 'acard', w: 5, min: 120 })
  return specs
}

// ---- opening (T-1877, decision 0083): the asset, quantity and placement of each line, plus the card's money and date ----

/** Column keys of an opening line in table order (key, colId, default width %). The last three are read from the card; the last column is the flexible one of the table, so the widths before it leave it room. */
export const OPENING_COLUMNS = [
  ['asset', 'item', 16], ['quantity', 'qty', 6], ['location', 'loc', 13], ['responsible', 'resp', 13], ['user', 'user', 11],
  ['cost', 'cost', 9], ['depreciation', 'dep', 9], ['acquired', 'acq', 8],
] as const
const CARD_INFO_KEYS: readonly string[] = ['cost', 'depreciation', 'acquired']

/** `withCardInfo`: the cost, accumulated depreciation and acquisition date columns (read-only, from the card). */
export function openingLineColumns(t: (id: string) => string, withCardInfo = true): DocColumn[] {
  return OPENING_COLUMNS
    .filter(([key]) => withCardInfo || !CARD_INFO_KEYS.includes(key))
    .map(([key, colId]) => ({ key, colId, label: t(`assets.doc.opening.col.${key}`), num: key === 'quantity' || key === 'cost' || key === 'depreciation' }))
}

export function openingColumnSpecs(withCardInfo = true): ColSpec[] {
  return OPENING_COLUMNS
    .filter(([key]) => withCardInfo || !CARD_INFO_KEYS.includes(key))
    .map(([, id, w]) => ({ id, w, min: id === 'qty' ? 70 : id === 'cost' || id === 'dep' || id === 'acq' ? 90 : 120 }))
}
