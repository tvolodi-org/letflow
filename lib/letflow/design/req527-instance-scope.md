# REQ-527 — instance scope (decision 0051 T13): decision record

Status: DECISION ONLY. Task T-0429, GH #2535, requirement REQ-527 (`docs/requirements.yaml`).
No code, migration, route-class change or requirement status change is made by this document.
Facts below were re-derived from the code on `origin/main` at `07a0929c1` (2026-10-25).

## 1. The problem, and what changed since REQ-527 was written

REQ-527 was filed (REQ-519 census, section 5, rows InstancesRead / attachments / start-cancel-...)
when instances "had NO scope node". That premise is stale: decision 0051 T13 already says the
instance carries a `scope_node` "set at instance start, never re-derived from the caller later",
and it has been BUILT on main:

* REQ-531 (GH #3092, merge `c910526dc`): `instance_projections.scope_node_id` (nullable text, FK to
  `scope_node_paths`, migration `20261024100001_add_scope_node_id_to_instance_projections.exs`);
  `INSTANCE_STARTED` carries it; `POST /instances` accepts an optional `scope_node_id`
  (`authorize_start_scope/2` in `lib/letflow/routers/instances.ex`, one 422 for unknown, retired,
  out-of-scope and other-tenant nodes); sub-process children inherit; `GET /instances` and
  `GET /instances/:id` return it. Idempotent start replays compare it (`same_start_request?` in
  `lib/letflow/engine.ex`) and require the same actor.
* REQ-532 (GH #3091, merge `99f285f7a`): `tasks.scope_node_id` is copied from the instance when a
  task row is inserted; the `scoped_approvers_without_task_scope` blocker of REQ-519 AC 10 is gone
  from the gate (`ScopedApprovers` is now an informational count, key `scoped_approvers` in
  `lib/letflow/scope_enforcement/on_gate.ex`).

What is still open, and what this record decides: **no instance route consults the node.** Every
instance-family route is `:tenant_wide`, so under enforcement `on` a scoped principal is denied all of
them with the uniform 403 (REQ-519 design section 5). The real question is therefore not "does an
instance get a node" (yes, decided and built) but "which instance routes become scope-aware, by what
mechanism, and which stay tenant-wide".

## 2. Route census (AC 1)

Derived from `lib/letflow/routers/instances.ex` (declaration order lines ~385-482) and
`test/fixtures/route_scope/tenant_wide_default_routes.txt`. Mounted under `/api/v1`. "Default" means
no `scope:` option: class `:tenant_wide`, source `:default`, listed in the snapshot. Permission roles
are from `docs/roles.md` (PLATFORM_ADMIN omitted; it is never decided by grants, INV-10).

Grep run (snapshot lines of the family):

```
$ grep -n "instances" test/fixtures/route_scope/tenant_wide_default_routes.txt
3:DELETE /instances/:id/attachments/:attachment_id AttachmentsManage
20:GET /instances InstancesRead
21:GET /instances/:id InstancesRead
22:GET /instances/:id/attachments AttachmentsRead
23:GET /instances/:id/attachments/:attachment_id AttachmentsRead
24:GET /instances/:id/history InstancesRead
25:GET /instances/:id/pins InstancesRead
26:GET /instances/:id/timeline InstancesRead
27:GET /instances/storage-usage AttachmentsRead
71:POST /instances InstancesStart
72:POST /instances/:id/advance-timer InstancesAdvanceTimer
73:POST /instances/:id/attachments AttachmentsManage
74:POST /instances/:id/cancel InstancesCancel
75:POST /instances/:id/rebind-pins InstancesCancel
76:POST /instances/:id/reconstruct InstancesCancel
```

| # | Method and path | Permission (roles holding it) | Current class | Handler reads |
|---|---|---|---|---|
| 1 | `GET /instances` | InstancesRead (DESIGNER, OPERATOR, WORKER, TENANT_ADMIN, AUDITOR) | `:tenant_wide` default | `Instances.list/2`: keyset page, `count` is the page length, no total |
| 2 | `GET /instances/:id` | InstancesRead | `:tenant_wide` default | `Instances.get_by_id/2`, one statement |
| 3 | `GET /instances/:id/history` | InstancesRead | `:tenant_wide` default | `ensure_instance_exists` then events page |
| 4 | `GET /instances/:id/timeline` | InstancesRead | `:tenant_wide` default | same two steps |
| 5 | `GET /instances/:id/pins` | InstancesRead | `:tenant_wide` default | `handle_get_pins` |
| 6 | `POST /instances` | InstancesStart (DESIGNER, OPERATOR, TENANT_ADMIN) | `:tenant_wide` default | `handle_create`, body `scope_node_id` checked by `authorize_start_scope/2` |
| 7 | `POST /instances/:id/cancel` | InstancesCancel (OPERATOR, TENANT_ADMIN) | `:tenant_wide` default | `Engine.cancel_instance/3` |
| 8 | `POST /instances/:id/advance-timer` | InstancesAdvanceTimer (OPERATOR, TENANT_ADMIN) | `:tenant_wide` default | `Scheduler.resolve_advance_target/3`, `fire_timer/2` |
| 9 | `POST /instances/:id/rebind-pins` | InstancesCancel (route-declared key) | `:tenant_wide` default | `handle_rebind_pins` |
| 10 | `POST /instances/:id/reconstruct` | InstancesCancel (route-declared key) | `:tenant_wide` default | `Reconstruction.reconstruct_instance/2` write-back |
| 11 | `GET /instances/:id/attachments` | AttachmentsRead (DESIGNER, OPERATOR, WORKER, TENANT_ADMIN, AUDITOR) | `:tenant_wide` default | `handle_list_attachments` |
| 12 | `GET /instances/:id/attachments/:attachment_id` | AttachmentsRead | `:tenant_wide` default | `handle_get_attachment_content` |
| 13 | `POST /instances/:id/attachments` | AttachmentsManage (OPERATOR, TENANT_ADMIN) | `:tenant_wide` default | `handle_upload_attachment` |
| 14 | `DELETE /instances/:id/attachments/:attachment_id` | AttachmentsManage | `:tenant_wide` default | `handle_delete_attachment` |
| 15 | `GET /instances/storage-usage` | AttachmentsRead | `:tenant_wide` default | `Attachments.storage_summary`, a tenant-wide figure |
| 16 | `POST /instances/:id/attachments/:attachment_id/link` | AttachmentLinksIssue | `:tenant_wide` DECLARED (REQ-517 2b, M7) | `handle_issue_attachment_link` |
| 17 | `GET /instances/:id/attachments/:attachment_id/link-content` | AttachmentsRead | `:tenant_wide` DECLARED | `handle_get_attachment_link_content` |

Rows 1-15 are the census of the requirement; 16-17 are listed so the family is complete (the
walk pins them: `{:link_route_reclassified, _}` in `Letflow.Api.RouteScope`,
`test/letflow/api/route_scope_walk_test.exs` `@issue_path`/`@content_path`). The route
declaration order matters (`/storage-usage` and the `/:id/...` suffixes precede `/:id`); no route is
added or moved by this decision.

Other readers of an instance's data outside this router, checked: `grep -rln InstanceProjection lib`
lists the engine, `Instances`, `Tasks` and `routers/tasks.ex`. Tasks carry the instance's node
(REQ-532) so a task route already answers by the same node; webhooks are tenant subscriptions and
are not scope-filtered (0051 T14, accepted). Nothing else serves instance rows to a caller.

## 3. Options for where an instance's scope node comes from (AC 2)

Common to all: a NULL node is `:unresolvable` and stays visible only to a principal holding the
permission tenant-wide (fail closed, T13, `Letflow.Tasks.ScopeResolver` is the model). Existing
instances: the column is nullable and REQ-531 backfills nothing (there is no honest source to
guess from; REQ-532's task backfill changed zero rows), so every instance started before REQ-531
is NULL and invisible to scoped principals. That is the intended migration for every option except
G.

| Opt | Source | Who sets it | Mutable after start | Relation to task node | D7 404 equivalence | Cursor / totals | Scoped-approver blocker (REQ-519 AC 10) |
|---|---|---|---|---|---|---|---|
| A | None used: instances stay tenant-wide although the column exists | n/a | n/a | tasks scoped, instances not | trivially preserved (uniform 403 for scoped) | unchanged | not affected (already removed by REQ-532) |
| B | The instance's own `scope_node_id`, set once at start by the starter (REQ-531, T13 as written), routes consult it | the starting caller: tenant-wide/token any active node of its tenant; scoped caller only a node inside its grant (REQ-531 AC 6); sub-process child inherits | no | identical by construction: task node = copy of instance node at task insert (REQ-532) | one scoped lookup `instance_id = ? AND scope_node_id IN (set)`; out-of-scope and nonexistent run the same statement | scope predicate sits in the one `WHERE`, before `order_by`, `limit` and the cursor seek, so `next_cursor`/`count` reflect scoped rows only | none: REQ-532 already ships the writer |
| C | The process definition's node (definition-level scope) | designer | yes (new definition version) | would have to be re-copied or could disagree with REQ-532's copy | same statement shape | same | contradicts T13 ("per instance at start, not per definition", stated in REQ-531); adds a second writer |
| D | Implicit: the starter's single grant node when the body names none | the grant, not the caller's choice | no | same as B | same as B | same as B | none. Ambiguous for a multi-grant caller, silently re-derives from the caller (T13 forbids "re-derived from the caller later"; at start it is allowed but hides a choice) |
| E | Derived from the instance's tasks (union of task nodes) | engine | yes (tasks come and go) | circular: tasks copy from the instance (REQ-532) | an instance with no open task would flip to unresolvable | totals would move while the instance runs | rejected, circular |
| F | A mutable field a caller may PATCH | caller | yes | tasks would drift from the instance | needs old-and-new check (T12) on a route that does not exist | cursor positions would move rows between scopes | adds a write route and the re-scope hazard for nothing |
| G | B plus a one-off audited admin act that assigns a node to an existing NULL instance | tenant-wide TENANT_ADMIN | once, NULL to node only | tasks of that instance would need re-copy | same as B | same as B | none, but it amends T13's "never re-derived"; see section 8, open question for the owner, not recommended now |

### Recommendation: option B, with a per-route split

Make the instance routes scope-aware on the node set at start (T13 as already written and built);
no new column, no new writer, no decision record changes. Split:

| Becomes scope-aware (`:filter` or `{:resolver, _}`) | Stays `:tenant_wide` |
|---|---|
| 1 `GET /instances` (`:filter`) | 9 `rebind-pins`, 10 `reconstruct` |
| 2, 3, 4, 5 the four by-id reads | 15 `GET /instances/storage-usage` |
| 6 `POST /instances` (start, see below) | 16, 17 attachment link issue and link content (M7) |
| 7 `cancel`, 8 `advance-timer` | |
| 11, 12, 13, 14 instance attachment list/get/upload/delete, scoped by the PARENT instance | |

What a scoped operator can then do (principal holding PROCESS_OPERATOR through a scoped grant, `on`):
list, read, watch (history, timeline, pins), cancel and force-fire a timer on instances whose
node lies in its subtree; start an instance only under a node inside its grant; list, read, upload
and delete attachments of those instances. A scoped TASK_WORKER or TENANT_AUDITOR gets the read
routes and attachment reads of its subtree. A scoped PROCESS_DESIGNER may start under its subtree
(it holds InstancesStart) and read; it cannot cancel (it never held InstancesCancel).

What stays denied to every scoped principal (uniform 403, unchanged body): rebind-pins and
reconstruct (repair and recovery acts that rewrite pins or the projection; scoping them is a
one-line change later with the same resolver, but is not needed to let operators run their work),
the storage-usage figure (one tenant-wide number, a scoped version would need its own scoped sum
and says nothing a subtree operator can use), the attachment link routes (REQ-517 2b pinned them
`:tenant_wide` until an issue-time scoped lookup of the parent exists; this decision lets the
implementation add that lookup, but changing the two routes is a separate decision because the
signed link then outlives the caller's scope), and instances with a NULL node.

Rules the implementation must follow (they are what the security ruling in section 7 rests on):

1. By-id routes: the allowed-node set query runs unconditionally first (`ScopeGate.scope_set/2`),
   then ONE instance lookup with the predicate in its `WHERE` (extend `Instances.get_by_id/2` and
   the `instance_visible?/ensure_instance_exists` helper with a `:scope` option of
   `Types.scope_set`, default `:all`, the shape `Tasks.get_task/2` uses). A malformed UUID keeps its
   422 for everyone (it is independent of whether any instance exists). For cancel and advance-timer
   the scoped lookup runs before body validation and before the engine call.
2. List: `:scope` predicate in the same statement as the filters, before `order_by`/`limit`/the
   cursor seek. The cursor is unsigned and carries only the keyset; the set is recomputed per request
   and never read from the cursor, so replaying another caller's cursor yields only the replayer's
   rows. The response has no total today (`count` = page length); none is added.
3. History, timeline, pins and attachments: the parent instance row is the gate (one lookup with
   the predicate, same 404 on miss) before any events or attachment query runs. No per-event or
   per-attachment node is introduced; their scope IS the instance's (T13 "variables and history carry
   a scope_node" is satisfied by inheritance, no column). An attachment lookup joins or follows the
   scoped parent in the same statement or after the gate, never by attachment id alone.
4. Start (route 6): a scoped caller under `on` MUST name a node inside its grant; naming none, or a
   node outside it, answers the same single 422 as an unknown node (`authorize_start_scope`
   already does the second; the first is new: a scoped caller starting a NULL instance would create an
   instance invisible to itself). Tenant-wide and token principals are unchanged. Because no loaded
   resource exists, the class cannot be `{:resolver, _}`; the implementation adds a small
   route-walk-pinned class (suggested name `:body_node`) or keeps `:filter`-style
   `require_scope_applied` with `authorize_start_scope`; the choice is the implementer's, but the
   walk must pin the route in `@expected_*` lists like the task routes.
5. The `Enforce` before-send check (`require_scope_applied`) already makes a resolver or filter route
   that never applied its scope a loud 500, so a handler that forgets the predicate fails closed.

## 4. Alternatives rejected, and why

* A (stay tenant-wide): safe but makes `on` useless for the operator persona; REQ-519 design
  section 6 item 2 names instance scope as a precondition for `on` to be useful, and the writer already
  exists. Rejected as a final state; remains the behaviour until the implementation requirements land.
* C, D, E, F: see the table; each re-derives or mutates scope against T13, adds a second writer, or is
  circular with REQ-532.
* G: not rejected on security grounds but it amends T13 ("never re-derived") and needs an owner
  decision (section 8).
* Scoping `rebind-pins`/`reconstruct`/`storage-usage`/link routes now: widens the first slice with
  routes whose scoped semantics need their own argument (recovery tool; tenant aggregate; signed
  link lifetime) and gives a scoped operator nothing it needs to run its instances.

## 5. Implementation requirements this decision calls for (AC 4, none filed here)

Each is one layer, sized for one change, owner ELIXIR-DEV, `depends_on` REQ-527, each with its own
SECURITY-REVIEWER code verdict (tenant-data path). To be filed by the requirement analyst.

* IR-1 Instance read plane: routes 1-5. `:scope` option on `Instances.get_by_id/list/history/timeline`
  and the existence helper; `Letflow.Instances.ScopeResolver.instance_scope/1` (pure, `{:node, id}` or
  `:unresolvable`, mirror of `Letflow.Tasks.ScopeResolver`); declare `:filter` on `GET /instances` and
  `{:resolver, ...}` on the four by-id routes; remove the five snapshot lines; extend the expected
  filter/resolver lists in `Letflow.Api.RouteScope`.
* IR-2 Instance write plane: routes 6, 7, 8. Scoped lookup before body validation for cancel and
  advance-timer; the start rule of section 3 item 4 including the new class and its walk pin; remove
  the three snapshot lines.
* IR-3 Instance attachments: routes 11-14, gated by the parent instance row; remove four snapshot
  lines. Routes 9, 10, 15, 16, 17 keep their lines and the link pins.

Each carries as acceptance criteria: the scoped-principal query/aggregate-free list test (page
and `next_cursor` exclude other rows), the replayed-foreign-cursor test, the byte-identical
out-of-scope versus nonexistent response and equal Ecto query count (telemetry, no timing), the
NULL-node instance invisible to a scoped caller and visible to a tenant-wide caller, a cross-tenant
negative test (INV-10: tenant B's node or instance id through tenant A's route), the unchanged
403 for a principal lacking the coarse permission, and the unchanged 403 for rows 9, 10, 15, 16, 17.

## 6. Tests that pin today's behaviour and must change with the implementation (not now)

Found with `grep -rn "/instances" test/letflow/api/scope test/letflow/plugs/authorize_scope_on_test.exs
test/letflow/api/route_scope_walk_test.exs test/letflow/routers/attachment_link_scope_test.exs
test/letflow/api/route_scope_resolver_test.exs` and `grep -rln "tenant_wide_default_routes\|InstancesRead" test`:

* `test/fixtures/route_scope/tenant_wide_default_routes.txt` (lines listed in section 2; it is exact, the walk
  fails on a stale or missing line).
* `test/letflow/api/route_scope_walk_test.exs` (default-sourced `/instances` target at ~139 and the link
  pins `@issue_path`, `@content_path`: the link pins must stay green).
* `test/letflow/api/route_scope_resolver_test.exs` (~92, ~142: uses `Routers.Instances` rows as the
  "unexpected" fixtures; they stay unexpected only until the expected lists gain instance routes, so
  these fixtures need another router).
* `test/letflow/routers/attachment_link_scope_test.exs` (~345 "`GET /instances/:id`: a scoped-only caller gets the
  same 403 for any id": true today, false after IR-1 for a caller whose node covers an instance; re-point
  to a route that stays tenant-wide or to a caller with no covering grant).
* `test/letflow/api/roles_matrix_parity_test.exs` and `authorization_*_test.exs` reference InstancesRead
  as a permission, not a class: no change expected, to be confirmed by running them.

## 7. Rulings (AC 3)

Security ruling by the designer on option B, to be re-checked by SECURITY-REVIEWER on every
implementation PR (this task is docs-only and touches no route):

* INV-1 (tenant isolation): HOLDS. The node predicate is an ADDITIONAL narrowing inside the existing
  schema-per-tenant `:prefix`; `scope_node_id` is an FK into the same tenant's `scope_node_paths`, so another
  tenant's node cannot be stored or matched. No path is made exempt: timers, sweepers and the engine keep
  acting on the instance's own node (T14); this decision gives them no HTTP-caller scope.
* INV-5 (404 equals 404): HOLDS under rules 1-3 of section 3: scope check before resource validation, one
  scoped lookup, allowed-set query unconditional, byte-identical body and headers, equal query count,
  proven by a telemetry-count test per route. Start refusals are one 422 for unknown, retired,
  out-of-scope, other-tenant and (for a scoped caller) missing nodes. Idempotent start replay cannot expose a
  foreign instance: `same_start_request?` requires the same actor and the same `scope_node_id`.
* INV-6 (new data-access path proves its scoping): each of IR-1..IR-3 adds a scoped statement and MUST ship
  the proof tests listed in section 5; `Enforce.require_scope_applied` is the backstop that turns a forgotten
  predicate into a 500, not a leak.
* Accepted and documented residual risks: (a) a NULL-node instance (every pre-REQ-531 instance, every
  system-started one) is invisible to scoped operators, so a tenant moving to `on` with in-flight work needs
  a tenant-wide admin to manage those until they finish (G is the open remedy); (b) webhooks and outbound events
  remain unfiltered tenant subscriptions (T14); (c) history exposes the actor and payload of events of an instance the
  caller may already read; restricted-field masking is unchanged (`exclude_hidden_event_types`, `public_variables`);
  (d) a tenant-wide caller can start an instance under any active node: that is the intended admin power.

Consistency with decision records: no record is contradicted. B is T13 and T14 as written. Nothing here
edits `docs/migration/decisions/`.

## 8. Findings and open points for the owner

* Stale text: REQ-527's description and REQ-519 design section 5 ("instances have NO scope node") predate
  REQ-531/532 (merged). `docs/requirements.yaml` shows REQ-531/532 `pending`; status flips are phase 2.
* Proposed clarification to 0051 T13 (NOT an amendment of its rule; owner may record it): (1) the scope of
  history, timeline, pins and attachments is the instance row's, by inheritance, no per-event column; (2) a
  scoped starter under `on` must name a node. The designer edits no record.
* Open owner decision, G: assigning a node to an existing NULL instance would amend T13's "never re-derived"
  and would be the only way to hand pre-existing in-flight instances to scoped operators. Not recommended now.
* Open sub-decision for the implementer of IR-2: name and shape of the start-route class (section 3 item 4).

## 9. Documentation to update when each implementation PR merges (AC 5)

Per route, in the implementation PR that reclassifies it. Cite symbols, not line numbers.

| Routes | `docs/roles.md` | Runbook / other docs |
|---|---|---|
| 1-5 (IR-1) | in the scoped-enforcement section, list instance reads as scope-aware (scoped holder sees its subtree, NULL-node instances tenant-wide only); remove instance reads from the "denied under `on`" text | `docs/runbooks/` scope-enforcement or enforcement-flip runbook (the one that carries the REQ-519 ON_IN_PRODUCTION text, find with `grep -rln "scope_enforcement" docs/runbooks`): what a scoped operator can read; the `Letflow.Routers.Instances` moduledoc route table and its "Route ordering" note |
| 6, 7, 8 (IR-2) | start under own subtree only, node required for scoped starters; cancel and advance-timer within subtree | same runbook: start-node rule and the single 422; moduledoc of `POST /instances` `scope_node_id` section |
| 11-14 (IR-3) | attachments scoped by parent instance | runbook attachment section; `docs/runbooks/gh2718-orphan-attachments-inventory.sql` header if it claims instance attachment visibility |
| 9, 10, 15, 16, 17 | state explicitly that they remain tenant-wide-only for scoped operators and why | the same runbook paragraph |
| all | the "Known limitation" text on instance routes (REQ-519 design section 5 rows) is rewritten; the NULL-node and in-flight-instance note of section 7(a) is added | `docs/anti-patterns.md` only if a new mistake pattern is found |
