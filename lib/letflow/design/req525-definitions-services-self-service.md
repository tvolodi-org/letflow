# REQ-525: definitions and services reads into `:self_service`, one route at a time (GH #2535, SEC RA-6)

Task T-0427 of the letflow team. Design and per-route rulings only. This change touches no route
class, no `@self_service_routes` entry, no snapshot line and no status in `docs/requirements.yaml`.
No implementation code appears below: tables and prose only.

Base: `main` 643cdc2f3. Facts re-derived from the code at that commit (routers, `authorization.ex`,
`route_scope.ex`, `scope/enforce.ex`, `service_catalog.ex`), not copied from section 5 of
`req519-enforced-writers-and-flag-on.md`.

## 1. Problem

After REQ-519 2f-b a tenant can be set to `on`. Under `on`, a route classed `:tenant_wide` (or
default-sourced, which runs as `:tenant_wide`) lets a caller through only when
`Letflow.Api.Scope.allowed?/3` finds a tenant-wide grant row (`Letflow.Api.Scope.Enforce.check/3`,
branch 4). A caller whose only rows are scoped gets the uniform 403 even though the coarse permission
`DefinitionsRead` allows the request. Ten routes of the DefinitionsRead family and `GET /services` are
in that state (`test/fixtures/route_scope/tenant_wide_default_routes.txt`). SEC RA-6 asks for each to be
ruled on its own. This record lists the routes, their fields, the open class-definition question, one
proposed ruling per route, and the acceptance criteria the implementation requirements must carry.

## 2. Route table (AC 1)

All ten rows below are `:tenant_wide` with source `:default` today: each is a line of the snapshot file
and none has a `scope:` option on its `authz_*` declaration (the declarations are in
`lib/letflow/routers/definitions.ex`, `solution_packs.ex`, `services.ex`; none of them passes `scope:`).
The coarse permission is `DefinitionsRead` for every row: `required_permission(:ServicesRead)` maps to
`:DefinitionsRead` too (`authorization.ex`, the `ServicesRead` clause). Holders of `DefinitionsRead`:
PLATFORM_ADMIN, TENANT_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, TENANT_AUDITOR
(`core_role_allows?/2` clauses, and the `DefinitionsRead` row of the matrix in `docs/roles.md`).
AGENT_RUNNER and CANDIDATE do not hold it.

Snapshot lines (grep of the fixture, current main):

    10:GET /definitions DefinitionsRead
    11:GET /definitions/:id DefinitionsRead
    12:GET /definitions/:id/export DefinitionsRead
    13:GET /definitions/active/:name DefinitionsRead
    14:GET /definitions/delta DefinitionsRead
    15:GET /definitions/search DefinitionsRead
    46:GET /services ServicesRead
    65:POST /definitions/:id/validate DefinitionsRead
    101:POST /solution-packs/:pack_id/update-review DefinitionsRead
    102:POST /solution-packs/export DefinitionsRead

(The other `/definitions`, `/solution-packs` and `/admin/services` lines carry write or manage keys and
are out of scope.)

Field legend. **T** = tenant-level metadata (a property of a tenant-level object, not tied to any scope
node). **R** = per-resource data (derived from an entity record, task, instance or attachment). **P** =
per-principal id. **Caller** = echoed or computed from caller input. No field in this family is **R**:
`process_definitions` has no scope-node column (`ProcessDefinition` schema fields: name, version,
description, status, stage, graph, created_by, archived_at, sequence_number, activated_by, owner_*,
needs_reactivation_*), unlike `instance_projections.scope_node_id` and `tasks.scope_node_id`.

### 2.1 Definition body (`definition_map/1`, `routers/definitions.ex`), used by R01 to R05

| field | kind | note |
|---|---|---|
| id, name, version, description, status, stage | T | |
| graph | T (design content) | nodes with attributes (HUMAN_TASK `role`, `form_schema`, service `endpoint` or `service_id`, `script_key`, timers, escalation roles), edges with conditions. The attribute map is open (`attributes: map() | nil` in `graph.ex`), so a designer could type any string into it. This is the one field the rulings depend on (SEC-525-Q2). |
| created_by | P | author user id, a UUID; no name, no email |
| created_at, updated_at, archived_at | T | |
| owner_module, owner_module_version | T | module that shipped the version; hashes are never serialised |
| activation_state, needs_reactivation_reason, needs_reactivation_at | T | reason is a closed code, never an id |

### 2.2 Routes

| # | route | current class | response (allowlist function) | per-field kind |
|---|---|---|---|---|
| 1 | `GET /definitions` | `:tenant_wide` (default) | `{items: [definition body], next_cursor}` (`render_list_result`); query params name, status, stage, cursor, page_size | body per 2.1; `next_cursor` opaque, T |
| 2 | `GET /definitions/:id` | `:tenant_wide` (default) | definition body; absent id: uniform 404 | per 2.1 |
| 3 | `GET /definitions/active/:name` | `:tenant_wide` (default) | definition body; 404 if none | per 2.1 |
| 4 | `GET /definitions/search` | `:tenant_wide` (default) | `{items: [{definition: body, rank}], next_cursor}` (`search_result_map`); `q` matched by `ILIKE` on name and description only (`@rank_case_sql`, `where ... d.name ILIKE`) | per 2.1; `rank` T; `q` is a filter, never echoed |
| 5 | `GET /definitions/delta` | `:tenant_wide` (default) | `{items: [definition body], next_since}`; every status including DRAFT, DEPRECATED, ARCHIVED; `next_since` is the tenant high-water mark of `definition_sequence` | per 2.1; `next_since` T (a change counter) |
| 6 | `GET /definitions/:id/export` | `:tenant_wide` (default) | `{bpm_export_schema_version, id, name, version, description, graph, exported_at}` (`export_document_map`) | all T; graph as 2.1 |
| 7 | `POST /definitions/:id/validate` | `:tenant_wide` (default) | 200 `{status, findings: [], warnings, definition_id, validated_at}`, or 422 problem with `errors` = violation `{code, message}` naming node ids (`violation_map`) | T; messages are generated from the stored graph; `validated_at` is the clock |
| 8 | `POST /solution-packs/export` | `:tenant_wide` (default) | body `{definition_ids: [..], version?}`; response `pack_document_map`: pack_id, version, bpm_export_schema_version, exported_at, `definitions[]` (definition_id, process_key, name, version, graph), `service_catalog_entries` (always `[]` on export), `variable_schemas[]` (definition_id, schema_name, schema_content), `manifest.required_roles` (always `[]` on export) | T, with `schema_content` (JSON Schema of instance variables) as design content; the caller supplies ids that SELECT resources (Caller) |
| 9 | `POST /solution-packs/:pack_id/update-review` | `:tenant_wide` (default) | body `{target_version, theirs_artefacts[], incoming_artefacts[]}` (caller-supplied content); response `{pack_id, target_version, entries[{artefact_type, artefact_id, classification, resolved}], has_unresolved_conflicts}`. Content strings are never echoed (`update_review_response_map`). Reads `solution_pack_artefact_bases` and resolutions of the tenant (`Definitions.compute_pack_update_plan/5`, `fetch_base`, `resolution_exists?`). | T; `classification` and `resolved` reveal stored pack state; ids are Caller |
| 10 | `GET /services` | `:tenant_wide` (default) | `{items: [service record], next_cursor}`: service_id, endpoint_url, request_schema, response_schema, required_auth (mode name), timeout_ms, scope (global or tenant), owner_tenant_id, created_at, updated_at. Rows: every `scope: :global` entry plus the caller tenant's own (`ServiceCatalog.list_for_tenant/2`); another tenant's entries are absent. `max_retries` is not serialised. | all T; `endpoint_url` is integration topology; `owner_tenant_id` is the caller tenant or null |

Caller facts for the claim "tenant id comes from the auth context": `GET /services` reads
`conn.assigns.auth_context.tenant_id` (the catalog table is global, no prefix); the definition and pack
routes read through `conn.assigns.scoped_opts` (schema prefix, INV-1). Neither takes a tenant identifier
from the request, so INV-10's cross-tenant negative test does not apply to the family (no route takes a
tenant id); the tenant-isolation tests in the existing router tests stay.

### 2.3 Call-path facts

- The coarse allow runs first. `Enforce.check/3` is called by `Letflow.Plugs.Authorize` in its allow
  branch, after `Authorization.evaluate_access/2` (moduledoc of `scope/enforce.ex`). For `:self_service`
  it returns the conn unchanged (branch 3), so a principal without `DefinitionsRead` is refused by the
  coarse check with the same uniform 403 as today (INV-5), before the class is looked at.
- Shadow mode counts `:self_service` routes as requests only (`scope/shadow.ex`, branch
  `{:self_service, _}`): ruling a route in therefore removes it from the shadow denial evidence of
  tenants in `shadow`.
- The route walk (`RouteScope.audit_routes/3`) forces a route into `@self_service_routes` only under the
  prefixes `/me` and `/help` (`@self_service_prefixes`). A route outside them is `:self_service` only if
  it is both declared `scope: :self_service` and listed; either alone fails (`:self_service_list_mismatch`,
  `:self_service_not_listed`). So `/definitions*`, `/solution-packs*` and `/services` can join with no
  change to the walk's prefix rule.

## 3. Open questions (AC 3). The security ruling decides; this record does not

### SEC-525-Q1: what does the class definition say about roles?

`route_scope.ex` defines `:self_service` as "tenant-level, non-sensitive, role-independent reads". The
four existing members are held by every authenticated role, or by all but CANDIDATE
(`MyModulesRead`; census row in the REQ-519 design). `DefinitionsRead` is held by six roles and not by
AGENT_RUNNER and CANDIDATE. Two ways to reconcile:

- **Option A, widen the class.** Reword the moduledoc definition so that "role-independent" means "does
  not depend on the caller's scope rows; the coarse permission of the policy key still applies", and
  update the REQ-518 AC 21 walk rule text accordingly. The walk code needs no change (section 2.3).
- **Option B, keep the definition and add a role gate inside the class.** A `:self_service` entry would
  carry an extra required-role or required-permission field, checked by `Enforce`. This needs a new field
  in `SelfServiceEntry`, a new branch in `Enforce.check/3` and `Shadow`, and a walk rule.

Designer's facts for the decision, not the decision: Option B duplicates the coarse allow, which already
is a per-permission role gate that runs before the class (section 2.3); no existing `:self_service` route
needs one. Option A changes one paragraph and keeps the entry shape (`SelfServiceEntry.validate!/1`)
unchanged. If SEC chooses B, every implementation requirement below grows by the gate and its tests, and
the sizing of section 6 must be revisited. **Until SEC-525-Q1 is recorded in the security verdict on this
change, no route below is ruled in effectively and every route stays `:tenant_wide`.**

### SEC-525-Q2: is the `graph` field acceptable for a scoped holder?

Rulings R01 to R05 return the full `graph` of every definition (draft and archived included for R01, R05).
The graph is design content with an open attribute map; the secrets rule (INV-4) says credentials live
behind `Letflow.Secrets` references, but nothing validates an attribute value that way. Argument for
accepting: a scoped holder is by construction a member of the same four roles that already read the same
graph tenant-wide; org-scoped grants restrict which RECORDS and TASKS a person sees, and the graph holds
no per-region data. Argument against: scoping is introduced to narrow what a regional worker sees, and a
literal URL or note typed into a node would reach that person. The alternative that would answer "no"
without keeping the route `:tenant_wide` is a graph-less summary body; it breaks the AC 4 rule that a
scoped holder gets the same body shape as a tenant-wide holder and the SPA contract
(`web/src/api/definitions.ts`, `DefinitionEditorPage`), so this record does not propose it. Proposed
ruling text below assumes SEC accepts the graph; if SEC rejects it, R01 to R05 become "stays
`:tenant_wide`" and nothing else in this record changes.

## 4. Rulings (AC 2)

Ruling ids are recorded here, not in `handoffs/` (this team does not touch it). Each ruling has its own
reasoning; none relies on a sibling. Status of every ruling: **PROPOSED by the designer; effective only
when the security review of this change records it by id.** A route whose ruling is not recorded stays
`:tenant_wide`.

Decision rule used for all ten: a route is ruled in only if (a) every field is T or P (no R field,
section 2.2), (b) a scoped holder has a demonstrated functional need, otherwise the fail-closed 403
stays (fewer exposed fields), (c) a caller-supplied id never selects a resource the caller must be scoped
for (the class definition's FILTER rule), and (d) the route is a read.

| id | route | outcome | reasoning |
|---|---|---|---|
| SEC-525-R01 | `GET /definitions` | **may be `:self_service`** (conditional on Q1 and Q2) | (a) all T/P; (b) the tenant dashboard calls `definitionsApi.list({page_size: 5})` (`web/src/pages/dashboard/TenantDashboardPage.tsx`) and the nav item "Definitions" is gated on `DefinitionsRead` (`AppShell.tsx`), so a scoped holder gets a broken dashboard today; (c) filters only (name, status, stage, cursor); (d) read. Cursor is unsigned and not a security control. |
| SEC-525-R02 | `GET /definitions/:id` | **may be `:self_service`** (conditional on Q1 and Q2) | The id selects a tenant-level object that has no scope node, so (c) holds: no resource the caller must be scoped for is chosen. Unknown id and another tenant's id are the same 404 (INV-5, schema prefix). Needed by every drill-down from R01. |
| SEC-525-R03 | `GET /definitions/active/:name` | **may be `:self_service`** (conditional on Q1 and Q2) | `name` is a lookup key of a tenant-level object; same body and same uniform 404 as R02. Needed for the "which version runs" lookup. |
| SEC-525-R04 | `GET /definitions/search` | **may be `:self_service`** (conditional on Q1 and Q2) | Search is over `name` and `description` only (rank query), `q` is a filter and is not echoed, results are R01's bodies. Condition: the matched columns must not grow to `graph` or any R field without a new ruling. |
| SEC-525-R05 | `GET /definitions/delta` | **may be `:self_service`** (conditional on Q1 and Q2) | Same bodies as R01 plus status history of the tenant's definitions; `next_since` is a change counter of a tenant-level sequence, not a resource count of anything scope-bound. The consumer is the mobile delta sync (REQ-125); whether a scoped mobile user exists is not shown by the code, so the need is the weakest of the five: SEC may keep it `:tenant_wide` without affecting R01 to R04. |
| SEC-525-R06 | `GET /definitions/:id/export` | **stays `:tenant_wide`** | Body is R02's graph in the importable portable format; no extra T/P field, but no scoped need either: the only consumer is the editor's export action (`DefinitionEditorPage`, `definitionsApi.exportJson`), a designer tool. (b) fails, so the fail-closed 403 stays. Not reclassified because R02 is. |
| SEC-525-R07 | `POST /definitions/:id/validate` | **stays `:tenant_wide`** | (d) fails: a POST that runs server-side work on a stored graph (design-time action, `useDefinitions` validate mutation) and whose error body contains generated violation messages naming node ids. No scoped need. Not a read in the class definition's sense. |
| SEC-525-R08 | `POST /solution-packs/export` | **stays `:tenant_wide`** | (c) fails literally: the body's `definition_ids` select resources, and the response is a bundle (definitions, `variable_schemas`, manifest) in the install format. No scoped need (pack authoring). |
| SEC-525-R09 | `POST /solution-packs/:pack_id/update-review` | **stays `:tenant_wide`** | (c) and (d) fail: caller-supplied artefact content and ids, and a response that reveals the tenant's stored base and resolution state per artefact. It is step one of a workflow whose apply step needs `DefinitionsCreate`, which no scoped read-only role holds. |
| SEC-525-R10 | `GET /services` | **stays `:tenant_wide`** | All fields are T, but (b) fails: the only consumer is `ServicesPage` (`web/src/pages/admin/services/ServicesPage.tsx`, `servicesApi.listForTenant`), an administration page. `endpoint_url` and the request and response schemas describe integration topology that a scoped holder has no use for. The shaping alternative (drop `endpoint_url`, `owner_tenant_id`) was considered and rejected: it must apply to every caller, so it changes the contract the admin page uses, and the AC 4 rule keeps the body shape equal for scoped and tenant-wide holders. If a scoped consumer appears, a new requirement with its own ruling reopens this. |

Summary: five routes may be ruled in (R01 to R05), five stay `:tenant_wide` (R06 to R10). No route is
ruled "only after a response-shaping change": the shaping candidates (graph-less bodies, dropping
`endpoint_url`) were rejected in Q2 and R10.

## 5. Acceptance criteria every implementation requirement must carry (AC 4)

For EACH route the requirement rules in (its own PR, its own ruling id):

1. `@self_service_routes` in `lib/letflow/api/route_scope.ex` gets the entry `{route: "<METHOD> <full path>", key: <policy key>, class: :self_service, ruling: "<SEC-525-Rnn>"}` (the keys: `:DefinitionsRead` for R01 to R05).
2. The route's `authz_get` declaration adds `scope: :self_service`. Both edits are needed, the walk fails on either alone.
3. The route walk (`test/letflow/api/route_scope_walk_test.exs`) is green, and `test/fixtures/route_scope/tenant_wide_default_routes.txt` loses exactly that route's line and no other (`git diff` of the fixture shows one removed line per route).
4. Under `on`, a SCOPED holder of `DefinitionsRead` (a tenant-role binding with scoped rows only) gets 200 and a body of the same shape (same keys, same types) as a tenant-wide holder's, with test data created in the same tenant. A principal without `DefinitionsRead` (AGENT_RUNNER or CANDIDATE) still gets the uniform 403 `insufficient permissions`, byte-identical to the 403 of an unmodified route (INV-5). The cross-tenant case: another tenant's definition id answers the same 404 as an absent id (INV-5).
5. Under `shadow`, the route is counted as a request and produces no denial evidence (assert the `Shadow` behaviour for `:self_service`, section 2.3).
6. No field is added to the response that is derived from an entity record, task, instance or attachment; adding one needs a new ruling (class definition).
7. A SECURITY-REVIEWER code verdict for that PR (INV-1, INV-2, INV-5, INV-6), cited in the PR body (REQ-518 AC 23 rule). `Refs #2535`, never `Closes`.
8. The documentation changes of section 7 for that route.

An implementation requirement whose route set contains a route not ruled in by the recorded verdict is
refused by the REQ-VALIDATOR (R06 to R10 never travel with R01 to R05).

Existing tests that the implementation PRs must change, from these greps (current main):

    $ grep -rn "api/v1/definitions\"" test --include=*.exs -l
    test/letflow/api/authz_deny_log_test.exs
    test/letflow/api/scope_shadow_test.exs
    test/letflow/routers/gh2747_cursor_tail_http_test.exs
    test/letflow/routers/tenant_auditor_routes_test.exs
    test/letflow/scope_enforcement_on_e2e_test.exs

    $ grep -n "@tenant_wide_route" test/letflow/scope_enforcement_on_e2e_test.exs
    57:  @tenant_wide_route "/api/v1/definitions"
    194,196,208,213,214,258,267,378,380 (uses)

    $ grep -rn "length(.*self_service\|self_service_routes()" test
    test/letflow/api/route_scope_self_service_test.exs:331  the self-service list is exactly M1, M2, the REQ-449 access route and H1 (sorted list pin)
    test/letflow/api/route_scope_self_service_test.exs:360,366  no entry pending; each entry shape
    test/letflow/api/route_scope_on_flip_blocker_test.exs:101,133,150
    test/letflow/api/route_scope_self_service_entry_test.exs:36
    test/letflow/scope_enforcement_on_e2e_test.exs:161  `assert length(self_service) == 4`

Consequences, by file:

- `scope_enforcement_on_e2e_test.exs` uses `GET /api/v1/definitions` (R01) as its one representative
  `:tenant_wide` route (denies a scoped worker under `on`, allows an admin and a token). The R01 PR must
  switch `@tenant_wide_route` to a route that stays `:tenant_wide` after every REQ-525, REQ-526 and
  REQ-527 PR, that TASK_WORKER holds the coarse permission for, and that has a stable 200 for an admin.
  Candidates must be checked against the REQ-526 and REQ-527 rulings; a route from R06 to R10 that a
  TASK_WORKER may call (R06, R07, R10) is stable by this record. Its line 161 filters by `/me` and
  `/help` prefixes, so it stays 4 and needs no change.
- `route_scope_self_service_test.exs:331` pins the sorted list of the four members: each PR adds its
  entries to that expectation, and the test name ("exactly M1, M2, ...") is updated.
- `scope_shadow_test.exs:212`, `authz_deny_log_test.exs:919` and `tenant_auditor_routes_test.exs:649,982`
  call `GET /definitions` under other modes and roles; the R01 PR runs them and records whether a
  denial expectation changed (a `:tenant_wide` shadow denial for a scoped holder disappears).
- `test/support/route_inventory.ex` reads the snapshot by path (`@snapshot_path`); the walk consumes it,
  so a removed line is picked up with no code change.
- `scripts/ci_changed_paths.sh`: `route_scope.ex` and the fixture are backend paths already; the docs
  changes count as docs the suite reads (runbook tests), so BACKEND_PATHS_RE applies.

## 6. Implementation requirements to be filed (AC 5)

Not filed by this task and no status flip: REQ-ANALYST files them from the recorded rulings. Owner
ELIXIR-DEV, `depends_on: [REQ-525]`, `gh: 2535` for traceability, each sized to one agent turn
(one or two route declarations, one list edit, one fixture edit, one test file).

| proposed requirement | routes | why this size |
|---|---|---|
| IMPL-525-A | `GET /definitions` (R01), `GET /definitions/search` (R04) | collection reads; carries the `@tenant_wide_route` switch of the e2e test; two list entries |
| IMPL-525-B | `GET /definitions/:id` (R02), `GET /definitions/active/:name` (R03) | single-object reads sharing the uniform-404 test |
| IMPL-525-C | `GET /definitions/delta` (R05) | filed only if SEC keeps R05 ruled in; its own PR because its need is the weakest and it can be dropped without touching A and B |

Not filed: R06 to R10 (stay `:tenant_wide`; no requirement). If SEC-525-Q1 picks Option B, a prerequisite
requirement "role gate inside `:self_service`" (SelfServiceEntry field, `Enforce` and `Shadow` branch,
walk rule, tests) is filed first and A to C depend on it.

## 7. Documentation updates per route (AC 6)

Until the implementation PR of a route has merged, `docs/roles.md` and `docs/runbooks/scope-enforcement-on.md`
keep the REQ-519 statement unchanged: the ON_IN_PRODUCTION item 5 text "Scoped users lose definitions,
entity-definition, instance and service reads until the tenant-level metadata follow-up (RA-6) ships",
in `docs/roles.md` (the scope-enforcement section, item 5 of the numbered `on` list) and in the runbook
(item 5 of the same list). This change edits neither file.

When each implementation PR merges it updates, citing the heading or symbol and no line numbers:

| PR | `docs/roles.md` | runbook `scope-enforcement-on.md` | other |
|---|---|---|---|
| IMPL-525-A | item 5 reworded: scoped users keep `GET /definitions` and `GET /definitions/search`; still lose the other definition reads, entity-definition, instance and service reads; the matrix row of `DefinitionsRead` unchanged (the permission is unchanged) | item 5 the same wording; the list of routes that answer 403 to a scoped user loses the two | `route_scope.ex` moduledoc if SEC-525-Q1 changed the class text; `routers/definitions.ex` moduledoc "Authorization" paragraph names the class of the route |
| IMPL-525-B | item 5: also `GET /definitions/:id`, `GET /definitions/active/:name` | same | router moduledoc |
| IMPL-525-C | item 5: also `GET /definitions/delta` | same | router moduledoc |
| (all) | the sentence stays for entity-definition (REQ-526), instance (REQ-527) and service reads (R10) | the service-reads clause stays: R10 keeps `GET /services` `:tenant_wide`, and the clause on exports, validate and pack reads is added as "still 403 for scoped users" | |

The last of A to C also removes the "definitions" word from item 5 only if R06 and R07 are gone from the
403 list, which they are not (they stay `:tenant_wide`): item 5 must keep naming definition export and
validation as still refused.

## 8. Left out on purpose

- Entity definitions (REQ-526), instance scope (REQ-527), the task scope writer (W3b), exam routes
  (SEC-518-R1), every route not named in the task.
- Any change to `route_scope.ex`, the fixture, the routers, the web client, `docs/roles.md`, the runbook
  or `docs/requirements.yaml` in this change.
- A response-shaping API change for any route (rejected in Q2 and R10).
- Mobile: R05 notes the REQ-125 consumer; `apps/mobile/` is not read for scoped-user behaviour here.

## 9. Findings for the security review

1. SEC-525-Q1 and SEC-525-Q2 are the two decisions this record cannot take; the proposed outcomes of
   R01 to R05 depend on both.
2. `scope_enforcement_on_e2e_test.exs` is coupled to R01 through `@tenant_wide_route` (section 5): a
   route ruling that looks like a one-line list edit also moves the e2e fixture.
3. The `graph` attribute map is open; the record found no validator that refuses a credential-looking
   value (INV-4 covers secrets by reference, the graph is not scanned). Not a defect of this change;
   noted for the Q2 decision.

Test plan for THIS change (design only): none beyond the lints; `lf.sh lint` must pass and no file
other than this record changes. Acceptance criteria 1 to 6 map to sections 2, 4, 3, 5, 6, 7.
