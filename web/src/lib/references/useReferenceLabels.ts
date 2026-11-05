/** useReferenceLabels — T-1378. The one hook that turns reference values (record ids) into text: one queryRecords call per
 *  type per page (filter record_id in <ids>), ids de-duplicated, cached by react-query. The returned function never
 *  returns an id: loading shows an ellipsis, a record that cannot be read shows "Unknown record". A value that is not a
 *  uuid (already a code) is shown as it is. */
import { useQueries } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { entitiesApi } from '@/api/entities'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { isUuid, labelOfRecord, type ReferenceType } from './referenceLabel'
import { REFERENCE_MESSAGES } from './referenceMessages'
import { referenceQueryKeys } from './referenceQueryKeys'

/** The query route's largest page. */
const MAX_PAGE = 200

export type ReferenceIds = Partial<Record<ReferenceType, string[]>>

async function fetchLabels(type: ReferenceType, ids: string[]): Promise<Record<string, string>> {
  const out: Record<string, string> = {}
  for (let i = 0; i < ids.length; i += MAX_PAGE) {
    const chunk = ids.slice(i, i + MAX_PAGE)
    const res = await entitiesApi.queryRecords(type, {
      filters: [{ field: 'record_id', op: 'in', value: chunk }],
      page_size: chunk.length,
    })
    for (const rec of res.items) {
      const label = labelOfRecord(type, rec)
      if (label !== null) out[rec.record_id] = label
    }
  }
  return out
}

/** `pages`: the ids of each loaded page. Returns a function (type, id) -> text (empty for null). */
export function useReferenceLabels(pages: ReferenceIds[]): (type: ReferenceType, id: string | null | undefined) => string {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const msg = REFERENCE_MESSAGES[useUiLocale()]
  const jobs = pages.flatMap((p) =>
    (Object.entries(p) as [ReferenceType, string[]][])
      .map(([type, ids]) => ({ type, ids: [...new Set(ids)].sort() }))
      .filter((j) => j.ids.length > 0),
  )
  const results = useQueries({
    queries: jobs.map((j) => ({
      queryKey: referenceQueryKeys.labels(tenantId, j.type, j.ids.join(',')),
      queryFn: () => fetchLabels(j.type, j.ids),
      retry: false,
    })),
  })
  const maps: Partial<Record<ReferenceType, Record<string, string>>> = {}
  let pending = false
  results.forEach((r, i) => {
    if (r.data) maps[jobs[i].type] = { ...maps[jobs[i].type], ...r.data }
    else if (r.isPending) pending = true
  })
  return (type, id) => {
    if (id == null || id === '') return ''
    const hit = maps[type]?.[id]
    if (hit !== undefined) return hit
    if (!isUuid(id)) return id
    return pending ? msg.loading : msg.unknown
  }
}
