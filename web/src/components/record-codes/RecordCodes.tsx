/** The codes of one item, location or lot. The host owns the query so it can show its count. */
import { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { Plus } from 'lucide-react'
import { useAccess } from '@/auth/access'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Radio } from '@/components/ui/Checkbox'
import { DataTable } from '@/components/ui/DataTable'
import { Dialog } from '@/components/ui/Dialog'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { TruncatedNotice } from '@/components/ui/TruncatedNotice'
import { usePickableCodes, useRecordCodes, useRecordCodeWrite } from '@/hooks/useRecordCodes'
import { useToast } from '@/hooks/useToast'
import { formatDate } from '@/i18n/format'
import { RECORD_CODE_KINDS, errorMessageKey, type CodeKind, type CodeTarget } from '@/lib/codes/recordCodes.api'
import { RecordCodesIntlProvider } from './RecordCodesIntlProvider'

interface Props {
  targetType: CodeTarget
  targetId: string
  targetActive: boolean
  data: ReturnType<typeof useRecordCodes>
  initialDialog?: 'new' | 'pick'
  onDialogChange?: (open: boolean) => void
}
const EMPTY: NonNullable<Props['data']['data']>['rows'] = []
export function RecordCodes(props: Props) {
  return <RecordCodesIntlProvider><RecordCodesInner {...props} /></RecordCodesIntlProvider>
}
function RecordCodesInner({ targetType, targetId, targetActive, data, initialDialog, onDialogChange }: Props) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id: `recordCodes.${id}` })
  const canWrite = useAccess().can('CodesWrite')
  const [dialogOpen, setDialogOpen] = useState(!!initialDialog && canWrite && targetActive)
  const [mode, setMode] = useState<'new' | 'pick'>(initialDialog ?? 'new')
  const [value, setValue] = useState('')
  const [kind, setKind] = useState<CodeKind>('barcode')
  const [searchInput, setSearchInput] = useState('')
  const [search, setSearch] = useState('')
  const [codeId, setCodeId] = useState('')
  const pick = usePickableCodes(search, dialogOpen && mode === 'pick')
  const write = useRecordCodeWrite(targetType, targetId)
  const toast = useToast()
  useEffect(() => { onDialogChange?.(dialogOpen) }, [dialogOpen, onDialogChange])
  useEffect(() => () => onDialogChange?.(false), [onDialogChange])
  const errorKey = write.error ? errorMessageKey(write.error) : null
  const fieldError = mode === 'new' && errorKey && ['valueTaken', 'valueInvalid', 'kindInvalid'].includes(errorKey)
  function open() { write.clearError(); setValue(''); setCodeId(''); setMode('new'); setDialogOpen(true) }
  async function confirm() {
    if (!canWrite || !targetActive) return
    const result = await write.submit(mode === 'new' ? { op: 'new', value, kind } : { op: 'attach', codeId })
    if (result !== 'error') setDialogOpen(false)
    if (result === 'ok') toast.success(t(`toast.${mode === 'new' ? 'new' : 'attach'}`))
  }
  const rows = data.data?.rows ?? EMPTY
  const newButton = canWrite && targetActive ? <Button variant="secondary" size="sm" icon={<Plus className="lf-icon" aria-hidden="true" />} onClick={open} data-testid="record-codes-new">{t('new')}</Button> : null
  return <div data-testid="record-codes">
    <div className="lf-card__body lf-form">
    <div className="lf-btn-row lf-btn-row--between">
      {newButton}
      {canWrite && <Link className="lf-link" to="/admin/codes">{t('open')}</Link>}
    </div>
    {!targetActive && <p className="caption lf-faint">{t('retiredTarget')}</p>}
    {!dialogOpen && errorKey && <div data-testid="record-codes-error"><Banner tone="danger">{t(`error.${errorKey}`)}</Banner></div>}
    {data.data?.truncated && <TruncatedNotice messageId="recordCodes.truncated" count={rows.length} />}
    </div>
    <div data-testid="record-codes-table"><DataTable
      data={rows} getRowId={(r) => r.codeId} isLoading={data.isLoading}
      error={data.isError ? t('loadError') : undefined} onRetry={() => void data.refetch()}
      labels={{ loading: t('loading'), retry: t('retry') }} emptyMessage={t('empty')}
      columns={[
        { key: 'value', label: t('value'), mono: true, render: (r) => r.value },
        { key: 'kind', label: t('kind'), render: (r) => t(`kind.${r.kind}`) },
        { key: 'status', label: t('status'), render: (r) => <StatusPill tone={r.status === 'assigned' ? 'success' : 'neutral'} glyph={r.status === 'assigned' ? 'dot' : r.status === 'retired' ? 'dash' : 'ring'}>{t(`status.${r.status}`)}</StatusPill> },
        { key: 'date', label: t('attachedOn'), mono: true, render: (r) => formatDate(r.assignedAt, undefined, intl.locale) },
        ...(canWrite ? [{ key: 'actions', label: t('actions'), render: (r: typeof rows[number]) => <Button variant="secondary" size="sm" disabled={write.isPending} data-testid={`record-codes-release-${r.codeId}`} onClick={() => { void write.submit({ op: 'release', codeId: r.codeId }).then((result) => { if (result === 'ok') toast.success(t('toast.release')) }) }}>{t('release')}</Button> }] : []),
      ]}
    /></div>
    <Dialog open={dialogOpen} title={t('dialog.title')} confirmText={t('dialog.confirm')} testId="record-codes-dialog"
      onCancel={() => setDialogOpen(false)} onConfirm={() => void confirm()} isLoading={write.isPending}
      confirmDisabled={mode === 'new' ? !value.trim() : !codeId}
      error={errorKey && !fieldError ? t(`error.${errorKey}`) : null}>
      <div className="lf-form">
        <Radio name="record-code-mode" label={t('dialog.new')} checked={mode === 'new'} onChange={() => { setMode('new'); write.clearError() }} />
        <Radio name="record-code-mode" label={t('dialog.pick')} checked={mode === 'pick'} onChange={() => { setMode('pick'); write.clearError() }} />
        {mode === 'new' ? <>
          <Field label={t('value')} mono error={fieldError && errorKey !== 'kindInvalid' ? t(`error.${errorKey}`) : undefined}>
            <input name="code_value" data-testid="record-codes-value" value={value} onChange={(e) => { setValue(e.target.value); write.clearError() }} />
          </Field>
          <Select label={t('kind')} name="code_kind" value={kind} options={RECORD_CODE_KINDS.map((k) => ({ value: k, label: t(`kind.${k}`) }))} onChange={(v) => { setKind(v as CodeKind); write.clearError() }} error={fieldError && errorKey === 'kindInvalid' ? t(`error.${errorKey}`) : undefined} />
        </> : <>
          <Field label={t('pick.search')} mono><input data-testid="record-codes-search" value={searchInput} onChange={(e) => setSearchInput(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); setCodeId(''); setSearch(searchInput) } }} /></Field>
          <Button variant="secondary" size="sm" onClick={() => { setCodeId(''); setSearch(searchInput) }}>{t('pick.find')}</Button>
          {pick.isLoading ? <p>{t('loading')}</p> : pick.isError ? <Banner tone="danger">{t('loadError')} <Button variant="secondary" size="sm" onClick={() => void pick.refetch()}>{t('retry')}</Button></Banner> : <>
            <Select label={t('pick.code')} name="received_code" value={codeId} placeholder={t('pick.choose')} onChange={setCodeId} options={(pick.data?.items ?? []).map((r) => ({ value: r.record_id, label: `${String(r.field_values['value'])} · ${t(`kind.${String(r.field_values['kind'])}`)}` }))} />
            {pick.data?.items.length === 0 && <p>{t('pick.none')}</p>}
            {pick.data?.more && <p>{t('pick.more')}</p>}
          </>}
        </>}
      </div>
    </Dialog>
  </div>
}
