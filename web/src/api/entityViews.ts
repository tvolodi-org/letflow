/** entity views API client — REQ-556
 *
 *  Wraps `/api/v1/entity-views` (Letflow.Routers.EntityViews, REQ-555): list needs
 *  EntitiesQuery, create/delete need EntitiesViewsManage. A view carries layout only
 *  (columns, filter, sort); records are still read by `POST /entities/query`.
 */

import { client } from './client'
import type { EntityView, EntityViewCreateRequest } from '@/types/api'

export const entityViewsApi = {
  list: (entityType: string) =>
    client.get<{ items: EntityView[] }>(`/api/v1/entity-views?entity_type=${encodeURIComponent(entityType)}`),

  create: (body: EntityViewCreateRequest) => client.post<EntityView>('/api/v1/entity-views', body),

  remove: (id: string) => client.delete<void>(`/api/v1/entity-views/${encodeURIComponent(id)}`),
}
