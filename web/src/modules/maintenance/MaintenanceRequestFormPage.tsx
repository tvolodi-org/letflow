/** MaintenanceRequestFormPage — GH 4802 / REQ-898. The form of a new maintenance work request: the equipment (set
 *  from the card action or chosen), the description (required, at most 2000 characters, counted), the urgency
 *  (normal preselected) and up to five photos. Save creates the request with an idempotency key and then uploads
 *  every photo; a refused photo is named with the server's reason, the created request stays and the screen opens
 *  it. The server stays the authority: a refusal of the request is shown in words, not as a code. */
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
import { MaintenanceIntlProvider } from './MaintenanceIntlProvider'
import { maintenanceApi, URGENCIES, type Urgency } from './maintenance.api'
import { maintenanceQueryKeys } from './maintenanceQueryKeys'
import { MAINTENANCE_REQUEST_CREATE } from './maintenancePermissions'
import { MAX_DESCRIPTION, MAX_PHOTOS, codePoints, errorMessageId, photoErrorId } from './maintenanceModel'

const ASSET_CARD = 'assets_card'

interface StagedPhoto {
  key: string
  name: string
  blob: Blob
}

function newKey(): string {
  return globalThis.crypto?.randomUUID?.() ?? `k-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

/** The form inside the module's own IntlProvider (the labels come from the module's catalog). */
export default function MaintenanceRequestFormPage() {
  return (
    <MaintenanceIntlProvider>
      <MaintenanceRequestForm />
    </MaintenanceIntlProvider>
  )
}

function MaintenanceRequestForm() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const navigate = useNavigate()
  const [search] = useSearchParams()
  const queryClient = useQueryClient()
  const toast = useToast()

  const presetCard = search.get('card') ?? ''
  const [cardId, setCardId] = useState(presetCard)
  const [description, setDescription] = useState('')
  const [urgency, setUrgency] = useState<Urgency>('normal')
  const [photos, setPhotos] = useState<StagedPhoto[]>([])
  const [descriptionError, setDescriptionError] = useState<string | null>(null)
  const [cardError, setCardError] = useState<string | null>(null)
  const [serverError, setServerError] = useState<string | null>(null)

  const canCreate = can(MAINTENANCE_REQUEST_CREATE)

  const cards = useQuery({
    queryKey: maintenanceQueryKeys.list(tenantId, `cards|${presetCard}`),
    queryFn: async () => {
      const page = await fetchCardsPage(ASSET_CARD, [DELETED_FALSE, ACTIVE_TRUE], undefined, 200)
      return page.items
    },
    enabled: canCreate,
    retry: false,
  })

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
    mutationFn: async () => {
      const key = newKey()
      const created = await maintenanceApi.create({ asset_card_id: cardId, description, urgency }, key)
      const refused: { name: string; reason: string }[] = []
      for (const photo of photos) {
        try {
          await maintenanceApi.uploadPhoto(created.id, photo.blob)
        } catch (err) {
          refused.push({ name: photo.name, reason: t(photoErrorId(err)) })
        }
      }
      return { created, refused }
    },
    onSuccess: async ({ created, refused }) => {
      await queryClient.invalidateQueries({ queryKey: maintenanceQueryKeys.all(tenantId) })
      toast.success(t('maintenance.requests.saved', { number: created.number ?? created.id }))
      navigate(`/admin/maintenance/requests/${created.id}`, {
        state: { photoErrors: refused },
      })
    },
    onError: (err) => setServerError(t(errorMessageId(err))),
  })

  const submit = () => {
    setServerError(null)
    const length = codePoints(description)
    if (cardId === '') {
      setCardError(t('maintenance.error.asset_card_not_found'))
      return
    }
    if (description.trim() === '') {
      setDescriptionError(t('maintenance.error.description_required'))
      return
    }
    if (length > MAX_DESCRIPTION) {
      setDescriptionError(t('maintenance.error.description_too_long', { max: MAX_DESCRIPTION }))
      return
    }
    setCardError(null)
    setDescriptionError(null)
    save.mutate()
  }

  const addPhotos = (files: FileList | null) => {
    if (files == null) return
    const next = [...photos]
    for (const file of Array.from(files)) {
      if (next.length >= MAX_PHOTOS) break
      next.push({ key: `${file.name}-${next.length}-${file.size}`, name: file.name, blob: file })
    }
    setPhotos(next)
  }

  const chosen = cardOptions.find((o) => o.value === cardId)

  return (
    <>
      <PageHeader
        eyebrow={t('maintenance.common.eyebrow')}
        title={t('maintenance.requests.newTitle')}
        lede={t('maintenance.requests.newLede')}
      />
      <QueryStateBoundary
        state={cards.isError ? classifyError(cards.error) : 'success'}
        onRetry={() => void cards.refetch()}
      >
        <form
            className="lf-form"
            aria-label={t('maintenance.requests.newTitle')}
          onSubmit={(e) => {
            e.preventDefault()
            submit()
          }}
        >
          <FormSection title={t('maintenance.requests.newTitle')}>
            {serverError != null && (
              <p className="lf-error" data-testid="request-form-error">
                {serverError}
              </p>
            )}
            {presetCard !== '' ? (
              <Field label={t('maintenance.requests.card')} readOnly data-testid="request-card-readonly">
                <input name="asset_card_id" value={chosen?.label ?? presetCard} readOnly />
              </Field>
            ) : (
              <Select
                name="asset_card_id"
                label={t('maintenance.requests.card')}
                width="l"
                value={cardId}
                options={cardOptions}
                placeholder={t('maintenance.requests.cardPlaceholder')}
                onChange={(v) => {
                  setCardId(v)
                  setCardError(null)
                }}
              />
            )}
            {cardError != null && (
              <p className="lf-error" data-testid="request-card-error">
                {cardError}
              </p>
            )}
            <Field
              label={t('maintenance.requests.description')}
              hint={t('maintenance.requests.descriptionHint', { max: MAX_DESCRIPTION })}
              error={descriptionError ?? undefined}
              data-testid="request-description-field"
            >
              <textarea
                name="description"
                rows={5}
                value={description}
                onChange={(e) => {
                  setDescription(e.target.value)
                  if (descriptionError != null) setDescriptionError(null)
                }}
                data-testid="request-description"
              />
            </Field>
            <p className="caption lf-faint" data-testid="request-description-count">
              {t('maintenance.requests.descriptionCount', { count: codePoints(description), max: MAX_DESCRIPTION })}
            </p>
            <Select
              name="urgency"
              label={t('maintenance.requests.urgency')}
              width="s"
              value={urgency}
              options={URGENCIES.map((u) => ({ value: u, label: t(`maintenance.urgency.${u}`) }))}
              onChange={(v) => setUrgency(v as Urgency)}
            />
            <Field
              label={t('maintenance.requests.photos')}
              hint={t('maintenance.requests.photosHint', { max: MAX_PHOTOS })}
              optional
              data-testid="request-photos-field"
            >
              <input
                type="file"
                accept="image/*"
                multiple
                onChange={(e) => addPhotos(e.target.files)}
                data-testid="request-photos-input"
              />
            </Field>
            {photos.length > 0 && (
              <ul className="lf-form__list" data-testid="request-photos-list">
                {photos.map((p) => (
                  <li key={p.key} data-testid={`request-photo-${p.name}`}>
                    <span>{p.name}</span>
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => setPhotos((all) => all.filter((x) => x.key !== p.key))}
                      data-testid={`request-photo-remove-${p.name}`}
                    >
                      {t('maintenance.requests.photosRemove')}
                    </Button>
                  </li>
                ))}
              </ul>
            )}
          </FormSection>
          <FormActions
            dirty={description !== '' || photos.length > 0}
            saving={save.isPending}
            primary={
              <Button variant="primary" size="md" type="submit" disabled={save.isPending} data-testid="request-save">
                {t('maintenance.common.save')}
              </Button>
            }
            secondary={
              <Button
                variant="ghost"
                size="md"
                onClick={() => navigate('/admin/maintenance/requests')}
                data-testid="request-cancel"
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
