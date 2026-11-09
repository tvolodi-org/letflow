import { client } from './client'
import type { CursorPage } from '@/types/api'

export interface AuditLogFilters {
  actor?: string
  resource_type?: string
  resource_id?: string
  from?: string
  to?: string
  cursor?: string
  page_size?: number
}

export interface AuditEntry {
  id: string
  occurred_at: string
  actor_id: string
  actor_display_name?: string
  resource_name?: string
  resource_type: string
  resource_id: string
  action: string
  before_state?: Record<string, unknown> | null
  after_state?: Record<string, unknown> | null
  ip_address?: string | null
}

interface RawAuditEntry {
  audit_id: string
  actor_id?: string | null
  actor_name?: string | null
  resource_name?: string | null
  action: string
  resource_type: string
  resource_id: string
  timestamp: string
  before_state?: Record<string, unknown> | null
  after_state?: Record<string, unknown> | null
}

interface RawAuditPage {
  items: RawAuditEntry[]
  next_cursor: string | null
  count: number
}

function mapAuditEntry(raw: RawAuditEntry): AuditEntry {
  return {
    id: raw.audit_id,
    occurred_at: raw.timestamp,
    actor_id: raw.actor_id ?? 'unknown',
    actor_display_name: raw.actor_name ?? undefined,
    resource_name: raw.resource_name ?? undefined,
    action: raw.action,
    resource_type: raw.resource_type,
    resource_id: raw.resource_id,
    before_state: raw.before_state ?? null,
    after_state: raw.after_state ?? null,
    ip_address: null,
  }
}

export const auditApi = {
  list: async (filters: AuditLogFilters): Promise<CursorPage<AuditEntry>> => {
    const response = await client.get<RawAuditPage>('/api/v1/audit', {
      actor_id: filters.actor,
      resource_type: filters.resource_type,
      resource_id: filters.resource_id,
      from: filters.from,
      to: filters.to,
      cursor: filters.cursor,
      page_size: filters.page_size ? String(filters.page_size) : undefined,
    })

    return {
      items: response.items.map(mapAuditEntry),
      next_cursor: response.next_cursor,
      count: response.count,
    }
  },

  /** CSV export of the filtered list (T-1557). Same filters, no cursor; the server caps the rows. */
  exportCsv: async (filters: AuditLogFilters): Promise<{ blob: Blob; truncated: boolean }> => {
    const { blob, headers } = await client.getBlob('/api/v1/audit', {
      format: 'csv',
      actor_id: filters.actor,
      resource_type: filters.resource_type,
      resource_id: filters.resource_id,
      from: filters.from,
      to: filters.to,
    })
    return { blob, truncated: headers.get('x-audit-export-truncated') === 'true' }
  },
}
