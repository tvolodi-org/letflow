/** MySettingsPage — T-1391 (D-100/D-101). The signed-in user's own settings; today one: the layout of the document
 *  forms. Saves through `PUT /api/v1/me/preferences`; `null` resets to the tenant default. Open to every signed-in user
 *  (the preference is the user's own). States: loading skeleton, load error with retry, saving, success toast, write error. */
import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { DOCUMENT_LAYOUT_DEFAULT_KEY, DOCUMENT_LAYOUT_KEY, preferencesApi } from '@/api/preferences'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { FetchError } from '@/components/ui/FetchError'
import { FormActions, FormSection } from '@/components/ui/FormSection'
import { PageHeader } from '@/components/ui/PageHeader'
import { Skeleton } from '@/components/ui/Skeleton'
import { DOC_LAYOUTS, type DocLayoutName } from '@/components/ui/doc/docLayouts'
import { LayoutPicker } from '@/components/ui/doc/LayoutPicker'
import { layoutFromAnswer, usePreferences } from '@/hooks/useDocumentLayout'
import { useToast } from '@/hooks/useToast'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import type { ApiError } from '@/types/api'
import { mySettingsMessages } from './mySettingsMessages'

/** The server's plain-language reason when it sent one, else the generic text. */
export function apiErrorText(err: unknown, fallback: string): string {
  const e = err as Partial<ApiError> | null
  const detail = e?.details?.['detail']
  return typeof detail === 'string' && detail ? detail : fallback
}

export default function MySettingsPage() {
  const locale = useUiLocale()
  const m = mySettingsMessages[locale]
  const toast = useToast()
  const qc = useQueryClient()
  const keys = useTenantScopedQueryKeys().me
  const prefs = usePreferences()
  const [draft, setDraft] = useState<DocLayoutName | null>(null)
  const [error, setError] = useState<string | null>(null)

  const save = useMutation({
    mutationFn: (value: DocLayoutName | null) => preferencesApi.put({ [DOCUMENT_LAYOUT_KEY]: value }),
    onSuccess: async () => {
      setError(null)
      setDraft(null)
      await qc.invalidateQueries({ queryKey: keys.preferences() })
      toast.success(m.saved)
    },
    onError: (err) => {
      // The saved value stays; the draft goes back to it.
      setDraft(null)
      setError(apiErrorText(err, m.saveError))
    },
  })

  const effective = layoutFromAnswer(prefs.data)
  const tenantDefault = layoutFromAnswer(prefs.data, DOCUMENT_LAYOUT_DEFAULT_KEY, 'tenant_defaults')
  const hasOwn = Boolean(prefs.data?.preferences && prefs.data.preferences[DOCUMENT_LAYOUT_KEY] != null)
  const value = draft ?? effective

  return (
    <>
      <PageHeader eyebrow={m.eyebrow} title={m.title} lede={m.lede} />
      <FormSection title={m.sectionTitle}>
        {prefs.isPending ? (
          <div data-testid="my-settings-loading" aria-busy="true" aria-label={m.loading}>
            <Skeleton width="60%" />
          </div>
        ) : prefs.isError ? (
          <FetchError onRetry={() => void prefs.refetch()} />
        ) : (
          <>
            {error && <Banner tone="danger">{error}</Banner>}
            <LayoutPicker
              name="my-document-layout"
              legend={m.legend}
              value={value}
              onChange={setDraft}
              disabled={save.isPending}
              data-testid="my-layout-picker"
            />
            <p className="lf-hint" data-testid="my-settings-tenant-default">
              {m.tenantDefaultIs} {DOC_LAYOUTS[tenantDefault].label[locale]}
            </p>
            <FormActions
              saving={save.isPending}
              primary={
                <Button variant="primary" loading={save.isPending} disabled={draft === null || draft === effective} onClick={() => save.mutate(draft)} data-testid="my-settings-save">
                  {m.save}
                </Button>
              }
              secondary={
                hasOwn ? (
                  <Button variant="ghost" disabled={save.isPending} onClick={() => save.mutate(null)} data-testid="my-settings-use-default">
                    {m.useDefault}
                  </Button>
                ) : undefined
              }
            />
          </>
        )}
      </FormSection>
    </>
  )
}
