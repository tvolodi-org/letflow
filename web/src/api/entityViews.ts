/** entity views API client — REQ-556
 *
 *  Wraps `/api/v1/entity-views` (Letflow.Routers.EntityViews, REQ-555): list needs
 *  EntitiesQuery, create/delete need EntitiesViewsManage. A view carries layout only
 *  (columns, filter, sort); records are still read by `POST /entities/query`.
 */

import { client } from './client'
import type {
  EntityView,
  EntityViewCreateRequest,
  ReportCreateRequest,
  ReportUpdateRequest,
  ReportView,
} from '@/types/api'

export const entityViewsApi = {
  list: (entityType: string) =>
    client.get<{ items: EntityView[] }>(`/api/v1/entity-views?entity_type=${encodeURIComponent(entityType)}`),

  create: (body: EntityViewCreateRequest) => client.post<EntityView>('/api/v1/entity-views', body),

  remove: (id: string) => client.delete<void>(`/api/v1/entity-views/${encodeURIComponent(id)}`),
}

/** Saved reports (REQ-634): `kind: "report"` of the same five routes. The list route returns
 *  every kind of the type, so `list` keeps only the reports. Create forces `kind`; update sends
 *  neither `kind` nor `entity_type` (both are immutable server-side). */
export const reportViewsApi = {
  list: async (entityType: string): Promise<{ items: ReportView[] }> => {
    const page = await client.get<{ items: EntityView[] }>(
      `/api/v1/entity-views?entity_type=${encodeURIComponent(entityType)}`,
    )
    const items = Array.isArray(page?.items) ? page.items : []
    return { items: items.filter((v): v is ReportView => v.kind === 'report') }
  },

  get: (id: string) => client.get<ReportView>(`/api/v1/entity-views/${encodeURIComponent(id)}`),

  create: (body: ReportCreateRequest) =>
    client.post<ReportView>('/api/v1/entity-views', { ...body, kind: 'report' }),

  update: (id: string, body: ReportUpdateRequest) =>
    client.put<ReportView>(`/api/v1/entity-views/${encodeURIComponent(id)}`, body),

  remove: (id: string) => client.delete<void>(`/api/v1/entity-views/${encodeURIComponent(id)}`),
}
