import { client } from './client'
import type {
  ProcessDefinition,
  CreateDefinitionRequest,
  CursorPage,
  DefinitionStatus,
  DefinitionGraph,
} from '@/types/api'

export interface PromoteResult {
  definition_id: string
  version: string
  status: string
}

// ── REQ-431: server-side semantic validation (REQ-372's violations) ──────────
//
// Two structurally different response shapes for POST /:id/validate — see
// lib/letflow/design/req431-definition-validation-canvas-presentation.md §3.2:
//   - clean (200): {status: 'valid', findings: [], definition_id, validated_at}
//   - invalid (422, RFC 9457): no `findings` key — the violation list is the
//     `errors` extension member, surfaced by client.ts's throwOnErrorResponse
//     as a THROWN ApiError with `details` set to that array. GraphValidationResponse
//     below describes only the 200/valid shape; callers must catch the 422, not
//     branch on a resolved "invalid" value.

/** One violation item, wire-shaped `{code, message}` (Graph.Violation, serialised
 *  by `violation_map/1`). `code` is treated as an opaque string client-side —
 *  new codes must render, not crash. */
export interface GraphValidationViolation {
  code: string
  message: string
}

/** Resolved shape on the 200/"valid" branch only. */
export interface GraphValidationResponse {
  status: 'valid' | 'invalid'
  definition_id: string
  findings: GraphValidationViolation[]
  validated_at?: string
}

/** getVersions reads at most this many pages of VERSION_PAGE_SIZE rows. */
export const MAX_VERSION_PAGES = 5
export const VERSION_PAGE_SIZE = 200

export const definitionsApi = {
  list: (params?: { status?: DefinitionStatus; name?: string; cursor?: string; page_size?: number }) =>
    client.get<CursorPage<ProcessDefinition>>('/api/v1/definitions', params as Record<string, unknown>),

  get: (id: string) =>
    client.get<ProcessDefinition>(`/api/v1/definitions/${id}`),

  getActive: (name: string) =>
    client.get<ProcessDefinition>(`/api/v1/definitions/active/${encodeURIComponent(name)}`),

  create: (body: CreateDefinitionRequest) =>
    client.post<ProcessDefinition>('/api/v1/definitions', body),

  update: (id: string, body: Partial<CreateDefinitionRequest>) =>
    client.patch<ProcessDefinition>(`/api/v1/definitions/${id}`, body),

  activate: (id: string) =>
    client.post<ProcessDefinition>(`/api/v1/definitions/${id}/activate`),

  // REQ-431 — bodyless validates the STORED graph. T-1563: with `graph` the server validates that draft graph with the
  // same validators and persists nothing (the process designer's live check).
  // Resolves clean (200); THROWS an ApiError (422, details: GraphValidationViolation[])
  // when the graph fails REQ-372's semantic checks. See §3.3 of the design doc.
  validate: (id: string, graph?: DefinitionGraph) =>
    graph
      ? client.post<GraphValidationResponse>(`/api/v1/definitions/${id}/validate`, { graph })
      : client.post<GraphValidationResponse>(`/api/v1/definitions/${id}/validate`),

  deprecate: (id: string) =>
    client.post<ProcessDefinition>(`/api/v1/definitions/${id}/deprecate`),

  archive: (id: string) =>
    client.post<ProcessDefinition>(`/api/v1/definitions/${id}/archive`),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/definitions/${id}`),

  exportJson: (id: string) =>
    client.get<unknown>(`/api/v1/definitions/${id}/export`),

  importJson: (body: unknown) =>
    client.post<ProcessDefinition>('/api/v1/definitions/import', body),

  // ISS-0820: params corrected to match handle_search/1's actual reads (q, cursor, page_size).
  // limit and offset were dead params the backend silently ignored.
  search: (params: { q: string; cursor?: string; page_size?: number }) =>
    client.get<CursorPage<ProcessDefinition>>('/api/v1/definitions/search', params as Record<string, unknown>),

  /** Every version of the definition called `name` (newest first). The server's `name` filter is a substring match
   *  (`%name%`), so the raw pages also hold other definitions (`purchase-approval` for `approval`): follow the
   *  cursor and keep exact name matches only. At most MAX_VERSION_PAGES pages are read; when the cap is hit the
   *  returned `next_cursor` is set (the caller shows a banner). */
  getVersions: async (name: string): Promise<CursorPage<ProcessDefinition>> => {
    const items: ProcessDefinition[] = []
    let cursor: string | null = null
    for (let page = 0; page < MAX_VERSION_PAGES; page++) {
      const params: Record<string, unknown> = { name, page_size: VERSION_PAGE_SIZE }
      if (cursor) params.cursor = cursor
      const res: CursorPage<ProcessDefinition> = await client.get<CursorPage<ProcessDefinition>>('/api/v1/definitions', params)
      for (const d of res.items ?? []) if (d.name === name) items.push(d)
      cursor = res.next_cursor ?? null
      if (!cursor) break
    }
    return { items, next_cursor: cursor }
  },

  promote: (testTenantId: string, definitionName: string) =>
    client.post<PromoteResult>(`/api/v1/tenants/${testTenantId}/promote/${encodeURIComponent(definitionName)}`, {}),
}
