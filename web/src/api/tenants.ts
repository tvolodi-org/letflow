import { client } from './client'

export interface Tenant {
  slug: string
  tenant_id?: string
  display_name: string
  idp_realm_id: string | null
  hostname?: string
  redirect_uris?: string[]
  status: 'ACTIVE' | 'INACTIVE'
  created_at: string
  tenant_type: 'production' | 'test'
}

// Real backend envelope: lib/letflow/api/pagination.ex's Page struct
// (`@derive {Jason.Encoder, only: [:items, :next_cursor, :count]}`) via
// lib/letflow/routers/tenants.ex's handle_list/1. There has never been a
// `total`/`limit`/`offset` field on this endpoint's response body — see
// lib/letflow/design/iss0711-tenant-count-field-mismatch.md.
export interface TenantListResponse {
  items: Tenant[]
  next_cursor: string | null
  count: number // length(items) for the CURRENT PAGE ONLY — never a cross-page total.
}

export const tenantsApi = {
  list: (params?: { search?: string; cursor?: string; page_size?: number }) =>
    client.get<TenantListResponse>('/api/v1/tenants', params as Record<string, unknown>),

  getBySlug: (slug: string) =>
    client.get<Tenant>(`/api/v1/tenants/${slug}`),

  patch: (slug: string, body: Partial<{ display_name: string; hostname: string; redirect_uris: string[] }>) =>
    client.patch<Tenant>(`/api/v1/tenants/${slug}`, body),

  deactivate: (slug: string) =>
    client.post<Tenant>(`/api/v1/tenants/${slug}/deactivate`, {}),

  reactivate: (slug: string) =>
    client.post<Tenant>(`/api/v1/tenants/${slug}/reactivate`, {}),
}
