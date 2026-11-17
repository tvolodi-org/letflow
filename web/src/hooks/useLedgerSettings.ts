/** REQ-839 — query hooks of the Negative balances admin screen. */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ledgerSettingsApi, type LedgerSettingBody } from '@/api/ledgerSettings'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export function useLedgerSettingsList() {
  const keys = useTenantScopedQueryKeys()
  return useQuery({ queryKey: keys.ledgerSettings.list(), queryFn: () => ledgerSettingsApi.list() })
}

export function useSaveLedgerSetting() {
  const keys = useTenantScopedQueryKeys()
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { registration: string; body: LedgerSettingBody }) => ledgerSettingsApi.put(v.registration, v.body),
    // Refetch after success and after a failure alike: a not_switchable or 409 means the list is stale.
    onSettled: () => qc.invalidateQueries({ queryKey: keys.ledgerSettings.all() }),
  })
}
