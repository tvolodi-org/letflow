/** UsersImportPage -- T-1633 / REQ-791 (BA decision T-1631 item 2). Template download, dry run, a row / column /
 *  reason report in ru, kk and en, fix and re-upload. A sibling of MasterDataImportPage (one fixed import type, no
 *  type picker). Every rule stays on the server; the screen sends the file and shows the answer. No tenant
 *  identifier is sent (the tenant comes from the token). Shared components only; no colour or spacing is set here.
 */
import React, { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { Download } from 'lucide-react'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { DropZone } from '@/components/ui/DropZone'
import { PageHeader } from '@/components/ui/PageHeader'
import { StatusPill, type StatusGlyph, type StatusTone } from '@/components/ui/StatusPill'
import { Steps } from '@/components/ui/Steps'
import { Tally } from '@/components/ui/Tally'
import { useToast } from '@/hooks/useToast'
import type { UiLocale } from '@/i18n/uiLocaleStore'
import {
  MAX_FILE_BYTES,
  countResults,
  type ImportAnswer,
  type ImportErrorKind,
  type ImportResultRow,
} from '../import/importModel'
import { UsersImportIntlProvider } from './UsersImportIntlProvider'
import { downloadUsersTemplate, runUsersImport } from './usersImportApi'
import { classifyUsersImportError, usersReasonSentence, usersRefusedRowsCsv } from './usersImportModel'

type Phase =
  | { name: 'idle' }
  | { name: 'working'; what: 'template' | 'check' | 'import' }
  | { name: 'checked'; answer: ImportAnswer }
  | { name: 'done'; answer: ImportAnswer }
  | { name: 'notApplied'; answer: ImportAnswer }
  | { name: 'error'; error: ImportErrorKind }

type Outcome = 'created' | 'unchanged' | 'refused'

const OUTCOME_LOOK: Record<Outcome, { tone: StatusTone; glyph: StatusGlyph }> = {
  created: { tone: 'current', glyph: 'dot' },
  unchanged: { tone: 'neutral', glyph: 'ring' },
  refused: { tone: 'danger', glyph: 'triangle' },
}

function outcomeOf(row: ImportResultRow): Outcome {
  if (row.status === 'error') return 'refused'
  return row.outcome === 'created' ? 'created' : 'unchanged'
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

function localeOf(intl: ReturnType<typeof useIntl>): UiLocale {
  return (['en', 'ru', 'kk'] as const).find((l) => l === intl.locale) ?? 'en'
}

const NAMED_HEADER_CODES = ['xlsx_unknown_header', 'xlsx_duplicate_header', 'xlsx_missing_header']

function errorText(intl: ReturnType<typeof useIntl>, error: ImportErrorKind): string {
  switch (error.kind) {
    case 'limits':
      return intl.formatMessage({ id: 'usersImport.error.limits' })
    case 'xlsx':
      if (error.headers && error.headers.length > 0 && NAMED_HEADER_CODES.includes(error.code)) {
        return intl.formatMessage({ id: `usersImport.error.${error.code}_named` }, { headers: error.headers.join(', ') })
      }
      return intl.formatMessage({ id: `usersImport.error.${error.code}`, defaultMessage: intl.formatMessage({ id: 'usersImport.error.unprocessable' }) })
    case 'unprocessable':
      return intl.formatMessage({ id: 'usersImport.error.unprocessable' })
    case 'notAvailable':
      return intl.formatMessage({ id: 'usersImport.error.notAvailable' })
    case 'forbidden':
      return intl.formatMessage({ id: 'usersImport.error.forbidden' })
    case 'busy':
      return intl.formatMessage({ id: 'usersImport.error.busy' })
    default:
      return intl.formatMessage({ id: 'usersImport.error.other' })
  }
}

function ResultTable({ results, hypothetical }: { results: ImportResultRow[]; hypothetical: boolean }) {
  const intl = useIntl()
  const locale = localeOf(intl)
  const columns: DataTableColumn<ImportResultRow>[] = [
    {
      id: 'outcome',
      header: intl.formatMessage({ id: 'usersImport.col.outcome' }),
      render: (r) => {
        const outcome = outcomeOf(r)
        const look = OUTCOME_LOOK[outcome]
        const id = hypothetical && outcome === 'created' ? 'usersImport.outcome.would_created' : `usersImport.outcome.${outcome}`
        return (
          <StatusPill tone={look.tone} glyph={look.glyph}>
            {intl.formatMessage({ id })}
          </StatusPill>
        )
      },
    },
    { id: 'line', header: intl.formatMessage({ id: 'usersImport.col.line' }), align: 'end', mono: true, render: (r) => r.line ?? '' },
    {
      id: 'column',
      header: intl.formatMessage({ id: 'usersImport.col.column' }),
      mono: true,
      render: (r) => (r.status === 'error' ? (r.reason?.header ?? '') : ''),
    },
    {
      id: 'reason',
      header: intl.formatMessage({ id: 'usersImport.col.reason' }),
      render: (r) =>
        r.status === 'error' ? (
          <span>{r.reason ? usersReasonSentence(locale, r.reason) : intl.formatMessage({ id: 'usersImport.error.other' })}</span>
        ) : (
          <span className="lf-faint">—</span>
        ),
    },
  ]
  return (
    <div data-testid="users-import-result-table">
      <DataTable
        columns={columns}
        data={results}
        density="compact"
        emptyMessage={intl.formatMessage({ id: 'usersImport.results.empty' })}
        rowState={(r) => (r.status === 'error' ? 'error' : undefined)}
      />
    </div>
  )
}

function Counts({ results, hypothetical }: { results: ImportResultRow[]; hypothetical: boolean }) {
  const intl = useIntl()
  const c = countResults(results)
  return (
    <div data-testid="users-import-counts">
      <Tally
        aria-label={intl.formatMessage({ id: 'usersImport.counts.label' })}
        items={[
          {
            label: intl.formatMessage({ id: hypothetical ? 'usersImport.counts.wouldCreated' : 'usersImport.outcome.created' }),
            value: c.created,
            glyph: OUTCOME_LOOK.created.glyph,
          },
          { label: intl.formatMessage({ id: 'usersImport.outcome.unchanged' }), value: c.unchanged, glyph: OUTCOME_LOOK.unchanged.glyph },
          { label: intl.formatMessage({ id: 'usersImport.outcome.refused' }), value: c.refused, glyph: OUTCOME_LOOK.refused.glyph, tone: 'danger' as const },
        ]}
      />
    </div>
  )
}

function UsersImportPageInner() {
  const intl = useIntl()
  const toast = useToast()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const [file, setFile] = useState<File | null>(null)
  const [phase, setPhase] = useState<Phase>({ name: 'idle' })
  const [templateFailed, setTemplateFailed] = useState(false)

  const locale = localeOf(intl)
  const working = phase.name === 'working'

  // The success toast and the users-list invalidation are side effects of reaching "done", not of rendering it.
  const doneAnswer = phase.name === 'done' ? phase.answer : null
  useEffect(() => {
    if (!doneAnswer) return
    toast.success(intl.formatMessage({ id: 'usersImport.summary.toast' }))
    // The users list is cached (staleTime 30 s): without this a quick return would show the old list.
    void qc.invalidateQueries({ queryKey: tenantKeys.admin.users() })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [doneAnswer])

  async function onTemplate() {
    setTemplateFailed(false)
    setPhase({ name: 'working', what: 'template' })
    try {
      const { blob } = await downloadUsersTemplate()
      saveBlob(blob, 'users-template.xlsx')
    } catch {
      setTemplateFailed(true)
    }
    setPhase({ name: 'idle' })
  }

  async function onRun(dryRun: boolean) {
    if (!file) return
    if (file.size > MAX_FILE_BYTES) {
      setPhase({ name: 'error', error: { kind: 'limits' } })
      return
    }
    setPhase({ name: 'working', what: dryRun ? 'check' : 'import' })
    try {
      const answer = await runUsersImport(file, dryRun)
      if (!Array.isArray(answer?.results)) throw new Error('unexpected import answer')
      if (dryRun) setPhase({ name: 'checked', answer })
      else if (answer.applied === false) {
        // Rolled back: nothing was written. The file picker is cleared for the corrected file.
        setFile(null)
        setPhase({ name: 'notApplied', answer })
      } else setPhase({ name: 'done', answer })
    } catch (err) {
      setPhase({ name: 'error', error: classifyUsersImportError(err) })
    }
  }

  const checkedClean =
    phase.name === 'checked' && phase.answer.results.length > 0 && countResults(phase.answer.results).refused === 0
  const checkedDirty = phase.name === 'checked' && !checkedClean
  const shown = phase.name === 'checked' || phase.name === 'done' || phase.name === 'notApplied' ? phase.answer : null
  const notApplied = phase.name === 'notApplied'
  const refusedCount = shown ? countResults(shown.results).refused : 0
  // Steps is zero-based: 0 file, 1 check, 2 import, 3 = all done.
  const stepCurrent = phase.name === 'done' ? 3 : checkedClean ? 2 : file ? 1 : 0

  return (
    <div className="lf-form">
      <PageHeader
        eyebrow={intl.formatMessage({ id: 'usersImport.eyebrow' })}
        title={intl.formatMessage({ id: 'usersImport.title' })}
        lede={intl.formatMessage({ id: 'usersImport.lede' })}
        actions={
          <Button
            variant="secondary"
            size="md"
            icon={<Download className="lf-icon" aria-hidden="true" />}
            data-testid="users-import-template"
            disabled={working}
            onClick={() => void onTemplate()}
          >
            {intl.formatMessage({ id: 'usersImport.template.button' })}
          </Button>
        }
      />

      <Steps
        aria-label={intl.formatMessage({ id: 'usersImport.steps.label' })}
        current={stepCurrent}
        steps={['file', 'check', 'import'].map((k) => ({ label: intl.formatMessage({ id: `usersImport.steps.${k}` }) }))}
      />

      {templateFailed ? (
        <div data-testid="users-import-template-failed">
          <Banner tone="danger">{intl.formatMessage({ id: 'usersImport.template.failed' })}</Banner>
        </div>
      ) : null}

      <div className="lf-wizard">
        <div className="lf-form">
          <section className="lf-card" aria-labelledby="users-import-file-h">
            <div className="lf-card__head">
              <h2 className="lf-card__title" id="users-import-file-h">
                {intl.formatMessage({ id: 'usersImport.card.file' })}
              </h2>
            </div>
            <div className="lf-card__body lf-form">
              <DropZone
                accept=".xlsx"
                title={intl.formatMessage({ id: 'usersImport.drop.title' })}
                invalidText={intl.formatMessage({ id: 'usersImport.drop.invalid' })}
                chosen={file ? { file } : null}
                onFile={(f) => {
                  setFile(f)
                  setTemplateFailed(false)
                  setPhase({ name: 'idle' })
                }}
              />
              {phase.name === 'error' ? (
                <div data-testid="users-import-error">
                  <Banner tone="danger">{errorText(intl, phase.error)}</Banner>
                </div>
              ) : null}
              <div className="lf-form__actions">
                <Button
                  variant="secondary"
                  size="md"
                  data-testid="users-import-check"
                  disabled={!file || working}
                  loading={working && phase.what !== 'template'}
                  onClick={() => void onRun(true)}
                >
                  {intl.formatMessage({ id: phase.name === 'working' && phase.what !== 'template' ? 'usersImport.busy' : 'usersImport.check' })}
                </Button>
                <Button variant="primary" size="md" data-testid="users-import-confirm" disabled={!checkedClean || working} onClick={() => void onRun(false)}>
                  {intl.formatMessage({ id: 'usersImport.confirm' })}
                </Button>
                {checkedDirty ? (
                  <span className="lf-hint" data-testid="users-import-why">
                    {intl.formatMessage({ id: 'usersImport.dryRun.why' })}
                  </span>
                ) : null}
              </div>
            </div>
          </section>

          {shown ? (
            <section
              className="lf-card"
              aria-labelledby="users-import-result-h"
              data-testid={phase.name === 'done' ? 'users-import-summary' : notApplied ? 'users-import-not-applied' : 'users-import-dry-run'}
            >
              <div className="lf-card__head">
                <div>
                  <h2 className="lf-card__title" id="users-import-result-h">
                    {intl.formatMessage({ id: phase.name === 'done' || notApplied ? 'usersImport.summary.title' : 'usersImport.dryRun.title' })}
                  </h2>
                  <p className="lf-muted">
                    {intl.formatMessage({
                      id: phase.name === 'done' ? 'usersImport.summary.done' : notApplied ? 'usersImport.notApplied' : 'usersImport.dryRun.nothingWritten',
                    })}
                  </p>
                </div>
                {phase.name === 'checked' ? (
                  checkedClean ? (
                    <StatusPill tone="success" glyph="dot">
                      {intl.formatMessage({ id: 'usersImport.dryRun.readyPill' })}
                    </StatusPill>
                  ) : (
                    <StatusPill tone="danger" glyph="triangle">
                      {intl.formatMessage({ id: 'usersImport.dryRun.needsFix' })}
                    </StatusPill>
                  )
                ) : null}
              </div>
              <div className="lf-card__body lf-form">
                {notApplied ? (
                  <div data-testid="users-import-reupload">
                    <Banner tone="warning">{intl.formatMessage({ id: 'usersImport.reupload' })}</Banner>
                  </div>
                ) : null}
                <Counts results={shown.results} hypothetical={notApplied || phase.name === 'checked'} />
                <ResultTable results={shown.results} hypothetical={notApplied || phase.name === 'checked'} />
                {refusedCount > 0 ? (
                  <div className="lf-form__actions">
                    <Button
                      variant="secondary"
                      size="sm"
                      icon={<Download className="lf-icon" aria-hidden="true" />}
                      data-testid="users-import-download-refused"
                      onClick={() => saveBlob(new Blob([usersRefusedRowsCsv(locale, shown.results)], { type: 'text/csv;charset=utf-8' }), 'users-refused-rows.csv')}
                    >
                      {intl.formatMessage({ id: 'usersImport.download.refused' })}
                    </Button>
                  </div>
                ) : null}
                {phase.name === 'checked' && shown.results.length > 0 ? (
                  <Banner tone={checkedClean ? 'success' : 'warning'}>
                    {intl.formatMessage({ id: checkedClean ? 'usersImport.dryRun.ready' : 'usersImport.dryRun.fix' })}
                  </Banner>
                ) : null}
                {phase.name === 'done' ? (
                  <div className="lf-form__actions">
                    <Button variant="primary" size="md" data-testid="users-import-back" onClick={() => navigate('/admin/users')}>
                      {intl.formatMessage({ id: 'usersImport.back' })}
                    </Button>
                  </div>
                ) : null}
              </div>
            </section>
          ) : null}
        </div>

        <aside className="lf-card" aria-labelledby="users-import-help-h">
          <div className="lf-card__head">
            <h2 className="lf-card__title" id="users-import-help-h">
              {intl.formatMessage({ id: 'usersImport.help.title' })}
            </h2>
          </div>
          <div className="lf-card__body lf-form">
            <ul className="lf-help">
              <li>{intl.formatMessage({ id: 'usersImport.help.columns' })}</li>
              <li>{intl.formatMessage({ id: 'usersImport.help.existing' })}</li>
              <li>{intl.formatMessage({ id: 'usersImport.help.signin' })}</li>
            </ul>
            <div data-testid="users-import-limits">
              <Banner tone="info">{intl.formatMessage({ id: 'usersImport.limits' })}</Banner>
            </div>
          </div>
        </aside>
      </div>
    </div>
  )
}

export default function UsersImportPage(): React.ReactElement {
  return (
    <UsersImportIntlProvider>
      <UsersImportPageInner />
    </UsersImportIntlProvider>
  )
}
