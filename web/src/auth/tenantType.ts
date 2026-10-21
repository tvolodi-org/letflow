import { fetchTenantConfigForSlug } from './tenantConfig'

/**
 * REQ-470: the tenant type ('test' | 'production') from the public tenant-config, so
 * every session has it, not only the platform-admin one that may read the tenants
 * record. Anything else (a missing key, null, an unknown value, a failed lookup) is
 * null: no banner, never a login failure.
 */
export async function fetchTenantTypeForSlug(slug: string | null): Promise<'production' | 'test' | null> {
  if (!slug) return null
  try {
    const config = await fetchTenantConfigForSlug(slug)
    return config.tenant_type === 'test' || config.tenant_type === 'production' ? config.tenant_type : null
  } catch {
    return null
  }
}
