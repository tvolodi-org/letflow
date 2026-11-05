/** CountPostingPanel — GH 3763 / REQ-718. From status signed on: post the signed differences sheet to the stock
 *  ledger (the Post button only starts the human post task, which is completed in the task inbox), issue the
 *  posting record once posted, and reverse the whole count. Buttons follow the order's posting state and the user's
 *  atoms; the server stays the authority (a refusal is shown as its own message). Assumption, owner may change at
 *  GATE B (D-086): there is no count freeze, so a difference is posted as a delta. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { useAccess } from '@/auth/access/useAccess'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Dialog } from '@/components/ui/Dialog'
import { Field } from '@/components/ui/Field'
import { FormSection } from '@/components/ui/FormSection'
import { Select } from '@/components/ui/Select'
import { useToast } from '@/hooks/useToast'
import { REVERSE_REASONS, TEXT_MAX, reasonTextError } from '../documents/documentsModel'
import { countsApi, type CountOrder } from './counts.api'
import { canIssuePostingRecord, canPost, canReverse, formatInZone, reasonMessageId } from './countsModel'
import { useCountsWrite } from './useCountsWrite'

type Dlg = 'post' | 'reverse' | null

export function CountPostingPanel({ order }: { order: CountOrder }) {
  return ['signed', 'posted'].includes(order.status) && order.posting_state !== undefined ? <PostingBody order={order} /> : null
}

function PostingBody({ order }: { order: CountOrder }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const toast = useToast()
  const { can } = useAccess()
  const [dlg, setDlg] = useState<Dlg>(null)
  const [code, setCode] = useState('')
  const [text, setText] = useState('')
  const [touched, setTouched] = useState(false)
  const post = useCountsWrite(() => countsApi.post(order.id))
  const reverse = useCountsWrite((body: { reason_code: string; reason_text?: string }) => countsApi.reverse(order.id, body))
  const record = useCountsWrite(() => countsApi.postingRecord(order.id))
  const dash = t('stock.common.dash')
  const state = order.posting_state ?? 'none'

  function closeDialog() {
    setDlg(null)
    setCode('')
    setText('')
    setTouched(false)
    post.reset()
    reverse.reset()
  }
  async function postNow() {
    const res = await post.submit(undefined)
    if (res.ok) {
      toast.success(t('counts.toast.posted'))
      closeDialog()
    }
  }
  const reasonError = code === '' ? 'stock.doc.error.field_required' : reasonTextError(code, text)
  async function reverseNow() {
    setTouched(true)
    if (reasonError) return
    const res = await reverse.submit({ reason_code: code, ...(text.trim() !== '' ? { reason_text: text } : {}) })
    if (res.ok) {
      toast.success(t('counts.toast.reversed'))
      closeDialog()
    }
  }
  async function recordNow() {
    const res = await record.submit(undefined)
    if (res.ok) toast.success(t('counts.toast.postingRecord'))
  }

  const waiting = order.post_pending ? 'counts.posting.waiting.post' : order.reverse_pending ? 'counts.posting.waiting.reverse' : null
  return (
    <>
      <FormSection title={t('counts.posting.title')}>
        <div className="lf-form" data-testid="posting-panel">
          {waiting && (
            <Banner tone="info" action={<Link to="/tasks">{t('stock.doc.waiting.link')}</Link>}>
              {t(waiting)}
            </Banner>
          )}
          {order.posting_check === 'mismatch' && <Banner tone="danger">{t('counts.posting.mismatch')}</Banner>}
          {record.error !== null && <Banner tone="danger">{t(reasonMessageId(record.error))}</Banner>}
          <dl className="lf-dl" data-testid="posting-facts">
            <dt>{t('counts.posting.state')}</dt>
            <dd data-testid="posting-state">{t(`counts.posting.state.${state}`)}</dd>
            {order.entry_id && (
              <>
                <dt>{t('counts.posting.entry')}</dt>
                <dd><span className="mono">{order.entry_id}</span></dd>
              </>
            )}
            {order.posted_at && (
              <>
                <dt>{t('counts.posting.postedAt')}</dt>
                <dd>{formatInZone(order.posted_at) || dash}</dd>
              </>
            )}
            {order.reversed_at && (
              <>
                <dt>{t('counts.posting.reversedAt')}</dt>
                <dd>{formatInZone(order.reversed_at) || dash}</dd>
              </>
            )}
            {order.posting_number && (
              <>
                <dt>{t('counts.posting.record')}</dt>
                <dd><span className="mono">{order.posting_number}</span></dd>
              </>
            )}
          </dl>
          <p className="lf-hint">{t('counts.posting.noFreeze')}</p>
          <div className="lf-form__actions">
            {canPost(order, can) && (
              <Button variant="primary" size="sm" onClick={() => setDlg('post')} data-testid="count-post">
                {t('counts.action.post')}
              </Button>
            )}
            {canIssuePostingRecord(order, can) && (
              <Button variant="primary" size="sm" loading={record.isPending} onClick={() => void recordNow()} data-testid="count-posting-record">
                {t('counts.action.postingRecord')}
              </Button>
            )}
            {canReverse(order, can) && (
              <Button variant="danger" size="sm" onClick={() => setDlg('reverse')} data-testid="count-reverse">
                {t('counts.action.reverse')}
              </Button>
            )}
          </div>
        </div>
      </FormSection>
      <ConfirmDialog
        open={dlg === 'post'}
        title={t('counts.posting.confirm.title')}
        body={t('counts.posting.confirm.body')}
        confirmText={t('counts.action.post')}
        cancelText={t('stock.doc.dialog.back')}
        isLoading={post.isPending}
        error={post.error !== null ? t(reasonMessageId(post.error)) : null}
        onConfirm={() => void postNow()}
        onCancel={closeDialog}
      />
      <Dialog
        open={dlg === 'reverse'}
        title={t('counts.reverse.title')}
        confirmText={t('counts.action.reverse')}
        cancelText={t('stock.doc.dialog.back')}
        confirmVariant="danger"
        isLoading={reverse.isPending}
        error={reverse.error !== null ? t(reasonMessageId(reverse.error)) : null}
        onConfirm={() => void reverseNow()}
        onCancel={closeDialog}
        testId="count-reverse-dialog"
      >
        <p>{t('counts.reverse.body')}</p>
        <Select
          label={t('stock.doc.reason.code')}
          value={code}
          onChange={setCode}
          options={REVERSE_REASONS.map((r) => ({ value: r, label: t(`stock.doc.reverseReason.${r}`) }))}
          placeholder={t('stock.doc.reason.choose')}
          error={touched && code === '' ? t('stock.doc.error.field_required') : undefined}
        />
        <Field label={t('stock.doc.reason.text')} error={touched && code !== '' && reasonError ? t(reasonError) : undefined} hint={t('stock.doc.reason.hint')}>
          <textarea value={text} maxLength={TEXT_MAX + 1} rows={3} onChange={(e) => setText(e.target.value)} />
        </Field>
      </Dialog>
    </>
  )
}
