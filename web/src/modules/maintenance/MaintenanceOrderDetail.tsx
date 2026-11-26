/** MaintenanceOrderDetail — GH 4801 / REQ-899. The record of a work order in the detail pane of the list (skill
 *  rule 2a): the fields, the link to the request, the assignee, what was done with who and when, who closed it
 *  and when. Assign (Reassign when a person is set) belongs to a holder of MaintenanceOrderManage and shows only
 *  while the order is open or in work; the server stays the authority. */
import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/Button'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { StatusPill } from '@/components/ui/StatusPill'
import type { MaintenanceOrder } from './maintenance.api'
import { formatWhen, orderStatusMessageId, orderStatusTone, urgencyTone } from './maintenanceModel'

export interface MaintenanceOrderDetailProps {
  order: MaintenanceOrder
  /** Display name of a user id; null when the user is not in the list the screen could read. */
  nameOf: (userId: string | null) => string | null
  canManage: boolean
  onAssign: () => void
  onClose: () => void
  error?: string | null
}

export function MaintenanceOrderDetail(props: MaintenanceOrderDetailProps) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const o = props.order
  const dash = t('maintenance.common.dash')
  const who = (id: string | null) => (id == null ? dash : (props.nameOf(id) ?? t('maintenance.orders.userUnknown')))
  const when = (iso: string | null) => (iso == null ? t('maintenance.orders.notYet') : formatWhen(iso))
  const assignable = o.status === 'open' || o.status === 'in_work'
  const assignText = o.assignee_user_id == null ? t('maintenance.orders.assign') : t('maintenance.orders.reassign')

  return (
    <div data-testid="maintenance-order-detail">
      <DetailHeader
        title={o.number ?? dash}
        path={o.asset.inventory_number ?? undefined}
        status={
          <StatusPill tone={orderStatusTone(o.status)} data-testid="order-status">
            {t(orderStatusMessageId(o.status))}
          </StatusPill>
        }
        actions={
          <>
            {props.canManage && assignable && (
              <Button variant="primary" size="sm" onClick={props.onAssign} data-testid="order-assign">
                {assignText}
              </Button>
            )}
            <Button
              variant="ghost"
              size="sm"
              iconOnly
              label={t('maintenance.common.close')}
              onClick={props.onClose}
              data-testid="order-close"
            />
          </>
        }
      />
      <div className="lf-card__body">
        {props.error != null && props.error !== '' && (
          <p className="lf-error" data-testid="order-error">
            {props.error}
          </p>
        )}
        <dl className="lf-form" data-testid="order-fields">
          <div className="lf-form__row">
            <dt className="lf-label">{t('maintenance.orders.asset')}</dt>
            <dd data-testid="order-asset">
              {o.asset.inventory_number ?? dash}
              {o.asset.name != null && o.asset.name !== '' ? ` · ${o.asset.name}` : ''}
            </dd>
          </div>
          <div className="lf-form__row">
            <dt className="lf-label">{t('maintenance.requests.description')}</dt>
            <dd data-testid="order-description-text">{o.description}</dd>
          </div>
          <div className="lf-form__row">
            <dt className="lf-label">{t('maintenance.orders.urgency')}</dt>
            <dd>
              <StatusPill tone={urgencyTone(o.urgency)}>{t(`maintenance.urgency.${o.urgency}`)}</StatusPill>
            </dd>
          </div>
          <div className="lf-form__row">
            <dt className="lf-label">{t('maintenance.orders.assignee')}</dt>
            <dd data-testid="order-assignee">
              {o.assignee_user_id == null ? t('maintenance.orders.unassigned') : who(o.assignee_user_id)}
            </dd>
          </div>
          {o.request != null && (
            <div className="lf-form__row">
              <dt className="lf-label">{t('maintenance.orders.request')}</dt>
              <dd data-testid="order-request">
                <Link to={`/admin/maintenance/requests/${o.request.id}`}>{o.request.number ?? o.request.id}</Link>
              </dd>
            </div>
          )}
          <div className="lf-form__row">
            <dt className="lf-label">{t('maintenance.orders.created')}</dt>
            <dd className="lf-control--mono">{formatWhen(o.created_at)}</dd>
          </div>
          {o.work_done != null && o.work_done !== '' && (
            <div className="lf-form__row">
              <dt className="lf-label">{t('maintenance.orders.workDone')}</dt>
              <dd data-testid="order-work-done">{o.work_done}</dd>
            </div>
          )}
          {o.done_by != null && (
            <div className="lf-form__row">
              <dt className="lf-label">{t('maintenance.orders.doneBy')}</dt>
              <dd data-testid="order-done-by">
                {who(o.done_by)} · <span className="lf-control--mono">{when(o.done_at)}</span>
              </dd>
            </div>
          )}
          {o.closed_by != null && (
            <div className="lf-form__row">
              <dt className="lf-label">{t('maintenance.orders.closedBy')}</dt>
              <dd data-testid="order-closed-by">
                {who(o.closed_by)} · <span className="lf-control--mono">{when(o.closed_at)}</span>
              </dd>
            </div>
          )}
        </dl>
      </div>
    </div>
  )
}
