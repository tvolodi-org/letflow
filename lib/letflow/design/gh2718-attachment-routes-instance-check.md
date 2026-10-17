# GH #2718 design: instance attachment routes answer an unknown or synthetic instance id with the Instances 404

Status: DESIGN (CODE-DESIGNER, 2026-10-17). Priority 2, SECURITY-adjacent. Design only, no implementation code.
Source: GH #2718 (body and two "Related" comments), `lib/letflow/design/gh2702-hide-synthetic-instances.md` (merged as #2720, commit 828d9d1b),
merged code `lib/letflow/event_store/instance_visibility.ex`, `lib/letflow/instances.ex`, `lib/letflow/routers/instances.ex`.
Branch base: origin/main 5597ea10. Related: #2702/#2720 (predicate), #2582 (record attachments vs managed types, a different route family,
`/entities/records/:type/:id/attachments`, out of scope), #2697 (not read for this note: the issue only lists it as related; see O7).

## 0. Findings from re-reading main

F1. The issue's claim is CONFIRMED by reading (not by running; no mix runs were allowed for this note). The six `/instances/:id/attachments...` routes
(plus `GET /storage-usage`, which has no id) are declared at `lib/letflow/routers/instances.ex:402-431`; none of their handlers calls anything that checks the
instance. The router moduledoc says so itself, "Not validated by this route layer", `instances.ex:302-308`.

F2. Route inventory (policy keys in `lib/letflow/api/authorization.ex:934-955`; permission gate `authz_*` runs BEFORE the handler, after
`Plug.Parsers`, see F6):

| # | Route | Router line | Handler | Permission | Context call |
|---|---|---|---|---|---|
| R1 | `POST /instances/:id/attachments` | 402 | `handle_upload_attachment` 1111-1128 | `AttachmentsManage` | `Attachments.upload/2` |
| R2 | `GET /instances/:id/attachments` | 406 | `handle_list_attachments` 1216-1241 | `AttachmentsRead` | `Attachments.list/2` |
| R3 | `GET /instances/:id/attachments/:attachment_id` (bytes; the "download route") | 410 | `handle_get_attachment_content` 1265-1285 | `AttachmentsRead` | `Attachments.get_content/3` |
| R4 | `DELETE /instances/:id/attachments/:attachment_id` | 414 | `handle_delete_attachment` 1589-1602 | `AttachmentsManage` | `Attachments.get/2` then `Attachments.delete/3` |
| R5 | `POST /instances/:id/attachments/:attachment_id/link` | 425 | `handle_issue_attachment_link` 1480-1503 | `AttachmentLinksIssue` | `Attachments.get/2`, `AttachmentLinks.issue/2` (writes the lazy signing key) |
| R6 | `GET /instances/:id/attachments/:attachment_id/link-content` | 429 | `handle_get_attachment_link_content` 1536-1564 | `AttachmentsRead` | token verify then `Attachments.get_content/3` |

The issue names R1, R2, R4; R3, R5, R6 carry the same `:id` and the same gap, so this design covers all six (decision D1, open question O1 if the
supervisor wants a narrower scope).

F3. Current behaviour per route for an unknown or synthetic id (all of it reads the code, nothing run):
- R1 upload: `cast_instance_id` (422 on a bad UUID), `actor_id`, `upload_attrs_from_conn` (`File.read!` of the whole multipart temp file into memory,
  `instances.ex:1141`), then `Attachments.upload/2` (`repository/attachments.ex:232-267`): content type allowlist (415), size (413), scan (422/503),
  `TenantProvisioning.tenant_id_for_schema_name`, `check_storage_quota` (409), then ONE transaction that upserts `repository_artifacts` and inserts the
  `instance_attachments` row. `instance_attachments.instance_id` has no FK (REQ-211 migration references only `repository_artifacts`). Result 201 for ANY syntactically valid
  UUID. After commit, `record_attachment_attached_event/2` (`attachments.ex:356-388`) calls `EventStore.append` with `ATTACHMENT_ATTACHED`:
  - nonexistent id: `active_instance_guard` (`event_store.ex:680-683`) returns `:instance_not_started`, the append transaction rolls back, a
    `Logger.warning` is written and swallowed. Net effect: an ORPHAN `instance_attachments` row plus a content-addressed `repository_artifacts` row, counted
    against the tenant storage quota, no event.
  - synthetic id: the synthetic projection is `:active`, so the append SUCCEEDS: an `ATTACHMENT_ATTACHED` event (file name, content type, size, description)
    is written onto the entity type's synthetic event log. Writes to a hidden instance, which #2702's invariant I2 ("no client route mutates a synthetic instance") forbids.
- R2 list: 200 with `{"items": [], "next_cursor": null}` for both (an unknown id has no rows). Pre-fix uploads to a synthetic id are listable.
- R3/R6 content: `Attachments.get_content/3` folds a missing attachment, a cross-instance attachment and a bad attachment id to `{:error, :not_found}`; the router then
  runs the REQ-388 denied-access audit write (`instances.ex:1325-1343`). An unknown/synthetic instance id with an attachment id that does not exist: 404 already; with an
  attachment that exists under that same unknown/synthetic id (an orphan created by a pre-fix upload): 200 bytes.
- R4 delete: `fetch_scoped_attachment_metadata` (`instances.ex:1434-1441`) requires `attachment.instance_id == path id`, so unknown id + unknown attachment = 404 already; unknown/synthetic id +
  an existing orphan attachment = 204 and an `ATTACHMENT_REMOVED` append attempt (same guard behaviour as R1).
- R5 link: same lookup as R4, then mints a bearer token for an orphan.

F4. The #2702 predicate as merged (`lib/letflow/event_store/instance_visibility.ex`):
- `exclude_synthetic(query, prefix)`: anti-join `NOT EXISTS (... entity_type_instances ...)` on a query whose first source is `InstanceProjection`.
- `synthetic?(instance_id, prefix)`: one `EXISTS` on `entity_type_instances` only. It is `false` for a nonexistent id. Used alone it would make unknown
  ids pass, so it is NOT sufficient for this issue (it is what `handle_get_pins` uses as defence in depth, `instances.ex:1060-1075`, which then relies on `PinResolver` for the unknown-id 404).
- "Exists AND not synthetic" in ONE query already exists privately as `Instances.ensure_instance_exists/2` (`instances.ex:366-378`: projection row by id with
  `exclude_synthetic`, `Repo.exists?`), and as `Instances.get_by_id/2` (`instances.ex:56-75`, returns the row or `{:error, :not_found}`).

F5. How the other Instances routes return the 404 (INV-5). Every one ends in `Response.not_found/1` (`lib/letflow/api/response.ex:226`: `send_problem(conn, Error.not_found())`,
a constant body with no detail slot), reached through the same code path for nonexistent and synthetic ids:
- `GET /:id`: `Instances.get_by_id/2` -> `{:error, :not_found}`.
- `GET /:id/history`, `/:id/timeline`: `cast_instance_id` -> `ensure_instance_exists` FIRST inside the context (`instances.ex` ~line 143/198) -> cursor decode -> events query. The router
  validates `page_size`, `from`/`to` BEFORE calling the context (`instances.ex:932-936`), so those 4xx answers do not depend on existence.
- cancel/rebind-pins/reconstruct: existence inside the engine call (#2702 design section 2), body validation and idempotency-key validation precede it.
- The 422 for a malformed UUID precedes everything (`cast_instance_id`).
So the established order is: permission (plug) -> UUID shape (422) -> existence-independent request validation (page size, body shape) -> existence (404) -> work. Rendering is constant, so byte identity is structural.

F6. Pipeline order before the handler (`lib/letflow/plugs/api_pipeline.ex`, moduledoc line 12 and the plug list): Admission -> `Plug.Parsers` (multipart up to 25 MiB, parsed and
spooled to a temp file BEFORE authentication and authorization) -> AuthPipeline -> router `authz_*` -> handler. Consequence: an oversized multipart body is a parser-level 413 for every id and every caller,
so it cannot discriminate between ids (identical for real, nonexistent, synthetic). Unchanged by this design.

F7. Callers. `Attachments.upload/2` and `Attachments.list/2` have exactly one non-test caller: `Letflow.Routers.Instances` (grep of `lib/`). `Attachments.list_all_for_instance/2`
is used by `engine.ex:8086` (task-completion snapshot of a real instance) and is untouched. The entity-record attachment family (`EntityAttachments`, `routers/entities.ex`) is a separate route family and out of scope (#2582).

F8. Role overlap (from `priv/permission_matrix/effective.golden`): every base role holding `AttachmentsRead`/`AttachmentsManage` (PLATFORM_ADMIN, PROCESS_OPERATOR, PROCESS_DESIGNER,
TASK_WORKER) also holds `InstancesRead`; every `AttachmentsManage` holder also holds `AttachmentsRead`. So adding the check gives no caller a new existence oracle that `GET /instances/:id` did not already give them
(INV-5 is about callers without the permission; they stop at the plug with the same 403 for any id). TENANT_ADMIN / TENANT_AUDITOR are not rows in the golden's base-role list; the #2702 walk already exercises them on the Instances reads, and the implementer must confirm both permissions in the golden for those two (O5).
Custom, group-granted permissions could in principle grant an attachment permission without `InstancesRead`; flagged in O5.

## 1. Decisions

D1. One rule for the whole family: every route R1-R6 requires the path `:id` to name a VISIBLE instance, meaning a row in `instance_projections` of the caller's tenant schema that is NOT registered in `entity_type_instances`. A
nonexistent id, a synthetic id, a platform-sentinel id and (by construction) another tenant's id are all the same answer: `Response.not_found/1` (404, constant problem body). Terminal instances (completed, cancelled, error) remain valid
parents: `Attachments` has always allowed attach/detach on non-active instances (REQ-391 comment at `attachments.ex:346-355`), so the check is existence-and-visibility, never a status check.

D2. Where the check lives: in the ROUTER layer, calling one new thin public function in `Letflow.Instances`, not inside `Letflow.Repository.Attachments`. Reasons: (a) the router is the only caller (F7) and already
owns the 404 vs 422 mapping for the other Instances routes; (b) `Repository.Attachments` is a REQ-211 core with 31 context tests (`test/letflow/repository/attachments_test.exs`) that deliberately attach to bare UUIDs, and
making it depend upward on `Letflow.Instances` inverts the current layering; (c) INV-RT-1 (no `Repo.*` in `lib/letflow/routers/`) is satisfied because the router calls the context function. Rejected alternative: a guard inside `upload/2`/`list/2`/`get_content/3` (changes a shipped context
contract, breaks the context tests, still needs the router to map a new error tuple).

D3. Predicate reuse (answers requirement 2): REUSE the #2702 predicate through the existing single-query composition; add NO second predicate and NO copy of the anti-join. Concretely, expose the logic of the private
`Instances.ensure_instance_exists/2` (projection exists AND `InstanceVisibility.exclude_synthetic/2`) as one public function and make `ensure_instance_exists/2` call it, so history/timeline and the attachment routes share one definition. A thin wrapper is
needed (rather than `InstanceVisibility.synthetic?/2` directly) because `synthetic?/2` is false for unknown ids (F4). Rejected: `synthetic?/2` then a separate existence read (two round trips, and the unknown and synthetic paths would differ in query count and
timing, the exact thing the #2702 design section 4 avoided); `Instances.get_by_id/2` (works, but loads and discards a full projection row; the wrapper is a plain `EXISTS`).

D4. No new status, no new error shape, no new `render_*` clause and no router-level `with` branch that carries a detail string. The 404 is the existing `Response.not_found/1` already imported by every attachment handler, so byte identity with the other
Instances routes is structural (same function, constant body), as in #2702 section 2 last row.

D5. No migration, no schema change, no FK on `instance_attachments.instance_id` (a FK to `instance_projections` would be wrong anyway: projections can be absent for a reconstructed instance, and it would not hide synthetic ids). No permission atom or `endpoint_policy_key` change, so the #2612 permission-matrix golden is not
affected (verify with `mix letflow.permission_matrix --check` in the PR, O6).

## 2. Interface (types only)

New public function in `Letflow.Instances` (`lib/letflow/instances.ex`):
- `instance_visible?(id :: Ecto.UUID.t(), opts :: keyword()) :: boolean()`. `opts` carries `:prefix` (required; `Keyword.fetch!`, so a missing prefix is a programmer error, not `false`). Precondition: `id` is an already-cast canonical UUID string (the router's `cast_instance_id` output). Semantics: one query on `InstanceProjection` by `instance_id`,
  composed with `InstanceVisibility.exclude_synthetic/2`, executed with `Repo.exists?` and `prefix: prefix`. Returns only `true`/`false`; a DB error propagates as the normal Repo raise (never folded into `false`, which would turn an outage into a 404; never rescued, INV-8 stays with the existing Plug-level handling).
- `ensure_instance_exists/2` (private) is rewritten to delegate to the same query, return values unchanged (`:ok | {:error, :not_found}`), so history and timeline are behaviourally untouched.

Router (`lib/letflow/routers/instances.ex`): one private helper, `require_visible_instance(conn_opts, instance_id) :: :ok | {:error, :not_found}`, used as a step in each handler's `with`, and each handler maps `{:error, :not_found}` to `Response.not_found(conn)` (R3-R6 already have that clause). No change to `Letflow.Repository.Attachments`, `Attachment`, `AttachmentLinks`, migrations or the authorization module. Moduledoc "Not validated by this route layer" paragraph (`instances.ex:302-308`) is replaced by the new rule (D1).

## 3. Per-route table (requirement 1)

Pipeline position for every route: `Plug.Parsers` -> auth -> `authz_*` permission (403, unchanged, so permission precedes existence and a caller without the permission gets the same 403 for any id) -> handler steps below.

| Route | Current behaviour (F3) | Desired behaviour | Handler step order after the change |
|---|---|---|---|
| R1 upload | 201 for any UUID; orphan rows for unknown id; event written onto a synthetic instance | unknown or synthetic id: 404 identical to other Instances routes; NOTHING written (no artifact row, no attachment row, no event, no quota effect, no scan, no `File.read!`) | `cast_instance_id` (422) -> `actor_id` -> `file` part present? (pattern check only, 422 `missing_file`, no file read) -> **visible-instance check (404)** -> `File.read!` and attrs -> `Attachments.upload/2` (415 / 413 / 422 infected / 503 / 409 quota / 201) |
| R2 list | 200 empty for any UUID | unknown or synthetic id: 404; real instance: unchanged | `cast_instance_id` (422) -> `page_size` parse and range (400) -> **visible-instance check (404)** -> `Attachments.list/2` (cursor 422/410 stay inside the context, after the check, like history's cursor) |
| R3 download | 404 only if the attachment is absent or belongs to another instance id; an orphan under an unknown/synthetic id streams | unknown or synthetic instance id: 404, regardless of the attachment id; real instance unchanged (still 404 for cross-instance, with the REQ-388 audit) | `cast_instance_id` (422) -> **visible-instance check (404)** -> `fetch_scoped_attachment_content` (unchanged) |
| R4 delete | as F3; deletes an orphan (204) | unknown or synthetic instance id: 404, whatever the attachment id (see "delete and legacy orphans" below) | `cast_instance_id` (422) -> **visible-instance check (404)** -> `fetch_scoped_attachment_metadata` -> `actor_id` -> `Attachments.delete/3` (204) |
| R5 link issue | mints a token for an orphan | unknown or synthetic instance id: 404, no token, no signing-key write | `cast_instance_id` (422) -> **visible-instance check (404)** -> `fetch_scoped_attachment_metadata` -> `AttachmentLinks.issue/2` |
| R6 link-content | token then attachment lookup; serves an orphan | unknown or synthetic instance id: 404 | `cast_instance_id` (422) -> **visible-instance check (404)** -> `verify_link_token` / `check_attachment_id_matches` (expired-or-invalid) -> `fetch_scoped_attachment_content` |

Ordering rationale. The check sits AFTER the cheap, existence-independent validations that the other Instances routes also run first (UUID shape, page size, the `file` part's presence) and BEFORE every write, every read of
caller-supplied bytes and every expensive step. For R1 this means content-type (415), size (413), scan, quota are all evaluated only for a visible instance; for an unknown or synthetic id they cannot be reached (they all live inside `Attachments.upload/2`). R6: the check precedes token verification so a bad token on an unknown instance and on a synthetic instance are the same
answer (404 for both), and existence checking never depends on the token. Consequence to state in the PR: for an unknown id, a bad content type now returns 404 instead of 415. This does not add an oracle (F8: every
`AttachmentsManage` holder can already see real vs unknown via the list route and `GET /instances/:id`), and it is the only ordering under which "nothing stored before the check" and "unknown == synthetic" both hold without splitting `upload/2` (open question O3 offers the alternative).

Delete and legacy orphans (requirement 1, the delete question). Decision D6: R4 (and R5) check the instance FIRST, uniformly with the rest of the family. An attachment whose parent instance does not exist or is synthetic therefore becomes undeletable and unlinkable through the API.
Such rows exist only from pre-fix uploads (F3); after this change none can be created. They are value-free for the entity case (file metadata and bytes the same caller uploaded) but they occupy tenant storage quota (`get_storage_usage` sums every row) and `repository_artifacts`. Remediation is a separate one-off data cleanup (follow-up issue, same shape as
#2702's O6 for orphan projections) and is NOT part of this PR. The alternative (exempting delete from the check so a caller who knows the attachment id can still remove an orphan) keeps cleanup possible but leaves delete as the one route in the family whose answer for a synthetic id is not the Instances 404 (204 vs 404 depending on a row the caller may not otherwise see), contradicting the issue's "byte-identical" acceptance. Supervisor decision: O2.

## 4. INV-5 byte-identical analysis (requirement 3)

Equality target: for each of R1-R6, a request with a SYNTHETIC entity-type instance id equals, in status, body, and the full response header set (masking only `x-request-id` and `date`, `x-trace-id` pinned by the request as in the #2702 walk), BOTH (a) the same route called with a fresh random UUID, and (b) `GET /instances/:id` for a random UUID. Mechanism:
1. Same terminal function: `Response.not_found/1` (constant `Error.not_found()` problem, no detail), no new render clause (D4). Headers are produced by the shared `send_problem` plus pipeline plugs, independent of the route.
2. Same decision path: unknown and synthetic ids are indistinguishable INSIDE the single `instance_visible?` query (one round trip, the anti-join is part of the WHERE clause), so the DB path, query count and error branch are the same, there is no "exists, then is it synthetic" two-step.
3. Order of checks vs the existence-dependent outcomes: permission (403) before; UUID (422), page size (400) and missing `file` part (422) before and independent of existence (so those answers are identical for real, unknown, synthetic ids, as for the other routes); everything that can differ by id (content type 415, size 413 in the context, scan, quota 409, 201, 200 list, 204, token handling, content bytes, denied-access audit) is after. Therefore the only inputs on which an unknown id differs from a real one are the real id's success or its post-check errors, i.e. exactly the oracle `GET /instances/:id` already provides to the same roles (F8).
4. Side effects and timing: nothing is stored, scanned, logged as an infected upload, audited, or appended before the check. The unknown/synthetic path does one `EXISTS` and renders; it does not call `Attachments.*`, `AttachmentLinks.*`, `EventStore.append`, nor `File.read!`. R3/R6 therefore no longer write an `attachment.access_denied` audit row for an unknown/synthetic instance id (REQ-388 audits a denied fetch of a REAL tenant attachment through the wrong instance; with an unknown instance there is no instance to be the wrong one). The same is true for both unknown and synthetic ids, so no timing/side-effect difference between the two exists; whether the audit row should still be written is O4.
5. Remaining residual, stated for SECURITY-REVIEWER: `Plug.Parsers` already spooled the multipart body (F6) before any of this, equally for all ids; response time for a real id's list/upload is naturally longer than a 404. This is the same residual every Instances route has (a real id's 200 is slower than a 404) and is not an INV-5 violation, which concerns content, not latency.

## 5. Invariants

I1. A client attachment route NEVER returns data, existence or error text distinguishing a synthetic instance from a nonexistent one (extends #2702 I1 to R1-R6).
I2. No attachment route writes anything (rows, events, quota, signing key, audit) for an unknown or synthetic instance id. Closes the synthetic-event-log write in F3/R1.
I3. A real instance (active or terminal) behaves byte-for-byte as before on all six routes, including all existing 4xx.
I4. `Letflow.Repository.Attachments`, `AttachmentLinks` and `EntityAttachments` contracts are unchanged; `Engine` task completion (`list_all_for_instance`) is unchanged.
Security invariants engaged (`docs/agents/instructions/security-invariants.md`): INV-1 (tenant prefix: `instance_visible?` takes the prefix from `scoped_opts` and passes it to the query-level prefix of both sources, the same mechanism as `InstanceVisibility`), INV-2 (response allowlist: no new fields), INV-5 (identical 404), INV-7 (no fragments or string-built SQL; reuse of
`exclude_synthetic/2` only), INV-8 (a DB error is a Repo raise, never folded into `false`/404). INV-3/INV-4/INV-6 are not touched (no auth change, no logging of bytes or ids beyond what exists).

## 6. Test plan (requirement 4; TEST-DESIGNER implements, real HTTP router, failing first)

Fixtures: a real workflow instance (Engine create from an active definition, as T5 of `test/letflow/routers/instances_synthetic_hidden_test.exs` does) and a synthetic one (`EntityTypeInstance.get_or_create/2`, as that file does), a fresh random UUID, and the same bearer token / `x-tenant-slug` / fixed `x-trace-id` plumbing. Headers compared with `x-request-id` and `date` masked. Failure messages must never print response bodies or restricted values.

New file `test/letflow/routers/gh2718_attachment_instance_check_test.exs`. Each test is written first and observed failing on main for the reason in the right column.

| Test | Asserts | Fails on main because |
|---|---|---|
| A1 upload, nonexistent id | 404, body and headers equal to `GET /instances/<random>` 404 | 201 |
| A2 upload, synthetic id | same as A1; compared with A1's response (status, body, headers) | 201 |
| A3 upload writes nothing for A1/A2 | row counts of `instance_attachments` and `repository_artifacts` unchanged; `events` count for the synthetic id unchanged (no `ATTACHMENT_ATTACHED`); `get_storage_usage` unchanged | rows and a synthetic event exist |
| A4 list, nonexistent id | 404 equal to the Instances 404 | 200 empty |
| A5 list, synthetic id | same, equal to A4 | 200 empty |
| A6 list with a pre-existing orphan row under the synthetic/unknown id (inserted through the context) | still 404, orphan not disclosed | 200 with the orphan |
| A7 delete, nonexistent and synthetic id, with (i) a nonexistent attachment id and (ii) an orphan attachment inserted via the context | all 404 equal to the Instances 404; orphan row still present | (ii) is 204 and deletes it |
| A8 download and link-content, nonexistent and synthetic id, with an orphan attachment id | 404; no bytes | 200 bytes (orphan) |
| A9 link issue, nonexistent and synthetic id, orphan attachment id | 404 and no signing-key write | 200 with token |
| A10 validation order | malformed UUID: 422 for every route, identical to before; list with bad `page_size` on an unknown id: the same 400 as on a real id; upload without a `file` part on an unknown id: the same 422 as on a real id | passes already on main (regression guard; must stay green) |
| A11 equality matrix | for each of R1-R6 and each role that has the permission (TENANT_ADMIN for manage routes; TASK_WORKER and TENANT_AUDITOR for reads): synthetic response == nonexistent response (status, body, headers) == `GET /instances/<random>` response | 200/201/204 differ |
| A12 permission precedes existence | a caller lacking the permission (AGENT_RUNNER, CANDIDATE, TENANT_AUDITOR on manage routes) gets the same 403 for a real, unknown and synthetic id | passes on main (guard) |
| A13 DB path | query count (telemetry handler on the repo query event scoped to the request, as #2702 T2b(v)) is equal for synthetic and nonexistent ids on R1-R6, and the unknown/synthetic path issues no write | n/a (fails when a second read or a write is present) |
| A14 control, real instance | active AND a cancelled instance: upload 201 with the same body shape, list 200 with the uploaded item, download 200 bytes, delete 204, link issue 200 | already passes (guards D1's "no status check") |
| A15 predicate unit | `Instances.instance_visible?/2`: true for a real projection, false for unknown, false for a synthetic id, false for the platform sentinel id, tenant isolation (an id real in tenant A is false in tenant B), raises `KeyError` without `:prefix` | function missing |

Existing tests that must change (fallout, TEST-DESIGNER owns): the route suites below dispatch to bare `Ecto.UUID.generate()` instance ids and will 404 after the fix, so each needs a real-instance fixture: `test/letflow/routers/req212_attachments_routes_test.exs`
(~25 sites), `req386_attachment_links_routes_test.exs`, `req388_attachment_access_denial_audit_test.exs`, `tenant_auditor_routes_test.exs` (attachment rows at ~105/424/433), and the `:same`/`:upload` expectations of attachment rows in `instances_synthetic_hidden_test.exs` (lines 55-60) flip to `:not_found`. The context suites (`test/letflow/repository/attachments_test.exs`, `entity_attachments_test.exs`, `engine_complete_task_test.exs`) call the context directly and stay unchanged. A shared helper for "create a real instance for a tenant" should live in test support rather than being copied (open question O8).

Acceptance-to-test mapping (issue #2718):
- "Design note first, re-reading the attachment routes on main (file:line) and the #2702 predicate" -> this file, sections 0 and 1.
- "upload and list for a nonexistent id and for a synthetic id return the same 404 as a nonexistent id on the other Instances routes" -> A1, A2, A4, A5, A11 (delete A7, download A8, link A9 extend it).
- "a real instance still works" -> A14 (and the existing req212/386/388 suites after their fixtures use real instances).
- "SECURITY-REVIEWER verdict; REVIEWER verdict; scoped tests, compile with warnings as errors and format check quoted" -> routing section 8.

Mutants the tests must kill:
M1 remove the check from R1 -> A1, A2, A3 fail. M2 remove it from R2 -> A4, A5, A6. M3 remove it from R4 -> A7. M4 remove it from R3, R5 or R6 -> A8, A9 (each route has its own row in A11).
M5 use `InstanceVisibility.synthetic?/2` instead of `instance_visible?/2` -> A1, A4, A7 (unknown id passes). M6 use existence only, without `exclude_synthetic` -> A2, A5, A11 (synthetic passes).
M7 place the R1 check after `Attachments.upload/2` or after `File.read!` -> A3 (rows or temp-file read) and A13 (writes) fail. M8 return 403, or a different detail/status for synthetic -> A11 fails.
M9 add a status check (only ACTIVE parents) -> A14 (cancelled instance) fails. M10 fold a DB error into `false` -> a test that makes the query raise (unit, A15 variant) asserts the raise propagates.
M11 drop the explicit prefix -> A15 tenant isolation fails. M12 R6 check after token verification -> A11's R6 row with an invalid token fails (404 expected, expired-or-invalid returned).

## 7. Size and files

One PR. Production: `lib/letflow/instances.ex` (+~12, one public function, `ensure_instance_exists` delegates), `lib/letflow/routers/instances.ex` (+~25: helper and six `with` steps; moduledoc paragraph replaced; `upload_attrs_from_conn` split so the `file` part check precedes `File.read!`). No migration, no schema, no config, no permission change. Docs: moduledoc, one anti-pattern line (DOC-UPDATER): "a route taking an instance id must not rely on the context for existence".

## 8. Routing

- SECURITY-REVIEWER: REQUIRED (mandatory for this issue regardless of the issue's "recommended"). Tenant-data path (API route, existence oracle, a write on a hidden synthetic instance closed), and the issue itself asks SECURITY-REVIEWER to rule on the shape: delete (O2), audit on the new 404 (O4), upload ordering (O3), custom-role overlap (O5).
- REVIEWER: required (scope: six routes vs the three the issue names, O1; layering: check in the router, not in the context; moduledoc rewrite).
- TEST-DESIGNER / TEST-DESIGN-VALIDATOR / TEST-RUNNER as usual; scoped tests, `mix compile --warnings-as-errors` and `mix format --check-formatted` quoted in the PR.
- ELIXIR-DEV implements; no FRONTEND-DEV impact expected, but see O9.

## 9. Open questions for the supervisor (no guesses made)

O1. Scope: the issue names upload, list, delete. This design extends the same check to download (R3), link issue (R5) and link-content (R6), because they carry the same `:id`, serve or mint capabilities for orphans, and would otherwise leave a documented exception. Confirm, or narrow to R1/R2/R4 (then R3/R5/R6 keep serving orphans under unknown/synthetic ids and the equality matrix A11 excludes them).
O2. Delete of an attachment whose parent instance is unknown or synthetic (legacy orphans): D6 chooses "404, undeletable via API, cleaned up by a separate one-off". Alternatives: exempt R4 from the check so the caller can still remove their own orphan (204 vs 404 is then the one non-uniform answer), or ship the cleanup (delete rows with no visible parent, release quota) in this PR. SECURITY-REVIEWER ruling needed; also whether to file the cleanup issue now.
O3. Upload ordering: the check precedes `Attachments.upload/2`, so an unknown id with a disallowed content type or oversized part (below the 25 MiB parser limit) answers 404 not 415/413. The alternative (keep 415/413 first) needs the content-type and size checks lifted out of `upload/2` into a function the router can call before the existence check, a context API change. Accept D3 ordering?
O4. REQ-388: on R3/R6 the denied-access audit row (`attachment.access_denied`) is no longer written when the instance id is unknown or synthetic. Keep that (uniform with the other Instances 404s, no write), or write an audit row with a new `reason` such as `instance_not_found` (needs an audit-reason decision and removes the "nothing written" property for those two routes)?
O5. Confirm in the golden / role tables that TENANT_ADMIN and TENANT_AUDITOR hold `InstancesRead` together with each attachment permission (F8 verified only the four base roles from `effective.golden`), and decide whether a custom group-granted `AttachmentsRead` without `InstancesRead` is a supported configuration. If it is, the new 404 gives that holder an existence oracle for instances they cannot otherwise read.
O6. Run `mix letflow.permission_matrix --check`: expected unchanged (#2612 not triggered, same reasoning as #2702 section 9). Confirm no golden regeneration is wanted.
O7. #2697 ("Entity query and export accept filter/sort on fields restricted for the caller") is listed as related by the issue but is not obviously connected to the attachment routes; I did not use it. Confirm there is nothing to carry over (for example a shared ordering decision).
O8. Test support: introduce a shared "real instance for tenant" helper (where: `test/support/`), or copy the T5 setup into each of the four route suites?
O9. Clients: `web/` and the mobile tier may rely on upload/list to a not-yet-started instance (no consumer was found in this note's reading, and the router moduledoc says no `web/` consumer existed at REQ-212). Confirm there is no workflow that attaches a file before the instance row exists (instance creation is synchronous and creates the projection, so none is expected).
