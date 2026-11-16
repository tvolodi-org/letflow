/** ProblemReportsPage -- T-2007. The owner's inbox of problem reports (platform company, permission
 *  `ProblemReportsManage`, route `/admin/problem-reports`): the list of reports, the captured facts beside the text, and
 *  one-click decisions (in work, ask, not done, fixed, answer). It calls only the three routes of
 *  `/platform-problem-reports`; every rule (permission, platform tenant, transitions, text checks) stays on the server.
 *  Customer text and captured context are data: rendered only as React text. No tenant or user id is sent or shown.
 *  The detail follows the user's layout setting (`ui.document_layout`): Row puts the text and the facts side by side,
 *  Tabs gives each its own tab. */
import React, { useState } from 'react'
import { useIntl, type IntlShape } from 'react-intl'
import { useSearchParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { EmptyState } from '@/components/ui/EmptyState'
import { Select } from '@/components/ui/Select'
import { Skeleton } from '@/components/ui/Skeleton'
import { StatusPill } from '@/components/ui/StatusPill'
import { ListDetail, DetailTabs, type DetailTab } from '@/components/ui/listDetail'
import { PageHeader } from '@/components/ui/PageHeader'
import { useDocumentLayout } from '@/hooks/useDocumentLayout'
import { useDecideReport, useInboxList, useInboxReport, useReportImage } from '@/hooks/useProblemReportsInbox'
import { useToast } from '@/hooks/useToast'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { formatDateTime } from '@/i18n/format'
import type { DecisionAction, InboxDetail, InboxFilter, InboxSummary } from '@/api/platformProblemReports'
import type { ApiError } from '@/types/api'
import { DecisionDialog } from './DecisionDialog'
import { ProblemReportsIntlProvider } from './ProblemReportsIntlProvider'
import { ActionsTable, FactsList, RequestsTable } from './ReportFacts'
import { ACTIONS, CAPS, STATUS_LOOK, UNKNOWN_LOOK, checkDecisionText, decisionErrorKind, isOpen, normalizeFilter, reportFacts } from './problemReportsModel'

const t = (intl: IntlShape, id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `problemReports.${id}` }, values)

function ReportImageThumbnail({ reportId, imageId, contentType }: { reportId: string; imageId: string; contentType: string }) {
  const query = useReportImage(reportId, imageId)

  if (query.isLoading) return <div className="lf-report__thumb lf-report__thumb--loading" aria-busy="true" />
  if (query.isError || !query.data) return null

  return (
    <a
      className="lf-report__thumb"
      href={query.data}
      target="_blank"
      rel="noopener noreferrer"
      data-testid={`pr-image-${imageId}`}
    >
      <img src={query.data} alt={contentType} />
    </a>
  )
}

function ReportPill({ status }: { status: string }) {
  const intl = useIntl()
  const look = STATUS_LOOK[status] ?? UNKNOWN_LOOK
  return (
    <StatusPill tone={look.tone} glyph={look.glyph} data-testid={`pr-status-${status}`}>
      {STATUS_LOOK[status] ? t(intl, `status.${status}`) : status}
    </StatusPill>
  )
}

function Dash({ value }: { value: string | null | undefined }) {
  return <>{value && value !== '' ? value : '—'}</>
}

interface DetailProps {
  id: string
  onDecide: (action: DecisionAction) => void
}

function ReportDetail({ id, onDecide }: DetailProps) {
  const intl = useIntl()
  const layout = useDocumentLayout()
  const query = useInboxReport(id)
  const [tab, setTab] = useState('')

  if (query.isLoading) {
    return (
      <div className="lf-card__body" role="status" aria-label={t(intl, 'loading')} data-testid="pr-detail-loading">
        <Skeleton width="40%" />
        <Skeleton />
        <Skeleton width="70%" />
      </div>
    )
  }
  if (query.isError || !query.data) {
    const status = (query.error as ApiError | null)?.status
    const gone = status === 404
    return (
      <div className="lf-card__body">
        <Banner
          tone="danger"
          action={
            gone ? undefined : (
              <Button variant="secondary" size="sm" onClick={() => void query.refetch()}>
                {t(intl, 'retry')}
              </Button>
            )
          }
        >
          <span data-testid="pr-detail-error">{t(intl, gone ? 'notFound' : status === 503 ? 'unavailable' : 'loadError')}</span>
        </Banner>
      </div>
    )
  }

  const report: InboxDetail = query.data
  const facts = reportFacts(report)
  const permissions = report.reporter?.permissions ?? []
  const open = isOpen(report.status)
  const asTabs = layout === 'tabs'

  const textCard = (
    <section data-testid="pr-text" aria-label={t(intl, 'text.heading')}>
      <h3 className="lf-form__title">{t(intl, 'text.heading')}</h3>
      <p className="lf-pr__text">{report.text}</p>
      {report.images && report.images.length > 0 && (
        <div className="lf-report__thumbs" data-testid="pr-images">
          {report.images.map((img) => (
            <ReportImageThumbnail key={img.id} reportId={report.id} imageId={img.id} contentType={img.content_type} />
          ))}
        </div>
      )}
    </section>
  )
  const factsCard = (
    <section data-testid="pr-facts" aria-label={t(intl, 'facts.heading')}>
      <h3 className="lf-form__title">{t(intl, 'facts.heading')}</h3>
      <FactsList rows={facts.rows} />
    </section>
  )

  const decisionPanel =
    report.last_action == null ? (
      <p className="lf-muted" data-testid="pr-decision-none">{t(intl, 'decision.none')}</p>
    ) : (
      <div className="lf-form" data-testid="pr-decision-panel">
        <dl className="lf-dl">
          <dt>{t(intl, 'decision.last')}</dt>
          <dd>{report.last_action}</dd>
          <dt>{t(intl, 'fact.decided')}</dt>
          <dd className="mono">{report.decided_at ? formatDateTime(report.decided_at) : '—'}</dd>
        </dl>
        {report.reply_text && (
          <section>
            <h3 className="lf-form__title">{t(intl, 'decision.reply')}</h3>
            <p className="lf-pr__text" data-testid="pr-reply-text">{report.reply_text}</p>
          </section>
        )}
        {report.dev_summary && (
          <section>
            <h3 className="lf-form__title">{t(intl, 'decision.dev')}</h3>
            <p className="lf-pr__text" data-testid="pr-dev-summary">{report.dev_summary}</p>
          </section>
        )}
      </div>
    )

  const rest: DetailTab[] = [
    { id: 'actions', label: t(intl, 'tab.actions'), count: facts.actions.length, panel: <ActionsTable rows={facts.actions} /> },
    { id: 'requests', label: t(intl, 'tab.requests'), count: facts.requests.length, panel: <RequestsTable rows={facts.requests} /> },
    {
      id: 'rights',
      label: t(intl, 'tab.rights'),
      count: permissions.length,
      panel:
        permissions.length === 0 ? (
          <p className="lf-muted">{t(intl, 'rights.empty')}</p>
        ) : (
          <p className="mono lf-pr__text" data-testid="pr-rights">{permissions.join(', ')}</p>
        ),
    },
    { id: 'decision', label: t(intl, 'tab.decision'), panel: decisionPanel },
  ]
  const tabs: DetailTab[] = asTabs
    ? [
        { id: 'report', label: t(intl, 'tab.report'), panel: <div className="lf-card__body">{textCard}</div> },
        { id: 'facts', label: t(intl, 'tab.facts'), panel: <div className="lf-card__body">{factsCard}</div> },
        ...rest,
      ]
    : rest

  return (
    <div data-testid="pr-detail" role="region" aria-label={report.number}>
      <DetailHeader
        title={report.number}
        path={`${report.reporter?.tenant_name ?? '—'} · ${report.reporter?.name ?? '—'}`}
        status={
          <>
            <ReportPill status={report.status} />
            {report.status === 'in_work' && report.last_action === 'ask' && (
              <span className="lf-muted" data-testid="pr-question-sent">{t(intl, 'questionSent')}</span>
            )}
          </>
        }
        actions={
          open ? (
            <>
              {ACTIONS.map((action) => (
                <Button
                  key={action}
                  variant={action === 'answer' ? 'primary' : 'secondary'}
                  size="md"
                  data-testid={`pr-action-${action}`}
                  onClick={() => onDecide(action)}
                >
                  {t(intl, `action.${action}`)}
                </Button>
              ))}
            </>
          ) : (
            <span className="lf-muted" data-testid="pr-closed-note">{t(intl, 'closedNote')}</span>
          )
        }
      />
      {!asTabs && (
        <div className="lf-pr__grid" data-testid="pr-grid">
          {textCard}
          {factsCard}
        </div>
      )}
      <DetailTabs idPrefix="pr" tabs={tabs} selected={tab} onChange={setTab} aria-label={t(intl, 'tabs.label')} />
    </div>
  )
}

function ProblemReportsBody() {
  const intl = useIntl()
  const toast = useToast()
  const qc = useQueryClient()
  const keys = useTenantScopedQueryKeys().problemReportsInbox
  const [params, setParams] = useSearchParams()
  const selected = params.get('report')
  const filter = normalizeFilter(params.get('status'))
  const list = useInboxList(filter)
  const decide = useDecideReport()

  const [action, setAction] = useState<DecisionAction | null>(null)
  const [text, setText] = useState('')
  const [fieldError, setFieldError] = useState<string | undefined>()
  const [dialogError, setDialogError] = useState<string | null>(null)

  const rows: InboxSummary[] = list.data?.pages.flatMap((p) => p.reports) ?? []

  const update = (changes: Record<string, string | null>) => {
    const next = new URLSearchParams(params)
    for (const [k, v] of Object.entries(changes)) {
      if (v === null) next.delete(k)
      else next.set(k, v)
    }
    setParams(next)
  }
  const select = (id: string | null) => update({ report: id })

  const closeDialog = () => {
    setAction(null)
    setText('')
    setFieldError(undefined)
    setDialogError(null)
  }
  const openDialog = (a: DecisionAction) => {
    setText('')
    setFieldError(undefined)
    setDialogError(null)
    setAction(a)
  }

  const confirm = () => {
    if (!action || !selected) return
    const check = checkDecisionText(action, text)
    if (check === 'empty') return setFieldError(t(intl, 'check.empty'))
    if (check === 'tooLong') return setFieldError(t(intl, 'check.tooLong', { limit: CAPS[action] }))
    setFieldError(undefined)
    setDialogError(null)
    decide.mutate(
      { id: selected, action, text: text.trim() },
      {
        onSuccess: (detail) => {
          closeDialog()
          toast.success(t(intl, 'toast.saved', { status: STATUS_LOOK[detail.status] ? t(intl, `status.${detail.status}`) : detail.status }))
        },
        onError: (err) => {
          const kind = decisionErrorKind(err)
          if (kind === 'copies' || kind === 'secret' || kind === 'invalid') {
            setFieldError(t(intl, `err.${kind}`))
            return
          }
          setDialogError(t(intl, `err.${kind}`))
          if (kind === 'closed') {
            void qc.invalidateQueries({ queryKey: keys.detail(selected) })
            void qc.invalidateQueries({ queryKey: keys.lists() })
          }
        },
      },
    )
  }

  const columns: DataTableColumn<InboxSummary>[] = [
    { id: 'number', header: t(intl, 'col.number'), mono: true, render: (r) => r.number },
    { id: 'status', header: t(intl, 'col.status'), hideStackLabel: true, render: (r) => <ReportPill status={r.status} /> },
    { id: 'company', header: t(intl, 'col.company'), render: (r) => <Dash value={r.reporter?.tenant_name} /> },
    { id: 'text', header: t(intl, 'col.text'), render: (r) => <span className="lf-pr__preview">{r.text_preview}</span> },
  ]

  const listError = list.isError ? t(intl, (list.error as ApiError | null)?.status === 503 ? 'unavailable' : 'loadError') : undefined

  return (
    <div className="lf-form">
      <PageHeader eyebrow={t(intl, 'eyebrow')} title={t(intl, 'title')} lede={t(intl, 'lede')} />
      <ListDetail
        screen="platform.problem-reports"
        listLabel={t(intl, 'list.pane')}
        listDefault={40}
        escapeCloses={action === null}
        tools={
          <Select
            label={t(intl, 'filter.label')}
            value={filter}
            onChange={(v) => update({ status: v === 'open' ? null : v, report: null })}
            options={(['open', 'closed', 'all'] as InboxFilter[]).map((f) => ({ value: f, label: t(intl, `filter.${f}`) }))}
            data-testid="pr-filter"
          />
        }
        list={
          <div data-testid="pr-list">
            <DataTable
              columns={columns}
              data={rows}
              isLoading={list.isLoading}
              error={listError}
              onRetry={() => void list.refetch()}
              labels={{ loading: t(intl, 'loading'), retry: t(intl, 'retry') }}
              density="compact"
              getRowId={(r) => r.id}
              selectedId={selected}
              onRowClick={(r) => select(r.id)}
              emptyMessage={t(intl, `empty.${filter}`)}
              emptyText={t(intl, `empty.${filter}.text`)}
            />
          </div>
        }
        listFooter={
          list.isLoading || list.isError ? undefined : (
            <div className="lf-btn-row lf-pr__foot" data-testid="pr-list-foot">
              <span className="lf-muted" data-testid="pr-count">{t(intl, 'count', { count: rows.length })}</span>
              {list.hasNextPage && (
                <Button variant="secondary" size="sm" data-testid="pr-load-older" loading={list.isFetchingNextPage} onClick={() => void list.fetchNextPage()}>
                  {t(intl, 'loadOlder')}
                </Button>
              )}
            </div>
          )
        }
        defaultSelectId={rows[0]?.id ?? null}
        onDefaultSelect={select}
        empty={
          <div className="lf-card__body">
            <EmptyState title={t(intl, 'pick')} data-testid="pr-pick" />
          </div>
        }
        detailOpen={selected !== null}
        onClose={() => select(null)}
        detail={selected ? <ReportDetail key={selected} id={selected} onDecide={openDialog} /> : <></>}
      />
      <DecisionDialog
        action={action}
        text={text}
        onText={(v) => {
          setText(v)
          setFieldError(undefined)
        }}
        fieldError={fieldError}
        error={dialogError}
        busy={decide.isPending}
        onConfirm={confirm}
        onCancel={closeDialog}
      />
    </div>
  )
}

export default function ProblemReportsPage(): React.ReactElement {
  return (
    <ProblemReportsIntlProvider>
      <ProblemReportsBody />
    </ProblemReportsIntlProvider>
  )
}
