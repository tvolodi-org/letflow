/** REQ-383 — tenant self-service settings API client.
 *
 * Wraps `PATCH /api/v1/tenant/settings` (REQ-382,
 * `lib/letflow/routers/tenant_settings.ex`). Unlike `tenants.ts`, this
 * endpoint has NO target-tenant path parameter — it always patches the
 * caller's own tenant (`conn.assigns.auth_context.tenant_id`). Kept as its
 * own module rather than added to `tenants.ts`, whose whole surface is
 * slug-addressed per-tenant-registry operations (design doc §1/§3.3).
 *
 * This screen sends exactly one shape and nothing else:
 * `{ brand_colors: { primary } }` — flat, matching
 * `lib/letflow/routers/tenant_settings.ex`'s `partition_top_level/1`, which
 * partitions the request body's TOP-LEVEL keys against
 * `TenantSettings.allowed_keys/0`. There is no `settings` wrapper key in the
 * router's real contract (see `test/letflow/routers/tenant_settings_test.exs`,
 * whose every dispatch uses this flat shape). A previous version of this
 * comment and client asserted a wrapped `{ settings: { brand_colors: {...} } }`
 * shape was correct; that was wrong (ISS-0887) — the router treated
 * `"settings"` as an unrecognized top-level key, silently no-op'd, and
 * returned 200 without persisting anything.
 */
import { client } from './client'

export interface TenantSettingsPatchBody {
  brand_colors: {
    primary: string // "#RRGGBB" — the only key this screen ever sends
  }
}

export interface TenantSettingsPatchResponse {
  tenant_id: string
  settings: Record<string, unknown> // full merged settings map (REQ-382 §3 step 9b)
}

export const tenantSettingsApi = {
  patchBrandColorPrimary: (primary: string) =>
    client.patch<TenantSettingsPatchResponse>('/api/v1/tenant/settings', {
      brand_colors: { primary },
    } satisfies TenantSettingsPatchBody),
  /** T-1391 — the tenant default of the document-form layout (flat top-level key, like the colour). */
  patchDocumentLayoutDefault: (layout: string) =>
    client.patch<TenantSettingsPatchResponse>('/api/v1/tenant/settings', { 'ui.document_layout_default': layout }),
}
