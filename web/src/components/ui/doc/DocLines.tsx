/** DocLines — the compact lines table of the platform document form (`lf-lines`): sticky header, zebra rows, one
 *  `tbody` per line so a row and its error messages stay together, an add strip and a totals row. Cells are the
 *  caller's; every cell carries `data-label` (under 640 px a line becomes a card). Generic: no module words. */
import React, { useRef } from 'react'
import { AlertCircle, Plus, X } from 'lucide-react'
import { Button } from '../Button'
import { useColResize, type ColSpec } from '../layout/ColumnResize'
import { useLayoutMessages } from '../layout/layoutMessages'

export interface DocColumn {
  key: string
  label: string
  /** Right-aligned number column. */
  num?: boolean
  /** Class suffix of the design's column width rule (`is-<cls>`); defaults to the key. */
  cls?: string
  /** Stable id of the column in the remembered layout (`[a-z0-9-]{1,24}`); a column without one is not resizable. */
  colId?: string
}

export interface DocLinesTableProps {
  columns: DocColumn[]
  /** Label of the `#` column for assistive technology. */
  lineLabel: string
  /** Edit mode adds a narrow column for the remove button. */
  editing?: boolean
  removeLabel?: string
  children: React.ReactNode
  footer?: React.ReactNode
  /** Extra table hook for a wide column set (see base.css `lf-lines--wide`). */
  wide?: boolean
  /** Resizable columns, widths remembered per user: table id, layout-screen id and the column defaults. */
  resize?: { id: string; screen: string; cols: ColSpec[] }
  'data-testid'?: string
}

export function DocLinesTable({ columns, lineLabel, editing, removeLabel, children, footer, wide, resize, ...rest }: DocLinesTableProps) {
  const tableRef = useRef<HTMLTableElement>(null)
  const m = useLayoutMessages()
  useColResize(tableRef, {
    id: resize?.id ?? 'lines',
    screen: resize?.screen ?? '',
    cols: resize?.cols ?? [],
    label: (_id, th) => `${m.resizeColumn}: ${th.textContent?.trim() ?? ''}`,
    enabled: () => !!resize && (tableRef.current?.closest('.lf-doc')?.clientWidth ?? 0) > 640,
  })
  return (
    <div className="lf-doc__scroll">
      <table ref={tableRef} className={['lf-lines lf-lines--zebra', wide ? 'lf-lines--wide' : '', editing ? 'lf-lines--edit' : ''].filter(Boolean).join(' ')} data-testid={rest['data-testid']}>
        <thead>
          <tr>
            <th scope="col" className="is-idx">
              <span aria-hidden="true">#</span>
              <span className="sr-only">{lineLabel}</span>
            </th>
            {columns.map((c) => (
              <th key={c.key} scope="col" data-col={resize ? c.colId : undefined} className={c.num ? `is-${c.cls ?? c.key} is-num` : `is-${c.cls ?? c.key}`}>
                {c.label}
              </th>
            ))}
            {editing && (
              <th scope="col" className="is-rm">
                <span className="sr-only">{removeLabel}</span>
              </th>
            )}
          </tr>
        </thead>
        {children}
        {footer}
      </table>
    </div>
  )
}

export interface DocLineItemProps {
  index: number
  lineLabel: string
  /** Messages of this line (each names its field); the row is marked as an error when there are any. */
  messages?: { field?: string; text: string }[]
  messageId: string
  colSpan: number
  testId: string
  children: React.ReactNode
  /** Edit mode: keeps the remove column even when the button is hidden (the only line), so cells stay under their headers. */
  editing?: boolean
  /** Edit mode: the remove button. */
  onRemove?: () => void
  removeLabel?: string
}

export function DocLineItem({ index, lineLabel, messages = [], messageId, colSpan, testId, children, editing, onRemove, removeLabel }: DocLineItemProps) {
  const bad = messages.length > 0
  return (
    <tbody className="lf-lines__item" data-testid={testId}>
      <tr className={bad ? 'lf-lines__row is-error' : 'lf-lines__row'}>
        <td className="is-idx" data-label={lineLabel}>
          {index + 1}
        </td>
        {children}
        {(editing || onRemove) && (
          <td className="is-rm">
            {onRemove && <Button variant="ghost" iconOnly label={removeLabel} icon={<X className="lf-icon" aria-hidden="true" />} onClick={onRemove} className="lf-lines__rm" />}
          </td>
        )}
      </tr>
      {bad && (
        <tr className="lf-lines__msg">
          <td colSpan={colSpan}>
            <div id={messageId} role="alert">
              {messages.map((m, i) => (
                <div key={i} className="lf-error">
                  <AlertCircle className="lf-icon" aria-hidden="true" />
                  {m.field && <strong>{m.field}</strong>}
                  <span>{m.text}</span>
                </div>
              ))}
            </div>
          </td>
        </tr>
      )}
    </tbody>
  )
}

/** The add strip below the lines (edit mode). */
export function DocLinesAdd(props: { colSpan: number; label: string; disabled?: boolean; onAdd: () => void }) {
  return (
    <tbody>
      <tr className="lf-lines__add">
        <td colSpan={props.colSpan}>
          <Button variant="secondary" disabled={props.disabled} icon={<Plus className="lf-icon" aria-hidden="true" />} onClick={props.onAdd}>
            {props.label}
          </Button>
        </td>
      </tr>
    </tbody>
  )
}

/** Totals row: a label cell spanning the leading columns, then the figures. */
export function DocLinesTotal(props: { labelSpan: number; label: string; cells: React.ReactNode[] }) {
  return (
    <tfoot>
      <tr>
        <td colSpan={props.labelSpan} className="lf-lines__total-label">
          {props.label}
        </td>
        {props.cells.map((c, i) => (
          <td key={i} className="is-num">
            {c}
          </td>
        ))}
      </tr>
    </tfoot>
  )
}
