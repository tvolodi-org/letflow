/** LinesEditor — GH 3769 / REQ-722. The lines of a draft: item, unit (the item's base unit, shown, not editable), lot
 *  (of the line's item), quantity as a decimal string, and for a receipt unit price and line value. Add and remove
 *  rows; at most MAX_LINES. One LineRow component per line so the lot picker hook runs per row. */
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import { useNames } from '../register/stockNames'
import { usePickerOptions, type PickerOption } from '../register/stockPickers'
import { MAX_LINES, emptyLine, type DocKind, type LineForm } from './documentsModel'

interface RowProps {
  index: number
  line: LineForm
  kind: DocKind
  items: PickerOption[]
  locations: PickerOption[]
  employees: PickerOption[]
  errors: Record<string, string>
  onChange: (next: LineForm) => void
  onRemove: () => void
  canRemove: boolean
}

function LineRow({ index, line, kind, items, locations, employees, errors, onChange, onRemove, canRemove }: RowProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const lots = usePickerOptions(
    'catalog_lot',
    [{ field: 'item_id', op: 'eq', value: line.itemId }],
    line.itemId !== '',
  )
  const name = useNames(line.uomId ? [{ catalog_uom: [line.uomId] }] : [])
  const k = `lines.${index}`
  const err = (f: string) => (errors[`${k}.${f}`] ? t(errors[`${k}.${f}`]) : undefined)
  const rowErr = errors[k] ? t(errors[k]) : undefined
  const patch = (p: Partial<LineForm>) => onChange({ ...line, ...p })

  const chooseItem = (itemId: string) => {
    const base = items.find((o) => o.value === itemId)?.fields?.['base_uom_id']
    patch({ itemId, uomId: typeof base === 'string' ? base : '', lotId: '' })
  }

  return (
    <fieldset data-testid="line-editor-row" aria-label={`${t('stock.doc.col.lineNo')} ${index + 1}`}>
      <legend>{`${t('stock.doc.col.lineNo')} ${index + 1}`}</legend>
      {rowErr && <span role="alert">{rowErr}</span>}
      <Select
        label={t('stock.col.item')}
        value={line.itemId}
        onChange={chooseItem}
        options={items}
        placeholder={t('stock.doc.pick')}
        error={err('itemId')}
      />
      <Field label={t('stock.col.unit')} readOnly>
        <input type="text" value={line.uomId ? name('catalog_uom', line.uomId) : ''} readOnly />
      </Field>
      <Select
        label={t('stock.col.lot')}
        value={line.lotId}
        onChange={(lotId) => patch({ lotId })}
        options={lots}
        placeholder={t('stock.doc.pickNone')}
        error={err('lotId')}
        optional
      />
      <Field label={t('stock.col.quantity')} error={err('quantity')} mono>
        <input type="text" inputMode="decimal" value={line.quantity} onChange={(e) => patch({ quantity: e.target.value })} />
      </Field>
      {kind === 'opening' && (
        <>
          <Select
            label={t('stock.col.location')}
            value={line.locationId}
            onChange={(locationId) => patch({ locationId })}
            options={locations}
            placeholder={t('stock.doc.pick')}
            error={err('locationId')}
          />
          <Select
            label={t('stock.col.responsible')}
            value={line.responsibleId}
            onChange={(responsibleId) => patch({ responsibleId })}
            options={employees}
            placeholder={t('stock.doc.pick')}
            error={err('responsibleId')}
          />
          <Field label={t('stock.doc.field.receivedOnReal')} error={err('receivedOn')} mono>
            <input type="date" value={line.receivedOn} onChange={(e) => patch({ receivedOn: e.target.value })} />
          </Field>
        </>
      )}
      {(kind === 'receipt' || kind === 'opening') && (
        <>
          <Field label={t('stock.doc.field.unitPrice')} error={err('unitPrice')} optional mono>
            <input type="text" inputMode="decimal" value={line.unitPrice} onChange={(e) => patch({ unitPrice: e.target.value })} />
          </Field>
          <Field label={t('stock.doc.field.lineValue')} error={err('lineValue')} optional mono>
            <input type="text" inputMode="decimal" value={line.lineValue} onChange={(e) => patch({ lineValue: e.target.value })} />
          </Field>
        </>
      )}
      {canRemove && (
        <Button variant="ghost" size="sm" onClick={onRemove}>
          {t('stock.doc.line.remove')}
        </Button>
      )}
    </fieldset>
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
  return (
    <section aria-label={t('stock.doc.lines')} data-testid="lines-editor">
      <h2>{t('stock.doc.lines')}</h2>
      {props.errors['lines'] && <span role="alert">{t(props.errors['lines'])}</span>}
      {lines.map((l, i) => (
        <LineRow
          // Rows are positional (no server id is ever sent), so the index is the stable key.
          key={i}
          index={i}
          line={l}
          kind={props.kind}
          items={items}
          locations={locations}
          employees={employees}
          errors={props.errors}
          onChange={(next) => onChange(lines.map((x, j) => (j === i ? next : x)))}
          onRemove={() => onChange(lines.filter((_, j) => j !== i))}
          canRemove={lines.length > 1}
        />
      ))}
      <Button variant="secondary" disabled={lines.length >= MAX_LINES} onClick={() => onChange([...lines, emptyLine()])}>
        {t('stock.doc.line.add')}
      </Button>
    </section>
  )
}
