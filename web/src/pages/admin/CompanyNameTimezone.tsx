/** CompanyNameTimezone — T-2403. Sets the tenant's company name (`app_name`, 1-100 characters) and time zone (IANA
 *  name) through `PATCH /api/v1/tenant/settings`; reads the effective values with `GET`. Shown by
 *  AppearanceSettingsPage to holders of `TenantSettingsManage`; the server enforces the permission and validates
 *  the values again, and its message is shown next to the form. */
import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { tenantSettingsApi } from '@/api/tenantSettings'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { FetchError } from '@/components/ui/FetchError'
import { FormActions, FormSection } from '@/components/ui/FormSection'
import { Select } from '@/components/ui/Select'
import { Skeleton } from '@/components/ui/Skeleton'
import { useTenantSettings } from '@/hooks/useTenantSettings'
import { useToast } from '@/hooks/useToast'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { apiErrorText } from '@/pages/me/MySettingsPage'
import { companySettingsMessages } from './companySettingsMessages'

const NAME_MAX = 100

function zoneNames(current: string): string[] {
  const all = typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : []
  return all.includes(current) ? all : [current, ...all]
}

export function CompanyNameTimezone() {
  const m = companySettingsMessages[useUiLocale()]
  const toast = useToast()
  const qc = useQueryClient()
  const keys = useTenantScopedQueryKeys().me
  const settings = useTenantSettings()
  const [name, setName] = useState<string | null>(null)
  const [zone, setZone] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const save = useMutation({
    mutationFn: (body: { app_name: string; timezone: string }) => tenantSettingsApi.patchCompany(body),
    onSuccess: async () => {
      setError(null)
      setName(null)
      setZone(null)
      await qc.invalidateQueries({ queryKey: keys.tenantSettings() })
      toast.success(m.saved)
    },
    onError: (err) => setError(apiErrorText(err, m.saveError)),
  })

  const currentName = settings.data?.app_name ?? ''
  const currentZone = settings.data?.timezone ?? ''
  const nameValue = name ?? currentName
  const zoneValue = zone ?? currentZone
  const trimmed = nameValue.trim()
  const nameInvalid = name !== null && (trimmed.length < 1 || trimmed.length > NAME_MAX)
  const dirty = (name !== null && trimmed !== currentName) || (zone !== null && zone !== currentZone)
  const canSave = dirty && trimmed.length >= 1 && trimmed.length <= NAME_MAX

  return (
    <div data-testid="company-name-timezone">
      <FormSection title={m.sectionTitle}>
        {settings.isPending ? (
          <div aria-busy="true" aria-label={m.loading}>
            <Skeleton width="60%" />
          </div>
        ) : settings.isError ? (
          <FetchError onRetry={() => void settings.refetch()} />
        ) : (
          <>
            <p className="lf-hint">{m.lede}</p>
            {error && <Banner tone="danger">{error}</Banner>}
            <Field label={m.nameLabel} error={nameInvalid ? m.nameError : undefined} width="l">
              <input
                type="text"
                value={nameValue}
                maxLength={NAME_MAX + 20}
                data-testid="company-name-input"
                onChange={(e) => setName(e.target.value)}
              />
            </Field>
            <Select
              label={m.zoneLabel}
              width="l"
              value={zoneValue}
              onChange={setZone}
              options={zoneNames(currentZone).map((z) => ({ value: z, label: z }))}
              data-testid="company-timezone-select"
            />
            <FormActions
              saving={save.isPending}
              primary={
                <Button
                  variant="primary"
                  loading={save.isPending}
                  disabled={!canSave}
                  onClick={() => save.mutate({ app_name: trimmed, timezone: zoneValue })}
                  data-testid="company-settings-save"
                >
                  {m.save}
                </Button>
              }
            />
          </>
        )}
      </FormSection>
    </div>
  )
}
