# GH #2657 / REQ-502 -- WMS stock ledger core (1 of 4): append-only `stock_movement` header plus legs, gap-free posting sequence, reversal, no-negative guard

Author: CODE-DESIGNER, 2026-10-19. Branch `docs/GH-2657-wms-ledger-core-design`, from `origin/main` `a614e9c1`
("fix(GH #2707): EventStore.append/2 locks the instance projection first", #2866). Design only: signatures, type
shapes, table and constraint lists, step lists, SQL statement shapes in prose, test briefs. No function bodies.
Nothing here was run (docs-only; the host is memory-starved). Every claim about existing code carries a
`file:line` re-read on `a614e9c1` today, or is marked NOT FOUND or NOT VERIFIED. Line numbers are at that sha.

Sources: decision 0057 D5, D4, D9 and gap G7 (`docs/migration/decisions/0057-wms-customer-draft-reconciliation.md:17,16,44-48,22`),
0058 part (c) (`0058-wms-offline-readiness.md:25-34`), 0060 (decimal_strict), 0061 (engine lock order), 0050, 0052, 0054,
base document `docs/WMS/WMS_Procurement_Requirements_Draft.md` (MD-08 line 67, MD-09 line 68, WM-06 line 79, CS-01 line 117,
WM-12 line 85, NF-09 line 138), mapping `docs/migration/wms-customer-draft-mapping-20261016.md`,
`lib/letflow/design/gh2590-req501-module-write-handlers.md`.

## 0. Verdicts in one screen

| # | Question | Verdict |
|---|---|---|
| V1 | Can the REQ-501 handler mechanism, as merged, run the no-negative guard? | **NO.** It is create-only: a handler reads no table, holds no repo, takes no lock, cannot update (`handler_writes.ex:138-149`, contract `gh2590...md:480-483`, deferred items `gh2590...md:1093-1099`). A ledger needs read, lock, counter, update. This note therefore needs ONE new platform primitive and a new decision record (section 3, D-L1; section 15; OQ-1). |
| V2 | Storage | Three tenant-schema tables of the platform (`stock_movement`, `stock_movement_leg`, `stock_balance`) plus a one-row counter table, created by a core tenant migration; NOT entity types. Written only by a new core context `Letflow.StockLedger`, reached from a handler through a new `HandlerWrites.post/3`. |
| V3 | Append-only enforcement | In the DATABASE (UPDATE, DELETE and TRUNCATE refusal triggers, structural constraints, deferred constraint triggers), plus single-writer static scan. No REVOKE (NOT FOUND in any migration, and the app role owns the tables). |
| V4 | Gap-free sequence | One row per tenant (`stock_ledger_counter`), incremented by `UPDATE ... RETURNING` in the posting transaction and locked to commit; NOT a Postgres SEQUENCE. A trigger forces `+1` steps. Proof in section 6. One sequence per TENANT. |
| V5 | Lock order | Inside decision 0061's order: after class 5 (entity-type rows), before class 6 (audit chain row). Inside the ledger: balance rows ascending by key, THEN the counter row (last). New class "5b" needs a 0061 amendment (D-L4). SERVICE_TASK origin is refused in the first slices because it takes the audit chain row before the handler's writes (real cycle, section 7.4). |
| V6 | Errors | Typed 409 `insufficient_stock` and 8 siblings with a machine-readable `details` object; 40P01 and 55P03 map to the existing 503 `entity_write_contention`; nothing committed, no counter value consumed. |
| V7 | Event time (G7) | A late-synchronised movement keeps its `client_event_time` as `event_time` and gets the server `posting_time` and a new `posting_seq` at posting; published as-posted balances (`posting_seq <= N`) never change. Every report states its basis and cut-off (section 8). |
| V8 | Status of prerequisites today | REQ-501 R1-R5 are ALL merged (the issue text is stale); #2654 is CLOSED (PR-2 merged); masters #2661/#2663 and the `stock` module are NOT FOUND on main. Section 1. |

## 1. Prerequisite section (carried from the issue, re-verified today)

### 1.1 REQ-501 / #2590 (the mechanism the guard runs in)

The issue states R3, R4a, R4b and R5 are NOT merged (it was written at `5997f92c`). Re-verified on `a614e9c1`:

| REQ-501 piece | Merge commit on main | Evidence |
|---|---|---|
| R1 Catalog registration, validation, lookup, manifest hash | `8a7b1be8` (#2650) | `git log origin/main --grep "GH #2590"` |
| R2 stamp storage | `a43ad970` (#2652) | same |
| R3 declaration and activation (`module_writes`, activation checks, PinRebind guard) | `e5ed281b` (#2665) | same; `lib/letflow/definitions/module_writes.ex` exists |
| R4a entities core (`HandlerWrites`, `HandlerContext`, handler contract) | `1a50321c` (#2670) | `lib/letflow/entities/handler_writes.ex`, `handler_context.ex` exist |
| R4b engine HUMAN_TASK integration, failure mapping | `b5c5e498` (#2672) | `engine.ex:380-400` |
| R5 SERVICE_TASK (HTTP and script-bound) | `6b1fb16b` (#2722) | `engine.ex:400-410` |

GH #2590 is CLOSED (`gh issue view 2590`). Production `:modules` is still `[Letflow.Modules.Exam]` and Exam declares no
handler (`config/config.exs:60`), so no handler runs in production today; the mechanism is exercised by the test fixtures only.

REQ-501 acceptance criteria this design RELIES on, each marked on main today:

| Relied-on criterion | On main? |
|---|---|
| A module registers handlers only via the Catalog; the handler runs INSIDE the step Multi; the platform builds the Owner, source, key; replay never runs a handler (D-R.1, D-R.4, D-R.19) | YES (R1, R4a, R4b) |
| Only a definition version stamped by the module's install may call the handler; hash and body checked at activation AND at run time | YES (R2, R3, R4b `P0b`, `owner_recheck`, `handler_writes.ex:476`) |
| Type locks are ordered by the engine, ascending, before any write (D-R.7) | YES (`handler_writes.ex:426-437`, `step_writes.ex:526-585`, `engine.ex:393-398`) |
| HUMAN_TASK and SERVICE_TASK origins, platform sentinel actor and activator subject on the service path | YES (R5, `handler_writes.ex:8-13`) |
| A handler can UPDATE a record, READ a table, take a row lock of its own, or write a non-entity table | **NO. NOT FOUND, by design.** `gh2590...md:199` (F-R5), `:211` (D-R.5), `:466-469` (no `step/3`, no read function), `:1093-1099` (deferred: update kind, read facade, "the first real ledger handler"). |
| An actor-capability layer (`ActorCapabilities`) | NOT FOUND (`grep -r ActorCapabilit lib docs` returns nothing). The access path used here is `Authorization.role_allows?/2` (`authorization.ex:1518-1520`), `TypeAccess` (`type_access.ex:73`), `FieldGrants` (`entities/query/field_grants.ex`), `RecordAccess` (`record_access.ex:43`). |

The last two rows are the finding that shapes this whole note (V1). The first real ledger handler is explicitly deferred by
REQ-501 itself (`gh2590...md:1094`).

### 1.2 Soft dependencies

| Dependency | State today | Effect |
|---|---|---|
| #2654 exact decimal strings | CLOSED 2026-10-17. PR-1 `49f43759` (#2761, writes) and PR-2 `e6dc2419` (#2770, reads, filters, cursor, aggregates) are both on main. The 2026-10-17 issue update ("strict reads wait for PR-2") is superseded. | A strict field is exact on write AND read now. The ledger does not depend on it for its own columns (they are Postgres `numeric`, exact by construction); it uses the public parser `Decimals.parse/3` (`entities/record/decimals.ex:128-148`) for the wire value of a posting quantity. Entity-store quantity fields of documents may rely on #2654 as shipped. |
| Masters #2661 (REQ-473 org), #2663 (REQ-474 catalog_items), behaviour halves #2662, #2664 | all OPEN; `lib/letflow/modules/` holds only `exam/`, `priv/modules/` only `exam/` (NOT FOUND: `Letflow.Modules.Org`, `Letflow.Modules.CatalogItems`, any `stock` module). | SOFT for this design (written against the planned read API of #2662/#2664: `active?/2`, `item_uom_valid?/3`). HARD for the slices that validate masters (L4, section 14). The core ledger slices L1-L3 do not reference a master type. |
| #2658 REQ-503 dimensions, #2660 REQ-504 quantity | both OPEN, no design note on main (`ls lib/letflow/design` shows neither). | This note includes their columns BY REFERENCE (section 4.5) with a provisional name list; the first migration file is written only after both notes are accepted (L1 depends on the notes, not on their implementations). |

## 2. Sources and verification (all on `a614e9c1`)

| # | Claim | Source |
|---|---|---|
| S1 | The handler-facing API is `create/3` only; it appends entity creates through `Records.command_multi/3` with a platform-derived Owner; no `repo`, no read, no step function | `entities/handler_writes.ex:138-149`; moduledoc `:1-70`; contract `gh2590...md:480-497` |
| S2 | Platform-facing: `lock_types/3,4` emit one `{:type_lock, type}` (or `{:pre_type_lock, type}`) step per type, ASCENDING, before any write | `handler_writes.ex:426-437`; `step_writes.ex:526-585`; `engine/entity_port.ex:236-254` |
| S3 | Engine order of a HUMAN completion: tasks, projection, pure steps, `:lock_ancestors`, entity-type rows (`:entity_writes_started`, `{:type_lock,_}`), the handler calls, THEN the tail (timer cancels, token reconcile, task activation, audit rows, events, projection, cascade) | `engine.ex:383-398` |
| S4 | Order of a SERVICE apply: `:lock_ancestors`, `{:pre_type_lock,_}` group, THEN tokens and task activation whose `task.create` audit takes the audit chain row, THEN the entity writes and handler calls, events, projection, cascade, entity audits last | `engine.ex:400-410`; pre-lock call `engine.ex:5800` |
| S5 | A completion whose node has lines or `module_writes` runs `SET LOCAL lock_timeout = '2s'` (and `statement_timeout` 5 s) as its first statements; a deadlock or timeout is reported `entity_write_contention`, HTTP 503, nothing committed | `engine.ex:390-392, 2920, 3195, 5664`; `api/response.ex:312-314`; `routers/tasks.ex:456-463` |
| S6 | The refusal envelope is `{"error": code, "line_index": n|null}` with a closed status table: `write_not_permitted` 403, `record_version_conflict` 409, `entity_write_contention` 503, everything else 422; `write_not_permitted` is byte-identical for every cause (INV-5) | `api/response.ex:288-314`; `engine.ex:2938-2946` (`@service_refusal_codes`) |
| S7 | Sequence-row protocol: insert-if-absent, `FOR UPDATE`, increment under the held lock, Ecto query composition (no SQL string, INV-7); `lock_instance_sequence/3` is the lock-only variant | `event_store.ex:787-845` |
| S8 | A per-tenant serialisation row already exists: the audit chain row (`audit_chain_locks`), insert-if-absent then `FOR UPDATE`, held to commit; every audited write of a tenant takes it | `audit.ex:211-232`; migration registered at `tenant_provisioning.ex:661` |
| S9 | Database-level append-only precedent: BEFORE UPDATE and BEFORE DELETE row triggers raising a fixed exception, created inside the tenant-guarded migration (`if prefix() do`), no interpolation of tenant data. **No TRUNCATE trigger exists** (row-level triggers do not fire on TRUNCATE). No `REVOKE` appears in any migration | `priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs:1-45, 76-110`; `grep -rn REVOKE priv/repo/migrations` returns nothing |
| S10 | Tenant tables come from `priv/repo/migrations/` PLUS a registration in `TenantProvisioning.tenant_scoped_migrations/0`; both halves are mandatory; the last entry today is `20261019200001`; the table-set oracle is `TenantFixture.expected_tenant_tables/0` | `tenant_provisioning.ex:661, 728-731`; `test/letflow/support/tenant_fixture_test.exs:144`; `test/letflow/migrations/tasks_scope_node_id_migration_test.exs:152` |
| S11 | Migration version prefixes must be unique; pick against open branches | `docs/anti-patterns.md:574` |
| S12 | Optimistic concurrency on entity records: `expected_last_event_global_seq`, mismatch `{:error, :record_version_conflict}` (HTTP 409) | `entities/records.ex:59, 577-581`; `api/response.ex:313` |
| S13 | The reserved idempotency prefix: a client key starting `sys:step:` is refused `{:error, :reserved_idempotency_key}` | `entities/records.ex:175, 1004-1007` |
| S14 | Exact decimal parser: canonical grammar `-?(0|[1-9][0-9]*)(\.[0-9]+)?`, no exponent, no `+`; scale and precision refused, never rounded; a JSON float is not accepted | `entities/record/decimals.ex:120-148`; decision 0060 item 2 |
| S15 | Handler PURITY scan H4 covers HANDLER files derived from manifests, and flags every `HandlerWrites` call but `create/3`; it is a tripwire, "the boundary is that the API hands a handler nothing dangerous" | `test/letflow/entities/handler_writes_callers_test.exs:21-35` |
| S16 | Forced-overlap harness: barrier row held by a third connection, workers on pinned connections, lock-queue FIFO, telemetry handler reports every 40P01 and 55P03 even if retried | `test/support/lock_order_helpers.ex:1-52`; decision 0061 rule 5 |
| S17 | Postgres 16 (so `NULLS NOT DISTINCT` exists, but this design does not rely on it) | `docker-compose.yml:3` |
| S18 | Default isolation: no override of the Repo or the config (`grep isolation config lib/letflow/repo.ex` empty), so READ COMMITTED; the gap-free proof states this assumption and a test pins it | `lib/letflow/repo.ex`, `config/*.exs` (NOT FOUND any override) |
| S19 | A foreign key from the engine's own tables takes `KEY SHARE` on the referenced row when the referencing row is inserted or twice-updated in a transaction (the #2709 mechanism) | decision 0061 "Amended (GH #2709, PR-2)" |
| S20 | `scope_node_paths` table lock (0054 D3 rule 3a) applies only to scoped types; scoped types are refused for handler writes until decision 0051 | `gh2590...md:972` (INV-6); `handler_writes.ex:30-33` |

## 3. Decisions (one-line rationale each)

* **D-L1 The ledger is a platform primitive with module-owned policy; storage is real SQL tables, not entity records.**
  Rationale: V1. Entity records are event-sourced rows reachable by handlers only through create-only `create/3`; the ledger needs a
  counter (read-modify-write), a no-negative check (read under lock) and a balance cache (update). Rejected options:
  * *R-A entity types for header, legs and balance, written by `create/3`*: no counter, no guard, no balance update; each leg would also cost an event plus a projection row. Rejected.
  * *R-B module code with a "scoped repo" in a platform-provided step*: gives module code the thing F-2/D-R.5 removed on purpose (tables, prefix, lock order, `SET LOCAL`), and 0054 option B ("module callback ... runs inside the locked transaction, unbounded time under row locks", `0054...md:45`) was rejected for the same reason. Rejected.
  * *R-C chosen*: the SQL lives in ONE core context, `Letflow.StockLedger`, whose posting function takes every lock itself in one fixed order (so the lock order cannot be violated by module code, the same argument as D-R.7), and a handler reaches it through ONE new handler-facing function `HandlerWrites.post/3` that builds a Multi step. The handler stays pure (no repo, no read). The module supplies the command (arguments from the task) and a policy callback (master checks, unit conversion); the platform supplies authority, locks, sequence, guard, writes.
  Consequence: decision 0057 D5's wording "the guard runs inside the module write handler" is met in substance (same transaction as the step, under ordered row locks, reached from the handler call) and amended in form: needs **decision 0062** (section 15).
* **D-L2 Append-only is enforced in the database, with a single-writer code scan as the second layer.** Section 5.
* **D-L3 One gap-free sequence per TENANT.** One sequence per tenant, not per warehouse: a transfer between warehouses is one header with one number, and a cut-off `N` is one number for every report. The tenant already has a per-tenant serialisation row on every audited write (S8), so the counter adds no new class of serialisation to a process-step transaction. Per-warehouse is the scale-out path (OQ-2). Section 6.
* **D-L4 Lock order:** ledger balance rows (ascending by balance key), then the counter row, positioned between decision 0061 classes 5 and 6 as new class "5b". Section 7.
* **D-L5 Time:** `event_time` (physical) and `posting_time` (server) are both stored; `posting_seq` is the only authority for order and cut-off. Section 8.
* **D-L6 Idempotency:** two unique keys, the client's `client_op_id` and the platform's `origin_key`; same key plus same payload hash returns the existing `movement_id` and posts nothing; same key plus different payload is a typed 409. Section 9.
* **D-L7 Reversal:** a NEW header (`cause = 'reversal'`, `reverses_header_id`) whose legs exactly negate the target's; at most one reversal per header; a reversal cannot be reversed; the guard applies to it. Section 10.
* **D-L8 `stock_balance` is a cache** updated in the same transaction, never read to decide anything but the guard, with a read-only reconciliation. Section 11.
* **D-L9 Errors are typed, closed, machine-readable.** Section 12.
* **D-L10 Contradictions between the customer draft and international practice are recorded and decided** (decision 0057 D9). Section 3.1.
* **D-L11 No foreign key from a ledger table to any engine table or entity table.** Rationale: S19. An FK from a ledger row to `instance_projections` or `tasks` would take a `KEY SHARE` lock on the parent in an order the ledger does not control, after the ledger rows, which 0061 forbids; masters are entity records whose references are declarative only (decision 0050 D3.6 as cited by #2661). The BPM references are plain columns. The only FKs are inside the ledger (leg to header, reversal to header).
* **D-L12 SERVICE_TASK origin is refused in slices L1-L4** (`post/3` returns a closed error and the apply lands in ERROR + DLQ as any handler refusal does). Rationale: the real cycle in section 7.4.

### 3.1 Contradictions and rulings (decision 0057 D9: international practice is the tie-break)

| # | Customer draft says | International practice | Ruling |
|---|---|---|---|
| C-1 | WM-06: "Every movement balances source and destination" (line 79); MD-08: "every transfer has balanced source/destination legs" (line 67), and receipts, issues, returns, adjustments are also "balanced postings" | Perpetual-inventory ledgers (SAP material documents, Dynamics 365 inventory transactions) post a goods receipt or issue single-sided and balance only the two-sided kinds (transfer posting, status/stock-type change); the counterpart of a receipt is the supplier or the consumption, outside the stock ledger | **Zero-sum per item is required for `transfer`, `status_change` and `reversal` of those; `receipt`/`return` have only positive legs, `issue` only negative legs, `adjustment` any sign** (D5 says only "a transfer sums to zero per item"). The statement "every movement balances" is read as per-kind. No virtual-location double entry in the ledger (the Odoo school) because it would put negative rows for suppliers in the balance table. |
| C-2 | MD-08: "retain reference to ... any 1C/SAP acknowledgment" next to an append-only ledger | An acknowledgment arrives AFTER posting and must not edit a posted row | The acknowledgment is NOT a header column. It is a later append-only table keyed by `movement_id` (gap G9, outbound ERP events; out of this issue). The header carries only the BPM references. |
| C-3 | MD-09: "late offline synchronization and corrections shall not silently rewrite earlier published balances" | Posting date versus document date (SAP, Dynamics): a late document gets the current posting number with its own document date; corrections are new documents | Matches D5 and G7; recorded for the reversal rule: a reversal carries its OWN event time (when the reversal was performed), never the target's, so a correction never rewrites a closed cut-off (section 10). |
| C-4 | The draft is silent on negative stock | Some systems allow negative stock by configuration; D5 forbids it | D5 stands (ruled). Slice 1 has no `allow_negative` switch (OQ-3). The database backs the guard with `CHECK (on_hand >= 0)` on `stock_balance`. |
| C-5 | D5: "one gap-free sequence per tenant OR per warehouse" | Document-number ranges are usually per company code, not per site | **Per tenant** (D-L3). |

## 4. Schema (first migration; nothing here is created by an entity definition)

Names follow the issue text (`stock_movement`, legs, `stock_balance`). All tables live in each TENANT schema (tenancy is the
schema prefix, no `tenant_id` column, as `audit_entries` and `tenant_module_upgrades`, `0055...md:58`). Delivery: one tenant
migration file (or a small ordered set) in `priv/repo/migrations/` AND its entry in `TenantProvisioning.tenant_scoped_migrations/0`
(S10); the oracle `expected_tenant_tables/0` gains the four table names in the same PR; the version prefix is chosen against open
branches (S11). Every non-null id is `uuid`. Quantities are `numeric(30,9)` provisionally (OQ-10; REQ-504 may narrow the scale).

### 4.1 `stock_ledger_counter` (one row)

| Column | Type | Rule |
|---|---|---|
| `id` | smallint PK | `CHECK (id = 1)`; the single row is INSERTED BY THE MIGRATION (seed `last_seq = 0`), so there is no insert-if-absent race |
| `last_seq` | bigint NOT NULL | `CHECK (last_seq >= 0)` |

Triggers (rules in 5.2). Never deleted, never truncated.

### 4.2 `stock_movement` (header, append-only)

| Column | Type | Null | Meaning and rule |
|---|---|---|---|
| `id` | uuid PK | no | the **stable operation id** returned to callers and echoed on a duplicate |
| `posting_seq` | bigint | no | UNIQUE; `CHECK (posting_seq >= 1)`; allocated by the counter (section 6) |
| `cause` | text | no | closed `CHECK`: `receipt`, `issue`, `transfer`, `return`, `status_change`, `adjustment`, `reversal` (the MD-08 list plus reversal) |
| `reason_code` | text | yes | required (non-blank) when `cause IN ('adjustment','reversal')` (WM-12: an adjustment has a reason) |
| `document_type`, `document_id`, `related_document_id` | text | yes | business document ids (e.g. receipt document, its purchase order); opaque strings, each at most 128 bytes |
| `actor_id` | uuid | no | the event actor: the completer on the HUMAN path, the platform sentinel on a (later) service path |
| `subject_id` | uuid | no | the authorisation subject (equals `actor_id` on the HUMAN path; the activator on the service path) |
| `correlation_id` | text | no | at most 128 bytes; defaults to the BPM instance id when the command gives none |
| `bpm_instance_id`, `bpm_task_id` | uuid | yes | from the `HandlerContext` (`instance_id`, `origin` `{:task, id}`); no foreign key (D-L11) |
| `bpm_node_id` | text | yes | the node id |
| `bpm_definition_id`, `bpm_definition_version` | uuid, text | yes | the pinned definition |
| `event_time` | timestamptz | no | physical event time (section 8) |
| `posting_time` | timestamptz | no | server time read UNDER the counter lock; `CHECK (event_time <= posting_time + interval '5 minutes')` is a backstop of the configured skew (OQ-4) |
| `client_op_id` | text | no | UNIQUE; the idempotency key (0058 c.1); 1-128 bytes; must not start with `sys:` (S13) |
| `origin_key` | text | no | UNIQUE; platform-derived `sys:step:<origin id>:<line>:<ordinal>` of the posting call (what makes a task-completion retry impossible to double-post even if the client reuses a `client_op_id` across tasks) |
| `payload_hash` | text | no | SHA-256 hex of the canonical posting payload (section 9) |
| `device_id` | text | yes | 0058 c.1 |
| `client_seq` | bigint | yes | per-device monotonic number; `CHECK (client_seq >= 0)`; `device_id` and `client_seq` both set or both null; UNIQUE `(device_id, client_seq)` where not null |
| `client_event_time` | timestamptz | yes | exactly what the device reported (kept even when `event_time` is clamped, never silently) |
| `reverses_header_id` | uuid | yes | FK to `stock_movement(id)`; `CHECK ((cause = 'reversal') = (reverses_header_id IS NOT NULL))`; UNIQUE partial index (`WHERE reverses_header_id IS NOT NULL`): at most ONE reversal per header |
| `site_id` | uuid | yes | the warehouse/site copy, filled by the policy when known (OQ-5); not part of any balance key |
| `leg_count` | smallint | no | number of legs; the deferred check (5.3) requires it to equal the legs inserted |

Also `UNIQUE (id, posting_seq, event_time)` (target of the leg's composite foreign key).

Indexes: UNIQUE `posting_seq`; UNIQUE `client_op_id`; UNIQUE `origin_key`; `(event_time, posting_seq)`; `(document_type, document_id)`;
`(bpm_instance_id)`; `(correlation_id)`; the partial uniques above.

### 4.3 `stock_movement_leg` (append-only)

| Column | Type | Null | Meaning and rule |
|---|---|---|---|
| `id` | uuid PK | no | |
| `movement_id`, `posting_seq`, `event_time` | uuid, bigint, timestamptz | no | composite FK `(movement_id, posting_seq, event_time)` to the header's `UNIQUE (id, posting_seq, event_time)`: the copies cannot differ from the header, so a cut-off sum and an event-time sum need no join |
| `leg_no` | smallint | no | 1-based; UNIQUE `(movement_id, leg_no)`; at most 200 per header |
| `item_id` | uuid | no | the `catalog_item` record id (declarative reference only) |
| `location_id` | uuid | no | the location record id (declarative reference only) |
| `quantity_base` | numeric(30,9) | no | the signed DELTA in the item's base unit; `CHECK (quantity_base <> 0)` |
| `base_unit_id` | uuid | no | the `catalog_uom` record id of the base unit (REQ-504 states the scale) |
| `document_line_id` | text | yes | the stable document-line id generated at issue time (0058 c.3) |
| *(columns owned by REQ-504 and REQ-503, section 4.5)* | | | |

Indexes: `(item_id, location_id, posting_seq)` INCLUDE `quantity_base` (as-posted sums); `(item_id, location_id, event_time, posting_seq)`
(event-time sums); `(movement_id, leg_no)`.

### 4.4 `stock_balance` (derived cache; the ONLY mutable ledger table)

| Column | Type | Null | Rule |
|---|---|---|---|
| `item_id`, `location_id` | uuid | no | key |
| *(balance-key dimension columns of REQ-503, NOT NULL with a sentinel for "none", section 4.5)* | | no | key |
| `on_hand` | numeric(30,9) | no | `CHECK (on_hand >= 0)` (the database backstop of the guard, C-4) |
| `last_posting_seq` | bigint | no | the `posting_seq` of the last posting that changed the row |
| `updated_at` | timestamptz | no | |

PRIMARY KEY is the full key (item, location, dimension key columns). A row is created on first touch with `on_hand = 0` and is
NEVER deleted (tombstone rule, 0058 c.7): a zero balance stays as a zero row.

### 4.5 Columns included by reference

| From | Columns (this note's PROVISIONAL names; the owning note's names win) | Placement |
|---|---|---|
| REQ-504 (#2660) | `quantity_original numeric(30,9)` (signed), `original_unit_id uuid`, `conversion_factor` (the decimal string applied, as `numeric`), tolerance evidence reference | leg, all nullable (a posting in the base unit leaves them null or equal) |
| REQ-503 (#2658) | `status` (default value decided there), `lot`, `serial`, `expiry`, `owner`, `custodian` | leg: all nullable (#2658 AC: "all new dimension columns are nullable"); balance: only those #2658 puts in the balance key |

Rules this note imposes on #2658 so the first migration can be written: (a) it states the **balance key** as an ordered column list;
(b) in `stock_balance` each key dimension is NOT NULL with one sentinel per type (empty string for text, the nil uuid for uuid), and the
single function that maps a leg's nullable value to the sentinel is the only place null is interpreted; (c) the reconciliation
query groups legs by `COALESCE(col, sentinel)` for the same columns; (d) the byte-identity migration test in #2658's AC (a posted leg is
unchanged by adding a nullable column) is run against THIS table; (e) the issue lists `status` and `lot` among the leg fields: they ARE those
columns, not a second pair. Until #2658 is accepted, no migration file is written (L1 is blocked by the note, section 14).

## 5. Append-only enforcement (decision: database level, three layers)

### 5.1 Why the database and not only the module path

The module-write-handler path is NOT a sufficient guarantee: a bug in `Letflow.StockLedger`, a console session, a migration, or a
future second writer can all bypass any application-level rule, and the ledger is the legal record of stock. The repository precedent
for a legal-record table is the database trigger (S9, `audit_entries`: "enforced in the DATABASE, not by Ecto changeset validation").
Decision 0054 option A (managed types) and the stamp mechanism (R2) protect ENTITY types and process definitions; they do not apply
because the ledger is not an entity type (D-L1). Layers:

1. **Triggers** on `stock_movement` and `stock_movement_leg`: BEFORE UPDATE and BEFORE DELETE (row) and **BEFORE TRUNCATE (statement)**, each raising one fixed exception text, no tenant data (`'stock_movement is immutable'`). The TRUNCATE trigger is NEW against the `audit_entries` precedent, which lacks it (S9: row triggers do not fire on TRUNCATE).
2. **Structural constraints** (4.2-4.4) and the deferred checks of 5.3.
3. **Single writer**: a scan (new test file, same style as `handler_writes_callers_test.exs`, S15) asserts that only `lib/letflow/stock_ledger/**` references the four table names or their schema modules, and that `HandlerWrites.post/3` is the only caller of `StockLedger.post`.

Residuals, stated: the table owner can `ALTER TABLE ... DISABLE TRIGGER` and a superuser can set `session_replication_role = replica`;
`REVOKE` is NOT used because the application connects as the owner of the tenant tables (no REVOKE in any migration, S9). Detecting
tampering after the fact is the reconciliation read (11.2) plus the gap check. These are accepted limits that SECURITY-REVIEWER records.

### 5.2 Trigger rules (prose, no bodies)

| Table | Trigger | Rule |
|---|---|---|
| `stock_movement`, `stock_movement_leg` | BEFORE UPDATE, DELETE (row); BEFORE TRUNCATE (statement) | raise the fixed text |
| `stock_ledger_counter` | BEFORE UPDATE (row) | `NEW.last_seq = OLD.last_seq + 1` and `NEW.id = OLD.id`, else raise |
| `stock_ledger_counter` | BEFORE DELETE, BEFORE TRUNCATE | raise |
| `stock_movement` | BEFORE INSERT (row) | `NEW.posting_seq` must equal the counter's CURRENT `last_seq` (so a header can only carry a value the same transaction just allocated); when `reverses_header_id` is set, the target exists and its own `reverses_header_id` IS NULL (a reversal cannot be reversed) |
| `stock_balance` | BEFORE UPDATE (row) | if `on_hand` changes, `NEW.last_posting_seq` must equal the counter's current `last_seq` (a balance can only change inside a posting that allocated a number); `item_id`/`location_id`/key columns immutable; no DELETE, no TRUNCATE (raise) |

### 5.3 Deferred constraint triggers (evaluated at COMMIT, once per posting)

| On | Rule |
|---|---|
| `stock_ledger_counter` AFTER UPDATE, `DEFERRABLE INITIALLY DEFERRED` | a `stock_movement` row with `posting_seq = NEW.last_seq` exists (a transaction that allocated a number without a header cannot commit: no gap by bug) |
| `stock_movement` AFTER INSERT, `DEFERRABLE INITIALLY DEFERRED` (one execution per header) | (i) the number of legs equals `leg_count`; (ii) for `cause IN ('transfer','status_change')` the legs sum to zero per `item_id`; (iii) `receipt`/`return` have only positive legs, `issue` only negative; (iv) for `reversal`, per balance key the legs of this header plus the legs of the target sum to zero and the key sets are equal |

Why per header and not per leg: a row-level constraint trigger on legs would run the sum once per leg (quadratic); on the header row it
runs once.

## 6. The gap-free sequence

### 6.1 Mechanism

The posting transaction touches the counter in two statements (steps 6 and 8 of 7.1), both after every balance row is locked and the guard
has passed: (1) a locking read of the single counter row, Ecto `lock: "FOR UPDATE"` composition exactly as the sequence-row precedent
(`event_store.ex:808-811`, S7), which waits for the previous holder and returns the latest committed `last_seq`; (2) after the idempotency
re-check under that lock, an Ecto `update_all` with `inc: [last_seq: 1]` and a `select` of the new `last_seq` (an
`UPDATE ... SET last_seq = last_seq + 1 ... RETURNING last_seq`; no SQL string, INV-7), with the tenant `prefix:` option. The row lock
is held until the transaction ends. Header and legs are inserted in the same transaction with the returned value. NOT a Postgres
SEQUENCE and not `max(posting_seq) + 1`: a SEQUENCE's `nextval` is not transactional (a rollback burns the number), and `max + 1` needs a
lock anyway.

READ COMMITTED is assumed (S18): after waiting, `FOR UPDATE` returns the latest committed row version (the EvalPlanQual recheck). Under
REPEATABLE READ or SERIALIZABLE the read would raise a serialization failure instead of producing a gap; a test pins the isolation level of
the posting transaction. A duplicate command found by the re-check returns WITHOUT the increment (so the duplicate path never burns or
needs to give back a number); the counter lock it took is released with the surrounding transaction.

### 6.2 Proof of gap-freeness (two concurrent postings)

Claim G1: the committed `posting_seq` values of `stock_movement` are exactly `1..M` for some `M`, for all time; and
Claim G2: at any instant every snapshot sees a prefix `1..n` of them (so `posting_seq <= N` is a stable cut-off).

Facts used (each enforced above): F1 the only writer of `last_seq` is the posting UPDATE, which adds exactly 1 (trigger 5.2); F2 a header's
`posting_seq` must equal the counter value current in its transaction (trigger 5.2), and a transaction that bumps the counter cannot
commit without a header of that number (deferred trigger 5.3); F3 the counter row lock (taken by the locking read of step 6) is held until commit or rollback; F4 a
rolled-back transaction leaves the counter row as it was (MVCC), unlike `nextval`; F5 PostgreSQL makes a commit visible to new snapshots
(ProcArray removal) BEFORE it releases the transaction's locks; F6 a transaction that takes the lock and finds a duplicate does not run the UPDATE (no number is used, the trigger is not involved).

Proof of G1 by induction on the transactions that run the counter UPDATE, in the order they acquired the row lock. By F3 that order is total and
non-overlapping: transaction `Tk` acquires the lock only after the previous lock holder (including a duplicate-path holder, F6, which changed nothing) has committed or rolled back. Let `c(k)` be the committed value
of `last_seq` before `Tk`. If the previous holder rolled back or took the duplicate path, then by F4/F6 `c(k)` is unchanged; if it committed an UPDATE, `c(k)` grew by 1 by F1. `Tk`
reads `c(k)` (READ COMMITTED recheck), writes `c(k)+1` and, if it commits, commits a header numbered `c(k)+1` (F2). Hence the committed header numbers
are `1, 2, 3, ...` in lock order with no value skipped and none reused. QED.

Proof of G2: `Tk` commits (visible to new snapshots, F5) before `T(k+1)` can take the counter lock, so no snapshot can contain the header
of `T(k+1)` without that of `Tk`.

Two concurrent postings, the interleavings that matter (counter at 41 committed):

| Step | T1 | T2 | Counter row | Outcome |
|---|---|---|---|---|
| a | locks its balance rows, passes the guard | locks its (different) balance rows, passes the guard | 41 | no conflict so far |
| b | counter `FOR UPDATE` -> 41, then `UPDATE` -> 42, holds the row | counter `FOR UPDATE` blocks | 42 (T1) | T2 waits (lock queue) |
| c1 | T1 inserts header 42 and legs, commits | T2 wakes, reads 42, writes 43 | 42 then 43 | both commit: 42, 43 |
| c2 | T1 fails after (b) (a constraint, a timeout, a crash) and ROLLS BACK | T2 wakes, reads 41, writes 42 | 41 then 42 | T2 commits 42; **no gap, 42 reused** |
| d | T1 and T2 carry the same `client_op_id` | T2 re-checks `client_op_id` AFTER obtaining the counter lock (step 7) and finds T1's committed header | 42 | T2 posts nothing and does not run the UPDATE |

A rolled-back posting that already took a balance row lock releases it with the rollback; no number is ever stored outside the
transaction. Test names in section 13 (T-GF-1..3).

### 6.3 Reader contract

A report takes `N` and its rows in ONE snapshot: a single statement (CTE) or one `REPEATABLE READ READ ONLY` transaction; `N` is
`max(posting_seq)` of that snapshot, or a caller-supplied number `<= max`. By G2 a report at `N` run later returns the same rows
(legs are immutable). A caller-supplied `N` above the counter is refused (`cutoff_in_future`).

## 7. Lock order

### 7.1 The posting algorithm (normative step list, one transaction, run inside the engine's step Multi)

Inputs are the validated command (section 9.1) and the `HandlerContext`. Every statement uses the tenant `prefix:` option and bound parameters.

1. **Shape and authority (no lock).** Closed-shape check; origin must be `{:task, _}` (D-L12); the subject holds `:StockPost` (and `:StockReverse` for a reversal) through `Authorization.role_allows?/2` (`authorization.ex:1518-1520`); a denial is the one public `write_not_permitted` body (INV-5).
2. **Policy (lock-free reads).** The module's `Policy.validate/2` (14.4) resolves masters (item, location active; unit valid; REQ-504 conversion to the base unit) and returns the NORMALISED command (base quantities as `Decimal`, scale checked, never rounded: `Decimals.parse/3`, S14). Reads take no lock.
3. **Idempotency pre-check (lock-free).** A header with this `client_op_id` or `origin_key` exists: payload hash equal returns `{:ok, {:duplicate, movement_id}}` and stops; different hash returns `idempotency_key_reuse`.
4. **Balance keys.** Compute the DISTINCT balance keys the legs touch (reversal: read the target's legs, which are immutable, no lock); sort ASCENDING by the tuple (`item_id`, `location_id`, then the dimension key columns in the order #2658 states), compared as bytes. For each key in that order: (a) insert-if-absent with `on_hand = 0` (`ON CONFLICT DO NOTHING`), (b) `SELECT ... FOR UPDATE` of that row, returning `on_hand`. One key at a time, so the acquisition order is the sorted order (a batched `ORDER BY ... FOR UPDATE` is a later optimisation that needs its own probe test).
5. **Guard.** For every key, `on_hand + sum(delta of its legs) >= 0`, else `{:error, {:insufficient_stock, details}}` (12.2) with nothing written and the counter untouched. The first violating key in sorted order is reported, with all violating leg indexes in `details`.
6. **Counter lock.** The locking read of 6.1 (the LAST ledger lock; it fixes the order of this posting among all postings).
7. **Idempotency re-check under the counter lock** (the race window of 6.2 row d): re-read the two keys (a plain read; the first committed same-key poster is visible after the wait under READ COMMITTED). Found: same payload hash returns `{:ok, %{duplicate: true, ...}}` and the algorithm stops with NO write and NO counter UPDATE; different hash returns `idempotency_key_reuse`.
8. **Number and writes.** The counter UPDATE of 6.1, `posting_time` from the database clock read now (under the lock), insert the header, insert the legs, `UPDATE stock_balance` per key (`on_hand + delta`, `last_posting_seq = posting_seq`).
9. **Return** `{:ok, %{movement_id, posting_seq, duplicate: false}}`. Audit and events are the engine tail's (no change of event schema, 14.5).

### 7.2 Position in decision 0061's global order

Decision 0061 rule 1 (`0061...md:13-21`): (1) the instance's tasks/timers/dispatch rows, (2) `P_x`, (3) ancestor group, (4) own tokens, (5) entity-type
rows ascending (`scope_node_paths` table lock first when it applies), (6) the tenant audit chain row, (7) sequence rows, (8) projection UPDATEs.

The ledger rows slot in as **class 5b: after class 5, before class 6**, internally "balance rows ascending, then the counter row". Reasons:
* the handler runs AFTER the type locks of the HUMAN path (S3), so the ledger step naturally follows class 5;
* everything that follows the handler on the HUMAN path (task activation audit, audit rows, events, projection, cascade) is class 6 or later (S3);
* the counter is taken LAST among the ledger rows so the long part of the work (reads, balance locks, the guard) happens while the tenant-wide counter is still free, and the counter is held for the shortest suffix of the transaction.

This requires **an amendment of decision 0061** (rule 5: "new code takes more than one of these row classes in this order, or amends this record in the same pull request") adding class 5b, written in the L3 PR; the amendment text is in 15.

### 7.3 Why the order cannot deadlock

* Ledger vs ledger: every posting takes balance rows in ascending key order, then the counter; the counter holder never waits for a balance row afterwards (it only inserts and updates rows it already holds). A wait-for cycle would need a transaction holding the counter and waiting for a balance row held by one waiting for the counter: impossible by the order. Two postings with opposite item order `[(A,B)]`/`[(B,A)]` both sort to `A, B`, so the second queues behind the first on `A` and never holds `B` first.
* Ledger vs the rest of the engine: ledger locks come after class 5 and before class 6 on every path that can post (HUMAN, S3). A path that takes class 6 or later and then wants a ledger lock would invert; none exists on the HUMAN path, and the SERVICE path is refused (7.4).
* The insert-if-absent of a missing balance row waits on the transaction that inserted it, in the same ascending order, so it cannot cycle with row locks.
* No FK from the ledger to engine tables (D-L11), so no hidden `KEY SHARE` edges (S19). The legs' FK to their own header (same transaction, own row) and the reversal FK to a committed header add no contended edge.
* The handler's `module_writes` target types (class 5) are locked before; a posting handler registers NO entity target type (or only bookkeeping ones), so the class-5 set is unchanged.

### 7.4 The SERVICE_TASK hazard (why L1-L4 refuse the service origin)

On the service apply the order is `:lock_ancestors`, `{:pre_type_lock,_}`, then token inserts and task activation whose `task.create`
audit takes the audit chain row **A**, then the entity writes and handler calls (S4, `engine.ex:400-410`). A posting there takes the
balance rows and the counter AFTER **A**. Interleaving: a HUMAN posting `Th` holds balance row `B(x)` and the counter and wants **A** for its tail
audit; a service apply `Ts` holds **A** and wants `B(x)`: `Ts` waits for `Th` (row `B(x)`), `Th` waits for `Ts` (**A**). A real cycle,
resolved only by the 2 s lock timeout or the deadlock detector. Class 5b would have to be taken in the service path BEFORE the task
activation, as a lock-only pre-step like the type pre-lock (`engine.ex:5800`), and the balance keys depend on handler arguments, which
are resolved from variables (known at plan time on the service path: NOT VERIFIED, this is L5's first task). Until then `post/3` refuses
`{:dispatch, _}` with the closed error `:ledger_origin_not_supported`.

### 7.5 Deadlock and timeout behaviour

| Event | Where | Result |
|---|---|---|
| `55P03` lock timeout (the plan's `SET LOCAL lock_timeout = '2s'`, S5) or `40P01` deadlock victim | any ledger lock wait | the transaction rolls back (nothing committed, no counter value consumed, no balance changed); the engine's contention rescue maps it to `{:entity_write_refused, :contention, :entity_write_contention}`: HTTP **503** `entity_write_contention`, retryable, `line_index: null` (S5, S6). No new code. |
| `statement_timeout` 5 s (`query_canceled`) | a slow statement | same mapping: `@contention_error_codes [:lock_not_available, :query_canceled, :deadlock_detected]` (`engine.ex:2925`) |
| a database error in a ledger step that is not contention (e.g. `23514` on `on_hand >= 0` after the guard passed) | the backstop | mapped to `insufficient_stock` only if the violated constraint is the balance CHECK (the race the guard should have closed; logged as a defect-class counter with ids only), otherwise `entity_write_failed` (500, no text) |

Hot item or hot counter: a waiter queues FIFO behind the holder for at most the lock timeout (2 s) and then gets 503; the holder is
itself bounded by `statement_timeout` 5 s and the 10 s wall guard (`gh2590...md:749-750`). Bounds: 200 legs per posting, 200 legs per
completion (a per-call token counter, like the 49-write cap), 20 `module_writes` lines per node. Throughput of the single counter is NOT
measured; the estimate (tens of postings per second per tenant, bounded by the tail of the completion transaction) must be measured by
test T-LD-1 against NF-01/NF-02 targets before a pilot (OQ-2 names the scale-out).

## 8. Time basis, late movements (G7) and reports

### 8.1 Event time of a late-synchronised movement

* `client_event_time` is stored exactly as reported (null for an online posting).
* `event_time` = `client_event_time` when present, else `posting_time`. It is NEVER overwritten by the posting time of a late sync: a receipt executed yesterday and synchronised today has `event_time` yesterday, `posting_time` today, `posting_seq` the next number (0058 b: facts "are ACCEPTED late: posted at server posting time, client event time kept").
* Refused: `event_time` later than `posting_time` plus the skew tolerance (default 5 minutes, OQ-4) -> 422 `event_time_in_future`. No lower bound in this slice (the offline lease bounds lateness: default 3 days, 0057 D13, REQ-480).
* The guard is evaluated at POSTING time against current balances, not at event time (a late issue that is negative as of its event time but positive now posts; a late issue that is negative now is refused `insufficient_stock`, 0058 b).

### 8.2 Two bases, both reproducible

| Basis | Predicate | Property |
|---|---|---|
| **as-posted** (default; stock on hand, audit) | `posting_seq <= N` | immutable and reproducible forever (G2); a late movement has `posting_seq > N` so it never changes a published report at `N` |
| **as-of event time** (period reports, CS-01 "any chosen historical moment") | `event_time <= T AND posting_seq <= N` | the pair `(T, N)` reproduces a published report exactly; recomputed with a larger `N` it includes late arrivals, which is the intended "appears in the appropriate period" (MD-09) |

The mixed form (event time only, no `N`) is NOT offered: it would silently rewrite a published balance when a late movement arrives (MD-09).

### 8.3 What every report states (CS-01 line 117)

The read API returns, with every result, `basis` (`"posting_seq"` or `"event_time"`), `cutoff_seq` (`N`), `as_of` (`T` or null), `timezone` (the tenant
timezone used to render period boundaries; storage is UTC), `filters`, and `ledger_seq` (the counter value in the snapshot). Opening balance
plus period receipts minus period issues and adjustments equals closing balance by construction, because all three are sums over the
same legs under one basis (test T-RP-3).

## 9. Commands, idempotency, offline fields, versions, tombstones

### 9.1 The posting command (the closed map `post/3` accepts)

`cause`, `legs` (list of `%{item_id, location_id, quantity (decimal string or integer; never a float), unit_id, dimensions (REQ-503 map), document_line_id}`),
`reason_code`, `document_type`, `document_id`, `related_document_id`, `correlation_id`, `event_time`/`client_event_time`, and the
offline fields **`client_op_id` (required)**, **`device_id`**, **`client_seq`**, **`client_event_time`** (0058 c.1; the ledger stores them beside `posting_seq` and `posting_time`). For `cause = 'reversal'`: `reverses_movement_id` and `reason_code`, no legs. Unknown keys, a float quantity, a string that does not match the canonical grammar (S14), or a quantity with more than 9 fractional digits are refused (`invalid_posting`, never rounded). The encoded command is capped at 256 KiB and 200 legs (this note's own cap; the service-origin write caps of R5 are described in `docs/guides/adding-an-application-module.md` section 5c).

### 9.2 Idempotency (AC: a duplicate command with the same key posts once and returns the same stable operation id)

`payload_hash` = SHA-256 over the canonical, key-sorted JSON of the NORMALISED command without `client_event_time`/transport fields. Outcomes:

| Situation | Result |
|---|---|
| `client_op_id` (or `origin_key`) not seen | post |
| seen, same `payload_hash` | `{:ok, %{movement_id: existing, posting_seq: existing, duplicate: true}}`; nothing written, counter untouched |
| seen, different `payload_hash` | `{:error, :idempotency_key_reuse}` -> 409 (same name as the entity side, `records.ex` `:idempotency_key_reuse`) |
| `client_op_id` starting `sys:` | refused (S13) |

### 9.3 Where the duplicate is decided (race-free, no burned number)

Two checks, both reads: the lock-free pre-check (7.1 step 3) answers the common replay without any lock; the authoritative check is
step 7, taken UNDER the counter lock and BEFORE the counter UPDATE. Because the counter lock is the same lock that orders all postings, two
same-key postings cannot both pass step 7: the second sees the first's committed header. The unique indexes on `client_op_id` and
`origin_key` are the backstop only (a `23505` there is a defect-class event mapped to `idempotency_key_reuse` with the existing row's id
omitted). No advisory lock is used. Rejected: an advisory lock keyed on the `client_op_id` hash (an extra lock class that 0061 would have to
list) and `ON CONFLICT` after the counter increment (it would burn the number and need a controlled abort).

### 9.4 `expected_version` (0058 c.2) and mutable resources

The ledger has no client-mutable resource: headers and legs are immutable, `stock_balance` and the counter are platform-written. The
requirement is met as follows: (a) a posting that refers to a mutable ENTITY record (a document line record) may carry
`expected_document_version` (the record's `last_event_global_seq`); the module policy (step 2) compares it with the current record
(through the read facade, 14.4) and returns the existing `record_version_conflict` 409 on mismatch (S12); (b) a reversal states the version of the thing it
reverses in the only form that exists for an immutable target: its identity plus "not yet reversed", which is the typed
`movement_already_reversed` 409 (section 10); (c) entity-store masters keep their own `expected_last_event_global_seq` (S12).

### 9.5 Retire/cancel is a tombstone (0058 c.7)

No ledger row is ever deleted (5.2); a zero `stock_balance` row stays; "cancelling" a posting is a reversal, not a delete. Retiring an item or location sets `active=false` on the entity master (not this slice); the policy (14.4) refuses NEW stock-adding legs (`receipt`, `return`, transfer destinations) to a retired item or location with 422/409 `master_inactive`, and always allows stock-removing legs and reversals so stock can be drained. Facts already true (0058 b) are a REQ-480 flag, out of scope.

## 10. Reversal

* A reversal is a NEW header, `cause = 'reversal'`, `reverses_header_id = target`, legs = the exact negation of the target's legs (same keys, same base unit, original quantity negated), `reason_code` required, its own `event_time` (C-3), its own `posting_seq`, `document_id` and `correlation_id` default to the target's.
* **Refused**: unknown target -> `movement_not_found` (denied == absent: the same body for a target of another tenant, which cannot be named anyway because tables are per-tenant, and for a malformed id); a target that already has a reversal -> `movement_already_reversed` (409); a target that is itself a reversal -> `movement_is_reversal` (409) ("reversal of a reversed header is refused" in both readings: reversing the reversed original and reversing the reversal).
* Race: two concurrent reversals of one header serialise on the balance keys (same keys) and, with the idempotency lock, only one passes; the other re-checks "already reversed" under the balance locks (the check is part of step 4-5, under the key locks) and is refused. The partial unique index is the backstop (a `23505` on it maps to `movement_already_reversed`).
* The guard applies: reversing a receipt whose stock was partly issued is refused `insufficient_stock` (practice: the correction needs a new document).
* No partial reversal and no reversal "in the past": a correction of a quantity is a reversal plus a new posting, or an `adjustment`.
* Permission: `:StockReverse` (separate from `:StockPost`, separation of duties).

## 11. `stock_balance` and the reconciliation read

### 11.1 Maintenance

Updated only by `StockLedger.post` in step 8, after the guard, under the held row lock, in the same transaction as the legs. `on_hand` of a key after
posting `n` equals the sum of the key's legs with `posting_seq <= n` (invariant I-BAL). It is never the source of truth and never read for a report or a cut-off; it is read only inside the guard.

### 11.2 Reconciliation (`StockLedger.reconcile/2`)

A read-only, `REPEATABLE READ READ ONLY` snapshot: for the key range (optionally chunked by key cursor), `FULL OUTER JOIN` of `stock_balance` and `SELECT key, SUM(quantity_base) ... GROUP BY key` over legs of the same snapshot; reports every key where the two differ or one side is missing (a missing balance row for a key with legs, a balance with no legs and `on_hand <> 0`), plus the sequence check `count(header) = max(posting_seq) = counter.last_seq`. Result: `%{checked_through_seq, mismatches: [%{key, balance, ledger_sum}], gap_check: :ok | {:gap, ...}}`. It repairs nothing (OQ-9). Permission `:StockLedgerReconcile`. Cost grows with the legs; chunking is part of the interface.

## 12. Errors (typed, closed, machine-readable)

### 12.1 Envelope

The existing refusal body `{"error": code, "line_index": n}` (S6) gains an optional third key `"details"` ONLY for the codes of the table below (all other codes keep their exact bytes; golden test). `details` holds ids and closed enums, never free text or exception text (INV-4/8). The status table of `Response.entity_write_status/1` (`api/response.ex:311-314`) gains the 409 rows. HUMAN path: `routers/tasks.ex:456-463` renders them.

### 12.2 Codes

| Code | HTTP | When | `details` (machine-readable) |
|---|---|---|---|
| `insufficient_stock` | 409 | guard (step 5) or the CHECK backstop | `{"legs": [{"leg_no": n, "item_id", "location_id", "dimensions": {...}, "requested": "<decimal string>", "available": "<decimal string>"}]}`; `available` appears ONLY when the subject holds `:StockLedgerRead`, otherwise the key is omitted (the id echo is the caller's own input) |
| `movement_not_balanced` | 409 | a transfer/status_change/reversal sum is not zero per item (checked before any lock; the deferred trigger is the backstop) | `{"item_ids": [...]}` |
| `movement_already_reversed` | 409 | section 10 | `{"movement_id": ...}` (the caller named it) |
| `movement_is_reversal` | 409 | section 10 | `{"movement_id": ...}` |
| `idempotency_key_reuse` | 409 | 9.2 | `{}` |
| `record_version_conflict` | 409 | 9.4 (existing code) | as today |
| `master_inactive` | 409 | 9.5 | `{"kind": "item"|"location", "leg_no": n}` |
| `event_time_in_future` | 422 | 8.1 | `{}` |
| `invalid_posting` | 422 | shape, float, scale, sign-per-cause, leg cap | `{"leg_no": n|null, "reason": <closed enum>}` |
| `validation_failed` (reason `movement_not_found`) | 422 | a reversal target that is unknown, malformed or not visible; the engine envelope has no 404 and a handler refusal is a step refusal, so it is the existing 422 class with `reason` in `details`, byte-identical for unknown and malformed ids | `{"reason": "movement_not_found"}` |
| `write_not_permitted` | 403 | no permission, wrong origin (`ledger_origin_not_supported`), stamp/hash failure | none (one body, INV-5) |
| `entity_write_contention` | 503 | 7.5 | none |
| duplicate (not an error) | 200/201 | 9.2 | result `duplicate: true` |

`line_index` is the declared index of the `module_writes` line (as for every handler refusal). The ledger step's Multi step names are
`{:line, key, :ledger_post}` inside the call's own `{:line, k0+1..k0+49, _}` range (`handler_writes.ex` contract: names outside the range are a contract violation), so the engine's `interpret_failure/2` maps a failed `:ledger_post` step through the new clause below.

### 12.3 Failure carrier

A `:ledger_post` step failure value is a closed tuple `{:ledger_refused, code_atom, details_map}`; `interpret_failure/2` (R4b's mapping in `StepWrites`/`HandlerWrites`, `handler_writes.ex` platform-facing functions) gains one clause turning it into `{:entity_write_refused, line_index, code}` carrying `details` to `Response.entity_write_refused/4` (new arity). Nothing from an exception reaches a body.

## 13. Test plan

New files (all `async: false`; the concurrency ones in Sandbox `:auto` with real commits, style of `Letflow.LockOrderHelpers`, S16; names are the proposal):

| Id | File | Case |
|---|---|---|
| T-AC1 | `stock_ledger/post_balance_test.exs` | a `transfer` whose legs do not sum to zero per item is refused `movement_not_balanced` before any lock and the counter is unchanged; one that sums to zero posts; a `receipt` with a negative leg and an `issue` with a positive leg are `invalid_posting` |
| T-AC2 | `stock_ledger/concurrent_no_negative_test.exs` | on hand 10 at one item+location; two concurrent `issue` of 6, forced overlap: both park on the balance row (barrier row held by Z), release Z: EXACTLY ONE posts, the other `insufficient_stock` with `details.legs[0]`; balance 4; leg sum 4; counter advanced by exactly 1 |
| T-AC3 | `stock_ledger/reversal_test.exs` | reversal of a reversed header -> `movement_already_reversed`; reversal of a reversal -> `movement_is_reversal`; reversal of a receipt partly issued -> `insufficient_stock`; two concurrent reversals of one header: one wins; unknown/malformed id -> the one `movement_not_found` body |
| T-AC4 | `stock_ledger/cutoff_test.exs` | post 5 movements, record `N=3` balances from legs `posting_seq <= 3`; post 2 more (one late with an earlier `event_time`); the as-posted report at `N=3` is byte-identical; the event-time report `(T, N=3)` is byte-identical, `(T, N=7)` includes the late one; the report states basis, cutoff, tz, ledger_seq |
| T-AC5 | `stock_ledger/balance_reconcile_test.exs` | after every posting of a StreamData sequence of random postings and reversals `stock_balance == SUM(legs)` per key (property); then a deliberately corrupted `on_hand` (set through a test-only `session_replication_role` bypass inside a throwaway tenant) is reported by `reconcile/2` with key, balance and ledger sum; a missing balance row is reported; a gap injected is reported by the gap check |
| T-AC6 | `stock_ledger/idempotency_test.exs` | same `client_op_id` and payload twice: one header, second returns the same `movement_id`, `duplicate: true`, counter advanced once; same key different payload -> `idempotency_key_reuse`; `sys:`-prefixed key refused; two concurrent same-key posts: one header, both return the same id; two tasks of one process carrying one `client_op_id`: the second completion succeeds with no second posting |
| T-GF-1 | `stock_ledger/gap_free_test.exs` | forced overlap at the counter: Z holds the counter row; T1 and T2 park there after their balance locks; release; seq values consecutive and commit order equals seq order (read `xmin`/commit order via a deferred probe row) |
| T-GF-2 | same | T1 fails after the counter UPDATE (test seam that raises in step 8) and rolls back while T2 is parked: T2 commits with the number T1 had; `max(posting_seq) = count(*)` |
| T-GF-3 | same | the isolation level of the posting transaction is READ COMMITTED (pinned); a 100-posting concurrent soak (4 workers, bounded, within the machine limits) ends with `1..100`, no gap, no duplicate |
| T-LK-1 | `stock_ledger/lock_order_test.exs` | postings with opposite item order `[(A,B)]` and `[(B,A)]` in forced overlap: no `40P01` reported by the telemetry handler (`attach_error_handler/1`), both commit; a step-name probe asserts the order balance keys ascending then counter |
| T-LK-2 | same | a HUMAN completion that posts and a HUMAN completion that writes class 6 only, in overlap on the audit chain row: no deadlock; the order class 5, ledger, audit chain row is asserted by a probe on the step names |
| T-LK-3 | same | Z holds the counter longer than the lock timeout (`engine_test_seams` override to ~300 ms): the poster returns 503 `entity_write_contention`, nothing committed, counter unchanged (no gap), the telemetry handler reports `55P03` |
| T-LK-4 | same | the SERVICE origin: a posting handler on a SERVICE_TASK node is refused (`write_not_permitted`, ERROR + DLQ), nothing written |
| T-AO-1 | `migrations/stock_ledger_migration_test.exs` | tenant replay creates the four tables and the seed row; `UPDATE`, `DELETE`, `TRUNCATE` on header and legs raise the fixed text; a header inserted with a made-up `posting_seq`, a counter bump by 2, a counter UPDATE without a header at commit, a leg whose copied `posting_seq` differs from its header, a reversal of a reversal, a second reversal of one header, a transfer not summing to zero (raw SQL) are each refused by the database; `expected_tenant_tables/0` updated |
| T-OFF-1 | `stock_ledger/offline_fields_test.exs` | `client_op_id`, `device_id`, `client_seq`, `client_event_time` stored and returned; `(device_id, client_seq)` unique; `device_id` without `client_seq` refused; a late `client_event_time` is kept as `event_time` while `posting_time`/`posting_seq` are the server's; a future `client_event_time` beyond the tolerance -> `event_time_in_future` |
| T-ERR-1 | `engine/ledger_failure_mapping_test.exs` | each code of 12.2 once: status, `line_index`, `details` shape exact; `available` omitted without `:StockLedgerRead`; byte-identity of every pre-existing refusal body (golden); no exception text, no stack |
| T-SEC-1 | `stock_ledger/security_test.exs` | two-tenant: tenant B's prefix never reads tenant A's headers/legs/balances and a reversal naming A's `movement_id` under B is the `movement_not_found` body; a subject without `:StockPost` is `write_not_permitted` byte-identical to every other cause; SQL text of every ledger statement contains no value (bound parameters; assert via a telemetry capture of the query text) |
| T-SC-1 | `entities/stock_ledger_callers_test.exs` | scan: only `lib/letflow/stock_ledger/**` names the tables/schemas; `StockLedger.post` has the single caller `HandlerWrites.post/3`; H4 allows exactly `create/3` and `post/3` |
| T-MIG-1 | with #2658 | adding a nullable dimension column to a populated ledger leaves posted rows byte-identical and sums unchanged (#2658's AC, run on these tables) |
| T-LD-1 | `stock_ledger/counter_throughput_test.exs` (tagged, not in CI default) | measured postings/s at 1, 2, 4 workers on one tenant; the number is written into the runbook; the pilot gate NF-01/NF-02 |

## 14. Interfaces

### 14.1 `Letflow.StockLedger` (core, `lib/letflow/stock_ledger/`; the only module that touches the ledger tables)

```
@type cause :: :receipt | :issue | :transfer | :return | :status_change | :adjustment | :reversal
@type posting_command :: %{required(:cause) => cause(), required(:client_op_id) => String.t(), optional(atom()) => term()}   # closed keys, 9.1
@type posted :: %{movement_id: Ecto.UUID.t(), posting_seq: pos_integer(), duplicate: boolean()}
@type refusal :: {:ledger_refused, code :: atom(), details :: map()}

@spec post(Ecto.Repo.t() | module(), HandlerContext.t(), posting_command()) :: {:ok, posted()} | {:error, refusal()}
@spec balances(prefix :: String.t(), basis(), filters :: map()) :: {:ok, report()} | {:error, :cutoff_in_future | :invalid_filter}
@spec movements(prefix :: String.t(), filters :: map(), page :: map()) :: {:ok, page_result()}
@spec fetch_by_client_op_id(prefix :: String.t(), String.t()) :: {:ok, posted()} | {:error, :not_found}
@spec reconcile(prefix :: String.t(), opts :: map()) :: {:ok, reconciliation()}
@type basis :: {:posting_seq, non_neg_integer() | :latest} | {:event_time, DateTime.t(), known_through :: non_neg_integer() | :latest}
```

`post/3` runs inside a Multi step (`Ecto.Multi.run`), never opens its own transaction (it asserts it is inside one). The read functions are
plain reads with the tenant prefix from the caller's authorised context.

### 14.2 `Letflow.Entities.HandlerWrites.post/3` (the one new handler-facing function)

```
@spec post(Ecto.Multi.t(), HandlerContext.t(), posting_command()) ::
        {:ok, Ecto.Multi.t()} | {:error, :invalid_posting | :too_many_postings | :ledger_not_registered}
```

Same discipline as `create/3`: per-call token, context must be the exact one built for this call, step names confined to the call's range
(`{:line, key, :ledger_post}`), at most one posting per handler call (and 200 legs per completion), requires the handler's registration to
carry `posts_ledger: true` (a new optional key of the `write_handlers` entry, validated by Catalog rule 10; `:ledger_not_registered` otherwise). The
handler is pure: it computes the command from its arguments and returns. Scan H4 is amended from "any `HandlerWrites` call but `create/3`" to "but `create/3` and `post/3`".

### 14.3 Manifest additions (module `stock`, proposed)

`write_handlers` entries with `posts_ledger: true` (e.g. `post_receipt`, `post_issue`, `post_transfer`, `post_status_change`, `post_adjustment`, `post_reversal`); `ledger_policy: {Mod, :fun}` (one policy callback module under the module namespace); permissions `:StockPost`, `:StockReverse`, `:StockLedgerRead`, `:StockLedgerReconcile`; `depends_on ["org", "catalog_items"]`; `role_grants` decided in the module skeleton slice (NOT VERIFIED role list; defaults in OQ-11). The module id `stock` and entry `Letflow.Modules.Stock` are proposals (NOT FOUND on main).

### 14.4 The policy callback (module logic that needs reads) and the read facade

```
@callback validate(prefix :: String.t(), posting_command()) :: {:ok, normalised_command()} | {:error, atom()}
```

Run by `StockLedger.post` at step 2 through a Catalog `apply/3` on registered data (the D-R.1 pattern: the Catalog is the single resolver and
apply site; no core file names a module file, Rule 1/6 of `mix letflow.check_boundaries`). It may read through the module's own read API (`Org.active?/2`,
`CatalogItems.item_uom_valid?/3`; #2662/#2664, NOT FOUND today) with NO lock and NO write; it is not a handler file, so H4 does not scan it, and
it gets its own scan (no `Repo.update_*`, no `lock`, no `Multi`). This callback is the "narrow read facade" that `gh2590...md:1099` defers; it is
narrower than a facade because the module cannot choose a lock or a table of the ledger. A module that wants the REQ-504 conversion
implements it here.

### 14.5 No event schema change

The `TASK_ENTITY_WRITES_APPLIED` v2 line items have `additionalProperties: false` (`gh2590...md` F-1); adding `movement_id` would force a v3 in-place seed bump. This
design does NOT: the ledger header carries `bpm_task_id`/`bpm_instance_id`, so the link is ledger-to-task; the reverse lookup is `movements/3` by `bpm_task_id`. (OQ-12.)

## 15. Decision records needed

* **0062 (proposed number, title): "Stock ledger primitive: platform-owned append-only ledger tables, gap-free counter, handler-facing `post/3`".** Content: D-L1, D-L2, D-L3, D-L4 (class 5b), D-L11, D-L12; amends the wording of 0057 D5 ("the guard runs inside the module write handler" -> reached from the handler call by `post/3`); amends gh2590 D-R.5 (handler API: `create/3` and `post/3`); lists the S19 FK rule. REVIEWER and SECURITY-REVIEWER sign it. Written by the L0 PR, NOT by this issue.
* **Amendment of 0061 (same L3 PR as the code, rule 5):** "Rule 1 gains class 5b between 5 and 6: the stock ledger's balance rows ascending by key, then the single `stock_ledger_counter` row. Taken only after the entity-type rows and before the audit chain row. A transaction that holds the audit chain row never takes a ledger row, so the SERVICE origin is refused until its pre-lock exists (7.4)." with the forced-overlap tests T-LK-1..4.
* **0058 note:** none needed; item 1 (columns), 2 and 7 are satisfied by 9.4 and 9.5; item 4 (typed 409 with details) by 12; items 5, 6, 8 are REQ-480.

## 16. Security

* **Tenant scoping (INV-1).** The tables are per tenant schema; the prefix comes from the engine's authorised context (`HandlerContext.prefix` set by `HandlerWrites`, `gh2590...md:967`), never from a command field; every statement passes `prefix:`; there is no `tenant_id` column to forge. A cross-tenant id in a command is simply absent in the other schema.
* **Who may post.** BPM decides when/who/which route; the platform step additionally requires the SUBJECT's role to carry `:StockPost` (`:StockReverse` for a reversal), checked with `Authorization.role_allows?/2` against the module's `role_grants` (`authorization.ex:1518-1520`, guide section 3). The completer must also be the task's assignee (engine, unchanged). `RecordAccess`/`TypeAccess` (`record_access.ex:43`, `type_access.ex:73`) govern the entity-store documents the module also writes; the ledger tables are NOT entity types, so `TypeAccess` and `FieldGrants` do not apply to them and `:StockLedgerRead` is the read gate (a new permission, T-SEC-1). `ActorCapabilities`: NOT FOUND. Location/warehouse scoping of a posting by 0051 scope grants (0058 a) is NOT in this issue: slice 1 is permission-only within the tenant (OQ-13); the `scope_node_paths` lock of 0054 D3 rule 3a does not apply (the ledger tables are unscoped, S20).
* **Denied == absent (INV-5).** Every authorisation, stamp, origin and target refusal is the one `write_not_permitted` body; `movement_not_found` is one body for unknown and malformed ids.
* **No tenant data in errors/logs (INV-2/4).** Refusals carry ids and closed enums only; `available` is permission-gated; no exception text; logging at the posting step is ids and counts only; the `23514` backstop log carries `movement`-less ids only.
* **SQL (INV-7).** Ecto query composition with bound parameters and the `prefix:` option; the only literal SQL is the migration's trigger/function text (fixed, no interpolation of tenant data; the tenant schema name comes from `prefix()` as in S9).
* **Lock/DoS.** A hot item/location serialises its postings FIFO for at most 2 s then 503; a holder is bounded by 5 s statement and 10 s wall guard; legs/posting 200, postings/handler call 1, legs/completion 200, lines/node 20; the counter is a tenant-wide convoy point (already the case for the audit chain row, S8). A malicious task completer cannot hold a lock beyond one completion transaction. The `allow_negative`-style bypass does not exist. Oversized `details` impossible (leg cap).
* **What SECURITY-REVIEWER must check:** (1) the trigger set blocks UPDATE/DELETE/TRUNCATE and the residuals of 5.1 are accepted; (2) the single-writer scan and that `post/3` cannot be reached with a forged context or from a non-handler; (3) the origin refusal and the 7.4 cycle; (4) `details` disclosure and the permission gate; (5) the policy callback cannot write or lock; (6) idempotency keys cannot collide with `sys:` and cannot leak another tenant's movement; (7) INV-5 byte-identity golden for old refusals; (8) the migration is in the provisioning list and replay is idempotent; (9) no FK to engine tables; (10) the `23514` path never reveals balance.

## 17. Implementation slicing (proposal; each slice one PR, serial merge per `core-directives.md`)

| Slice | Content | Size | Depends on |
|---|---|---|---|
| L0 | decision 0062, 0061 amendment text, 0057 D5 wording note (docs only) | S | this note accepted by CDV and SUPERVISOR (OQ-1) |
| L1 | migration(s): four tables, seed counter row, all triggers and deferred triggers, provisioning entries, `expected_tenant_tables` oracle, schemas, migration tests T-AO-1 | M (~700 LOC + tests) | design notes #2658 and #2660 accepted (columns); L0 |
| L2a | `Letflow.StockLedger.post/3` core: algorithm 7.1 for the five kinds, guard, counter, idempotency, offline fields, balance maintenance; concurrency tests T-AC1/2/6, T-GF-*, T-LK-1/3, T-OFF-1 | L (~900 + tests) | L1 |
| L2b | reversal, `balances/3`, `movements/3`, `reconcile/2`, basis/cut-off, T-AC3/4/5, T-RP | M | L2a |
| L3 | `HandlerWrites.post/3`, Catalog `posts_ledger` and `ledger_policy` validation, H4 amendment, failure carrier and the 409 envelope, 0061 amendment, engine lock-order tests T-LK-2/4, T-ERR-1, T-SC-1, T-SEC-1; fixture module with a posting handler | L | L2a, REQ-501 R1-R5 (all merged) |
| L4 | module `stock` skeleton: manifest, permissions, role_grants, policy callback with master checks, read routes (balances, movements, reconcile) behind `:StockLedgerRead`, runbook limits | L | L3, #2661/#2662 and #2663/#2664 (masters + read APIs) |
| L5 | SERVICE-origin pre-locks (7.4) and removal of the refusal | M | L3, a plan-time argument-resolution design |

Explicitly OUT of this issue and its slices: REQ-503 behaviour (quarantine flows, serial uniqueness, owner/custodian transfer, available-to-pick; its
design is #2658); REQ-504 conversion, rounding rule, tolerance and the unit scale (its design is #2660; this note only reserves the
columns and the policy callback); the 1C/SAP acknowledgment table (G9); the command log and lease (REQ-480); counts and variance
approval (WM-12 behaviour); document issuing (REQ-488); allocation/FEFO; per-warehouse scoping of postings; a balance repair action.

## 18. Acceptance-criteria map (issue #2657 and its comment)

| AC | Where |
|---|---|
| Note names the tables, append-only enforcement, sequence with proof under two concurrent postings, the lock order; claims cited or NOT FOUND | 4, 5, 6.2, 7; 2 |
| Event time of a late-synchronised movement (G7); report time basis and cut-off | 8 |
| Test plan: unbalanced transfer refused; two concurrent postings below zero leave one; reversal of reversed refused; balance at cut-off N; cache equals sum and reconciliation reports corruption; duplicate key posts once with the same operation id | 13 T-AC1..T-AC6 |
| Prerequisite carried; REQ-501 ACs not on main listed | 1.1 (only the update/read/lock facade is missing; handled by D-L1) |
| CDV passes; SECURITY-REVIEWER is a gate | 16 (reviewer checklist); L3/L1 PRs |
| Offline: `client_op_id`, `device_id`, per-device `client_seq`, `client_event_time` stored beside `posting_seq` and posting time | 4.2, 9.1, T-OFF-1 |
| Offline: typed 409 with machine-readable details, at least `insufficient_stock` | 12 |
| Offline: `expected_version` on mutable resources, typed conflict | 9.4 |
| Offline: retire/cancel is a tombstone | 9.5, 5.2 |
| Quantities per D4 and the interim shape until #2654 | 1.2 (#2654 shipped; Postgres `numeric(30,9)`; parser S14) |
| REQ-503 and REQ-504 columns by reference | 4.5 |

## 19. Open questions for the supervisor (recommended default each)

| Id | Question | Recommended default |
|---|---|---|
| OQ-1 | Accept D-L1 (platform ledger primitive + `HandlerWrites.post/3`, new decision 0062) instead of extending REQ-501 with a generic read/lock/update facade or giving module code a scoped repo? | Accept D-L1. It is the smallest primitive that keeps the handler pure and the lock order in one place. |
| OQ-2 | One sequence per tenant or per warehouse? | Per tenant now; per-warehouse only if T-LD-1 shows the convoy is a problem (it needs a per-site counter table and a cut-off per site; a cross-site transfer would then need two numbers). |
| OQ-3 | Allow negative stock by item/location policy? | No in slice 1 (D5). The CHECK stays. A policy switch is a later decision. |
| OQ-4 | Future-event tolerance and any lateness bound? | Tolerance 5 minutes (config), no lower bound (the offline lease bounds it). |
| OQ-5 | Include a nullable `site_id` copy on the header now? | Yes (append-only tables cannot be back-filled later), filled by the policy when known, not in any balance key. |
| OQ-6 | Is the duplicate decided under the counter lock (9.3, no advisory lock, no burned number)? | Yes, as written; the unique indexes are only the backstop. |
| OQ-7 | `available` in `insufficient_stock.details`: always, or only with `:StockLedgerRead`? | Only with `:StockLedgerRead`; the pick UI that needs it gets that permission. |
| OQ-8 | Caps: 200 legs per posting and per completion, 1 posting per handler call? | Yes. |
| OQ-9 | Should `reconcile/2` ever repair a balance? | No; read-only. A repair (rebuild from legs under a locked tenant) is its own design. |
| OQ-10 | Quantity column type `numeric(30,9)` until REQ-504 fixes scales? | Yes; the poster refuses more than 9 fractional digits and never rounds. |
| OQ-11 | Role grants for `:StockPost`, `:StockReverse`, `:StockLedgerRead`, `:StockLedgerReconcile`? | `:StockPost` and `:StockLedgerRead` to the task-worker role; `:StockReverse` and `:StockLedgerReconcile` to the tenant admin and auditor roles only. The real role list is NOT VERIFIED here; decided in L4. |
| OQ-12 | Put `movement_id` into the APPLIED event? | No (it needs a v3 seed bump); reverse lookup by `bpm_task_id`. |
| OQ-13 | Warehouse/zone scoping of postings (0051/0058 a) in this series? | Out; permission-only now; revisit with REQ-480 leases. |

## 20. Risks for CODE-DESIGN-VALIDATOR to attack first

1. **V1 / D-L1**: that a core ledger primitive honours "the guard runs in the module write handler" (D5) and the layering of 0039; and that no cheaper route exists with the merged REQ-501 contract.
2. **The gap-free proof (6.2)**: the counter-last order, the READ COMMITTED `FOR UPDATE` recheck, F5 (visibility before lock release, argued from PostgreSQL commit internals, not run here), and whether the deferred trigger of 5.3 closes "incremented but no header". Also the duplicate path (step 7, F6): the counter lock is taken but the UPDATE is skipped.
3. **The SERVICE-origin cycle (7.4)** is asserted by reading `engine.ex:400-410`; the interleaving is derived, not run.
4. **Class 5b**: that no HUMAN-path statement between the handler and the commit takes a class below 6 after the ledger (the tail list in S3 is from the moduledoc, not a statement-by-statement trace).
5. **Throughput** of the single counter is an estimate (NOT MEASURED).
6. **Dimension columns by reference**: 4.5 depends on #2658/#2660 stating the balance key and sentinels.
7. **Trigger residuals**: owner can disable triggers; `session_replication_role`.
