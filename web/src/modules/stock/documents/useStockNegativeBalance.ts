/** REQ-838: read the tenant rule and the exact on-hand key of every lowering document line.
 *  This is a custom hook so its caller needs no extra query-state boundary: every failure simply means no warning. */
import { useMemo } from 'react'
import { useQueries } from '@tanstack/react-query'
import { queryKeys } from '@/api/queryKeys'
import { stockApi } from '../register/stock.api'
import { groupOnHand, quantitiesExceedBalance, stockBalanceGroups } from './negativeBalance'
import type { FormState } from './documentsModel'

export function useStockNegativeBalance(form: FormState, tenantId: string, mayRead: boolean): ReadonlySet<number> {
  const groups = useMemo(() => stockBalanceGroups(form), [form])
  const watches = mayRead && groups.length > 0
  const [rule] = useQueries({ queries: [{
    queryKey: queryKeys.stock.postingRules(tenantId),
    queryFn: () => stockApi.postingRules(),
    enabled: watches,
    retry: false,
  }] })
  const allowed = watches && rule.data?.negative_balance === 'allowed'
  const balances = useQueries({
    queries: groups.map((group) => ({
      queryKey: queryKeys.stock.balance(tenantId, group.id),
      queryFn: () => stockApi.balances(group.params),
      enabled: allowed,
      retry: false,
    })),
  })

  return useMemo(() => {
    const out = new Set<number>()
    // One unavailable read must not turn stale or partial data into a warning; the form behaves as it did before REQ-838.
    if (!allowed || balances.some((q) => !q.isSuccess)) return out
    groups.forEach((group, i) => {
      const rows = balances[i]?.data?.rows ?? []
      if (quantitiesExceedBalance(group.quantities, groupOnHand(group, rows))) {
        group.lineIndexes.forEach((index) => out.add(index))
      }
    })
    return out
  }, [allowed, balances, groups])
}
