/** MasterDataImportPage -- GH 3650 / REQ-675 (assets phase A screen S6), restyled in style task S6.
 *
 *  Type picker (from the installed modules' importTypes), template download, drop zone, dry run, confirm, summary.
 *  Core page: it never names a module (0039 D3). Every rule stays in the import route; the screen sends the file
 *  and shows the answer. No tenant identifier is sent (the tenant comes from the token).
 *
 *  Look: the design system's import wizard (platform/examples/import.html): PageHeader, Steps, cards, TypePicker,
 *  DropZone, Tally, DataTable, Banner. Shared components only; no colour or spacing is set here.
 *  Nothing on this screen is retired or listed per record, so there is no "Show retired" control.
 */
import React, { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { Download, FileSpreadsheet } from 'lucide-react'
import { P, useAccess } from '@/auth/access'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { DropZone } from '@/components/ui/DropZone'
import { EmptyState } from '@/components/ui/EmptyState'
import { PageHeader } from '@/components/ui/PageHeader'
import { Skeleton } from '@/components/ui/Skeleton'
import { StatusPill, type StatusGlyph, type StatusTone } from '@/components/ui/StatusPill'
import { Steps } from '@/components/ui/Steps'
import { Tally } from '@/components/ui/Tally'
import { TypePicker } from '@/components/ui/TypePicker'
import { useToast } from '@/hooks/useToast'
import { useInstalledModules } from '@/hooks/useInstalledModules'
import { getInstalledImportTypes } from '@/modules/registry'
import { ImportIntlProvider } from '@/i18n/ImportIntlProvider'
import { downloadTemplate, runImport } from './importApi'
import {
  MAX_FILE_BYTES,
  ROW_REASON_TYPES,
  classifyImportError,
  countResults,
  violationField,
  type ImportAnswer,
  type ImportErrorKind,
  type ImportResultRow,
} from './importModel'

type Phase =
  | { name: 'idle' }
  | { name: 'working'; what: 'template' | 'check' | 'import' }
  | { name: 'checked'; answer: ImportAnswer }
  | { name: 'done'; answer: ImportAnswer }
  | { name: 'error'; error: ImportErrorKind }

type Outcome = 'created' | 'updated' | 'unchanged' | 'refused'

const OUTCOME_LOOK: Record<Outcome, { tone: StatusTone; glyph: StatusGlyph }> = {
  created: { tone: 'current', glyph: 'dot' },
  updated: { tone: 'info', glyph: 'half' },
  unchanged: { tone: 'neutral', glyph: 'ring' },
  refused: { tone: 'danger', glyph: 'triangle' },
}

function outcomeOf(row: ImportResultRow): Outcome {
  return row.status === 'error' ? 'refused' : (row.outcome ?? 'unchanged')
}

function saveBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

function ReasonText({ row }: { row: ImportResultRow }) {
  const intl = useIntl()
  const reason = row.reason
  if (!reason) return null
  const known = (ROW_REASON_TYPES as readonly string[]).includes(reason.type)
  const text = known
    ? intl.formatMessage({ id: `import.reason.${reason.type}` })
    : intl.formatMessage({ id: 'import.reason.unknown' }, { type: reason.type })
  return (
    <span className="lf-cell-2">
      {reason.header ? (
        <strong>
          {intl.formatMessage({ id: 'import.reason.header' }, { header: '' })}
          <span className="mono">{reason.header}</span>
        </strong>
      ) : null}
      <span>{text}</span>
      {reason.violations && reason.violations.length > 0 ? (
        <ul className="lf-help">
          {reason.violations.map((v, i) => (
            <li key={i}>
              <span className="mono">{violationField(v)}</span>
              {v.message ? `: ${v.message}` : v.code ? `: ${v.code}` : ''}
            </li>
          ))}
        </ul>
      ) : null}
    </span>
  )
}

function ResultTable({ results }: { results: ImportResultRow[] }) {
  const intl = useIntl()
  const columns: DataTableColumn<ImportResultRow>[] = [
    {
      id: 'outcome',
      header: intl.formatMessage({ id: 'import.col.outcome' }),
      render: (r) => {
        const outcome = outcomeOf(r)
        const look = OUTCOME_LOOK[outcome]
        return (
          <StatusPill tone={look.tone} glyph={look.glyph}>
            {intl.formatMessage({ id: `import.outcome.${outcome}` })}
          </StatusPill>
        )
      },
    },
    { id: 'line', header: intl.formatMessage({ id: 'import.col.line' }), align: 'end', mono: true, render: (r) => r.line ?? '' },
    { id: 'externalId', header: intl.formatMessage({ id: 'import.col.externalId' }), mono: true, render: (r) => r.external_ref?.id ?? '' },
    {
      id: 'message',
      header: intl.formatMessage({ id: 'import.col.message' }),
      render: (r) => (r.status === 'error' ? <ReasonText row={r} /> : <span className="lf-faint">—</span>),
    },
  ]
  return (
    <div data-testid="import-result-table">
      <DataTable
        columns={columns}
        data={results}
        density="compact"
        emptyMessage={intl.formatMessage({ id: 'import.results.empty' })}
        rowState={(r) => (r.status === 'error' ? 'error' : undefined)}
      />
    </div>
  )
}

function Counts({ results }: { results: ImportResultRow[] }) {
  const intl = useIntl()
  const c = countResults(results)
  const item = (outcome: Outcome, value: number) => ({
    label: intl.formatMessage({ id: `import.outcome.${outcome}` }),
    value,
    glyph: OUTCOME_LOOK[outcome].glyph,
    tone: outcome === 'refused' ? ('danger' as const) : undefined,
  })
  return (
    <div data-testid="import-counts">
      <Tally
        aria-label={intl.formatMessage({ id: 'import.counts.label' })}
        items={[item('created', c.created), item('updated', c.updated), item('unchanged', c.unchanged), item('refused', c.refused)]}
      />
    </div>
  )
}

function errorText(intl: ReturnType<typeof useIntl>, error: ImportErrorKind): string {
  switch (error.kind) {
    case 'limits':
      return intl.formatMessage({ id: 'import.error.limits' })
    case 'xlsx':
      return intl.formatMessage({ id: `import.error.${error.code}` })
    case 'unprocessable':
      return intl.formatMessage({ id: 'import.error.unprocessable' }, { detail: error.detail })
    case 'notAvailable':
      return intl.formatMessage({ id: 'import.error.notAvailable' })
    case 'forbidden':
      return intl.formatMessage({ id: 'import.error.forbidden' })
    case 'busy':
      return intl.formatMessage({ id: 'import.error.busy' })
    default:
      return intl.formatMessage({ id: 'import.error.other' })
  }
}

function LoadingSkeleton({ label }: { label: string }) {
  return (
    <section className="lf-card" data-testid="import-loading" aria-busy="true" aria-label={label}>
      <div className="lf-card__body lf-form">
        <Skeleton width="40%" />
        <Skeleton width="80%" />
        <Skeleton width="60%" />
      </div>
    </section>
  )
}

function MasterDataImportPageInner() {
  const intl = useIntl()
  const access = useAccess()
  const toast = useToast()
  const installed = useInstalledModules()
  const types = getInstalledImportTypes(installed.data ?? [])
  const [chosen, setChosen] = useState<string | null>(null)
  const [file, setFile] = useState<File | null>(null)
  const [phase, setPhase] = useState<Phase>({ name: 'idle' })
  const [templateFailed, setTemplateFailed] = useState(false)

  const locale = (['en', 'ru', 'kk'] as const).find((l) => l === intl.locale) ?? 'en'
  const entityType = chosen ?? types[0]?.entityType ?? ''
  const working = phase.name === 'working'

  // The success toast is a side effect of reaching "done", not of rendering it.
  const doneAnswer = phase.name === 'done' ? phase.answer : null
  useEffect(() => {
    if (doneAnswer) toast.success(intl.formatMessage({ id: 'import.summary.toast' }))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [doneAnswer])

  function reset() {
    setPhase({ name: 'idle' })
    setTemplateFailed(false)
  }

  async function onTemplate() {
    setTemplateFailed(false)
    setPhase({ name: 'working', what: 'template' })
    try {
      const { blob } = await downloadTemplate(entityType)
      saveBlob(blob, `${entityType}-template.xlsx`)
      setPhase({ name: 'idle' })
    } catch {
      setTemplateFailed(true)
      setPhase({ name: 'idle' })
    }
  }

  async function onRun(dryRun: boolean) {
    if (!file || !entityType) return
    if (file.size > MAX_FILE_BYTES) {
      setPhase({ name: 'error', error: { kind: 'limits' } })
      return
    }
    setPhase({ name: 'working', what: dryRun ? 'check' : 'import' })
    try {
      const answer = await runImport(entityType, file, dryRun)
      if (!Array.isArray(answer?.results)) throw new Error('unexpected import answer')
      setPhase(dryRun ? { name: 'checked', answer } : { name: 'done', answer })
    } catch (err) {
      setPhase({ name: 'error', error: classifyImportError(err) })
    }
  }

  const checkedClean = phase.name === 'checked' && countResults(phase.answer.results).refused === 0
  const checkedDirty = phase.name === 'checked' && !checkedClean
  const shown = phase.name === 'checked' || phase.name === 'done' ? phase.answer : null
  const title = intl.formatMessage({ id: 'import.title' })
  const header = (actions?: React.ReactNode) => (
    <PageHeader
      eyebrow={intl.formatMessage({ id: 'import.eyebrow' })}
      title={title}
      lede={intl.formatMessage({ id: 'import.lede' })}
      actions={actions}
    />
  )

  if (installed.isLoading) {
    return (
      <div className="lf-form">
        {header()}
        <LoadingSkeleton label={intl.formatMessage({ id: 'import.loading' })} />
      </div>
    )
  }
  if (installed.isError) {
    return (
      <div className="lf-form">
        {header()}
        <Banner
          tone="danger"
          action={
            <Button variant="secondary" size="sm" data-testid="import-load-retry" onClick={() => void installed.refetch()}>
              {intl.formatMessage({ id: 'import.retry' })}
            </Button>
          }
        >
          <span data-testid="import-load-error">{intl.formatMessage({ id: 'import.loadFailed' })}</span>
        </Banner>
      </div>
    )
  }
  if (types.length === 0) {
    return (
      <div className="lf-form">
        {header()}
        <section className="lf-card">
          <EmptyState
            data-testid="import-empty"
            title={intl.formatMessage({ id: 'import.noTypes' })}
            action={
              <Button variant="secondary" size="md" onClick={() => void installed.refetch()}>
                {intl.formatMessage({ id: 'import.noTypes.action' })}
              </Button>
            }
          />
        </section>
      </div>
    )
  }

  const stepCurrent = phase.name === 'done' ? 4 : file ? 2 : 1
  const canTemplate = access.can(P.EntitiesRecordsExport)

  return (
    <div className="lf-form">
      {header(
        canTemplate ? (
          <Button
            variant="secondary"
            size="md"
            icon={<Download className="lf-icon" aria-hidden="true" />}
            data-testid="import-template"
            disabled={working}
            onClick={() => void onTemplate()}
          >
            {intl.formatMessage({ id: 'import.template.button' })}
          </Button>
        ) : undefined,
      )}

      <Steps
        aria-label={intl.formatMessage({ id: 'import.steps.label' })}
        current={stepCurrent}
        steps={['type', 'file', 'check', 'import'].map((k) => ({ label: intl.formatMessage({ id: `import.steps.${k}` }) }))}
      />

      {templateFailed ? (
        <div data-testid="import-template-failed">
          <Banner tone="danger">{intl.formatMessage({ id: 'import.template.failed' })}</Banner>
        </div>
      ) : null}

      <div className="lf-wizard">
        <div className="lf-form">
          <section className="lf-card" aria-labelledby="import-type-h">
            <div className="lf-card__head">
              <h2 className="lf-card__title" id="import-type-h">
                {intl.formatMessage({ id: 'import.card.type' })}
              </h2>
            </div>
            <div className="lf-card__body">
              <TypePicker
                name="import-type"
                label={intl.formatMessage({ id: 'import.type' })}
                value={entityType}
                types={types.map((t) => ({ id: t.entityType, label: t.labels[locale], icon: FileSpreadsheet }))}
                onChange={(id) => {
                  if (working) return
                  setChosen(id)
                  reset()
                }}
              />
            </div>
          </section>

          <section className="lf-card" aria-labelledby="import-file-h">
            <div className="lf-card__head">
              <h2 className="lf-card__title" id="import-file-h">
                {intl.formatMessage({ id: 'import.card.file' })}
              </h2>
            </div>
            <div className="lf-card__body lf-form">
              <DropZone
                accept=".xlsx"
                title={intl.formatMessage({ id: 'import.drop.title' })}
                invalidText={intl.formatMessage({ id: 'import.drop.invalid' })}
                chosen={file ? { file } : null}
                onFile={(f) => {
                  setFile(f)
                  reset()
                }}
              />
              {phase.name === 'error' ? (
                <div data-testid="import-error">
                  <Banner tone="danger">{errorText(intl, phase.error)}</Banner>
                </div>
              ) : null}
              <div className="lf-form__actions">
                <Button variant="secondary" size="md" data-testid="import-check" disabled={!file || working} loading={working && phase.what !== 'template'} onClick={() => void onRun(true)}>
                  {intl.formatMessage({ id: phase.name === 'working' && phase.what !== 'template' ? 'import.busy' : 'import.check' })}
                </Button>
                <Button variant="primary" size="md" data-testid="import-confirm" disabled={!checkedClean || working} onClick={() => void onRun(false)}>
                  {intl.formatMessage({ id: 'import.confirm' })}
                </Button>
                {checkedDirty ? (
                  <span className="lf-hint" data-testid="import-why">
                    {intl.formatMessage({ id: 'import.dryRun.why' })}
                  </span>
                ) : null}
              </div>
            </div>
          </section>

          {shown ? (
            <section
              className="lf-card"
              aria-labelledby="import-result-h"
              data-testid={phase.name === 'done' ? 'import-summary' : 'import-dry-run'}
            >
              <div className="lf-card__head">
                <div>
                  <h2 className="lf-card__title" id="import-result-h">
                    {intl.formatMessage({ id: phase.name === 'done' ? 'import.summary.title' : 'import.dryRun.title' })}
                  </h2>
                  <p className="lf-muted">
                    {intl.formatMessage({ id: phase.name === 'done' ? 'import.summary.done' : 'import.dryRun.nothingWritten' })}
                  </p>
                </div>
                {phase.name === 'checked' ? (
                  checkedClean ? (
                    <StatusPill tone="success" glyph="dot">
                      {intl.formatMessage({ id: 'import.dryRun.readyPill' })}
                    </StatusPill>
                  ) : (
                    <StatusPill tone="danger" glyph="triangle">
                      {intl.formatMessage({ id: 'import.dryRun.needsFix' })}
                    </StatusPill>
                  )
                ) : null}
              </div>
              <div className="lf-card__body lf-form">
                <Counts results={shown.results} />
                <ResultTable results={shown.results} />
                {phase.name === 'checked' ? (
                  <Banner tone={checkedClean ? 'success' : 'warning'}>
                    {intl.formatMessage({ id: checkedClean ? 'import.dryRun.ready' : 'import.dryRun.fix' })}
                  </Banner>
                ) : null}
              </div>
            </section>
          ) : null}
        </div>

        <aside className="lf-card" aria-labelledby="import-help-h">
          <div className="lf-card__head">
            <h2 className="lf-card__title" id="import-help-h">
              {intl.formatMessage({ id: 'import.help.title' })}
            </h2>
          </div>
          <div className="lf-card__body lf-form">
            <ul className="lf-help">
              <li>{intl.formatMessage({ id: 'import.help.externalRef' })}</li>
              <li>{intl.formatMessage({ id: 'import.help.reference' })}</li>
              <li>{intl.formatMessage({ id: 'import.help.order' })}</li>
              <li>{intl.formatMessage({ id: 'import.help.active' })}</li>
            </ul>
            <div data-testid="import-limits">
              <Banner tone="info">{intl.formatMessage({ id: 'import.limits' })}</Banner>
            </div>
            <p className="caption lf-faint">{intl.formatMessage({ id: 'import.help.rerun' })}</p>
          </div>
        </aside>
      </div>
    </div>
  )
}

export default function MasterDataImportPage(): React.ReactElement {
  return (
    <ImportIntlProvider>
      <MasterDataImportPageInner />
    </ImportIntlProvider>
  )
}
