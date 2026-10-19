# GH #2657 / REQ-502 -- WMS stock ledger core (1 of 4): append-only posting header plus legs, gap-free posting sequence, reversal, no-negative guard

Author: CODE-DESIGNER, 2026-10-19. Revision 1 (CDV FAIL + SECURITY PASS_WITH_FINDINGS applied; advisor ruling R-N applied; section 21 maps every finding).
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
| V2 | Which route? | **R-N**, a domain-neutral core posting primitive. RULED by the advisor letflow-ec (Opus), high confidence, relayed by the coordinator 2026-10-19. R-D (entity-type ledger through update-kind handler writes) is kept in section 3.2 as the REJECTED alternative with the ruling's reason. |
| V3 | Storage | Core tenant tables `ledger_entry` (header), `ledger_leg`, `ledger_balance`, `ledger_counter` (one row per registered ledger id). Core names no business term; the stock vocabulary (item, location, status, lot, `stock_movement`, `stock_balance`) lives in the stock module's registration, policy and read layer. |
| V4 | Append-only | Database triggers against UPDATE/DELETE/TRUNCATE (a TRIPWIRE, not a security boundary: the app role owns the tables), structural constraints, deferred constraint triggers, hash chain; single-writer scans; the pooled test reset is changed (5.4). |
| V5 | Sequence | One counter row PER LEDGER ID, locked to commit, `+1` forced by trigger; NOT a Postgres SEQUENCE; proof in section 6. One posting per transaction (7.4). |
| V6 | Lock order | Class 5b between 0061 classes 5 and 6: balance rows ascending (missing rows inserted first, same order), then the counter row. Needs a 0061 amendment. |
| V7 | Errors | Typed 409s with `details` through a new 4-tuple refusal channel (12.3); 503 for contention. |
| V8 | Time (G7) | `event_time` kept, `posting_time`/`posting_seq` server-side; lateness cap DECIDED 96 h (8.3). |
| V9 | Audit | One `ledger.posted` audit entry per posting, appended by the engine tail after the counter (7.7). |
| V10 | Prerequisites today | REQ-501 R1-R5 merged; #2654 closed; masters #2661/#2663 and the #2658/#2660 notes NOT FOUND (section 1). The ledger core (L1-L3) does not depend on the masters. |

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
| A handler UPDATES a record, READS a table, takes a lock, or writes a non-entity table | **NO. NOT FOUND by design** (`gh2590...md:199` F-R5, `:1073` OQ-R4 "update kind is a separate prerequisite", `:1094` "the first real ledger handler", `:1099` "a narrow read facade ... together with update-kind support") |
| `ActorCapabilities` | NOT FOUND (`grep -r ActorCapabilit lib docs` empty). The access path is `Authorization.role_allows?/2` (`authorization.ex:1518-1520`), `TypeAccess` (`type_access.ex:73`), `FieldGrants`, `RecordAccess` (`record_access.ex:43`). |
| A function resolving a user id to its effective roles from the DATABASE inside a transaction | NOT FOUND (`effective_roles/2`, `authorization.ex:630`, maps role strings of a verified token). Required by section 16.2. |

### 1.2 Soft dependencies

| Dependency | State today | Effect |
|---|---|---|
| #2654 exact decimals | CLOSED 2026-10-17; PR-1 `49f43759` (#2761) and PR-2 `e6dc2419` (#2770) on main; the 2026-10-17 issue update is superseded | strict reads/filters/aggregates are live. The ledger's own columns are Postgres `numeric` (exact by construction); the wire value is parsed by `Decimals.parse/3` (`entities/record/decimals.ex:128-148`). |
| Masters #2661/#2663 and behaviour halves #2662/#2664 | all OPEN; `lib/letflow/modules/` has only `exam/`, `priv/modules/` only `exam/` (NOT FOUND: `Org`, `CatalogItems`, any stock module) | SOFT for this design; HARD for slice L4. |
| #2658 (dimensions), #2660 (quantity) | OPEN, no note on main | columns by reference (4.5); L1 waits for both notes. |

## 2. Sources and verification (all on `a614e9c1`)

| # | Claim | Source |
|---|---|---|
| S1 | Handler API is `create/3` only; no repo, no read, no step function | `entities/handler_writes.ex:138-149`; `gh2590...md:480-497` |
| S2 | `lock_types/3,4`: one `{:type_lock,t}` / `{:pre_type_lock,t}` step per type ascending | `handler_writes.ex:426-437`; `step_writes.ex:526-585`; `engine/entity_port.ex:236-254` |
| S3 | HUMAN completion order: tasks, projection, pure steps, `:lock_ancestors`, entity-type rows, handler calls, THEN the tail | `engine.ex:383-398` |
| S3b | The tail starts with `:cancel_escalation_timers`, `:cancel_reminder_timers`, then token reconcile, task activation, audit rows, events, projection, cascade | `engine.ex:7350, 7365` and the moduledoc `:383-398`; 0061 "Amended (GH #2707, PR-1)" item 1 puts timer rows after the entity-type rows and before the audit chain row, touched only while `P_x` is held |
| S4 | SERVICE apply: `:lock_ancestors`, `{:pre_type_lock,_}`, then tokens and task activation whose `task.create` audit takes the audit chain row, then entity writes and handlers | `engine.ex:400-410`, pre-lock `:5800` |
| S5 | A node with lines/`module_writes` runs `SET LOCAL lock_timeout '2s'` and `statement_timeout` 5 s first; contention codes `[:lock_not_available, :query_canceled, :deadlock_detected]` map to 503 `entity_write_contention` | `engine.ex:390-392, 2920, 2925, 3195, 5664`; `api/response.ex:312-314`; `routers/tasks.ex:456-463` |
| S6 | Refusal envelope `{"error": code, "line_index": n|null}`; status table 403/409/503/422; `write_not_permitted` byte-identical for every cause | `api/response.ex:288-314`; `engine.ex:2938-2946` |
| S6b | Failure channel: `EntityPort.failure` is `{:refused, index, code, detail_atom} \| {:failed, index, step} \| :not_a_line_failure`; the engine writes a best-effort refusal audit AFTER the rollback (ids and a closed detail atom) and returns the 3-tuple `{:entity_write_refused, index, code}`; the `details` map has no channel | `engine/entity_port.ex:179-182`; `engine.ex:8440-8462`; `step_writes.ex:944-960` |
| S6c | Sites that match the 3-tuple `{:entity_write_refused, _, _}` | `engine.ex:2549, 2994, 3038, 3057, 3062, 3116, 3143, 3243, 3250, 5478, 5675, 5682, 5695, 5737, 6008, 6045, 6073-6101, 8433, 8461-8462`; `engine/service_task_dispatcher.ex:667`; `engine/script_task_dispatcher.ex:107`; `routers/tasks.ex:456-463`; `entities/records.ex:828-876` (Records-level `{:entity_write_refused, i, code}`) |
| S7 | Sequence-row protocol: insert-if-absent, `lock: "FOR UPDATE"` Ecto composition, increment; `lock_instance_sequence/3` | `event_store.ex:787-845` (lock query `:806-811`) |
| S8 | A per-tenant serialisation row already exists: the audit chain row, held to commit by every audited write | `audit.ex:211-232`; `tenant_provisioning.ex:661` |
| S9 | `audit_legs` immutability: BEFORE UPDATE/DELETE row triggers, fixed exception, inside the tenant-guarded migration. It deliberately has **no TRUNCATE trigger**; so do `lua_script_execution_audit` and the repository tables, because the pooled test-schema reset TRUNCATEs them. No `REVOKE` in any migration | `priv/repo/migrations/20260830020001_create_audit_legs_tenant_scoped.exs:76-110`; `20261015100002_lua_script_audit_read_only.exs:11-13`; `test/support/tenant_template.ex:621-631` |
| S9b | `TenantTemplate`: clones are `CREATE TABLE (LIKE ... INCLUDING ALL)` (no rows); `@seed_tables` is the fixed list `["event_type_registry","schema_migrations","script_policy"]` copied from the live template; `reset_clone_schema!/3` TRUNCATEs exactly the dirty tables and returns `{:error,{:unprovable,_}}` on drift; functions and triggers are re-created with the template-schema qualifier textually replaced by the clone schema | `tenant_template.ex:292, 1343, 1565, 1609-1619, 621-640` |
| S10 | Tenant tables need a migration PLUS a `TenantProvisioning` entry; oracle `expected_tenant_tables/0`; last entry `20261019200001` | `tenant_provisioning.ex:661, 728-731`; `test/letflow/support/tenant_fixture_test.exs:144` |
| S11 | Unique migration version prefixes | `docs/anti-patterns.md:574` |
| S12 | `expected_last_event_global_seq` -> `:record_version_conflict` (409) | `entities/records.ex:59, 577-581` |
| S13 | A client key starting `sys:step:` is refused `:reserved_idempotency_key` | `entities/records.ex:175, 1004-1007` |
| S14 | Exact decimal parser: canonical grammar, scale/precision refused not rounded, floats not accepted | `entities/record/decimals.ex:120-148`; 0060 item 2 |
| S15 | Scan H4 covers HANDLER files derived from manifests and flags every `HandlerWrites` call but `create/3` | `test/letflow/entities/handler_writes_callers_test.exs:21-35` |
| S16 | Forced-overlap harness | `test/support/lock_order_helpers.ex:1-52` |
| S17 | Postgres 16 | `docker-compose.yml:3` |
| S18 | No isolation override (READ COMMITTED) | `lib/letflow/repo.ex`, `config/*.exs` (NOT FOUND any override) |
| S19 | FK on the engine's tables takes `KEY SHARE` on a parent (the #2709 mechanism) | 0061 "Amended (GH #2709, PR-2)" |
| S20 | Scoped types refused for handler writes until 0051 | `handler_writes.ex:30-33`; `gh2590...md:972` |
| S21 | Catalog rule 10: `@handler_keys [:args,:function,:name,:targets]` exact key set; `check_handler_targets_and_code` refuses empty `targets` (`write_handler_no_targets`), targets outside `manages_entity_types`, a handler outside the module namespace; `WriteHandler` struct `[:module_id,:name,:entry_module,:targets,:args]`, `@enforce_keys` all five | `modules/catalog.ex:61-77, 596-690` |
| S22 | `TENANT_ADMIN` holds every tenant-scope permission, Catalog permissions included | `api/authorization.ex:1536-1542` |
| S23 | Decision 0039 D1: "Platform core ... Names no business domain."; D3: boundaries enforced by `mix letflow.check_boundaries` | `0039...md:52-60, 72-`; `lib/mix/tasks/letflow.check_boundaries.ex` rules 0-6 |
| S24 | Decision 0054 "Correction": ledger invariants (balanced transfers, no negative stock under lock) belong in reviewed MODULE code, not in declarative step data | `0054...md:143` |
| S25 | Decision 0040: no per-actor rate limit on authenticated routes | `0040...md:23, 27` |

## 3. Route decision (OQ-1 CLOSED: R-N, advisor letflow-ec ruling)

### 3.1 Constraint set

C1 core names no business domain (0039 D1, enforced by D3's check, S23); C2 ledger invariants live in reviewed module code (0054 Correction, S24); C3 0057 D5: the guard runs "inside the module write handler"; C4 gh2590 F-R5/OQ-R4: the planned route was update-kind handler writes plus a narrow read facade, scheduled for WMS slice 5 (`gh2590...md:199,1073,1094,1099`); C5 the ledger needs a gap-free counter, an atomic multi-leg posting, a guard under ordered row locks and exact quantities; C6 offline fields (0058 c).

### 3.2 Route R-D (REJECTED): entity-type ledger through update-kind handler writes plus a read facade

Shape: header, leg and balance are managed ENTITY TYPES; the handler writes them through `create/3` (header and legs are `append_only` types: update/delete refused at runtime with `entity_append_only`, `0054...md:167`) and a NEW update-kind with a record-version precondition (S12), plus a NEW read facade returning one record under the type's lock.

Needs from REQ-501 housekeeping (all NOT FOUND today): update kind in `Records.command_multi` (it supports only `kind: :create`, `gh2590...md:199`); a read facade and lock rule (handler purity contract, S15); update lines in the `TASK_ENTITY_WRITES_APPLIED` schema (`additionalProperties: false`); engine plan and authorisation of update lines.

Why rejected (the ruling's reason): R-D **cannot give a gap-free queryable `posting_seq`** (the only gap-free number is the header type's per-type sequence number in the event stream, S7; exposing it as a field needs a new core "system field" feature) **and cannot give an atomic multi-leg posting** beyond the 49 creates per handler call and 20 lines per node; the guard serialises on the balance TYPE row tenant-wide (`handler_writes.ex:426-437`), so "item id, then location" row locks (0057 D5) are not expressible; append-only would be Records-layer only (no database trigger exists for entity records); each leg and each balance update costs an event, a projection row and an audit entry. The two core changes that make a neutral primitive justifiable are already accepted: `append_only` entity types (`0054...md:167`) and `non_negative`/`min`/`max` bounds (GH #2532, closed, `0057...md:26`).

### 3.3 Route R-N (ADOPTED): a domain-neutral core posting primitive

A core context `Letflow.Ledger` (directory `lib/letflow/ledger/`) names only **ledger, entry, leg, balance, balance key, counter, quantity**. Dimensions are an OPAQUE ordered tuple of text slots. There is no item, location, stock, warehouse or site vocabulary, no cause list, no hard-coded permission atom and no business CHECK in core. The MODULE registers the ledger in its manifest (new top-level `ledger` key): the ledger id pattern, the slot names, the closed set of CAUSES with their sign rules, the permission atoms (post, reverse, read, reconcile), the optional scope slot, the lateness cap and the policy callbacks. The vocabulary of the issue (`stock_movement`, `stock_balance`, item, location) lives in the stock module's registration, policy data, read views and routes.

**Boundary enforcement (new `check_boundaries` rule, "Rule 7").** Files under `lib/letflow/ledger/**` and the ledger migration may not (a) reference any `lib/letflow/modules/<id>/` file (already refused by the existing edge rules 4/5, S23) and (b) contain, case-insensitively as whole words, any of `stock`, `item`, `location`, `warehouse`, `site`, `lot`, `serial`, `sku`, `material`, `inventory`, `bin`, `pallet`, `:Stock`; the rule is a source-text scan added to `mix letflow.check_boundaries` and mirrored by the ExUnit scan T-SC-2. The list is a reviewed constant; adding a business term to it is a one-line diff.

**Second plausible consumer (0039 D1 test):** a CMMS spare-part store (issues and returns against a non-negative on-hand with gap-free document numbers) or HR leave balances (accrual and usage legs, non-negative balance, reversal by a new entry). Neither is built; both would register a different ledger id, slots and causes with no core change. The primitive is otherwise justified as a platform feature by the two accepted core changes above.

How R-N answers the constraints:

| Constraint | R-N |
|---|---|
| C1 | neutral mechanism like the event store or audit chain; Rule 7 and T-SC-2 |
| C2 (0054 Correction) | The Correction wants ledger invariants in reviewed module code, not declarative step data. R-N keeps that for everything that is BUSINESS: which causes exist, their sign rules, the slot meanings, master validation, unit conversion, who may post, the process route, all registered as reviewed module data and code. The core enforces only the generic MECHANICAL invariants that a create-only handler cannot (append-only, gap-free counter, zero-sum per declared group, non-negative balance, reversal pairing). 0062 records this as a deviation from the letter of the Correction and states that module code still owns the policy. |
| C3 (0057 D5) | met in substance; 0062 amends the wording (the guard runs in the transaction of the handler's step, reached by `HandlerWrites.post/3`, under row locks in a fixed order) |
| C4 (OQ-R4) | **OQ-R4 stays OWED at WMS slice 5 and is NOT replaced**: update-kind handler writes and the read facade are still needed for entity DOCUMENTS (a receipt document's status, quantities received). R-N removes only the LEDGER's dependence on them. |

### 3.4 What the ruling requires of the rest of the note

The note is written for R-N. R-D would have changed sections 4-7 and 12.3; it is not maintained. Unchanged either way: sections 8, 9.2-9.5, 10, 12.2, 13 intent, 16.

## 4. Schema (R-N; first migration)

All tables are per tenant schema (tenancy is the prefix, no `tenant_id`). Delivery: one tenant migration file (or an ordered set) in `priv/repo/migrations/` AND an entry in `TenantProvisioning.tenant_scoped_migrations/0` (S10), `expected_tenant_tables/0` updated in the same PR (4.6), version prefix chosen against open branches (S11). Every trigger and function body qualifies EVERY table name with the schema from `prefix()` (no `search_path`, no unqualified reference), uses no `SECURITY DEFINER` and contains no interpolated tenant data; this is what lets `TenantTemplate` clone them by replacing the template qualifier (S9b); a clone test (T-TT-2) proves the triggers in a clone refuse and name the clone schema. The `down` of the migration raises unless the environment is dev or test (a legal record: a production rollback must be a deliberate new migration). Quantities are `numeric(30,9)` provisionally (OQ-10). No FK from any ledger table to an engine or entity table (D-L11).

Naming map (issue term -> core table -> stock module view/read name): `stock_movement` -> `ledger_entry` -> `stock_movement`; legs -> `ledger_leg` -> `stock_movement_leg`; `stock_balance` -> `ledger_balance` -> `stock_balance`. The module names are views or read-API names defined by the stock module slice (L4), never core tables.

### 4.1 `ledger_counter` (one row per ledger id)

| Column | Type | Rule |
|---|---|---|
| `ledger_id` | text PK | `1..64` bytes; matches the registration's ledger-id pattern (checked in code); one sequence domain: a module registers either one fixed id or a pattern that makes one id per instance (per-warehouse sequences are the scale path, 7.6) |
| `last_seq` | bigint NOT NULL | `CHECK (last_seq >= 0)` |
| `last_chain_hash` | text NOT NULL | hash of the last entry (SEC-10); `''` at start |

**Bootstrap (F3).** There is NO seed row in the migration: ledger ids are data (module registrations), so the row is created lazily by the poster with insert-if-absent (`ON CONFLICT DO NOTHING`, then the locking read), exactly as the sequence-row precedent (S7, `insert_sequence_row_if_absent`). Two first-posters of one ledger race harmlessly: the second insert waits on the first's transaction and then conflicts. This also makes pooled test clones (built with `LIKE`, no rows copied, `@seed_tables` a fixed list, S9b) work with NO change to `@seed_tables`. The BEFORE INSERT trigger allows only `last_seq = 0, last_chain_hash = ''`.

### 4.2 `ledger_entry` (header, append-only)

| Column | Type | Null | Meaning |
|---|---|---|---|
| `id` | uuid PK | no | the **stable operation id** |
| `ledger_id` | text | no | the sequence domain; FK-free reference to `ledger_counter.ledger_id` |
| `posting_seq` | bigint | no | `>= 1`; UNIQUE `(ledger_id, posting_seq)` |
| `cause` | text | no | one of the causes the module REGISTERED (checked in code against the registration); **no core CHECK on the list**: only `CHECK (octet_length(cause) BETWEEN 1 AND 64)`; the cause `reversal` is reserved by core |
| `sign_rule` | text | no | copied from the registration by the poster so the deferred trigger needs no access to code: `CHECK (sign_rule IN ('positive','negative','zero_sum_by_slot_1','any','reversal'))` (a closed MECHANISM vocabulary, not a business list) |
| `reverses_entry_id` | uuid | yes | FK to `ledger_entry(id)`; `CHECK ((cause = 'reversal') = (reverses_entry_id IS NOT NULL))`; UNIQUE partial index where not null |
| `reason_code` | text | yes | `CHECK (octet_length <= 64)`; required non-blank for `reversal` and for causes the registration marks `reason_required` |
| `document_type`, `document_id`, `related_document_id` | text | yes | each `CHECK (octet_length <= 128)` |
| `actor_id`, `subject_id` | uuid | no | event actor and authorisation subject (equal on the HUMAN path) |
| `correlation_id` | text | no | `<= 128` bytes; defaults to the BPM instance id |
| `bpm_instance_id`, `bpm_task_id` | uuid | yes | from `HandlerContext`; no FK (D-L11) |
| `bpm_node_id` | text | yes | `<= 128` bytes |
| `bpm_definition_id`, `bpm_definition_version` | uuid, text | yes | version `<= 64` bytes |
| `event_time` | timestamptz | no | section 8 |
| `posting_time` | timestamptz | no | `clock_timestamp()` read under the counter lock |
| `client_op_id` | text | no | `1..128` bytes; no `sys:` prefix; UNIQUE with `subject_id` |
| `origin_key` | text | no | UNIQUE; `sys:step:<origin>:<line>:<ordinal>` |
| `payload_hash` | text | no | SHA-256 hex over the validated RAW command plus `subject_id` (9.2) |
| `chain_hash` | text | no | SHA-256 hex over `(prev chain_hash, ledger_id, posting_seq, id, payload_hash)`; the previous value is `ledger_counter.last_chain_hash` read under the counter lock |
| `device_id` | text | yes | `<= 64` bytes, `[A-Za-z0-9._:-]`; untrusted metadata |
| `client_seq` | bigint | yes | `>= 0`; both or neither with `device_id`; UNIQUE `(subject_id, device_id, client_seq)` where set |
| `client_event_time` | timestamptz | yes | exactly as reported; allowed only with `device_id` |
| `scope_ref` | text | yes | opaque scope reference copied from the registered scope slot when the registration declares one (OQ-5, 16.2); `<= 128` bytes; not in any balance key |
| `leg_count` | smallint | no | `1..200` |

Also `UNIQUE (id, ledger_id, posting_seq, event_time)`. Indexes: UNIQUE `(ledger_id, posting_seq)`; UNIQUE `(subject_id, client_op_id)`; UNIQUE `origin_key`; `(ledger_id, event_time, posting_seq)`; `(document_type, document_id)`; `(bpm_task_id)`; `(correlation_id)`; the partial uniques.

### 4.3 `ledger_leg` (append-only)

| Column | Type | Null | Meaning |
|---|---|---|---|
| `id` | uuid PK | no | |
| `entry_id`, `ledger_id`, `posting_seq`, `event_time` | uuid, text, bigint, timestamptz | no | composite FK to the header's `UNIQUE (id, ledger_id, posting_seq, event_time)`: the copies cannot differ |
| `leg_no` | smallint | no | 1-based; UNIQUE `(entry_id, leg_no)` |
| `k1` .. `k8` | text COLLATE "C" | no | the balance-key slots, default `''` (none); `k1` and `k2` must be non-empty; each `CHECK (octet_length <= 128)`; canonical form: lowercase UUID text or the module's canonical string, compared as bytes |
| `quantity` | numeric(30,9) | no | signed delta in the base unit; `CHECK (quantity <> 0)` |
| `unit_ref` | text | no | the base unit's opaque reference |
| `attrs` | jsonb | yes | non-key attributes (e.g. an expiry), `CHECK (octet_length(attrs::text) <= 4096)` |
| `document_line_id` | text | yes | `<= 128` bytes |
| (REQ-504 columns) | | | 4.5 |

Indexes: `(ledger_id, k1, k2, posting_seq)` INCLUDE `quantity`; `(ledger_id, k1, k2, event_time, posting_seq)`; `(entry_id, leg_no)`.

### 4.4 `ledger_balance` (derived cache; the only mutable ledger table)

PRIMARY KEY `(ledger_id, k1 .. k8)`; `on_hand numeric(30,9) NOT NULL CHECK (on_hand >= 0)`; `last_posting_seq bigint NOT NULL`; `updated_at timestamptz`. A row is inserted with `on_hand = 0, last_posting_seq = 0` on first touch and never deleted (tombstone rule).

### 4.5 Columns by reference (consequences of R-N for #2658 and #2660)

* **REQ-503 (#2658).** Under R-N the typed nullable dimension columns become **slots**: the module registration lists the slot names in an APPEND-ONLY ordered list (the stock module: `["item","location","status","lot","serial","owner","custodian"]`, at most 8); an unused slot is `''`; adding a dimension registers a new slot name, no DDL and no row rewrite. A dimension that is not a balance-key part (expiry) goes into `attrs`. #2658's AC wording (typed nullable columns, a migration byte-identity test) becomes "slot registration is append-only and a populated ledger is byte-identical after a registration change"; #2658 must be aligned (cross-note finding, OQ-16).
* **REQ-504 (#2660).** `quantity_original numeric(30,9)` (signed), `original_unit_ref text`, `conversion_factor numeric`, a tolerance-evidence reference: nullable on `ledger_leg`; the conversion itself is module policy (14.4).
* Comparator (F16): byte comparison of the slot texts (`COLLATE "C"` in SQL, binary comparison in Elixir), `''` the sentinel, UUID slots lowercase canonical text. Slot order is the lock order: slot 1, slot 2, ... (for the stock module: item, then location, as in 0057 D5). The slot list is append-only; reordering or removing a slot is refused by the Catalog (rule 11, 14.3).

### 4.6 Tenant export, restore, delete and the table-set oracle

* **Table-set oracle:** `TenantFixture.expected_tenant_tables/0` (`test/support/tenant_fixture.ex:133, 862`; the list holds `audit_chain_locks` at `:141`) gains the four names in the L1 PR; the replay test (`tasks_scope_node_id_migration_test.exs:152` style) asserts the table set equals the oracle.
* **Provisioning:** the migration is registered in `TenantProvisioning.tenant_scoped_migrations/0` (`tenant_provisioning.ex:728-731`), so a new tenant, a replayed tenant and a sandbox schema all get the tables.
* **Delete:** the only schema removal found is the sandbox pool's `DROP SCHEMA ... CASCADE` (`sandbox_pool.ex:1004-1026`); DROP does not fire the row or TRUNCATE triggers, so deleting a sandbox is unaffected. A production TENANT delete path: NOT FOUND.
* **Export and restore:** a tenant export/restore mechanism is NOT FOUND in `lib/`; decision 0057 D19 (`0057...md:68`) plans an export package ("documents and audit"). Requirement carried to that work: the ledger (`ledger_entry`, `ledger_leg`, the `chain_hash` column) is part of the package; a restore is whole-schema (counter, entries, legs, balances together) so the counter, the chain and the balances stay consistent; a partial restore of a ledger table is forbidden; after any restore `reconcile/3` must report clean before the tenant is unfrozen. Purge of ledger rows is never offered (D19: purge only on written request and after retention allows; for the ledger, by dropping the whole schema).

## 5. Append-only enforcement

### 5.1 Decision: database level, a tripwire plus a single writer

The handler path alone is not a sufficient guarantee for a legal record; the repository precedent for such a record is the database trigger (S9). Decision 0054 option A (managed types) and the R2 stamp protect entity types and definitions, not these tables. The triggers are a **TRIPWIRE against bugs and accidents, not a security boundary**: the application connects as the table owner, which can disable triggers.

1. **Triggers** on `ledger_entry` and `ledger_leg`: BEFORE UPDATE and BEFORE DELETE (row) raising one fixed text, and **BEFORE TRUNCATE (statement)** raising the same (added on the advisor's instruction; the precedent tables omit it because the pooled test reset needs TRUNCATE, S9 - resolved in 5.4).
2. **Structural constraints** (section 4) and the deferred checks (5.3).
3. **Single writer scans** (T-SC-1/2/3) and the process token (16.4).

Residuals, stated: the table owner can `ALTER TABLE ... DISABLE TRIGGER`; a superuser can set `session_replication_role = replica`; `REVOKE` is not used (no REVOKE in any migration, S9). **Tamper evidence** (SEC-10): `ledger_entry.chain_hash` and `ledger_counter.last_chain_hash` form a hash chain per ledger id over `(ledger_id, posting_seq, id, payload_hash)`, serialised for free by the counter lock; `reconcile/3` verifies it. The chain is in the FIRST migration because an append-only table cannot be back-filled. It detects, not prevents, tampering by the owner. 0062 records both residuals.

### 5.2 Trigger rules

| Table | Trigger | Rule |
|---|---|---|
| entry, leg | BEFORE UPDATE, DELETE (row), TRUNCATE (statement) | raise the fixed text |
| counter | BEFORE UPDATE | `NEW.last_seq = OLD.last_seq + 1`, `ledger_id` unchanged |
| counter | BEFORE INSERT | `last_seq = 0` and `last_chain_hash = ''` only |
| counter | BEFORE DELETE, TRUNCATE | raise |
| entry | BEFORE INSERT | `NEW.posting_seq` equals the CURRENT `last_seq` of the counter row of `NEW.ledger_id` (the number must have been allocated by this transaction); when `reverses_entry_id` is set, the target exists, has the same `ledger_id`, and its own `reverses_entry_id` IS NULL |
| balance | BEFORE INSERT | `on_hand = 0` and `last_posting_seq = 0` |
| balance | BEFORE UPDATE | key columns immutable; if `on_hand` changes then `NEW.last_posting_seq` equals the counter's current `last_seq` for the row's `ledger_id`; no DELETE/TRUNCATE. This proves the change happened in a transaction that already holds the allocated number; it does NOT prove the change came from the poster (a session with UPDATE rights could set both), which is why reconciliation exists. |

### 5.3 Deferred constraint triggers (at COMMIT)

| On | Rule |
|---|---|
| counter AFTER UPDATE, `DEFERRABLE INITIALLY DEFERRED` | an entry with `(ledger_id, posting_seq) = (NEW.ledger_id, NEW.last_seq)` exists |
| entry AFTER INSERT, `DEFERRABLE INITIALLY DEFERRED` (once per header) | (i) the number of legs equals `leg_count`; (ii) the legs obey the header's `sign_rule`: `positive` all quantities > 0, `negative` all < 0, `zero_sum_by_slot_1` the quantities sum to zero per distinct `k1`, `any` none; (iii) for `reversal`, per balance key the legs of this entry and of the target sum to zero and the key sets are equal |

The mechanism vocabulary is closed and neutral; WHICH cause uses WHICH rule is module data.

### 5.4 Pooled test schemas (TenantTemplate): the reset conflict, resolved

Facts (S9b): `reset_clone_schema!/3` TRUNCATEs exactly the dirty tables plus the closure of FK-referencing tables (no CASCADE), re-copies `@seed_tables`, and its moduledoc states there is no BEFORE TRUNCATE trigger (`tenant_template.ex:621-631`); clones are `CREATE TABLE (LIKE ... INCLUDING ALL)` with no rows (`:1343`). With the new triggers a reset of a dirty ledger table would raise.

Chosen mechanism (recorded for 0062): **ledger tables are unresettable.** `TenantTemplate` gets a fixed list `@append_only_tables = ["ledger_entry","ledger_leg","ledger_counter","ledger_balance"]`; when its probe finds ANY of them dirty, `reset_clone_schema!` returns `{:error, {:unprovable, [:append_only_table_dirty]}}` BEFORE any DML, and the caller rebuilds the slot with the existing `rebuild_clone_schema!/1` (no repair in place, as for drift). The counter bootstrap needs no `@seed_tables` change (4.1: lazily created; a seed row would be dirtied by every posting and cannot be deleted). Rejected: a GUC-controlled TRUNCATE bypass inside the trigger (weakens the guard for every tenant, since any raw SQL session can set a GUC); omitting the TRUNCATE trigger (the precedent; leaves TRUNCATE open, against the advisor's instruction). Cost: every test module that posts rebuilds its slot afterwards; ledger tests are few and `async: false`. Tests: T-TT-1 (a dirty ledger slot is `unprovable` and rebuilt; a clean slot untouched), T-TT-2 (triggers in a clone refuse and name the clone schema).

## 6. The gap-free sequence

### 6.1 Mechanism

Two counter statements, both after every balance row is locked and the guard has passed (steps 8 and 9 of 7.1), on the ONE counter row of the posting's `ledger_id` (a posting touches exactly one ledger id): (1) a locking read of that row, Ecto `lock: "FOR UPDATE"` composition exactly as the sequence-row precedent (`event_store.ex:806-811`, S7), which waits for the previous holder and returns the latest committed `last_seq` and `last_chain_hash`; (2) after the idempotency re-check under that lock, an Ecto `update_all` with `inc: [last_seq: 1]` and a `select` of the new value (`UPDATE ... SET last_seq = last_seq + 1 ... RETURNING`; no SQL string, INV-7) that also sets `last_chain_hash`, with the tenant `prefix:` option. The lock is held to the end of the transaction. NOT a Postgres SEQUENCE (`nextval` is not transactional: a rollback burns the number) and not `max + 1`. READ COMMITTED is assumed (S18): after waiting, `FOR UPDATE` returns the latest committed version; under REPEATABLE READ the read would raise a serialization failure instead of producing a gap; a test pins the isolation level. A duplicate found by the re-check returns WITHOUT the UPDATE.

### 6.2 Proof of gap-freeness

Claim G1: for each ledger id, the committed `posting_seq` values are exactly `1..M` for all time (everything below is per ledger id). Claim G2: every snapshot sees a prefix `1..n`.

Facts (each enforced above): F1 the only writer of `last_seq` is the posting UPDATE, +1 (trigger 5.2); F2 a header's `posting_seq` equals the counter value current in its transaction (trigger 5.2) and a transaction that bumps the counter cannot commit without a header of that number (deferred trigger 5.3); F3 the counter row lock is held to commit or rollback; F4 a rolled-back transaction leaves the counter as it was (MVCC); F5 PostgreSQL makes a commit visible to new snapshots (ProcArray removal) BEFORE it releases the transaction's locks (argued from PostgreSQL commit internals, not run here); F6 a transaction that finds a duplicate under the lock does not run the UPDATE.

Proof of G1: induction over the transactions in the order they acquired the counter lock. By F3 the order is total and non-overlapping: `Tk` acquires the lock only after the previous holder committed, rolled back or took the duplicate path. Let `c(k)` be the committed `last_seq` before `Tk`: unchanged if the previous holder rolled back or took the duplicate path (F4, F6), `+1` if it committed an UPDATE (F1). `Tk` reads `c(k)`, writes `c(k)+1` and, if it commits, commits a header numbered `c(k)+1` (F2). So committed numbers are `1,2,3,...` in lock order, none skipped, none reused. QED. Proof of G2: `Tk` is visible to new snapshots (F5) before `T(k+1)` can take the lock.

Two concurrent postings (counter at 41):

| Step | T1 | T2 | Counter | Outcome |
|---|---|---|---|---|
| a | locks its balance rows, passes the guard | locks its (different) rows, passes the guard | 41 | no conflict |
| b | counter `FOR UPDATE` then `UPDATE` -> 42 | counter `FOR UPDATE` blocks | 42 (T1) | T2 queues |
| c1 | inserts posting 42 and legs, commits | wakes, reads 42, writes 43 | 42, 43 | commits 42, 43 |
| c2 | fails after (b) and ROLLS BACK | wakes, reads 41, writes 42 | 41, 42 | T2 commits 42, **no gap, 42 reused** |
| d | same `(subject, client_op_id)` as T2 | re-checks after the lock (step 8), finds T1's committed header | 42 | T2 posts nothing, no UPDATE |

### 6.3 Reader contract

A report takes `N` and its rows in ONE snapshot (a single statement/CTE, or one `REPEATABLE READ READ ONLY` transaction); `N` is `max(posting_seq)` of that snapshot or a caller number `<= max`; above the counter it is refused `cutoff_in_future`. By G2 a report at `N` run later returns the same rows.

## 7. Lock order

### 7.1 The posting algorithm (normative; ONE posting per transaction, one ledger id per posting)

Inputs: the validated command (9.1) and the `HandlerContext`. Every statement uses the tenant `prefix:` option and bound parameters.

1. **Shape, token, origin (no lock).** The process token of the handler call is verified by `Letflow.Ledger.post/2` itself (16.4); the command's closed shape is checked; the transaction-scoped posting counter (7.4) must be zero; the origin must be `{:task, _}`, else the typed refusal `:ledger_origin_not_supported` (D-L12).
2. **Authority (no lock).** The subject's roles are read from the DATABASE in this transaction and must include one holding the registration's `post` permission (`reverse` for a reversal), 16.2; a subject with any scoped (not tenant-wide) role grant is REFUSED, fail-closed (16.2).
3. **Facts and declaration (before ANY ledger lock; no lock at all is taken by it).** The module's optional `gather_facts` callback (lock-free reads through the module's read API, under the transaction's `statement_timeout`) and then its PURE `declare` callback (14.4) produce the declarative posting: ledger id, cause, legs (slot values, quantity, unit, attrs), reason, document ids. The core then checks the GENERIC rules against the registration: ledger id matches the pattern, cause is registered, sign rule, leg count, slot count, canonical decimals (never rounded), caps. Neither callback runs under a ledger row lock (running module code under row locks is the rejected 0054 option B, `0054...md:45`); they do run after the engine locks the transaction already holds (class 1-5), because the handler call executes there (running them in the pre-transaction plan phase is OQ-17, default no).
4. **Idempotency pre-check (lock-free).** Lookup by `(subject_id, client_op_id)` and by `origin_key`: same `payload_hash` returns the duplicate result and stops; a different hash, or the two keys matching DIFFERENT entries, returns `idempotency_key_reuse`; a `(subject_id, device_id, client_seq)` held by a different `client_op_id` returns `client_seq_conflict`.
5. **Reversal derivation (no lock; immutable data).** For `cause = reversal`: read the target entry; absent, other ledger id or not visible -> `validation_failed` reason `movement_not_found`; target is itself a reversal -> `posting_is_reversal`; derive the negated legs from the target's legs.
6. **Balance rows: insert, then lock, both ascending.** Compute the DISTINCT balance keys; sort ASCENDING by `(k1 .. k8)` byte-wise. (6a) For every key in that order: insert-if-absent with `ON CONFLICT DO NOTHING` (so every missing row exists before any is locked, in the same order as the locks). (6b) For every key in that order: `SELECT ... FOR UPDATE` returning `on_hand`. One key at a time.
7. **Guard, and the reversal re-check under the key locks.** For a reversal, re-read whether a reversal of the target now exists (the first of two concurrent reversals commits before the second gets the shared key locks): found -> `posting_already_reversed`. For every key `on_hand + sum(delta) >= 0`, else `insufficient_stock` (12.2); nothing written, counter untouched.
8. **Counter lock and idempotency re-check.** Insert-if-absent of the counter row of the ledger id, then the locking read of 6.1 (the LAST ledger lock). Re-read the two keys: found -> duplicate result (same hash) or `idempotency_key_reuse`, with NO write and NO UPDATE.
9. **Number and writes.** The counter UPDATE (6.1); `posting_time = clock_timestamp()` read now; compute `chain_hash`; insert the header, the legs, then `UPDATE ledger_balance` per key (`on_hand + delta`, `last_posting_seq = posting_seq`).
10. **Return** `{:ok, %{entry_id, ledger_id, posting_seq, duplicate: false}}`. The audit entry and events are the engine tail's (7.7, 14.5).

### 7.2 Position in decision 0061's order, and why

Decision 0061 rule 1 (`0061...md:13-21`): (1) instance tasks/dispatch rows, (2) `P_x`, (3) ancestor group, (4) own tokens, (5) entity-type rows ascending, (6) the tenant audit chain row, (7) sequence rows, (8) projection UPDATEs; 0061 "Amended (GH #2707, PR-1)" item 1 places the instance's own `timers` rows after class 5 and before class 6, touched only while `P_x` is held.

The ledger is **class 5b: after 5, before 6** (internally: balance rows ascending, then the counter row of the ledger id). Why this cannot cross any other class: on the HUMAN path the handler runs after the type locks (S3) and everything after it is the TAIL: `:cancel_escalation_timers` and `:cancel_reminder_timers` (`engine.ex:7350, 7365`), token reconcile, task activation, audit rows (class 6), events and sequence rows (7), projection UPDATEs (8) (S3b). Every row of the tail classes is either (a) instance-own and touched only while THIS transaction holds `P_x` (timers, tokens, sequence rows, projection), so no other transaction can hold one while waiting for a ledger row (it would have to hold `P_x` of this instance, which this transaction holds), or (b) newly inserted by this transaction, or (c) the tenant-wide audit chain row, which a ledger-posting transaction takes only AFTER its ledger rows and which a non-ledger transaction holds without ever waiting for a ledger row. The 0061 amendment text (section 15) names the timers.

### 7.3 Why it cannot deadlock

* Ledger vs ledger: every posting takes keys ascending then the counter; the counter holder takes no further ledger lock (it updates rows it already holds); a cycle would need a counter holder waiting for a ledger row it does not hold, impossible. Opposite item order `[(A,B)]`/`[(B,A)]` both sort to `A,B`.
* **The counter holder DOES wait for rows later in the transaction** (the tail: audit chain row, sequence rows, projection). Deadlock-freedom there rests on 7.2: nothing that holds a tail row ever waits for a ledger row.
* The insert-if-absent of a missing balance row waits on the inserting transaction in the same ascending order.
* No FK from the ledger to engine tables (D-L11, S19).
* **One posting per transaction (7.4).**

### 7.4 Why more than one posting per transaction is forbidden (BLOCKER F2)

A node may declare up to 20 `module_writes` lines, each a handler call, and `post/3` could be called once per line. Posting #2 would take balance rows AFTER posting #1 holds the counter: T1 holds the counter and wants key `y`, T2 holds `y` and wants the counter -> a cycle. Rule: **at most ONE `post/3` per transaction**, enforced by a transaction-scoped token (a per-transaction marker created by the engine's step context and checked and set by `Letflow.Ledger.post/3` at step 1; a second call returns the closed error `:too_many_postings`, which `HandlerWrites.post/3` returns to the handler and the build turns into a failing step), plus a limit of 200 legs per posting. Test T-LK-5 (two lines both posting, forced overlap with an opposite-key poster: the second call is refused at build, no deadlock). A multi-leg business operation is ONE posting with many legs.

### 7.5 The SERVICE_TASK hazard (why L1-L4 refuse the service origin)

On the service apply the order is `:lock_ancestors`, `{:pre_type_lock,_}`, then tokens and task activation whose `task.create` audit takes the audit chain row **A**, then the handler calls (S4). A posting there takes balance rows and the counter AFTER **A**. Interleaving: a HUMAN posting `Th` holds `B(x)` and the counter and wants **A** for its tail audit; a service apply `Ts` holds **A** and wants `B(x)`: a real cycle (derived by reading, not run). `post/3` refuses `{:dispatch, _}` with the TYPED refusal `:ledger_origin_not_supported` (surfaced as `write_not_permitted`, and as ERROR + DLQ on the service path). Lifting it needs a later 0061 amendment (ledger lock-only pre-steps before the task-activation audit) and its own forced-overlap tests.

Consequence (F20): **automated and integration postings are excluded from L1-L4**: no script-bound or HTTP SERVICE_TASK, scheduled adjustment, or ERP/1C-driven posting can use the ledger until L5. Conditions for lifting (SEC-12): (a) the ledger rows are taken as lock-only pre-steps BEFORE the task-activation audit, with balance keys resolvable at plan time (NOT VERIFIED that service-path arguments are); (b) the subject's roles are re-resolved from the database at run time and the platform sentinel never holds the post permission (the activator's roles are the subject); (c) when script-produced variables feed legs, activation requires an explicit consent flag on the node recorded with `activated_by`; (d) the cycle test T-LK-4 inverted.

### 7.6 Deadlock and timeout behaviour

| Event | Result |
|---|---|
| `55P03` (the plan's `lock_timeout 2s`, S5), `40P01`, `57014` (`statement_timeout` 5 s) | rollback; nothing committed, no number consumed; mapped to 503 `entity_write_contention`, `line_index: null` (`engine.ex:2925`, `tasks.ex:456-463`). No new code. |
| a `23514` on `on_hand >= 0` after the guard passed | the race the guard should have closed: `insufficient_stock` with `details` of 12.2 (reversal: only `leg_no` and count), logged as a defect-class counter with no values |

Hot item/counter: FIFO behind the holder for at most 2 s then 503; holder bounded by 5 s statement and 10 s wall guard (`gh2590...md:749-750`). Bounds: 200 legs per posting, 1 posting per transaction, 20 lines per node.

**Throughput (F18).** The counter is held from step 8 to the END of the surrounding transaction, i.e. through the engine tail, and a ledger transaction also waits behind the tenant-wide audit-chain row (S8): the hold is not "the shortest suffix", it is the tail. One authenticated actor can occupy the convoy with sequential completions; decision 0040 records that there is NO per-actor rate limit (S25), so the only bounds are the lock timeout (2 s -> 503) and the posting caps. Pilot exit criterion for T-LD-1: with 4 concurrent workers on ONE tenant, at least **20 postings/s sustained for 60 s, p95 completion latency under 500 ms, contention 503 rate under 1%**; if the customer's NF-01 peak (lines/s) is declared higher, the criterion is 2x that figure. Failing it triggers OQ-2. Accepted for release 1: postings of one ledger id serialise across the tenant. The recorded scale path is **per-ledger-instance sequences**: a module that registers a ledger id pattern per warehouse gets one counter row, one gap-free sequence and one cut-off number per warehouse, with no core change (a transfer between two warehouses then needs two postings or a shared ledger id, a module decision).

### 7.7 The audit entry per posting (`ledger.posted`)

One audit chain entry `ledger.posted` per NON-duplicate posting, with ids only: `entry_id`, `ledger_id`, `posting_seq`, `cause`, `leg_count`, the actor; no quantity, no slot value, no free text. It is appended by the ENGINE TAIL beside the per-line entity-write audits (`append_entity_write_audits`, `engine.ex:3330`, action `entity_write.process_step` at `:3334`), built from the `:ledger_post` step result in `changes`, not by the ledger step itself. Consistency with the lock order: the audit chain row (class 6) is therefore taken in the tail, AFTER the counter row (class 5b), exactly as 0061 requires; taking it inside the ledger step would put class 6 before the tail's timer rows (benign by 7.2 (a) but a needless departure from the written order). A refused or duplicate posting writes no `ledger.posted`; refusals keep the existing best-effort refusal audit (12.3).

## 8. Time basis, late movements (G7) and reports

### 8.1 Event time of a late-synchronised movement

* `client_event_time` is stored exactly as reported (null online); it is accepted only together with `device_id` (a device that queues work). Online postings use `event_time = posting_time` and a `client_event_time` without `device_id` is `invalid_posting`.
* `event_time = client_event_time` when present, else `posting_time`; NEVER overwritten by the posting time (0058 b: facts accepted late, client event time kept).
* `posting_time = clock_timestamp()` read under the counter lock (single database clock). It is informational and can in principle regress (clock step); `posting_seq` alone orders.
* Timestamps are parsed strictly: ISO-8601 with explicit offset or `Z`, microsecond precision, years 2000-2100; `infinity`, `-infinity`, out-of-range and offset-less values are `invalid_posting`.
* The guard is evaluated at POSTING time against current balances (a late issue negative as of its event time but positive now posts; negative now -> `insufficient_stock`, 0058 b).

### 8.2 Two bases, both reproducible

| Basis | Predicate | Property |
|---|---|---|
| as-posted (default) | `posting_seq <= N` | immutable and reproducible (G2); a late movement has `posting_seq > N` |
| as-of event time | `event_time <= T AND posting_seq <= N` | the pair `(T, N)` reproduces a published report; with a larger `N` it includes late arrivals ("appears in the appropriate period", MD-09) |

Event time WITHOUT `N` is not offered (it would rewrite a published balance).

### 8.3 DECISION D-T: the lateness cap (OQ-15 decided)

Rule: `event_time` may be earlier than `posting_time` by at most **4 days** (`max_event_lateness`, default 96 hours, configuration key under the ledger registration, platform default), and later than `posting_time` by at most 5 minutes (skew). Beyond either, the posting is refused `event_time_too_old` (422) or `event_time_in_future` (422), nothing written.

Reasoning: (a) the offline lease is the maximum outage, default 3 days (0058 (a), 0057 D13); a fact captured at the start of the longest permitted outage must still be postable on reconnection; (b) one day of margin covers synchronisation delay and a device clock set to local time; (c) international practice in ERP inventory ledgers is that backdating is bounded by an OPEN POSTING PERIOD, and that period control is a configured window (SAP MM posting-period control opens the current and previous period; Dynamics 365 inventory close/`inventory closing` prevents posting before the last closing date): the cap is the minimal stand-in for a period window, since period close is out of scope here (no closing exists); (d) a cap with no value would let any actor with the post permission backdate unboundedly, which defeats "published balances are not silently rewritten"; (e) it cannot rewrite a published as-posted report anyway (G2), it only bounds how far an event-time report can move. A longer window is a tenant configuration change by a platform operator, recorded in the audit chain; period close is a later requirement. Recorded for 0062.

### 8.4 What every report states (CS-01 :117)

`basis`, `cutoff_seq` (`N`), `as_of` (`T` or null), `timezone` (tenant timezone used for period boundaries; storage UTC), `filters`, `ledger_seq` (counter value in the snapshot). Opening + period receipts - issues and adjustments = closing, by construction (all sums over the same legs under one basis; T-RP-3).

## 9. Commands, idempotency, offline fields, versions, tombstones

### 9.1 The posting command (closed map)

`cause`, `legs` (list of `%{k: [slot texts], quantity (decimal string or integer, never a float), unit_ref, attrs, document_line_id}`), `reason_code`, `document_type`, `document_id`, `related_document_id`, `correlation_id`, and the offline fields **`client_op_id` (required)**, `device_id`, `client_seq`, `client_event_time` (0058 c.1). For `reversal`: `reverses_entry_id` and `reason_code`, no legs. Unknown keys, floats, non-canonical decimals or more than 9 fractional digits (never rounded) are `invalid_posting`. The encoded command is capped at 256 KiB.

How the offline fields reach the handler (F17): they are fields of the TASK COMPLETION request's variables (the same body that carries form values), mapped to the handler's declared `var` arguments (`gh2590...md` D-R.4: args are resolved values only); they are never taken from headers. `client_op_id` is a required handler argument, generated by the client UI for an online posting too; `device_id`, `client_seq`, `client_event_time` are omitted online and left null. `expected_document_version` is optional in the command and **required exactly when the command names a `document_id` whose type the module marks versioned** (policy rule, 9.4).

### 9.2 Idempotency and the payload hash

`payload_hash` = SHA-256 over the canonical, key-sorted JSON of the VALIDATED RAW command (the client-supplied fields after closed-shape check and decimal canonicalisation, BEFORE any master-data normalisation, so a later master change cannot turn a replay into a different payload) PLUS `subject_id`. Keys are scoped per actor: `UNIQUE (subject_id, client_op_id)` (SEC-5): another actor's identical `client_op_id` is a different key and posts independently, so no existence oracle exists across actors; the same actor with the same key and a different hash gets `idempotency_key_reuse`.

| Situation | Result |
|---|---|
| neither key seen | post |
| `(subject, client_op_id)` seen, same hash | `{:ok, %{entry_id: existing, posting_seq: existing, duplicate: true}}`, nothing written |
| seen, different hash | `idempotency_key_reuse` (409) |
| `client_op_id` and `origin_key` match DIFFERENT headers | `idempotency_key_reuse` (409) |
| `client_op_id` starting `sys:` | refused (S13) |

The decision is made in two places (7.1 step 4 lock-free, step 8 under the counter lock); the unique indexes are the backstop (a `23505` maps to `idempotency_key_reuse` without revealing the other row).

### 9.3 Offline `client_seq` (F8)

`UNIQUE (subject_id, device_id, client_seq)`. A `(device_id, client_seq)` already held by a DIFFERENT `client_op_id` is `client_seq_conflict` (409), found by the pre-check (7.1 step 4) and backed by a `23505` mapping. **Out-of-order acceptance is intended**: the ledger does not reject a lower `client_seq` than a previous one; "per-device monotonic" (0058 c.1) is a property the DEVICE guarantees and the replayer (REQ-480) uses to apply commands in order. `device_id`, `client_seq` and `client_event_time` are untrusted metadata: never used for ordering, cut-off or authorisation; `device_id` is length- and charset-bounded.

### 9.4 `expected_version` (0058 c.2)

The ledger has no client-mutable resource (legs/postings immutable, balance/counter platform-written). The criterion is met by: (a) `expected_document_version` against a mutable entity record (its `last_event_global_seq`), compared by the policy, mismatch -> `record_version_conflict` (S12); (b) a reversal's precondition is "not yet reversed" -> `posting_already_reversed`; (c) entity masters keep `expected_last_event_global_seq`.

### 9.5 Retire/cancel is a tombstone (0058 c.7)

No ledger row is ever deleted (5.2); a zero balance row stays; cancelling a posting is a reversal. A retired master (`active=false`) blocks only STOCK-ADDING legs (positive quantity) with `master_inactive`; stock-removing legs and reversals are always allowed so stock can be drained (test T-RT-1). Facts already true (0058 b) are REQ-480.

## 10. Reversal

* A reversal is a NEW posting, `cause = reversal`, `reverses_entry_id = target`, legs = the exact negation of the target's (same keys, unit, original quantity negated), `reason_code` required, its own `event_time` (never the target's: a correction never rewrites a closed cut-off, MD-09), own `posting_seq`; `document_id` and `correlation_id` default to the target's.
* Refused: unknown/malformed/not-visible target -> `validation_failed` reason `movement_not_found` (one body); target already reversed -> `posting_already_reversed` (409); target is itself a reversal -> `posting_is_reversal` (409) (both readings of "reversal of a reversed header").
* Concurrency and where the checks sit: 7.1 steps 5 (target exists, is not a reversal, derive negated legs), 6 (key locks), 7 (re-read "already reversed" AFTER the key locks, BEFORE the counter lock); two concurrent reversals of one header share every key, so the second re-reads after the first commits. The partial unique index is the backstop.
* The guard applies. Reversing a receipt whose stock was partly issued is `insufficient_stock`; for a reversal the `details` carry ONLY `leg_no` and the count, never the target's contents (SEC-7). Residual (documented): a caller allowed to post can learn "enough/not enough" for a key by probing; the guard is an oracle by nature; the exact `available` is permission-gated (12.2).
* No partial reversal; permission is the registration's `reverse` atom.

## 11. `ledger_balance` and reconciliation

### 11.1 Maintenance

Updated only by `Letflow.Ledger.post` in step 9, after the guard, under the held row lock, in the same transaction. Invariant I-BAL: `on_hand` after posting `n` equals the sum of the key's legs with `posting_seq <= n`. Read only inside the guard.

### 11.2 `reconcile/3`

A `REPEATABLE READ READ ONLY` snapshot under a `statement_timeout`, **mandatorily chunked by key cursor** (a page cap), with a **concurrency cap** (one reconcile per tenant at a time, a second returns `reconcile_busy`): FULL OUTER JOIN of `ledger_balance` with the grouped entry sums per key, reporting every differing or missing key; plus the sequence check `count = max(posting_seq) = counter.last_seq` and the hash-chain check. Result: `%{checked_through_seq, mismatches: [%{key, balance, ledger_sum}], gap_check, chain_check}`. It repairs nothing (OQ-9). The registration's `reconcile` permission. Cut-off reports have the same statement timeout and page cap (SEC-9).

## 12. Errors (typed, closed, machine-readable)

### 12.1 Envelope

The refusal body `{"error": code, "line_index": n}` (S6) gains an optional `"details"` ONLY for the codes of 12.2; every other code keeps its exact bytes (golden test over all existing codes). `details` holds ids and closed enums, never free text or exception text. `Response.entity_write_status/1` (`api/response.ex:311-314`) gains 409 rows.

### 12.2 Codes

| Code | HTTP | When | `details` |
|---|---|---|---|
| `insufficient_stock` | 409 | step 7 or the CHECK backstop | `{"legs": [{"leg_no", "k": [...slots], "requested", "available"?}]}`; `available` only with the registration's `read` permission; for a REVERSAL: `{"leg_nos": [...], "count": n}` only |
| `posting_not_balanced` | 409 | sign rule `zero_sum_by_slot_1` violated (before any lock) | `{"k1": [...]}` |
| `posting_already_reversed` | 409 | 10 | `{"entry_id"}` (the caller named it) |
| `posting_is_reversal` | 409 | 10 | `{"entry_id"}` |
| `idempotency_key_reuse` | 409 | 9.2 | `{}` |
| `client_seq_conflict` | 409 | 9.3 | `{}` |
| `record_version_conflict` | 409 | 9.4 (existing code) | as today |
| `master_inactive` | 409 | 9.5 | `{"slot": name, "leg_no": n}` |
| `event_time_in_future`, `event_time_too_old` | 422 | 8.3 | `{}` |
| `invalid_posting` | 422 | shape, float, scale, sign, caps, strict timestamp | `{"leg_no": n|null, "reason": <closed enum>}` |
| `validation_failed` reason `movement_not_found` | 422 | reversal target | `{"reason": "movement_not_found"}` |
| `write_not_permitted` | 403 | no permission, wrong origin, stamp failure, `:too_many_postings` at activation-visible level | none |
| `entity_write_contention` | 503 | 7.6 | none |
| duplicate | success | 9.2 | result `duplicate: true` |

### 12.3 The failure channel for `details` (F6)

Today `EntityPort.failure` is `{:refused, index, code, detail_atom}` and the engine returns the 3-tuple `{:entity_write_refused, index, code}` (S6b). New, additive:

```
# engine/entity_port.ex failure union gains:
{:refused_detailed, index :: non_neg_integer(), code :: atom(), detail :: atom(), details :: map()}
# the engine result gains a DISTINCT 4-tuple (the 3-tuple is untouched):
{:error, {:entity_write_refused_detailed, index :: non_neg_integer(), code :: atom(), details :: map()}}
```

Producer: `StepWrites.interpret_failure/2` (`step_writes.ex:944`) maps a failed `{:line, key, :ledger_post}` whose reason is `{:ledger_refused, code, details}`. Engine: one new clause in `interpret_complete_result/3` (`engine.ex:8440-8462`) beside `{:refused, ...}` that writes the best-effort refusal audit (same function, same shape: ids + the closed `detail` atom ONLY, never the `details` map, so no quantity, no slot value reaches the audit chain) and returns the 4-tuple. Pattern sites to touch: `engine.ex:2549` (type), `engine.ex:8461-8462` (producer), `routers/tasks.ex:456-463` (new clause BEFORE the generic one, rendering `Response.entity_write_refused/4`), `engine/service_task_dispatcher.ex:667` and `engine/script_task_dispatcher.ex:107` (classify the 4-tuple as `:entity_write_refused`; unreachable in L1-L4 because the service origin is refused, but exhaustive). Sites matching only `{:entity_write_refused, :contention, _}` (`engine.ex:5695, 5737, 6008, 6045`) and the Records-level tuples (`records.ex:828-876`) are unchanged. Golden tests T-ERR-2: every existing 3-tuple consumer yields byte-identical results for every existing code; the 4-tuple yields the exact envelope.

## 13. Test plan

New files, `async: false`; concurrency ones in Sandbox `:auto` with real commits in the style of `Letflow.LockOrderHelpers` (S16). The posting identifiers use the module-neutral core names; the WMS-level assertions are made through a test registration (a fixture module), because core has no stock vocabulary.

| Id | File | Case |
|---|---|---|
| T-AC1 | `ledger/post_balance_test.exs` | a `zero_sum_by_slot_1` posting whose legs do not sum to zero per slot 1 is refused `posting_not_balanced` before any lock, counter unchanged; a balanced one posts; a `positive` kind with a negative entry and a `negative` kind with a positive entry are `invalid_posting` |
| T-AC2 | `ledger/concurrent_no_negative_test.exs` | on hand 10; two concurrent `negative` postings of 6 in forced overlap (barrier row on the balance key): EXACTLY ONE posts, the other `insufficient_stock` with `details.legs[0]`; balance 4; counter advanced by exactly 1 |
| T-AC3 | `ledger/reversal_test.exs` | reversal of a reversed posting -> `posting_already_reversed`; reversal of a reversal -> `posting_is_reversal`; reversal of a partly-consumed receipt -> `insufficient_stock` with only `leg_nos`/count; two concurrent reversals of one posting: one wins; unknown/malformed id -> the one `movement_not_found` body; a caller WITHOUT the read permission gets no `available` and no target content |
| T-AC4 | `ledger/cutoff_test.exs` | after N=3 record the as-posted report; post more incl. a late one with an earlier `event_time`: the as-posted report at N=3 is byte-identical, the event-time report `(T, N=3)` identical, `(T, N=7)` includes the late one; the report carries basis, cutoff, tz, ledger_seq |
| T-AC5 | `ledger/balance_reconcile_test.exs` | property (StreamData): after every posting/reversal `ledger_balance == SUM(legs)` per key; then a deliberately corrupted balance, made by a plain `UPDATE ledger_balance SET on_hand = ..., last_posting_seq = <counter>` (allowed by the trigger because the balance table is mutable; **no superuser and no `session_replication_role` needed**), is reported by `reconcile/3` with key, balance and ledger sum |
| T-AC6 | `ledger/idempotency_test.exs` | same `(subject, client_op_id)` and payload twice: one header, same `entry_id`, `duplicate: true`, counter advanced once; same key different payload -> `idempotency_key_reuse`; `sys:` key refused; two concurrent same-key posts: one header, both return the same id; ANOTHER actor with the same `client_op_id` posts independently and cannot observe the first (no oracle); `client_op_id`/`origin_key` matching different headers -> `idempotency_key_reuse`; payload hash stable when a master is renamed between replays |
| T-GF-1..3 | `ledger/gap_free_test.exs` | forced overlap at the counter (consecutive, commit order = seq order); T1 rolls back after the UPDATE while T2 waits (T2 reuses the number; `max = count`); READ COMMITTED pinned; bounded 100-posting soak (4 workers) `1..100` |
| T-LK-1 | `ledger/lock_order_test.exs` | opposite key order `[(A,B)]`/`[(B,A)]` in forced overlap: no `40P01` (telemetry handler), both commit; step-name probe: keys ascending then counter |
| T-LK-2 | same | a posting HUMAN completion and a non-posting completion overlapping on the audit chain row: no deadlock; probe: class 5, ledger, timers/audit order |
| T-LK-3 | same | counter held beyond the lock timeout (`engine_test_seams` override): 503, nothing committed, counter unchanged |
| T-LK-4 | same | SERVICE origin refused (`write_not_permitted`, ERROR + DLQ), nothing written; the Th/Ts interleaving is the documented reason |
| T-LK-5 | same | a node with two posting lines: the second `post/3` returns `:too_many_postings` at build; with an opposite-key poster in overlap there is no deadlock |
| T-AO-1 | `migrations/ledger_migration_test.exs` | tenant replay creates the four tables, the seed row (idempotent on second replay); UPDATE/DELETE/TRUNCATE on posting/entry refused with the fixed text; a made-up `posting_seq`, a counter bump by 2, a counter UPDATE without header at commit, an entry whose copied seq differs, a reversal of a reversal, a second reversal, an unbalanced `zero_sum` posting (raw SQL) are each refused. The deferred cases need **real commits (Sandbox `:auto`) or `SET CONSTRAINTS ALL IMMEDIATE`**; a plain sandboxed transaction never reaches COMMIT. `down` refused outside dev/test |
| T-TT-1/2 | `support/tenant_template_ledger_test.exs` | a dirty ledger slot is `unprovable` and rebuilt, a clean slot untouched; triggers in a clone refuse and name the clone schema (S9b) |
| T-OFF-1 | `ledger/offline_fields_test.exs` | offline fields stored and returned; `(subject, device_id, client_seq)` unique -> `client_seq_conflict`; out-of-order `client_seq` accepted; `client_event_time` kept as `event_time` with server `posting_time`/`posting_seq`; future beyond tolerance -> `event_time_in_future`; older than 4 days -> `event_time_too_old`; `client_event_time` without `device_id` and `infinity`/offset-less/out-of-range timestamps -> `invalid_posting`; over-long `device_id`/free text -> refused by the DB CHECK as well |
| T-ERR-1/2 | `engine/ledger_failure_mapping_test.exs` | each code of 12.2 once (status, `line_index`, `details` shape); `available` omitted without the read permission; golden: every pre-existing refusal body and 3-tuple consumer unchanged |
| T-SEC-1 | `ledger/security_test.exs` | two-tenant: tenant B's prefix never reads A; subject without the post permission -> `write_not_permitted` byte-identical to every other cause; roles resolved from the DATABASE: a role revoked between task claim and completion is refused; `TENANT_AUDITOR` can hold read/reconcile but a post/reverse grant to it is refused by the matrix test; SQL text carries no value (telemetry capture) |
| T-SEC-2 | `ledger/scope_refusal_test.exs` | a subject with a non-tenant-wide role grant (user or group principal) is refused with the one `write_not_permitted` body and audit detail `scoped_principal_unsupported`; a tenant-wide subject posts |
| T-AU-1 | `engine/ledger_audit_test.exs` | a posting writes exactly one `ledger.posted` audit entry with ids only, appended in the tail AFTER the counter (step-name probe), none for a duplicate or a refusal |
| T-SC-4 | `ledger/boundaries_test.exs` | Rule 7: a core ledger file containing a denylist term fails `mix letflow.check_boundaries`; Rule 8: a second caller of `Letflow.Ledger.post` fails it |
| T-SC-1/2/3 | `ledger/callers_test.exs` | only `lib/letflow/ledger/**` names the tables; `Letflow.Ledger.post` has the single caller `HandlerWrites.post/3`; the scan covers EVERY file under `lib/letflow/modules/**` (module code must not reference ledger tables or `Letflow.Ledger` except through the manifest registration); no Lua/WASM host function names the ledger; (T-SC-2) no core ledger file contains stock vocabulary |
| T-RP-1 | `ledger/report_test.exs` | `balances/3` as-posted and event-time with filters; the result states basis, cutoff, tz, ledger_seq, filters |
| T-RP-2 | same | a cut-off or reconcile read is chunked, honours the page cap and `statement_timeout`; a concurrent second reconcile -> `reconcile_busy` |
| T-RP-3 | same | **CS-01 identity**: opening balance at `N0` + period receipts - period issues and adjustments (legs with `N0 < posting_seq <= N1`) = closing balance at `N1` for the same key and basis, for both bases |
| T-VER-1 | `ledger/document_version_test.exs` | `expected_document_version` stale -> `record_version_conflict`; current -> posts (via the fixture policy) |
| T-RT-1 | `ledger/retired_master_test.exs` | a retired master blocks a stock-adding entry (`master_inactive`), allows a stock-removing entry and a reversal |
| T-MIG-1 | with #2658 | adding a slot name to the registration of a populated ledger leaves posted rows byte-identical and sums unchanged |
| T-LD-1 | `ledger/counter_throughput_test.exs` (tagged) | the exit criterion of 7.6 |

NOT VERIFIED for the test DB: whether the test role is a superuser; no test above depends on it.

## 14. Interfaces

### 14.1 `Letflow.Ledger` (core, `lib/letflow/ledger/`)

```
@type ledger_id :: String.t()
@type cause :: String.t()                      # a module-registered name; core does not enumerate causes
@type basis :: {:posting_seq, non_neg_integer() | :latest}
             | {:event_time, DateTime.t(), known_through :: non_neg_integer() | :latest}
@type posting_command :: %{required(:client_op_id) => String.t(), optional(atom()) => term()}      # the MODULE-level command (client fields + business fields)
@type declarative_posting :: %{ledger_id: ledger_id(), cause: cause(), legs: [declared_leg()],
                               reason_code: String.t() | nil, document_type: String.t() | nil, document_id: String.t() | nil,
                               related_document_id: String.t() | nil, correlation_id: String.t() | nil,
                               event_time: DateTime.t() | nil, reverses_entry_id: Ecto.UUID.t() | nil, scope_ref: String.t() | nil}
@type declared_leg :: %{k: [String.t()], quantity: Decimal.t(), unit_ref: String.t(), attrs: map() | nil,
                        document_line_id: String.t() | nil, optional(atom()) => term()}      # REQ-504 columns ride in the optional keys
@type posted :: %{entry_id: Ecto.UUID.t(), ledger_id: ledger_id(), posting_seq: pos_integer(), duplicate: boolean()}
@type refusal :: {:ledger_refused, code :: atom(), details :: map()}
@type report :: %{basis: basis(), ledger_id: ledger_id(), cutoff_seq: non_neg_integer(), as_of: DateTime.t() | nil, timezone: String.t(),
                  filters: map(), ledger_seq: non_neg_integer(), rows: [map()], next_cursor: term() | nil}
@type page_result :: %{rows: [map()], next_cursor: term() | nil}
@type reconciliation :: %{ledger_id: ledger_id(), checked_through_seq: non_neg_integer(),
                          mismatches: [%{key: [String.t()], balance: String.t(), ledger_sum: String.t()}],
                          gap_check: :ok | {:gap, [pos_integer()]}, chain_check: :ok | {:broken_at, pos_integer()}, next_cursor: term() | nil}

@spec post(HandlerContext.t(), posting_command()) :: {:ok, posted()} | {:error, refusal()}      # @doc false context; verifies the process token itself
@spec balances(prefix :: String.t(), ledger_id(), basis(), filters :: map(), page :: map()) :: {:ok, report()} | {:error, :cutoff_in_future | :invalid_filter}
@spec entries(prefix :: String.t(), ledger_id(), filters :: map(), page :: map()) :: {:ok, page_result()}
@spec fetch_by_client_op_id(prefix :: String.t(), subject_id :: Ecto.UUID.t(), String.t()) :: {:ok, posted()} | {:error, :not_found}
@spec reconcile(prefix :: String.t(), ledger_id(), opts :: map()) :: {:ok, reconciliation()} | {:error, :reconcile_busy}
```

`post/2` runs inside the engine's Multi step and asserts it is inside a transaction. It verifies the per-call process token itself and refuses a forged or absent context (the same discipline as `create/3`, `handler_writes.ex` token); the context type is `@doc false`. A `mix letflow.check_boundaries` rule (new, "Rule 8") limits the callers of `Letflow.Ledger.post` to `lib/letflow/entities/handler_writes.ex`. The read functions take the permission check from the registration (`read` / `reconcile` atoms) in their callers (module routes, L4); core hard-codes no atom.

### 14.2 `HandlerWrites.post/3` (the one new handler-facing function)

```
@spec post(Ecto.Multi.t(), HandlerContext.t(), Letflow.Ledger.posting_command()) ::
        {:ok, Ecto.Multi.t()} | {:error, :invalid_posting | :too_many_postings | :ledger_not_registered}
```

Same discipline as `create/3`; step names confined to the call's range (`{:line, key, :ledger_post}`); at most one posting per TRANSACTION (7.4). Scan H4 changes from "any `HandlerWrites` call but `create/3`" to "`create/3` and `post/3`".

### 14.3 Catalog / manifest changes (F5), each specified

* New optional top-level manifest key `ledger` (map, one or more registrations): `ledger_id_pattern` (a regex that must start with the module id, e.g. `^stock(:[a-z0-9-]{1,32})?$`), `slots` (append-only ordered list, at most 8 names), `causes` (map name -> `%{sign_rule, reason_required}`), `permissions` (map `post|reverse|read|reconcile` -> atoms declared in the manifest's own `permissions`), `scope_slot` (optional slot name whose value is the scope reference, 16.2), `max_event_lateness_hours` (default 96), `policy` (`{Mod, :fun}` base in the module's namespace: `gather_facts/2` optional, `declare/3` required). New Catalog rule 11 validates it (slot names format, uniqueness and append-only against the previously installed registration where known, cause names, sign rule in the closed set, permission atoms declared and NOT core atoms (reusing the existing `core_permission_collision` rule), policy exported and in the module namespace). `Catalog.fetch_ledger/2` resolves by string comparison (D-R.2 pattern).
* Write handler entries (rule 10, S21): the exact-key check `@handler_keys` is relaxed to the four required keys plus the optional `:posts_ledger` (boolean); the `WriteHandler` struct gains `posts_ledger` (default false, NOT in `@enforce_keys`). A handler with `posts_ledger: true` requires a `ledger` registration in the same manifest (new error `write_handler_ledger_missing`). **A posting handler still needs at least one target** (rules `write_handler_no_targets` and `write_handler_without_managed_types` are unchanged): require ONE bookkeeping managed target (the module already manages entity types, e.g. its document-line record) and say so rather than relaxing rule 10; `EntityPort.lock_types` is then unchanged.
* `ManifestHash` (`modules/manifest_hash.ex`) must cover the `ledger` registration (id pattern, slots, causes, sign rules, permission atoms, scope slot, lateness, policy MFA) and each handler's `posts_ledger`; any change bumps the hash and so (OQ-R3 of gh2590) refuses in-flight handler tasks until re-stamped: the module bumps `version` with such a change.
* Activation/`ModuleWrites`: arguments are validated as today; one new activation check: a `posts_ledger` handler may not appear on a SERVICE_TASK node in L1-L4 (refused at activation with a `module_writes_node_type_not_supported`-style code, so the refusal is visible at design time, not only at run time).

### 14.4 The policy callbacks (module code; PURE declaration before any ledger lock)

```
@callback gather_facts(prefix :: String.t(), posting_command()) :: {:ok, facts :: map()} | {:error, {code :: atom(), details :: map()}}   # OPTIONAL
@callback declare(posting_command(), facts :: map(), registration :: map()) :: {:ok, declarative_posting()} | {:error, {code :: atom(), details :: map()}}   # REQUIRED, PURE
```

* `declare/3` is a PURE function: no read, no write, no process, no clock, no lock; it maps the module-level command (and the facts) to the declarative posting (ledger id, cause, legs with slot values, quantities in the base unit, reason, document ids, scope reference). A callback that ran under ledger row locks would be 0054 option B (`0054...md:45`, rejected); here neither callback runs under a ledger lock (7.1 step 3).
* `gather_facts/2` is the only place module code reads for the ledger: master checks (`Org.active?/2`, `CatalogItems.item_uom_valid?/3`; NOT FOUND today), unit-conversion factors, the current version of a document record (9.4). It takes no lock, writes nothing, and runs under the transaction's `statement_timeout`. It is absent until the slices that need masters (L4); the ledger core (L1-L3) and its fixture work with `facts = %{}`, so the core does not wait for #2661/#2663.
* Codes either may return: `master_inactive` (details `{slot, leg_no}`), `record_version_conflict`, `invalid_posting` (details `{leg_no, reason}`); any other value becomes `write_not_permitted`. Resolved through a Catalog `apply/3` on registered data.
* Forbidden in policy modules (new scan, SEC-11; `gather_facts` may use only the module's read API): `Repo.query`, `Ecto.Adapters.SQL`, any prefix other than the one passed, `Process`, `:erlang`, `Task`, reads of the ledger tables, `Ecto.Multi`, `lock`, and (for `declare/3`) any `Repo`, `Ecto.Query`, I/O or clock reference.
* Core re-validates every generic rule on the declarative posting; module code cannot make core accept an unregistered cause, a slot beyond the registration, a float, or a sign-rule violation.
* The REQ-504 conversion (alternate unit to base unit, rounding rule per item, tolerance) is computed by `declare/3` from the facts the module gathered (the conversion factor) and rides in the optional leg keys. It does not close OQ-R4.

### 14.5 No event schema change

`TASK_ENTITY_WRITES_APPLIED` v2 line items have `additionalProperties: false` (`gh2590...md` F-1); adding a posting id would force a v3 bump. The header carries `bpm_task_id`/`bpm_instance_id`; reverse lookup is `entries/4` by `bpm_task_id` (OQ-12).

## 15. Decision records needed

* **0062 (proposed): "Domain-neutral ledger primitive: platform-owned append-only ledger tables, gap-free counter per ledger id, handler-facing `post/3`"**, written by L0 (docs). Contents:
  1. the route ruling R-N (advisor letflow-ec) and the rejection of R-D with its reason (3.2);
  2. **relation to 0039 D1**: core names no business domain; the primitive is neutral; `check_boundaries` Rule 7 and scan T-SC-2; the second plausible consumer (CMMS spare parts, HR leave balances) and the two accepted core changes (`append_only` types, non-negative bounds) that justify it as a platform feature;
  3. **amendment of the wording of 0057 D5**: "the no-negative guard runs inside the module write handler" becomes "runs, under row locks in a fixed order (slot 1, then slot 2, ...), in the transaction of the handler's step, reached from the handler call by `HandlerWrites.post/3`; the stock module's registration supplies the item/location slot meaning";
  4. **what the 0054 Correction still requires of module code**: ledger POLICY stays reviewed module data and code (causes, sign rules, slot meanings, master validation, unit conversion, permissions, process routes, the pure `declare` callback); the core enforces only generic mechanical invariants; the deviation from the letter of the Correction is recorded with V1 as the reason;
  5. **OQ-R4 (update-kind handler writes plus the read facade for entity documents) stays OWED at WMS slice 5 and is NOT replaced** by this primitive;
  6. D-L2..D-L5, D-L11, D-L12; the TRUNCATE trigger as a tripwire and the TenantTemplate "unresettable" choice (5.4); the hash chain and the owner-tamper residual (5.1); the lateness cap D-T (8.3); the per-cause balancing decision D-C (19); the SERVICE refusal as a TYPED refusal whose lifting needs a later 0061 amendment (7.5); the `ledger.posted` audit entry (7.7); tenant export/restore requirements (4.6).
* **0061 amendment (L3 PR, rule 5):** "Rule 1 gains class 5b between 5 and 6, AFTER the instance's own timer rows of 'Amended (GH #2707, PR-1)' item 1: the ledger's balance rows ascending by `(k1..k8)` (missing rows inserted first in the same order), then the single counter row of the ledger id. At most one posting per transaction and one ledger id per posting. A transaction that holds the audit chain row or any later class never takes a ledger row; the SERVICE origin is refused (typed) until its pre-lock exists." with tests T-LK-1..5.
* 0058: no note needed (items 1, 2, 4, 7 satisfied by 9.1, 9.4, 12, 9.5).

## 16. Security

### 16.1 Tenant scoping (INV-1)

Per-tenant schema; the prefix comes from the engine's authorised context (`HandlerContext.prefix`, `gh2590...md:967`), never from a command field; every statement passes `prefix:`.

### 16.2 Authorization of posting (F10 / SEC-3)

* Permission atoms AND the scope dimension come from the module's `ledger` registration (permissions declared in its manifest and granted by `role_grants`; the optional `scope_slot`), checked with `Authorization.role_allows?/2` (`authorization.ex:1518-1520`); core hard-codes no atom and no scope vocabulary.
* **Scope (fail-closed until 0051 is wired for `post/3`).** `post/3` does NOT yet enforce scope-node grants (decision 0051, `Letflow.Api.Scope.Enforce`). Until a later slice wires it, a subject that holds ANY non-tenant-wide role grant (a `role_scope_grants` row with `tenant_wide = false` for the user or one of its groups; table `priv/repo/migrations/20261015025331_create_role_scope_grants.exs:80-97`; the exact lookup is NOT VERIFIED and is read by the implementer) is REFUSED with the one `write_not_permitted` body (audit detail `scoped_principal_unsupported`), so a scoped principal can never post by accident. Test T-SEC-2. Warehouse/zone scoping by the registered `scope_slot` is OQ-13.
* **Position:** a step inside the transaction (7.1 step 2), not an activation snapshot and not only the pre-transaction `authorize_module_writes` (which checks the stamp, `engine.ex:3093-3096`). Roles of `subject_id` are resolved FROM THE DATABASE in this transaction. The function that does this is NOT FOUND (1.1); L3 must add one (signature: `effective_roles_for_user(prefix, user_id) :: [role]`, covering group-derived roles and the org-scoped grants merged by REQ-517..519 `d206c83a`; how those scoped grants are consulted is NOT VERIFIED and must be read by the implementer). Test: role revoked between task claim and completion -> refused.
* **No separation of duties for `TENANT_ADMIN`:** it holds every tenant-scope permission automatically, Catalog permissions included (`authorization.ex:1536-1542`, S22), so the post and reverse atoms are held by it regardless of `role_grants`. `TENANT_AUDITOR` may be granted at most the read and reconcile atoms, never post or reverse (matrix test). `PLATFORM_ADMIN` holds everything (`authorization.ex:1535`) and is NOT relied on as an authorization argument. A `TASK_WORKER` post grant is tenant-wide (no warehouse scope in this series, OQ-13): the real gate is BPM routing, the task assignee and the stamp, not the atom.
* Denied == absent (INV-5): every authorisation, stamp, origin and target refusal is the one `write_not_permitted` body.

### 16.3 Disclosure, logs, SQL, DoS

Refusals carry ids/enums only; `available` is permission-gated; reversal details never echo the target; the guard-oracle residual is documented (10). Free-text columns carry `CHECK (octet_length(...) <= n)` (4.2, 4.3) and are not logged; logging at the posting step is ids and counts. SQL is Ecto composition with bound parameters and `prefix:` (INV-7); the only literal SQL is the fixed migration text. DoS: FIFO at most 2 s then 503; holder bounded by 5 s/10 s; 200 legs, 1 posting per transaction, 20 lines per node; the counter convoy is tenant-wide (already so for the audit chain row, S8) and there is no per-actor rate limit (S25), stated as a residual; reconcile and cut-off reads are timeout-bound, chunked and concurrency-capped (11.2).

### 16.4 Single access path (SEC-4)

`Letflow.Ledger.post` verifies the per-call process token itself; the context struct is `@doc false`; `check_boundaries` limits callers to `handler_writes.ex`; T-SC-1 scans EVERY file under `lib/letflow/modules/**` for ledger table or `Letflow.Ledger` references; a negative scan asserts no Lua/WASM host function names the ledger.

### 16.5 SECURITY-REVIEWER checklist (per slice)

L1 (`ledger_*` tables): triggers (UPDATE/DELETE/TRUNCATE) as a tripwire, schema-qualified names, no SECURITY DEFINER, lazy counter bootstrap, hash chain, CHECKs, `down` guard, TenantTemplate "unresettable" change, oracle and provisioning entries, Rule 7 (no business term in core). L2 (`Letflow.Ledger.post/2`): algorithm order (insert-then-lock ascending, counter last), token/idempotency scoping per subject, lateness cap, strict timestamps, bound parameters, no values in logs, READ COMMITTED pinned. L3 (`HandlerWrites.post/3`): single access path (Rule 8), roles from the DB, scoped principal refused, details gating, the 4-tuple channel and unchanged 3-tuple bytes, Catalog rule 11, pure-`declare` scan, `ledger.posted` audit ids only, SERVICE origin typed refusal. L4 (stock module): routes and read gating by the registered atoms, chunking/timeouts, module scan, no ledger SQL in module code. L5: SEC-12 conditions and its 0061 amendment.

## 17. Implementation slicing (proposal; neutral names)

| Slice | Content | Size | Depends on |
|---|---|---|---|
| L0 | decision 0062, 0061 amendment text, 0057 D5 wording (docs only) | S | this note accepted |
| L1 | migration(s): `ledger_counter`, `ledger_entry`, `ledger_leg`, `ledger_balance`, all triggers, hash chain, provisioning entry, `expected_tenant_tables` oracle, `TenantTemplate` "unresettable" change, check_boundaries Rule 7, T-AO-1, T-TT-*, T-SC-2 | M | notes #2658/#2660 accepted (slot and unit columns); L0 |
| L2a | `Letflow.Ledger.post/2`: algorithm 7.1 for non-reversal causes with a TEST registration (fixture ledger, `facts = %{}`): guard, counter, idempotency, offline fields; T-AC1/2/6, T-GF, T-LK-1/3, T-OFF-1 | L | L1 |
| L2b | reversal, `balances/5`, `entries/4`, `reconcile/3`; T-AC3/4/5, T-RP-* | M | L2a |
| L3 | `HandlerWrites.post/3`, Catalog rule 11 and `posts_ledger`, `ManifestHash`, H4 change, failure channel 12.3, roles-from-DB function, scoped-principal refusal, `ledger.posted` audit in the engine tail, Rule 8, 0061 amendment code, T-LK-2/4/5, T-ERR-*, T-SEC-*, T-SC-*, fixture module | L | L2a, REQ-501 R1-R5 (merged) |
| L4 | stock module: manifest (ledger registration: slots, causes, permissions, `declare` and `gather_facts`), views `stock_movement`/`stock_balance`, read routes, runbook | L | L3; #2661/#2662 and #2663/#2664 only for `gather_facts` master checks (the `declare` part and the registration do not wait) |
| L5 | SERVICE-origin pre-locks and lifting the typed refusal (SEC-12), with its 0061 amendment | M | L3 |

The ledger core (L1-L3) proceeds without the masters: its fixture registration and `facts = %{}` do not depend on them. Explicitly OUT of this issue and its slices: REQ-503 behaviour (quarantine, serial uniqueness, owner/custodian transfer, available-to-pick); REQ-504 conversion/rounding/tolerance logic (its design is #2660; this note reserves the columns and the callback); the 1C/SAP acknowledgment table (G9); command log and lease (REQ-480); counts/variance (WM-12); period close; per-ledger-instance sequences (the scale path); a balance repair action; automated postings (until L5); OQ-R4's update-kind and read facade for entity documents (owed at WMS slice 5).

## 18. Acceptance-criteria map

| AC | Where |
|---|---|
| Tables, append-only, sequence proof, lock order, citations | 4, 5, 6.2, 7, 2 |
| G7 event time; time basis/cut-off | 8 |
| Test plan (unbalanced, concurrent negative, reversal, cut-off, cache+reconcile, idempotency) | 13 T-AC1..6 |
| Prerequisite carried; REQ-501 ACs not on main | 1.1 |
| CDV/SECURITY gates | 16.5, 21 |
| Offline: ids, 409 details, expected_version, tombstone | 4.2, 9, 12, 9.4, 9.5 |
| Quantities per D4 | 1.2, 4.3 |
| REQ-503/504 by reference | 4.5 |

## 19. Decisions recorded (not open)

* **D-L1 route:** R-N, RULED by the advisor letflow-ec (OQ-1 closed).
* **D-L2** append-only in the database (5.1); **D-L3** one sequence PER LEDGER ID (the stock module registers one id per tenant in release 1; the tenant already has a per-tenant serialisation row, S8; per-ledger-instance ids are the scale path); **D-L4** class 5b (7.2); **D-L5** time (8); **D-L11** no FK from ledger tables to engine tables (S19); **D-L12** SERVICE origin refused in L1-L4 (7.5).
* **D-T lateness cap = 96 hours** (8.3).
* **D-C per-cause balancing (OQ-14 decided).** The draft says WM-06 "every movement balances source and destination" and MD-08 "every transfer has balanced source/destination legs". International practice (SAP material documents, Dynamics 365 inventory transactions) posts a goods receipt or issue single-sided and balances only two-sided causes (transfer posting, stock-type/status change); the counterpart of a receipt is the supplier, outside the stock ledger. Decision: sign rules per cause (`positive`, `negative`, `zero_sum_by_slot_1`, `any`, `reversal`); "every movement balances" is read per cause; no virtual-location double entry. This agrees with 0057 D5 ("a transfer sums to zero per item") and with the draft's own MD-08 wording for transfers; no real conflict needing the user was found. Recorded in 0062.
* **C-2** the 1C/SAP acknowledgment is a later append-only table, not a header column (practice: an acknowledgment arrives after posting). **C-3** a reversal carries its own event time. **C-4** negative stock forbidden (D5) with the `CHECK` backstop. **C-5** per-tenant sequence.

## 20. Open questions

| Id | Question | Default |
|---|---|---|
| OQ-2 | One stock ledger id per tenant (release 1) or one per warehouse? | per tenant; per-warehouse ids (the scale path of 7.6) only if T-LD-1 fails its exit criterion |
| OQ-3 | Allow negative balance by policy? | no (D5) |
| OQ-5 | Fill `scope_ref` from a registered scope slot now? | store it when the registration declares a scope slot; enforcement is OQ-13 |
| OQ-9 | Should reconcile repair? | no |
| OQ-10 | `numeric(30,9)` until REQ-504 fixes scales? | yes |
| OQ-11 | Role grants for the four atoms? | task-worker post+read; tenant-admin gets all automatically (S22); auditor read+reconcile; real role list NOT VERIFIED, decided in L4 |
| OQ-12 | Entry id into the APPLIED event? | no |
| OQ-13 | Warehouse/zone scoping of postings (0051/0058 a)? | out; until wired a scoped principal is refused (16.2) |
| OQ-16 | #2658 alignment: slots instead of typed nullable columns. | slots (4.5); the #2658 designer must align its note |
| OQ-17 | Run `gather_facts`/`declare` in the pre-transaction plan phase (before ANY lock of the transaction) instead of inside the step? | no; inside the step, before any ledger lock (7.1 step 3) |

Closed: OQ-1 (R-N ruled), OQ-4 (skew 5 min, part of D-T), OQ-6 (duplicate under the counter lock), OQ-7 (`available` permission-gated), OQ-8 (one posting per transaction, 200 legs), OQ-14 (D-C), OQ-15 (D-T, 96 h).

## 21. Revision map (findings of the CDV FAIL and the SECURITY review)

| Finding | Status | Where |
|---|---|---|
| F1 route R-N/R-D, 0039/0054/OQ-R4 (OQ-1 then ruled R-N) | done | 3, 15, 20 |
| F2 one posting per transaction; false claim fixed; OQ-8 | done | 7.3, 7.4, 20 |
| F3 TRUNCATE, seed row, TenantTemplate; precedent wording | done | 4.1, 5.1, 5.4, S9, S9b |
| F4 class 5b justification, tail list, timers | done | 7.2, S3b, 15 |
| F5 Catalog rule 10 / struct / ManifestHash / ModuleWrites / lock_types | done | 14.3 |
| F6 failure channel | done | 12.3, S6b, S6c |
| F7 payload hash, key mismatch, SEC-5 scoping | done | 9.2 |
| F8 client_seq conflict, out-of-order, untrusted | done | 9.3 |
| F9 reversal checks in algorithm | done | 7.1 steps 5-7, 10 |
| F10 / SEC-3 permission lookup, DB roles, TENANT_ADMIN/AUDITOR/PLATFORM_ADMIN | done (lookup function NOT FOUND, specified) | 16.2 |
| F11 / SEC-11 callback types, error shape, forbidden, timeouts | done | 14.1, 14.4 |
| F12 tests | done | 13 |
| F13 / SEC-6 clock_timestamp, no hard CHECK, lateness cap, strict timestamps | done | 8, 4.2 |
| F14 balance first insert, soften claim | done | 4.4, 5.2 |
| F15 / SEC-2 qualified names, no SECURITY DEFINER, idempotent seed, down | done | 4, 4.1 |
| F16 comparator, append-only dimension list | done | 4.5 |
| F17 offline fields path, conditional version | done | 9.1 |
| F18 T-LD-1 criterion, convoy, 0040 | done | 7.6 |
| F19 C-1 into 0062 and decided | done | 15, 19 |
| F20 SERVICE exclusion | done | 7.5 |
| SEC-4 single access path | done | 14.1, 16.4 |
| SEC-7 reversal details | done | 10, 12.2 |
| SEC-8 octet_length CHECKs | done | 4.2, 4.3, 16.3 |
| SEC-9 reconcile bounds | done | 11.2 |
| SEC-10 tamper evidence | done (hash chain in L1) | 5.1 |
| SEC-12 L5 conditions | done | 7.5 |
| Addendum 2 OQ-15 decided; addendum 3 OQ-14 decided; addendum 1 R-N default / R-D laid out | done | 8.3, 19, 3 |
| Ruling 1 neutral names and data (`ledger_entry/leg/balance/counter`, counter per ledger id, cause is policy data, Rule 7) | done | 3.3, 4, 5.3 |
| Ruling 2 pure `declare` before any lock; `gather_facts` | done | 7.1 step 3, 14.4 |
| Ruling 3 permissions and scope from the registration; scoped principal refused | done | 14.3, 16.2, T-SEC-2 |
| Ruling 4 0062 contents (0057 D5 wording, 0054 Correction, OQ-R4 owed) | done | 15 |
| Ruling 5 second consumer | done | 3.3 |
| Technical: insert-then-lock ascending; class 5b; per-ledger scale path; D-L12 typed; TRUNCATE trigger + reset; READ COMMITTED test; export/restore/delete/oracle; `ledger.posted` audit; slices | done | 7.1, 7.2, 7.5, 7.6, 5.4, T-GF-3, 4.6, 7.7, 17 |

## 22. Risks for CODE-DESIGN-VALIDATOR to attack first

1. Neutrality (3.3): that no business term can enter core (Rule 7 is a text scan), that the slot/cause registration really removes the stock vocabulary from core, and that 0062 states the Correction deviation honestly.
2. The gap-free proof (6.2), F5 visibility argument and the duplicate path.
3. Class 5b against the real tail (7.2) and the SERVICE cycle (7.5): derived by reading, not run.
4. Slots vs typed columns (4.5) and the cross-note effect on #2658.
5. The roles-from-DB function (NOT FOUND) and the org-scoped grants interaction.
6. Throughput numbers (criterion only, not measured).
