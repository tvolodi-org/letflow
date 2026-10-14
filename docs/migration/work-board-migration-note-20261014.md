# Work-board migration note, 2026-10-14

Companion to `docs/migration/decisions/0049-work-board-replaces-letflow-queue.md` and
`docs/agents/protocols/WORK_BOARD.md`. Tracking issue GH #2430 (ISS-1073).

**Nothing in this note has been applied.** No label was created or set on GitHub, no
queue row was edited, and no issue was closed. The supervisor applies the labels at
cutover and triages the blocked rows before it.

## Source and counts

Read on 2026-10-14 from `GET /tasks` of the queue service (bearer token from the
checkout `.env`, not recorded here), single response, plus `gh api` listing of every
issue of the repo (state=all, paginated) for the GitHub state column.

* Rows in the queue: **1119**; done: 1001; **not done: 118** (**61 open, 57 blocked**).
* Rows with a `depends_on`: 31.
* Repository path: `tvolodi-org/letflow` (moved 2026-10-14; the old `tvolodi/letflow` URL redirects). `#N` below are issue numbers in that repository.
* The queue-to-GitHub sync is DOWN since 2026-10-14: rows created after this reading have no issue unless the sole filer filed one directly, and a row going done does not close its issue. The cutover export is diffed against this list by row id; a row whose issue was closed by hand shows as closed here only after it is re-read.
* The supervisor reported 94 non-done on 2026-10-13 (37 open, 57 blocked); the blocked
  count is unchanged (57), the open count grew because new work was filed since (61 now). The list below is the 2026-10-14 reading and is the one to diff.
* Drift since this reading (2026-10-14, after the list was taken): Q-1120 (GH #2505, REQ-445 status drift) was filed and Q-1099 (REQ-468, GH #2475) went done with PR #2504. Rows are not re-counted here; the cutover export is diffed against this list by row id and these two appear as the expected differences.

| Category | Rows |
|---|---|
| A. Open row, GitHub issue open: live work (label at cutover as shown) | 55 |
| B. Open row whose GitHub issue is already closed | 1 |
| C. Issue-owned row, GitHub issue closed (`gh:` reference, row stays open) | 1 |
| D. Rows with no GitHub issue: superseded, not planned (NOT migrated) | 8 |
| E. Supervisor triage, no claimable label (blocked-open, no owner, issue-owned and superseded) | 9 |
| F. Blocked row whose GitHub issue is already closed: nothing to migrate | 44 |
| **Total non-done** | **118** |

Confirmed-live set that gets labels at cutover without further triage: category A (55). Category E (9) carries no claimable label: the blocked rows enter the board only if the supervisor confirms them (else closed as not planned), and the issue-owned rows close in one step when REQ-468..472 (#2475..#2479) land.

## Rules applied

1. **Row ids are kept** in every table so the cutover export of the queue can be diffed
   against this note. A row id is the queue task id (`Q-<id>`, the `id` field).
2. `Q-8` and `Q-10` to `Q-16` (REQ-101 to REQ-108, the August MVP-1 scaffold) have no
   GitHub issue. They are **superseded, not planned**, and are **not migrated**.
3. `Q-1086`, `Q-1094`, `Q-1095` and `Q-1082` are **issue-owned**: filed GitHub-first, the
   GitHub issue body is the authority, the row only carries a `gh:` reference and stays an
   open row. (GH #2439 behind `Q-1082` is closed as not planned: category C. The other
   three are category E: their implementation is superseded by REQ-468..472, #2475..#2479.)
4. Label rule used for the "label at cutover" column: `type:` from the row `task_type`;
   `prio:1` for issues and `prio:2` for requirements, which preserves the queue's
   issues-first order (within one prio the lower issue number goes first, WORK_BOARD.md
   section 3: that replaces the queue's LIFO for issues); `stage:` from the row `stage`
   when present; `state:ready` for an open row, `state:in-progress` plus the proposed
   `claimed:<checkout>` for a locked row, `state:blocked` for a blocked row. The
   supervisor may change any `prio:`.
5. The row title is the queue's; where it differs from the GitHub title, the GitHub title is
   authoritative (three ISS numbers differ and are annotated; Q-1083 / #2441 and Q-1085 /
   #2444 were re-scoped on GitHub after the row was written; the mapping was checked).
6. `Depends on:` shows the dependency rows translated to GH numbers; "(done)" marks a
   dependency whose row is already done, which needs no edge.

## A. Open row, GitHub issue open: live work (label at cutover as shown)

Count: **55**

| Row | Title | Row status | GH issue | GH state | Depends on | Label at cutover |
|---|---|---|---|---|---|---|
| Q-966 | REQ-449: GET /api/v1/me/access: the caller's effective roles, permissions and platform-tenant f... | open | #2237 | open | #2235 (done) | type:requirement, prio:2, stage:S4, state:ready |
| Q-967 | REQ-450: Web: gate navigation and pages on server-reported permissions, split the platform cons... | open | #2238 | open | #2236 (done), #2237 | type:requirement, prio:2, stage:S8, state:ready |
| Q-968 | REQ-451: Make the role charter binding for agents and UAT: mandatory reading, real role names i... | open | #2239 | open | #2233 (done), #2235 (done) | type:requirement, prio:2, stage:S7, state:ready |
| Q-971 | REQ-454: Least privilege for UAT setup: persona seed scripts run as the tenant's TENANT_ADMIN,... | open | #2243 | open | #2235 (done), #2241 (done) | type:requirement, prio:2, stage:S7, state:ready |
| Q-1017 | ISS-1017 (GH title: ISS-1035): Engine: a HUMAN_TASK escalation timer always CANCELS the task; there is no non-cancel... | open | #2325 | open | - | type:issue, prio:1, state:ready |
| Q-1019 | ISS-1019: No UAT scenario covers the D-ESC escalation tasks: meridian (4 escalation tasks + rem... | open | #2330 | open | - | type:issue, prio:1, state:ready |
| Q-1029 | REQ-466: Adopt distinct_from in the vortex production order release and swiftroute shipment app... | open | #2344 | open | #2340 (done), #2341 (done), #2342 (done), #2343 (done) | type:requirement, prio:2, stage:S3, state:ready |
| Q-1030 | ISS-1030: seed_swiftroute_persona_actors.sh: a Keycloak-only persona needs one login/sync into... | open | #2345 | open | - | type:issue, prio:1, stage:S1, state:ready |
| Q-1033 | ISS-1033: redeploy-qa.sh keeps every web-dist-backup-<stamp> directory forever (283 dirs / 472... | open | #2352 | open | - | type:issue, prio:1, stage:S1, state:ready |
| Q-1034 | ISS-1034: web client shows "Forbidden" for the constant separation-of-duties 403 (REQ-463): the... | open | #2355 | open | #2341 (done) | type:issue, prio:1, stage:S8, state:ready |
| Q-1035 | ISS-1035: Engine: a gateway that routes a token straight back to the node it just completed cre... | open | #2359 | open | - | type:issue, prio:1, stage:S3, state:ready |
| Q-1036 | ISS-1036: REQ-457 residual: TENANT_AUDITOR-cannot-change refusal step on the platform scope | open | #2363 | open | - | type:issue, prio:1, stage:S7, state:ready |
| Q-1041 | ISS-1041: Sharded backend gate: slice 9..12 runs 16-30% heavier than the others; rebalance by m... | open | #2380 | open | - | type:issue, prio:1, stage:S1, state:ready |
| Q-1043 | ISS-1043: Letflow exposes no build SHA or version endpoint, so WF-05 preflight cannot confirm w... | open | #2384 | open | - | type:issue, prio:1, state:ready |
| Q-1052 | ISS-1052: BA question (low rank): can the assessor of an escalated review also approve the same... | open | #2396 | open | - | type:issue, prio:1, state:ready |
| Q-1055 | ISS-1055: R5 (ISS-1042 follow-up, low): the worker and slot maps in test/support/tenant_fixture... | open | #2401 | open | - | type:issue, prio:1, state:ready |
| Q-1056 | ISS-1056: V2 (ISS-1042 follow-up, performance-only): add a depth-2 FK-chain test for the in-pla... | open | #2402 | open | - | type:issue, prio:1, state:ready |
| Q-1057 | ISS-1057: Recurrence (ISS-0426 family, low): ExecutorTest AC-5 at test/letflow/engine/lua/execu... | open | #2403 | open | - | type:issue, prio:1, state:ready |
| Q-1060 | ISS-1060: Mobile and Frontend jobs always start on docs-only PRs and gate only at step level, s... | open | #2412 | open | - | type:issue, prio:1, state:ready |
| Q-1061 | ISS-1061: ISS-1030 AC 5 follow-up (parent Q-1012 / GH #2312): wizard-driven realm and user crea... | open | #2414 | open | - | type:issue, prio:1, state:ready |
| Q-1064 | ISS-1064: Structured gate verdict and step timing in handoffs: a closed verdict set for validat... | open | #2418 | open | - | type:issue, prio:1, state:ready |
| Q-1065 | ISS-1065: Batch MINOR issues by area into one WF-03 run: an eligibility rule, a queue claim and... | open | #2419 | open | - | type:issue, prio:1, state:ready |
| Q-1066 | ISS-1066: Security review beyond the diff: SECURITY-REVIEWER lists the assumptions a change rel... | open | #2420 | open | - | type:issue, prio:1, state:ready |
| Q-1067 | ISS-1067: Cut the mandatory reading load: an anti-patterns index checked for coverage, and requ... | open | #2421 | open | - | type:issue, prio:1, state:ready |
| Q-1068 | ISS-1068: Risk-tiered pipeline: a short chain for test-only and docs-only changes, decided by a... | open | #2422 | open | - | type:issue, prio:1, state:ready |
| Q-1069 | ISS-1069: Standing priority owner: PRODUCT-OWNER keeps one ordered backlog toward the user's pr... | open | #2423 | open | - | type:issue, prio:1, state:ready |
| Q-1070 | ISS-1070: Sandbox mode convention follow-up (decided on Q-1062 / GH #2415, KEEP :auto without r... | open | #2424 | open | - | type:issue, prio:1, state:ready |
| Q-1071 | ISS-1071: Stale R-Co portal path in the exam router comments: lib/letflow/modules/exam/router.e... | open | #2425 | open | - | type:issue, prio:1, state:ready |
| Q-1072 | ISS-1072: UI-DESIGNER role (hard gate on GUI changes) and alignment of web/ with the design sys... | open | #2428 | open | - | type:issue, prio:1, state:ready |
| Q-1073 | ISS-1073: Work board on GitHub replaces letflow-queue: GitHub issues are the single store, the... | open | #2430 | open | - | type:issue, prio:1, state:ready |
| Q-1080 | ISS-1080: Onboarding: Idempotency-Key is sent and never read; a resubmit gets 409 'slug already... | open | #2437 | open | - | type:issue, prio:1, state:in-progress, claimed:letflow-4, (supervisor confirms claim; lock holder letflow-4-worker-q1080) |
| Q-1083 | ISS-1083: test/support/template_build_reaper_test.exs:333 flake: 'sweep_template_build_orphans/... | open | #2441 | open | - | type:issue, prio:1, state:ready |
| Q-1090 | ISS-1090: Onboarding wizard: decide what happens to the realm, administrator and client inputs:... | open | #2454 | open | - | type:issue, prio:1, state:ready |
| Q-1091 | ISS-1091: test/scripts/test_parallel_watchdog_orphan_test.exs:321 flake: 'EXIT-trap path: abort... | open | #2457 | open | - | type:issue, prio:1, state:ready |
| Q-1092 | ISS-1092: ISS-1084 follow-up: behavioural replacement for the pool-clamp arithmetic and sampler... | open | #2460 | open | - | type:issue, prio:1, state:ready |
| Q-1096 | ISS-1096: ISS-NEW: Exam: --radius-md is used by exam blocks and elsewhere but not defined in to... | open | #2470 | open | - | type:issue, prio:1, state:ready |
| Q-1097 | ISS-1097: ISS-NEW: Exam session: the submit button has no in-flight guard, so a double click se... | open | #2471 | open | - | type:issue, prio:1, state:ready |
| Q-1098 | ISS-1098: ISS-NEW: Exam session: a late failed save can replace the result screen; the expired... | open | #2473 | open | - | type:issue, prio:1, state:ready |
| Q-1100 | REQ-469: Backend: tenant_type (test / production) on the tenant: migration, set at creation and... | open | #2476 | open | - | type:requirement, prio:2, stage:S4, state:ready |
| Q-1101 | REQ-472: Backend: GET /api/tenant-config carries tenant_type (test / production / null) as one... | open | #2477 | open | #2476 | type:requirement, prio:2, stage:S4, state:ready |
| Q-1102 | REQ-470: Web: read tenant_type from the public tenant-config, hide the test-environment banner... | open | #2478 | open | #2477 | type:requirement, prio:2, stage:S8, state:ready |
| Q-1103 | REQ-471: Vortex production order release: reroute the budget escalation off role-ceo to a new r... | open | #2479 | open | - | type:requirement, prio:2, stage:S3, state:ready |
| Q-1104 | ISS-1104: ISS-NEW: Attachment link issuing: a state-changing route is keyed to the READ permiss... | open | #2480 | open | - | type:issue, prio:1, state:ready |
| Q-1105 | ISS-1105: ISS-NEW: patch_tenant_with_audit lacks the catch :exit that bind_tenant_realm gained... | open | #2483 | open | - | type:issue, prio:1, state:ready |
| Q-1107 | ISS-1107: ISS-NEW: DECISION: pre-fix tenant-chain audit entries still carry platform operator i... | open | #2485 | open | - | type:issue, prio:1, state:ready |
| Q-1108 | ISS-1108: ISS-NEW: Local e2e: the run recipe lives only in a stale inventory doc, and the specs... | open | #2486 | open | - | type:issue, prio:1, state:ready |
| Q-1109 | ISS-1109: ISS-NEW: Grant :PromotionsRead to TENANT_AUDITOR once the stored-tenant check (Q-1011... | open | #2489 | open | #2311 (done) | type:issue, prio:1, state:ready |
| Q-1110 | ISS-1110: ISS-NEW: ci.yml path filter: echo / grep -q under pipefail can SIGPIPE and yield back... | open | #2492 | open | - | type:issue, prio:1, state:in-progress, claimed:letflow-3, (supervisor confirms claim; lock holder letflow-3-worker-q1110) |
| Q-1111 | ISS-1111: ISS-NEW: Promotions: GET /promotions/:id returns teardown_error and failing_assertion... | open | #2494 | open | - | type:issue, prio:1, state:ready |
| Q-1112 | ISS-1112: ISS-NEW: Promotions: a hand-crafted well-prefixed list cursor raises in decode_list_r... | open | #2495 | open | - | type:issue, prio:1, state:ready |
| Q-1115 | ISS-1115: ISS-NEW: Login directory: narrow the blanket rescue in upsert_entry/2 so schema drift... | open | #2498 | open | - | type:issue, prio:1, state:ready |
| Q-1116 | ISS-1116: ISS-NEW: Docs follow-ups of the pending TENANT_ADMIN grant (0048): roles.md TENANT_AD... | open | #2500 | open | - | type:issue, prio:1, state:ready |
| Q-1117 | ISS-1117: ISS-NEW: Pending TENANT_ADMIN grant: four named tests are missing (lf_tok_ never bind... | open | #2501 | open | - | type:issue, prio:1, state:ready |
| Q-1118 | ISS-1118: ISS-NEW: pending_tenant_admin_grants: the partial open index duplicates the unique em... | open | #2502 | open | - | type:issue, prio:1, state:ready |
| Q-1119 | ISS-1119: ISS-NEW: UAT-class note: seeded UAT users need email_verified=true for the first-logi... | open | #2503 | open | - | type:issue, prio:1, state:ready |

## B. Open row whose GitHub issue is already closed

Count: **1**

| Row | Title | Row status | GH issue | GH state | Depends on | Label at cutover |
|---|---|---|---|---|---|---|
| Q-1106 | ISS-1106: ISS-NEW: Design doc req442-per-tenant-login-disclosure-mode.md still describes the ol... | open | #2484 | closed/completed | - | none: GH #2484 already closed (completed); close the row at export |

## C. Issue-owned rows: `gh:` reference, row stays open

Count: **1**

| Row | Title | Row status | GH issue | GH state | Depends on | Label at cutover |
|---|---|---|---|---|---|---|
| Q-1082 | ISS-1082: Onboarding: the progress page never leaves 'pending'; OnboardingProgressPage branches... | open | #2439 | closed/not_planned | - | none: GH #2439 is closed (not_planned); row stays open, `gh:` reference only |

## D. Rows with no GitHub issue: superseded, not planned (NOT migrated)

Count: **8**

| Row | REQ | Title | Row status | GH issue | Label at cutover |
|---|---|---|---|---|---|
| Q-8 | REQ-101 | REQ-101: Provisional MVP-1 web-framework note | blocked | none | none: superseded, not planned (REQ id below); do NOT migrate |
| Q-10 | REQ-102 | REQ-102: Minimal Ecto schema for MVP-1 | blocked | none | none: superseded, not planned (REQ id below); do NOT migrate |
| Q-11 | REQ-103 | REQ-103: Static dev bearer-token auth plug | blocked | none | none: superseded, not planned (REQ id below); do NOT migrate |
| Q-12 | REQ-104 | REQ-104: Generalize ProcessInstance from stored workflow_definitions row | blocked | none | none: superseded, not planned (REQ id below); do NOT migrate |
| Q-13 | REQ-105 | REQ-105: MVP-1 Plug routes (list/create/get/transition), token-gated | blocked | none | none: superseded, not planned (REQ id below); do NOT migrate |
| Q-14 | REQ-106 | REQ-106: Point web/ at running Letflow API | blocked | none | none: superseded, not planned (REQ id below); do NOT migrate |
| Q-15 | REQ-107 | REQ-107: End-to-end MVP-1 smoke test | blocked | none | none: superseded, not planned (REQ id below); do NOT migrate |
| Q-16 | REQ-108 | REQ-108: REVIEWER sign-off gating MVP-1 as done | blocked | none | none: superseded, not planned (REQ id below); do NOT migrate |

## E. Supervisor triage: rows that carry no claimable label

Count: **9**

Rows 1-5 below (Q-887 .. Q-990) are blocked rows whose GitHub issue is still open: confirm live or close as not planned. Q-1085 has no owner. Q-1086, Q-1094 and Q-1095 are issue-owned and no longer ready: their work is tracked by the REQ issues named in the label column.

| Row | Title | Row status | GH issue | GH state | Depends on | Label at cutover |
|---|---|---|---|---|---|---|
| Q-887 | ISS-0887 (GH title: ISS-0892): QA UAT fixtures missing: no swiftroute/meridian/vortex realms, tenants, actors or pro... | blocked | #1994 | open | - | type:issue, prio:1, state:blocked + body `blocked-on:` line; ONLY if the supervisor confirms live, else close as not planned |
| Q-888 | ISS-0888: QA UAT credentials missing: promo proposer accounts, Keycloak master-admin (attachmen... | blocked | #1995 | open | - | type:issue, prio:1, state:blocked + body `blocked-on:` line; ONLY if the supervisor confirms live, else close as not planned |
| Q-890 | ISS-0890: WF-05 full-corpus scenarios not runnable against QA: missing specs, unbuilt features,... | blocked | #1997 | open | - | type:issue, prio:1, state:blocked + body `blocked-on:` line; ONLY if the supervisor confirms live, else close as not planned |
| Q-904 | ISS-0904: Run meridian/vortex definition seed scripts on QA, then re-run preflight and the 9 EN... | blocked | #2039 | open | - | type:issue, prio:1, state:blocked + body `blocked-on:` line; ONLY if the supervisor confirms live, else close as not planned |
| Q-990 | ISS-0990 (GH title: ISS-1008): SwiftRoute shipment approval: no form requires the decision fields or the declared va... | blocked | #2277 | open | - | type:issue, prio:1, state:blocked + body `blocked-on:` line; ONLY if the supervisor confirms live, else close as not planned |
| Q-1085 | ISS-1085: Tenant contract drift: the web Tenant type expects fields the tenant API never sends... | open | #2444 | open | - | none: category E; GH #2444 is "pending product decision, no owner" (feature gap, requirement missing); not ready, no claimable label until the supervisor assigns an owner or a requirement |
| Q-1086 | ISS-1086: distinct-from (REQ-466) is structural, not membership-aware: a single role-ceo holder... | open | #2447 | open | - | category E, issue-owned, `gh:` reference; superseded for implementation by REQ-471 (#2479); closes in one step when those land. No claimable label. |
| Q-1094 | ISS-1094: REQUIREMENT DRAFT: onboarding API stops answering the client_config and realm_config... | open | #2464 | open | - | category E, issue-owned, `gh:` reference; superseded for implementation by REQ-468..472 (#2475..#2479); closes in one step when those land. No claimable label. |
| Q-1095 | ISS-1095: REQUIREMENT DRAFT: tenant_type (test / production) on the tenant, set at creation by... | open | #2465 | open | - | category E, issue-owned, `gh:` reference; superseded for implementation by REQ-468..472 (#2475..#2479); closes in one step when those land. No claimable label. |

## F. Blocked row whose GitHub issue is already closed: nothing to migrate

Count: **44**

| Row | Title | Row status | GH issue | GH state | Depends on | Label at cutover |
|---|---|---|---|---|---|---|
| Q-123 | token_id persisted-vs-derived distinction relies on UUID-castability heuristic, not a type | blocked | #228 | closed/completed | - | none: GH #228 already closed (completed); nothing to migrate |
| Q-127 | Derived idempotency-key suffixes in sub_process.ex have no shared constant/helper (type-safety) | blocked | #255 | closed/completed | - | none: GH #255 already closed (completed); nothing to migrate |
| Q-144 | REQ-077: Promotion pipeline routes (promotion_review.zig, promotions.zig, promotion_read.zig, p... | blocked | #284 | closed/completed | #279 (done) | none: GH #284 already closed (completed); nothing to migrate |
| Q-162 | ISS-0089: VariableSchema.validations_for/3's non-map defence is unreachable — Ecto's :map loade... | blocked | #306 | closed/completed | - | none: GH #306 already closed (completed); nothing to migrate |
| Q-172 | ISS-0107: full-suite-only tenant-schema teardown race hits PromotionTest and PromotionAssertion... | blocked | #359 | closed/completed | - | none: GH #359 already closed (completed); nothing to migrate |
| Q-182 | ISS-0114: Letflow.EngineConcurrencyTest:365 -- 42P01 undefined_table on tenant_<id>.instance_pr... | blocked | #368 | closed/completed | - | none: GH #368 already closed (completed); nothing to migrate |
| Q-183 | ISS-0115: Letflow.IdentityTest:205 -- 42P01 undefined_table on tenant_<id>.users (full-suite on... | blocked | #369 | closed/completed | - | none: GH #369 already closed (completed); nothing to migrate |
| Q-184 | ISS-0116: Root cause of the tenant-schema-disappears-mid-test family is STILL UNKNOWN -- succes... | blocked | #370 | closed/completed | - | none: GH #370 already closed (completed); nothing to migrate |
| Q-200 | ISS-0200: result.summary has no size discipline, and it is the larger half of the artefact | blocked | #391 | closed/completed | - | none: GH #391 already closed (completed); nothing to migrate |
| Q-214 | ISS-0214: Live capture_schema_state reproduction during WF03-ISS0115-20260821 full-suite run: s... | blocked | #424 | closed/completed | - | none: GH #424 already closed (completed); nothing to migrate |
| Q-246 | REQ-117: Wire web/ to Letflow's API -- base URL, auth token, and the login path | blocked | #484 | closed/completed | #480 (done) | none: GH #484 already closed (completed); nothing to migrate |
| Q-254 | REQ-133: End-to-end login -- SPA through Keycloak to an authorized API call | blocked | #492 | closed/completed | #472 (done), #486 (done) | none: GH #492 already closed (completed); nothing to migrate |
| Q-266 | ISS-0266: CheckDeferralStalenessTest T-LIVE-ACTIVITY assertion fails: S8/S9 now active in docs/... | blocked | #524 | closed/completed | - | none: GH #524 already closed (completed); nothing to migrate |
| Q-280 | REQ-112: pack_conflict_resolutions.resolution enum values (:keep_theirs/:take_incoming/:custom)... | blocked | #324 | closed/completed | - | none: GH #324 already closed (completed); nothing to migrate |
| Q-285 | ISS-0285: letflow-queue re-surfaces already-resolved issues as claimable tasks (duplicate githu... | blocked | #562 | closed/completed | - | none: GH #562 already closed (completed); nothing to migrate |
| Q-409 | ISS-0409: ServiceCatalogTest REQ-192 list_all/1 pagination correctness fails in full suite, pas... | blocked | #805 | closed/completed | - | none: GH #805 already closed (completed); nothing to migrate |
| Q-410 | ISS-0410: Letflow.ServiceCatalog.list_all/1 has no scope/tenant filter, causing a test-isolatio... | blocked | #806 | closed/completed | - | none: GH #806 already closed (completed); nothing to migrate |
| Q-416 | ISS-0416: ServiceCatalogTest AC7 narrow-scope test intermittently fails with undefined_table on... | blocked | #813 | closed/completed | - | none: GH #813 already closed (completed); nothing to migrate |
| Q-419 | ISS-0419: CI backend gate: verify/fix wasmex Rust NIF build caching so mix deps.get does not si... | blocked | #817 | closed/completed | - | none: GH #817 already closed (completed); nothing to migrate |
| Q-432 | ISS-0432: Profiling result: the engine's lever is DB round-trip COUNT, not BEAM-side compute --... | blocked | #836 | closed/completed | - | none: GH #836 already closed (completed); nothing to migrate |
| Q-433 | ISS-0433: Scheduler.Poller re-reads Application.get_env config every tick instead of caching in... | blocked | #838 | closed/completed | - | none: GH #838 already closed (completed); nothing to migrate |
| Q-440 | ISS-0440: Make the handoff top-level status enum violation structurally impossible (7th occurre... | blocked | #849 | closed/completed | - | none: GH #849 already closed (completed); nothing to migrate |
| Q-448 | REQ-219 [REPO: tvolodi/letflow-queue] letflow-queue: read-only GET /tasks listing endpoint with... | blocked | #861 | closed/completed | - | none: GH #861 already closed (completed); nothing to migrate |
| Q-456 | ISS-0456: wasm_hang timing flake recurrence -- PR #874 push-event backend gate, plugin_handler_... | blocked | #875 | closed/completed | - | none: GH #875 already closed (completed); nothing to migrate |
| Q-458 | ISS-0458: 10 pre-existing test failures observed during mix letflow.check.test full-suite run (... | blocked | #882 | closed/completed | - | none: GH #882 already closed (completed); nothing to migrate |
| Q-605 | REQ-312: Design decision record for the SolutionPack service_catalog_entries install policy --... | blocked | #1261 | closed/not_planned | - | none: GH #1261 already closed (not_planned); nothing to migrate |
| Q-685 | REQ-359: Extend UAT-RUNNER with explicit environment target, establish QA-environment conventio... | blocked | #1435 | closed/not_planned | #1430 (done) | none: GH #1435 already closed (not_planned); nothing to migrate |
| Q-759 | ISS-0759: No GUI surface exists to view a promotion-review conflict refusal -- no review-queue/... | blocked | #1647 | closed/completed | - | none: GH #1647 already closed (completed); nothing to migrate |
| Q-774 | ISS-0774: Two pre-existing test flakes surfaced during WF02-REQ372-20260921's full-suite runs -... | blocked | #1688 | closed/completed | - | none: GH #1688 already closed (completed); nothing to migrate |
| Q-795 | REQ-406: P1: web/src/modules/types.ts and registry.ts, installed-modules API client, and the ES... | blocked | #1780 | closed/completed | #1777 (done) | none: GH #1780 already closed (completed); nothing to migrate |
| Q-796 | REQ-407: P1: router.tsx and AppShell.tsx build module routes and nav from the installed-module... | blocked | #1781 | closed/completed | #1780 | none: GH #1781 already closed (completed); nothing to migrate |
| Q-875 | ISS-0875: Iss0778PlatformRoleSeedingE2eTest T4: ExUnit.TimeoutError (60s) in Postgrex insert pa... | blocked | #1936 | closed/completed | - | none: GH #1936 already closed (completed); nothing to migrate |
| Q-942 | REQ-434: Decision record 0042 and design for email-first login: a platform tenant-login directo... | blocked | #2190 | closed/completed | #1632 (done), #1286 (done), #1404 (done), #283 (done), #285 (done) | none: GH #2190 already closed (completed); nothing to migrate |
| Q-943 | REQ-434: Decision record 0042 and design for email-first login: a platform tenant-login directo... | blocked | #2191 | closed/completed | #1632 (done), #1286 (done), #1404 (done), #283 (done), #285 (done) | none: GH #2191 already closed (completed); nothing to migrate |
| Q-947 | REQ-438: SPA email-first login screen: credential-free discovery page, ProtectedRoute wiring, l... | blocked | #2195 | closed/completed | #2194 (done), #492, #1632 (done) | none: GH #2195 already closed (completed); nothing to migrate |
| Q-952 | REQ-441: Provider-agnostic mail notifier adapter for the login-discovery tenant-list email: SMT... | blocked | #2206 | closed/completed | #2194 (done) | none: GH #2206 already closed (completed); nothing to migrate |
| Q-953 | REQ-444: Email-first enablement gate (split from REQ-437, BA decision D-D): shipped defaults of... | blocked | #2207 | closed/completed | #2194 (done), #2206, #2205 (done) | none: GH #2207 already closed (completed); nothing to migrate |
| Q-955 | REQ-441: Provider-agnostic mail notifier adapter for the login-discovery tenant-list email: SMT... | blocked | #2213 | closed/completed | #2192 (done) | none: GH #2213 already closed (completed); nothing to migrate |
| Q-956 | REQ-444: Email-first enablement gate (split from REQ-437, BA decision D-D): shipped defaults of... | blocked | #2214 | closed/completed | #2194 (done), #2213, #2205 (done) | none: GH #2214 already closed (completed); nothing to migrate |
| Q-977 | ISS-0977: SmtpSink ordering race: tests read the sink's command transcript before the sink hand... | blocked | #2258 | closed/not_planned | - | none: GH #2258 already closed (not_planned); nothing to migrate |
| Q-1016 | ISS-1016: Engine has no distinct-person rule: one user can complete several approval levels of... | blocked | #2323 | closed/completed | - | none: GH #2323 already closed (completed); nothing to migrate |
| Q-1021 | ISS-1021: Engine: completing a HUMAN_TASK without a required decision key is accepted; variable... | blocked | #2335 | closed/completed | - | none: GH #2335 already closed (completed); nothing to migrate |
| Q-1045 | ISS-1045: Resync simulation fixtures test/fixtures/simulation/meridian/process_claim_intake.yam... | blocked | #2387 | closed/not_planned | #2343 (done) | none: GH #2387 already closed (not_planned); nothing to migrate |
| Q-1046 | ISS-1046: Meridian loan origination: reroute escalate-disburse-loan to a non-approver role (rol... | blocked | #2388 | closed/not_planned | #2343 (done) | none: GH #2388 already closed (not_planned); nothing to migrate |

## Open points for the supervisor

* Category E rows: confirm live or close as not planned (Q-1086, Q-1094, Q-1095: close in
  one step when REQ-468..472 land; Q-1085 needs an owner). Until then they carry no board
  label and the queue export keeps them as it has them.
* Category A rows that are `locked` in the queue today are listed with a proposed
  `claimed:` value taken from the lock holder string; confirm it names the right checkout.
* Category B/F rows need no GitHub action; the queue export closes the rows.
* Per-row `Depends on:` lines for categories A and E are to be written into the issue
  bodies (the queue `depends_on` is the source; it is not editable in the queue itself).
