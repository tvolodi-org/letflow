# 0073 -- Domain-neutral ledger primitive: platform-owned append-only ledger tables, gap-free counter per ledger id, handler-facing post/3

Status: Accepted: route R-N ruled by the advisor letflow-ec (2026-10-19); OQ-19, OQ-20 and OQ-21 taken as the note's defaults; drafted by CODE-DESIGNER in task T-0887. Implementation: WMS stock ledger slices L1..L7 (GH #2657, REQ-616 is slice L0).

Date: 2026-10-28

Related: 0039 D1, 0054 D4a and its Correction (advisor, option A, 2026-10-15), 0057 D5, 0058 (c), 0060, 0061, GH #2657, GH #2532, GH #2590, REQ-499, REQ-501, REQ-502, REQ-503, REQ-504, REQ-616

Source: `lib/letflow/design/gh2657-wms-stock-ledger-core.md` (revision 5), sections 3, 3.5, 4.6, 5.1, 5.4, 7.5, 8.3, 12.2, 15, 17, 19 and 20.

This record writes no code, no migration, no seed and no test. It fixes the route, the rulings and the wording of the source note so that slices L1..L7 can start. The note calls this record "0062 (proposed)"; 0062 is taken by `0062-restriction-carrying-variables.md`, so the record is 0073. It edits none of 0039, 0054, 0057 and 0061; the wording it amends is stated here and applied by the slices named below.

## Problem

The WMS stock ledger needs four things that the existing engine does not give: a gap-free, queryable posting sequence; an atomic multi-leg posting; a no-negative-balance guard that runs under row locks taken in a fixed order (decision 0057 D5); and append-only storage enforced in the database. The merged REQ-501 module write-handler contract is create-only (note section 0, V1): a handler can write new records through `create/3`, has no update kind and no read, so it cannot by itself run the 0057 D5 guard.

The planned answer was route R-D: managed entity types for header, leg and balance, update-kind handler writes plus a narrow read facade (`lib/letflow/design/gh2590-req501-module-write-handlers.md`, F-R5, D-R.17, OQ-R4), scheduled for WMS slice 5. The advisor letflow-ec ruled on 2026-10-19 that this route does not fit (OQ-1 closed) and adopted a domain-neutral core posting primitive instead (route R-N). The remaining questions are the relation of that primitive to 0039 D1 (core names no business domain), the wording of 0057 D5, what the 0054 Correction still requires of module code, and the lock order.

Roadmap blockers of `docs/migration/core-roadmap-20261014.md`, "WMS slice 5 (stock ledger)", state re-derived on origin/main at 2026-10-28:

1. REQ-499 (GH #2587): `status: done` in `docs/requirements.yaml`; PRs C1 `2b628b534` and C2 `3d1579bb6` merged.
2. REQ-501 (GH #2590): `status: done`.
3. GH #2583: closed (`gh api repos/tvolodi-org/letflow/issues/2583 --jq .state` prints `closed`).
4. "The ledger type declares managed_by and posts only in a module write handler": a rule the ledger slices follow, satisfied by route R-N. Posting runs only through `HandlerWrites.post/3`, called from a module write handler, never as a declarative `entity_write`.

Gate of slice L0 (note sections 17 and 18): the two amendments of the #2657 acceptance criteria are recorded as comments on GH #2657: AMENDMENT 1 (comment id 6259361954, 2026-10-19) and AMENDMENT 2 (comment id 6260381925, 2026-10-19). AMENDMENT 1 amends the 0058 (c) items 2 and 7, master-side parts, which move to slice L7.

## Decision

**D1 Route R-N adopted, route R-D rejected.** Route R-N, a domain-neutral core posting primitive, is adopted: the core context `Letflow.Ledger` (directory `lib/letflow/ledger/`), reached from a module write handler by `HandlerWrites.post/3`. Ruled by the advisor letflow-ec, 2026-10-19. Route R-D (entity-type ledger through update-kind handler writes plus a read facade) is rejected, with the ruling's reasons (note section 3.2):

* it cannot give a gap-free queryable posting sequence (the only gap-free number is the header type's per-type sequence number in the event stream; exposing it as a field needs a new core "system field" feature);
* it cannot give an atomic multi-leg posting beyond 49 creates per handler call and 20 lines per node;
* row locks in a fixed order are not expressible: the guard serialises on the balance TYPE row tenant-wide, whereas 0057 D5 wants item and location rows in a fixed order;
* append-only would hold only at the Records layer (no database trigger exists for entity records);
* each leg and each balance update costs one event, one projection row and one audit entry.

The two core changes that make a neutral primitive justifiable are already accepted: `append_only` entity types (decision 0054, `entity_append_only`) and the `non_negative`, `min` and `max` bounds (GH #2532, closed; decision 0057).

**D2 Relation to 0039 D1, and the boundary rules.** Core names no business domain. The vocabulary core may use is: ledger, entry, leg, balance, balance key, counter, quantity. Dimensions are an opaque ordered tuple of text slots. There is no item, location, stock, warehouse or site vocabulary, no cause list, no hard-coded permission atom, no business error code and no business CHECK in core; the module registers all of that in its manifest. In the words of note section 3.5:

> **Rule 7 (neutral vocabulary).** SCOPE: every file under `lib/letflow/ledger/**`, the ledger migration, `lib/letflow/modules/ledger_registration.ex` (the rule-12 validator and accessor), and the ledger parts of shared files, which therefore live in their OWN files so the scan can cover them: `lib/letflow/ledger/handler_post.ex` (the implementation behind `HandlerWrites.post/3`, a one-line delegate), `lib/letflow/ledger/failure.ex` (the clause `StepWrites.interpret_failure/2` delegates to) and `lib/letflow/ledger/codes.ex` (the neutral code list and its HTTP status table, which `api/response.ex` delegates to). SCAN UNIT: the Elixir AST (`Code.string_to_quoted`) of each file; the tokens are identifiers (atoms, variables, function and module names) and string literals; each token is split on `_`, on non-alphanumerics and on camelCase boundaries into lowercase words; COMMENTS, `@moduledoc` and `@doc` are excluded. A word fails the check when it EQUALS a denylist entry or the entry plus a plural suffix (`s`, `es`): denylist `stock, item, location, warehouse, site, lot, serial, sku, material, inventory, bin, pallet`. So `stock_movement`, `insufficient_stock`, `:StockPost`, `items`, `locations` fail; `insufficient_balance` passes; `binary`, `website` and `lottery` are different whole words and pass. The denylist is a reviewed constant, and a new allowlist pair or a new denylist entry is added ONLY by a reviewed diff. **Reviewed allowlist for migration SQL:** SQL is a string literal tokenised the same way, and Postgres vocabulary can collide (`serial`/`bigserial` is a column type keyword); the allowlist is a short reviewed list of `{file, word}` pairs (initially empty; the ledger migration uses `bigint`, so no entry is expected), and a new pair is a one-line reviewed diff.

> **Rule 7b (no module reference).** The scanned files may not reference any `Letflow.Modules.*` name except `Letflow.Modules.LedgerRegistration`.

> **Rule 8 (single call site, and no forgery).** A call-site scan (a new function in the `check_boundaries` task that parses every `lib/**` file's AST; the existing task classifies file-level xref edges only, S23) over the module subdirectories `lib/letflow/modules/<id>/**` and Lua/WASM host code (`lib/letflow/scripts/**` and the host-function modules): (a) `Letflow.Ledger.post` and `Letflow.Ledger.Capability.mint` are called only from `lib/letflow/ledger/handler_post.ex`; (b) module and host code may call the authorised READ functions of 14.1, nothing else of `Letflow.Ledger`; (c) **no struct literal, struct pattern match, `%{__struct__: ...}` or alias of `Letflow.Ledger.Capability`, `Letflow.Ledger.Authorized` or `Letflow.Api.Scope.Principal`** appears there (a module could otherwise write `%Principal{kind: :token, grants: :token}`, which `Scope.allowed_set/2` answers `{:ok, :all}`, and mint an `authorized` value; `Scope.Principal` is a plain public struct, `api/scope.ex:99-106`); (d) no `apply/3`, `Kernel.apply`, `:erlang.apply`, `Module.concat`, `Module.safe_concat` or `String.to_existing_atom` that could build a `Letflow.Ledger` or `Principal` name; (e) the policy files named by a registration's `policy:` may reference only `Letflow.Ledger.Policy` among `Letflow.*` names (14.4). EXEMPTIONS (explicit, reviewed): `lib/letflow/modules/ledger_registration.ex` (it is under `modules/` but not a module subdirectory, so it is outside the scan scope by construction) and `lib/letflow/ledger/**`. TEST SEAM (T-SC-4): the scan is a pure function `violations([{path, source_text}])`, so the test feeds synthetic sources and asserts the exact violation tuples. Optional hardening (OQ-24, default no): a MAC or nonce on `Capability` and `Authorized` verified by core.

Second plausible consumers (the 0039 D1 test): a spare-part store of a CMMS (issues and returns against a non-negative on-hand with gap-free document numbers) and HR leave balances (accrual and usage legs, non-negative balance, reversal by a new entry). Neither is built; each would register a different ledger id, slots and causes with no core change. The primitive is otherwise justified as a platform feature by the two accepted core changes named in D1 (`append_only` entity types, decision 0054; `non_negative`/`min`/`max` bounds, GH #2532, decision 0057). **Rule 7 ships in the same PR as the ledger tables (slice L1).**

**D3 D-E: neutral core error codes, module aliases.** Core error codes are neutral; a module maps them to wire codes through the registration's `error_aliases`. The closed aliasable set is: `insufficient_balance`, `balance_bound_exceeded`, `unit_mismatch`, `posting_not_balanced`, `posting_already_reversed`, `posting_is_reversal`. Example: the stock module registers `error_aliases: %{"insufficient_balance" => "insufficient_stock"}`, so its clients see only `insufficient_stock` while core says `insufficient_balance`. Alias rules (note section 12.2): an alias VALUE matches `[a-z_]{1,48}` and is disjoint from every core, engine, entity and ledger wire code (`write_not_permitted`, `entity_write_contention`, `idempotency_key_reuse`, `validation_failed`, `record_version_conflict`, `entity_append_only`, ...; the full list is a reviewed constant in `ledger/codes.ex`), injective within one registration, and disjoint from the aliases of every other installed module. The HTTP status always follows the CORE code. Audit, logs and metrics record the NEUTRAL core code, never the alias; the keys of `details` come from the registration's slot names, never from names hard-coded in core. Owner confirmation OQ-19: yes (D9).

**D4 Amended wording of 0057 D5.** 0057 is NOT edited by this record. Old wording (0057 D5): "The no-negative guard runs inside the module write handler (REQ-501 mechanism) under row locks in a fixed order (item id, then location)." New wording (note section 15 item 3): "runs, under row locks in a fixed order (slot 1, then slot 2, ...), in the transaction of the handler's step, reached from the handler call by `HandlerWrites.post/3`; the stock module's registration supplies the item/location slot meaning". The guard is the same in substance (constraint C3 is met); only the place and the naming change.

**D5 What the 0054 Correction still requires of module code.** The Correction (advisor, option A, 2026-10-15) to the D4a ruling in `0054-process-step-writes-entity.md` wants ledger invariants in reviewed module code, not in declarative step data. Under R-N that stays true for everything that is business: ledger POLICY (the closed set of causes and their sign rules, slot meanings, per-key bounds, units, permissions, the pure `declare/2` function) stays reviewed module data and code, registered in the manifest. Core enforces only generic MECHANICAL invariants that a create-only handler cannot: append-only, the gap-free counter, zero-sum per declared group, non-negative balance and registered per-key bounds, reversal pairing. **Deviation from the letter of the Correction, and its reason:** the merged REQ-501 handler contract is create-only (note section 0, V1), so the mechanical part cannot live in the handler. D4a.2(b) (`writable_by_process` refused on `managed_by` types) stands.

**D6 OQ-R4 stays owed.** Update-kind handler writes plus the narrow read facade (the F-R5 table row, D-R.17 and OQ-R4 of `lib/letflow/design/gh2590-req501-module-write-handlers.md`) remain owed at WMS slice 5 and are NOT replaced by R-N: they are still needed for entity documents and for master checks. R-N removes only the ledger's dependence on them. Master checks (item, location and unit active), record-version preconditions (`expected_document_version`, typed `record_version_conflict`) and retired-master checks are DEPENDENT on that facade (note sections 14.6 and 17, slice L7). Until it exists the ledger accepts any well-formed slot values: master validation is a documented limit of L1..L4.

**D7 Carried decisions** (text and reasons from the note; each is a numbered item whose id appears here).

* **D-L2 Append-only in the database, tripwire plus chain (note 5.1 and 5.4).** The handler path alone is not a sufficient guarantee for a legal record; the repository precedent is the database trigger. Triggers on `ledger_entry` and `ledger_leg`: BEFORE UPDATE and BEFORE DELETE (row) raising one fixed text, and BEFORE TRUNCATE (statement) raising the same, as a TRIPWIRE against bugs and accidents, not a security boundary (the application connects as the table owner). Tamper evidence: `entry_digest` covers every immutable header column and the canonical ordered legs; `chain_hash = SHA-256(prev_chain_hash || entry_digest)` per ledger id, serialised by the counter lock; the new `chain_hash` is also written into the `ledger.posted` audit entry, which sits in the tenant audit chain, so a rewrite of the ledger by the table owner must also forge the audit chain. `reconcile/3` recomputes digests and the chain. Both columns are in the FIRST migration because an append-only table cannot be back-filled. TenantTemplate choice: **ledger tables are unresettable**. `TenantTemplate` gets a fixed list of the four ledger tables; when its probe finds any dirty, `reset_clone_schema!` returns `{:error, {:unprovable, ["append_only_table_dirty"]}}` before any DML, the pool labels it `:verify_failed` and rebuilds the slot (no repair in place, no new pool label). Rejected: a GUC-controlled TRUNCATE bypass inside the trigger (any raw SQL session can set a GUC), and omitting the TRUNCATE trigger (leaves TRUNCATE open). Cost: every test module that posts rebuilds its slot afterwards; ledger tests are few and `async: false`. The sandbox fixture loader refuses `ledger_*` tables as fixture targets with a typed error.
* **D-L2a Owner-tamper residual (note 5.1).** The table owner can run `ALTER TABLE ... DISABLE TRIGGER`; a superuser can set `session_replication_role = replica`; `REVOKE` is not used. So the hash chain DETECTS bugs and edits by anyone who does not recompute the chain; it does not prevent them, and an owner who recomputes both chains and the audit chain can still defeat it. An optional keyed digest (HMAC with a platform secret via `Letflow.Secrets`, INV-4) raises the bar and is OQ-18: unkeyed in release 1, the columns are the same.
* **D-L2b Tenant export and restore (note 4.6).** Carried to the export work (decision 0057 D19): the ledger (`ledger_entry`, `ledger_leg`, `entry_digest`, `chain_hash`) is part of the export package; a restore is whole-schema (counter, entries, legs and balances together); a partial restore of a ledger table is forbidden; after a restore `reconcile/3` must report clean before the tenant is unfrozen. Purge of ledger rows is never offered.
* **D-L3 One sequence per ledger id.** The stock module registers one fixed ledger id per tenant in release 1; per-instance ids are the scale path and are not enabled in L1..L4.
* **D-L4 Lock class 5b.** The ledger rows take a new lock class 5b in the engine's global row-lock order (text in D8).
* **D-L5 Time basis (note section 8).** `event_time` is kept as the device-reported fact; `posting_time` and `posting_seq` are server-side; there are two reproducible bases for reports (as-posted and event-time); every report states which it uses.
* **D-L11 No foreign key from ledger tables to engine tables.** No FK references a ledger table and none leaves one, so no non-ledger FK closure can pull a ledger table into a TRUNCATE.
* **D-L12 SERVICE origin refused in L1..L4.** `post/3` refuses a `{:dispatch, _}` origin with the TYPED refusal `:ledger_origin_not_supported` (surfaced as `write_not_permitted`, and as ERROR plus DLQ on the service path); activation also refuses a `posts_ledger` handler on a SERVICE_TASK node. Reason: on the service apply the audit chain row A is taken before the handler calls, a human posting holding the balance rows and counter wants A for its tail audit, so a real lock cycle exists (derived by reading, not run). Lifting it needs a later 0061 amendment (ledger lock-only pre-steps before the task-activation audit) and its own forced-overlap tests. Conditions for lifting: (a) the ledger rows are taken as lock-only pre-steps BEFORE the task-activation audit, with balance keys resolvable at plan time (not verified that service-path arguments are); (b) the subject's roles are re-resolved from the database at run time, the platform sentinel never holds the post permission and the `credential` rule applies; (c) when script-produced variables feed legs, activation requires an explicit consent flag on the node recorded with `activated_by`; (d) the cycle test T-LK-4 is inverted.
* **D-T Lateness cap (note 8.3).** `event_time` may be earlier than `posting_time` by at most `max_event_lateness_hours`, default **96 hours (4 days)**, and later by at most 5 minutes (skew); beyond either the posting is refused `event_time_too_old` or `event_time_in_future` (422), nothing written. The value is the registration's `max_event_lateness_hours` (manifest data, hashed by `ManifestHash`); rule 12 caps it at **720 hours**; there is no tenant or operator override and no runtime setting. Raising the window means a module version change. Reasoning: (a) the offline lease is the maximum outage, default 3 days (0058 (a), 0057 D13); a fact captured at the start of the longest permitted outage must still be postable on reconnection; (b) one day of margin covers synchronisation delay and a device clock set to local time; (c) ERP inventory ledgers bound backdating by an open posting period (SAP MM posting-period control; Dynamics 365 inventory closing), and the cap is the minimal stand-in since period close is out of scope; (d) a cap with no value would let any holder of the post permission backdate unboundedly, defeating "published balances are not silently rewritten"; (e) it cannot rewrite a published as-posted report anyway, it only bounds how far an event-time report can move. Period close is a later requirement.
* **D-C Per-cause balancing (note section 19).** Sign rules per cause: `positive`, `negative`, `zero_sum_by_slot_1`, `any`, `reversal`. "Every movement balances" is read per cause: a goods receipt or issue is single-sided (its counterpart, the supplier, is outside the stock ledger); only two-sided causes (transfer, status change) balance. No virtual-location double entry. This agrees with 0057 D5 and with the draft's own MD-08 wording for transfers.
* **D-P Policy purity (note section 19).** In L1..L4 the module's policy is ONE pure function `declare/2`, invoked by `HandlerWrites.post/3` at BUILD time with no database access. There is no `gather_facts`, no master check, no `expected_document_version` check and no retired-master check; each needs a READ, REQ-501 gives handlers no reads, and a `gather_facts` callback would reintroduce the read facade that OQ-R4 says is still owed (D6). Consequence: two #2657 acceptance criteria (0058 (c) items 2 and 7, master side) are met only in part, which AMENDMENT 1 records.

**D8 The 0061 amendment text (class 5b).** The following is the text of note section 15 for the amendment of decision 0061, verbatim. It is applied to 0061 by slice L3 (the L3 PR, rule 5), with the tests T-LK-1..6; **0061 is not edited by this record or by REQ-616**.

> Rule 1 gains class 5b: after class 5 (and after the ancestor group of class 3) and before class 6; relative to the projection-protected rows of the instance (own tokens, timers per 'Amended (GH #2707, PR-1)' item 1, sequence rows, projection) its position is UNCONSTRAINED, because those rows are touched only while the transaction holds `P_x`: the ledger's balance rows ascending by `(k1..k8)` (missing rows inserted first in the same order), then the single counter row of the ledger id. At most one posting per transaction (static activation check plus the inner merge-function check of 7.4) and one ledger id per posting. A transaction that holds the audit chain row or any later class never takes a ledger row; the SERVICE origin is refused (typed) until its pre-lock exists.

**D9 Owner defaults and gates.** The note's defaults are taken as the owner decisions, "yes":

* OQ-19: D-E holds, neutral core code `insufficient_balance` with the stock module's wire alias `insufficient_stock` (D3).
* OQ-20: D-P holds, no `gather_facts` and no master, version or retired-master checks in L1..L4 (D7); the amendment of the two #2657 criteria is recorded on GH #2657 as AMENDMENT 1 (comment 6259361954) and AMENDMENT 2 (comment 6260381925), both dated 2026-10-19.
* OQ-21: a warehouse-scoped principal cannot post until slice L6; L6 is a named slice gating the pilot, and so is L7.

OQ-13 (warehouse and zone scoping of postings, slice L6) and OQ-23 (tenant-wide serial uniqueness) are **not decided** here. They are out of scope of this record and gate the pilot together with slices L6 and L7: the stock module is not enabled for a customer tenant until L6 and L7 are done, and serial-tracked goods stay out of the pilot until OQ-23 is resolved.

## Consequences

Slices (note section 17; neutral names):

| Slice | Content |
|---|---|
| L0 | this record (docs only) |
| L1 | migration(s) for `ledger_counter`, `ledger_entry`, `ledger_leg`, `ledger_balance`; all triggers, digest and chain, full CHECK set, provisioning entry, `expected_tenant_tables` oracle, TenantTemplate "unresettable" change, fixture-loader deny list, check_boundaries Rule 7 and 7b |
| L2a | `Letflow.Ledger.post/1` with a test registration: guard, `key_bounds`, unit pin, counter, idempotency, offline fields |
| L2b | reversal, `authorize/3`, `balances/5`, `entries/3`, `reconcile/2` |
| L3 | `HandlerWrites.post/3` and `handler_post.ex`, capability, Catalog rule 12 and `posts_ledger`, `ManifestHash`, activation checks, failure channel, roles, scope and credential, `ledger.posted` audit, Rule 8, the 0061 amendment (D8) |
| L4 | stock module: manifest registration, views, read routes through `authorize/3`, runbook; no master checks |
| L5 | SERVICE-origin pre-locks and lifting the typed refusal (D-L12), with its 0061 amendment |
| L6 | scope enforcement for `post/3` through the registered `scope_slot`, fail closed: gates the pilot |
| PILOT GATE | The stock module is NOT enabled for a customer tenant until L6 AND L7 are done, and serial-tracked goods stay out of the pilot until OQ-23 is resolved. Without L7 a typo in an item or location id creates a NEW balance key whose first-touch `unit_ref` and `max_on_hand` pin is permanent; without L6 a scoped storekeeper cannot post; without OQ-23 the same serial can be active at two locations. |
| L7 | master validation, `expected_document_version`, retired-master checks, per-instance ledger ids: gates the pilot; depends on the OQ-R4 read facade (owed at WMS slice 5) |

* Ownership of follow-ups: Rule 7 and the tables land in L1; the 0061 amendment is applied in L3; 0057 and 0054 are not edited, their amended wording lives here; OQ-R4 stays at WMS slice 5.
* Cost recorded (note 3.3, EC F13): a posting handler must still declare at least one managed bookkeeping target (`write_handler_no_targets` and `write_handler_without_managed_types` stay), so a stock module must manage at least one entity type that the posting handler writes through `create/3`, for example a document-line record.
* Out of scope: REQ-503 behaviour (quarantine, serial flows beyond the key bound, owner or custodian transfer, available-to-pick); REQ-504 conversion, rounding and tolerance logic; the quantity amendments A1..A33 of `lib/letflow/design/gh2660-wms-quantity.md` (carried by L1); the 1C/SAP acknowledgment table; command log and lease (REQ-480); counts and variance; period close; per-ledger-instance sequences; a balance repair action; automated postings until L5.
* Residuals: the owner-tamper residual and the unkeyed digest (D-L2a).
* No status of any requirement is flipped and no run-history event is appended by this record.

## Open

* **OQ-13** (warehouse and zone scoping of postings): NOT DECIDED here. Out of L1..L5; slice L6 gates the pilot; until then scoped principals are refused.
* **OQ-23** (tenant-wide serial uniqueness; the `key_bounds` bound is per balance key including location; a registered `unique_over` subset with a shadow key row locked in the same ascending order): NOT DECIDED here. Not in release 1, per-key bound only; revisit with the read facade. Serial-tracked goods stay out of the pilot until it is resolved.
* OQ-18 (keyed digest for the hash chain): default no, unkeyed in release 1.
* OQ-24 (a MAC or nonce on `Capability` and `Authorized`): default no.
* OQ-2 (one ledger id per tenant or per warehouse): per tenant; per-warehouse only if T-LD-1 fails.
* OQ-11 (role grants for the four permission atoms): decided in slice L4.
* The record number 0073 replaced the note's "0062 (proposed)".

## Amended (REQ-676, assets B1)

Sources: owner decisions D-061 (one transaction may post to two registers), D-062 (shared ledger tables partitioned by ledger id, proven by a speed test, separate tables as the fallback) and D-073 (phase B specifications before GATE A, no phase B implementation before it) in `ai-dala-portfolio/DECISIONS.md`, and requirement REQ-676 (GH #3666) in `docs/requirements.yaml`. This section writes no code, no migration, no test, no seed and no route. It replaces D8 and the table shape of slice L1 part A, and adds to D-L3 and to the slice table rows L1 to L5. Everything above this heading stays as written. 0061 is not edited here: its class 5b text is applied by slice L3 (D8), now with the text of A3 below. The speed test itself and the partition migration are later requirements, written after GATE A.

### A1 Why

D8 allows at most one posting per transaction and one ledger id per posting, and the activation check `module_writes_multiple_ledger_postings` (note section 7.4) refuses a node with two posting lines. The owner decided (D-061) that a change of kind (a chair bought as stock becomes a tracked low-value asset) is one workflow document that posts to the stock register and to the asset register in one transaction, with the same document id in both. The owner also decided (D-062) that the registers keep the four shared ledger tables, partitioned by ledger id so each register is physically its own part, with separate tables as the fallback if a speed test says so. The tables of slice L1 part A exist on origin/main (migration `20261031100001_create_ledger_tables.exs`), are not partitioned, and hold no row on any tenant because no posting code exists.

### A2 Two postings in one transaction (replaces the sentence "at most one posting per transaction ... and one ledger id per posting" of D8)

* One transaction carries at most TWO postings. The two postings have different ledger ids. Both carry the same non-empty `document_type` and the same non-empty `document_id`. Either both are committed or neither is.
* Refused with nothing committed: a second posting to the same ledger id in one transaction; a third posting; two postings whose `document_type` or `document_id` differ (or either is empty). The typed refusals are `ledger_duplicate_ledger_in_transaction`, `ledger_too_many_postings` and `ledger_document_mismatch` (neutral core codes, mapped by the module like the other codes of note section 12.2).
* Activation check (replaces `module_writes_multiple_ledger_postings`): `Definitions.ModuleWrites` refuses a node whose `module_writes` contain MORE THAN TWO lines whose handler has `posts_ledger` (code `module_writes_too_many_ledger_postings`, 422), and refuses two such lines whose handlers register the same ledger id.
* Run-time check (replaces the merge-function check of note section 7.4 item 2): `post/3` at build time reads the per-transaction posting plan carried in the accumulator of the one `Multi.merge` that reduces all `module_writes` lines (the structure T-LK-5 guards) and records a `deferred_refusal` when the plan already holds two postings, already holds the same ledger id, or holds a different `document_type` or `document_id`. The refusal is a contract failure with the same surfacing as the old `:too_many_postings`. The per-call rule (a second `post/3` inside ONE handler call) stays.
* The SERVICE origin stays refused (D-L12); a two-posting node on a SERVICE_TASK is refused at activation like a one-posting node.

### A3 Lock order, the new class 5b text (replaces the quoted text of D8)

> Rule 1 gains class 5b: after class 5 (and after the ancestor group of class 3) and before class 6; relative to the projection-protected rows of the instance (own tokens, timers per 'Amended (GH #2707, PR-1)' item 1, sequence rows, projection) its position is UNCONSTRAINED, because those rows are touched only while the transaction holds `P_x`: the balance rows of ALL postings of the transaction, ascending by `(ledger_id, k1..k8)` (missing rows inserted first in the same order), then the counter rows of the ledger ids of the transaction, ascending by `ledger_id`. At most two postings per transaction, with different ledger ids and the same document type and id (static activation check plus the run-time check of 0073 A2). A transaction that holds the audit chain row or any later class never takes a ledger row; the SERVICE origin is refused (typed) until its pre-lock exists.

Which step takes the locks of both postings: ONE lock step, placed after every `module_writes` line of the node has been built and before any posting step writes. `post/3` at build time only adds its posting (its balance keys come from its legs) to the per-transaction plan; the lock step sorts the union of the balance keys of both postings by `(ledger_id, k1..k8)`, inserts the missing rows in that order, locks all balance rows in that order, then locks the counter rows by `ledger_id`. The posting steps then allocate `posting_seq` and write under those locks. The lock order therefore does not depend on the order of the `module_writes` lines.

Why it cannot form a cycle (in the style of note section 7.3). Take the total order on ledger resources: every balance row `(ledger_id, k1..k8)` precedes every counter row, balance rows are ordered by `(ledger_id, k1..k8)`, counter rows by `ledger_id`. Every transaction, whether it carries one or two postings and whatever the order of its lines, acquires its ledger locks in strictly ascending order of this one order, because the lock step sorts the union and never follows line order. A wait-for edge from a ledger-lock holder to a ledger resource therefore always points to a strictly greater resource, so no cycle consists of ledger resources only. A two-posting transaction against a one-posting transaction: the one-posting transaction locks a subset of the resources in the same ascending order; holding counter A it takes no further ledger lock, so it never waits for a balance row or a counter the two-posting transaction holds. Two two-posting transactions with lines in opposite order (stock line first in one node, asset line first in the other): both sort to the same sequence, so the second waits for the first at the first shared resource and holds nothing the first wants. Holders of tail rows (audit chain row, sequence rows, projection) never wait for a ledger row (note section 7.2), so edges into the tail cannot close a cycle either. The insert-if-absent pass runs over the whole union before any lock of the lock pass, in the same ascending order.

The rules that a transaction holding the audit chain row never takes a ledger row, and that the SERVICE origin stays refused (D-L12), are kept word for word.

### A4 Per-posting rules kept

Each of the two postings keeps its own counter row, its own gap-free `posting_seq`, its own digest chain (`chain_hash` per ledger id) and its own `ledger.posted` audit entry. A reversal stays inside the ledger id of the entry it reverses. A two-posting document is reversed by ONE transaction that carries the two reversal postings under the rules of A2 (same `document_type` and `document_id`, both or neither), so a change of kind is never half undone: a reversal of one posting of a two-posting document alone is refused. How the sibling is identified (the two entries share `document_type`, `document_id` and `correlation_id`; a stored group column is an alternative) is decided in the L2b requirement; if a column is needed it joins the replacing migration of A5, since the tables hold no row.

### A5 Partition shape (replaces the table shape of slice L1 part A; D-L3, one sequence per ledger id, stays)

`ledger_entry`, `ledger_leg` and `ledger_balance` are declared `PARTITION BY LIST (ledger_id)`; `ledger_counter` is not partitioned (one row per ledger id). PostgreSQL requires the partition key in every primary key and unique index of a partitioned table (decision 0003). Every key of migration `20261031100001` is listed with its new column list:

| Table, key | Today | New | What the narrower uniqueness means |
|---|---|---|---|
| `ledger_entry` primary key | `(id)` | `(id, ledger_id)` | an entry is identified within its ledger; ids are uuids, so no practical change |
| `ledger_entry_ledger_seq_key` | `(ledger_id, posting_seq)` | already contains `ledger_id` | none |
| `ledger_entry_subject_op_key` | `(subject_id, client_op_id)` | `(ledger_id, subject_id, client_op_id)` | the idempotency key is per ledger id, so the two postings of one command may share `client_op_id` |
| `ledger_entry_origin_key_key` | `(origin_key)` | `(ledger_id, origin_key)` | origin keys are unique per ledger id; the origin key of each posting is built so that the two postings of one document differ in any case |
| `ledger_entry_leg_target_key` | `(id, ledger_id, posting_seq, event_time)` | already contains `ledger_id` | none |
| `ledger_entry_reverses_unique_index` (partial, `WHERE reverses_entry_id IS NOT NULL`) | `(reverses_entry_id)` | `(ledger_id, reverses_entry_id)` | one reversal per entry, still, because a reversal stays in the ledger id of its target |
| `ledger_entry_device_seq_unique_index` (partial) | `(subject_id, device_id, client_seq)` | `(ledger_id, subject_id, device_id, client_seq)` | a device sequence number is unique per ledger id |
| `ledger_entry.reverses_entry_id` self foreign key | `(reverses_entry_id)` to `ledger_entry (id)` | `(reverses_entry_id, ledger_id)` to `ledger_entry (id, ledger_id)` | the database itself refuses a reversal across ledger ids |
| `ledger_leg` primary key | `(id)` | `(id, ledger_id)` | as for the entry |
| `ledger_leg_entry_leg_no_key` | `(entry_id, leg_no)` | `(ledger_id, entry_id, leg_no)` | leg numbers are unique within an entry, which lives in one ledger id |
| `ledger_leg_entry_fk` | `(entry_id, ledger_id, posting_seq, event_time)` to the entry target key | already contains `ledger_id` | none |
| `ledger_balance` primary key | `(ledger_id, k1..k8)` | already contains `ledger_id` | none |
| `ledger_counter` primary key | `(ledger_id)` | unchanged (not partitioned) | none |

The non-unique indexes of the migration keep their columns; each is declared on the parent and exists per partition. The tables of migration `20261031100001` on existing tenants are replaced by a new tenant-scoped migration (registered in `Letflow.TenantProvisioning` like its predecessor) that drops the four tables and creates the partitioned shape; it REFUSES TO RUN when any of the four ledger tables has a row. This is safe because no posting code exists, so no tenant holds a row; the migration is written after the speed test result and after GATE A.

### A6 Partition life cycle

* The partitions of a ledger id (one each for `ledger_entry`, `ledger_leg` and `ledger_balance`, named from a fixed prefix and the first 16 hex characters of the SHA-256 of the ledger id, quoted as identifiers under INV-7, because the ledger id form allows `:` and `-`) are created when the module that registers that ledger id is installed or reactivated for the tenant, through `Letflow.Modules.Installs.install/3` and `reactivate/3` (`lib/letflow/modules/installs.ex`), in the same transaction as the install or reactivate transition, and never inside a posting transaction. Creation is `CREATE TABLE ... (LIKE parent INCLUDING ALL)` followed by `ALTER TABLE parent ATTACH PARTITION ... FOR VALUES IN ('<ledger id>')`, which takes SHARE UPDATE EXCLUSIVE on the parent and so does not block reads or writes of other ledger ids; the plain `CREATE TABLE ... PARTITION OF` form is not used because the PostgreSQL 16 documentation says it takes ACCESS EXCLUSIVE on the parent. The requirement that writes the creation code proves the lock mode with a `pg_locks` test. Creation is idempotent (a reactivate finds its partitions).
* Per-instance ledger ids (the D-L3 scale path, slice L7) need their own creation rule and are NOT enabled by this amendment.
* There is no DEFAULT partition. A row for a ledger id without a partition is refused by the database (no partition of relation found for row), a typed refusal in `post/3`.
* Triggers of slice L1 part B (PostgreSQL 16, `CREATE TRIGGER`: a row-level trigger created on a partitioned table creates an identical trigger on each existing partition and on every partition created or attached later; a statement-level trigger on the parent fires only for statements run on the parent): BEFORE UPDATE and BEFORE DELETE (row) on `ledger_entry` and `ledger_leg`: declared on the PARENT only (cloned to partitions); the balance BEFORE INSERT and BEFORE UPDATE row triggers: on the PARENT only; the deferred constraint triggers (entry AFTER INSERT, counter AFTER UPDATE): on the PARENT only for the entry (row-level, cloned), on the counter table itself (not partitioned); BEFORE TRUNCATE (statement): on the parent AND on every partition, created by the partition creation of this section, because a TRUNCATE of a partition run directly does not fire the parent's statement trigger. The counter triggers are on the counter table as before.
* `@expected_tenant_tables` in `test/support/tenant_fixture.ex` keeps the four parent names (`ledger_balance`, `ledger_counter`, `ledger_entry`, `ledger_leg`) and its count; the oracle that compares the table set to the database excludes partitions (`pg_class.relispartition`), so partitions are not listed. The unresettable list of D-L2 names the four parents; the dirty probe reads the parents and therefore sees every partition's rows, and the check that a partition exists for each registered ledger id belongs to the pool slot rebuild.

### A7 Speed test plan (a plan for a later requirement)

The test the owner asked for (D-062) compares three storage shapes on the same generated data, on the same host, with the same indexes per ledger id: (a) the unpartitioned tables of migration `20261031100001`; (b) the partitioned shape of A5; (c) the fallback of A8. Data: two ledger ids with the slot sets of `ai-dala-portfolio/architectures/assets.md`: the stock register (OrgUnit, Location, Responsible, SKU, Lot) loaded to the LARGE volume and the asset register (OrgUnit, Location, MaterialResponsible, ActualUser, Asset) loaded to the SMALL volume. Measured operations: one posting (entry, legs, balance rows, counter); one two-posting transaction; the balance of one key; the balances of one slot-1 value; the movements of one document id; the balance of one key as of an `event_time`.

The test drives the tables with the SQL statements of the posting algorithm of note section 7.1, in a scratch tenant schema of the test database, never QA, because the posting code does not exist yet. The end-to-end T-LD-1 test of note section 13 stays with slices L3 and L4. One run takes at most 10 minutes with at most 4 concurrent workers (as T-LD-1 uses 4 workers).

### A8 Pass rule and the fallback shape

The posting floor is the T-LD-1 exit criterion of note section 7.6: with 4 concurrent workers on ONE tenant, at least 20 postings per second sustained for 60 seconds, p95 completion latency under 500 ms, contention 503 rate under 1 percent; it is applied to each ledger id while the other ledger id is loaded. Shape (b) is adopted when it meets that floor and the read thresholds of A9; otherwise shape (c) is adopted, if it meets them. If neither shape meets the floor the result goes to the owner and no shape is adopted.

Shape (c): one set of entry, leg and balance tables per registered ledger id (`ledger_counter` stays shared, one row per ledger id). The table names are formed from a fixed prefix, the table kind and the first 16 hex characters of the SHA-256 of the ledger id, never from the ledger id itself, so the ledger id form of migration `20261031100001` (which allows `:` and `-`) cannot reach an identifier; every name is quoted as an identifier (INV-7) and the ledger id is checked against the form before use. Shape (c) keeps from slice L1 part A the column sets, the CHECK set, the counter table, the keys of the unpartitioned migration (they are per table, so `ledger_id` in them is redundant but harmless) and all triggers (created per table set at install or reactivate, TRUNCATE included). The posting code of L2a then addresses the tables through a ledger-id-to-table-names function.

### A9 Open owner questions

Not decided and not given a number here:

* The large and small data volumes of the speed test (entries and legs per ledger id, distinct balance keys). Source: NF-01 and NF-02 of `docs/WMS/WMS_Procurement_Requirements_Draft.md`, which say the volumes are still to be defined.
* The p95 threshold of each read operation of A7. Source: NF-02 of the same file (response-time targets still to be defined).

The speed test requirement is not started until the owner has answered them.

### A10 Impact on the slices (held ledger tasks: T-0889, T-0890, T-0898, T-0899, T-0900, T-0922, T-1003, T-1033, T-1034)

| Slice | What this amendment changes | Waits for the speed test result |
|---|---|---|
| L1 part B (triggers; REQ-620) | triggers on the parents as in A6, TRUNCATE also per partition; the partitioned tables and keys of A5 replace part A's shape | yes (shape b or c) |
| L1 part C (provisioning, oracle, TenantTemplate, fixture deny list; REQ-620) | parent names stay in `@expected_tenant_tables`, oracle excludes partitions, unresettable list names the parents (A6) | yes |
| L2a (`post/1`; REQ-621) | idempotency keys are per ledger id (A5); lock order of A3; a ledger-id-to-table function if shape (c) | yes |
| L2b (reversal, reads, reconcile) | a two-posting document is reversed as a pair (A4); reads are per ledger id | yes |
| L3 (`HandlerWrites.post/3`, activation checks, 0061 amendment) | two-posting activation and run-time checks (A2); the new class 5b text of A3 is what is applied to 0061 | no |
| L4 (stock module) | the module's install and reactivate create the partitions of its ledger id (A6) | yes (storage creation only) |
| L5 (SERVICE-origin pre-locks) | no change; the SERVICE origin stays refused | no |

REQ-620 and REQ-621 are the register entries whose criteria the later rework of slices L1 and L2a amends; this change does not edit them.

### A11 Phase A dependencies

This amendment rests on: D-066 (trees and storage) with REQ-649 (org tree path in the scope table, depth bound 40), REQ-645 and REQ-646 (location tree with a parent foreign key and no depth bound) and REQ-642 (master data as real columns, decision 0076); D-067 (access and scope) with decision 0076 (balances and movements scoped by org unit through the ledger scope slot; the scoped balances read is item B6, not this amendment); employees D-065 with REQ-643 (responsible person and actual user hold employee ids); links REQ-644 (a movement whose org unit and location are not linked is refused, D-065); codes REQ-648 (code record with assignment history); lots REQ-647. Per D-073 this amendment is amended if the GATE A check changes any of them.

Out of scope: balance as of a date and the audit trail (B2), opening balances (B3), stock workflows (B4), counts (B5), the scoped balances read (B6), the asset register module (phase C), OQ-13 and OQ-23, and period close (D-062: not part of this product).

## Amended (REQ-682, assets B6)

Sources: owner decisions D-067 (scoped by org unit; a read slice for balances of a scoped user: visible rows only, a hidden parent's rollup read as "your units in P", the other side of a transfer masked) and D-073 (phase B specifications before GATE A) in `ai-dala-portfolio/DECISIONS.md`, decision 0051 D2, D6 and D7, REQ-642 point (8) (visibility table, row "balances and movements, scoped by the ledger scope slot, phase B") and requirement REQ-682 (GH #3679) in `docs/requirements.yaml`. This section writes no code, migration, test, seed or route. It adds to the text above and to the B1 section; where it replaces a sentence, it says so. The original text and the B1 section are unchanged.

### S1 Why

A user whose grants name some org units (not tenant-wide) cannot read balances or movements today: `authorize/3` of the ledger design note (`lib/letflow/design/gh2657-wms-stock-ledger-core.md`, section 14.1) requires `Letflow.Api.Scope.allowed_set/2` to answer `{:ok, :all}`, and slice L6 adds scope for posting only. D-067 puts balances and movements in the class "scoped by org unit". This section fixes the read side.

### S2 The scope slot

The scope slot is one of the 8 opaque balance-key slots `k1..k8` (D2), named by the optional rule-12 registration key `scope_slot` (note section 14.3). Its format is `uuid` and its value is the `org_unit` record id, the same string the org module writes as the scope node id (`lib/letflow/modules/org/masters.ex`). The slots are text `COLLATE "C"`, so the comparison is byte equality on the string; there is no uuid cast (unlike the entity predicate of REQ-674).

* Core fixes no position for the scope slot. The stock register (slots OrgUnit, Location, Responsible, SKU, Lot) and the asset register (OrgUnit, Location, MaterialResponsible, ActualUser, Asset) each name their OrgUnit slot in their registration.
* The header column `scope_ref` (one per posting, note section 4.2) is NOT read for visibility. Visibility is decided per balance row and per leg by the value of its scope slot.
* A balance row or leg whose scope slot value is the empty string is visible only to a reader with `{:ok, :all}`.
* A registration without `scope_slot` gives a scoped reader the refusal of S3.
* Indexes. For a scope slot in position k1 or k2 the existing indexes of migration `20261031100001` serve the filter: `ledger_leg_k1_k2_index`, `ledger_leg_k2_k1_index`, `ledger_balance_k2_k1_index`, or the `ledger_balance` primary key. For any later position the filter scans within the (k1, k2) range, as note section 4.3 says, acceptable for the pilot. Whether a further index is needed is left to the speed test plan of the B1 amendment (A7); this section adds none.

### S3 Authorisation of a scoped read (replaces, for purpose `:read` only, "Scope.allowed_set == {:ok, :all}" of note section 14.1)

`authorize/3` with purpose `:read` accepts `{:ok, :all}` and `{:ok, {:nodes, ids}}` from `Letflow.Api.Scope.allowed_set/2` for the registration's read atom and stores the answer inside the opaque authorized value; a set supplied by the caller is never used. `{:ok, :none}`, a `ScopeSetError` (including the 50_000-id cap of `Letflow.ScopeNodePaths.allowed_node_ids/2`), a registration without `scope_slot`, and every refusal of the existing text give the same bare `:error`. Purpose `:reconcile` still requires `{:ok, :all}`.

### S4 Visible rows and totals

Every balance report (both bases of note section 8.2) and every entry listing filters on "scope slot value in the allowed ids" inside the outermost WHERE of the query, before any sum, count, group or cursor (0051 D6; never a filter after the query). A scoped reader gets only rows of units in its allowed set. A total, a sum per slot value and a count count visible rows only, with no placeholder row and no count of hidden rows (0051 D7).

Worked example. Units: P (parent), A, B and H (children of P). One SKU. The reader is granted on A and B.

| Unit | Balance | Reader (A, B) sees | Tenant-wide reader sees |
|---|---|---|---|
| P | 5 | no row | 5 |
| A | 10 | 10 | 10 |
| B | 20 | 20 | 20 |
| H | 40 | no row | 40 |
| Total for the SKU | | 30 | 75 |

### S5 Rollup over a parent

One key is added to the `filters` map of `balances/4` and `entries/3` (note section 14.1 types it only as `filters :: map()` with the error `:invalid_filter`; the key set is fixed by slice L2b, whose draft in the held task T-0922 closes the filters to the slot names of the registration, so this key is an addition to that set): a subtree of the scope slot, naming one org unit P. It is answered with the rows whose scope slot value is in the descendants of P (`Letflow.ScopeNodePaths.descendants_of/2`, P included), intersected with the allowed set.

One report field is added, coverage, with exactly two values: `complete` when the authorized value holds `{:ok, :all}` or `Letflow.Api.Scope.allowed?/3` allows P, and `visible_only` otherwise. A client shows a `visible_only` result as "your units in P" and never as the total of P. In the example of S4 the reader granted on A and B gets the rollup over P = 30 with coverage `visible_only`; a reader granted on P gets 75 with coverage `complete`. An unknown P, and a P whose visible descendants hold no row, give the same answer (no rows, `visible_only`) with the same number of queries (0051 D7, INV-5).

### S6 Movements with a hidden side

An entry is listed for a scoped reader only when at least one of its legs has a visible scope slot value. Such an entry carries its header fields and its visible legs in full, and every other leg as a masked leg with exactly `leg_no`, `quantity`, `unit_ref` and a masked marker, without any slot value, `attrs` or `document_line_id`. An entry with no visible leg is absent, so filtering by the `document_id` of a document whose legs are all hidden gives the same empty answer, with the same number of queries, as an unknown `document_id`.

Example: a transfer of 3 units of one SKU from A (visible) to H (hidden). The reader sees the leg of A with -3 in full and one masked leg with +3; a tenant-wide reader sees both legs in full. For the two postings of one change-of-kind document (A2), each ledger id is read with its own `authorize/3` call and masked by the same rule.

### S7 Current tree

Visibility is decided against the tree at read time (0051 D2). After a unit moves out of the reader's grant, its old balances and movements are hidden from that reader; those of a unit moved in become visible. `allowed_set/2` expands to live units only, so balances and legs of a retired unit are visible only to a reader with `{:ok, :all}` (open question S10).

### S8 Impact on the slices and on REQ-642

This change edits none of the items below.

| Item | What this amendment changes in it |
|---|---|
| L2b (`authorize/3`, `balances/4`, `entries/3`, `reconcile/2`; held task T-0922) | `authorize/3` for `:read` per S3; the subtree filter key and the coverage field per S5; the visible-rows filter in balances and entries per S4; masked legs per S6. The later rework amends the criteria of T-0922. |
| L4 (stock module read routes; held task T-1033) | its read routes pass the coverage field and masked legs through unchanged |
| L6 (posting scope through `scope_slot`) | reads the same `scope_slot` key; the posting rule for a transfer with a hidden side stays OQ-13 |
| REQ-642 point (8) (F9, access declarations) | the "balances and movements" row of the visibility table is filled by this section; no `:scope_declarations` entry is added or changed (0051 M4), since the ledger tables are not entity types and are not declared through rule 11 |

### S9 Phase A dependencies

This section rests on: D-066 (trees and storage) with REQ-642 (master data as real columns, decision 0076) and REQ-649 (org tree path in the scope table, depth 40, 0051 Amendment A2); D-067 (access and scope) with REQ-642 point (8), REQ-643 (org_unit, org_legal_entity and org_site readable tenant-wide by name, so the label "your units in P" can name P; employees scoped by org unit, so a responsible-person slot of a hidden leg is masked with the rest; employee ids in the responsible and actual-user slots, D-065) and REQ-674 (the uuid scope predicate for entity reads); REQ-519 (the enforcement flag; pending: until a tenant turns it on every caller reads with `{:ok, :all}` and nothing here is observable); REQ-648 (codes resolve to a target whose own scope is checked; the scoped balance read does not depend on codes); D-065 and REQ-649 (a unit with a balance cannot be retired). This section is amended if the GATE A check changes one of them (D-073).

### S10 Open questions

Not decided here, for the owner:

* Whether a scoped reader keeps seeing the movements of a unit after it is retired or moved away. S7 gives the result of the current rules: they are hidden. (default, owner may change at GATE B)
* Whether a scoped user may post a transfer to or from a hidden unit (OQ-13, slice L6).

Until REQ-519 lets a tenant turn enforcement on, no reader on QA or in production is scoped, so the rules of this section are checked by tests only, not by UAT.

Out of scope: the location tree (locations are tenant-wide and never a scope, REQ-642 points (3) and (8)); a second scope slot or a named scope set (0051 D1 amendment, not built); a new reader role (D-067; 0046 D10); balance as of a date beyond the event-time basis of note section 8.2 (B2); the screens.
