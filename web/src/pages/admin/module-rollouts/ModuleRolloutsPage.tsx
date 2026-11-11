/** ModuleRolloutsPage -- T-1660 (fleet driver part 3, BA decision T-1651 item 6). The platform operator's screen for
 *  module rollouts: list them, see each company's outcome (incl. "outside window"), see a halted rollout, start one and
 *  resume one. It calls only the four existing routes of `/platform-module-rollouts`; every rule (permission,
 *  platform tenant, window, halting) stays on the server. No tenant identifier is sent. Shared components only.
 */
import React, { useEffect, useState } from 'react'
import { useIntl, type IntlShape } from 'react-intl'
import { useQueryClient } from '@tanstack/react-query'
import { useSearchParams } from 'react-router-dom'
import type { ModuleOutcomeStatus, ModuleRollout, ModuleRolloutOutcome, ModuleRolloutResult } from '@/api/platformModuleRollouts'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { Field } from '@/components/ui/Field'
import { MasterDetail } from '@/components/ui/MasterDetail'
import { PageHeader } from '@/components/ui/PageHeader'
import { CoreHelpLink } from '@/pages/help/CoreHelpLink'
import { StatusPill, type StatusGlyph, type StatusTone } from '@/components/ui/StatusPill'
import { useModuleRolloutsList, useTenantNames, useModuleRolloutStatus, useResumeModuleRollout, useStartModuleRollout } from '@/hooks/useModuleRollouts'
import { formatDateTime } from '@/i18n/format'
import type { ApiError } from '@/types/api'
import { ModuleRolloutsIntlProvider } from './ModuleRolloutsIntlProvider'
import { canResume } from './moduleRolloutsModel'

const MAX_MODULE_ID = 255
const COUNT_ORDER: ModuleOutcomeStatus[] = ['pending', 'running', 'succeeded', 'failed', 'skipped', 'outside_window']

interface Look {
  tone: StatusTone
  glyph: StatusGlyph
}
const ROLLOUT_LOOK: Record<ModuleRollout['status'], Look> = {
  running: { tone: 'info', glyph: 'half' },
  completed: { tone: 'success', glyph: 'dot' },
  halted: { tone: 'danger', glyph: 'triangle' },
}
const OUTCOME_LOOK: Record<ModuleOutcomeStatus, Look> = {
  pending: { tone: 'info', glyph: 'half' },
  running: { tone: 'info', glyph: 'half' },
  succeeded: { tone: 'success', glyph: 'dot' },
  failed: { tone: 'danger', glyph: 'triangle' },
  skipped: { tone: 'neutral', glyph: 'dash' },
  outside_window: { tone: 'warning', glyph: 'ring' },
}

const t = (intl: IntlShape, id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `moduleRollouts.${id}` }, values)

function RolloutPill({ status }: { status: ModuleRollout['status'] }) {
  const intl = useIntl()
  const look = ROLLOUT_LOOK[status] ?? { tone: 'neutral', glyph: 'ring' }
  return (
    <StatusPill tone={look.tone} glyph={look.glyph} data-testid={`module-rollout-status-${status}`}>
      {ROLLOUT_LOOK[status] ? t(intl, `status.${status}`) : status}
    </StatusPill>
  )
}

function OutcomePill({ status }: { status: ModuleOutcomeStatus }) {
  const intl = useIntl()
  const look = OUTCOME_LOOK[status] ?? { tone: 'neutral', glyph: 'ring' }
  return (
    <StatusPill tone={look.tone} glyph={look.glyph} data-testid={`module-outcome-${status}`}>
      {OUTCOME_LOOK[status] ? t(intl, `outcome.${status}`) : status}
    </StatusPill>
  )
}

function countsText(intl: IntlShape, counts: Partial<Record<ModuleOutcomeStatus, number>>): string {
  return COUNT_ORDER.filter((s) => (counts[s] ?? 0) > 0)
    .map((s) => `${t(intl, `outcome.${s}`)} ${counts[s]}`)
    .join(' · ')
}

function when(value: string | null): string {
  return value ? formatDateTime(value) : '—'
}

function StartBar({ busy, error, onStart }: { busy: boolean; error: string | null; onStart: (moduleId: string) => void }) {
  const intl = useIntl()
  const [moduleId, setModuleId] = useState('')
  const trimmed = moduleId.trim()
  const valid = trimmed.length >= 1 && trimmed.length <= MAX_MODULE_ID
  return (
    <section className="lf-card" aria-label={t(intl, 'start.button')}>
      <div className="lf-card__body lf-form">
        <Field label={t(intl, 'start.label')} error={error ?? undefined} mono>
          <input
            type="text"
            value={moduleId}
            maxLength={MAX_MODULE_ID}
            data-testid="module-rollouts-module-input"
            onChange={(e) => setModuleId(e.target.value)}
          />
        </Field>
        <div>
          <Button variant="primary" size="md" data-testid="module-rollouts-start" disabled={!valid || busy} loading={busy} onClick={() => onStart(trimmed)}>
            {t(intl, 'start.button')}
          </Button>
        </div>
      </div>
    </section>
  )
}

function OutcomeTable({ outcomes, names }: { outcomes: ModuleRolloutOutcome[]; names: Map<string, string> }) {
  const intl = useIntl()
  const columns: DataTableColumn<ModuleRolloutOutcome>[] = [
    { id: 'company', header: t(intl, 'col.company'), render: (o) => names.get(o.tenant_id) ?? o.tenant_id },
    {
      id: 'outcome',
      header: t(intl, 'col.outcome'),
      hideStackLabel: true,
      render: (o) => <OutcomePill status={o.status} />,
    },
    { id: 'error', header: t(intl, 'col.error'), mono: true, render: (o) => o.error_code ?? '—' },
    { id: 'attempted', header: t(intl, 'col.attempted'), mono: true, render: (o) => when(o.attempted_at) },
    { id: 'completed', header: t(intl, 'col.completed'), mono: true, render: (o) => when(o.completed_at) },
  ]
  return (
    <div data-testid="module-rollouts-outcomes">
      <DataTable columns={columns} data={outcomes} density="compact" getRowId={(o) => o.tenant_id} emptyMessage={t(intl, 'detail.noCompanies')} />
    </div>
  )
}

function Detail({
  rolloutId,
  names,
  resumeError,
  resumeBusy,
  onResume,
}: {
  rolloutId: string
  names: Map<string, string>
  resumeError: string | null
  resumeBusy: boolean
  onResume: () => void
}) {
  const intl = useIntl()
  const query = useModuleRolloutStatus(rolloutId)
  if (query.isLoading) return <p className="lf-faint" data-testid="module-rollouts-detail-loading">{t(intl, 'loading')}</p>
  if (query.isError || !query.data) {
    const notFound = (query.error as ApiError | null)?.status === 404
    return (
      <Banner
        tone="danger"
        action={
          notFound ? undefined : (
            <Button variant="secondary" size="sm" onClick={() => void query.refetch()}>
              {t(intl, 'retry')}
            </Button>
          )
        }
      >
        <span data-testid="module-rollouts-detail-error">{t(intl, notFound ? 'notFound' : 'loadError')}</span>
      </Banner>
    )
  }
  const { rollout, outcomes } = query.data
  const showResume = canResume(rollout, outcomes, new Date())
  return (
    <div data-testid="module-rollouts-detail" aria-label={rollout.module_id}>
      <DetailHeader
        title={`${rollout.module_id} ${rollout.to_version}`}
        status={<RolloutPill status={rollout.status} />}
        actions={
          showResume ? (
            <Button variant="primary" size="md" data-testid="module-rollouts-resume" disabled={resumeBusy} loading={resumeBusy} onClick={onResume}>
              {t(intl, 'resume.button')}
            </Button>
          ) : undefined
        }
      />
      <div className="lf-card__body lf-form">
        <p className="lf-faint" data-testid="module-rollouts-failures">
          {t(intl, 'detail.failures', { count: rollout.consecutive_failures, limit: rollout.halt_after })}
        </p>
        {rollout.status === 'halted' && (
          <Banner tone="danger" title={t(intl, 'halted.title')}>
            <span data-testid="module-rollouts-halted">{t(intl, 'halted.text', { count: rollout.consecutive_failures })}</span>
          </Banner>
        )}
        {resumeError && (
          <Banner tone="danger">
            <span data-testid="module-rollouts-resume-error">{resumeError}</span>
          </Banner>
        )}
        {outcomes.some((o) => o.status === 'outside_window') && (
          <Banner tone="info">
            <span data-testid="module-outcome-outside-window-note">{t(intl, 'outsideWindow.note')}</span>
          </Banner>
        )}
        <h3>{t(intl, 'detail.heading')}</h3>
        <OutcomeTable outcomes={outcomes} names={names} />
      </div>
    </div>
  )
}

function ModuleRolloutsBody() {
  const intl = useIntl()
  const qc = useQueryClient()
  const keys = useTenantScopedQueryKeys().moduleRollouts
  const [params, setParams] = useSearchParams()
  const selected = params.get('rollout')
  const list = useModuleRolloutsList()
  const names = useTenantNames()
  const start = useStartModuleRollout()
  const resume = useResumeModuleRollout()
  const [startError, setStartError] = useState<string | null>(null)
  const [resumeError, setResumeError] = useState<string | null>(null)

  useEffect(() => {
    if (!selected) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') select(null)
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  })

  const select = (id: string | null) => {
    const next = new URLSearchParams(params)
    if (id) next.set('rollout', id)
    else next.delete('rollout')
    setParams(next)
    setResumeError(null)
  }
  const shown = (data: ModuleRolloutResult) => {
    qc.setQueryData(keys.status(data.rollout.id), data)
    select(data.rollout.id)
  }

  const onStart = (moduleId: string) => {
    setStartError(null)
    start.mutate(moduleId, {
      onSuccess: shown,
      onError: (err) => setStartError(t(intl, err.status === 404 ? 'start.unknown' : 'start.failed')),
    })
  }
  const onResume = () => {
    if (!selected) return
    setResumeError(null)
    resume.mutate(selected, {
      onSuccess: (data) => qc.setQueryData(keys.status(data.rollout.id), data),
      onError: (err) => setResumeError(t(intl, err.status === 409 ? 'resume.superseded' : 'resume.failed')),
    })
  }

  const columns: DataTableColumn<ModuleRolloutListRow>[] = [
    { id: 'module', header: t(intl, 'col.module'), mono: true, render: (r) => r.rollout.module_id },
    { id: 'version', header: t(intl, 'col.version'), mono: true, render: (r) => r.rollout.to_version },
    { id: 'status', header: t(intl, 'col.status'), hideStackLabel: true, render: (r) => <RolloutPill status={r.rollout.status} /> },
    { id: 'counts', header: t(intl, 'col.counts'), render: (r) => countsText(intl, r.counts) || '—' },
    { id: 'started', header: t(intl, 'col.started'), mono: true, render: (r) => when(r.rollout.started_at) },
  ]

  return (
    <div className="lf-form">
      <PageHeader eyebrow={t(intl, 'eyebrow')} title={t(intl, 'title')} lede={t(intl, 'lede')} actions={<CoreHelpLink topic="moduleRollouts" />} />
      <StartBar busy={start.isPending} error={startError} onStart={onStart} />
      <MasterDetail
        masterWidth="wide"
        master={
      <section aria-label={t(intl, 'list.heading')}>
        <h2>{t(intl, 'list.heading')}</h2>
        <div data-testid="module-rollouts-list">
          <DataTable
            columns={columns}
            data={list.data?.rollouts ?? []}
            isLoading={list.isLoading}
            error={list.isError ? t(intl, 'loadError') : undefined}
            onRetry={() => void list.refetch()}
            labels={{ loading: t(intl, 'loading'), retry: t(intl, 'retry') }}
            density="compact"
            getRowId={(r) => r.rollout.id}
            selectedId={selected}
            onRowClick={(r) => select(r.rollout.id)}
            emptyMessage={t(intl, 'list.empty')}
            emptyText={t(intl, 'list.emptyText')}
          />
        </div>
      </section>
        }
        detailOpen={selected !== null}
        onBack={() => select(null)}
        detail={
          selected ? (
            <Detail rolloutId={selected} names={names} resumeError={resumeError} resumeBusy={resume.isPending} onResume={onResume} />
          ) : (
            <p className="lf-faint lf-card__body" data-testid="module-rollouts-detail-empty">
              {t(intl, 'detail.pick')}
            </p>
          )
        }
      />
    </div>
  )
}

type ModuleRolloutListRow = { rollout: ModuleRollout; counts: Partial<Record<ModuleOutcomeStatus, number>> }

export default function ModuleRolloutsPage(): React.ReactElement {
  return (
    <ModuleRolloutsIntlProvider>
      <ModuleRolloutsBody />
    </ModuleRolloutsIntlProvider>
  )
}
