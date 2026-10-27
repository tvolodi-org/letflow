# Tenant configuration bundle (REQ-552 slice 1, REQ-599 part 1)

Moves a tenant's configuration from one tenant to another (for example test to production) without
the definition promotion pipeline. Implemented by `Letflow.TenantConfigBundle` and mounted by
`Letflow.Routers.TenantConfigBundle`.

## Routes

| Route | Permission | Result |
|---|---|---|
| `GET /api/v1/tenant/config-bundle` | `:TenantSettingsManage`; `label_overrides` needs `:LabelsManage`, `notification_templates` needs `:NotificationTemplatesManage` | the bundle of the caller's own tenant; a part the caller may not read is left out (no key, no 403) |
| `POST /api/v1/tenant/config-bundle/import` | `:TenantSettingsManage`, plus `:ModulesManage` when `module_settings` is non-empty | counts: `tenant_settings_changed`, `modules_changed`, `modules_unchanged` |

There is no tenant identifier in the path, query or body: an import always changes the tenant of the
token. To promote, export with the source tenant's token and import with the target tenant's token.

## What the bundle carries

`bundle_schema_version` (`bpm/config-bundle/v2`), `exported_at`, `tenant_settings` (the closed keys of
`Letflow.Identity.TenantSettings`) and `module_settings` (one entry per installed module: `module_id`,
`module_version`, `settings`). A module setting that holds a secret reference is exported as that
reference string; no secret is ever resolved.

From v2 two more parts, each only for a caller who holds its manage permission: `label_overrides` (`message_id`,
`locale`, `text`; sorted by `message_id`, `locale`) and `notification_templates` (`template_key`, `locale`,
`subject`, `body`; sorted by `template_key`, `locale`). A tenant with none exports `[]`. Overrides whose id left the
default file are exported as stored.

## Versions

- Export is always `bpm/config-bundle/v2`.
- Import accepts v1 and v2. A v1 document has no `label_overrides` / `notification_templates`; an absent part leaves
  the target untouched.
- Until part 2 of REQ-599 (GH #3370) the two new parts of a v2 document are not read or applied on import; the
  audit entry records the version of the imported document.

## What it does not carry

Scripts (decision 0053, Record P), roles, number sequences, integration mappings (the link lives on the webhook
subscription `outbound_mapping_id`; a name-keyed follow-up decides), definitions (use the promotion pipeline or a
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
