/** OpeningLinesEditor — T-1877. The opening document's adapter of LFLinesEditor (the editor the other asset documents
 *  use): each line is one asset card with its own placement (location, material responsible, actual user, decision 0083
 *  D3). The cost, accumulated depreciation and acquisition date are NOT line fields: they stay on the card (0083 D2) and
 *  are shown read-only from the picked card. Import from Excel (the route writes the lines of the saved draft, found by
 *  the header's external pair) and the template download are the stock opening's pattern. The assets module does not
 *  import modules/stock, so the import helpers are a small copy (`openingImport.ts`). */
import { useMemo, useRef, useState, type ChangeEvent } from 'react'
import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { useAccess } from '@/auth/access/useAccess'
import { formatDate } from '@/i18n/format'
import { formatMoney } from '@/lib/formatDecimal'
import { formatQuantity } from '@/lib/formatQuantity'
import { saveBlob } from '@/lib/saveBlob'
import { DocCard } from '@/components/ui/doc/DocLayout'
import { LFLinesEditor } from '@/components/ui/lines/LFLinesEditor'
import { ItemPicker } from '@/components/ui/lines/ItemPicker'
import { normalizeDecimal } from '@/components/ui/lines/pasteRows'
import { formatLines } from '@/components/ui/lines/linesMessages'
import { Button } from '@/components/ui/Button'
import { Select, type SelectOption } from '@/components/ui/Select'
import { TruncatedNotice } from '@/components/ui/TruncatedNotice'
import type { LeCellCtx, LeColumn, LeError, LeImportController, LeScanResult } from '@/components/ui/lines/types'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { useLinesMode } from '@/hooks/useLinesMode'
import { MAX_ROWS } from '@/lib/entities/fetchAllRecords'
import { MAX_FILE_BYTES } from '@/pages/admin/import/importModel'
import { downloadTemplate, runImport } from '@/pages/admin/import/importApi'
import { useNames } from '../assetsNames'
import { anyPickerTruncated, usePickerOptions, usePickerState } from '../assetsPickers'
import { ASSETS_CARD_WRITE } from '../assetsPermissions'
import { assetDocumentsApi, type AssetDocument } from './assetDocuments.api'
import { assetLabel, buildAssetCatalog } from './assetLinesCatalog'
import { incrementQuantity } from './AssetLinesEditor'
import { MAX_LINES } from './documentForm'
import { ASSET_DOCUMENTS_LAYOUT_SCREEN, openingColumnSpecs, openingLineColumns } from './lineColumns'
import { emptyOpeningLine, validateOpeningLine, type OpeningLine } from './openingForm'
import { OPENING_LINE_TYPE, importErrorText, summariseImport } from './openingImport'

export const OPENING_LINES_SCREEN_ID = 'lf-opening-lines'
export const ENTITIES_RECORDS_IMPORT = 'EntitiesRecordsImport'
export const ENTITIES_RECORDS_EXPORT = 'EntitiesRecordsExport'

type Line = OpeningLine

/** Field of a line error -> the key of its column. */
export const OPENING_FIELD_COL: Record<string, string> = {
  assetId: 'asset', quantity: 'quantity', locationId: 'location', responsibleId: 'responsible', userId: 'user',
}

/** Scan: the first line of the same asset gets +1, else a new line with quantity 1 (the editor checks the maximum). */
export function scanOpeningLines(code: string, lines: Line[], resolve: (c: string) => { id: string } | null): LeScanResult<Line> {
  const asset = resolve(code)
  if (!asset) return { status: 'unknown', lines }
  const at = lines.findIndex((l) => l.assetId === asset.id)
  if (at >= 0) {
    const qty = incrementQuantity(lines[at]!.quantity)
    return { status: 'inc', lines: lines.map((l, i) => (i === at ? { ...l, quantity: qty } : l)), index: at, qty }
  }
  return { status: 'new', lines: [...lines, { ...emptyOpeningLine(), assetId: asset.id }], index: lines.length, qty: '1' }
}

export interface OpeningImporter {
  documentId: string
  /** Why the import cannot run now (a title on the disabled button). */
  disabledReason?: string
  onImported: (fresh: AssetDocument) => void
}

export function OpeningLinesEditor(props: {
  lines: Line[]
  errors: Record<string, string>
  onChange: (lines: Line[]) => void
  /** A save was attempted: show the errors of every line. */
  showErrors?: boolean
  importer?: OpeningImporter
}) {
  const intl = useIntl()
  const locale = useUiLocale()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const [mode, setMode] = useLinesMode(OPENING_LINES_SCREEN_ID)
  const { lines } = props
  const { can } = useAccess()
  const { options, status } = usePickerState('assets_card')
  const locations = usePickerOptions('location_node')
  const employees = usePickerOptions('org_employee')
  const catalog = useMemo(() => buildAssetCatalog(options), [options])
  const name = useNames(lines.some((l) => l.assetId !== '') ? [{ assets_card: lines.filter((l) => l.assetId !== '').map((l) => l.assetId) }] : [])
  const dash = t('assets.common.dash')
  const pick = t('assets.doc.pick')
  const none = t('assets.doc.pickNone')
  const cardOf = (id: string) => {
    const c = catalog.byId(id)
    return c && c.cardKind !== '' ? { kind: c.cardKind } : undefined
  }
  const fieldOf = (assetId: string, key: string): string => {
    const v = options.find((o) => o.value === assetId)?.fields?.[key]
    return typeof v === 'string' ? v.trim() : ''
  }

  const columns = useMemo<LeColumn<Line>[]>(() => {
    const base = openingLineColumns((id) => intl.formatMessage({ id }))
    const labelOf = (opts: SelectOption[], id: string) => (id === '' ? dash : opts.find((o) => o.value === id)?.label ?? id)
    const select = (label: string, field: 'locationId' | 'responsibleId' | 'userId', opts: SelectOption[], placeholder: string) => ({
      cell: (ctx: LeCellCtx<Line>) => (
        <Select label={label} hideLabel value={ctx.line[field]} onChange={(v) => ctx.patch({ [field]: v } as Partial<Line>)} options={opts} placeholder={placeholder} />
      ),
      view: (l: Line) => labelOf(opts, l[field]),
      paste: (line: Line, text: string) => ({ line, reason: text.trim() === '' ? undefined : formatLines(locale, 'r.lotPaste', { x: text }) }),
    })
    const label = (key: string) => intl.formatMessage({ id: `assets.doc.opening.col.${key}` })
    const byKey: Record<string, Partial<LeColumn<Line>>> = {
      asset: {
        grow: true,
        cell: (ctx: LeCellCtx<Line>) => (
          <ItemPicker
            id={ctx.id}
            value={ctx.line.assetId}
            catalog={catalog}
            label={label('asset')}
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
        cell: (ctx: LeCellCtx<Line>) => (
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
        paste: (line, text) => ({ line: { ...line, quantity: normalizeDecimal(text) } }),
      },
      location: select(label('location'), 'locationId', locations, none),
      responsible: select(label('responsible'), 'responsibleId', employees, pick),
      user: select(label('user'), 'userId', employees, none),
      // Read-only: the card's own values (no cell, so no input; a paste is ignored).
      cost: { view: (l) => formatMoney(fieldOf(l.assetId, 'acquisition_cost'), intl.locale) || dash, paste: (line) => ({ line }) },
      depreciation: { view: (l) => formatMoney(fieldOf(l.assetId, 'accumulated_depreciation'), intl.locale) || dash, paste: (line) => ({ line }) },
      acquired: { view: (l) => formatDate(fieldOf(l.assetId, 'acquisition_date'), undefined, intl.locale) || dash, paste: (line) => ({ line }) },
    }
    return base.map((c) => ({ key: c.key, colId: c.colId, label: c.label, num: c.num, view: () => dash, ...byKey[c.key] }) as LeColumn<Line>)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [catalog, options, locations, employees, locale, intl])

  const errors = useMemo(() => {
    const out: Record<number, LeError[]> = {}
    for (const [key, id] of Object.entries(props.errors)) {
      const m = /^lines\.(\d+)(?:\.(\w+))?$/.exec(key)
      if (!m) continue
      ;(out[Number(m[1])] ??= []).push({ col: m[2] ? OPENING_FIELD_COL[m[2]] : undefined, message: t(id) })
    }
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.errors, locale])

  const live = (l: Line): LeError[] => Object.entries(validateOpeningLine(l, cardOf)).map(([field, id]) => ({ col: OPENING_FIELD_COL[field], message: t(id) }))

  // ---- import from Excel (the stock opening's pattern) ----
  const imp = props.importer
  const fileRef = useRef<HTMLInputElement>(null)
  const ctlRef = useRef<LeImportController<Line> | null>(null)
  const [templateError, setTemplateError] = useState(false)
  const onImportFile = async (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    e.target.value = ''
    const ctl = ctlRef.current
    if (!file || !imp || !ctl) return
    if (file.size > MAX_FILE_BYTES) {
      ctl.showError(t('assets.doc.import.tooBig'))
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
      imp.onImported(await assetDocumentsApi.get(imp.documentId))
    } catch {
      ctl.showError(t('assets.doc.import.reloadFailed'))
      return
    }
    ctl.showResult(summary)
  }
  const onTemplate = async () => {
    setTemplateError(false)
    try {
      const { blob } = await downloadTemplate(OPENING_LINE_TYPE)
      saveBlob(blob, `${OPENING_LINE_TYPE}-template.xlsx`)
    } catch {
      setTemplateError(true)
    }
  }

  const isBlank = (l: Line) => l.assetId === '' && l.locationId === '' && l.responsibleId === '' && l.userId === '' && (l.quantity === '' || l.quantity === '1')

  return (
    <DocCard area="lines" title={t('assets.doc.lines')} count={lines.length} data-testid="lines-card">
      {anyPickerTruncated(options, locations, employees) && <TruncatedNotice messageId="assets.pickers.truncated" count={MAX_ROWS} />}
      {status === 'ready' && options.length === 0 && (
        <div className="lf-empty" role="status" data-testid="no-cards">
          <p className="lf-empty__title">{t('assets.doc.noCards.title')}</p>
          <p className="lf-empty__text">{t('assets.doc.noCards.text')}</p>
          {can(ASSETS_CARD_WRITE) ? (
            <Link to="/admin/assets/cards">{t('assets.doc.noCards.link')}</Link>
          ) : (
            <p className="lf-empty__text">{t('assets.doc.noCards.askAdmin')}</p>
          )}
        </div>
      )}
      <LFLinesEditor<Line>
        screenId={OPENING_LINES_SCREEN_ID}
        resize={{ id: 'op-lines-edit', screen: ASSET_DOCUMENTS_LAYOUT_SCREEN, cols: openingColumnSpecs() }}
        lines={lines}
        onChange={props.onChange}
        columns={columns}
        blank={emptyOpeningLine}
        duplicate={(l) => ({ ...l, extRefSystem: '', extRefId: '' })}
        isBlank={isBlank}
        max={MAX_LINES}
        mode={mode}
        onModeChange={setMode}
        errors={errors}
        listError={props.errors['lines'] ? t(props.errors['lines'], { max: MAX_LINES }) : undefined}
        validateLine={live}
        showErrors={props.showErrors}
        searchText={(l) => `${assetLabel(catalog.byId(l.assetId) ?? { id: '', code: '', title: '' })} ${l.quantity}`}
        scan={(code, ls) => scanOpeningLines(code, ls, catalog.resolve)}
        onImport={imp ? (ctl) => { ctlRef.current = ctl; fileRef.current?.click() } : undefined}
        importDisabledReason={imp?.disabledReason}
        totals={() => ({ col: 'asset', node: `${t('assets.doc.lines.total')}: ${lines.length}` })}
      />
      {imp && <input ref={fileRef} type="file" accept=".xlsx" hidden tabIndex={-1} aria-hidden="true" data-testid="lines-import-file" onChange={(e) => void onImportFile(e)} />}
      <div className="lf-opening-help">
        <p className="lf-hint" data-testid="opening-card-hint">{t('assets.doc.opening.fromCard')}</p>
        {imp && (
          <div data-testid="opening-import-help">
            <p className="lf-hint">{t('assets.doc.import.columns')}</p>
            {can(ENTITIES_RECORDS_EXPORT) && (
              <div className="lf-btn-row">
                <Button variant="secondary" onClick={() => void onTemplate()} data-testid="opening-template">{t('assets.doc.import.template')}</Button>
                {templateError && <span role="alert">{t('assets.doc.import.templateFailed')}</span>}
              </div>
            )}
          </div>
        )}
      </div>
    </DocCard>
  )
}
