import { membershipsApi } from '@/api/memberships'

/** T-2291: the display name of the caller's own tenant, for the top bar.
 *  GET /api/v1/tenants/:slug is platform-only, so every other session reads the name from
 *  GET /me/memberships (self-service; it always lists the caller's own tenant). Returns null
 *  on any failure or when the name is blank, so the caller falls back to the slug. */
export async function resolveOwnTenantDisplayName(token: string, slug: string): Promise<string | null> {
  try {
    const { memberships } = await membershipsApi.listWithToken(token)
    const name = memberships.find(m => m.tenant_slug === slug)?.tenant_display_name
    return typeof name === 'string' && name.trim() !== '' ? name : null
  } catch {
    return null
  }
}
