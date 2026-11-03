/** MasterDataImportPage -- GH 3650 / REQ-675 (assets phase A screen S6).
 *
 *  Type picker (from the installed modules' importTypes), template download, dry run, confirm, summary.
 *  Core page: it never names a module (0039 D3). Every rule stays in the import route; the screen sends the file
 *  and shows the answer. No tenant identifier is sent (the tenant comes from the token).
 */
import React, { useState } from 'react'
import { useIntl } from 'react-intl'
import { P, useAccess } from '@/auth/access'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
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

const th: React.CSSProperties = { textAlign: 'left', padding: '.4rem .6rem', borderBottom: '2px solid var(--border-default)' }
const td: React.CSSProperties = { padding: '.4rem .6rem', borderBottom: '1px solid var(--border-default)', verticalAlign: 'top' }

type Phase =
  | { name: 'idle' }
  | { name: 'working'; what: 'template' | 'check' | 'import' }
  | { name: 'checked'; answer: ImportAnswer }
  | { name: 'done'; answer: ImportAnswer }
  | { name: 'error'; error: ImportErrorKind }

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
    <div>
      <div>{text}</div>
      {reason.header ? <div>{intl.formatMessage({ id: 'import.reason.header' }, { header: reason.header })}</div> : null}
      {reason.violations && reason.violations.length > 0 ? (
        <ul style={{ margin: 0, paddingLeft: '1.1rem' }}>
          {reason.violations.map((v, i) => (
            <li key={i}>
              {violationField(v)}
              {v.message ? `: ${v.message}` : v.code ? `: ${v.code}` : ''}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  )
}

function ResultTable({ results }: { results: ImportResultRow[] }) {
  const intl = useIntl()
  return (
    <table data-testid="import-result-table" style={{ borderCollapse: 'collapse', width: '100%' }}>
      <thead>
        <tr>
          <th style={th}>{intl.formatMessage({ id: 'import.col.line' })}</th>
          <th style={th}>{intl.formatMessage({ id: 'import.col.outcome' })}</th>
          <th style={th}>{intl.formatMessage({ id: 'import.col.externalId' })}</th>
          <th style={th}>{intl.formatMessage({ id: 'import.col.message' })}</th>
        </tr>
      </thead>
      <tbody>
        {results.map((row, i) => (
          <tr key={i} data-testid="import-result-row">
            <td style={td}>{row.line ?? ''}</td>
            <td style={td}>
              {intl.formatMessage({ id: `import.outcome.${row.status === 'error' ? 'refused' : (row.outcome ?? 'unchanged')}` })}
            </td>
            <td style={td}>{row.external_ref?.id ?? ''}</td>
            <td style={td}>{row.status === 'error' ? <ReasonText row={row} /> : null}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function Counts({ results }: { results: ImportResultRow[] }) {
  const intl = useIntl()
  const c = countResults(results)
  return (
    <p data-testid="import-counts" style={{ display: 'flex', gap: '1rem', flexWrap: 'wrap' }}>
      <span>{intl.formatMessage({ id: 'import.count.created' }, { n: c.created })}</span>
      <span>{intl.formatMessage({ id: 'import.count.updated' }, { n: c.updated })}</span>
      <span>{intl.formatMessage({ id: 'import.count.unchanged' }, { n: c.unchanged })}</span>
      <span>{intl.formatMessage({ id: 'import.count.refused' }, { n: c.refused })}</span>
    </p>
  )
}

function ErrorMessage({ error }: { error: ImportErrorKind }) {
  const intl = useIntl()
  let text: string
  switch (error.kind) {
    case 'limits':
      text = intl.formatMessage({ id: 'import.error.limits' })
      break
    case 'xlsx':
      text = intl.formatMessage({ id: `import.error.${error.code}` })
      break
    case 'unprocessable':
      text = intl.formatMessage({ id: 'import.error.unprocessable' }, { detail: error.detail })
      break
    case 'notAvailable':
      text = intl.formatMessage({ id: 'import.error.notAvailable' })
      break
    case 'forbidden':
      text = intl.formatMessage({ id: 'import.error.forbidden' })
      break
    case 'busy':
      text = intl.formatMessage({ id: 'import.error.busy' })
      break
    default:
      text = intl.formatMessage({ id: 'import.error.other' })
  }
  return (
    <p role="alert" data-testid="import-error" style={{ color: 'var(--color-danger, var(--text-primary))' }}>
      {text}
    </p>
  )
}

function MasterDataImportPageInner() {
  const intl = useIntl()
  const access = useAccess()
  const { data: installedModules = [] } = useInstalledModules()
  const types = getInstalledImportTypes(installedModules)
  const [chosen, setChosen] = useState<string | null>(null)
  const [file, setFile] = useState<File | null>(null)
  const [phase, setPhase] = useState<Phase>({ name: 'idle' })
  const [templateFailed, setTemplateFailed] = useState(false)

  const locale = (['en', 'ru', 'kk'] as const).find((l) => l === intl.locale) ?? 'en'
  const entityType = chosen ?? types[0]?.entityType ?? ''
  const working = phase.name === 'working'

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
  const shown = phase.name === 'checked' || phase.name === 'done' ? phase.answer : null

  if (types.length === 0) {
    return (
      <PageLayout title={intl.formatMessage({ id: 'import.title' })}>
        <p>{intl.formatMessage({ id: 'import.noTypes' })}</p>
      </PageLayout>
    )
  }

  return (
    <PageLayout title={intl.formatMessage({ id: 'import.title' })}>
      <div style={{ display: 'grid', gap: 'var(--space-4)' }}>
        <label style={{ display: 'grid', gap: '.25rem', maxWidth: '24rem' }}>
          <span>{intl.formatMessage({ id: 'import.type' })}</span>
          <select
            data-testid="import-type"
            value={entityType}
            disabled={working}
            onChange={(e) => {
              setChosen(e.target.value)
              reset()
            }}
          >
            {types.map((t) => (
              <option key={t.entityType} value={t.entityType}>
                {t.labels[locale]}
              </option>
            ))}
          </select>
        </label>

        <section>
          <h2>{intl.formatMessage({ id: 'import.help.title' })}</h2>
          <ul>
            <li>{intl.formatMessage({ id: 'import.help.reference' })}</li>
            <li>{intl.formatMessage({ id: 'import.help.order' })}</li>
            <li>{intl.formatMessage({ id: 'import.help.externalRef' })}</li>
            <li>{intl.formatMessage({ id: 'import.help.active' })}</li>
          </ul>
          {access.can(P.EntitiesRecordsExport) ? (
            <Button variant="secondary" size="md" data-testid="import-template" disabled={working} onClick={() => void onTemplate()}>
              {intl.formatMessage({ id: 'import.template.button' })}
            </Button>
          ) : null}
          {templateFailed ? (
            <p role="alert" data-testid="import-template-failed">
              {intl.formatMessage({ id: 'import.template.failed' })}
            </p>
          ) : null}
        </section>

        <section>
          <p data-testid="import-limits">{intl.formatMessage({ id: 'import.limits' })}</p>
          <label style={{ display: 'grid', gap: '.25rem', maxWidth: '24rem' }}>
            <span>{intl.formatMessage({ id: 'import.file' })}</span>
            <input
              type="file"
              data-testid="import-file"
              accept=".xlsx"
              disabled={working}
              onChange={(e) => {
                setFile(e.target.files?.[0] ?? null)
                reset()
              }}
            />
          </label>
          <div style={{ display: 'flex', gap: '.5rem', marginTop: '.5rem' }}>
            <Button variant="secondary" size="md" data-testid="import-check" disabled={!file || working} onClick={() => void onRun(true)}>
              {intl.formatMessage({ id: phase.name === 'working' && phase.what !== 'template' ? 'import.busy' : 'import.check' })}
            </Button>
            <Button variant="primary" size="md" data-testid="import-confirm" disabled={!checkedClean || working} onClick={() => void onRun(false)}>
              {intl.formatMessage({ id: 'import.confirm' })}
            </Button>
          </div>
        </section>

        {phase.name === 'error' ? <ErrorMessage error={phase.error} /> : null}

        {shown ? (
          <section data-testid={phase.name === 'done' ? 'import-summary' : 'import-dry-run'}>
            <h2>{intl.formatMessage({ id: phase.name === 'done' ? 'import.summary.title' : 'import.dryRun.title' })}</h2>
            <Counts results={shown.results} />
            <p>
              {phase.name === 'done'
                ? intl.formatMessage({ id: 'import.summary.done' })
                : intl.formatMessage({ id: 'import.dryRun.nothingWritten' })}
            </p>
            {phase.name === 'checked' ? (
              <p>{intl.formatMessage({ id: checkedClean ? 'import.dryRun.ready' : 'import.dryRun.fix' })}</p>
            ) : null}
            <ResultTable results={shown.results} />
          </section>
        ) : null}
      </div>
    </PageLayout>
  )
}

export default function MasterDataImportPage(): React.ReactElement {
  return (
    <ImportIntlProvider>
      <MasterDataImportPageInner />
    </ImportIntlProvider>
  )
}
