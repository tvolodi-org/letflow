/** DocumentActions — GH 3769 / REQ-722. The action bar of the document view: Edit, Discard and Issue (draft), Retry
 *  posting and Cancel (issued), Reverse (posted), Cancel (reversed). A button shows only when the user's access lists
 *  the atom of its route and the state allows it; the server stays the authority. Confirm dialogs for discard and
 *  issue, a reason dialog for reverse and cancel. */
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
import { stockQueryKeys } from '../register/stockQueryKeys'
import { documentsApi, type StockDocument } from './documents.api'
import { REVERSE_REASONS, TEXT_MAX, actionsFor, documentErrorInfo, documentErrorMessageId, isOpening, reasonTextError } from './documentsModel'

type Dlg = 'discard' | 'issue' | 'reverse' | 'cancel' | null

export function DocumentActions({ doc, onEdit }: { doc: StockDocument; onEdit: () => void }) {
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
  const [checkMsgs, setCheckMsgs] = useState<string[] | null>(null)
  const acts = actionsFor(doc.state, can, doc.kind)

  const close = () => {
    setDlg(null)
    setError(null)
    setCode('')
    setText('')
    setTouched(false)
  }
  const refresh = async () => {
    await qc.invalidateQueries({ queryKey: stockQueryKeys.document(tenantId, doc.id) })
    await qc.invalidateQueries({ queryKey: stockQueryKeys.documentsAll(tenantId) })
  }
  const run = useMutation({
    mutationFn: async (what: 'discard' | 'issue' | 'post' | 'reverse' | 'cancel') => {
      switch (what) {
        case 'discard': return documentsApi.discard(doc.id)
        case 'issue': return documentsApi.issue(doc.id)
        case 'post': return documentsApi.post(doc.id)
        case 'reverse': return documentsApi.reverse(doc.id, { reason_code: code, ...(text.trim() !== '' ? { reason_text: text } : {}) })
        case 'cancel': return documentsApi.cancel(doc.id, { reason: text.trim() })
      }
    },
    onSuccess: async (_d, what) => {
      close()
      if (what === 'discard') {
        await qc.invalidateQueries({ queryKey: stockQueryKeys.documentsAll(tenantId) })
        navigate('/admin/stock/documents')
        return
      }
      await refresh()
    },
    onError: (e) => {
      const line = documentErrorInfo(e).lineNo
      const text = t(documentErrorMessageId(e))
      setError(isOpening(doc.kind) && line !== undefined ? `${intl.formatMessage({ id: 'stock.doc.error.line' }, { line })} ${text}` : text)
    },
  })
  const check = useMutation({
    mutationFn: () => documentsApi.check(doc.id),
    onSuccess: (r) => {
      setError(null)
      setCheckMsgs(
        r.lines.flatMap((l) =>
          l.reasons.map((reason) =>
            intl.formatMessage(
              { id: 'stock.doc.check.line' },
              { line: l.line_no, reason: t(`stock.doc.error.${reason}`) },
            ),
          ),
        ),
      )
    },
    onError: (e) => setError(t(documentErrorMessageId(e))),
  })

  const reasonError =
    dlg === 'reverse' ? (code === '' ? 'stock.doc.error.field_required' : reasonTextError(code, text))
    : dlg === 'cancel' ? (text.trim() === '' ? 'stock.doc.error.reasonTextRequired' : reasonTextError('', text))
    : null
  const shownReasonError = touched && reasonError ? t(reasonError) : undefined
  const submitReason = () => {
    setTouched(true)
    if (reasonError) return
    run.mutate(dlg === 'reverse' ? 'reverse' : 'cancel')
  }

  if (!acts.edit && !acts.discard && !acts.issue && !acts.retry && !acts.cancel && !acts.reverse) return null
  return (
    <div className="lf-btn-row" data-testid="document-actions">
      {acts.edit && <Button variant="secondary" onClick={onEdit}>{t('stock.doc.action.edit')}</Button>}
      {acts.issue && isOpening(doc.kind) && (
        <Button variant="secondary" loading={check.isPending} onClick={() => { setError(null); check.mutate() }}>
          {t('stock.doc.action.check')}
        </Button>
      )}
      {acts.issue && <Button variant="primary" onClick={() => setDlg('issue')}>{t('stock.doc.action.issue')}</Button>}
      {acts.discard && <Button variant="danger" onClick={() => setDlg('discard')}>{t('stock.doc.action.discard')}</Button>}
      {acts.retry && (
        <Button variant="secondary" loading={run.isPending && run.variables === 'post'} onClick={() => { setError(null); run.mutate('post') }}>
          {t('stock.doc.action.retry')}
        </Button>
      )}
      {acts.reverse && <Button variant="danger" onClick={() => setDlg('reverse')}>{t('stock.doc.action.reverse')}</Button>}
      {acts.cancel && <Button variant="danger" onClick={() => setDlg('cancel')}>{t('stock.doc.action.cancel')}</Button>}
      {error && dlg === null && <span role="alert" data-testid="action-error">{error}</span>}
      {checkMsgs !== null && (
        <div role="status" data-testid="check-result">
          {checkMsgs.length === 0 ? (
            <p>{t('stock.doc.check.ok')}</p>
          ) : (
            <ul>{checkMsgs.map((m, i) => <li key={i}>{m}</li>)}</ul>
          )}
        </div>
      )}

      <ConfirmDialog
        open={dlg === 'discard'}
        title={t('stock.doc.discard.title')}
        body={t('stock.doc.discard.body')}
        confirmText={t('stock.doc.action.discard')}
        cancelText={t('stock.doc.dialog.back')}
        confirmVariant="danger"
        isLoading={run.isPending}
        error={error}
        onConfirm={() => run.mutate('discard')}
        onCancel={close}
      />
      <ConfirmDialog
        open={dlg === 'issue'}
        title={t('stock.doc.issue.title')}
        body={t('stock.doc.issue.body')}
        confirmText={t('stock.doc.action.issue')}
        cancelText={t('stock.doc.dialog.back')}
        isLoading={run.isPending}
        error={error}
        onConfirm={() => run.mutate('issue')}
        onCancel={close}
      />
      <Dialog
        open={dlg === 'reverse' || dlg === 'cancel'}
        title={t(dlg === 'reverse' ? 'stock.doc.reverse.title' : 'stock.doc.cancel.title')}
        confirmText={t(dlg === 'reverse' ? 'stock.doc.action.reverse' : 'stock.doc.action.cancel')}
        cancelText={t('stock.doc.dialog.back')}
        confirmVariant="danger"
        isLoading={run.isPending}
        error={error}
        onConfirm={submitReason}
        onCancel={close}
        testId="reason-dialog"
      >
        {dlg === 'reverse' && (
          <Select
            label={t('stock.doc.reason.code')}
            value={code}
            onChange={setCode}
            options={REVERSE_REASONS.map((r) => ({ value: r, label: t(`stock.doc.reverseReason.${r}`) }))}
            placeholder={t('stock.doc.reason.choose')}
            error={touched && code === '' ? t('stock.doc.error.field_required') : undefined}
          />
        )}
        <Field label={t('stock.doc.reason.text')} error={shownReasonError} hint={t('stock.doc.reason.hint')}>
          <textarea value={text} maxLength={TEXT_MAX + 1} rows={3} onChange={(e) => setText(e.target.value)} />
        </Field>
      </Dialog>
    </div>
  )
}
