/** TenantLayoutDefault — T-1391 (D-100/D-101). The tenant administrator's default layout of the document forms, saved
 *  through `PATCH /api/v1/tenant/settings` (key `ui.document_layout_default`). The caller (AppearanceSettingsPage) shows
 *  it only to holders of `TenantSettingsManage`; the server enforces the permission again. */
import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { DOCUMENT_LAYOUT_DEFAULT_KEY } from '@/api/preferences'
import { tenantSettingsApi } from '@/api/tenantSettings'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { FetchError } from '@/components/ui/FetchError'
import { FormActions, FormSection } from '@/components/ui/FormSection'
import { Skeleton } from '@/components/ui/Skeleton'
import type { DocLayoutName } from '@/components/ui/doc/docLayouts'
import { LayoutPicker } from '@/components/ui/doc/LayoutPicker'
import { layoutFromAnswer, usePreferences } from '@/hooks/useDocumentLayout'
import { useToast } from '@/hooks/useToast'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { apiErrorText } from '@/pages/me/MySettingsPage'
import { mySettingsMessages } from '@/pages/me/mySettingsMessages'

export function TenantLayoutDefault() {
  const m = mySettingsMessages[useUiLocale()]
  const toast = useToast()
  const qc = useQueryClient()
  const keys = useTenantScopedQueryKeys().me
  const prefs = usePreferences()
  const [draft, setDraft] = useState<DocLayoutName | null>(null)
  const [error, setError] = useState<string | null>(null)

  const save = useMutation({
    mutationFn: (layout: DocLayoutName) => tenantSettingsApi.patchDocumentLayoutDefault(layout),
    onSuccess: async () => {
      setError(null)
      setDraft(null)
      await qc.invalidateQueries({ queryKey: keys.preferences() })
      toast.success(m.tenantSaved)
    },
    onError: (err) => {
      setDraft(null)
      setError(apiErrorText(err, m.saveError))
    },
  })

  const current = layoutFromAnswer(prefs.data, DOCUMENT_LAYOUT_DEFAULT_KEY, 'tenant_defaults')
  const value = draft ?? current

  return (
    <div data-testid="tenant-layout-default">
      <FormSection title={m.tenantSectionTitle}>
        {prefs.isPending ? (
          <div aria-busy="true" aria-label={m.loading}>
            <Skeleton width="60%" />
          </div>
        ) : prefs.isError ? (
          <FetchError onRetry={() => void prefs.refetch()} />
        ) : (
          <>
            <p className="lf-hint">{m.tenantLede}</p>
            {error && <Banner tone="danger">{error}</Banner>}
            <LayoutPicker name="tenant-document-layout" legend={m.tenantLegend} value={value} onChange={setDraft} disabled={save.isPending} />
            <FormActions
              saving={save.isPending}
              primary={
                <Button variant="primary" loading={save.isPending} disabled={draft === null || draft === current} onClick={() => draft && save.mutate(draft)} data-testid="tenant-layout-save">
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
