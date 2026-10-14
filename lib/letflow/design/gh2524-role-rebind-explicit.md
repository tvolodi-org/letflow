# GH 2524: `POST /roles` no longer rebinds silently; rebinding is an explicit, audited action

Issue: GH 2524 (tvolodi-org/letflow, prio 1, security-relevant). Context, not scope: decision
draft 0051 M8 / D9 / D11 (letflow-2): "rebinding an existing routing role name to a different
group becomes an explicit audited action for a tenant-wide admin" (`role.rebound`).

## 1. Problem

`RoleRegistry.upsert_role/4` (`lib/letflow/identity/role_registry.ex`, `insert_or_update_role/4`)
inserts with `on_conflict: [set: [group_id: group_id, kind: kind]]`. `POST /identity/roles`
(`:RolesManage`, held by PROCESS_DESIGNER, TENANT_ADMIN, PLATFORM_ADMIN) therefore moves an
existing role name to another group with no separate action and no audit entry. A routing role's
group decides who receives and may complete a HUMAN_TASK (`tasks.ex`), so a PROCESS_DESIGNER can
change who approves, with no trace.

## 2. Callers (backward-compatibility inventory)

| Caller | What it sends | Effect of this change |
|---|---|---|
| `POST /roles` (router `handle_upsert_role/2`) | any name, any of the two kinds, a group | different group on an existing name: now 409 `role_already_bound`, nothing changes |
| `RoleRegistry.seed_default_platform_role_groups/1` (onboarding, `recover_provisioning/1`, `RoleBackfill`) | each platform role name with the group *named after it* | **changed (section 4.3)**: an existing binding keeps its group; the seed no longer moves an admin-chosen binding back |
| `TenantAdminMigration.ensure_binding(nil, _)` | `TENANT_ADMIN` only when no binding exists | unchanged (insert path) |
| `scripts/lib/seed_persona_actors_base.sh` `upsert_role` | routing role with the group found by name | unchanged on a re-run (same group: 200). If an admin rebound the name, the script now stops with its existing "POST ... failed" error instead of silently moving it back |
| web `rolesApi.create` (`web/src/api/identity.ts`) | defined, **no caller** in `web/src` | none |
| solution/definition install (`Letflow.Definitions.RoleBinding`) | reads `list_roles/1` only | none |

## 3. Behaviour (acceptance criteria of GH 2524)

1. **Create** (name not bound): unchanged. 200 with the role map.
2. **Same name, same group**: idempotent. 200 with the existing role, nothing written, no audit.
   `kind` keeps today's behaviour: a same-group re-post with the other `kind` still converts the
   kind (the existing H1/H2 guards and the REQ-447 seed guard are what protect built-in names;
   kind conversion is not a rebind and is out of this issue's scope).
3. **Same name, different group**: `POST /roles` answers **409** with detail
   `role_already_bound` (stable code; the body names no group), and no row changes.
4. **Rebind**: new route `POST /identity/roles/:id/rebind`, body
   `{"group_id": <uuid>, "reason": <string>}`.
   * Permission: policy key `:RolesRebind` -> permission `:UsersGroupsRolesManage` (the tenant
     admin permission: TENANT_ADMIN, and PLATFORM_ADMIN which holds every permission;
     PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, TENANT_AUDITOR do not hold it -> 403).
     When 0051 scopes exist, this key is the place where "tenant-wide" is enforced; nothing in
     this change pre-empts that.
   * Check order (ISS-1033: permission gate -> cast -> fetch -> guards -> body validation ->
     write) and the exact response of each step:

     | # | Step | Failure response |
     |---|---|---|
     | 1 | permission gate (macro, `:RolesRebind`) | 403 `insufficient permissions` (existing) |
     | 2 | `with_cast_id(conn, raw_id, ...)` | plain 404 (`Response.not_found/1`) |
     | 3 | lock the role row by id, tenant prefix | plain 404 (same as 2) |
     | 4 | H1 on the locked row's name (`Authorization.platform_admin_name?/1`) without platform scope | 403 `insufficient permissions` (`forbid_insufficient/1`) |
     | 5 | `reason`: must be a binary; `String.trim/1`; 1..500 codepoints; no `Cc`/`Cf`/`Zl`/`Zp` character | 422 `Response.unprocessable(conn, "invalid_reason")` (missing, non-string, blank, too long, control/format char: one code) |
     | 6 | `group_id`: must be a binary castable by `Ecto.UUID.cast/1` | 422 `Response.unprocessable(conn, "invalid_group_id")` (missing, non-string, malformed: one code; same shape as `POST /roles` today) |
     | 7 | target group exists (read with `lock: "FOR SHARE"`, tenant prefix) | plain 404 |
     | 8 | the role's `group_id` equals the target | 200 with the role, nothing written, no audit |
     | 9 | update `group_id` (changeset with `foreign_key_constraint(:group_id)`) and append the audit entry | changeset error: rolled back, 422 `validation failed` (today's `POST /roles` shape); audit error: rolled back, `{:error, {:audit_failed, reason}}`, 500 (server fault) |

     Steps 3-9 all run inside `RoleRegistry.rebind_role/4` in ONE `Repo.transaction/2`. The
     router does no body parsing beyond passing `conn.body_params["group_id"]` and
     `conn.body_params["reason"]` through unchanged (no `Validation.problem/1`), so exactly one
     place decides each 422. The 422 bodies carry the code only, never the submitted value.
   * Audit entry (step 9, same transaction; `Audit.insert_entry(Repo, attrs, prefix)` called
     inside the transaction function): `action: "role.rebound"`, `resource_type: "tenant_role"`,
     `resource_id: role.id`, `actor_id: conn.assigns.auth_context.user_id`,
     `before_state: %{"name" => n, "kind" => k, "group_id" => old}`,
     `after_state: %{"name" => n, "kind" => k, "group_id" => new, "reason" => trimmed}`.
     The entry's own `timestamp` is the UTC time.
   * 200 with the updated role map (same `role_map/1` allowlist as GET/POST /roles).

## 4. Implementation shape

**Every `Repo` call below passes `prefix: prefix` itself** (`Letflow.Repo` has no default
prefix; the transaction option alone is not enough), exactly as `role_registry.ex` does today:
the lock queries, the insert, the group reads, the update, and `Audit.insert_entry(Repo, attrs,
prefix)`.

### 4.1 `RoleRegistry.upsert_role/4` (same name and arity; contract narrowed)

`insert_or_update_role/4` becomes, inside the existing transaction:

```
locked = lock tenant_role by name (FOR UPDATE, prefix)
case locked:
  nil ->
    {:ok, inserted} = Repo.insert(changeset, on_conflict: :nothing, conflict_target: :name, prefix: prefix)
    # TenantRole autogenerates its id client-side, so a lost race still returns {:ok, struct}
    # with an id that is not in the table. Detect it the way insert_group/2 does: re-read by
    # name under lock and compare ids.
    row = lock tenant_role by name again
    row.id == inserted.id -> return row                          (created)
    otherwise             -> continue with `row` in the branches below
  row with same group_id and same kind -> return row               (idempotent, no write)
  row with same group_id, other kind   -> update kind only, return (today's behaviour)
  row with another group_id            -> Repo.rollback(:role_already_bound)
```

New error atom `:role_already_bound` added to `upsert_error()`. The `group_id` comparison is on
the canonical text from `Ecto.UUID.cast/1` (already done in `upsert_role/4`).

### 4.2 `RoleRegistry.rebind_role/4` (new)

```
@spec rebind_role(role_id :: Ecto.UUID.t(), group_id :: term(),
                  %{actor_id: Ecto.UUID.t() | nil, reason: term()},
                  opts :: [prefix: String.t(), platform_scope: boolean()]) ::
        {:ok, TenantRole.t()}
        | {:error, :role_not_found | :group_not_found | :invalid_group_id | :invalid_reason
                   | :platform_admin_outside_platform_tenant | Ecto.Changeset.t() | term()}
```

Runs steps 3-9 of the table above, in that order, in one transaction. `role_id` is already
canonical (the router cast it). `opts[:platform_scope]` defaults to `false` (fail closed). The
reason check uses `~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u` (C0, DEL, C1, U+2028/U+2029, and format/bidi characters such as
U+200B..U+200F, U+202A..U+202E, U+2066..U+2069, U+FEFF), so a reason cannot visually spoof an
audit reader. `actor_id` may be nil only for a non-HTTP caller; the router always passes the
caller's id.

### 4.3 Seed: `ensure_platform_role_binding/2` (new, private), race-free

`seed_names/2` calls, per name, a new private `ensure_platform_role_binding(name, opts)` that
does everything inside ONE `Repo.transaction/2`:

```
row = lock tenant_role by name (FOR UPDATE, prefix)
row == nil                        -> group = get_or_create_group_by_name(name, opts);
                                     upsert_role(name, :platform_role, group.id, opts)   (insert path)
row.kind == :platform_role        -> return row (keeps an admin-chosen group; never moves it)
row.kind == :process_routing_role -> rollback {:role_name_taken_by_routing_role, name}
```

and `check_guarded_names_free/1` is widened from `["TENANT_ADMIN", "TENANT_AUDITOR"]` to every
name of `seedable_role_names(prefix)` (same error shape
`{:error, {:role_name_taken_by_routing_role, name}}`, checked before any write, first by name
order). Reading under the same lock removes the read-then-upsert race (CODE-DESIGN-VALIDATOR
finding 6).

Why fail closed on a routing row (SECURITY-REVIEWER design finding 1): only `:platform_role` rows
grant permissions, so keeping a routing row's group while converting the kind would hand a
lower-privileged user's chosen group the built-in role (for `PLATFORM_ADMIN` in the platform
tenant: platform scope). Today's seed converted such a row and moved it to the group named after
the role; with 4.1 that move is no longer silent, so the seed refuses instead of granting or
rebinding.

Behaviour change, deliberate: before, the seed silently moved an existing `:platform_role`
binding back to the group named after the role ("repair"). That repair was incidental, not a
control; since H2 only `:UsersGroupsRolesManage` holders can create a built-in binding, and after
this change only the audited rebind route can move one. A built-in binding moved by a
PROCESS_DESIGNER before H2 now stays where it is; a one-time read-only listing of built-in
`:platform_role` bindings whose group is not the group named after the role is recommended to
the operator (infra/QA DB, not part of this change; recorded in the PR body).

Indirect seed callers (all keep working; they only see the new error on a routing-kind row with
a seedable name): onboarding (`tenant_onboarding.ex`, `{:role_seeding_failed, _}`),
`recover_provisioning/1`, `RoleBackfill` (classifies by role NAME only, so keeping a group does
not change `:seeded`/`:unchanged`), `mix letflow.seed`, `mix letflow.backfill_platform_roles`.

`TenantAdminMigration.ensure_binding(nil, _)`: unchanged except in a concurrent race where a
`TENANT_ADMIN` row with a different group appears mid-transaction; that is now
`:role_already_bound`, then its existing rollback `:unexpected_error`, instead of a silent
rebind.

### 4.4 Router

* `handle_upsert_role/2`: `{:error, :role_already_bound}` -> `Response.conflict(conn,
  "role_already_bound")`.
* `authz_post "/roles/:id/rebind", :RolesRebind` -> `handle_rebind_role(conn, raw_id, opts)`:
  `with_cast_id` -> `RoleRegistry.rebind_role(id, body["group_id"], %{actor_id:
  conn.assigns.auth_context.user_id, reason: body["reason"]}, Keyword.put(opts,
  :platform_scope, platform_scope?(conn)))` -> map the errors per the table in section 3.
  The moduledoc route list gains the line.
* `Authorization`: `endpoint_policy_key("POST", "/roles/:id/rebind") -> :RolesRebind` (next to
  the `/roles` clauses); `required_permission(:RolesRebind) -> :UsersGroupsRolesManage` (next to
  `:RolesManage`; REQUIRED, otherwise the identity catch-all returns `:RolesRebind`, which
  `permission_scope/1` classifies as platform); `:RolesRebind` in the `endpoint_policy_key()`
  type.

## 5. Tests (TEST-DESIGNER brief)

* RoleRegistry unit: create; same group idempotent (no new row, same id, no audit row); same
  group other kind converts kind (unchanged behaviour); different group -> `:role_already_bound`,
  row unchanged; rebind: updates group only, writes exactly one `role.rebound` entry with actor,
  old/new group, reason, timestamp; same-group rebind no audit; missing/blank/too long/control
  reason refused (incl. a Cf character such as U+202E), nothing written; unknown role / unknown
  group 404 atoms; rebind of the PLATFORM_ADMIN row without `platform_scope: true` refused inside
  `rebind_role/4`; seed after a rebind keeps the rebound group and returns ok; seed with a
  `:process_routing_role` row named `PROCESS_DESIGNER` bound to group X returns
  `{:error, {:role_name_taken_by_routing_role, "PROCESS_DESIGNER"}}` and grants X nothing (row
  unchanged); same for `PLATFORM_ADMIN` in the platform tenant.
* Router: POST /roles different group -> 409 `role_already_bound`, rows unchanged, for
  PROCESS_DESIGNER and TENANT_ADMIN; same group 200 idempotent; rebind as TENANT_ADMIN 200 +
  audit; rebind as PROCESS_DESIGNER 403 and nothing changes (AC5); rebind PLATFORM_ADMIN name by
  a TENANT_ADMIN of P without platform scope 403; bad id 404; bad body 422.
* Existing tests pinning the silent rebind are rewritten to the new contract:
  `role_registry_test.exs` "different group_id updates the binding";
  `identity_roles_guard_test.exs` CONTROL kind-overwrite (now same group);
  `platform_escalation_guard_test.exs` H1 control (operator now uses the rebind route).
  Route-inventory pins (`length(...) == N`) are updated for the one new route.

## 6. Noted, not changed

A TENANT_ADMIN can rebind `TENANT_ADMIN` to an empty group and lock every tenant admin out.
`POST /roles` allowed the same before this change (not a regression); the rebind is now at
least audited with a reason.

## 7. Out of scope

0051 org scopes and "tenant-wide" enforcement (F1); deleting a role binding; kind conversion
rules; the unused web `rolesApi.create` shape; `docs/roles.md` (owned by another lane; the
permission table needs no new permission because `:RolesRebind` maps to an existing one).
