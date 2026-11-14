import { useEffect, useMemo, useRef } from 'react'
import { useQuery } from '@tanstack/react-query'
import { webhooksApi } from '@/api/dlq'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { WebhookDeliveryAttemptsTable } from '@/components/webhooks/WebhookDeliveryAttemptsTable'
import type { WebhookSubscription } from '@/types/api'
import { formatDateTime } from '@/i18n/format'

interface WebhookSubscriptionDetailPanelProps {
  subscription: WebhookSubscription
  isOpen: boolean
  onClose: () => void
}

function resolveSubscriptionId(subscription: WebhookSubscription): string {
  return subscription.subscription_id ?? subscription.id
}

function resolveTargetUrl(subscription: WebhookSubscription): string {
  return subscription.target_url ?? subscription.url ?? '—'
}

function resolveStatus(subscription: WebhookSubscription): 'ACTIVE' | 'PAUSED' {
  if (subscription.status === 'ACTIVE' || subscription.status === 'PAUSED') return subscription.status
  return subscription.is_active === false ? 'PAUSED' : 'ACTIVE'
}

function formatTimestamp(value?: string | null): string {
  if (!value) return '—'
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return formatDateTime(parsed)
}

export function WebhookSubscriptionDetailPanel({
  subscription,
  isOpen,
  onClose,
}: WebhookSubscriptionDetailPanelProps) {
  const closeButtonRef = useRef<HTMLButtonElement | null>(null)
  const subscriptionId = resolveSubscriptionId(subscription)
  const tenantKeys = useTenantScopedQueryKeys()

  const deliveriesQuery = useQuery({
    queryKey: tenantKeys.webhooks.deliveries(subscriptionId, 20),
    queryFn: () => webhooksApi.getDeliveries(subscriptionId, { limit: 20 }),
    enabled: isOpen,
  })

  useEffect(() => {
    if (isOpen) closeButtonRef.current?.focus()
  }, [isOpen])

  const eventTypes = useMemo(() => {
    if (!subscription.event_types || subscription.event_types.length === 0) return '—'
    return subscription.event_types.join(', ')
  }, [subscription.event_types])

  if (!isOpen) return null

  // T-1893: the record sits in the detail pane of ListDetail (owner rule 2a), no fixed overlay;
  // Escape and the narrow back button belong to ListDetail.
  return (
    <aside
      role="region"
      aria-labelledby="webhook-detail-title"
      data-testid="webhook-subscription-detail-panel"
      style={{ padding: '1.25rem' }}
    >
        <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1rem' }}>
          <div>
            <h3 id="webhook-detail-title" style={{ margin: 0 }}>Subscription details</h3>
            <p style={{ margin: '.3rem 0 0', color: 'var(--text-secondary)', fontSize: '.85rem' }}>
              Recent delivery attempts for the selected subscription.
            </p>
          </div>
          <button
            ref={closeButtonRef}
            onClick={onClose}
            style={{
              marginLeft: 'auto',
              border: '1px solid var(--color-neutral-400)',
              background: 'var(--surface-card)',
              borderRadius: '6px',
              padding: '.45rem .8rem',
              cursor: 'pointer',
            }}
          >
            Close
          </button>
        </div>

        <section
          data-testid="webhook-subscription-summary"
          style={{
            border: '1px solid var(--border-default)',
            borderRadius: '10px',
            padding: '1rem',
            marginBottom: '1rem',
            background: 'var(--surface-page)',
          }}
        >
          <dl style={{ display: 'grid', gridTemplateColumns: 'minmax(120px, 160px) 1fr', rowGap: '.65rem', columnGap: '.75rem', margin: 0 }}>
            <dt style={{ color: 'var(--color-neutral-700)', fontWeight: 600 }}>Target URL</dt>
            <dd style={{ margin: 0, fontFamily: 'monospace', wordBreak: 'break-word' }}>{resolveTargetUrl(subscription)}</dd>

            <dt style={{ color: 'var(--color-neutral-700)', fontWeight: 600 }}>Status</dt>
            <dd style={{ margin: 0, color: resolveStatus(subscription) === 'PAUSED' ? 'var(--color-warning-text)' : 'var(--color-success-dark)', fontWeight: 700 }}>
              {resolveStatus(subscription)}
            </dd>

            <dt style={{ color: 'var(--color-neutral-700)', fontWeight: 600 }}>Event types</dt>
            <dd style={{ margin: 0 }}>{eventTypes}</dd>

            <dt style={{ color: 'var(--color-neutral-700)', fontWeight: 600 }}>Created</dt>
            <dd style={{ margin: 0 }}>{formatTimestamp(subscription.created_at)}</dd>
          </dl>
        </section>

        <section>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '.75rem' }}>
            <div>
              <h4 style={{ margin: 0 }}>Recent delivery attempts</h4>
              <p style={{ margin: '.25rem 0 0', color: 'var(--text-secondary)', fontSize: '.82rem' }}>
                Status, response code, and timestamp for the latest webhook deliveries.
              </p>
            </div>
            <button
              onClick={() => void deliveriesQuery.refetch()}
              style={{
                border: '1px solid var(--color-neutral-400)',
                background: 'var(--surface-card)',
                borderRadius: '6px',
                padding: '.4rem .7rem',
                cursor: 'pointer',
                fontSize: '.82rem',
              }}
            >
              Retry
            </button>
          </div>

          {deliveriesQuery.isLoading ? (
            <div data-testid="webhook-delivery-loading" style={{ padding: '1rem', border: '1px dashed var(--color-neutral-400)', borderRadius: '8px', color: 'var(--color-neutral-700)' }}>
              Loading delivery attempts…
            </div>
          ) : null}

          {deliveriesQuery.isError ? (
            <div
              data-testid="webhook-delivery-error"
              style={{ border: '1px solid var(--color-error-border)', background: 'var(--color-error-tint)', borderRadius: '8px', padding: '1rem', color: 'var(--color-error-dark)' }}
            >
              <strong>Unable to load delivery attempts.</strong>
              <div style={{ marginTop: '.35rem', fontSize: '.85rem' }}>
                {deliveriesQuery.error instanceof Error ? deliveriesQuery.error.message : 'WebhookDeliveryLogLoadFailed'}
              </div>
            </div>
          ) : null}

          {!deliveriesQuery.isLoading && !deliveriesQuery.isError && deliveriesQuery.data && deliveriesQuery.data.items.length === 0 ? (
            <div
              data-testid="webhook-delivery-empty"
              style={{ border: '1px dashed var(--color-neutral-400)', background: 'var(--surface-page)', borderRadius: '8px', padding: '1rem', color: 'var(--color-neutral-700)' }}
            >
              No delivery attempts recorded yet.
            </div>
          ) : null}

          {!deliveriesQuery.isLoading && !deliveriesQuery.isError && deliveriesQuery.data && deliveriesQuery.data.items.length > 0 ? (
            <div style={{ overflowX: 'auto' }}>
              <WebhookDeliveryAttemptsTable attempts={deliveriesQuery.data.items} />
            </div>
          ) : null}
        </section>
    </aside>
  )
}