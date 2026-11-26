/** MaintenanceOrderFormPage — GH 4801 / REQ-899. The form of a new work order, two ways in. From a request
 *  (`?request=<id>`, opened by Make work order): the card, the description and the urgency of the request are shown
 *  read-only and Save sends `request_id` only. Direct: the card, the description (1 to 2000 characters) and the
 *  urgency are chosen and sent. An optional assignee comes from the active users. One POST /orders with an
 *  idempotency key, then the order page opens. The server stays the authority: a refusal is shown in words. */
import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { useAccess } from '@/auth/access'
import { useAuth } from '@/auth/AuthContext'
import { useToast } from '@/hooks/useToast'
import { ACTIVE_TRUE, DELETED_FALSE, fetchCardsPage } from '@/modules/assets/assets.api'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { FormActions, FormSection } from '@/components/ui/FormSection'
import { PageHeader } from '@/components/ui/PageHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Select } from '@/components/ui/Select'
import { classifyError } from '@/utils/classifyError'
import { MaintenanceAssigneeSelect, useAssignees } from './MaintenanceAssigneeSelect'
import { MaintenanceIntlProvider } from './MaintenanceIntlProvider'
import { maintenanceApi, URGENCIES, type CreateOrderBody, type Urgency } from './maintenance.api'
import { maintenanceQueryKeys } from './maintenanceQueryKeys'
import { MAINTENANCE_ORDER_MANAGE } from './maintenancePermissions'
import { MAX_DESCRIPTION, codePoints, errorMessageId } from './maintenanceModel'

const ASSET_CARD = 'assets_card'

function newKey(): string {
  return globalThis.crypto?.randomUUID?.() ?? `k-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

/** The form inside the module's own IntlProvider (the labels come from the module's catalog). */
export default function MaintenanceOrderFormPage() {
  return (
    <MaintenanceIntlProvider>
      <MaintenanceOrderForm />
    </MaintenanceIntlProvider>
  )
}

function MaintenanceOrderForm() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const navigate = useNavigate()
  const [search] = useSearchParams()
  const queryClient = useQueryClient()
  const toast = useToast()

  const requestId = search.get('request') ?? ''
  const fromRequest = requestId !== ''
  const canManage = can(MAINTENANCE_ORDER_MANAGE)

  const [cardId, setCardId] = useState('')
  const [description, setDescription] = useState('')
  const [urgency, setUrgency] = useState<Urgency>('normal')
  const [assignee, setAssignee] = useState('')
  const [cardError, setCardError] = useState<string | null>(null)
  const [descriptionError, setDescriptionError] = useState<string | null>(null)
  const [serverError, setServerError] = useState<string | null>(null)
  // One key per form: a second click of Save replays the same request instead of making a second order.
  const [key] = useState(newKey)

  const request = useQuery({
    queryKey: maintenanceQueryKeys.request(tenantId, requestId),
    queryFn: () => maintenanceApi.get(requestId),
    enabled: canManage && fromRequest,
    retry: false,
  })
  const cards = useQuery({
    queryKey: maintenanceQueryKeys.list(tenantId, 'cards|order'),
    queryFn: async () => (await fetchCardsPage(ASSET_CARD, [DELETED_FALSE, ACTIVE_TRUE], undefined, 200)).items,
    enabled: canManage && !fromRequest,
    retry: false,
  })
  const assignees = useAssignees()

  const cardOptions = useMemo(
    () =>
      (cards.data ?? []).map((c) => {
        const number = String(c.field_values['inventory_number'] ?? '')
        const name = String(c.field_values['name'] ?? '')
        return { value: c.record_id, label: name === '' ? number : `${number} · ${name}` }
      }),
    [cards.data],
  )

  const save = useMutation({
    mutationFn: () => {
      const body: CreateOrderBody = fromRequest
        ? { request_id: requestId }
        : { asset_card_id: cardId, description, urgency }
      if (assignee !== '') body.assignee_user_id = assignee
      return maintenanceApi.makeOrder(body, key)
    },
    onSuccess: async (created) => {
      await queryClient.invalidateQueries({ queryKey: maintenanceQueryKeys.all(tenantId) })
      toast.success(t('maintenance.orders.saved', { number: created.number ?? created.id }))
      navigate(`/admin/maintenance/orders/${created.id}`)
    },
    onError: (err) => setServerError(t(errorMessageId(err))),
  })

  const submit = () => {
    setServerError(null)
    if (!fromRequest) {
      if (cardId === '') {
        setCardError(t('maintenance.error.asset_card_not_found'))
        return
      }
      if (description.trim() === '') {
        setDescriptionError(t('maintenance.error.description_required'))
        return
      }
      if (codePoints(description) > MAX_DESCRIPTION) {
        setDescriptionError(t('maintenance.error.description_too_long', { max: MAX_DESCRIPTION }))
        return
      }
    }
    setCardError(null)
    setDescriptionError(null)
    save.mutate()
  }

  const source = request.data
  const sourceError = request.isError ? classifyError(request.error) : cards.isError ? classifyError(cards.error) : 'success'
  const assetLabel =
    source != null
      ? `${source.asset.inventory_number ?? ''}${source.asset.name != null && source.asset.name !== '' ? ` · ${source.asset.name}` : ''}`
      : ''

  return (
    <>
      <PageHeader
        eyebrow={t('maintenance.common.eyebrow')}
        title={t('maintenance.orders.newTitle')}
        lede={t('maintenance.orders.newLede')}
      />
      <QueryStateBoundary
        state={sourceError}
        onRetry={() => void (fromRequest ? request.refetch() : cards.refetch())}
      >
        <form
          className="lf-form"
          aria-label={t('maintenance.orders.newTitle')}
          onSubmit={(e) => {
            e.preventDefault()
            submit()
          }}
        >
          <FormSection
            title={
              fromRequest
                ? t('maintenance.orders.fromRequest', { number: source?.number ?? '' })
                : t('maintenance.orders.direct')
            }
          >
            {serverError != null && (
              <p className="lf-error" data-testid="order-form-error">
                {serverError}
              </p>
            )}
            {fromRequest ? (
              <>
                <Field label={t('maintenance.orders.requestCard')} readOnly data-testid="order-card-readonly">
                  <input name="asset_card_id" value={assetLabel} readOnly />
                </Field>
                <Field label={t('maintenance.orders.requestDescription')} readOnly data-testid="order-description-readonly">
                  <textarea name="description" rows={4} value={source?.description ?? ''} readOnly />
                </Field>
                <Field label={t('maintenance.orders.requestUrgency')} readOnly data-testid="order-urgency-readonly">
                  <input name="urgency" value={source != null ? t(`maintenance.urgency.${source.urgency}`) : ''} readOnly />
                </Field>
              </>
            ) : (
              <>
                <Select
                  name="asset_card_id"
                  label={t('maintenance.requests.card')}
                  width="l"
                  value={cardId}
                  options={cardOptions}
                  placeholder={t('maintenance.requests.cardPlaceholder')}
                  error={cardError ?? undefined}
                  onChange={(v) => {
                    setCardId(v)
                    setCardError(null)
                  }}
                />
                <Field
                  label={t('maintenance.requests.description')}
                  hint={t('maintenance.requests.descriptionHint', { max: MAX_DESCRIPTION })}
                  error={descriptionError ?? undefined}
                  data-testid="order-description-field"
                >
                  <textarea
                    name="description"
                    rows={5}
                    value={description}
                    onChange={(e) => {
                      setDescription(e.target.value)
                      if (descriptionError != null) setDescriptionError(null)
                    }}
                    data-testid="order-description"
                  />
                </Field>
                <Select
                  name="urgency"
                  label={t('maintenance.requests.urgency')}
                  width="s"
                  value={urgency}
                  options={URGENCIES.map((u) => ({ value: u, label: t(`maintenance.urgency.${u}`) }))}
                  onChange={(v) => setUrgency(v as Urgency)}
                />
              </>
            )}
            <MaintenanceAssigneeSelect
              value={assignee}
              onChange={setAssignee}
              users={assignees.users}
              isError={assignees.isError}
            />
          </FormSection>
          <FormActions
            dirty={assignee !== '' || description !== ''}
            saving={save.isPending}
            primary={
              <Button
                variant="primary"
                size="md"
                type="submit"
                disabled={save.isPending || (fromRequest && source == null)}
                data-testid="order-save"
              >
                {t('maintenance.common.save')}
              </Button>
            }
            secondary={
              <Button
                variant="ghost"
                size="md"
                onClick={() => navigate(fromRequest ? '/admin/maintenance/requests' : '/admin/maintenance/orders')}
                data-testid="order-cancel"
              >
                {t('maintenance.common.cancel')}
              </Button>
            }
          />
        </form>
      </QueryStateBoundary>
    </>
  )
}
