# 0067 -- Tenant `x_` extension layer over module entity types: tenant additions are stored apart from the module definition, merged over it at validation, and never touched by a module upgrade

Status: PROPOSED by the developer of GH #3174 (REQ-550 slice 0, task T-0496), 2026-10-25. Needs SECURITY-REVIEWER and REVIEWER sign-off (see Sign-off). Changes no code: every implementation slice is its own requirement (see "Expected implementation requirements").

Date: 2026-10-25

Requirement: REQ-550 (GH #3174).

Builds on: [0055](0055-module-upgrade-migration-uninstall.md) D4 (the tenant `x_` extension layer, "DIRECTION only, constraints on upgrade"). This record is **candidate (b)** ("tenant extensions to standard module entities") of [0053](0053-tenant-scripted-rules.md), "Requirement candidates".

Settles: the sentence in 0055, section "Scope: binding vs direction": **"storage, merge point and merge rules are NOT decided here"** (full text: "D4 is reduced to the constraints an upgrade must honour; storage, merge point and merge rules are NOT decided here and the `x_` rules bind only when candidate (b) lands"), and the last bullet of 0055 D4, "Tenant-side enforcement that tenant additions are `x_` belongs to candidate (b)". This record settles that part of D4 only.

Does not amend: 0055. D4 stays as written; its four constraints are repeated below as binding on this layer (R0).

Depends on: [0050](0050-foundation-modules-org-catalog-and-reference-contract.md) (D6, D7, `managed_by`); [0051](0051-org-scoped-role-grants-and-enforcement.md) (scope declarations); 0053 (D5, hooks); 0055 (D3 tripwire and key-level writes, D4); [0065](0065-entity-pre-write-script-hook.md) (D5, restriction-filtered candidate).

## Sources

Opened for this record (all on `origin/main` at 2026-10-25):

- `docs/requirements.yaml`, REQ-550 (read in full).
- `docs/migration/decisions/0055-module-upgrade-migration-uninstall.md`: "Scope: binding vs direction", D3 (key-level atomic writes, tripwire, allow-list `touches`), D4, AC5, AC16.
- `docs/migration/decisions/0053-tenant-scripted-rules.md`: candidate (b), "Storage is not the gap", D5.
- `docs/migration/decisions/0065-entity-pre-write-script-hook.md`, D5.
- `docs/migration/decisions/0066-module-uninstall-soft-uninstall-and-reactivate.md` (format and the status column pattern). Note: `origin/main` holds two records numbered 0066 (this one and `0066-generic-saved-views-over-records.md`); not fixed here.
- `docs/roles.md` (permission table row `EntitiesDefinitionsWrite`, row `EntitiesRestrictionsManage`); `docs/agents/instructions/security-invariants.md` (INV-1, INV-2, INV-5, INV-7, INV-8).
- `lib/letflow/entities/definition.ex` (`field_type()`, `field_def`, `append_only`, `decimal_strict`), `lib/letflow/entities/entity_definition.ex` (`managed_by`), `lib/letflow/entities/process_writable.ex` (`classes/0`), `lib/letflow/entities/definitions.ex` (`get_active_definition_by_name/2`, `strict_specs/2`).
- `lib/letflow/entities/records.ex` (`validate_field_values/4`, `definition_document/1`, `update_record/3`, `merge_preserved/3`, `validate_merged/5`, `fetch_active_definition/2`), `lib/letflow/entities/record/validator.ex` (`build_record_schema/1`, `normalize_record_payload/2`; the schema has `additionalProperties: false`), `lib/letflow/entities/record/size_cap.ex`.
- `lib/letflow/entities/query/allowlist.ex`, `lib/letflow/entities/query/field_grants.ex`, `lib/letflow/entities/type_access.ex`, `lib/letflow/entities/scope_declaration.ex`, `lib/letflow/scripts/policy.ex`, `lib/letflow/routers/entities.ex` (`render_get_definition/3`), `lib/letflow/routers/entities/record_writes.ex`, `lib/letflow/routers/entities/record_import.ex`, `lib/letflow/entities/import_upsert.ex`.
- `lib/letflow/entities/definition/ddl.ex` (`promoted_columns/1`), `lib/letflow/tenant_provisioning.ex` (DDL from the module document), `lib/letflow/modules/catalog.ex` (`validate/1`), `lib/letflow/api/authorization.ex`.
- `lib/letflow/modules/exam/certificate_document.ex`, `lib/letflow/documents/document_type.ex` (print forms are code).

## R0. The rule of the layer

**A module upgrade never overwrites, reorders or deletes anything in the tenant layer.**

- The upgrade runner has no write path to the layer: the layer's table is not in any step's `touches` allow-list, and the runner and its writer live outside the layer's context module (0055 D3, AC27).
- The tripwire of 0055 D3 (the allow-list of tables checked with `pg_stat_xact_user_tables`) aborts any batch or cutover that writes to the layer. 0055 D3 already names "the extension rows of D4 once they exist" as protected; the layer's table of D2 is that table.
- Extension rows are byte-identical before and after any upgrade (0055 AC5).

The four constraints of 0055 D4, repeated here as **BINDING** on this layer:

1. Tenant additions live **outside** the module's `entity_definitions` row (D2).
2. `x_` applies to **field and validation keys**, not to entity-type names (0050 D6 owns the type-name prefix rule). Modules may not use `x_`-prefixed field or validation keys; that is a `Catalog.validate/1` rule. At the time of this record `grep -n "x_" lib/letflow/modules/catalog.ex` finds nothing: the rule is **NOT BUILT** and is part of requirement I6.
3. An upgrade whose new module version defines a key equal to an extension key **fails the plan** with exactly `{:error, {:extension_conflict, entity_type, name}}`.
4. A new module constraint that an existing extension contradicts, and a retired module field that an extension references, are **WARNINGS**, not failures.

## D1. Scope of the layer

**Decision.** The layer adds fields and field-level validations to module entity types. It carries nothing that only changes presentation.

**Which types.** Only a type with `managed_by` set (module-owned, 0050 D7) and `status: :active`. Tenant-owned types are out: they have their own roadmap bullet and a tenant edits its own definition. One rule in two steps:

- Step 1, **always excluded** (no catalog flag can include them): a type with `append_only: true` (`Definition.t()`) and a type whose write class is not tenant-writable (`ProcessWritable.classes/0`). Reasons: an append-only ledger can never correct a value, so a mistyped x_ value would be unfixable and retired keys could not be carried forward (D3); a non-tenant-writable class is written only by module code or the process engine, so the tenant could never fill an x_ field and the layer would have no meaning.
- Step 2: every other module type is extensible unless its module catalog entry says `extensible: false` (opt-OUT). The choice between opt-OUT and opt-IN is open point OP-1. Step 1 does not depend on OP-1.

**What a tenant adds.**

- Extra fields: key `x_<snake_case>`, type from `Definition.field_type()` except `:json`, `:localized_text` and `:decimal` in slice 1, with `required`, `default`, `enum_values`, `min`/`max`/`non_negative`. `:decimal` is excluded because `decimal_strict` is a module-definition flag read by `Definitions.strict_specs/2`, which does not merge; with no decimal x_ field, no x_ field can be strict.
- Extra validations: restricted to what the definition document can express today, the per-field bounds above on x_ fields. `unique` constraints (the only `constraint_def` type) over x_ fields need a promoted column and an index and are not in slice 1 (D2, promotion).
- Tightening a **module** field's bounds from the tenant layer is **not settled by the source**: OP-2.

**Override kinds split.** The rule: **anything that changes which data a record can hold or how a write is validated belongs to this layer; anything that only changes how stored data is presented (form layout, list columns and order, print template, label) belongs to the separate roadmap item "per-tenant form, list and print-template overrides"** (print templates: REQ-564; labels: REQ-551). The only coupling: that item may show an x_ field because this layer makes it a field of the effective definition (D2, definition read); it never adds fields. KZ print forms are module code (`lib/letflow/modules/exam/certificate_document.ex`, `lib/letflow/documents/document_type.ex`), not definition-driven, so they belong to the presentation item; the open question in REQ-550 about their owner is thereby derived from the sources, not left to the owner.

Sources: REQ-550 D1; 0053 candidate (b); 0050 D7; the code files named above.

## D2. Storage and merge point

**Storage.** One new table `entity_type_extensions` in each tenant schema, read and written only under the tenant's Ecto `:prefix`, exactly like `entity_definitions` (`Definitions.get_active_definition_by_name/2` queries with `tenant_id` and `Repo.one(query, prefix: prefix)`), with `tenant_id` in **every row** (INV-1: both the schema and the column). Columns: `id`, `tenant_id`, `entity_type` (text, identifier format of ISS-0777), `kind` (`field`), `name` (`x_...`), `spec` (jsonb, the `field_def` shape), `position` (integer, ascending creation order), `status` (`active` or `retired`), `inserted_at`, `updated_at`. Unique `(tenant_id, entity_type, name)`; check constraint `name LIKE 'x\_%'`. It is not a row of `entity_definitions` (0055 D4 bullet 1; that table's partial unique index makes a same-name second row impossible). The migration and the tenant provisioning list entry are an implementation slice (I1).

**Promotion.** An x_ field is **not** promoted to a column in the first release; it lives only in the `field_values` JSONB blob (0053, "Storage is not the gap"). Reasons: promotion is driven by `Definition.Ddl.promoted_columns/1` from the module definition at activation and an upgrade replaces that definition; a tenant-owned column on a module table would be a second writer to module DDL, contradicting R0. Consequence: x_ fields are not filterable or sortable through the query engine until a later record adds promoted extension columns (OP-3).

**Merge.** One function (named here, built later): `effective definition = module definition document ++ active extension fields in position order`, computed from the active definition row and the tenant's extension rows in one read per call.

**Merge call sites** (each file opened by the author; `grep -rn get_active_definition_by_name lib/letflow` re-run on `origin/main`, hits under `lib/letflow/design/` ignored):

1. `lib/letflow/entities/records.ex`: `validate_field_values/4` -> `definition_document/1`, the single write-validation point for `create_record`, `update_record`, `upsert_record_by_external_ref`, and therefore for `lib/letflow/routers/entities/record_writes.ex` and `lib/letflow/routers/entities/record_import.ex`. The definition is resolved by `fetch_active_definition/2` in the same file (hit at `records.ex:2025`); that is where the merged definition is produced for sites 1 and 6.
2. `lib/letflow/entities/record/validator.ex`: `build_record_schema/1` and `normalize_record_payload/2` take the merged document (no signature change; the document just carries more fields).
3. `lib/letflow/entities/query/allowlist.ex`: `fetch_active_definition/2` (the field allow-list of the query engine): x_ fields are allowed in projections; filter and sort on an x_ field are refused until OP-3.
4. `lib/letflow/routers/entities.ex`: `render_get_definition/3` (`GET /entities/definitions/active/:name`): the response carries the module definition unchanged plus a separate `extensions` array, each row with its `status`, so a form generator renders both and a consumer can tell module fields from tenant fields and live keys from retired ones.
5. `lib/letflow/scripts/policy.ex`: the definition checks (the `field_name_codes/2` path, `from_pair_known?/2`, the `fields_known?/2` path), so a 0053 or 0065 script manifest may name an x_ field (D6).
6. `lib/letflow/entities/records.ex`, UPDATE path (`update_record/3`: `merge_preserved/3`, then `validate_merged/5`, then `validate_field_values/4` on the `merged` map): the second merge step of the layer, the retired-key carry-forward of D3. Create, upsert and import need no carry-forward (nothing is stored yet).

**Record read: no merge, deliberately.** `GET` record and query responses return the stored `field_values` as they are, redacted by key name through `FieldGrants` / `FieldPolicy` (INV-2: an x_ key is redacted exactly like a module key). Retired x_ values therefore stay visible to a caller who may read the type (a retired field is not secret, it is merely no longer validated or editable), and a client that sends them back on an update is tolerated by the carry-forward of D3. Reason: a read-side filter would put the extension read into every list and query response for no authorisation gain. What the read surface needs is the definition answer (site 4). The owner may prefer to hide retired values: OP-8.

**Deliberately NOT merge sites**, each with its reason:

- `lib/letflow/entities/definitions.ex` lines 384 (`strict_specs/2`), 642 (`decimal_strict_in_play?/2`), 669 (`ensure_strictness_unchanged/2`): decimal-strict flag checks on the module definition JSON; no x_ field is strict.
- `lib/letflow/entities/handler_writes.ex` 428 (`managed_by?/3`), `lib/letflow/entities/step_writes.ex` 219 and 420, `lib/letflow/entities/scoped_writes.ex` 107 and 126, `lib/letflow/entities/script_reads.ex` 113, `lib/letflow/entities/record_access.ex` 47: presence, class, managed-by and scope checks that validate no field values. Writes by handlers and steps go on to `Records.create_record` / `update_record`, that is through sites 1 and 6.
- `lib/letflow/entities/record/projector.ex` 351 (`write_entity_table_snapshots/4`): replays stored events, validates nothing, only promoted columns, and x_ is never promoted.
- `lib/letflow/modules/exam/authoring.ex` 60, `lib/letflow/modules/exam/snapshot.ex` 595, `lib/letflow/modules/exam/snapshot/rollout.ex` 215 and 225: module-internal checks of one named module type (`session`) for module-declared fields.
- `lib/letflow/number_sequences.ex` 115 (`check_bindable/2`): `managed_by` and `append_only` refusal only.
- `lib/letflow/tenant_provisioning.ex` 2087: builds DDL and promoted columns from the MODULE document; it must not merge, because an x_ field is never promoted (R0).
- `lib/letflow/entities/query/allowlist.ex` 430 and `lib/letflow/scripts/policy.ex` 199, 208, 876 are merge sites 3 and 5; `lib/letflow/routers/entities.ex` 993 is site 4.

The implementing slice adds a source-scan test listing these call sites, so a new `get_active_definition_by_name` caller must classify itself.

Sources: REQ-550 D2; 0053 "Storage is not the gap"; the files above.

## D3. Merge rules

**Precedence.** The module wins; the layer only **adds** keys. The write path (D4) and the 0055 plan (R0) both refuse equal keys, so there is nothing to override.

**A tenant validation only adds a constraint and never relaxes a module one.** Because slice 1 validates only x_ fields, relaxation is structurally impossible; tightening module fields is OP-2.

**Ordering.** Module fields first in module order, then extension fields by `position` ascending. The layer never changes module order; reordering extension rows changes `position` only.

**Required.** An x_ field with `required: true` must carry a `default`, applied at write time only. No backfill of stored records (a mass rewrite would be a 0055-style migration the tenant cannot run). Stored records without the key stay readable; an UPDATE of such a record applies the default. Reason: INV-8 and no event storm. The validator does not apply a field `default` today (`Definition.field_def` has `optional(:default)`, `validator.ex` never applies it): applying it is new behaviour and is named in I3.

**How an update treats the layer.** Facts read in `records.ex` and `validator.ex`: `update_record/3` replaces the whole `field_values` map, the record schema has `additionalProperties: false`, and the whole merged map is validated again against the effective definition. So a key unknown to the effective definition fails with 422 `record_payload_invalid`, and a key left out of the body is deleted by the replacement. Two rules follow.

**Remove.** Removing an extension field marks its row `status: retired` (row kept, key reserved so the name cannot be reused with another type). A retired field is omitted from the effective definition. **Retired-key carry-forward** (call site 6, modelled on `merge_preserved/3` for restricted fields): on `update_record`, before schema validation, the layer (a) drops from the client body every key that names a retired row of the type, so a client that echoes a value it read is not refused; (b) sets aside the stored values of those keys and validates the rest against the effective definition; (c) puts the stored retired values back verbatim into the map that is stored. Stored values are therefore **never deleted by an update**, are not validated, are not editable through the API, and stay in events and replay. They count toward `Record.SizeCap` (measured on the stored map). Create, upsert and import carry nothing: a body with a retired key has it dropped as in (a). A purge of retired values is out of this record.

**Retype.** Not allowed in place. A type change is retire plus a new field with a new `x_` name; the tenant migrates values itself (record import and upsert exist: `record_import.ex`, `import_upsert.ex`). No source supports in-place conversion: **not settled by the source**, OP-4.

**Changing a live x_ field's constraints** (the type may not change). No stored record is re-validated or rewritten when the layer's definition changes. LOOSENING (wider bounds, extra `enum_values`, `required` true to false) never breaks an update. TIGHTENING (narrower bounds, removed `enum_values`, `required` false to true, which still needs a `default`) is allowed, and a record whose untouched x_ value no longer validates **fails its next update** with 422 `record_payload_invalid` naming the x_ path, until the value is corrected in the same update. There is no grandfather exception for x_ values (the only grandfather rule in the write path is `Record.SizeCap`'s, for size); an exception would compare each x_ value with the stored one inside the shared validator, a change this record does not make. **Not settled by the source**: OP-7. The layer does not scan for records that would no longer validate. "Existing records are grandfathered" is **not** stated.

Sources: REQ-550 D3; `records.ex`; `validator.ex`; 0055 D3 key-level writes.

## D4. Enforcement of `x_`

The layer's write path (a function in a new context module; the route is a later slice) refuses:

- (a) a key without the `x_` prefix: `{:error, {:extension_key_invalid, name}}`, mapped to 422 `invalid_extension_key`;
- (b) a key equal to a module-owned key of the type, that is present in the active module definition's `fields`: `{:error, {:extension_key_reserved, name}}`, mapped to 422 `extension_key_reserved`.

Plus a DB check constraint on `name` (belt and braces) and the ISS-0777 identifier format (INV-7). INV-5: a request naming a type the caller may not see (`TypeAccess.authorized?/3`), a type that is not module-owned, or a type that does not exist gets the one uniform `404`, never a 422 that reveals the type. The 0055 plan-time check is a different code path with the other error tuple (`extension_conflict`, R0) and is not reachable from a tenant request.

Sources: REQ-550 D4; 0055 D4 last bullet; `lib/letflow/entities/type_access.ex`.

## D5. Authority

A new permission `:EntitiesExtensionsManage` (tenant scope), held by TENANT_ADMIN (and PLATFORM_ADMIN within the platform tenant, as for every tenant-scope permission in `docs/roles.md`); **not** PROCESS_DESIGNER, who holds `EntitiesDefinitionsWrite` today. Reason: the layer changes what every user of a module's type must submit, a tenant-wide effect. Recommendation the owner may veto: OP-5. The implementing slice updates `docs/roles.md`, `lib/letflow/api/authorization.ex` and the role-matrix pins.

**INV-2 applies to x_ fields.** An x_ field is subject to the same field restrictions and per-type access as module fields, because both are keyed by `(entity_type, field name)`: `FieldGrants.load_restrictions/3`, `FieldPolicy` and `TypeAccess` read names, not definitions. A restriction row for `x_foo` works unchanged and redaction applies to the stored `field_values` key. Managing a restriction stays `EntitiesRestrictionsManage`'s business, not this permission's.

**0051 scope.** The layer adds no scope declaration and cannot change the type's `scope_declaration` (`lib/letflow/entities/scope_declaration.ex`); records stay in the module type's scope. **Audit:** every change of the layer writes an audit entry (actor, type, name, before and after).

Sources: REQ-550 D5; `docs/roles.md`; `security-invariants.md` INV-2; the files above.

## D6. Interaction with module upgrade and with scripts

- **Plan reports.** The upgrade plan lists per tenant each `extension_conflict` (failure) and the two warnings of R0, naming entity type and key. The plan reads the layer read-only.
- **Migration events.** `ENTITY_RECORD_MIGRATED` events (0055 D3) fire no 0053 or 0065 hooks, so an x_ field is never touched by migration; the rule "no step touches a key starting `x_`" (0055 D3, key-level atomic writes) stays binding.
- **Pre-write script.** An x_ field is visible to the pre-write script as part of the restriction-filtered record candidate (it is part of the validated `field_values`), under the same redaction rule (0065 D5). A script may **not** declare an x_ field as a derived field in slice 1 (derived fields are bound to module-declared fields). Not settled by the source: OP-6.

Sources: REQ-550 D6; 0055 D3, D4; 0053; 0065 D5.

## Boundary

This record owns the **field- and validation-level `x_` layer on module entity types**. Excluded:

- **Process-definition and pack-level versioning and per-tenant overrides**, owned by the requirement "Solution versioning and per-tenant overrides" (core roadmap Wave 3, row of that title). No REQ id is registered for it on `origin/main` at the time of writing (`grep -n "olution versioning"` on `origin/main:docs/requirements.yaml` finds only REQ-550's own text), so it is cited by title; the reviewer fills in the id when it exists (OP-9).
- **Form, list and print-template overrides**, the separate roadmap item (print templates: REQ-564), split from this layer by the rule in D1.
- Tenant-owned entity types, saved views, number sequences and module uninstall.

## Open points

Each is **not settled by the source**; options and a recommendation are given and nothing is decided silently beyond the recommendation.

| # | Point | Options | Recommendation |
|---|---|---|---|
| OP-1 | Which module types are extensible (0053 says "standard module entities", no per-type list) | opt-OUT (`extensible: false` to exclude) / opt-IN (`extensible: true` required) | opt-OUT: the roadmap promises extensions to module entities generally |
| OP-2 | Tightening a module field's validation from the tenant layer | none / tighten-only | tighten-only, in a later slice, not slice 1 |
| OP-3 | Promoted x_ columns, filter and sort on x_ fields, `unique` over x_ | not in v1 / separate table `entity_x_<type>` keyed by record id / columns on the module table | separate table, in its own record (a module-table column would be a second DDL writer) |
| OP-4 | Retyping an extension field | not allowed / in-place conversion | not allowed; retire plus new `x_` name |
| OP-5 | Permission for the layer | reuse `EntitiesDefinitionsWrite` (PROCESS_DESIGNER) / new `:EntitiesExtensionsManage` (TENANT_ADMIN) | new permission |
| OP-6 | A script declaring an x_ field as a derived field | not in slice 1 / allow | allow later: a tenant script on a tenant field is consistent |
| OP-7 | A record whose untouched x_ value no longer validates after tightening | fail its next update / skip validation of x_ values equal to the stored ones | fail the update: it surfaces bad data and costs no code in the shared validator |
| OP-8 | Retired x_ values on record read | visible, redacted by key name / hidden | visible (a retired field is not secret) |
| OP-9 | REQ id of the solution-versioning requirement | cite by title / cite by id once registered | cite by id when it exists |

## Expected implementation requirements

None is filed or built here; each `depends_on` this record.

- **I1** migration, schema and tenant-provisioning entry for `entity_type_extensions`, with a cross-tenant negative test.
- **I2** the layer's write path with the D4 refusals, `:EntitiesExtensionsManage`, the route and audit (security review mandatory; INV-10 cross-tenant negative test).
- **I3** the effective-definition merge into write validation (sites 1, 2 and 6), with the retired-key carry-forward, the tightening rule and application of an x_ field `default` at write time (new behaviour, D3 "Required").
- **I4** the read surface (definition `extensions`, query allow-list, script policy) including an INV-2 redaction test and the call-site source-scan test.
- **I5** the upgrade-plan check: `extension_conflict` and the two warnings (depends on the 0055 upgrade implementation).
- **I6** the catalog flag `extensible: false` and the `Catalog.validate/1` rule "modules may not use `x_` keys" (not built today, see R0).
- **I7** (later) promoted extension columns (OP-3).

## Consistency with earlier records

- 0055 D4 stays as written; its four constraints are binding here (R0). 0055 D3's tripwire and key-level write rule are used, not changed.
- 0050 D7: `managed_by` types keep generic writes refused for the module's own fields; extension values are written through the ordinary record write path under the tenant's own permissions, not through the layer's admin path.
- 0053 and 0065: hooks and derived fields are unchanged; D6 only states visibility.
- 0051: no scope declaration is added (D5).

## Not decided here

Any code, migration, route, UI or test; tenant-owned types; `unique` constraints and promoted x_ columns (OP-3); tightening module field bounds (OP-2); form, list and print-template overrides; solution and pack versioning; a purge of retired x_ values; the number of the solution-versioning requirement (OP-9).

## Threat cases for SECURITY-REVIEWER

1. Cross-tenant read or write of extension rows through a tenant id in the body, path or header (INV-1, INV-10).
2. A role without `:EntitiesExtensionsManage`, or a caller of tenant A, changing tenant B's layer (D5).
3. A distinguishable reply that reveals a module type the caller may not see (INV-5, D4).
4. An x_ value readable by a caller restricted from that key (INV-2, D5).
5. A tenant pre-creating `x_` names to block an upgrade: not possible, modules may not use `x_` (R0).
6. Identifier injection through an extension name or type (INV-7, D4).
7. An unbounded number of extension fields: a cap per type (for example 50) and the existing `Record.SizeCap` on the blob.
8. An upgrade batch writing to the layer: aborted by the tripwire (R0).

## Sign-off

- SECURITY-REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
- REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
