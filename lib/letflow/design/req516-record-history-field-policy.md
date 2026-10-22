# REQ-516 design: consumers of entity-event `field_values`, the record history route and the shared FieldPolicy

Issue #2701 (Refs, not Closes). Decision 0059 (accepted) fixes the direction; this record re-derives the
consumer list from `main` (80390c78b) and decides redaction point and storage form per consumer. No product code
changes in this task. Repo copy: `lib/letflow/design/req516-record-history-field-policy.md` (identical).

## 1. Problem

Entity events (`ENTITY_RECORD_CREATED` v1/v2, `ENTITY_RECORD_UPDATED`) carry the full record `field_values`
(`lib/letflow/entities/records.ex:1198-1210`, built by `build_event_attrs/3`). Field restrictions (REQ-231) are
applied to query, record writes' responses and exports, but there is no record history route, and no rule says how
any other copy of those values must be redacted. This design (a) lists every consumer on main, (b) fixes the
redaction point and storage form of each, (c) specifies `GET /entities/:type/records/:id/history` and the
remaining `FieldPolicy` surface, (d) lists the implementation slices.

## 2. What already exists (so the design stays small)

- `Letflow.Entities.FieldPolicy` is on main (#2697, `lib/letflow/entities/field_policy.ex`): `restriction_set/2`,
  `load_sets/2`, `check_request/4` (request side), `redact/3` (loads the set, applies the sentinel) and
  `redact_with_sets/3` (pure). Rule: a field is restricted for a user when an `entity_field_restrictions` row exists
  and the user holds no `user_entity_grants` row for it; roles play no part (`FieldGrants.load_restrictions/3`).
  The sentinel is the atom `:__field_redacted__` (`FieldGrants.redact_field_values/2`): key kept, value replaced.
- #2702 is on main: `Letflow.EventStore.InstanceVisibility` (`exclude_synthetic/2`, `synthetic?/2`) hides the
  per-entity-type synthetic instances from every Instances route (`routers/instances.ex` moduledoc "Synthetic
  entity-type instances are invisible"). Record events live ONLY on those synthetic instances
  (`Records` appends with `EntityTypeInstance.get_or_create/2`); process instances carry
  `TASK_ENTITY_WRITES_APPLIED` whose payload is an allowlist without values (`Response.applied_payload/1`).

## 3. #2702 ordering dependency (stated as required)

With #2702 merged, `GET /instances/:id/history|timeline` answer 404 for a synthetic instance, so **no role,
TENANT_AUDITOR included, can read record create/update history anywhere until this route lands**. Record history for
auditors is served only by the new route. Rollout order, planned together with #2718 (attachment routes):
1. FieldPolicy additions and the route ship together (slice S2) and the route is reachable by TENANT_AUDITOR
   (it holds `:EntitiesQuery`, `test/letflow/api/authorization_tenant_auditor_test.exs` `@auditor_granted`);
2. nothing may re-open the synthetic instances on `/instances` as a stop-gap;
3. docs (`docs/roles.md`, the `routers/instances.ex` moduledoc sentence "until REQ-516 ... lands") are updated in S2.
The auditor-visibility gap is therefore open from the #2702 merge until S2 merges; S2 is ordered right after the
webhook/outbound slice only because that slice is a few lines (S1); S2 may go first if the operator prefers to close
the auditor gap sooner (no code dependency between S1 and S2 except the shared helper in section 5.1).

## 4. Consumer inventory (read from main; each row re-derived by grep)

Commands run (all in the worktree at 80390c78b):
- `grep -rn "field_values" lib --include=*.ex` (the producers/consumers below),
- `grep -rnE "Webhooks\.deliver\(|deliver\(" lib --include=*.ex | grep -v "def deliver\|design/"` -> only
  `login_discovery/dispatch.ex:98,111` (unrelated e-mail adapter): `Webhooks.deliver/3` has NO production caller
  (`webhooks.ex:70-74` states automatic triggering is out of scope),
- `grep -rnE "Logger\.[a-z]+.*(payload|field_values)" lib --include=*.ex` -> no hit;
  `grep -rnE "inspect\((payload|event|attrs|record|ctx|row|changeset|command)" ... | grep -iE "log|warn|error|info"`
  -> `platform/migration_rollout.ex:493`, `mix/tasks/letflow.seed.ex:67` (changeset errors, no values),
- `grep -rnE "EventStore\.(read|read_global|point_in_time|get_legacy_original)\(" lib` -> `entities/record/projector.ex:153,266`
  (internal projector), `idempotency.ex:232` (legacy original lookup); `read_global/1` has no caller.

| # | Consumer | file:line | Carries event `field_values` today? | Redaction point | Storage form |
|---|----------|-----------|--------------------------------------|-----------------|--------------|
| C1 | Event store rows (source of truth) | `entities/records.ex:1198-1231` (`build_event_attrs`), `event_store.ex` `append/2` | YES, full values | none: the event is the record of truth (decision 0059 D2: existing events are never rewritten) | stored RAW |
| C2 | **Record history (NEW route)** | does not exist: `grep -n "history" lib/letflow/routers/entities.ex` -> no route | will read C1 | read time, per caller, `FieldPolicy.redact_event_payload/3` (5.2) | not stored; computed per request |
| C3 | `GET /instances/:id/history` payload, `Response.public_event_payload/2` | `api/response.ex:96-115`; caller `routers/instances.ex:1012-1022` | not reachable for record events since #2702 (synthetic = 404); the generic `true ->` arm would pass `field_values` through verbatim if one ever were | defence in depth: `public_event_payload/2` gets an arm for `ENTITY_RECORD_*` that drops `field_values` (no principal there, so it removes, never shows) | not stored |
| C4 | `GET /instances/:id/timeline` | `instances.ex:179-225`, `routers/instances.ex:1048-1060` | no: item has `metadata`/`description`, not payload | none needed; guarded by the 404 of #2702 | not stored |
| C5 | Webhooks, `Letflow.Webhooks.deliver/3` | `webhooks.ex:247-360`, JSON body `Jason.encode!(payload)` at `webhooks.ex:275`; attempt rows (`webhooks/delivery.ex`) hold no payload | latent: caller-supplied `payload`; no caller | at the dispatch entry, before `Jason.encode!`: `FieldPolicy.redact_for_recipient/3` (5.3). A recipient is external: no principal, no grants | the delivery row has no payload; the body is built redacted per call (redact on send) |
| C6 | Webhook -> DLQ landing | `webhooks.ex:464-475` `land_in_dlq` (`source_payload: payload`) | latent, same payload as C5 | the SAME already-redacted payload C5 sent is what is passed to `land_in_dlq` (no second raw copy exists) | stored ALREADY-REDACTED |
| C7 | Outbound service-task requests | `engine/service_task_dispatcher.ex:958-975` `build_outbound_audit_context` (`rendered_body`), `:994-1010` `audit_outbound_request`; DLQ `engine.ex:9889` `source_payload: Map.fetch!(context, :attempted_request)` | not today: the body is rendered from INSTANCE VARIABLES; record values reach variables only through script reads, which already omit restricted fields (`entities/script_reads.ex:165-185,285-310`). The variable case is decision 0062 R12 (labels); out of scope here | this design adds one rule for any future direct path: a rendered body/URL that embeds entity `field_values` goes through `redact_for_recipient/3` first | audit `after_state` and DLQ `source_payload` store the ALREADY-REDACTED rendered request |
| C8 | Service-task exhaustion DLQ row | `engine.ex:9843-9895` | as C7 | as C7 | already-redacted |
| C9 | DLQ read API `GET /dlq*` | `routers/dlq.ex:221` (`"source_payload" => entry.source_payload`), `dlq/entry.ex:52` | whatever C6/C8 stored | none at read: rows are stored redacted (C6/C8); read redaction is impossible because the DLQ has no entity type/principal context | stored |
| C10 | Audit entries | `audit.ex:233-258` (`insert_entry`, `before_state`/`after_state`), chain hash `audit.ex:598-631`, list `audit.ex:355-372`, `routers/audit.ex:151` | NO record audit exists: every `Audit.insert_entry` caller (`grep -rn "Audit.insert_entry" lib`) is identity/definitions/engine/stamp, e.g. `entities/managed_types/stamp.ex:405-421` stores counts and type names only | write time. An entry is hash-chained (`audit.ex:630` canonical JSON in the hash), so it cannot be redacted later; a future record audit must store `FieldPolicy.redact_for_recipient/3` output | stored ALREADY-REDACTED (rule); guard test forbids a raw `field_values` key in audit states |
| C11 | Event exports | `grep -rniE "event.*export|export.*event" lib/letflow/routers` -> none. Record export `POST /entities/records/:entity_type/export` (`routers/entities.ex:500`, `export_record_map` `:1838-1856`) | records, not events; already redacted by `check_request`/`redact_page` with `EntitiesRecordsExportUnredacted` as the only bypass | already covered by #2697 | not stored |
| C12 | Logs | grep above: no `field_values`/payload in any log call | no | rule + lint guard (S5): no `Logger` call may interpolate a payload, event, or `field_values` | never logged |
| C13 | Internal readers | `entities/record/projector.ex:153,266` (builds `entity_record_latest`), `entities/script_reads.ex:179` (select), `entities/record_access.ex`, `modules/read_api.ex:45`, `modules/org/org.ex:128`, `modules/catalog_items/catalog_items.ex:119` | yes, trusted in-process code | script reads omit restricted fields (existing); `read_api`/`org`/`catalog_items` read managed foundation types with no restriction rows by definition | n/a |
| C14 | Idempotency / tamper / squat tooling | `idempotency/squat_audit.ex:290,466`, `entities/managed_types/tamper_inventory.ex:33,234-257`, `release/idempotency_squats.ex:20` | read single keys (`session_id`, `user_id`) inside SQL; report ids and counts only, never values | none needed | n/a |
| C15 | Archive / retention | `event_store/archived_event.ex:69` (`payload` column), `event_store.ex:1473` `archive/1`, `engine/reconstruction.ex:327,404` | archive copies the payload verbatim (same trust level as C1) | none: not client-readable; if an archive read route is ever added it must call C2's redactor | stored RAW (same as C1) |

Consumers that are PRESENT and leaking today: none after #2702 (C3 is the only latent hole and C2 is the missing
route). Consumers that are LATENT (would leak the moment wired): C5-C8, C10, C12. That is why the design fixes the
rule now.

## 5. Design

### 5.1 Storage-form rule (the one decision per consumer class)

- **Interactive reader with a principal (C2):** redact at READ time with the caller's CURRENT restrictions and
  grants. Nothing stored. Consequence (decision 0059 D2, to be stated in `docs/`): a restriction removed later
  exposes history written while it applied.
- **Consumer that leaves the system or is immutable (C5-C10):** there is no caller principal and the copy cannot be
  re-redacted later (DLQ has no context, audit is hash-chained). So these store/send the payload ALREADY-REDACTED
  at the point of copy, using the restriction ROWS only (every field with an `entity_field_restrictions` row is
  masked; no grants apply, because a recipient has no user). Effect, stated plainly: once a field is restricted,
  external recipients never see it and removing the restriction later does NOT retroactively reveal it in a DLQ
  row or audit entry. This is stricter than C2 on purpose: outside copies are not "a view of the record".
- Masking form for stored copies: the existing
  atom sentinel (it JSON-encodes as `"__field_redacted__"`, identical to query results, and cannot collide with
  JSON data). One mask for the whole platform.

### 5.2 `Letflow.Entities.FieldPolicy` additions (module already exists; nothing is renamed)

```
@spec redact_event_payload(principal(), String.t(), map()) :: {:ok, map()} | {:error, :invalid_schema_name}
  # event payload "field_values" redacted via restriction_set/2; other keys untouched; an event
  # type without "field_values" (ENTITY_RECORD_DELETED) is returned unchanged.
@spec redact_event_payload_with_sets(restriction_sets(), String.t(), map()) :: map()   # pure
@spec restricted_anywhere(String.t() /*prefix*/, String.t()) :: {:ok, MapSet.t(String.t())} | {:error, :invalid_schema_name}
  # fields that have ANY entity_field_restrictions row (no grants): FieldGrants gets
  # load_all_restricted/2 (one query, same prefix scoping and tenant_id_for_schema_name check as load_restrictions/3).
@spec redact_for_recipient(String.t() /*prefix*/, String.t() /*entity_type*/, map()) :: {:ok, map()} | {:error, :invalid_schema_name}
  # redact_field_values/2 with restricted_anywhere/2.
```
Errors propagate; a loader error is never treated as "no restrictions" (as `load_sets/2` today). `principal` is built
only from the auth context and the resolved tenant prefix (INV-1). Routes carry no field logic of their own: the
route calls `redact_event_payload/3` and nothing else.

### 5.3 Where each redaction is wired (slice detail)

- C5/C6: in `Webhooks.deliver/3`, `payload` is passed through `redact_payload_for_delivery/2` before
  `attempt_loop`: for a payload that is an entity event (`"entity_type"` + `"field_values"` keys) it applies
  `redact_for_recipient/3` with the subscription's tenant prefix; any other payload is unchanged. One
  redacted map is used for the body, the signature (`Jason.encode!` bytes, `webhooks.ex:275`) and `land_in_dlq/6`.
  Failure to load restrictions fails the delivery closed (no request is sent, the error is returned).
- C3: `Response.public_event_payload/2`: new `cond` arm for `event_type in ["ENTITY_RECORD_CREATED",
  "ENTITY_RECORD_UPDATED"]` returns `Map.delete(payload, "field_values")`.
- C7/C8: no code change now (no direct path). A guard test (S5) pins that `service_task_dispatcher.ex` and `engine.ex`
  do not reference `field_values`, so a new path forces a conscious change.
- C10/C12: guard tests only (S5).

### 5.4 `GET /entities/records/:entity_type/:record_id/history`

Path note: the issue says `/entities/:type/records/:id/history`; the router mounts entities under
`/entities` with `/records/:entity_type/:record_id/...` (see the attachment routes, `routers/entities.ex:444-475`).
The route is declared in that style: `GET /entities/records/:entity_type/:record_id/history`. This is an
assumption (listed below); the shorter form in the issue cannot be added without breaking the router's convention.

- Declaration (mirrors `GET .../attachments`, `routers/entities.ex:454`):
  `authz_get "/records/:entity_type/:record_id/history", :EntitiesQuery, scope: {:resolver, {ScopeResolver, :record_scope}}`.
  Permission `:EntitiesQuery` is reused (history is a read of the same records; TENANT_AUDITOR, TENANT_ADMIN,
  PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER hold it, `docs/roles.md:188`). No new permission atom, so
  `core_permissions` counts and the role matrix are unchanged. Route inventory `api/route_scope.ex:114-115` gains the
  line `"GET /entities/records/:entity_type/:record_id/history EntitiesQuery"`.
- Handler, new module `Letflow.Routers.Entities.RecordHistory` (keeps `routers/entities.ex` line pins stable):
  1. `ScopeGate.scope_set(conn, :EntitiesQuery)`; entity type gate through `TypeAccess` (a hidden type = same 404);
  2. `Ecto.UUID.cast(record_id)` else 404;
  3. record visibility: `ScopedLookup.fetch_in_scope/5` for a scoped caller; for scope `:all` (which returns
     `{:ok, :unscoped}` without a lookup, `scoped_lookup.ex:55`) an explicit existence check on `entity_record_latest`
     (deleted rows included, so the history of a deleted record is readable). Out-of-scope, hidden type and
     nonexistent record are ONE response: the same 404 body (INV-5), same code path as attachments
     (`visible_or_fresh_id`/`parent_visible?` pattern);
  4. events: `from(e in Event, prefix: ^prefix, left_join: sp in "event_payload_store", on: sp.event_id == e.event_id and
     sp.event_created_at == e.created_at)` restricted to the entity type's synthetic instance
     (`EntityTypeInstance.fetch_instance_id/2`), with
     `fragment("COALESCE(?->>'record_id', ?->>'record_id')", e.payload, sp.payload) == ^record_id` (parameter binding,
     INV-7) and the payload selected as `COALESCE(sp.payload, e.payload)`. This is the pattern of
     `entities/managed_types/tamper_inventory.ex:224-237` (`record_id_of/2`). It is required because an oversized
     payload is stored in `events.payload` as the single-key map `{"$ref": event_id}` with the real bytes in
     `event_payload_store` (`event_store.ex:930`, `stored_payload.ex:29`, `records.ex` `resolve_original_payload`);
     filtering `events.payload` alone would silently drop the create/update events of records with large field
     values. `Instances.history/3` (`instances.ex:139-163`) does NOT resolve `$ref` and `EventStore.resolve_payloads/2`
     is private (`event_store.ex:1643`), so neither is reused. Order by `sequence_number`, keyset cursor + `page_size`
     in SQL (so pagination stays correct; no in-memory filtering). Tenant prefix explicit (INV-1).
     Performance: there is no index on the record_id key, so the query scans the type's synthetic-instance event
     stream per request. Accepted for this slice (no migration); a follow-up expression index on
     `(COALESCE(payload->>'record_id', ...))` is named as later work for the operator if histories get long.
  5. `FieldPolicy.load_sets(principal, [entity_type])` once per request, then `redact_event_payload_with_sets/3` per
     item; strict-decimal rendering via `Decimals.render_field_values/2` as `Support.record_map` does.
  6. Item shape (hand-built map, INV-2): `event_id, event_type, sequence_number, created_at, actor_id,
     actor_display_name, entity_def_version, field_values` (redacted). No raw payload, no `external_ref`, no `_sys`.
     `ENTITY_RECORD_DELETED` has no `field_values`; the item omits the key.
- Scope caveat, stated in docs: the scope filter uses the record's CURRENT scope column; earlier events written
  while the record sat in another node are shown with the same access. The scope column itself, if restricted,
  is masked like any other field.
- No ETag/caching, no writes, no new table, no migration, no feature flag (read-only route, additive).

### 5.5 Deliberately left out

Rewriting stored events; per-subscription grants for webhooks (needs a schema change; see assumption A2); a record
audit trail; an event-export route; resolving restricted values carried in instance VARIABLES (decision 0062);
changing `/instances` visibility; any UI.

## 6. Tests (each: restricted value ABSENT without access, PRESENT with the grant)

Fixtures: tenant with a type `T`, a restriction row on field `secret`, user U1 (no grant), user U2 (grant row in
`user_entity_grants`), record created with `secret="s3"`, one update.

| ID | File (new unless noted) | Asserts |
|----|--------------------------|---------|
| H1 | `test/letflow/routers/entities/record_history_test.exs` | U1 `GET .../history`: every item's `field_values["secret"] == "__field_redacted__"`, body does not contain `s3`; U2 (grant): value `"s3"` present in the create and update items |
| H2 | same | the same record read by a TENANT_AUDITOR without grant -> masked; with grant -> present (the #2702 dependency path) |
| H3 | same | restriction row removed afterwards -> U1 now sees `s3` (documents the read-time consequence of decision 0059 D2) |
| H4 | same | INV-10/INV-5: a record id of another tenant, an id outside the caller's 0051 scope, a hidden entity type and a random uuid return byte-identical 404 bodies; cross-tenant negative test |
| H5 | same | oversized payload: a record whose field values exceed the inline limit (payload stored as `{"$ref": id}`) still shows its create and update events in history, redacted for U1, present for U2; pagination: `page_size`, cursor continuity, deleted record's history readable, `ENTITY_RECORD_DELETED` item has no `field_values` |
| P1 | the existing FieldPolicy test file (find with `grep -rl FieldPolicy test`; create `test/letflow/entities/field_policy_test.exs` if none) | `redact_event_payload/3` masks for U1, passes for U2; `restricted_anywhere/2` ignores grants; loader error propagates (never "unrestricted") |
| W1 | `test/letflow/webhooks_delivery_test.exs` (extend) | delivered body of an entity-event payload has `secret` masked; with the restriction row removed (a recipient's only "grant") the value is present; signature is computed over the masked bytes |
| W2 | same | exhausted delivery: the `dlq_entries.source_payload` holds the masked value, never `s3`; restriction later removed -> still masked (stored already-redacted) |
| R1 | `test/letflow/api/response_test.exs` (extend) | `public_event_payload("ENTITY_RECORD_CREATED", %{"field_values" => ...})` has no `field_values` key |
| G1 | `test/letflow/entities/field_values_consumers_guard_test.exs` | source scan: `service_task_dispatcher.ex`, `dlq*.ex`, `audit.ex` and every `Audit.insert_entry` attrs builder contain no `field_values`; no `Logger` call interpolates a payload; the allowed-consumer list is the table in section 4 |
| T1 | `test/letflow/api/route_scope_resolver_test.exs`, `route_scope.ex` inventory (extend) | the new route line is registered |

Tests that must change for S2 (greps run: `grep -rn "records/:entity_type/:record_id/attachments" test`, which lists
`entities_test.exs`, `route_scope_walk_test.exs`, `authorization_test.exs`):
- `test/letflow/routers/entities_test.exs:273-299`: title "returns exactly the eighteen designed routes" becomes
  "nineteen"; `assert length(actual) == 18` becomes 19; add `{"GET", "/records/:entity_type/:record_id/history", :EntitiesQuery}`
  to the exact `expected` list.
- `test/letflow/api/route_scope_walk_test.exs:310-326`: add `{"GET", "/records/:entity_type/:record_id/history", resolver}`
  to the Entities per-route class list and update the "eight resolver routes" comment to nine.
- `test/letflow/api/authorization_test.exs` (around 1571, 1998, 2214): these lists are samples, not exhaustive sets, so
  they do not break; the developer adds the history route to the `endpoint_policy_key` case list (about 2214) for coverage.
- `test/letflow/api/route_scope_resolver_test.exs:37-38`: inventory list gets the new line (T1).
No `core_permissions` count test changes (no new atom).
CRLF/line pins: new handler lives in a new file; do not add lines above cited symbols in `routers/entities.ex`
beyond one `authz_get` block (`grep -rl "entities.ex" test/` then run each hit).

## 7. Implementation slices (for the operator to file; the team does not file issues)

| Slice | Content | Order | Tests |
|-------|---------|-------|-------|
| S1 | `FieldPolicy.redact_for_recipient/3`, `restricted_anywhere/2`, `FieldGrants.load_all_restricted/2`; wire `Webhooks.deliver/3` + DLQ landing (C5, C6); outbound rule + guard for C7/C8 | first (decision: webhooks and outbound first) | P1 (recipient part), W1, W2 |
| S2 | `FieldPolicy.redact_event_payload/3` (+ `_with_sets`), the history route + `RecordHistory` module, route inventory, docs (`docs/roles.md`, `routers/instances.ex` moduledoc, consequence of read-time redaction); closes the TENANT_AUDITOR gap of section 3 | second, may swap with S1 | P1 (event part), H1-H5, T1 |
| S3 | `Response.public_event_payload/2` arm for `ENTITY_RECORD_*` (C3) | third | R1 |
| S4 | Guards for C10/C12/C7-C8 (audit states, logs, dispatcher) | last | G1 |

Each slice is one PR with `Refs #2701`; the last closes it. S1 and S2 touch tenant-data paths: SECURITY-REVIEWER is mandatory.

## 8. Assumptions and open points for the owner

- A1: route path is `/entities/records/:entity_type/:record_id/history` (router convention) not `/entities/:type/records/:id/history`.
- A2: acceptance wording "present with a grant" cannot hold literally for webhook/outbound/DLQ/audit: a recipient has no user and a
  subscription has no owner column (`webhooks/subscription.ex:76-92`). The design uses "present when no restriction row exists" for
  those tests. Alternative needing a migration: a `grant_user_id` on the subscription so delivery uses that user's grants; not chosen
  (new column, stale-grant risk, external recipient). SECURITY-REVIEWER to confirm.
- A3: `:EntitiesQuery` is reused for the route rather than minting `:EntitiesRecordsHistoryRead`.
- A4: webhooks currently have no automatic trigger, so S1 hardens `deliver/3` before a trigger exists; no behaviour change today.
