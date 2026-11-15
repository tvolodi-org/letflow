/** OfficialFormDetail — T-1983. The detail panel of one official form: header actions (starter, upload), the current
 *  state per language, the upload section with the refusal list, and the version history with the row actions.
 *  No modal for editing (design-system rule 2a); the reason dialog is the page's. */
import { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { X } from 'lucide-react'
import type { OfficialFormTemplateMeta, TemplateAction, TemplateLocale, TemplateRefusal } from '@/api/officialFormTemplates'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { DropZone } from '@/components/ui/DropZone'
import { FormSection } from '@/components/ui/FormSection'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { formatDate } from '@/i18n/format'
import { RefusalList } from './RefusalList'
import { TEMPLATE_LOCALES, formState, knownReasonId, rollbackable, rowsOf } from './officialFormsModel'

export interface UploadResult {
  ok: boolean
  refusals: TemplateRefusal[] | null
  errorKey: string | null
}

interface Props {
  form: string
  rows: OfficialFormTemplateMeta[]
  busy: boolean
  /** The list is still loading: no "standard" claim and no empty text yet. */
  loading: boolean
  onClose: () => void
  onStarter: () => void
  onDownload: (row: OfficialFormTemplateMeta) => void
  onPreview: (row: OfficialFormTemplateMeta, lang: 'ru' | 'kk') => void
  onAction: (row: OfficialFormTemplateMeta, action: TemplateAction) => void
  onUpload: (locale: TemplateLocale, file: File) => Promise<UploadResult>
  /** Harness only. */
  initialUploadOpen?: boolean
  initialFile?: File
  submitUploadOnMount?: boolean
}

const TONE = { draft: ['info', 'ring'], active: ['success', 'dot'], retired: ['neutral', 'dash'] } as const

export function OfficialFormDetail(props: Props) {
  const { form, rows, busy, loading, onClose, onStarter, onDownload, onPreview, onAction, onUpload } = props
  const intl = useIntl()
  const locale = intl.locale
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const formRows = rowsOf(rows, form)
  const state = formState(formRows)
  const [open, setOpen] = useState(props.initialUploadOpen ?? false)
  const [file, setFile] = useState<File | null>(props.initialFile ?? null)
  const [uploadLocale, setUploadLocale] = useState<TemplateLocale>('default')
  const [uploading, setUploading] = useState(false)
  const [result, setResult] = useState<UploadResult | null>(null)

  const submit = async (f: File) => {
    setUploading(true)
    setResult(null)
    const r = await onUpload(uploadLocale, f)
    setUploading(false)
    if (r.ok) {
      setOpen(false)
      setFile(null)
    } else {
      setResult(r)
    }
  }
  // Harness only: submit the initial file once, one frame after mount (the screenshot tool cannot click).
  useEffect(() => {
    if (!props.submitUploadOnMount || !file) return
    const frame = requestAnimationFrame(() => void submit(file))
    return () => cancelAnimationFrame(frame)
    // Once on mount: the harness file is fixed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const date = (v: string | null) => (v ? formatDate(v, { year: 'numeric', month: 'numeric', day: 'numeric' }, locale) : '—')
  const langName = (l: string) => t(`officialForms.locale.${l}`)
  const byId = new Map(formRows.map((r) => [r.id, r]))

  const columns: DataTableColumn<OfficialFormTemplateMeta>[] = [
    {
      id: 'version',
      header: t('officialForms.col.version'),
      render: (r) => {
        const src = r.rollback_of ? byId.get(r.rollback_of) : undefined
        return (
          <>
            <span className="mono">v{r.version_no}</span>
            <br />
            <span className="caption lf-faint">{langName(r.locale)}</span>
            {src && (
              <>
                <br />
                <span className="caption lf-faint">{t('officialForms.note.copyOf', { n: src.version_no })}</span>
              </>
            )}
          </>
        )
      },
    },
    {
      id: 'status',
      header: t('officialForms.col.status'),
      render: (r) => {
        const reasonId = r.reason_code == null ? null : knownReasonId(r.reason_code)
        return (
          <>
            <StatusPill tone={TONE[r.status][0]} glyph={TONE[r.status][1]}>
              {t(`officialForms.status.${r.status}`)}
            </StatusPill>
            {r.reason_code != null && (
              <>
                <br />
                <span className="caption lf-faint" title={t('officialForms.col.reason')}>
                  {reasonId ? t(reasonId) : <span className="mono">{r.reason_code}</span>}
                </span>
              </>
            )}
          </>
        )
      },
    },
    {
      id: 'dates',
      header: t('officialForms.col.dates'),
      render: (r) => (
        <>
          <span className="mono">{date(r.inserted_at)}</span> <span className="caption lf-faint">{t('officialForms.col.uploaded')}</span>
          {r.activated_at && (
            <>
              <br />
              <span className="mono">{date(r.activated_at)}</span> <span className="caption lf-faint">{t('officialForms.col.activeFrom')}</span>
            </>
          )}
          {r.retired_at && (
            <>
              <br />
              <span className="mono">{date(r.retired_at)}</span> <span className="caption lf-faint">{t('officialForms.col.retired')}</span>
            </>
          )}
        </>
      ),
    },
    {
      id: 'actions',
      header: t('officialForms.col.actions'),
      render: (r) => (
        <div className="lf-btn-row">
          <Button variant="ghost" size="sm" disabled={busy} onClick={() => onDownload(r)}>
            {t('officialForms.row.download')}
          </Button>
          {r.locale === 'default' ? (
            <>
              <Button variant="ghost" size="sm" disabled={busy} onClick={() => onPreview(r, 'ru')}>
                {t('officialForms.row.previewRu')}
              </Button>
              <Button variant="ghost" size="sm" disabled={busy} onClick={() => onPreview(r, 'kk')}>
                {t('officialForms.row.previewKk')}
              </Button>
            </>
          ) : (
            <Button variant="ghost" size="sm" disabled={busy} onClick={() => onPreview(r, r.locale as 'ru' | 'kk')}>
              {t('officialForms.row.preview')}
            </Button>
          )}
          {r.status === 'draft' && (
            <>
              <Button variant="secondary" size="sm" onClick={() => onAction(r, 'activate')}>
                {t('officialForms.row.activate')}
              </Button>
              <Button variant="ghost" size="sm" onClick={() => onAction(r, 'retire')}>
                {t('officialForms.row.discard')}
              </Button>
            </>
          )}
          {r.status === 'active' && (
            <Button variant="ghost" size="sm" onClick={() => onAction(r, 'retire')}>
              {t('officialForms.row.switchBack')}
            </Button>
          )}
          {rollbackable(r) && (
            <Button variant="ghost" size="sm" onClick={() => onAction(r, 'rollback')}>
              {t('officialForms.row.rollback')}
            </Button>
          )}
        </div>
      ),
    },
  ]

  return (
    <>
      <DetailHeader
        title={t(`officialForms.form.${form}.name`)}
        path={t(`officialForms.form.${form}.code`)}
        actions={
          <>
            <Button variant="secondary" size="sm" disabled={busy} onClick={onStarter} data-testid="official-forms-starter">
              {t('officialForms.action.downloadStarter')}
            </Button>
            <Button variant="primary" size="sm" onClick={() => setOpen((o) => !o)} data-testid="official-forms-upload-toggle">
              {t('officialForms.action.upload')}
            </Button>
            <Button variant="ghost" size="sm" iconOnly label={t('officialForms.close')} icon={<X className="lf-icon" aria-hidden="true" />} onClick={onClose} />
          </>
        }
      />
      <div className="lf-card__body lf-form">
        <FormSection title={t('officialForms.section.current')}>
          <ul data-testid="official-forms-current" aria-busy={loading || undefined}>
            {!loading && TEMPLATE_LOCALES.filter((l) => l !== 'default' || state.active.some((r) => r.locale === 'default')).map((l) => {
              const a = state.active.find((r) => r.locale === l)
              return (
                <li key={l}>
                  {a
                    ? t('officialForms.current.own', { lang: langName(l), n: a.version_no, date: date(a.activated_at) })
                    : t('officialForms.current.standard', { lang: langName(l) })}
                </li>
              )
            })}
          </ul>
          <p className="caption lf-faint">{t('officialForms.current.pdf')}</p>
        </FormSection>

        {open && (
          <FormSection title={t('officialForms.section.upload')}>
            <div data-testid="official-forms-upload">
              <Select
                label={t('officialForms.upload.language')}
                value={uploadLocale}
                onChange={(v) => setUploadLocale(v as TemplateLocale)}
                options={TEMPLATE_LOCALES.map((l) => ({ value: l, label: langName(l) }))}
              />
              <DropZone
                accept=".docx"
                maxBytes={1048576}
                title={t('officialForms.upload.drop')}
                limits={t('officialForms.upload.limits')}
                invalidText={t('officialForms.upload.invalid')}
                chosen={file ? { file } : null}
                onFile={(f) => {
                  setFile(f)
                  setResult(null)
                }}
              />
              {result?.refusals && <RefusalList refusals={result.refusals} />}
              {result && !result.refusals && result.errorKey && (
                <Banner tone="danger">
                  <span data-testid="official-forms-upload-error">{t(result.errorKey)}</span>
                </Banner>
              )}
              <div className="lf-btn-row">
                <Button variant="primary" disabled={!file} loading={uploading} onClick={() => file && void submit(file)} data-testid="official-forms-upload-submit">
                  {t('officialForms.upload.submit')}
                </Button>
                <Button variant="secondary" disabled={uploading} onClick={() => setOpen(false)}>
                  {t('officialForms.upload.cancel')}
                </Button>
              </div>
            </div>
          </FormSection>
        )}

        <FormSection title={t('officialForms.section.versions')}>
          <DataTable
            density="compact"
            columns={columns}
            data={formRows}
            isLoading={loading}
            getRowId={(r) => r.id}
            emptyMessage={t('officialForms.versions.empty')}
            emptyText={t('officialForms.versions.emptyText')}
            labels={{ loading: t('officialForms.loading'), retry: t('officialForms.retry') }}
          />
        </FormSection>
      </div>
    </>
  )
}
