/** lineColumns — T-1379. The columns of the lines table of a document kind, shared by the view and the editor.
 *  `key` names the cell; the editor and the view each render their own cell for it. */
import type { DocColumn } from '@/components/ui/doc/DocLines'
import type { ColSpec } from '@/components/ui/layout/ColumnResize'
import type { DocKind } from './documentsModel'

/** Layout-screen id of the document screens in the remembered layout (`ui.layout`). */
export const DOCUMENTS_LAYOUT_SCREEN = 'stock.documents'

export function lineColumns(kind: DocKind, t: (id: string) => string): DocColumn[] {
  const cols: DocColumn[] = [
    { key: 'item', label: t('stock.col.item'), colId: 'item' },
    { key: 'lot', label: t('stock.col.lot'), colId: 'lot' },
    { key: 'quantity', label: `${t('stock.col.quantity')}, ${t('stock.col.unit').toLowerCase()}`, num: true, cls: 'qty', colId: 'qty' },
  ]
  if (kind === 'opening') {
    // The released CSS gives item and lot 29% + 22% of a fixed-layout table and has no width rule for the opening
    // columns, which would collapse to zero. Without a rule the five text columns share the free width equally.
    // Recorded for R7 in design-notes.md.
    cols[0] = { ...cols[0], cls: 'open-item' }
    cols[1] = { ...cols[1], cls: 'open-lot' }
    cols.push(
      { key: 'location', label: t('stock.col.location'), cls: 'loc' },
      { key: 'responsible', label: t('stock.col.responsible') },
      { key: 'receivedOn', label: t('stock.doc.field.receivedOnReal') },
    )
  }
  if (kind === 'receipt' || kind === 'opening') {
    cols.push(
      { key: 'unitPrice', label: t('stock.doc.field.unitPrice'), num: true, cls: 'price', colId: 'price' },
      { key: 'lineValue', label: t('stock.doc.field.lineValue'), num: true, cls: 'value', colId: 'value' },
    )
  }
  return cols
}

/** Default widths (percent of the table) and smallest widths (px) of the resizable columns, the design's WEIGHT table.
 *  The last column of the kind is the flexible one (its percent is ignored). Opening has no resizable columns. */
const WEIGHT: Record<string, { w: number; min: number }> = {
  item: { w: 29, min: 140 },
  lot: { w: 22, min: 110 },
  qty: { w: 12, min: 80 },
  price: { w: 13, min: 80 },
  value: { w: 14, min: 80 },
}

export function lineColumnSpecs(kind: DocKind): ColSpec[] {
  if (kind === 'opening') return []
  const ids = ['item', 'lot', 'qty', ...(kind === 'receipt' ? ['price', 'value'] : [])]
  return ids.map((id) => ({ id, ...WEIGHT[id]! }))
}
