# Security review ruling: what a STOREKEEPER-only user sees in the task list (T-1850)

Task T-1850 (PM D-131), the follow-up of `docs/design/roles-architect-verdict.md` point 4 (T-1848). Written as the
security reviewer. Docs only: no code, configuration, QA or production change. Marks: **(V)** verified by reading the
file or running the command named; **(G)** a guess or inference that I did not prove.

## Ruling in plain words

1. **Defect: yes.** Today a user who holds only the storekeeper role sees every task of their company in "My Tasks"
   and in the task list, and can open any of them by id. Ordinary task workers see only their own tasks.
2. This contradicts the product's own description of the role: `docs/roles.md` and the code comment on the role both
   say the storekeeper does "its own tasks". No decision record says the storekeeper should see all tasks.
3. **Severity: medium.** It is a leak inside one company (no other company's data is reached; tenant isolation
   holds). It shows the names of tasks, who they are assigned to, their status, dates, business key and form layout,
   for example approvals meant for managers. It does not show the data entered into forms or process variables.
4. Any storekeeper can see it, by just opening "My Tasks". No special skill is needed.
5. Only the storekeeper role is affected. A storekeeper who is also a task worker is already filtered correctly.
6. **What to do:** add one permission "read all tasks of the company" (`TasksReadAll`), give it to exactly the five
   roles that see all tasks today, and filter the task list for everyone else. Every other role keeps its answer.
7. No current UAT flow breaks: stock counts are not tasks, and stock posting tasks go to the company administrator.
8. The fix is a small backend change with one new permission row per role; rollback is a plain revert.

## 1. The finding, re-verified

### 1.1 Code path of the task reads

| Step | What it does | Source |
|---|---|---|
| Route `GET /tasks` | `authz_get "/", :TasksList, scope: :filter` → `handle_list/3` | `lib/letflow/routers/tasks.ex` (V) |
| Route `GET /tasks/inbox` | same policy key `:TasksList` → `handle_inbox/3` | `lib/letflow/routers/tasks.ex`, `endpoint_policy_key("GET", "/tasks/inbox")` in `authorization.ex` (V) |
| Route `GET /tasks/:id` | `:TasksGetById` → `handle_get_by_id/3` | `lib/letflow/routers/tasks.ex` (V) |
| Permission | `required_permission(key) when key in [:TasksList, :TasksGetById], do: :TasksRead` | `lib/letflow/api/authorization.ex` (V) |
| Row filter decision (list) | `evaluate_access/2`: after the permission check, `if endpoint == :TasksList and is_task_worker_only?(roles)` → `AllowWithRowFilter` with `task_scope: {:own_user_and_groups, ctx.user_id}`; otherwise `Allow` with `task_scope: :all` | `authorization.ex`, final `true ->` branch of `evaluate_access/2` (V) |
| Row filter decision (inbox, by id) | `build_inbox_assignee_scope/3` calls `Authorization.is_task_worker_only?(roles)` again: true → `{:principal, ...}`, false → `:unfiltered` | `routers/tasks.ex` (V) |
| The predicate | `TASK_WORKER` held AND none of `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TENANT_ADMIN`, `TENANT_AUDITOR` | `is_task_worker_only?/1` in `authorization.ex` (V) |
| The query | `filter_by_assignee_scope(query, :unfiltered)` returns the query unchanged; `{:principal, ...}` keeps USER = me, GROUP in my groups, ROLE in my role names | `lib/letflow/tasks.ex` (V) |

A STOREKEEPER-only caller holds `TasksRead` (`core_role_allows?(:STOREKEEPER, ...)` closed list; golden row
`STOREKEEPER TasksRead true core core` in `priv/permission_matrix/effective.golden`) (V). It does not hold
`TASK_WORKER`, so `is_task_worker_only?/1` is false, the decision is `task_scope: :all`, the inbox and by-id scope is
`:unfiltered`, and all three routes return every task of the tenant. (V)

### 1.2 Runnable proof

I appended the test below temporarily to `test/letflow/routers/tasks_test.exs` (it uses that file's own helpers
`build_conn/4`, `dispatch/1`, `insert_task!/2`, `insert_user!/2`, `insert_group!/2`, `insert_group_member!/3`,
`insert_role!/3`, `item_ids/1`), ran it, and restored the file byte for byte (worktree clean afterwards). (V)

Command: `MIX_TEST_PARTITION=1850 timeout 570 mix test test/letflow/routers/tasks_test.exs:2722`
Result line: `Result: 1 passed, 90 excluded` (`Finished in 2.0 seconds`). The test asserts today's behaviour, so
"passed" means the defect is real.

```elixir
describe "T-1850 proof: STOREKEEPER-only caller and the task reads" do
  setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "t1850")}

  test "GET /tasks, /tasks/inbox and /tasks/:id are unfiltered for STOREKEEPER-only", %{tenant: tenant} do
    sk = insert_user!(tenant, %{username: "t1850-sk"}).id
    other = insert_user!(tenant, %{username: "t1850-other"}).id
    approvers = insert_group!(tenant, name: "t1850-approvers")
    insert_group_member!(tenant, approvers.id, other)
    insert_role!(tenant, "approver", approvers.id)

    t_other_user = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: other})
    t_other_group = insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: approvers.id})
    t_admin_role = insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "TENANT_ADMIN"})
    t_own = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: sk})

    for path <- ["/?page_size=50", "/inbox?page_size=50"] do
      sk_conn = build_conn(:get, path, tenant, roles: ["STOREKEEPER"], user_id: sk) |> dispatch()
      assert sk_conn.status == 200
      sk_ids = item_ids(Jason.decode!(sk_conn.resp_body))
      # TODAY (the finding): every task of the tenant.
      assert t_own.id in sk_ids
      assert t_other_user.id in sk_ids
      assert t_other_group.id in sk_ids
      assert t_admin_role.id in sk_ids

      # Control: TASK_WORKER-only, and STOREKEEPER + TASK_WORKER, are filtered.
      for roles <- [["TASK_WORKER"], ["STOREKEEPER", "TASK_WORKER"]] do
        c = build_conn(:get, path, tenant, roles: roles, user_id: sk) |> dispatch()
        ids = item_ids(Jason.decode!(c.resp_body))
        assert t_own.id in ids
        refute t_other_user.id in ids
        refute t_other_group.id in ids
        refute t_admin_role.id in ids
      end
    end

    d = build_conn(:get, "/#{t_other_group.id}", tenant, roles: ["STOREKEEPER"], user_id: sk) |> dispatch()
    assert d.status == 200
    w = build_conn(:get, "/#{t_other_group.id}", tenant, roles: ["TASK_WORKER"], user_id: sk) |> dispatch()
    assert w.status == 404
  end
end
```

When the fix lands, the same test with the STOREKEEPER assertions flipped (`refute ... in sk_ids` for the three
foreign tasks, `404` for the by-id read) is the red-proof test (section 5, T1).

No existing test pins the storekeeper's task-list answer either way: `grep -rn "STOREKEEPER.*Tasks\|TasksList.*STOREKEEPER"
test/` finds nothing; `test/letflow/modules/stock/storekeeper_test.exs` only lists `:TasksRead`/`:TasksComplete` as held
atoms. (V)

### 1.3 Defect or intended?

Defect. Sources, all opened:

- `docs/roles.md`, section STOREKEEPER: "Does: ... its own tasks". Section TASK_WORKER: "read and complete their
  tasks". (V)
- `lib/letflow/api/authorization.ex`, comment on `core_role_allows?(:STOREKEEPER, ...)`: "This is the closed CORE list:
  own tasks (count and approval tasks), ...". (V)
- `docs/migration/decisions/0081-storekeeper-role.md`: D2 lists `TasksRead`, `TasksComplete` in the closed core list and
  says nothing about seeing all tasks. "Known limits": "Task list, get and complete use the TASK_WORKER-keyed scope set.
  Under `scope_enforcement :on` a STOREKEEPER-only user gets an empty or denied task set". That limit is about node-scoped
  grants, not about the row filter, and it does not decide that a tenant-wide storekeeper sees everyone's tasks. (V)
- `is_task_worker_only?/1`'s exclusion list was written for roles that watch the whole queue (REQ-447 added
  TENANT_ADMIN, REQ-448 added TENANT_AUDITOR, both on purpose: `docs/roles.md` "Operators, designers, admins and
  auditors read tenant-wide"). STOREKEEPER was added later (D-093) and the predicate was not reconsidered; the effect
  (not filtered, because it is not TASK_WORKER) is a side effect of naming roles, not a decision. (V for the history in
  the moduledoc and design comments; G that nobody considered it: I found no record that did.)

### 1.4 Severity and who can use it

- **Tenant isolation (INV-1) is not at issue.** Every read goes through the tenant's `:prefix`; the tests
  "AC4/INV-1: GET /tasks tenant isolation" and "REQ-132 AC5" in `tasks_test.exs` cover it. A storekeeper sees only tasks
  of their own company. (V for the code path; tests read by name, not re-run.)
- **What is broken** is the in-tenant row rule (server-side authorisation, the spirit of INV-2: the server decides which
  rows a caller may read) and least privilege, as documented in `docs/roles.md`.
- **Who:** any user whose only task-reading role is STOREKEEPER, through the web "My Tasks" page (it calls
  `/api/v1/tasks/inbox`, `web/src/api/tasks.ts`; menu entry `'/tasks'` gated by `P.TasksRead` in `AppShell.tsx`) or the
  API directly, including an API token carrying only STOREKEEPER (G: token contexts take the same `roles` path).
- **Data shown** (V, `task_list_item_map/2` and `task_detail_map/3` in `routers/tasks.ex`): list items carry `id`,
  `instance_id`, `node_id`, `node_name`, `status`, `assignee_type`, `assignee_ref`, `created_at`, `token_id`, `form_id`,
  `form_version`; the detail adds `correlation_key`, `updated_at`, `form_schema`. Not shown: output variables, process
  variables, `completed_by`. So a storekeeper learns that "Approve salary change for X" exists (if a definition names a
  task that way, G), who must approve it, and the business key. Approvals of other org units and confidential steps are
  visible as metadata.
- **Not reachable from it:** the instance itself (`GET /instances/:id`) needs `InstancesRead`, which STOREKEEPER does
  not hold (golden). Completing or claiming a task addressed to a user, group or role is refused by
  `Tasks.authorize_completion/3` and `apply_claim/5` unless the caller is that assignee. (V)
- **Side observation (not ruled, G on frequency):** a task with no assignee (`assignee_type` nil) may be claimed and
  completed by any holder of `TasksComplete` (`apply_completion_authz(%Task{assignee_type: nil}, ...)` returns `:ok`;
  `apply_claim` assigns it to the caller). A task worker cannot find such a task in the list (the principal filter
  excludes nil), a storekeeper can. Graph check CHK-09 wants a role on a human task (comment in
  `priv/modules/stock/generate_pack.exs`), so such tasks are probably rare. Worth one look by the security reviewer of
  the fix.
- **Rating: medium.** Confidentiality of in-company workflow metadata; easy to use; no write, no cross-tenant, no
  secrets.

### 1.5 Other roles not in the five

Roles that hold `TasksRead` (golden, V): PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, STOREKEEPER, TASK_WORKER,
TENANT_ADMIN, TENANT_AUDITOR. AGENT_RUNNER and CANDIDATE do not (403 before any row filter; no module `role_grants`
gives `TasksRead`: `grep -rn TasksRead lib/letflow/modules` is empty, V). The tenant grant overlay can add only
`AssetsRead`/`AssetsPost` to STOREKEEPER (`grantable/0`, V). So STOREKEEPER is the **only** role with the problem
today. Combinations: STOREKEEPER + TASK_WORKER is filtered (proof above); STOREKEEPER + any of the five sees all, which
is correct because the other role grants it.

Tenant-defined roles (`docs/design/tenant-defined-roles.md`, verdict T-1848) do not exist on main yet. With them every
custom role that holds `TasksRead` would hit the same hole; the permission rule below closes it for them too.

### 1.6 Scope enforcement (node-scoped grants)

The row filter and the node scope are applied together (`Tasks.list_tasks/2` uses `filter_by_assignee_scope` and
`filter_by_scope`). (V)

- `scope_enforcement` off or shadow: node scope is `:all` (`ScopeGate.scope_set_for_role/3`). The storekeeper sees all
  tasks. (V)
- `on`, storekeeper with a tenant-wide grant: `set_for/2` asks `Scope.allowed?(principal, :TasksRead, :tenant_wide)`;
  the tenant-wide storekeeper grant allows it, the set is `:all`, the storekeeper sees all tasks. (V for code; G that the
  seeded storekeeper binding is tenant-wide, per 0081 D1 "a group and a platform-role binding per tenant".)
- `on`, storekeeper with only a node-scoped grant: falls back to `Scope.allowed_set_for_role(principal, "TASK_WORKER")`,
  role not held → `:none`, the list is empty (0081 "Known limits"). Fails closed. (V)

So node scoping does not hide the defect for a normally seeded storekeeper.

## 2. The safe permission-only rule

### 2.1 Wording

New tenant-scope permission **`TasksReadAll`**: "read every task of the tenant, not only the tasks addressed to me, my
groups or my roles". `TasksRead` keeps its route meaning ("may use the task read routes") and from then on means "read
my own tasks" for a caller without `TasksReadAll`.

Rule for `GET /tasks`, `GET /tasks/inbox`, `GET /tasks/:id`: a caller who holds `TasksRead` and does **not** hold
`TasksReadAll` (after the non-platform PLATFORM_ADMIN drop, `effective_roles/2`) gets the own-user-and-groups scope;
a caller who holds both gets the whole tenant. This replaces the role-name test `is_task_worker_only?/1` on these three
routes.

I chose an added `TasksReadAll` over renaming to `TasksReadOwn` + `TasksReadAll`: the add-only form leaves every
existing golden row and every route's required permission unchanged, and the overlay/tenant-role machinery can grant
"see all" later without touching "see own".

### 2.2 Who holds it

| Role | `TasksRead` | `TasksReadAll` | Task list today | Task list after |
|---|---|---|---|---|
| PLATFORM_ADMIN | true | true (catch-all clause) | all (platform tenant only; dropped elsewhere) | same |
| TENANT_ADMIN | true | true (every tenant-scope atom) | all | same |
| PROCESS_DESIGNER | true | true (add to closed list) | all | same |
| PROCESS_OPERATOR | true | true (add to closed list) | all | same |
| TENANT_AUDITOR | true | true (add to closed list of 13, becomes 14) | all | same |
| TASK_WORKER | true | false | own | same |
| STOREKEEPER | true | **false** | **all** | **own** (the only change) |
| AGENT_RUNNER | false | false | 403 | same |
| CANDIDATE | false | false | 403 | same |

Equivalence check (V by reasoning over the golden): today "filtered" = TASK_WORKER and none of the five; after =
holds `TasksRead` and none of the five holds-`TasksReadAll` roles. The two differ only for a caller who holds
`TasksRead` without TASK_WORKER and without the five, which is STOREKEEPER (alone or with AGENT_RUNNER/CANDIDATE). Every
existing golden row stays identical; nine new `TasksReadAll` rows are added (five true, four false).

`TasksReadAll` must be tenant scope in `@permission_scope` (otherwise TENANT_ADMIN would not get it and
`has_permission_in_scope?` would refuse it outside the platform tenant), and must **not** be added to `grantable/0`.

### 2.3 What stays out of this fix

- `routers/instances.ex` `with_participation/4` (GH #2932) also calls `is_task_worker_only?/1`. STOREKEEPER has no
  `InstancesRead`, so nothing is wrong there today. Leave it on the old predicate in this fix, or give it its own
  `InstancesReadAll` in the stage-0 role-name work of the verdict; do not reuse `TasksReadAll` for instances.
- The `"TASK_WORKER"`-keyed scope sets (`ScopeGate.scope_set_for_role/3`) and the node-scoped storekeeper limit of 0081
  are a separate site of the verdict (F1 scope).
- The unassigned-task side observation (1.4).

### 2.4 UAT and real flows

- Stock counts (orders, sheets, differences, signing) are module documents and module routes
  (`StockCountOrder`, `StockCountRecord`), not BPM tasks: `grep -rln "assignee" lib/letflow/modules/stock` is empty. (V)
- Stock posting and the opening-balance `approve` step are HUMAN_TASKs with role `TENANT_ADMIN`
  (`priv/modules/stock/generate_pack.exs`, `process_definition` and `two_step_definition`). A storekeeper-only user
  cannot complete them today (`assignee_role_not_held`), so hiding them changes no outcome. (V)
- The `submit` step of the opening balance has role `STOCK_OPENING_SUBMIT` and is completed by the issuing user at
  issue (comment in `generate_pack.exs`). (V for the comment; G how it is assigned at run time.)
- Tasks meant for storekeepers keep working if they are routed to the storekeeper's user, a group they are in, or a
  role name bound to one of their groups (for example the seeded `STOREKEEPER` binding, which seeding creates as a group
  and binding named `STOREKEEPER`: `test/letflow/identity/storekeeper_seeding_test.exs` T-10a, V): the principal filter
  includes `role_names` from `TenantRole` rows of the user's groups (`resolve_principal_scope/2`, V).
- UAT: the actor roster has no storekeeper (`grep -i storekeeper test/fixtures/uat/actors.yaml scripts/uat_preflight.sh`
  is empty; sidecar `tenant-administration-78-role-sidebar-storekeeper.yaml` records it as a GAP). The stock-count
  scenarios use the company administrator, who keeps the whole queue. No current scenario changes. (V)

### 2.5 Migration and rollback

- No database migration: permissions are compiled, roles are compiled, no stored grant changes. (V: `core_role_allows?`
  is code; the overlay is closed to Assets.)
- Deploy effect: after deploy, storekeeper-only users see fewer tasks in "My Tasks". Nothing is lost or rewritten.
- Rollback: revert the commit; the storekeeper sees all tasks again.
- Change set (for the requirement, not done here): `@permission_scope` entry, three closed lists
  (PROCESS_DESIGNER, PROCESS_OPERATOR, TENANT_AUDITOR), a predicate on permissions used by `evaluate_access/2` and
  `build_inbox_assignee_scope/3`, `mix letflow.permission_matrix --write`, `docs/roles.md` (TENANT_AUDITOR "13 atoms" text
  and STOREKEEPER "own tasks"), the `permissions()` list and the pins that count permissions (to be grepped by the
  implementer: `length(Authorization.permissions())`, `authorization_test.exs` grids, the auditor closed-set literal,
  `roles_matrix_parity_test.exs`). Security review is mandatory (access path).

## 3. Test list for the fix

| ID | Test | Proves |
|---|---|---|
| T1 | Router: STOREKEEPER-only on `GET /tasks`, `/tasks/inbox`: own task in, other user's, other group's and TENANT_ADMIN-role task out; `GET /tasks/:id` of another group's task → 404 equal to a nonexistent id. Red on today's code (section 1.2 flipped). | the fix, INV-5 |
| T2 | Router: STOREKEEPER-only sees a task addressed to role `STOREKEEPER` bound to a group the user is in. | storekeeper tasks still reach them |
| T3 | Router: each of PROCESS_DESIGNER, PROCESS_OPERATOR, TENANT_ADMIN, TENANT_AUDITOR alone, and PLATFORM_ADMIN in the platform tenant, still sees all four tasks on the three routes. | no regression |
| T4 | Router: TASK_WORKER alone and STOREKEEPER + TASK_WORKER stay filtered; STOREKEEPER + PROCESS_OPERATOR sees all. | combinations |
| T5 | Router: non-platform tenant PLATFORM_ADMIN + TASK_WORKER stays filtered (REQ-447 PR 2 drop). | the drop still applies |
| T6 | Unit: `evaluate_access/2` for `:TasksList`: `AllowWithRowFilter` exactly for callers without `TasksReadAll`, for every role list of `roles()` singletons. | decision table |
| T7 | Permission matrix: `--check` passes; diff vs main is only the nine new `TasksReadAll` rows (5 true, 4 false). | golden identical otherwise |
| T8 | `grantable/0` does not contain `TasksReadAll`; a tenant overlay naming it is dropped by `sanitize_overlay/1`. | the overlay cannot widen it |
| T9 | `permission_scope(:TasksReadAll) == :tenant`. | TENANT_ADMIN gets it, platform rules unchanged |
| T10 | Scope enforcement `on`, tenant-wide storekeeper: own tasks only (row filter AND node set). | 1.6 interaction |

## 4. Sources

Opened and read: `lib/letflow/api/authorization.ex` (`evaluate_access/2` final branch, `is_task_worker_only?/1`,
`required_permission/1`, `core_role_allows?/2` for all roles, `grantable/0`, `permission_scope/1`),
`lib/letflow/routers/tasks.ex` (moduledoc, routes, `handle_list/3`, `build_list_assignee_scope/3`, `handle_inbox/3`,
`build_inbox_assignee_scope/3`, `handle_get_by_id/3`, `handle_complete/3`, `handle_claim/3`, `task_list_item_map/2`),
`lib/letflow/tasks.ex` (`resolve_principal_scope/2`, `filter_by_assignee_scope/2`, `filter_by_scope/2`,
`authorize_completion/3`, `apply_claim/5`), `lib/letflow/api/scope_gate.ex` (`scope_set_for_role/3`, `set_for/2`),
`lib/letflow/api/scope.ex` (`allowed?/3`, `allowed_set_for_role/2`), `lib/letflow/routers/instances.ex`
(`with_participation/4`), `lib/letflow/engine/task_activation.ex` (`resolve_assignee/1` doc),
`priv/permission_matrix/effective.golden` (TasksRead rows), `priv/modules/stock/generate_pack.exs` (task roles),
`docs/roles.md`, `docs/migration/decisions/0081-storekeeper-role.md`, `docs/design/roles-architect-verdict.md`
(point 4 and the E3 row), `test/letflow/routers/tasks_test.exs` (helpers and the REQ-132 tests),
`web/src/api/tasks.ts`, `web/src/components/layout/AppShell.tsx` (grep lines),
`test/fixtures/uat/scenario-env-limitations/tenant-administration-78-role-sidebar-storekeeper.yaml`.

Not read: GH #2932 issue text (only its `docs/roles.md` summary), decision 0051 (node-scoped grants) itself, the
storekeeper seeding code itself (only its test T-10a; whether the seeded binding's grant row is tenant-wide stays G), the auth pipeline for API tokens, the
full stock/assets UAT scenarios (grep only), the web task screens beyond the API call.
