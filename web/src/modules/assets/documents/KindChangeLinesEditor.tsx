/** KindChangeLinesEditor — T-1336 / C16. The change of kind document's adapter of LFLinesEditor (the same editor the
 *  other asset documents and the stock forms use): each line is one stock position that leaves the stock register
 *  (item, unit, lot, quantity, location, responsible) and the asset that enters the asset register (kind, inventory
 *  number, name, org unit, location, holder, user). Picking an item sets its base unit and clears the lot. There is no
 *  price column: the value of the card is an open owner question. The assets module does not import modules/stock, so
 *  the few cells are small copies of the stock ones. */
import { useMemo } from 'react'
import { useIntl } from 'react-intl'
import { formatQuantity } from '@/lib/formatQuantity'
import { DocCard } from '@/components/ui/doc/DocLayout'
import { LFLinesEditor } from '@/components/ui/lines/LFLinesEditor'
import { ItemPicker } from '@/components/ui/lines/ItemPicker'
import { normalizeDecimal } from '@/components/ui/lines/pasteRows'
import { formatLines } from '@/components/ui/lines/linesMessages'
import { Select, type SelectOption } from '@/components/ui/Select'
import type { LeCellCtx, LeColumn, LeError } from '@/components/ui/lines/types'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { useLinesMode } from '@/hooks/useLinesMode'
import { useNames } from '../assetsNames'
import { usePickerOptions, anyPickerTruncated } from '../assetsPickers'
import { TruncatedNotice } from '@/components/ui/TruncatedNotice'
import { MAX_ROWS } from '@/lib/entities/fetchAllRecords'
import { buildItemCatalog } from './assetLinesCatalog'
import { MAX_LINES } from './documentForm'
import { TARGET_KINDS, emptyKindChangeLine, validateKindChangeLine, type KindChangeLine } from './kindChangeForm'
import { ASSET_DOCUMENTS_LAYOUT_SCREEN, kindChangeColumnSpecs, kindChangeLineColumns } from './lineColumns'

export const KIND_CHANGE_LINES_SCREEN_ID = 'lf-kind-change-lines'

type Line = KindChangeLine
type Ctx = LeCellCtx<Line>

/** Field of a line error -> the key of its column. */
export const KC_FIELD_COL: Record<string, string> = {
  itemId: 'item', uomId: 'unit', lotId: 'lot', quantity: 'quantity', stockLocationId: 'stockLocation',
  stockResponsibleId: 'stockResponsible', targetKind: 'targetKind', inventoryNumber: 'inventoryNumber',
  assetName: 'assetName', assetOrgUnitId: 'assetOrgUnit', assetLocationId: 'assetLocation',
  materialResponsibleId: 'materialResponsible', actualUserId: 'actualUser',
}

function LotSelect({ ctx, label, pick }: { ctx: Ctx; label: string; pick: string }) {
  const lots = usePickerOptions('catalog_lot', [{ field: 'item_id', op: 'eq', value: ctx.line.itemId }], ctx.line.itemId !== '')
  return <Select label={label} hideLabel value={ctx.line.lotId} onChange={(lotId) => ctx.patch({ lotId })} options={lots} placeholder={pick} />
}

export function KindChangeLinesEditor(props: {
  lines: Line[]
  errors: Record<string, string>
  onChange: (lines: Line[]) => void
  /** A save was attempted: show the errors of every line. */
  showErrors?: boolean
}) {
  const intl = useIntl()
  const locale = useUiLocale()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const [mode, setMode] = useLinesMode(KIND_CHANGE_LINES_SCREEN_ID)
  const { lines } = props
  const items = usePickerOptions('catalog_item')
  const locations = usePickerOptions('location_node')
  const employees = usePickerOptions('org_employee')
  const orgUnits = usePickerOptions('org_unit')
  const catalog = useMemo(() => buildItemCatalog(items), [items])
  const uomIds = lines.map((l) => l.uomId).filter((x) => x !== '')
  const lotIds = lines.map((l) => l.lotId).filter((x) => x !== '')
  const name = useNames(uomIds.length + lotIds.length > 0 ? [{ catalog_uom: uomIds, catalog_lot: lotIds }] : [])
  const dash = t('assets.common.dash')
  const pick = t('assets.doc.pick')
  const none = t('assets.doc.pickNone')

  const columns = useMemo<LeColumn<Line>[]>(() => {
    const base = kindChangeLineColumns((id) => intl.formatMessage({ id }))
    const select = (label: string, field: keyof Line, options: SelectOption[], placeholder: string, view: (l: Line) => string) => ({
      cell: (ctx: Ctx) => (
        <Select label={label} hideLabel value={ctx.line[field]} onChange={(v) => ctx.patch({ [field]: v } as Partial<Line>)} options={options} placeholder={placeholder} />
      ),
      view,
      paste: (line: Line, text: string) => ({ line, reason: text.trim() === '' ? undefined : formatLines(locale, 'r.lotPaste', { x: text }) }),
    })
    const text = (label: string, field: 'inventoryNumber' | 'assetName') => ({
      cell: (ctx: Ctx) => (
        <div className="lf-control">
          <input
            id={ctx.id}
            type="text"
            autoComplete="off"
            aria-label={label}
            aria-invalid={ctx.invalid || undefined}
            aria-describedby={ctx.describedBy}
            value={ctx.line[field]}
            onChange={(e) => ctx.patch({ [field]: e.target.value } as Partial<Line>)}
            onBlur={ctx.onBlur}
          />
        </div>
      ),
      view: (l: Line) => l[field] || dash,
      paste: (line: Line, value: string) => ({ line: { ...line, [field]: value.trim() } }),
    })
    const labelOf = (opts: SelectOption[], id: string) => (id === '' ? dash : opts.find((o) => o.value === id)?.label ?? id)
    const label = (key: string) => t(`assets.doc.kc.col.${key}`)
    const byKey: Record<string, Partial<LeColumn<Line>>> = {
      item: {
        grow: true,
        cell: (ctx: Ctx) => (
          <ItemPicker
            id={ctx.id}
            value={ctx.line.itemId}
            catalog={catalog}
            label={label('item')}
            invalid={ctx.invalid}
            describedBy={ctx.describedBy}
            onBlur={ctx.onBlur}
            onPick={(it) => ctx.patch({ itemId: it?.id ?? '', uomId: it?.unitId ?? '', lotId: '' })}
          />
        ),
        view: (l) => {
          const it = l.itemId === '' ? null : catalog.byId(l.itemId)
          return it ? (it.code ? `${it.code} – ${it.title}` : it.title) : dash
        },
        paste: (line, value) => {
          if (value.trim() === '') return { line }
          const it = catalog.resolve(value)
          return it ? { line: { ...line, itemId: it.id, uomId: it.unitId ?? '', lotId: '' } } : { line, reason: formatLines(locale, 'r.unknown', { x: value }) }
        },
      },
      unit: { view: (l) => (l.uomId === '' ? dash : name('catalog_uom', l.uomId)) },
      lot: {
        cell: (ctx: Ctx) => <LotSelect ctx={ctx} label={label('lot')} pick={none} />,
        view: (l) => (l.lotId === '' ? dash : name('catalog_lot', l.lotId)),
        skip: (l) => l.itemId !== '' && catalog.byId(l.itemId)?.lotTracked === false,
        paste: (line, value) => ({ line, reason: value.trim() === '' ? undefined : formatLines(locale, 'r.lotPaste', { x: value }) }),
      },
      quantity: {
        cell: (ctx: Ctx) => (
          <div className="lf-control lf-control--num">
            <input
              id={ctx.id}
              type="text"
              inputMode="decimal"
              autoComplete="off"
              aria-label={label('quantity')}
              aria-invalid={ctx.invalid || undefined}
              aria-describedby={ctx.describedBy}
              value={ctx.line.quantity}
              onChange={(e) => ctx.patch({ quantity: e.target.value })}
              onBlur={ctx.onBlur}
            />
          </div>
        ),
        view: (l) => (l.quantity === '' ? dash : formatQuantity(l.quantity, intl.locale)),
        paste: (line, value) => ({ line: { ...line, quantity: normalizeDecimal(value) } }),
      },
      stockLocation: select(label('stockLocation'), 'stockLocationId', locations, pick, (l) => labelOf(locations, l.stockLocationId)),
      stockResponsible: select(label('stockResponsible'), 'stockResponsibleId', employees, pick, (l) => labelOf(employees, l.stockResponsibleId)),
      targetKind: select(
        label('targetKind'), 'targetKind', TARGET_KINDS.map((k) => ({ value: k, label: t(`assets.doc.kc.target.${k}`) })), pick,
        (l) => (l.targetKind === '' ? dash : t(`assets.doc.kc.target.${l.targetKind}`)),
      ),
      inventoryNumber: text(label('inventoryNumber'), 'inventoryNumber'),
      assetName: text(label('assetName'), 'assetName'),
      assetOrgUnit: select(label('assetOrgUnit'), 'assetOrgUnitId', orgUnits, t('assets.doc.kc.orgUnitDefault'), (l) => labelOf(orgUnits, l.assetOrgUnitId)),
      assetLocation: select(label('assetLocation'), 'assetLocationId', locations, pick, (l) => labelOf(locations, l.assetLocationId)),
      materialResponsible: select(label('materialResponsible'), 'materialResponsibleId', employees, pick, (l) => labelOf(employees, l.materialResponsibleId)),
      actualUser: select(label('actualUser'), 'actualUserId', employees, none, (l) => labelOf(employees, l.actualUserId)),
    }
    return base.map((c) => ({ key: c.key, colId: c.colId, label: c.label, num: c.num, view: () => dash, ...byKey[c.key] }) as LeColumn<Line>)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [catalog, locations, employees, orgUnits, name, locale, intl])

  const errors = useMemo(() => {
    const out: Record<number, LeError[]> = {}
    for (const [key, id] of Object.entries(props.errors)) {
      const m = /^lines\.(\d+)(?:\.(\w+))?$/.exec(key)
      if (!m) continue
      ;(out[Number(m[1])] ??= []).push({ col: m[2] ? KC_FIELD_COL[m[2]] : undefined, message: t(id) })
    }
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.errors, locale])

  const live = (l: Line): LeError[] => Object.entries(validateKindChangeLine(l)).map(([field, id]) => ({ col: KC_FIELD_COL[field], message: t(id) }))
  const isBlank = (l: Line) => JSON.stringify({ ...l, quantity: l.quantity === '1' ? '' : l.quantity }) === JSON.stringify({ ...emptyKindChangeLine(), quantity: '' })

  return (
    <DocCard area="lines" title={t('assets.doc.lines')} count={lines.length} data-testid="lines-card">
      {anyPickerTruncated(items, locations, employees, orgUnits) && <TruncatedNotice messageId="assets.pickers.truncated" count={MAX_ROWS} />}
      <LFLinesEditor<Line>
        screenId={KIND_CHANGE_LINES_SCREEN_ID}
        resize={{ id: 'kc-lines-edit', screen: ASSET_DOCUMENTS_LAYOUT_SCREEN, cols: kindChangeColumnSpecs() }}
        lines={lines}
        onChange={props.onChange}
        columns={columns}
        blank={emptyKindChangeLine}
        duplicate={(l) => ({ ...l, inventoryNumber: '' })}
        isBlank={isBlank}
        max={MAX_LINES}
        mode={mode}
        onModeChange={setMode}
        errors={errors}
        listError={props.errors['lines'] ? t(props.errors['lines'], { max: MAX_LINES }) : undefined}
        validateLine={live}
        showErrors={props.showErrors}
        searchText={(l) => `${catalog.byId(l.itemId)?.title ?? ''} ${l.inventoryNumber} ${l.assetName} ${l.quantity}`}
        totals={() => ({ col: 'item', node: `${t('assets.doc.lines.total')}: ${lines.length}` })}
      />
    </DocCard>
  )
}
