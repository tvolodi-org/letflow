/** T-1989 — query hooks of the Approval rules screen. */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { approvalRulesApi, type ApprovalRuleBody } from '@/api/approvalRules'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export function useApprovalRulesList() {
  const keys = useTenantScopedQueryKeys()
  return useQuery({ queryKey: keys.approvalRules.list(), queryFn: () => approvalRulesApi.list() })
}

export function useSaveApprovalRule() {
  const keys = useTenantScopedQueryKeys()
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { definitionName: string; nodeId: string; body: ApprovalRuleBody }) =>
      approvalRulesApi.put(v.definitionName, v.nodeId, v.body),
    // Refetch after success and after a failure alike: a 409 / not_a_four_eyes_step means the list is stale.
    onSettled: () => qc.invalidateQueries({ queryKey: keys.approvalRules.all() }),
  })
}
