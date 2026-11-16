/** OfficialFormTemplatesPage — T-1983 (form-template editor S5, docs/design/form-template-editor.md).
 *  Route /admin/official-forms, permission OfficialFormTemplatesManage. A list of the 12 official forms (ListDetail) and,
 *  in the detail panel, the starter download, upload with the refusal list, preview, activate, retire, rollback and the
 *  version history. Server: /api/v1/documents/official-form-templates.
 *  `initialSelectedKey`, `initialUploadOpen`, `initialFile`, `submitUploadOnMount`, `initialDialog`, `initialReason` and
 *  `submitDialogOnMount` are HARNESS-ONLY props (the screenshot tool cannot click); the router never passes them. */
import React, { useEffect, useMemo, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import {
  officialFormTemplatesApi,
  refusalsOf,
  type FetchedTemplateFile,
  type OfficialFormTemplateMeta,
  type TemplateAction,
  type TemplateLocale,
  type TemplateRefusal,
} from '@/api/officialFormTemplates'
import { Banner } from '@/components/ui/Banner'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { EmptyState } from '@/components/ui/EmptyState'
import { ListDetail, useListSelection } from '@/components/ui/listDetail'
import { PageHeader } from '@/components/ui/PageHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { StatusPill } from '@/components/ui/StatusPill'
import {
  useOfficialFormTemplateTransition,
  useOfficialFormTemplatesList,
  useUploadOfficialFormTemplate,
} from '@/hooks/useOfficialFormTemplates'
import { useToast } from '@/hooks/useToast'
import { saveBlob } from '@/lib/saveBlob'
import { classifyError } from '@/utils/classifyError'
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { OfficialFormDetail, type UploadResult } from './OfficialFormDetail'
import { OfficialFormsIntlProvider } from './OfficialFormsIntlProvider'
import { ReasonDialog } from './ReasonDialog'
import {
  OFFICIAL_TEMPLATE_FORMS,
  conflictKey,
  fileNameOf,
  formState,
  rowsOf,
  uploadErrorKey,
  type OfficialTemplateForm,
} from './officialFormsModel'

export interface OfficialFormTemplatesPageProps {
  locale?: UiLocale
  /** Harness only. */
  initialSelectedKey?: string
  /** Harness only. */
  initialUploadOpen?: boolean
  /** Harness only. */
  initialFile?: File
  /** Harness only. */
  submitUploadOnMount?: boolean
  /** Harness only. */
  initialDialog?: { action: TemplateAction; id: string }
  /** Harness only. */
  initialReason?: string
  /** Harness only. */
  submitDialogOnMount?: boolean
}

export default function OfficialFormTemplatesPage(props: OfficialFormTemplatesPageProps): React.ReactElement {
  return (
    <OfficialFormsIntlProvider locale={props.locale}>
      <OfficialFormTemplatesInner {...props} />
    </OfficialFormsIntlProvider>
  )
}

interface DialogState {
  action: TemplateAction
  id: string
  reason: string
  errorKey: string | null
  refusals: TemplateRefusal[] | null
}

function OfficialFormTemplatesInner(props: OfficialFormTemplatesPageProps) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const list = useOfficialFormTemplatesList()
  const upload = useUploadOfficialFormTemplate()
  const transition = useOfficialFormTemplateTransition()
  const sel = useListSelection(props.initialSelectedKey ?? null)
  const [dialog, setDialog] = useState<DialogState | null>(
    props.initialDialog
      ? { ...props.initialDialog, reason: props.initialReason ?? '', errorKey: null, refusals: null }
      : null,
  )
  const [busy, setBusy] = useState(false)
  const flying = useRef(false)

  const rows = useMemo(() => list.data?.templates ?? [], [list.data])
  const selected = OFFICIAL_TEMPLATE_FORMS.find((f) => f.id === sel.selectedId) ?? null
  const formLabel = (id: string) => `${t(`officialForms.form.${id}.code`)} ${t(`officialForms.form.${id}.name`)}`
  const dialogRow = dialog ? rows.find((r) => r.id === dialog.id) ?? null : null

  const columns: DataTableColumn<OfficialTemplateForm>[] = [
    {
      id: 'form',
      header: t('officialForms.col.form'),
      render: (f) => (
        <>
          <span className="mono">{t(`officialForms.form.${f.id}.code`)}</span>
          <br />
          <span className="caption lf-faint">{t(`officialForms.form.${f.id}.name`)}</span>
        </>
      ),
    },
    { id: 'module', header: t('officialForms.col.module'), render: (f) => t(`officialForms.module.${f.module}`) },
    {
      id: 'state',
      header: t('officialForms.col.state'),
      render: (f) => {
        const s = formState(rowsOf(rows, f.id))
        const versions = s.active.map((r) => (r.locale === 'default' ? `v${r.version_no}` : `${r.locale} v${r.version_no}`)).join(' · ')
        return (
          <>
            {s.active.length === 0 ? (
              <StatusPill tone="neutral" glyph="dash">
                {t('officialForms.state.standard')}
              </StatusPill>
            ) : (
              <StatusPill tone="success" glyph="dot">
                {t('officialForms.state.own', { versions })}
              </StatusPill>
            )}
            {s.draft && (
              <>
                {' '}
                <StatusPill tone="info" glyph="ring">
                  {t('officialForms.state.draft', { n: s.draft.version_no })}
                </StatusPill>
              </>
            )}
          </>
        )
      },
    },
  ]

  /** One download at a time; a refusal shows a toast and never leaves a half state. */
  const download = async (fetchFile: () => Promise<FetchedTemplateFile>, fallback: string) => {
    if (flying.current) return
    flying.current = true
    setBusy(true)
    try {
      const { blob, contentDisposition } = await fetchFile()
      saveBlob(blob, fileNameOf(contentDisposition, fallback))
    } catch {
      toast.error(t('officialForms.toast.noFile'))
    } finally {
      flying.current = false
      setBusy(false)
    }
  }
  const nameOf = (r: OfficialFormTemplateMeta) => `${r.form}-${r.locale}-v${r.version_no}`

  const doUpload = async (form: string, locale: TemplateLocale, file: File): Promise<UploadResult> => {
    try {
      const row = await upload.mutateAsync({ form, locale, file })
      toast.success(t('officialForms.toast.accepted', { n: row.version_no }))
      sel.saved({ kind: 'edit' })
      return { ok: true, refusals: null, errorKey: null }
    } catch (err) {
      const refusals = refusalsOf(err)
      return { ok: false, refusals, errorKey: refusals ? null : uploadErrorKey(err) }
    }
  }

  const confirm = async () => {
    if (!dialog || !dialogRow || dialog.reason === '') return
    try {
      const row = await transition.mutateAsync({ id: dialog.id, action: dialog.action, reasonCode: dialog.reason })
      const toastId = { activate: 'activated', retire: 'retired', rollback: 'rolledBack' }[dialog.action]
      toast.success(t(`officialForms.toast.${toastId}`, { n: row.version_no }))
      setDialog(null)
      sel.saved({ kind: 'edit' })
    } catch (err) {
      const refusals = refusalsOf(err)
      setDialog((d) => (d ? { ...d, refusals, errorKey: refusals ? null : conflictKey(err) } : d))
    }
  }

  // Harness only: confirm the initial dialog once, one frame after the list has loaded.
  const autoDone = useRef(false)
  useEffect(() => {
    if (!props.submitDialogOnMount || autoDone.current || !dialog || !dialogRow) return
    autoDone.current = true
    const frame = requestAnimationFrame(() => void confirm())
    return () => cancelAnimationFrame(frame)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dialogRow])

  const detail = selected ? (
    <OfficialFormDetail
      key={selected.id}
      form={selected.id}
      rows={rows}
      busy={busy}
      loading={list.isLoading}
      onClose={sel.close}
      onStarter={() => void download(() => officialFormTemplatesApi.starter(selected.id), `${selected.id}-starter.docx`)}
      onDownload={(r) => void download(() => officialFormTemplatesApi.download(r.id), `${nameOf(r)}.docx`)}
      onPreview={(r, lang) =>
        void download(() => officialFormTemplatesApi.preview(r.id, lang), `${nameOf(r)}-preview-${lang}.docx`)
      }
      onAction={(r, action) => {
        transition.reset()
        setDialog({ action, id: r.id, reason: '', errorKey: null, refusals: null })
      }}
      onUpload={(locale, file) => doUpload(selected.id, locale, file)}
      initialUploadOpen={props.initialUploadOpen}
      initialFile={props.initialFile}
      submitUploadOnMount={props.submitUploadOnMount}
    />
  ) : (
    <></>
  )

  return (
    <>
      <PageHeader eyebrow={t('officialForms.eyebrow')} title={t('officialForms.title')} lede={t('officialForms.lede')} />
      <Banner tone="info">
        <span data-testid="official-forms-notice">{t('officialForms.notice.printsPending')}</span>
      </Banner>
      <QueryStateBoundary
        state={list.isError ? classifyError(list.error) : 'success'}
        onRetry={() => void list.refetch()}
      >
        <ListDetail
          screen="admin.official-forms"
          listLabel={t('officialForms.list.label')}
          listDefault={45}
          defaultSelectId={OFFICIAL_TEMPLATE_FORMS[0].id}
          onDefaultSelect={sel.select}
          detailOpen={selected !== null}
          onClose={sel.close}
          escapeCloses={dialog === null}
          list={
            <DataTable
              density="compact"
              columns={columns}
              data={[...OFFICIAL_TEMPLATE_FORMS]}
              isLoading={list.isLoading}
              getRowId={(f) => f.id}
              selectedId={sel.selectedId}
              onRowClick={(f) => sel.select(f.id)}
              emptyMessage={t('officialForms.pick')}
              labels={{ loading: t('officialForms.loading'), retry: t('officialForms.retry') }}
            />
          }
          detail={detail}
          empty={
            <div className="lf-card__body">
              <EmptyState title={t('officialForms.pick')} data-testid="official-forms-pick" />
            </div>
          }
        />
      </QueryStateBoundary>
      {dialog && dialogRow && (
        <ReasonDialog
          action={dialog.action}
          row={dialogRow}
          rows={rowsOf(rows, dialogRow.form)}
          formLabel={formLabel(dialogRow.form)}
          reason={dialog.reason}
          onReason={(reason) => setDialog((d) => (d ? { ...d, reason } : d))}
          loading={transition.isPending}
          errorKey={dialog.errorKey}
          refusals={dialog.refusals}
          onConfirm={() => void confirm()}
          onCancel={() => setDialog(null)}
        />
      )}
    </>
  )
}
