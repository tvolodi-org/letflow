/** REQ-384 §2.2 — GET /api/v1/me/memberships client.
 *
 *  Mirrors `lib/letflow/routers/me.ex`'s response shape exactly:
 *  `{"memberships": [{"tenant_id", "tenant_slug", "tenant_display_name",
 *  "display_label"}, ...]}`, always including the caller's own current
 *  tenant as one entry. Field selection is server-side only (INV-2) — this
 *  endpoint never returns `idp_realm_id` or any OIDC config; that is
 *  resolved separately via `fetchTenantConfigForSlug` (`auth/tenantConfig.ts`).
 */
import { client } from './client'

export interface Membership {
  tenant_id: string
  tenant_slug: string
  tenant_display_name: string
  display_label: string | null
}

export interface MembershipsResponse {
  memberships: Membership[]
}

export const membershipsApi = {
  list: () => client.get<MembershipsResponse>('/api/v1/me/memberships'),
  /** Same call with an explicit token, for the login path where it is not installed yet. */
  listWithToken: (token: string) =>
    client.getWithToken<MembershipsResponse>('/api/v1/me/memberships', token),
}
