/** AssetCountDetail — T-1933 / REQ-822 (K7a). One asset count order in the detail panel: the facts, the actions its status
 *  and the user's atoms allow (issue and cancel after a confirm dialog), and the edit form for a draft. K7b and K7c add
 *  their panels in `AssetCountWork`. */
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
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { classifyError } from '@/utils/classifyError'
import { formatEventTime } from '../documents/documentsModel'
import { useNames } from '../assetsNames'
import { assetCountsApi, type AssetCountOrder } from './assetCounts.api'
import { AssetCountOrderForm } from './AssetCountOrderForm'
import { AssetCountWork } from './AssetCountWork'
import { canCancel, canEdit, canIssue, reasonMessageId, statusTone } from './assetCountsModel'
import { useAssetCountsWrite } from './useAssetCountsWrite'
import { assetsQueryKeys } from '../assetsQueryKeys'

type Confirm = 'issue' | 'cancel'

function Facts({ order }: { order: AssetCountOrder }) {
  const intl = useIntl()
  const locale = useUiLocale()
  const t = (id: string) => intl.formatMessage({ id })
  const name = useNames([{
    org_unit: [order.org_unit_id],
    org_employee: [...(order.chair_employee_id ? [order.chair_employee_id] : []), ...order.member_employee_ids],
    location_node: order.location_ids,
  }])
  const dash = t('assets.common.dash')
  const time = (iso: string | null | undefined) => formatEventTime(iso, locale, dash)
  const list = (type: 'org_employee' | 'location_node', xs: string[], empty: string) => (xs.length === 0 ? empty : xs.map((x) => name(type, x)).join(', '))
  const freeze =
    order.freeze_locations !== true
      ? t('assets.count.freeze.off')
      : order.freeze_state === 'active'
        ? intl.formatMessage({ id: 'assets.count.freeze.active' }, { time: time(order.freeze_until) })
        : t(`assets.count.freeze.${order.freeze_state ?? 'none'}`)
  return (
    <dl className="lf-dl" data-testid="count-facts">
      <dt>{t('assets.count.detail.orgUnit')}</dt>
      <dd>{name('org_unit', order.org_unit_id)}</dd>
      <dt>{t('assets.count.detail.kinds')}</dt>
      <dd>{order.kinds.map((k) => t(`assets.kind.${k}`)).join(', ')}</dd>
      <dt>{t('assets.count.detail.plannedStart')}</dt>
      <dd>{time(order.planned_start)}</dd>
      <dt>{t('assets.count.detail.plannedEnd')}</dt>
      <dd>{time(order.planned_end)}</dd>
      <dt>{t('assets.count.detail.chair')}</dt>
      <dd>{name('org_employee', order.chair_employee_id) || dash}</dd>
      <dt>{t('assets.count.detail.members')}</dt>
      <dd>{list('org_employee', order.member_employee_ids, t('assets.count.detail.none'))}</dd>
      <dt>{t('assets.count.detail.locations')}</dt>
      <dd>{list('location_node', order.location_ids, t('assets.count.detail.wholeUnit'))}</dd>
      <dt>{t('assets.count.detail.freeze')}</dt>
      <dd>{freeze}</dd>
      <dt>{t('assets.count.detail.note')}</dt>
      <dd>{order.note ?? dash}</dd>
      {order.issued_at && (
        <>
          <dt>{t('assets.count.detail.issuedAt')}</dt>
          <dd>{time(order.issued_at)}</dd>
        </>
      )}
      {order.cancelled_at && (
        <>
          <dt>{t('assets.count.detail.cancelledAt')}</dt>
          <dd>{time(order.cancelled_at)}</dd>
        </>
      )}
    </dl>
  )
}

export function AssetCountDetail({ id, onClose }: { id: string; onClose: () => void }) {
  const intl = useIntl()
  const t = (mid: string) => intl.formatMessage({ id: mid })
  const toast = useToast()
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [editing, setEditing] = useState(false)
  const [confirm, setConfirm] = useState<Confirm | null>(null)

  const query = useQuery({
    queryKey: assetsQueryKeys.count(tenantId, id),
    queryFn: () => assetCountsApi.get(id),
    retry: false,
  })
  const run = useAssetCountsWrite((kind: Confirm) => assetCountsApi[kind](id))
  const order = query.data

  async function act(kind: Confirm) {
    const res = await run.submit(kind)
    if (res.ok) {
      toast.success(t(`assets.count.toast.${kind === 'issue' ? 'issued' : 'cancelled'}`))
      setConfirm(null)
    }
  }

  const closeButton = (
    <Button variant="ghost" size="sm" iconOnly label={t('assets.count.action.closePanel')} icon={<X className="lf-icon" aria-hidden="true" />} onClick={onClose} data-testid="count-detail-close" />
  )

  if (query.isError && (query.error as { status?: number } | null)?.status === 404) {
    return (
      <>
        <DetailHeader title={t('assets.count.title')} actions={closeButton} />
        <div className="lf-card__body">
          <Banner tone="info">{t('assets.count.error.notFound')}</Banner>
        </div>
      </>
    )
  }
  const state = query.isPending ? 'loading' : query.isError ? classifyError(query.error) : 'success'
  return (
    <QueryStateBoundary state={state} onRetry={() => void query.refetch()}>
      {order && editing ? (
        <AssetCountOrderForm order={order} onSaved={() => setEditing(false)} onDiscard={() => setEditing(false)} />
      ) : order ? (
        <>
          <DetailHeader
            title={order.number ?? t('assets.count.draftTitle')}
            status={<StatusPill tone={statusTone(order.status)}>{t(`assets.count.status.${order.status}`)}</StatusPill>}
            actions={
              <>
                {canEdit(order, can) && <Button variant="secondary" size="sm" onClick={() => setEditing(true)} data-testid="count-edit">{t('assets.count.action.edit')}</Button>}
                {canIssue(order, can) && <Button variant="primary" size="sm" onClick={() => setConfirm('issue')} data-testid="count-issue">{t('assets.count.action.issue')}</Button>}
                {canCancel(order, can) && <Button variant="danger" size="sm" onClick={() => setConfirm('cancel')} data-testid="count-cancel">{t('assets.count.action.cancel')}</Button>}
                {closeButton}
              </>
            }
          />
          <div className="lf-card__body">
            <Facts order={order} />
            <AssetCountWork order={order} />
          </div>
          {confirm !== null && (
            <ConfirmDialog
              open
              title={t(`assets.count.confirm.${confirm}.title`)}
              body={t(`assets.count.confirm.${confirm}.body`)}
              confirmText={t(`assets.count.confirm.${confirm}.ok`)}
              cancelText={t('assets.count.confirm.keep')}
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
