# GH #2597 - audit and remediate pre-#2550 idempotency-key squats

Status: design. Base: origin/main 5997f92c (contains #2550 as `90e5f2be`; its pre-state is `90e5f2be^`).
Gates: SECURITY-REVIEWER (INV-1, INV-3, INV-6, INV-7), REVIEWER. Source: #2550 design OQ-1
(`gh2550-client-idempotency-key-namespace.md:247-250`), SECURITY-REVIEWER finding F3.

## 0. Verified facts that shape the design

- `event_idempotency` has a unique index on `idempotency_key` and **no FK** to `events`
  (`20260816120006_create_event_idempotency.exs:42-46,66-69`). The row points at `(event_id,
  event_created_at)`; the event can be in `events` OR `events_archive`, so a row can also be
  orphaned. `events` has no unique index on the key (`:32-35`). No schema `update_changeset`
  exists, rows are never re-pointed (`event_store/idempotency_record.ex`, "No update_changeset").
- `events` is range-partitioned on `created_at`, PK `(event_id, created_at)`
  (`20260922000001_create_events_partitioned.exs:64-65`). `events_archive` has the same columns
  (`event_store/archived_event.ex:64-75`).
- **There is no immutability trigger and no hash chain on `events`.** Only `audit_entries` has
  both (`20260830020001_create_audit_entries_tenant_scoped.exs:76-105`, `Letflow.Audit`
  `chain_hash`/`prev_chain_hash`, `audit/entry.ex:34-35`). A grep of `priv/repo/migrations` for
  event triggers found none (grep, not a DB inspection). So the "append-only, hash-chained"
  premise in the task applies to the audit chain, and the immutability of `events` is by
  convention only. Design choice (D2): do not touch `events` anyway.
- **`Letflow.Release` does not exist.** `grep "Letflow.Release" lib rel config` found nothing; #2567
  (the wrapper module) is OPEN and unmerged (`gh issue view 2567`). The pattern that exists today
  is `Mix.Tasks.Letflow.BackfillScriptHmacSecrets` (`lib/mix/tasks/letflow.backfill_script_hmac_secrets.ex:53-70`):
  a public core function `backfill/1` plus a task that prints counts and halts non-zero. Tenants
  come from `TenantProvisioning.list_registrations/0` (`tenant_provisioning.ex:288-291`, each
  `Registration` has `tenant_id`, `schema_name`).
- Issue text cites `certificate.ex:128,159`; those are moduledoc lines. The real write is
  `lib/letflow/modules/exam/certificate.ex:335-342` (`actor_id: candidate_id`, `idempotency_key:
  "certificate:issue:" <> session.id`, `idempotency_match: :target`). The issue also says
  `Certificate.issue_or_fetch`; the public entry point is `issue_or_get_for_user/3` (`:267`).

## 1. Pre-#2550 entry points and what they could write

Read from `90e5f2be^` (`git show`): `routers/entities.ex:1005,1063,1151` (body key, raw);
`routers/instances.ex:470,549,638,1653-1655` (header key, raw, truncated to 255 bytes);
`engine/lua/platform.ex` `do_emit_event/3` (raw key, any `event_type`). Namespacing now lives in
`idempotency.ex:54-81,104-117`.

| Entry point | event_type written | actor |
|---|---|---|
| POST/PUT entity record | `ENTITY_RECORD_CREATED` / `ENTITY_RECORD_UPDATED` (`entities/records.ex:1194-1196`) | authenticated user |
| POST /instances | `INSTANCE_STARTED` (`engine.ex:2266`) | user |
| cancel | `INSTANCE_CANCELLED` (`engine.ex:7463`) | user |
| rebind pins | `INSTANCE_PINS_REBOUND` (`engine/pin_rebind.ex:470`) | user |
| Lua `emit_event` | any type the script names | execution actor; unreachable in production per #2550 design `:25-29` (not re-verified here) |

Define `client_types` = those five event types. A squat made through a client route has an
`event_type` in `client_types` and an `actor_id` that is an authenticated user.

## 2. Per-family squat shape and flag rule

"Could be sent bare" is true for **every** family: all five HTTP entry points accepted any string
up to 255 bytes. The question per family is whether a squat is distinguishable.

| Family (prefix) | Legitimate writer: event_type / actor | Flag rule (any true) | Status |
|---|---|---|---|
| `certificate:issue:` | `ENTITY_RECORD_CREATED`, payload `entity_type = "certificate"`, `field_values.session_id` = key suffix / actor = the session's `user_id` (`certificate.ex:326-342`; ownership via `Session.get_session_for_user/3`, `session.ex:305-312`) | R1 `event_type != ENTITY_RECORD_CREATED`; R2 payload `entity_type != "certificate"`; R3 actor != session `user_id`; R4 `field_values.session_id` != suffix | flaggable |
| `timer_fired:` | `TIMER_FIRED` / platform actor `0000...0002` (`scheduler.ex:413-416`, `engine.ex:3547-3548`, `event_store.ex:963`) | actor != platform actor, or type in `client_types` | flaggable |
| `escalation_timer_fired:` | engine path / platform actor (`engine.ex:3907-3908`) | same as above | flaggable |
| `script_run:` | `SCRIPT_RUN_RECORDED` / platform actor (`engine.ex:5112-5117`) | actor != platform actor | flaggable |
| `effect_applied:` | `effect_applied` / platform actor (`ordering/consumer.ex:154-159`) | actor != platform actor | flaggable |
| `ordering_lag_exceeded:` | `ordering_lag_threshold_exceeded` / platform actor (`ordering/metrics.ex:127-133`); key embeds a ms clock | actor != platform actor | flaggable |
| `promotion_assertion_teardown_failed:` | platform actor (`platform_events.ex` adapter) | actor != platform actor | flaggable |
| `attachment_attached:` | `ATTACHMENT_ATTACHED` / uploader (`repository/attachments.ex:366-371`) | `event_type != ATTACHMENT_ATTACHED` | flaggable (type only) |
| `attachment_removed:` | `ATTACHMENT_REMOVED` / deleter (`attachments.ex:404-409`) | `event_type != ATTACHMENT_REMOVED` | flaggable (type only) |
| `service_task_dispatch:`, `service_task:`, `script_task_dispatch:` | engine events (`engine.ex:4423,5029,5072`; `service_task.ex:602-604`) | event_type in `client_types` | flaggable only after OQ-3 |
| `definition_promoted:`, `definition_version_rolled_back:` | platform events appended by `PlatformEvents` | event_type in `client_types` | flaggable only after OQ-3 |
| `entities-record-import:` | `ENTITY_RECORD_CREATED` / importer (`routers/entities.ex:1359`, key carries a per-call import id) | none: same type and shape as a squat | report-only |
| `req345-seed-` | `ENTITY_RECORD_CREATED` / seed actor (`letflow.seed.exam_fixtures.ex:286-568`, fixed keys) | none: indistinguishable without the seed actor | report-only |
| `sys:` (reserved, `idempotency.ex:59`) | nothing writes it yet | any row whose key starts `sys:` is reported as `reserved_prefix_present`, never remediated | report-only |

Why some families are weak targets, with the reason stated per family so the PR can quote it:
`ordering_lag_exceeded:` needs the exact millisecond; `entities-record-import:` needs a UUID minted
per call and, per #2550 design D6, never returned (design claim, not re-read); `effect_applied:` and
`attachment_*:` need an unguessable record UUID. None of these is "impossible", so all are audited
rather than dismissed. Keys containing `::sub_process_` (derived keys, `sub_process.ex:266-276`)
take the base's family but legitimately write `INSTANCE_STARTED` (`sub_process.ex:647`), which would
collide with the INSTANCE_STARTED client type. They are bucketed `derived_key`, reported, never
flagged (OQ-4).

Flag-rule rule of thumb: a flag needs a **positive** mismatch with a verified legitimate writer.
Unknown or unclassifiable never becomes a flag, because remediation acts only on flags.

## 3. Modules and types (no bodies)

Three new files, split by write capability so "read-only" is structural:

- `lib/letflow/idempotency/squat_audit.ex` - `Letflow.Idempotency.SquatAudit`. Reads only.
- `lib/letflow/idempotency/squat_remediation.ex` - `Letflow.Idempotency.SquatRemediation`. The only writer.
- `lib/letflow/release/idempotency_squats.ex` - `Letflow.Release.IdempotencySquats`. Operator
  wrappers (`audit/0`, `remediate/3`) that print and set the exit status, callable with
  `bin/letflow eval` and without Mix. The name sits under `Letflow.Release.` without defining
  `Letflow.Release`, so it cannot collide with #2567's module (anti-pattern "Two branches picking the
  same module name is a real rebase-time collision class"). Thin Mix tasks `letflow.audit_idempotency_squats`
  and `letflow.remediate_idempotency_squat` delegate to it (existing task pattern above).

Types:

- `@type family :: String.t()` - one of `Letflow.Idempotency.server_prefixes/0` ++ `reserved_prefixes/0` (`idempotency.ex:63-81,59`). Rules iterate that list, so a prefix added later is audited as `report_only` until given a rule.
- `@type reason :: :wrong_event_type | :wrong_entity_type | :actor_mismatch | :target_mismatch | :actor_not_platform | :client_event_type`
- `@type finding :: %{tenant_id: Ecto.UUID.t(), schema: String.t(), key: String.t(), family: family(), target_id: String.t() | nil, stored_actor: Ecto.UUID.t() | nil, expected_actor: Ecto.UUID.t() | nil, event_type: String.t() | nil, event_created_at: DateTime.t() | nil, inserted_at: DateTime.t(), verdict: :flagged | :report_only, reason: reason() | :session_not_found | :target_not_uuid | :event_missing | :payload_unresolved | :derived_key | :reserved_prefix_present | :no_rule | nil}`
- `@spec SquatAudit.audit_tenant(schema :: String.t()) :: {:ok, [finding()]} | {:error, term()}`
- `@spec SquatAudit.audit_all() :: [{Registration.t(), {:ok, [finding()]} | {:error, term()}}]` - iterates `TenantProvisioning.list_registrations/0`; a failing tenant does not stop the others.
- `@spec SquatAudit.classify_key(repo :: module(), schema :: String.t(), key :: String.t()) :: {:ok, finding()} | {:error, :no_such_key}` - the ONE rule evaluator for a single key. `audit_tenant/1` and remediation both call it, so the audit and the refusal can never disagree.
- `@spec SquatRemediation.remediate(schema :: String.t(), key :: String.t(), operator :: String.t()) :: {:ok, %{outcome: :removed | :already_clear, key: String.t()}} | {:error, :invalid_key | :invalid_operator | :unknown_tenant | {:not_flagged, finding()} | :delete_count_mismatch | term()}`
- `@spec Letflow.Release.IdempotencySquats.audit() :: :ok` and `remediate(schema, key, operator) :: :ok` - print; `System.halt(1)` when any tenant errored or remediation errored.

## 4. Audit query, step order (read-only)

Per tenant schema (from the registration; always `prefix:`, INV-1; the schema is never read from input):

1. Open a transaction and make it read-only as its first action with `SET LOCAL transaction_read_only = on`. A bare `SET TRANSACTION READ ONLY` fails inside an already-open transaction (e.g. the test sandbox, cf. the savepoint workaround at `event_store/retention_operations.ex:111-120,445-450`); that `SET LOCAL` works there is an assumption to be proven by the write-attempt test (T6), not a verified fact.
2. Select `event_idempotency` rows (`i`) where `starts_with(i.idempotency_key, $family)`, once per family. NOT `LIKE`: `_` is a LIKE wildcard and `service_task:` contains one.
3. LEFT JOIN `events e` on `e.event_id = i.event_id AND e.created_at = i.event_created_at` (equality on the partition key keeps partition pruning possible), and LEFT JOIN `events_archive a` the same way. Take `COALESCE(e.*, a.*)` for `event_type`, `actor_id`, `payload`. Neither found gives `reason :event_missing`, report-only.
4. Order by `i.inserted_at, i.id`; fetch in keyset batches (size an implementation constant) so a large table is not loaded whole.
5. Certificate only: target = key suffix cast to uuid (fails gives `:target_not_uuid`, report-only). Expected actor = `field_values->>'user_id'` of `entity_record_latest` where `entity_type = 'session' AND record_id = target` (the table `entity_record_latest`, columns `entity_type, record_id, field_values`: `entities/record/latest.ex:27-31`; same source as `session.ex:305-308`). No row gives `:session_not_found`, report-only (a key for a session that does not exist blocks nothing).
6. Payload rules read `payload->>'entity_type'` and `payload->'field_values'->>'session_id'`. A payload that is a single-key `$ref` map (oversized, `records.ex` `resolve_original_payload`) gives `:payload_unresolved`; only R1 and R3 apply to it (they do not need the payload).
7. Apply the rule from section 2; emit a `finding`. Output prints exactly the finding columns, **never** `payload` or `field_values` (INV-4 posture); a summary line per tenant gives counts only: scanned, flagged, report_only, errored.

Structural read-only proof: (a) `SquatAudit` and its wrapper functions contain no `Repo.insert|update|delete|insert_all|update_all|delete_all`, no `Repo.query` with a non-SELECT, no `Multi`, no `Audit.` call (source-scan test, same style as the #2550 scan, `idempotency_test.exs`); (b) the `transaction_read_only` setting makes Postgres itself refuse writes (test T6 attempts an INSERT inside the same entry and expects SQLSTATE 25006).

## 5. Remediation (D1-D5)

**D1. Function and who runs it.** `SquatRemediation.remediate/3` by a **platform operator** via `bin/letflow eval` / the Mix task. No HTTP route, no tenant-admin path, because: the realistic squatters are tenant admins and process operators (`EntitiesRecordsWrite` holders, #2550 design `:57-65`); a tenant-facing route would let the party that may have planted the squat decide what is a squat and erase evidence. A route would also be a new tenant-data-path write surface needing authorization, rate limits and a permission to invent (INV-3). Operators already run backfills this way (`gh issue view 2567`). `operator` is a mandatory non-empty label (<= 100 chars, printable) recorded in the audit entry; the platform operator is not a tenant user, so `actor_id` is nil.

**D2. What is removed.** Only the `event_idempotency` row. The squatter's `events` row and `entity_record_latest` row are left. Reasons: (i) `events` has no immutability trigger (section 0) but is the evidence and history, and deleting it needs partition and `event_payload_store` handling (`event_store.ex:1727-1754` shows the archive-time dance); (ii) it is not needed to unblock the writer, since duplicate resolution goes through the sidecar only (`event_store.ex:773-790`) and nothing reads `events.idempotency_key` (grep `lib`, no match outside design docs). After the delete, the legitimate issuer's claim insert succeeds and `events` then holds two rows with the same key text, which is legal (no unique index there). No collision with the squatter's record: the certificate entity has no unique constraint on `session_id` (`certificate.ex:111-124`) and the issuer never looks up an existing certificate, it only relies on the key; it creates a new record with a new `record_id` (`records.ex` create path). The squat record stays as an orphan; its `entity_type` and `record_id` are put in the audit entry so an operator can delete it through the normal entity API (OQ-2).

**D3. Step order, inside one `Repo.transaction`** (explicit `prefix:` on every call):
1. Validate: key a binary of 1..255 bytes, valid UTF-8, no NUL, no wildcard handling at all (exact `=`); operator valid; schema in `TenantProvisioning.registered_schema/1` terms (`tenant_provisioning.ex:229`), else `:unknown_tenant`.
2. `SELECT ... FROM event_idempotency WHERE idempotency_key = $key FOR UPDATE` (Ecto `lock("FOR UPDATE")`, INV-7). No row: roll back, return `{:ok, %{outcome: :already_clear}}`, **no audit entry**.
3. `classify_key/3` on the locked row, same transaction. `verdict != :flagged`: roll back, `{:error, {:not_flagged, finding}}`. A legitimate row, a report-only row and a derived key all land here.
4. `Audit.insert_entry/3` (`audit.ex:~196-215`): `action "idempotency_squat.remediated"`, `resource_type "idempotency_key"`, `resource_id` = key, `actor_id` nil, `before_state` = `{operator, family, row_id, event_id, event_type, event_created_at, stored_actor, expected_actor, reason, squat_entity_type, squat_record_id}` (no payload values), `after_state` = `{removed: true}`. Same transaction as the change (0051 D8: audit writes are not best-effort).
5. `delete_all` where `id = row.id AND idempotency_key = key`; count must be 1 else rollback `:delete_count_mismatch`.

**D4. Idempotent.** First call: `:removed`. Second call: no row, `:already_clear`, no second audit entry. If the legitimate writer has since re-claimed the key, the row exists and is not flagged, so the answer is `{:not_flagged, ...}` and nothing is deleted (a different, safe outcome; the runbook says so). Re-running the audit never lists a removed key.

**D5. Lock order and race.** Remediation locks the `event_idempotency` row first, then (inside `Audit.insert_entry`) the tenant `audit_chain_locks` row (`audit.ex:~180-200`). The legitimate issuer's path is `instance_sequence` FOR UPDATE, then the idempotency claim insert (`event_store.ex:~700-760,812`), and never the audit chain. Order is therefore idempotency row -> audit chain in remediation; no writer was found taking audit chain before an idempotency claim, but `Audit.insert_entry` has 65 call sites that I did not trace one by one (OQ-5). Race with a simultaneous legitimate write: the issuer's `INSERT ... ON CONFLICT DO NOTHING` on `uq_event_idempotency_key` waits for the remediation transaction. If it commits the delete, the issuer inserts and succeeds; if remediation rolls back, the issuer conflicts and gets `idempotency_key_reuse` exactly as before. If the issuer won first, step 3 sees an unflagged row and refuses. Postgres's unique-index wait on an uncommitted delete is standard behaviour but was not tested here; T4 covers it.

**D6. 0051 D8 vocabulary.** D8 (`docs/migration/decisions/0051-org-scoped-role-grants-and-enforcement.md:330-350`) lists `noun.verb` names and forbids renaming existing ones (`:338-339`). I rename nothing. I add one new name, `idempotency_squat.remediated` (`noun.past_participle`, like `grant.revoked`). The chain accepts new action strings with no code change (D8's own "VERIFIED" paragraph; `audit/entry.ex:30,44-52`). D8 is an enumerated list scoped to role grants and org units, so it needs an **additive amendment** (or a ruling that platform-operator remediation audit names live outside D8), to be filed via the supervisor, not made by this PR (OQ-1).

## 6. Blast radius, SECURITY notes

- Writes: one DELETE of one `event_idempotency` row and one `audit_entries` insert per remediation. Audit: zero writes. One tenant per call.
- INV-1: the schema name comes from the registration list or `registered_schema/1`, never from a string the operator types for a tenant they could mistype into another; every query passes `prefix:`; the finding carries `schema` and the wrapper echoes it back before acting.
- INV-3: no HTTP surface; operator identity is recorded; exact-key only; refuses on any non-flag. Operators hold DB credentials already, so this adds no privilege, it adds a checked path.
- INV-6 (audit trail): the entry is in the same transaction; its `before_state` is enough to reconstruct what was removed. INV-7: `FOR UPDATE` through Ecto `lock/2`, `starts_with` bound as a parameter, no interpolated SQL.
- INV-4: output and audit contain ids, key, event type, timestamps; no `payload`, no `field_values`, no tokens. A key can contain a user-chosen string (the squatter's text), so printing must escape control characters.
- Residual: a squat that is indistinguishable from the legitimate write (report-only families, Lua) is listed but cannot be removed by this tool. A candidate forging their own certificate cannot occur while `:CANDIDATE` lacks `EntitiesRecordsWrite` (#2550 design `:249-250`); R4 still catches a same-actor wrong `session_id`.
- Anti-patterns (`docs/anti-patterns.md`): "A gate-approved design fixing a shared write function missed a sibling write path constructing the same state independently" - hence every server family is audited, not only certificate. "Claiming a function 'already carries' a value without reading its real parameter list" - hence `file:line` for every writer in section 2 and the unverified ones marked OQ. "Two branches picking the same module name" - hence `Letflow.Release.IdempotencySquats`. "A grep-shaped acceptance criterion can be tripped by the module's own moduledoc" - the read-only source scan must exclude moduledoc text or the moduledoc must not quote write function names.

## 7. Tests (ExUnit, real Postgres via `TenantFixture.provisioned_tenant!/1`, `async: false`)

Fixtures write rows directly (`Repo.insert` of `%Event{}` and `IdempotencyRecord.insert_changeset/2` with `prefix:`), as the #2550 legacy tests do, because the squat predates the namespacing and the HTTP route can no longer produce it.

| Id | AC | Test |
|---|---|---|
| T1 | A1 | Seed a real session record (`user_id = U`), run `Certificate.issue_or_get_for_user(U, sid, prefix)` (legitimate row), and a second session `sid2` with a squat: `ENTITY_RECORD_CREATED` by actor `X != U2`, key `certificate:issue:<sid2>`. `audit_tenant/1` returns exactly one finding, for `sid2`, `verdict :flagged`, `reason :actor_mismatch`, with `stored_actor X`, `expected_actor U2`, event type and timestamp populated. The legitimate one is absent from flags. |
| T2 | A1 | Certificate rules R1-R4 each: wrong event_type (`ENTITY_RECORD_UPDATED`), wrong `entity_type`, same actor but wrong `session_id` in payload. Also `:session_not_found`, `:target_not_uuid`, `:event_missing` (idempotency row with no event) are report-only. A row whose event is in `events_archive` is classified, not `:event_missing`. |
| T3 | A2 | One test per flaggable family in section 2: squat by user actor with a `client_types` event is flagged; the verified legitimate shape (platform actor, right type) is not. Report-only families (`entities-record-import:`, `req345-seed-`, `sys:`, `::sub_process_` keys) are listed with their reason and never `:flagged`. A `service_task:` key is matched by prefix (the `_` wildcard case): a row `serviceXtask:...` is not picked up. |
| T4 | A3 | Remediation of the T1 squat returns `:removed`; then `issue_or_get_for_user(U2, sid2, prefix)` returns `{:ok, view}` with `first_issuance: true`. The old squat event and record still exist. One `audit_entries` row with the exact action, key, `stored_actor`, operator, and a valid chain hash. Concurrent variant: start the issuer while a remediation transaction holds the delete uncommitted; the issuer completes after commit. |
| T5 | A3 | The legitimate T1 key: `remediate` returns `{:error, {:not_flagged, _}}`, row count unchanged, no audit row. Report-only key and a nonexistent key: same refusal / `:already_clear`. Wrong-tenant schema string: `:unknown_tenant`. Key with `%`, `_`, trailing text: no wildcard behaviour (exact match only). Invalid operator: `:invalid_operator`, nothing written. |
| T6 | A1, A3 | Idempotent: second `remediate` returns `:already_clear`, audit row count stays 1. Read-only: (a) source scan of `squat_audit.ex` finds no write calls; (b) inside the audit entry point's transaction, an INSERT raises SQLSTATE 25006; (c) row counts of `event_idempotency`, `events`, `audit_entries` identical before and after `audit_all/0`. |
| T7 | A4 | Wrapper output test: counts line per tenant, no `payload`/`field_values` text, control characters in a key are escaped; non-zero exit path when a tenant errors (inject a failing schema). Runbook exists and names both commands (file-exists assertion). |

## 8. Runbook (written by the implementer, `docs/runbooks/idempotency-key-squat-audit.md`)

Sections: purpose; prerequisites (a release with this PR, DB access); step 1 run `bin/letflow eval "Letflow.Release.IdempotencySquats.audit()"`; step 2 review each flagged row (compare `stored_actor` to `expected_actor`, check `reason`, look at the squat record named by `squat_record_id` before acting); step 3 `bin/letflow eval "Letflow.Release.IdempotencySquats.remediate(\"<schema>\", \"<exact key>\", \"<operator>\")"`; step 4 re-run the audit and ask the candidate to retry; safe to re-run; what `:not_flagged` and report-only mean. States that running on QA or production is an infra request through the normal flow, not part of this PR (issue AC4).

## 9. AC-to-design map

| Issue AC | Design element | Test |
|---|---|---|
| Read-only audit, per tenant, certificate | sections 3-4, rules R1-R4 | T1, T2, T6 |
| Other server prefixes, flagged or reasoned | section 2 table (every `server_prefixes/0` entry + `sys:`) | T3 |
| Explicit remediation, exact key, refuses unflagged, audited, idempotent | section 5 D1-D6 | T4, T5, T6 |
| Runbook | section 8 | T7 |

## 10. Open questions (for the supervisor)

- **OQ-1** 0051 D8 amendment for `idempotency_squat.remediated`, or a ruling that it needs none; also whether the name should rather live in a platform-operator vocabulary.
- **OQ-2** Should the squatter's orphan record (and, for entity type `certificate`, any public-read handle) be deleted by this tool, or left to a manual API delete? Design: left.
- **OQ-3** The legitimate event-type sets for `service_task_dispatch:`, `service_task:`, `script_task_dispatch:`, `definition_promoted:`, `definition_version_rolled_back:` were not fully enumerated here. ELIXIR-DEV must read each writer and confirm none writes a `client_types` event before enabling the flag; otherwise that family stays report-only. Also unverified: the actor on `service_task_dispatch` and `script_task_dispatch` events.
- **OQ-4** `::sub_process_` derived keys of server families are never flagged. Acceptable, or classify them by their base?
- **OQ-5** Trace the 65 `Audit.insert_entry`/`append_multi` call sites for any that take the audit chain lock before an idempotency claim (lock-order inversion with D5).
- **OQ-6** Sequencing with #2567: this PR ships `Letflow.Release.IdempotencySquats` standalone. If #2567 lands first, should the wrappers be re-homed into its module and does its app-start helper replace ours? Also how a release `eval` starts Repo is unspecified here and must follow #2567.
- **OQ-7** Should `audit()` exit non-zero when flags exist (useful in CI/infra checks) or only on errors (as designed)?
- **OQ-8** Whether a platform user could hold the id `0000...0002`; the platform-actor rules assume not (not verified).
