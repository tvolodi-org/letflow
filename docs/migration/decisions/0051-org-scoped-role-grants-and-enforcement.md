# 0051 -- Org-scoped role grants and enforcement: a tenant grant table over `org_unit` nodes, one `allowed?/3`, scope-aware 404s, escalation instead of self-approval

Status: Accepted: ruled by the user's advisor session (letflow-ec) under the user's delegation, recorded by the supervisor; the user accepted the core changes in principle 2026-10-14.
Rulings applied: Q9 rulings (c) D1 fail-closed with explicit tenant_wide row, mandatory backfill, tokens, JIT/OIDC rows, rollout stages; (d) approver model, F1 rule, escalation; threats T11-T17; filter placement; 404 equivalence; audit events, per advisor session letflow-ec, Q9, relayed by the supervisor 2026-10-14. Open points 2, 6 and 7 are removed as resolved; remaining numbers are kept.
The decisions D1..D10 are the architect's, relayed by the supervisor on 2026-10-14 from the user's
advisor, and are quoted as such below; this record writes them down and adds only the mechanism
facts (cited file:line or NOT FOUND), the threat cases, and the corrections listed in "Deviations
from the relayed wording". It does not edit 0013, 0046 or 0048.

Date: 2026-10-14. Drafted by `CODE-DESIGNER`. Owner: `ORCH`.

Depends on: sibling draft 0050 (`org` module). Names used here are 0050's: the tree entity is
`org_unit`; `scope_node_id` is an `org_unit` record id (a `:string` id, no reference type, 0050
D3.6). `org_legal_entity` and `org_site` are not tree nodes and cannot be a scope. Core reaches the tree
only through the interface of 0050 D8 (default: a core-owned path projection).
Related: 0013 (role names), 0046 (two scopes, eight roles, closed set), 0048 (pending admin grant).

## Context

Relayed architect decisions (supervisor, 2026-10-14): "ONE core change: a tenant grant table
(principal = user or group, role, scope_node_id) where scope = an `org` module node; a grant covers
the node's subtree; a role with no scope row stays tenant-wide; the closed role set is unchanged;
the coarse role check stays in the token, the scope check is a DB lookup at request time; one core
function allowed?(principal, permission, resource_scope); every module action declares how it finds
its resource scope, and a check-style test fails when a route declares none; query/aggregate need a
scope filter; out-of-scope reads return 404; every grant change and tree change is audited;
TENANT_AUDITOR stays tenant-wide by default; SoD: approver-equals-requester must escalate to the next
level, never auto-approve."

Today a role is tenant-wide: holding `TASK_WORKER` or an approver role lets the holder act on every
department's rows. The pilot limit is stated in D9.

### Deviations from the relayed wording (for the architect, to be relayed)

1. "Coarse role check stays in the token": for OIDC users roles are NOT from the token per request
   (see below). Read as "the role-name check stays where it is".
2. "A role with no scope row stays tenant-wide" is fail-open when rows are later removed. RULED (Q9 (c)):
   D1 supersedes it with fail-closed plus an explicit `tenant_wide` row and a mandatory backfill.
3. "ONE core change": together with the core-to-org interface (0050 D8, ACCEPTED) this is a grant table
   plus a path projection, both in `Letflow.Api.Scope`'s area; the 0050 D7 `managed_by` write lock and F1
   are further core changes.

### Security MUSTs: confirmed by the advisor (Q10)

SECURITY-REVIEWER (security-0051.md, FAIL pending M1-M9) set these as binding design requirements. The advisor
(letflow-ec, Q10, relayed 2026-10-14) CONFIRMED all of them and strengthened several. Each changes or tightens
an advisor-ruled or relayed position and is written into the decisions as stated:

4. M1 (tightens "TENANT_ADMIN is the grant writer", T8): the whole admin plane resolves with
   `resource_scope :tenant_wide`; a scoped TENANT_ADMIN gets domain actions only. Also refused: any change that
   leaves a tenant with zero tenant-wide TENANT_ADMINs (scoping, unbinding, deactivating the last one) (D11).
5. M2 (SUPERSEDES Q9 (c) "tokens are always tenant-wide"): tokens stay tenant-wide, but are minted only by a
   tenant-wide TENANT_ADMIN, token roles must be a subset of what the NAMED user holds tenant-wide (else 422,
   same code as `roles_invalid`) unless the user is an admin-flagged service principal (audited act), mint and
   listing are audited, and the flip precondition lists tokens whose roles exceed their user's current
   tenant-wide roles, which must be revoked or re-minted before enforcement. Scoped integration tokens: later
   follow-up (D1). Advisor-confirmed exception 2026-10-15: PLATFORM_ADMIN may mint in the platform tenant
   only, self-only, expiry <= 90 days (D1 (a); `lib/letflow/design/gh2552-api-token-issuer-and-roles.md` §3).
6. M3 (SUPERSEDES open point 5 "tenant-wide wins" as a sync default): tenant-wide wins only WITHIN a principal.
   Before enforcement, IdP/JIT sync writes a `tenant_wide` row. After enforcement, sync writes NO row (the user is
   denied until an admin grants scope) and emits an audited "binding pending scope" event; sync never adds or
   keeps `tenant_wide` for a user who has scoped rows (`grant.sync_suppressed`). Group-member add audits the
   effective-scope delta (D1, D8).
7. M4: scope-column and `tenant_wide` declarations come from module code / manifest and are immutable once set;
   the definitions API refuses to touch managed or scope-aware type names, and refuses creating a new type whose
   name collides with a managed type of any installed module (D6; 0050 D7).
8. M5: the enforcement flag is flipped ON and OFF only by tenant-wide TENANT_ADMIN or platform scope, read from
   the DB per request, preconditions enforced server-side inside the flip; turning OFF needs the same gate plus
   a mandatory reason and an audit (D12).
9. M6 (strengthens "same number of DB queries"): a mechanism, one scoped by-id query; a query-count test is
   sufficient, no timing assertions (D7).
10. M7 (T15) DECIDED: the residual is accepted with conditions (scope checked at link issue time, TTL <= 300 s,
    one attachment per link, issuing audited, residual documented) (T15).
11. M8 (SUPERSEDES the D9 "pilot limit until F1" as a temporary state): PERMANENT. Rebinding an existing routing
    role name to a different group becomes an explicit audited action for a tenant-wide admin; the current silent
    overwrite is recorded as a DEFECT, filed as GH #2524 (D9, D11).
12. M9 (T12): scope checked on old and new value for every write path; bulk / import checks every row,
    all-or-nothing with one generic batch error; NULL scope is unresolvable except on types declared
    tenant_wide (D6, T12).

### Confirmed by the advisor (Q10)

13. F6 (REVIEWER): a `script` principal is tenant-wide only and never inherits the invoker's scope (D1); its reads
    are limited to the running instance's own data plus declared tenant-wide master lookups (host prefetch), and its
    outputs take the instance's scope. 0053 D5 states the same rule.

Current mechanism, verified on this branch (file:line):

- Roles are resolved per request, and NOT only from the token. OIDC branch:
  `AuthPipeline.verify_local_account_state/2` calls `Identity.list_effective_role_names/2`, "one new,
  uncached `Repo` round trip per authenticated OIDC request" (`lib/letflow/plugs/auth_pipeline.ex:369-401`,
  query at `lib/letflow/identity.ex:833-846`, a join of `group_members` and `tenant_roles` with
  `kind == :platform_role`). The token's own role claims (`Oidc.ClaimMapping.resolve_roles/2`,
  `lib/letflow/oidc/claim_mapping.ex:97,170`) feed the one-time JIT sync into `group_members`, not the
  per-request decision. API-token branch: roles come from the token row (`verify_api_token`,
  `auth_pipeline.ex:153,235`), documented as a "single-uncached-query shape (AC1)" (`auth_pipeline.ex:378`).
- The role strings become the closed atom set in `Authorization.effective_roles/2`
  (`lib/letflow/api/authorization.ex:600-609`), called from `lib/letflow/plugs/authorize.ex:123`;
  `roles/0` is at `authorization.ex:468`, `@roles` (8 members) at 394-403; unknown strings are dropped
  (`roles_from_strings/1`, 582-591).
- `evaluate_access/2` takes only `(AccessContext, endpoint_policy_key)` (`authorization.ex:1120`); the
  context has `user_id`, `roles`, `platform_tenant?` and no resource (`authorization.ex:543-559`). It
  structurally cannot see a resource scope (INV-2 moduledoc, `authorization.ex:35-43`).
- An existing row-scope mechanism: `evaluate_access/2` can return `:AllowWithRowFilter`
  (`authorization.ex:332`) carrying a `task_row_scope` (`:all | {:own_user_and_groups, user_id}`,
  `authorization.ex:392`), set only for a task-worker-only caller on `:TasksList`
  (`authorization.ex:1155-1168`). `Tasks.resolve_principal_scope/2` (`lib/letflow/tasks.ex:355`) reads
  the user's groups and role names fresh per call, no cache.
- `tenant_memberships` (cross-tenant switcher links) are NOT FOUND in the request path:
  read only by `GET /me/memberships` (`lib/letflow/identity/tenant_membership.ex:37`).
- Tenant filtering of entity queries is by Postgres schema prefix, not by a `tenant_id` column:
  `Compiler.compile(request, prefix)` (`lib/letflow/entities/query/compiler.ex:155`), `Allowlist.load/2`
  (159-162), `run_aggregate/2` executes with `Repo.all(query, prefix: prefix)` (`compiler.ex:699-701`);
  the router calls them at `lib/letflow/routers/entities.ex:1722-1725` (query) and `1977` (aggregate).
  A scope filter has no existing hook: it would be a new predicate in both `compile/2`
  (`compiler.ex:155-180`) and `compile_aggregate/2` (`compiler.ex:650-690`). `FieldGrants`
  (`entities/query/field_grants.ex:84`) filters FIELDS per user, not rows.
- SoD: `Letflow.Engine.SeparationOfDuties` compares the actor with `tasks.completed_by` of the MOST
  RECENT COMPLETED task of each node named in `distinct_from` (`separation_of_duties.ex:136-150`;
  node attribute read at 152-155). `distinct_from` covers PRIOR COMPLETERS only, not the instance
  STARTER (`actor_id` on the instance-started event, `lib/letflow/engine.ex:1656`; no starter field
  in `lib/letflow/event_store/instance_projection.ex:137-175`). Refusal is a hard
  `{:error, {:separation_of_duties, ids}}` (`separation_of_duties.ex:119`); no escalation path: NOT FOUND.
- Task candidacy: `Letflow.Tasks` checks group or role assignees at claim time
  (`lib/letflow/tasks.ex:485,501,581,589`); no scope or `scope_node` on a task: NOT FOUND.
- Route declaration: the `authz_*` macros take a literal policy key
  (`lib/letflow/api/authorized_router.ex:108`) and `test/letflow/api/authorization_enforcement_test.exs`
  walks every route for a non-`:Unknown` key. No notion of "how this route finds its resource scope":
  NOT FOUND.
- Audit of grants and tree changes: no grant table exists, so NOT FOUND; the 0050 tree has no audit yet.

## Decisions

### D1. One grant table, fail-closed, with an explicit tenant-wide row (Q9 (c): ACCEPTED)

A tenant-schema table `role_scope_grants`: `principal_type` (`user` | `group`), `principal_id`, `role`
(one of the closed `Authorization.roles/0` names), `scope_node_id` (an `org_unit` record id, nullable),
`tenant_wide` (boolean). A CHECK enforces exactly one of: `tenant_wide = true` with `scope_node_id`
NULL, or `tenant_wide = false` with `scope_node_id` set. A role granted with scoped rows applies only
inside the union of those rows' subtrees. The role set stays closed (0046 D10, 0013); a grant never
creates a role or a permission. `PLATFORM_ADMIN` and platform-scope permissions are out of scope for
grants (0046 D2). This SUPERSEDES the relayed "no row = tenant-wide".
Clarification (REVIEWER on REQ-497 PR 1a, 2026-10-15): `role_scope_grants` rows may exist for the
`PLATFORM_ADMIN` binding (the stage-1 backfill mirrors every `:platform_role` binding); they are never
consulted: grants never decide `PLATFORM_ADMIN` or platform-scope access (INV-10).

**Principal types.** Grant rows exist for `user` and `group` only. Two more principal kinds are defined by
rule, with no rows: a `token` principal (below) and a `script` principal, the identity under which an engine
script or rule runs (0053). A script principal is tenant-wide only: it holds no grants and NEVER inherits the
invoking user's (or token's) scope. Per the advisor's Q10 ruling it reads only (a) the running instance's own
data and (b) declared `:tenant_wide` master lookups, both pre-fetched by the host (0053 D5); it never reads other
records of the instance's `scope_node` subtree. Its outputs take the instance's scope (T13); an instance with no
node, or `:unresolvable`, is denied.

**Effective scope of (user U, role R) (decided; formerly open point 5).** Roles reach a user only through
groups today (`tenant_roles.group_id`; the per-request role query joins `group_members` and `tenant_roles`,
`identity.ex:833-846`), so there is no "user holds role" fact except through a group. (1) R must be held by
U through some group G of U (the unchanged coarse check); otherwise DENY, and a `user` row for a role U does
not hold through a group has no effect. (2) Applicable principals: U itself and every such G. (3) Within one
principal: a `tenant_wide` row makes that principal tenant-wide (tenant-wide wins within a principal);
otherwise it contributes the union of its scoped rows' subtrees; zero rows contributes nothing. (4) Across
principals: union of subtrees; any tenant-wide contribution makes the result tenant-wide. A `user` row
therefore only adds subtrees; to narrow a user, scope the group or move the user to a scoped group.
Resolution returns a tagged result (`:tenant_wide`, `{:nodes, ids}`, `:deny`), never raises on a missing node.

**A `tenant_wide` row exists only by an explicit act (M3).** It is created or relied on only by the audited
admin act `grant.made_tenant_wide` (or by the one-time backfill, audited as `scope.backfill_completed`). IdP
claim sync (`sync_role_claims_from_token`, `identity.ex:877-900`): before enforcement it writes a `tenant_wide`
row (legacy); after enforcement it writes NO row (the user is denied until an admin grants scope) and emits an
audited "binding pending scope" event. Sync never adds or keeps `tenant_wide` for a user who holds scoped rows:
adding such a user to a group whose applicable row is tenant-wide is suppressed and audited as
`grant.sync_suppressed`. Adding a user to a group by an admin
(`:GroupsManage`) is itself a grant of the group's scope and is audited with the resulting effective-scope
delta (role, from, to).

Fail-closed rules:

* "No rows" always means DENY. A (principal, role) pair with a binding but zero rows is denied; it never
  falls back to tenant-wide.
* A principal that has had scoped rows for a role never becomes tenant-wide by row removal. Deleting the
  last scoped row of a (principal, role) is refused unless the same request replaces it with an explicit
  `tenant_wide = true` row (the audited "make tenant-wide" action, `grant.made_tenant_wide`) or removes
  the role binding itself (which cascades the rows).
* An `org_unit` cannot be deleted or retired while any grant references it. A grant whose node is
  unresolvable is denied (`:unresolvable`, T6), never tenant-wide.
* **Mandatory backfill.** The migration that creates `role_scope_grants` inserts an explicit
  `tenant_wide = true` row for EVERY existing role binding (user and group), per tenant schema, INSIDE
  the migration transaction. After it, every bound role has at least one row.
* **Every binding write path creates its row in the same transaction.** Binding write paths found in
  the tree (each must be changed, listed so none is missed): `RoleRegistry.upsert_role`
  (`lib/letflow/routers/identity.ex:929`, route `POST /roles` at `:239`); group member add/remove
  (`identity.ex:206,214`); JIT/OIDC role-claim sync `Identity.sync_role_claims_from_token/3`
  (`lib/letflow/identity.ex:877`); `lib/letflow/identity/role_backfill.ex`;
  `lib/letflow/identity/tenant_admin_migration.ex`; the pending administrator grant
  (`lib/letflow/identity/pending_admin_grants.ex`, 0048). While enforcement is OFF, a writer creates an explicit
  `tenant_wide` row in the SAME transaction as the binding (legacy behaviour preserved). In an enforced tenant
  a writer that does not know the intended scope inserts NO row (DENY) and returns a typed error; it never
  defaults to a `tenant_wide` row (silent widening). New tenants provisioned after the release (provisioning
  path, seeds, `role_backfill.ex`, `tenant_admin_migration.ex`) use the same writers. The backfill runs per
  tenant inside the migration transaction and ends with an assert (zero bindings without a row) that aborts
  the migration; T9's query also runs as a scheduled check. Completeness of this list: NOT VERIFIED (found by name search
  only); T9's test (no binding without a row) is the backstop.
* **API tokens (T11, M2). Tokens are tenant-wide, minted only by a tenant-wide admin, and bounded by their
  owner.** A token has no `role_scope_grants` row and the rule is explicit and tested ("a token principal is
  tenant-wide for its token roles; there is no scoped token"), not an absence-of-row inference. Roles of a
  token come from the token row (`auth_pipeline.ex:153,235`), not from `group_members`. Verified minting
  facts: `POST /tokens` is keyed `:TokensManage` (`routers/identity.ex:221-223`), `user_id` and `roles` both
  come from the request body, and `Identity.create_token/3` (`identity.ex:1454-1478`) checks only that roles
  are in the closed issuable set and the PLATFORM_ADMIN rule, NOT the owner's roles or the minter's scope. So,
  unbounded, a token converts a scoped user's access into tenant-wide. Required:
  (a) minting requires a TENANT_ADMIN holding the role tenant-wide (D11); advisor-confirmed exception
  2026-10-15: PLATFORM_ADMIN may mint in the platform tenant only, self-only, expiry <= 90 days; see
  `lib/letflow/design/gh2552-api-token-issuer-and-roles.md` §3 (GH #2552);
  (b) every minted token's roles must be a subset of the roles the NAMED user holds tenant-wide, else the mint
  is refused with 422 and the same code as `roles_invalid`, unless the user is explicitly flagged a service
  principal by an audited admin act;
  (c) mint is audited (the EXISTING `token.create` event, with roles and the tenant-wide statement, NEVER the token value) and
  each token listing used for the flip precondition is audited (`token.listed`);
  (d) the flip precondition (Rollout 4) is "no token holds a role beyond its owner's tenant-wide roles", not
  merely "list the tokens": tokens whose roles exceed their user's current tenant-wide roles are listed and must
  be revoked or re-minted before enforcement.
  Residual risk, accepted: a token holding `TASK_WORKER` or `PROCESS_OPERATOR` sees every scope.
  Scoped integration tokens (`principal_type = token` rows) are a later follow-up and need their own record.

### Rollout (Q9 (c), staged)

1. One release ships the table, the backfill (D1), and every binding write path creating rows. No
   behaviour change.
2. Enforcement is behind a PER-TENANT flag, default OFF.
3. Shadow mode: compute `allowed?` and log/count would-deny, deny nothing, for at least one UAT cycle. Shadow
   logs carry no resource contents (INV-2/INV-4).
4. Before a tenant flips: zero bindings without a row (T9 query), the org consistency check (0050 D8) passes,
   AND no token holds a role beyond its owner's tenant-wide roles (D1); all three are checked server-side inside
   the flip transaction and refuse the flip (D12); the flip is audited (`scope.enforcement_enabled`).
5. A pilot tenant flips first. Never enable on a tenant while the 0050 D7 interim option (c) applies.

### D2. Subtree semantics (architect)

A grant on node N covers N and every descendant. Membership is resolved at request time against the
CURRENT tree, never copied into the grant row, so moving a subtree changes access immediately (T1).

### D3. Two-step check: coarse then scoped (architect, amended)

The coarse role/permission check is unchanged (`evaluate_access/2`). The scope check is a DB lookup
at request time. Nothing scope-related is cached in the token or a process. This matches the
existing uncached per-request role lookup (`auth_pipeline.ex:369-381`).

Cost and query plan (required, SECURITY-REVIEWER and designer verify):

* Tree access uses the 0050 D8 interface. With the default core-owned projection `scope_node_paths`
  (node id, materialised path, depth), "is node R inside subtree of grant node G" is a prefix test on
  the path column: one indexed query, no recursion. The path predicate uses bound parameters with `%` and `_`
  escaped (INV-7); so does the backfill migration. A closure table is the alternative; a recursive
  CTE over a module-owned parent column is rejected as O(tree) per request and as a boundary breach.
* Indexes: `role_scope_grants (principal_type, principal_id, role)`; `scope_node_paths (path
  text_pattern_ops)` and `(node_id)`. Maximum tree depth is bounded (recommended 12) and enforced by
  the `org` move action.
* OIDC path: load the user's grants in the same `AuthPipeline` step as `list_effective_role_names/2`
  (a second query, or one joined query), memoised in `auth_context` for the request only. API-token
  path: its documented single-uncached-query shape (`auth_pipeline.ex:378`, AC1) is preserved by
  joining the token's principal grants into that same query; if that cannot be done the acceptance
  criterion must be re-stated explicitly, not silently broken. List requests compute the allowed
  node set once per request and apply it as one predicate (D6), not per row.

### D4. One core function, beside the existing row filter (architect, amended)

`Letflow.Api.Scope.allowed?(principal, permission, resource_scope)` is the only place a scope decision
is made. `resource_scope` is `:tenant_wide` (no node; allowed iff the caller holds the role
tenant-wide), `{:node, node_id}`, or `:unresolvable` (denied, fail closed). `evaluate_access/2` stays
pure and untouched (INV-2 structural argument preserved); `allowed?/3` is called after it.

Relation to existing row scoping: `:AllowWithRowFilter` / `task_row_scope` (own tasks and own groups)
stays as is and is orthogonal: it narrows WHICH tasks a worker-only caller lists by assignment,
`Scope` narrows by ORG POSITION. For task lists the two compose (intersection). To avoid two
mechanisms, F1 reuses `Tasks.resolve_principal_scope/2` as the single place a principal's groups and
roles are read, and extends that result with the allowed node set rather than adding a parallel
reader.

### D5. Every module action declares its resource scope (architect)

Each module action (and each core route that is scope-aware) declares how its resource scope is found:
a function from the loaded resource to `{:node, id}` or `:tenant_wide`. A check-style test (same shape
as `authorization_enforcement_test.exs`) fails when a route of a scope-aware module declares none. A
route with no single resource (list endpoints) declares a scope FILTER instead (D6).

### D6. Query and aggregate carry a scope filter (Q9; SECURITY-REVIEWER, INV-2)

Filter placement rules:

* The scope set is a REQUIRED argument of `Compiler.compile` and `compile_aggregate`: no default arity
  (today `compile/2` and `compile_aggregate/2`, `compiler.ex:152-155,649-652`, take `(request, prefix)`;
  the new argument is part of the contract, so a caller that forgets it does not compile).
* The predicate is ANDed into the OUTERMOST `WHERE`, before `group_by`, `having`, `count`, `total` and
  cursor pagination, so every one of them sees only scoped rows. It is computed server side, never from
  the request. Never post-filter.
* Export reuses the compiled query (the same `Allowlist.load` / `compile` / `Cursor.paginate` sequence,
  `routers/entities.ex` export route at `:414`), so it inherits the filter.
* Every scope-aware entity type declares ONE promoted, indexed scope column. Masters declare
  `tenant_wide`. An entity type that declares neither is DENIED once enforcement is on. These declarations
  (scope column and `tenant_wide`) come from the owning module's code / manifest, NOT from tenant-editable
  definition JSON, and are immutable once set; the definitions API refuses create / update / activate /
  deprecate / delete of a definition whose type name is managed or scope-aware, refuses creating a new type
  whose name collides with a managed type of any installed module, and refuses altering the
  declarations (M4; mechanism and per-route test in 0050 D7). Otherwise a `PROCESS_DESIGNER` (holder of
  `:EntitiesDefinitionsWrite`) could supersede the type or declare `tenant_wide` as a self-service exemption.
* Writes (M9): scope is checked on the OLD and NEW value for PATCH, bulk update, IMPORT (`:EntitiesRecordsImport`
  routes, `entities.ex:293-314`) per row, and any module action that changes the scope column. A scoped caller
  can never create a record with a scope node outside its subtree, nor with NULL scope (NULL is
  `:unresolvable`, not tenant-wide, except on types declared `tenant_wide`). Bulk update / import checks EVERY
  row, all-or-nothing, and returns one generic error for the batch (no per-row "out of scope" detail). The scope column is covered by field-level write rules (`FieldGrants` is
  read-side only).
* Field grants are unchanged and still apply on top.

### D7. Out-of-scope reads are 404 (Q9; INV-5)

A read or write outside the caller's scope returns the same status and body as a nonexistent id; 403
stays reserved for "right resource scope, wrong role". Equivalence rules:

* The scope check happens BEFORE any resource validation (no 422/400 that reveals existence).
* Byte-identical body and headers; no `ETag` / `Last-Modified`; the same number of DB queries.
* Lists omit out-of-scope rows and totals exclude them (no placeholders).
* **Mechanism (M6, INV-5).** For by-id reads and writes the lookup is ONE query with the scope predicate in
  its WHERE (`id = ? AND scope in allowed set or tenant-wide`), so out-of-scope and nonexistent ids run the
  same query and return nothing. The allowed-node-set query runs unconditionally BEFORE it (also for a
  nonexistent id). For writes the scope check runs before body validation, including malformed bodies. The
  same shape applies to PATCH-by-id, DELETE, and the instance / task / attachment lookups (`Tasks.get_task`,
  `tasks.ex:266`; `ensure_instance_exists`: NOT VERIFIED location). A query-count test (Ecto telemetry) between an
  out-of-scope and a nonexistent id for each scope-aware route is sufficient; no timing assertions.

### D8. Audit (Q9)

Audited through the existing audit chain, each with actor, before/after, UTC time and correlation id
(`trace_id`): `grant.created`, `grant.revoked`, `grant.made_tenant_wide`, `grant.self_grant_refused`,
`org_unit.created`, `org_unit.moved`, `org_unit.retired`, `org_unit.renamed`, `org_membership.added`,
`org_membership.removed`, `group_member.added`, `group_member.removed`, `scope.enforcement_enabled`,
`scope.enforcement_disabled`, `scope.backfill_completed` (with counts), `grant.sync_suppressed`, `token.create`,
`token.revoke`, `token.listed`, `role.rebound` (before/after group). Token events keep their EXISTING names
`token.create` / `token.revoke` (`identity.ex` on main; supervisor ruling 2026-10-14): the issuer, actor and
`trace_id` go into the metadata. Renaming an existing event is its own migration decision, because the hash-chained
history would otherwise carry two names for one event. `token.listed` is new. `group_member.added/removed` record the resulting
effective-scope delta (role, from, to). Audit writes are in the SAME transaction as the change they record,
not best effort; token values never appear in audit or shadow logs. Scope-404s are counted in
telemetry, NOT audited.

**`tenant_admin.guard_refused` (supervisor ruling 2026-10-15).** One single refusal event is used by EVERY N1 zero-tenant-wide-admin refusal path, so no path invents its own name: the deactivation path (#2564) and the grant, unbind and rebind paths (#2533), plus the other N1 paths listed under "Security review pass 2". Metadata: `action` (which guarded action was refused, e.g. deactivate, grant, unbind, rebind), `actor`, `target_id`, `reason_code`, `counted_admins` (the active tenant-wide admin count the guard saw) and `trace_id`. It is written in its OWN transaction AFTER the guarded transaction has rolled back, because an audit row written inside the refused transaction would roll back with it (this is a deliberate exception to the same-transaction rule above, which applies to successful changes). Like the other D8 events it carries no token values and no IdP claim values.

VERIFIED: the chain accepts new event types without a code change. The `action` is a free-form string
(`lib/letflow/audit.ex:123` type `action: String.t()`, `lib/letflow/audit/entry.ex:30` `field(:action,
:string)`, required but not enumerated at `entry.ex:44-52`); the table column is `:string, null: false`
(`priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs:50`) and no registry or
check constraint on `action` was found there. Caveat: only the table migration was grepped for a CHECK;
other consumers that filter by action (reporting UI, `Audit.list_entries/1` params) were not read: NOT
VERIFIED. `resource_id` is a string, so org-unit and grant ids fit (design REQ-195 §1.2).

**Amendment to D8, additive (advisor letflow-ec ruling under the user's delegation, relayed by the supervisor, 2026-10-16; recorded by letflow-2).** The list above is extended with one action, `idempotency_squat.remediated` (GH #2597: the explicit removal of a pre-#2550 idempotency-key squat; it was outside this list). D8 is otherwise unchanged. The ruling also fixes the rules for every audit action added from now on:

1. **Naming.** An action is `<subject>.<past_tense_verb>`, lower-case snake_case, exactly one dot (`grant.created`, `org_unit.moved`). The subject is the object concerned. A new action is a new name: an existing action is never overloaded with a payload flag. Remediations of a security finding use the verb `remediated`; detections use `detected`; so the trail can be filtered by finding class. (The pre-existing names `token.create`, `token.revoke` and the like keep their names, as D8 already states.)
2. **Payload.** Affected record ids and counts only. Never an idempotency key value or any client-supplied content (a squatted key is attacker-controlled text). The payload carries the finding reference (for example GH #2597), the actor (the operator, or the migration name), and the before and after state. The audit entry is written in the SAME transaction as the remediation it records.
3. **Consumers (NOT VERIFIED, carried as a test requirement).** Whether every consumer that filters by action (the reporting UI, `Audit.list_entries/1` params) tolerates an action name it does not know was not read (see the VERIFIED paragraph above). Until it is verified, the implementing requirement of each new action includes a one-time test showing that the audit listing and any action filter return the new action without error; this is tracked in a separate issue.
### D9. Defaults, the approver model, and the pilot limit (Q9 (d))

`TENANT_AUDITOR` stays tenant-wide by default (0046 D6); an admin may scope it by grant (AuditRead is
T17). **`PROCESS_OPERATOR` is REJECTED as the approver.** Approvers use `TASK_WORKER` permissions plus
CUSTOM TENANT ROUTING ROLES created with `POST /roles` (for example `PR_APPROVER_L1`, `PR_APPROVER_L2`,
kind `process_routing_role`). The closed role set is unchanged (0046 D10).

VERIFIED that a `HUMAN_TASK` `role` attribute resolves custom tenant roles: `resolve_assignee/1` derives
`assignee_type = "ROLE"` and `assignee_ref = attributes["role"]` for any role name
(`lib/letflow/engine/task_activation.ex:142-162`); claim and completion check `ref in scope.role_names`
(`lib/letflow/tasks.ex:496,586`); `resolve_principal_scope/2` builds `role_names` from every
`tenant_role` row bound to the user's groups with NO `kind` filter (`tasks.ex:355-374`); definition-time
role-binding checks accept a role of any kind (`lib/letflow/definitions/role_binding.ex:61-65`).
`POST /roles` accepts `kind` `platform_role | process_routing_role` (`routers/identity.ex:919-927`);
custom names need only `:RolesManage` (`identity.ex:239`), while built-in names need
`:UsersGroupsRolesManage` (`identity.ex:910`). Note: the per-request API role lookup is filtered to
`kind == :platform_role` (`lib/letflow/identity.ex:833-846`), so a routing role grants no API permission,
which is the intent. Not verified end to end: a running instance routed to a `POST /roles` role (the
reads above are static).

**Approver resolution (F1 rule, Q3).** A routing role is a custom name and is NOT in the closed
`role_scope_grants.role` set, so a routing role can never have a grant row and there is no "nearest ancestor
holding the approver role by grant". The only expressible rule, and the one ruled in Q3, is: a user can
approve a task iff the user is in the task's routing role via a group AND holds a `TASK_WORKER` grant whose
subtree covers the task's scope node. D10's next-level resolution uses the same rule with the escalation
routing role.

Approval authority follows the routing-role binding, so the binding is a scope-granting act (M8, PERMANENT, not
only until F1). Until F1 (Q3) lands, ANY holder of the routing role can approve ANY department's request, and
enabling enforcement does NOT protect approval authority beyond that. `POST /roles` USED TO upsert and overwrite
`group_id` on conflict while `:RolesManage` is held by `PROCESS_DESIGNER`, so a designer could silently rebind an
approver role to a group of their choosing. That DEFECT (GH #2524) WAS FIXED by PR #2537 (merge 1465df2a):
`POST /roles` no longer rebinds, and rebinding is the explicit `POST /roles/:id/rebind` action described below. Rule: `upsert_role` is split. Creating a
binding stays as is (in an enforced tenant it requires a tenant-wide TENANT_ADMIN); rebinding an existing name to
a different group is an explicit, separate action for a tenant-wide admin, audited with before/after
group (`role.rebound`, D11).

### D10. Separation of duties escalates (architect; Q9 (d) rulings)

When the approver equals the requester, the step must ESCALATE to the next level (the next approver: the escalation routing role under the F1 rule of D9, not a walk up the tree), and must never auto-approve. Today's rule only refuses (`separation_of_duties.ex:119`)
and covers prior completers, not the starter.

* **Starter coverage (ACCEPTED, first consumer):** the process models a "submit-request" HUMAN_TASK
  completed by the requester, and the approval node names it in `distinct_from`; the requester, as
  completer of that task, cannot also complete the approval (REQ-VALIDATOR finding F4 on the local
  procurement requirement draft, 2026-10-14; the claim rests on `separation_of_duties.ex`, which compares the actor with `tasks.completed_by`).
* **Escalation (RULED):** a definition-level timer on the approval task, default 3 BUSINESS days (a
  tenant setting), routes to level 2 (`PR_APPROVER_L2`), NEVER auto-approves. Mechanism that exists:
  HUMAN_TASK attributes `escalation_timer_duration` + `escalation_role` (CHK-21, REQ-396,
  `lib/letflow/definitions/graph.ex:437`; armed at `lib/letflow/engine.ex:799-830`; on firing
  `Scheduler` calls `advance_after_escalation_timer_fired`, which cancels the original task and creates
  a new task at the escalation target, `lib/letflow/scheduler.ex:307-309`); it never completes the
  original task. GAPS: the duration is ISO-8601 converted to seconds (`engine.ex:808-815`), so calendar
  time, not business days; a business-day calendar: NOT FOUND (`grep -i business_day lib`: no hits); a
  tenant setting supplying the default: NOT VERIFIED (no such setting read). The business-day default
  and the tenant setting therefore need a follow-up core/design change; until then the definition
  author sets a fixed calendar duration. Also note `scheduler.ex:71-77` still says escalation timers are
  deferred; the code above shows that text is stale.
* **F2 (starter coverage in the engine and automatic escalation on self-approval)** comes AFTER slices
  1-2. Until F2, a refused self-approval is a hard error and the process must give a second approver
  path (a task assigned by scope, F1).

### D11. The admin plane is tenant-wide only (M1, M8; S1, S2, S10)

A TENANT_ADMIN holds every tenant-scope permission (`authorization.ex:1385-1386`), so a TENANT_ADMIN restricted
by a scoped grant would still pass the coarse check for every admin route. Rule: a scoped TENANT_ADMIN is allowed
domain actions only, never admin-plane ones. These resolve with `resource_scope :tenant_wide`, i.e. allowed
only to a principal holding the role tenant-wide: group member add/remove/list (route key `:GroupsManage`,
`identity.ex:206,214`, mapped to `:UsersGroupsRolesManage` by `required_permission/1`, `authorization.ex:1217`),
`:UsersManage`, `:UsersGroupsRolesManage`, `:TokensManage` (`POST /tokens`), `:RolesManage` (`POST /roles`,
including routing-role bind/rebind in an enforced tenant), pending admin grants, writes to `role_scope_grants`,
`org_unit` / `org_unit_membership` writes, the enforcement flag (D12) and the consistency endpoint. The D5
check-style test walks ALL routes (core and module, including attachments, tasks, instances), each classified
`:tenant_wide` | scope-declared | filter | admin-plane, with one assertion per admin-plane route that a scoped
TENANT_ADMIN is refused.

* Self-grant (S2): a principal may not create, widen or make tenant-wide a grant for itself or for any group it
  belongs to, nor add itself to a group; any change that would leave the tenant with zero tenant-wide TENANT_ADMINs (scoping, unbinding or deactivating the last one) is refused. Refusals are
  audited (`grant.self_grant_refused`).
* Subtree move (S1): a move affecting nodes that carry grants is allowed only for a tenant-wide TENANT_ADMIN and
  emits one audit event listing the principals whose effective scope changed (count and ids). Projection write
  and `org_unit` write are one transaction (0050 D8); a concurrent move-vs-request test shows a request sees
  either tree entirely.

### D12. The enforcement flag (M5)

Per-tenant, stored in the DB and read per request (no cache); NOT a config entry writable through the generic
entities or tenant_config API. Flipping ON or OFF requires a tenant-wide TENANT_ADMIN or platform scope, never a
scoped admin (turning it off is a total bypass); turning it OFF additionally requires a mandatory reason, stored
in the audit event. The Rollout 4 preconditions are checked server-side inside
the flip transaction and refuse the flip. `scope.enforcement_enabled` and `scope.enforcement_disabled` are
audited in the same transaction.

### Q3. Task candidates (architect, fixed roles now)

Fixed roles now. Once D1..D7 land, a task carries a `scope_node` and candidate resolution filters by it
(F1, a SECOND small core change). **F1 rule candidate (RULED):** the user is in the task's routing
role/group AND holds a `TASK_WORKER` grant whose subtree covers the task's scope node. A true resolver
hook (manager-of, delegation) comes later through the module Catalog (`Letflow.Modules.Catalog`), not in
the engine (`Letflow.Engine` is a plain transactional context, CLAUDE.md REQ-045).

## Consequences

- Core adds: the `role_scope_grants` table, the `scope_node_paths` projection (0050 D8 default),
  `Letflow.Api.Scope`, and compiler predicates. `Authorization` matrix and role set unchanged (0046 D7/D10).
- Follow-ups, not part of this change: F1 task `scope_node` + candidate filter; F2 SoD starter
  coverage and escalation (after slices 1-2); F3 resolver hook; business-day escalation default.
- Cost: see D3; the API-token single-query shape is preserved or its AC explicitly re-stated.
- Existing tenants keep working: legacy bindings are backfilled to explicit tenant-wide rows (D1); enforcement is per-tenant, default OFF, shadow first (Rollout).

## Threat cases for SECURITY-REVIEWER

- T1 Subtree move. Moving node X under a different parent widens or narrows every holder of a grant
  on the old and new ancestors immediately. Required: tree changes audited (D8), move is a privileged
  action (0050 D7), cycles prevented, and a test that access follows the CURRENT tree.
- T2 Group grant. A grant to a group applies to every current member; adding a user to a group is
  therefore a scope-granting act. Required: group-member add/remove audited; the grant table is
  readable only with `:UsersGroupsRolesManage`; a user in two groups gets the UNION of scopes and a
  tenant-wide result from any principal wins, per the D1 effective-scope algorithm; IdP sync cannot re-widen (M3).
- T3 Stale token vs revoked grant. Grants are read at request time (D3), never carried in the token.
  Test: revoke, next request is 404.
- T4 Aggregate leakage via counts. Counts, totals, `group_by` buckets and pagination `total` must be
  computed over scoped rows (INV-2). Also cursor pagination (`Cursor.paginate`, `entities.ex:1725`)
  and export (`entities.ex:2179`): same filter.
- T5 Existence oracle. 404 body, headers and timing class must equal the nonexistent case (INV-5);
  list endpoints must omit, not placeholder.
- T6 Unresolvable scope. A route whose scope cannot be derived (null node, deleted or retired node)
  is denied (`:unresolvable`), never treated as tenant-wide.
- T7 Self-approval. Closed for the first consumer by the submit-request task in `distinct_from`
  (D10); other processes remain exposed until F2.
- T8 Grant-table writer. Whoever can write grants can raise their own scope. Required: writes need
  `TENANT_ADMIN`'s `:UsersGroupsRolesManage`; a principal may not grant itself scope; last-admin risk
  of 0046 open risk 1 is unchanged. The whole admin plane is tenant-wide only (D11); self-grant rules in D11.
- T9 Fail-open by removal. Removing a user's last scoped grant, or retiring a node, must never make
  the user tenant-wide (D1 fail-closed rules). Required: tests for both paths.
- T10 Org-tree write path (0050 D7): who can re-parent nodes is a security boundary; closed by the
  `managed_by` write lock, and 0051 is never enabled while interim option (c) applies.
- T11 API tokens. Tenant-wide, minted by tenant-wide admin only, roles bounded by the owner's tenant-wide roles, audited (D1, M2). Tests pin the rule and the 422.
- T12 Scope from a mutable field. Where a resource's scope derives from a field a caller can change,
  check scope on BOTH the old and the new value (an update cannot move a row out of, or into, a scope the
  caller does not hold), for PATCH, bulk update, import and module actions; NULL scope is `:unresolvable` (D6, M9). The
  same applies to a process step that writes an entity (REQ-484, planned, NOT VERIFIED in code) and to 0053 hook 2:
  T12 and T13 apply to that engine write path inside `complete_task`.
- T13 Instances, variables and history carry a `scope_node` set at instance start, never re-derived from
  the caller later. An instance started by a system path with no node is `:unresolvable` for scoped
  principals (visible to tenant-wide holders only).
- T14 Async/system paths, decided per path (none uses the HTTP caller's scope at run time):
  timers (`scheduler.ex`) act only on the instance's own scope_node, escalation stays within it and
  widens nothing; service tasks (`engine/service_task_dispatcher.ex`) run under the instance's
  scope_node as a ceiling; scripts (Lua/WASM, `lib/letflow/engine/lua`, `wasm`): no record access found
  in `lib/letflow/engine` (`grep Records. / Query.Compiler` there: no hits; SECURITY-REVIEWER re-confirmed), so no
  scope bypass exists today; the script principal is tenant-wide only and never inherits the invoker's scope (D1),
  and any future host function that reads records must apply that rule and the instance scope; inbound webhooks / trigger
  starts must supply a `scope_node` or the instance is `:unresolvable`; outbound events and webhooks
  (`lib/letflow/webhooks`) are tenant-level subscriptions and are NOT scope-filtered, documented and
  accepted (each event payload carries the `scope_node`; a subscription may add a node filter later);
  exports reuse the scope-filtered compiled query (D6). Whether the service-task payload path reads
  records: no read found at `service_task_dispatcher.ex` lines checked (433-439, 666, 693; head-limited grep, not
  exhaustive).
- T15 Bearer artefacts outliving revoked scope: signed links, attachment links and pagination cursors.
  The attachment link TTL is a fixed 300 s
  (`lib/letflow/repository/attachment_links.ex:161`) and `verify` takes only `(token, tenant_id)`; the serving
  route still runs the `:AttachmentsRead` pipeline (`attachment_links.ex:78-83`). DECIDED (M7): the residual is
  accepted with conditions: scope is checked at link ISSUE time as a full scoped lookup on the parent record;
  TTL <= 300 s; one attachment per link; issuing is audited with issuer and scope node; the residual is
  documented (a revoked user keeps access for at most 300 s through links already issued). The serving route
  re-evaluates scope where it can (if a serving path is ever bearer-only without auth, it cannot). A cursor is
  position only, opaque, never embeds the allowed set, and every page re-applies the CURRENT scope predicate
  (`Cursor.paginate`, `entities/query/cursor.ex`). Tests: revoke a grant mid-pagination; revoke then serve a link.
- T16 Reference validation as an existence oracle (0050 `lookup`/`active?`): the same error for
  not-found and out-of-scope; masters (`catalog_item`, `catalog_uom`, `org_legal_entity`) are declared tenant-wide
  readable.
- T17 `AuditRead` (`TENANT_AUDITOR`, audit routes) is tenant-wide and exposes cross-scope data:
  ACCEPTED and documented; an admin may scope the auditor by grant (D9) but the audit log itself is not
  row-scoped.

## Consistency with existing decision records

- 0046 D10 / 0013: role set closed (eight roles per 0046 D10); CONSISTENT (grants add scope, not roles).
- 0046 D6: `TENANT_AUDITOR` tenant-wide read-only; CONSISTENT (D9).
- 0046 D2 / INV-10: platform authority bound to the platform tenant; CONSISTENT.
- 0046 D4/D5: `TENANT_ADMIN` owns users, groups, role bindings; CONSISTENT, it is the grant writer (T8).
- 0048: pending administrator grant binds `TENANT_ADMIN` at first login; CONSISTENT, a bound admin is
  a legacy or explicit tenant-wide binding.
- 0050: names and the D8 interface; CONSISTENT.
- Not edited: this record amends none of them.

## Open points

Architect:
1. Where grants are read (default in D3: the same `AuthPipeline` step, request-local memo) and the
   "stays in the token" wording (Deviation 1).
3. Starter recording for F2: projection column vs reading the started event.
4. (Closed: F2 after slices 1-2, D10.)
5. (Closed: decided in D1, effective-scope algorithm and M3. Number kept.)

(Open points 2, 6 and 7 removed as resolved: 0050 D8; D1 and Rollout; D9. Numbers kept.)

SECURITY-REVIEWER: T1-T17, D6/T4 filter placement and INV-2 near `evaluate_access/2`, D7/T5 404
equivalence under INV-5, the D8 event list (chain acceptance verified, caveat noted), D1 fail-closed rules, backfill and rollout, token default, and the T14 per-path decisions.

## Sign-off

REVIEWER:

SECURITY-REVIEWER:

## Security review pass 2 (2026-10-14): SHOULDs carried into the implementing requirements

SECURITY-REVIEWER pass 2: PASS_WITH_FINDINGS, no remaining MUST. These become acceptance criteria of the implementing requirements:

- **N1. Zero-tenant-wide-admin guard.** Enforce it with one in-transaction check that counts only active admins, under a lock, on every path:
  - scoping or unbinding the last admin;
  - deactivating the last admin, including `PATCH /users/:id`;
  - removing the last admin from the group carrying TENANT_ADMIN, or deleting that group;
  - `role.rebound` of the TENANT_ADMIN binding;
  - revoking a pending admin grant.

  Each path gets a test. Every refusal on these paths writes the single `tenant_admin.guard_refused` event (D8).
- **N2.** `token.listed` carries the actor, the count and the token ids only, never token values, hashes or prefixes.
- **N3.** `binding.pending_scope` joins the D8 event list. Its payload is user, group, role and trace_id only, with no IdP claim values, deduplicated per (user, role).
- **N4.** The route-walk test also covers every route that calls `Entities.Definitions.create` or `activate`. System provisioning (`tenant_provisioning.ex`) comes under the managed-name immutability rule.

## Amendment 1 (2026-10-17): flip preconditions, shadow evidence and audit actions (additive)

Status: Accepted, relayed. Source: the supervisor (letflow-supervisor-22) and letflow-9c, relaying the advisor's rulings on OQ-1..8 and the supervisor's rulings of 2026-10-17, written into the requirements REQ-517, REQ-518 and REQ-519 (GH #2535); recorded by letflow-2. Not verified by the recorder against code beyond what the validator read on main. Additive: nothing above is reversed, except where noted.

**A1. D12 flip preconditions (extends Rollout 4).** The flip `shadow -> on` is refused, inside the flip transaction and under the lock order of `flip/4` (lock A, the tenants row, the scope-tree lock), unless ALL hold: (1) T9: zero bindings without a grant row; (2) the org consistency check passes; (3) no token holds roles that exceed its owner's tenant-wide roles (`tokens_exceed_owner`); (4) NEW, blocking: at least one EXPLICIT tenant-wide TENANT_ADMIN exists (`zero_tenant_wide_admins`; D12 had it informational), counted as a `tenant_wide=true` TENANT_ADMIN row for the user or a bound group, or a live TENANT_ADMIN token owner, never as zero-row members, who are denied under `on` (SEC design review D-1, relayed by letflow-9c); (5) NEW: `shadow_required` (`off -> on` is refused; `on` is reached only from `shadow`); (6) NEW: the shadow evidence of A3; (7) NEW: no scoped approver while tasks carry no scope node (`scoped_approvers_without_task_scope`, advisor ruling OQ-1; removed by the requirement that ships the writer of `tasks.scope_node_id`). A refused flip reports every failing precondition and writes no flag change.

**A2. Service principals.** The service-principal exemption of this record covers ONLY the mint-time subset check. Tokens of a flagged service principal still count for precondition (3): a flagged owner with an exceeding token still refuses the flip. The flag is explicit and audited, never inferred (OQ-4).

**A3. Shadow evidence.** The in-memory shadow metric cannot gate a per-tenant flip, so per-tenant, per-UTC-day, per-reason counters are persisted (REQ-517 AC 22). The flip requires: continuously in `shadow` for at least `:scope_shadow_min_days` (default 7), at least `:scope_shadow_min_requests` (default 100) requests in that trailing window, and zero would-denies with reason `no_grant_rows` or `grants_unavailable`; every counted UTC day must also show requests > 0 (a day with no counted requests does not count as evidence, because counts lost on a crash would otherwise make the gate more lenient). Thresholds come from application env only; no request field can lower them. The evidence covers only `:tenant_wide` and admin-plane route denials; data-path denials are proven by tests (REQ-518, REQ-519 AC 16). The refusal body and its audit carry the fixed field `evidence_scope`.

**A4. Reasons.** D12 required a reason only for turning OFF. NEW: `on -> shadow` also requires a mandatory reason (explicit extension); `off -> shadow` keeps the optional reason. Turning OFF is never gated by the ON preconditions. Only an interactive tenant-wide TENANT_ADMIN can flip: API tokens cannot (a behaviour change from the stage-1 PUT).

**A5. Audit actions (extends D8).** NEW actions, each listed and filterable through `Audit.list_entries`: `scope.enforcement_refused` (every refused flip, own transaction after the rollback), `service_principal.flagged` / `service_principal.unflagged`, `binding.refused`, `attachment_link.issued`; `grant.sync_suppressed`, `binding.pending_scope`, `group_member.added` and `group_member.removed` are as in D1/N3. Grant and service-principal entries carry the actor credential kind. No token value, hash or IdP claim value appears in any of them.

**A6. Not decided here.** The optional platform-scope route that flips ANOTHER tenant's flag stays unbuilt and needs its own decision record (0046 D4, M5). In an `on` tenant no new platform-role binding can be created; the remedy is to create it before the flip or flip down and up (REQ-519 OQ-5).

**A7. Admin plane rules (SEC design review of REQ-517, relayed).** API tokens may call the grant write routes (tokens are tenant-wide by D1 and are the break-glass path under `on`); the flag route and the service-principal flag route are interactive-user only. Deleting the only remaining TENANT_ADMIN row of a group is refused with typed 409 `last_admin_binding_row` (the operator unbinds the role instead). Self-service routes (`/me/*`, `/help`) need their own route class or scoped-only users are locked out of them under `on`; the class is `:self_service` with ONE ruled member, `/me/memberships`, until SECURITY-REVIEWER rules on `/me/modules` and `/help/resolved` (REQ-518 AC 21, marker `pending_sec_ruling`); those two stay `:tenant_wide` meanwhile, and the `on` flip is blocked until the class ships.

## Amendment 2 (2026-10-19): flip route as built in 2f-b (additive, corrects A4)

Status: Accepted, relayed. Source: the second SECURITY-REVIEWER pass on REQ-519 2f-b (handoff d2535519-0519-4c02-9e11-000000000021), relayed by letflow-9c; recorded by letflow-2 to satisfy REQ-519 AC 19. Not verified by the recorder against the 2f-b code; the 2f-b PR is the evidence. Additive: it narrows the wording of A4 to what 2f-b builds.

**A8. Who can call the flip route.** The `PUT` flip route is interactive-user only for EVERY transition, including `off -> shadow`: API tokens, and platform-tenant PLATFORM_ADMIN without a TENANT_ADMIN role, lose the `PUT` that stage 1 allowed. A4's "API tokens cannot" is read as covering all transitions, not only the flip to `on`. `GET` and `available_modes` list `off`, `shadow` and `on`.

**A9. De-escalation.** `on -> shadow` runs no `enable_checks!` (the Rollout-4 facts gate escalation only) and its audit entry is `scope.enforcement_disabled`, with the mandatory reason of A4.

**A10. Known gap, tracked.** The last-admin guard still counts token owners while the flip route needs an interactive admin, so an `on` tenant can lose the last interactive TENANT_ADMIN and have no way to turn enforcement off. Tracked as GH #2869 (needs a design decision before any pilot use; REQ-519 AC 24).
