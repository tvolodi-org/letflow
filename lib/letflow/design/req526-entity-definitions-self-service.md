# REQ-526: entity-definition reads (`GET /entities/definitions*`) into `:self_service`, one route at a time (GH #2535, SEC RA-6)

Task T-0428 of the letflow team. Design and per-route rulings only. This change touches no route class,
no `@self_service_routes` entry, no snapshot line, no router, no doc under `docs/` and no status in
`docs/requirements.yaml`. No implementation code appears below: tables and prose only.

Base: `main` e194724b8. Facts re-derived from the code at that commit (`routers/entities.ex`,
`entities/definitions.ex`, `entities/type_access.ex`, `entities/scope_declaration.ex`,
`api/route_scope.ex`, `api/scope/enforce.ex`, `api/scope_gate.ex`, `api/scope.ex`,
`api/authorization.ex`), not copied from section 5 of `req519-enforced-writers-and-flag-on.md`.

This record builds on `req525-definitions-services-self-service.md`, which recorded two class-level
decisions that apply here without being re-decided: SEC-525-Q1 = Option A (the coarse permission of the
policy key still applies inside `:self_service`; no role gate field) and SEC-525-Q3 = Q3-a (the entry
guard `SelfServiceEntry` admits an allowlist of ruled path prefixes). Section 3 says what REQ-526 adds.

## 1. Problem

After REQ-519 2f-b a tenant can be set to `on`. Under `on` a route classed `:tenant_wide` lets a caller
through only when `Letflow.Api.Scope.allowed?/3` finds a tenant-wide grant row
(`Letflow.Api.Scope.Enforce.check/3`, branch 4). A caller whose only rows are scoped gets the uniform 403
although the coarse permission `EntitiesDefinitionsRead` allows the request. The four `GET
/entities/definitions*` routes are in that state: a scoped TASK_WORKER cannot fetch the column catalogue of
the entity type it may query, which is the very first call the web record pages and the mobile list
renderer make. SEC RA-6 asks for each route to be ruled on its own, with attention to INV-5: a
definition read must not become an existence oracle for a type the caller may not query.

## 2. Route table (AC 1)

### 2.1 Routes and current class

All four rows are `:tenant_wide` with source **`:declared`** (an explicit `scope: :tenant_wide` on the
`authz_get`, `lib/letflow/routers/entities.ex`, section "Definition read routes"), not `:default`. This
differs from REQ-525, and it matters for the acceptance criteria (section 5, item 3):

    $ grep -c entities test/fixtures/route_scope/tenant_wide_default_routes.txt
    0
    $ grep -n "authz_get \"/definitions" lib/letflow/routers/entities.ex
    333:  authz_get "/definitions/active/:name", :EntitiesDefinitionsRead, scope: :tenant_wide do
    337:  authz_get "/definitions/by-name/:name", :EntitiesDefinitionsRead, scope: :tenant_wide do
    341:  authz_get "/definitions/:id", :EntitiesDefinitionsRead, scope: :tenant_wide do
    345:  authz_get "/definitions", :EntitiesDefinitionsRead, scope: :tenant_wide do

The snapshot file has no line for any `/entities/*` route (`RouteScope.class_of/1`: a declared class
wins over the default; `test/letflow/api/route_scope_resolver_test.exs`, "NO route of Routers.Entities is
default-sourced"). So the criterion "the snapshot loses exactly that line" cannot hold for these routes;
section 5 states the real equivalent.

| id | method and path | handler | policy key | class today | source | statuses |
|---|---|---|---|---|---|---|
| E1 | `GET /entities/definitions/active/:name` | `handle_get_active_definition_by_name/2` -> `Definitions.get_active_definition_by_name/2` (`Activation.resolve(:entity, name, prefix)`, then the row of that version) | `EntitiesDefinitionsRead` | `:tenant_wide` | declared | 200, 404, 500 |
| E2 | `GET /entities/definitions/by-name/:name` | `handle_get_definition_by_name/2` -> `get_definition_by_name/2` (newest row of that name, **any status**) | `EntitiesDefinitionsRead` | `:tenant_wide` | declared | 200, 404, 500 |
| E3 | `GET /entities/definitions/:id` | `handle_get_definition/2` (`Ecto.UUID.cast/1` first; a malformed id is the same 404) -> `get_definition/2` (**any version, any status**) | `EntitiesDefinitionsRead` | `:tenant_wide` | declared | 200, 404, 500 |
| E4 | `GET /entities/definitions` | `handle_list_definitions/1` -> `list_definitions/3` (keyset over `inserted_at desc, id desc`, one row per **version**) | `EntitiesDefinitionsRead` | `:tenant_wide` | declared | 200, 400 (page size, cursor), cursor-expired problem, 500 |

Holders of the coarse permission (`docs/roles.md` matrix row `EntitiesDefinitionsRead`, `core_role_allows?/2`
clauses): PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, TENANT_ADMIN, TENANT_AUDITOR.
AGENT_RUNNER and CANDIDATE do not (`core_role_allows?(:AGENT_RUNNER, _permission)` is `false`). The role
set equals the holders of `EntitiesQuery`, so a holder of the one always holds the other.

The write routes `POST /entities/definitions` and `POST /entities/definitions/:name/activate`
(`EntitiesDefinitionsWrite`, declared `:tenant_wide`) are out of scope and stay so.

### 2.2 Response fields (re-derived from `definition_map/1`, `routers/entities.ex`, section "Response allowlists")

E1 to E3 return one object, E4 returns `{"items": [definition_map...], "next_cursor": string|null}`
(no `count`). The `EntityDefinition` schema (`lib/letflow/entities/entity_definition.ex`) has these
columns: `tenant_id`, `name`, `display_name`, `definition_json`, `content_hash`, `logical_shape_version`,
`artifact_version_id`, `status`, `managed_by`, `write_class`, timestamps. It has **no scope-node column**:
a definition is a tenant-level object, not data of a scope node. `managed_by` and `write_class` are not
in the response.

Legend: **T** = tenant-level metadata (property of a tenant-level object, not tied to a scope node).
**R** = per-resource data (derived from an entity record, task, instance or attachment). **P** =
per-principal. **Caller** = echoed or computed from caller input.

| field | source | kind | note |
|---|---|---|---|
| `id` | `entity_definitions.id` | T | row id of one version |
| `name` | `entity_definitions.name` | T | the entity type name |
| `display_name` | column | T | |
| `definition` | `definition_json` | T | the column catalogue: field names, types, constraints, relations (`fk_def`), UI hints. Free-form JSON written by the tenant's definition author; it is design-time configuration, not record data. It may name other types through relations (see 2.4, point 4) |
| `content_hash` | column, lower hex | T | |
| `logical_shape_version` | column, lower hex | T | |
| `artifact_version_id` | column | T | |
| `status` | column, `active` or `inactive` | T | |
| `inserted_at` | column, ISO 8601 | T | |
| `next_cursor` (E4) | `Pagination.page_response` | T | encodes the `(inserted_at, id)` of the last definition row; unsigned, not a security control (anti-pattern: do not call it one) |

No field is **R**, **P** or **Caller**. Nothing in the response is derived from a record, task, instance
or attachment, so the "tenant-level metadata, no per-resource data" condition of RA-6 holds for the body.
The open question is therefore not what the body holds but **which definitions a scoped caller may see**,
which is the oracle analysis below.

### 2.3 Call-path facts (the grep that lists the callers)

    $ grep -rn "TypeAccess.authorized?\|TypeAccess.visible_to\|TypeAccess.denied_types" lib
    lib/letflow/routers/entities.ex   render_get_definition/3 (E1, E2, E3): authorized?/3 after the fetch
    lib/letflow/entities/definitions.ex   list_definitions/3 (E4): where(^TypeAccess.visible_to(user_id, :def))
    (plus the write and record paths, unrelated)

    $ grep -rn "ScopeGate\." lib/letflow/routers/entities.ex
    1233 (EntitiesQuery), 1488 (EntitiesAggregate), 1669 (EntitiesRecordsExport)

No definition-read handler calls `ScopeGate` today. Under `on`, `Enforce.check/3` sends a `:tenant_wide`
route to `Scope.allowed?(principal, permission, :tenant_wide)`; a `:self_service` route returns the conn
unchanged and registers no scope-applied check (that check is for `:filter` and `{:resolver, _}` only). So
**a `:self_service` declaration alone gives a scoped caller exactly what a tenant-wide holder gets**: every
definition not hidden by `TypeAccess`. Any narrowing below is a handler change, not a class property.

### 2.4 Existence-oracle analysis per route (AC 1, INV-5)

Three different questions are called "may the caller query this type" in the code; they are separate
layers and the analysis keeps them apart.

- **Layer 1, `TypeAccess` (GH #2739, REQ-394).** A type with a row in `entity_type_restrictions` and no
  `user_entity_type_grants` row for the caller is denied. Today: E1 to E3 answer the same zero-detail 404
  as a nonexistent name or id (`render_get_definition/3`, `{:ok, :denied}` branch); E4 excludes the row
  inside the one SQL statement, so pages and `next_cursor` are computed over visible rows
  (`entities_definitions_list_type_access_test.exs` pins byte equality between a world with the type and a
  world without it). **No oracle at layer 1. Unchanged by this record.**
- **Layer 2, scope declaration (REQ-518).** `ScopeDeclaration.for_type/2` resolves a type to
  `{:column, field}`, `:tenant_wide` or `:undeclared`. For a scoped caller (`{:nodes, ids}` or `:none`) an
  `:undeclared` type yields an **empty result** from `Compiler.compile/3`: "a scope failure is never an
  error". `EntitiesQuery` for such a caller therefore gives no data for it. The definition routes ignore
  layer 2 entirely today.
- **Layer 3, existence.** Whether a type exists at all.

If E1 to E4 became `:self_service` and stayed as they are, a scoped caller would receive the definition of
every type that layer 1 does not hide, including types that layer 2 makes empty for them. The response
then differs between "a type the caller may query" (200 with a body) and ... nothing: for those layer-2
types the caller gets a 200 body although it may not query them, while a nonexistent name gets 404. That
is the exact existence oracle REQ-526 names: the caller can list which type names exist in the tenant and
read the column catalogue of types whose data it cannot reach. It is not a cross-tenant oracle (the schema
`:prefix` bounds every query, INV-1) but it contradicts the criterion "the answer for a type it may not
query is identical to the answer for a nonexistent type".

Per route, as the code stands (`$ grep` sources: `render_get_definition/3`, `list_definitions/3`):

| route | layer 1 (restricted type) | layer 2 (undeclared type, scoped caller) if made `:self_service` unchanged | layer 3 cross-tenant id | differs between queryable and not-queryable? |
|---|---|---|---|---|
| E1 `active/:name` | same 404 as absent (identical) | **200 with body vs 404 for absent: differs** | n/a (name) ; other tenant's data unreachable (prefix) | yes at layer 2 only |
| E2 `by-name/:name` | same 404 | **differs** (and it returns inactive/draft versions too) | n/a | yes at layer 2 only |
| E3 `:id` | same 404 (malformed id and absent id also the same 404) | **differs**; the id is a version row id, so one probe per known uuid | other tenant's id: same 404 (prefix) | yes at layer 2 only |
| E4 list | row excluded inside the statement (identical to absent world) | **differs**: lists undeclared types and their every version | n/a | yes at layer 2 only |

Further points that bear on the rulings:

1. **Status leak.** E2, E3 and E4 return `inactive` versions, i.e. superseded and never-activated
   (draft) shapes; E1 returns only the version the activation pointer names. The scoped consumers found
   (section 4) need only the active shape.
2. **Query-count parity.** The 0051 D7 equivalence asks for the same query count, checked with a counting
   test and no timing assertions. For a name no module manifest names, `ScopeDeclaration.for_type/2`
   resolves with **zero queries** (`candidates/1` is empty). A check placed **before** the fetch and
   answered by one shared function therefore costs the same for an existing undeclared type and a
   nonexistent one. Only names that some module manifest names can cost an installed-modules read (plus an
   `owner_of` read per such name); those names are in public module code. Accepted, and the test pins it
   (section 5, item 6).
3. **No module ships declarations today.** `grep -rn "scope_declarations" lib` lists only
   `entities/scope_declaration.ex`, `modules/catalog.ex`, `modules/manifest_hash.ex` and `modules/module.ex`
   (the mechanism), no module manifest. Every type is `:undeclared` in production, so a shaped E1 answers
   404 to every scoped caller until a module ships a declaration. That equals the 403 of today in effect
   but is the correct fail-closed behaviour and needs no later change when declarations arrive. The real
   benefit of the ruling lands with the per-module `:scope_declarations` work, which is not covered here.
4. **Relations.** `definition` may name another type through an `fk_def`. A scoped caller who may query
   type A can read that A relates to type B even if B is `:undeclared` for them. This is content of A's
   own definition (the author's text), not a probe: the caller cannot ask "does B exist" through any
   route, only read what A says. It is the same posture tenant-wide holders have for a layer-1 restricted
   target. Accepted; recorded as a finding for the SECURITY-REVIEWER.
5. **Field-level restrictions.** `definition` is not redacted per field today for any holder. Scoped and
   tenant-wide holders get the same body for a queryable type; nothing changes.

## 3. Open questions (the security ruling decides; this record proposes)

### SEC-526-Q1: which scope set defines "a type the caller may query"?

Options, facts only:

- **Q1-a, the `EntitiesQuery` scope set.** `ScopeGate.scope_set(conn, :EntitiesQuery)` is the set the data
  path uses; "may query" literally means that. A definition read for a scoped caller is shaped by the same
  layer-2 rule as the query compiler: a type is queryable when the set is not `:none` and
  `ScopeDeclaration.for_type/2` is not `:undeclared`. The roles that hold the read permission hold
  `EntitiesQuery` too (2.1), so no holder is left out by a missing `EntitiesQuery` row except one whose
  rows are scoped to no node (`:none`).
- **Q1-b, the `EntitiesDefinitionsRead` set.** The set of the route's own permission. Wrong question: a
  principal could be scoped for definition reads and unscoped for queries or the reverse, and the shaping
  would not match what the data path does.
- **Q1-c, no shaping, class change only.** Rejected by 2.4: it is the oracle.

Designer's recommendation: Q1-a. The shaping function lives in one place and takes `(scope_set, name,
prefix)`; `:all` (not `on`, or a tenant-wide holder) returns "queryable" with **no query and no change**,
so behaviour for `off`, `shadow` and tenant-wide holders is byte-identical to today.

### SEC-526-Q2: where does the check sit relative to the fetch?

- **Q2-a, before the fetch, by name.** E1, E2: the name is known up front. Not-queryable -> the one shared
  404 function, no row read. Same cost for existing and nonexistent (2.4, point 2).
- **Q2-b, after the fetch, on the row's name** (as `TypeAccess` does today). Works for E3 (the name is
  known only from the row), costs one extra read for a not-queryable existing type versus zero for an absent
  one in the layer-2 case, because a hidden existing row is fetched and then dropped.
- **Q2-c, inside the statement.** E4 (list): the queryable name set is resolved first, then ANDed into the
  one statement as `name = ANY(^names)` (typed `{:array, :string}`, INV-7) beside `tenant_id`, the keyset
  predicate and `TypeAccess.visible_to/2`, before `ORDER BY`/`LIMIT`, so pages and `next_cursor` are
  computed over visible rows only. A post-filter is refused (0051 D6: "there is no post-filter").
  The name sets are free strings on both sides: `entity_definitions.name` is `:string` and the
  bound array is `text[]`, no uuid cast is involved (T-0393 check).

Recommendation: Q2-a for E1/E2, Q2-b for E3, Q2-c for E4 (only if E4 is ruled in; section 4 says it is not).

## 4. Rulings (AC 2)

Ruling ids are recorded in this section, not in `handoffs/` (this team does not touch it). Status of every
ruling below: **PROPOSED by the designer (T-0428 design step)**; it is RECORDED when the SECURITY-REVIEWER
verdict of this task cites it, exactly as REQ-525's rulings were. A route without a recorded ruling stays
`:tenant_wide`. Each implementation PR still needs its own code verdict (section 5, item 7).

Decision rule (same as REQ-525): a route is ruled in only if (a) every field is T or P (2.2: yes for all
four), (b) a scoped holder has a demonstrated functional need, otherwise the fail-closed 403 stays (fewer
exposed fields), (c) a caller-supplied name or id never selects something the caller must be scoped for
without the layer-2 shaping, and (d) the route is a read. Plus the REQ-526 rule: (e) for a type the caller
may not query the answer is identical to the answer for a nonexistent type.

Consumers searched (`grep -rn "entities/definitions" web/src apps/mobile/lib scripts`, tests excluded):

    web/src/api/entities.ts:52   getActiveDefinition -> /api/v1/entities/definitions/active/${entityType}
    web/src/pages/entities/EntityCrudPage.tsx, EntityListBrowserPage.tsx   use getActiveDefinition
    apps/mobile/lib/renderers/list/list.dart:197,306   GET .../entities/definitions/active/:name
    scripts/seed_meridian_entities.sh, scripts/seed_vortex_entities.sh   by-name (admin seeding)

| id | route | outcome | reasoning |
|---|---|---|---|
| SEC-526-R01 | E1 `GET /entities/definitions/active/:name` | **`:self_service` only after a named response-shaping change** (the scope-visibility shaping of Q1-a with Q2-a: a not-queryable name answers the shared 404 before any row read). | (a) all T. (b) demonstrated need: the web record pages call it first (`EntityCrudPage`, `EntityListBrowserPage`) and so does the mobile list renderer; without it a scoped TASK_WORKER who may query a type cannot render its list, the very purpose of scoped grants. (c) the name selects a tenant-level object; the shaping makes it select only what the caller may query. (d) read. (e) holds only with the shaping; without it 2.4 shows a 200-versus-404 oracle at layer 2. Only the version named by the activation pointer is returned (point 1), so no draft shape leaks. |
| SEC-526-R02 | E2 `GET /entities/definitions/by-name/:name` | **stays `:tenant_wide`**. | (b) fails: the only callers are the seed scripts (`seed_meridian_entities.sh`, `seed_vortex_entities.sh`), admin work under TENANT_ADMIN, and nothing in `web/` or `apps/mobile/`. It returns the newest row **of any status** (draft and superseded shapes, 2.4 point 1), more than the active shape a scoped reader needs, and E1 already serves the scoped need. Not reclassified because E1 is. |
| SEC-526-R03 | E3 `GET /entities/definitions/:id` | **stays `:tenant_wide`**. | (b) fails: no consumer outside admin tooling. (c) fails without a per-row shaping: the id is a version row id of any status, discovered only from E4 or from outside, and the name needed for the layer-2 check is known only after the fetch (Q2-b), the weakest form of the shaping (an extra read for a hidden existing row). Not reclassified because E1 is. |
| SEC-526-R04 | E4 `GET /entities/definitions` | **stays `:tenant_wide`**. | (b) fails: no `web/` or `apps/mobile/` consumer lists entity definitions (the dashboard definitions tile calls the process-definition list, REQ-525-R01, a different route). Ruling it in would need the in-statement shaping of Q2-c (the most complex form) for no consumer. Re-open condition: a named scoped consumer (for example a scoped type picker); the re-opening requirement then carries Q2-c and the byte-equality twin-world test of `entities_definitions_list_type_access_test.exs` for the scoped case. |

Summary: one route may be ruled in, after one named shaping change (R01); three stay `:tenant_wide`
(R02 to R04). The single implementation requirement therefore carries the shaping (section 6).

## 5. Acceptance criteria every implementation requirement must carry (AC 3)

For EACH route the requirement rules in (here only E1; its own PR, its own ruling id):

1. (After IMPL-525-0 has landed the class-text rewording of SEC-525-Q1 and the guard change of
   SEC-525-Q3, and after the prefix edit of IMPL-526-0 below.) `@self_service_routes` in
   `lib/letflow/api/route_scope.ex` gets the entry `%{route: "GET /entities/definitions/active/:name",
   key: :EntitiesDefinitionsRead, class: :self_service, ruling: "SEC-526-R01"}`.
2. The route's `authz_get` declaration changes `scope: :tenant_wide` to `scope: :self_service`. Both edits
   are needed, the walk fails on either alone (`:self_service_list_mismatch`).
3. The route walk (`test/letflow/api/route_scope_walk_test.exs`, and `RouteScope.audit_routes/3` on the
   real table, T-RW4 of `route_scope_on_flip_blocker_test.exs`) is green. **The snapshot criterion differs
   from REQ-525:** the route is declared, so `test/fixtures/route_scope/tenant_wide_default_routes.txt` has
   no line for it and must stay **byte-unchanged** (`git diff` of the fixture is empty). The three
   `length(snapshot) == N` pins therefore do not move because of this requirement (their value changes only
   with REQ-525 PRs; the PR takes the count from the fixture it leaves). The REQ-526 text "loses exactly that
   line" is satisfied vacuously and is recorded here as a corrected reading, not skipped.
4. Under `on`, a SCOPED holder of `EntitiesDefinitionsRead` (a tenant-role binding with scoped rows only)
   gets, for a type it may query (declared by an installed module, `EntitiesQuery` set not `:none`, not
   hidden by `TypeAccess`): 200 and a body of the same shape (same keys, same value types) as a
   tenant-wide holder's for the same type, created in the same tenant.
5. Under `on`, for a type the scoped caller may not query, the response is **byte-identical, headers and
   body, to the response for a nonexistent name**. Cases, each a test: (i) an existing `:undeclared` type,
   (ii) an existing declared type whose caller has `EntitiesQuery` set `:none`, (iii) a type hidden by
   `TypeAccess` (existing behaviour, kept), (iv) a name with no definition at all. The 404 comes from the
   one shared function `Response.not_found/1`. A principal without the coarse permission (AGENT_RUNNER,
   CANDIDATE) still gets the uniform 403 `insufficient permissions`, byte-identical to the 403 of the route
   before the change (INV-5); the 403 comes from the coarse allow, which runs before the class.
6. A query-count test (no timing assertion) at the surface the criterion names: the number of database
   statements for case (i) equals the number for case (iv) for a name no module manifest names, counted
   with the repo telemetry handler the 0051 D7 tests already use (the PR names it).
7. Not `on` (`off`, `shadow`) and tenant-wide holders: output and query count byte-identical to the
   unchanged route (`ScopeGate.scope_set/2` returns `:all` with no query; the shaping function returns
   "queryable" without reading). Under `shadow` the route counts as a request and produces no denial
   evidence (`Shadow`: `{:self_service, _source} -> conn`).
8. Cross-tenant (INV-10 habit even though the route takes no tenant identifier): another tenant's
   definition name or id answers the same 404 as an absent one (schema `:prefix`, INV-1).
9. No field derived from a record, task, instance or attachment is added to the response; adding one needs
   a new ruling.
10. Own SECURITY-REVIEWER code verdict (INV-1, INV-2, INV-5, INV-6), cited in the PR body (REQ-518 AC 23
    rule). `Refs #2535`, never `Closes`.
11. The documentation changes of section 7 for that route.

An implementation requirement whose route set contains a route not ruled in by a recorded verdict is
refused by the REQ-VALIDATOR (R02 to R04 never travel with R01).

### Existing tests the implementation PRs must change or run (greps on current main)

    $ grep -rn "entities/definitions" test --include=*.exs -l
    test/letflow/api/authorization_test.exs                       (policy-key tests, unaffected)
    test/letflow/api/route_scope_resolver_test.exs                (@tenant_wide_lines lists only 2 write routes; see below)
    test/letflow/api/scope_grants_route_walk_test.exs             (docs text only)
    test/letflow/api/scope_shadow_test.exs                        line 216, GET /api/v1/entities/definitions in a shadow equality list
    test/letflow/routers/entities_definitions_list_type_access_test.exs, entities_test.exs, entities_decimal_strict_test.exs,
    entities_definition_write_type_access_test.exs, entities_scope_writes_http_test.exs, gh2747_cursor_tail_http_test.exs, ...

Must change:

- `test/letflow/routers/entities_scope_writes_http_test.exs` (test "the seven definition and restriction
  routes are explicitly :tenant_wide (declared)", lines 828 to 833): the line
  `GET /entities/definitions/active/:name EntitiesDefinitionsRead` moves out of the `:tenant_wide` list into
  a `:self_service` assertion; the test name ("seven") is corrected to the new count (six). The same stale
  "seven" name stands in `route_scope_resolver_test.exs` at the test after `@tenant_wide_lines` (list of two,
  name "the seven definition/restriction routes"): the PR renames it.
- `test/letflow/api/route_scope_on_flip_blocker_test.exs`: T-RW2 `length(list)` (+1), T-RW3 `@expected_rulings`
  (+`"GET /entities/definitions/active/:name" => "SEC-526-R01"`), and the helper `self_service_path?/1` with
  its `@prefixes ["/me", "/help"]` stays unchanged (the walk's forced prefixes do not change, as in
  SEC-525-Q3); `route_scope_self_service_test.exs:331` (sorted member list) and
  `scope_enforcement_on_e2e_test.exs:161` (`length(self_service) == 4`) are raised by the entries merged
  before it; each PR counts from the list it leaves.
- `route_scope_self_service_entry_test.exs`: "a route outside /me and /help is rejected" keeps
  `GET /entities/records/:entity_type` rejected and gains an acceptance case for `/entities/definitions/...`
  (IMPL-526-0).
- `scope_shadow_test.exs:216` lists `GET /api/v1/entities/definitions` (E4): E4 stays `:tenant_wide`, so it
  is unaffected; the PR runs the file and says so.
- Existing definition-read tests with an unscoped or `off` tenant (`entities_test.exs`,
  `entities_definitions_list_type_access_test.exs`, `entities_decimal_strict_test.exs`) must stay green
  unchanged: the PR runs them as the regression proof for item 7.
- `scope_enforcement_on_e2e_test.exs` uses `GET /api/v1/definitions` as its `:tenant_wide` representative;
  REQ-525 IMPL-525-A switches it to `GET /api/v1/services`. REQ-526 does not touch services, so that
  replacement stays valid; the REQ-526 PR does not edit this constant.
- Source-scanning tests that read `routers/entities.ex` by path (`grep -rl "routers/entities.ex" test/`)
  are run once at the end; the edit is one option on one declaration plus one new handler helper, no move.

## 6. Implementation requirements to be filed (AC 4)

Not filed by this task and no status flip: REQ-ANALYST files them from the recorded rulings. Owner
ELIXIR-DEV, `depends_on: [REQ-526]` (and IMPL-525-0, which carries the class-text rewording and the first
guard change), `gh: 2535` for traceability, each sized to one agent turn.

| proposed requirement | routes | why this size |
|---|---|---|
| IMPL-526-0 | (no route) | prerequisite: add the prefix `/entities/definitions` to `SelfServiceEntry`'s `@prefixes` (the allowlist shape of SEC-525-Q3 Q3-a; `/entities/records` stays rejected, so a typo cannot rule in a record route), its test case, and the `SelfServiceEntry` typedoc wording. The walk's `@self_service_prefixes` stays `/me`, `/help`. If IMPL-525-0 has not landed, this requirement `depends_on` it. One list edit, one test file |
| IMPL-526-A | E1 `GET /entities/definitions/active/:name` (SEC-526-R01) | one declaration, one list entry, one shaping function (Q1-a, Q2-a) used by the handler, the pins of section 5. Depends on IMPL-526-0 |

Not filed: R02, R03, R04 (stay `:tenant_wide`; no requirement). If a scoped consumer of the list or of by-id
reads appears, REQ-ANALYST files a new ruling requirement for it first (the re-open condition of R04).

## 7. Documentation updates per route (AC 5)

Until the implementation PR of a route has merged, `docs/roles.md` and `docs/runbooks/scope-enforcement-on.md`
keep the REQ-519 sentence unchanged: item 5 of the numbered `on` list, "Scoped users lose definitions,
entity-definition, instance and service reads until the tenant-level metadata follow-up (RA-6) ships"
(`docs/roles.md` line 121, runbook line 39 on current main; cite the item, not the line). This change edits
neither file.

When each implementation PR merges it updates, citing the heading or symbol and no line numbers:

| PR | `docs/roles.md` | runbook `scope-enforcement-on.md` | other |
|---|---|---|---|
| IMPL-526-0 | none | none | `route_scope.ex` `SelfServiceEntry` typedoc and comment |
| IMPL-526-A (E1) | item 5 reworded: scoped users keep `GET /entities/definitions/active/:name` for a type they may query (every other type answers 404, like an absent one); they still lose `by-name`, `:id` and the list of entity definitions, instance and service reads. The matrix row of `EntitiesDefinitionsRead` is unchanged (the permission is unchanged) | item 5 the same wording; the list of routes answering 403 to a scoped user loses E1 | `routers/entities.ex` moduledoc: a paragraph naming the class of E1 and the shaping; `route_scope.ex` entry; the `LIMIT-` list of `docs/roles.md` gains one line that no module ships declarations yet, so a scoped user sees 404 for every type until one does (2.4 point 3) |
| (R02, R03, R04) | the sentence stays for `by-name`, `:id`, the list | the same | none |

Item 5's "entity-definition" word is not removed by A: three of the four reads remain refused.

## 8. Left out on purpose

- Definitions and services reads (REQ-525), instance scope (REQ-527), the task scope writer (W3b), exam
  routes (SEC-518-R1), the entity-definition write routes, every route not named in the task.
- Any change to `route_scope.ex`, the fixture, the routers, `docs/roles.md`, the runbook or
  `docs/requirements.yaml` in this change; no `handoffs/` edit.
- Shipping any module `:scope_declarations` (S-9 item 1): a per-module concern.
- A signed cursor, a column-level redaction of `definition`, and hiding relation targets inside a visible
  definition (2.4 points 4 and 5).
- The list shaping (Q2-c) and the by-id shaping (Q2-b): designed enough to re-open R03 and R04, not built.

## 9. Findings for the security review

1. **Declared, not default.** The REQ-526 text and REQ-525's pattern assume snapshot lines; these four
   routes have none. The corrected criterion is section 5 item 3. REQ-VALIDATOR should read it that way.
2. **Class alone is not enough.** `:self_service` returns the conn unchanged, so without the layer-2
   shaping the class change would expose every unrestricted type's catalogue to a scoped caller. This is
   the reason R01 is "after a named response-shaping change" and not "may be".
3. **No manifest ships declarations**, so the shaped E1 returns 404 to every scoped caller in production
   today (2.4 point 3). The ruling is still right; its value arrives with the first module declaration.
4. **Relation targets** inside a visible definition name types the caller cannot query (2.4 point 4);
   accepted as content of the visible type, to be confirmed by the SECURITY-REVIEWER.
5. **Stale test names**: "the seven definition/restriction routes" asserts two lines in
   `route_scope_resolver_test.exs` and seven in `entities_scope_writes_http_test.exs`; both names go stale
   when R01 lands and are corrected there.
6. **Q1-a edge**: a principal scoped to no node for `EntitiesQuery` but holding the definition read
   permission sees 404 for every type (the `:none` set), consistent with `EntitiesQuery` returning no data.
7. **Rulings are proposals** until the SECURITY-REVIEWER verdict of this task records them (section 4).
