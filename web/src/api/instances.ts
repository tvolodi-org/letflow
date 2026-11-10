import { client } from './client'
import type {
  ProcessInstance,
  StartInstanceRequest,
  CursorPage,
  InstanceStatus,
  EventRecord,
  TimelinePage,
  NodeEntriesPage,
  InstancePinsResponse,
  RebindPinsRequestBody,
  RebindPinsResult,
} from '@/types/api'

export const instancesApi = {
  list: (params?: {
    status?: InstanceStatus[]
    definition_id?: string
    cursor?: string
    page_size?: number
  }) =>
    client.get<CursorPage<ProcessInstance>>('/api/v1/instances', {
      ...params,
      status: params?.status?.join(','),
    } as Record<string, unknown>),

  get: (id: string) =>
    client.get<ProcessInstance>(`/api/v1/instances/${id}`),

  start: (body: StartInstanceRequest) =>
    client.post<ProcessInstance>('/api/v1/instances', body),

  cancel: (id: string, reason?: string) =>
    client.post<void>(`/api/v1/instances/${id}/cancel`, { reason }),

  events: (
    id: string,
    params?: {
      after_seq?: number
      before_seq?: number
      limit?: number
      event_type?: string
      from?: string
      to?: string
    },
  ) =>
    client.get<EventRecord[]>(`/api/v1/instances/${id}/history`, params as Record<string, unknown>),

  timeline: (id: string, params?: { cursor?: string; page_size?: number }) =>
    client.get<TimelinePage>(`/api/v1/instances/${id}/timeline`, params as Record<string, unknown>),

  /** T-1635: one page of the instance's NODE_ENTERED events (REQ-793) from the history route, for the replay. */
  nodeEntries: (id: string, params?: { cursor?: string; page_size?: number }) =>
    client.get<NodeEntriesPage>(`/api/v1/instances/${id}/history`, {
      event_type: 'NODE_ENTERED',
      ...params,
    } as Record<string, unknown>),

  reconstruct: (id: string) =>
    client.get<ProcessInstance>(`/api/v1/instances/${id}/reconstruct`),

  // REQ-399: already-shipped route (REQ-080) — pure read of
  // PinResolver.reconstruct_effective_pins/2, no query params.
  getPins: (id: string) =>
    client.get<InstancePinsResponse>(`/api/v1/instances/${id}/pins`),

  // REQ-078/PIN-05, operator UI: REQ-432. No explicit idempotency-key
  // header is set — the backend sources it from the `idempotency-key`
  // request header when present, and generates one server-side when absent
  // (design §3.1/OQ-2); this UI has no cross-request retry/dedup need of
  // its own, so the simplest correct choice is to let the backend generate
  // one per call.
  rebindPins: (id: string, body: RebindPinsRequestBody) =>
    client.post<RebindPinsResult>(`/api/v1/instances/${id}/rebind-pins`, body),
}
