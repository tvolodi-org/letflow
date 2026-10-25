# 0069 -- Solution versioning and per-tenant overrides at pack and process-definition level: a named, versioned override layer kept apart from the installed definition, pinned to the pack version it was made against, never overwritten by an update

Status: PROPOSED by the developer of GH #3197 (REQ-562 slice 0, task T-0519), 2026-10-25. Needs SECURITY-REVIEWER and REVIEWER sign-off (see Sign-off). Changes no code: every implementation slice is its own requirement (see D8).

Date: 2026-10-25

Requirement: REQ-562 (GH #3197).

Amends: [0039](0039-platform-module-solution-layering.md) D7, "Tenant configuration is additive only". The sentence amended is: **"Where a tenant *has* changed an installed definition, the existing 3-way pack-update machinery in `solution_pack.ex` remains the fallback, not the normal path."** After this record, a tenant deviation in the artefacts covered by D2 is carried by a named override (D2), and the 3-way machinery stays the single update path (D4) that now reads overrides; it is no longer a fallback that discovers an edited definition after the fact. The first sentence of D7 (a tenant sets values a module declared, never edits the module's definitions in place) is not changed, and the paragraph "Client scripts are not in scope" is not touched (already amended by 0053).

Builds on: [0055](0055-module-upgrade-migration-uninstall.md) D1 (the module version is the unit of upgrade; per-artefact versions stay the unit of activation and pinning) and D9 (rollback).

Depends on: REQ-550 and its record [0067](0067-tenant-x-extension-layer-over-module-entity-types.md) (boundary, D1 "Override kinds split").

Other decisions touched: **0055 D1**: not amended, its module-semver rule is applied to packs only as a recommendation (D1, Q1). **0067**: not amended; its Boundary section named this requirement by title with no REQ id, and this record supplies it (REQ-562, its open point OP-9). **0026, 0027, 0029**: unchanged, the pack section set stays closed (D2). **0039 D8 and the rest of 0039**: unchanged. **0068**: unchanged; print templates stay with REQ-564.

## Sources

Files and records opened for this record:

- `docs/migration/core-roadmap-20261014.md`, Wave 3 row "Solution versioning and per-tenant overrides".
- REQ-562 as registered in `docs/requirements.yaml`.
- [0039](0039-platform-module-solution-layering.md) D7 and its relationship to 0026/0027/0029; [0055](0055-module-upgrade-migration-uninstall.md) D1, D9, D10; [0067](0067-tenant-x-extension-layer-over-module-entity-types.md) D1 and Boundary; [0068](0068-per-tenant-print-template-overrides.md) (layout of a slice-0 record); [0003](0003-ecto-schema-strategy.md); `docs/agents/instructions/security-invariants.md`.
- `lib/letflow/definitions/solution_pack.ex`, `lib/letflow/definitions.ex`, `lib/letflow/definitions/solution_pack_install.ex`, `lib/letflow/definitions/solution_pack_artefact_base.ex`, `lib/letflow/definitions/pack_update_resolution.ex`, `lib/letflow/definitions/process_definition.ex`, `lib/letflow/routers/solution_packs.ex`.

### What main already has

- **Pack name and version.** `export/4` in `lib/letflow/definitions/solution_pack.ex` writes `version: pack_version(version)`; `pack_version/1` returns the string when it is a non-empty binary and otherwise `@default_pack_version`, `"1.0.0"`. The version is free text: nothing checks semver. `pack_id` is a fresh `Ecto.UUID.generate()` per export.
- **Install record.** `solution_pack_installs` (`lib/letflow/definitions/solution_pack_install.ex`): `tenant_id`, `pack_id`, `installed_version` (string, max 255), `status` (`active | uninstalled`), `installed_at`, `uninstalled_at`. One active row per `(tenant_id, pack_id)` (`uq_solution_pack_install_active`).
- **Base.** `solution_pack_artefact_bases` (`solution_pack_artefact_base.ex`): `(tenant_id, pack_id, artefact_type, artefact_id)`, `base_version`, `base_content` (canonical JSON text), `captured_at`. Insert-if-absent at install.
- **Resolutions.** `pack_update_resolutions` (`pack_update_resolution.ex`): per `(tenant_id, pack_id, target_version, artefact_type, artefact_id)`, `resolution` (`keep_local | take_incoming | merged`), `resolved_content`, `resolved_by`, `resolved_at`.
- **Where these tables live.** Fact read in the code, and it matters for D6: all three tables are GLOBAL, in the public schema with a `tenant_id` column, not under a per-tenant `:prefix` (moduledocs of `solution_pack_install.ex` and `solution_pack_artefact_base.ex`, "GLOBAL, not tenant-scoped"; the moduledoc itself marks the general rule as an open question).
- **Plan.** `Letflow.Definitions.compute_pack_update_plan/5` (`lib/letflow/definitions.ex`) compares base, theirs and incoming by byte equality of canonical JSON and classifies each artefact through `classify_artefact/3`: `unchanged`, `clean_update`, `local_only`, `conflict`; a nil base is always `conflict`.
- **Apply.** `apply_pack_update/6` (`solution_pack.ex`) runs in one transaction, records the resolutions and refuses `{:unresolved_conflict, type, id}`.
- **Routes.** `lib/letflow/routers/solution_packs.ex`: `POST /:pack_id/update-review` (`:DefinitionsRead`) and `POST /:pack_id/update-apply` (`:DefinitionsCreate`), both flagged in the router comments as reusing the closest permission for REVIEWER.
- **Process definitions.** `process_definitions` (`process_definition.ex`) carries `name`, `version` (string), `status`, `graph`, and the owner stamps `owner_module`, `owner_module_version`, `owner_manifest_hash`, `owner_body_hash`.
- **Sections.** A pack document has the sections `definitions`, `variable_schemas`, `entity_definitions`, `service_catalog_entries` (the last unsupported: `check_unsupported_sections/1`) and `manifest`.

## What "solution versioning" means here

A tenant's solution is the set of installed packs and modules, each at a version, **plus the tenant's own deviations from them**. A pack version and a module semver (0055 D1) each name what the vendor shipped; neither names the tenant's deviation, which today exists only as an edited definition that the next 3-way comparison finds as `local_only` or `conflict`. This record makes the deviation a **named, listable, versioned object (an override)**, pinned to the pack version it was made against, so that an update can say what it will keep, what it must re-check and what it cannot apply, before it changes anything. Per D2 to D4 the table below states what each decision adds and what it leaves unchanged.

| | Adds | Leaves unchanged |
|---|---|---|
| D2 | An override record per overridden artefact, stored apart from the installed definition, with a closed list of overridable properties. | The pack section set (closed); the installed definition row; `solution_pack_artefact_bases` meaning (what the pack last delivered). |
| D3 | Override version, pin to the pack version, behaviour at update, interplay with instances. | Process definition `version` as the unit of activation (0055 D1); running instances keep their pinned definition. |
| D4 | Override report and refusal rules inside the plan; a pre-update override check. | `compute_pack_update_plan/5`, `classify_artefact/3` truth table and `apply_pack_update/6` stay the single update path; the two routes keep their paths and replies for tenants that have no override. |

## Decisions

### D1. What a pack version is

**Decision.** (1) **Format.** Not settled by the source: 0055 D1 requires strict semver of the *module* manifest only, and `pack_version/1` accepts any non-empty string. Recommendation (Q1): strict semver for any pack **exported after the first code slice** (a new export refusing a non-semver version), while an already installed `installed_version` is read as an opaque string and never rewritten. No migration of existing rows. (2) **Pack versus module.** A module wraps a pack (0039); the module version (0055 D1) is the unit of upgrade a tenant sees, the pack version names the pack content inside it. Both are recorded; the module manifest declares which pack version it ships, and a module upgrade applies its pack through D4. They need not be equal. (3) **Incoming version not greater than installed.** Ordering is defined only for two semver strings. For two semver strings: an incoming version equal to `installed_version` is a no-op review (the plan is returned, apply refuses with a stable code `version_not_newer`); an incoming lower version is refused (`version_downgrade`; rollback is D4). If either string is not semver, ordering is **not settled by the source**: the review route answers the plan but apply refuses until the owner picks (Q1), the safe default.

**Reasons.** Comparing free text for order is a guess; refusing a downgrade silently keeps D4 simple and keeps rollback a decision of its own.

**Source.** `solution_pack.ex` (`pack_version/1`, `@default_pack_version`); `solution_pack_install.ex`; 0055 D1; 0039.

### D2. What an override is, and what it may change

**Decision.** An override is a **stored layer kept apart from the installed definition and merged over it**; the present model of "edit the definition, then diff against base" stays readable (D7) but is not how a new deviation is made. Chosen over keeping edits-plus-base only, because only a separate layer lets an update tell "the tenant chose this" from "the tenant's copy drifted", and lets the tenant revert by removing the override.

*Pack level.* The override layer covers the artefact types `process_definition` and `variable_schema`. `entity_definition` artefacts are **excluded** from this layer: field and validation additions on module entity types belong to the `x_` layer of 0067, and tenant-owned entity types are out of scope (see Boundary). The section set stays closed: no new pack section, `service_catalog_entries` stays unsupported (0026, 0027, 0029 unchanged, 0039 relationship).

*Process-definition level.* May be overridden: step assignment (assignee role or rule reference), numeric thresholds referenced by gateway conditions, step and form labels, deadlines/timer durations. May **not** be overridden: graph structure (nodes, edges, node ids), gateway condition expressions, variable names and types, anything another artefact references by id, and any script. Which exact properties of the `graph` map are overridable is a closed list in the implementing slice; a property not on the list is refused. Whether a threshold override may be expressed against a module-declared `settings_schema` key (0039 D7, first sentence) rather than a graph property is not settled by the source (Q3), recommendation: yes where the module declares the setting, since that is already the normal path.

*Shape.* One row per `(artefact_type, artefact_id)` of an install: `pack_id`, the pinned pack version (D3), an override version, `patch` (a map of overridable property paths to values, not a copy of the definition), `patch_hash`, status. Merge: effective definition = installed definition with `patch` applied over the closed property list. Absence of a row means no override.

**Reasons.** A patch of named properties is small, diffable and cannot change structure; a full copy would be the present edited-definition model under another name.

**Source.** Roadmap row; REQ-562 D2; `solution_pack.ex`; `process_definition.ex`; 0039; 0067 D1.

### D3. Versioning of the override

**Decision.** An override carries its own monotone `override_version` per `(install, artefact)` and the `pack_version` it was made against (`made_against`). Edits create a new version; the previous stays as history, never deleted. At pack update:

- Override on an artefact the incoming pack leaves **unchanged** (base equals incoming): **kept**, `made_against` advanced to the new version by the apply (audited).
- Artefact **changed** by the incoming pack (`clean_update`/`conflict` in the sense of D4) and the override touches a property the change also touches: **re-checked**, reported as `override_conflict` in the plan and settled by a recorded resolution as today (`keep_local` = keep the override, `take_incoming` = retire it, `merged` = new override version). Where the change touches other properties: kept, with the warning `override_kept_pack_changed`.
- Artefact **removed** in the incoming pack: override is not applied, reported `override_orphaned`, status `orphaned`, never deleted.
- An override property no longer on the closed list of the incoming version: reported `override_property_gone`, same handling as orphaned.

An update **never overwrites or deletes an override**: the only transitions are keep, advance `made_against`, retire by an explicit `take_incoming` resolution, or orphan.

*Process definition version.* The process definition `version` stays the unit of activation and pinning (0055 D1). Applying an effective definition (installed plus override) creates a new process definition version through the existing definitions path; **running instances stay pinned to the version they started on** and are not changed by an override or an update. Whether a new override takes effect on a *new* version only or may re-activate in place is decided by the existing activation rules and not changed here.

**Reasons.** A named pin lets the plan say what it cannot keep, instead of discovering it after the write; "never overwrites" is the tenant-facing promise that makes updates safe.

**Source.** 0055 D1, D9; `solution_pack.ex` (`apply_pack_update/6`); `definitions.ex` (`classify_artefact/3`).

### D4. Update and rollback

**Decision.** `compute_pack_update_plan/5` and `apply_pack_update/6` **remain the single update path**; no second path is added. They gain: (a) per entry an `override` field (version, `made_against`, outcome among kept, re-check, orphaned, property gone); (b) the refusal rules of D1 (`version_not_newer`, `version_downgrade`); (c) the rule that an unresolved `override_conflict` blocks apply exactly as an unresolved `conflict` does today. The `classify_artefact/3` truth table is **not changed**: the classification runs on installed content as now, and the override is read next to it. Both routes keep their paths and, for an install with no override, their present replies.

*Rollback.* **Excluded from this record and from the first code slices.** Reason: a rollback of a pack must also roll back the effective process definitions, base rows and resolutions; 0055 D9 settles rollback for the module version only, with a journal and per-step `down`, and nothing in the sources gives the pack the same journal. Not settled by the source whether the owner wants it; recommendation (Q2): decide it together with the module-upgrade slice that implements 0055 D9, since a module rollback already re-activates previous definition rows (0055 D9) and a pack rollback would only duplicate it. Until then, a tenant returns to the vendor definition by retiring the override.

**Reasons.** One update path keeps the conflict machinery and its tests single; adding a rollback without a journal would repeat what 0055 D9 had to build.

**Source.** `definitions.ex`, `solution_pack.ex`, `routers/solution_packs.ex`; 0055 D9, D10.

### D5. Authority and audit

**Decision.** One new tenant-scope permission for managing overrides, atom chosen by the implementing requirement, proposed `SolutionOverridesManage` (a proposal; it does not exist in code), classified TENANT-scope (INV-10, 0046; an unclassified permission fails the build), granted to TENANT_ADMIN only, no new role, `docs/roles.md` updated by the slice. Listing overrides and the report in the plan need `:DefinitionsRead`. The two existing update routes keep `:DefinitionsRead` and `:DefinitionsCreate`; applying an update that resolves an override conflict additionally needs the new permission. Whether the two existing routes' permissions should be corrected is a question for the owner (Q4); it is not changed here.

*Audit.* Every create, new version, retire and orphan of an override, and every `made_against` advance, writes a hash-chain entry in the same transaction as the change (the 0055 D10 shape, `Audit.append_multi/4`); payload: pack id, artefact type and id, override version, `patch_hash`, actor, reason, **never the patch values** (a value may be a restricted threshold). Rationale mandatory.

*INV-2.* An override response returns property paths and values only to a caller who may read the underlying artefact; a property whose value is under a field restriction or a secret reference is returned as the reference or redacted (INV-4). The slice states, per route, which fields a read returns.

**Reasons.** Overrides change how a business process runs, so the tenant's top administrative role holds them; the chain records who changed what without copying values.

**Source.** `routers/solution_packs.ex` comments; 0046; 0055 D10; INV-2, INV-4, INV-10.

### D6. Tenant isolation

**Decision.** Override rows live in a **new table in the tenant schema** under the Ecto `:prefix` (0003, INV-1), with `tenant_id` kept in each row. This differs deliberately from the three existing pack tables, which are global (see "What main already has"): this record does not move them and does not decide the general global-versus-tenant rule their moduledocs leave open. A join between an override row and a global base/install row is made by `(tenant_id, pack_id)` taken from the auth context. Every route of the code slices takes the tenant from the auth context and never from the path, query or body. The migration is added to the tenant-provisioning list so new tenants get the table (as 0055 D1 requires of its tables). The first code slice carries the cross-tenant negative test (INV-10): a user of tenant B cannot read, create or change tenant A's override and gets the same not-found as for an absent id (INV-5), same status, headers and body. SECURITY-REVIEWER verdict is mandatory for that slice and every other (D8).

**Reasons.** A tenant's deviation is tenant data; putting it in a global table would rely on a `tenant_id` filter alone.

**Source.** INV-1, INV-5, INV-10; 0003; `solution_pack_install.ex` moduledoc.

### D7. Existing tenants

**Decision.** Installs made before the change keep their rows in `solution_pack_installs`, `solution_pack_artefact_bases` and `pack_update_resolutions` untouched: **no data is deleted, rewritten or backfilled**. No override rows are created automatically; a tenant with an edited definition (a `local_only` or `conflict` today) keeps it as is, visible through the existing review route exactly as now. The existing `update-review` and `update-apply` routes answer as before until a tenant creates its first override (opt-in is the first override row); with no override, `override` fields are absent or empty and the refusals of D1 apply only to pack versions that are both semver. A tool that turns an existing edit into an override ("adopt local edit") is an optional later slice (D8, S6), because deciding which edited properties are on the closed list needs the tenant's input. Already deployed QA tenants need no data step: a new table and nullable additions only.

**Reasons.** The promise is no tenant-visible change without opt-in.

**Source.** `solution_pack_installs`, `solution_pack_artefact_bases`, `pack_update_resolutions` schema modules; 0055 D1.

### D8. Slice plan

Not filed or built by this record. Common: each slice is sized to one change, `depends_on` includes REQ-562 and this record's accepted state (both REVIEWER and SECURITY-REVIEWER signed), and **SECURITY-REVIEWER is a mandatory gate for every slice that adds a route or a table** (S2, S3, S5; S4 and S6 as they touch tenant data). REQ ids are assigned by the BA after sign-off.

- **S1 Pack version rules.** Semver check at export, `version_not_newer`/`version_downgrade` in the review/apply path (D1, per Q1). No table, no route change beyond new refusal codes. Tests: S1-semver, S1-downgrade, S1-nonsemver-installed-unchanged. Depends on Q1.
- **S2 Override storage and management API.** Table in the tenant schema, tenant-provisioning list, closed property list for `process_definition` and `variable_schema`, create/new-version/retire/list routes, the permission, audit. Tests: C-manage (cross-tenant negative, D6), S2-closed-list (structure change refused), S2-immutable-history, S2-audit-no-values, route-inventory pins (`__authz_routes__`, route_scope snapshot, `tenant_wide_default_routes.txt`) whose new values that slice's design states.
- **S3 Effective definition and activation.** Merge of installed plus patch into a new process definition version; running instances stay pinned. Tests: S3-merge, S3-running-instance-unchanged.
- **S4 Plan and apply read overrides.** `override` in `compute_pack_update_plan/5`, `override_conflict` blocking apply, kept/advance/orphan rules (D3, D4). Tests: S4-keep, S4-conflict-resolved, S4-never-overwrites, S4-orphan, S4-no-override-unchanged (replies equal to today for an install without overrides).
- **S5 Web screen** (FRONTEND-DEV). List and edit overrides, show the update report. After S2 and S4.
- **S6 Adopt local edit** (optional). Turns an existing `local_only` edit into an override.
- **Deferred, not a slice here:** pack rollback (Q2).

## Boundary

This record owns **versioning and overrides at pack and process-definition level**. Excluded:

- The **field- and validation-level `x_` layer on module entity types**: owned by REQ-550 and its record [0067](0067-tenant-x-extension-layer-over-module-entity-types.md). `entity_definition` artefacts therefore take no override here (D2).
- **List, form and print-template overrides of module entity types**: split between REQ-550 (by 0067 D1, "Override kinds split": anything that changes which data a record holds or how a write is validated belongs to the `x_` layer; anything that only changes presentation belongs to the separate roadmap item "per-tenant form, list and print-template overrides", print templates REQ-564, record [0068](0068-per-tenant-print-template-overrides.md)) and that roadmap item. This record owns neither and states no rule on which side owns a field, validation, list, form or print template of a module entity type other than this deferral to 0067 D1.
- Client scripts (0039 D7 and 0053), tenant-owned entity types, module uninstall, generic list, pivot and graph views.

## Open points

1. **Q1 Pack version format** (D1). Options: (a) strict semver for packs exported after S1, installed values read as opaque; (b) semver only for packs wrapped by a module; (c) unchanged. Recommendation: (a). The source does not settle it.
2. **Q2 Pack rollback** (D4). Options: (a) excluded, decided with the 0055 D9 implementation slice; (b) a later pack-level slice with its own journal; (c) in S4. Recommendation: (a).
3. **Q3 Threshold overrides versus module `settings_schema`** (D2). Options: (a) a threshold override is allowed only where the module declares a setting; (b) any property on the closed list. Recommendation: (a).
4. **Q4 Permissions of the two existing update routes** (D5). Options: leave `:DefinitionsRead`/`:DefinitionsCreate` (recommended, this record), or move to the new permission. The source (router comment, "Flagged for REVIEWER") does not settle it.
5. **Q5 Closed property list for process-definition overrides** (D2): the list in the text is a proposal; the final list is the S2 design's, reviewed by SECURITY-REVIEWER.

## Tests the implementation slices must add

S1-semver, S1-downgrade, S1-nonsemver-installed-unchanged, C-manage, S2-closed-list, S2-immutable-history, S2-audit-no-values, S3-merge, S3-running-instance-unchanged, S4-keep, S4-conflict-resolved, S4-never-overwrites, S4-orphan, S4-no-override-unchanged (placement in D8).

## Threats for SECURITY-REVIEWER

- Cross-tenant read or change of an override, and a join between tenant-schema overrides and global pack tables keyed wrongly (D6; INV-1, INV-5, INV-10).
- An override that changes graph structure, a gateway expression or a script (D2).
- Override values in audit payloads or responses, restricted or secret values (D5; INV-2, INV-4).
- An update that overwrites, drops or silently re-points an override (D3, D4).
- Privilege: apply of an update resolving an override conflict without the new permission (D5).

## Sign-off

- SECURITY-REVIEWER: pending, not yet reviewed (content of D2, D5, D6).
- REVIEWER: pending, not yet reviewed.
