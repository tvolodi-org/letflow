/** ReportFacts -- T-2007: the captured facts of one problem report and its two tables. Every value is customer data and
 *  is rendered only as React text (no HTML, no markdown, no link built from it). */
import { Fragment } from 'react'
import { useIntl } from 'react-intl'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { formatDateTime } from '@/i18n/format'
import type { ActionRow, FactRow, RequestRow } from './problemReportsModel'

export function FactsList({ rows }: { rows: FactRow[] }) {
  const intl = useIntl()
  return (
    <dl className="lf-dl" data-testid="pr-facts-list">
      {rows.map((r) => (
        <Fragment key={r.id}>
          <dt>{r.label ? intl.formatMessage({ id: `problemReports.fact.${r.label}` }) : r.name}</dt>
          <dd className={r.mono ? 'mono' : undefined}>{r.date ? formatDateTime(r.value) : r.value}</dd>
        </Fragment>
      ))}
    </dl>
  )
}

export function ActionsTable({ rows }: { rows: ActionRow[] }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id: `problemReports.${id}` })
  const columns: DataTableColumn<ActionRow & { rowKey: string }>[] = [
    { id: 'at', header: t('col.at'), mono: true, render: (r) => r.at || '—' },
    { id: 'kind', header: t('col.kind'), render: (r) => r.kind },
    { id: 'name', header: t('col.name'), render: (r) => r.name },
  ]
  return (
    <div data-testid="pr-actions-table">
      <DataTable columns={columns} data={rows.map((r, i) => ({ ...r, rowKey: String(i) }))} density="compact" getRowId={(r) => r.rowKey} emptyMessage={t('actions.empty')} />
    </div>
  )
}

export function RequestsTable({ rows }: { rows: RequestRow[] }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id: `problemReports.${id}` })
  const columns: DataTableColumn<RequestRow & { rowKey: string }>[] = [
    { id: 'at', header: t('col.at'), mono: true, render: (r) => r.at || '—' },
    { id: 'method', header: t('col.method'), mono: true, render: (r) => r.method },
    { id: 'path', header: t('col.path'), mono: true, render: (r) => r.path || '—' },
    { id: 'status', header: t('col.httpStatus'), mono: true, render: (r) => r.status || '—' },
    { id: 'error', header: t('col.errorCode'), mono: true, render: (r) => r.error_code || '—' },
    { id: 'trace', header: t('col.trace'), mono: true, render: (r) => r.trace_id || '—' },
  ]
  return (
    <div data-testid="pr-requests-table">
      <DataTable columns={columns} data={rows.map((r, i) => ({ ...r, rowKey: String(i) }))} density="compact" getRowId={(r) => r.rowKey} emptyMessage={t('requests.empty')} />
    </div>
  )
}
