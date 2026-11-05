/** DifferencesPanel — GH 3761 / REQ-720 criterion 2. From status counted on: mark the sheet signed, issue the
 *  differences sheet, show its lines, mark it signed, and list the signature marks. Buttons follow the order's
 *  state and the user's atoms; the server stays the authority (a refusal is shown as its own message). */
import { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { FormSection } from '@/components/ui/FormSection'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { StatusPill } from '@/components/ui/StatusPill'
import { useToast } from '@/hooks/useToast'
import { classifyError } from '@/utils/classifyError'
import { useNames } from '../register/stockNames'
import type { NameIds } from '../register/stockRegisterModel'
import { countsApi, type CountLine, type CountOrder, type DifferenceLine, type SignatureRow } from './counts.api'
import { usePagedList } from './CountSheet'
import { countsQueryKeys } from './countsQueryKeys'
import { canIssueDifferences, canSignDifferences, canSignSheet, formatInZone, reasonMessageId, requiredSigners } from './countsModel'
import { SignersDialog } from './SignersDialog'
import { useCountsWrite } from './useCountsWrite'
import { formatQuantity } from '@/lib/formatQuantity'

type Dlg = 'sheet' | 'differences' | null

function Differences({ orderId }: { orderId: string }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const query = useQuery({ queryKey: countsQueryKeys.differences(tenantId, orderId), queryFn: () => countsApi.differences(orderId), retry: false })
  const rows = query.data?.lines ?? []
  const ids: NameIds = {}
  for (const r of rows) {
    const add = (type: keyof NameIds, id: string | null | undefined) => {
      if (id) (ids[type] ??= []).push(id)
    }
    add('location_node', r.location_id)
    add('catalog_item', r.catalog_item_id)
    add('catalog_lot', r.catalog_lot_id)
    add('org_employee', r.responsible_employee_id)
    add('catalog_uom', r.unit_ref)
  }
  const name = useNames([ids])
  const dash = t('stock.common.dash')
  const columns: DataTableColumn<DifferenceLine>[] = [
    { key: 'line', label: t('counts.col.line'), render: (r) => r.line_no, mono: true },
    { key: 'location', label: t('counts.col.location'), render: (r) => name('location_node', r.location_id) },
    { key: 'item', label: t('counts.col.item'), render: (r) => name('catalog_item', r.catalog_item_id) },
    { key: 'lot', label: t('counts.col.lot'), render: (r) => name('catalog_lot', r.catalog_lot_id) || dash },
    { key: 'responsible', label: t('counts.col.responsible'), render: (r) => name('org_employee', r.responsible_employee_id) || dash },
    { key: 'unit', label: t('counts.col.unit'), render: (r) => name('catalog_uom', r.unit_ref) },
    { key: 'book', label: t('counts.col.book'), render: (r) => formatQuantity(r.book_quantity), mono: true, align: 'end' },
    { key: 'counted', label: t('counts.col.counted'), render: (r) => formatQuantity(r.counted_quantity), mono: true, align: 'end' },
    { key: 'difference', label: t('counts.differences.difference'), render: (r) => formatQuantity(r.difference), mono: true, align: 'end' },
    {
      key: 'direction',
      label: t('counts.differences.direction'),
      render: (r) =>
        r.direction === 'surplus' ? (
          <StatusPill tone="success" glyph="dot">{t('counts.differences.surplus')}</StatusPill>
        ) : (
          <StatusPill tone="danger" glyph="triangle">{t('counts.differences.shortage')}</StatusPill>
        ),
    },
  ]
  const state = query.isPending ? 'loading' : query.isError ? classifyError(query.error) : 'success'
  return (
    <QueryStateBoundary state={state} onRetry={() => void query.refetch()}>
    <div className="lf-field" data-testid="differences-table">
      {query.data && (
        <p className="lf-hint" data-testid="differences-head">
          {query.data.number ?? dash} · v{query.data.version_no} · {formatInZone(query.data.issued_at) || dash}
        </p>
      )}
      <DataTable
        columns={columns}
        data={rows}
        isLoading={query.isPending}
        getRowId={(r) => String(r.line_no)}
        emptyMessage={t('counts.differences.empty')}
        emptyText={t('counts.differences.emptyText')}
        labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
      />
    </div>
    </QueryStateBoundary>
  )
}

function Signatures({ orderId }: { orderId: string }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const query = useQuery({ queryKey: countsQueryKeys.signatures(tenantId, orderId), queryFn: () => countsApi.signatures(orderId), retry: false })
  const rows = query.data?.rows ?? []
  const name = useNames([{ org_employee: rows.map((r) => r.employee_id) }])
  const columns: DataTableColumn<SignatureRow>[] = [
    { key: 'doc', label: t('counts.signatures.document'), render: (r) => t(`counts.signatures.kind.${r.document_kind}`) },
    { key: 'who', label: t('counts.signatures.employee'), render: (r) => name('org_employee', r.employee_id) },
    { key: 'role', label: t('counts.signatures.role'), render: (r) => t(`counts.signers.role.${r.signer_role}`) },
    { key: 'at', label: t('counts.signatures.markedAt'), render: (r) => formatInZone(r.marked_at), mono: true },
  ]
  const state = query.isPending ? 'loading' : query.isError ? classifyError(query.error) : 'success'
  return (
    <QueryStateBoundary state={state} onRetry={() => void query.refetch()}>
    <div className="lf-field" data-testid="signatures-table">
      <DataTable
        columns={columns}
        data={rows}
        isLoading={query.isPending}
        getRowId={(r) => `${r.document_kind}-${r.version_no}-${r.employee_id}`}
        emptyMessage={t('counts.signatures.empty')}
        emptyText={t('counts.signatures.emptyText')}
        labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
      />
    </div>
    </QueryStateBoundary>
  )
}

/** Nothing is loaded before the sheet is closed: the hooks live in the inner component. */
export function DifferencesPanel({ order }: { order: CountOrder }) {
  const { can } = useAccess()
  const show = ['counted', 'signed', 'posted'].includes(order.status) && (can('StockCountRecord') || !!order.sheet_signed_at)
  return show ? <DifferencesBody order={order} /> : null
}

function DifferencesBody({ order }: { order: CountOrder }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const toast = useToast()
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [dlg, setDlg] = useState<Dlg>(null)
  // All pages of the sheet lines: the responsible employees must be complete before the dialog opens.
  const lines = usePagedList<CountLine>(countsQueryKeys.lines(tenantId, order.id), (cursor) =>
    countsApi.lines(order.id, cursor ? { cursor } : {}),
  )
  useEffect(() => {
    if (lines.hasNextPage && !lines.isFetchingNextPage) void lines.fetchNextPage()
  }, [lines])
  const allLines = (lines.data?.pages ?? []).flatMap((p) => p.rows)
  const linesReady = !lines.isPending && !lines.hasNextPage
  const differences = useQuery({
    queryKey: countsQueryKeys.differences(tenantId, order.id),
    queryFn: () => countsApi.differences(order.id),
    enabled: !!order.differences_document_id && dlg === 'differences',
    retry: false,
  })
  const diffLines = differences.data?.lines ?? []
  const signers = requiredSigners(order, dlg === 'differences' ? diffLines : allLines)
  const name = useNames([{ org_employee: signers.map((s) => s.id) }])
  const sign = useCountsWrite((arg: { kind: 'sheet' | 'differences'; ids: string[] }) =>
    arg.kind === 'sheet' ? countsApi.signSheet(order.id, arg.ids) : countsApi.signDifferences(order.id, arg.ids),
  )
  const issue = useCountsWrite(() => countsApi.issueDifferences(order.id))

  async function confirm(ids: string[]) {
    if (dlg === null) return
    const res = await sign.submit({ kind: dlg, ids })
    if (res.ok) {
      toast.success(t(dlg === 'sheet' ? 'counts.toast.sheetSigned' : 'counts.toast.differencesSigned'))
      setDlg(null)
    }
  }
  async function issueNow() {
    const res = await issue.submit(undefined)
    if (res.ok) toast.success(t('counts.toast.differencesIssued'))
  }
  function closeDialog() {
    setDlg(null)
    sign.reset()
  }

  const dialogReady = linesReady && (dlg !== 'differences' || differences.isSuccess)
  return (
    <>
      <FormSection title={t('counts.differences.title')}>
        <div className="lf-form" data-testid="differences-panel">
          {issue.error !== null && <Banner tone="danger">{t(reasonMessageId(issue.error))}</Banner>}
          <div className="lf-form__actions">
            {canSignSheet(order, can) && (
              <Button variant="primary" size="sm" loading={!linesReady} onClick={() => setDlg('sheet')} data-testid="sign-sheet">
                {t('counts.action.signSheet')}
              </Button>
            )}
            {canIssueDifferences(order, can) && (
              <Button variant="primary" size="sm" loading={issue.isPending} onClick={() => void issueNow()} data-testid="issue-differences">
                {t('counts.action.issueDifferences')}
              </Button>
            )}
            {canSignDifferences(order, can) && (
              <Button variant="primary" size="sm" onClick={() => setDlg('differences')} data-testid="sign-differences">
                {t('counts.action.signDifferences')}
              </Button>
            )}
          </div>
          {order.differences_document_id && <Differences orderId={order.id} />}
        </div>
      </FormSection>
      {order.sheet_signed_at && (
        <FormSection title={t('counts.signatures.title')}>
          <Signatures orderId={order.id} />
        </FormSection>
      )}
      {dlg !== null && dialogReady && (
        <SignersDialog
          title={t(dlg === 'sheet' ? 'counts.signers.sheetTitle' : 'counts.signers.differencesTitle')}
          signers={signers}
          nameOf={(id) => name('org_employee', id)}
          isLoading={sign.isPending}
          error={sign.error !== null ? t(reasonMessageId(sign.error)) : null}
          onConfirm={(ids) => void confirm(ids)}
          onCancel={closeDialog}
        />
      )}
    </>
  )
}
