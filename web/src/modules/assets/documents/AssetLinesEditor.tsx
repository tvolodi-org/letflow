/** AssetLinesEditor — T-1469 / C14 part 2. The asset document's adapter of LFLinesEditor (LE1/LE2, the same editor the
 *  stock form uses): the lines are an asset (picked from the cards, by inventory number or barcode) and a quantity.
 *  The editor owns grid, line by line, keyboard, paste, search, virtual rows and the maximum; this file describes the
 *  columns and hands over the catalog, the per-line check, the scan and the totals. The form state keeps >= 1 line
 *  (a PUT replaces the whole list); a sole empty line is shown as the empty state. No import: there is no import route. */
import { useMemo, type ReactNode } from 'react'
import { useIntl } from 'react-intl'
import { formatQuantity } from '@/lib/formatQuantity'
import { DocCard } from '@/components/ui/doc/DocLayout'
import { LFLinesEditor } from '@/components/ui/lines/LFLinesEditor'
import { ItemPicker } from '@/components/ui/lines/ItemPicker'
import { normalizeDecimal } from '@/components/ui/lines/pasteRows'
import { formatLines } from '@/components/ui/lines/linesMessages'
import type { LeCellCtx, LeColumn, LeError, LeScanResult } from '@/components/ui/lines/types'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { useLinesMode } from '@/hooks/useLinesMode'
import { useNames } from '../assetsNames'
import { usePickerOptions } from '../assetsPickers'
import { buildAssetCatalog, assetLabel } from './assetLinesCatalog'
import { MAX_LINES, emptyLine, validateLine, type LineForm } from './documentForm'
import { ASSET_DOCUMENTS_LAYOUT_SCREEN, lineColumnSpecs, lineColumns } from './lineColumns'

export const ASSET_LINES_SCREEN_ID = 'lf-asset-lines'

/** Field key of a line error -> the key of its column. */
const FIELD_COL: Record<string, string> = { assetId: 'asset', quantity: 'quantity' }

/** Adds one to a decimal quantity text (whole numbers only matter here; a decimal keeps its scale). */
export function incrementQuantity(q: string): string {
  const v = q.trim()
  if (!/^\d+(\.\d+)?$/.test(v)) return '1'
  const [whole, frac = ''] = v.split('.')
  const next = (BigInt(whole!) + 1n).toString()
  return frac === '' ? next : `${next}.${frac}`
}

/** Scan: the first line of the same asset gets +1, else a new line with quantity 1 (the editor checks the maximum). */
export function scanLines(code: string, lines: LineForm[], resolve: (c: string) => { id: string } | null): LeScanResult<LineForm> {
  const asset = resolve(code)
  if (!asset) return { status: 'unknown', lines }
  const at = lines.findIndex((l) => l.assetId === asset.id)
  if (at >= 0) {
    const qty = incrementQuantity(lines[at]!.quantity)
    return { status: 'inc', lines: lines.map((l, i) => (i === at ? { ...l, quantity: qty } : l)), index: at, qty }
  }
  return { status: 'new', lines: [...lines, { assetId: asset.id, quantity: '1' }], index: lines.length, qty: '1' }
}

export function AssetLinesEditor(props: {
  lines: LineForm[]
  errors: Record<string, string>
  onChange: (lines: LineForm[]) => void
  /** A save was attempted: show the errors of every line. */
  showErrors?: boolean
  /** Rendered inside the card, under the editor. */
  footer?: ReactNode
}) {
  const intl = useIntl()
  const locale = useUiLocale()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const [mode, setMode] = useLinesMode(ASSET_LINES_SCREEN_ID)
  const { lines } = props
  const options = usePickerOptions('assets_card')
  const catalog = useMemo(() => buildAssetCatalog(options), [options])
  const name = useNames(lines.filter((l) => l.assetId !== '').length > 0 ? [{ assets_card: lines.filter((l) => l.assetId !== '').map((l) => l.assetId) }] : [])
  const dash = t('assets.common.dash')
  const cardOf = (id: string) => {
    const c = catalog.byId(id)
    return c && c.cardKind !== '' ? { kind: c.cardKind } : undefined
  }

  const columns = useMemo<LeColumn<LineForm>[]>(() => {
    const base = lineColumns((id) => intl.formatMessage({ id }))
    const byKey: Record<string, Partial<LeColumn<LineForm>>> = {
      asset: {
        grow: true,
        cell: (ctx: LeCellCtx<LineForm>) => (
          <ItemPicker
            id={ctx.id}
            value={ctx.line.assetId}
            catalog={catalog}
            label={intl.formatMessage({ id: 'assets.reg.col.asset' })}
            invalid={ctx.invalid}
            describedBy={ctx.describedBy}
            onBlur={ctx.onBlur}
            onPick={(it) => ctx.patch({ assetId: it?.id ?? '' })}
          />
        ),
        view: (l) => {
          if (l.assetId === '') return dash
          const c = catalog.byId(l.assetId)
          return c ? assetLabel(c) : name('assets_card', l.assetId)
        },
        paste: (line, text) => {
          if (text.trim() === '') return { line }
          const it = catalog.resolve(text)
          return it ? { line: { ...line, assetId: it.id } } : { line, reason: formatLines(locale, 'r.unknown', { x: text }) }
        },
      },
      quantity: {
        cell: (ctx: LeCellCtx<LineForm>) => (
          <div className="lf-control lf-control--num">
            <input
              id={ctx.id}
              type="text"
              inputMode="decimal"
              autoComplete="off"
              aria-label={intl.formatMessage({ id: 'assets.reg.col.quantity' })}
              aria-invalid={ctx.invalid || undefined}
              aria-describedby={ctx.describedBy}
              value={ctx.line.quantity}
              onChange={(e) => ctx.patch({ quantity: e.target.value })}
              onBlur={ctx.onBlur}
            />
          </div>
        ),
        view: (l) => (l.quantity === '' ? dash : formatQuantity(l.quantity, intl.locale)),
        paste: (line, text) => ({ line: { ...line, quantity: normalizeDecimal(text) } }),
      },
    }
    return base.map((c) => ({ key: c.key, colId: c.colId, label: c.label, num: c.num, view: () => dash, ...byKey[c.key] }) as LeColumn<LineForm>)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [catalog, locale, intl])

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
    Object.entries(validateLine(l, cardOf)).map(([field, id]) => ({ col: FIELD_COL[field], message: t(id) }))

  return (
    <DocCard area="lines" title={t('assets.doc.lines')} count={lines.length} data-testid="lines-card">
      <LFLinesEditor<LineForm>
        screenId={ASSET_LINES_SCREEN_ID}
        resize={{ id: 'lines-edit', screen: ASSET_DOCUMENTS_LAYOUT_SCREEN, cols: lineColumnSpecs() }}
        lines={lines}
        onChange={props.onChange}
        columns={columns}
        blank={emptyLine}
        duplicate={(l) => ({ ...l })}
        isBlank={(l) => l.assetId === '' && (l.quantity === '' || l.quantity === '1')}
        max={MAX_LINES}
        mode={mode}
        onModeChange={setMode}
        errors={errors}
        listError={props.errors['lines'] ? t(props.errors['lines'], { max: MAX_LINES }) : undefined}
        validateLine={live}
        showErrors={props.showErrors}
        searchText={(l) => `${assetLabel(catalog.byId(l.assetId) ?? { id: '', code: '', title: '' })} ${l.quantity}`}
        scan={(code, ls) => scanLines(code, ls, catalog.resolve)}
        totals={() => ({ col: 'asset', node: `${t('assets.doc.lines.total')}: ${lines.length}` })}
      />
      {props.footer}
    </DocCard>
  )
}
