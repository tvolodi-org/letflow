# 0064 -- Org-relative task assignment: an assignee resolver registered through the module Catalog, not in the engine

Status: PROPOSED by the designer of GH #3153 (REQ-538 slice 0, task T-0458), 2026-10-25. Needs
SECURITY-REVIEWER and REVIEWER sign-off, and the owner's answer to the open questions OQ-1 and OQ-2
(see Sign-off). Changes no code: every implementation slice is its own requirement (D8).

Date: 2026-10-25

Related: [0050](0050-foundation-modules-org-catalog-and-reference-contract.md) D1, D2, D3.6, D7, D8;
[0051](0051-org-scoped-role-grants-and-enforcement.md) Q3, the F1 candidate rule, F3, T3, T5, T9,
T13, T14, D10, D11; [0061](0061-engine-lock-order-platform-invariant.md) (engine lock order);
REQ-045 (no process per workflow instance); REQ-531 and REQ-532 (instance and task scope node).

## Sources

The files opened to write this record:

- `docs/migration/core-roadmap-20261014.md`, Wave 2 row "Org-relative task assignment (resolver via
  the module Catalog, not in the engine)", decision-record column "yes (new)".
- `docs/migration/decisions/0050-foundation-modules-org-catalog-and-reference-contract.md` (D1: `org`
  has `org_unit` and `org_unit_membership` only, `position` not built; D3.6: references are
  declarative; D7: `managed_by` lock; D8: tree depth bound of 12).
- `docs/migration/decisions/0051-org-scoped-role-grants-and-enforcement.md` (Q3 "Task candidates":
  a resolver hook "comes later through the module Catalog (Letflow.Modules.Catalog), not in the
  engine"; the F1 rule; F3 "resolver hook"; T3, T5, T9, T13, T14; D10, D11).
- `docs/migration/decisions/0061-engine-lock-order-platform-invariant.md` (lock order).
- `lib/letflow/modules/catalog.ex` (`write_handler/2`, `resolve_write_handler/3`,
  `call_write_handler/4`, `validate/2` with `validate_write_handlers/2`).
- `lib/letflow/engine/task_activation.ex` (`resolve_assignee/1`, `insert_attrs/4`,
  `insert_newly_pending`, `insert_newly_pending_from_existing_records`, `insert_task_row/4`,
  `do_insert/4`, `record_task_create_audit/3`).
- `lib/letflow/tasks.ex` (`list_tasks/2`, `get_task/2`, `in_scope/3`, `f1_allowed?/3`,
  `f1_recheck/3`, `apply_claim`, `apply_completion_authz`, `assign_task/3`, `filter_by_scope/2`).
- `lib/letflow/tasks/scope_resolver.ex` (`task_scope/1`).
- `lib/letflow/routers/tasks.ex` (how the task routes reach the scope decision).
- `priv/repo/migrations/20260818110003_create_tasks.exs` (`assignee_type` is a nullable string).
- `test/letflow/tasks/scope_node_id_no_writer_scan_test.exs`, `test/letflow/tasks/f1_context_test.exs`,
  `test/letflow/modules/catalog_write_handlers_test.exs`, `test/letflow/routers/tasks_scope_http_test.exs`,
  `test/letflow/routers/tasks_scope_inv5_http_test.exs`.
- `docs/requirements.yaml`, entries REQ-532 and REQ-538.

## Context

Decision 0051 Q3 fixes only the interim task-candidate rule (a task carries a scope node, and
candidates are filtered by it) and defers a true resolver hook ("manager-of ... comes later through
the module Catalog, not in the engine"; Follow-up F3). Decision 0050 D1 gives the `org` module two
entity types, `org_unit` (a tree by parent id) and `org_unit_membership` (user to unit), and states
that `position` is not built. So "the requester's department head" has no data source today, and the
engine has no place to ask for one. This record decides how a task's assignee is resolved relative to
the requester's place in the org tree before any code is written.

Facts on main that the decisions rest on:

- `TaskActivation.resolve_assignee/1` reads `assignee_type` and `assignee_ref` from the HUMAN_TASK
  node's attributes and returns nil only when both keys are absent. An explicit `assignee_type` is
  passed through unchanged.
- `tasks.assignee_type` is nullable (`add :assignee_type, :string` in the create-tasks migration), and
  a nil assignee is a normal task shape.
- In `lib/letflow/tasks.ex`, `apply_claim(_, %Task{assignee_type: nil}, ...)` lets any claimant take
  the task, and `apply_completion_authz(%Task{assignee_type: nil}, _, _)` returns `:ok`.
  `apply_claim` ends in a catch-all `{:error, :not_claimable}`. `apply_completion_authz` has clauses
  for nil, "USER", "GROUP" and "ROLE" only, and no catch-all.
- The instance has no requester field: `grep -n "started_by\|requester\|initiator" lib/letflow/engine.ex
  lib/letflow/engine/instance_state.ex` prints nothing.
- Task visibility is decided by the task's scope node: `ScopeResolver.task_scope/1` returns
  `{:node, id}` for a non-empty `scope_node_id`, else `:unresolvable`; `filter_by_scope({:nodes, ids})`
  and the `{:nodes, ids}` query of `in_scope/3` match `t.scope_node_id in ^ids`.
- `TaskActivation.insert_task_row/4` is the only writer of `tasks.scope_node_id`, pinned by
  `scope_node_id_no_writer_scan_test.exs` (a security merge condition of REQ-518).

## Decisions

### D1. Resolver contract

**Decision.**

- A module registers an assignee resolver in its manifest under a new key `:assignee_resolvers`: a
  list of specs `%{name, relations, function: {Module, :fun}}`, the same shape as `:write_handlers`
  and `Letflow.Modules.WriteHandlerSpec`.
- `Letflow.Modules.Catalog` gains, in a later slice (D8, 1c):
  - `assignee_resolver/2` (module id, resolver name) returning `{:ok, descriptor}` or
    `{:error, :not_found}`. The descriptor carries no function, as `Catalog.WriteHandler` does not.
  - `call_assignee_resolver/3`, which re-resolves the resolver by module id and name and is the only
    place that applies resolver code. It copies `call_write_handler/4`.
  - matching rules in `validate/2`, as `validate_write_handlers/2` does: `{:invalid_assignee_resolvers,
    value}`, duplicate name, function exported, function inside the module's own namespace.
- Input: ONE map, built by core and never by the module:
  `%{prefix: <tenant prefix, supplied by core>, scope_node_id: <instance scope node of REQ-531/532> | nil,
  requester_id: <user uuid>, relation: "department_head"}`. The module cannot pass or change the prefix.
- Output: `{:ok, [user_id]}` (non-empty; at most one user for `department_head`; the list shape is kept
  for later relations) or `{:refuse, reason_atom}`. Any other value is malformed (D4).
- The instance carries no requester today. Slice 1b carries `requester_id` on the instance, set at
  start and never re-derived (like the scope node, T13), before a resolver can be called.
- Node syntax: a HUMAN_TASK node attribute `assignee_type: "RESOLVED"` with
  `assignee_ref: "<module_id>.<resolver>:<relation>"`, read by a new branch of
  `TaskActivation.resolve_assignee/1`.

**Reasons.** The write-handler registration is the existing, security-reviewed pattern for module code
that core calls: a descriptor without a function, a re-resolution by id at call time, and validation at
install. Copying it adds no new trust model. Core building the input is what keeps INV-1 out of the
module's hands. A refusal value next to the user list lets a module say "no answer" without raising.

**Source.** 0051 Q3 and F3; `lib/letflow/modules/catalog.ex` (`write_handler/2`, `resolve_write_handler/3`,
`call_write_handler/4`, `validate_write_handlers/2`); `lib/letflow/engine/task_activation.ex`
(`resolve_assignee/1`); `lib/letflow/engine.ex` and `lib/letflow/engine/instance_state.ex` (no requester field).

### D2. Engine boundary

**Decision.**

- `Letflow.Engine` stays free of org logic. Resolution goes through a resolver registered via
  `Letflow.Modules.Catalog`; the engine never names `org_unit`, `org_unit_membership`, an org module id,
  a hierarchy walk or a "head".
- Single call site: one private function in `lib/letflow/engine/task_activation.ex`, called from both
  task-creation paths (`insert_newly_pending` and `insert_newly_pending_from_existing_records`) just
  before `do_insert/4`, the one task-row insert. That function calls `Catalog.call_assignee_resolver/3`
  and nothing else org-shaped; it passes only the generic relation string read from the node.
- Source-scan test a later slice adds (slice 1c): `Letflow.Engine.NoOrgLogicScanTest` in
  `test/letflow/engine/no_org_logic_scan_test.exs`. It reads `lib/letflow/engine.ex` and every file under
  `lib/letflow/engine/`, and fails on any match of `org_unit`, `org_unit_membership`, the `"org"` module
  id or `Letflow.Modules.Org`.
  - Pass: the files as built pass, and the test asserts it scanned more than zero files (a stale path
    must not pass while checking nothing).
  - Seeded-violation fail: the test runs the same scanner over a string or temporary file containing
    `org_unit_membership` and asserts that the scanner reports it, so the scan cannot pass vacuously.
- Lock order (0061): the resolver is read-only (plain SELECT, no `FOR UPDATE`, no write) and runs before
  the `task.create` audit takes the audit chain row, so it adds no lock to the order. Slice 1c or 1d shows
  this in a query-log or forced-overlap test.
- Containing a raise inside the engine transaction: a raise inside Postgres leaves the transaction
  aborted, and an Elixir `rescue` does not recover it. The Catalog wrapper runs the resolver inside a
  fixed-text SAVEPOINT (no interpolation, INV-7) and rolls back to it on raise, exit or throw. The time
  bound is `SET LOCAL statement_timeout` for the call (no in-process timer, since REQ-045 forbids a
  process per instance), together with the tree depth bound of 12 (0050 D8). The savepoint requirement is
  decided here; the exact mechanism is for the slice 1c design to prove in a test.

**Reasons.** REQ-045 makes the engine a plain transactional context, and 0051 Q3 puts org-relative
resolution in modules. One call site keeps the indirection reviewable, and a source scan keeps it from
eroding. `TaskActivation` lives under `lib/letflow/engine/`, so the scan covers the call site itself.

**Source.** REQ-045 (`Letflow.Engine` moduledoc, "Process-vs-row decision"); 0051 Q3; 0050 D8; 0061;
`lib/letflow/engine/task_activation.ex`; `lib/letflow/modules/catalog.ex` (`call_write_handler/4`).

### D3. Data source of "head"

**Decision.** Provisionally (a): a nullable `head_user_id` field on `org_unit`, pending the owner's
confirmation (OQ-1). Options considered:

- (a) a nullable `head_user_id` on `org_unit` (recommended);
- (b) a `membership_role` ("member" or "head") on `org_unit_membership`;
- (c) the `position` type of 0050 D1.

The head need not be a member of the unit, but the resolver requires that the user exists and is active
in the tenant; a `head_user_id` that is not a tenant user is a malformed result (D4). This is a change to
the org module's entity type, so it is its own requirement (D8, slice 1a). No code slice is written until
the owner confirms.

**Reasons.** (a) gives one value per unit by its shape, so "two heads" cannot occur; it adds no entity
type (0050 D1 keeps `position` unbuilt until a requirement consumes it); it is one field on one existing
type. (b) needs a uniqueness rule (one head per unit) that the declarative module types cannot express.
(c) builds a whole type for one relation. References are declarative only (0050 D3.6), so `head_user_id`
is not FK-enforced and the resolver validates it.

**Source.** 0050 D1, D3.6, D7; REQ-538 open question 1.

### D4. Fail-closed rule

**Decision.**

State. A failed resolution creates the task with `assignee_type = "UNRESOLVED"`, `assignee_ref = nil`,
and `status` `PENDING`. No new status value and no migration. The state must not be a nil assignee type:
`apply_claim` lets any claimant take a nil-assignee task and `apply_completion_authz` returns `:ok` for
it. "UNRESOLVED" falls to `apply_claim`'s catch-all `{:error, :not_claimable}`. `apply_completion_authz`
has no catch-all, so slice 1d adds an explicit refusing clause for "UNRESOLVED" (else completion would
raise, INV-8) with a test.

Visibility (option (b): the task keeps the instance's scope node). The task row keeps `scope_node_id`
equal to the instance's node: REQ-532 AC1 is unchanged, the single writer
`TaskActivation.insert_task_row/4` is unchanged, `Task.audit_state/1` is unchanged so REQ-532 AC6 stays
true, and the node is not copied into any audit. Instead slice 1d treats `assignee_type = "UNRESOLVED"`
exactly like a NULL node for every principal that is not tenant-wide, in three places. Each covers
different paths (the handlers in `lib/letflow/routers/tasks.ex` call `ScopeGate.scope_set_for_role` or
`scope_set`, then `Tasks.get_task/2` or `Tasks.in_scope/3`; `ScopeResolver.task_scope/1` is called for a
decision only from `Tasks.f1_allowed?/3`), so dropping any one leaves its paths open:

1. A first clause `def task_scope(%Task{assignee_type: "UNRESOLVED"}), do: :unresolvable` in
   `ScopeResolver.task_scope/1`. It covers only the scoped branch of `f1_allowed?/3`: the in-transaction
   F1 recheck of claim and complete (`Tasks.f1_recheck/3`, called from the engine) and the D7 check.
2. The predicate below inside `filter_by_scope({:nodes, ids})`. It covers GET /tasks and GET /tasks/inbox
   (`list_tasks/2`) and GET /tasks/:id (`get_task/2` applies `filter_by_scope` with the handler's set).
3. The same predicate inside the `{:nodes, ids}` query of `in_scope/3`. It covers the pre-check of
   POST /tasks/:id/complete, /claim, /assign and /reassign.

The predicate must be NULL-safe. In SQL `NULL != 'UNRESOLVED'` is NULL, not true, so a bare
`t.assignee_type != "UNRESOLVED"` would hide every unassigned task from every scoped principal. The
predicate is the Ecto expression `(is_nil(t.assignee_type) or t.assignee_type != "UNRESOLVED")`, ANDed
with the existing `t.scope_node_id in ^ids`: plain Ecto operators, no `fragment`, so INV-7 is not
involved. The `task_scope/1` clause is a pattern match on the string and never matches nil.

None of the three writes or names a new `scope_node_id` use, so the function labels in `@task_ledger` of
`scope_node_id_no_writer_scan_test.exs` (`def in_scope/3`, `defp filter_by_scope/2`,
`def task_scope/1`) stay the same and that test stays green with no edit. Any edit to that ledger is a
SECURITY-REVIEWER decision and is not part of this record.

Tenant-wide holders are unaffected: `:all` scope and the `:unfiltered` assignee scope still see the task.
The exclusion applies to every scoped principal: TASK_VIEW, TASKS_LIST and TASK_WORKER holders alike.

The way out is the existing assign path: a tenant-wide holder assigns (the `assignee_ref IS NULL` guard
admits it), which sets `assignee_type = "USER"` and `assignee_ref` and nothing else. Once the type is no
longer UNRESOLVED, the unchanged node makes the task visible to the assignee's scope as for any task. No
node restore, no second writer, no instance read in `tasks.ex`. The task is never re-resolved (D6).

Authored states are refused. Slice 1d makes definition validation (or `resolve_assignee/1`) refuse an
authored `"UNRESOLVED"` (only the engine sets it) and accept `"RESOLVED"` only with a well-formed
`assignee_ref` (`<module_id>.<resolver>:<relation>`).

Audit. The existing `task.create` entry (`record_task_create_audit/3`) carries the state. Slice 1d adds
one closed key, `assignee_reason`, to its `after_state`, only when the task is UNRESOLVED, taking exactly
one of the six codes of the table below. The key is added by the create-audit call in `TaskActivation`,
not by `Task.audit_state/1`, so the payload of an ordinary task stays byte-identical (REQ-532 AC6). The
state itself is `assignee_type`; there is no separate marker key, no free text, no org id and no scope
node in the reason. A resolver reason atom outside the closed set maps to `resolver_failed`.

| case | task state | who can see the task | audited reason (`assignee_reason`) |
|---|---|---|---|
| no resolver registered for the relation | PENDING, `assignee_type` UNRESOLVED | tenant-wide holders only; every scoped principal gets the not-found answer | `no_resolver` |
| resolver returns no user (`{:ok, []}` or `{:refuse, _}`) | PENDING, UNRESOLVED | tenant-wide holders only | `no_user` |
| requester without membership (or without an org unit) | PENDING, UNRESOLVED | tenant-wide holders only | `no_membership` |
| unit without head | PENDING, UNRESOLVED | tenant-wide holders only | `no_head` |
| walk reaches the root without a head | PENDING, UNRESOLVED | tenant-wide holders only | `root_without_head` |
| resolver raises, exits, throws or times out, or returns a malformed value (not `{:ok, [uuid]}`, more than one user for `department_head`, a user not in the tenant, a cycle or depth over 12) | PENDING, UNRESOLVED | tenant-wide holders only | `resolver_failed` |

No case falls back to an unrestricted or default assignee: not a default person, not a role queue, not a
nil assignee, not tenant-wide worker routing. The engine transaction never aborts because of a resolver
failure (INV-8). The reason code never tells a caller who is not tenant-wide whether a unit or a head
exists, because only tenant-wide principals see the task at all (INV-5).

Tests that must stay green unchanged in slice 1d:

- `test/letflow/tasks/scope_node_id_no_writer_scan_test.exs`;
- the REQ-532 creation and audit tests (task node equals instance node; `task.create` audit shape
  byte-identical for ordinary tasks);
- the existing `task_scope` and `f1_allowed?` tests (`test/letflow/tasks/f1_context_test.exs`);
- `test/letflow/routers/tasks_scope_http_test.exs` and `test/letflow/routers/tasks_scope_inv5_http_test.exs`,
  which exercise scoped principals on tasks inserted with `assignee_type: nil` and would catch a predicate
  that is not NULL-safe.

Tests slice 1d adds (route level unless stated; IDs for the slice's test plan):

- **V1** a scoped TASK_WORKER whose subtree covers the node, and a scoped TASK_VIEW holder, get the same
  404 as for a nonexistent id on GET /tasks/:id, claim, complete and assign, and the UNRESOLVED id is
  absent from both GET /tasks and GET /tasks/inbox.
- **V2** a tenant-wide holder sees and assigns the task.
- **V3** after assign, the scoped assignee sees the task.
- **V4** NULL-safety pin: in the same fixture, a task with a NULL `assignee_type` on the covered node is
  still listed in GET /tasks and GET /tasks/inbox, returns 200 on GET /tasks/:id and is claimable by the
  same scoped TASK_WORKER; a scoped PROCESS_OPERATOR covering the node still passes `in_scope/3` on assign.
- **V5** unit: the `tasks.scope_node_id` of an UNRESOLVED task equals the instance's node.
- **V6** unit: `ScopeResolver.task_scope/1` gives `:unresolvable` for UNRESOLVED with a node, and
  `{:node, id}` for a nil `assignee_type` with a node.
- one test per row of the table above, the refusing `apply_completion_authz` clause, and the refusal of
  authored "UNRESOLVED" and of "RESOLVED" with a missing or malformed ref at definition create.

**Reasons.** A nil assignee is the open shape on main, so reusing it would fail open. A new
`assignee_type` value needs no migration (the column is a free string) and lands in the catch-all of
`apply_claim`. Keeping the instance node avoids a second writer of `scope_node_id` and keeps REQ-532 AC1
and AC6 intact; the exclusion by `assignee_type` gives the same visibility as a NULL node, which is the
existing fail-closed rule for scoped grants (0051 F1, T13).

**Source.** `lib/letflow/tasks.ex` (`apply_claim`, `apply_completion_authz`, `filter_by_scope/2`,
`in_scope/3`, `f1_allowed?/3`, `assign_task/3`); `lib/letflow/tasks/scope_resolver.ex`;
`lib/letflow/routers/tasks.ex`; `lib/letflow/engine/task_activation.ex`;
`priv/repo/migrations/20260818110003_create_tasks.exs`; `test/letflow/tasks/scope_node_id_no_writer_scan_test.exs`;
0051 F1, T13; REQ-532 AC1, AC6.

### D5. Security

**Decision.**

- **INV-1.** The prefix is supplied by core (D1). Property a test must prove: with tenant A and tenant B
  each holding an org tree and a head, a task created in B is resolved only from B's `org_unit` rows (a
  head id that exists only in A is never returned; a query-log or row-level assertion shows only B's
  prefix), and a resolver registered by a module installed only in A is not found for B
  (`{:error, :not_found}`, reason `no_resolver`).
- **INV-5.** Property a test must prove (it holds because the three D4 changes exclude UNRESOLVED tasks
  from scoped principals on every path, while the NULL-safe predicate leaves nil-assignee tasks visible):
  for a scoped caller, including a TASK_WORKER or TASK_VIEW holder whose subtree covers the instance
  node, GET of an UNRESOLVED task id, of a nonexistent id and of a foreign-tenant task id return an
  identical status, body and header set; the `assignee_reason` code appears in no response to a caller
  that is not tenant-wide. Tested through the route.
- **INV-3 and INV-8.** A resolver that raises, exits, throws, times out or returns a malformed value is
  the `resolver_failed` row: the transaction commits and the instance advances.
- **INV-10.** If any slice adds a route that takes a tenant identifier, it carries a cross-tenant
  negative test.
- **Cross-tenant negative test in the first implementation slice** that touches tenant data (D8): tenant
  B cannot cause a resolution against tenant A's org data and the reverse, a resolver registered by a
  module installed only in A does not run for B, and an absent and a foreign id answer identically.
- **SECURITY-REVIEWER is a mandatory gate for every implementation slice**, including the org field
  slice 1a.
- Threat cases the SECURITY-REVIEWER checks (at least TC-1 to TC-3):
  - **TC-1** the resolver returns a user outside the tenant, or a deactivated user: malformed,
    `resolver_failed`, never assigned.
  - **TC-2** a cycle (or depth over 12) in the org tree: the resolver terminates and fails closed.
  - **TC-3** the requester moves between units while the task is open: no re-resolution (D6); a test
    shows the open task keeps its assignee and a new task uses the new unit.
  - **TC-4** a scoped admin writes the head field to point at themselves: writes follow the 0050 D7
    `managed_by` lock and 0051 D11.
  - **TC-5** a manifest forges a descriptor: the call re-resolves the resolver by module id and name, as
    `call_write_handler/4` does.

**Reasons.** The resolver reads tenant org data inside the engine transaction, which is a tenant-data
path by definition. The three D4 changes are what make INV-5 true for UNRESOLVED tasks; the tests above
are their evidence.

**Source.** `docs/agents/instructions/security-invariants.md` (INV-1, INV-3, INV-5, INV-7, INV-8, INV-10);
0050 D7, D8; 0051 D11, T9, T14; REQ-538 D5.

### D6. Timing and stability

**Decision.** The assignee is resolved ONCE, inside the transaction that creates the task, and never
re-derived: the same rule as the instance scope node (0051 T13). A later change of the head does not
move an open task; a tenant-wide holder reassigns through the existing assign path. Owner confirmation
is OQ-2.

**Reasons.** T13 already fixes the analogous rule for scope. The assignee becomes data in the task row
and its audit, so replay and audit stay deterministic. Re-resolution would need an org-to-task reverse
hook or timers, which the engine may not hold (REQ-045). Rejected option: re-resolve on head change.

**Source.** 0051 T13; REQ-045; REQ-538 open question 2.

### D7. Relation to scope

**Decision.** The resolved user is only a candidate. The task is created with `assignee_type = "USER"`
and `assignee_ref = <id>` only if that user also passes the F1 rule for the task's scope node: a
TASK_WORKER grant covering `ScopeResolver.task_scope(task)`, or a tenant-wide holder. The check is
`Tasks.f1_allowed?/3`, evaluated for the resolved user at creation through the existing Scope API.
Otherwise the outcome is the D4 row `no_user`. Resolution can only narrow access, never widen it. A later
revocation of the grant is handled by the existing request-time F1 check (0051 T3), not by D6.

**Reasons.** 0051 F1 is the only candidate rule; a resolver that bypassed it would be a second, wider
access path. The engine already calls `Tasks.f1_recheck/3`, so calling `Tasks.f1_allowed?/3` crosses no
new boundary.

**Source.** 0051 F1, T3; `lib/letflow/tasks.ex` (`f1_allowed?/3`, `f1_recheck/3`).

### D8. Slice plan

**Decision.** Each follow-on implementation requirement has `depends_on: [REQ-532]` (the task scope
writer, W3b), cites decisions 0050 and 0051 in its description, and passes the SECURITY-REVIEWER and
REVIEWER gates.

1. **1a org module:** `head_user_id` on `org_unit` (pack, entity definition, write-lock tests). Tests:
   field validation, the 0050 D7 lock, TC-4.
2. **1b core:** carry `requester_id` on the instance (set at start, T13), unless an existing field is
   found when the slice is written.
3. **1c Catalog:** the `:assignee_resolvers` manifest key, `assignee_resolver/2`,
   `call_assignee_resolver/3`, the `validate/2` rules and the savepoint wrapper. Tests mirror
   `test/letflow/modules/catalog_write_handlers_test.exs`, plus `Letflow.Engine.NoOrgLogicScanTest` (D2)
   and TC-5.
4. **1d engine call site:** the UNRESOLVED state with the task keeping the instance node; UNRESOLVED
   excluded for scoped principals in `ScopeResolver.task_scope/1` (F1 recheck), `filter_by_scope/2`
   (list, inbox, GET by id) and `in_scope/3` (claim, complete, assign, reassign pre-check) with the
   NULL-safe predicate `(is_nil(t.assignee_type) or t.assignee_type != "UNRESOLVED")`; no ledger change;
   refusal of authored UNRESOLVED and malformed RESOLVED; the `assignee_reason` audit key; the refusing
   `apply_completion_authz` clause; the D7 F1 check. Tests: V1 to V6 of D4, every D4 row, D7
   no-widening, D6 stability, and the cross-tenant negative test of D5. If 1d is not the first slice that
   touches tenant data, the first one that does carries the cross-tenant negative test.
5. **1e** the `org` module's `department_head` resolver (walk bounded by 12). Tests: TC-1 to TC-3.

Out of scope: delegation, substitute-on-leave, a business-day escalation default (0051 F3 names the
resolver hook only), and any change to REQ-531 or REQ-532.

**Reasons.** Each slice is one change a single review can hold, and the order follows the data
dependencies: the head field and the requester must exist before a resolver can read them, and the
Catalog contract must exist before the engine calls it.

**Source.** REQ-538 D8 and acceptance criterion 8; REQ-532; 0050; 0051.

## Consequences

- No code changes with this record. Implementation starts only after the owner answers OQ-1 and OQ-2 and
  the record is signed off.
- A new `assignee_type` value, "UNRESOLVED", becomes part of the task model in slice 1d; clients that
  switch on `assignee_type` need a branch for it.
- The engine gains one Catalog call and a source scan that forbids org words under `lib/letflow/engine*`.
- The org module gains one field (slice 1a), so its pack version changes in that slice.

## Consistency with existing decision records

- **0051 F1** names candidates as "routing role AND TASK_WORKER grant". A resolved USER assignee has no
  routing role; D7 requires the grant (or tenant-wide authority) for the resolved user. This is a
  narrowing of who may be assigned, not a widening, but REVIEWER should confirm it.
- **REQ-532 AC1 and AC6 and the single-writer ledger** are not narrowed: option (b) keeps the instance
  node on UNRESOLVED tasks (D4).
- **0050 D1** keeps `position` unbuilt; D3 adds a field to `org_unit` instead of building it.
- **0050 D3.6** keeps references declarative, so `head_user_id` is not FK-enforced; the resolver validates
  it (D4, TC-1).
- **REQ-045** is kept: no process per instance; the time bound is a statement timeout, not a timer.
- **0061** is kept: the resolver takes no row lock (D2).
- The engine's own SAVEPOINT wording is unverified on main (as the GH #2707 design notes), so D2 leaves
  the exact savepoint mechanism to the slice 1c design to prove.

## Open owner questions

- **OQ-1 (D3) Which data names the head of a unit.** Options: (a) a nullable `head_user_id` on
  `org_unit`; (b) a `membership_role` on `org_unit_membership`; (c) the `position` type of 0050 D1.
  Recommendation: (a), for the reasons in D3. Until the owner confirms, no code slice is written.
- **OQ-2 (D6) Resolve once or re-resolve.** Options: (a) resolve once at task creation, never re-derived;
  (b) re-resolve when the head changes. Recommendation: (a), for the reasons in D6.

## Not decided here

- Delegation, substitute-on-leave and escalation defaults.
- Relations other than `department_head` (the list output shape leaves room for them).
- Any change to REQ-531 or REQ-532.
- Any edit to the `scope_node_id` writer ledger.

## Sign-off

- SECURITY-REVIEWER: pending.
- REVIEWER: pending.
- Owner (OQ-1, OQ-2): pending.
