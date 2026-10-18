# GH #2659 / REQ-505 - master external_ref {system, id} and the idempotent upsert-by-external-id import

Status: design rev 2 (CODE-DESIGNER), after CODE-DESIGN-VALIDATOR FAIL on rev 1 (35ef0e5c). Base: origin/main 21c9b40b.
Owner of the build: ELIXIR-DEV (backend only; no `web/` change). No implementation code below: names, shapes, step
orders, tests. Method: code read with grep/git, NO `mix` run (host memory-starved). Citations are `path:line` on this base.

Sources: decision 0057 D1 (`docs/migration/decisions/0057-wms-customer-draft-reconciliation.md:13`: masters come in by a
one-time idempotent import, `EntitiesRecordsImport`, upsert by external id; every master has a nullable `external_ref`
`{system, id}` from day one) and D12 (`:56`: seed through the generic idempotent import); WMS draft IN-01 (`:106`), IN-06
(`:111`), MD-01 (`:60`); decision 0060 (decimal_strict, #2654 merged); decision 0061 (global lock order); GH #2543.

## 0. The four acceptance criteria of the issue and where each is answered

| AC | Text (abridged) | Answered in |
|---|---|---|
| [1] | Design note decides core vs module with citations on main; effect on existing tenants; no `upsert_by` = today's behaviour | section 1 (decision), 2.1/2.5 and 6 (existing tenants, migration, event schema v2), 5.1/6 (backward compatibility) |
| [2] | Test plan: same file twice -> one record per external id; a record without `external_ref` is accepted; two systems, same id do not collide; partial failure rolls back or reports per entry (state which) | 9 rows T1-T4; 5.4 (per-entry, stated); 5.2 + 2.3 (ref-less entries) |
| [3] | Extra tests: two concurrent imports -> one record; same ref in two tenants does not collide; `upsert_by` vs idempotency key (#2543); decide whether the import schema version needs a bump | 9 rows T5-T7; 5.3; 5.5 (no bump, decided) |
| [4] | Permission model unchanged (route gate `EntitiesRecordsImport`); SECURITY-REVIEWER gate; CDV passes | 7 |

## 1. Core vs module: decision

**Core.** The primitive is a new function in `Letflow.Entities.Records` plus two nullable columns on the per-tenant
`entity_record_latest` and a v2 of the registered `ENTITY_RECORD_CREATED` event schema; the HTTP surface is an optional `upsert_by` on the
existing generic import route. Reasons:

1. The route is generic and tenant-facing (moduledoc row `lib/letflow/routers/entities.ex:71`, route `:331`), and D12 names
   "the generic idempotent import" as the seed path, so it must work without any module.
2. The only race arbiter that needs no new lock is a unique index on the projection row; only core can add it.
3. A module cannot own it: a module-owned (`managed_by`) type is refused on every tenant write route with a constant 403
   (`guard_tenant_write`, `entities.ex:2899-2906`, via `ManagedTypes.check_tenant_write/2`, `entities/managed_types.ex:248-256`),
   so the HTTP import cannot reach a managed type. If the WMS masters end up module-managed, the module's write handler
   (REQ-501 mechanism) calls the SAME core primitive with its `Owner` authority (the `authority` argument of
   `create_record/3`, `records.ex:325-332`). One implementation, two callers (OQ-1).

Rejected: a module-only importer (duplicates the race logic; no D12 seed path); a new route (second permission surface).

## 2. The external_ref convention

**Two nullable columns on `entity_record_latest` plus one partial unique index; the value travels in the event payload as
a top-level optional `"external_ref"` object, NOT inside `field_values`.**

| Option | Verdict |
|---|---|
| Nested object in `field_values` | Rejected. `Record.Validator` is closed (`additionalProperties: false`, `entities/record/validator.ex:58,77`) so every master definition would have to declare a `:json` field; a nested value cannot carry a unique constraint (definition `constraints` compile to UNIQUE only on promoted per-type table columns, `records.ex:1070-1099`); a `:json` field cannot be `queried` (`entities/definition.ex:117`). |
| Dedicated unique index on a promoted column | Rejected. Promotion is per type and opt-in (`records.ex:966-973`); the guarantee must hold for every type from day one (0057 D1). |
| Columns on `entity_record_latest` + partial unique index | **Chosen.** One index for all types; tenant isolation by schema prefix. The ISS-0648 promotion triggers/DDL concern the per-type promoted tables and are irrelevant here (the columns are on `entity_record_latest`, which promotion never alters). |

### 2.1 Schema migration (one tenant-scoped migration, `if prefix()` guard)

`entity_record_latest` (`priv/repo/migrations/20260906010001_create_entity_record_latest.exs`; schema `entities/record/latest.ex:21-33`):

| Column | Type | Null |
|---|---|---|
| `external_system` | `varchar(64)` | yes |
| `external_id` | `varchar(255)` | yes |

Plan (rev 3): **two migration files, two manifest entries**, so each runs in its own Ecto DDL transaction and no lock is held across both scans. Inside one DDL transaction `ADD COLUMN` takes ACCESS EXCLUSIVE and holds it to commit, which would cover the CHECK validation scan and the index build and block reads; `NOT VALID` + `VALIDATE` only helps "if the DDL transaction is lifted" (`priv/repo/migrations/20261017100001_add_catalog_endpoint_url_reserved_ref_guard.exs:18-19`), and the manifest runner (`Ecto.Migrator.run(Repo, migrations, :up, all: true, prefix: ...)`, `tenant_provisioning.ex:387-410`) lifts nothing.
* **Migration (a)** (columns + CHECK): `ADD COLUMN` x2 nullable, no default (catalog-only, no rewrite), and `CHECK ((external_system IS NULL) = (external_id IS NULL))` named `entity_record_latest_external_ref_pair_chk`, a plain constraint in the same transaction (no `NOT VALID` step: it would add nothing inside one transaction). Cost: ACCESS EXCLUSIVE on that tenant's `entity_record_latest` for ONE validation scan (every row is NULL/NULL, so it passes); that tenant's reads and writes wait for it.
* **Migration (b)** (index): partial unique index `entity_record_latest_external_ref_idx` on `(entity_type, external_system, external_id)` `WHERE external_id IS NOT NULL`, plain `CREATE INDEX` (NOT `CONCURRENTLY`, which cannot run in the manifest's transaction). Cost: SHARE lock (blocks writes, not reads) for ONE scan; the index holds zero rows. Separate transactions mean the ACCESS EXCLUSIVE and SHARE windows never overlap.
* Boot-time cost: per tenant, one short ACCESS EXCLUSIVE scan and one short SHARE scan of its own `entity_record_latest`. Accepted for expected tenant sizes (seconds at most); an operator can run the boot replay in a maintenance window for a very large tenant (OQ-10: acceptable?).
* No backfill.
* No `deleted` predicate on the index (section 4.4). Two systems with the same id differ in `external_system`; the entity type is in the key.

Registration: BOTH migrations MUST be appended, in order (a) then (b), to `@tenant_scoped_migration_manifest` (list starts `tenant_provisioning.ex:506`; the "every future migration must append an entry" contract is at `tenant_provisioning.ex:760-772`) so fresh AND existing tenants get it (existing ones via `replay_migrations/2` and the boot-time replay over all registrations, ISS-0771). Latest file in the tree: `20261018100002_add_admin_flagged_service_principal_to_users.exs`; the new one takes the next free timestamp.

### 2.2 Ecto schema (`Letflow.Entities.Record.Latest`)

Add `field :external_system, :string` and `field :external_id, :string`. The insert changeset (`@insert_fields`, `latest.ex:39-45`) casts both optionally (not in `validate_required`) and declares `unique_constraint` on the new index name. The update changeset (`@update_fields`, `latest.ex:48`) does not cast them: the reference is immutable once set, like `entity_type`/`record_id`.

### 2.3 Value rules (`Letflow.Entities.ExternalRef`, new, pure)

`parse(term) :: {:ok, %{system: String.t(), id: String.t()}} | {:error, :external_ref_invalid}`:
* Exactly keys `"system"` and `"id"`, both strings; unknown key, non-object, either missing -> error.
* `system`: 1..64 bytes, `[a-z0-9][a-z0-9._-]*` (lower-case slug). No case folding: a mixed-case system is rejected, never normalised.
* `id`: 1..255 bytes, valid UTF-8, no NUL, not all whitespace; compared byte-exact (no trim, no fold). Numeric source ids are sent as strings.

### 2.4 Event payload and the registered event schema (BLOCKER B1 of CDV)

The registered schema for `ENTITY_RECORD_CREATED`/`ENTITY_RECORD_UPDATED` is `@created_or_updated_schema` with four properties and `"additionalProperties" => false` (`entities/event_types.ex:54-64`, specs at `:71-90`, both at `schema_version: 1`). `Registry.validate_payload/3` validates against the highest registered version (`event_store/registry.ex:151-166`, `get_type/2` orders by `schema_version desc limit 1`, `:232-245`). So a CREATED payload carrying `"external_ref"` would fail with `payload_validation_failed`. Therefore (rev 3: only CREATED changes):

* **Only `ENTITY_RECORD_CREATED` goes to v2.** The ref is set only by a create, so `ENTITY_RECORD_UPDATED` payloads do NOT carry `external_ref` (the projector never reads it there) and UPDATED stays at v1; `ENTITY_RECORD_DELETED` is unchanged. v2 of CREATED = the same schema plus an optional property `"external_ref"` = `{"type":"object","required":["system","id"],"properties":{"system":{"type":"string"},"id":{"type":"string"}},"additionalProperties":false}`, top level `"additionalProperties"` still `false`, `required` unchanged (every v1 payload is also a valid v2 payload).
* **Bumped in place, as the in-repo precedent does.** The CREATED entry of `@event_type_specs` (`event_types.ex:71`) is REPLACED by a `schema_version: 2` entry; no v1 entry is kept beside it. Precedent: `TASK_ENTITY_WRITES_APPLIED` v2 (`tenant_provisioning.ex:1430-1433`, GH #2590 R4a): "bumped IN PLACE (a v1 entry kept beside v2 would fail every replay with :schema_version_not_monotonic for a tenant already at v2)". Consequences: a fresh tenant registers CREATED at v2 only; an upgraded tenant (at v1) registers v2 (monotonic, `registry.ex:336-346`); a re-seed of an already-upgraded tenant hits the existing `:duplicate_event_type_version` case which `seed!/1` already skips (`event_types.ex:117-140`). **`seed!/1` is NOT changed** (rev 2's monotonic-skip is dropped).
* **How v2 reaches EXISTING tenants.** `replay_migrations/2` runs `Ecto.Migrator.run` and then `maybe_seed_entity_event_types/2` for the default manifest (`tenant_provisioning.ex:407`, defined `:1484-1500`), and the boot-time replay over all registered tenants (ISS-0771) calls it per tenant. Replacing the spec is therefore enough for fresh tenants (at provisioning) and upgraded tenants (at replay): the same "replayed to v2" mechanism #2590 R4b relies on, checked with `EventStore.Registry.max_schema_version/2` (`registry.ex:253-261`; consumers `engine.ex:3100`, `:5418`; `gh2590-req501-module-write-handlers.md:55`).
* **Rollout order** (must hold): migrations (a)(b) -> CREATED v2 registered in every tenant -> code that writes a ref. Enforced two ways: (a) PR-1 ships the migrations + v2 schema before any writer exists (writer-free, section 10); (b) the ROUTER makes ONE `Registry.max_schema_version("ENTITY_RECORD_CREATED", prefix)` read per upsert request (in the pre-check, 5.2; never per entry, which would be up to 200 reads) and answers the whole request with a constant 503 `event_schema_outdated` when it is below 2 (a tenant not yet replayed), before any entry is written. The module-handler caller of the primitive does the same single read before its batch; the primitive itself does not re-read per call. Payloads without a ref are unaffected under v1 or v2.
* Event payload: only CREATED gains `"external_ref"` (`build_event_attrs/3`, `records.ex:837-850`), and only when a ref is supplied; every other payload is byte-identical to today, so existing events and replay are untouched.

### 2.5 Projection: every writer of the two columns

The columns are written/derived in these places (rev 1 wrongly said only `records.ex` and the projector):

* `Records` command pipeline: `ctx` gains an optional `external_ref` (nil by default); `upsert_record_latest/3` for `kind: :create` (`records.ex:870-880`) puts the two columns on the insert; the update/delete clause (`:886-896`) never touches them.
* `Records.command_multi/3` (`records.ex:550`), used by engine step writes (`entities/step_writes.ex:703`; moduledoc `:16`): builds its own `ctx` (create kind); it leaves `external_ref` nil. Engine-written records therefore always have NULL/NULL; no behaviour change.
* `Record.Projector` (`entities/record/projector.ex`): the `snapshot()` type (`:90`) gains `external_system`/`external_id`; `apply_event/3` (`:454`) CREATED clause sets them from `event.payload["external_ref"]`, UPDATED/DELETED clauses carry them forward unchanged and never clear; `write_snapshots/3` (`:270-286`, which `delete_all`s the type's rows then re-inserts through `Latest.insert_changeset/2`) must pass the two keys into that insert, else a `rebuild_projection/2` would silently drop every ref and violate nothing visibly. The per-type promoted-table dual write (`records.ex:966-1045`, projector `maybe_write_entity_table_snapshots`) does not carry the ref.
* Reads: `record_map/2` (`entities.ex:2862`, def line; comment `:2857-2861`) emits `"external_ref"` only when non-nil; `entity_row_map/2` (`entities.ex:2826`, query/export rows) is NOT changed in this requirement (OQ-3). With a nil ref both bodies are byte-identical to today.

## 3. Public signatures (design only)

In `Letflow.Entities.Records`:
* `upsert_record_by_external_ref(attrs :: upsert_attrs(), prefix :: String.t()) :: {:ok, upsert_result()} | upsert_error()`, and the `/3` arity with `authority :: ManagedTypes.owner()` (the `/2` is `:tenant`, mirroring `records.ex:320-332`).
* `upsert_attrs`: `%{entity_type, external_ref :: %{system, id}, field_values :: map(), actor_id :: UUID, idempotency_key :: String.t()}`; the reserved-attribute and `sys:step:` refusals apply as for the other commands (`records.ex:414-415`).
* `upsert_result`: `%{record: Latest.t(), outcome: :created | :updated | :unchanged, is_duplicate: boolean()}`.
* `upsert_error` adds to `command_error()`: `:external_ref_invalid`, `{:external_ref_record_deleted, ref}`, `:external_ref_contention`; passes through `{:definition_not_found, t}`, `{:record_payload_invalid, v}`, `:entity_type_managed`, `{:definition_changed, t}`, `:idempotency_key_reuse`, `{:entity_append_only, t}`.

Helpers: `Latest.get_by_external_ref(entity_type, system, id, prefix) :: {:ok, t()} | {:error, :not_found} | {:error, :invalid_schema_name}` (returns deleted rows too, like `get/3`, `latest.ex:84-98`); private `Records.external_ref_conflict?(Ecto.Changeset.t()) :: boolean()` placed beside `sequence_conflict?/1` (`records.ex:1392`), true when the changeset carries a `:unique` constraint error named `entity_record_latest_external_ref_idx`.

`create_record/2,3` accepts an optional internal `external_ref` attr (never set by the existing router paths); `update_record/2,3` does not (an update never writes a ref); existing behaviour is unchanged.

## 4. Upsert semantics

### 4.1 Algorithm (bounded optimistic loop, at most 3 attempts)

1. No-query validation: `ExternalRef.parse/1`; reserved attrs; step key (the `max_schema_version` guard is the router's single per-request read, 2.4; the primitive does not re-read).
2. Resolve the active definition and ownership as the other commands (`records.ex:337-339`); `validate_field_values` returns the NORMALISED values (strict decimals as canonical strings, `records.ex:1468-1474`), so every compare below uses normalised values and `decimal_strict` fields (0060) behave as in `create_record`.
3. `Latest.get_by_external_ref/4`.
4. Branch, in THIS order:
   * absent -> create path (ref columns in the same Multi insert). Outcome `:created`.
   * present and `deleted` -> `{:external_ref_record_deleted, ref}`, nothing appended.
   * present, live, normalised `field_values` JSON-equal to stored (`json_equal?/2`, `records.ex:1329-1356`) -> `:unchanged`: no event, no write. **This is evaluated before the update path and before the append-only check**, so a re-run of the same file against an `append_only` type is safe (all `unchanged`).
   * present, live, different -> if the type is `append_only` (`ensure_mutable`, `records.ex:1451`) -> `{:entity_append_only, t}`; else `update_record` (full replacement) with `expected_last_event_global_seq` = the `last_event_global_seq` just read. Outcome `:updated`.
5. Retry: the create path's unique violation on the ref index surfaces through the Multi's `:upsert_record_latest` step as `{:error, :upsert_record_latest, %Ecto.Changeset{}, _}`, which `interpret_result/3`'s generic clause (`records.ex:1186`) turns into `{:error, %Ecto.Changeset{}}` (the `:insert_event` clause at `:1174` is for the other step). The upsert function's loop matches that changeset with `external_ref_conflict?/1` and the update path's `{:error, :record_version_conflict}` (`records.ex:949-956`), and re-runs from step 3; a lost-race create then finds the winner and becomes `unchanged`/`updated`. After 3 attempts -> `:external_ref_contention`. Each failed attempt rolled back its whole transaction (event, idempotency claim, projection).

### 4.2 Race arbiter and lock order (decision 0061)

* Arbiter: the partial unique index for inserts; the existing `check_record_version` `FOR UPDATE` re-read for updates (`records.ex:949-956`). Both run after the type's sequence-row lock taken by `EventStore.append_multi` (`event_store.ex:694-726`; comment `records.ex:814`).
* The upsert adds no lock and no lock class, and holds nothing across attempts: each attempt is one existing single-type command transaction. It takes only class 5 of 0061 rule 1 (one entity-type row), so no inversion is possible and 0061 needs no amendment (rule 5 is about paths that take several classes).
* Rejected: a pessimistic variant (`EventStore.lock_instance_sequence/3`, `event_store.ex:737-746`, then lookup, then compose in one outer transaction): correct but lengthens the lock hold. Kept as the fallback if the retry loop proves observable under load.
* The step-3 lookup is a hint; the write re-validates under the lock (index / version check).

### 4.3 Events, versions, entity_def_version

Create: one `ENTITY_RECORD_CREATED` (v2 payload with the ref). Update: one `ENTITY_RECORD_UPDATED` whose payload does NOT carry the ref (refs are only ever set on CREATED, 2.4). Unchanged: no event. **An `unchanged` record keeps its older `entity_def_version` and `last_event_global_seq` deliberately**: re-importing identical values must not bump the version (that would invalidate other writers' `expected_last_event_global_seq` and fabricate history); the record is re-pinned to the newer definition on its next real update, as for any untouched record. No client-supplied version in the import (OQ-4).

### 4.4 Soft-deleted records

A ref stays bound to its record after deletion (the index has no `deleted` predicate; the projector keeps the columns on DELETED). A later import of that ref cannot create a second record and cannot revive the old one: the entry reports `external_ref_record_deleted`. Revival is OQ-2.

### 4.5 Overwrite scope, field restrictions, TypeAccess (F2)

Upsert is full replacement of `field_values` (`records.ex:359-367`); not overwritten: the ref, `record_id`, `entity_type`, `deleted`.

What the code does today: the generic HTTP create/update/import path consults neither `TypeAccess` nor `FieldGrants` on write (`entities.ex:1017-1060` and `:1228-1380` have no such call). The engine step-write path DOES apply write-side field restrictions: `check_restrictions/3` over `FieldGrants.load_restrictions/3` (`entities/step_writes.ex:795`, moduledoc `:16`), refusing with `:field_restricted` when any written key is restricted for the subject. Rev 1's claim that no write path consults FieldGrants was wrong.

New side channels the upsert opens, which create-only import did not: (a) `outcome` `unchanged` vs `updated` vs `created`, and `external_ref_record_deleted`, reveal existence and value-equality of a record found by ref; (b) full replacement by an actor with restricted fields would erase (omission) or overwrite fields the actor may not touch; (c) `unchanged` vs `updated` lets a restricted-field actor probe a restricted field's value by guessing it.

Decision (picked, not left as accepted risk), applied only in upsert mode, via a router pre-check run once per request before any entry is written:
1. **TypeAccess**: `TypeAccess.authorized?(user_id, entity_type, prefix)` (`entities/type_access.ex:73`); a `:denied` answer folds to the same 404 as an unknown type, byte-identical (INV-5), so existence of the type and of any record is not observable by a type-denied caller.
2. **Write-side field restrictions, mirroring step writes**: `FieldGrants.load_restrictions/3` once per request. For an entry whose `field_values` names a restricted key -> per-entry `field_restricted`. For an entry whose ref matches an EXISTING record, when the actor has ANY restricted field on the type -> per-entry `field_restricted` BEFORE the compare (so `unchanged`/`updated` cannot be used as a probe, and a full replacement cannot erase a field the actor cannot see). The create path for an absent ref with no restricted keys proceeds. Cost: one extra read; behaviour without `upsert_by` is untouched (it keeps today's no-check create-only import).
Consequences, stated plainly: (1) **fail-closed for admins**: an actor (including a tenant admin) who has an ungranted restricted field on the type cannot re-run an import against existing refs, nor update existing records by ref; every such entry returns `field_restricted`. The remedy is a field grant for that actor (or running the import as an actor with the grant); it is deliberate, since a compare or overwrite by an actor who cannot see the field is exactly the probe/erase channel. (2) **The rule is stricter than today's behaviour**: the existing `POST`/`PUT` record routes and the non-upsert import consult neither `TypeAccess` nor `FieldGrants` on write (`entities.ex:1017-1060`, `:1228-1380`); only the engine step-write path does. That stricter rule applies only in upsert mode, a new mode, and does not change any existing request. Aligning the plain routes is out of scope (separate issue; OQ-11).

Reasoning: the same actor who passes these checks can already read every field of the type through `query`, so the remaining signals add nothing; the checks close the channels for the actors who cannot.

### 4.6 Audit

Each created/updated record has its event with `actor_id` = the authenticated user (`entities.ex:1234`, INV-1). The `unchanged` outcome writes nothing by design; the per-entry `outcome` in the response is the operator's record. No audit-chain row is written (as today for record writes).

## 5. HTTP: `POST /entities/records/:entity_type/import`

### 5.1 Request

Additive optional members only. Existing check order (cap -> schema-version gate -> `entity_type` match; documented comment block `entities.ex:1214-1225`, calls `:1237-1239`) is untouched.
* Top level `"upsert_by"`: absent (default) or exactly `"external_ref"`; any other value -> 422 (new `check_upsert_by/1` after the entity_type match, so existing error ordering is unchanged).
* Per entry `"external_ref": {"system","id"}`. In upsert mode every entry needs a valid one; a missing/invalid ref is a per-entry `external_ref_invalid`, the rest proceed. **Why ref-less entries are rejected in upsert mode (AC [2])**: an upsert without a key cannot be idempotent; creating it plainly would silently duplicate on every re-run, defeating the one-time-safe import. "A record without `external_ref` is accepted" is satisfied where ref-less records are legitimate: the import WITHOUT `upsert_by` (today's create), `POST`/`PUT`, and every record created before this change (the columns are nullable); it is tested there (T2).
* **Entry `external_ref` without `upsert_by` (resolves rev 1's OQ-6): ignored**, like any unknown entry key today, so the no-`upsert_by` request is byte-identical in handling and response. Tested.
* `record_id` on an entry stays echo-only in both modes (`entities.ex:1348-1350`); it never addresses a record.

### 5.2 Handler flow with `upsert_by`

1. Router pre-check (once, before the first entry, hence before the existing first-entry-only `definition_not_found` fold): modelled on `RequestAccess.check/4` (`entities/request_access.ex:12-21`, #2700), which does the type-denial read and the existence read UNCONDITIONALLY with no short-circuit "so a denied and an absent request of the same shape do the same database work". Here, in this order and always all of them: (i) `TypeAccess.authorized?/3` (denied-or-allowed); (ii) the existence read (`Definitions.get_active_definition_by_name/2`); (iii) `FieldGrants.load_restrictions/3` (the actor's restriction set; run even when (i)/(ii) already decided refusal, discarded then); (iv) ONE `Registry.max_schema_version("ENTITY_RECORD_CREATED", prefix)` read (2.4). Only after all four reads is the decision made: absent OR denied -> the one shared 404 exit (same body, same code path, nothing logged or audited), so timing cannot tell a missing type from a denied one; otherwise a version below 2 -> 503 `event_schema_outdated`. This keeps the 404 fold of `run_import` (`entities.ex:1331-1334`) correct even when entry 0's ref is invalid: a malformed entry-0 ref cannot mask a 404 or be answered 200 for a nonexistent type.
2. Pre-scan: an entry whose `(system, id)` equals an EARLIER entry's is answered `duplicate_external_ref_in_request` (not written, regardless of value equality); the first occurrence proceeds. This replaces the #2543 same-`record_id` dedup in upsert mode.
3. Per entry (sequential, as `run_import` `entities.ex:1329-1346`): `Records.upsert_record_by_external_ref/2` (tenant-owned types only; the guard at `entities.ex:1229` still returns the constant 403 for managed types before the body is read).

### 5.3 Idempotency key (#2543)

* Server-derived, never client-supplied (the route has no `idempotency_key` member; `Idempotency` stays the only reader of client keys, `idempotency.ex:23-24`). Key = `"entities-record-import:" <> import_request_id <> ":ext:" <> lower-hex SHA-256 of (system 0x00 id)`, exactly 127 bytes by construction (23 + 36 + 5 + 64 -> `entities-record-import:` is 23, UUID 36, `:ext:` 5, hex 64), far under the `varchar(255)` limit that a raw 255-byte id would risk. `import_request_id` is minted per HTTP call (`entities.ex:1240`).
* Consequence: two separate calls never share a key, so the key is NOT what makes re-import idempotent; the external ref is. A byte-identical re-POST finds every record by ref and answers `unchanged` with zero events.
* Within one call a ref occurs once (pre-scan), so the key is never reused with a different request; `idempotency_key_reuse` cannot come from ref collisions. A retried attempt (4.1 step 5) reuses the same key; the rolled-back transaction released its claim.
* Without `upsert_by`: today's derivation (`entities.ex:1384-1390`) is untouched.

#### 5.3.1 `is_duplicate` and replay for a caller-chosen key (REQ-501 module handler)

The module handler may pass its own key and replay it. The function is **convergent, not replay-keyed**: its result is a function of current state first, and the key only protects the append.
* Replay of a create whose record still equals the file's values: step 3 finds the record, step 4 answers `:unchanged`, `is_duplicate: false`, no append (the key is not even consulted).
* Replay when the record was changed in between by someone else: step 4 reaches the update path, the append claims the SAME key already bound to the earlier CREATED event with a different event type/request, so the underlying command answers `{:error, :idempotency_key_reuse}` (#2543 binding, `records.ex:67-88`); the upsert returns that error unchanged (no retry, not a contention). The handler caller must use a distinct key per logical request.
* Replay of an update likewise: equal -> `:unchanged`; changed in between -> `:idempotency_key_reuse`.
* `is_duplicate: true` is returned only if the underlying `create_record`/`update_record` returns it (a replay racing between the lookup and the append); the result then carries `outcome` of the original (`:created`/`:updated`) and the original record decoded from the stored event, as the single commands do. It is a normal, safe result.

### 5.4 Partial failure and cap

**Per-entry report, not whole-file rollback; the cap stays 200 (`@import_record_cap`, `entities.ex:1284`), 413 above it.** Reasons: (a) it is today's contract: `create_record` "commits its own transaction per call and is never composed into an outer Multi" (`entities.ex:1322-1324`); (b) a whole-file rollback would hold the type's sequence row and index across up to 200 writes, extending the hold that decision 0061 shrinks, and change the response contract; (c) idempotency by ref makes re-running a partly failed file convergent: that, not atomicity, is the recovery path. Larger seed sets are sent as several <= 200 requests.

### 5.5 Response, schema version, rolling deploy

* Status/shape unchanged: 200 `{"results": [...]}` (`entities.ex:1244`). In upsert mode an `ok` entry also carries `"outcome"` (`created|updated|unchanged`) and `"external_ref"`; `error` reasons gain `external_ref_invalid`, `external_ref_record_deleted`, `external_ref_contention`, `duplicate_external_ref_in_request`, `entity_append_only`, `field_restricted` (constant, no detail; mapped in `import_reason_json/1`, `entities.ex:1411-1449`). Without `upsert_by` the response is byte-identical.
* **No bump of `record_export_schema_version`** (decided): it is an exact-match gate on `"entities/record-export/v1"` (`entities.ex:1226`, `:1305-1310`, also used by export at `:2343`); the change is additive request members, and a v1 document without them behaves as before. A bump would reject every existing export/import round trip.
* **Rolling deploy and rollback** (an old node ignores unknown request members, so an `upsert_by` request landing on an old node would silently create duplicates, because the old handler is create-only): accepted, with the mandatory rollout order **migration -> event schema v2 in every tenant -> code**; and the operational rule that the one-time seed (D12) runs only after the deploy has completed on all nodes (a single humanless merge-and-deploy; the seed is a one-off operator action, not a client-library default). A marker old nodes would reject is not available without bumping the version gate (which we declined); the alternative of bumping was weighed and rejected because it breaks export-to-import. Residual risk is stated for SECURITY-REVIEWER/REVIEWER (OQ-9). Rollback of code after the migration: columns, index and v2 schema remain and are inert (nullable; v1-shaped payloads valid under v2); records already holding refs keep them; an old node simply never writes refs.

## 6. Compatibility, existing tenants, exam module

* No `upsert_by`: request handling, derived keys, results byte-identical (regression test T8).
* Existing tenants: two NULL columns, a CHECK (migration a) and an empty partial index (migration b), 2.1, plus CREATED v2 registered by the replay (2.4). No backfill. Lock cost: one ACCESS EXCLUSIVE scan then one SHARE scan per tenant at boot (2.1, OQ-10).
* Exam module (`lib/letflow/modules/exam/*`; managed types written with `Owner` authority and `idempotency_match: :target`, `records.ex:84-87`): untouched; it never passes `external_ref`. `duplicate_result/1` (`records.ex:1376`) builds a `%Latest{}` without the new fields (nil), correct for a ref-less duplicate.
* Replay/rebuild: extended as in 2.5.

## 7. Permissions and SECURITY-REVIEWER scope (AC [4])

* **Ruling (supervisor, applied): `EntitiesRecordsImport` alone suffices for `upsert_by`, including its update branch.** The route-level gate is unchanged (`authorization.ex:1036`, `:1372`); no new permission atom, no second in-handler permission check. Basis: AC [4] literally; decision 0057 D1/D12 name `EntitiesRecordsImport` as the seed gate; `authorization.ex:117-124` documents Import as the more privileged, deliberately separate grant. Requiring `EntitiesRecordsWrite` as well would be an explicit AC change for the supervisor and is not done.
* **Pinned equivalence test (escalation provably nil today)**: a test reads `priv/permission_matrix/effective.golden` (the matrix `test/letflow/api/permission_matrix_test.exs` already pins) and asserts that every role with `EntitiesRecordsImport true` also has `EntitiesRecordsWrite true`. Current golden: Import is true for PLATFORM_ADMIN (`:123`) and TENANT_ADMIN (`:319`); both hold Write (`:124`, `:320`); the only other Write holder is PROCESS_OPERATOR (`:222`), which has no Import. If a future role grant breaks the equivalence the test fails and forces a conscious decision.
* **Doc change**: the `authorization.ex` moduledoc entry for `:EntitiesRecordsImport` (`:117-124`) gains a sentence that, with `upsert_by`, the grant covers updating existing records by external ref within the type.
* Restrictions that DO apply in upsert mode are data-path checks, not permission changes: `TypeAccess` folded to 404 and write-side field restrictions (4.5).
* SECURITY-REVIEWER triggers: migration on a tenant data table; unique index spanning a tenant's types; new registered event schema version; tenant-data write path with a new update branch; response shaping (`record_map`, import results); lookup is `prefix`-scoped (INV-1/INV-5): a ref from another tenant is simply absent. `external_ref_record_deleted` reveals only a deleted record of the caller's own tenant in a type the caller is allowed to access.
* INV-7/8: Ecto only, no SQL from data; no tenant data in logs; the `import_reason_json` catch-all stays for anything unmapped.

## 8. Reproduce-first

On the unchanged base, a failing test (T1-repro) imports the same two-entry file twice and asserts one record per entry: it fails today (four records). It becomes the T1 test once `upsert_by` exists.

## 9. Test plan (ExUnit, real Postgres, tenant schemas, no mocks)

| ID | AC | Test |
|---|---|---|
| T1 | [2] | Import a file of N refs twice with `upsert_by`: second response all `unchanged`, row count N, event count unchanged. Variant: second file changes a field -> `updated`, still N rows, one new UPDATED event each. `append_only` type: second identical import all `unchanged` (F3); a differing value on an append-only type -> `entity_append_only`. |
| T2 | [2] | Record without `external_ref` accepted: import WITHOUT `upsert_by` creates ref-less records as today; `POST`/`PUT` ref-less unaffected, responses have no `external_ref` key; pre-existing rows have NULL/NULL; in upsert mode a ref-less entry is a per-entry `external_ref_invalid` and the rest are written. Entry `external_ref` without `upsert_by` is ignored (no ref stored). |
| T3 | [2] | Two systems, same id: `{1c,"42"}` and `{sap,"42"}` -> two records, independent updates; same pair in two entity types -> two records. |
| T4 | [2] | Partial failure (per entry, 5.4): 5 entries, 2 bad (enum violation; missing ref) -> HTTP 200, 3 ok + 2 error, 3 rows; re-post of the corrected file converges. 201 entries -> 413, nothing written. Duplicate ref in the file -> second entry `duplicate_external_ref_in_request`. Deleted ref -> `external_ref_record_deleted`, no event. |
| T5 | [3] | Concurrency: two processes import the same ref set behind a barrier (<= 4 workers, bounded): exactly one row per ref, no 5xx, outcomes `created` + `updated`/`unchanged`. Forced overlap: hold the type's sequence row from a third connection, queue two creates, release; one wins by the index, the other converges; deadlock and lock-timeout errors observed through the Repo telemetry event (0061 rule 5) so a retry cannot hide them. Direct index tests: same triple twice -> unique violation; same pair in another type -> ok; the pair CHECK rejects `(NULL,'x')`. `external_ref_conflict?/1` unit test; retry-exhaustion -> `external_ref_contention`. |
| T6 | [3] | Same `(type, system, id)` in two tenants -> two records, one per schema; tenant A's import never changes tenant B's row; a lookup under A's prefix cannot see B's. |
| T7 | [3] | Idempotency (#2543): second byte-identical POST has different derived keys yet `unchanged`; a 255-byte id yields a key of exactly 127 bytes and is accepted; within-call same ref with different values -> `duplicate_external_ref_in_request`, never `idempotency_key_reuse`; without `upsert_by` the existing #2543 import tests pass unchanged; module caller replay: replay with record unchanged -> `unchanged`, `is_duplicate: false`; replay after an intervening change by another writer -> `idempotency_key_reuse` (5.3.1). |
| T8 | [1] | Backward compatibility: golden comparison of an existing import test's response and events pre/post change (byte-identical); managed type -> constant 403 with and without `upsert_by`. |
| T9 | [1] | Event schema (B1): a ref-carrying create validates under v2 and the append succeeds; UPDATED payloads carry no ref and stay v1; v2 exists in a FRESH tenant AND in an UPGRADED tenant (provisioned at the pre-change state with v1 only, then `replay_migrations/2` -> `max_schema_version == 2` for CREATED only; UPDATED and DELETED still 1); re-seeding an upgraded tenant hits the duplicate case and is a no-op (`seed!/1` unchanged); a tenant at v1 gets the router's whole-request 503 `event_schema_outdated` with nothing written, from ONE `max_schema_version` read per request (assert read count); a v1-shaped payload still validates under v2. |
| T10 | [1] | Replay: extend the REQ-229 live-vs-rebuilt equivalence test with ref-carrying records: `rebuild_projection/2` (through `write_snapshots/3`) reproduces both columns; a record updated twice keeps its ref; a deleted record keeps it; engine step-written records (`command_multi/3`) stay NULL/NULL. |
| T11 | [2] | Decimals: strict-decimal field `"12.5"` normalises to the padded string; re-import of `"12.50"` -> `unchanged` (compare after normalisation). |
| T12 | [4] | Permission: pinned equivalence test over `effective.golden` (Import true -> Write true, 7); Import-only caller (a synthetic role in a test) with `upsert_by` is allowed and can update (documents the ruling); caller without Import -> 403 as today. |
| T13 | [4] | Data-path checks (4.5): a type-denied caller in upsert mode gets the byte-identical 404 of an unknown type; an actor with a restricted field gets `field_restricted` for a restricted key, and for an existing-ref entry before any compare (no `unchanged`/`updated` probe); the same actor without `upsert_by` is unchanged from today. |
| T14 | [1] | 404 fold (F8): upsert request for an unknown type whose FIRST entry has a malformed ref -> 404 (not 200 with a per-entry error); same for a type-denied caller. |
| T15 | [1] | Ref validation unit tests for `ExternalRef.parse/1` (case, length, NUL, unknown keys, non-string id). |
| T16 | [1] | Migration: a fresh tenant and an upgraded tenant both have the columns, the CHECK (validated), the index, and the manifest entry. |

## 10. PR split, risks, open questions

| PR | Content | Size |
|---|---|---|
| PR-1 | Migrations (a) columns+CHECK and (b) index, two files, two manifest entries + `Latest` fields/changesets + `Latest.get_by_external_ref/4` + `ExternalRef` + CREATED v2 spec (replaced in place; `seed!/1` untouched) + `Projector` (`snapshot()`, `apply_event`, `write_snapshots/3`) + `record_map` conditional key + tests T9 (schema parts), T10, T15, T16. Writer-free: nothing writes a ref yet. | M |
| PR-2 | `Records.upsert_record_by_external_ref/2,3` (loop, outcomes, `external_ref_conflict?/1`) + domain tests T1 (domain), T3, T5, T6, T7 (module-caller part), T11. | M |
| PR-3 | Router: `upsert_by`, pre-check, pre-scan, derived key, results/reasons, `TypeAccess`/field-restriction checks, `authorization.ex` moduledoc note, moduledoc table row, HTTP tests T1, T2, T4, T7, T8, T12-T14, docs. | M |

Merge order PR-1 -> PR-2 -> PR-3 (the rollout order of 2.4 is thereby structural). SECURITY-REVIEWER on PR-1 and PR-3.

Risks: optimistic loop under heavy contention (bounded, fallback 4.2); index build SHARE lock on a large tenant table (single scan; accepted); `unchanged` writes no event (by design); rolling-deploy duplicate window for an upsert request on an old node (5.5, mitigated by rollout order and operational rule); a future writer of `entity_record_latest` that skips the ref (guarded by T10).

Open questions for the supervisor:
* OQ-1: are the WMS masters tenant-owned types (HTTP import reaches them) or module-managed (only the module handler, via the same primitive)?
* OQ-2: a re-import of a soft-deleted ref is refused per entry (this design); revive instead would need a new event type.
* OQ-3: expose `external_ref` in query/export rows and as a filter (IN-06, MD-01 will need it)? Out of scope here.
* OQ-4: a client-supplied expected version per entry? Not in this design.
* OQ-7: should single `POST`/`PUT` accept `external_ref`? Not in scope; the primitive supports it.
* OQ-9: accept the rolling-deploy duplicate window of 5.5, or require a distinct request marker (which means a version-gate change)?
(Resolved in this revision: permission model (7), ref-less entries (5.1), entry ref without `upsert_by` (5.1), schema-version bump (5.5).)
* OQ-10: is the boot-time lock cost of 2.1 (one ACCESS EXCLUSIVE scan and one SHARE scan per tenant, each in its own transaction) acceptable, or should the replay be run in a maintenance window?
* OQ-11: align the plain `POST`/`PUT`/non-upsert import with the upsert-mode TypeAccess and field-restriction checks (4.5)? Separate issue.

## 11. Notes for ELIXIR-DEV (test fallout)

* Adding `external_system`/`external_id` to the projector `snapshot()` map (`projector.ex:90`) and to `Latest` can break exact-map assertions in `test/letflow/entities/record/projector_test.exs` and any test comparing a whole `%Latest{}`/snapshot; update them in PR-1.
* Any test asserting the `seed!/1` result shape or the registered `ENTITY_RECORD_CREATED` `schema_version` (now 2 on fresh tenants, with no v1 row) must be updated in PR-1; `seed!/1` itself is unchanged.
* The tenant-provisioning manifest count/ordering tests change by two entries (migrations a and b).
