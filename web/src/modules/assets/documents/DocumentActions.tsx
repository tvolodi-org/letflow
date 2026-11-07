/** DocumentActions — T-1334 / C14. The action bar of the asset document view: Issue and Discard (draft), Reverse
 *  (posted), Edit (draft, opens the form in the view). A button shows only when the user's access lists the atom of its
 *  route and the state allows it; the server stays the authority. Confirm dialogs for discard and issue, a reason dialog
 *  for reverse. There is no Retry or Cancel: the assets router has no post or cancel route. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Dialog } from '@/components/ui/Dialog'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import { assetsQueryKeys } from '../assetsQueryKeys'
import { assetDocumentsApi, type AssetDocument } from './assetDocuments.api'
import { REVERSE_REASONS, TEXT_MAX, actionsFor, documentErrorInfo, documentErrorMessageId, reasonTextError } from './documentsModel'

type Dlg = 'discard' | 'issue' | 'reverse' | null

export function DocumentActions({ doc, onEdit }: { doc: AssetDocument; onEdit?: () => void }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const qc = useQueryClient()
  const navigate = useNavigate()
  const [dlg, setDlg] = useState<Dlg>(null)
  const [error, setError] = useState<string | null>(null)
  const [code, setCode] = useState('')
  const [text, setText] = useState('')
  const [touched, setTouched] = useState(false)
  const acts = actionsFor(doc.state, can)

  const close = () => {
    setDlg(null)
    setError(null)
    setCode('')
    setText('')
    setTouched(false)
  }
  const run = useMutation({
    mutationFn: async (what: 'discard' | 'issue' | 'reverse') => {
      switch (what) {
        case 'discard': return assetDocumentsApi.discard(doc.id)
        case 'issue': return assetDocumentsApi.issue(doc.id)
        case 'reverse': return assetDocumentsApi.reverse(doc.id, { reason_code: code, ...(text.trim() !== '' ? { reason_text: text } : {}) })
      }
    },
    onSuccess: async (_d, what) => {
      close()
      if (what === 'discard') {
        await qc.invalidateQueries({ queryKey: assetsQueryKeys.documentsAll(tenantId) })
        navigate('/admin/assets/documents')
        return
      }
      await qc.invalidateQueries({ queryKey: assetsQueryKeys.document(tenantId, doc.id) })
      await qc.invalidateQueries({ queryKey: assetsQueryKeys.documentsAll(tenantId) })
    },
    onError: (e) => {
      const line = documentErrorInfo(e).lineNo
      const msg = t(documentErrorMessageId(e))
      setError(line !== undefined ? `${intl.formatMessage({ id: 'assets.doc.error.line' }, { line })} ${msg}` : msg)
    },
  })

  const reasonError = dlg === 'reverse' ? (code === '' ? 'assets.doc.error.field_required' : reasonTextError(code, text)) : null
  const shownReasonError = touched && reasonError ? t(reasonError) : undefined
  const submitReason = () => {
    setTouched(true)
    if (reasonError) return
    run.mutate('reverse')
  }

  if (!acts.edit && !acts.discard && !acts.issue && !acts.reverse) return null
  return (
    <div className="lf-btn-row" data-testid="document-actions">
      {acts.edit && onEdit && <Button variant="secondary" onClick={onEdit}>{t('assets.doc.action.edit')}</Button>}
      {acts.issue && <Button variant="primary" onClick={() => setDlg('issue')}>{t('assets.doc.action.issue')}</Button>}
      {acts.discard && <Button variant="danger" onClick={() => setDlg('discard')}>{t('assets.doc.action.discard')}</Button>}
      {acts.reverse && <Button variant="danger" onClick={() => setDlg('reverse')}>{t('assets.doc.action.reverse')}</Button>}
      {error && dlg === null && <span role="alert" data-testid="action-error">{error}</span>}

      <ConfirmDialog
        open={dlg === 'discard'}
        title={t('assets.doc.discard.title')}
        body={t('assets.doc.discard.body')}
        confirmText={t('assets.doc.action.discard')}
        cancelText={t('assets.doc.dialog.back')}
        confirmVariant="danger"
        isLoading={run.isPending}
        error={error}
        onConfirm={() => run.mutate('discard')}
        onCancel={close}
      />
      <ConfirmDialog
        open={dlg === 'issue'}
        title={t('assets.doc.issue.title')}
        body={t('assets.doc.issue.body')}
        confirmText={t('assets.doc.action.issue')}
        cancelText={t('assets.doc.dialog.back')}
        isLoading={run.isPending}
        error={error}
        onConfirm={() => run.mutate('issue')}
        onCancel={close}
      />
      <Dialog
        open={dlg === 'reverse'}
        title={t('assets.doc.reverse.title')}
        confirmText={t('assets.doc.action.reverse')}
        cancelText={t('assets.doc.dialog.back')}
        confirmVariant="danger"
        isLoading={run.isPending}
        error={error}
        onConfirm={submitReason}
        onCancel={close}
        testId="reason-dialog"
      >
        <Select
          label={t('assets.doc.reason.code')}
          value={code}
          onChange={setCode}
          options={REVERSE_REASONS.map((r) => ({ value: r, label: t(`assets.doc.reverseReason.${r}`) }))}
          placeholder={t('assets.doc.reason.choose')}
          error={touched && code === '' ? t('assets.doc.error.field_required') : undefined}
        />
        <Field label={t('assets.doc.reason.text')} error={shownReasonError} hint={t('assets.doc.reason.hint')}>
          <textarea value={text} maxLength={TEXT_MAX + 1} rows={3} onChange={(e) => setText(e.target.value)} />
        </Field>
      </Dialog>
    </div>
  )
}
