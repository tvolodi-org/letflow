/** CountDetail — GH 3735 / REQ-702. One count in the detail panel: the order facts, the actions its status and the
 *  user's atoms allow (issue, cancel, close after a confirm dialog; open straight away), the edit form for a draft,
 *  and from status counting on the count sheet. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { useQuery } from '@tanstack/react-query'
import { X } from 'lucide-react'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { StatusPill } from '@/components/ui/StatusPill'
import { useToast } from '@/hooks/useToast'
import { classifyError } from '@/utils/classifyError'
import { useNames } from '../register/stockNames'
import { countsApi, type CountOrder } from './counts.api'
import { CountOrderForm } from './CountOrderForm'
import { CountSheet } from './CountSheet'
import { countsQueryKeys } from './countsQueryKeys'
import { canCancel, canClose, canEdit, canIssue, canOpen, formatInZone, hasSheet, reasonMessageId, statusTone, STOCK_COUNT_RECORD } from './countsModel'
import { useCountsWrite } from './useCountsWrite'

type Confirm = 'issue' | 'cancel' | 'close'

function Facts({ order }: { order: CountOrder }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const ids = (o: CountOrder) => ({
    org_unit: [o.org_unit_id],
    org_employee: [...(o.chair_employee_id ? [o.chair_employee_id] : []), ...o.member_employee_ids],
    location_node: o.location_ids,
  })
  const name = useNames([ids(order)])
  const dash = t('stock.common.dash')
  const list = (type: 'org_employee' | 'location_node', xs: string[]) => (xs.length === 0 ? t('counts.detail.none') : xs.map((x) => name(type, x)).join(', '))
  return (
    <dl className="lf-dl" data-testid="count-facts">
      <dt>{t('counts.col.orgUnit')}</dt>
      <dd>{name('org_unit', order.org_unit_id)}</dd>
      <dt>{t('counts.col.kind')}</dt>
      <dd>{t(`counts.kind.${order.kind}`)}</dd>
      <dt>{t('counts.col.plannedStart')}</dt>
      <dd>{formatInZone(order.planned_start) || dash}</dd>
      <dt>{t('counts.detail.plannedEnd')}</dt>
      <dd>{formatInZone(order.planned_end) || dash}</dd>
      <dt>{t('counts.col.chair')}</dt>
      <dd>{name('org_employee', order.chair_employee_id) || dash}</dd>
      <dt>{t('counts.detail.members')}</dt>
      <dd>{list('org_employee', order.member_employee_ids)}</dd>
      <dt>{t('counts.detail.locations')}</dt>
      <dd>{list('location_node', order.location_ids)}</dd>
      <dt>{t('counts.detail.note')}</dt>
      <dd>{order.note ?? dash}</dd>
      {order.issued_at && (
        <>
          <dt>{t('counts.detail.issuedAt')}</dt>
          <dd>{formatInZone(order.issued_at)}</dd>
        </>
      )}
    </dl>
  )
}

export function CountDetail({ id, onClose }: { id: string; onClose: () => void }) {
  const intl = useIntl()
  const t = (mid: string) => intl.formatMessage({ id: mid })
  const toast = useToast()
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [editing, setEditing] = useState(false)
  const [confirm, setConfirm] = useState<Confirm | null>(null)

  const query = useQuery({
    queryKey: countsQueryKeys.detail(tenantId, id),
    queryFn: () => countsApi.get(id),
    retry: false,
  })
  const run = useCountsWrite((kind: Confirm | 'open') => countsApi[kind](id))
  const order = query.data

  async function act(kind: Confirm | 'open') {
    const res = await run.submit(kind)
    if (res.ok) {
      toast.success(t(`counts.toast.${{ issue: 'issued', cancel: 'cancelled', open: 'opened', close: 'closed' }[kind]}`))
      setConfirm(null)
    }
  }

  const closeButton = (
    <Button variant="ghost" size="sm" iconOnly label={t('counts.action.closePanel')} icon={<X className="lf-icon" aria-hidden="true" />} onClick={onClose} data-testid="count-detail-close" />
  )

  if (query.isError && (query.error as { status?: number } | null)?.status === 404) {
    return (
      <>
        <DetailHeader title={t('counts.title')} actions={closeButton} />
        <div className="lf-card__body">
          <Banner tone="info">{t('counts.error.notFound')}</Banner>
        </div>
      </>
    )
  }
  const state = query.isPending ? 'loading' : query.isError ? classifyError(query.error) : 'success'
  return (
    <QueryStateBoundary state={state} onRetry={() => void query.refetch()}>
      {order && editing ? (
        <CountOrderForm order={order} onSaved={() => setEditing(false)} onDiscard={() => setEditing(false)} />
      ) : order ? (
        <>
          <DetailHeader
            title={order.number ?? t('counts.title')}
            status={<StatusPill tone={statusTone(order.status)}>{t(`counts.status.${order.status}`)}</StatusPill>}
            actions={
              <>
                {canEdit(order, can) && <Button variant="secondary" size="sm" onClick={() => setEditing(true)} data-testid="count-edit">{t('counts.action.edit')}</Button>}
                {canIssue(order, can) && <Button variant="primary" size="sm" onClick={() => setConfirm('issue')} data-testid="count-issue">{t('counts.action.issue')}</Button>}
                {canOpen(order, can) && <Button variant="primary" size="sm" loading={run.isPending} onClick={() => void act('open')} data-testid="count-open">{t('counts.action.open')}</Button>}
                {canClose(order, can) && <Button variant="primary" size="sm" onClick={() => setConfirm('close')} data-testid="count-close">{t('counts.action.close')}</Button>}
                {canCancel(order, can) && <Button variant="danger" size="sm" onClick={() => setConfirm('cancel')} data-testid="count-cancel">{t('counts.action.cancel')}</Button>}
                {closeButton}
              </>
            }
          />
          <div className="lf-card__body">
            {run.error !== null && confirm === null && <Banner tone="danger">{t(reasonMessageId(run.error))}</Banner>}
            <Facts order={order} />
            {hasSheet(order) && <CountSheet orderId={order.id} status={order.status} canRecord={can(STOCK_COUNT_RECORD)} />}
          </div>
          {confirm !== null && (
            <ConfirmDialog
              open
              title={t(`counts.confirm.${confirm}.title`)}
              body={t(`counts.confirm.${confirm}.body`)}
              confirmText={t(`counts.confirm.${confirm}.ok`)}
              cancelText={t('counts.confirm.keep')}
              confirmVariant={confirm === 'cancel' ? 'danger' : 'primary'}
              isLoading={run.isPending}
              error={run.error !== null ? t(reasonMessageId(run.error)) : null}
              onConfirm={() => void act(confirm)}
              onCancel={() => {
                setConfirm(null)
                run.reset()
              }}
            />
          )}
        </>
      ) : null}
    </QueryStateBoundary>
  )
}
