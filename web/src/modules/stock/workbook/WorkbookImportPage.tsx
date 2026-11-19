/** WorkbookImportPage — REQ-887. Screen 'Загрузка остатков из Excel': check a Qoimeks-layout workbook,
 *  show the Russian remarks and the differences, write the balances from the file, list the loads and cancel one.
 *  Route: admin/stock/workbook-import. Permission guard: StockWorkbookApply (T-2239). */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Dialog } from '@/components/ui/Dialog'
import { DropZone } from '@/components/ui/DropZone'
import { Field } from '@/components/ui/Field'
import { PageHeader } from '@/components/ui/PageHeader'
import { Select } from '@/components/ui/Select'
import { StatusPill, type StatusTone, type StatusGlyph } from '@/components/ui/StatusPill'
import { Tally } from '@/components/ui/Tally'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError } from '@/utils/classifyError'
import { StockIntlProvider } from '../StockIntlProvider'
import { usePickerOptions } from '../register/stockPickers'
import { stockQueryKeys } from '../register/stockQueryKeys'
import { workbookApi, type WorkbookChange, type WorkbookCheckResult, type WorkbookImportRow } from './workbook.api'
import { workbookCheckErrorId, workbookCancelErrorId, type CancelDialogState } from './workbookImportModel'
import { formatStockDateTime } from '../register/stockRegisterModel'

const ACTIVE_ONLY: never[] = []

/** Harness-only: pre-set initial state for screenshot fixtures without async interaction. */
export interface WorkbookImportHarnessProps {
  checkResult?: WorkbookCheckResult | null
  loadResult?: { noChange: true } | { documentId: string; number: string } | null
  checkError?: string | null
  loadError?: string | null
  cancelDialogOpen?: boolean
  cancelAction?: 'cancelled' | 'reverse_pending' | null
  cancelDocId?: string | null
  cancelError?: string | null
  orgUnitId?: string
  importRows?: WorkbookImportRow[]
  harnessChecked?: boolean
}

const HARNESS_IMPORT_ROW: WorkbookImportRow = {
  document_id: 'd1',
  number: 'QCI-2026-000001',
  created_at: '2026-11-18T04:00:00Z',
  created_by: '11111111-0000-0000-0000-000000000001',
  created_by_label: 'Aigerim S.',
  file_name: 'stock-2026-11-18.xlsx',
  sheet: 'Остатки 2026-11-18',
  lines: 42,
  remarks_count: 3,
  state: 'issued',
  reversal_pending: false,
}

function WorkbookImportInner({ harness }: { harness?: WorkbookImportHarnessProps }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) =>
    intl.formatMessage({ id }, values as Record<string, string>)
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const access = useAccess()
  const canReverse = access.can('StockReverse')

  const [orgUnitId, setOrgUnitId] = useState(harness?.orgUnitId ?? '')
  const [file, setFile] = useState<File | null>(null)

  // The org unit and file at the time of the last successful check (tracks whether the form matches the check).
  const [checkedOrgUnitId, setCheckedOrgUnitId] = useState('')
  const [checkedFile, setCheckedFile] = useState<File | null>(null)

  const [checkResult, setCheckResult] = useState<WorkbookCheckResult | null>(harness?.checkResult ?? null)
  const [checkError, setCheckError] = useState<string | null>(harness?.checkError ?? null)
  const [loadResult, setLoadResult] = useState<{ noChange: true } | { documentId: string; number: string } | null>(
    harness?.loadResult ?? null,
  )
  const [loadError, setLoadError] = useState<string | null>(harness?.loadError ?? null)

  const [cancelDialog, setCancelDialog] = useState<CancelDialogState | null>(
    harness?.cancelDialogOpen ? { id: 'd1', lines: 42, reason: '', busy: false, error: harness.cancelError ?? null } : null,
  )
  const [cancelAction, setCancelAction] = useState<{ action: 'cancelled' | 'reverse_pending'; docId: string | null } | null>(
    harness?.cancelAction
      ? { action: harness.cancelAction, docId: harness.cancelDocId ?? null }
      : null,
  )

  const orgUnits = usePickerOptions('org_unit', ACTIVE_ONLY)

  const qc = useQueryClient()
  const importsQuery = useQuery({
    queryKey: stockQueryKeys.workbookImports(tenantId),
    queryFn: () => workbookApi.imports(),
    retry: false,
  })

  const importsRendererState = harness
    ? 'success'
    : importsQuery.isPending
      ? 'loading'
      : importsQuery.isError
        ? classifyError(importsQuery.error)
        : 'success'

  /** True when the current form state matches the last successful check: load is eligible. */
  const isChecked =
    harness?.harnessChecked !== undefined
      ? harness.harnessChecked
      : checkResult !== null && checkedOrgUnitId === orgUnitId && checkedFile !== null && checkedFile === file

  const loadEnabled =
    isChecked && checkResult !== null && checkResult.changes.length > 0 && !checkResult.too_many_changes && loadResult === null

  const checkMutation = useMutation({
    mutationFn: async () => {
      if (!orgUnitId) {
        const e: { status: number; message: string; code: string; details: { reason: string } } = {
          status: 0, message: 'org_unit_required', code: '0', details: { reason: '' },
        }
        throw e
      }
      if (!file) {
        const e: { status: number; message: string; code: string; details: { reason: string } } = {
          status: 0, message: 'file_required', code: '0', details: { reason: '' },
        }
        throw e
      }
      return workbookApi.check(orgUnitId, file)
    },
    onSuccess: (result) => {
      setCheckResult(result)
      setCheckedOrgUnitId(orgUnitId)
      setCheckedFile(file)
      setCheckError(null)
      setLoadResult(null)
      setLoadError(null)
    },
    onError: (err) => {
      setCheckResult(null)
      setCheckedOrgUnitId('')
      setCheckedFile(null)
      setCheckError(workbookCheckErrorId(err))
    },
  })

  const loadMutation = useMutation({
    mutationFn: async () => {
      if (!file || !orgUnitId) throw new Error('check_first')
      return workbookApi.apply(orgUnitId, file, file.name)
    },
    onSuccess: (result) => {
      setLoadError(null)
      if ('applied' in result && result.applied === false) {
        setLoadResult({ noChange: true })
      } else if ('document_id' in result) {
        setLoadResult({ documentId: result.document_id, number: result.number })
        void qc.invalidateQueries({ queryKey: stockQueryKeys.workbookImports(tenantId) })
      }
    },
    onError: (err) => {
      setLoadError(workbookCheckErrorId(err))
    },
  })

  const cancelMutation = useMutation({
    mutationFn: async ({ id, reason }: { id: string; reason: string }) =>
      workbookApi.cancel(id, reason),
    onSuccess: (result, vars) => {
      setCancelDialog(null)
      setCancelAction({ action: result.action, docId: vars.id })
      void qc.invalidateQueries({ queryKey: stockQueryKeys.workbookImports(tenantId) })
    },
    onError: (err) => {
      setCancelDialog((d) => (d ? { ...d, busy: false, error: workbookCancelErrorId(err) } : null))
    },
  })

  const onOrgUnitChange = (v: string) => {
    setOrgUnitId(v)
    if (v !== checkedOrgUnitId) {
      setCheckResult(null)
      setCheckError(null)
      setLoadResult(null)
      setLoadError(null)
    }
  }

  const onFile = (f: File) => {
    setFile(f)
    if (f !== checkedFile) {
      setCheckResult(null)
      setCheckError(null)
      setLoadResult(null)
      setLoadError(null)
    }
  }

const STATE_PILL: Record<string, { tone: StatusTone; glyph: StatusGlyph }> = {
    draft: { tone: 'neutral', glyph: 'ring' },
    issued: { tone: 'neutral', glyph: 'half' },
    posted: { tone: 'success', glyph: 'dot' },
    reversed: { tone: 'info', glyph: 'ring' },
    cancelled: { tone: 'neutral', glyph: 'dash' },
  }
  const REVERSAL_PILL = { tone: 'warning' as const, glyph: 'half' as const }

  const changeColumns: DataTableColumn<WorkbookChange>[] = [
    {
      key: 'row',
      label: t('stock.wb.col.row'),
      render: (r) => (r.row !== null && r.row !== undefined ? String(r.row) : '—'),
      align: 'end',
      mono: true,
    },
    { key: 'item_code', label: t('stock.wb.col.article'), render: (r) => r.item_code },
    { key: 'item_name', label: t('stock.wb.col.name'), render: (r) => r.item_name },
    {
      key: 'place_code',
      label: t('stock.wb.col.place'),
      render: (r) =>
        r.row === null || r.row === undefined
          ? `${r.place_code} ${t('stock.wb.emptied')}`
          : r.place_code,
    },
    { key: 'book_quantity', label: t('stock.wb.col.book'), align: 'end', mono: true, render: (r) => r.book_quantity },
    { key: 'file_quantity', label: t('stock.wb.col.file'), align: 'end', mono: true, render: (r) => r.file_quantity },
    { key: 'difference', label: t('stock.wb.col.difference'), align: 'end', mono: true, render: (r) => r.difference },
  ]

  const importRows = harness?.importRows ?? (harness?.cancelDialogOpen ? [HARNESS_IMPORT_ROW] : importsQuery.data?.rows ?? [])

  const loadColumns: DataTableColumn<WorkbookImportRow>[] = [
    {
      key: 'number',
      label: t('stock.wb.loads.col.number'),
      mono: true,
      render: (r) =>
        r.number ? (
          <Link to={`/admin/stock/documents/${r.document_id}`} data-testid={`load-doc-${r.document_id}`}>
            {r.number}
          </Link>
        ) : (
          '—'
        ),
    },
    {
      key: 'created_at',
      label: t('stock.wb.loads.col.date'),
      mono: true,
      render: (r) => formatStockDateTime(r.created_at, { locale: intl.locale }),
    },
    { key: 'created_by', label: t('stock.wb.loads.col.user'), render: (r) => r.created_by_label || '—' },
    { key: 'file_name', label: t('stock.wb.loads.col.file'), render: (r) => r.file_name ?? '—' },
    { key: 'lines', label: t('stock.wb.loads.col.lines'), align: 'end', mono: true, render: (r) => String(r.lines) },
    {
      key: 'remarks_count',
      label: t('stock.wb.loads.col.remarks'),
      align: 'end',
      mono: true,
      render: (r) => (r.remarks_count !== null && r.remarks_count !== undefined ? String(r.remarks_count) : '—'),
    },
    {
      key: 'state',
      label: t('stock.wb.loads.col.state'),
      render: (r) => {
        const pill = r.reversal_pending ? REVERSAL_PILL : (STATE_PILL[r.state] ?? { tone: 'neutral' as const, glyph: 'ring' as const })
        const label = r.reversal_pending ? t('stock.wb.loads.reversalPending') : t(`stock.wb.loads.state.${r.state}`)
        return <StatusPill tone={pill.tone} glyph={pill.glyph}>{label}</StatusPill>
      },
    },
    {
      key: 'cancel',
      label: '',
      render: (r) => {
        const canCancel = canReverse && r.state !== 'cancelled' && r.state !== 'reversed' && !r.reversal_pending
        return canCancel ? (
          <Button
            variant="secondary"
            size="sm"
            data-testid={`cancel-${r.document_id}`}
            onClick={() =>
              setCancelDialog({ id: r.document_id, lines: r.lines, reason: '', busy: false, error: null })
            }
          >
            {t('stock.wb.loads.cancel')}
          </Button>
        ) : null
      },
    },
  ]

  const confirmCancel = () => {
    if (!cancelDialog || cancelDialog.reason.trim() === '') return
    setCancelDialog((d) => (d ? { ...d, busy: true, error: null } : d))
    cancelMutation.mutate({ id: cancelDialog.id, reason: cancelDialog.reason })
  }

  return (
    <div className="lf-form">
      <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.wb.title')} lede={t('stock.wb.lede')} />

      <section className="lf-card" aria-labelledby="wb-check-h" data-testid="wb-check-section">
        <div className="lf-card__head">
          <h2 className="lf-card__title" id="wb-check-h">{t('stock.wb.card.check')}</h2>
        </div>
        <div className="lf-card__body lf-form">
          <Select
            label={t('stock.wb.orgUnit')}
            value={orgUnitId}
            onChange={onOrgUnitChange}
            options={orgUnits}
            placeholder={t('stock.wb.orgUnit.placeholder')}
            data-testid="wb-org-unit"
            width="l"
          />
          <DropZone
            accept=".xlsx"
            title={t('stock.wb.dropzone.title')}
            limits={t('stock.wb.dropzone.limits')}
            invalidText={t('stock.wb.dropzone.invalid')}
            chosen={file ? { file } : null}
            onFile={onFile}
          />
          <div className="lf-form__actions">
            <Button
              variant="secondary"
              data-testid="wb-check"
              loading={checkMutation.isPending}
              disabled={!orgUnitId || !file}
              onClick={() => checkMutation.mutate()}
            >
              {checkMutation.isPending ? t('stock.wb.check.checking') : t('stock.wb.check')}
            </Button>
          </div>
          {checkError !== null && (
            <div data-testid="wb-check-error">
              <Banner tone="danger">{t(checkError)}</Banner>
            </div>
          )}
        </div>
      </section>

      {checkResult !== null && (
        <section className="lf-card" aria-labelledby="wb-result-h" data-testid="wb-check-result">
          <div className="lf-card__head">
            <h2 className="lf-card__title" id="wb-result-h">{t('stock.wb.card.result')}</h2>
          </div>
          <div className="lf-card__body lf-form">
            <p className="lf-muted" data-testid="wb-sheet">
              {t('stock.wb.result.sheet')}: <strong>{checkResult.sheet}</strong>
              {' · '}
              {t('stock.wb.result.rowsRead', { n: checkResult.rows_read })}
            </p>

            <Tally
              aria-label={t('stock.wb.tally.label')}
              items={[
                { label: t('stock.wb.tally.read'), value: checkResult.rows_read },
                { label: t('stock.wb.tally.changes'), value: checkResult.changes.length },
                { label: t('stock.wb.tally.unchanged'), value: checkResult.unchanged_count },
                { label: t('stock.wb.tally.remarks'), value: checkResult.remarks.length },
              ]}
            />

            {checkResult.remarks.length > 0 && (
              <div data-testid="wb-remarks">
                <Banner tone="warning">
                  <strong>{t('stock.wb.result.remarks')}</strong>
                  <p className="caption">{t('stock.wb.result.remarksHint')}</p>
                  <ul className="lf-help">
                    {checkResult.remarks.map((r, i) => (
                      <li key={i}>{r.text}</li>
                    ))}
                  </ul>
                </Banner>
              </div>
            )}

            {checkResult.too_many_changes && (
              <div data-testid="wb-too-many-changes">
                <Banner tone="warning">{t('stock.wb.result.tooManyChanges')}</Banner>
              </div>
            )}

            {checkResult.changes.length === 0 && !checkResult.too_many_changes && (
              <p data-testid="wb-no-changes">{t('stock.wb.result.noChanges')}</p>
            )}

            {checkResult.changes.length > 0 && (
              <>
                <p className="caption lf-muted" data-testid="wb-unchanged-count">
                  {t('stock.wb.result.unchangedCount', { n: checkResult.unchanged_count })}
                </p>
                <DataTable
                  columns={changeColumns}
                  data={checkResult.changes}
                  isLoading={false}
                  emptyMessage={t('stock.wb.result.noChanges')}
                  getRowId={(r) => `${r.item_code}|${r.place_code}`}
                  labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
                />
              </>
            )}

            {loadResult === null && (
              <div className="lf-form__actions">
                <Button
                  variant="primary"
                  data-testid="wb-load"
                  loading={loadMutation.isPending}
                  disabled={!loadEnabled}
                  onClick={() => loadMutation.mutate()}
                >
                  {loadMutation.isPending ? t('stock.wb.load.loading') : t('stock.wb.load')}
                </Button>
                {!isChecked && (
                  <span className="lf-hint" data-testid="wb-load-hint">
                    {t('stock.wb.err.checkFirst')}
                  </span>
                )}
              </div>
            )}

            {loadError !== null && (
              <div data-testid="wb-load-error">
                <Banner tone="danger">{t(loadError)}</Banner>
              </div>
            )}

            {loadResult !== null && 'noChange' in loadResult && (
              <div data-testid="wb-load-no-change">
                <Banner tone="info">{t('stock.wb.load.noChange')}</Banner>
              </div>
            )}

            {loadResult !== null && 'documentId' in loadResult && (
              <div data-testid="wb-load-success">
                <Banner tone="success">
                  {t('stock.wb.load.success', { number: loadResult.number })}
                  {' '}
                  <Link to={`/admin/stock/documents/${loadResult.documentId}`} data-testid="wb-doc-link">
                    {t('stock.wb.load.docLink')}
                  </Link>
                </Banner>
              </div>
            )}
          </div>
        </section>
      )}

      {cancelAction !== null && (
        <div data-testid="wb-cancel-result">
          <Banner tone={cancelAction.action === 'cancelled' ? 'success' : 'info'}>
            {cancelAction.action === 'cancelled'
              ? t('stock.wb.cancel.cancelled')
              : t('stock.wb.cancel.reversePending')}
            {cancelAction.action === 'reverse_pending' && cancelAction.docId && (
              <>
                {' '}
                <Link to={`/admin/stock/documents/${cancelAction.docId}`} data-testid="wb-cancel-doc-link">
                  {t('stock.wb.cancel.reversePendingLink')}
                </Link>
              </>
            )}
          </Banner>
        </div>
      )}

      <section className="lf-card" aria-labelledby="wb-loads-h" data-testid="wb-loads-section">
        <div className="lf-card__head">
          <h2 className="lf-card__title" id="wb-loads-h">{t('stock.wb.loads.title')}</h2>
        </div>
        <div className="lf-card__body">
          <QueryStateBoundary
            state={importsRendererState}
            onRetry={() => void importsQuery.refetch()}
          >
            <DataTable
              columns={loadColumns}
              data={importRows}
              isLoading={false}
              emptyMessage={t('stock.wb.loads.empty')}
              getRowId={(r) => r.document_id}
              labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
            />
          </QueryStateBoundary>
        </div>
      </section>

      {cancelDialog !== null && (
        <Dialog
          title={t('stock.wb.cancel.title')}
          open
          confirmText={t('stock.wb.cancel.confirm')}
          cancelText={t('stock.wb.cancel.close')}
          isLoading={cancelDialog.busy}
          confirmDisabled={cancelDialog.reason.trim() === ''}
          error={cancelDialog.error !== null && cancelDialog.error !== undefined ? t(cancelDialog.error) : null}
          onConfirm={confirmCancel}
          onCancel={() => !cancelDialog.busy && setCancelDialog(null)}
          testId="wb-cancel-dialog"
        >
          <Field label={t('stock.wb.cancel.reason')} hint={t('stock.wb.cancel.reasonHint')}>
            <textarea
              rows={3}
              maxLength={500}
              value={cancelDialog.reason}
              data-testid="wb-cancel-reason"
              onChange={(e) => setCancelDialog((d) => (d ? { ...d, reason: e.target.value, error: null } : d))}
            />
          </Field>
        </Dialog>
      )}
    </div>
  )
}

/** `harness`: pre-set state for screenshot fixtures without async interaction. */
export default function WorkbookImportPage({ harness }: { harness?: WorkbookImportHarnessProps } = {}) {
  return (
    <StockIntlProvider>
      <WorkbookImportInner harness={harness} />
    </StockIntlProvider>
  )
}

/** Harness alias used by fixture files. */
export { WorkbookImportPage as WorkbookImportPageHarness }
