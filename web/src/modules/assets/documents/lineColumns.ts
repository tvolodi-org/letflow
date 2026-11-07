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
