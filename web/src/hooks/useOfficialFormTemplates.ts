/** T-1983 — query hooks of the Official forms screen. Mutations refetch the one list on settle (a 409 means stale). */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { officialFormTemplatesApi, type TemplateAction, type TemplateLocale } from '@/api/officialFormTemplates'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export function useOfficialFormTemplatesList() {
  const keys = useTenantScopedQueryKeys()
  return useQuery({
    queryKey: keys.officialFormTemplates.list(),
    queryFn: () => officialFormTemplatesApi.list(),
  })
}

export function useUploadOfficialFormTemplate() {
  const keys = useTenantScopedQueryKeys()
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { form: string; locale: TemplateLocale; file: File }) =>
      officialFormTemplatesApi.upload(v.form, v.locale, v.file),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.officialFormTemplates.all() }),
  })
}

export function useOfficialFormTemplateTransition() {
  const keys = useTenantScopedQueryKeys()
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { id: string; action: TemplateAction; reasonCode: string }) =>
      officialFormTemplatesApi.transition(v.id, v.action, v.reasonCode),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.officialFormTemplates.all() }),
  })
}
