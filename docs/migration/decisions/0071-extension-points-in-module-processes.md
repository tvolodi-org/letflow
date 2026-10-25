# 0071 -- Extension points in module processes: a module version declares named sites, a tenant attaches a published script step to a site from the tenant schema, and the module's definition is never changed

Status: PROPOSED by the developer of GH #3232 (REQ-568 slice 0, task T-0542), 2026-10-25. Needs SECURITY-REVIEWER and REVIEWER sign-off (see Sign-off). Changes no code: every implementation slice is its own requirement (see D9).

Date: 2026-10-25

Requirement: REQ-568 (GH #3232).

Supersedes / amends: [0039](0039-platform-module-solution-layering.md) D7, paragraph "Client scripts are not in scope". Its last sentence is quoted here in one line: **"Extension points are a later decision once that registry exists."** [0053](0053-tenant-scripted-rules.md) D0 supersedes the client-scripts paragraph of 0039 D7 for client scripts (the registry is `script_rules`, 0053 D1) but decides nothing about extension points. This record is the decision that sentence deferred. No text of 0039, 0053, 0054 or 0055 is edited; where this record builds on one of them the relationship is stated per section.

Builds on: [0055](0055-module-upgrade-migration-uninstall.md) for upgrade survival (D4, D6, D8); [0053](0053-tenant-scripted-rules.md) D1, D2, D3, D6, D7, D11; [0054](0054-process-step-writes-entity.md) D1, D2, D12; [0065](0065-entity-pre-write-script-hook.md) D4 (a binding row in the tenant schema is the precedent).

Depends on: REQ-550 and its record [0067-tenant-x-extension-layer-over-module-entity-types.md](0067-tenant-x-extension-layer-over-module-entity-types.md) (three files share the number 0067, so it is always cited by full name); REQ-562 and its record [0069-solution-versioning-and-per-tenant-overrides.md](0069-solution-versioning-and-per-tenant-overrides.md). Both records are on main.

Other decisions touched: **0050, 0051**: unchanged. **REQ-045**: unchanged (no supervised process per workflow instance; see D3). **0039 D7 first sentence** (a tenant sets values a module declared and never edits the module's definitions in place): unchanged, this record applies it.

## Sources

Files and records opened for this record:

- `docs/migration/core-roadmap-20261014.md`, "Customization beyond scripts", bullet extension points in module processes.
- REQ-568 as registered in `docs/requirements.yaml` (read only).
- `docs/migration/decisions/0039-platform-module-solution-layering.md` D7.
- `docs/migration/decisions/0053-tenant-scripted-rules.md` D0, D1, D2, D3, D6, D7, D11.
- `docs/migration/decisions/0054-process-step-writes-entity.md` D1, D1a, D2, D12.
- `docs/migration/decisions/0055-module-upgrade-migration-uninstall.md` D2, D4, D5, D6, D8.
- `docs/migration/decisions/0065-entity-pre-write-script-hook.md` D4.
- `docs/migration/decisions/0067-tenant-x-extension-layer-over-module-entity-types.md` D1 "Override kinds split" and Boundary.
- `docs/migration/decisions/0069-solution-versioning-and-per-tenant-overrides.md` D2 and Boundary; also its layout and Sign-off wording.
- `docs/agents/instructions/security-invariants.md`.
- `lib/letflow/engine/service_task.ex`, `lib/letflow/engine/pin_resolver.ex`, `lib/letflow/engine/script_task_dispatcher.ex`, `lib/letflow/modules/module.ex`.

## What main already has (present state)

- **0039 D7.** A tenant sets values a module declared and never edits module definitions; the 3-way pack update is the fallback. The paragraph "Client scripts are not in scope" says declared extension points where a tenant attaches its own Lua need a runtime invocation path and an audit path, and ends with the sentence quoted in the header.
- **0053 D0.** Supersedes that paragraph for client scripts: the registry exists as `script_rules`.
- **0053 D1.** `script_rules` is a tenant-schema table with no `tenant_id`, with `key`, `version`, `source`, `manifest`, `hook_kind` and `status` (`draft | published | retired | revoked`).
- **0053 D2.** `route_kind :script` on a SERVICE_TASK graph node, config `script_key` and `script_version`; activation of a definition is refused unless the version is `published`. Runtime shape: the engine marks the task running and commits; the script runs under the Lua `Task.Supervisor` with no DB access; a new transaction applies the result, keyed `(instance, node, attempt)`. Output goes through `VariableMerge.merge`.
- **0053 D3.** A `:script` pin kind freezes `(key, version, sha256)` for a node `script_key` at `INSTANCE_STARTED`. It covers a node attribute only.
- **0054 D1.** An `entity_writes` attribute on HUMAN_TASK and SERVICE_TASK nodes (20-line cap); D2 puts the write behind `Letflow.Engine.EntityPort`, one behaviour; D12 lists what does not change.
- **0055 D4.** The tenant `x_` layer: an upgrade never writes, reorders or deletes it; a contradiction fails the plan or is a WARNING, as that section says. **D6**: a running instance keeps the definition version it started on. **D8**: an upgrade never touches tenant scripts, definitions or the `x_` layer (item 2), and the tenant id comes from auth only (item 7).
- **Code.** `lib/letflow/engine/service_task.ex` has `@type route_kind :: :inline_url | :catalog_service | :script`; `lib/letflow/engine/pin_resolver.ex` has `pin_for/3`; `lib/letflow/engine/script_task_dispatcher.ex` exists; `lib/letflow/modules/module.ex` has the `manifest/0` callback. `grep -rni extension_point lib` prints nothing: no extension-point concept exists on main.

## Decisions

Every sentence the sources do not settle says "not settled by the source" and is listed in Open points.

### D1. What an extension point is

**Decision.** An extension point is a named site that a module VERSION declares in its manifest against one of its own process definitions. A declaration has: `name` (stable, unique within the module version, key format as in 0053), `kind` (closed set; the first value is `script_step`), `site` (definition key, node id, position), `input` (the variables handed to the attachment) and `returns` (the variable names and types the attachment may return, a subset of what the module already declares). The module declares points; a tenant never creates one. The module's process-definition row and pack document are unchanged by an attachment.

**Reasons.** 0039 D7 first sentence: the module defines, the tenant configures. 0055 D4: tenant additions live outside the module's row.

**Not settled by the source:** the manifest field shape, whether names carry a module prefix, which check rejects a duplicate name or a site on an unknown node. Recommendation: validate at catalog time, with `Catalog.validate/1` carrying the point checks; the choice is OP-6.

**Sources.** 0039 D7; 0055 D4; 0053 D1 (key format).

### D2. What a tenant attaches, and how it runs

**Decision.** The kinds of attachment, chosen from what 0053 and 0054 already allow:

- (a) a script step: a script published in the tenant, bound as `(script_key, script_version)` with `hook_kind` `service_task` (0053 D1, D2);
- (b) an entity-write step (0054 D1): not in the first code slice;
- (c) a tenant task or notification step: no source allows it, not settled by the source (OP-1).

First code slice: (a) only. Run time, as far as 0053 D2 permits: the script has no DB access; its result is applied in a new transaction keyed `(instance, node, attempt)`; its output is validated against the script manifest AND the point's `returns` schema and merged through `VariableMerge.merge`; anything outside `returns` is refused. A failed attachment follows 0053 D7 (stable failure codes, instance ERROR plus DLQ incident, only `script_busy` retried). The module step is never rolled back by a tenant step, since it is already committed.

**Not settled by the source:**

- where the attachment runs relative to the site, before or after (OP-2; recommendation: after only in v1);
- how the engine finds an attachment (lookup by point name) and dispatches a step that is not a graph node carrying `route_kind :script` (OP-7, also OP-2; 0053 D2 covers a SERVICE_TASK node with `route_kind :script` in the graph, not a step injected after another node);
- whether a failed attachment should be non-blocking instead (OP-3; recommendation: keep the 0053 D7 behaviour in v1).

**Reasons.** The tenant script registry and its limits already exist (0053 D1, D7, D11) and are reviewed; a second runner would have to be reviewed again.

**Sources.** 0053 D1, D2, D7, D11; 0054 D1.

### D3. Where an attachment lives and what the engine touches

**Decision.** An attachment is a row in a tenant-schema table (proposed name `extension_point_attachments`), with no `tenant_id` column (0006 D2, as `script_rules` in 0053 D1). Fields: `point_name`, `module_id`, `kind`, `script_key`, `script_version`, `status` (`active | inactive`), attach and detach audit fields, and `manifest_point_hash` of the declaration it was made against. It is keyed by point name, apart from the module's definition row and pack document: an attachment changes neither the module definition row nor the pack document. In v1 there is one active attachment per point name (OP-4 for several). The table is read under the Ecto `:prefix` of the instance's tenant.

Engine files and modules a slice touches, with the paragraph that permits the change:

| File or module | Change | Permitting paragraph |
|---|---|---|
| `lib/letflow/engine/script_task_dispatcher.ex`, `lib/letflow/engine/service_task_dispatcher.ex` (lease, compare-and-set, incident on expiry) | reuse as they are for a script attachment | 0053 D2 runtime shape |
| `lib/letflow/engine/pin_resolver.ex`, `lib/letflow/engine/pin_rebind.ex` | pin an attachment | 0053 D3 allows a `:script` pin for a node `script_key` only; pinning an attachment is not permitted by 0053/0054: OP-5 |
| `lib/letflow/engine/service_task.ex` | a dispatch built from an attachment instead of a node attribute | not permitted by 0053/0054: OP-7 (0053 D2 permits the `:script` kind on a graph node only) |
| `lib/letflow/engine.ex` | the completion path finds attachments after a site | not permitted by 0053/0054: OP-7 and OP-2 (0053 D2 permits the second transaction for a script task; a lookup by point name is a new engine behaviour neither record names) |
| `lib/letflow/modules/module.ex`, `lib/letflow/modules/catalog.ex` | the manifest declares points; `Catalog.validate/1` checks them | not permitted by 0053/0054: OP-6 (0055 D4 is only a precedent for rejecting `x_` keys; it is not a 0053/0054 paragraph) |
| `lib/letflow/definitions/graph.ex` | activation check that a site names a known node | not permitted by 0053/0054: OP-6 (0053 D2 permits refusing activation only for an unpublished `script_key`) |

Anything not listed is not allowed. REQ-045 is unchanged: no supervised process per instance, Postgres row locks arbitrate concurrency, `Letflow.InstanceSupervisor` stays empty, and the runner is the existing Lua `Task.Supervisor` of 0053 D2.

**Reasons.** 0065 D4 binds a script to a hook through a row in the tenant schema; 0053 D1 is the precedent for the table shape.

**Sources.** 0053 D1, D2, D3; 0054 D2; 0065 D4; 0006 D2.

### D4. Survival of a module upgrade

**Decision.**

- **Same point name and kind after an upgrade:** the attachment is kept untouched. 0055 D4 says an upgrade never writes, reorders or deletes the tenant layer, and 0055 D8 item 2 says an upgrade never touches tenant scripts or definitions; this record extends that rule to attachment rows, and the tripwire of 0055 D5 aborts any step that writes them.
- **Refusals** (0055 D2 class C form `{:error, {:upgrade_forbidden, reason, subject}}`): an upgrade step that touches attachment rows (0055 D8 item 2); a module version in which two points share a name (the check that carries it is OP-6; recommendation `Catalog.validate/1`).
- **Warnings** (the plan lists them, no `ack_destructive`; the vocabulary of 0055 D4 "contradicts ... are WARNINGS"): a point with attachments is removed, renamed, or has its kind changed; its `input` or `returns` is narrowed so that the bound script no longer fits. The attachment becomes `inactive` and is listed to the tenant; it is never deleted by an upgrade. A rename is a remove plus an add with no automatic remap; the tenant re-attaches explicitly, as a new audited row. Whether a narrowed contract also disables is OP-8 (recommendation: inactive).
- **Running instances** (0055 D6): an instance keeps the definition version it started on. Whether an attachment is pinned at instance start is OP-5. Until OP-5 is decided, an inactive attachment is skipped and the skip is audited.
- **Tenant id** comes from auth only (0055 D8 item 7).

**Reasons.** The tenant's work must outlive the vendor's release; deleting it silently is the failure 0055 D4 exists to prevent.

**Sources.** 0055 D2, D4, D5, D6, D8.

### D5. Boundary against REQ-562 and REQ-550

**Decision.** A declared point is a vendor-declared contract of the module version; the tenant adds a step at a named site, and the definition stays as shipped. The attachment is addressed by point name, so it is not bound to one pack version and is not re-checked on each update, except for the name and kind (D4). An override of 0069-solution-versioning-and-per-tenant-overrides.md D2 changes properties of the installed definition through a stored patch pinned to the pack version; it may not add or change a script (0069 D2). An extension point cannot change or remove a module step, change the graph, or change a threshold. Fields and validations are owned by 0067-tenant-x-extension-layer-over-module-entity-types.md (D1 "Override kinds split"); extension points add no fields and no validations: a returned variable must already exist in the module's declared schema. For a given customisation the owner is the one that 0067 D1 and the 0069 Boundary name; this record only adds "tenant step at a declared site" and creates no second ownership rule.

**Reasons.** Two records owning the same customisation would let a pack update and an attachment contradict each other.

**Sources.** 0067-tenant-x-extension-layer-over-module-entity-types.md D1, Boundary; 0069-solution-versioning-and-per-tenant-overrides.md D2, Boundary.

### D6. Authority and audit

**Decision.** Recommendation (OP-9): attach and detach use the existing `DefinitionsWrite` permission, held by TENANT_ADMIN and PROCESS_DESIGNER in `priv/permission_matrix/effective.golden`, so the golden file and the auditor refused-set literal do not move. The script itself still needs `ScriptsPublish` by a person, with separation of duties as in 0053 D6; a module never activates or publishes a script (0053 D6). Audit events with stable codes: attach, detach, inactivation by an upgrade, and every skipped inactive attachment. Run results use the audit of 0053 D9.

**Not settled by the source:** which permission carries attach and detach (OP-9).

**Sources.** 0053 D6, D9.

### D7. Isolation and sandbox

**Decision.**

- **INV-1:** the attachment table is in the tenant schema under Ecto `:prefix`, with no `tenant_id` column (0006 D2, 0053 D1); the tenant comes from the auth context only (INV-1(c), 0055 D8 item 7). The module declaration is global and read-only to tenants.
- **INV-3:** an attached script runs only in the existing sandbox, with the limits of 0053 D7 and D11 and the host surface of 0053 D4, and no wider.
- **INV-10 and INV-5:** every slice that adds a route carries a cross-tenant negative test: tenant B cannot read, attach to, change or detach tenant A's attachment, and gets the same not-found as for an absent id.
- Each route slice also states the count pins it moves (route inventory, route-scope snapshot, `__authz_routes__`) in its own design; the numbers are not fixed here because they change with main.

**Sources.** `docs/agents/instructions/security-invariants.md` INV-1, INV-3, INV-5, INV-10; 0053 D4, D7, D11.

### D8. Existing tenants and modules

**Decision.** A module without points changes nothing. The attachment table is new and empty, so no existing row needs handling. The feature flag defaults off.

**Sources.** Project rule that new flags default off.

### D9. Code slices

None of these is filed or built; this record only lists them. Each has `depends_on` at least REQ-568, REQ-550 and REQ-562, and this record once accepted.

- **X1.** Manifest declaration, the point checks and the activation check for sites; no route. `depends_on`: OP-6 decided.
- **X2.** Attachment table, tenant routes and permission. `depends_on`: X1, OP-9. Table and route slice: SECURITY-REVIEWER gate.
- **X3.** Run-time dispatch of a script attachment. `depends_on`: X2, OP-2, OP-7. Run-time slice: SECURITY-REVIEWER gate.
- **X4.** Upgrade plan integration: warnings, inactive, list, tripwire. `depends_on`: X2, OP-8. SECURITY-REVIEWER gate.
- **X5.** Pinning of attachments, only if OP-5 is decided for it. `depends_on`: X3. SECURITY-REVIEWER gate.
- **X6.** Later: the entity-write attachment kind (0054 D1). `depends_on`: X3.

This record contains no implementation code.

## Open points

Each is not settled by the source.

- **OP-1. Kinds beyond a script step.** Options: script only; script plus entity-write; also tenant task or notification. Recommendation: script only in the first slice, entity-write second, no tenant task.
- **OP-2. Before or after the site.** Options: after only; before also. Recommendation: after only in v1, because before would make the engine hold a module step pending a tenant script.
- **OP-3. Failure of an attachment.** Options: blocking as 0053 D7 (instance ERROR plus DLQ); non-blocking (log and continue). Recommendation: keep 0053 D7 in v1.
- **OP-4. Several attachments per point and their order.** Options: one per point; several with an explicit order. Recommendation: one per point in v1.
- **OP-5. Pinning an attachment at instance start.** 0053 D3 covers a node `script_key` only. Options: pin `(point, key, version, sha256)` at `INSTANCE_STARTED`; read the active attachment at run time. Recommendation: pin, as for a node script, in a later slice (X5).
- **OP-6. Manifest shape, point-name prefix, point checks and the site activation check.** Options: checks in `Catalog.validate/1` and `graph.ex` activation; checks in the manifest callback only. Recommendation: `Catalog.validate/1` for names and kinds, `graph.ex` activation for unknown sites.
- **OP-7. Engine lookup and dispatch in the completion path.** Options: a port behind configuration, in the style of `Letflow.Engine.EntityPort` (0054 D2), with REVIEWER sign-off for the new core to tenant-data edge and a boundary check; a direct query in `engine.ex`. Recommendation: the port.
- **OP-8. Narrowed contract.** Options: attachment goes inactive; attachment stays active and fails at run time. Recommendation: inactive.
- **OP-9. Permission for attach and detach.** Options: reuse `DefinitionsWrite`; a new permission (the permission golden file and the auditor refused-set literal then move). Recommendation: reuse.

## Threats for SECURITY-REVIEWER

- Cross-tenant read, attach or detach of an attachment (D3, D7; INV-1, INV-5, INV-10).
- A script attached to a site that exceeds its sandbox or returns variables outside `returns` (D2, D7; INV-3).
- An upgrade that deletes, rewrites or silently re-points an attachment (D4).
- Privilege: attach without the publish step of 0053 D6 (D6).
- A run-time lookup that reads the wrong tenant schema (D3, OP-7).

## Sign-off

- SECURITY-REVIEWER: pending, not yet reviewed (content of D3, D4, D6, D7). The verdict is recorded in the `## Gates` block of the PR body.
- REVIEWER: pending, not yet reviewed. The verdict is recorded in the `## Gates` block of the PR body.
