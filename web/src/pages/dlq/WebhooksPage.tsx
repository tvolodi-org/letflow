import { useEffect, useMemo, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useSearchParams } from 'react-router-dom'
import { webhooksApi } from '@/api/dlq'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { WebhookSubscriptionDetailPanel } from '@/components/webhooks/WebhookSubscriptionDetailPanel'
import type { WebhookSubscription } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { formatDateTime } from '@/i18n/format'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { ListDetail } from '@/components/ui/listDetail'

type CreateFormState = {
  targetUrl: string
  secret: string
  eventTypes: string[]
}

const EVENT_OPTIONS: Array<{ value: string; label: string }> = [
  { value: 'task.completed', label: 'Task completed' },
  { value: 'instance.started', label: 'Instance started' },
  { value: 'instance.completed', label: 'Instance completed' },
  { value: 'instance.errored', label: 'Instance errored' },
]

function resolveSubscriptionId(item: WebhookSubscription): string {
  return item.subscription_id ?? item.id
}

function resolveTargetUrl(item: WebhookSubscription): string {
  return item.target_url ?? item.url ?? ''
}

function resolveStatus(item: WebhookSubscription): 'ACTIVE' | 'PAUSED' {
  if (item.status === 'ACTIVE' || item.status === 'PAUSED') return item.status
  return item.is_active === false ? 'PAUSED' : 'ACTIVE'
}

function isValidHttpUrl(value: string): boolean {
  try {
    const url = new URL(value)
    return url.protocol === 'http:' || url.protocol === 'https:'
  } catch {
    return false
  }
}

export default function WebhooksPage() {
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const [searchParams, setSearchParams] = useSearchParams()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState<CreateFormState>({ targetUrl: '', secret: '', eventTypes: [] })
  const [formError, setFormError] = useState<string | null>(null)
  const [oneTimeSecret, setOneTimeSecret] = useState<string | null>(null)

  const { data, isLoading, isError, error, refetch } = useQuery({
    queryKey: tenantKeys.webhooks.list(),
    queryFn: () => webhooksApi.list(),
  })

  const subscriptions = useMemo(() => data?.items ?? [], [data])
  const selectedSubscriptionId = searchParams.get('subscription')
  const selectedSubscription = useMemo(
    () => subscriptions.find((item) => resolveSubscriptionId(item) === selectedSubscriptionId) ?? null,
    [selectedSubscriptionId, subscriptions],
  )

  useEffect(() => {
    if (!selectedSubscriptionId || isLoading) return
    if (selectedSubscription) return

    const nextParams = new URLSearchParams(searchParams)
    nextParams.delete('subscription')
    setSearchParams(nextParams, { replace: true })
  }, [isLoading, searchParams, selectedSubscription, selectedSubscriptionId, setSearchParams])

  const createWebhook = useMutation({
    mutationFn: () => webhooksApi.create({
      target_url: form.targetUrl,
      secret: form.secret.trim() ? form.secret : null,
      event_types: form.eventTypes,
    }),
    onSuccess: (created) => {
      qc.invalidateQueries({ queryKey: tenantKeys.webhooks.list() })
      setCreating(false)
      setForm({ targetUrl: '', secret: '', eventTypes: [] })
      setFormError(null)
      setOneTimeSecret(created.hmac_secret_once ?? null)
    },
  })

  const updateWebhook = useMutation({
    mutationFn: ({ id, nextStatus }: { id: string; nextStatus: 'ACTIVE' | 'PAUSED' }) =>
      webhooksApi.update(id, { status: nextStatus, is_active: nextStatus === 'ACTIVE' }),
    onSuccess: () => qc.invalidateQueries({ queryKey: tenantKeys.webhooks.list() }),
  })

  const deleteWebhook = useMutation({
    mutationFn: (id: string) => webhooksApi.delete(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: tenantKeys.webhooks.list() }),
  })

  const handleToggleEventType = (eventType: string): void => {
    setForm((previous) => {
      if (previous.eventTypes.includes(eventType)) {
        return {
          ...previous,
          eventTypes: previous.eventTypes.filter((value) => value !== eventType),
        }
      }
      return {
        ...previous,
        eventTypes: [...previous.eventTypes, eventType],
      }
    })
  }

  const handleCreate = (): void => {
    if (!form.targetUrl.trim() || form.eventTypes.length === 0) {
      setFormError('Target URL and at least one event type are required.')
      return
    }

    if (!isValidHttpUrl(form.targetUrl.trim())) {
      setFormError('Target URL is invalid.')
      return
    }

    setFormError(null)
    createWebhook.mutate()
  }

  const handleCopyAndDismiss = async (): Promise<void> => {
    if (oneTimeSecret) {
      try {
        await navigator.clipboard.writeText(oneTimeSecret)
      } catch {
        // Clipboard write can fail in restricted contexts; dismiss still proceeds.
      }
    }
    setOneTimeSecret(null)
  }

  const openDetails = (subscriptionId: string): void => {
    const params = new URLSearchParams(searchParams)
    params.set('subscription', subscriptionId)
    setSearchParams(params)
  }

  const closeDetails = (): void => {
    const params = new URLSearchParams(searchParams)
    params.delete('subscription')
    setSearchParams(params)
  }

  const columns: DataTableColumn<WebhookSubscription>[] = [
    {
      id: 'target_url',
      header: 'Target URL',
      accessor: (w) => (
        <span style={{ fontFamily: 'monospace', fontSize: '.8rem', maxWidth: '320px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', display: 'block' }}>
          {resolveTargetUrl(w) || '—'}
        </span>
      ),
    },
    {
      id: 'event_types',
      header: 'Event types',
      accessor: (w) => w.event_types?.join(', ') ?? '—',
    },
    {
      id: 'status',
      header: 'Status',
      accessor: (w) => <StatusBadge status={resolveStatus(w)} domain="dlq" />,
    },
    {
      id: 'created_at',
      header: 'Created',
      sortable: true,
      sortValue: (w) => w.created_at,
      accessor: (w) => formatDateTime(w.created_at),
    },
    {
      id: 'actions',
      header: 'Actions',
      accessor: (w) => {
        const id = resolveSubscriptionId(w)
        const status = resolveStatus(w)
        const isPaused = status === 'PAUSED'
        const nextStatus: 'ACTIVE' | 'PAUSED' = isPaused ? 'ACTIVE' : 'PAUSED'
        return (
          <div style={{ display: 'flex', gap: '.4rem' }}>
            <Button variant="secondary" size="sm" data-testid={`webhook-view-${id}`} onClick={() => openDetails(id)}>
              View details
            </Button>
            <Button variant="secondary" size="sm" onClick={() => updateWebhook.mutate({ id, nextStatus })}>
              {isPaused ? 'Resume' : 'Pause'}
            </Button>
            <Button variant="danger" size="sm" onClick={() => deleteWebhook.mutate(id)} loading={deleteWebhook.isPending}>
              Delete
            </Button>
          </div>
        )
      },
    },
  ]

  return (
    <PageLayout
      title="Webhook Subscriptions"
      actions={
        <Button variant="primary" size="sm" onClick={() => setCreating(true)}>
          + New Subscription
        </Button>
      }
    >
      {oneTimeSecret && (
        <div
          data-testid="webhook-secret-once-panel"
          style={{
            background: 'var(--color-info-light)',
            border: '1px solid var(--color-info)',
            borderRadius: '6px',
            padding: '1rem',
            marginBottom: '1.25rem',
          }}
        >
          <h3 style={{ margin: '0 0 .5rem' }}>One-time HMAC secret</h3>
          <p style={{ margin: '0 0 .5rem', color: 'var(--color-info-text)', fontSize: '.85rem' }}>
            Copy this value now. It is shown only once after subscription creation.
          </p>
          <code style={{ display: 'block', background: 'var(--color-info-tint)', padding: '.45rem .6rem', borderRadius: '4px', marginBottom: '.75rem' }}>
            {oneTimeSecret}
          </code>
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <Button variant="primary" size="sm" onClick={() => { void handleCopyAndDismiss() }}>
              Copy and dismiss
            </Button>
            <Button variant="ghost" size="sm" onClick={() => setOneTimeSecret(null)}>
              Dismiss
            </Button>
          </div>
        </div>
      )}

      {creating && (
        <div style={{ background: 'var(--surface-page)', border: '1px solid var(--border-default)', borderRadius: '6px', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create subscription</h3>

          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Target URL</label>
            <input
              value={form.targetUrl}
              onChange={(e) => setForm((previous) => ({ ...previous, targetUrl: e.target.value }))}
              placeholder="https://example.com/webhooks/bpm"
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
            />
          </div>

          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>HMAC secret (optional)</label>
            <input
              value={form.secret}
              onChange={(e) => setForm((previous) => ({ ...previous, secret: e.target.value }))}
              placeholder="Leave empty to auto-generate"
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
            />
          </div>

          <fieldset style={{ margin: '0 0 .75rem', border: '1px solid var(--border-default)', borderRadius: '4px', padding: '.65rem .75rem' }}>
            <legend style={{ fontSize: '.85rem', fontWeight: 600, padding: '0 .25rem' }}>Event types</legend>
            <div style={{ display: 'grid', gap: '.4rem' }}>
              {EVENT_OPTIONS.map((eventOption) => (
                <label key={eventOption.value} style={{ display: 'flex', alignItems: 'center', gap: '.5rem', fontSize: '.85rem' }}>
                  <input
                    type="checkbox"
                    checked={form.eventTypes.includes(eventOption.value)}
                    onChange={() => handleToggleEventType(eventOption.value)}
                  />
                  {eventOption.label}
                </label>
              ))}
            </div>
          </fieldset>

          {formError && (
            <p style={{ margin: '0 0 .75rem', color: 'var(--color-error-dark)', fontSize: '.85rem', fontWeight: 600 }}>
              {formError}
            </p>
          )}

          <div style={{ display: 'flex', gap: '.5rem' }}>
            <Button variant="primary" size="sm" onClick={handleCreate} loading={createWebhook.isPending}>Save</Button>
            <Button variant="secondary" size="sm" onClick={() => setCreating(false)}>Cancel</Button>
          </div>
        </div>
      )}

      <ListDetail
        screen="dlq.webhooks"
        listLabel="Webhook subscriptions"
        listDefault={60}
        listMin={320}
        list={
          <QueryStateBoundary
            state={(isLoading ? 'loading' : isError ? classifyError(error) : 'success') as RendererState}
            onRetry={() => { void refetch() }}
            columns={[{ widthPercent: 35 }, { widthPercent: 25 }, { widthPercent: 10 }, { widthPercent: 15 }, { widthPercent: 15 }]}
          >
            <DataTable<WebhookSubscription>
              columns={columns}
              data={subscriptions}
              emptyMessage="No webhook subscriptions."
            />
          </QueryStateBoundary>
        }
        detailOpen={selectedSubscription != null}
        onClose={closeDetails}
        detail={selectedSubscription ? (
          <WebhookSubscriptionDetailPanel
            subscription={selectedSubscription}
            isOpen={true}
            onClose={closeDetails}
          />
        ) : null}
      />
    </PageLayout>
  )
}
