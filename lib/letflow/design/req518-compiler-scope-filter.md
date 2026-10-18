# REQ-518: scoped data path (2c-i), 404 equivalence and writes (2c-ii), approver rule F1 (2d), org-scoped role grants stage 2 (GH #2535)

AGENT: CODE-DESIGNER. Workflow WF-02, run `WF02-REQ518-COMPILER-SCOPE-20261018`, step 01.
Base: `main` 84f6773f1 (REQ-517 2a #2765 and 2b #2782 merged). Branch
`feature/WF02-REQ518-COMPILER-SCOPE-20261018`. Design only: signatures are `@spec`-shaped text, SQL and
queries are prose, no function bodies, no `.ex` blocks.

Sources read in full: `docs/requirements.yaml` REQ-518 (22 ACs on main; AC 23 of PR #2801 is NOT merged and
was NOT read, see section 7.3), decision 0051 (D1, D2, D3, D4, D6, D7, D8, D9, D11, D12, Q3, T1-T17,
Amendment 1 A1-A7), `docs/agents/instructions/security-invariants.md` (INV-1, 2, 5, 6, 7, 8),
`lib/letflow/design/req517-scoped-grants-admin-plane.md` (4.1 classes, 4.3 `Enforce`, 4.4 `allowed?/3`, 4.8
`Shadow`, 13, 16), handoffs `WF02-REQ517-.../step-12` (SEC C-1, C-2, F-1..F-4) and `step-13` (REVIEWER F-1..F-5),
and the code: `Letflow.Entities.Query.Compiler` (all of it relevant), `Allowlist`, `Cursor`, `RequestAccess`,
`TypeAccess`, `FieldPolicy`, `Letflow.Entities.Records`, `ManagedTypes`, `Letflow.Routers.Entities`,
`Letflow.Routers.Tasks`, `Letflow.Routers.Me`, `Letflow.Tasks`, `Letflow.Engine.complete_task/3`,
`Letflow.Api.Scope`, `RouteScope`, `Scope.Enforce`, `Scope.Shadow`, `Letflow.ScopeNodePaths`,
`Letflow.Modules.Module`/`Catalog`, `Exam.Session`/`Snapshot`/`AntiCheat`, `script_reads.ex`,
`mix letflow.seed.exam_fixtures`, `test/fixtures/route_scope/tenant_wide_default_routes.txt` (143 lines).

## Changelog

| Rev | Date (UTC) | Change |
|---|---|---|
| r0 | 2026-10-18 | Initial design, three PRs plus the AC 23 ledger (section 7.3) per coordinator message. |
| r0a | 2026-10-18 | CODE-DESIGN-VALIDATOR small fixes (handoff step-02): Catalog rule number 9 -> 11 (rules 1-10 exist); ruling id for GET /me/memberships SEC-517-RA-3 -> 0051-A7 (no such SEC id existed); R-1 build default stated (threading until ruled); DELETE query-param parse ordered after the scope lookup; 7.3 AC 23 corrected from the PR #2801 text. Required changes G1-G3 in the handoff are NOT applied here. |
| r1 | 2026-10-18 | CDV FAIL rework. G1: F1 default rule is the literal TASK_WORKER grant via a named per-role scope function (`Scope.allowed_for_role?/3`, `Scope.allowed_set_for_role/2`), negative tests for scoped PROCESS_OPERATOR and TENANT_ADMIN; the wider reading stays OQ-3; assign/reassign stay on the route permission (C.3). G2: unmanaged-type declarations limited to test-only modules through a Catalog rule and a test-config allowlist; R-3 restated, R-7 corrected, OQ-1 and OQ-4 closed for production (3.2, 8, 12.2, 15). G3: 2c-i split into 2c-i-a (compiler and declaration, no route reclassified) and 2c-i-b (ScopeGate, backstop, route classes, self-service); 2d explicit commit order (section 1, C.0). Non-blocking: named the scope-404 telemetry event (5.2), attachment create short-circuits before the multipart read (5.5), mutant ids renamed MU1..MU41 (section 11; MU36-MU38 added in r1), OQ-8 states the backstop can turn a committed 2xx into a 500. |
| r1a | 2026-10-18 | CODE-DESIGN-VALIDATOR recheck (step-03-cdv-recheck): stale 2c-i labels -> 2c-i-a/2c-i-b, mutant range note MU1..MU41, RA-13 (tenant-wide exemption of the F1 grant rule), 2c-i-a sizing note for the threading fallback. |
| r2 | 2026-10-18 | SEC design gate PASS_WITH_FINDINGS (step-04): C-1 `allowed_set/2` raises on any `allowed_node_ids/2` error and on a 50,000-id cap, never `:all`/partial/silent `:none` (3.3, T-C13, T-C14, MU40, MU41); C-2 fixture with a retired INTERMEDIATE node with a live descendant (3.8, T-C4, T-C12); C-3 pure new-value check before the transaction and before the idempotency claim (5.3, T-W22, MU39); C-4 `:f1_scope` is a plain read on the transaction's repo handle after the task lock, lock orders unchanged (C.4, T-F17); C-5 T-W21 production-shaped refusal test; C-6 type-gate bytes test T-W23 (5.3); C-7 rulings recorded in section 8 (R-1 SEC-518-R1 literal form is the build default, threading fallback removed; R-2 ids SEC-518-R2-modules and SEC-518-R2-help, so /me/modules and /help/resolved become `:self_service` in 4.2), AC 23 PR-checklist table (7.5), `config/test.exs` `:modules` SEC trigger; R-2 added sentence and help condition (4.1, 4.4, T-S9); R-3 prod-config evaluation test (T-D8); R-4 detective-only conditions (3.6); advisories A-1..A-8 (12.3); RA-13 conditions (C.3, C.5, section 14). |
| r2a | 2026-10-18 | CODE-DESIGN-VALIDATOR recheck of r2 (step-06): `:exam_route_reclassified` walk rule explicitly ships in 2c-i-a (3.1, section 1, 3.6, new T-C15); create path states the pure C-3 check before `Idempotency.from_body` (5.3). |

---

## 0. Findings against the requirement text and the as-built 517 (read first)

| # | Finding | Decision |
|---|---|---|
| F1 | The FACTS line numbers are stale. As built on main 84f6773f1 the nine call sites are: `routers/entities.ex` 1958 (query) and 2394 (export) for `compile`, 2211 for `run_aggregate`; `script_reads.ex` 199; `exam/anti_cheat.ex` 251; `exam/session.ex` 238 (`list_available_exams`) and 1494 (`query_all/3`); `exam/snapshot.ex` 1111 (`query_all/3`); `mix/tasks/letflow.seed.exam_fixtures.ex` 619. `compile_aggregate` has no external caller (only `run_aggregate` and tests). Arity change breaks about 67 call sites in 9 existing test files (`query_test` 21, `query_joins_test` 16, `query_aggregate_test` 10, `query_cursor_field_grants_test` 10, `query_self_join_test` 3, `entities_query_restricted_walker_test` 3, `pack_install_test` 2, `certificate_test` 1, `service_task_entity_writes_sentinel_test` 1). | The test edits are FORCED and mechanical (add the explicit third argument `:all`). Listed in the PR body; no assertion changes. The AC 1 source scan covers `lib/` and `lib/mix/` only, never `test/`. |
| F2 | AC 2 and AC 14 name a `total`. On main there is NO total: `POST /entities/query` and export return `items` + `next_cursor` (`Cursor.paginate/5` runs no count query), the task list returns `count = length(items)` of the page, and only `POST /entities/query/aggregate` has counts. | "total" is tested where it exists: aggregate `count`/`sum`/`group_by` buckets/`having`-equivalent (aggregate results; note the DSL has no `having` clause on main, `build_aggregate_request` parses aggregates, group_by, filters, join only), the task list `count` and pagination, and the cursor pages. No total field is added (scope creep). AC 2's "count/total query" telemetry assertion becomes: every executed data and aggregate statement carries the predicate. Requirement amendment RA-6. |
| F3 | The managed-type write lock (GH #2583, `guard_tenant_write/3`) answers a constant 403 `entity_type_managed` for EVERY generic record write route (POST, PUT, DELETE, import) of a module-managed type, before the path id, body or scope is read. 0051 D6 makes declarations module-owned. If declarations were restricted to MANAGED types, no scope-aware type would be writable through the generic routes and AC 6 to 9 would be unreachable over HTTP. | Production declarations cover MANAGED types only (Catalog rule 11, 3.2), so they cannot bypass the managed-type lock (0051 D6/M4). Declarations on UNMANAGED types exist only for test-only modules named in a test-config allowlist (R-3). Consequence stated plainly: in production a scoped caller gets the constant 403 on every generic write route of a managed declared type and the uniform 404 for undeclared types; the write-side logic (AC 6-9) is proven only against the test-only fixture `fixture_scoped`, which is a known limit of the pilot state (R-8). |
| F4 | `Scope.effective_scope/2` returns grant ROOT nodes `{:nodes, roots}`; the compiler argument `{:nodes, [node_id]}` must be the expanded ALLOWED set (roots plus live descendants), computed once per request. `ScopeNodePaths.descendants_of/2` exists but caps input at 500 ids and returns retired nodes. | New `ScopeNodePaths.allowed_node_ids/2` (3.4) and `Scope.allowed_set/2` (3.3). Retired nodes are excluded (T6: a record whose scope node is retired is invisible to a scoped caller, consistent with `allowed?/3`'s `:unresolvable`). |
| F5 | Import (`POST /records/:type/import`) is per-entry partial success today (each `create_record` commits alone; failures are per-entry results). AC 9 requires all-or-nothing and ONE generic error for scope. Import never updates (it mints new ids; `record_id` in the document is a reconciliation label), so "old value" does not occur on import. | Scope pre-check of every row before the first create, for scoped callers on scope-declared types only. Everything else (tenant-wide callers, per-entry validation failures) keeps today's behavior byte for byte. Residual: a grant revoked while a batch is in flight (3.9). |
| F6 | The four record-attachment routes behave differently for a nonexistent parent today: create gives 404 via the FK changeset, list gives an EMPTY 200 page, get content and delete give 404. | "Identical to a nonexistent parent" is defined per route as "whatever the route does today for a nonexistent parent" (5.5). The out-of-scope branch re-enters the same code path as the nonexistent branch. |
| F7 | AC 7 says a reference field pointing at an out-of-scope or nonexistent record "gives the same error". No reference validation exists on the record write path on main (`Records`/`Validator`: no foreign-key lookup; only unique constraints). | The clause is satisfied vacuously today and is PINNED by a test (T-W8) that fails the day a reference check appears without a scope-aware lookup. |
| F8 | As built in 517: `RouteScope` has `@self_service_routes_allowed? false` and `@expected_filter_routes []` (walk fails any `:self_service`/`:filter` route), no `@self_service_routes` attribute and no `pending_sec_ruling` handling (REVIEWER 517 F-1, SEC F-1, F-4). | 518 flips both constants in the SAME change that first assigns a route, adds a committed expectation list for `{:resolver, _}` routes (new), builds `@self_service_routes` and the marker rules (4.2), and amends design 4.1 to the as-built rule (key table first). |
| F9 | Under `on` the plug lets `{:resolver, _}`, `:filter` and `:self_service` routes through after only the coarse allow (`Enforce.check/3`). SEC C-2: "the handlers must actually apply the scope". Nothing in 517 proves a handler did. | Runtime backstop (D6): handlers apply scope only through `Letflow.Api.ScopeGate`, which sets a request marker; `Enforce` registers a before-send check for resolver and filter routes that turns a 2xx without the marker into a detail-free 500 in `on`. Plus the per-route ledger (7.3). New mechanism, flagged for SEC/REVIEWER (OQ-8). |
| F10 | `Tasks` routes: claim and complete share the policy key `:TasksComplete`; classification is per route (the `scope:` option), not per key, so they can be classified independently. GET `/tasks` has `task_scope: :all | {:own_user_and_groups, id}` via `AllowWithRowFilter`; non-worker-only roles list UNFILTERED today. | F1 adds a node predicate that INTERSECTS with the existing assignee scope (3.1 of Part C). The routing-role checks that exist today (assignee type USER/GROUP/ROLE in `authorize_completion` and `apply_claim`) stay the routing requirement; F1 adds only the grant-coverage requirement (C.3). |
| F11 | `StepWrites` (engine HUMAN_TASK and SERVICE_TASK entity writes) reads a vacuous config seam `:entity_writes_scope_keys` and names 0051 as its replacement. | Out of scope for 518 (T14: the engine write path runs under the instance's scope node, owned by W3b). Recorded as residual R-4 and OQ-9: the seam stays vacuous; once a type is scope-declared a process step that writes it with the platform actor is NOT scope-checked. |
| F12 | The requirement says three PRs. AC 21 is tagged [2c-i] but its SECURITY-REVIEWER ruling must exist in this design BEFORE the AC 21 PR is built. | The design records the ruling slots (section 8). If the rulings are not recorded when 2c-i-b is ready, AC 21 is a separable commit that can merge as its own PR (2c-i-s) after 2c-i, with its own SEC pass (RA-7). |

---

## 1. PR split and boundary

Order: 2c-i-a, then 2c-i-b, then 2c-ii and 2d in either order (independent after 2c-i-b; 2d does not need 2c-ii's
`ScopedLookup`). Each is independently green. Every PR needs SECURITY-REVIEWER (SEC C-2) and REVIEWER.

Sizing note (r2): R-1 is ruled IN (SEC-518-R1), so the exam sites 7-9 keep the literal `:all` with the ruling comment and 2c-i-a carries no exam threading except the required `:scope` opt of `list_available_exams/2`; the threading fallback is removed.

| | PR 2c-i-a: compiler scope arg and declaration, NO route reclassified | PR 2c-i-b: ScopeGate, backstop, filter routes, self-service | PR 2c-ii: 404 equivalence, writes, bulk, revocation, attachments | PR 2d: approver rule F1 |
|---|---|---|---|---|
| ACs | 1 (compiler contract, all nine sites), 2, 3, 4, 5, 22 | 1 (router derivation of the set), 18, 21, 22 | 6, 7, 8, 9, 10, 11, 19, 22 | 12-17, 20, 22 |
| Behavior change for a tenant not `on` | none (the `:all` path emits the SQL it emits today; the three router sites pass a literal `:all` with `# scope-all: route is still :tenant_wide until 2c-i-b`, safe because a scoped caller is refused 403 before the handler under `on`) | none (`ScopeGate` returns `:all` with no read unless `on`) | none (`ScopeGate` returns `:all` / allow with no read unless the per-request flag is `on`) | none (existing task tests unedited; AC 16) |
| Reclassifications (route class changes) | none (no route class, snapshot line or expectation list changes; only the additive `:exam_route_reclassified` walk rule ships, T-C15) | `POST /entities/query`, `POST /entities/query/aggregate`, `POST /entities/records/:entity_type/export` -> `:filter`; `GET /me/memberships` -> `:self_service` (+ `/me/modules`, `/help/resolved`, both ruled IN) | create, PUT, DELETE, import, 4 attachment routes -> `{:resolver, _}`; 7 other `entities.ex` routes declared `:tenant_wide` | `GET /tasks`, `GET /tasks/inbox` -> `:filter`; `GET /tasks/:id`, claim, complete, assign, reassign -> `{:resolver, _}` |
| Snapshot lines removed (of 143) | 0 | 3 + 3 (M1, M2, H1) | 15 (E1-E7 declared, E11-E18 resolvers) | 7 |
| Migrations | none | none | none | 1 tenant-scoped (`tasks.scope_node_id`) |
| New modules | `Entities.ScopeDeclaration`, `ScopeNodePaths.allowed_node_ids/2`, `Scope.allowed_set/2`, Catalog rule 11 | `Api.ScopeGate`, `Entities.ScopeResolver` (shell), `Enforce` backstop, `RouteScope` additions | `Entities.ScopedLookup`, `Entities.ScopedWrites` | `Tasks.ScopeResolver`, test-support `TaskScopeFixture` |
| Files 2c-i-b, 2c-ii and 2d edit | none of these | `route_scope.ex` expectation lists and `tenant_wide_default_routes.txt` (different lines, rebases cleanly) | same | same |
| Not in any 518 PR | flip to `on` (REQ-519), module routes (stay `:tenant_wide`), instance routes, webhooks, the production writer of `tasks.scope_node_id` (W3b), scoped integration tokens, scoped AuditRead, escalation (D10), StepWrites scope (F11) | | | |

WHAT THE SHADOW PERIOD DOES NOT PROVE (requirement text, restated for the PR bodies): shadow evidence covers only
`:tenant_wide` and admin-plane routes. Data-path denials in this requirement are proven by its tests and the
REQ-519 AC 16 end-to-end suite. No text, refusal or documentation may claim more.

## 2. Decision summary

| # | Decision |
|---|---|
| D1 | The scope set is the expanded ALLOWED node-id set computed by `Scope.allowed_set/2` (the same module that owns `allowed?/3`), via the new single-purpose `ScopeNodePaths.allowed_node_ids/2`. `Scope.allowed_set/2` and `allowed?/3` share the same private candidate/effective logic, and an agreement property test ties them (T-C12). |
| D2 | `Letflow.Api.ScopeGate` is the ONLY conn-level entry for handlers: it reads the per-request flag, memoises the set, and sets the "scope applied" marker. With the flag `off`/`shadow` it returns `:all` / allow without any read. |
| D3 | `Letflow.Entities.ScopeDeclaration.for_type/2` (and the batch `for_types/2`) resolves from the `:scope_declarations` manifest key of INSTALLED modules only; in production only a type in the module's own `manages_entity_types` can be declared; an unmanaged type may be declared only by a test-only module on the config allowlist (G2, SEC ruling R-3). Tenant definition JSON is never read. |
| D4 | The compiler takes `scope` as the required third positional argument. `:all` produces the same query as today; for a scoped set the predicate is ANDed as its own outermost `where` and into the ON clause of every joined hop. |
| D5 | By-id scope checks (PUT, DELETE, attachments, tasks) are ONE predicate lookup run after the unconditional set read and BEFORE body parsing (D7 of 0051); the in-transaction recheck (old and new value, F1) is the race backstop and answers the SAME error. |
| D6 | Runtime backstop for resolver and filter routes: before-send assertion that a 2xx response was preceded by a `ScopeGate` call (F9). |
| D7 | Every scope refusal on the data path is the route's existing nonexistent-resource answer. For routes without an id (POST create, import) it is `Response.not_found` (the same bytes as the by-id 404), OQ-2. |
| D8 | The deny-reason set is NOT changed by 518 (no new `Scope.deny_reason()`); a no-new-reason test pins the four copies (section 12.3). |
| D9 | F1 default rule (G1): a caller with a scope narrower than tenant-wide on the route permission may see, claim or complete a task only through a TASK_WORKER grant covering the task's node, evaluated by the named per-role function `Scope.allowed_for_role?/3` (list: `Scope.allowed_set_for_role/2`), plus the existing routing-role checks; NULL node is `:unresolvable`. Assign and reassign use the route permission (`Scope.allowed?/3`). The wider reading (any role allowing the route permission) is OQ-3 only. |
| D10 | Self-service: `:self_service` is declared through the same `scope:` option; the ruled list is `RouteScope`'s committed attribute `@self_service_routes`. Only `GET /me/memberships` is `:self_service` until SEC rules. |

---

# PART A: PR 2c-i

## 3.1 Module map (2c-i-a and 2c-i-b)

PR assignment: PR 2c-i-a owns `types.ex`, `compiler.ex`, `scope_declaration.ex`, `module.ex`, `catalog.ex`, `manifest_hash.ex`, `scope.ex` (`allowed_set/2`), `scope_node_paths.ex`, `script_reads.ex`, the mix task, the three exam files, the fixture and the forced test edits, and the three router call sites with a literal `:all`. PR 2c-i-b owns `scope_gate.ex`, `enforce.ex`, `route_scope.ex`, the router `scope:` options and derivation (`entities.ex`, `me.ex`, `help.ex`), `exam/router.ex` threading, and the snapshot and walk changes. No route class, snapshot line or expectation list changes in 2c-i-a; the ONE route-walk addition that ships in 2c-i-a is the additive walk rule `:exam_route_reclassified` (R-1 condition (a)) in `route_scope.ex`/its walk test (test T-C15), because the literal `:all` at exam sites 7-9 is built in 2c-i-a and its ruling lapses without that guard (CDV r2 recheck).

| File | New / changed | Content |
|---|---|---|
| `lib/letflow/entities/query/types.ex` | changed | `@type scope_set :: :all | {:nodes, [String.t()]} | :none` (single definition; `Scope` and `Compiler` reference it) |
| `lib/letflow/entities/query/compiler.ex` | changed | `compile/3`, `compile_aggregate/3`, `run_aggregate/3`; private `scope_predicate/4`, `hop_scope_predicate/3`; moduledoc "scope" section; the two-argument forms deleted |
| `lib/letflow/entities/scope_declaration.ex` | new | `ScopeDeclaration.for_type/2`, `for_types/2` (3.2) |
| `lib/letflow/modules/module.ex` | changed | optional manifest key `:scope_declarations` in `t:manifest/0`, `defmanifest` literal table row |
| `lib/letflow/modules/catalog.ex` | changed | validation rule 11 (3.2; rules 1-10 already exist in catalog.ex), error `{:invalid_scope_declarations, value}` |
| `lib/letflow/modules/manifest_hash.ex` | changed | covers `scope_declarations` only when present (absent key leaves every existing hash unchanged; test T-D7) |
| `lib/letflow/api/scope.ex` | changed | `allowed_set/2`; shared private effective-scope helper; moduledoc |
| `lib/letflow/scope_node_paths.ex` | changed | `allowed_node_ids/2` |
| `lib/letflow/api/scope_gate.ex` | new | `Letflow.Api.ScopeGate` (3.5) |
| `lib/letflow/api/scope/enforce.ex` | changed | before-send backstop for `{:resolver, _}` and `:filter` (3.6) |
| `lib/letflow/api/route_scope.ex` | changed | flips, expectation lists, `@self_service_routes`, new errors (3.6, 4.2) |
| `lib/letflow/routers/entities.ex` | changed | 3 handlers pass the set; `scope: :filter` on 3 routes (the 7 definitions/restrictions routes and the 8 write/attachment routes are 2c-ii) |
| `lib/letflow/routers/me.ex`, `lib/letflow/routers/help.ex` | changed | `scope:` option per the ruled list (4.2) |
| `lib/letflow/entities/script_reads.ex` | changed | literal `:all` + comment `# scope-all: script principal is tenant-wide, 0051 D1/F6` |
| `lib/mix/tasks/letflow.seed.exam_fixtures.ex` | changed | literal `:all` + comment `# scope-all: mix task, no HTTP user` |
| `lib/letflow/modules/exam/session.ex`, `snapshot.ex`, `anti_cheat.ex` | changed | literal `:all` + `# scope-all: SEC-518-R1` at the three private helpers (R-1 IN, 3.7); `list_available_exams/2` takes the required `:scope` opt |
| `lib/letflow/modules/exam/router.ex` | changed | passes the caller's set to `list_available_exams`  |
| `test/support/modules/fixture_scoped/` | new | fixture module (3.8) |
| `test/support/scope_set_fixture.ex` | new | builds a two-subtree tree, grants and principals for the tests |
| nine existing test files | changed | forced `:all` argument (F1) |

## 3.2 ScopeDeclaration (AC 4)

```
@type declaration :: {:column, field :: String.t()} | :tenant_wide | :undeclared
for_type(entity_type :: String.t(), prefix :: String.t()) :: declaration()
for_types(entity_types :: [String.t()], prefix :: String.t()) :: %{String.t() => declaration()}
```

Resolution (only these inputs): (1) the compiled manifests from `Letflow.Modules.Catalog.entry_modules/0` whose
`:scope_declarations` names the type; no manifest names it -> `:undeclared` with ZERO queries; (2) the module must
be installed in the tenant (`Letflow.Modules.Installs`, one read per `for_types/2` call regardless of the number of
types); (3) the type must be MANAGED by the declaring module (`ManagedTypes.owner_of/2`, one read per call, only for the candidate types): the stamp must equal the declaring module id, otherwise `:undeclared`; an UNMANAGED type resolves to a declaration only when the declaring module id is on the test-only allowlist (below), otherwise `:undeclared` (defence in depth behind Catalog rule 11). A malformed prefix is `:undeclared` (fail
closed; the callers have validated it). A declaration never comes from `definition_json`: a tenant-editable key named
`scope_node`, `scope_column`, `tenant_wide` or similar is ignored (T-D3), and the definitions API has no path to a
manifest (T-D4, existing managed_by rules unchanged).

Manifest key (optional, absent means none): `:scope_declarations :: %{entity_type_name => {:column, field_name} | :tenant_wide}`.
Catalog rule 11 (G2): a map; every key matches the managed-name format `^[a-z][a-z0-9_]{0,63}$` AND is a member of the same manifest's `manages_entity_types`, else `{:scope_declaration_unmanaged_type, name}`, EXCEPT for a module whose id is in `Application.get_env(:letflow, :scope_declaration_unmanaged_modules, [])`; that key is set only in `config/test.exs` (to `["fixture_scoped"]`) and a scan test (T-D8) fails if it appears in `config/config.exs`, `config/prod.exs`, `config/runtime.exs` or `lib/`. So no production module can declare an unmanaged type, and the definitions API cannot create or supersede a declared type (the managed-name rules of REQ-496 already refuse it; this closes OQ-4 for production). Every value is
`:tenant_wide` or `{:column, name}` with `name` in the same format; any other shape is
`{:invalid_scope_declarations, value}`. Further: a type name declared by two modules is `{:duplicate_scope_declaration, name}`
at `Catalog.validate_all`. The column semantics: the field must be a `:string` field of the type that is PROMOTED
(`queried: true`) and indexed (`definition.indexes`); the compiler enforces promotion at run time (3.4): a declared
column that is not a promoted column of the per-type table makes the predicate `false` (fail closed), it never falls
back to the JSON document.

## 3.3 `Scope.allowed_set/2` (D1)

```
@spec allowed_set(Principal.t(), Authorization.permission() | atom()) ::
        {:ok, Types.scope_set()}
allowed_set/2 never returns :all, a partial set or a silent :none because of an error (C-1, INV-8).
```

Error handling (C-1): `ScopeNodePaths.allowed_node_ids/2` can return `{:error, :invalid_node_id | :invalid_schema_name | :too_many_ids}`. In every such case `allowed_set/2` RAISES `Letflow.Api.Scope.ScopeSetError` (a typed internal exception carrying only the reason atom). A DB error raised inside the node reads propagates the same way. The pipeline's error handler maps it to the detail-free 500; exactly one constant log line `scope_set_failed reason=<atom>` per occurrence (no ids, no tenant, no values). A config or data fault is therefore loud, never `:none` (which would look like "you have no data") and never `:all`. A hard cap bounds the expanded set: `allowed_node_ids/2` fails with `:too_many_ids` once the deduplicated expanded set would exceed `Application.get_env(:letflow, :scope_allowed_ids_cap, 50_000)` (SEC suggestion; OQ-7); no truncation, the same raise and 500. The cap key is read from application env so the test can lower it (T-C14); it is not request-controlled.

Decision table (the same order as `allowed?/3` steps 0-7, sharing the private helper that computes the candidate roles
and `combine/1` so the two cannot diverge):

| Condition | Result |
|---|---|
| permission not in `Authorization.permissions/0` | `:none` |
| platform-scope permission | `:all` iff `has_permission_in_scope?`, else `:none` |
| no candidate role | `:none` |
| `PLATFORM_ADMIN` candidate in the platform tenant | `:all` |
| token principal | `:all` (D1: tokens are tenant-wide) |
| grants not loaded | `:none` |
| combined effective `:tenant_wide` | `:all` |
| combined `:deny` (zero rows) | `:none` |
| combined `{:nodes, roots}` | `ScopeNodePaths.allowed_node_ids(roots, prefix)`: `{:ok, []}` -> `:none` (genuinely no live node), `{:ok, ids}` -> `{:nodes, ids}`, `{:error, _}` -> raise `ScopeSetError` (above) |

Agreement property (T-C12): on the fixture tree, for every node `n` and principal kind, `n in allowed_set` iff
`allowed?(p, perm, {:node, n})` is `{:allow, _}` for a scoped principal, and `allowed_set == :all` iff
`allowed?(p, perm, :tenant_wide)` allows. The fixture tree includes a retired INTERMEDIATE node with a live descendant under a grant on a live ancestor (3.8): `allowed?/3` considers only the resource node's own `retired_at`, so the descendant is allowed, the set contains it, and the retired intermediate node itself is absent from the set (C-2).

## 3.4 `ScopeNodePaths.allowed_node_ids/2` and the predicate (AC 2, 3, T1)

```
@spec allowed_node_ids(root_ids :: [node_id()], prefix :: String.t()) ::
        {:ok, [node_id()]} | {:error, :invalid_node_id | :invalid_schema_name | :too_many_ids}
```
Roots chunked by 500 (the `descendants_of/2` cap) so no input is rejected; per chunk the two statements of
`descendants_of/2` (the paths of the roots, then one `LIKE ANY` over the escaped patterns, `%` `_` `\` escaped by
`like_prefix_pattern/1`, bound parameters, INV-7); retired nodes filtered out; result deduplicated and sorted. For up
to 500 roots the cost is exactly 2 statements. This is the ONLY tree access of the data path.

Predicate shape (prose). For a primary or joined binding of entity type `T` with declaration `d`, scope `s`:

| `s` | `d` | Predicate on `T`'s binding |
|---|---|---|
| `:all` | any | none (the query is the one built today; asserted by SQL equality, T-C1) |
| `:none` | any | constant `false` |
| `{:nodes, ids}` | `:tenant_wide` | none (T16: masters readable once the coarse check passed) |
| `{:nodes, ids}` | `:undeclared` | constant `false` |
| `{:nodes, ids}` | `{:column, f}`, binding `{:per_type_table, _}`, column `f` physically present | `f IN (bound text[] of ids)`; NULL never matches (T6) |
| `{:nodes, ids}` | `{:column, f}`, binding `:latest` or column absent | constant `false` (fail closed, no JSON fallback) |

The presence test uses `relation_column_exists?/3` (the existing information_schema primitive) once per declared
`{:column, _}` binding, and the column name is always taken from the declaration (format-validated), never from the
request, and bound as a field reference (`field(binding, ^name)`), never concatenated. The id list is ONE bound
parameter typed as a string array.

Placement:
- Primary: an additional `where` ANDed to the query at the outermost level (separate from the user filter dynamic) in
  `compile_plain` (both branches), `compile_joined`, `aggregate_base_plain`, `aggregate_base_joined`; therefore
  before `group_by`, aggregate select, cursor resume filter, `order_by` and `limit` which are applied afterwards or
  to the same query (`Cursor.paginate/5` adds its resume filter and limit to the returned query).
- Every joined hop (AC 3): the hop's `on:` dynamic gains `AND <predicate of hop.to_entity_type on hop.to_alias>`.
  The ON position gives the required semantics for both join types: a LEFT join keeps the primary row with a NULL
  target when the target is out of scope, an INNER join drops the row. The `through` entity of a two-hop join is
  scope-filtered by its own declaration on the near hop, so an out-of-scope through row also NULLs the far hop.
  An undeclared target yields `false` in the ON clause (a left join returns NULL, nothing leaks).
- `compile/3` calls `ScopeDeclaration.for_types/2` ONCE with the primary and all hop target types, only when `s` is not `:all`.
- Argument guard: `:all`, `:none`, or a `{:nodes, list}` tuple; anything else raises (programmer error, no
  fail-open default). `{:nodes, []}` is treated as `:none`.
- Export (`handle_export_records`) reuses the compiled query: no second code path (AC 2). The cursor carries no set
  (T3); every page recompiles with the CURRENT set (AC 10).

Public API after 2c-i-a:

```
@spec compile(Types.query_request(), prefix :: String.t(), Types.scope_set()) ::
        {:ok, Ecto.Query.t()} | compile_error()
@spec compile_aggregate(aggregate_request(), prefix :: String.t(), Types.scope_set()) ::
        {:ok, Ecto.Query.t()} | aggregate_compile_error()
@spec run_aggregate(aggregate_request(), prefix :: String.t(), Types.scope_set()) ::
        {:ok, [map()]} | aggregate_compile_error()
```
No new error tuple is added to `compile_error()`: a scope failure is never an error, it is an empty result.

## 3.5 `Letflow.Api.ScopeGate` (D2, D6)

```
@spec scope_set(Plug.Conn.t(), policy_key :: atom()) :: {Plug.Conn.t(), Types.scope_set()}
@spec resource_allowed?(Plug.Conn.t(), policy_key :: atom(), Scope.resource_scope()) :: {Plug.Conn.t(), boolean()}
@spec mode(Plug.Conn.t()) :: :off | :shadow | :on
```
- `mode/1` reads `auth_context.scope_enforcement` (the per-request value `AuthPipeline` stores; key absent -> `:off`).
- `scope_set/2`: sets the marker `conn.private[:letflow_scope_applied]`; mode not `:on` -> `{conn, :all}` with NO
  query; `:on` -> `Scope.principal_from_conn/1` then `Scope.allowed_set(principal, Authorization.required_permission(key))`;
  `{:error, :no_principal}` -> `:none`; the result is memoised in `conn.private` per permission, so a request does
  the allowed-node-set read at most once (AC 5).
- `resource_allowed?/3` : mode not `:on` -> `{conn, true}` without a read; `:on` -> `Scope.allowed?/3`.
- Never raises on a missing principal; a DB error propagates to the pipeline's detail-free 500 (INV-8).

## 3.6 Route-class plumbing (AC 18, 19, 20, 21; F8, F9)

`RouteScope` as built keeps the key-table-first order. Changes:

| Item | Change |
|---|---|
| Flags | `@self_service_routes_allowed?` becomes true in PR 2c-i-b; `@expected_filter_routes` becomes the committed list of `{method, full_path}` of the `:filter` routes (2c-i-b: three entity routes; 2d adds `GET /tasks`, `GET /tasks/inbox`); NEW `@expected_resolver_routes` (2c-ii: 8 entity routes; 2d: 5 task routes). The walk fails `:unexpected_filter_route` / `:unexpected_resolver_route` for a route of that class not on the list AND for a listed route that no longer has the class (SEC 517 F-1 required action). |
| Walk errors added | `:unexpected_resolver_route`, `:self_service_not_listed`, `:self_service_list_mismatch`, `:tenant_wide_unruled`, `:pending_marker_unlisted` (4.2), `:data_route_default` (a route of `routers/entities.ex` or `routers/tasks.ex` whose source is `:default`), `:exam_route_reclassified` (any route mounted by the exam entry module that is not `:tenant_wide`; ships in 2c-i-a, R-1) |
| Snapshot | `test/fixtures/route_scope/tenant_wide_default_routes.txt` loses exactly the lines of the reclassified or explicitly declared routes (28 of the 143 lines belong to entities, tasks, me and help); `:stale_snapshot` makes the removal mandatory |
| `Enforce.check/3` | for `{:resolver, _}` and `:filter`: `Plug.Conn.register_before_send/2` of an assertion: in a 2xx response without the marker, replace the response by the detail-free 500 and log one constant line `scope_not_applied` (no ids). `:self_service` and the others are unchanged. `off`/`shadow` untouched (the check lives in the `:on` branch only) |
| `Shadow.observe/3` | unchanged (already counts resolver, filter and self-service as requests only) |

R-4 (ruled IN as a DETECTIVE control, section 8): the before-send check detects a handler that omitted `ScopeGate`; it does not make a response safe and the marker proves "gate called", not "result applied". It fires only in the `on` branch and only for 2xx responses; its callback rescues itself and answers the same detail-free 500 as `Enforce.fail_closed`. `ScopeGate` returns `{conn, set}`: handlers must continue with the returned conn, because it is the conn that is finally sent (advisory A-6).

## 3.7 The nine call sites (AC 1) and SEC ruling R-1

| # | Site | Value | Rule |
|---|---|---|---|
| 1 | `routers/entities.ex` run_query | 2c-i-a: literal `:all` (route still `:tenant_wide`); 2c-i-b: `ScopeGate.scope_set(conn, :EntitiesQuery)` result | derived from the caller's effective scope; token, tenant-wide, platform admin -> `:all`; scoped -> `{:nodes, ids}`; none -> `:none` |
| 2 | `routers/entities.ex` run_export | `scope_set(conn, :EntitiesRecordsExport)` | same |
| 3 | `routers/entities.ex` run_query_aggregate (`run_aggregate/3`) | `scope_set(conn, :EntitiesAggregate)` | same |
| 4 | `entities/script_reads.ex` | literal `:all` | `# scope-all: script principal is tenant-wide, 0051 D1/F6` |
| 5 | `mix/tasks/letflow.seed.exam_fixtures.ex` | literal `:all` | `# scope-all: mix task, no HTTP user` |
| 6 | `exam/session.ex` `list_available_exams/2` | required `opts` key `:scope`; in 2c-i-a `exam/router.ex` passes a literal `:all` with `# scope-all: exam routes are :tenant_wide until reclassified (walk guard :exam_route_reclassified)`; in 2c-i-b it is `ScopeGate.scope_set(conn, :ExamSessionStart)` | threaded (no ruling needed). A missing key raises |
| 7 | `exam/session.ex` `query_all/3` (private; 11 call sites inside `create_txn`, `get_session_state_for_user`, `fetch_*`, `upsert_answer`, `load_answers`, `submit` flows) | literal `:all` + `# scope-all: SEC-518-R1` (R-1 IN) | see below |
| 8 | `exam/snapshot.ex` `query_all/3` (private, `build_late` and `load_item`) | same ruling | same |
| 9 | `exam/anti_cheat.ex` `query_events/2` | same ruling | same |

Ruling R-1 (sites 7, 8, 9; the AC forbids "T14 system path" as the justification, so the argument is different):
(a) all three read exam-module types that no manifest declares (`:undeclared`), and under a scoped set an
undeclared type returns no data, so threading a scoped set would make the exam module return nothing instead of
enforcing anything; (b) each runs only after an ownership gate on a record the caller owns (`check_owner`, session
lookups by the caller's own `user_id`); (c) every exam module route is default-sourced `:tenant_wide`, so under `on` a
scoped-only principal is refused (403) before any exam code runs, and tenant-wide and token principals are `:all` by
D1; (d) a self-expiring guard: a route-walk rule `:exam_route_reclassified` fails if any exam module route stops
being `:tenant_wide` while the exam module declares no `:scope_declarations`, and the scan test fails if an exam
manifest gains one while the three sites still carry the literal. RULED IN by SECURITY-REVIEWER (id `SEC-518-R1`, design gate step-04); the literal `:all` with the comment
`# scope-all: SEC-518-R1` is the BUILD DEFAULT at sites 7, 8 and 9, and the threading fallback is removed from this design.
Conditions (the ruling lapses automatically if either guard is removed): (a) the walk rule `:exam_route_reclassified` and
the scan test (an exam manifest that gains `:scope_declarations` while a literal remains) are MANDATORY tests in 2c-i-a
and 2c-i-b; the walk rule covers ANY route of the `exam` module, including routes added later, not only the 8 current
`exam-sessions` routes (it asserts every route mounted by the exam entry module is `:tenant_wide`); (b)
`list_available_exams/2` keeps its required `:scope` opt (site 6, threaded).

Scan test (AC 1): `test/letflow/entities/scope_all_scan_test.exs` parses `lib/**/*.ex` (AST, not grep) for calls to
`compile`, `compile_aggregate` and `run_aggregate` of the Compiler (alias-aware) and fails for a literal `:all` third
argument outside `lib/letflow/routers/entities.ex` unless the call or the line above carries a comment of the form
`# scope-all: <rule or ruling id>`. The same test is extended in 2c-ii and 2d to the Records scope key and the Tasks
scope key (section 5.7, C.4). It also asserts function_exported?/3 true and /2 false for the three functions.

## 3.8 Fixture module (AC 2, 3, 4 tests)

`test/support/modules/fixture_scoped/fixture_scoped.ex`: manifest id `fixture_scoped`,
`scope_declarations: %{"scoped_item" => {:column, "scope_node"}, "scoped_child" => {:column, "scope_node"},
"scoped_master" => :tenant_wide}`, `manages_entity_types: ["scoped_managed_item"]` plus a fourth declaration `"scoped_managed_item" => {:column, "scope_node"}` (managed: read tests, the constant 403 on writes, T-W18); the module id is on the test-only allowlist so the three other types stay UNMANAGED and tenant-writable (F3, R-3), a pack defining the three types (`scoped_item`: string `scope_node` queried and indexed, string `name`, integer
`amount` for sums; `scoped_child` with an fk to `scoped_item` for the joins; `scoped_master`), activated and promoted at
install. A second type `plain_undeclared` is created by the test as an ordinary tenant type. The fixture tree
(`test/support/scope_set_fixture.ex`): `root` with subtrees `a` (children `a1` and `a2`; `a2` is RETIRED and has a LIVE child `a2x`, the retired-intermediate case of C-2; a grant on `a` must reach `a2x` and not `a2`) and `b` (child `b1`), a retired leaf `a3`; principals: scoped TASK_WORKER on `a`, scoped on `a` and `b1`, tenant-wide TASK_WORKER, zero-row binding,
token principal, platform admin.

## 3.9 Cost (AC 5)

Extra statements per request for a scoped OIDC caller: `Scope.allowed_set/2`: 2 (3.4), once, memoised; the grants
load is the existing one-per-request memo (`auth_context.scope_grants`); `ScopeDeclaration.for_types/2`: 0 when no
manifest names a requested type, otherwise 1 (installed modules) + 1 (`owner_of`, only for candidate types); one
`relation_column_exists?` read per declared column binding. Token principal: 0 extra and the single-query token path
is untouched. `:all`: 0 extra. Not `on`: 0 extra. Query-count tests (T-C9) compare against a baseline of the same
request for a tenant-wide caller, and assert the REQ-497 token and OIDC shapes unchanged.

---

# PART A2: AC 21, the `:self_service` class

## 4.1 Definition (restated, binding)

`:self_service` = a tenant-level, non-sensitive, role-independent read: the response is either the caller's own
principal data or tenant-level metadata with no per-resource data (no entity record, task, instance or attachment),
and a caller-supplied id may appear only as a FILTER, never to select a resource the caller must be scoped for. It
shares the `scope:` option mechanism and the key table / default order of 517 (no second table).

## 4.2 `@self_service_routes` and walk rules

A committed attribute of `Letflow.Api.RouteScope` (the module that owns the classification); the AC 21 tests read it
and nowhere else:

```
@self_service_routes :: [%{route: "METHOD FULL_PATH", key: atom(), class: :self_service | :tenant_wide,
                           ruling: String.t() | :pending_sec_ruling}]
```

State after the SEC design-gate rulings (section 8, step-04): all three are `:self_service`; no `pending_sec_ruling` entry remains, and the marker rules of the walk stay for any future route:

| route | key | class | ruling |
|---|---|---|---|
| `GET /me/memberships` | `:MembershipsRead` | `:self_service` | `0051-A7` (the 517 SECURITY-REVIEWER ruling that fixed this single member, amendment A7) |
| `GET /me/modules` | `:MyModulesRead` | `:self_service` | `SEC-518-R2-modules` |
| `GET /help/resolved` | `:HelpRead` | `:self_service` | `SEC-518-R2-help` |

A row changes in this list only: `class: :self_service` plus the ruling id, or `class: :tenant_wide`
plus the id (the "SEC-ruled tenant-wide" state). The route declaration (`scope: :self_service` in `me.ex`/`help.ex`) is
changed in the same PR.

Walk errors (AC 21 (i)): every route under `/me` and `/help` appears in the list (`:self_service_not_listed`); the set
of routes with class `:self_service` equals EXACTLY the list entries classed `:self_service`
(`:self_service_list_mismatch`, so adding a route to the class means editing the list); a `:tenant_wide` entry carries
a ruling id or the marker, and a `/me` or `/help` route that is `:tenant_wide` with neither fails
(`:tenant_wide_unruled`); a marker on a route not in the list fails (`:pending_marker_unlisted`). A
`:pending_sec_ruling` entry is printed by the walk in a stable line the PR body copies, and is the REQ-519 AC 9 blocker.

## 4.3 Runtime

`Enforce` already passes `:self_service` through after the coarse allow; `Authorize` already never reaches
`apply_scope_mode` for an unauthenticated request (the allow branch only). The three handlers need no code change
(they read `auth_context`/tenant data only); the class is declared. AC 21 (v): the response of `GET /me/memberships`
is built from `auth_context.user_id` and the normalized email subject key of THAT user (read: `handle_list_memberships`
passes `Identity.list_memberships_for_subject(subject_key)` of the caller's own row); the test creates a second user
with memberships and asserts none of them appears.

## 4.4 Rulings recorded (R-2, step-04)

Class definition 4.1: IN, with the added sentence: no field derived from a resource the caller must be scoped for may be
added to a `:self_service` response; adding one requires a new ruling and an edit of `@self_service_routes`.
`GET /me/memberships`: `:self_service` under 0051-A7. `GET /me/modules`: IN (`Installs.list_installed(prefix:)` is
tenant-level module metadata with no caller filter; `:MyModulesRead` is already held by every role including CANDIDATE),
id `SEC-518-R2-modules`. `GET /help/resolved`: IN, id `SEC-518-R2-help`, with the CONDITION (replaces the designer's
wording): `process_definition_id` stays only a FILTER over help rows, `stale` is computed from the SELECTED HELP ROW's own
`process_definition_id` via `Definitions.get_by_id`, never from the request id, so the route is not a definition-existence
oracle; the response may carry no field read from `Definitions` beyond the existing boolean; a change that probes
`Definitions` with the request id re-opens the ruling. Test T-S9: a `process_definition_id` naming an existing definition
with no help row and one naming no definition give byte-identical responses for a scoped-only user.

---

# PART B: PR 2c-ii

## 5.1 Module map (2c-ii)

| File | New / changed | Content |
|---|---|---|
| `lib/letflow/entities/scoped_lookup.ex` | new | by-id predicate lookup (5.2) |
| `lib/letflow/entities/scoped_writes.ex` | new | type gate, new-value check, import pre-check (5.3, 5.4) |
| `lib/letflow/entities/scope_resolver.ex` | new | `record_scope/1` resolver for the route walk and create/import (5.6) |
| `lib/letflow/entities/records.ex` | changed | optional attr `:scope` on create/update/delete; in-transaction recheck step (5.3) |
| `lib/letflow/routers/entities.ex` | changed | 8 handlers re-ordered; `scope: {:resolver, ...}` on 8 routes (5.6) |
| `lib/letflow/repository/entity_attachments.ex` | unchanged | handlers gate on the parent before calling it |
| `lib/letflow/api/route_scope.ex`, snapshot file | changed | 3.6 |

## 5.2 ScopedLookup (AC 6, 11; D5)

```
@spec fetch_in_scope(entity_type :: String.t(), record_id :: Ecto.UUID.t(), Types.scope_set(), prefix :: String.t()) ::
        {:ok, :visible} | :not_found
```
One statement. For scope `:all`: not called by the routers (existing path unchanged). For a scoped set: the type's
declaration decides the statement (all with the record id and `deleted = false` NOT part of the predicate, the
existing `Records` logic keeps its own `deleted`/already-deleted answers):

| declaration | statement |
|---|---|
| `{:column, f}` on a per-type table | `SELECT 1 FROM <table> WHERE record_id = $1 AND f IN (ids)` |
| `:tenant_wide` type, scoped caller | the writes are refused for scoped callers (5.3), so by-id write routes answer not found without a statement |
| `:undeclared`, `:latest` source, `:none` | no statement; `:not_found` |

Parent lookup for attachments uses the same function. "The allowed-node-set read runs unconditionally before it":
the handler calls `ScopeGate.scope_set/2` FIRST in every case, so a nonexistent id, an out-of-scope id and an
in-scope id all pay the same set read; the lookup statement is issued in the same cases for all (a declaration that
needs no statement is the same for both ids of the compared pair). Telemetry (0051 D8: scope 404s are counted, NOT audited): on every refusal `ScopedLookup`, `ScopedWrites`, `Tasks.in_scope/3` and the attachment parent gate emit `[:letflow, :scope, :not_found]` with measurements `%{count: 1}` and metadata `%{policy: policy_key_atom, kind: :by_id | :write_value | :import | :attachment_parent | :task}` (closed atoms only; no id, node, set or tenant). It is emitted identically for a nonexistent and an out-of-scope id (one query cannot tell them apart), so it is a count of both, never an oracle. No metrics-registry family is added (deferred, with the shadow-evidence reporting, to REQ-519 AC 12); test T-W19 asserts the event and its metadata keys. Test T-W1 compares the Ecto-telemetry statement
count of an out-of-scope and a nonexistent id per route and asserts byte-identical status, body and headers
(request id and date excluded and named; no ETag or Last-Modified in either).

## 5.3 Writes: order, old and new value (AC 7, 8; T12, M9)

Handler order for PUT and DELETE (scoped caller; `:all` callers take today's path unchanged):
1. `guard_tenant_write` (constant 403 for managed types, unchanged, answer independent of id/body/scope);
2. `cast_record_id` (malformed -> the existing 404);
3. `ScopeGate.scope_set`, then `ScopedLookup.fetch_in_scope`; `:not_found` -> `Response.not_found`;
4. only now `object_body`, `validate_schema`, then (PUT only) the PURE new-value check of C-3 (below), then idempotency, and for DELETE the `expected_last_event_global_seq` query-parameter parse (CDV r0a: it is resource validation that returns 400 today and so must also follow the lookup) (so a malformed or schema-invalid body for an out-of-scope
   or nonexistent id gives the SAME 404, AC 7);
5. `Records.update_record/delete_record` with the attr `scope: set`.

C-3 (INV-5, SEC): pure NEW-value check BEFORE the transaction and before the idempotency claim, for create and update.
`ScopedWrites.check_new_value(field_values, declaration, scope_set) :: :ok | :refused` has no I/O (set membership of the
declared column's value; missing, null or non-string is refused; `:tenant_wide`/`:undeclared` types refused for a scoped
set). The router runs it right after the envelope validation and BEFORE `Idempotency.from_body`, before
`put_legacy_original/4` (which reads events) and before `Records` is called, answering `Response.not_found`. Therefore a
scoped caller replaying an existing idempotency key with a body that names an out-of-scope node gets the generic 404, never
the stored record's id or version (a key created by another caller is not confirmed). Replay of a key whose request value
IS in scope behaves as today (pre-existing key semantics, advisory A-3). The in-transaction `:scope_check` below stays as
the race backstop (old value, and the new value again). Tests T-W22 (replay of a key created by another caller with an
out-of-scope value, create and update: generic 404, no stored id/version in body or headers) and mutant MU39.

Type-gate answer (C-6, advisory A-2): for create and import the type-gate refusal (undeclared or `:tenant_wide` type, scoped
caller) is `Response.not_found`, byte-identical to the answer for a NONEXISTENT type name (`definition_not_found` is folded to
`Response.not_found` by `render_record_command`); test T-W23. Type existence is tenant-level metadata, not a scoped resource
(definitions routes are tenant-wide only). On `POST /entities/query` the accepted difference is documented: an undeclared
existing type gives the empty page, a nonexistent type gives the `RequestAccess` error envelope.

`Records` gets the optional attribute `:scope` (default `:all`; the AC 1 style scan, 5.7, forces explicit use at every
call site outside the router and the test fixtures). With a scoped set, inside the transaction after the per-type
sequence lock and idempotency check (where `maybe_check_record_version` already re-reads the row `FOR UPDATE`), a new
step `:scope_check`: (old) the locked row's scope column value must be in the set; (new, update only) the validated
`field_values[f]` must be a string in the set; a missing, null or non-string new value is refused; `:tenant_wide`
and `:undeclared` types are refused for a scoped set. Refusal is `{:error, :scope_refused}` rolling the transaction
back (nothing appended), rendered as `Response.not_found` by `render_record_command` (same bytes as the by-id 404,
D7). It is race-only for the old value (the lookup in step 3 already saw it) and the authoritative check for the new
value. A PUT that does not mention the scope field when the type is scope-aware is refused as a NULL (scoped caller).

POST create (scoped caller): after `guard_tenant_write`, the type gate (`ScopedWrites.type_gate/3`: undeclared or
`:tenant_wide` type -> refused before the body is read, OQ-5), then the envelope validation, then `Records.create_record`
with `scope:`; the new value is checked FIRST by the pure `ScopedWrites.check_new_value/3` right after the envelope validation and BEFORE `Idempotency.from_body` (C-3, T-W22), and again in the same `:scope_check` step as race backstop; refused -> `Response.not_found`. A tenant-wide
caller may create a NULL-scope record on a scope-aware type (visible then only to tenant-wide holders; D6 text). A
nonexistent, retired, malformed and out-of-scope node id all give the identical answer (T16): the check is set
membership, never a node read.

Scope column not writable through a field-level bypass (AC 8): the check is on the final validated `field_values` for
every caller path of `Records` that passes a scoped set, regardless of `FieldGrants`/`FieldPolicy` (read-side
redaction and write restrictions run before and cannot lift it); test: update the scope field with and without a
field write permission, both refused when the new node is out of scope.

Module actions (AC 8, last clause): any module code that writes on behalf of an HTTP user passes the user's set as
`scope:` to the `Records` function; the fixture module's test action exercises it (T-W6). No production module
action exists for a scoped caller yet (module routes are `:tenant_wide`).

## 5.4 Import: all-or-nothing (AC 9)

`import_records_unmanaged` order for a scoped caller: existing structural checks first (200-record cap, schema
version, entity type match: they concern the document, not resources); then the type gate; then
`ScopedWrites.check_batch(entries, declaration, set)` over EVERY entry (value of the scope field must be a string in
the set; this covers "old OR new" for the import's only value); any failure refuses the whole batch with ONE answer
(`Response.not_found`, no row count, no per-row detail, independent of which row or reason) and NOTHING is written;
all valid -> the existing per-entry loop runs with `scope: set` on each `create_record` (same set, so no per-entry
scope refusal can occur). Per-entry validation failures of in-scope rows keep today's partial-success results.
Residual R-3: a grant revoked while the loop runs is not observed until the next request (the loop is bound to the
request's snapshot, as every request is).

## 5.5 Record attachments (AC 11; F6)

Each of the four handlers (create, list, get content, delete) calls `ScopeGate.scope_set` then
`ScopedLookup.fetch_in_scope(entity_type, record_id, set)` for the PARENT. On `:not_found` the handler continues into
the branch the nonexistent parent takes today without touching the attachment tables. For CREATE the gate runs before `record_attachment_upload_attrs_from_conn` (the multipart read, `File.read!`) and before the scan: an out-of-scope parent and a nonexistent parent BOTH short-circuit to `Response.not_found` before the upload part is examined, so even a missing file part gives 404, never 422, for them (for `:all` callers the order is unchanged and a nonexistent parent still reaches the FK changeset 404). create -> 404; list -> the
EMPTY 200 page `{"items": [], "next_cursor": null}`; get content -> 404; delete -> 404. Test per route: out-of-scope
parent vs nonexistent parent, identical status/body/headers and statement count; a scoped caller cannot attach to,
list, read or delete an attachment of an out-of-scope record. For `:all` callers no gate statement runs. Existing
attachment-id/record-id cross-checks (`fetch_scoped_record_attachment_*`) are unchanged.

## 5.6 Resolvers (AC 19)

```
Letflow.Entities.ScopeResolver.record_scope(%{declaration: ScopeDeclaration.declaration(), field_values: map()}) ::
    Scope.resource_scope()      # :tenant_wide for :tenant_wide; {:node, v} for {:column, f} with a binary v; :unresolvable otherwise
```
Exported (arity 1) so the walk's `function_exported?/2` rule holds; used by create/import to compute a row's
resource scope; membership in the already-computed set is the decision (no per-row node read).

## 5.7 Revocation (AC 10) and scan extension

Revocation needs no state: the first request after a grant row is deleted or a node moved recomputes
`allowed_set` from the live tables (no cache; the memo is per request). Test: page 1 with a cursor, delete the grant
row, page 2 of the SAME cursor returns only currently allowed rows (the cursor test decodes the cursor and asserts no
node id or set is inside it); move a subtree and see the new scope on the next request. The scan test of 3.7 is
extended: any call of `Records.create_record/update_record/delete_record` in `lib/` outside
`lib/letflow/routers/entities.ex` and the already-listed authority callers passes a `scope:` key or carries a
`# scope-all: <rule>` comment (the default `:all` exists only for system callers: engine step writes (F11), exam
module (R-1 family), seed tasks).

---

# PART C: PR 2d

## C.0 Commit order of PR 2d (each commit compiles and passes the tests that exist at it)

1. Migration `20261019100001`, manifest registration, `Task` field (no cast), `TaskScopeFixture`, scan T-F2, migration tests T-F1. No behavior change.
2. `Scope.allowed_for_role?/3` and `Scope.allowed_set_for_role/2` (pure additions in `scope.ex`), unit tests incl. the agreement property for roles (T-F16).
3. `Tasks.ScopeResolver`, `Tasks.in_scope/3`, `Tasks.f1_allowed?/3`, the `:scope` param of `list_tasks/2` and `get_task/2`, the `f1` opt and the `:f1_scope` step of `claim_task/3` and `Engine.complete_task/3`, `ScopeGate.scope_set_for_role/3`. All default to today's behavior when the opt is absent; tests T-F3..T-F12, T-F14, T-F15 pass here against the context API with `f1` supplied directly.
4. Router handlers pass the set and `f1` (from `ScopeGate`), the seven `scope:` classes, expectation lists and the removal of the 7 snapshot lines; route-walk and ledger tests T-L12..T-L18, T-L19..T-L27. This is the only commit that changes route classes, so the only one the SEC pass must read line by line (SEC C-2).
5. `docs/roles.md` section and T-F13.

## C.1 Column (AC 12)

Migration `priv/repo/migrations/20261019100001_add_scope_node_id_to_tasks.exs`: tenant-scoped, `if prefix() do` guard,
registered in `@tenant_scoped_migration_manifest` after the last entry (the 517 `20_261_018_200_002` scope shadow
counters) as `{20_261_019_100_001, Letflow.Repo.Migrations.AddScopeNodeIdToTasks, "20261019100001_add_scope_node_id_to_tasks.exs"}`;
moduledoc counts moved. `ALTER TABLE "<schema>".tasks ADD COLUMN scope_node_id text NULL` and constraint
`tasks_scope_node_id_fkey` (24 bytes) `FOREIGN KEY (scope_node_id) REFERENCES "<schema>".scope_node_paths (node_id) ON DELETE
RESTRICT` (only interpolation: the schema from `prefix()`, INV-7), partial index `tasks_scope_node_id_idx` on
`(scope_node_id) WHERE scope_node_id IS NOT NULL`. `down` drops index, constraint, column, guarded by `to_regclass`.
No new table: `@expected_tenant_tables` and its paired count are unchanged (anti-patterns: oracle edit rule N/A, asserted
by T-F1). The test clone path re-adds foreign keys (`TenantTemplate`), asserted on a replayed and a cloned tenant.
`Letflow.Tasks.Task` gets `field :scope_node_id, :string` in NO cast list; the only writer is the test-support
`Letflow.Support.TaskScopeFixture.set_scope_node!(task_id, node_id, prefix)` (direct SQL). Source-scan test T-F2:
no `lib/` code writes the column (patterns: `scope_node_id` in `cast`, `put_change`, `change`, `update_all`, raw `SET`,
`Repo.insert` of a `%Task{scope_node_id:` literal).

## C.2 Resolver and gate (AC 13-15, 20; D9)

```
Letflow.Tasks.ScopeResolver.task_scope(Task.t()) :: Scope.resource_scope()   # nil node -> :unresolvable; binary -> {:node, id}
Letflow.Tasks.in_scope(task_id :: String.t(), Types.scope_set(), opts) :: :ok | {:error, :task_not_found}
    # ONE statement: the tasks row WHERE id = $1 AND scope_node_id IN (ids); :none and NULL never match; an id that
    # does not cast maps to the route's existing invalid-id answer BEFORE the set read, as today (no oracle)
Letflow.Tasks.f1_allowed?(Task.t(), Scope.Principal.t(), permission) :: boolean()
    # Scope.allowed?(principal_with_FRESH_grants, permission, task_scope(task)) is {:allow, _}
```
`Tasks.resolve_principal_scope/2` stays the single reader of groups and roles. It is EXTENDED, per D4/AC 13, with an
optional `:scope` field in its result map `principal_scope()` (`allowed_nodes :: Types.scope_set()`), computed only when
the caller supplies a principal (`resolve_principal_scope(user_id, opts)` with `opts[:f1]` set); with `f1` absent the
result is exactly today's map (existing tests unedited).

The set given to `in_scope/3`, `list_tasks/2` and `get_task/2` for the five F1 routes (get, list, inbox, claim, complete) is `ScopeGate.scope_set_for_role(conn, policy_key, "TASK_WORKER")`; for assign and reassign it is `ScopeGate.scope_set(conn, policy_key)` (route permission).

Handler order (claim, complete, assign, reassign, get), scoped caller in `on`: set read, `Tasks.in_scope/3`; failing
-> the route's existing answer for a nonexistent task (`{:error, :task_not_found}` -> 404 on claim/complete/assign/
reassign/get), then the existing code. The existing "in scope but outside the routing role" errors
(`assignee_group_not_member`, `assignee_role_not_held`, `assigned_to_other_user`) are unchanged and come AFTER the
scope gate (AC 14).

List and inbox (AC 14): `Tasks.list_tasks/2` params gain `:scope` (a `Types.scope_set()`); `{:nodes, ids}` adds the
predicate `scope_node_id IN (ids)` (NULL excluded), `:none` adds `false`, `:all` nothing. It COMPOSES with the
existing `filter_by_assignee_scope` by AND (intersection). `count` and the cursor page therefore exclude out-of-scope
tasks; the cursor holds no set. `get_task/2` gets the same optional `:scope` param (one query with the predicate).

## C.3 The F1 rule (AC 13; G1)

Named per-role functions in `Letflow.Api.Scope` (the only place a scope decision is made; they reuse the same private
`effective_scope/2` and `decide_resource` logic as `allowed?/3`, so the rules cannot diverge):

```
@spec allowed_for_role?(Principal.t(), role :: String.t(), resource_scope()) :: decision()
    # only the effective scope of THAT role name counts (tenant_wide row -> allow; nodes -> subtree test as allowed?/3;
    # role not held, grants not loaded, zero rows, retired or unresolvable node -> the same deny reasons)
@spec allowed_set_for_role(Principal.t(), role :: String.t()) :: {:ok, Types.scope_set()}
```

Task gate `Tasks.f1_allowed?(task, principal, route_permission)`: (1) if the principal is NOT narrower than tenant-wide
on the route permission (`Scope.allowed?(principal, route_permission, :tenant_wide)` allows: a tenant-wide holder, a token
principal, a platform admin) the grant requirement does not apply and today's behavior is unchanged (a tenant-wide
PROCESS_OPERATOR or TENANT_ADMIN keeps working); (2) otherwise the caller must hold a TASK_WORKER grant covering the
task: `Scope.allowed_for_role?(principal, "TASK_WORKER", Tasks.ScopeResolver.task_scope(task))` allows. A scoped
PROCESS_OPERATOR or TENANT_ADMIN WITHOUT a TASK_WORKER grant is therefore refused (negative test T-F15), and a scoped
caller's other-role grants never widen the task view. Lists and `in_scope/3` use the same rule through
`allowed_set_for_role(principal, "TASK_WORKER")` (when (1) does not apply).

A user may see, claim or complete a task iff (routing) the existing checks pass: for the worker-only `list`/inbox the
`{:own_user_and_groups}` row scope; for claim/complete the `USER`/`GROUP`/`ROLE` assignee rules of
`apply_claim`/`apply_completion_authz`, where a role is held through a group (the existing `resolve_principal_scope`
fresh queries) AND (grant) the rule above, so:
(a) routing role + TASK_WORKER grant on an ancestor: allowed; (b) TASK_WORKER grant on a sibling subtree: refused
(404-equivalent); (c) outside the routing role with a covering grant: the existing error (403/409 per route); (d)
tenant-wide TASK_WORKER in the routing role: allowed; (e) NULL node: refused for scoped, allowed for tenant-wide.
Task nodes in tests are set by `TaskScopeFixture`.

Assign and reassign (not in AC 13's text; AC 20 classifies them): scope gate with the ROUTE PERMISSION
(`:TasksAssign`, `:TasksReassign`) through `Scope.allowed?/3` over the task's node, no TASK_WORKER requirement and no
routing-role rule beyond what exists; recorded so the ledger has no unclassified task route.

The wider reading (the union of the roles that allow the route permission, so that a scoped PROCESS_OPERATOR grant on the
node would suffice) is NOT built; it stays OQ-3 pending the RA-10 amendment.

## C.4 Engine path (AC 15)

`Engine.complete_task/3` and `Tasks.claim_task/3` take an optional opt `f1: nil | Scope.Principal.t()` (nil means the
flag is not `on`: the F1 branch is selected ONLY by the per-request flag, AC 16; the router sets it from
`ScopeGate.mode/1` and the conn's principal; token principals pass the F1 gate as tenant-wide). With a principal, a new Multi
step `:f1_scope` runs right after the task row is locked and before any transition/SoD step: it reloads the grants of
the actor with `Scope.load_grants(user_id, prefix)` INSIDE the transaction (fresh, not the request memo, so group membership is fresh too), then
`Tasks.f1_allowed?/3`; refusal rolls back and returns `{:error, :task_not_found}` (the same 404 as a nonexistent
task). So a claim made before a grant was revoked cannot complete after the revocation (T-F9). SoD
(`distinct_from`, REQ-463) code paths and their tests are untouched. The scan test of 3.7 is extended to the
`f1`/`scope` keys of `list_tasks`, `get_task`, `claim_task`, `complete_task` callers in `lib/`.

Lock order (C-4): `:f1_scope` is a PLAIN READ: no `FOR SHARE` or `FOR UPDATE` on `role_scope_grants`, groups, bindings, org
or `scope_node_paths` rows, and no advisory lock. It runs on the transaction's own repo handle (the Multi's `repo`
argument), after the task row lock and before the transition steps. It therefore adds no lock and the orders stay
untouched: the 517 admin-plane order (A, R, G, N, B, C) and the engine order of GH #2704. Test T-F17: the existing
lock-order suites (the GH #2704/#2705 tests and the 517 held-lock tests) pass UNEDITED; a telemetry/`pg_locks` capture
during `complete_task` shows no new lock mode on those tables.

## C.5 Docs (AC 17)

RA-13 (SEC conditions): the exemption of a principal who holds the route permission tenant-wide is stated in `docs/roles.md` in a paragraph SEPARATE from the three verbatim sentences (the three sentences stay exactly once each); its predicate is exactly `Scope.allowed?(principal, route_permission, :tenant_wide)` returning `{:allow, _}` and nothing role-name based; the routing-role checks stay in force for the exempt principal; T-F15 pins the mixed case (scoped TASK_WORKER plus tenant-wide PROCESS_OPERATOR is exempt). The AC 13 requirement text (an "iff") MUST be amended by REQ-ANALYST BEFORE PR 2d merges; this design may not silently diverge from an AC.

`docs/roles.md` gains a section headed `Known limitation: scoped approvers (stage 2)` (the file has none today)
containing, each exactly once and verbatim, S1, S2 and S3 of the requirement text. The PR body repeats them. Test
T-F13 reads the file and asserts each string occurs exactly once by exact match. (The test lives under
`test/letflow/docs/`; the file is read with its working-tree line endings normalised to LF before matching because
`core.autocrlf` is true.)

---

# 7. Route inventory and reclassification ledger (AC 18, 19, 20, 21, 23)

## 7.1 Every route of the four routers

| # | Route | Policy key | Class after 518 | PR | Scope applied by (handler -> function) | Resolver (exported /1) |
|---|---|---|---|---|---|---|
| E1 | POST /entities/definitions/:name/activate | EntitiesDefinitionsWrite | `:tenant_wide` declared | 2c-ii | plug (`Enforce` tenant-wide) | n/a |
| E2 | POST /entities/definitions | EntitiesDefinitionsWrite | `:tenant_wide` declared | 2c-ii | plug | n/a |
| E3 | GET /entities/definitions/active/:name | EntitiesDefinitionsRead | `:tenant_wide` declared | 2c-ii | plug | n/a |
| E4 | GET /entities/definitions/by-name/:name | EntitiesDefinitionsRead | `:tenant_wide` declared | 2c-ii | plug | n/a |
| E5 | GET /entities/definitions/:id | EntitiesDefinitionsRead | `:tenant_wide` declared | 2c-ii | plug | n/a |
| E6 | GET /entities/definitions | EntitiesDefinitionsRead | `:tenant_wide` declared | 2c-ii | plug | n/a |
| E7 | POST /entities/restrictions/import | EntitiesRestrictionsManage | `:tenant_wide` declared | 2c-ii | plug | n/a |
| E8 | POST /entities/query | EntitiesQuery | `:filter` | 2c-i-b | `run_query` -> `ScopeGate.scope_set` -> `Compiler.compile/3` | n/a |
| E9 | POST /entities/query/aggregate | EntitiesAggregate | `:filter` | 2c-i-b | `run_query_aggregate` -> `scope_set` -> `Compiler.run_aggregate/3` | n/a |
| E10 | POST /entities/records/:entity_type/export | EntitiesRecordsExport | `:filter` | 2c-i-b | `run_export` -> `scope_set` -> `Compiler.compile/3` | n/a |
| E11 | POST /entities/records/:entity_type | EntitiesRecordsWrite | `{:resolver, {Letflow.Entities.ScopeResolver, :record_scope}}` | 2c-ii | `create_record_unmanaged` -> `ScopedWrites.type_gate` + `Records.create_record(scope:)` | record_scope/1 |
| E12 | PUT /entities/records/:entity_type/:record_id | EntitiesRecordsWrite | resolver (same) | 2c-ii | `update_record_unmanaged` -> `ScopedLookup` before body, `Records.update_record(scope:)` | record_scope/1 |
| E13 | DELETE /entities/records/:entity_type/:record_id | EntitiesRecordsWrite | resolver (same) | 2c-ii | `delete_record_unmanaged` -> `ScopedLookup`, `Records.delete_record(scope:)` | record_scope/1 |
| E14 | POST /entities/records/:entity_type/import | EntitiesRecordsImport | resolver (same) | 2c-ii | `import_records_unmanaged` -> `ScopedWrites.check_batch` | record_scope/1 |
| E15 | POST .../:record_id/attachments | EntitiesAttachmentsManage | resolver (same) | 2c-ii | `handle_create_record_attachment` -> `ScopedLookup` on the parent | record_scope/1 |
| E16 | GET .../:record_id/attachments | EntitiesAttachmentsRead | resolver (same) | 2c-ii | `handle_list_record_attachments` -> `ScopedLookup` | record_scope/1 |
| E17 | GET .../attachments/:attachment_id | EntitiesAttachmentsRead | resolver (same) | 2c-ii | `handle_get_record_attachment_content` -> `ScopedLookup` | record_scope/1 |
| E18 | DELETE .../attachments/:attachment_id | EntitiesAttachmentsManage | resolver (same) | 2c-ii | `handle_delete_record_attachment` -> `ScopedLookup` | record_scope/1 |
| T1 | GET /tasks/inbox | TasksList | `:filter` | 2d | `handle_inbox` -> `scope_set` -> `Tasks.list_tasks(scope:)` | n/a |
| T2 | GET /tasks | TasksList | `:filter` | 2d | `handle_list` -> same | n/a |
| T3 | GET /tasks/:id | TasksGetById | `{:resolver, {Letflow.Tasks.ScopeResolver, :task_scope}}` | 2d | `handle_get_by_id` -> `Tasks.get_task(scope:)` | task_scope/1 |
| T4 | POST /tasks/:id/complete | TasksComplete | resolver (same) | 2d | `handle_complete` -> `Tasks.in_scope/3` then `Engine.complete_task(f1:)` | task_scope/1 |
| T5 | POST /tasks/:id/claim | TasksComplete | resolver (same) | 2d | `handle_claim` -> `Tasks.in_scope/3` then `Tasks.claim_task(f1:)` | task_scope/1 |
| T6 | POST /tasks/:id/assign | TasksAssign | resolver (same) | 2d | `handle_assign` -> `Tasks.in_scope/3` | task_scope/1 |
| T7 | POST /tasks/:id/reassign | TasksReassign | resolver (same) | 2d | `handle_reassign` -> `Tasks.in_scope/3` | task_scope/1 |
| M1 | GET /me/memberships | MembershipsRead | `:self_service` | 2c-i-b | pass-through, own data only (`auth_context`) | n/a |
| M2 | GET /me/modules | MyModulesRead | `:self_service` (SEC-518-R2-modules) | 2c-i-b | pass-through, tenant-level metadata only | n/a |
| H1 | GET /help/resolved | HelpRead | `:self_service` (SEC-518-R2-help) | 2c-i-b | pass-through, filter over help rows only (R-2 condition) | n/a |

Everything else (instances, attachments of instances, webhooks, module routes including all exam routes, identity,
admin plane) is unchanged. The 143-line snapshot shrinks by exactly 28 lines over the PRs 2c-i-b, 2c-ii and 2d: 2c-i-b removes E8-E10 and M1 (+ M2, H1, both ruled IN and declared `:self_service`), 2c-ii removes E1-E7 and E11-E18, 2d removes T1-T7.

## 7.2 Class declaration of the E1-E7 routes

They are declared `scope: :tenant_wide` explicitly (source `:declared`), not left default-sourced, so the walk rule
`:data_route_default` (no route of `routers/entities.ex` or `routers/tasks.ex` is default-sourced) can be asserted and a
route added without a classification fails the build (AC 19). E1-E7 behave exactly as before (the plug decides
`:tenant_wide` identically for declared and default sources).

## 7.3 AC 23 mapping (coordinator message; PR #2801 not merged, text not read)

The coordinator described AC 23 as: SEC conditions C-1 and C-2, i.e. every 518 reclassification PR needs its own
SECURITY-REVIEWER pass, and the handlers must actually apply the scope. NOT verified against the merged text; the
mapping below must be re-checked against AC 23 when #2801 merges (open item OI-1).

CDV r0a CORRECTION (AC 23 text read from the diff of PR #2801, still unmerged; the relayed summary above is
partly wrong). The actual AC 23 is: each of 2c-i, 2c-ii, 2d that changes a route class or the snapshot has its OWN
SECURITY-REVIEWER verdict recorded in that PR (not one for the set); the PR body lists EVERY reclassified route
(method, path, old class, new class); a PR moving a route out of the default class without the verdict does not
merge; the verdict id is quoted in the PR body and ORCH checks it at merge for any diff touching the snapshot or a
route class; the 2c-i verdict cites the AC 21 ruling id (or `pending_sec_ruling`). Mapping: per-PR verdict and
the PR-body route table (method, path, old class, new class) = the 7.1 ledger rows of that PR, copied verbatim
into the PR body together with the verdict id; the 2c-i body cites the `ruling` column of 4.2. The "handlers must
actually apply the scope" element and the runtime backstop (D6/F9) are design-added hardening from SEC 517 C-2,
NOT part of AC 23's text; they stay (T-L19..T-L27, T-B1) but must not be cited as AC 23 coverage. C-1 is REQ-519
AC 22 (not an AC of this requirement); 4.2 supplies what it reads (the `pending_sec_ruling` entries). OI-1 is
closed except for the merge of #2801.

| Element of AC 23 (as relayed) | Design element |
|---|---|
| per-slice SEC passes | PR 2c-i-a, 2c-i-b, 2c-ii and 2d each end with a SECURITY-REVIEWER code pass listing the ledger rows of its PR (2c-i-a changes no route: its pass covers the compiler, declaration and call sites); the 2c-i-b pass covers E8-E10 and M1 (+M2, H1); 2c-ii covers E1-E7 declarations and E11-E18; 2d covers T1-T7. If AC 21 splits (F12) it gets its own pass. Pre-merge gate in the PR template: "ledger rows reviewed: ids" |
| handlers must apply the scope | ledger column "Scope applied by" in 7.1 (each row names the handler function and the call) + the runtime backstop (D6, F9) + one test per row (T-L1..T-L26) that, in `on`, drives a scoped caller and asserts data/refusal, and one test per row that a fixture handler which omits the gate gets 500 (T-L27) |
| C-1 (REQ-519 must not add `on` before /me/* and /help/* are classified) | 4.2: the walk prints the `pending_sec_ruling` lines; the PR bodies list them; REQ-519 AC 9 reads the same attribute |
| C-2 (snapshot shrink reviewed line by line) | the PR body pastes the removed snapshot lines, one per ledger row |

## 7.4 Deny-reason set: four copies (coordinator note; issue #2800)

518 adds NO reason. The four places that spell the closed six-value set are: (1) `Scope.deny_reason()` in
`lib/letflow/api/scope.ex`; (2) `@reasons`/`@metric` in `Scope.ShadowEvidence`; (3) the CHECK list of migration
`20261018200002_create_scope_shadow_counters.exs`; (4) `@scope_shadow_reasons` in `lib/letflow/metrics/registry.ex`
(about line 154), which the 517 agreement test does not cover. Test T-R1 (design-added, cheap): asserts the four sets
are equal (reading the registry attribute through its function-head behavior or a public accessor added for the test
if none exists), so a reason added later by anyone is loud. If a later change (or an SEC ruling in this PR) adds a
reason, ALL FOUR places and the migration CHECK (a new tenant-scoped migration widening the constraint) change in one
commit. #2800 (single source of truth) remains the structural fix and is not part of 518.

---

## 7.5 PR checklist (AC 23, C-7), identical for 2c-i-a, 2c-i-b, 2c-ii, 2d

1. The PR body contains the table of EVERY reclassified or newly declared route: method, path, old class, new class, plus the snapshot lines removed (copied from 7.1; empty for 2c-i-a).
2. The PR body quotes this PR's OWN SECURITY-REVIEWER code verdict id (not the set's); ORCH checks it at merge for any diff touching the snapshot, a route class, `route_scope.ex`, `scope/enforce.ex`, `authorized_router.ex` or `config/test.exs` `:modules` (the `fixture_scoped` entry is a mandatory-SEC trigger for 2c-i-a).
3. 2c-i-b cites the `ruling` column of 4.2 (`0051-A7`, `SEC-518-R2-modules`, `SEC-518-R2-help`).
4. The PR states the R-4 sentence (detective control) when it touches `Enforce`.
5. Gate output of section 13 quoted.

# 8. SECURITY-REVIEWER rulings (design gate PASS_WITH_FINDINGS, handoffs/WF02-REQ518-COMPILER-SCOPE-20261018/step-04-security-reviewer-design.json)

| Id | Ruling id used in code/lists | Outcome | Conditions folded into this design |
|---|---|---|---|
| R-1 | `SEC-518-R1` | IN for exam sites 7, 8, 9 (literal `:all` with `# scope-all: SEC-518-R1`); threading fallback removed | `:exam_route_reclassified` walk rule over ANY exam route plus the scan test are mandatory in 2c-i-a/2c-i-b; `list_available_exams` keeps the required `:scope` opt; ruling lapses if a guard is removed (3.7) |
| R-2 | `SEC-518-R2-modules`, `SEC-518-R2-help`; memberships stays `0051-A7` | class definition IN with the added sentence; `/me/modules` IN; `/help/resolved` IN with the filter condition | 4.1, 4.4, T-S9 |
| R-3 | (no code id; T-D8) | IN | T-D8 also asserts the allowlist key is `[]` under PROD config evaluation (`Config.Reader` over `config/config.exs`, `prod.exs`, `runtime.exs` with env `:prod`), not only a file scan; `config/runtime.exs` must not read the key from `System.get_env` (scan); compensating production-shaped test T-W21 |
| R-4 | (none) | IN as a DETECTIVE control only | 3.6: docs and PR body say the before-send check detects a handler that omitted `ScopeGate`, it does not make a response safe (preventive controls are T-L19..T-L26 and the ledger; the marker proves "gate called", not "result applied"); fires only in the `on` branch and only for 2xx, every non-2xx passes unchanged; the replacement is the same detail-free `Response.internal_error` body as `Enforce.fail_closed`, no ids in the log; the callback rescues itself and answers the detail-free 500; a handler that drops the conn returned by `ScopeGate` loses the marker and gets a false 500 (fail closed, accepted, caught by T-L19..T-L26); the committed-write caveat (OQ-8) accepted because write handlers apply scope BEFORE writing; if a filter route ever streams, its gate must be asserted before the first chunk |
| R-5 | (none) | IN | one answer for a batch, no count; T-W5 plus T-W23 byte-identical bodies and headers for type-gate refusal, out-of-scope node, NULL node, retired node, nonexistent node |
| R-6 | (none) | IN | refusal is the generic 404 before the body is read |
| R-7, R-8 | (none) | accepted as corrected, with a compensating production-shaped test | T-W21 (section 10.2) |
| RA-13 | (none) | ACCEPTED with conditions | C.3, C.5, section 14 SEC r2: ACCEPTED with conditions (a) exemption predicate exactly `Scope.allowed?(principal, route_permission, :tenant_wide)` allowing, nothing role-name based; (b) routing-role checks stay for the exempt principal; (c) mixed case pinned by T-F15; (d) REQ-ANALYST amends the AC 13 text BEFORE PR 2d merges and docs/roles.md states the exemption in a paragraph separate from the three verbatim sentences. |
| OQ-3 | (none) | literal TASK_WORKER confirmed; the union reading needs a decision-record amendment | C.3 |

Required changes C-1 to C-7 are folded in: C-1 (3.3), C-2 (3.8), C-3 (5.3), C-4 (C.4), C-5 (T-W21), C-6 (5.3, T-W23), C-7 (this section, 7.5).

---

# 9. AC map

| AC | PR | Design element | Sections | Tests |
|---|---|---|---|---|
| 1 | 2c-i-a, 2c-i-b | arity-3 compile, compile_aggregate, run_aggregate; 9 sites; scan | 3.4, 3.7 | T-C1, T-C2, T-C3 |
| 2 | 2c-i-a | predicate placement; one set read; telemetry capture; export reuse | 3.3, 3.4 | T-C4, T-C5, T-C6 |
| 3 | 2c-i-a | ON-clause predicate per hop, one-hop and through | 3.4 | T-C7, T-C8 |
| 4 | 2c-i-a | ScopeDeclaration, manifest key, undeclared = no data, fixture | 3.2, 3.8 | T-D1..T-D7 |
| 5 | 2c-i-a | cost re-assertion | 3.9 | T-C9, T-C10 |
| 6 | 2c-ii | ScopedLookup, equal statement count, identical bytes | 5.2, 5.3 | T-W1, T-W2 |
| 7 | 2c-ii | scope before body; reference clause (F7) | 5.3 | T-W3, T-W8 |
| 8 | 2c-ii | old/new check, POST rules, module action, field bypass | 5.3 | T-W4..T-W7 |
| 9 | 2c-ii | batch pre-check, one generic error, no writes | 5.4 | T-W9, T-W10 |
| 10 | 2c-ii | no cache, cursor without set | 5.7 | T-W11, T-W12 |
| 11 | 2c-ii | parent gate per attachment route | 5.5 | T-W13..T-W16 |
| 12 | 2d | migration, no writer, task reads | C.1 | T-F1, T-F2 |
| 13 | 2d | F1 rule (a)-(e) | C.2, C.3 | T-F3..T-F7 |
| 14 | 2d | 404-equivalence of claim/complete, list/get scope, composition | C.2 | T-F8, T-F9, T-F10 |
| 15 | 2d | engine recheck in transaction | C.4 | T-F11, T-F12 |
| 16 | 2d | off/shadow byte-identical | C.4 | T-F14 |
| 17 | 2d | docs section exact strings | C.5 | T-F13 |
| 18 | 2c-i-b | three `:filter` routes | 7.1 | T-L1..T-L3, walk |
| 19 | 2c-ii | resolvers, every entities route classified | 5.6, 7.1, 7.2 | T-L4..T-L11, walk |
| 20 | 2d | task routes | C.2, 7.1 | T-L12..T-L18, walk |
| 21 | 2c-i-b | `:self_service`, list, walk | 4 | T-S1..T-S8 |
| 22 | all | gates, real output | section 13 | gate output |
| 23 (relayed) | all | per-PR SEC pass, ledger, backstop | 7.3, 3.6 | T-L19..T-L27 |

# 10. Tests (TEST-DESIGNER writes them; ids are the contract)

Unless stated: real HTTP through the router with real tenants, the stored value `on` set by
`Letflow.Support.ScopeEnforcementFixture.set_stored_mode!/2`, tree and principals from `ScopeSetFixture`;
`async: false` where DDL, held locks or the shared sandbox are used.

## 10.1 PRs 2c-i-a (T-C1..T-C10, T-C12, T-D*) and 2c-i-b (T-C11, T-S*, T-B1)

| Id | AC | Test |
|---|---|---|
| T-C1 | 1 | `function_exported?/3` true and `/2` false for the three functions; `compile(r, p, :all)` SQL equals the SQL of the pre-change code (committed expected strings captured from main for 6 request shapes) |
| T-C2 | 1 | source scan (3.7): the nine sites; a seeded fixture file with a bare `:all` and no comment fails, one with `# scope-all: x` passes; exam sites carry the ruling comment or an opts-derived value |
| T-C3 | 1 | `mix compile --warnings-as-errors` output quoted in the PR (gate); the argument guard raises for `nil`, `:foo`, `{:nodes, :x}` |
| T-C4 | 2 | table-driven, scoped TASK_WORKER on subtree `a`, data in `a`, `a2x` (live under the retired `a2`), `a2` (retired), `b`, `a3` (retired), NULL scope, plus a tenant-wide caller: query rows, aggregate count/sum, `group_by` buckets, cursor page 1 and page 2, export; only in-scope rows; the tenant-wide caller sees all; no out-of-scope row in any count. (No `total` or `having` exists, F2) |
| T-C5 | 2 | Ecto telemetry capture: the data statement, the cursor page statement, the export statement and the aggregate statement each contain the predicate with a bound parameter and no literal node id |
| T-C6 | 2 | `allowed_node_ids/2` escapes `%` `_` `\` (a node id `x_y` does not match `xzy`), bound parameters only; hostile ids are values |
| T-C7 | 3 | one-hop LEFT join: out-of-scope target row is NULL, primary kept; INNER join drops; two-hop `through`: out-of-scope through row NULLs the far hop |
| T-C8 | 3 | TypeAccess still runs first and unchanged (existing tests unedited); an undeclared joined target yields NULL/dropped |
| T-D1 | 4 | `for_type/2` returns column, tenant_wide, undeclared for the three fixture types and a non-declared type with zero queries (telemetry) |
| T-D2 | 4 | undeclared type: scoped caller gets 404-equivalent empty page on query, empty/zero on aggregate, empty on export; a tenant-wide caller gets full data (one test per path, same type) |
| T-D3 | 4 | a tenant definition carrying `scope_node`/`scope_column`/`tenant_wide` keys in `definition_json` changes nothing |
| T-D4 | 4 | the definitions API cannot alter a declaration; managed_by rules unchanged |
| T-D5 | 4 | `:tenant_wide` master readable by a scoped caller and a `{:nodes}` caller; a zero-row (`:none`) caller sees nothing (fail closed) |
| T-D6 | 4 | declared column not promoted / type on `:latest`: scoped caller sees nothing, tenant-wide sees all |
| T-D7 | 4 | Catalog rule 11 rejects bad shapes; `ManifestHash` of every existing module unchanged; duplicate declaration rejected |
| T-C9 | 5 | query counts: token path single-query shape unchanged; OIDC loads grants once; one `allowed_set` per request even with two gate calls; baseline-relative counts |
| T-C10 | 5 | the allowed set is NOT recomputed per row (page of 50 rows, same count as a page of 1) |
| T-C11 | 18 | `on`: scoped TASK_WORKER gets 200 with scoped data from E8-E10 (not the 2b 403); tenant-wide unchanged; walk fails if any of the three is still `:tenant_wide` |
| T-D8 | 4/G2/R-3 | Catalog rule 11 (and the prod-config evaluation of R-3: `Application.get_env` of the key is `[]` after `Config.Reader` evaluation of the prod configs): an unmanaged declaration is rejected for a production-config module (`{:scope_declaration_unmanaged_type, name}`); accepted only for `fixture_scoped` through the test-config allowlist; scan: the allowlist key appears only in `config/test.exs`; `for_type/2` returns `:undeclared` for an unmanaged type of a module not on the list |
| T-C13 | 2/C-1 | `allowed_set/2` with a stubbed `allowed_node_ids/2` returning `{:error, :invalid_node_id}`, `{:error, :invalid_schema_name}` and a raised DB error: it RAISES `ScopeSetError`; through HTTP the response is the detail-free 500 with exactly one `scope_set_failed` line, no ids, and never a 200 with data or an empty page; MU40 |
| T-C14 | 2/C-1 | cap: with `:scope_allowed_ids_cap` lowered to 3 and a grant whose expanded set has 4 live nodes, `allowed_node_ids/2` is `{:error, :too_many_ids}`, `allowed_set/2` raises, HTTP answers the same 500, no truncated page; exactly at the cap succeeds; MU41 |
| T-C15 | 1, R-1 | `:exam_route_reclassified` walk rule: every route mounted by the exam entry module is `:tenant_wide` (fails for a seeded exam route declared `:filter`, `:self_service` or a resolver, and for a route added later); plus the scan: an exam manifest gaining `:scope_declarations` while a `SEC-518-R1` literal remains fails. Ships in 2c-i-a |
| T-C12 | D1 | agreement property between `allowed_set/2` and `allowed?/3` over the fixture tree and principal kinds |
| T-S1 | 21 | route walk (list rules 4.2), seeded fixture routes for each error |
| T-S2 | 21 | `on`: scoped-only user gets 200 from M1, M2 and H1 (all ruled IN) |
| T-S9 | 21/R-2 | the help-oracle test of 4.4 (existing definition without a help row vs nonexistent definition: byte-identical for a scoped-only user) |
| T-S3 | 21 | principal failing the coarse check gets the unchanged answer |
| T-S4 | 21 | `off` and `shadow` responses byte-identical to the committed 517 fixture `off_shadow_responses.json` plus three new recorded rows (M1, M2, H1) captured BEFORE the lib change |
| T-S5 | 21 | `Authorize` passes `:self_service` through only after the coarse allow; unauthenticated request never reaches it |
| T-S6 | 21 | shadow counts these routes as requests only (no reason metric) |
| T-S7 | 21 | M1 body holds only the caller's memberships; a second user's memberships never appear |
| T-S8 | 21 | the PR body line list equals the `pending_sec_ruling` entries (none today; the test keeps the rule for future entries) |
| T-B1 | F9 | fixture resolver/filter route whose handler omits the gate: `on` -> 500 and one `scope_not_applied` line; `off`/`shadow` -> 200 |

## 10.2 PR 2c-ii

| Id | AC | Test |
|---|---|---|
| T-W1 | 6 | for E12, E13, E15-E18: out-of-scope id vs nonexistent id: same status, byte-identical body and header set (request id and date named and excluded), same statement count (telemetry), no ETag/Last-Modified; list endpoints omit rows with no placeholder |
| T-W2 | 6 | query route: an out-of-scope id as a filter value yields the same empty page as a nonexistent id |
| T-W3 | 7 | out-of-scope id with a malformed body and with a schema-invalid body: the same 404 as a nonexistent id |
| T-W4 | 8 | PUT moving a record from in-scope to out-of-scope node refused 404-equivalent; PUT on a row whose old value is out of scope refused |
| T-W5 | 8 | POST with a node outside the subtree, with NULL, with a retired node, with a nonexistent node: all the SAME refusal; tenant-wide NULL create allowed |
| T-W6 | 8 | module action path: a fixture action passes the caller's set to `Records` and is refused the same way |
| T-W7 | 8 | scope field updated with and without field write permission: refused when out of scope |
| T-W8 | 7 | F7 pin: reference payload out-of-scope vs nonexistent identical; fails if a reference check appears without a scope-aware lookup (scan of `Validator`/`Records` for lookups) |
| T-W9 | 9 | import with one out-of-scope row (and with one NULL row): whole batch refused, identical status/body whichever row or reason, no row count; database assertion: zero rows written; all-valid batch succeeds; tenant-wide import unchanged (existing tests unedited) |
| T-W10 | 9 | race residual documented: a revocation between pre-check and loop is not observed (assert the documented behavior, one batch) |
| T-W11 | 10 | revoke mid-pagination: page 2 of the same cursor applies the CURRENT scope; the cursor carries no set or node id |
| T-W12 | 10 | grant row deleted / node moved: the first following request sees the new scope |
| T-W13..16 | 11 | per attachment route (create, list, get, delete): out-of-scope parent vs nonexistent parent identical response and statement count; a scoped caller cannot attach to, list, read or delete an out-of-scope record's attachment |
| T-L4..L11 | 19 | per route E11-E18 in `on`: a scoped caller in scope succeeds, out of scope is refused; the route is `{:resolver, _}` with an exported resolver; walk: every route of `entities.ex` classified, none default (`:data_route_default`), none of E8-E18 in the snapshot |
| T-W17 | 8 | `Records` scan extension (3.7, 5.7) |
| T-W19 | 6 | the `[:letflow, :scope, :not_found]` event fires once per refusal with exactly the keys `policy` and `kind`, identically for out-of-scope and nonexistent ids, with no id/node/tenant in metadata |
| T-W20 | 11 | attachment create: out-of-scope and nonexistent parent, with a missing file part and with a valid file part, give the same 404 and the upload part is never read |
| T-W21 | 8/C-5 | production-shaped: `:scope_declaration_unmanaged_modules` = `[]`; a scoped caller on EVERY write and attachment route (E11-E18): 403 `entity_type_managed` for a declared MANAGED type, the generic 404 for an undeclared type and for a `:tenant_wide`-declared type; database assertion that no row, event or attachment was written |
| T-W22 | 8/C-3 | idempotency replay: a key created by another caller, replayed by a scoped caller with an out-of-scope (and with a NULL) new value, on create and on update: generic 404, body and headers carry no stored record id or version; MU39 |
| T-W23 | 8/C-6 | the type-gate refusal (undeclared type, `:tenant_wide` type, scoped caller) equals byte for byte (body and headers, request id and date excluded) the answer for a NONEXISTENT type name, on create and on import; on query the documented empty-page difference is asserted |
| T-W18 | 6 | `guard_tenant_write` answer unchanged and independent of scope (managed fixture type: constant 403 for a scoped caller) |

## 10.3 PR 2d

| Id | AC | Test |
|---|---|---|
| T-F1 | 12 | migration applies/rolls back; FK `confdeltype = 'r'`; replayed tenant and clone carry the FK; `@expected_tenant_tables` unchanged |
| T-F2 | 12 | source scan: no `lib/` writer of `scope_node_id`, covering `insert_all`/`Repo.insert_all` keyword forms and `TaskActivation`; the column appears in no cast list and in no task response map (`task_json`, list, detail, complete; INV-2, A-8) |
| T-F3..F7 | 13 | the five cases (a)-(e) with `TaskScopeFixture` |
| T-F8 | 14 | claim and complete outside scope: same status, body, headers and statement count as a nonexistent task id; unchanged existing errors for in-scope/out-of-routing-role |
| T-F9 | 14/15 | claim in scope, revoke the grant, complete -> 404-equivalent (fresh grants in the transaction) |
| T-F10 | 14 | list and inbox: out-of-subtree and NULL-node tasks excluded, `count` and cursor pages exclude them; composition with `task_row_scope` is the intersection (a task in scope but not assigned to the worker is absent) |
| T-F11 | 15 | `Engine.complete_task` F1 recheck inside the transaction: forced revocation between lock and check (held lock) refuses |
| T-F12 | 15 | SoD behavior unchanged: existing REQ-463 tests pass unedited |
| T-F13 | 17 | docs strings exactly once each |
| T-F15 | 13/G1 | negative: a scoped PROCESS_OPERATOR and a scoped TENANT_ADMIN holding grants on the node but NO TASK_WORKER grant are refused (404-equivalent) on get, list (task absent), claim, complete; the same callers with a covering TASK_WORKER grant are allowed; a tenant-wide PROCESS_OPERATOR is unchanged; assign and reassign for the scoped PROCESS_OPERATOR follow the route permission and succeed in scope |
| T-F17 | 15/C-4 | lock order unchanged: the existing lock-order suites pass unedited; no new lock mode on role/group/binding/org rows during `complete_task` and `claim_task` |
| T-F16 | 13/G1 | `Scope.allowed_for_role?/3` and `allowed_set_for_role/2` agreement property over the fixture tree (member of the set iff allowed for that role) |
| T-F14 | 16 | `off`/`shadow`: claim, complete, list, get byte-identical; existing `tasks*_test.exs`, `engine_complete_task_test.exs` unedited; F1 branch not entered (telemetry: no extra statement) |
| T-L12..L18 | 20 | per route T1-T7 in `on` (resolver/filter, exported resolver, walk: every route of `tasks.ex` classified, none default) |
| T-L19..L26 | 23 | one scoped-caller test per ledger row proving the handler applied the scope |
| T-L27 | 23 | the backstop test per class (T-B1) |
| T-R1 | 7.4 | the four copies of the deny reasons agree |
| T-G1 | F-3 of 517 SEC | every mounted non-skipped policy key resolves to a member of `Authorization.permissions/0` (advisory item carried by SEC 517 F-3) |

# 11. Mutants (the suite must kill each)

| Id | Mutant | Killed by |
|---|---|---|
| MU1 | predicate applied as a post-filter on fetched rows | T-C5 |
| MU2 | predicate inside the user filter dynamic (not outermost) so a future OR escapes, or only on the data statement not on the aggregate | T-C5, T-C4 |
| MU3 | `{:nodes, ids}` holds grant roots, not descendants | T-C4, T-C12 |
| MU4 | retired node (leaf or intermediate) left in the allowed set, or a live descendant of a retired intermediate node dropped | T-C4 (a2, a2x, a3), T-C12 |
| MU5 | joined target predicate in WHERE instead of ON (turns the left join into an inner) | T-C7 |
| MU6 | `through` entity not filtered | T-C7 |
| MU7 | undeclared type treated as `:tenant_wide` | T-D2 |
| MU8 | declared column not promoted falls back to the JSON document | T-D6 |
| MU9 | declaration read from `definition_json` | T-D3 |
| MU10 | `:none` allows masters | T-D5 |
| MU11 | the set recomputed per row or per page statement | T-C9, T-C10 |
| MU12 | `ScopeGate` consults the DB when the flag is not `on` | T-S4, T-F14, T-C9 |
| MU13 | scope lookup after body validation | T-W3 |
| MU14 | out-of-scope answers 403 or a different body | T-W1 |
| MU15 | out-of-scope skips the unconditional set read (count differs) | T-W1 |
| MU16 | update checks only the new value | T-W4 |
| MU17 | update checks only the old value | T-W4 |
| MU18 | NULL scope accepted for a scoped caller on create | T-W5 |
| MU19 | import checks only the first row, or writes before checking | T-W9 |
| MU20 | import per-row detail in the refusal | T-W9 |
| MU21 | cursor embeds the set | T-W11 |
| MU22 | attachment list for out-of-scope parent returns 404 (differs from nonexistent) | T-W15 |
| MU23 | F1 reads the request-memo grants in the transaction instead of fresh ones | T-F9, T-F11 |
| MU24 | NULL task node treated as tenant-wide | T-F7 |
| MU25 | list scope replaces the row scope instead of intersecting | T-F10 |
| MU26 | `scope_node_id` writable from a production path | T-F2 |
| MU27 | resolver/filter handler omits the gate and the backstop is absent | T-B1 |
| MU28 | `:self_service` accepted for a route not on the list | T-S1 |
| MU29 | `/me/memberships` returns another user's memberships | T-S7 |
| MU30 | self_service pass-through before the coarse allow | T-S5 |
| MU31 | declared snapshot line kept after reclassification | walk `:stale_snapshot` |
| MU32 | a resolver route on the expectation list loses its resolver | `:unexpected_resolver_route` |
| MU33 | F1 branch entered when the flag is `off` | T-F14 |
| MU34 | tenant-wide caller gets a scope statement (SQL differs from today) | T-C1 |
| MU35 | deny reason added in one of the four copies | T-R1 |
| MU36 | F1 grant rule uses the union of roles allowing the route permission (scoped PROCESS_OPERATOR sees tasks) | T-F15 |
| MU37 | unmanaged-type declaration accepted for a production-config module | T-D8 |
| MU38 | attachment create reads the multipart part before the scope gate | T-W20 |
| MU39 | new-value scope check only inside the transaction (after the idempotency claim), so a replay returns the stored record | T-W22 |
| MU40 | `allowed_set/2` turns an `allowed_node_ids/2` error into `:none` or `:all` | T-C13 |
| MU41 | the id cap truncates instead of failing closed | T-C14 |

# 12. Security: INV analysis and residual risks

## 12.1 INV table

| INV | Treatment |
|---|---|
| INV-1 | prefix only from `scoped_opts`; the set is computed for the caller's tenant; declarations come from code; new migration is tenant-scoped, no `tenant_id` column added |
| INV-2 | scope applied server side before serialization; FieldGrants/redaction unchanged and still run on top; the set never appears in a response or cursor |
| INV-4 | no node ids, set or reasons in logs; constant lines `scope_not_applied`; telemetry carries counts only |
| INV-5 | by-id answers identical in status, body, headers and statement count; scope before body; list endpoints omit; undeclared type gives the empty answer, never a different one |
| INV-6 | every new data path is named in the ledger with its scoping proof; `ScopedLookup` and `ScopedWrites` are the only new data access modules |
| INV-7 | node ids bound as one array parameter; column name from a format-validated declaration bound as a field reference; LIKE patterns escaped by the existing helper; migration interpolates only the schema |
| INV-8 | `compile/3` guard raises only on programmer error; DB errors propagate to the pipeline's detail-free 500; no fail-open default except the documented `:all` default of `Records`/`Tasks` options guarded by the scan |
| INV-10 | platform-scope permissions yield `:all`/`:none` by the unchanged platform branch before grants |

## 12.2 Residual risks recorded for SECURITY-REVIEWER

R-1 exam sites literal `:all` (ruling). R-2 `/me/modules`, `/help/resolved` (ruling). R-3 an import batch in flight is
bound to the request's snapshot. R-4 `StepWrites`/engine entity writes are not scope-checked (F11, W3b). R-5 scoped
approvers cannot act on any task until W3b (requirement text, AC 17). R-6 the `Records` and `Tasks` `:all` default
is protected by a scan, not by the type system. R-7 (corrected) a `:tenant_wide` declaration is NOT restrictive-only: it makes every record of the type readable by every scoped
caller that passes the coarse check (T16). Its safety rests on the declaration being module-owned and the type name
being locked: production declarations are limited to MANAGED types, whose names the managed-type rules protect against
create/supersede through the definitions API (REQ-496), and the test-only allowlist cannot be set outside `config/test.exs`
(T-D8). If SEC rejects R-3, or the allowlist is ever widened, the 0051 D6 M4 refusal of definitions for scope-aware
names (OQ-4) becomes a precondition. R-8 AC 6-9 (record writes by scoped callers) are exercised only against the
test-only unmanaged fixture; in production they are unreachable until a module declares an unmanaged type under a future
ruling or W3b adds module write routes.

## 12.3 Advisories carried (SEC step-04)

A-1 the plug passes resolver, filter and self-service routes after only the coarse allow, so the per-route behaviour tests T-L19..T-L26 (not the walk) are the control and are mandatory and non-skippable. A-2 type-name existence differs on query between a nonexistent and an undeclared type: accepted tenant-level metadata (5.3). A-3 idempotency-key existence across scopes is pre-existing (GH #2543), unchanged. A-4 a `:none` export returns the empty page; test that no unredacted-export audit is written for rows never returned if cheap (T-C6b). A-5 `me.ex` `handle_list_memberships` has a bare `{:ok, memberships} =` match (pre-existing INV-8 hit, now reachable by scoped users): route to ELIXIR-DEV as a drive-by or an issue, not a 518 blocker. A-6 `ScopeGate` must be called with, and the handler continue with, the conn finally sent (3.6). A-7 the code pass repeats the INV-5 spot checks: attachment list for an out-of-scope parent equals the empty 200 of a nonexistent parent, attachment create short-circuits before the multipart read, import structural checks precede the type gate without revealing scope. A-8 the `tasks.scope_node_id` column stays out of cast lists, response maps and `insert_all` (T-F2); F1 stays fail-closed.

# 13. Gates and commands (AC 22)

Each PR: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix letflow.check`,
`mix letflow.check_boundaries`, `mix letflow.check_requirements_registration`, `mix letflow.permission_matrix --check`
(`MIX_ENV=dev`; no permission atom is added, golden unchanged), and the scoped `mix test` over
`test/letflow/routers/entities*`, `test/letflow/entities`, `test/letflow/modules` (2c-i call sites), `test/letflow/plugs`,
`test/letflow/api`, `test/letflow/routers/tasks*_test.exs`, `test/letflow/engine_complete_task_test.exs` (2d),
`test/letflow/routers/me_test.exs`, `test/letflow/routers/help_test.exs`, plus `test/letflow/scope_node_paths`,
`test/letflow/tasks*` and `test/letflow/docs` (2d) which AC 22 does not list. SECURITY-REVIEWER and REVIEWER required
on each PR. Anti-pattern checks for ELIXIR-DEV: manifest registration and version collision for
`20261019100001`; explicit short constraint names; no grep-shaped scan that the module's own moduledoc trips (the
new scans are AST-based); the tenant fixture oracle unchanged because no table is added; CRLF working tree for edits
to `entities.ex` (new files LF).

# 14. Requirement amendments proposed (REQ-ANALYST / letflow-2; not edited here)

| # | Amendment |
|---|---|
| RA-6 | AC 2 and AC 14: `total` does not exist on query/export/task list; restate as aggregate counts, task list `count`, and page contents (F2); AC 2 `having` has no DSL surface |
| RA-7 | AC 21: permit the self-service commit to ship as its own PR (2c-i-s) if the SEC ruling is not recorded when 2c-i is ready (F12) |
| RA-8 | AC 4: the manifest key is `:scope_declarations` with Catalog rule 11; production declarations cover managed types only, unmanaged only for test-only modules on a test-config allowlist (F3, R-3); AC 6-9 over HTTP are therefore tested on the fixture only (R-8) |
| RA-9 | AC 7: the reference clause is vacuous on main (F7); keep as a pinned property |
| RA-10 | AC 13: the design builds the LITERAL TASK_WORKER grant (D9, C.3); amend only if the wider reading (union of roles allowing the route permission) is wanted (OQ-3) |
| RA-11 | AC 9: state the status of the generic refusal (404, D7) and that import's only value is the new value (F5) |
| RA-12 | AC 1: the scan covers `lib/` AST and the `Records`/`Tasks` keys (3.7, 5.7, C.4); the forced test edits (F1) are listed |
| RA-13 | AC 13 (CDV r1 recheck): C.3 exempts a principal who holds the route permission TENANT-WIDE (any role, including a tenant-wide PROCESS_OPERATOR or TENANT_ADMIN without a TASK_WORKER grant, a token principal, a platform admin) from the TASK_WORKER grant requirement, keeping today's behavior and the routing-role checks; AC 13 reads as an "iff" over the TASK_WORKER grant, so state this exemption in AC 13 (it matches D1: tenant-wide on the permission is tenant-wide) or remove it. Mixed case pinned by T-F15: scoped TASK_WORKER plus tenant-wide PROCESS_OPERATOR is exempt |

# 15. Open questions (defaults built)

| # | Question | Default built | Needs |
|---|---|---|---|
| OQ-1 | May a declaration cover an unmanaged module-shipped type? | RESOLVED for production by G2: no; managed types only; unmanaged only for test-only allowlisted modules (R-3) | SEC confirmation |
| OQ-2 | Status/body of a scope refusal on POST create and import | generic 404 (`Response.not_found`) | SEC (R-5) |
| OQ-3 | Wider F1 reading: any role allowing the route permission instead of the literal TASK_WORKER grant | NOT built; literal TASK_WORKER is the default (G1) | REQ-ANALYST (RA-10) |
| OQ-4 | Should the definitions API refuse creating a tenant type named like a declared type (0051 D6 M4 "scope-aware" names)? | not built in 518; unnecessary while production declarations are managed-only (G2); becomes a precondition if R-3 is rejected or the allowlist widens (R-7) | REQ-ANALYST, SEC |
| OQ-5 | May a scoped caller write a `:tenant_wide`-declared master through the generic routes? | no (refused 404) (R-6) | SEC |
| OQ-6 | Retired or nonexistent node in a tenant-wide caller's create | accepted as today (no node validation in 518; the org module's lookup is 0050 scope) | none |
| OQ-7 | Allowed-set size | RESOLVED (C-1): hard cap 50,000 expanded ids (`:scope_allowed_ids_cap`), fail closed with the detail-free 500, no truncation | none |
| OQ-8 (RULED IN as detective control, R-4) | Is the before-send backstop (D6) accepted as a mechanism? Caveat to rule on: it runs after the handler, so for a write route it can turn a 2xx into a 500 AFTER the write has committed (the client sees a failure for a persisted change). It fires only when a handler omitted the gate, which the ledger and tests (T-B1, T-L27) make a defect caught before merge, and only under `on`; the write handlers also apply the scope before writing, so a committed unscoped write is the same defect the 500 reports | built | SEC, REVIEWER |
| OQ-9 | StepWrites seam for scoped types after a declaration exists | untouched (F11, R-4) | W3b owner |
| OI-1 | AC 23 mapping (7.3) was corrected by CDV from the PR #2801 text in r0a | none | none |

# 16. Self-review against the brief

All 22 merged ACs map to a design element in section 9; AC 23 is mapped as relayed (OI-1). The route inventory with
class per route is 7.1 (28 routes of four routers, 28 snapshot lines). Slices: sections 1, PART A, A2, B, C.
Interfaces and `@spec`-shaped signatures: 3.2-3.5, 5.2, 5.6, C.2. Query shapes: 3.4, 5.2. Mutants: section 11 (MU1..MU41).
AC-to-test map: sections 9-10. Requirement amendments: section 14. SEC rulings: section 8 (all recorded). No
implementation code appears in this file.
