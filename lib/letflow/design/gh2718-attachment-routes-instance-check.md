# GH #2718 design: instance attachment routes answer an unknown or synthetic instance id with the Instances 404

Status: RULED (supervisor rulings O1-O4 applied, amendment of 2026-10-17), subject to SECURITY-REVIEWER on the final shapes; the DELETE shape (D6) is presented to SECURITY-REVIEWER as the default with a documented fallback. Priority 2, SECURITY-adjacent. Design only, no implementation code.
Amendment log: (A1) supervisor rulings O1 yes, O3 accept, O4 accept, O2 CHANGED (delete proceeds for an unknown instance, hides a synthetic one); (A2) CODE-DESIGN-VALIDATOR blockers: F8 corrected, O9 corrected (web consumers exist), M7 made killable, split-upload interface specified; (A3) new deliverable: read-only orphan-attachment inventory SQL (section 10).
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
(INV-5 is about callers without the permission; they stop at the plug with the same 403 for any id). Verified for all six roles with an attachment permission, from the golden: TENANT_ADMIN holds `AttachmentLinksIssue`, `AttachmentsManage`, `AttachmentsRead` (golden lines 303-305) and `InstancesRead` (331); TENANT_AUDITOR holds `AttachmentsRead` (354) and `InstancesRead` (380) but NOT `AttachmentsManage` (353) nor `AttachmentLinksIssue` (352). Consequence for tests: TENANT_AUDITOR is a valid caller only for the read routes R2, R3, R6 and must see the same not-found shape there; on R1, R4, R5 it gets the plug-level 403 for any id (real, unknown, synthetic), before existence.
Policy statement (replaces the old open question O5): a custom group-granted attachment permission WITHOUT `InstancesRead` is NOT a supported configuration. If it exists, the new 404 gives that holder an existence signal (404 vs success) for instance ids they cannot read through `GET /instances/:id`; this is accepted as an operator misconfiguration and is not mitigated by this change (mitigating it would mean answering 403/404 uniformly for such a caller, a permission-model change out of scope).

## 1. Decisions

D1. One rule for the whole family: every route R1-R6 requires the path `:id` to name a VISIBLE instance, meaning a row in `instance_projections` of the caller's tenant schema that is NOT registered in `entity_type_instances`. A
nonexistent id, a synthetic id, a platform-sentinel id and (by construction) another tenant's id are all the same answer: `Response.not_found/1` (404, constant problem body). Terminal instances (completed, cancelled, error) remain valid
parents: `Attachments` has always allowed attach/detach on non-active instances (REQ-391 comment at `attachments.ex:346-355`), so the check is existence-and-visibility, never a status check.
EXCEPTION (supervisor ruling O2, D6): R4 DELETE hides a SYNTHETIC instance but lets an UNKNOWN instance id proceed to the attachment lookup, so a legacy orphan row can still be deleted.

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
affected (the implementer step runs `mix letflow.permission_matrix --check` and quotes the result; this is an action, not a decision, section 9 O6).

D6. DELETE shape (supervisor ruling O2, default presented to SECURITY-REVIEWER). R4 must NOT make legacy orphans undeletable. Rule: after the attachment lookup succeeds and BEFORE `actor_id`/`Attachments.delete/3`, the handler asks `InstanceVisibility.synthetic?/2` for the path instance id: synthetic means `Response.not_found/1` (hide, row untouched); anything else (a real instance OR an unknown instance id) proceeds to the delete. Unknown and real instances therefore take the identical code path and query sequence; there is NO visible-instance check on R4. The order is lookup first, synthetic check second (not the reverse) so that, for a MISSING attachment, a synthetic, an unknown and a real instance id all issue exactly one query (the attachment lookup) and answer the same 404, and the query count cannot distinguish them (section 4 item 5 for the oracle analysis). R5 (link issue) is NOT relaxed: it keeps the visible-instance check first (minting a bearer capability for an orphan has no cleanup value).
FALLBACK if SECURITY-REVIEWER finds an oracle in D6: R4 checks the visible instance first, like R5 (original design: all legacy orphans under unknown or synthetic ids become undeletable through the API), plus a separate one-off operator cleanup driven by the section 10 inventory. Switching is a two-line change in the handler plus the R4 rows of tests A7*/A11/A13 and mutants M3a-M3d.

## 2. Interface (types only)

New public function in `Letflow.Instances` (`lib/letflow/instances.ex`):
- `instance_visible?(id :: Ecto.UUID.t(), opts :: keyword()) :: boolean()`. `opts` carries `:prefix` (required; `Keyword.fetch!`, so a missing prefix is a programmer error, not `false`). Precondition: `id` is an already-cast canonical UUID string (the router's `cast_instance_id` output). Semantics: one query on `InstanceProjection` by `instance_id`,
  composed with `InstanceVisibility.exclude_synthetic/2`, executed with `Repo.exists?` and `prefix: prefix`. Returns only `true`/`false`; a DB error propagates as the normal Repo raise (never folded into `false`, which would turn an outage into a 404; never rescued, INV-8 stays with the existing Plug-level handling).
- `ensure_instance_exists/2` (private) is rewritten to delegate to the same query, return values unchanged (`:ok | {:error, :not_found}`), so history and timeline are behaviourally untouched.

Router (`lib/letflow/routers/instances.ex`), all private, no `Repo.*` (INV-RT-1). `scoped_opts` below is `conn.assigns.scoped_opts`, the keyword list produced by `Letflow.Api.Context.scoped_repo_opts/1` (at minimum `[prefix: String.t()]`); it is passed through UNCHANGED to the Instances/InstanceVisibility calls, which do `Keyword.fetch!(opts, :prefix)` exactly as `handle_get_pins` does at `instances.ex:1066` (no re-derivation of the schema from input, INV-1).
- `require_visible_instance(scoped_opts :: keyword(), instance_id :: Ecto.UUID.t()) :: :ok | {:error, :not_found}`. Calls `Instances.instance_visible?/2`. Used by R1, R2, R3, R5, R6.
- `reject_synthetic_instance(scoped_opts :: keyword(), instance_id :: Ecto.UUID.t()) :: :ok | {:error, :not_found}`. Calls `InstanceVisibility.synthetic?/2` with `Keyword.fetch!(scoped_opts, :prefix)`. Used ONLY by R4 (D6), placed after the metadata lookup.
- Split of the private `upload_attrs_from_conn/3` (`instances.ex:1134-1153`, called only from `handle_upload_attachment`; it is removed and replaced by the two functions below; nothing else calls it):
  - `upload_file_part(conn :: Plug.Conn.t()) :: {:ok, Plug.Upload.t()} | {:error, :missing_file}`. Pure pattern check of `conn.body_params["file"]` for a `%Plug.Upload{}`; reads nothing from disk, does no DB call. Error shape identical to today's (`{:error, :missing_file}` maps to 422 "a file part named \"file\" is required").
  - `build_upload_attrs(upload :: Plug.Upload.t(), instance_id :: Ecto.UUID.t(), actor_id :: Ecto.UUID.t(), conn :: Plug.Conn.t()) :: Attachments.upload_attrs()`. Total (no error tuple): does the `File.read!` and builds the same attrs map as today (instance_id, raw_bytes, file_name, content_type, uploaded_by, description). A missing or unreadable temp file raises `File.Error` exactly as today (not newly rescued).
- `handle_upload_attachment` `with` chain becomes: `cast_instance_id/1` -> `actor_id/1` -> `upload_file_part/1` -> `require_visible_instance/2` -> `build_upload_attrs/4` -> `Attachments.upload/2`.
- NEW `else` clauses (they do not exist today): `handle_upload_attachment` (R1) and `handle_list_attachments` (R2) gain `{:error, :not_found} -> Response.not_found(conn)`. R3, R5, R6 already have that clause; R4 already has it. No other clause is added or changed, and `render_upload_attachment/3` and `render_list_attachments/2` are NOT touched (D4).
- `handle_list_attachments` `with` chain: `cast_instance_id/1` -> `Pagination.parse_page_size_param/1` -> `Pagination.validate_page_size/1` -> `require_visible_instance/2` -> `Attachments.list/2`. `handle_get_attachment_content`: `cast_instance_id/1` -> `require_visible_instance/2` -> `fetch_scoped_attachment_content/4`. `handle_get_attachment_link_content`: `cast_instance_id/1` -> `require_visible_instance/2` -> `verify_link_token/2` -> `check_attachment_id_matches/2` -> `fetch_scoped_attachment_content/4`. `handle_issue_attachment_link`: `cast_instance_id/1` -> `require_visible_instance/2` -> `fetch_scoped_attachment_metadata/3` -> `AttachmentLinks.issue/2`. `handle_delete_attachment`: `cast_instance_id/1` -> `fetch_scoped_attachment_metadata/3` -> `reject_synthetic_instance/2` -> `actor_id/1` -> `Attachments.delete/3`.
No change to `Letflow.Repository.Attachments`, `Attachment`, `AttachmentLinks`, migrations or the authorization module. Moduledoc "Not validated by this route layer" paragraph (`instances.ex:302-308`) is replaced by the new rule (D1, D6).

## 3. Per-route table (requirement 1)

Pipeline position for every route: `Plug.Parsers` -> auth -> `authz_*` permission (403, unchanged, so permission precedes existence and a caller without the permission gets the same 403 for any id) -> handler steps below.

| Route | Current behaviour (F3) | Desired behaviour | Handler step order after the change |
|---|---|---|---|
| R1 upload | 201 for any UUID; orphan rows for unknown id; event written onto a synthetic instance | unknown or synthetic id: 404 identical to other Instances routes; NOTHING written (no artifact row, no attachment row, no event, no quota effect, no scan, no `File.read!`) | `cast_instance_id` (422) -> `actor_id` -> `file` part present? (pattern check only, 422 `missing_file`, no file read) -> **visible-instance check (404)** -> `File.read!` and attrs -> `Attachments.upload/2` (415 / 413 / 422 infected / 503 / 409 quota / 201) |
| R2 list | 200 empty for any UUID | unknown or synthetic id: 404; real instance: unchanged | `cast_instance_id` (422) -> `page_size` parse and range (400) -> **visible-instance check (404)** -> `Attachments.list/2` (cursor 422/410 stay inside the context, after the check, like history's cursor) |
| R3 download | 404 only if the attachment is absent or belongs to another instance id; an orphan under an unknown/synthetic id streams | unknown or synthetic instance id: 404, regardless of the attachment id; real instance unchanged (still 404 for cross-instance, with the REQ-388 audit) | `cast_instance_id` (422) -> **visible-instance check (404)** -> `fetch_scoped_attachment_content` (unchanged) |
| R4 delete | as F3; deletes an orphan (204) under an unknown or a synthetic id | UNKNOWN instance id: unchanged, proceeds exactly like a real instance (orphan row deleted, 204, quota released; missing attachment: 404). SYNTHETIC instance id: 404 (`Response.not_found/1`), the row is NOT deleted, identical to the 404 for a missing attachment. NO visible-instance check (D6) | `cast_instance_id` (422) -> `fetch_scoped_attachment_metadata` (404 when absent or `attachment.instance_id != path id`) -> **`reject_synthetic_instance` (404 only for a synthetic id)** -> `actor_id` -> `Attachments.delete/3` (204) |
| R5 link issue | mints a token for an orphan | unknown or synthetic instance id: 404, no token, no signing-key write | `cast_instance_id` (422) -> **visible-instance check (404)** -> `fetch_scoped_attachment_metadata` -> `AttachmentLinks.issue/2` |
| R6 link-content | token then attachment lookup; serves an orphan | unknown or synthetic instance id: 404 | `cast_instance_id` (422) -> **visible-instance check (404)** -> `verify_link_token` / `check_attachment_id_matches` (expired-or-invalid) -> `fetch_scoped_attachment_content` |

Ordering rationale. The check sits AFTER the cheap, existence-independent validations that the other Instances routes also run first (UUID shape, page size, the `file` part's presence) and BEFORE every write, every read of
caller-supplied bytes and every expensive step. For R1 this means content-type (415), size (413), scan, quota are all evaluated only for a visible instance; for an unknown or synthetic id they cannot be reached (they all live inside `Attachments.upload/2`). R6: the check precedes token verification so a bad token on an unknown instance and on a synthetic instance are the same
answer (404 for both), and existence checking never depends on the token. Consequence to state in the PR: for an unknown id, a bad content type now returns 404 instead of 415. This does not add an oracle (F8: every
`AttachmentsManage` holder can already see real vs unknown via the list route and `GET /instances/:id`), and it is the only ordering under which "nothing stored before the check" and "unknown == synthetic" both hold without splitting `upload/2` (open question O3 offers the alternative).

Delete and legacy orphans (requirement 1, the delete question; supervisor ruling O2, D6). Legacy orphans are `instance_attachments` rows whose `instance_id` names no projection (pre-fix uploads to an unknown id) or a synthetic instance (pre-fix uploads to an entity-type instance). They are value-free for the entity case but occupy tenant storage quota (`get_storage_usage` sums every row, `attachments.ex:649-670`) and `repository_artifacts`. R4 therefore keeps working for unknown-parent orphans (the owner can delete them and the quota is released) and hides synthetic-parent rows. Consequence to state in the PR: orphans under a SYNTHETIC id are not deletable through the API after this change (they were uploaded to a hidden instance; the hide rule wins); the section 10 inventory counts them separately so an operator cleanup can be sized. After this change no new orphan of either kind can be created through R1.

## 4. INV-5 byte-identical analysis (requirement 3)

Equality target (R4 DELETE has its own target, item 5): for each of R1-R3, R5, R6, a request with a SYNTHETIC entity-type instance id equals, in status, body, and the full response header set (masking only `x-request-id` and `date`, `x-trace-id` pinned by the request as in the #2702 walk), BOTH (a) the same route called with a fresh random UUID, and (b) `GET /instances/:id` for a random UUID. Mechanism:
1. Same terminal function: `Response.not_found/1` (constant `Error.not_found()` problem, no detail), no new render clause (D4). Headers are produced by the shared `send_problem` plus pipeline plugs, independent of the route.
2. Same decision path: unknown and synthetic ids are indistinguishable INSIDE the single `instance_visible?` query (one round trip, the anti-join is part of the WHERE clause), so the DB path, query count and error branch are the same, there is no "exists, then is it synthetic" two-step.
3. Order of checks vs the existence-dependent outcomes: permission (403) before; UUID (422), page size (400) and missing `file` part (422) before and independent of existence (so those answers are identical for real, unknown, synthetic ids, as for the other routes); everything that can differ by id (content type 415, size 413 in the context, scan, quota 409, 201, 200 list, 204, token handling, content bytes, denied-access audit) is after. Therefore the only inputs on which an unknown id differs from a real one are the real id's success or its post-check errors, i.e. exactly the oracle `GET /instances/:id` already provides to the same roles (F8).
4. Side effects and timing: nothing is stored, scanned, logged as an infected upload, audited, or appended before the check. The unknown/synthetic path does one `EXISTS` and renders; it does not call `Attachments.*`, `AttachmentLinks.*`, `EventStore.append`, nor `File.read!`. R3/R6 therefore no longer write an `attachment.access_denied` audit row for an unknown/synthetic instance id (REQ-388 audits a denied fetch of a REAL tenant attachment through the wrong instance; with an unknown instance there is no instance to be the wrong one). The same is true for both unknown and synthetic ids, so no timing/side-effect difference between the two exists; whether the audit row should still be written is O4.
5. DELETE (R4, D6) oracle analysis, for SECURITY-REVIEWER. R4 deliberately has no instance-existence step, so the question is what a caller with `AttachmentsManage` can infer. Let U = unknown instance, S = synthetic, V = real visible instance, "missing" = no attachment row with that id and parent id, "orphan" = a row exists whose `instance_id` equals the path id.
   - U+missing vs V+missing: SAME path (cast, one attachment lookup, `Response.not_found/1`), same bytes, same query count. No instance-existence oracle. Test A7b/A7c/A7g.
   - S+missing vs U+missing: same path and same bytes (the lookup returns nothing, the synthetic check is never reached). No oracle for synthetic-vs-unknown. Test A7b.
   - S+orphan: lookup finds the row, `reject_synthetic_instance` answers the same 404 and the row is untouched; indistinguishable by status and bytes from S+missing, but the query count differs by one (lookup + synthetic check vs lookup only). That residual needs a caller who already knows an attachment id AND that it is parented to a synthetic id; it reveals nothing about the entity type. Test A7e; the query-count equality of A7g is asserted only for the `missing` cases, deliberately.
   - U+orphan: 204, the row is deleted. This legitimately succeeds only for a caller who knows BOTH the attachment id (an unguessable UUID, only handed out by the upload response or list) and the parent id. What it leaks: that a row with that id and that parent existed in this tenant. The caller already held both values; V+row also answers 204, so the 204 does NOT distinguish a real parent from an unknown one. It also deletes the row (a mutation the caller is authorized for by `AttachmentsManage`), and then a repeat is 404.
   - Cross-parent probe: the row exists under parent X, the caller names path Y (U, S or V): 404 for all (`attachment.instance_id != path id`), as today, so a known attachment id cannot be used to learn whether Y exists.
   - Side effects invisible to the caller: for U+orphan the follow-up `ATTACHMENT_REMOVED` append fails the active-instance guard and is swallowed (Logger.warning), as today; for V it is recorded.
   Residual accepted if SECURITY-REVIEWER agrees: none that reveals instance existence. If it finds one, use the D6 FALLBACK.
6. Remaining residual, stated for SECURITY-REVIEWER: `Plug.Parsers` already spooled the multipart body (F6) before any of this, equally for all ids; response time for a real id's list/upload is naturally longer than a 404. This is the same residual every Instances route has (a real id's 200 is slower than a 404) and is not an INV-5 violation, which concerns content, not latency.

## 5. Invariants

I1. A client attachment route NEVER returns data, existence or error text distinguishing a synthetic instance from a nonexistent one (extends #2702 I1 to R1-R6).
I2. No attachment route CREATES anything (rows, events, quota use, signing key, audit) for an unknown or synthetic instance id (R1, R5 and the reads never write for them). The one write permitted on an unknown id is R4 deleting an existing legacy orphan row of the caller's own (D6), which releases quota; R4 never writes for a synthetic id. Closes the synthetic-event-log write in F3/R1.
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
| A3b upload checks before it reads the temp file | the dispatched conn carries a `%Plug.Upload{}` whose `path` points to a file that does NOT exist (built directly in `Plug.Test` params, no multipart round trip), instance id unknown AND synthetic: response is the Instances 404 (not a 500 from `File.read!`); control: the same conn with a REAL instance id raises/answers the existing `File.Error` behaviour, proving the path is really unreadable | 201 or a 500 `File.Error` instead of 404 |
| A4 list, nonexistent id | 404 equal to the Instances 404 | 200 empty |
| A5 list, synthetic id | same, equal to A4 | 200 empty |
| A6 list with a pre-existing orphan row under the synthetic/unknown id (inserted through the context) | still 404, orphan not disclosed | 200 with the orphan |
| A7a delete, unknown instance + missing attachment | 404 byte-identical (status, body, headers) to `GET /instances/<random>` 404 | passes on main (guard) |
| A7b delete, synthetic instance + missing attachment | byte-identical to A7a | passes on main (guard) |
| A7c delete, REAL instance + missing attachment | byte-identical to A7a (no instance oracle on delete) | passes on main (guard) |
| A7d delete a legacy orphan under an UNKNOWN instance id (row inserted through `Attachments.upload/2` with a random instance id) | 204; the row is gone; `Attachments.get_storage_usage` drops by exactly that row's `byte_size`; a second delete is the 404 of A7a; a new upload of the same bytes to a real instance then fits where the quota had been full (optional quota-tight variant) | passes on main (guard; MUST keep passing, it is what D6 protects) |
| A7e delete a legacy orphan under a SYNTHETIC instance id (row inserted via the context with the synthetic id) | 404 byte-identical to A7b; the row is still present afterwards; no `ATTACHMENT_REMOVED` event on the synthetic instance | 204 and the row is deleted |
| A7f delete cross-parent: attachment of real instance X, path instance unknown Y, then synthetic S | 404 for both; row still present | passes on main (guard) |
| A7g delete query count | telemetry query count is equal across U+missing, S+missing, V+missing (one query each) | n/a (fails if a visible-instance check or extra read is added before the lookup) |
| A8 download and link-content, nonexistent and synthetic instance id, with an ORPHAN attachment id. Fixture: the orphan row is inserted through the context (`Attachments.upload/2` with the unknown or synthetic instance id; the context still allows it). For R6 mint a VALID token with `AttachmentLinks.issue(attachment_id, tenant_id)` (context call, bypasses the now-guarded R5 route) and an INVALID one (a random string and a token for another attachment id) | R3: 404, no bytes. R6: 404 for the valid AND the invalid token (the check precedes token verification); each equal to the Instances 404 | R3 200 bytes; R6 200 bytes for the valid token, expired-or-invalid for the invalid one |
| A9 link issue, nonexistent and synthetic instance id, orphan attachment id (same context-inserted orphan as A8) | 404, no token, no signing-key write (secret/key row count unchanged) | 200 with token |
| A10 validation order | malformed UUID: 422 for every route, identical to before; list with bad `page_size` on an unknown id: the same 400 as on a real id; upload without a `file` part on an unknown id: the same 422 as on a real id | passes already on main (regression guard; must stay green) |
| A11 equality matrix | for each of R1-R3, R5, R6 and each role that has the permission (TENANT_ADMIN for manage and link routes; TASK_WORKER and TENANT_AUDITOR for the read routes R2, R3, R6; TENANT_AUDITOR holds neither `AttachmentsManage` nor `AttachmentLinksIssue`, so for R1, R5 it is covered by A12): synthetic response == nonexistent response (status, body, headers) == `GET /instances/<random>` response. R6 rows run with a valid AND an invalid token fixture (A8). R4 is covered by A7a-A7c, not by this matrix | 200/201/204 differ |
| A12 permission precedes existence | a caller lacking the permission (AGENT_RUNNER, CANDIDATE, TENANT_AUDITOR on manage routes) gets the same 403 for a real, unknown and synthetic id | passes on main (guard) |
| A13 DB path | query count (telemetry handler on the repo query event scoped to the request, as #2702 T2b(v)) is equal for synthetic and nonexistent ids on R1, R2, R3, R5, R6, and the unknown/synthetic path issues no write (R4 is in A7g) | n/a (fails when a second read or a write is present) |
| A14 control, real instance | active AND a cancelled instance: upload 201 with the same body shape, list 200 with the uploaded item, download 200 bytes, delete 204, link issue 200 | already passes (guards D1's "no status check") |
| A15 predicate unit | `Instances.instance_visible?/2`: true for a real projection (active and cancelled), false for unknown, false for a synthetic id, false for the platform sentinel id, tenant isolation (an id real in tenant A is false in tenant B), raises `KeyError` without `:prefix` | function missing |
| A16 `instance_visible?` propagates a DB error (kills M10) | call it with `prefix: "gh2718_no_such_schema"` (a schema that does not exist): `assert_raise Postgrex.Error` (undefined_table); it must not return `false`. Last statement of its test, because the failed query poisons the sandbox transaction | passes only if the function folds errors; function missing on main |

Existing tests that must change (fallout, TEST-DESIGNER owns): the route suites below dispatch to bare `Ecto.UUID.generate()` instance ids and will 404 after the fix, so each needs a real-instance fixture: `test/letflow/routers/req212_attachments_routes_test.exs`
(~25 sites), `req386_attachment_links_routes_test.exs`, `req388_attachment_access_denial_audit_test.exs`, `tenant_auditor_routes_test.exs` (attachment rows at ~105/424/433), and the `:same`/`:upload` expectations of attachment rows in `instances_synthetic_hidden_test.exs` (lines 55-60) flip to `:not_found`. The context suites (`test/letflow/repository/attachments_test.exs`, `entity_attachments_test.exs`, `engine_complete_task_test.exs`) call the context directly and stay unchanged. A shared helper for "create a real instance for a tenant" should live in test support rather than being copied (open question O8).

Acceptance-to-test mapping (issue #2718):
- "Design note first, re-reading the attachment routes on main (file:line) and the #2702 predicate" -> this file, sections 0 and 1.
- "upload and list for a nonexistent id and for a synthetic id return the same 404 as a nonexistent id on the other Instances routes" -> A1, A2, A4, A5, A11 (delete A7a-A7g, download A8, link A9 extend it).
- "a real instance still works" -> A14 (and the existing req212/386/388 suites after their fixtures use real instances).
- "SECURITY-REVIEWER verdict; REVIEWER verdict; scoped tests, compile with warnings as errors and format check quoted" -> routing section 8.

Mutants the tests must kill:
M1 remove the check from R1 -> A1, A2, A3 fail. M2 remove it from R2 -> A4, A5, A6. M4 remove it from R3, R5 or R6 -> A8, A9 (each route has its own row in A11).
M3a (R4) add a visible-instance check before the lookup (the FALLBACK shape) -> A7d fails (orphan under an unknown id not deleted). M3b (R4) drop `reject_synthetic_instance` -> A7e fails (synthetic orphan deleted). M3c (R4) run the synthetic check before the lookup -> A7g fails (query count differs for S+missing). M3d (R4) answer a different status or detail for synthetic+orphan (for example 403, or 409) -> A7e fails.
M5 use `InstanceVisibility.synthetic?/2` instead of `instance_visible?/2` on R1-R3, R5, R6 -> A1, A4, A8 fail (unknown id passes). M6 use existence only, without `exclude_synthetic` -> A2, A5, A11 fail (synthetic passes).
M7a place the R1 check after `Attachments.upload/2` -> A3 and A13 fail (rows or query count). M7b place the R1 check after `File.read!` (that is, after `build_upload_attrs/4`) -> A3b fails (the unreadable-temp-path conn gives a `File.Error` 500 instead of the 404). M8 return 403, or a different detail/status for synthetic -> A11 fails.
M9 add a status check (only ACTIVE parents) -> A14 (cancelled instance) and A15 fail. M10 fold a DB error into `false` (for example `rescue`) -> A16 fails (no `Postgrex.Error` raised).
M11 drop the explicit prefix -> A15 tenant isolation fails. M12 R6 check after token verification -> A11's R6 row with an INVALID token fails (404 expected, expired-or-invalid returned) and A8.

## 7. Size and files

One PR. Production: `lib/letflow/instances.ex` (+~12, one public function, `ensure_instance_exists` delegates), `lib/letflow/routers/instances.ex` (+~25: helper and six `with` steps; moduledoc paragraph replaced; `upload_attrs_from_conn` split so the `file` part check precedes `File.read!`). No migration, no schema, no config, no permission change. Docs: moduledoc, one anti-pattern line (DOC-UPDATER): "a route taking an instance id must not rely on the context for existence".

## 8. Routing

- SECURITY-REVIEWER: REQUIRED (mandatory for this issue regardless of the issue's "recommended"). Tenant-data path (API route, existence oracle, a write on a hidden synthetic instance closed). Specific rulings asked on the final shapes: the D6 DELETE shape and its oracle analysis (section 4 item 5; fallback documented), the absence of an audit row on the new 404 (O4, ruled), the upload ordering (O3, ruled), the unsupported-configuration policy for an attachment permission without `InstancesRead` (F8).
- REVIEWER: required (scope: all six routes per ruling O1 vs the three the issue names; layering: check in the router, not in the context; moduledoc rewrite; the section 10 inventory SQL is read-only and counts only).
- TEST-DESIGNER / TEST-DESIGN-VALIDATOR / TEST-RUNNER as usual; scoped tests, `mix compile --warnings-as-errors` and `mix format --check-formatted` quoted in the PR.
- ELIXIR-DEV implements.
- FRONTEND-DEV: REQUIRED CHECK (read-only unless a defect is found). `web/` consumes these routes (section 9 O9): `web/src/api/attachments.ts`, `web/src/components/instances/AttachmentPanel.tsx`, `web/src/hooks/useAttachments.ts`, `web/src/pages/instances/AttachmentViewerPage.tsx`, `web/src/pages/tasks/TaskInboxPage.tsx` (inventory supplied by the coordinator; this note did not re-read the files). FRONTEND-DEV must confirm each call only ever passes the id of an existing instance (for example a task's `instance_id`, or the instance open in the detail page), and that a 404 from these routes is handled like the 404 of the other Instances calls rather than shown as a generic failure. The implementer step is not complete until that confirmation is quoted in the PR.

## 9. Open questions for the supervisor (no guesses made)

O1. RULED yes (supervisor): all six routes R1-R6 get the instance rule (R4 with the D6 shape).
O2. RULED (supervisor, CHANGED): DELETE hides a synthetic instance and lets an unknown instance proceed to the attachment lookup (D6). OPEN FOR SECURITY-REVIEWER: confirm the oracle analysis in section 4 item 5, or select the documented FALLBACK (check-first like R5, plus a one-off operator cleanup from the section 10 inventory). Also open: whether to file the cleanup follow-up for orphans under SYNTHETIC ids now (they are undeletable through the API after this change).
O3. RULED accept (supervisor): an unknown id with a disallowed content type or an oversized part answers 404 before 415/413.
O4. RULED accept (supervisor): no `attachment.access_denied` audit row and no new audit reason for an unknown or synthetic instance id on R3/R6.
O5. Closed in part by the validator correction (F8): TENANT_ADMIN and TENANT_AUDITOR are in the golden with both permissions, verified. The other half is a POLICY STATEMENT, not a question (F8): a custom group-granted attachment permission without `InstancesRead` is not a supported configuration and would see an existence signal; accepted, not mitigated here.
O6. ACTION (not a decision): in the implementer step run `mix letflow.permission_matrix --check` and quote the result; expected unchanged (#2612 not triggered, same reasoning as #2702 section 9).
O7. CLOSED: gh2697 is the entity-query restricted-field walker; nothing to carry over.
O8. Test support: introduce a shared "real instance for tenant" helper (where: `test/support/`), or copy the T5 setup into each of the four route suites? (Still open; implementer's call unless the supervisor rules.)
O9. CORRECTED: web consumers DO exist: `web/src/api/attachments.ts`, `web/src/components/instances/AttachmentPanel.tsx`, `web/src/hooks/useAttachments.ts`, `web/src/pages/instances/AttachmentViewerPage.tsx`, `web/src/pages/tasks/TaskInboxPage.tsx` use these routes (inventory from the coordinator, not re-read here). The earlier statement that no consumer was found was wrong. They now receive 404 for an unknown or synthetic instance id. FRONTEND-DEV must check they only ever use existing instances (routing section). The mobile tier is a specification only (`docs/mobile/`), no code uses the routes yet.
O10. NEW, location of the section 10 inventory SQL: this checkout has no `reports/infra-requests/` and no `.sql` file (git ls-files); the `inv-*.sql` convention lives in the supervisor checkout. See section 10 for the proposed paths; supervisor to confirm which one is wanted.

## 10. Deliverable: read-only orphan-attachment inventory SQL (the implementer creates the file; this note specifies path, shape and reading)

Purpose. Size the legacy orphans that the missing existence check allowed: `instance_attachments` rows whose parent instance does not exist, or is a synthetic entity-type instance, plus the storage quota they hold (`get_storage_usage` is `sum(byte_size)` over every row of the tenant schema, `attachments.ex:649-670`, so these bytes count against `Tenant.storage_allowance_bytes`).

Repo location and convention (as found). The convention is the supervisor checkout's `reports/infra-requests/inv-*.sql` (for example `inv-sys-vars-count.sql`, `inv-2524-role-bindings.sql`): a header comment (purpose, output columns, who requested it, which columns were verified against which commit, "run with psql, needs \gexec"), then a single `BEGIN READ ONLY; ... ROLLBACK;`, tenant schemas enumerated from `public.tenant_schemas` joined to `public.tenants`, one generated `UNION ALL` per schema through `format(... %I ...)` and `\gexec`, `to_regclass` guards, counts only. Path to specify: `reports/infra-requests/inv-2718-orphan-attachments.sql` in the supervisor checkout (infra requests are run from there; QA first, prod only on a separate request). letflow-3 itself has neither that directory nor any `.sql` file, so the implementer ALSO commits the same file in this PR at `docs/runbooks/gh2718-orphan-attachments-inventory.sql` (next to `docs/runbooks/*.md`) with a pointer from `docs/runbooks/` text if a runbook entry is written (O10: supervisor picks one canonical location).

Content shape (specification, not code). One statement set:
1. `BEGIN READ ONLY;` as the first statement (also `SET default_transaction_read_only = on;` before it, as `inv-2524-role-bindings.sql` does), `ROLLBACK;` as the last. No other statement type.
2. One query that builds, with `string_agg(format(...), ' UNION ALL ')`, a SELECT per tenant schema from `public.tenant_schemas ts JOIN public.tenants t ON t.id = ts.tenant_id`, restricted to schemas where `ts.migrations_applied_at IS NOT NULL` and `to_regclass` finds all three tables `instance_attachments`, `instance_projections`, `entity_type_instances` in that schema; executed with `\gexec`. This is how it runs per tenant schema: the schema name comes from `tenant_schemas.schema_name`, is quoted with `%I`, and never from input (INV-1/INV-7). With zero tenants `\gexec` runs nothing.
3. Each generated per-schema SELECT returns exactly one row with these columns, all counts and sums, no ids, no file names, no values: `tenant_slug`, `schema_name`, `total_rows`, `total_bytes`, `missing_parent_rows`, `missing_parent_bytes`, `synthetic_parent_rows`, `synthetic_parent_bytes`. Byte columns are `COALESCE(SUM(a.byte_size), 0)` per class (cast to bigint), counts are `COUNT(*) FILTER (...)`.
4. Classification, mutually exclusive and exhaustive, SYNTHETIC FIRST: a row is `synthetic_parent` when `EXISTS (SELECT 1 FROM <schema>.entity_type_instances e WHERE e.instance_id = a.instance_id)`; a row is `missing_parent` when it is NOT synthetic AND `NOT EXISTS (SELECT 1 FROM <schema>.instance_projections p WHERE p.instance_id = a.instance_id)`. (A registry row with no projection, the "winner crashed" state of #2702 F8, therefore counts once, as synthetic.) Everything else is a row with a visible parent and appears only in `total_*`.
5. A final `ORDER BY tenant_slug`.
6. Verify, before commit, the column names against main (`instance_attachments.instance_id`, `byte_size`; `entity_type_instances.instance_id`; `instance_projections.instance_id`; `tenant_schemas.schema_name`, `migrations_applied_at`; `tenants.slug`) and say so in the header, as the existing files do.

How to read the results. `missing_parent_rows > 0`: legacy orphans of the kind R4 can still delete (D6) when the owner knows the attachment id; their bytes are the quota recoverable that way. `synthetic_parent_rows > 0`: orphans under a hidden entity-type instance, NOT deletable through the API after this change; their bytes are the quota an operator cleanup would release, and a non-zero total decides whether to file that follow-up (O2). Both zero everywhere: no cleanup is needed and the follow-up is not filed. `total_bytes - missing_parent_bytes - synthetic_parent_bytes` is the quota legitimately held by real instances. Compare `total_bytes` with the tenant's `storage_allowance_bytes` to see whether orphans put a tenant near its limit.
