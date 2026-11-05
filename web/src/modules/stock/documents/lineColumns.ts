/** lineColumns — T-1379. The columns of the lines table of a document kind, shared by the view and the editor.
 *  `key` names the cell; the editor and the view each render their own cell for it. */
import type { DocColumn } from '@/components/ui/doc/DocLines'
import type { DocKind } from './documentsModel'

export function lineColumns(kind: DocKind, t: (id: string) => string): DocColumn[] {
  const cols: DocColumn[] = [
    { key: 'item', label: t('stock.col.item') },
    { key: 'lot', label: t('stock.col.lot') },
    { key: 'quantity', label: `${t('stock.col.quantity')}, ${t('stock.col.unit').toLowerCase()}`, num: true, cls: 'qty' },
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
      { key: 'unitPrice', label: t('stock.doc.field.unitPrice'), num: true, cls: 'price' },
      { key: 'lineValue', label: t('stock.doc.field.lineValue'), num: true, cls: 'value' },
    )
  }
  return cols
}
