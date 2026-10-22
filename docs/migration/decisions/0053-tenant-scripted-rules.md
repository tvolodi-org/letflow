# 0053 -- Tenant scripted rules: the core runtime, the `script_rules` registry, and hook 1 (SERVICE_TASK `script`)

Status: Ratified 2026-10-14 by the user's advisor session (letflow-ec) under the user's delegation; recorded by the supervisor; supersessions of 0029 §1, §3 and 0039 D7 take effect now, the pack-related ones wait for Record P (D0).

Date: 2026-10-14. Drafted by `CODE-DESIGNER`. Owner: `ORCH`. Amended after REVIEWER pass 1 (F1-F15) and SECURITY-REVIEWER pass 1 (MUST 1-11). Re-reviewed 2026-10-14: SECURITY-REVIEWER pass 2 PASS_WITH_FINDINGS (no remaining MUST), REVIEWER pass 2 PASS_WITH_FINDINGS (see "Sign-off").

Depends on / related: 0014 (Lua = `tv-labs/lua`, WASM behind a process boundary; runtime choice unchanged, host-API contract amended, see "Consistency"), 0029 (superseded in part, D0), 0030 Finding 1, 0039 D7 (superseded in part, D0), 0046, 0050, 0051, 0052 (amended on Record P ratification, D0), planned REQ-484.

## Scope: what is decided and what is direction

BINDING in this record: the core runtime (sandbox, limits, value-returning executor, principal and data rules, failure codes), the `script_rules` registry with permissions, separation of duties, test cases and dry-run, audit, concurrency (D0-D11), and hook 1 only: the SERVICE_TASK `script` route (D2, D3 pin part).

DIRECTION, non-binding until its own decision record is ratified (working names, numbers assigned when drafted):

- **Record P, "scripts in solution packs and promotion"**: the pack `scripts` section, install policy, the promotion `:script` kind (old D3 pack part, D11). Follow-up note (F14), parser rule: scripts are strings plus a JSON manifest; sha256 is recomputed at parse; a mismatch rejects the whole pack.
- **Record E, "entity pre-write script hook and derived fields"** (hook 2; needs REQ-484 and a dynamic data API). Follow-up note (F13): derived fields computed from reads are not atomic with the write; Record E must address this.
- **Record F, "form-validation script hook"** (hook 3; runs in the locked `complete_task` transaction).
- **Record T, "after-commit entity-event triggers and the outbox"** (hook 4, old D6).
- A separate record or requirement for schema-validating the output of ALL service tasks (F9).

Build order (direction beyond step 3): (1) executor returns values, mandatory limits, sandbox allow-list; (2) `script_rules`, permissions, SoD, test cases, dry-run; (3) hook 1; then P, E, F, T by their own records.

## Context

Relayed architect design (supervisor, 2026-10-14), abridged: tenant-scoped `script_rules` (key, immutable published version, source, manifest, hook kind, status draft/published/retired, author, publisher, sha256); definitions reference key+version pinned like instance pinning; pure-function model (inputs in, outputs out, the engine applies them); `ScriptsWrite` (PROCESS_DESIGNER, TENANT_ADMIN) and `ScriptsPublish` (TENANT_ADMIN) as additive core permissions; SoD publisher != author; publish blocked unless stored test cases pass; hash-chain audit on publish/retire and a per-run record; instruction budget, wall clock, heap, output cap, per-tenant concurrency via Admission; dry-run endpoint; fail closed; WASM only for platform-reviewed plugins; forbidden list (network, fs, os, io, debug, load, require, string.dump, secrets, email/HTTP, other tenants, role/grant/audit changes, restriction bypass, unbounded queries, tenant WASM, Lua in gateways). Gateway conditions stay `Letflow.Engine.Expr`.

Current state, verified on this branch (file:line):

- The runtime exists but nothing calls it. `Lua.Executor` has no caller outside `lib/letflow/engine/lua/` (only moduledoc prose, `lib/letflow/modules/exam/scoring.ex:23`, `lib/letflow/supervisor/infrastructure.ex:289`); `LuaScriptAudit.execute_script_for_audit/6` (`lua_script_audit.ex:135`) has zero callers (`:39-41`). No `.lua` source exists in the repo.
- Sandbox: `Sandbox.new/1` (`lua/sandbox.ex`) is a DENY set of 33 entries (`:133-234`, applied `:264-275`); it passes only `sandboxed:` and `max_instructions:` to `Lua.new`, not `max_string_bytes` (which `Lua.new` accepts, `deps/lua/lib/lua.ex:105`, default 256 MiB). The deny set does NOT cover `os.time_ms`/`os.time_us` (installed, `deps/lua/lib/lua/vm/stdlib/os.ex:44-53`; `sandbox.ex:157,210` list them as installed), `print` (`IO.puts` to node stdout, `stdlib.ex:55,169-177`), `collectgarbage`, `rawset/rawget`, `setmetatable/getmetatable`, `utf8` (SECURITY-REVIEWER; source reading, NOT VERIFIED by running a VM). `string.dump` and `coroutine` are absent.
- Limits: instruction budget 100_000 (`config/config.exs:22`), wall clock 5_000 ms (`:31`), `lua_max_heap_words: nil` = no heap cap (`:40`); the `nil` clause runs under `Task.Supervisor.async_nolink` (`executor.ex:362-373`); the capped path bypasses the Task.Supervisor with a bare `:erlang.spawn_opt` (`executor.ex:541-550`, moduledoc `:131-144`), unlinked and only monitored. Timeout `Task.shutdown(task, :brutal_kill)` (`executor.ex:705-707`); a script can `pcall` its own budget error so wall clock is the real stop (`:70-80`).
- Error text: crash outcomes are built as `"... task crashed: " <> format_exit_reason(reason)` (`executor.ex:566,662,702`) with `Exception.format` + stack trace or `inspect` (`:710-716`).
- Host API: closed 8-row matrix (`platform.ex:346-352`), empty grant set in production (`:391-393`); `executor.ex:405-414` returns only `%{manifest_hash: hash}`: no output channel. `write_variable` stages in the process dictionary (`platform.ex:753-756`). `platform.now()` reads a configurable `SystemClock` (`:364-370`). The one data precedent, `fetch_instance_state`, does `Repo.get` from the sandbox task process (`platform.ex:632-651`, `:650` per REVIEWER). No uuid function.
- `Manifest` is `%{script_id, capabilities}` only (`lua/manifest.ex:102,142-156`). Per-run audit table has 3 value columns (`lua_script_audit.ex:56-72`) and its moduledoc says the general integration supersedes it (`:9-13`). Tenant audit: `Audit.append_multi/4` (`audit.ex:189`).
- SERVICE_TASK: `route_kind :inline_url | :catalog_service` only (`service_task.ex:81,197-233`), retry classes timeout/network/429 (`:436-442`), default timeout 30_000 (`:76`).
- Pins: kinds `:catalog_entry | :variable_schema | :module` (`pin_resolver.ex:190`, string forms `:612-614`), frozen in `INSTANCE_STARTED`; `PinRebind` the only later writer (`pin_rebind.ex:140-150`).
- Permissions are a closed atom list (`lib/letflow/api/authorization.ex:385-447`); `ScriptsWrite`/`ScriptsPublish`: NOT FOUND.
- Field restrictions are per user id (`entities/query/field_grants.ex:84`); a service task has no user, the dispatcher uses `EventStore.platform_actor_id()` (`service_task_dispatcher.ex:675,702`).
- Admission: global + fair-share per-tenant (`admission.ex:408`), used only by the HTTP plug (`plugs/admission.ex:169`); it does NOT monitor callers, a crashed holder leaks its ref until restart (`admission.ex:100-108`).
- Gateways use `Letflow.Engine.Expr`, a CEL-subset (`engine/expr.ex:24-33,37-45`).
- Dry-run endpoint, stored test cases, output size cap, `host_unavailable` failure class: NOT FOUND.
- Layering: `lib/letflow/engine.ex` and `lib/letflow/engine/*.ex` (non-recursive) contain no `Letflow.Entities` reference today. The draft's earlier citation "0022 rule 2" was NOT FOUND (0022 is the BilimBaga record); the layering rule text itself is NOT VERIFIED here.

### Row-lock answer (the architect's OPEN question)

NO. A SERVICE_TASK does not run inside the instance row-lock transaction.

- The engine only INSERTs a `service_task_dispatches` row inside its Multis (`engine.ex:1322-1336`); no handler is invoked there.
- Execution is by the Poller (`service_task_dispatcher/poller.ex:67`) -> `attempt_dispatch/2`, one transaction that `FOR UPDATE`-locks the DISPATCH row only (`service_task_dispatcher.ex:749,784-786`). The HTTP call runs inside that transaction (`:795`), holding a pooled connection and the dispatch-row lock for up to `timeout_ms`, but no instance lock. HTTP dispatch is deliberately at-most-once (`:634`).
- The result is applied in a SEPARATE transaction that locks the dispatch row and the instance projection (`engine.ex:3403-3418,3428-3432`); two commits, a documented gap (`:3380-3390`).
- Instance locks are taken by `complete_task` via `fetch_and_lock_task/3` and `fetch_and_lock_instance_projection/3` (`engine.ex:291-297`; `completion_guards` run inside that Multi, `:2315-2337`). Entity writes open their own transaction at `records.ex:265`; code before `run_command` (`records.ex:176,211`) runs outside any lock.

Consequence: the 50 ms rule does not constrain hook 1; it binds hooks 3 (and 2 after REQ-484), which are direction here.

### Deviations from the relayed wording (for the architect)

1. "Gateway conditions stay CEL": read as `Letflow.Engine.Expr` (CEL-subset, closed grammar).
2. "Outputs through the variable schema": today the service-task advance path passes `nil` validations (`engine.ex:3441`; `variable_merge.ex:209`, the `|| %{}` at `:217`), so service-task output is NOT schema-checked. Applying validations to ALL service tasks is a behavioural change to HTTP tasks with regression risk (F9); this record applies output validation to `route_kind :script` ONLY, and leaves the all-service-task change to its own record.
3. "Wire up LuaScriptAudit": it cannot carry the per-run record; D9 adds a new one; `LuaScriptAudit` is retired once the hook-1 per-run record lands; its table stays read-only as history (ruled by the advisor, Q11).
4. "now()/uuid host-derived": `now` today is wall clock; uuid does not exist. The existing `now` and `os.time*` leave the script surface; `ctx.now` and `ctx.uuid` are new, host-derived inputs.
5. "Pure-function": `emit_event`, `call_service`, staged `write_variable` (`platform.ex:350,753,790-830`) are dropped from the script API.
6. "Honouring field restrictions": restrictions are per user id; D5 defines a script principal.
7. "Per-tenant concurrency via Admission": no per-tenant budget setting exists; D8 uses a separate Admission instance, with caller monitoring added.
8. "Pinned at activation": pin kinds are a closed set; hook 1 adds a `:script` pin kind (D3). Entity-type pinning belongs to Record E.
9. "Retries only for idempotent hooks": script failure classes are new (D7); `host_unavailable` appeared in an earlier draft and is DROPPED: it is not defined anywhere and a pure, pre-fetched script has no host to be unavailable.
10. "max_heap_size": default is OFF; D7 makes it mandatory and removes the `nil` clause for tenant scripts.
11. Hook 4 "via an outbox": no outbox exists; direction only (Record T).

## Decisions

### D0. What this record supersedes and amends (exact sentences)

Effective now (ratified 2026-10-14): 0029 §1, 0029 §3, 0039 D7 and the 0014 point 4 amendment. Effective with Record P: the 0029 §4 lines, the 0052 D1 amendment and the 0050 staleness.

* 0029 §1 (heading and body, `0029...md:276-281`): "Scripted rules: NO. A pack does not carry scripted rules today." and "A solution-pack document does not, and today cannot, carry a scripted rule." are superseded now (tenant scripts exist as core). Packs carry scripts only when Record P is ratified; until then packs carry none and 0052 D1 stands. §1's commitment to an out-of-band "alternative provisioning path ... built by a later bucket-B requirement" is REPLACED by `script_rules` (D1) plus Record P; it is not built separately.
* 0029 §3 ("the audit question does not arise ... both answers NO"): superseded now, its premise (no pack-supplied script content) no longer holds once §1 is reversed; D9 and Record P answer the audit question.
* 0029 §4 (`:421-427`): the rule that `pack_document` stays a closed, exhaustively enumerated struct stays; Record P reopens the set once by adding `scripts` and names its install policy. The §4 bullet "Scripted rules ... WANTED, not added ... this record declines" (`:459-465`) and phase-table line "Scripted rules -> REMOVED from the pack phase's own deliverable list" (`:506-512`) are superseded, effective with Record P.
* 0029 §2 (role seeding) stands; `required_roles` stays advisory.
* 0039 D7, paragraph "Client scripts are not in scope ... This record does not change that. Extension points are a later decision once that registry exists." (`0039...md:190-194`) is superseded for client scripts, effective now: the registry is `script_rules` (D1). The rest of D7 stands; 0039's REVIEWER line "scripts stay out (D7)" (`:271`) is historical.
* 0052 D1 ("The pack gains no section and no 'activate' flag", 0052 line 31) and its Consistency bullet ("section-closed", 0052 line 102) are AMENDED ONLY WHEN Record P is ratified; until then true as written. 0052's install/activate step does not cover scripts: scripts are never activated by a pack, only published by a person (D7).
* 0050 lines 136 and 297 ("consistent with 0029 (scripts and rules stay out of packs)"; table row "0029 unaffected: ... not pack scripts") are STALE once Record P is ratified; the module-code rules they describe (lookup/active, retire/rename/snapshot) stay reviewed code, not scripts.
* 0014 (e) ("neither runtime is given database access at all. Host functions receive already-resolved values") is NOT amended by hook 1: hook 1 reads are pre-fetched by the host (D5). A dynamic data API would amend it and belongs to Records E/F. 0014 point 4 (WASM-12: "the Lua host API is the definition WASM conforms to") is AMENDED: D4 removes `emit_event`, `call_service`, `write_variable`, `log`, `get_instance_state` and `now` from the tenant-script surface; WASM is platform-only (D11), so WASM-12 parity must be re-derived for the platform host API or explicitly waived for tenant scripts. The waiver for tenant scripts is CONFIRMED, ruled by the advisor (Q11); the platform host API keeps its own contract.
* 0051 T14 (0051:490-496: "the script principal is tenant-wide only and never inherits the invoker's scope (D1), and any future host function that reads records must apply that rule and the instance scope") is NOT amended: this record is CONSISTENT with it, and D5 makes it concrete for hook 1 (own-instance data plus tenant-wide masters; outputs take the instance scope).
* 0030 Finding 1 is not superseded; it is the state this record builds from.

### D1. `script_rules`

Tenant-schema table (no `tenant_id`, 0006 D2): `key`, `version` (integer per key), `source`, `manifest` (capabilities, limits, input schema, output schema, declared reads, declared `fail` codes), `hook_kind` (`service_task` now; `entity_write | form_validation | entity_event` reserved for Records E/F/T), `status` (`draft | published | retired | revoked`), `author` set, `publisher`, `sha256`. A published version is immutable (no update path; DB trigger or absent UPDATE grant, designer's choice). The hash extends `Manifest.compute_hash/2` framing (`manifest.ex:142-156`) to cover version, hook kind, limits, schemas, and stored test cases. Drafts are never executable except by dry-run (D10). Scripts are tenant-wide: a version has no org scope (0051 resource scope `:tenant` for all management routes). `revoked` (a vulnerable version) fails hook runs closed; `retired` means no new pins, pinned instances keep running (T13).

### D2. Hook 1: SERVICE_TASK `script`

New `route_kind :script` (extends `service_task.ex:81`), config `script_key`, `script_version`. Output is validated against the manifest output schema AND, on this route only, through `VariableMerge.merge` with real validations (Deviation 2). Gateways, guards and edge conditions stay `Expr`; no Lua there. A script published for one `hook_kind` cannot bind to another. Activation of a definition referencing `(key, version)` is REFUSED unless that version is `published` in the tenant (draft, absent, retired-for-new-pins or revoked all refuse); this also guards pack-installed definitions (F8).

Runtime shape (F3, advisor-confirmed): the engine marks the task running and COMMITS; the script runs under the Lua `Task.Supervisor` with NO DB access and no pooled connection; a NEW transaction applies the result idempotently, keyed by `(instance, node, attempt)` (the existing second transaction, `engine.ex:3403-3432`, locks the dispatch row). A crash or timeout of the script task is an incident (DLQ), not a silent retry. This does not extend the connection-holding pattern of the HTTP route (`service_task_dispatcher.ex:795`). How the running state is represented is for the designer (NOT VERIFIED against the dispatcher's status columns), but the row MUST hold a lease (`claimed_at` plus a lease duration of at least the maximum wall clock plus a margin). A `running` row whose lease expired (the dispatcher or node died between the commit and the apply) is turned into an incident in the DLQ by the poller and is NEVER re-run automatically: this adds no retry semantics. The apply transaction is a compare-and-set on the dispatch row (status `running` AND same attempt), so a late or duplicate apply cannot double-apply. The HTTP route stays at-most-once (`:634`); the script route may be attempted again only on `script_busy`, and the `(instance, node, attempt)` key guarantees at most one applied result. Acceptable because a hook 1 script is a pure function of its pre-fetched input with no side effect.

### D3. Pinning (hook 1)

A `:script` pin kind (extends `pin_resolver.ex:190`, `pin_rebind.ex` normalisation) freezes `(key, version, sha256)` in `INSTANCE_STARTED`, so an in-flight instance never picks up a newer version. Wording corrected (F12): the engine is event-sourced and applies RECORDED results, so the pin protects in-flight instances and reproducibility/audit; it is not what makes replay work (see D5). Retiring a script referenced by an active definition is blocked. Entity-type references and pack handling: Records E and P.

### D4. Pure-function model

A script is `function(input) -> output`. Input is schema-validated JSON built by the host. Output is a value validated against the manifest output schema and the target schema. Script API: `ctx.now`, `ctx.uuid` (D5), `print` (capped host log line, D11), `fail(code, details)` (D5-bounded), and the allow-listed pure library (D11). `emit_event`, `call_service`, `write_variable`, `log`, `get_instance_state` and the existing `now` are NOT script-visible; `print` is a capped host log line, not a value channel (D11) (Deviation 5). Prerequisite: an executor that returns the script value (`executor.ex:413` returns a hash only) and decodes it with string keys only, validated against the schema with known keys BEFORE any conversion; decoding creates no atoms.

### D5. Data, principal, time, uuid

* **Hook 1 reads are PRE-FETCHED (F1 default).** The manifest declares reads (`name`, `entity_type`, id or declared filter, row limit); the host (the dispatcher process, outside the sandbox) resolves them before the run and passes them in `input`. There is no `data.get`/`data.query` host function in hook 1, and no `Repo` call from the sandbox task. Justification: a Lua host function runs inside the sandbox task process (`Lua.eval!` at `executor.ex:408`); the precedent `fetch_instance_state` opens its own connection from there (`platform.ex:650`), which is the pool-exhaustion/deadlock shape T10 forbids; pre-fetch needs no message loop, makes the input hashable and replay-recordable, and keeps 0014 (e) true. A dynamic API (task sends `{ref, request}` to a caller parked in a receive loop that answers on its own connection, with call and row caps) is reserved for Records E/F, which must also specify which transaction hook 3 reads in.
* **Read contract (SECURITY MUST 4), normative.** `entity_type` is validated against the tenant's `entity_definitions` (never a table or schema name, never a core table); filter fields are validated against the definition; the filter is compiled by the existing query compiler with bound parameters; the tenant prefix comes from the run context only. Unknown type, unknown id, redacted and out-of-scope all yield the same value, the same budget cost and the same number of round trips as a plain miss (INV-5).
* **Principal (advisor-confirmed).** The script principal is TENANT-WIDE ONLY and has no user grants. It NEVER inherits the invoking user's org scope or grants (SECURITY MUST 10): that would let a published script act with the invoker's rights and let the invoker's rights vary the output. Host pre-fetch is limited to (a) the instance's own data and (b) declared tenant-wide master lookups; any other org-scoped record is denied, indistinguishable from not found. Script OUTPUTS take the instance's scope (the result is applied as instance data under 0051). This is CONSISTENT with 0051 T14 (D0; D5 makes it concrete): the instance scope applies to where outputs land, not to what the script may read. The triggering user id is recorded for attribution (D9), not used for access.
* **Input redaction (INV-2, MUST 3).** The host builds `input` (instance variables, declared reads) through the same field-restriction filter as a read for the script principal: every field with an `entity_field_restrictions` row is redacted. A restricted field enters only if it is named in the manifest input schema AND the publisher held `EntitiesRestrictionsManage` at publish; it is re-checked at run time, so a restriction added after publish re-redacts. A script output field derived from a restricted input must be declared in the manifest, and the host refuses activation/publish if it maps to a target field with fewer restrictions. `fail` codes must come from the manifest-declared enumeration; `details` is limited in size and to scalar types and never interpolates input values.
  * *Amended by 0062 (GH #2616, proposed).* The "fewer restrictions" refusal binds ENTITY-FIELD targets (step entity writes and handler writes, 0054), with the predicate and the activation and run-time checks of 0062 R5. A process-variable target is not a field: it carries the input's restriction labels as provenance and inherits the taint (0062 R2, R4, R7); reads redact it for the caller (0062 R8, R8h).
* **Time and uuid.** `ctx.now` = the triggering event time, passed in as input data. `ctx.uuid()` = UUIDv5 over `(instance_id, node_id, token_id, counter)` under a fixed namespace constant defined in the implementing requirement (F12).
* **Determinism, corrected (MUST 11).** A hook 1 script is a deterministic function of its `input` (all reads are inside it). Replay and recovery consume the RECORDED result events and never re-execute a script; a test proves no code path re-runs a script during replay. Retry of a non-idempotent hook is forbidden. If a later hook uses a dynamic data API, the run record carries read-result hashes and "same inputs, same outputs" is not claimed.

### D6. Permissions and separation of duties

`ScriptsWrite` (PROCESS_DESIGNER, TENANT_ADMIN) and `ScriptsPublish` (TENANT_ADMIN) are core permissions in `authorization.ex:385-447` and `role_allows?`; the role set stays closed (0046). Both are classified `tenant` (INV-10); management and dry-run routes derive the tenant from the auth context only; a foreign tenant's key returns exactly the response of a missing key; the requirement must name cross-tenant negative tests. SoD (MUST 6): the version records the FULL contributor set (every user who saved any revision of source, manifest or test cases); publish is rejected if the publisher is in it (replaces "editing makes you author"); the publish call carries the sha256 of the content the publisher reviewed and is rejected if the content changed; the publisher must not have contributed to ANY revision since the last published version of that key (compared by user id, not role or group; same shape as `promotion_review_store.ex:526-529`), bound to the sha256. A deleted or token principal among the contributors does not shrink the set. Two accounts of one person cannot be solved technically; recording the IdP subject (when available) stays a SHOULD (ruled by the advisor, Q11). Promotion/pack contributor binding (installer or promoter becomes a contributor, source contributor set carried as metadata, bound to sha256) is a requirement on Record P and is binding there.

**Solo publisher: `scripts.sod` (ruled by the advisor, Q11; accepted with amendments, formerly Open point 9).** Tenant policy `scripts.sod` = `strict` (default) | `solo_audited`. Solo mode matters only when the author IS the single tenant-wide admin; under `strict`, a script authored by a designer can be published by that admin. Switching to `solo_audited` is refused when the tenant has >= 2 tenant-wide TENANT_ADMIN users, needs a mandatory reason, is audited, and is a tenant-wide-admin action (0051 D11). The platform operator can forbid `solo_audited` per tenant through platform configuration; the default is 'forbidden' for enterprise tenants. There is NO platform-operator co-sign: reviewing a script reads tenant content, forbidden to PLATFORM_ADMIN by 0046 D4 (break-glass deferred, 0046 D9); a strict one-user tenant adds a second user. Every self-published version carries a visible `self_published` flag and an audit event. The flag travels with the version through promotion and pack install; a strict target refuses it unless a target-side tenant-wide admin who is not a contributor confirms, bound to the sha256. [SUPERSEDED by the D6 amendment (2026-10-14) below: a binding that creates the second admin no longer switches the policy; auto-strict is evaluated at decision time.] When a second tenant-wide TENANT_ADMIN appears, the binding switches the policy to strict in the same transaction (audited), and every still-running `self_published` version enters a visible 'pending review' list (not disabled; cleared by a non-contributor admin's confirmation bound to the sha256; no automatic deadline).

**D6 amendment, 2026-10-14 (ruled by the supervisor/advisor from letflow-4's 7b design; supersedes the sentence above that "a binding that creates the second admin switches the policy").**

* **Auto-strict is evaluated AT DECISION TIME**, inside the publish transaction, not when an admin is added. The count is the number of DISTINCT, ACTIVE, owning users who hold TENANT_ADMIN through the TA-bound group or through an active, unexpired TENANT_ADMIN token. Deactivated users and 0051-scoped TENANT_ADMIN holders are excluded; a user with several tokens counts once. The counting helper is specified by GH #2547 (TENANT_ADMIN grant-path audit and admin count). A count of 2 or more refuses a solo publish and flips the stored policy to `strict` in the same transaction (audited).
* **The effective `scripts.sod` is COMPUTED**, never read from the stored value, which is only the declared choice. Publish, promotion and the pending-review list all use the computed value.
* **The pending-review list is DERIVED at read time**: `self_published` AND not confirmed AND current admin count >= 2. There are no identity hooks (nothing fires when an admin is added).
* **Concurrency:** the publish transaction, and every admin-adding path, take a tenant-level advisory lock; the alternative is a SERIALIZABLE publish. If neither is implemented, the residual window (a solo publish racing the grant of a second admin) must be stated in the implementing requirement. The safety property is unchanged: a version is never published by a contributor, and a self-published version is visible and reviewable once a second admin exists.

**7b rulings (same date and source).**

* EVERY script-registry write (create, save, discard, publish, retire, revoke) requires an OIDC credential. An API-token caller gets 403 `api_token_not_allowed`. Reads and dry-run stay allowed. Reason: `POST /identity/tokens` takes `user_id` and roles from the body and `api_tokens` records no issuer (GH #2552), so a minted token could launder authorship. Stated residual: OIDC client-credentials logins are not interactive; SoD still holds because it is keyed by user id.
* Drafts are never hard-deleted: DELETE discards, version numbers are never reused, and the contributors of discarded drafts still count for SoD.
* Source read by `AuditRead` holders (D9) is tracked as GH #2548.

**7c rulings (2026-10-15, ruled by the supervisor/advisor from letflow-4's 7c design).**

* **C10 interim limit (amends the D5 "Input redaction" bullet until lifted).** A script that opts into RESTRICTED entity fields is refused at activation, because process variables carry no field restrictions. Restricted fields that are not opted in are omitted from the delivered row. The limit lifts when variables can carry restrictions. 0062 (GH #2616) defines restriction-carrying variables; C10 is lifted by 0062 at the merge of its implementing requirement's part 3, not before, and until then the refusal and its tests stay.
* **7c ships as two PRs under GH #2534.**
  * **7c-1:** the dispatcher, CAS, pin, run record, kill switch, output and write checks, events and replay, `LuaScriptAudit` retirement, the example, and the backfill re-run test. A script that declares reads is refused at activation until 7c-2.
  * **7c-2:** the read port, run-time `check_reads`, redaction and N1. 7c-2 closes #2534.

### D7. Limits and failure (hook 1 binding)

Per run, from the manifest, clamped by platform maxima (figures stay targets, ruled by the advisor, Q11: the implementing requirement measures `Sandbox.new` plus spawn cost and sets defaults, and must not exceed the D7 maxima without a new ruling; F11): instruction budget; wall clock, default 1_000 ms, maximum 5_000 ms (pure computation needs no more; this deliberately does not raise the held-connection budget of F3); heap `max_heap_size` mandatory, never nil; `max_string_bytes` passed to `Lua.new` at default 1 MiB (platform max set by the requirement; the library default is 256 MiB); output byte cap default 64 KiB; row and call caps for reads. `max_heap_size` by default does not count off-heap refc binaries; the task sets `include_shared_binaries => true` in the flag map when the OTP supports it. Checked: `.tool-versions` pins erlang 29.0.5 (CI reads it, `ci.yml:68-69`), and `erlang:process_flag(max_heap_size, #{..., include_shared_binaries => true})` was ACCEPTED by the local OTP 29 (no `badarg`). That it actually bounds a refc-binary-heavy script was NOT run: NOT VERIFIED, acceptance test required. Whatever the flag does, the HOST enforces `max_string_bytes` and the output cap anyway (MUST 2). A test: a doubling `string.rep` loop is rejected far below host memory.

> Addendum (GH #2867, does not change the D7 figures above): `platform.emit_event` also caps its JSON-encoded payload at 65_536 bytes (64 KiB), key `config :letflow, :lua_emit_event_max_payload_bytes`; over the cap it returns `payload_too_large` before any transaction opens.

Executor (F2, MUST 2): ALL tenant scripts run under `Letflow.Engine.Lua.TaskSupervisor`; the heap flag is set from inside the task (`Process.flag(:max_heap_size, ...)`), so the bare `spawn_opt` path (`executor.ex:541-550`) and the `nil` heap clause (`:362-373`) are removed for tenant scripts. A per-run watchdog that monitors the caller (the dispatcher) and carries the deadline is itself a supervised process (the `Task.Supervisor` child, via `async_nolink`, or a child of a dedicated supervisor), starts the script worker LINKED to itself (watchdog death kills the worker; supervisor shutdown kills both), is itself monitored by the dispatcher, and kills the worker on caller death or timeout, so a dead caller cannot leave a script running (deadline enforcement no longer lives only in the caller). `brutal_kill` stays (the task holds no resource). That Flag-in-task behaves as the `spawn_opt` option is OTP behaviour, not run here: NOT VERIFIED; an acceptance test is required.

**Kill switch (ruled by the advisor, Q11; MUST in the implementing requirement).** A per-tenant script kill switch, settable by a tenant-wide TENANT_ADMIN or the platform operator. While it is on, runs fail closed as `script_rejected` incidents. Every flip is audited. `revoked` stays revoked (no expiry).

Failure (MUST 8): fail closed. Tenant-visible responses, instance history and logs carry only stable codes: `script_error`, `budget_exceeded`, `memory_limit_exceeded`, `output_invalid`, `timeout`, `script_failed`, `script_rejected`, `script_busy`; never `inspect` or `Exception.format` output (the current strings at `executor.ex:566,662,702,710-716` must not reach a tenant). Hook 1 give-up marks the instance ERROR and enqueues the DLQ incident (`execution_error.ex:254`). Only `script_busy` is retriable; the rest are not. Any future hook that runs in or beside a transaction must convert every executor outcome (including exit and crash) to a typed `{:error, code}` without raising.

### D8. Concurrency

A second `Letflow.Admission` server (`ScriptAdmission`, own `:name`, distinct child id) supervised beside the Lua `Task.Supervisor` (`infrastructure.ex:289`), sized below the Repo pool. Because `Admission` does not monitor callers (`admission.ex:100-108`) and `after` does not run on a kill, this record requires `Admission` to gain opt-in caller monitoring that releases the slot on `:DOWN` (the watchdog of D7 is the slot holder: it acquires the slot, `Admission` monitors that acquiring pid explicitly, and the slot is released when the watchdog exits, which happens when the dispatcher goes down); releasing in `after` alone is NOT acceptable. `{:error, :capacity}` maps to `script_busy`. Does not share the HTTP budget.

### D9. Audit

Publish and retire/revoke append a hash-chain entry via `Audit.append_multi/4` (`audit.ex:189`) in the SAME Multi as the status change, carrying key, version, sha256, contributor set, publisher and the test-case hash. Draft create/edit/delete and dry-run (key, version, outcome) are also audited. Each run appends a per-run record on the instance stream (hook 1 always has an instance): key, version, sha256, HMAC-SHA256 of the canonical input keyed with a per-tenant secret referenced by name (INV-4; an unkeyed hash is brute-forceable for low-entropy inputs). The secret is created at tenant provisioning or by migration, NEVER lazily during a run (same class as REQ-448 OQ-9; ruled by the advisor, Q11), outcome class, duration, instructions, heap words, script principal plus triggering user id. NO output and no value is stored; logs carry no values. New instance event types need registration in the event type registry (`entities/event_types.ex`); whether it accepts them unchanged is for the designer to verify. Source is shown only to `ScriptsWrite`/`ScriptsPublish`/`AuditRead` holders and never in list endpoints.

### D10. Test cases and dry-run

Stored test cases (input, expected output or expected `fail` code) are part of the version and of `sha256`. Publish runs them in the same sandbox with the same limits, under a non-production principal and with no reads except fixtures; any failure blocks publish. Dry-run endpoint (`POST .../script-rules/:key/dry-run`, `ScriptsWrite`) runs a draft or version on caller-supplied input; it writes no entity and no instance event, and returns outcome, duration, instructions, heap. Raw Lua error text is returned ONLY to the author in dry-run; everywhere else only the stable codes of D7.

### D11. Sandbox: WASM and the forbidden set

WASM stays only for platform-reviewed plugins registered by configuration (`infrastructure.ex:286`), never tenant-supplied (a `wasmex` NIF fault can take down the node, 0014 "accepted residual risk"). Test: no tenant route can register a WASM plugin.

The script global environment is an explicit ALLOW-LIST built from scratch, not a deny list (MUST 1). `_G` of a script VM equals exactly (advisor-confirmed): `string` (no `dump`), `table`, `math`, `pairs`, `ipairs`, `next`, `select`, `type`, `tostring`, `tonumber`, `pcall`, `error`, `assert`, `setmetatable`, `getmetatable`, `rawget`, `rawset`, `rawequal`, `rawlen`, `unpack`, plus the host-provided `ctx`, `fail` and `print`. Replaced by host versions: `math.random` is host-seeded (seed derived from the same inputs as `ctx.uuid`, so deterministic); `os.time*` is gone, time is `ctx.now`; `print` is a capped host log line (size and count caps, no value interpolation into node stdout, MUST 1 log hygiene). DENIED: all of `os` (including `os.time_ms`, `os.time_us`), `io`, `debug`, `load`, `loadstring`, `loadfile`, `dofile`, `require`, `package`, `collectgarbage`, `coroutine`, `string.dump`; `utf8` is absent (not on the confirmed list). `coroutine` is denied (ruled by the advisor, Q11). Because `pcall` is allowed, the wall clock (watchdog) is the real stop, not the instruction budget (`executor.ex:70-80`). Library members are fixed by the implementing requirement and compared by an EQUALITY test (not subset) on every `Sandbox.new` option set and every bump of the `lua` dependency (now 1.0.2). Forbidden capabilities: network, fs, secrets, email/HTTP (connector tasks only), other tenants, role/grant/audit changes, restriction bypass, unbounded queries, tenant WASM, Lua in gateways.

## Consequences

- Core adds: `script_rules`, `script_run_records` (or instance-stream events), two permissions, `route_kind :script`, a `:script` pin kind, a second Admission server with caller monitoring, a value-returning executor, an allow-listed sandbox.
- Removes from the script surface: `emit_event`, `call_service`, `write_variable`, `log`, `get_instance_state`, `now`, `os.*` (`print` is kept only as a capped host log line, D11).
- Output validation applies to the script route only (Deviation 2); the all-service-task gap stays open until its own record.
- Hooks 2-4, the pack section and promotion are NOT decided here.

## Threat cases for SECURITY-REVIEWER (what the binding text answers)

T1 sandbox escape: D11 allow-list and equality test. T2 resource exhaustion: D7 (heap, string, output caps, no `nil` heap, atoms never created by decode). T3 cross-tenant/INV-5: D5 read contract and D6 management routes. T4 restriction bypass: D5 input redaction and declared outputs. T5 side channels: D9 keyed hash, no output. T6 poisoned test cases: D10 plus SoD bound to reviewed sha256 (D6). T7 publisher == author: D6 contributor set. T8 determinism: D3/D5 corrected. T9 pack as attack path: Record P, with MUST 9 binding there (installing a `(key, version)` with a different sha256 is REJECTED; a changed script is a new version installed as `draft`; install never alters or retires a published version). T10 connection/lock: D5 pre-fetch, D2 outside transactions. T11 admission starvation: D8. T12 error leakage: D7 stable codes, D5 `fail` bounds. T13 retire races: D1 `revoked`/`retired`.

## Consistency with existing decision records

- 0014: runtime choice (Lua = `tv-labs/lua`, WASM behind a process boundary) unchanged; host-API contract AMENDED (point 4, WASM-12 parity; D0).
- 0029, 0039 D7, 0052 D1, 0050 (two sentences), 0051 T14 (consistent, not amended): superseded or amended as listed in D0.
- 0030 Finding 1: consistent. 0046: role set closed, permissions additive.
- Layering (F10): the earlier statement "this record does not add an engine -> entities dependency" was wrong. Hook 1's pre-fetched reads make the engine (dispatcher) request entity reads. The dependency is introduced through a behaviour DEFINED in the engine (reads port) and IMPLEMENTED in `Letflow.Entities`, injected by configuration, so the engine names no `Letflow.Entities` module. This still adds a dependency edge and needs REVIEWER sign-off in the implementing requirement. Records E/F add the opposite edge (entities calling the executor) and must treat it the same way.
- INV-1, INV-2, INV-3, INV-4, INV-5, INV-8, INV-10: D5-D11.

## Open points

All rulings below are 'ruled by the advisor (Q11)', 2026-10-14, relayed by the supervisor. Open point 9 was accepted and moved into D6.

1. Budgets: D7 figures stay targets; the implementing requirement measures `Sandbox.new` plus spawn cost, sets defaults, and must not exceed the D7 maxima without a new ruling (F11).
2. Manifest opt-in for restricted fields (D5): accepted. It barely constrains, since publishers hold `EntitiesRestrictionsManage`; the run-time re-check carries the weight.
3. `LuaScriptAudit`: retire once the hook-1 per-run record lands; its table stays read-only as history.
4. `coroutine`: denied (D11).
5. WASM-12 parity waiver for tenant scripts: confirmed (D0); the platform host API keeps its own contract.
6. `ctx.now` for hooks 2/3, and Records E and F: direction only (request time captured once per command is for those records).
7. Per-tenant script kill switch: MUST in the implementing requirement (D7); `revoked` has no expiry.
8. IdP subject recording: stays SHOULD (D6).
9. Single eligible publisher: accepted with amendments, now decision D6 (`scripts.sod`).

SECURITY-REVIEWER: pass 2 done (see "Sign-off").

## Customization beyond scripts (non-binding note)

Not decided or scheduled here. The roadmap/backlog is the home for these candidates: form/list/print-template overrides, number sequences, module-process extension slots, integration mappings, scheduled jobs, notification templates, label overrides, data import, configuration export/import, report builder. Each needs its own record or requirement.

**Requirement candidates: tenant customization of data (two separate needs, user clarification relayed 2026-10-14).**

(a) **Tenant-owned entity types.** These are whole new entity types a tenant creates for itself, fully theirs, with no module owner.

What exists today:
- A TENANT_ADMIN or PROCESS_DESIGNER can create and activate entity definitions at runtime (`:EntitiesDefinitionsWrite`, `docs/roles.md:98`).
- Activation promotes constrained fields to columns.
- Definitions can declare foreign keys between types (`definition/ddl.ex:126-134`, promoted only when constrained).
- A generic record form and list exist in the web app (`web/src/components/entities/EntityRecordForm.tsx`).
- Per-type READ access and per-field restrictions exist (`entities/type_access.ex`, REQ-394; `FieldGrants`, REQ-231).

What is missing:
- **Referencing module entities by id** under the 0050 reference contract. The generic record route cannot run a module's `lookup`/`active?` checks, so a tenant type pointing at `catalog_item` is unchecked.
- **Tenant-defined relations and lookups in the UI**, such as reference pickers and related lists.
- **Form and list generation** beyond the generic form.
- **Per-type WRITE permissions**, since `TypeAccess` governs reads.
- **Scope declarations for 0051** (a promoted, indexed scope column, or `tenant_wide`).

Depends on 0050 (reference contract, `managed_by`) and 0051 stage 2 (scopes).

(b) **Tenant extensions to standard module entities.** These are extra fields and validations a tenant adds to a module's entity type, plus per-tenant list, form and print-template overrides (including KZ print forms).

Storage is not the gap: entity records keep fields in a JSONB `field_values` blob with column promotion. The gap is **definition ownership on module upgrade**. An upgrade replaces the module's definition, so tenant additions live in a separate tenant layer:
- The layer uses a reserved `x_` namespace that modules may not use.
- It is stored apart from the module definition and merged over it at read and validation time.
- An upgrade never writes to it.
- The upgrade fails with a named conflict if the module introduces the same name.
- Overrides of lists, forms and print templates sit in the same tenant layer.

Depends on the module upgrade/migration record (roadmap wave 2).

Each candidate needs its own record and requirement. Neither is filed before the wave-1 items are moving.

## Sign-off

REVIEWER: pass 1 PASS_WITH_FINDINGS (F1-F15); pass 2 PASS_WITH_FINDINGS, 2026-10-14 (all pass-1 findings fixed or deferred to Records E/P; new findings N1-N10 are text fixes and implementing-requirement criteria). N1-N8 applied 2026-10-14.

SECURITY-REVIEWER: pass 1 (MUST 1-11); pass 2 PASS_WITH_FINDINGS, no remaining MUST; findings F-A..F-E carried into the implementing requirements (below).

Ratification: ratified 2026-10-14 by the user's advisor session (letflow-ec) under the user's delegation, recorded by the supervisor; open-point rulings in "Open points", solo-publisher policy in D6. Pack-related supersessions wait for Record P.

## Security review pass 2 (2026-10-14): findings carried into the implementing requirements

SECURITY-REVIEWER pass 2: PASS_WITH_FINDINGS, no remaining MUST. These become acceptance criteria of the implementing requirements:

- **F-A (high): binary memory.**
  - The refc-binary acceptance test for `include_shared_binaries` is a blocking gate.
  - Fallback: the watchdog samples the process's binary memory and kills it on a cap.
  - The heap-limit flag is set with `error_logger: false`, so the kill report never logs tenant values.
- **F-B: metamethod tests.**
  - An `__index` function loop.
  - `__lt` inside `table.sort`.
  - A `string.gsub` callback.
  - String-metatable mutation does not survive to the next run.
  - Output decoding calls no metamethods.
- **F-C: fresh VM per run.** Every run builds a fresh VM from `Sandbox.new`, with nothing reused across runs, scripts or tenants.
- **F-D: named tests and error text.** A named test asserts that output decoding creates no atoms. The raw Lua error text shown to the author in dry-run has host frames and paths stripped.
- **F-E: apply and Admission.** The apply transaction is a compare-and-set on the dispatch row (status running, same attempt), so a late or duplicate apply cannot double-apply. The Admission slot monitor sits on the watchdog, which dies with the dispatcher.

## Dependency hazards found by the 7a SECURITY gate (PR #2544)

The 7a runtime (PR #2544, merge 02c682e0) is built on `lua` 1.0.2 (`mix.lock` line 13; design `lib/letflow/design/gh2534-7a-script-runtime.md` section 0). SECURITY-REVIEWER found four node-level hazards in that library:

1. `table.concat` and `string.format` ignore `max_string_bytes`: 300 MB and 200 MB strings were built under a 1 MiB cap.
2. `print` joined all its arguments before truncating.
3. The bound of `string.gsub` ignored `%0`-`%9` expansion in the replacement.
4. A crashing script Task could log tenant values.

All four are fixed host-side in 7a, without patching the library, in `lib/letflow/engine/lua/script_runner.ex`, `script_host.ex`, `script_value.ex` and `sandbox.ex` (all four changed in PR #2544). Tests: `test/letflow/engine/lua/script_runtime_test.exs` (the "AC1/AC14 sandbox allow-list (equality)" describe; oversized `table.concat`, `string.format`, `string.gsub` and `string.char` refused before building; `print` of many 1 MiB strings; print and error text never logged).

**Rule.** The dependency stays pinned in `mix.lock`. Any version bump is gated by the allow-list equality test plus the 7a hazard tests above, because a new version can add library members or change bounds. Reporting these hazards upstream is the user's decision; this record does not say it has been done.
