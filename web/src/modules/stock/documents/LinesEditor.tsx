/** LinesEditor — GH 3769 / REQ-722, redesigned in T-1379 (GATE B rework R2). The lines of a draft as a compact editable
 *  table (one row per line): item, unit (the item's base unit, shown, not editable), lot (of the line's item), quantity
 *  as a decimal string, and for a receipt unit price and line value; an opening balance adds location, responsible and
 *  the real receipt date. Add and remove rows; at most MAX_LINES. Enter in a number cell moves to the same cell of the
 *  next row; Enter in the last cell of the last row adds a row. Errors of a line are listed under it, each naming its
 *  field. One LineRow per line so the lot picker hook runs per row. */
import { useEffect, useState, type ReactNode } from 'react'
import { useIntl } from 'react-intl'
import { DocCard } from '@/components/ui/doc/DocLayout'
import { DocLineItem, DocLinesAdd, DocLinesTable, DocLinesTotal, type DocColumn } from '@/components/ui/doc/DocLines'
import { Select } from '@/components/ui/Select'
import { DateCell } from '@/components/ui/DateField'
import { useNames } from '../register/stockNames'
import { usePickerOptions, type PickerOption } from '../register/stockPickers'
import { MAX_LINES, emptyLine, sumDecimals, type DocKind, type LineForm } from './documentsModel'
import { lineColumns } from './lineColumns'

/** Field key of a line error -> the message id of its column label. */
const FIELD_LABEL: Record<string, string> = {
  itemId: 'stock.col.item',
  lotId: 'stock.col.lot',
  quantity: 'stock.col.quantity',
  unitPrice: 'stock.doc.field.unitPrice',
  lineValue: 'stock.doc.field.lineValue',
  locationId: 'stock.col.location',
  responsibleId: 'stock.col.responsible',
  receivedOn: 'stock.doc.field.receivedOnReal',
}

interface RowProps {
  index: number
  line: LineForm
  items: PickerOption[]
  locations: PickerOption[]
  employees: PickerOption[]
  errors: Record<string, string>
  onChange: (next: LineForm) => void
  onRemove: () => void
  canRemove: boolean
  columns: DocColumn[]
  /** Enter pressed in the number cell `col` of this row. */
  onEnter: (col: string) => void
}

function LineRow({ index, line, items, locations, employees, errors, onChange, onRemove, canRemove, columns, onEnter }: RowProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const lots = usePickerOptions('catalog_lot', [{ field: 'item_id', op: 'eq', value: line.itemId }], line.itemId !== '')
  const name = useNames(line.uomId ? [{ catalog_uom: [line.uomId] }] : [])
  const k = `lines.${index}`
  const patch = (p: Partial<LineForm>) => onChange({ ...line, ...p })
  const chooseItem = (itemId: string) => {
    const base = items.find((o) => o.value === itemId)?.fields?.['base_uom_id']
    patch({ itemId, uomId: typeof base === 'string' ? base : '', lotId: '' })
  }

  const messages: { field?: string; text: string }[] = []
  if (errors[k]) messages.push({ text: t(errors[k]) })
  for (const [key, id] of Object.entries(errors)) {
    if (!key.startsWith(`${k}.`)) continue
    const f = key.slice(k.length + 1)
    messages.push({ field: FIELD_LABEL[f] ? t(FIELD_LABEL[f]) : undefined, text: t(id) })
  }
  const bad = (f: string) => errors[`${k}.${f}`] !== undefined
  const msgId = `ln-${index}-err`
  const lineWord = `${t('stock.doc.col.lineNo')} ${index + 1}`
  const unitName = line.uomId ? name('catalog_uom', line.uomId) : ''
  const num = (col: string, field: 'quantity' | 'unitPrice' | 'lineValue', label: string) => (
    <div className="lf-control lf-control--num">
      <input
        id={`ln-${index}-${col}`}
        type="text"
        inputMode="decimal"
        autoComplete="off"
        aria-label={label}
        aria-invalid={bad(field) || undefined}
        aria-describedby={bad(field) ? msgId : undefined}
        value={line[field]}
        onChange={(e) => patch({ [field]: e.target.value })}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault()
            onEnter(col)
          }
        }}
      />
      {field === 'quantity' && (
        <span className="lf-affix">
          <span className="sr-only">{t('stock.col.unit')} </span>
          {unitName || t('stock.common.dash')}
        </span>
      )}
    </div>
  )

  const cells: Record<string, ReactNode> = {
    item: <Select label={t('stock.col.item')} hideLabel value={line.itemId} onChange={chooseItem} options={items} placeholder={t('stock.doc.pick')} />,
    lot: <Select label={t('stock.col.lot')} hideLabel value={line.lotId} onChange={(lotId) => patch({ lotId })} options={lots} placeholder={t('stock.doc.pickNone')} />,
    quantity: num('quantity', 'quantity', t('stock.col.quantity')),
    location: <Select label={t('stock.col.location')} hideLabel value={line.locationId} onChange={(locationId) => patch({ locationId })} options={locations} placeholder={t('stock.doc.pick')} />,
    responsible: <Select label={t('stock.col.responsible')} hideLabel value={line.responsibleId} onChange={(responsibleId) => patch({ responsibleId })} options={employees} placeholder={t('stock.doc.pick')} />,
    receivedOn: (
      <DateCell
        label={t('stock.doc.field.receivedOnReal')}
        value={line.receivedOn}
        onChange={(receivedOn) => patch({ receivedOn })}
        invalid={bad('receivedOn')}
        describedBy={bad('receivedOn') ? msgId : undefined}
      />
    ),
    unitPrice: num('unitPrice', 'unitPrice', t('stock.doc.field.unitPrice')),
    lineValue: num('lineValue', 'lineValue', t('stock.doc.field.lineValue')),
  }

  return (
    <DocLineItem
      index={index}
      lineLabel={lineWord}
      messages={messages}
      messageId={msgId}
      colSpan={columns.length + 2}
      testId="line-editor-row"
      editing
      onRemove={canRemove ? onRemove : undefined}
      removeLabel={`${t('stock.doc.line.removeNamed')} ${index + 1}`}
    >
      {columns.map((c) => (
        <td key={c.key} className={c.num ? 'is-num' : undefined} data-label={c.label}>
          {cells[c.key]}
        </td>
      ))}
    </DocLineItem>
  )
}

export function LinesEditor(props: {
  kind: DocKind
  lines: LineForm[]
  errors: Record<string, string>
  onChange: (lines: LineForm[]) => void
}) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const items = usePickerOptions('catalog_item')
  const locations = usePickerOptions('location_node', [], props.kind === 'opening')
  const employees = usePickerOptions('org_employee', [], props.kind === 'opening')
  const { lines, onChange } = props
  const columns = lineColumns(props.kind, t)
  const editable = columns.filter((c) => c.key === 'quantity' || c.key === 'unitPrice' || c.key === 'lineValue')
  const lastCol = editable[editable.length - 1]?.key ?? 'quantity'
  const [focusId, setFocusId] = useState<string | null>(null)
  useEffect(() => {
    if (focusId) {
      document.getElementById(focusId)?.focus()
      setFocusId(null)
    }
  }, [focusId, lines.length])

  const enter = (i: number, col: string) => {
    if (i + 1 < lines.length) setFocusId(`ln-${i + 1}-${col}`)
    else if (col === lastCol && lines.length < MAX_LINES) {
      onChange([...lines, emptyLine()])
      setFocusId(`ln-${i + 1}-${columns[0]?.key ?? 'item'}`)
    }
  }
  const withValue = props.kind === 'receipt' || props.kind === 'opening'
  const total = withValue ? sumDecimals(lines.map((l) => l.lineValue)) : null
  const colSpan = columns.length + 2
  return (
    <DocCard area="lines" title={t('stock.doc.lines')} count={lines.length} data-testid="lines-editor">
      {props.errors['lines'] && <p role="alert" className="lf-error">{t(props.errors['lines'])}</p>}
      <DocLinesTable
        wide={props.kind === 'opening'}
        columns={columns}
        lineLabel={t('stock.doc.col.lineNo')}
        editing
        removeLabel={t('stock.doc.line.remove')}
        footer={
          <DocLinesTotal
            labelSpan={withValue ? columns.length : columns.length + 2}
            label={`${t('stock.doc.lines.total')}: ${lines.length}`}
            cells={withValue ? [total ?? t('stock.common.dash'), ''] : []}
          />
        }
      >
        {lines.map((l, i) => (
          <LineRow
            // Rows are positional (no server id is ever sent), so the index is the stable key.
            key={i}
            index={i}
            line={l}
            items={items}
            locations={locations}
            employees={employees}
            errors={props.errors}
            columns={columns}
            onEnter={(col) => enter(i, col)}
            onChange={(next) => onChange(lines.map((x, j) => (j === i ? next : x)))}
            onRemove={() => {
              onChange(lines.filter((_, j) => j !== i))
              setFocusId(`ln-${Math.max(0, i - 1)}-quantity`)
            }}
            canRemove={lines.length > 1}
          />
        ))}
        <DocLinesAdd colSpan={colSpan} label={t('stock.doc.line.add')} disabled={lines.length >= MAX_LINES} onAdd={() => onChange([...lines, emptyLine()])} />
      </DocLinesTable>
    </DocCard>
  )
}
