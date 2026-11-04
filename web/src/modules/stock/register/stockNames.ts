/** stockNames — GH 3767 / REQ-724. Names of the masters a page of the register points at: one queryRecords call
 *  per master type per page (filter record_id in <ids of the page>), ids de-duplicated, nulls dropped. An id with
 *  no readable record shows as its id text. */
import { useQueries } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { entitiesApi } from '@/api/entities'
import type { EntityRecord } from '@/types/api'
import { stockQueryKeys } from './stockQueryKeys'
import { LABEL_FIELD, type MasterType, type NameIds } from './stockRegisterModel'

/** The query route's largest page. */
const MAX_PAGE = 200

function labelOf(type: MasterType, rec: EntityRecord): string {
  const fv = rec.field_values
  for (const f of [LABEL_FIELD[type], 'name', 'code']) {
    const v = fv[f]
    if (typeof v === 'string' && v !== '') return v
  }
  return rec.record_id
}

async function fetchNames(type: MasterType, ids: string[]): Promise<Record<string, string>> {
  const out: Record<string, string> = {}
  for (let i = 0; i < ids.length; i += MAX_PAGE) {
    const chunk = ids.slice(i, i + MAX_PAGE)
    const res = await entitiesApi.queryRecords(type, {
      filters: [{ field: 'record_id', op: 'in', value: chunk }],
      page_size: chunk.length,
    })
    for (const rec of res.items) out[rec.record_id] = labelOf(type, rec)
  }
  return out
}

/** `pages`: the ids of each loaded page. Returns a function id -> text (empty for null). */
export function useNames(pages: NameIds[]): (type: MasterType, id: string | null | undefined) => string {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const jobs = pages.flatMap((p) =>
    (Object.entries(p) as [MasterType, string[]][])
      .map(([type, ids]) => ({ type, ids: [...new Set(ids)].sort() }))
      .filter((j) => j.ids.length > 0),
  )
  const results = useQueries({
    queries: jobs.map((j) => ({
      queryKey: stockQueryKeys.names(tenantId, j.type, j.ids.join(',')),
      queryFn: () => fetchNames(j.type, j.ids),
      retry: false,
    })),
  })
  const maps: Partial<Record<MasterType, Record<string, string>>> = {}
  results.forEach((r, i) => {
    if (r.data) maps[jobs[i].type] = { ...maps[jobs[i].type], ...r.data }
  })
  return (type, id) => (id == null || id === '' ? '' : (maps[type]?.[id] ?? id))
}
