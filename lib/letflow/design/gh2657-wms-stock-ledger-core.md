# GH #2657 / REQ-502 -- WMS stock ledger core (1 of 4): append-only ledger entry plus legs, gap-free posting sequence, reversal, no-negative guard

Author: CODE-DESIGNER, 2026-10-19. Revision 5, final (rounds 2, 3, 4 and the advisor delta review applied; section 21 maps every finding).
Branch `docs/GH-2657-wms-ledger-core-design`, from `origin/main` `a614e9c1`. Design only: signatures, type shapes, table
and constraint lists, step lists, SQL statement shapes in prose, test briefs. No function bodies. Nothing here was run (docs only).
Every claim about existing code carries a `file:line` re-read on `a614e9c1`, or is marked NOT FOUND or NOT VERIFIED.

Sources: decision 0057 D5, D4, D9, G7 (`docs/migration/decisions/0057-wms-customer-draft-reconciliation.md:17,16,44-48,22`), 0058 (c)
(`0058-wms-offline-readiness.md:25-34`), 0060, 0061, 0039 D1/D3, 0054 D6 and its "Correction" (`0054...md:143`), 0040; base document
`docs/WMS/WMS_Procurement_Requirements_Draft.md` (MD-08 :67, MD-09 :68, WM-06 :79, CS-01 :117, WM-12 :85); mapping
`docs/migration/wms-customer-draft-mapping-20261016.md`; `lib/letflow/design/gh2590-req501-module-write-handlers.md` (cited `gh2590...md`).

## 0. Verdicts in one screen

| # | Question | Verdict |
|---|---|---|
| V1 | Can the merged REQ-501 handler contract run the guard? | **No.** Create-only: no read, no lock, no update, no repo (`handler_writes.ex:138-149`; `gh2590...md:199,211,466-469,1073,1093-1099`). |
| V2 | Which route? | **R-N**, a domain-neutral core posting primitive. RULED by the advisor letflow-ec (Opus), high confidence, 2026-10-19. R-D (entity-type ledger through update-kind handler writes) is the REJECTED alternative, section 3.2. |
| V3 | Storage | Core tenant tables `ledger_entry` (header), `ledger_leg`, `ledger_balance`, `ledger_counter` (one row per ledger id, created lazily). Core names no business term; the stock vocabulary lives in the stock module's registration and read layer. |
| V4 | Append-only | Database triggers against UPDATE/DELETE/TRUNCATE (a TRIPWIRE: the app role owns the tables), constraints, deferred constraint triggers, a digest-based hash chain anchored in the audit chain; single-writer scans; pooled test reset changed (5.4). |
| V5 | Sequence | One counter row PER LEDGER ID, locked to commit, `+1` forced by trigger; NOT a Postgres SEQUENCE; proof in section 6. One posting per transaction, enforced statically AND at run time (7.4). |
| V6 | Lock order | Class 5b between 0061 classes 5 and 6: balance rows ascending (missing rows inserted first), then the counter row. Needs a 0061 amendment. |
| V7 | Errors | Core codes are neutral (`insufficient_balance`); the module maps them to its wire codes (`insufficient_stock`) by a registration `error_aliases` map (decision D-E, needs supervisor confirmation). Typed 409s with `details` through a new 5-tuple refusal channel (12.3); 503 for contention. |
| V8 | Time (G7) | `event_time` kept, `posting_time`/`posting_seq` server-side; lateness cap 96 h from the registration, capped at 720 h (8.3). |
| V9 | Policy | In L1-L4 the module's policy is ONE pure function `declare/2` run at BUILD time. There is no `gather_facts` and no master or version check in L1-L4: they depend on the OQ-R4 read facade (3.3, 14.6). |
| V10 | Audit | One `ledger.posted` audit entry per posting, appended by the engine tail after the counter, carrying the `chain_hash` (7.7). |
| V11 | Prerequisites today | REQ-501 R1-R5 merged; #2654 closed; masters #2661/#2663 and the #2658/#2660 notes NOT FOUND (section 1). |
| V12 | Needs supervisor confirmation | D-E neutral error code plus alias (OQ-19); removal of `gather_facts` from L1-L4 AND the resulting AMENDMENT of two acceptance criteria of #2657 (OQ-20, a gate before L0, section 18); the scoped-principal limitation (OQ-21). |

## 1. Prerequisite section (carried from the issue, re-verified today)

### 1.1 REQ-501 / #2590

The issue says R3, R4a, R4b, R5 are not merged (written at `5997f92c`). On `a614e9c1` all are merged:

| Piece | Commit | Evidence |
|---|---|---|
| R1 Catalog registration | `8a7b1be8` (#2650) | `git log origin/main --grep "GH #2590"` |
| R2 stamp storage | `a43ad970` (#2652) | same |
| R3 declaration and activation | `e5ed281b` (#2665) | `lib/letflow/definitions/module_writes.ex` exists |
| R4a `HandlerWrites`, `HandlerContext` | `1a50321c` (#2670) | `lib/letflow/entities/handler_writes.ex` |
| R4b engine HUMAN_TASK integration | `b5c5e498` (#2672) | `engine.ex:393-398` |
| R5 SERVICE_TASK | `6b1fb16b` (#2722) | `engine.ex:400-410` |

GH #2590 is CLOSED. Production `:modules` is `[Letflow.Modules.Exam]`, which declares no handler (`config/config.exs:60`).

REQ-501 criteria relied on, and what is NOT on main:

| Criterion | On main? |
|---|---|
| Handlers registered only through the Catalog; run inside the step Multi; platform builds Owner/source/key; replay never runs a handler | YES |
| Stamp, hash and body checked at activation and at run time (`handler_writes.ex:476`) | YES |
| Type locks ordered by the engine ascending before any write | YES (`handler_writes.ex:426-437`, `step_writes.ex:526-585`) |
| HUMAN and SERVICE origins | YES |
| A handler UPDATES a record, READS a table, takes a lock, or writes a non-entity table | **NO. NOT FOUND by design** (`gh2590...md:199` F-R5, `:1073` OQ-R4, `:1094` "the first real ledger handler", `:1099` "a narrow read facade ... together with update-kind support"). This is why master checks, version preconditions and retired-master checks are NOT in L1-L4 (3.3). |
| `ActorCapabilities` | NOT FOUND (`grep -r ActorCapabilit lib docs` empty). The access path is `Authorization.role_allows?/2` (`authorization.ex:1518-1520`), `TypeAccess` (`type_access.ex:73`), `FieldGrants`, `RecordAccess` (`record_access.ex:43`). |
| Effective roles of a user from the DATABASE | **EXISTS** (revision 1 said NOT FOUND, wrongly): `Identity.list_effective_role_names/2` (`identity.ex:1285`), `Authorization.effective_roles/2` (`authorization.ex:630-638`, strips `PLATFORM_ADMIN` outside the platform tenant), scope grants `RoleScopeGrants.applicable_rows_for_user/2` (`identity/role_scope_grants.ex:673`, covers group rows), `Scope.load_grants/2` (`api/scope.ex:355`), `Scope.allowed_set/2` (`api/scope.ex:161`). Used in 16.2. |

### 1.2 Soft dependencies

| Dependency | State today | Effect |
|---|---|---|
| #2654 exact decimals | CLOSED 2026-10-17; PR-1 `49f43759` (#2761) and PR-2 `e6dc2419` (#2770) on main; the 2026-10-17 issue update is superseded | strict reads/filters/aggregates are live. The ledger's own columns are Postgres `numeric` (exact); the wire value is parsed by `Decimals.parse/3` (`entities/record/decimals.ex:128-148`). |
| Masters #2661/#2663 and behaviour halves #2662/#2664 | all OPEN; `lib/letflow/modules/` has only `exam/`, `priv/modules/` only `exam/` (NOT FOUND: `Org`, `CatalogItems`, any stock module) | NOT needed by L1-L4 (no master check there, 3.3). Needed only by the later master-validation slice that also needs the read facade (17). |
| #2658 (dimensions), #2660 (quantity) | OPEN, no note on main | columns by reference (4.5); L1 waits for both notes; M6 gives #2658 a comment text (4.5). |

## 2. Sources and verification (all on `a614e9c1`)

| # | Claim | Source |
|---|---|---|
| S1 | Handler API is `create/3` only; no repo, no read, no step function | `entities/handler_writes.ex:138-149`; `gh2590...md:480-497` |
| S1b | The per-call process token: `safe_call/3` does `Process.put(@token_key, ...)` before the handler runs (`:615`) and `Process.delete` after it returns (`:635`); `create/3` checks it at BUILD time (`:139`, `fetch_token` `:153-157`). The Multi steps the handler returns run LATER, so a token check inside a step can never succeed | `handler_writes.ex:139, 153-157, 612-636` |
| S2 | `lock_types/3,4`: one `{:type_lock,t}` / `{:pre_type_lock,t}` step per type ascending | `handler_writes.ex:426-437`; `step_writes.ex:526-585`; `engine/entity_port.ex:236-254` |
| S3 | HUMAN completion order: tasks, projection, pure steps, `:lock_ancestors`, entity-type rows, handler calls, THEN the tail | `engine.ex:383-398` |
| S3b | The tail starts with `:cancel_escalation_timers`, `:cancel_reminder_timers`, then token reconcile, task activation, audit rows, events, projection, cascade | `engine.ex:7350, 7365` and the moduledoc `:383-398`; 0061 "Amended (GH #2707, PR-1)" item 1 puts timer rows after the entity-type rows and before the audit chain row, touched only while `P_x` is held |
| S4 | SERVICE apply: `:lock_ancestors`, `{:pre_type_lock,_}`, then tokens and task activation whose `task.create` audit takes the audit chain row, then entity writes and handlers | `engine.ex:400-410`, pre-lock `:5800` |
| S5 | A node with lines/`module_writes` runs `SET LOCAL lock_timeout '2s'` and `statement_timeout` 5 s first; contention codes `[:lock_not_available, :query_canceled, :deadlock_detected]` map to 503 `entity_write_contention` | `engine.ex:390-392, 2920, 2925, 3195, 5664`; `api/response.ex:312-314`; `routers/tasks.ex:456-463` |
| S6 | Refusal envelope `{"error": code, "line_index": n|null}`; status table 403/409/503/422; `write_not_permitted` byte-identical for every cause | `api/response.ex:288-314`; `engine.ex:2938-2946` |
| S6b | Failure channel: `EntityPort.failure` is `{:refused, index, code, detail_atom} \| {:failed, index, step} \| :not_a_line_failure`; the engine writes a best-effort refusal audit AFTER the rollback and returns the 3-tuple `{:entity_write_refused, index, code}`; the `details` map has no channel | `engine/entity_port.ex:179-182`; `engine.ex:8440-8462`; `step_writes.ex:944-960` |
| S6c | Sites that match the 3-tuple `{:entity_write_refused, _, _}` | `engine.ex:2549, 2994, 3038, 3057, 3062, 3116, 3143, 3243, 3250, 5478, 5675, 5682, 5695, 5737, 6008, 6045, 6073-6101, 8433, 8461-8462`; `engine/service_task_dispatcher.ex:667`; `engine/script_task_dispatcher.ex:107`; `routers/tasks.ex:456-463`; `entities/records.ex:828-876` |
| S7 | Sequence-row protocol: insert-if-absent, `lock: "FOR UPDATE"` Ecto composition, increment; `lock_instance_sequence/3` | `event_store.ex:787-845` (lock query `:806-811`) |
| S8 | A per-tenant serialisation row already exists: the audit chain row, held to commit by every audited write | `audit.ex:211-232`; `tenant_provisioning.ex:661` |
| S9 | `audit_entries` immutability: BEFORE UPDATE/DELETE row triggers, fixed exception, inside the tenant-guarded migration. It deliberately has **no TRUNCATE trigger**; so do `lua_script_execution_audit` and the repository tables, because the pooled test-schema reset TRUNCATEs them. No `REVOKE` in any migration | `priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs:76-110`; `20261015100002_lua_script_audit_read_only.exs:11-13`; `test/support/tenant_template.ex:621-631` |
| S9b | `TenantTemplate`: clones are `CREATE TABLE (LIKE ... INCLUDING ALL)` (no rows); `@seed_tables` is the fixed list `["event_type_registry","schema_migrations","script_policy"]`; `reset_clone_schema!/3` TRUNCATEs exactly the dirty tables plus the FK-referencing closure, and returns `{:error,{:unprovable, reasons}}` where `reasons` is a list of STRINGS (first entry `"definition_drift"` for drift); the pool labels any non-drift unprovable result `:verify_failed`; functions and triggers are re-created with the template qualifier textually replaced by the clone schema | `tenant_template.ex:292, 621-640, 1343, 1565, 1609-1619`; `test/support/tenant_fixture.ex:1860-1875` |
| S9c | The sandbox fixture loader runs `TRUNCATE "<schema>"."<table>" CASCADE` for fixture table names | `lib/letflow/sandbox_pool/fixture_loader.ex:121` |
| S10 | Tenant tables need a migration PLUS a `TenantProvisioning` entry; oracle `expected_tenant_tables/0`; last entry `20261019200001` | `tenant_provisioning.ex:661, 728-731`; `test/support/tenant_fixture.ex:133, 862`; `test/letflow/support/tenant_fixture_test.exs:144` |
| S11 | Unique migration version prefixes | `docs/anti-patterns.md:574` |
| S12 | `expected_last_event_global_seq` -> `:record_version_conflict` (409) | `entities/records.ex:59, 577-581` |
| S13 | A client key starting `sys:step:` is refused `:reserved_idempotency_key` | `entities/records.ex:175, 1004-1007` |
| S14 | Exact decimal parser: canonical grammar, scale/precision refused not rounded, floats not accepted | `entities/record/decimals.ex:120-148`; 0060 item 2 |
| S15 | Scan H4 covers HANDLER files derived from manifests and flags every `HandlerWrites` call but `create/3` | `test/letflow/entities/handler_writes_callers_test.exs:21-35` |
| S16 | Forced-overlap harness | `test/support/lock_order_helpers.ex:1-52` |
| S17 | Postgres 16 | `docker-compose.yml:3` |
| S18 | No isolation override in the repo (READ COMMITTED); a ROLE-level `default_transaction_isolation` could still change it, hence the run-time assertion (N3) | `lib/letflow/repo.ex`, `config/*.exs` (NOT FOUND any override) |
| S19 | FK on the engine's tables takes `KEY SHARE` on a parent (the #2709 mechanism) | 0061 "Amended (GH #2709, PR-2)" |
| S20 | Scoped types refused for handler writes until 0051 | `handler_writes.ex:30-33`; `gh2590...md:972` |
| S21 | Catalog rule 10: `@handler_keys [:args,:function,:name,:targets]` exact key set; `check_handler_targets_and_code` refuses empty `targets`, targets outside `manages_entity_types`, a handler outside the module namespace; `WriteHandler` struct `[:module_id,:name,:entry_module,:targets,:args]` | `modules/catalog.ex:61-77, 596-690` |
| S21b | **Rule 11 already exists**: REQ-518 `:scope_declarations` (`validate_scope_declarations`); the ledger rule is therefore **rule 12**, run after rule 11 | `modules/catalog.ex:~336-348` |
| S22 | `TENANT_ADMIN` holds every tenant-scope permission, Catalog permissions included | `api/authorization.ex:1536-1542` |
| S23 | Decision 0039 D1: "Platform core ... Names no business domain."; D3: boundaries enforced by `mix letflow.check_boundaries`, which classifies FILE-LEVEL xref edges only | `0039...md:52-60, 72-`; `lib/mix/tasks/letflow.check_boundaries.ex:16-60, 209-223` |
| S24 | Decision 0054 "Correction": ledger invariants belong in reviewed MODULE code, not in declarative step data | `0054...md:143` |
| S25 | Decision 0040: no per-actor rate limit on authenticated routes | `0040...md:23, 27` |
| S26 | The scope credential and fail-closed rule: `credential` (`:oidc` or `:api_token`) is set by the auth pipeline per branch; scope grants that cannot be loaded become `:not_loaded`, which fails closed | `plugs/auth_pipeline.ex:420-442` |

## 3. Route decision (OQ-1 CLOSED: R-N, advisor letflow-ec ruling)

### 3.1 Constraint set

C1 core names no business domain (0039 D1, enforced by D3's check, S23); C2 ledger invariants live in reviewed module code (0054 Correction, S24); C3 0057 D5: the guard runs "inside the module write handler"; C4 gh2590 F-R5/OQ-R4: the planned route was update-kind handler writes plus a narrow read facade, scheduled for WMS slice 5 (`gh2590...md:199,1073,1094,1099`); C5 the ledger needs a gap-free counter, an atomic multi-leg posting, a guard under ordered row locks and exact quantities; C6 offline fields (0058 c).

### 3.2 Route R-D (REJECTED): entity-type ledger through update-kind handler writes plus a read facade

Shape: header, leg and balance are managed ENTITY TYPES; the handler writes them through `create/3` (header and legs are `append_only` types: update/delete refused at runtime with `entity_append_only`, `0054...md:167`) and a NEW update-kind with a record-version precondition (S12), plus a NEW read facade returning one record under the type's lock.

Needs from REQ-501 housekeeping (all NOT FOUND today): update kind in `Records.command_multi` (only `kind: :create`, `gh2590...md:199`); a read facade and lock rule (handler purity contract, S15); update lines in the `TASK_ENTITY_WRITES_APPLIED` schema (`additionalProperties: false`); engine plan and authorisation of update lines.

Why rejected (the ruling's reason): R-D **cannot give a gap-free queryable `posting_seq`** (the only gap-free number is the header type's per-type sequence number in the event stream, S7; exposing it as a field needs a new core "system field" feature) **and cannot give an atomic multi-leg posting** beyond 49 creates per handler call and 20 lines per node; the guard serialises on the balance TYPE row tenant-wide (`handler_writes.ex:426-437`), so row locks in a fixed order (0057 D5) are not expressible; append-only would be Records-layer only (no database trigger exists for entity records); each leg and balance update costs an event, a projection row and an audit entry. The two core changes that make a neutral primitive justifiable are already accepted: `append_only` entity types (`0054...md:167`) and `non_negative`/`min`/`max` bounds (GH #2532, closed, `0057...md:26`).

### 3.3 Route R-N (ADOPTED): a domain-neutral core posting primitive

A core context `Letflow.Ledger` (directory `lib/letflow/ledger/`) names only **ledger, entry, leg, balance, balance key, counter, quantity**. Dimensions are an OPAQUE ordered tuple of text slots. There is no item, location, stock, warehouse or site vocabulary, no cause list, no hard-coded permission atom, no business error code and no business CHECK in core. The MODULE registers the ledger in its manifest (new top-level `ledger` key, 14.3): ledger-id form, slot names and formats, the closed set of CAUSES with their sign rules, per-key bounds, the permission atoms, the optional scope slot, the lateness cap, `error_aliases` and the pure policy function. The vocabulary of the issue (`stock_movement`, `stock_balance`, item, location, `insufficient_stock`) lives in the stock module's registration, views, routes and wire codes.

**The policy is ONE pure function `declare/2` at BUILD time (decision B3).** In L1-L4 the module's policy is `declare(command, registration) :: {:ok, declarative_posting}`, a pure function of the command and the registration data, invoked by `HandlerWrites.post/3` through the Catalog at BUILD time (inside the handler call, with no database access at all). There is no `gather_facts`, no master check (item/location active, unit valid), no `expected_document_version` check and no retired-master check in L1-L4: each of those needs a READ of a table, and REQ-501 gives handlers no reads (S1, V1); a `gather_facts` callback would reintroduce the read facade that OQ-R4 says is still owed. They are listed as DEPENDENT on the OQ-R4 read facade (owed at WMS slice 5, or provided later by core) in 9.4, 9.5, 14.6 and 17.

**Boundary enforcement (new `check_boundaries` rules, 3.5).** Defined in 3.5.

**Second plausible consumer (0039 D1 test):** a CMMS spare-part store (issues and returns against a non-negative on-hand with gap-free document numbers) or HR leave balances (accrual and usage legs, non-negative balance, reversal by a new entry). Neither is built; both would register a different ledger id, slots and causes with no core change. The primitive is otherwise justified as a platform feature by the two accepted core changes above.

| Constraint | R-N |
|---|---|
| C1 | neutral mechanism like the event store or audit chain; Rules 7 and 8 (3.5) |
| C2 (0054 Correction) | The Correction wants ledger invariants in reviewed module code, not declarative step data. R-N keeps that for everything that is BUSINESS: which causes exist, their sign rules, slot meanings, per-key bounds, unit choice, who may post, the process route, all registered as reviewed module data plus the pure `declare/2`. The core enforces only generic MECHANICAL invariants a create-only handler cannot (append-only, gap-free counter, zero-sum per declared group, non-negative balance and registered per-key bounds, reversal pairing). 0062 records this as a deviation from the letter of the Correction and states that module code still owns the policy. |
| C3 (0057 D5) | met in substance; 0062 amends the wording |
| C4 (OQ-R4) | **OQ-R4 stays OWED at WMS slice 5 and is NOT replaced**: update-kind handler writes and the read facade are still needed for entity DOCUMENTS and for the master checks above. R-N removes only the LEDGER's dependence on them. |

**Design cost recorded (EC F13):** a posting handler must still declare at least one managed bookkeeping target (S21: `write_handler_no_targets` and `write_handler_without_managed_types` stay), so a stock module must manage at least one entity type that the posting handler writes through `create/3` (for example a document-line record). That is a cost of keeping rule 10 unchanged.

### 3.4 What the ruling requires of the rest of the note

The note is written for R-N. R-D would have changed sections 4-7 and 12.3 and is not maintained. Unchanged either way: sections 8, 9.2-9.3, 10, 12.2 intent, 16.

### 3.5 Boundary rules (M1, M2, round 3 items 9 and SEC 1)

* **Rule 7 (neutral vocabulary).** SCOPE: every file under `lib/letflow/ledger/**`, the ledger migration, `lib/letflow/modules/ledger_registration.ex` (the rule-12 validator and accessor), and the ledger parts of shared files, which therefore live in their OWN files so the scan can cover them: `lib/letflow/ledger/handler_post.ex` (the implementation behind `HandlerWrites.post/3`, a one-line delegate), `lib/letflow/ledger/failure.ex` (the clause `StepWrites.interpret_failure/2` delegates to) and `lib/letflow/ledger/codes.ex` (the neutral code list and its HTTP status table, which `api/response.ex` delegates to). SCAN UNIT: the Elixir AST (`Code.string_to_quoted`) of each file; the tokens are identifiers (atoms, variables, function and module names) and string literals; each token is split on `_`, on non-alphanumerics and on camelCase boundaries into lowercase words; COMMENTS, `@moduledoc` and `@doc` are excluded. A word fails the check when it EQUALS a denylist entry or the entry plus a plural suffix (`s`, `es`): denylist `stock, item, location, warehouse, site, lot, serial, sku, material, inventory, bin, pallet`. So `stock_movement`, `insufficient_stock`, `:StockPost`, `items`, `locations` fail; `insufficient_balance` passes; `binary`, `website` and `lottery` are different whole words and pass. The denylist is a reviewed constant, and a new allowlist pair or a new denylist entry is added ONLY by a reviewed diff. **Reviewed allowlist for migration SQL:** SQL is a string literal tokenised the same way, and Postgres vocabulary can collide (`serial`/`bigserial` is a column type keyword); the allowlist is a short reviewed list of `{file, word}` pairs (initially empty; the ledger migration uses `bigint`, so no entry is expected), and a new pair is a one-line reviewed diff.
* **Rule 7b (no module reference).** The scanned files may not reference any `Letflow.Modules.*` name except `Letflow.Modules.LedgerRegistration`.
* **Rule 8 (single call site, and no forgery).** A call-site scan (a new function in the `check_boundaries` task that parses every `lib/**` file's AST; the existing task classifies file-level xref edges only, S23) over the module subdirectories `lib/letflow/modules/<id>/**` and Lua/WASM host code (`lib/letflow/scripts/**` and the host-function modules): (a) `Letflow.Ledger.post` and `Letflow.Ledger.Capability.mint` are called only from `lib/letflow/ledger/handler_post.ex`; (b) module and host code may call the authorised READ functions of 14.1, nothing else of `Letflow.Ledger`; (c) **no struct literal, struct pattern match, `%{__struct__: ...}` or alias of `Letflow.Ledger.Capability`, `Letflow.Ledger.Authorized` or `Letflow.Api.Scope.Principal`** appears there (a module could otherwise write `%Principal{kind: :token, grants: :token}`, which `Scope.allowed_set/2` answers `{:ok, :all}`, and mint an `authorized` value; `Scope.Principal` is a plain public struct, `api/scope.ex:99-106`); (d) no `apply/3`, `Kernel.apply`, `:erlang.apply`, `Module.concat`, `Module.safe_concat` or `String.to_existing_atom` that could build a `Letflow.Ledger` or `Principal` name; (e) the policy files named by a registration's `policy:` may reference only `Letflow.Ledger.Policy` among `Letflow.*` names (14.4). EXEMPTIONS (explicit, reviewed): `lib/letflow/modules/ledger_registration.ex` (it is under `modules/` but not a module subdirectory, so it is outside the scan scope by construction) and `lib/letflow/ledger/**`. TEST SEAM (T-SC-4): the scan is a pure function `violations([{path, source_text}])`, so the test feeds synthetic sources and asserts the exact violation tuples. Optional hardening (OQ-24, default no): a MAC or nonce on `Capability` and `Authorized` verified by core.

## 4. Schema (R-N; first migration)

All tables are per tenant schema (tenancy is the prefix, no `tenant_id`). Delivery: one tenant migration file (or an ordered set) in `priv/repo/migrations/` AND an entry in `TenantProvisioning.tenant_scoped_migrations/0` (S10), `expected_tenant_tables/0` updated in the same PR (4.6), version prefix chosen against open branches (S11); Rule 7 ships in the SAME PR as the tables. Every trigger and function body qualifies EVERY table name with the schema, built with Postgres `format('%I', ...)`/`quote_ident` from the validated `prefix()` (INV-7: the schema name is the only interpolation and it is quoted, not concatenated raw), never uses `search_path`, never `SECURITY DEFINER`, and contains no tenant data; this is what lets `TenantTemplate` clone them by replacing the template qualifier (S9b); clone test T-TT-2. The `down` of the migration raises unless an explicit configuration flag `:allow_ledger_migration_down` is true (set only in dev and test config; NOT `Mix.env`, which does not exist in a release). Quantities are `numeric(30,9)` provisionally (OQ-10). No FK from any ledger table to an engine or entity table (D-L11).

**Text hygiene (R2-7).** Every untrusted text column has `CHECK (octet_length(col) <= n)` and `CHECK (col !~ '[[:cntrl:]]')`; hash columns have `CHECK (col ~ '^[0-9a-f]{64}$')`; ledger-id columns have `CHECK (col ~ '^[a-z0-9_]{1,32}(:[a-z0-9-]{1,32})?$')`. Slot values are validated in code against the slot's registered `format` (4.5) and canonicalised; free text lives only in `attrs`.

Naming map (issue term -> core table -> stock module view/read name): `stock_movement` -> `ledger_entry` -> `stock_movement`; legs -> `ledger_leg` -> `stock_movement_leg`; `stock_balance` -> `ledger_balance` -> `stock_balance`. The module names are views or read-API names of the stock module slice, never core tables.

### 4.1 `ledger_counter` (one row per ledger id)

| Column | Type | Rule |
|---|---|---|
| `ledger_id` | text PK | the structural form of the CHECK above: `<module_id>` or `<module_id>:<suffix>`, at most 64 bytes |
| `last_seq` | bigint NOT NULL | `CHECK (last_seq >= 0)` |
| `last_chain_hash` | text NOT NULL | `''` or 64 hex; the chain head (5.1) |

**Bootstrap (F3, N2).** There is NO seed row in the migration: the row is created lazily by the first poster of a ledger id with insert-if-absent (`ON CONFLICT DO NOTHING`, then the locking read), exactly as the sequence-row precedent (S7). The BASE CASE of the proof is therefore `c(1) = 0` (the freshly inserted row has `last_seq = 0`). Two first-posters race harmlessly: the second insert waits on the first's transaction; if the first ROLLS BACK the row never existed and the second inserts it; if it commits the second conflicts and locks. This also makes pooled test clones (built with `LIKE`, no rows, `@seed_tables` a fixed list, S9b) work with NO change to `@seed_tables`. The BEFORE INSERT trigger allows only `last_seq = 0, last_chain_hash = ''`. For per-instance ledger ids a cap on distinct ids per tenant applies (14.3, default 64).

### 4.2 `ledger_entry` (header, append-only)

| Column | Type | Null | Meaning |
|---|---|---|---|
| `id` | uuid PK | no | the **stable operation id** |
| `ledger_id` | text | no | the sequence domain |
| `posting_seq` | bigint | no | `>= 1`; UNIQUE `(ledger_id, posting_seq)` |
| `cause` | text | no | one of the causes the module REGISTERED (checked in code); **no core CHECK on the list**: only `octet_length BETWEEN 1 AND 64`; the cause `reversal` is reserved by core |
| `sign_rule` | text | no | copied from the registration so the deferred trigger needs no code: `CHECK (sign_rule IN ('positive','negative','zero_sum_by_slot_1','any','reversal'))` (a closed MECHANISM vocabulary) |
| `reverses_entry_id` | uuid | yes | FK to `ledger_entry(id)`; `CHECK ((cause = 'reversal') = (reverses_entry_id IS NOT NULL))`; UNIQUE partial index where not null; the target must have the same `ledger_id` (trigger) |
| `reason_code` | text | yes | `<= 64` bytes; required non-blank for `reversal` and for causes the registration marks `reason_required` |
| `document_type`, `document_id`, `related_document_id` | text | yes | each `<= 128` |
| `actor_id`, `subject_id` | uuid | no | event actor and authorisation subject |
| `correlation_id` | text | no | `<= 128`; defaults to the BPM instance id |
| `bpm_instance_id`, `bpm_task_id` | uuid | yes | from `HandlerContext`; no FK (D-L11) |
| `bpm_node_id` | text | yes | `<= 128` |
| `bpm_definition_id`, `bpm_definition_version` | uuid, text | yes | version `<= 64` |
| `event_time` | timestamptz | no | section 8 |
| `posting_time` | timestamptz | no | `clock_timestamp()` read under the counter lock |
| `client_op_id` | text | no | `1..128`; no `sys:` prefix; UNIQUE with `subject_id` |
| `origin_key` | text | no | `<= 200`; UNIQUE; `sys:step:<origin>:<line>:<ordinal>` |
| `payload_hash` | text | no | SHA-256 hex over the validated RAW command plus `subject_id` (9.2) |
| `entry_digest` | text | no | SHA-256 hex over the canonical form of ALL immutable header columns (every column of this table except `entry_digest` and `chain_hash`) plus the canonical ordered legs (per leg in `leg_no` order: slots, quantity as canonical text at scale 9, `unit_ref`, `attrs` as canonical key-sorted JSON, `document_line_id`, the REQ-504 columns). Computed in code (5.1) |
| `chain_hash` | text | no | SHA-256 hex over `prev_chain_hash || entry_digest`, where `prev_chain_hash` is `ledger_counter.last_chain_hash` read under the counter lock |
| `device_id` | text | yes | `<= 64`, `[A-Za-z0-9._:-]`; client-supplied, NOT an authorization control (8.1) |
| `client_seq` | bigint | yes | `>= 0`; both or neither with `device_id`; UNIQUE `(subject_id, device_id, client_seq)` where set |
| `client_event_time` | timestamptz | yes | as reported; allowed only with `device_id` |
| `scope_ref` | text | yes | opaque copy of the registered scope slot's value (16.2); `<= 128`; not in any balance key |
| `leg_count` | smallint | no | `1..200` |

Also `UNIQUE (id, ledger_id, posting_seq, event_time)`. Indexes: UNIQUE `(ledger_id, posting_seq)`; UNIQUE `(subject_id, client_op_id)`; UNIQUE `origin_key`; `(ledger_id, event_time, posting_seq)`; `(document_type, document_id)`; `(bpm_task_id)`; `(correlation_id)`; the partial uniques.

### 4.3 `ledger_leg` (append-only)

| Column | Type | Null | Meaning |
|---|---|---|---|
| `id` | uuid PK | no | |
| `entry_id`, `ledger_id`, `posting_seq`, `event_time` | uuid, text, bigint, timestamptz | no | composite FK to the header's `UNIQUE (id, ledger_id, posting_seq, event_time)`: the copies cannot differ |
| `leg_no` | smallint | no | 1-based; UNIQUE `(entry_id, leg_no)` |
| `k1` .. `k8` | text COLLATE "C" | no | balance-key slots, default `''` (none); **only `k1` must be non-empty** (CHECK); the number of slots used and which are required are checked in code against the registration (N1); each `<= 128` bytes |
| `quantity` | numeric(30,9) | no | signed delta in the base unit; `CHECK (quantity <> 0)` |
| `unit_ref` | text | no | `<= 128`, charset `[a-z0-9._:-]` (the `:token` format); must belong to the registration's optional `units` allowlist when one is declared; the unit the key's balance is kept in (pinned on the balance row, 4.4) |
| `attrs` | jsonb | yes | non-key attributes; code limits: at most 16 keys, depth 2, scalar values, key charset `[a-z0-9_]`; `CHECK (octet_length(attrs::text) <= 4096)` |
| `document_line_id` | text | yes | `<= 128` |
| (REQ-504 columns) | | | 4.5 |

Indexes: `(ledger_id, k1, k2, posting_seq)` INCLUDE `quantity`; `(ledger_id, k2, k1, posting_seq)` (EC F11: a by-second-slot query); `(ledger_id, k1, k2, event_time, posting_seq)`; `(entry_id, leg_no)`. Filters on slot 3 and later scan within the `(k1, k2)` range (acceptable for the pilot; a test budget is a L2 item); a dimension that is not a key part (an expiry) lives in `attrs` and, for reporting, belongs on the lot MASTER and is joined at read time. A NINTH slot would need DDL (recorded).

### 4.4 `ledger_balance` (derived cache; the only mutable ledger table)

PRIMARY KEY `(ledger_id, k1 .. k8)`; `on_hand numeric(30,9) NOT NULL CHECK (on_hand >= 0)`; **`unit_ref text NOT NULL`** pinned at first touch (EC F10: the unit is not in the key; a leg with a different unit for an existing key is refused `unit_mismatch`); **`max_on_hand numeric(30,9) NULL`** pinned at first touch from the registration's `key_bounds` (M6/F8; when several bounds match a key the MINIMUM wins) with `CHECK (max_on_hand IS NULL OR on_hand <= max_on_hand)`; a pinned value is NEVER re-pinned, so a later registration change affects only NEW keys, never existing ones (pilot risk, below); `last_posting_seq bigint NOT NULL`; `updated_at timestamptz`. A row is inserted with `on_hand = 0, last_posting_seq = 0` on first touch and never deleted (tombstone rule). Secondary index `(ledger_id, k2, k1)`.

**Pilot risk of the pin (CDV 10).** The first posting that touches a key pins `unit_ref` and `max_on_hand` from CLIENT-SUPPLIED values (no master check exists in L1-L4) and the row is immutable (trigger 5.2): a wrong unit or a mistyped bound on a first receipt is permanent for that key. Mitigations in the design: `unit_ref` has the `:token` charset and an optional registration `units` allowlist (a first poster cannot pin an arbitrary string); bounds come from the REGISTRATION, not the client. Operator remedy for a wrongly pinned key: post a reversal or an `adjustment` taking the key to zero and re-post under a corrected key (a different slot value or unit string); there is no in-place repair by design. Conversion and tolerance evidence that `declare/2` writes into the optional REQ-504 leg keys in L1-L4 comes from CLIENT-SUPPLIED factors and is UNTRUSTED metadata (stored, not verified; verification needs the read facade).

### 4.5 Columns by reference, slots, and the text for #2658 (OQ-16 closed)

* **REQ-503 (#2658).** Under R-N the typed nullable dimension columns become **slots**: the registration lists slots in an APPEND-ONLY ordered list, each `%{name, format: :uuid | :token, required: boolean}`; `:uuid` is a lowercase canonical UUID text (core validates and canonicalises, so two spellings cannot split a balance, EC F9), `:token` a fixed charset `[a-z0-9._:-]` of at most 128 bytes; an unused slot is `''`; adding a dimension registers a new slot name (no DDL, no row rewrite); reordering or removing a slot is refused by rule 12. A non-key dimension (expiry) goes into `attrs`. **Per-BALANCE-KEY invariants beyond `on_hand >= 0` (M6, EC F8): a registration `key_bounds` entry `%{when_slot_nonempty: slot_name, max_on_hand: decimal_string}` makes the core pin `max_on_hand` on the balance row when the key is first touched and enforce it in the guard under the same key lock, backed by the CHECK in 4.4.** Scope of the guarantee, stated exactly: the bound applies to ONE balance key, i.e. the full tuple `(k1 .. k8)` INCLUDING location. The stock module's `%{when_slot_nonempty: "serial", max_on_hand: "1"}` therefore means "at most one unit of this item+location+serial tuple", NOT "a serial exists once in the tenant": the same serial received at two locations is two keys and both pass. Tenant-wide serial uniqueness needs a different mechanism, recorded as OQ-23: a registered `unique_over: [slot names]` subset whose SHADOW key row (the same table, key slots outside the subset set to `''`) is locked in the same ascending order and carries its own `max_on_hand`; it is NOT in release 1 (default). Values: `max_on_hand` must be positive and fit `numeric(30,9)` (rule 12). Core code for a bound violation: `balance_bound_exceeded` (409, alias at the module).
  **Text to post on #2658 (for the coordinator):** "Under decision-0062 route R-N (advisor ruling 2026-10-19) the ledger stores dimensions as at most 8 opaque text slots registered by the module in an append-only ordered list with a closed format (uuid or token); an unused slot is the empty string; adding a dimension is a registration change, not DDL. Please align the #2658 note: (1) list the dimension NAMES, FORMATS and which are required, instead of typed nullable columns; (2) state which belong to the balance key (slot order is the lock order: item, location first); (3) express "at most one unit per item+location+serial" as a registration key_bound (when serial non-empty, max_on_hand 1) enforced under the key lock; NOTE it is per balance key including location, so tenant-wide serial uniqueness is a separate open item (OQ-23); (4) replace the byte-identity migration test by: slot registration is append-only and a populated ledger is byte-identical after a registration change; (5) expiry goes into the leg attrs, or onto the lot master and is joined at read time; (6) status effect on available-to-pick is a read-side filter on a slot."
* **REQ-504 (#2660).** `quantity_original numeric(30,9)` (signed), `original_unit_ref text`, `conversion_factor numeric`, a tolerance-evidence reference: nullable on `ledger_leg`; the conversion itself is computed by `declare/2` from arguments already in the command (no master read in L1-L4).
* Comparator (F16): byte comparison of the slot texts (`COLLATE "C"` in SQL, binary comparison in Elixir), `''` the sentinel. Slot order is the lock order.

### 4.6 Tenant export, restore, delete and the table-set oracle

* **Table-set oracle:** `TenantFixture.expected_tenant_tables/0` (`test/support/tenant_fixture.ex:133, 862`) gains the four names in the L1 PR; the replay test asserts the table set equals the oracle.
* **Provisioning:** the migration is registered in `TenantProvisioning.tenant_scoped_migrations/0` (`tenant_provisioning.ex:728-731`).
* **Delete:** the only schema removal found is the sandbox pool's `DROP SCHEMA ... CASCADE` (`sandbox_pool.ex:1004-1026`); DROP does not fire the row or TRUNCATE triggers. A production TENANT delete path: NOT FOUND. **The sandbox fixture loader** runs `TRUNCATE ... CASCADE` on fixture tables (S9c): with the TRUNCATE trigger it would raise for a ledger table; `fixture_loader.ex` gets a deny list (`ledger_*` tables are refused as fixture targets, a typed error) and a test (T-TT-4), so a fixture can never target the ledger.
* **Export and restore:** NOT FOUND in `lib/`; decision 0057 D19 (`0057...md:68`) plans an export package. Requirement carried to that work: the ledger (`ledger_entry`, `ledger_leg`, `entry_digest`, `chain_hash`) is part of the package; a restore is whole-schema (counter, entries, legs, balances together); a partial restore of a ledger table is forbidden; after a restore `reconcile/3` must report clean before the tenant is unfrozen. Purge of ledger rows is never offered.

## 5. Append-only enforcement

### 5.1 Decision: database level, a tripwire plus a single writer, and a chain anchored in the audit chain

The handler path alone is not a sufficient guarantee for a legal record; the repository precedent for such a record is the database trigger (S9). Decision 0054 option A (managed types) and the R2 stamp protect entity types and definitions, not these tables. The triggers are a **TRIPWIRE against bugs and accidents, not a security boundary**: the application connects as the table owner, which can disable triggers.

1. **Triggers** on `ledger_entry` and `ledger_leg`: BEFORE UPDATE and BEFORE DELETE (row) raising one fixed text, and **BEFORE TRUNCATE (statement)** raising the same (added on the advisor's instruction; the precedent tables omit it because the pooled test reset needs TRUNCATE, S9, resolved in 5.4).
2. **Structural constraints** (section 4) and the deferred checks (5.3).
3. **Single writer** scans (Rules 7, 8) and the capability (16.4).

**Tamper evidence (R2-2).** `entry_digest` covers EVERY immutable header column and the canonical ordered legs (4.2); `chain_hash = SHA-256(prev_chain_hash || entry_digest)` per ledger id, serialised by the counter lock. The new `chain_hash` is also written into the `ledger.posted` audit entry (7.7), which sits in the tenant audit chain (itself immutable and chained), so a rewrite of the ledger by the table owner must also forge the audit chain. `reconcile/3` recomputes digests and the chain. Honest statement: this DETECTS bugs and edits by anyone who does not recompute the chain; an owner who recomputes both chains and the audit chain can still defeat it; an optional keyed digest (HMAC with a platform secret via `Letflow.Secrets`, INV-4) raises the bar and is OQ-18 (default: unkeyed in release 1; the columns are the same). Both columns are in the FIRST migration because an append-only table cannot be back-filled.

Residuals: the owner can `ALTER TABLE ... DISABLE TRIGGER`; a superuser can set `session_replication_role = replica`; `REVOKE` is not used (S9).

### 5.2 Trigger rules

| Table | Trigger | Rule |
|---|---|---|
| entry, leg | BEFORE UPDATE, DELETE (row), TRUNCATE (statement) | raise the fixed text |
| counter | BEFORE UPDATE | `NEW.last_seq = OLD.last_seq + 1`, `ledger_id` unchanged |
| counter | BEFORE INSERT | `last_seq = 0` and `last_chain_hash = ''` only |
| counter | BEFORE DELETE, TRUNCATE | raise |
| entry | BEFORE INSERT | `NEW.posting_seq` equals the CURRENT `last_seq` of the counter row of `NEW.ledger_id`; when `reverses_entry_id` is set, the target exists, has the same `ledger_id` and its own `reverses_entry_id` IS NULL |
| balance | BEFORE INSERT | `on_hand = 0` and `last_posting_seq = 0` |
| balance | BEFORE UPDATE | key columns, `unit_ref` and `max_on_hand` immutable; if `on_hand` changes then `NEW.last_posting_seq` equals the counter's current `last_seq` for the row's `ledger_id`; no DELETE/TRUNCATE. This proves the change happened in a transaction that already holds the allocated number; it does NOT prove it came from the poster (a session with UPDATE rights could set both), which is why reconciliation exists. |

### 5.3 Deferred constraint triggers (at COMMIT)

| On | Rule |
|---|---|
| counter AFTER UPDATE, `DEFERRABLE INITIALLY DEFERRED` | an entry with `(ledger_id, posting_seq) = (NEW.ledger_id, NEW.last_seq)` exists **and its `chain_hash` equals `NEW.last_chain_hash`** (EC F1) |
| entry AFTER INSERT, `DEFERRABLE INITIALLY DEFERRED` (once per header) | (i) the number of legs equals `leg_count`; (ii) the legs obey `sign_rule`: `positive` all quantities > 0, `negative` all < 0, `zero_sum_by_slot_1` the quantities sum to zero per distinct `k1`, `any` none; (iii) for `reversal`, per balance key the legs of this entry and of the target sum to zero and the key sets are equal |

The mechanism vocabulary is closed and neutral; WHICH cause uses WHICH rule is module data.

### 5.4 Pooled test schemas (TenantTemplate): the reset conflict, resolved (N4, EC F7)

Facts (S9b): `reset_clone_schema!/3` TRUNCATEs exactly the dirty tables plus the closure of FK-referencing tables (no CASCADE), re-copies `@seed_tables`, and its moduledoc states there is no BEFORE TRUNCATE trigger (`tenant_template.ex:621-624`); clones are `CREATE TABLE (LIKE ...)` with no rows (`:1343`). With the new triggers a reset of a dirty ledger table would raise.

Chosen mechanism (recorded for 0062): **ledger tables are unresettable.** `TenantTemplate` gets a fixed list `@append_only_tables = ["ledger_entry","ledger_leg","ledger_counter","ledger_balance"]`; when its probe finds ANY of them dirty, `reset_clone_schema!` returns `{:error, {:unprovable, ["append_only_table_dirty"]}}` (the reasons are STRINGS, S9b) BEFORE any DML; the pool labels it `:verify_failed` (tenant_fixture.ex:1860-1875: any non-drift unprovable result), which already rebuilds the slot with `rebuild_clone_schema!/1` (no repair in place). No new pool label is added. The moduledoc sentence at `tenant_template.ex:621-624` ("there is no BEFORE TRUNCATE trigger") is rewritten in the L1 PR to say the ledger tables are the exception and are rebuilt, not truncated. The counter bootstrap needs no `@seed_tables` change (4.1). The sandbox fixture loader deny list is in 4.6. Rejected: a GUC-controlled TRUNCATE bypass inside the trigger (any raw SQL session can set a GUC) and omitting the TRUNCATE trigger (the precedent; leaves TRUNCATE open, against the advisor). Cost: every test module that posts rebuilds its slot afterwards; ledger tests are few and `async: false`.
Tests: T-TT-1 (a dirty ledger slot is `unprovable` with the string reason and rebuilt; a clean slot untouched), T-TT-2 (triggers in a clone refuse and name the clone schema), **T-TT-3 (no non-ledger table's FK closure pulls a ledger table into a TRUNCATE: an assertion over the clone's FK graph that no foreign key references a ledger table and none leaves one)**, T-TT-4 (fixture loader refuses a ledger table).

## 6. The gap-free sequence

### 6.1 Mechanism

Two counter statements on the ONE counter row of the posting's `ledger_id` (a posting touches exactly one ledger id), both after every balance row is locked and the guard has passed (steps 8 and 9 of 7.1): (1) a locking read, Ecto `lock: "FOR UPDATE"` composition exactly as the sequence-row precedent (`event_store.ex:806-811`, S7), which waits for the previous holder and returns the latest committed `last_seq` and `last_chain_hash`; (2) after the idempotency re-check under that lock, the code computes `new_seq = last_seq + 1`, `entry_digest` and `new_chain_hash = SHA-256(last_chain_hash || entry_digest)` **from the values the locking read returned, BEFORE the UPDATE (no dependence on RETURNING, EC F1)**, then runs an Ecto `update_all` setting `last_seq = new_seq` and `last_chain_hash = new_chain_hash` (no SQL string, INV-7), with the tenant `prefix:` option. The lock is held to the end of the transaction. NOT a Postgres SEQUENCE (`nextval` is not transactional) and not `max + 1`. READ COMMITTED is required: after waiting, `FOR UPDATE` returns the latest committed version; under REPEATABLE READ the read would raise a serialization failure instead of producing a gap. **Step 1 of the algorithm asserts at run time that `current_setting('transaction_isolation')` is `read committed` and refuses otherwise** (N3: a role-level `default_transaction_isolation` would silently change the Repo default and break the proof; a test sets it on a role and expects the refusal) and the test T-GF-3 pins the Repo default. A duplicate found by the re-check returns WITHOUT the UPDATE.

### 6.2 Proof of gap-freeness

Claim G1: for each ledger id, the committed `posting_seq` values are exactly `1..M` for all time. Claim G2: every snapshot sees a prefix `1..n`. (Everything below is per ledger id.)

Facts (each enforced above): F1 the only writer of `last_seq` is the posting UPDATE, +1 (trigger 5.2); F2 a header's `posting_seq` equals the counter value current in its transaction (trigger 5.2) and a transaction that bumps the counter cannot commit without a header of that number (deferred trigger 5.3); F3 the counter row lock is held to commit or rollback; F4 a rolled-back transaction leaves the counter as it was (MVCC); F5 PostgreSQL makes a commit visible to new snapshots (ProcArray removal) BEFORE it releases the transaction's locks (argued from PostgreSQL commit internals, not run here); F6 a transaction that finds a duplicate under the lock does not run the UPDATE; **F7 the counter row is created lazily by insert-if-absent; a creator that rolls back leaves no row, a committed creator leaves `last_seq = 0`**.

Proof of G1: induction over the transactions in the order they acquired the counter lock. **Base case: the first lock holder reads `c(1) = 0` (F7: either the row it created itself, or the committed row of a first poster that committed with `last_seq = 0` untouched, or, if that first poster rolled back, a row it inserts itself).** By F3 the order is total and non-overlapping: `Tk` acquires the lock only after the previous holder committed, rolled back or took the duplicate path. Let `c(k)` be the committed `last_seq` before `Tk`: unchanged if the previous holder rolled back or took the duplicate path (F4, F6), `+1` if it committed an UPDATE (F1). `Tk` reads `c(k)`, writes `c(k)+1` and, if it commits, commits a header numbered `c(k)+1` (F2). So committed numbers are `1,2,3,...` in lock order, none skipped, none reused. QED. Proof of G2: `Tk` is visible to new snapshots (F5) before `T(k+1)` can take the lock.

Two concurrent postings (counter at 41):

| Step | T1 | T2 | Counter | Outcome |
|---|---|---|---|---|
| a | locks its balance rows, passes the guard | locks its (different) rows, passes the guard | 41 | no conflict |
| b | counter `FOR UPDATE` then `UPDATE` -> 42 | counter `FOR UPDATE` blocks | 42 (T1) | T2 queues |
| c1 | inserts entry 42 and legs, commits | wakes, reads 42, writes 43 | 42, 43 | commits 42, 43 |
| c2 | fails after (b) and ROLLS BACK | wakes, reads 41, writes 42 | 41, 42 | T2 commits 42, **no gap, 42 reused** |
| d | same `(subject, client_op_id)` and same key set as T2 | T2 waits at its balance-row lock; after T1 commits its re-check right after the key locks (step 7) finds T1's entry | 42 | T2 returns the duplicate result; no guard, no counter lock, no UPDATE |
| e | same key as T2 but a DIFFERENT key set (so no shared balance row) | T2 passes the guard, waits at the counter; after T1 commits the counter re-check (step 9) finds T1's entry | 42 | T2 returns the duplicate result without the UPDATE (F6) |
| f | the first poster of a ledger id inserts the counter row and rolls back | the second poster inserts the row itself | none, then 0 -> 1 | the base case (F7); T-AO-1 |

### 6.3 Reader contract

A report takes `N` and its rows in ONE snapshot (a single statement/CTE, or one `REPEATABLE READ READ ONLY` transaction); `N` is `max(posting_seq)` of that snapshot or a caller number `<= max`; above the counter it is refused `cutoff_in_future`. By G2 a report at `N` run later returns the same rows.

## 7. Lock order

### 7.1 The posting algorithm (normative; ONE posting per transaction, one ledger id per posting)

**At BUILD time** (inside the handler call, in `HandlerWrites.post/3` through `lib/letflow/ledger/handler_post.ex`; no database access): (B1) verify the per-call process token and the context EXACTLY as `create/3` does (S1b: the token exists only during the build, so this is the only place it can be checked); the build-time CREDENTIAL check on the context (no DB) may stay here as an early refusal: `credential != :oidc` yields the uniform `write_not_permitted` body; (B2) check the command's closed shape and size (the 256 KiB and 200-leg caps are enforced by core BEFORE `declare/2` is called); (B3) run the module's pure `declare/2` through the Catalog (a raise/exit/throw becomes a deferred closed failure); (B4) core validation of EVERYTHING `declare` returned against the registration: ledger id form and that it belongs to the handler's named registration, cause registered, sign rule, leg count and caps, slot count/formats/required slots (canonicalising UUID slots), `unit_ref` charset/allowlist, canonical decimals (never rounded), `attrs` limits, `reason_code`, `document_*` lengths, `reverses_entry_id` shape, `scope_ref`, timestamp parse (strict) and the client-supplied `event_time` against the lateness cap measured with the build-time clock (a fast check; the authoritative check is step 9); (B5) the one-posting check (7.4); (B6) mint an opaque `Letflow.Ledger.Capability` (only `handler_post.ex` may call `mint`, Rule 8) holding the platform-set prefix, instance, origin, actor, subject, `credential`, registration name, `origin_key`, the validated declarative posting, and **a `deferred_refusal :: nil | {code, wire_code, details}`**; (B7) append ONE Multi step `{:line, key, :ledger_post}` whose closure calls `Letflow.Ledger.post(capability)`.

**B4 and B5 never emit a client-visible refusal themselves (INV-5, INV-4; round 4 SEC 1).** If B3, B4 or B5 finds a problem, the build does NOT append a typed `Multi.error`: it records the problem as the capability's `deferred_refusal` and still appends the ONE ordinary step of B7. The RUN step executes the AUTHORITY check first (step 2: credential, roles from the database, scope) and only then, for an AUTHORISED subject, returns the deferred refusal as `{:ledger_refused, code, wire_code, details}`. An unauthorised subject (no post permission, `:api_token`, scoped principal) who sends an invalid command therefore gets the byte-identical `write_not_permitted` body for every build-time refusal kind and cannot probe the registration's shape (slot names, formats, causes, lateness cap) through error bodies. The deferred refusal still carries nothing from module code: `declare/2`'s own `{code, details}` is NOT passed to the wire; core rebuilds `invalid_posting` details from a closed reason enum plus `leg_no` (an integer or null), and any reason outside the enum becomes `unspecified`.

**Build-time refusals reach the typed envelope, for AUTHORISED subjects (CDV 2).** Handler errors collapse to a closed set without detail (`handler_invalid_arguments` 422, `handler_not_permitted` 403, `handler_shape`/`handler_raised` internal; `step_writes.ex:980-1000`), so a refusal returned as `{:error, ...}` from `post/3` would never carry `invalid_posting {leg_no, reason}`, `posting_not_balanced` or `event_time_*`. The deferred refusal rides the ONE ledger step instead, whose name `{:line, key, :ledger_post}` is routed by `StepWrites.interpret_failure/2` to `ledger/failure.ex` (12.3). `post/3` itself returns `{:error, :invalid_context}` only for a forged or absent token/context (the same as `create/3`'s `:invalid_write_command`, collapsed by the existing mapping to an internal failure).

**Bookkeeping with `check_built` (CDV 3).** `check_built/3` refuses (`handler_shape`) any returned entry that `create/3` did not record in the token's `produced` list, and `next_ordinal/1` takes the ordinal and the 49-entry budget from the same token (`handler_writes.ex:203-216, 650-675`). `post/3` therefore uses the same primitives: it takes `ordinal = next_ordinal(token)`, builds its step key as `StepSource.call_key(line_index) + ordinal`, and records the step entry in `produced` with `record_produced/2`, so `check_built` and `complete?` accept it. **The ledger step consumes ONE of the 49 write slots of its handler call** (a posting handler can additionally `create/3` at most 48 bookkeeping records). A refusal step (`Multi.error`) is recorded the same way.

**At RUN time** (the step; every statement uses the tenant `prefix:` and bound parameters):

1. **Capability, origin, isolation (no lock).** `Ledger.post/1` accepts ONLY a `Capability` value (a hand-built context or map is refused). It takes no `changes` argument: the Multi step that runs it has an EMPTY accumulator (7.4), so the one-posting check is NOT here. The origin must be `{:task, _}`, else the typed refusal `:ledger_origin_not_supported` (D-L12). Assert `current_setting('transaction_isolation')` is `read committed`.
2. **Authority (no lock), FIRST.** 16.2: credential, roles from the DATABASE, scope. A denial returns the one `write_not_permitted` body. **Only after authority passes** does the step return the capability's `deferred_refusal` (if set, see the build phase above) as the typed refusal; a contract failure (`:too_many_postings`, `:ledger_not_registered`) returns the closed internal failure of 12.3, never a typed body.
3. **Idempotency pre-check (lock-free).** Lookup by `(subject_id, client_op_id)` and by `origin_key`: same `payload_hash` returns the duplicate result and stops; a different hash, or the two keys matching DIFFERENT entries, returns `idempotency_key_reuse`; a `(subject_id, device_id, client_seq)` held by a different `client_op_id` returns `client_seq_conflict`.
4. **Reversal derivation (no lock; immutable data).** For `cause = reversal`: read the target entry; absent, other ledger id or not visible -> `validation_failed` reason `movement_not_found`; target is itself a reversal -> `posting_is_reversal`; derive the negated legs.
5. **Ledger-id cap (per-instance ids only).** If the ledger id has no counter row yet, the count of distinct ledger ids of this registration must be below its cap (14.3), else `ledger_instances_exhausted`.
6. **Balance rows: insert, then lock, both ascending.** Compute the DISTINCT balance keys; sort ASCENDING by `(k1 .. k8)` byte-wise. (6a) Each key in that order: insert-if-absent with `ON CONFLICT DO NOTHING` (carrying the leg's `unit_ref` and the bound from `key_bounds`). (6b) Each key in that order: `SELECT ... FOR UPDATE` returning `on_hand`, `unit_ref`, `max_on_hand`. One key at a time.
7. **Idempotency re-check by BOTH keys, immediately after the key locks (B2).** Re-run the lookup of step 3. A duplicate whose first posting committed while this transaction waited at 6b returns the duplicate result HERE, before the reversal re-check and before the guard (otherwise the retry would see the post-first balance and wrongly return `insufficient_balance` or `posting_already_reversed` for a command that already posted).
8. **Reversal re-check and guard.** For a reversal, re-read whether a reversal of the target now exists: found -> `posting_already_reversed`. Per key: `unit_ref` equals the pinned unit, else `unit_mismatch`; `on_hand + sum(delta) >= 0`, else `insufficient_balance`; the new `on_hand <= max_on_hand` when pinned, else `balance_bound_exceeded` (12.2); nothing written, counter untouched.
9. **Counter lock, second idempotency re-check, time check, number.** Insert-if-absent of the counter row, then the locking read of 6.1 (the LAST ledger lock). Re-check both keys (this catches a same-key retry whose key set differs, row e of 6.2): found -> duplicate result or `idempotency_key_reuse`, no write, no UPDATE. Read `posting_time = clock_timestamp()` now and apply the lateness and skew check of 8.3 against it (`event_time_too_old` / `event_time_in_future` roll the step back; nothing was written). Compute `new_seq`, `entry_digest`, `new_chain_hash` from the locked values (6.1) and run the counter UPDATE.
10. **Writes.** Insert the header, the legs, then `UPDATE ledger_balance` per key (`on_hand + delta`, `last_posting_seq = posting_seq`).
11. **Return** `{:ok, %{entry_id, ledger_id, posting_seq, chain_hash, duplicate: false}}`. The audit entry and events are the engine tail's (7.7, 14.5).

### 7.2 Position in decision 0061's order, and why

Decision 0061 rule 1 (`0061...md:13-21`): (1) instance tasks/dispatch rows, (2) `P_x`, (3) ancestor group, (4) own tokens, (5) entity-type rows ascending, (6) the tenant audit chain row, (7) sequence rows, (8) projection UPDATEs; "Amended (GH #2707, PR-1)" item 1 places the instance's own `timers` rows after class 5 and before class 6, touched only while `P_x` is held.

The ledger is **class 5b: after 5, before 6** (internally: balance rows ascending, then the counter row of the ledger id). Its position is stated as **after class 5 and before class 6; relative to the projection-protected rows (tokens, timers, sequence rows, projection) it is unconstrained**: the HUMAN completion runs the handler FIRST and the tail takes those rows afterwards (S3), and they are touched only while this transaction holds `P_x`, so no order between them and the ledger rows can create a wait-for edge. It also comes after class 3: a sub-process child's PARENT GROUP is locked by `:lock_ancestors` before the entity-type rows (S3), so the ledger rows are taken after the parent group and before the audit chain row (the 0061 amendment names this dependency, EC F4). Why this cannot cross another class: on the HUMAN path the handler runs after the type locks (S3) and everything after it is the TAIL: `:cancel_escalation_timers` and `:cancel_reminder_timers` (`engine.ex:7350, 7365`), token reconcile, task activation, audit rows (class 6), events and sequence rows (7), projection UPDATEs (8) (S3b). Every row of the tail classes is either (a) instance-own and touched only while THIS transaction holds `P_x` (timers, tokens, sequence rows, projection), so no other transaction can hold one while waiting for a ledger row (it would have to hold `P_x` of this instance), or (b) newly inserted by this transaction, or (c) the tenant-wide audit chain row, which a ledger-posting transaction takes only AFTER its ledger rows and which a non-ledger transaction holds without ever waiting for a ledger row. The 0061 amendment text (section 15) uses the same wording and names the timers among the projection-protected rows.

### 7.3 Why it cannot deadlock

* Ledger vs ledger: every posting takes keys ascending then the counter; the counter holder takes no further LEDGER lock (it updates rows it already holds); a cycle would need a counter holder waiting for a ledger row it does not hold, impossible. Opposite key order `[(A,B)]`/`[(B,A)]` both sort to `A,B`.
* **The counter holder DOES wait for rows later in the transaction** (the tail: audit chain row, sequence rows, projection). Deadlock-freedom there rests on 7.2: nothing that holds a tail row ever waits for a ledger row.
* The insert-if-absent of a missing balance row waits on the inserting transaction in the same ascending order, before any lock of that pass.
* No FK from the ledger to engine tables (D-L11, S19).
* **One posting per transaction (7.4).**

### 7.4 One posting per transaction (BLOCKER F2/B1/R2-9, round 3 item 1, round 4)

A node may declare up to 20 `module_writes` lines, each a handler call. A second posting would take balance rows AFTER the first holds the counter: T1 holds the counter and wants key `y`, T2 holds `y` and wants the counter -> a cycle. Rule: **at most ONE ledger posting per transaction**, enforced twice, and NOT by the per-call process token (reset per `build_call`, exists only during the build, S1b) and NOT by a marker read inside the ledger Multi step: the steps of a merged Multi run with their own accumulator.

**Verified structure (re-read in the main checkout, `deps/ecto/lib/ecto/multi.ex`).** `apply_operation` for a `{:merge, fun}` operation calls `apply_merge_fun(merge, acc)`, i.e. the merge function RECEIVES the enclosing Multi's accumulated changes (`multi.ex:883-892`), and `merge_results` (~944-955) folds the sub-Multi's step names back into that accumulator. In this codebase ALL `module_writes` lines are reduced into ONE `Multi.merge` (`step_writes.ex:547-548`, the call to `append_handler_calls` at `:604`), and each handler call's own `Multi.merge(fn _changes -> invoke(...) end)` (`handler_writes.ex:476-477`) is a SIBLING operation inside that one sub-Multi. The inner merge function of handler call N therefore receives an accumulator that already holds the results of handler calls 1..N-1 (their merged step names, including any `{:line, _, :ledger_post}`). The `:ledger_post` STEP itself runs with the sub-Multi's own accumulator and must not be relied on.

1. **Statically, at activation.** `Definitions.ModuleWrites` (R3) refuses a node whose `module_writes` contain more than one line whose handler has `posts_ledger` (code `module_writes_multiple_ledger_postings`, 422).
2. **At run time, by the inner merge function.** Change `build_call/4` to `Multi.merge(fn changes -> invoke(attrs, line, variables, k0, changes) end)`; `invoke/5` puts a platform-set flag `ledger_posted?` (true iff `changes` already holds a key `{:line, _, :ledger_post}`) into the per-call token (a new field, not handler-visible); `post/3` at BUILD (step B5) records a `deferred_refusal` `{:contract, :too_many_postings}` in the capability when the flag is set. That refusal is a contract failure: after the authority check the step returns the internal failure `{:failed, index, :ledger_marker}` (12.3: closed 500 `entity_write_failed`, no details); for an unauthorised subject it is `write_not_permitted` like every other build-time refusal. No database round trip and no `set_config`. **DEPENDENCY, stated:** this relies on all handler calls sitting inside the one `Multi.merge` at `step_writes.ex:547-548`; **T-LK-5 is the guard against that structure changing** (the earlier `set_config` fallback is dead and removed).
3. The per-call `:too_many_postings` (a second `post/3` inside ONE handler call) stays: the token's `produced` list already holds a ledger step.

Tests: T-LK-5 (a node with two posting lines is refused at activation; a hand-edited snapshot with two posting lines fails at the second line's build through the inner merge function, nothing committed, and with an opposite-key poster in overlap there is no deadlock; line 1 posting plus line 2 a plain `create/3` call passes; the test also fails if the lines are no longer reduced into one merge), T-LK-6 (two sequential transactions in ONE process both post: the flag lives in the per-call token and the Multi changes, so it cannot leak between transactions, EC F4).

### 7.5 The SERVICE_TASK hazard (why L1-L4 refuse the service origin)

On the service apply the order is `:lock_ancestors`, `{:pre_type_lock,_}`, then tokens and task activation whose `task.create` audit takes the audit chain row **A**, then the handler calls (S4). A posting there takes balance rows and the counter AFTER **A**. Interleaving: a HUMAN posting `Th` holds `B(x)` and the counter and wants **A** for its tail audit; a service apply `Ts` holds **A** and wants `B(x)`: a real cycle (derived by reading, not run). `post/3` refuses `{:dispatch, _}` with the TYPED refusal `:ledger_origin_not_supported` (surfaced as `write_not_permitted`, and as ERROR + DLQ on the service path); activation also refuses a `posts_ledger` handler on a SERVICE_TASK node (14.3). Lifting it needs a later 0061 amendment (ledger lock-only pre-steps before the task-activation audit) and its own forced-overlap tests.

Consequence (F20): **automated and integration postings are excluded from L1-L4**. Conditions for lifting (SEC-12): (a) the ledger rows are taken as lock-only pre-steps BEFORE the task-activation audit, with balance keys resolvable at plan time (NOT VERIFIED that service-path arguments are); (b) the subject's roles are re-resolved from the database at run time, the platform sentinel never holds the post permission and the `credential` rule of 16.2 applies; (c) when script-produced variables feed legs, activation requires an explicit consent flag on the node recorded with `activated_by`; (d) the cycle test T-LK-4 inverted.

### 7.6 Deadlock and timeout behaviour

| Event | Result |
|---|---|
| `55P03` (the plan's `lock_timeout 2s`, S5), `40P01`, `57014` (`statement_timeout` 5 s) | rollback; nothing committed, no number consumed; mapped to 503 `entity_write_contention`, `line_index: null` (`engine.ex:2925`, `tasks.ex:456-463`). No new code. |
| a `23514` on `on_hand >= 0` or on `max_on_hand` after the guard passed | the race the guard should have closed: `insufficient_balance` / `balance_bound_exceeded` with the `details` of 12.2 (reversal: only `leg_nos` and count), logged as a defect-class counter with no values |

Hot key/counter: FIFO behind the holder for at most 2 s then 503; holder bounded by 5 s statement and 10 s wall guard (`gh2590...md:749-750`). Bounds: 200 legs per posting, 1 posting per transaction, 20 lines per node.

**Throughput.** The counter is held from step 9 to the END of the surrounding transaction, i.e. through the engine tail, and a ledger transaction also waits behind the tenant-wide audit-chain row (S8): the hold is the tail, not a short suffix. One authenticated actor can occupy the convoy with sequential completions; decision 0040 records NO per-actor rate limit (S25), so the only bounds are the lock timeout (2 s -> 503) and the posting caps. Pilot exit criterion for T-LD-1: with 4 concurrent workers on ONE tenant, at least **20 postings/s sustained for 60 s, p95 completion latency under 500 ms, contention 503 rate under 1%**; if the customer's NF-01 peak (lines/s) is declared higher, the criterion is 2x that figure. Accepted for release 1: postings of one ledger id serialise across the tenant. **Scale path: per-ledger-instance sequences** (a registration with per-warehouse ledger ids gets one counter, one gap-free sequence and one cut-off number per warehouse, no core change). **Its cost (EC F5): a transfer between two warehouses is no longer one atomic posting** (one posting per transaction, one ledger id per posting); the alternative that keeps atomicity is a transit location inside ONE ledger id. This is stated so the choice is made knowingly (OQ-2).

### 7.7 The audit entry per posting (`ledger.posted`)

One audit chain entry `ledger.posted` per NON-duplicate posting, with ids only: `entry_id`, `ledger_id`, `posting_seq`, `cause`, `leg_count`, the actor, **and the `chain_hash`** (the anchor of 5.1); no quantity, no slot value, no free text. It is appended by the ENGINE TAIL beside the per-line entity-write audits (`append_entity_write_audits`, `engine.ex:3330`, action `entity_write.process_step` at `:3334`), built from the `:ledger_post` step result in `changes`, not by the ledger step itself, so the audit chain row (class 6) is taken in the tail AFTER the counter (class 5b), exactly as 0061 requires. A refused or duplicate posting writes no `ledger.posted`; refusals keep the existing best-effort refusal audit (12.3). A tail step that fails after the counter was bumped rolls the WHOLE transaction back, counter and ledger rows included (test T-AU-2, EC F3).

## 8. Time basis, late movements (G7) and reports

### 8.1 Event time of a late-synchronised movement

* `client_event_time` is stored exactly as reported (null online); it is accepted only together with `device_id`. Online postings use `event_time = posting_time`; a `client_event_time` without `device_id` is `invalid_posting`.
* **`device_id` is client-supplied and is NOT an authorization control (R2-11):** any holder of the post permission can invent a `device_id` and thereby back-date up to the cap. A stricter regime (a separate backdating permission above a small threshold) is OQ-22, default no.
* `event_time = client_event_time` when present, else `posting_time`; NEVER overwritten by the posting time (0058 b).
* `posting_time = clock_timestamp()` read under the counter lock (single database clock); it is informational and can regress (clock step); `posting_seq` alone orders. The lateness and skew checks of 8.3 are made against THIS value (step 9), after the counter lock.
* Timestamps are parsed strictly: ISO-8601 with explicit offset or `Z`, microsecond precision, years 2000-2100; `infinity`, `-infinity`, out-of-range and offset-less values are `invalid_posting`.
* The guard is evaluated at POSTING time against current balances (a late issue negative as of its event time but positive now posts; negative now -> `insufficient_balance`, 0058 b).

### 8.2 Two bases, both reproducible

| Basis | Predicate | Property |
|---|---|---|
| as-posted (default) | `posting_seq <= N` | immutable and reproducible (G2); a late movement has `posting_seq > N` |
| as-of event time | `event_time <= T AND posting_seq <= N` | the pair `(T, N)` reproduces a published report; with a larger `N` it includes late arrivals ("appears in the appropriate period", MD-09) |

Event time WITHOUT `N` is not offered (it would rewrite a published balance).

### 8.3 DECISION D-T: the lateness cap (OQ-15 decided)

Rule: `event_time` may be earlier than `posting_time` by at most `max_event_lateness_hours`, default **96 hours (4 days)**, and later than `posting_time` by at most 5 minutes (skew). Beyond either, the posting is refused `event_time_too_old` or `event_time_in_future` (422), nothing written. **One source (N5):** the value is the registration's `max_event_lateness_hours` (manifest data, hashed by `ManifestHash`), and rule 12 caps it at **720 hours**; there is no tenant or operator override and no runtime setting. Raising the window means a module version change.

Reasoning: (a) the offline lease is the maximum outage, default 3 days (0058 (a), 0057 D13); a fact captured at the start of the longest permitted outage must still be postable on reconnection; (b) one day of margin covers synchronisation delay and a device clock set to local time; (c) international practice in ERP inventory ledgers bounds backdating by an OPEN POSTING PERIOD, a configured window (SAP MM posting-period control opens the current and previous period; Dynamics 365 inventory closing prevents posting before the last closing date): the cap is the minimal stand-in for a period window, since period close is out of scope; (d) a cap with no value would let any holder of the post permission backdate unboundedly, defeating "published balances are not silently rewritten"; (e) it cannot rewrite a published as-posted report anyway (G2), it only bounds how far an event-time report can move. Period close is a later requirement. Recorded for 0062.

### 8.4 What every report states (CS-01 :117)

`basis`, `cutoff_seq` (`N`), `as_of` (`T` or null), `timezone` (tenant timezone used for period boundaries; storage UTC), `filters`, `ledger_seq` (counter value in the snapshot). Opening + period receipts - issues and adjustments = closing, by construction (T-RP-3).

## 9. Commands, idempotency, offline fields, versions, tombstones

### 9.1 The posting command (closed map)

`cause`, `legs` (list of `%{k: [slot texts], quantity (decimal string or integer, never a float), unit_ref, attrs, document_line_id}`), `reason_code`, `document_type`, `document_id`, `related_document_id`, `correlation_id`, and the offline fields **`client_op_id` (required)**, `device_id`, `client_seq`, `client_event_time` (0058 c.1). For `reversal`: `reverses_entry_id` and `reason_code`, no legs. Unknown keys, floats, non-canonical decimals or more than 9 fractional digits (never rounded) are `invalid_posting`. The encoded command is capped at 256 KiB.

How the offline fields reach the handler (F17): they are fields of the TASK COMPLETION request's variables, mapped to the handler's declared `var` arguments (`gh2590...md` D-R.4: args are resolved values only); never taken from headers. `client_op_id` is a required handler argument generated by the client UI for an online posting too; `device_id`, `client_seq`, `client_event_time` are omitted online and left null.

### 9.2 Idempotency and the payload hash

`payload_hash` = SHA-256 over the canonical, key-sorted JSON of the VALIDATED RAW command (the client-supplied fields after closed-shape check and decimal canonicalisation, i.e. the input of `declare/2`, so it does not depend on anything the module derives) PLUS `subject_id`. Keys are scoped per actor: `UNIQUE (subject_id, client_op_id)`: another actor's identical `client_op_id` is a different key and posts independently, so there is no existence oracle across actors; the same actor with the same key and a different hash gets `idempotency_key_reuse`.

| Situation | Result |
|---|---|
| neither key seen | post |
| `(subject, client_op_id)` seen, same hash | `{:ok, %{entry_id: existing, posting_seq: existing, duplicate: true}}`, nothing written |
| seen, different hash | `idempotency_key_reuse` (409) |
| `client_op_id` and `origin_key` match DIFFERENT entries | `idempotency_key_reuse` (409) |
| `client_op_id` starting `sys:` | refused (S13) |

The decision is made in three places (7.1 step 3 lock-free; step 7 right after the key locks; step 9 under the counter lock); the unique indexes are the backstop (a `23505` maps to `idempotency_key_reuse` without revealing the other row).

### 9.3 Offline `client_seq` (F8)

`UNIQUE (subject_id, device_id, client_seq)`. A `(device_id, client_seq)` already held by a DIFFERENT `client_op_id` is `client_seq_conflict` (409), found by the pre-check and backed by a `23505` mapping. **Out-of-order acceptance is intended**: the ledger does not reject a lower `client_seq` than a previous one; "per-device monotonic" (0058 c.1) is a property the DEVICE guarantees and the replayer (REQ-480) uses to order commands. `device_id`, `client_seq` and `client_event_time` are untrusted metadata, never used for ordering, cut-off or authorisation.

### 9.4 `expected_version` (0058 c.2)

The ledger has no client-mutable resource (legs/entries immutable, balance/counter platform-written). The criterion is met by: (a) a reversal's precondition "not yet reversed" -> `posting_already_reversed`; (b) entity masters keep `expected_last_event_global_seq` (S12). **A precondition on a mutable ENTITY record (`expected_document_version`, comparing its `last_event_global_seq`, mismatch -> `record_version_conflict`) is NOT in L1-L4: it needs a read of the record and is DEPENDENT on the OQ-R4 read facade (14.6).** When it exists the version must be re-checked under the lock (TOCTOU).

### 9.5 Retire/cancel is a tombstone (0058 c.7)

No ledger row is ever deleted (5.2); a zero balance row stays; cancelling a posting is a reversal. A retired master (`active=false`) blocking only stock-adding legs (`master_inactive`) while stock-removing legs and reversals stay allowed is a master CHECK and is **DEPENDENT on the OQ-R4 read facade (14.6), not in L1-L4**: in L1-L4 the ledger neither knows nor checks masters. Facts already true (0058 b) are REQ-480.

## 10. Reversal

* A reversal is a NEW posting, `cause = reversal`, `reverses_entry_id = target`, legs = the exact negation of the target's (same keys, unit, original quantity negated), `reason_code` required, its own `event_time`, own `posting_seq`; `document_id` and `correlation_id` default to the target's. Its `ledger_id` equals the target's.
* Refused: unknown/malformed/not-visible target -> `validation_failed` reason `movement_not_found` (one body); target already reversed -> `posting_already_reversed` (409); target is itself a reversal -> `posting_is_reversal` (409).
* Where the checks sit: 7.1 step 4 (target exists, same ledger, not a reversal, derive negated legs), step 6 (key locks), step 7 (idempotency re-check), step 8 (re-read "already reversed" AFTER the key locks, BEFORE the counter lock); two concurrent reversals of one header share every key, so the second re-reads after the first commits; a RETRY of the same reversal command returns the duplicate result at step 7, not `posting_already_reversed`. The partial unique index is the backstop.
* The guard applies. Reversing a receipt whose stock was partly issued is `insufficient_balance`; for a reversal the `details` carry ONLY `leg_nos` and the count, never the target's contents. Residual (documented): a caller allowed to post can learn "enough/not enough" for a key by probing; the guard is an oracle by nature; the exact `available` is permission-gated (12.2).
* No partial reversal; permission is the registration's `reverse` atom.

## 11. `ledger_balance` and reconciliation

### 11.1 Maintenance

Updated only by `Letflow.Ledger.post` in step 10, after the guard, under the held row lock, in the same transaction. Invariant I-BAL: `on_hand` after posting `n` equals the sum of the key's legs with `posting_seq <= n`. Read only inside the guard.

### 11.2 `reconcile/3`

Under a `statement_timeout` and an upper time bound of 60 s per run, **mandatorily chunked by key cursor** (a page cap). Concurrency cap (R2-10): each chunk first takes `pg_try_advisory_xact_lock` keyed by a hash of the schema and the ledger id (bound parameters); a failure returns `reconcile_busy`. **The lock is transaction-scoped, so it limits CONCURRENT CHUNKS, not concurrent runs**: two runs may interleave between chunks; the design accepts that (each chunk is internally consistent, 11.2 fixed-`N` rule) and does not claim whole-run exclusivity (a session-level lock was rejected: it would pin a connection for the whole run). Consistency across chunks: the first chunk fixes `N` (the counter value in its snapshot); every chunk runs in its own `REPEATABLE READ READ ONLY` transaction and compares, per key, the sum of legs with `posting_seq <= N` to the balance row ONLY when that row's `last_posting_seq <= N`; keys whose balance moved past `N` are re-checked in a final pass at a new `N`, so a posting between chunks is never reported as a mismatch. It reports every differing or missing key; the sequence check `count = max(posting_seq) = counter.last_seq`; and the chain check (recomputing `entry_digest` and `chain_hash` for the range and comparing to the stored values and to the `ledger.posted` audit entries). Result: `%{ledger_id, checked_through_seq, mismatches, gap_check, chain_check, next_cursor}`. It repairs nothing (OQ-9). Cut-off reports have the same statement timeout and page cap.

## 12. Errors (typed, closed, machine-readable)

### 12.1 Envelope

The refusal body `{"error": code, "line_index": n}` (S6) gains an optional `"details"` ONLY for the codes of 12.2; every other code keeps its exact bytes (golden test). `details` holds ids and closed enums, never free text or exception text. The `available` figure is computed and gated INSIDE the step (R2-12): the 5-tuple of 12.3 already carries the gated map, so no consumer can add it back. The HTTP status table lives in `lib/letflow/ledger/codes.ex` (scanned by Rule 7) and `Response.entity_write_status/1` (`api/response.ex:311-314`) delegates to it.

### 12.2 Codes (D-E: core codes are neutral; the module maps them to wire codes)

| Core code (and the wire code under the stock module's `error_aliases`) | HTTP | When | `details` |
|---|---|---|---|
| `insufficient_balance` (stock module wire code `insufficient_stock`) | 409 | step 8 or the CHECK backstop | `{"legs": [{"leg_no", "k": [...slots], "requested", "available"?}]}`; `available` only when the subject holds the registration's `read` permission; for a REVERSAL `{"leg_nos": [...], "count": n}` only |
| `balance_bound_exceeded` (stock: `serial_already_active` if the module aliases it) | 409 | a registered `key_bounds` limit | `{"legs": [{"leg_no"}]}` |
| `unit_mismatch` | 409 | a leg's `unit_ref` differs from the key's pinned unit | `{"leg_no"}` |
| `posting_not_balanced` | 409 | sign rule `zero_sum_by_slot_1` violated (before any lock) | `{"k1": [...]}` |
| `posting_already_reversed` | 409 | 10 | `{"entry_id"}` (the caller named it) |
| `posting_is_reversal` | 409 | 10 | `{"entry_id"}` |
| `idempotency_key_reuse` | 409 | 9.2 | `{}` |
| `client_seq_conflict` | 409 | 9.3 | `{}` |
| `event_time_in_future`, `event_time_too_old` | 422 | 8.3 | `{}` |
| `invalid_posting` | 422 | shape, float, scale, sign, caps, strict timestamp | `{"leg_no": n|null, "reason": <closed enum>}` |
| `ledger_instances_exhausted` | 422 | the per-instance ledger-id cap | `{}` |
| `validation_failed` reason `movement_not_found` | 422 | reversal target | `{"reason": "movement_not_found"}` |
| `write_not_permitted` | 403 | no permission, scoped principal, a credential other than `:oidc`, wrong origin, stamp failure, **and ANY build-time refusal of an UNAUTHORISED subject (the authority check runs before the deferred refusal is released, 7.1)**; ONE body (INV-5) | none |
| `entity_write_failed` | 500 | a contract failure (`:too_many_postings`, `:ledger_not_registered`, a forged context) mapped by `ledger/failure.ex` to `{:failed, index, :ledger_marker}` (12.3): a closed internal failure, NOT the 5-tuple, no `details`, no wire code of its own | none |
| `entity_write_contention` | 503 | 7.6 | none |
| duplicate | success | 9.2 | result `duplicate: true` |

**Who sees the typed codes.** Every typed 409/422 above that originates at BUILD time (`invalid_posting`, `posting_not_balanced`, `event_time_*`, `unit_mismatch` shape parts) is released only to an AUTHORISED subject (7.1); an unauthorised subject gets `write_not_permitted`. Run-time refusals (`insufficient_balance`, `balance_bound_exceeded`, `posting_already_reversed`, ...) occur after the authority check by construction.

**Alias rules (CDV 8, SEC r3 3; rule 12 enforces them).** The aliasable core codes are a CLOSED subset: `insufficient_balance`, `balance_bound_exceeded`, `unit_mismatch`, `posting_not_balanced`, `posting_already_reversed`, `posting_is_reversal`. An alias VALUE (`[a-z_]{1,48}`) must be disjoint from every core, engine, entity and ledger wire code (`write_not_permitted`, `entity_write_contention`, `idempotency_key_reuse`, `validation_failed`, `record_version_conflict`, `entity_append_only`, ...; the full list is a reviewed constant in `ledger/codes.ex`), from the other aliases of the same registration (the mapping is injective) and from the aliases of every other installed module. The HTTP status always follows the CORE code. A golden test asserts the complete core code list and the alias constraints are unchanged (T-ERR-4).

Decision **D-E** (needs supervisor confirmation, OQ-19): the issue's AC names `insufficient_stock`; core must not (Rule 7). The stock module's registration carries `error_aliases: %{"insufficient_balance" => "insufficient_stock"}`; the alias is applied when the refusal is built (the 5-tuple carries both), the HTTP status follows the core code, and the module's clients see only `insufficient_stock`. Tests assert the wire code `insufficient_stock` through the stock registration and `insufficient_balance` through the neutral test registration. **Audit, logs and metrics record the NEUTRAL core code** (`insufficient_balance`), never the alias; and the keys of `details` come from the registration's slot names (for example the slot name in `master_inactive` or the `k` list order), never from names hard-coded in core. Both are covered by the per-slice SECURITY checklist (16.5) and a test (T-ERR-5: the audit entry, the log line and the metric label of an aliased refusal carry the neutral code; the `details` keys equal the registered slot names).

### 12.3 The failure channel for `details`

Today `EntityPort.failure` is `{:refused, index, code, detail_atom}` and the engine returns the 3-tuple `{:entity_write_refused, index, code}` (S6b). New, additive:

```
# engine/entity_port.ex failure union gains:
{:refused_detailed, index :: non_neg_integer(), code :: atom(), wire_code :: String.t(), detail :: atom(), details :: map()}
# the engine result gains a DISTINCT 5-tuple (the 3-tuple is untouched):
{:error, {:entity_write_refused_detailed, index :: non_neg_integer(), code :: atom(), wire_code :: String.t(), details :: map()}}
```

Producer: `StepWrites.interpret_failure/2` (`step_writes.ex:944`) delegates a failed `{:line, key, :ledger_post}` whose reason is `{:ledger_refused, code, wire_code, details}` to `lib/letflow/ledger/failure.ex`. There is ONE ledger step name, `{:line, key, :ledger_post}`, which is not the `:build` name that collapses to the closed handler set. Typed build-time refusals (`invalid_posting`, `posting_not_balanced`, `event_time_*`) are the capability's `deferred_refusal`, released by that step only after the authority check (7.1), so they travel this same channel and only for authorised subjects. **Contract failures** (`:too_many_postings`, `:ledger_not_registered`, a forged context, a `declare/2` raise) are a SEPARATE explicit clause in `ledger/failure.ex`: a failed `:ledger_post` step whose reason is `{:ledger_contract, atom}` is mapped to `{:failed, index, :ledger_marker}` (the existing internal-failure shape, closed 500 `entity_write_failed`, NO `details`), NOT to the 5-tuple. T-ERR-1 asserts that body. Engine: one new clause in `interpret_complete_result/3` (`engine.ex:8440-8462`) beside `{:refused, ...}` that writes the best-effort refusal audit (same function and shape: ids + the closed `detail` atom ONLY, never the `details` map, so no quantity and no slot value reaches the audit chain) and returns the 5-tuple. Pattern sites to touch: `engine.ex:2549` (type), `engine.ex:8461-8462` (producer), `routers/tasks.ex:456-463` (new clause BEFORE the generic one, rendering with the wire code), `engine/service_task_dispatcher.ex:667` and `engine/script_task_dispatcher.ex:107` (classify the 5-tuple as `:entity_write_refused`; unreachable in L1-L4, exhaustive). Sites matching only `{:entity_write_refused, :contention, _}` (`engine.ex:5695, 5737, 6008, 6045`) and the Records-level tuples (`records.ex:828-876`) are unchanged. **No consumer of the 5-tuple may log or `inspect` `details`** (R2-12): test T-ERR-3 captures the Logger output and the audit entries of every consumer path and asserts no slot value or quantity appears. Golden tests T-ERR-2: every existing 3-tuple consumer yields byte-identical results for every existing code; the 5-tuple yields the exact envelope.

## 13. Test plan

New files, `async: false`; concurrency ones in Sandbox `:auto` with real commits in the style of `Letflow.LockOrderHelpers` (S16). The posting assertions run through a TEST registration (a neutral fixture module) plus, for the wire code and slot names, the stock registration once it exists.

| Id | File | Case |
|---|---|---|
| T-AC1 | `ledger/post_balance_test.exs` | (typed refusals below are for AUTHORISED subjects) | a `zero_sum_by_slot_1` posting whose legs do not sum to zero per slot 1 is refused `posting_not_balanced` before any lock, counter unchanged; a balanced one posts; a `positive` cause with a negative leg and a `negative` cause with a positive leg are `invalid_posting`; **each of these build-time refusals reaches an AUTHORISED client as the typed envelope with its `details` (through the deferred refusal of 7.1), not as a collapsed handler error** |
| T-AC2 | `ledger/concurrent_no_negative_test.exs` | on hand 10; two concurrent `negative` postings of 6 in forced overlap (barrier row on the balance key): EXACTLY ONE posts, the other `insufficient_balance` with `details.legs[0]`; balance 4; counter advanced by exactly 1 |
| T-AC3 | `ledger/reversal_test.exs` | reversal of a reversed posting -> `posting_already_reversed`; reversal of a reversal -> `posting_is_reversal`; reversal of a partly-consumed receipt -> `insufficient_balance` with only `leg_nos`/count; two concurrent reversals of one posting: one wins; **a concurrent identical RETRY of the same reversal command returns the duplicate result, not `posting_already_reversed` (B2)**; unknown/malformed id -> the one `movement_not_found` body; a caller WITHOUT the read permission gets no `available` and no target content |
| T-AC4 | `ledger/cutoff_test.exs` | after N=3 record the as-posted report; post more incl. a late one with an earlier `event_time`: the as-posted report at N=3 is byte-identical, the event-time report `(T, N=3)` identical, `(T, N=7)` includes the late one; the report carries basis, cutoff, tz, ledger_seq |
| T-AC5 | `ledger/balance_reconcile_test.exs` | property (StreamData): after every posting/reversal `ledger_balance == SUM(legs)` per key; then a deliberately corrupted balance, made by a plain `UPDATE ledger_balance SET on_hand = ..., last_posting_seq = <counter>` (allowed by the trigger; **no superuser and no `session_replication_role` needed**), is reported by `reconcile/3` with key, balance and ledger sum; a tampered `entry_digest`/`chain_hash` (set through a throwaway tenant where the test disables the trigger as owner) is reported by the chain check |
| T-AC6 | `ledger/idempotency_test.exs` | same `(subject, client_op_id)` and payload twice: one header, same `entry_id`, `duplicate: true`, counter advanced once; same key different payload -> `idempotency_key_reuse`; `sys:` key refused; two concurrent same-key posts: one header, both return the same id; **TIGHT STOCK + concurrent identical retry: on hand exactly equals the posting, both callers run in forced overlap, the loser returns the duplicate result and never `insufficient_balance` (B2, row d)**; a concurrent same-key retry with a different key set returns the duplicate at the counter lock (row e); ANOTHER actor with the same `client_op_id` posts independently and cannot observe the first; `client_op_id`/`origin_key` matching different entries -> `idempotency_key_reuse`; payload hash independent of anything `declare/2` derives |
| T-GF-1..3 | `ledger/gap_free_test.exs` | forced overlap at the counter (consecutive, commit order = seq order); T1 rolls back after the UPDATE while T2 waits (T2 reuses the number; `max = count`); **the Repo default is READ COMMITTED and a role set to `REPEATABLE READ` makes the step refuse (N3)**; bounded 100-posting soak (4 workers) `1..100` |
| T-LK-1 | `ledger/lock_order_test.exs` | opposite key order `[(A,B)]`/`[(B,A)]` in forced overlap: no `40P01` (telemetry handler), both commit; step-name probe: missing rows inserted ascending, then locks ascending, then the counter |
| T-LK-2 | same | a posting HUMAN completion and a non-posting completion overlapping on the audit chain row: no deadlock; probe: class 5, then the ledger rows (balance rows, counter), then the audit chain row after the counter; the order among the projection-protected tail rows (tokens, timers, sequence rows, projection) is NOT asserted (unconstrained, 7.2) |
| T-LK-3 | same | counter held beyond the lock timeout (`engine_test_seams` override): 503, nothing committed, counter unchanged |
| T-LK-4 | same | SERVICE origin refused (`write_not_permitted`, ERROR + DLQ), nothing written; activation refuses a `posts_ledger` handler on a SERVICE_TASK node |
| T-LK-5 | same | activation refuses a node with two posting lines (`module_writes_multiple_ledger_postings`); a hand-edited snapshot with two posting lines fails at the SECOND line's build through the merge-function check (7.4 item 2), nothing committed, no deadlock with an opposite-key poster; line 1 posting plus line 2 a plain `create/3` call passes; the test proves the parent changes reach `invoke/5` (otherwise the fallback marker is used) |
| T-LK-6 | same | two sequential transactions in one process both post (the flag lives in the per-call token and the Multi changes: no leak) |
| T-AO-1 | `migrations/ledger_migration_test.exs` | tenant replay creates the four tables and **leaves `ledger_counter` EMPTY** (no seed row; idempotent on a second replay); the counter row is created lazily on the first post; **a concurrent first-post race on a fresh ledger id yields one counter row and consecutive numbers 1, 2; a first-poster that rolls back leaves no row and the second poster still gets 1**; UPDATE/DELETE/TRUNCATE on entry/leg refused with the fixed text; a made-up `posting_seq`, a counter bump by 2, a counter UPDATE without an entry at commit, a counter `last_chain_hash` that differs from the entry's `chain_hash`, a leg whose copied seq differs, a reversal of a reversal, a second reversal, an unbalanced `zero_sum` entry (raw SQL), a balance beyond `max_on_hand`, a control character in a text column, a malformed hash are each refused. The deferred cases need **real commits (Sandbox `:auto`) or `SET CONSTRAINTS ALL IMMEDIATE`**. `down` refused unless `:allow_ledger_migration_down` is set |
| T-TT-1..4 | `support/tenant_template_ledger_test.exs` | 5.4 |
| T-OFF-1 | `ledger/offline_fields_test.exs` | offline fields stored and returned; `(subject, device_id, client_seq)` unique -> `client_seq_conflict`; out-of-order `client_seq` accepted; `client_event_time` kept as `event_time` with server `posting_time`/`posting_seq`; future beyond tolerance -> `event_time_in_future`; older than the registered cap -> `event_time_too_old` (a fast build-time refusal with the typed envelope, and the authoritative check against the `posting_time` read under the counter lock); `client_event_time` without `device_id` and `infinity`/offset-less/out-of-range timestamps -> `invalid_posting`; over-long or control-character text -> refused by the code and by the DB CHECK |
| T-KB-1 | `ledger/key_bound_test.exs` | `key_bounds` (slot non-empty, max 1): a second receipt of the same item+location+serial key -> `balance_bound_exceeded`, **while the same serial at a DIFFERENT location posts (the bound is per balance key, OQ-23)**; overlapping bounds: the minimum wins; a registration change does not alter an existing key's pinned bound; a first receipt with a unit outside the registration `units` allowlist is refused; two concurrent receipts of one value: exactly one posts; `unit_mismatch` for a different unit on an existing key |
| T-ERR-1..5 | `engine/ledger_failure_mapping_test.exs` | each code of 12.2 once for an authorised subject (status, `line_index`, `details` shape), **and a contract failure (`:too_many_postings`, `:ledger_not_registered`, a raising `declare/2`) asserts the closed 500 `entity_write_failed` body with NO `details` and NOT the 5-tuple; `invalid_posting` details contain only `leg_no` and a closed reason, never module-supplied text**, **including every BUILD-time refusal (`invalid_posting` with `{leg_no, reason}`, `posting_not_balanced`, `event_time_in_future`/`event_time_too_old`)**; T-ERR-4: alias constraints and the complete core code list are unchanged; `available` omitted without the read permission; the alias maps `insufficient_balance` to `insufficient_stock` in the stock registration and not in the neutral one; golden: every pre-existing refusal body and 3-tuple consumer unchanged; no consumer logs or audits `details` (T-ERR-3) |
| T-SEC-1 | `ledger/security_test.exs` | **an UNAUTHORISED subject (no post permission; `:api_token`; a scoped principal) sending an INVALID command gets the byte-identical `write_not_permitted` body for EACH build-time refusal kind (invalid shape, float quantity, bad slot format, unbalanced transfer, lateness, second posting), identical to the body for a valid command; the same commands from an AUTHORISED subject get the typed envelope**; two-tenant: tenant B's prefix never reads A; subject without the post permission -> `write_not_permitted` byte-identical to every other cause; **roles resolved from the DATABASE: a role revoked between task claim and completion is refused**; `PLATFORM_ADMIN` in a non-platform tenant is stripped (`effective_roles/2`); an `:api_token` credential is refused for post/reverse; **a call to the step function with a hand-built context or map is refused (capability)**; rule 12 rejects `TENANT_AUDITOR`/`CANDIDATE` holding post/reverse; **a missing, `nil` or defaulted `credential` is refused (allowlist `:oidc` only) and never reaches Principal construction**; `authorize/3` rejects `kind: :token`; SQL text carries no value (telemetry capture) |
| T-SEC-2 | `ledger/scope_refusal_test.exs` | a subject for whom `Scope.allowed_set(principal, post_atom)` is not `{:ok, :all}` (a scoped grant on the user or on one of its groups) is refused with the one `write_not_permitted` body and audit detail `scoped_principal_unsupported`; an unloadable grant set (`:not_loaded`) is refused; a tenant-wide subject posts |
| T-AU-1/2 | `engine/ledger_audit_test.exs` | a posting writes exactly one `ledger.posted` audit entry with ids and `chain_hash`, appended in the tail AFTER the counter (step-name probe), none for a duplicate or a refusal; **T-AU-2: a tail step that fails after the counter bump rolls back counter, entry, legs and balances (EC F3)** |
| T-PL-1 | `ledger/policy_pure_test.exs` | `declare/2` runs at build with ZERO queries (telemetry) and no process dictionary use; **T-PL-2: timing budget with a maximum-size command (256 KiB, 200 legs): `declare/2` plus B4 complete within 200 ms**; the allowlist scan (14.4) flags `:ets`, `:persistent_term`, `Agent`, `GenServer`, `send`/`receive`/`spawn`, `Application`, `System`, `File`, `:rand`, `DateTime`/`NaiveDateTime`/`Date`/`:os`/`:erlang` clock calls in a policy file and in a helper in its directory; a raise/exit/throw in `declare/2` becomes the closed build failure with no text; core re-validates `declare`'s output (an out-of-registration cause, a wrong slot format, an over-cap `event_time`, a bad `scope_ref`, an over-long `document_id`, a foreign `reverses_entry_id`) |
| T-SC-1 | `entities/ledger_boundaries_test.exs` | Rule 7 on the real tree and on synthetic sources: `stock_movement`, `insufficient_stock`, `:StockPost` flagged; `insufficient_balance` passes; comments and docs excluded; scope includes `handler_post.ex`, `failure.ex`, `codes.ex`, `ledger_registration.ex`, the migration; Rule 7b: a `Letflow.Modules.*` reference other than `LedgerRegistration` flagged |
| T-SC-4 | same | Rule 8 through the pure `violations/1` seam on synthetic sources: a second caller of `Ledger.post` or `Capability.mint`, an `apply/3` building a `Letflow.Ledger` name in a module subdirectory, a Lua host function naming the ledger, **a struct literal or pattern of `Capability`, `Authorized` or `Scope.Principal` (including through an alias)**, a policy file referencing a `Letflow.*` name other than `Letflow.Ledger.Policy` are each flagged; a module calling an authorised READ function is NOT flagged; `ledger_registration.ex` is exempt |
| T-RP-1 | `ledger/report_test.exs` | `balances/5` as-posted and event-time with filters; the result states basis, cutoff, tz, ledger_seq, filters; output maps are the allowlisted ones (no `actor_id`/`subject_id`/`bpm_*` unless the read atom grants it) |
| T-RP-2 | same | a cut-off or reconcile read is chunked, honours the page cap and `statement_timeout`; a concurrent second reconcile -> `reconcile_busy`; a posting between chunks is not reported as a mismatch |
| T-RP-3 | same | **CS-01 identity**: opening balance at `N0` + period receipts - period issues and adjustments (legs with `N0 < posting_seq <= N1`) = closing balance at `N1` for the same key and basis, for both bases |
| T-MIG-1 | with #2658 | registering an additional slot name on a populated ledger leaves posted rows byte-identical and sums unchanged |
| T-LD-1 | `ledger/counter_throughput_test.exs` (tagged) | the exit criterion of 7.6 |
| DEFERRED | | T-VER-1 (`expected_document_version` conflict), T-RT-1 (retired master blocks only stock-adding legs) and every master/unit validation test are DEFERRED to the slice that has the OQ-R4 read facade (14.6, 17) |

NOT VERIFIED for the test DB: whether the test role owns the tables (T-AC5's chain-tamper case needs the owner to disable a trigger in a throwaway tenant).

## 14. Interfaces

### 14.1 `Letflow.Ledger` (core, `lib/letflow/ledger/`)

```
@type ledger_id :: String.t()
@type cause :: String.t()                      # a module-registered name; core does not enumerate causes
@type basis :: {:posting_seq, non_neg_integer() | :latest}
             | {:event_time, DateTime.t(), known_through :: non_neg_integer() | :latest}
@type posting_command :: %{required(:client_op_id) => String.t(), optional(atom()) => term()}      # MODULE-level command (client fields + business fields)
@type declarative_posting :: %{ledger_id: ledger_id(), cause: cause(), legs: [declared_leg()],
                               reason_code: String.t() | nil, document_type: String.t() | nil, document_id: String.t() | nil,
                               related_document_id: String.t() | nil, correlation_id: String.t() | nil,
                               event_time: DateTime.t() | nil, reverses_entry_id: Ecto.UUID.t() | nil, scope_ref: String.t() | nil}
@type declared_leg :: %{k: [String.t()], quantity: Decimal.t(), unit_ref: String.t(), attrs: map() | nil,
                        document_line_id: String.t() | nil, optional(atom()) => term()}      # REQ-504 columns ride in the optional keys
@opaque capability :: %Letflow.Ledger.Capability{}      # server-minted at BUILD time, only by handler_post.ex (Rule 8)
@opaque authorized :: %Letflow.Ledger.Authorized{}      # minted by authorize/3, consumed by the read functions
@type posted :: %{entry_id: Ecto.UUID.t(), ledger_id: ledger_id(), posting_seq: pos_integer(), chain_hash: String.t(), duplicate: boolean()}
@type refusal :: {:ledger_refused, code :: atom(), wire_code :: String.t(), details :: map()}
@type report :: %{basis: basis(), ledger_id: ledger_id(), cutoff_seq: non_neg_integer(), as_of: DateTime.t() | nil, timezone: String.t(),
                  filters: map(), ledger_seq: non_neg_integer(), rows: [map()], next_cursor: term() | nil}
@type page_result :: %{rows: [map()], next_cursor: term() | nil}
@type reconciliation :: %{ledger_id: ledger_id(), checked_through_seq: non_neg_integer(),
                          mismatches: [%{key: [String.t()], balance: String.t(), ledger_sum: String.t()}],
                          gap_check: :ok | {:gap, [pos_integer()]}, chain_check: :ok | {:broken_at, pos_integer()}, next_cursor: term() | nil}

# WRITE path (internal; reached only through HandlerWrites.post/3)
@spec mint(HandlerContext.t(), registration_name :: String.t(), declarative_posting(), origin_key :: String.t()) :: {:ok, capability()} | {:error, :invalid_context}
@spec post(capability()) :: {:ok, posted()} | {:error, refusal()}          # @doc false; inside the Multi step (empty accumulator, 7.4); asserts a transaction
# READ path (called by modules' authorised routes)
@spec authorize(Plug.Conn.t(), ledger_id(), :read | :reconcile) :: {:ok, authorized()} | :error      # builds the principal itself with Scope.principal_from_conn/1 (api/scope.ex:378); REJECTS kind: :token and any credential other than :oidc; permission atom from the registration; Scope.allowed_set == {:ok, :all}
@spec balances(authorized(), basis(), filters :: map(), page :: map()) :: {:ok, report()} | {:error, :cutoff_in_future | :invalid_filter}
@spec entries(authorized(), filters :: map(), page :: map()) :: {:ok, page_result()}
@spec fetch_by_client_op_id(authorized(), String.t()) :: {:ok, posted()} | {:error, :not_found}   # subject derived from the authorized value, never a parameter
@spec reconcile(authorized(), opts :: map()) :: {:ok, reconciliation()} | {:error, :reconcile_busy}
```

The write path takes an OPAQUE server-minted capability, not a bare context (R2-1, B1): the context type is `@doc false`, `Capability` has `@enforce_keys`, is built only in `lib/letflow/ledger/capability.ex` and `mint` is callable only from `handler_post.ex` (Rule 8). The READ functions (R2-5) take an `authorized` value that `authorize/3` mints from the CONNECTION (it calls `Scope.principal_from_conn/1`, so module code never supplies a `Principal`, and a `kind: :token` principal, which `Scope.allowed_set/2` would answer `{:ok, :all}`, is refused explicitly) after checking the registration's `read`/`reconcile` atom and `Scope.allowed_set(principal, atom) == {:ok, :all}`; their results are explicit ALLOWLIST maps (INV-2: no struct pass-through; `actor_id`, `subject_id` and `bpm_*` columns are included only when the read atom is held and a reason is documented per field); "not found" and "not authorised" are one answer (INV-5). Modules may call these read functions (Rule 8 does not flag them).

### 14.2 `HandlerWrites.post/3` (the one new handler-facing function)

```
@spec post(Ecto.Multi.t(), HandlerContext.t(), posting_command()) ::
        {:ok, Ecto.Multi.t()} | {:error, :invalid_context}
```

A one-line delegate to `lib/letflow/ledger/handler_post.ex`. It performs the BUILD-time work B1-B7 of 7.1: it verifies the per-call process token and context at BUILD time exactly as `create/3` does (S1b), runs `declare/2`, validates, mints the capability and appends the single step `{:line, key, :ledger_post}` recorded in the token's `produced` list (consuming one of the 49 write slots, so `check_built` accepts it). It never emits a client-visible refusal itself: every B3/B4/B5 problem (including `:too_many_postings` from the flag of 7.4 and a missing registration) is stored as the capability's `deferred_refusal` and released by the run step only after the authority check (7.1); `{:error, :invalid_context}` is returned only for a forged or absent token/context. The cross-call and cross-line guarantee is the static activation check plus the merge-function check (7.4). Scan H4 changes from "any `HandlerWrites` call but `create/3`" to "`create/3` and `post/3`".

### 14.3 Catalog / manifest changes, each specified (F5, M3)

* **Rule 12 (new; rule 11 is REQ-518 `scope_declarations`, S21b)** runs AFTER rule 11 and validates the optional top-level `ledger` key, a map `registration name -> registration`:
  ```
  %{ledger_ids: {:fixed, [String.t()]} | {:instances, %{max: pos_integer()}},
    slots: [%{name: String.t(), format: :uuid | :token, required: boolean()}],      # <= 8, append-only
    causes: %{String.t() => %{sign_rule: :positive | :negative | :zero_sum_by_slot_1 | :any, reason_required: boolean()}},
    key_bounds: [%{when_slot_nonempty: String.t(), max_on_hand: String.t()}],
    permissions: %{post: atom(), reverse: atom(), read: atom(), reconcile: atom()},
    scope_slot: String.t() | nil,
    max_event_lateness_hours: pos_integer(),                                        # default 96, at most 720
    error_aliases: %{String.t() => String.t()},                                     # core code -> wire code
    policy: {module(), :declare}}                                                    # declare/2 exported, in the module namespace
  ```
  Checks: ledger-id STRUCTURAL form `<module_id>` or `<module_id>:<suffix>` (suffix `[a-z0-9-]{1,32}`, total at most 64 bytes), anchored, and rejected if it could overlap another known module's ids (module id compared as the exact segment before `:`); slot names unique, formats closed, count at most 8, and append-only against the previously installed registration where known; cause names, sign rules in the closed set; `key_bounds` slot names exist and bounds are canonical decimals; permission atoms declared in the manifest's own `permissions`, NOT core atoms (reusing `core_permission_collision`), **and the role grants of `post` and `reverse` may not include `TENANT_AUDITOR` or `CANDIDATE`** (resolved from the compiled manifest, no `String.to_atom`), `post`/`reverse`/`read`/`reconcile` distinct where separation of duties is intended (R2-8; rule 12 REQUIRES `reverse` to differ from `post`); `scope_slot`, if present, names an existing slot (it is independent of rule 11's `scope_declarations`, which map managed ENTITY types to scope columns); lateness at most 720; aliases obey the rules of 12.2 (closed aliasable keys, values disjoint from every core/engine/entity/ledger code and from other modules' aliases, injective); `key_bounds` values are positive and fit `numeric(30,9)`; an optional `units` allowlist of `:token` strings. `Catalog.fetch_ledger/2` resolves by string comparison (D-R.2 pattern). Per-instance ids: at most `max` distinct ledger ids per tenant (default 64, enforced at counter creation, 7.1 step 5); the ledger-id SUFFIX can only be format-validated in L1-L4 (no master read), so the instance mode is **not enabled in L1-L4**: fixed ids only (OQ-2); any later per-instance mode needs the read facade to validate the suffix against a master and a test that a post-atom holder cannot create unbounded counters or balance rows (balance rows created from slot values are likewise unbounded without master validation: an L4 checklist item).
* **Write handler entries (rule 10, S21).** The exact-key check is relaxed to the four required keys plus the optional `:posts_ledger`, **a registration NAME (string), not a boolean** (several registrations may exist; R2-4); the `WriteHandler` struct gains `posts_ledger` (default nil, NOT in `@enforce_keys`). A handler with `posts_ledger` requires that registration in the same manifest (`write_handler_ledger_missing`) and the core checks the declarative posting's ledger id against that registration and its atoms. **A posting handler still needs at least one managed bookkeeping target** (3.3 design cost).
* **`ManifestHash`** (`modules/manifest_hash.ex`) must cover the whole registration (ledger ids, slots, causes, bounds, permission atoms, scope slot, lateness, aliases, policy MFA) and each handler's `posts_ledger`; a change bumps the hash and so (OQ-R3 of gh2590) refuses in-flight handler tasks until re-stamped; the module bumps `version` with such a change.
* **Activation (`ModuleWrites`).** New codes: `module_writes_multiple_ledger_postings` (more than one `posts_ledger` line on a node, 7.4) and a refusal of a `posts_ledger` handler on a SERVICE_TASK node in L1-L4 (7.5). `EntityPort.lock_types` is unchanged (the bookkeeping target is locked like any target).

### 14.4 The policy function (module code, PURE, BUILD time) and `Letflow.Ledger.Policy` (CDV 7, SEC r3 2)

```
@callback declare(posting_command(), registration :: map()) :: {:ok, declarative_posting()} | {:error, {code :: atom(), details :: map()}}

# Letflow.Ledger.Policy: the ONLY Letflow module a policy file may call (pure, total, no I/O)
@spec decimal(term(), scale :: 0..9) :: {:ok, Decimal.t()} | {:error, :invalid}     # canonical grammar of S14, never rounds
@spec uuid(term()) :: {:ok, String.t()} | {:error, :invalid}                         # lowercase canonical text
@spec token(term(), max_bytes :: pos_integer()) :: {:ok, String.t()} | {:error, :invalid}   # [a-z0-9._:-]
@spec leg(%{k: [String.t()], quantity: Decimal.t(), unit_ref: String.t(), optional(atom()) => term()}) :: declared_leg()   # constructor; unknown keys dropped
@spec posting(map()) :: declarative_posting()                                         # constructor, closed key set
```

Pure: no read, no write, no process, no clock, no lock; invoked by `handler_post.ex` through a Catalog `apply/3` on registered data, in the build process (which holds the live per-call token and the engine transaction's connection, so ambient authority is the risk the allowlist removes), with zero database access (T-PL-1). **Static guard is an ALLOWLIST, not a denylist (SEC r3 2, round 4 SEC 3):** policy code lives in ONE directory per module, `lib/letflow/modules/<id>/ledger_policy/**`, named by the registration's `policy:`; the `check_boundaries` rule scans EVERY file there and permits only these module references: `Enum`, `Map`, `List`, `String`, `Integer`, `Keyword`, `MapSet`, `Tuple`, `Access`, `Decimal`, other files of the same directory, and `Letflow.Ledger.Policy`. `Kernel` is NOT allowed wholesale: only its operators, comparison, boolean and `is_*` guard forms and the local pure builtins (`length`, `map_size`, `elem`, `hd`, `tl`, `abs`, `min`, `max`, `byte_size`, `to_string` on binaries) in LOCAL form are allowed, and the REMOTE forms `Kernel.send/2`, `Kernel.spawn/*`, `Kernel.spawn_link/*`, `Kernel.apply/2,3`, `Kernel.self/0`, `Kernel.make_ref/0`, `Kernel.node/*` are banned (as are the local calls `send`, `spawn`, `self`, `make_ref`, `node`, `apply`). Also banned: `String.to_atom`, `String.to_existing_atom`, `List.to_atom`, `List.to_existing_atom`, every `Module.*` function, and **`Regex` entirely** (the helpers `Policy.token/2` and `Policy.uuid/1` cover the format checks; a policy file needs no regex). By omission and explicitly also banned: `Repo`, `Ecto.*`, `Process`, `:erlang`, `:ets`, `:persistent_term`, `Agent`, `GenServer`, `Task`, `Application`, `System`, `File`, `:rand`, `DateTime`/`NaiveDateTime`/`Date`/`:os` (clocks), and the forms `receive` and `apply/3` with a non-literal module. A helper outside that directory is therefore unreachable from `policy:` (the transitive closure is confined to the directory). **Runtime bound, stated honestly:** core enforces the 256 KiB and 200-leg caps BEFORE `declare/2` is called, so its input is bounded; but `declare/2` runs in the engine process with NO timeout (the engine transaction has only the DB-level 5 s statement timeout, which does not interrupt Elixir code): a pure but slow policy could hold the transaction (and the class 1-5 locks it already holds) until the 10 s wall guard. That is an ACCEPTED RESIDUAL for compiled, reviewed module code; T-PL-2 is a regression budget on the fixture policy, not a runtime bound. **`declare/2`'s error `{code, details}` is not passed to the wire:** core rebuilds the `invalid_posting` details from a closed reason enum plus `leg_no` (7.1). Allowed error codes: `invalid_posting` (details `{leg_no, reason}`); anything else becomes `write_not_permitted`. A raise/exit/throw becomes the closed build failure. Core re-validates EVERYTHING it returns (B4). Facts are data, never authority: `declare/2` cannot read roles or grants and nothing it returns is trusted without re-validation. There is NO `gather_facts` (B3). T-PL-2 bounds its run time at the maximum command size.

### 14.5 No event schema change

`TASK_ENTITY_WRITES_APPLIED` v2 line items have `additionalProperties: false` (`gh2590...md` F-1); adding a posting id would force a v3 bump. The header carries `bpm_task_id`/`bpm_instance_id`; reverse lookup is `entries/3` by `bpm_task_id` (OQ-12).

### 14.6 Future read facade (documented, NOT built here; B3)

The OQ-R4 facade is the owed prerequisite for master validation (item/location/unit active), `expected_document_version`, retired-master checks and any suffix validation. When it is designed it must satisfy (EC F12, SEC R2-6): a CLOSED function set (get one record of a registered read type by id; `active?(type, id)`), no raw query, no lock (a SQL-telemetry test captures every statement and asserts no write, no `FOR UPDATE`/`FOR SHARE`, no schema other than the prefix, no ledger table), a statement timeout, facts are data never authority (no role or grant reads), results can be stale at commit (accepted TOCTOU for business facts; a version precondition must be re-checked under the lock), it runs inside the engine transaction after the class 1-5 locks (a pre-transaction plan phase is the later target), and it must not appear in `declare/2` (it would live in a separate, explicit pre-validation step). Until it exists the ledger accepts any well-formed slot values: master validation is a documented limit of L1-L4.

## 15. Decision records needed

* **0062 (proposed): "Domain-neutral ledger primitive: platform-owned append-only ledger tables, gap-free counter per ledger id, handler-facing `post/3`"**, written by L0 (docs). Contents:
  1. the route ruling R-N (advisor letflow-ec) and the rejection of R-D with its reason (3.2);
  2. **relation to 0039 D1**: core names no business domain; the primitive is neutral; Rules 7/7b/8 (3.5); the second plausible consumer (CMMS spare parts, HR leave balances) and the two accepted core changes; **Rule 7 ships in the same PR as the tables**; **D-E: neutral core error codes with module `error_aliases`**;
  3. **amendment of the wording of 0057 D5**: "the no-negative guard runs inside the module write handler" becomes "runs, under row locks in a fixed order (slot 1, then slot 2, ...), in the transaction of the handler's step, reached from the handler call by `HandlerWrites.post/3`; the stock module's registration supplies the item/location slot meaning";
  4. **what the 0054 Correction still requires of module code**: ledger POLICY stays reviewed module data and code (causes, sign rules, slot meanings, key bounds, permissions, the pure `declare/2`); the core enforces only generic mechanical invariants; the deviation from the letter of the Correction is recorded with V1 as the reason;
  5. **OQ-R4 (update-kind handler writes plus the read facade) stays OWED at WMS slice 5 and is NOT replaced**; master checks, version preconditions and retired-master checks are explicitly DEPENDENT on it (14.6);
  6. D-L2..D-L5, D-L11, D-L12; the TRUNCATE trigger as a tripwire and the TenantTemplate "unresettable" choice (5.4); the digest-based hash chain anchored in `ledger.posted` and the owner-tamper residual (5.1); the lateness cap D-T (8.3, registration value capped at 720 h); the per-cause balancing decision D-C (19); the SERVICE refusal as a TYPED refusal whose lifting needs a later 0061 amendment (7.5); tenant export/restore requirements (4.6); the scoped-principal limitation and its gating slice (16.2).
* **0061 amendment (L3 PR, rule 5):** "Rule 1 gains class 5b: after class 5 (and after the ancestor group of class 3) and before class 6; relative to the projection-protected rows of the instance (own tokens, timers per 'Amended (GH #2707, PR-1)' item 1, sequence rows, projection) its position is UNCONSTRAINED, because those rows are touched only while the transaction holds `P_x`: the ledger's balance rows ascending by `(k1..k8)` (missing rows inserted first in the same order), then the single counter row of the ledger id. At most one posting per transaction (static activation check plus the inner merge-function check of 7.4) and one ledger id per posting. A transaction that holds the audit chain row or any later class never takes a ledger row; the SERVICE origin is refused (typed) until its pre-lock exists." with tests T-LK-1..6.
* 0058: no note needed (items 1, 2, 4, 7 satisfied by 9.1, 9.4, 12, 9.5).

## 16. Security

### 16.1 Tenant scoping (INV-1)

Per-tenant schema; the prefix comes from the engine's authorised context (`HandlerContext.prefix`, `gh2590...md:967`), carried inside the capability, never from a command field; every statement passes `prefix:`.

### 16.2 Authorization of posting (M5, R2-3)

* Permission atoms AND the scope slot come from the module's `ledger` registration (permissions declared in its manifest and granted by `role_grants`), compiled atoms only (no `String.to_atom`); core hard-codes none.
* **Credential (allowlist, and its plumbing, CDV 6, round 4 CDV 3, SEC r3 4).** `HandlerContext` has NO `credential` field today and `build_context/2` copies only fixed attrs (`handler_writes.ex:520-534`); nothing carries the auth pipeline's per-branch `credential` (`:oidc` | `:api_token`, set in `lib/letflow/plugs/auth_pipeline.ex` ~439-453) into the engine. The concrete sites ELIXIR-DEV must change, in order: (1) `lib/letflow/routers/tasks.ex` (the call `Engine.complete_task(attrs, Keyword.put(opts, :f1, f1))` at ~361-362) reads `conn.assigns.auth_context.credential` and adds `credential: ...` to `opts`; (2) `lib/letflow/engine.ex` `complete_task/3` (~2616-2634) currently reads only `:prefix` and `:f1` from `opts` and hands `run_complete_task/7` FIXED positional parameters, so the new option needs a hop through `run_complete_task` and the entity plan; (3) `lib/letflow/engine/entity_port.ex` `multi_ctx` type (~126-134): add `optional(:credential) => atom()`; (4) the base map built at `lib/letflow/entities/step_writes.ex` ~661-675 (the `base` passed to `HandlerWrites.build_call/4`) copies it; (5) `lib/letflow/entities/handler_writes.ex` `call_attrs` type (~112-124): add `optional(:credential)`; (6) `build_context/2` (~520-534) sets the new `HandlerContext.credential` (`lib/letflow/entities/handler_context.ex` gains the field). **Rule: the ledger requires `credential == :oidc` (an ALLOWLIST); `nil`, missing or any other value is refused as if it were `:api_token`, which also covers any OTHER completer path that never sets it (fail closed)** — proven by test **T-SEC-3 (`ledger/credential_callers_test.exs`): it lists EVERY caller of `Engine.complete_task/3` in `lib/` (found by an AST scan, so a new caller fails the test until it is classified) and shows that each either passes `credential` taken from the request's auth context or is refused by the ledger when a posting handler runs under it (the tasks router sets `:oidc`/`:api_token`; every other caller yields `nil` and is refused)**, and a defaulted credential must never reach Principal construction (a `kind: :token` principal yields `{:ok, :all}` from `Scope.allowed_set/2`). L1-L4 refuse `:api_token` for post and reverse (an admin can mint a token for any user; the script registry refuses `:api_token` writes for the same reason, `auth_pipeline.ex:439-443`); lifting that needs its own rule.
* **Roles, from the DATABASE, in the transaction (step 2 of 7.1).** `Identity.list_effective_role_names(subject_id, prefix: prefix)` (`identity.ex:1285`) -> `Authorization.effective_roles(names, platform_tenant?)` (`authorization.ex:630-638`; strips `PLATFORM_ADMIN` outside the platform tenant, so `platform_tenant?` is resolved from the DATABASE for the tenant, not from the request) -> some role must satisfy `Authorization.role_allows?(role, atom)` (`authorization.ex:1518-1520`) for the registration's `post` (or `reverse`) atom. This runs inside the step, not from an activation snapshot and not only in the pre-transaction `authorize_module_writes` (`engine.ex:3093-3096`, which checks the stamp). Test: a role revoked between claim and completion is refused.
* **Scope.** Build the `Scope.Principal` OUTSIDE a request (recipe, closes the NOT VERIFIED item): `%Scope.Principal{kind: :user, user_id: subject_id, prefix: prefix, platform_tenant?: PlatformTenant.platform_tenant?(tenant_id), roles: <the DB-resolved effective roles above>, grants: Scope.load_grants(subject_id, prefix)}` (struct `api/scope.ex:99-106`); `tenant_id` is resolved from the prefix with `TenantProvisioning.tenant_id_for_schema_name(prefix)` (`tenant_provisioning.ex:258`, the same call `audit.ex` uses) because the context carries only the prefix, and `PlatformTenant.platform_tenant?/1` (`platform_tenant.ex:117`) takes that id. Then use `Scope.load_grants(subject_id, prefix)` (`api/scope.ex:355`; backed by `RoleScopeGrants.applicable_rows_for_user/2`, `role_scope_grants.ex:673`, which already covers group rows through `group_members`) and require `Scope.allowed_set(principal, post_atom) == {:ok, :all}` (`api/scope.ex:161`; `{:ok, :all}` only for tenant-wide, token or platform principals; it can raise `ScopeSetError`, which is caught and treated as a refusal). A load failure or `:not_loaded` memo is a REFUSAL (fail closed, `auth_pipeline.ex:420-428`). The request-time constructor the recipe mirrors is `Scope.principal_from_conn/1` (`api/scope.ex:378-391`). Every refusal here is the one `write_not_permitted` body with audit detail `scoped_principal_unsupported` / `credential_unsupported` / `role_denied`, and the authority check runs BEFORE any deferred build-time refusal is released (7.1), so an unauthorised subject cannot learn the registration's shape from error bodies.
* **Known limitation (EC F13, OQ-21, needs supervisor confirmation).** Until a later slice wires scope enforcement for `post/3`, a warehouse-scoped storekeeper CANNOT post at all: only tenant-wide principals can. That slice (**L6: enforce the registered `scope_slot` through `Scope.allowed_set_for_role`/the scope check, fail closed**) is named and GATES THE PILOT.
* **`TENANT_ADMIN`** holds every tenant-scope permission automatically, Catalog permissions included (`authorization.ex:1536-1542`, S22), so it holds post and reverse regardless of `role_grants`: no separation of duties for that role. `TENANT_AUDITOR` may be granted at most read and reconcile (rule 12 rejects more). `PLATFORM_ADMIN` holds everything and is NOT relied on. A `TASK_WORKER` post grant is tenant-wide: the real gate is BPM routing, the task assignee and the stamp, not the atom.
* Denied == absent (INV-5): every authorisation, stamp, origin and target refusal is the one `write_not_permitted` body.

### 16.3 Disclosure, logs, SQL, DoS

Refusals carry ids/enums only; `available` is computed and gated inside the step; reversal details never echo the target; the guard-oracle residual is documented (10). Free-text columns carry the CHECKs of section 4 and are not logged. SQL is Ecto composition with bound parameters and `prefix:` (INV-7); the only literal SQL is the fixed migration text with the quoted schema. DoS: FIFO at most 2 s then 503; holder bounded by 5 s/10 s; 200 legs, 1 posting per transaction, 20 lines per node; the counter convoy is tenant-wide (already so for the audit chain row, S8) and there is no per-actor rate limit (S25), stated as a residual; reconcile and cut-off reads are timeout-bound, chunked and concurrency-capped (11.2). **CSV/XLSX export of ledger data (L4) must neutralise cells starting with `=`, `+`, `-`, `@`**, and slot canonicalisation prevents NFC/NFD lookalike keys (format `:token` has a fixed ASCII charset).

### 16.4 Single access path (SEC-4, R2-1, R2-9)

`Letflow.Ledger.post/1` accepts only a server-minted opaque `Capability`; the token is verified at BUILD time in `handler_post.ex`; Rule 8 limits `post` and `mint` to that file and scans modules and Lua/WASM host code for the ledger and for dynamic dispatch; the read functions require an `authorized` value. T-SEC-1 includes the hand-built-context refusal.

### 16.5 SECURITY-REVIEWER checklist (per slice)

Every slice: audit entries, logs and metrics carry the NEUTRAL core code, and `details` keys come from the registration's slot names, not from core. L1 (`ledger_*` tables): triggers (UPDATE/DELETE/TRUNCATE) as a tripwire, schema-qualified names via `quote_ident`, no SECURITY DEFINER, lazy counter bootstrap, `entry_digest`/`chain_hash`, the FULL CHECK set (control chars, hash format, ledger-id form, lengths), `down` flag guard, TenantTemplate "unresettable" change and fixture-loader deny list, oracle and provisioning entries, Rule 7 shipped with the tables. L2 (`Letflow.Ledger.post/2`): the algorithm order (insert-then-lock ascending; idempotency re-check right after the key locks; counter last), opaque capability, isolation assertion, idempotency scoping per subject, lateness checked against `posting_time` under the lock, ledger id vs registration, `key_bounds` and unit pin, bound parameters, no values in logs, reconcile advisory lock and snapshot rule. L3 (`HandlerWrites.post/3`): build-time token, Rule 8 call-site + dynamic-dispatch scan, roles/scope per 16.2, `credential` in `HandlerContext`, rule 12 (auditor/candidate, distinct atoms, overlap), activation refusing more than one posting line and SERVICE nodes, pure `declare/2` + edge rule, core re-validation, `ledger.posted` with `chain_hash`, the 5-tuple not logged, SERVICE origin typed refusal, mandatory SEC trigger (catalog.ex, authorization.ex, permission matrix). L4 (stock module): `Ledger.authorize/3`, allowlisted read maps, export neutralisation, no ledger SQL in module code, INV-10 route classification, chunking/timeouts. L5: SEC-12 conditions and its 0061 amendment. L6: scope enforcement.

## 17. Implementation slicing (proposal; neutral names)

| Slice | Content | Size | Depends on |
|---|---|---|---|
| L0 | decision 0062, 0061 amendment text, 0057 D5 wording (docs only) | S | this note accepted; OQ-19..21 confirmed; **the supervisor has recorded the AMENDMENT of two #2657 acceptance criteria (section 18) on the issue** |
| L1 | migration(s): `ledger_counter`, `ledger_entry`, `ledger_leg`, `ledger_balance`, all triggers, digest/chain, full CHECK set, provisioning entry, `expected_tenant_tables` oracle, `TenantTemplate` "unresettable" change + fixture-loader deny list, check_boundaries Rule 7/7b, T-AO-1, T-TT-*, T-SC-1 | M | notes #2658/#2660 accepted (slot and unit columns); L0 |
| L2a | `Letflow.Ledger.post/1` with a TEST registration (fixture ledger): guard, `key_bounds`, unit pin, counter, idempotency, offline fields; T-AC1/2/6, T-GF, T-LK-1/3, T-OFF-1, T-KB-1 | L | L1 |
| L2b | reversal, `authorize/3`, `balances/5`, `entries/3`, `reconcile/2`; T-AC3/4/5, T-RP-* | M | L2a |
| L3 | `HandlerWrites.post/3` + `handler_post.ex`, capability, Catalog rule 12 and `posts_ledger`, `ManifestHash`, activation checks, H4 change, failure channel 12.3, roles/scope/credential per 16.2 (adds `credential` to `HandlerContext`), `ledger.posted` audit in the engine tail, Rule 8, 0061 amendment code, T-LK-2..6, T-ERR-*, T-SEC-*, T-AU-*, T-PL-1, T-SC-4, fixture module | L | L2a, REQ-501 R1-R5 (merged) |
| L4 | stock module: manifest (ledger registration: slots, causes, bounds, permissions, aliases, `declare/2`), views `stock_movement`/`stock_balance`, read routes through `authorize/3`, runbook; NO master checks | L | L3 |
| L5 | SERVICE-origin pre-locks and lifting the typed refusal (SEC-12), with its 0061 amendment | M | L3 |
| L6 | scope enforcement for `post/3` through the registered `scope_slot` (fail closed): **gates the pilot** | M | L3 |
| PILOT GATE | **The stock module is NOT enabled for a customer tenant until L6 AND L7 are done**, and **serial-tracked goods stay out of the pilot until OQ-23 (serial uniqueness across locations) is resolved.** Rationale: without L7 (master validation) a typo in an item or location id creates a NEW balance key and the first-touch `unit_ref`/`max_on_hand` pin on it is permanent (4.4); without L6 a scoped storekeeper cannot post; without OQ-23 the same serial can be active at two locations. | | |
| L7 | master validation, `expected_document_version`, retired-master checks, per-instance ledger ids: **gates the pilot** | M | the OQ-R4 read facade (owed at WMS slice 5), masters #2661/#2662 and #2663/#2664 |

The ledger core (L1-L3) proceeds without the masters and without the facade. Explicitly OUT of this issue and its slices: REQ-503 behaviour (quarantine, serial flows beyond the key bound, owner/custodian transfer, available-to-pick); REQ-504 conversion/rounding/tolerance logic (its design is #2660; this note reserves the columns); the 1C/SAP acknowledgment table (G9); command log and lease (REQ-480); counts/variance (WM-12); period close; per-ledger-instance sequences (the scale path); a balance repair action; automated postings (until L5); OQ-R4's update-kind and read facade (owed at WMS slice 5).

## 18. Acceptance-criteria map

| AC | Where |
|---|---|
| Tables, append-only, sequence proof, lock order, citations | 4, 5, 6.2, 7, 2 |
| G7 event time; time basis/cut-off | 8 |
| Test plan (unbalanced, concurrent negative, reversal, cut-off, cache+reconcile, idempotency) | 13 T-AC1..6 |
| Prerequisite carried; REQ-501 ACs not on main | 1.1 |
| CDV/SECURITY gates | 16.5, 21 |
| Offline (0058 c.1): `client_op_id`, `device_id`, `client_seq`, `client_event_time` stored beside `posting_seq` and posting time | 4.2, 9.1 : MET |
| Offline (0058 c.4): typed 409 with machine-readable details, at least `insufficient_stock` | 12 : MET (the wire code `insufficient_stock` through the alias, D-E) |
| Offline (0058 c.2): commands on mutable resources state `expected_version`; mismatch is a typed conflict | 9.4 : **MET IN PART**. The ledger has no client-mutable resource; the reversal precondition ("not yet reversed", `posting_already_reversed`) is met. The `expected_document_version` check against a mutable ENTITY record (typed `record_version_conflict`) is NOT in L1-L4: it needs a read and is DEPENDENT on the OQ-R4 read facade (14.6, slice L7). |
| Offline (0058 c.7): retire/cancel is a tombstone, never a delete | 5.2, 9.5 : **MET IN PART**. No ledger row is ever deleted and a zero balance row stays (met). The "retired master blocks only stock-adding legs / active master check" is NOT in L1-L4: it needs a read and is DEPENDENT on the facade (slice L7). |
| Quantities per D4 | 1.2, 4.3 |

**Gate (CDV 5).** Two acceptance criteria of #2657 (the 0058 (c) items 2 and 7 master-side parts above) are met only in part by L1-L6. The supervisor must record an AMENDMENT of those two criteria on #2657 (their remaining parts move to the read-facade slice L7) BEFORE L0 starts; this note does not amend the issue itself. This is listed with D-E and the scoped-principal limitation as a decision needing confirmation (OQ-20, OQ-19, OQ-21).
| REQ-503/504 by reference | 4.5 |

## 19. Decisions recorded

* **D-L1 route:** R-N, RULED by the advisor letflow-ec (OQ-1 closed).
* **D-L2** append-only in the database as a tripwire plus chain (5.1); **D-L3** one sequence PER LEDGER ID (the stock module registers one fixed id per tenant in release 1; per-instance ids are the scale path and are not enabled in L1-L4); **D-L4** class 5b (7.2); **D-L5** time (8); **D-L11** no FK from ledger tables to engine tables (S19); **D-L12** SERVICE origin refused in L1-L4 (7.5).
* **D-T lateness cap = 96 hours**, registration value capped at 720 h (8.3).
* **D-C per-cause balancing (OQ-14 decided).** The draft says WM-06 "every movement balances source and destination" and MD-08 "every transfer has balanced source/destination legs". International practice (SAP material documents, Dynamics 365 inventory transactions) posts a goods receipt or issue single-sided and balances only two-sided causes (transfer posting, stock-type/status change); the counterpart of a receipt is the supplier, outside the stock ledger. Decision: sign rules per cause (`positive`, `negative`, `zero_sum_by_slot_1`, `any`, `reversal`); "every movement balances" is read per cause; no virtual-location double entry. This agrees with 0057 D5 and with the draft's own MD-08 wording for transfers; no real conflict needing the user was found. Recorded in 0062.
* **D-E neutral error codes with module aliases (new; needs supervisor confirmation, OQ-19).** Core code `insufficient_balance`, the stock module's wire code `insufficient_stock` via `error_aliases` (12.2). The issue AC names `insufficient_stock`, which the alias delivers to clients.
* **Pilot gate (advisor delta review).** The stock module is not enabled for a customer tenant until L6 and L7 are done; serial-tracked goods stay out of the pilot until OQ-23 is resolved (17).
* **D-P policy purity (B3; needs supervisor confirmation, OQ-20).** In L1-L4 the policy is the pure `declare/2` at build time; no `gather_facts`, no master/version/retired checks; they depend on the OQ-R4 read facade (14.6). **Consequence: two acceptance criteria of #2657 are met only in part (section 18), which requires an issue amendment recorded by the supervisor before L0.**
* **C-2** the 1C/SAP acknowledgment is a later append-only table, not a header column. **C-3** a reversal carries its own event time. **C-4** negative stock forbidden (D5) with the `CHECK` backstop. **C-5** per-tenant sequence (one fixed id per tenant).

## 20. Open questions

| Id | Question | Default |
|---|---|---|
| OQ-2 | One stock ledger id per tenant (release 1) or one per warehouse? Per-warehouse ids cost atomic inter-warehouse transfers (7.6) and need the facade for suffix validation | per tenant; per-warehouse only if T-LD-1 fails |
| OQ-3 | Allow negative balance by policy? | no (D5) |
| OQ-9 | Should reconcile repair? | no |
| OQ-10 | `numeric(30,9)` until REQ-504 fixes scales? | yes |
| OQ-11 | Role grants for the four atoms? | task-worker post+read; tenant-admin gets all automatically (S22); auditor read+reconcile; real role list NOT VERIFIED, decided in L4 |
| OQ-12 | Entry id into the APPLIED event? | no |
| OQ-13 | Warehouse/zone scoping of postings? | out of L1-L5; slice L6 gates the pilot; until then scoped principals are refused |
| OQ-18 | Keyed digest (HMAC with a platform secret) for the hash chain? | unkeyed in release 1; the audit anchor raises the bar; keying is code-only later |
| OQ-19 | **Confirm D-E: neutral core error code `insufficient_balance` with the stock module's wire alias `insufficient_stock`.** | yes |
| OQ-20 | **Confirm D-P: no `gather_facts` and no master/version/retired-master checks in L1-L4; they wait for the OQ-R4 read facade. This amends two #2657 acceptance criteria (0058 (c) items 2 and 7, master side); the supervisor records the amendment on #2657 BEFORE L0.** | yes, with the amendment recorded |
| OQ-21 | **Confirm the scoped-principal limitation: a warehouse-scoped storekeeper cannot post until L6.** | yes; L6 is a named slice gating the pilot, and so is L7 (see the pilot gate in 17) |
| OQ-22 | A separate backdating permission above a small threshold? | no |
| OQ-23 | Tenant-wide serial uniqueness (the `key_bounds` bound is per balance key including location): add a registered `unique_over` subset with a shadow key row locked in the same ascending order? | not in release 1; per-key bound only; revisit with the read facade **Serial-tracked goods stay out of the pilot until this is resolved (17).** |
| OQ-24 | A MAC or nonce on `Capability` and `Authorized` verified by core (optional hardening on top of Rule 8)? | no |

Closed in this revision: OQ-1 (R-N ruled), OQ-4, OQ-5 (replaced by the registered scope slot, 16.2), OQ-6, OQ-7, OQ-8, OQ-14 (D-C), OQ-15 (D-T), OQ-16 (closed by `key_bounds` and the #2658 text in 4.5), OQ-17 (removed with `gather_facts`).

## 21. Revision map: every finding of the three reviews

| Finding | Status | How / where |
|---|---|---|
| CDV B1 token cannot work at step time | done (re-done in round 3) | token checked at BUILD in `handler_post.ex`; opaque minted capability; the one-posting check is in the MERGE FUNCTION (parent changes passed into `invoke/5`), not in the step: 7.1, 7.4, 14.1, 14.2, 16.4, S1b, T-LK-5/6 |
| CDV B2 idempotency re-check after guard | done | re-check by both keys right after the key locks (7.1 step 7) plus the counter-lock re-check; 6.2 rows d/e; T-AC6 tight-stock, T-AC3 reversal retry |
| CDV B3 `gather_facts` reintroduces the facade | done | removed; pure `declare/2` only; master/version/retired checks DEPENDENT on the OQ-R4 facade: 3.3, 9.4, 9.5, 14.4, 14.6, 17 L7, T deferred |
| CDV M1 Rule 7 neutrality, `insufficient_stock` | done | neutral `insufficient_balance` + `error_aliases` (D-E); scan unit and scope defined; Rule 7b allowlist: 3.5, 12.2 |
| CDV M2 Rule 8 enforceability | done | call-site AST scan + dynamic dispatch scan, pure `violations/1` seam; reads allowed: 3.5, T-SC-4 |
| CDV M3 rule number collision, policy shape | done | rule 12 after rule 11; `scope_slot` independent of `scope_declarations`; `policy: {Mod, :declare}` arity 2: 14.3, S21b |
| CDV M4 T-AO-1 stale | done | no seed row; counter empty after replay; lazy creation; first-post race and rollback variant: 4.1, T-AO-1 |
| CDV M5 roles/scope left to implementer | done | specified with the verified functions; credential gap: 1.1, 16.2 |
| CDV M6 per-key invariants | done | `key_bounds` pinned on the balance row and enforced under the key lock; OQ-16 closed; #2658 text: 4.4, 4.5, T-KB-1 |
| CDV N1 k1/k2 CHECK | done | only `k1` non-empty: 4.3 |
| CDV N2 proof base case | done | F7, base case `c(1)=0`, row f: 6.2 |
| CDV N3 isolation assertion | done | `current_setting('transaction_isolation')` at step 1: 6.1, 7.1 |
| CDV N4 reset reasons | done | string reasons, `:verify_failed` label, moduledoc sentence, fixture loader deny: 5.4, 4.6, S9b, S9c |
| CDV N5 lateness one source | done | registration value capped at 720; override sentence deleted: 8.3 |
| CDV N6 unit per key | done | pinned `unit_ref`, `unit_mismatch`: 4.4, 7.1 step 8 |
| CDV N7 balance index | done | `(ledger_id, k2, k1)`, slot 3 filters scan, expiry via master, ninth slot DDL: 4.3, 4.4 |
| CDV N8 12.2 write_not_permitted row | done | clarified; marker failure is `entity_write_failed`: 12.2 |
| CDV N9 ledger-id suffix validation | done | structural form, rule 12 overlap, instance mode not enabled in L1-L4: 14.3 |
| CDV N10 merge T-SC-2/T-SC-4 | done | T-SC-1 (Rule 7/7b) and T-SC-4 (Rule 8): 13 |
| SEC R2-1 token/capability, Rule 8 | done | as B1 |
| SEC R2-2 digest and chain | done | `entry_digest` over all immutable columns + legs, `chain_hash` in `ledger.posted`, keyed option OQ-18: 4.2, 5.1, 7.7 |
| SEC R2-3 roles/scope/credential | done | 16.2 (the NOT FOUND claim corrected in 1.1) |
| SEC R2-4 ledger_id and `posts_ledger` | done | structural form, named registration, overlap, cap, fixed ids in L1-L4: 14.3 |
| SEC R2-5 read API authorization | done | `authorize/3`, `authorized()`, allowlisted maps, not-found == not-authorized: 14.1 |
| SEC R2-6 policy callback sandboxing | done | no `gather_facts`; `declare/2` pure, edge rule, zero-query test, re-validation; facade requirements for later: 14.4, 14.6, T-PL-1 |
| SEC R2-7 CHECK completeness | done | section 4 text hygiene, slot formats, attrs caps; CSV neutralisation: 4, 16.3 |
| SEC R2-8 rule 12 caps | done | lateness 720, distinct atoms, sentence deleted: 8.3, 14.3 |
| SEC R2-9 one posting enforcement | done (round 3) | static activation check + merge-function check: 7.4 |
| SEC R2-10 reconcile | done | `pg_try_advisory_xact_lock`, fixed `N`, `last_posting_seq <= N` rule, time bound: 11.2 |
| SEC R2-11 device_id not authorization | done | stated; lateness vs `posting_time` under lock; OQ-22: 8.1 |
| SEC R2-12 quote_ident, `available` in step, 5-tuple not logged | done | section 4, 12.1, 12.3, T-ERR-3 |
| EC F1 circular hash step | done | computed from the locking read before the UPDATE; deferred trigger checks the chain head: 6.1, 5.3 |
| EC F2 guard vs idempotency | done | as B2 |
| EC F3 tail failure test | done | T-AU-2: 7.7 |
| EC F4 token in step context; 0061 dependency | done (round 3) | one-posting check in the merge function and per-call token, not the process dictionary; sequential-transactions test; class 3 named: 7.2, 7.4, T-LK-6 |
| EC F5 per-warehouse cost | done | 7.6, OQ-2 |
| EC F6 `down` guard | done | config flag, not `Mix.env`: section 4 |
| EC F7 FK closure test | done | T-TT-3: 5.4 |
| EC F8 per-key bound | done | as M6 |
| EC F9 slot formats | done | 4.5 |
| EC F10 unit pin | done | as N6 |
| EC F11 indexes | done | as N7 |
| EC F12 facade rules, no module refs, Rule 7 with tables | done | 14.6, 3.5, section 4, 15 |
| EC F13 scoped limitation, bookkeeping cost | done | 16.2 (L6 gates the pilot), 3.3, OQ-21 |
| Supervisor addendum: decisions needing confirmation | done | OQ-19 (D-E), OQ-20 (D-P + the AC amendment), OQ-21 (scope) |
| **Round 3 CDV 1 (BLOCKER) marker does not work across merged Multis** | done and VERIFIED in round 4 | mechanism: pass parent changes into `invoke/5`, flag in the per-call token, deferred contract refusal; Ecto behaviour verified (`multi.ex:883-892`, `merge_results` ~944-955); the `set_config` fallback is removed: 7.1, 7.4, 14.1, 16.4, T-LK-5/6 |
| Round 3 CDV 2 build-time refusals lack a channel | done (reworked in round 4) | refusals are the capability's `deferred_refusal`, released by the ledger step AFTER the authority check: 7.1, 12.3, T-AC1, T-OFF-1, T-ERR-1 |
| Round 3 CDV 3 `check_built` / `produced` bookkeeping | done | the ledger step is recorded in `produced`, key from `next_ordinal`, consumes one of the 49 slots: 7.1 |
| Round 3 CDV 4 `key_bounds` overclaim | done | restated per balance key; #2658 text item (3) corrected; OQ-23 with the `unique_over` shadow-key mechanism: 4.5, T-KB-1 |
| Round 3 CDV 5 OQ-20 drops two ACs | done | gate before L0, "met in part" rows, listed for confirmation: 17, 18, 19, 20 |
| Round 3 CDV 6 credential plumbing | done | router -> opts -> multi_ctx -> call_attrs -> `build_context` -> `HandlerContext.credential`; `:oidc` allowlist, absent fails closed: 16.2 |
| Round 3 CDV 7 `Letflow.Ledger.Policy` unspecified | done | signatures, purity contract, allowlist scan confined to one directory: 14.4 |
| Round 3 CDV 8 alias collision | done | closed aliasable keys, disjointness, injectivity, golden test: 12.2, 14.3, T-ERR-4 |
| Round 3 CDV 9 scan edges | done | plural/word rule, migration SQL allowlist, Rule 8 exemptions, struct/alias forgery (SEC 1): 3.5, T-SC-1, T-SC-4 |
| Round 3 CDV 10 pin and conversion hazards | done | pilot risk with operator remedy, later bounds never apply to existing keys, conversion evidence untrusted: 4.4 |
| Round 3 SEC 1 forgeable Principal/Authorized/Capability | done | Rule 8 (c); `authorize/3` takes the conn and rejects `kind: :token`; optional MAC OQ-24: 3.5, 14.1 |
| Round 3 SEC 2 policy purity allowlist | done | as CDV 7: 14.4, T-PL-2 |
| Round 3 SEC 3 alias targets | done | as CDV 8 |
| Round 3 SEC 4 credential allowlist, tenant_id, Principal recipe | done | 16.2 (recipe closes the NOT VERIFIED item) |
| Round 3 SEC 5 `unit_ref` charset/allowlist, bounds validity, min-wins, no re-pin, reconcile lock scope | done | 4.3, 4.4, 14.3, 11.2 |
| **Round 4 SEC 1 (MAJOR) build-time refusals before authority (INV-5/INV-4)** | done | B4/B5 emit nothing; the capability carries `deferred_refusal`; the run step checks authority FIRST and releases it only for an authorised subject; the credential check on the context stays an early uniform refusal at B1; T-SEC-1 byte-identity case for every refusal kind; typed expectations restated for authorised subjects: 7.1, 7.4, 12.2, 12.3, 14.2, 16.2, T-AC1, T-OFF-1, T-ERR-1, T-SEC-1 |
| Round 4 SEC 2 / CDV 2 (MINOR) contract-failure mapping | done | explicit `ledger/failure.ex` clause `{:ledger_contract, atom}` -> `{:failed, i, :ledger_marker}` (closed 500, no details, not the 5-tuple); T-ERR-1 asserts the body; 7.1, 7.4, 12.2 consistent: 12.3 |
| Round 4 SEC 3 (MINOR) policy allowlist | done | `Kernel` not allowed wholesale (remote `send/spawn/apply/self/make_ref/node` banned), `String.to_atom`, `List.to_atom`, `Module.*`, `Regex` banned; caps enforced before `declare/2`; no-timeout residual accepted and T-PL-2 called a regression budget; module `details` not passed to the wire: 14.4, 7.1 |
| Round 4 CDV 1 (MINOR) Ecto behaviour | done | hedge replaced with the verified citation and the one-merge dependency (`step_writes.ex:547-548`, `:604`, `handler_writes.ex:476-477`); T-LK-5 guards the structure; fallback paragraph dropped: 7.4, T-LK-5 |
| Round 4 CDV 3 (MINOR) credential sites | done | six concrete files and positions listed, `nil` fails closed: 16.2 |
| **Round 5 item 1** L7 and OQ-23 gate the pilot | done | pilot gate row in 17; recorded in 19, 20 (OQ-21, OQ-23): the module is not enabled for a customer until L6 and L7, serial-tracked goods stay out until OQ-23 |
| Round 5 item 2 class 5b wording | done | "after class 5, before class 6; unconstrained relative to the projection-protected rows (tokens, timers)" in 7.2, the 0061 amendment text in 15 (also its stale marker phrase), the T-LK-2 probe in 13 |
| Round 5 item 3 credential callers test | done | T-SEC-3 `ledger/credential_callers_test.exs` lists every caller of `Engine.complete_task/3` and shows each sets `credential` or is refused: 16.2 |
| Round 5 item 4 D-E audit/log/metric code and `details` keys | done | neutral code in audit, logs, metrics; `details` keys from registered slot names; T-ERR-5; 16.5 checklist: 12.2, 16.5, 13 |
| Round 5 item 5 Rule 7 allowlist | done | new allowlist pairs and denylist entries only by a reviewed diff: 3.5 |

## 22. Risks for CODE-DESIGN-VALIDATOR to attack first

1. Neutrality (3.3, 3.5): that Rule 7 as an AST token scan really keeps business terms out, that the slot/cause registration removes the stock vocabulary, and that 0062 states the Correction deviation honestly.
2. The BUILD-time/RUN-time split (7.1, 7.4): that `declare/2` at build, the capability with its deferred refusal, the authority-first rule and the inner merge-function one-posting check close the token, marker and INV-5 problems, and that no run-time path needs a read.
3. The gap-free proof with the lazy counter (6.2, F7), the visibility argument and the duplicate paths (rows d, e).
4. Class 5b against the real tail and the SERVICE cycle (7.2, 7.5): derived by reading, not run.
5. `key_bounds` as the only per-key invariant (4.5): whether it is enough for serial uniqueness without master validation.
6. The scope/credential specification (16.2): the Principal recipe outside a request mirrors `principal_from_conn/1`; the credential plumbing path is a design, not existing code. The merge-function mechanism of 7.4 is verified against Ecto but depends on the one-merge structure at `step_writes.ex:547-548`.
7. Throughput numbers (criterion only, not measured).
