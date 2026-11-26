/** maintenance.api — GH 4802 / REQ-898. Calls of the maintenance routes (REQ-894 / REQ-895 / REQ-896). Every write
 *  carries the idempotency key in the body and exactly the keys the route accepts; no call sends a tenant
 *  identifier (the tenant comes from the token). */
import { client } from '@/api/client'

const BASE = '/api/v1/modules/maintenance'

const seg = (id: string) => encodeURIComponent(id)

export const URGENCIES = ['low', 'normal', 'urgent'] as const
export type Urgency = (typeof URGENCIES)[number]

export const REQUEST_STATUSES = ['new', 'ordered', 'rejected'] as const
export type RequestStatus = (typeof REQUEST_STATUSES)[number]

/** The equipment of a request: the two readable fields of the asset card, never its id alone. */
export interface RequestAsset {
  id: string
  inventory_number: string | null
  name: string | null
}

export interface RequestOrderRef {
  id: string
  number: string | null
}

/** One work request as the server shows it (`Letflow.Modules.Maintenance.Requests`). */
export interface MaintenanceRequest {
  id: string
  number: string | null
  status: RequestStatus
  asset: RequestAsset
  description: string
  urgency: Urgency
  reported_by: string
  reject_reason: string | null
  order: RequestOrderRef | null
  photo_count: number
  created_at: string
}

/** One photo of a request (`Letflow.Modules.Maintenance.Photos`). */
export interface MaintenancePhoto {
  id: string
  position: number
  caption: string | null
  has_thumbnail: boolean
  inserted_at: string
}

export interface RequestListPage {
  rows: MaintenanceRequest[]
  next_cursor: string | null
}

export interface CreateRequestBody {
  asset_card_id: string
  description: string
  urgency: Urgency
}

export const maintenanceApi = {
  /** The requests newest first; `status` is the server-side filter (all, new, ordered, rejected). */
  list: (status: string, cursor?: string) => {
    const q = new URLSearchParams()
    if (status !== '') q.set('status', status)
    if (cursor) q.set('cursor', cursor)
    const query = q.toString()
    return client.get<RequestListPage>(`${BASE}/requests${query === '' ? '' : `?${query}`}`)
  },
  get: (id: string) => client.get<MaintenanceRequest>(`${BASE}/requests/${seg(id)}`),
  create: (body: CreateRequestBody, key: string) =>
    client.post<MaintenanceRequest>(`${BASE}/requests`, { ...body, idempotency_key: key }),
  reject: (id: string, reason: string) => client.post<MaintenanceRequest>(`${BASE}/requests/${seg(id)}/reject`, { reason }),
  /** REQ-896: the work order made from a request; the order copies its card, description and urgency. */
  createOrder: (requestId: string, key: string) =>
    client.post<{ id: string; number: string | null }>(`${BASE}/orders`, { request_id: requestId, idempotency_key: key }),
  listPhotos: (id: string) => client.get<{ photos: MaintenancePhoto[] }>(`${BASE}/requests/${seg(id)}/photos`),
  /** Multipart: `original` required, `thumbnail` and `caption` optional (the shape of the card photo upload). */
  uploadPhoto: (id: string, original: Blob, caption = '') => {
    const form = new FormData()
    form.append('original', original, 'photo.jpg')
    if (caption !== '') form.append('caption', caption)
    return client.post<MaintenancePhoto>(`${BASE}/requests/${seg(id)}/photos`, form)
  },
  photoContent: (id: string, photoId: string, kind: 'original' | 'thumbnail') =>
    client.getBlob(`${BASE}/requests/${seg(id)}/photos/${seg(photoId)}/${kind}`),
}
