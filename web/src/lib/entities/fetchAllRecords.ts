/** fetchAllRecords — the one "load everything" loop of the list screens (items, locations, org). It follows the
 *  cursor in pages of 200 up to MAX_PAGES and marks the list when the server still had more, so a screen can say
 *  that it shows only the first part instead of cutting silently (pilot volume follow-up, T-1801). */
import { entitiesApi } from '@/api/entities'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'

export const MAX_PAGES = 50
export const PAGE_SIZE = 200
/** Rows loaded before the list is cut. */
export const MAX_ROWS = MAX_PAGES * PAGE_SIZE

/** The rows; `truncated` is true when the page cap was reached with more rows on the server. The flag lives on
 *  the array, so a query using this list must keep `structuralSharing: false` (react-query would copy the array). */
export type RecordList = EntityRecord[] & { truncated?: boolean }

export async function fetchAllRecords(
  type: string,
  filters: EntityQueryFilterClause[],
  sortField = 'code',
  sortDir: 'asc' | 'desc' = 'asc',
  maxPages = MAX_PAGES,
): Promise<RecordList> {
  const out: RecordList = []
  let cursor: string | undefined
  for (let page = 0; page < maxPages; page++) {
    const res = await entitiesApi.queryRecords(type, {
      filters,
      sort: [{ field: sortField, dir: sortDir }],
      page_size: PAGE_SIZE,
      ...(cursor ? { cursor } : {}),
    })
    out.push(...res.items)
    if (!res.next_cursor || res.next_cursor === cursor) return out
    cursor = res.next_cursor
  }
  out.truncated = true
  return out
}

/** True when any of the query results holds a list cut at the page cap. */
export function anyTruncated(queries: { data?: unknown }[]): boolean {
  return queries.some((q) => Array.isArray(q.data) && (q.data as RecordList).truncated === true)
}
