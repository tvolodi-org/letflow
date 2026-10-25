# Tenant configuration bundle (REQ-552, slice 1)

Moves a tenant's configuration from one tenant to another (for example test to production) without
the definition promotion pipeline. Implemented by `Letflow.TenantConfigBundle` and mounted by
`Letflow.Routers.TenantConfigBundle`.

## Routes

| Route | Permission | Result |
|---|---|---|
| `GET /api/v1/tenant/config-bundle` | `:TenantSettingsManage` | the bundle of the caller's own tenant |
| `POST /api/v1/tenant/config-bundle/import` | `:TenantSettingsManage`, plus `:ModulesManage` when `module_settings` is non-empty | counts: `tenant_settings_changed`, `modules_changed`, `modules_unchanged` |

There is no tenant identifier in the path, query or body: an import always changes the tenant of the
token. To promote, export with the source tenant's token and import with the target tenant's token.

## What the bundle carries

`bundle_schema_version` (`bpm/config-bundle/v1`), `exported_at`, `tenant_settings` (the closed keys of
`Letflow.Identity.TenantSettings`) and `module_settings` (one entry per installed module: `module_id`,
`module_version`, `settings`). A module setting that holds a secret reference is exported as that
reference string; no secret is ever resolved.

## What it does not carry

Scripts (decision 0053, Record P), roles, number sequences, definitions (use the promotion pipeline or a
solution pack), and the module install state itself: a module that is not installed in the target makes
the import fail.

## Import rules

- Stricter than `PATCH /tenant/settings`: an unknown tenant-settings key or `brand_colors` sub-key is a 422.
- Tenant settings are shallow-merged onto the stored settings, then validated like a PATCH.
- All-or-nothing: every violation is listed in the 422 detail and nothing is written.
- Unknown `bundle_schema_version`: 422 `unknown_bundle_schema_version`.
- Idempotent: re-importing identical content reports `tenant_settings_changed: 0` and writes no audit entry.
- A change writes exactly one audit entry (`tenant_config_bundle.import`) with key names and module ids, never values.
- A caller without the permissions gets the same 403 body as any other forbidden route.
