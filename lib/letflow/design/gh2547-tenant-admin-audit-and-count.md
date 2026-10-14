# GH 2547: every TENANT_ADMIN grant/removal path is audited; tenant-wide admin count helper

Run `WF03-GH2547-TA-AUDIT-20261014`. Stacked on PR #2537 (head 4560e623a, `role.rebound` in tree).
Inputs: GH #2547 body (ACs binding), supervisor rulings 1-7 (relayed in the CODE-DESIGNER dispatch,
2026-10-14), ISSUE-FIXER diagnosis `handoffs/WF03-GH2547-TA-AUDIT-20261014/step-01-issue-fixer.json`,
decision 0051 (D8, M3, N1, N3), 0053 (D6, open point 9), `security-invariants.md` (INV-4, INV-6,
INV-7), `docs/anti-patterns.md` (bulk `update_all`/`delete_all` skipping audit, ISS-0906; "already
carries actor_id" claims, REQ-195). Every file:line below was read on this branch.

Design only. No migration. No new route. No new write function.

## Contract for #2533 / 7b-2b (Revision 1b, binding; relay verbatim)

All four functions live in `Letflow.Identity`. `prefix` is the tenant schema name (the same value as
`opts[:prefix]` elsewhere in this module), passed positionally.

```
@spec count_tenant_wide_admins(prefix :: String.t()) :: non_neg_integer()
@spec tenant_wide_admin_user_ids(prefix :: String.t()) :: [Ecto.UUID.t()]
@spec tenant_admin_lock_key(prefix :: String.t()) :: integer()
@spec lock_tenant_admins!(prefix :: String.t()) :: :ok
```

1. **`count_tenant_wide_admins/1`**: the number of DISTINCT users in `prefix` with
   `users.status == :active` who are (a) a member of the group bound to the `tenant_role` named
   `"TENANT_ADMIN"` with `kind == :platform_role`, OR (b) the owner of an `api_tokens` row whose
   `roles` contain `"TENANT_ADMIN"`, with `revoked_at` nil and (`expires_at` nil OR
   `expires_at > DateTime.utc_now()`). A user who is both counts once. Tokens of a deactivated
   user do not count (#2557 fixes their authentication separately). `PLATFORM_ADMIN` does not
   count. Holders limited to an org scope are excluded through the extension point
   `exclude_scoped_holders/2` (§6.2a); 0051 scopes do not exist yet, so today it excludes no one.
   One read query. Opens no transaction, takes no lock, writes nothing; safe inside a caller's
   `Repo.transaction` and sees that transaction's own uncommitted writes. Raises on a DB error.
2. **`tenant_wide_admin_user_ids/1`**: exactly the set counted by (1), as canonical UUID strings
   sorted ascending. Same transaction properties. For 0053 D6 / open point 9: `solo_audited` is
   allowed only when the tenant has exactly one tenant-wide admin AND the self-publish rule needs
   to know whether that one admin is the publishing author; a count cannot answer "is the author
   the one admin", the id list can, from the same definition, in the same transaction.
3. **`tenant_admin_lock_key/1`**: pure, no DB access. A 64-bit signed integer for the bigint
   advisory-lock key space, derived from `prefix` (§6.6): stable across calls, nodes and releases,
   different for different tenant schemas, and never equal to any advisory-lock key in use today.
4. **`lock_tenant_admins!/1`**: `pg_advisory_xact_lock(tenant_admin_lock_key(prefix))`, held until
   the surrounding transaction ends. Raises `ArgumentError` (fixed message, no prefix) when
   `Repo.in_transaction?()` is false (the `login_directory.ex:499` precedent). Re-entrant within one
   transaction (Postgres advisory locks stack per session). Returns `:ok`.

**Lock protocol (every path that adds or removes a tenant-wide admin, in one transaction):**
`lock_tenant_admins!(prefix)` as the FIRST locking statement (no row lock held before it) ->
the `tenant_role` row by name (`FOR UPDATE`, no `kind` filter) where the path touches a binding ->
the `groups` row -> business rows (`group_members`, `users`, `api_tokens`, pending grants) -> the
audit chain lock (inside `Audit.insert_entry/3`). Guard rule for 0051 N1: write first, then
`count_tenant_wide_admins(prefix)`, then `Repo.rollback` if it is 0. This PR already takes the lock
on every path in §6.6's table; #2533 adds it to user deactivation and pending-grant revoke.

## 0. Acceptance criteria to design elements

| AC (GH #2547, as refined by the rulings) | Design element |
|---|---|
| AC1: every path that grants or removes TENANT_ADMIN writes an audit event with actor, target user, before/after, UTC time, trace id; one test per path | §2 (audit context plumbing), §3 (per-path changes), §4 (per-path table), §8 T-01..T-14 |
| AC2: IdP strip semantics decided and tested vs 0051 M3; a manual membership is never stripped by sync | §5 (KEEP, ruling 1), §8 T-15, T-16 |
| AC3: helper returns tenant-wide admin count (TA-group members plus active, unexpired TA tokens), used by 0051 N1 and 0053 D6, tested | §6 (`Identity.count_tenant_wide_admins/1`, `tenant_wide_admin_user_ids/1`, `exclude_scoped_holders/2`, exported lock `tenant_admin_lock_key/1` / `lock_tenant_admins!/1`, lock protocol for N1; Contract section at top), §8 T-20..T-28, T-32..T-36 |
| AC4: no new grant path; existing audited paths unchanged; no double event on the pending bind | §7 (argument), §3.2 (opt-out), §8 T-17, T-18, T-29..T-31 |

UTC time is automatic: `Letflow.Audit.insert_entry/3` stamps `timestamp = DateTime.utc_now()`
inside the chain lock (`audit.ex:246`). Nothing in this design sets a timestamp.

## 1. Paths in scope (from the diagnosis, re-verified)

| Id | Path | Entry point | Today |
|---|---|---|---|
| (a) | add member, any group | `POST /identity/groups/:id/members` -> `Identity.add_group_member/3` (`identity.ex:617`) | no audit |
| (a') | remove member, any group | `DELETE /identity/groups/:id/members/:user_id` -> `Identity.remove_group_member/3` (`identity.ex:789`), bare `delete_all` | no audit |
| (b) | move a binding | `POST /identity/roles/:id/rebind` -> `RoleRegistry.rebind_role/4` -> `move_role/5` (`role_registry.ex:583`) | `role.rebound`, `trace_id: nil` (`:601`) |
| (b') | create a binding over a populated group; same-group kind conversion | `POST /identity/roles` -> `RoleRegistry.upsert_role/4` -> `insert_role/4` (`:478`), `converge_existing_role/4` (`:499`) | no audit |
| (c) | pending-admin-grant first-login bind | `AuthPipeline.bind_pending_admin/4` (`auth_pipeline.ex:350`) -> `PendingAdminGrants.bind_on_login/5` -> `transact_bind/7` (`pending_admin_grants.ex:518`) | `tenant.admin_grant.bound` + `platform.tenant_admin_grant.bound`, `trace_id: nil` (`:545`, `:558`) |
| (d) | IdP role-claim sync (one-time) | `AuthPipeline.provision_user/3` (`:326`) -> `Identity.provision_oidc_user/4` -> `sync_role_claims_from_token/3` (`identity.ex:877`) | no audit |
| (d') | RoleBackfill sync-marker reset | `RoleBackfill.run/0` -> `classify/4` -> `reset_role_claims_sync_markers/1` (`role_backfill.ex:209`) | no audit |
| (e) | TenantAdminMigration copy / binding / token rewrite | `TenantAdminMigration.run/1` -> `apply_plan/5` (`tenant_admin_migration.ex:317`) | audited, `actor nil`, no `trace_id` key (`audit!/6`, `:403`); `ensure_binding(nil)` (`:339`) unaudited |
| (f) | token mint | `POST /identity/tokens` -> `Identity.create_token/3` -> `insert_token/3` (`identity.ex:1498`) | `token.create`, `actor_id nil`, `trace_id nil` |
| (f') | token revoke | `DELETE /identity/tokens/:id` -> `Identity.revoke_token/2` (`identity.ex:1626`) | `token.revoke`, `actor_id nil`, `trace_id nil` |

Out of scope (ruling 5): user deactivation (`user.update_status`, already audited) and F1 (a
deactivated user's token still authenticates; filed separately). Token expiry is passive
(`verify_api_token/2`, `identity.ex:1710`); no event exists or can exist, and `expires_at` is in the
mint event's `after_state`.

Also checked, not changed:
- `Letflow.IdentityMigration` (`lib/letflow/identity_migration.ex`, `mix letflow.copy_identity_tables`)
  copies `users`/`groups`/`tenant_role` rows from the legacy public tables into tenant schemas
  without audit. It cannot run any more: its source tables are dropped by
  `20260819000004_drop_legacy_public_identity_tables.exs` (its own moduledoc, lines 17-21), so it
  is not a live grant path.
- `create_token/3` does not check the minter's or the owner's roles (any `:TokensManage` holder can
  mint a `TENANT_ADMIN` token for any user). That is the 0051 M2 gap owned by #2533; this design
  only audits the mint, it does not add the check.

## 2. How actor and trace reach the write functions (ruling 7)

### 2.1 Decision: an optional `:audit_context` key in the existing keyword `opts`

Chosen over a new positional argument because every affected public function already takes a
keyword `opts` and has many callers that must not change: `Identity.add_group_member/3` alone has
callers in `pending_admin_grants.ex:535`, the router, and roughly 160 test/fixture call sites across
40 files (counted with Grep over `test/`, `scripts/`, `priv/`). A new key changes no arity, no
return shape and no existing caller. A caller that omits the key gets the fallback in §2.2, so an
un-migrated caller still writes a correct audit row (actor `nil`), never no row.

### 2.2 New module `Letflow.Identity.AuditContext` (`lib/letflow/identity/audit_context.ex`)

Pure, no DB access, no process state of its own.

```
@type t :: %{
        required(:actor_id) => Ecto.UUID.t() | nil,
        required(:trace_id) => String.t() | nil,
        required(:source) => String.t()
      }

@spec from_opts(opts :: keyword()) :: t()
@spec current_trace_id() :: String.t() | nil
@spec normalize_trace_id(term()) :: String.t() | nil
```

- `from_opts/1`: reads `opts[:audit_context]` (a map, possibly partial). Result:
  `actor_id` = the map's `:actor_id` or `nil`; `trace_id` = `normalize_trace_id/1` of the map's
  `:trace_id` when that is a non-empty binary, else `current_trace_id/0`; `source` = the map's
  `:source` when a binary, else `"system"`. Never raises on a missing or malformed key (a non-map
  value is treated as absent).
- `current_trace_id/0`: `normalize_trace_id/1` of `Logger.metadata()[:trace_id]`. This is the
  value `Letflow.Api.Context.assign_trace_id/1` (`api/context.ex:160`) sets for every `/api/v1`
  request and `Letflow.Obs.Logger.with_trace/1` (`obs/logger.ex:207`) sets for a CLI run.
- `normalize_trace_id/1` (SEC-A1): `audit_entries.trace_id` is `:string`, i.e. `varchar(255)`
  (`priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs:57`), while the
  incoming `x-trace-id` header is cut at 256 BYTES with no UTF-8 awareness (`api/context.ex:110`,
  `:178`), so it can be over-long or end mid-codepoint, and either would make the audit insert
  raise and roll back the admin action. Rules: a non-binary or empty value -> `nil`; a binary that
  is not valid UTF-8 -> `nil` (fail to "no correlation", never to "write refused"); otherwise
  the first 255 codepoints (`String.codepoints/1`, so the cut is always on a UTF-8 boundary and the
  result fits `varchar(255)`, which counts characters). Pure, never raises. Every trace id that
  reaches an audit row in this design goes through it.

Why the Logger fallback is acceptable: the explicit map is still the primary channel (router and
auth pipeline pass it), the fallback only covers callers this change does not touch (fixtures, the
onboarding seed, `mix letflow.seed.exam_fixtures`). The trace id is correlation data, never an
authorization input (§9).

### 2.3 Router (`lib/letflow/routers/identity.ex`): one new private helper

```
@spec audit_opts(conn :: Plug.Conn.t(), opts :: keyword()) :: keyword()
```

Returns `opts` with `:audit_context` set to
`%{actor_id: conn.assigns.auth_context.user_id, trace_id: conn.assigns[:trace_id], source: "api"}`.
Actor is the DB-resolved authenticated user (for an API-token caller, the token owner), never a
request value. Applied in exactly these handlers: `do_add_member/3`, `handle_remove_member/4`,
`do_create_token/3`, `handle_revoke_token/3`, router `upsert_role/5`, `handle_rebind_role/3`
(which keeps passing `attrs.actor_id` as today; only `opts` gains the context). The guard helpers
(`with_platform_admin_group_guard/4`, etc.) keep receiving the unchanged `opts`.

### 2.4 Auth pipeline (`lib/letflow/plugs/auth_pipeline.ex`): two private arities change

- `authenticate_oidc/2` passes `conn.assigns[:trace_id]` to both steps.
- `provision_user/3` -> `provision_user/4` (`identity_context, tenant_id, realm, trace_id`); calls
  `Identity.provision_oidc_user/4` with
  `prefix: schema_name, audit_context: %{actor_id: nil, trace_id: trace_id, source: "idp_sync"}`.
- `bind_pending_admin/4` -> `bind_pending_admin/5` (adds `trace_id`); calls
  `PendingAdminGrants.bind_on_login/5` with `prefix: schema_name, trace_id: trace_id`
  (`trace_id:` is the key this module already uses for `create`/`revoke`, `pending_admin_grants.ex:63`).

Both are private; no public signature changes.

### 2.5 CLI paths: a generated trace id per run

`TenantAdminMigration.run/1` and `RoleBackfill.run/0` wrap their whole body in
`Letflow.Obs.Logger.with_trace/1`. Decision: a generated trace id IS appropriate. One id per run
ties every audit row of one sweep together, and the same id lands in the run's log lines through
Logger metadata, so an operator can go from a log line to the audit rows. `with_trace/1` restores
the prior metadata afterwards (`obs/logger.ex:212-220`), so a caller that already has a trace id
(a test, a future HTTP-triggered caller) gets its own id back after the run. Return values of both
`run` functions do not change. The two mix tasks (`letflow.migrate_tenant_admins`,
`letflow.backfill_platform_roles`) need no change.

### 2.6 Every caller touched (complete list)

| File | Function(s) | Change |
|---|---|---|
| `lib/letflow/identity/audit_context.ex` | new module | §2.2 |
| `lib/letflow/routers/identity.ex` | new `audit_opts/2`; `do_add_member/3`, `handle_remove_member/4`, `do_create_token/3`, `handle_revoke_token/3`, `upsert_role/5`, `handle_rebind_role/3` | pass `audit_opts`; map `{:error, {:audit_failed, _}}` and `{:error, {:transaction_failed, _}}` to 500 in add/remove/upsert |
| `lib/letflow/plugs/auth_pipeline.ex` | `authenticate_oidc/2`, `provision_user/4`, `bind_pending_admin/5` | §2.4 |
| `lib/letflow/identity.ex` | `@type opts`, `add_group_member/3`, `remove_group_member/3`, `sync_role_claims_from_token/3`, `insert_or_fetch_group_member/3` (private), `insert_token/3` (private), `revoke_token/2`, `delete_group/2` (lock only); new `count_tenant_wide_admins/1`, `tenant_wide_admin_user_ids/1`, `tenant_admin_lock_key/1`, `lock_tenant_admins!/1` (public), `tenant_wide_admins_query/2`, `exclude_scoped_holders/2` (private) | §3, §6, §6.6 |
| `lib/letflow/identity/role_registry.ex` | `upsert_role/4` path (`insert_role/4`, `converge_existing_role/4`), `rebind_role/4` -> `move_role/5`, `ensure_platform_role_binding/2` (lock only) | §3.4, §3.4b, §6.6 |
| `lib/letflow/identity/pending_admin_grants.ex` | `bind_on_login/5`, `run_bind/7`, `transact_bind/7` (+ lock step) | §3.5, §6.6 |
| `lib/letflow/identity/tenant_admin_migration.ex` | `run/1`, `audit!/6`, `real_tenant/4` (lock only) | §3.7, §6.6 |
| `lib/letflow/identity/role_backfill.ex` | `run/0`, `classify/4`, `reset_role_claims_sync_markers/1` | §3.8 |

Not touched: `lib/mix/tasks/*`, `tenant_onboarding.ex`, `Letflow.Audit`, any migration, any web code.

## 3. Per-path changes

All new audit writes use `Audit.insert_entry(Repo, attrs, prefix)` inside the same
`Repo.transaction` as the write they record (the #2537 `move_role/5` pattern), or
`Audit.append_multi/4` where the function is already an `Ecto.Multi`. An audit failure rolls the
write back. Every `Repo` call passes `prefix: prefix` itself.

### 3.1 Common payload for `group_member.added` / `group_member.removed` (0051 D8 names, ruling 2)

- `actor_id`: `AuditContext.from_opts(opts).actor_id` (router: the caller; sync: the user, §3.6).
- `action`: `"group_member.added"` | `"group_member.removed"`.
- `resource_type`: `"group_member"`; `resource_id`: the target `user_id` (same convention as the
  existing `group_member.copied`, `tenant_admin_migration.ex:364`, so filtering by `resource_id`
  gives one user's membership history).
- `trace_id`: `AuditContext.from_opts(opts).trace_id`.
- `before_state` / `after_state`: string-keyed maps, ids and role names only:

| Key | before (added) | after (added) | before (removed) | after (removed) |
|---|---|---|---|---|
| `"group_id"` | group id | group id | group id | group id |
| `"user_id"` | target user | target user | target user | target user |
| `"member"` | `false` | `true` | `true` | `false` |
| `"group_roles"` | list of `%{"name", "kind"}` for every `tenant_role` row bound to the group (any kind), sorted by name | same | same | same |
| `"user_platform_roles"` | `list_effective_role_names/2` before the write, sorted | same, after the write | before | after |
| `"roles_gained"` | - | after minus before (sorted) | - | - |
| `"roles_lost"` | - | - | - | before minus after (sorted) |
| `"source"` | - | `AuditContext.source` | - | `AuditContext.source` |

`roles_gained`/`roles_lost` is the D8 "effective-scope delta (role, from, to)" in its pre-0051 form
(every grant is tenant-wide until #2533). `group_roles` answers ruling 2 ("which roles the group
carries"). No e-mail, username, display name, claim value or token data appears (INV-4, 0051 N3).

Read order inside the transaction (CDV-2 / SEC-B1): `user_platform_roles` (before) is read just
before the insert/delete; `group_roles` and `user_platform_roles` (after) are read AFTER the
insert/delete, never once up front. Together with the group-row locks of §3.0 this makes the
recorded `group_roles` the roles the group carries at the moment the membership change becomes
visible: a concurrent `upsert_role/4` on the same group either committed before (then it is in
`group_roles`) or is blocked until this transaction commits (then its own `role_binding.*` row
lists this user in `granted_user_ids`/`affected_user_ids`). The before/after role lists come from
`list_effective_role_names/2`, never derived from `group_roles`. (`tenant_role.name` is unique
across kinds, so one role name is bound to at most one group.)

### 3.0 Raise handling and lock order (common to §3.2-§3.8)

**Raises (CDV-1).** `Audit.insert_entry/3` returns `{:error, _}` for a changeset error or an
invalid prefix, but RAISES on a DB error (`audit.ex:235` `repo.transaction`, `:269` `repo.insert`
via a raising Postgrex error, e.g. a trigger or a lost connection). Both shapes are handled:
- Non-raising `{:error, reason}` -> `Repo.rollback({:audit_failed, reason})` (or a Multi step
  returning `{:error, {:audit_failed, reason}}`).
- Raise -> the transaction is rolled back by Ecto before the exception propagates. Each public
  function then either rescues it at its outermost level (stated per function below) or lets it
  reach the caller's own rescue.

| Function | Raise handling | Caller-visible result of a raise |
|---|---|---|
| `Identity.add_group_member/3` | `try ... rescue` around its `Repo.transaction/2` (the `create_token/3` / `revoke_token/2` precedent in the same module, `identity.ex:1542`, `:1670`) | `{:error, {:transaction_failed, Exception.t()}}` |
| `Identity.remove_group_member/3` | same | `{:error, {:transaction_failed, Exception.t()}}` |
| `RoleRegistry.upsert_role/4` | `try ... rescue` around `do_upsert_role/4`'s transaction | `{:error, {:transaction_failed, Exception.t()}}` |
| `Identity.sync_role_claims_from_token/3` | `rescue` around its `Repo.transaction(multi)` (ORCH decision) | the original `user`, unchanged (never raises, `identity.ex:858-864` contract kept) |
| `RoleBackfill` marker reset | none new; the existing `rescue` in `process_registration/2` (`role_backfill.ex:156-163`) applies | `{:error, {:backfill_failed, tenant_id, {:unexpected_exception, exception}}}` |
| `TenantAdminMigration` | none new; existing `process_tenant/3` rescue (`tenant_admin_migration.ex:215-226`) | tenant in `failed` with `:unexpected_error` (unchanged) |
| `PendingAdminGrants.transact_bind/8` | none new; `bind_on_login/5`'s existing `rescue` (`:403-411`) | `:noop` (unchanged) |

A rescue inside a caller's open transaction (the pending bind's Multi, the migration's per-tenant
transaction) returns an error tuple while the outer Postgres transaction is already aborted; both
existing callers turn any error into a rollback (`pending_admin_grants.ex:536-537`,
`tenant_admin_migration.ex:346`), so nothing commits. Rescue log lines never include the exception
message or any claim/user attribute: fixed text, the tenant prefix, the user id and
`inspect(exception.__struct__)` only (the `tenant_admin_migration.ex:217-219` / `pending_admin_grants.ex:403-411`
precedent, INV-4/INV-8).

**Lock order (CDV-2 / SEC-B1).** Every path that writes a binding or a membership takes row locks
in one global order: (0) the tenant admin advisory lock, `Identity.lock_tenant_admins!/1`
(Revision 1b: taken by every path in the §6.6 table, as the first locking statement; a function
called inside a caller's transaction re-enters it at no cost when the caller already holds it, and
a caller that does not hold it must not call `add_group_member/3`/`remove_group_member/3` after
taking row locks, a REVIEWER check); (1) the `tenant_role` row, by name or id, `FOR UPDATE`; (2) the `groups` row; (3)
business rows (`group_members`, `users`, `api_tokens`); (4) the audit chain lock (taken last, inside
`insert_entry/3`). Concretely:
- `upsert_role/4`: role by name `FOR UPDATE` (existing `lock_role_by_name/2`), then the group
  `FOR UPDATE` (new), then the binding write, then the member read, then audit.
- `rebind_role/4` (unchanged): role by id `FOR UPDATE`, then target group `FOR SHARE`.
- `add_group_member/3`: no explicit group lock; the `group_members.group_id` FK check
  (`20260822000102...exs:45`) takes `FOR KEY SHARE` on the group row at insert time.
- `remove_group_member/3`: the group row `FOR KEY SHARE` explicitly before the delete (a delete of
  a referencing row takes no parent lock by itself).
`FOR UPDATE` conflicts with `FOR KEY SHARE`, so a binding write and a membership change on the same
group serialise in both directions; `FOR SHARE` (rebind) and `FOR KEY SHARE` do not conflict, which
is fine because rebind does not record members. No path takes a role row after a group row, so the
new lock adds no cycle.

### 3.2 `Identity.add_group_member/3` (path a), with the explicit opt-out for path c

```
@type opts :: [
        prefix: String.t(),
        login_directory: :enabled | :skip,
        audit_context: Letflow.Identity.AuditContext.t(),
        group_member_audit: :emit | :caller_audits
      ]

@spec add_group_member(group_id :: Ecto.UUID.t(), user_id :: Ecto.UUID.t(), opts :: opts()) ::
        {:ok, %{member: GroupMember.t(), created: boolean()}}
        | {:error, :group_not_found}
        | {:error, :user_not_found}
        | {:error, :caller_audit_requires_transaction}
        | {:error, {:audit_failed, term()}}
        | {:error, {:transaction_failed, Exception.t()}}
```

Steps, all inside one `Repo.transaction/2` (`prefix: prefix`), wrapped in the rescue of §3.0:
1. `opts[:group_member_audit]` defaults to `:emit`. Any value other than `:emit` or
   `:caller_audits` is treated as `:emit` (fail to auditing). If it is `:caller_audits` and
   `Repo.in_transaction?()` is `false`, return `{:error, :caller_audit_requires_transaction}` before
   any query (fail closed: the opt-out only exists for a caller that writes its own audit entry in
   the same, already-open transaction).
2. Group lookup -> `:group_not_found`; user lookup -> `:user_not_found` (unchanged order).
3. Read `user_platform_roles` (before).
4. `insert_or_fetch_group_member/3`, changed as in §3.2.1 (its insert takes the FK `KEY SHARE`
   lock on the group, §3.0).
5. Only when the row was actually inserted by this call AND the mode is `:emit`: read
   `group_roles` and `user_platform_roles` (after) and `Audit.insert_entry` `group_member.added`
   (§3.1). On `{:error, reason}`: `Repo.rollback({:audit_failed, reason})`; a raise is handled per §3.0.
6. Return `{:ok, %{member, created}}` unchanged in meaning (`created` still drives 201 vs 200).

Idempotent re-add (row already there): no write, no audit (same rule as #2537's same-group
rebind).

Decision for ruling 2 (where the audit sits): **in the public context function, default on, with
one explicit opt-out**, not at the router. Reason: the router is not the only writer; the IdP sync
writes memberships too and any future caller (a 0051 grant API, a script) would silently skip a
router-only audit. Default-on makes a forgotten caller produce an audited row with `actor_id: nil`
instead of no row. The opt-out exists only so the pending bind keeps its single event (AC4); it is
guarded three ways: (1) refused outside a transaction, (2) only `pending_admin_grants.ex` may pass
it, as a literal (T-18 scans `lib/` for every mention of the `group_member_audit` key, in any form,
and for any non-literal value), (3) it suppresses only the audit row, never changes what is written.

#### 3.2.1 `insert_or_fetch_group_member/3` (private): know whether THIS call inserted

Today the race fallback reports `created: true` even when a concurrent caller's row won
(`identity.ex:2088-2096`), which would make two callers each audit one row. Change the insert to
`Repo.insert_all(GroupMember, [row], on_conflict: :nothing, conflict_target: [:group_id, :user_id], prefix: prefix)`
with `inserted_at` set explicitly (`NaiveDateTime.utc_now()` truncated to the second, the
`tenant_admin_migration.ex:354` precedent; `insert_all` does not autogenerate timestamps).
The returned count (0 or 1) is the "inserted by this call" fact. `insert_all` returns no struct,
so `member` is then re-selected with the existing `get_group_member/3` (the authoritative row,
with the DB's `inserted_at`), whether the count is 1 or 0 (a lost race returns the winner's row). A
`nil` re-select after a count of 1 cannot happen inside the transaction; it is treated as
`Repo.rollback(:unexpected_missing_member)` rather than assumed away. New private return shape:

```
@spec insert_or_fetch_group_member(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
        {:ok, %{member: GroupMember.t(), created: boolean(), inserted: boolean()}}
```

`created` keeps today's meaning (no membership seen before this call); `inserted` is
`count == 1`. Audit is keyed on `inserted`, so exactly one `group_member.added` exists per row.

### 3.3 `Identity.remove_group_member/3` (path a')

```
@spec remove_group_member(group_id :: Ecto.UUID.t(), user_id :: Ecto.UUID.t(), opts :: opts()) ::
        :ok
        | {:error, :group_not_found}
        | {:error, {:audit_failed, term()}}
        | {:error, {:transaction_failed, Exception.t()}}
```

One `Repo.transaction/2`, wrapped in the rescue of §3.0: lock the group row `FOR KEY SHARE`
(new private `key_share_lock_group/2`; `nil` -> `:group_not_found`, replacing today's plain
`Repo.get`); read `user_platform_roles` (before); `delete_all` on `(group_id, user_id)`; if the
count is 1, read `group_roles` and `user_platform_roles` (after) and insert `group_member.removed`
(§3.1), rolling back with `{:audit_failed, reason}` on a non-raising failure. Count 0 (not a
member): `:ok`, no audit (idempotent, as today). No opt-out for removal; no internal caller needs one.

Router: `{:error, {:audit_failed, _}}` and `{:error, {:transaction_failed, _}}` ->
`Response.internal_error/1` (500), as #2537 does for rebind. Same for `do_add_member/3` and router
`upsert_role/5`. `{:error, :caller_audit_requires_transaction}` is unreachable
from the router (it never passes the opt-out); the router does not add a clause for it.

### 3.4 `RoleRegistry.upsert_role/4` (path b'): audit binding writes that grant someone

```
@type upsert_error ::
        :invalid_role_name | :invalid_group_id | :group_not_found
        | :name_not_a_recognized_platform_role | :platform_admin_outside_platform_tenant
        | :role_already_bound | {:audit_failed, term()} | {:transaction_failed, Exception.t()}
        | Ecto.Changeset.t()

@spec upsert_role(name :: String.t(), kind :: kind(), group_id :: Ecto.UUID.t() | String.t(),
                  opts :: [prefix: String.t(), audit_context: Letflow.Identity.AuditContext.t()]) ::
        {:ok, TenantRole.t()} | {:error, upsert_error()}
```

New transaction body of `do_upsert_role/4` (same name and arity; wrapped in the rescue of §3.0),
in this order (CDV-2 / SEC-B1):
1. `ctx = AuditContext.from_opts(opts)`.
2. `lock_role_by_name(name, prefix)` (`FOR UPDATE`; locks the row if it exists, `nil` otherwise).
3. New private `lock_group_for_update(group_id, prefix)` (`FOR UPDATE` on `groups`); `nil` ->
   `Repo.rollback(:group_not_found)`. This replaces today's plain `Repo.get(Group, ...)`
   (`role_registry.ex:445`) and keeps `:group_not_found` checked before any binding branch, as today.
   Taken before the write on BOTH branches (insert and kind conversion), so a concurrent member
   insert (FK `KEY SHARE`) on that group waits, or this waits for it.
4. `insert_or_update_role(name, kind, group_id, prefix, ctx)` (new arity, below).

New private arities (the audit context and the member check reach them as one explicit argument):

```
@spec insert_or_update_role(String.t(), kind(), Ecto.UUID.t(), String.t(), AuditContext.t()) :: TenantRole.t()
@spec insert_role(String.t(), kind(), Ecto.UUID.t(), String.t(), AuditContext.t()) :: TenantRole.t()
@spec converge_existing_role(TenantRole.t(), kind(), Ecto.UUID.t(), String.t(), AuditContext.t()) :: TenantRole.t()
@spec audit_binding_write(event :: :created | {:kind_changed, old_kind :: kind()},
                          role :: TenantRole.t(), prefix :: String.t(), ctx :: AuditContext.t()) :: :ok
@spec group_member_ids(group_id :: Ecto.UUID.t(), prefix :: String.t()) :: [Ecto.UUID.t()]
```

(`insert_or_update_role/4` becomes `/5`; `insert_role/4` becomes `/5`; `converge_existing_role/4`
becomes `/5`. Today `insert_or_update_role/4` takes `opts` and uses it only for `prefix`
(`role_registry.ex:466`); the `/5` form takes `prefix` directly plus `ctx`.) After a state-changing write:
- `insert_role/5` where the re-read id equals the inserted id (a real insert) calls
  `audit_binding_write(:created, role, prefix, ctx)`; the lost-race branch continues into
  `converge_existing_role/5` as today;
- `converge_existing_role/5` where `kind` is converted on the same group calls
  `audit_binding_write({:kind_changed, old_kind}, updated, prefix, ctx)`.
`audit_binding_write/4` reads `group_member_ids/2` (sorted, after the write, under the group lock
of step 3); if the list is empty it returns `:ok` and writes nothing; otherwise it calls
`Audit.insert_entry` and returns `:ok`, or `Repo.rollback({:audit_failed, reason})` on a
non-raising error (a raise propagates to the rescue of §3.0).

**Decision (ruling 5 b'): audit only grant-relevant binding writes, defined as: the target group
has at least one member at write time (any kind of role, any user status).** Justification:
- A binding over an empty group grants nobody. Every later grant through it is a
  `group_member.added` row, which already records `group_roles` (§3.1), so nothing is lost.
- A binding over a populated group grants (or, for a routing role, changes HUMAN_TASK eligibility
  for) every member at once; that is the (b') grant path and it is always audited, whoever the
  caller is (router, onboarding seed, RoleBackfill seed, `TenantAdminMigration.ensure_binding/2`).
- Auditing every creation would add 7-8 rows to every onboarding and every fixture tenant (all seed
  bindings point at freshly created, empty groups) and break existing pins such as
  `tenant_admin_migration_test.exs:753` ("platform tenant got no audit row"), with no audit value.
- Process-routing bindings are included (not only platform roles): #2524's concern was exactly
  that a routing binding decides who may complete a HUMAN_TASK.

Payload:
- `role_binding.created`: `resource_type "tenant_role"`, `resource_id` = role id,
  `before_state nil`, `after_state %{"name", "kind", "group_id", "granted_user_ids" => sorted member ids, "granted_count", "source"}`.
- `role_binding.kind_changed`: `before_state %{"name", "kind" => old, "group_id"}`,
  `after_state %{"name", "kind" => new, "group_id", "affected_user_ids", "affected_count", "source"}`.
- `actor_id`/`trace_id`/`source` from `AuditContext.from_opts(opts)`.

Race (SEC-B1): because step 3 holds the group `FOR UPDATE` until commit, and every membership
change on that group needs `KEY SHARE` on it (§3.0), the member list read by
`audit_binding_write/4` is exactly the set of users who gain (or, for a kind change, gain/lose) the
role when this transaction commits. A member added concurrently either committed first (it is in
the list) or commits after (its own `group_member.added` lists the new role in `group_roles`).
Same-group same-kind (idempotent) and `:role_already_bound` write nothing and audit nothing
(unchanged #2537 behaviour); they still take the two locks briefly.

Seed path: `ensure_platform_role_binding/2` already locks the role by name before calling
`get_or_create_group_by_name/2` and `upsert_role/4` in its own transaction (`role_registry.ex:278-298`),
so the order stays role -> group. The nested `do_upsert_role/4` re-locks the same role row (no-op
in the same transaction) and then the group.

Router `upsert_role/5`: add `{:error, {:audit_failed, _}}` and `{:error, {:transaction_failed, _}}`
-> 500. Seed callers already turn any `{:error, _}` into a rollback (`role_registry.ex:293`) or
`:unexpected_error` (`tenant_admin_migration.ex:346`); no change there.

### 3.4b `RoleRegistry.rebind_role/4` (path b): trace only

```
@spec rebind_role(role_id :: Ecto.UUID.t(), group_id :: term(),
                  attrs :: %{actor_id: Ecto.UUID.t() | nil, reason: term()},
                  opts :: [prefix: String.t(), platform_scope: boolean(),
                           audit_context: Letflow.Identity.AuditContext.t()]) ::
        {:ok, TenantRole.t()} | {:error, rebind_error()}
```

`move_role/5` gains the resolved trace id (new private arity `move_role/6`) and writes it into
`trace_id` instead of `nil` (`role_registry.ex:601`). Actor stays `attrs.actor_id`. Event name,
before/after maps, no-op rule, error mapping: unchanged.

### 3.5 Pending-admin-grant bind (path c): one event, now with trace

```
@spec bind_on_login(tenant :: Tenant.t(), provisioned :: %{user: User.t(), created: boolean()},
                    identity_context :: IdentityContext.t(), jit_config :: JitProvisioningConfig.t(),
                    opts :: [prefix: String.t(), trace_id: String.t() | nil]) :: :bound | :noop
```

- `run_bind/7` -> `run_bind/8` and `transact_bind/7` -> `transact_bind/8` gain `trace_id`
  (`Keyword.get(opts, :trace_id)`, default `nil`).
- `grant_entry/5` is called with that trace for BOTH `tenant.admin_grant.bound` and
  `platform.tenant_admin_grant.bound` (today `nil`, `:545`, `:558`). Actor stays the bound user,
  payloads unchanged.
- The `:membership` step calls
  `Identity.add_group_member(group_id, user.id, prefix: prefix, group_member_audit: :caller_audits)`.
  It runs inside the Multi's transaction, so the guard of §3.2 step 1 passes, and no
  `group_member.added` row is written. The bind therefore keeps exactly its two existing events
  (one per chain), AC4. The existing `{:error, _reason} -> {:error, :membership}` mapping covers the
  new error variants unchanged.

### 3.6 IdP claim sync (path d), ruling 3

`sync_role_claims_from_token/3` spec unchanged (`:: User.t()`), and it still never raises.

The `:memberships` Multi step replaces `Enum.each` (`identity.ex:900`, which discards every result)
with `Enum.reduce_while/3` over the resolved group ids, in the order
`resolve_group_ids_for_role_names/2` returns them. Per group: read before roles,
`insert_or_fetch_group_member/3`; when `inserted` is `true`, read `group_roles` and after roles and
`Audit.insert_entry` a `group_member.added` row (§3.1). `{:ok, _}` -> `{:cont, ...}`;
`{:error, reason}` -> `{:halt, {:error, {:audit_failed, reason}}}`. The step returns
`{:ok, group_ids}` when the reduction finished, else that error tuple, which aborts the Multi.
Payload fields:
- `actor_id` = `user.id` (the user themself; the sync acts on their own login), regardless of
  `opts[:audit_context].actor_id`;
- `source` = `"idp_sync"` (forced, not taken from opts);
- `trace_id` = `AuditContext.from_opts(opts).trace_id` (the request's trace via §2.4).

Failure handling (CDV-1, ORCH decision):
- Non-raising failure: the Multi rolls back every membership this call inserted (including those
  of earlier groups in the same reduction) and the marker update; the existing
  `{:error, step, reason, _changes}` branch (`identity.ex:938-944`) logs and returns the original
  user. For `{:audit_failed, _}` the log line names the step and the tag `:audit_failed` only, not
  `inspect(reason)` (an audit changeset holds the payload).
- Raise (the realistic case: a DB error inside `insert_entry/3`): a new `rescue` around
  `Repo.transaction(multi)` catches it after Ecto has rolled back, logs fixed text plus `prefix`,
  `user.id` and `inspect(exception.__struct__)` only (no exception message; precedent
  `pending_admin_grants.ex:403-411`), and returns the original user.
- Either way: no membership from this call remains, `role_claims_synced_at` stays `nil`, and the
  next login retries. That is the existing self-healing contract; the fail direction is "no roles
  this request" (safe). Sync runs outside any transaction (both callers invoke it after their own
  transaction commits, `identity.ex:2271-2272`, or with none open, `:2253`), so the rescue never
  hides an aborted outer transaction.

Only memberships this call actually inserted are audited; claimed roles that resolve to nothing,
and memberships that already existed, write nothing. Claim values never enter the payload, only
`tenant_role` names via `group_roles` (0051 N3, INV-4). The one-time gate, the marker stamp rule
(ISS-0773) and `resolve_group_ids_for_role_names/2` are unchanged.

### 3.7 TenantAdminMigration (path e)

- `run/1`: body wrapped in `Letflow.Obs.Logger.with_trace/1` (outside `guarded/2`). Spec unchanged.
- `audit!/6`: attrs gain `trace_id: AuditContext.current_trace_id()`. Actor stays `nil` (CLI,
  there is no authenticated user; the release `rpc` operator is not a tenant user). Event names and
  before/after maps unchanged (`group_member.copied`, `role_binding.removed`, `token.roles_migrated`).
- `ensure_binding(nil, schema)` (`:339`) passes
  `audit_context: %{actor_id: nil, trace_id: AuditContext.current_trace_id(), source: "tenant_admin_migration"}`
  to `RoleRegistry.upsert_role/4`. If the `TENANT_ADMIN` group it found or created already has
  members, §3.4 writes `role_binding.created` in the same per-tenant transaction (closing the
  diagnosis's "ensure_binding(nil) unaudited" gap). An empty group writes nothing (the normal case,
  since the copy runs after it and is itself audited).

### 3.8 RoleBackfill marker reset (path d'), ruling 5

Behaviour does not change: same gate (`:seeded` tenants only), same `update_all` over every row of
the tenant's `users`, same `role_claims_markers_reset` sum, same return shapes.

- `run/0`: body wrapped in `Letflow.Obs.Logger.with_trace/1`. Spec unchanged.
- `reset_role_claims_sync_markers/1` becomes:

```
@spec reset_role_claims_sync_markers(schema_name :: String.t(), tenant_id :: Ecto.UUID.t()) ::
        {:ok, non_neg_integer()} | {:error, {:audit_failed, term()}}
```

  One `Repo.transaction/2`: (1) select ids of users whose `role_claims_synced_at` is not nil
  (before); (2) the existing `update_all` set `role_claims_synced_at: nil`, now with
  `select: u.id` so it returns `{count, ids}` (count identical to today); (3) one
  `Audit.insert_entry` row:
  - `action "role_claims_sync.reset"`, `resource_type "tenant"`, `resource_id` = tenant id,
    `actor_id nil`, `trace_id` = `AuditContext.current_trace_id()` (the run's generated id);
  - `before_state %{"users_with_marker" => sorted ids from (1), "count" => length}`;
  - `after_state %{"reset_user_ids" => sorted ids from (2), "reset_count" => count, "source" => "role_backfill", "effect" => "next_login_resyncs_idp_role_claims"}`.
  Target users = `reset_user_ids`. A non-raising audit failure -> rollback ->
  `{:error, {:audit_failed, reason}}` -> `{:error, {:backfill_failed, tenant_id, {:audit_failed, reason}}}`.
  A raise (DB error, or a test trigger) -> rolled back by Ecto, caught by the EXISTING rescue in
  `process_registration/2` (`role_backfill.ex:156-163`) ->
  `{:error, {:backfill_failed, tenant_id, {:unexpected_exception, exception}}}`. No new rescue.
  Either way the markers are unchanged.
  One event per tenant, not per user: it is one operator act, and per-user rows would take the
  tenant chain lock once per user.
- `classify/4` returns `{:ok, acc}` or `{:error, reason}`; `process_registration/2` halts with
  `{:error, {:backfill_failed, tenant_id, reason}}` on the error, the shape it already uses.

This event matters for TENANT_ADMIN because the reset makes the next login re-run the IdP sync,
which can re-grant a TA membership an admin removed (REQ-378 permanence is deliberately broken by
ISS-0910 here). The re-grant itself is then audited by §3.6 with `source "idp_sync"`.

### 3.9 Tokens (paths f, f'), ruling 4

Names stay `token.create` / `token.revoke` (AC4; 0051 D8's `token.created` is for #2533 to
reconcile). `insert_token/3` -> private `insert_token/4` (adds the resolved `AuditContext.t()`);
`revoke_token/2` resolves it from `opts`. Both set `actor_id` and `trace_id` from
`AuditContext.from_opts(opts)` instead of `nil`. Before/after maps unchanged (`struct_state` minus
`:token_hash`); the target user is the existing `user_id` key. Public specs unchanged:

```
@spec create_token(user_id :: Ecto.UUID.t(), attrs :: create_token_attrs(), opts :: opts()) :: (unchanged)
@spec revoke_token(token_id :: Ecto.UUID.t() | String.t(), opts :: opts()) :: (unchanged)
```

## 4. Per-path audit table

| Path | Function | Event | Actor source | Trace source | Before / after | Test |
|---|---|---|---|---|---|---|
| (a) add, TA group | `Identity.add_group_member/3` | `group_member.added` | router `auth_context.user_id` | `conn.assigns.trace_id` via `audit_opts/2` | §3.1, `member false->true`, `roles_gained ["TENANT_ADMIN"]` | T-01 |
| (a) add, other group | same | `group_member.added` | same | same | §3.1, `group_roles` of that group (may be `[]`) | T-02 |
| (a) re-add | same | none | - | - | - | T-03 |
| (a') remove, TA group | `Identity.remove_group_member/3` | `group_member.removed` | router | router | §3.1, `roles_lost ["TENANT_ADMIN"]` | T-04 |
| (a') remove non-member | same | none | - | - | - | T-05 |
| (b) rebind TA binding | `RoleRegistry.rebind_role/4` | `role.rebound` (unchanged) | `attrs.actor_id` (unchanged) | router `audit_opts/2` (new) | unchanged | T-06 |
| (b') create binding, populated group | `RoleRegistry.upsert_role/4` | `role_binding.created` | router | router | `nil` / `name, kind, group_id, granted_user_ids` | T-07 |
| (b') create binding, empty group | same | none | - | - | - | T-08 |
| (b') kind conversion, populated group | same | `role_binding.kind_changed` | router | router | kind old/new, `affected_user_ids` | T-09 |
| (c) pending bind | `PendingAdminGrants.bind_on_login/5` | `tenant.admin_grant.bound` + `platform.tenant_admin_grant.bound` (unchanged, no `group_member.added`) | bound user (unchanged) | auth pipeline `conn.assigns.trace_id` (new) | unchanged | T-10 |
| (d) IdP sync | `Identity.sync_role_claims_from_token/3` | `group_member.added` per inserted row | the user (`user.id`) | auth pipeline via `provision_oidc_user/4` opts | §3.1, `source "idp_sync"` | T-11 |
| (d') marker reset | `RoleBackfill.run/0` | `role_claims_sync.reset` | `nil` (CLI) | `with_trace/1` generated | `users_with_marker` / `reset_user_ids, reset_count` | T-12 |
| (e) migration | `TenantAdminMigration.run/1` | `group_member.copied`, `role_binding.removed`, `token.roles_migrated` (unchanged), `role_binding.created` when the TA group was populated | `nil` (CLI) | `with_trace/1` generated (new) | unchanged | T-13 |
| (f) mint | `Identity.create_token/3` | `token.create` | router (new) | router (new) | unchanged | T-14a |
| (f') revoke | `Identity.revoke_token/2` | `token.revoke` | router (new) | router (new) | unchanged | T-14b |

## 5. IdP strip semantics (AC2, ruling 1): KEEP

Decided: sync never removes a membership. The IdP is authoritative only at the first successful
sync (REQ-378 revocation permanence, `sync_role_claims_from_token/3` moduledoc and
`lib/letflow/design/req378-oidc-live-revocation-check.md` §2.2.4). A TENANT_ADMIN claim that
disappears later changes nothing in Letflow; revocation is an explicit, audited Letflow act
(`group_member.removed`, §3.3). The one-time sync behaviour is not changed.

Cross-check with 0051 M3 (lines 58-62): M3 governs only what sync WRITES (tenant-wide before
enforcement, nothing plus `grant.sync_suppressed` after). It never has sync remove a row. KEEP is
consistent with M3 and with its direction ("sync writes less over time, never more").

A manual membership is trivially never stripped (nothing strips). The sync's moduledoc gains one
sentence stating "never removes a membership; a claim that disappears has no effect".

No migration: a `group_members.source` provenance column is only needed for a strip, which is not
being built.

## 6. Tenant-wide admin count helper (AC3, ruling 6)

### 6.1 Signatures (in `Letflow.Identity`, next to `list_effective_role_names/2`)

Revision 1b (ORCH amendment, binding): positional `prefix`, names as in the Contract section.

```
@spec count_tenant_wide_admins(prefix :: String.t()) :: non_neg_integer()
@spec tenant_wide_admin_user_ids(prefix :: String.t()) :: [Ecto.UUID.t()]
```

Both guard `is_binary(prefix)` (a non-binary raises `FunctionClauseError`, like any misuse).
`tenant_wide_admin_user_ids/1` returns the set, sorted ascending; `count_tenant_wide_admins/1` is
the same query with `count(u.id, :distinct)` instead of the id select (one shared private query
builder, `tenant_wide_admins_query/2`, so the two can never diverge). The scope filter #2533 needs
is the extension point of §6.2a, not a new argument. Justification for the id list (0053 D6, ORCH
asked to keep it, so former OQ-4 is closed): `solo_audited` requires exactly one tenant-wide admin,
and the self-publish rule must also know whether that admin IS the publishing author; only the id
list answers that, from the same definition, in the same transaction.

```
@spec tenant_wide_admins_query(prefix :: String.t(), now :: DateTime.t()) :: Ecto.Query.t()
```

(private; builds the §6.2 query including the §6.2a step).

### 6.2 Definition

Distinct `users.id` in `prefix` where `users.status == :active` AND at least one of:
1. a `group_members` row joins a `tenant_role` row with `name == "TENANT_ADMIN"` and
   `kind == :platform_role` on `group_id`;
2. an `api_tokens` row with `user_id == users.id`, `"TENANT_ADMIN"` in `roles`, `revoked_at` nil,
   and (`expires_at` nil OR `expires_at > now`), where `now = DateTime.utc_now()` taken once per call
   (the same clock and the same strict comparison as `verify_api_token/2`, `identity.ex:1711`).

Shape: one query, `users` filtered by status with two `exists(...)` subqueries combined with `or`,
array membership through a parameterized `fragment("? = ANY(?)", ^"TENANT_ADMIN", t.roles)`
(INV-7; no string interpolation). `api_tokens.user_id` is NOT NULL with an FK to `users`
(migration `20260823000001`, `ApiToken.insert_changeset` `validate_required :user_id`), and no user
delete exists, so every token has an owner and an inner condition on the owner is complete.

Not counted: `PLATFORM_ADMIN` (dropped outside the platform tenant at role resolution; whether it
implies tenant administration inside the platform tenant is OQ-1), inactive users (0051 N1 "counts
only active admins"; note F1 means an inactive user's TA token still authenticates today, so after
F1 is fixed the helper and the auth pipeline agree), revoked or expired tokens, routing roles.

### 6.2a Extension point: `exclude_scoped_holders/2` (for 0051 / #2533)

```
@spec exclude_scoped_holders(query :: Ecto.Query.t(), prefix :: String.t()) :: Ecto.Query.t()
```

Private, in `Letflow.Identity`, applied by `tenant_wide_admins_query/2` to the `users` query as
its LAST step, before the select. Purpose: 0051 counts only TENANT-WIDE admins (N1, D6 "tenant-wide
TENANT_ADMIN users"); a holder whose TENANT_ADMIN is limited to an org scope must not count. Today
there is no `role_scope_grants` table (0051 stage 1, #2533, is not built), so every grant is
tenant-wide and the function returns `query` unchanged. Its leading comment block (private
functions carry no `@doc`) states: "0051 / #2533: when `role_scope_grants` exists, add the
predicate that removes a user whose only TENANT_ADMIN source is a scoped grant; until then this is
the identity. `count_tenant_wide_admins/1` and `tenant_wide_admin_user_ids/1` both pass through
here, so the predicate is added once." The public `@doc` of `count_tenant_wide_admins/1` names
this step and #2533.

Proof it is a no-op today: T-34 (a tripwire that `role_scope_grants` does not exist in a tenant
schema, so #2533 must revisit this step when it adds the table) and T-35 (the helper's result
equals an independent oracle over every holder type).

### 6.3 Transaction safety

The helpers open no transaction, take no lock (not even `lock_tenant_admins!/1`; locking is the
caller's job), write nothing and call only `Repo` (which, inside a caller's `Repo.transaction`,
runs on the caller's connection). They raise on a DB error like every
other read here (`list_effective_role_names/2`); inside a transaction that aborts the caller, which
is the correct outcome for a guard. They are callable at any point of a caller's transaction and
see the caller's own uncommitted writes.

### 6.4 What the 0051 N1 guard should lock (guidance only; the guard is NOT built here)

Revision 1 (SEC-B2) replaces the earlier "lock the TA row filtered by kind" guidance, which was
unsound: a lock filtered by `kind == :platform_role` matches nothing once the binding was converted
to `:process_routing_role`, and with no binding there is nothing to lock at all.

Protocol for every count-REDUCING path, inside the one transaction that performs the reduction:
1. **First locking statement:** `Identity.lock_tenant_admins!(prefix)` (§6.6; Revision 1b exports
   it, replacing the inline `hashtextextended` query of Revision 1). It exists whether or not any
   binding exists, and it is released at commit/rollback.
2. **Then** the `tenant_role` row locked **by name only** (`name = "TENANT_ADMIN"`, no `kind`
   filter), `FOR UPDATE`; it may be `nil` (no binding), which is fine because step 1 already
   serialises. `rebind_role/4` locks the same row by id (`role_registry.ex:557`), which is the same
   row lock.
3. **Then** the business rows the path already locks or writes (the group `KEY SHARE`/`FOR UPDATE`
   of §3.0, the `users` row in `update_locked_user/5`, the `api_tokens` row, the pending grant row).
4. **Then** the audit chain lock (taken last by `insert_entry/3`).
5. **Write first, then count, then decide:** perform the reduction (delete the membership, set the
   user inactive, revoke the token, move or convert the binding), then call
   `count_tenant_wide_admins/1` in the same transaction, and if it returns 0, `Repo.rollback` with the
   zero-admin error. The guard does not predict the effect of a write; it measures the state the
   write produced, so every interaction (a member who also holds a token, a role on two paths) is
   counted by the one definition of §6.2.

Count-reducing paths: `remove_group_member/3` on the TA group; user deactivation
(`update_locked_user/5`, including `PATCH /users/:id` per N1); `revoke_token/2` of a TA token;
`rebind_role/4` of the TA binding; `upsert_role/4` converting the TA binding's `kind` (found here,
not on N1's list, audited as `role_binding.kind_changed`); pending-grant revoke (per N1's list);
`delete_group/2` of the TA group (cannot reduce today, it refuses a group with members, but stays
on the list for N1). Revision 1b: the admin-ADDING paths take the same lock too (§6.6), so a
0053 D6 check that holds it sees a stable admin set. Under READ COMMITTED (the default) every
statement takes a fresh snapshot, so a count read after the lock sees every committed change made
under the lock before. Passive token expiry cannot be locked; N1 evaluates at action time only.

The `@doc` of `count_tenant_wide_admins/1` states this protocol in short form: "`lock_tenant_admins!/1`
first, then the TENANT_ADMIN role row by name, then the group row, then business rows, then the
audit chain; write, then count, then roll back on 0". This resolves former OQ-2.

**Note (supervisor ruling, 2026-10-15).** The guard rule is a TRANSITION: count before the write > 0 AND count after the write == 0, then roll back. It is not a bare "after == 0", so a tenant that already has zero tenant-wide admins is not blocked from repairing itself. Exception: revoking the LAST OPEN pending admin grant is refused while the count is 0, because that grant is the recovery path. The rule applies to #2564 (deactivation) and #2533 PR 1b (REQ-497 AC9-AC11) alike. Both write `tenant_admin.guard_refused` through #2564's `Identity.record_guard_refused/2`, whichever merges second.

### 6.5 "Used by" (AC3)

Neither consumer exists (no `last_admin`/`solo_audited`/`scripts.sod` code on this branch; #2533
and #2534/#2535 open). Per ruling 6 this change ships the API, its tests, and the contract: the
`@doc` of `count_tenant_wide_admins/1` states it is the single required source for the 0051 N1 guard and
the 0053 D6 / open point 9 eligible-publisher check, and §6.4 above. ORCH records the contract on
#2533 and #2534 when the PR opens.

### 6.6 The tenant admin lock (Revision 1b)

```
@spec tenant_admin_lock_key(prefix :: String.t()) :: integer()
@spec lock_tenant_admins!(prefix :: String.t()) :: :ok
```

**Existing advisory-lock keys (Grep `pg_advisory` over `lib/`, `priv/`, `test/`):**

| Site | Function | Key space | Key |
|---|---|---|---|
| `tenant_provisioning.ex:307`, `:1503`, `:2307` | `pg_advisory_xact_lock` | single bigint | `hashtext(schema_name)` (an int4, so within [-2^31, 2^31)) |
| `ordering/consumer.ex:114` | `pg_try_advisory_xact_lock` | single bigint | `:erlang.phash2(correlation_id, 2_147_483_647)` (within [0, 2^31)) |
| `login_directory.ex:508` | `pg_advisory_xact_lock(int, int)` | two-int (separate space in Postgres) | `(435_001, hash)` |
| `test/support/tenant_template.ex:149` | `pg_advisory_lock` | single bigint | `hashtext(template schema literal)` (int4) |
| `test/letflow/identity_migration_test.exs:98` | `pg_advisory_lock` | single bigint | `hashtext("letflow:test:iss0060_tenant_schemas_guard")` (int4) |
| `test/support/bpm_default_realm_displacement.ex:242` | `pg_advisory_lock` | single bigint | `847_331_009` (< 2^31) |

Every existing single-bigint key lies within [-2^31, 2^31).

**Derivation of `tenant_admin_lock_key/1`** (pure Elixir, no DB): take
`:crypto.hash(:sha256, "letflow:tenant_admin_lock:v1:" <> prefix)`, read its first 8 bytes as a
signed 64-bit big-endian integer `k`; if `k` lies within [-2^31, 2^31), return
`Bitwise.bxor(k, 0x4000_0000_0000_0000)` (sets bit 62, moving it out of that range; the result is
still a valid signed 64-bit value), else return `k`.
- Stable: SHA-256 and the fixed versioned label do not depend on node, release, BEAM version or
  Postgres version (unlike `hashtext`, whose output Postgres does not promise across versions).
- Tenant-unique: the input is the tenant's schema name (unique per tenant, derived from the tenant
  UUID); two schemas collide only on a 64-bit hash collision (negligible), and a collision would
  only over-serialise two tenants, never under-lock one.
- No collision with existing keys: the result is never within [-2^31, 2^31), where every existing
  single-bigint key lies; the two-int key space (login directory) is disjoint by Postgres design.
  The `v1` label lets a future change re-key deliberately.

**`lock_tenant_admins!/1`**: if `Repo.in_transaction?()` is false, raise `ArgumentError` with the
fixed message `"lock_tenant_admins!/1 must run inside a transaction"`; else
`Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [tenant_admin_lock_key(prefix)])`
(bound parameter, INV-7) and return `:ok`. Blocks until acquired; respects a caller's
`SET LOCAL lock_timeout` (the pending bind's). `Repo.in_transaction?/0` is false for a plain test
process under the SQL sandbox (`login_directory_test.exs:407` relies on the same fact), so the
raise is testable.

**Where this PR takes it.** Rule: the call is the first locking statement of the transaction,
before any row lock. For member add/remove the lock is taken ALWAYS, on any group, not only when
the group carries TENANT_ADMIN. Reason: whether a group carries TA is known only by reading
`tenant_role`, and a binding can be created, converted or moved onto that group between that read
and the membership write (a TOCTOU window); taking the lock first and unconditionally closes it.
Cost is negligible: every one of these paths already writes an audit row, and audit inserts
already serialise per tenant on the audit chain lock (`audit.ex:284-301`); the advisory lock only
moves that per-tenant serialisation to the start of the transaction. The same reasoning applies to
sync, tokens and bindings.

| Path | Function | When the lock is taken | Notes |
|---|---|---|---|
| member add (any group) | `Identity.add_group_member/3` | first statement of its transaction, always | re-entrant when the caller already holds it (pending bind) |
| member remove (any group) | `Identity.remove_group_member/3` | first statement, always | |
| IdP sync | `Identity.sync_role_claims_from_token/3` | first step of its Multi when `group_ids != []` (it writes nothing otherwise) | covers a TA group and any other; TOCTOU-free |
| binding create / kind change | `RoleRegistry.upsert_role/4` (`do_upsert_role/4`) | first statement, before `lock_role_by_name/2`, always | |
| seed binding | `RoleRegistry.ensure_platform_role_binding/2` | first statement of its own transaction, before its `lock_role_by_name/2` (`role_registry.ex:280`), so the nested `upsert_role/4` call re-enters | needed to keep the order: without it the nested call would take the advisory lock AFTER a role row |
| rebind | `RoleRegistry.rebind_role/4` | first statement, before `lock_role_by_id/2`, always | |
| token mint | `Identity.create_token/3` (`insert_token`) | first step of its Multi, always (any roles) | roles come from the request, but "always" keeps one rule |
| token revoke | `Identity.revoke_token/2` | first step of its Multi, always | the token's roles are read before the transaction; "always" removes the window where `TenantAdminMigration` rewrites `PLATFORM_ADMIN` -> `TENANT_ADMIN` concurrently |
| pending-admin-grant bind | `PendingAdminGrants.transact_bind/8` | new Multi step right after `:lock_timeout`, before `:grant` | bounded by the existing `SET LOCAL lock_timeout`; a timeout is a fault -> `:noop`, marker stays nil, next login retries |
| TenantAdminMigration | `real_tenant/4` | first statement of the per-tenant transaction (before `plan/1`) | dry run takes no lock (reads only) |
| group delete | `Identity.delete_group/2` | wraps its `delete_all` in a `Repo.transaction/2` whose first statement is the lock, always | the existing FK-violation `rescue` stays outside the transaction (the transaction re-raises after rolling back), so `{:error, :bound_to_role}` is unchanged; the "do not call inside an open transaction" precondition stays |

**Paths that do NOT take it in this PR, and their residual window:**
- User deactivation / reactivation (`update_user_status/3`, `PATCH /users/:id`): out of scope
  (ruling 5). Until #2533 adds the lock (N1 list), a deactivation can commit between a lock
  holder's count and its commit, so a D6/N1 decision can be off by that one user for the length of
  the holder's transaction.
- Pending-grant revoke (`PendingAdminGrants.revoke/3`): removes a FUTURE grant only (no current
  admin changes); #2533 adds it per N1. No window on the current count.
- Passive token expiry: time-based, cannot be locked. Window: a token that expires during a lock
  holder's transaction is counted by a read before `expires_at` and not by one after.
- RoleBackfill marker reset: changes no membership; the re-grant it enables happens in a later
  sync, which takes the lock.
- Writes outside `lib/` (raw `Repo.insert` in test fixtures): not production paths.

**No deadlock cycle (proof).** Locks are ranked A (advisory, per tenant) < R (`tenant_role` row)
< G (`groups` row) < B (business rows: `group_members`, `users`, `api_tokens`,
`pending_admin_grants`) < C (audit chain lock; tenant chain, then platform chain for the pending
bind).
1. Every transaction that takes A takes it before any row lock (table above). So no transaction
   ever waits for A while holding R, G, B or C, and A can only appear in a wait-for graph as
   "waits for A, holds nothing". Such a node has no outgoing hold edges, so A is in no cycle.
2. Two transactions that both take A for the same tenant are mutually exclusive after A: one
   cannot hold any of R/G/B/C of that tenant while the other is past A. So no cycle among
   A-takers. In particular `rebind_role/4` (A, R by id, G `FOR SHARE`, C) and `do_upsert_role/4`
   (A, R by name, G `FOR UPDATE`, C) can never interleave, and the new group `FOR UPDATE` is only
   ever taken under A.
3. A-taker vs non-A-taker: within A, every path acquires R -> G -> B -> C, except the pending bind,
   which takes B (grant, user) before the FK `KEY SHARE` on G (membership insert). A cycle would
   need a non-A-taker that holds a G lock conflicting with `KEY SHARE` (i.e. `FOR UPDATE` on a
   group, or a group row update/delete) while waiting for B rows or for C held by the A-taker.
   After this PR every lib writer of a `groups` row lock of that strength (`do_upsert_role/4`,
   `delete_group/2`) takes A. Remaining non-A-takers in this area (user status updates: `users`
   row then C; `create_group/2`: inserts a new row) take at most one of B, then C, which is the
   pre-existing order; C is always last for everyone. So no cycle exists.
4. Cross-tenant: different A keys and disjoint schemas; the only shared lock is the platform audit
   chain, which every taker acquires last (pending bind: tenant C then platform C, as today).

## 7. No new grant path (AC4)

- No new route, no new public write function. The only public additions are two read-only
  helpers (§6) and one pure module (§2.2).
- The new `opts` keys change only what is AUDITED, never what is WRITTEN: `:audit_context`
  feeds actor/trace/source; `:group_member_audit` suppresses one audit row and is refused outside a
  transaction. No key widens a permission, skips a guard, or reaches a write the caller could not
  already make. Router authorization (macros, `with_platform_admin_*_guard`, H1/H2, token
  platform-scope checks) is untouched and still runs before any call.
- `insert_or_fetch_group_member/3` switches `Repo.insert` to `Repo.insert_all` with the same
  conflict target: identical rows written, identical `created` result.
- Sync: same gate, same group resolution, same marker rule. Backfill: same gate, same `update_all`.
- Existing audited paths keep their event names and payloads; they only gain `trace_id` (and, for
  tokens, `actor_id`). The pending bind writes no extra event (T-17).

## 8. Tests (TEST-DESIGNER brief)

New files: `test/letflow/identity/gh2547_ta_audit_paths_test.exs` (context level) and
`test/letflow/routers/identity_gh2547_audit_test.exs` (HTTP level: actor and trace from the request;
send `x-trace-id: <fixed uuid>` and assert the audit row's `trace_id` equals it).
`test/letflow/identity/tenant_wide_admins_test.exs` for the helper and the lock (T-20..T-28, T-32..T-35). Each path test asserts: exactly
one row with the action, `actor_id`, `resource_id` (target user), `trace_id` non-nil and as
expected, before/after keys and values per §3, and `Audit.verify_chain/1` still `{:ok, :valid}`.

| Id | Test |
|---|---|
| T-01 | `POST /groups/:id/members` to the TA-bound group -> 201, one `group_member.added`, actor = caller, trace = header, `group_roles` contains `TENANT_ADMIN`, `roles_gained == ["TENANT_ADMIN"]`, `source "api"` |
| T-02 | same to a group carrying no role and to a routing-role group -> one event each, `group_roles` `[]` / the routing role, `roles_gained == []` |
| T-03 | re-add an existing member -> 200, no new event |
| T-04 | `DELETE /groups/:id/members/:user_id` on the TA group -> 204, one `group_member.removed`, `roles_lost == ["TENANT_ADMIN"]`; second case: removing a TA member from a roleless group -> one event, `roles_lost == []`, `user_platform_roles` still contains `TENANT_ADMIN` |
| T-05 | remove a non-member -> 204, no event |
| T-06 | `POST /roles/:id/rebind` of the TA binding -> `role.rebound` `trace_id` = header; the existing assertions in `identity_role_rebind_test.exs` unchanged |
| T-07 | `POST /roles` creating the TA binding (after deleting the seeded one in the fixture) over a group with 2 members -> one `role_binding.created`, `granted_user_ids` both, actor, trace |
| T-08 | same over an empty group -> no event |
| T-09 | TA caller, `POST /roles` with the name, group and opposite `kind` of an existing binding whose group has members (e.g. the seeded `PROCESS_OPERATOR` binding re-posted as `process_routing_role`, after adding a member) -> one `role_binding.kind_changed`, `affected_user_ids` = the members; the same re-post on an empty group -> no event |
| T-10 | pending-grant first login with `x-trace-id` -> both bound events carry that trace; payloads equal the pre-change pins |
| T-11 | first OIDC login with a TA claim (and one other claim) -> one `group_member.added` per inserted row, actor = the user, `source "idp_sync"`, trace = header; no claim string other than a `tenant_role` name in any payload |
| T-12 | `RoleBackfill.run/0` on a `:seeded` tenant with 2 synced users and 1 unsynced -> one `role_claims_sync.reset`, `users_with_marker` = the 2, `reset_user_ids` = all 3, `reset_count == 3`, trace a UUID; return value identical to the pre-change shape; an `:unchanged` tenant gets no event |
| T-13 | `TenantAdminMigration.run/1` -> every row of the run has the same non-nil `trace_id`, actor `nil`; payload pins of `tenant_admin_migration_test.exs` unchanged; with a pre-populated `TENANT_ADMIN` group and no binding -> also one `role_binding.created` |
| T-14a / T-14b | `POST /tokens` with `["TENANT_ADMIN"]` and `DELETE /tokens/:id` -> `token.create` / `token.revoke` with actor = caller, trace = header; `after_state` keys unchanged, no `token_hash` |
| T-15 | no-strip: user synced with a TA claim (marker set) logs in again with a token lacking it -> still TA (`list_effective_role_names`), membership row present, no `group_member.*` event written by that login |
| T-16 | manual TA member (added via the route, marker nil) first OIDC login with only a `PROCESS_DESIGNER` claim -> TA membership kept, PROCESS_DESIGNER added (one event), no removal event |
| T-17 | AC4: pending bind writes exactly `["tenant.admin_grant.bound"]` new in the tenant chain and `["platform.tenant_admin_grant.bound"]` in the platform chain, no `group_member.added` |
| T-18 | the opt-out: `add_group_member(..., group_member_audit: :caller_audits)` outside a transaction -> `{:error, :caller_audit_requires_transaction}`, no row; inside a transaction -> row, no event; an unknown value (e.g. `:bogus`) -> treated as `:emit`, one event. Source scan over every `.ex` file under `lib/` (excluding `lib/letflow/design/`): (a) the token `group_member_audit` (any form: `group_member_audit:` keyword, `:group_member_audit` atom in `Keyword.put`/`Keyword.merge`/a map, a string) appears only in `lib/letflow/identity.ex` and `lib/letflow/identity/pending_admin_grants.ex`; (b) in `pending_admin_grants.ex` every occurrence is exactly the keyword followed by the literal `:caller_audits` (a variable, function call, module attribute or any other non-literal value fails the test); (c) `pending_admin_grants.ex` has exactly one occurrence |
| T-19 | audit failure rolls back. **Injection (raising):** a trigger on `audit_entries` that raises for a chosen action (the `pending_admin_binding_test.exs:733` pattern); this makes `insert_entry/3` RAISE a `Postgrex.Error`. **Injection (non-raising):** inside the test's sandbox transaction, `ALTER SCHEMA <tenant schema> RENAME TO gh2547_<hex>` (DDL is transactional and never commits), then call the context function with `prefix: "gh2547_<hex>"`: every table is still there, and `insert_entry/3` returns `{:error, :invalid_schema_name}` without a DB call (`tenant_provisioning.ex:243-256`); the test module is `async: false`. Assertions: **HTTP (raise)**: add -> response status 500 (the §3.0 rescue returns `{:transaction_failed, _}`, nothing reaches `Plug.ErrorHandler`), and `group_members` has no row; remove -> 500, the row is still there; upsert -> 500, no `tenant_role` row. **Context (non-raising)**: `add_group_member/3` -> `{:error, {:audit_failed, :invalid_schema_name}}`, no row; `remove_group_member/3` -> same tag, row kept; `upsert_role/4` -> `{:error, {:audit_failed, :invalid_schema_name}}` (populated group), no binding. **Sync**: (i) raise on the FIRST audit -> returns the original user struct (no raise), no membership, `role_claims_synced_at` nil, log has no exception message; (ii) SEC-A3: user claims two roles bound to groups g1, g2; the trigger raises only when `NEW.after_state->>'group_id' = g2` -> neither g1 nor g2 membership remains, marker nil, no `group_member.added` row; (iii) non-raising via the schema rename -> same outcome. **Marker reset (raise)**: `RoleBackfill.run/0` -> `{:error, {:backfill_failed, tenant_id, {:unexpected_exception, %Postgrex.Error{}}}}` (the existing rescue, `role_backfill.ex:156-163`), every marker unchanged |
| T-19b | lock pin (CDV-2): with `SandboxAutoMode` (the `iss0979_audit_chain_lock_test.exs:46-73` precedent, real separate connections, bounded waits), process A opens a transaction and takes `SELECT ... FROM groups WHERE id = g FOR UPDATE` and holds it; process B calls `add_group_member(g, u, ...)`; assert B has not returned after 300 ms, release A (rollback), assert B returns `{:ok, %{created: true}}` within 5 s. Second case: A opens an outer `Repo.transaction`, calls `upsert_role/4` binding a role to g inside it (the nested transaction keeps the group lock until A's outer transaction ends) and waits for a message before committing; B's `add_group_member(g, u2, ...)` has not returned after 300 ms; A commits; B returns within 5 s and B's `group_member.added` `after_state.group_roles` contains the new role. Every wait is bounded; both tasks are awaited or killed in `on_exit` |
| T-19c | `AuditContext.normalize_trace_id/1` (SEC-A1): 300 ASCII chars -> first 255; 254 ASCII + one 3-byte char + 10 more -> 255 codepoints ending on a codepoint boundary, `String.valid?` true; a 256-byte header value cut mid-codepoint (invalid UTF-8) -> `nil`; `""`/non-binary -> `nil`; HTTP: a request with a 256-byte `x-trace-id` adds a member and the row stores at most 255 chars (no 500) |
| T-20 | helper counts distinct users: 2 TA members -> 2 |
| T-21 | inactive TA member excluded; inactive owner of a valid TA token excluded |
| T-22 | revoked TA token excluded; token with `expires_at` in the past excluded; `expires_at` in the future counted; `expires_at` nil counted |
| T-23 | token-only admin (no membership) counted |
| T-24 | user who is a TA member AND owns a TA token counted once (count 1, ids `[u]`) |
| T-25 | called inside `Repo.transaction` after `lock_tenant_admins!(prefix)` and an uncommitted `add_group_member` in the same transaction -> sees it; works after `SELECT ... FOR UPDATE` on the TA `tenant_role` row; outside any transaction the helper also works (it opens none); `pg_locks` shows no advisory lock held by the test connection after a bare helper call (the helper takes none) |
| T-26 | non-TA tokens / members of other platform-role groups / `PLATFORM_ADMIN` token -> not counted |
| T-27 | tenant isolation (SEC-A2): tenant B has one membership-only admin and one token-only admin; tenant A has one admin; A's count is 1 and A's ids exclude both B users; B's count is 2 |
| T-28 | `tenant_wide_admin_user_ids/1` sorted, equals the set behind the count |
| T-29 | AC4 regression: existing suites pass unchanged: `pending_admin_binding_test`, `pending_admin_grants_test`, `tenant_admin_migration_test`, `role_backfill_test`, `role_registry_test`, `identity_role_rebind_test`, `identity_roles_guard_test`, `platform_escalation_guard_test`, `iss0736_oidc_live_revocation_test`, `iss0778_platform_role_seeding_e2e_test`, `audit_dispositions_test`, `audit_capture_test`, `identity_test` (context and router), `api_token_auth_pipeline_test`, onboarding router tests |
| T-30 | `token.create` / `token.revoke` action strings and `after_state` key sets equal the pre-change ones |
| T-31 | onboarding of a fresh tenant writes no `role_binding.created` (all seed groups empty) |
| T-32 | lock key: `tenant_admin_lock_key(p)` equals itself across 3 calls and equals a value pinned in the test (stability across releases); differs for two tenant schemas; for 1,000 generated `tenant_<32 hex>` names every key lies outside [-2^31, 2^31) and all are distinct |
| T-33 | lock blocks an admin-adding path (representative: `add_group_member/3` to the TA group), `SandboxAutoMode` as in T-19b: process A opens a transaction and calls `lock_tenant_admins!(prefix)`; process B calls `add_group_member`; B has not returned after 300 ms; A rolls back; B returns `{:ok, %{created: true}}` within 5 s. Control: A holds the lock of ANOTHER tenant's prefix -> B returns at once. `lock_tenant_admins!/1` outside a transaction raises `ArgumentError`; inside one, a second call in the same transaction returns `:ok` at once (re-entrant). All waits bounded; tasks killed in `on_exit` |
| T-34 | extension-point tripwire: no table `role_scope_grants` exists in a provisioned tenant schema (`information_schema.tables`); the test's failure message names `exclude_scoped_holders/2` and #2533 |
| T-35 | extension point is a no-op today: a tenant with one holder of every kind (membership-only, token-only, both, inactive member, revoked/expired token owner, non-TA member) -> `tenant_wide_admin_user_ids/1` equals an oracle computed in the test from the fixture's own definition (no shared code), and `count_tenant_wide_admins/1` equals its length |
| T-36 | pending bind under the lock: with process A holding `lock_tenant_admins!` for longer than the bind's existing `SET LOCAL lock_timeout` (`@lock_timeout "2s"`, `pending_admin_grants.ex:54`; A holds about 3 s, bounded), the bind returns `:noop`, the grant stays open, marker nil; after release the next login binds |

Note for TEST-DESIGNER / TEST-RUNNER: `add_group_member/3` now writes audit rows by default, so a
test that calls it on a schema without `audit_entries`, or on a prefix not of the form
`tenant_<32 hex>` (`TenantProvisioning.tenant_id_for_schema_name/1`), will now fail where it
passed. `create_token/3` already has this exposure, so most fixtures are fine; any failure of that
kind in T-29 is a fixture issue, not a behaviour change, and must be reported as such.

## 9. Points for SECURITY-REVIEWER

- **Audit completeness (the issue's "INV-4" gate)**: every grant/removal path in §1 writes a row in
  the same transaction; an audit failure rolls back the write (500 on HTTP, safe no-op on login,
  halt on CLI). Default-on in the context functions so a new caller cannot silently skip it.
- **INV-4 (no secrets in audit)**: token payloads keep excluding `token_hash`; the plaintext never
  reaches any new code. New payloads carry ids, role names, counts and fixed strings only: no
  e-mail, username, display name, IdP claim value (0051 N3), or token data.
- **INV-6 (scoping of the new read path)**: `count_tenant_wide_admins/1` / `tenant_wide_admin_user_ids/1`
  take `prefix` positionally (binary guard, no default), pass it to the single `Repo` call, join only tenant-schema
  tables (`users`, `group_members`, `tenant_role`, `api_tokens`), and are not exposed by any route
  in this change. T-27 proves isolation.
- **INV-7**: the array check is a parameterized fragment, no interpolated SQL.
- **Actor** always comes from the DB-resolved `auth_context` (or the provisioned user for sync,
  `nil` for CLI), never from a request value.
- **Trace id** may come from the client `x-trace-id` header (truncated to 256 bytes,
  `api/context.ex:110`); it is stored as correlation data and covered by the chain hash. It is never
  an authorization input. Existing routers already store it this way (`onboarding.ex:523`). Before
  it reaches an audit row it passes `AuditContext.normalize_trace_id/1` (≤255 codepoints, valid
  UTF-8 or `nil`), so a hostile header cannot make an admin write fail (SEC-A1, T-19c).
- **Raise safety** (§3.0): every new audit write is covered for both `{:error, _}` and a raise;
  the login path never raises and never leaves a partial grant (T-19 sync cases); rescue logs carry
  no exception message.
- **Race safety** (§3.0, §3.4): binding writes lock the group `FOR UPDATE` after the role row, so
  the recorded `granted_user_ids` / `group_roles` cannot miss a concurrent membership change (T-19b).
- **The opt-out** (`group_member_audit: :caller_audits`) is the one place an audit row can be
  suppressed: refused outside a transaction, single legitimate caller pinned by T-18, and the caller
  writes its own event in the same transaction.
- **Strip KEEP** means an IdP-side TA removal has no effect after the first sync; the Letflow-side
  removal is the control and is audited. The RoleBackfill reset is the one path that re-opens the
  sync, and it is now audited (§3.8).

## 10. Open questions and their status (Revision 1, CDV verdicts)

Accepted defaults (CDV, revision 1):
- **OQ-1 (accepted)** Platform tenant: `PLATFORM_ADMIN` holders do not count; only the literal
  `TENANT_ADMIN`.
- **OQ-2 (resolved)** by the §6.4 rewrite: the advisory lock on the tenant schema is taken first,
  so a missing binding row no longer leaves the guard without a lock.
- **OQ-5 (accepted)** Onboarding seed trace may be `nil` if provisioning runs outside the request
  process; only fires for a populated group, which a fresh tenant never has (T-31).
- **OQ-6 (accepted)** `mix letflow.seed.exam_fixtures` mints CANDIDATE tokens with no trace; not a
  TA path; unchanged.
- **OQ-7 (accepted)** Payload size of `role_claims_sync.reset` (two id lists, about 37 bytes per
  user each); one-off operator action, and the list is the target set AC1 asks for.

Closed by the ORCH amendment (Revision 1b):
- **OQ-4 (closed)** `tenant_wide_admin_user_ids/1` is kept by ORCH's binding amendment; the 0053 D6
  justification is in the Contract section and §6.1. No longer routed to REVIEWER.

Residual windows (Revision 1b, stated in §6.6, not open questions): user deactivation and
pending-grant revoke are not under the lock until #2533; passive token expiry cannot be locked.

Follow-ups (accepted as not in this change; ORCH files them):
- **FU-1 (was OQ-3)** RoleBackfill partial failure: if the marker-reset transaction fails (now also
  on an audit failure) after the seed committed, a re-run classifies the tenant `:unchanged` and
  never resets its markers. Pre-existing shape for any reset failure. This change only adds a
  moduledoc note in `role_backfill.ex` stating it.
- **FU-2 (was OQ-8)** `create_token/3` / `revoke_token/2` return a non-raising audit failure as a
  bare `{:error, reason}` that the router has no clause for (pre-existing, `identity.ex:1540`,
  `:1668`); a raise is already `{:transaction_failed, _}` -> 500. Not changed here (AC4).

## 10a. Revision 1 changelog (CODE-DESIGN-VALIDATOR + SECURITY-REVIEWER FAIL, round 1)

| Blocker / advisory | Change | Sections |
|---|---|---|
| CDV-1 raising audit writes | New §3.0 "Raise handling" table: rescue at the outermost level for add/remove/upsert (`{:transaction_failed, _}` -> 500), sync rescues and returns the original user (no exception message logged), marker reset uses the existing `process_registration/2` rescue; nested callers turn errors into rollbacks | §3.0, §3.2, §3.3, §3.4, §3.6, §3.8 |
| CDV-1 sync `Enum.each` | `reduce_while` halting `{:error, {:audit_failed, _}}` on a non-raising failure; both error and raise roll back every membership of the call and keep the marker `nil` | §3.6 |
| CDV-1 T-19 expectations | T-19 states both injections (trigger = raise, schema rename = non-raising `{:error, :invalid_schema_name}`), exact HTTP result (500 via the rescue, not a `Plug.ErrorHandler` re-raise), no-row assertions, and the marker-reset value `{:backfill_failed, tid, {:unexpected_exception, %Postgrex.Error{}}}` | §8 T-19 |
| CDV-2 = SEC-B1 race | `do_upsert_role/4` locks role by name, then the group `FOR UPDATE`, before both the insert and the kind-change branch; `remove_group_member/3` takes `FOR KEY SHARE` on the group; `group_roles` is read AFTER the insert/delete; global lock order stated; lock-pin test added | §3.0, §3.1, §3.2, §3.3, §3.4, §8 T-19b |
| SEC-B2 N1 lock guidance | §6.4 rewritten: advisory xact lock keyed on the tenant schema first, then the TA role row by name only, then business rows, then the audit chain; write, then count, then roll back on 0; `@doc` wording given; OQ-2 resolved | §6.4, §3.0, §10 |
| CDV advisory: T-18 scan | scan covers every form of the `group_member_audit` key and fails on any non-literal value; unknown values fall back to `:emit` | §3.2, §8 T-18 |
| CDV advisory: arities | `insert_or_update_role/5`, `insert_role/5`, `converge_existing_role/5`, `audit_binding_write/4`, `group_member_ids/2` specified; ctx passed explicitly, member check inside `audit_binding_write/4` | §3.4 |
| CDV advisory: re-select | `member` re-selected with `get_group_member/3` after `insert_all` | §3.2.1 |
| SEC-A1 trace length | `AuditContext.normalize_trace_id/1` (≤255 codepoints, valid UTF-8 or `nil`) + test | §2.2, §8 T-19c, §9 |
| SEC-A2 isolation | T-27 uses a membership-only and a token-only admin in tenant B | §8 T-27 |
| SEC-A3 partial sync | T-19 sync case (ii): second group's audit fails after the first insert; neither membership remains | §8 T-19 |
| SEC: other paths | `IdentityMigration` (cannot run, legacy tables dropped) and the missing minter role check (0051 M2 / #2533) noted | §1 |
| OQ verdicts | OQ-1, OQ-5..OQ-7 accepted; OQ-2 resolved; OQ-4 to REVIEWER; OQ-3, OQ-8 now FU-1, FU-2 | §10 |

## 10b. Revision 1b changelog (ORCH binding helper-contract amendment)

| Amendment item | Change | Sections |
|---|---|---|
| (1) rename, positional prefix | `count_tenant_wide_admins(prefix)`, `tenant_wide_admin_user_ids(prefix)`; one shared private query builder | Contract, §6.1, §0, §2.6, §8, §9 |
| (2) semantics | unchanged; deactivated users' tokens not counted (#2557 noted) | Contract, §6.2 |
| (3) scoped-holder extension point | private `exclude_scoped_holders/2`, identity today, named for 0051 / #2533; tripwire + oracle tests | §6.2a, §8 T-34, T-35 |
| (4) no transaction/lock in helper | stated; T-25 checks no advisory lock is left by a bare call | §6.3, §8 T-25 |
| (5) exported lock | `tenant_admin_lock_key/1` (SHA-256 derived, outside the int32 range of every existing bigint key; existing keys listed), `lock_tenant_admins!/1` (raises outside a transaction, re-entrant); taken first on every add/remove path incl. delete_group, always on member add/remove (TOCTOU reason); residual windows stated; deadlock proof covering `rebind_role/4`, `do_upsert_role/4` and the group `FOR UPDATE` | §6.6, §6.4, §3.0, §2.6 |
| (6) lock tests | key stability/uniqueness/range; held lock blocks `add_group_member/3`; other tenant's lock does not; pending bind times out safely | §8 T-32, T-33, T-36 |
| OQ-4 | closed (kept by ORCH) | §10 |

## 10c. Implementation notes (ELIXIR-DEV, step 04)

Non-blocking advisories folded in:

| Advisory | Implemented as |
|---|---|
| SEC-A4 | `AuditContext.normalize_trace_id/1` also returns `nil` when the value contains any Unicode `Cc` character (NUL, CR, LF, other C0/C1, DEL); checked after the UTF-8 validity check, before the 255-codepoint cut |
| SEC-A5 | `revoke_token/2`: the unlocked pre-read keeps the `:not_found` / already-revoked fast paths; the write runs in `Repo.transaction/2` (was an `Ecto.Multi`) that takes `lock_tenant_admins!/1`, re-reads the row `FOR UPDATE`, and builds `before_state` from that row. A token revoked concurrently between the two reads is returned unchanged with no write and no event. Error shapes unchanged (bare `{:error, reason}` for a changeset or a non-raising audit failure, FU-2) |
| SEC-A6 | `sync_role_claims_from_token/3`: when `group_ids != []` the Multi starts with `SET LOCAL lock_timeout = '2s'` (same value as `pending_admin_grants.ex` `@lock_timeout`) and then `lock_tenant_admins!/1`. A timeout raises out of `Repo.transaction/1` after the rollback and is caught by the §3.0 rescue: the original user is returned, marker `nil`, so the next login retries. Logged as fixed text plus prefix, user id and exception module |
| CDV-A2 | §6.6 note below |
| CDV-A3 | The `@doc` of `count_tenant_wide_admins/1` states that first logins with role claims serialise per tenant |

CDV-A2, the pending-bind deadlock note for §6.6: the pending bind takes the tenant admin lock as
its second Multi step (after `SET LOCAL lock_timeout`, before the grant row), and its
`add_group_member/3` call re-enters it. Its residual order inversion (B rows grant and user, then
the FK `KEY SHARE` on G) is covered by point 3 of the proof: every lib holder of a conflicting G
lock (`do_upsert_role/4` `FOR UPDATE`, `delete_group/2`) takes A first, so it cannot hold G while
the bind is past A. The bind's `lock_timeout` bounds any wait the proof does not cover (for
example a raw-SQL writer outside `lib/`): a timeout is a `:noop`, never a hang.

Deviations from the design (small, behaviour-preserving):
- §3.2.1: `insert_or_fetch_group_member/3` returns `{:error, :unexpected_missing_member}` instead
  of calling `Repo.rollback/1` itself. Callers turn it into a rollback (`add_group_member/3`) or a
  halted Multi step (sync). Reason: the sync calls it from inside `Multi.run/3`, where a
  `Repo.rollback/1` throw would bypass the Multi's `{:error, step, reason, changes}` shape. The
  row is still never assumed to exist.
- §3.4: `do_upsert_role/4` calls `lock_role_by_name/2` itself (step 2) and
  `insert_or_update_role/5` locks the same row again (a no-op in the same transaction); the design
  allowed either.
- §3.2: `add_group_member/3`'s group and user existence checks run inside the transaction, after
  the lock (they were outside any transaction before). Same results, same order.
- Not done here: README state diagram (no workflow transition changed).
- REVIEWER advisories (post-gate, no behaviour change): `add_group_member/3` reads `before_roles`
  only in `:emit` mode; `create_token/3` and `revoke_token/2` gained the GH 2547 `@doc` paragraph
  (lock first, re-read under the lock for revoke, actor + trace).

## 11. Sequencing

Merge after PR #2537 (this branch is stacked on its head 4560e623a). Overlap: `routers/identity.ex`
and `role_registry.ex` are edited by both; rebase on `main` once #2537 merges.
