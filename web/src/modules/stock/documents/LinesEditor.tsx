/** LinesEditor — the stock document's adapter of LFLinesEditor (T-1448, was GH 3769 / REQ-722, T-1379). It describes the lines of the
 *  seven document kinds as columns (item, lot, quantity with the item's unit, unit price and line value for a receipt and an
 *  opening balance, plus location, responsible and the real receipt date for an opening balance) and hands the editor its
 *  catalog, validation, scan, totals and the remembered mode. The editor owns grid, line by line, keyboard, paste, search.
 *  The form state keeps >= 1 line (a PUT replaces the whole list); a sole empty line is shown as the empty state. */
import { useMemo, useRef, type ChangeEvent, type ReactNode } from 'react'
import { useIntl } from 'react-intl'
import { formatMoney } from '@/lib/formatDecimal'
import { formatQuantity } from '@/lib/formatQuantity'
import { DocCard } from '@/components/ui/doc/DocLayout'
import { LFLinesEditor } from '@/components/ui/lines/LFLinesEditor'
import { ItemPicker } from '@/components/ui/lines/ItemPicker'
import { normalizeDecimal } from '@/components/ui/lines/pasteRows'
import { formatLines } from '@/components/ui/lines/linesMessages'
import type { LeCellCtx, LeColumn, LeError, LeImportController, LeScanResult } from '@/components/ui/lines/types'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { useLinesMode } from '@/hooks/useLinesMode'
import { Select } from '@/components/ui/Select'
import { DateCell } from '@/components/ui/DateField'
import { useNames } from '../register/stockNames'
import { usePickerOptions, type PickerOption, anyPickerTruncated } from '../register/stockPickers'
import { TruncatedNotice } from '@/components/ui/TruncatedNotice'
import { MAX_ROWS } from '@/lib/entities/fetchAllRecords'
import { MAX_LINES, emptyLine, sumDecimals, validateLine, type DocKind, type LineForm } from './documentsModel'
import { DOCUMENTS_LAYOUT_SCREEN, lineColumns, lineColumnSpecs } from './lineColumns'
import { buildCatalog, itemLabel } from './linesCatalog'
import { documentsApi, type StockDocument } from './documents.api'
import { OPENING_LINE_TYPE, importErrorText, summariseImport } from './openingImport'
import { MAX_FILE_BYTES } from '@/pages/admin/import/importModel'
import { runImport } from '@/pages/admin/import/importApi'

export const LINES_SCREEN_ID = 'stock-documents.lines'

/** Field key of a line error -> the key of its column. */
const FIELD_COL: Record<string, string> = { itemId: 'item', lotId: 'lot', quantity: 'quantity', unitPrice: 'unitPrice', lineValue: 'lineValue', locationId: 'location', responsibleId: 'responsible', receivedOn: 'receivedOn' }

/** Lots of one item (only mounted rows ask; a row with no item asks nothing). */
function LotSelect({ ctx, label, pick }: { ctx: LeCellCtx<LineForm>; label: string; pick: string }) {
  const lots = usePickerOptions('catalog_lot', [{ field: 'item_id', op: 'eq', value: ctx.line.itemId }], ctx.line.itemId !== '')
  return <Select label={label} hideLabel value={ctx.line.lotId} onChange={(lotId) => ctx.patch({ lotId })} options={lots} placeholder={pick} />
}

/** The shared reference label ("code - title") of a record, never its id (the view of a posted document, T-1378). */
function RefName({ type, id }: { type: 'catalog_item' | 'catalog_lot' | 'catalog_uom'; id: string }) {
  const name = useNames([{ [type]: [id] }])
  return <>{name(type, id)}</>
}

function QuantityView({ line }: { line: LineForm }) {
  const intl = useIntl()
  return (
    <span className="lf-lines__qty">
      <span>{formatQuantity(line.quantity, intl.locale)}</span> {line.uomId ? <RefName type="catalog_uom" id={line.uomId} /> : null}
    </span>
  )
}

export function incrementQuantity(q: string): string {
  return q.trim() === '' ? '1' : (sumDecimals([q.trim(), '1']) ?? '1')
}

/** Scan: the first line of the same item gets +1, else a new line with quantity 1 (pure; the editor checks the maximum). */
export function scanLines(code: string, lines: LineForm[], resolve: (c: string) => { id: string; unitId?: string } | null): LeScanResult<LineForm> {
  const item = resolve(code)
  if (!item) return { status: 'unknown', lines }
  const at = lines.findIndex((l) => l.itemId === item.id)
  if (at >= 0) {
    const qty = incrementQuantity(lines[at]!.quantity)
    return { status: 'inc', lines: lines.map((l, i) => (i === at ? { ...l, quantity: qty } : l)), index: at, qty }
  }
  return { status: 'new', lines: [...lines, { ...emptyLine(), itemId: item.id, uomId: item.unitId ?? '', quantity: '1' }], index: lines.length, qty: '1' }
}

export function LinesEditor(props: {
  kind: DocKind
  lines: LineForm[]
  errors: Record<string, string>
  onChange: (lines: LineForm[]) => void
  /** A save was attempted: show the errors of every line. */
  showErrors?: boolean
  readOnly?: boolean
  noPermission?: boolean
  /** Rendered inside the card, under the editor. */
  footer?: ReactNode
  /** Import from Excel (opening documents): the route writes the lines of the saved draft, so the screen reloads them. */
  importer?: { documentId: string; disabledReason?: string; onImported: (fresh: StockDocument) => void }
}) {
  const intl = useIntl()
  const locale = useUiLocale()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const [mode, setMode] = useLinesMode(LINES_SCREEN_ID)
  const { kind, lines } = props
  const opening = kind === 'opening'
  const itemOpts = usePickerOptions('catalog_item')
  const uoms = usePickerOptions('catalog_uom')
  const locations = usePickerOptions('location_node', [], opening)
  const employees = usePickerOptions('org_employee', [], opening)
  const catalog = useMemo(() => buildCatalog(itemOpts), [itemOpts])
  const unitName = (id: string) => uoms.find((o) => o.value === id)?.label ?? ''
  const nameOf = (opts: readonly PickerOption[], id: string) => opts.find((o) => o.value === id)?.label ?? ''
  const dash = t('stock.common.dash')
  const withValue = kind === 'receipt' || opening

  const columns = useMemo<LeColumn<LineForm>[]>(() => {
    const base = lineColumns(kind, (id) => intl.formatMessage({ id }))
    const num = (field: 'quantity' | 'unitPrice' | 'lineValue', label: string) => (ctx: LeCellCtx<LineForm>): ReactNode => (
      <div className="lf-control lf-control--num">
        <input
          id={ctx.id}
          type="text"
          inputMode="decimal"
          autoComplete="off"
          aria-label={label}
          aria-invalid={ctx.invalid || undefined}
          aria-describedby={ctx.describedBy}
          value={ctx.line[field]}
          onChange={(e) => ctx.patch({ [field]: e.target.value })}
          onBlur={ctx.onBlur}
        />
        {field === 'quantity' && (
          <span className="lf-affix">
            <span className="sr-only">{intl.formatMessage({ id: 'stock.col.unit' })} </span>
            {unitName(ctx.line.uomId) || dash}
          </span>
        )}
      </div>
    )
    const numPaste = (field: 'quantity' | 'unitPrice' | 'lineValue') => (line: LineForm, text: string) => ({ line: { ...line, [field]: normalizeDecimal(text) } })
    const byKey: Record<string, Partial<LeColumn<LineForm>>> = {
      item: {
        grow: true,
        cell: (ctx) => (
          <ItemPicker
            id={ctx.id}
            value={ctx.line.itemId}
            catalog={catalog}
            label={intl.formatMessage({ id: 'stock.col.item' })}
            invalid={ctx.invalid}
            describedBy={ctx.describedBy}
            onBlur={ctx.onBlur}
            onPick={(it) => ctx.patch({ itemId: it?.id ?? '', uomId: it?.unitId ?? '', lotId: '' })}
          />
        ),
        view: (l) => (l.itemId ? <RefName type="catalog_item" id={l.itemId} /> : dash),
        paste: (line, text) => {
          if (text.trim() === '') return { line }
          const it = catalog.resolve(text)
          return it
            ? { line: { ...line, itemId: it.id, uomId: it.unitId ?? '', lotId: '' } }
            : { line, reason: formatLines(locale, 'r.unknown', { x: text }) }
        },
      },
      lot: {
        cell: (ctx) => <LotSelect ctx={ctx} label={intl.formatMessage({ id: 'stock.col.lot' })} pick={intl.formatMessage({ id: 'stock.doc.pickNone' })} />,
        view: (l) => (l.lotId ? <RefName type="catalog_lot" id={l.lotId} /> : dash),
        skip: (l) => l.itemId !== '' && catalog.byId(l.itemId)?.lotTracked === false,
        paste: (line, text) => ({ line, reason: text.trim() === '' ? undefined : formatLines(locale, 'r.lotPaste', { x: text }) }),
      },
      quantity: { cell: num('quantity', intl.formatMessage({ id: 'stock.col.quantity' })), view: (l) => (l.quantity === '' ? dash : <QuantityView line={l} />), paste: numPaste('quantity') },
      unitPrice: { savedHidden: true, cell: num('unitPrice', intl.formatMessage({ id: 'stock.doc.field.unitPrice' })), view: (l) => formatMoney(l.unitPrice, intl.locale) || dash, paste: numPaste('unitPrice') },
      lineValue: { savedHidden: true, cell: num('lineValue', intl.formatMessage({ id: 'stock.doc.field.lineValue' })), view: (l) => formatMoney(l.lineValue, intl.locale) || dash },
      location: {
        cell: (ctx) => <Select label={intl.formatMessage({ id: 'stock.col.location' })} hideLabel value={ctx.line.locationId} onChange={(locationId) => ctx.patch({ locationId })} options={locations} placeholder={intl.formatMessage({ id: 'stock.doc.pick' })} />,
        view: (l) => nameOf(locations, l.locationId) || dash,
        savedHidden: true,
      },
      responsible: {
        cell: (ctx) => <Select label={intl.formatMessage({ id: 'stock.col.responsible' })} hideLabel value={ctx.line.responsibleId} onChange={(responsibleId) => ctx.patch({ responsibleId })} options={employees} placeholder={intl.formatMessage({ id: 'stock.doc.pick' })} />,
        view: (l) => nameOf(employees, l.responsibleId) || dash,
        savedHidden: true,
      },
      receivedOn: {
        cell: (ctx) => <DateCell label={intl.formatMessage({ id: 'stock.doc.field.receivedOnReal' })} value={ctx.line.receivedOn} onChange={(receivedOn) => ctx.patch({ receivedOn })} invalid={ctx.invalid} describedBy={ctx.describedBy} id={ctx.id} />,
        view: (l) => l.receivedOn || dash,
        savedHidden: true,
      },
    }
    return base.map((c) => ({ key: c.key, colId: c.colId, label: c.label, num: c.num, view: () => dash, ...byKey[c.key] }) as LeColumn<LineForm>)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [kind, catalog, uoms, locations, employees, locale, intl])

  const errors = useMemo(() => {
    const out: Record<number, LeError[]> = {}
    for (const [key, id] of Object.entries(props.errors)) {
      const m = /^lines\.(\d+)(?:\.(\w+))?$/.exec(key)
      if (!m) continue
      const i = Number(m[1])
      ;(out[i] ??= []).push({ col: m[2] ? FIELD_COL[m[2]] : undefined, message: t(id) })
    }
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.errors, locale])

  const live = (l: LineForm): LeError[] =>
    Object.entries(validateLine(kind, l)).map(([field, id]) => ({ col: FIELD_COL[field], message: t(id) }))

  const imp = props.importer
  const fileRef = useRef<HTMLInputElement>(null)
  const ctlRef = useRef<LeImportController<LineForm> | null>(null)
  const onImportFile = async (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    e.target.value = ''
    const ctl = ctlRef.current
    if (!file || !imp || !ctl) return
    if (file.size > MAX_FILE_BYTES) {
      ctl.showError(t('stock.doc.import.tooBig'))
      return
    }
    let summary
    try {
      summary = summariseImport(locale, await runImport(OPENING_LINE_TYPE, file, false))
    } catch (err) {
      ctl.showError(importErrorText(locale, err))
      return
    }
    try {
      imp.onImported(await documentsApi.get(imp.documentId))
    } catch {
      ctl.showError(t('stock.doc.import.reloadFailed'))
      return
    }
    ctl.showResult(summary)
  }

  const total = withValue ? sumDecimals(lines.map((l) => l.lineValue)) : null

  return (
    <DocCard area="lines" title={t('stock.doc.lines')} count={lines.length} data-testid="lines-card">
      {anyPickerTruncated(itemOpts, uoms, locations, employees) && <TruncatedNotice messageId="stock.pickers.truncated" count={MAX_ROWS} />}
      <LFLinesEditor<LineForm>
        screenId="lf-stock-lines"
        resize={{ id: props.readOnly ? 'lines' : 'lines-edit', screen: DOCUMENTS_LAYOUT_SCREEN, cols: lineColumnSpecs(kind) }}
        lines={lines}
        onChange={props.onChange}
        columns={columns}
        blank={emptyLine}
        duplicate={(l) => ({ ...l, externalRefSystem: '', externalRefId: '' })}
        isBlank={(l) => Object.values(l).every((v) => v === '')}
        max={MAX_LINES}
        mode={mode}
        onModeChange={setMode}
        readOnly={props.readOnly}
        noPermission={props.noPermission}
        errors={errors}
        listError={props.errors['lines'] ? t(props.errors['lines'], { max: MAX_LINES }) : undefined}
        validateLine={live}
        showErrors={props.showErrors}
        searchText={(l) => `${itemLabel(catalog.byId(l.itemId) ?? { id: '', code: '', title: '' })} ${l.quantity}`}
        scan={(code, ls) => scanLines(code, ls, catalog.resolve)}
        onImport={imp ? (ctl) => { ctlRef.current = ctl; fileRef.current?.click() } : undefined}
        importDisabledReason={imp?.disabledReason}
        totals={withValue ? () => ({ col: 'lineValue', node: formatMoney(total, intl.locale) || dash }) : undefined}
      />
      {imp && <input ref={fileRef} type="file" accept=".xlsx" hidden tabIndex={-1} aria-hidden="true" data-testid="lines-import-file" onChange={(e) => void onImportFile(e)} />}
      {props.footer}
    </DocCard>
  )
}
