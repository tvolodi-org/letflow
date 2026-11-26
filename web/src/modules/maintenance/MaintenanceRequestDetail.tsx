/** MaintenanceRequestDetail — GH 4802 / REQ-898. The record of the maintenance work request in the detail pane
 *  of the list screen (skill rule 2a: one record is read in the panel, never in a modal): the fields of the
 *  request, the photos as thumbnails that open the original, the work order link when the request is ordered and
 *  the reason when it was rejected. The actions (Reject, Make work order) belong to a holder of
 *  MaintenanceOrderManage and are shown only while the request is new; the server stays the authority. */
import { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/Button'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { StatusPill } from '@/components/ui/StatusPill'
import { MaintenancePhotoImage } from './MaintenancePhotoImage'
import type { MaintenancePhoto, MaintenanceRequest } from './maintenance.api'
import { formatWhen, statusTone, urgencyTone } from './maintenanceModel'

export interface MaintenanceRequestDetailProps {
  request: MaintenanceRequest
  photos: MaintenancePhoto[]
  /** The user holds MaintenanceOrderManage. */
  canManage: boolean
  onReject: () => void
  onMakeOrder: () => void
  onClose: () => void
  /** The reason of the last refused write, shown in the panel. */
  error?: string | null
}

export function MaintenanceRequestDetail(props: MaintenanceRequestDetailProps) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const r = props.request
  const dash = t('maintenance.common.dash')
  const isNew = r.status === 'new'
  const asset = r.asset
  const [currentId, setCurrentId] = useState<string | null>(null)

  // The opened photo belongs to the shown request: another request opens its own first photo.
  useEffect(() => {
    setCurrentId(null)
  }, [r.id])

  const current = props.photos.find((p) => p.id === currentId) ?? null

  return (
    <div data-testid="maintenance-request-detail">
      <DetailHeader
        title={r.number ?? dash}
        path={asset.inventory_number ?? undefined}
        status={
          <StatusPill tone={statusTone(r.status)} data-testid="request-status">
            {t(`maintenance.status.${r.status}`)}
          </StatusPill>
        }
        actions={
          <>
            {props.canManage && isNew && (
              <>
                <Button variant="secondary" size="sm" onClick={props.onReject} data-testid="request-reject">
                  {t('maintenance.requests.reject')}
                </Button>
                <Button variant="primary" size="sm" onClick={props.onMakeOrder} data-testid="request-make-order">
                  {t('maintenance.requests.makeOrder')}
                </Button>
              </>
            )}
            <Button
              variant="ghost"
              size="sm"
              iconOnly
              label={t('maintenance.common.close')}
              onClick={props.onClose}
              data-testid="request-close"
            />
          </>
        }
      />
      <div className="lf-card__body">
        {props.error != null && props.error !== '' && (
          <p className="lf-error" data-testid="request-error">
            {props.error}
          </p>
        )}
        <dl className="lf-form" data-testid="request-fields">
          <div className="lf-form__row">
            <dt className="lf-label">{t('maintenance.requests.asset')}</dt>
            <dd data-testid="request-asset">
              {asset.inventory_number ?? dash}
              {asset.name != null && asset.name !== '' ? ` · ${asset.name}` : ''}
            </dd>
          </div>
          <div className="lf-form__row">
            <dt className="lf-label">{t('maintenance.requests.description')}</dt>
            <dd data-testid="request-description">{r.description}</dd>
          </div>
          <div className="lf-form__row">
            <dt className="lf-label">{t('maintenance.requests.urgency')}</dt>
            <dd data-testid="request-urgency">
              <StatusPill tone={urgencyTone(r.urgency)}>{t(`maintenance.urgency.${r.urgency}`)}</StatusPill>
            </dd>
          </div>
          <div className="lf-form__row">
            <dt className="lf-label">{t('maintenance.requests.created')}</dt>
            <dd className="lf-control--mono" data-testid="request-created">
              {t('maintenance.requests.createdAt', { date: formatWhen(r.created_at) })}
            </dd>
          </div>
          {r.status === 'rejected' && r.reject_reason != null && r.reject_reason !== '' && (
            <div className="lf-form__row">
              <dt className="lf-label">{t('maintenance.requests.rejectReason')}</dt>
              <dd data-testid="request-reject-reason">{r.reject_reason}</dd>
            </div>
          )}
          {r.order != null && (
            <div className="lf-form__row">
              <dt className="lf-label">{t('maintenance.requests.order')}</dt>
              <dd data-testid="request-order">
                <Link to={`/admin/maintenance/orders/${r.order.id}`}>{r.order.number ?? r.order.id}</Link>
              </dd>
            </div>
          )}
        </dl>
        <div data-testid="request-photos">
          <h3 className="lf-label">{t('maintenance.requests.photos')}</h3>
          {props.photos.length === 0 ? (
            <p className="lf-faint" data-testid="request-photos-empty">
              {t('maintenance.requests.photosNone')}
            </p>
          ) : (
            <>
              <ul className="lf-photo-grid" aria-label={t('maintenance.requests.photos')}>
                {props.photos.map((p, i) => (
                  <li key={p.id} className="lf-photo__item" data-testid="request-photo">
                    <button
                      type="button"
                      className="lf-photo-tile"
                      aria-pressed={current?.id === p.id}
                      aria-label={t('maintenance.requests.photoAlt', { position: i + 1 })}
                      onClick={() => setCurrentId(p.id)}
                      data-testid={`photo-tile-${p.id}`}
                    >
                      {p.has_thumbnail ? (
                        <MaintenancePhotoImage
                          requestId={r.id}
                          photoId={p.id}
                          kind="thumbnail"
                          alt=""
                          className="lf-photo-tile__img"
                        />
                      ) : (
                        <span className="lf-photo-tile__img lf-photo__ph" aria-hidden="true" />
                      )}
                    </button>
                  </li>
                ))}
              </ul>
              {current ? (
                <div className="lf-photo-view" data-testid="photo-view">
                  <MaintenancePhotoImage
                    key={current.id}
                    requestId={r.id}
                    photoId={current.id}
                    kind="original"
                    alt={t('maintenance.requests.photoAlt', { position: props.photos.indexOf(current) + 1 })}
                    className="lf-photo-view__img"
                  />
                </div>
              ) : null}
            </>
          )}
        </div>
      </div>
    </div>
  )
}
