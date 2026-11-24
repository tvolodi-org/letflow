# `platform.register_tenant` v2 and the system-authority start (design, pilot gap G17c)

Status: DESIGN (T-2734, written 2026-11-24). It describes how to build the change; nothing in it is built yet. The build
is T-2727. The consumer is the contract amendment of `POST /admin/v1/tenants` (202 + poll), approved by the PM on
2026-11-24 17:25 with three changes. Its build is T-2728, and section 9 is the part of this design that T-2728 implements.
Decision record: `docs/migration/decisions/0094-platform-call-authority.md`, amendment "The system-authority start".

**This change adds NO new way to create a tenant.** The tenant row is still written in exactly one place, the body of
the catalogue function `tenant.create` (`Letflow.PlatformFunctions.Impl.TenantCreate`). Only the dispatcher reaches that
body, and only for a node of an active `platform.register_tenant` version in the platform tenant. What changes is WHO
may start that definition: the two routes that have no person behind them (route 3, the provisioner mount, and route 4,
the self-service signup) get a narrow start authority that is bound to this one definition (section 6).

## 0. Where this starts from (main and T-2704, read 2026-11-24)

| Fact | Where |
|---|---|
| v1 of the definition: `validate -> create -> provision -> bind_realm -> grant_first_admins -> notify -> end`, start permission `TenantsManage`, variables `slug name hostname realm_id admin_email tenant_id schema_name` (all strings) | `lib/letflow/platform_processes/definition.ex` |
| The seed writes v1 and never replaces a newer version (`:created`, `:already_present`, `:newer_version_kept`) | `lib/letflow/platform_processes/seed.ex` |
| The one start function, `start_register_tenant/2`. It needs an `actor_id` and an `auth_context` | `lib/letflow/platform_processes.ex` |
| A start whose `auth_context` is nil is refused with the answer for an unknown definition | `Letflow.Definitions.StartPermission.check/3` (`authorize(nil, _, _)`), called from `Letflow.Engine.create/2` (`gate_start_permission/2`) |
| The engine's start replay check runs BEFORE the definition lookup and BEFORE the start permission: the same key with the same request answers the first result, and the same key with another request answers `:idempotency_key_reuse` | `Letflow.Engine.create/2` (`start_replay_check/3`) |
| Routes 1 (`POST /api/v1/onboarding`) and 2 (`POST /api/v1/tenants`) start the definition. The start key is the slug alone (`"register-tenant:" <> slug`, `register_tenant_start_key/1`). The answer is `202 {instance_id, status, slug, replayed?}`, or 409 when the same slug comes with other values | branch `team/T-2704` (`lib/letflow/platform_processes/route_start.ex`); **not merged yet** |
| Route 3 (`POST /admin/v1/tenants`) and route 4 (signup, `Letflow.Signup.Provisioning.create_tenant/2`) both call `Letflow.TenantProvisioner.create/1`. That call runs synchronously under a per-tenant session lock and does: realm probe, hostname and realm not taken, budgets + demo cap + tenant row + lifecycle row in ONE transaction under the cap lock, provision, onboarding record, pending grant, realm bind, default modules | `lib/letflow/tenant_provisioner.ex` |
| What v1 does not cover (T-2704 findings): `tenant_type` (REQ-469); the onboarding record (hostname); the caller's own `tenant_id` as `tenants.id`; the demo lifecycle row (tier, expiry, cap, budgets, default modules); a start with no person behind it | T-2704 implement #1 findings |
| `tenant_lifecycles.tenant_id` is a foreign key to `tenants` (`on_delete: :restrict`), so no lifecycle row can exist before the tenant row | `priv/repo/migrations/20261027000001_create_tenant_lifecycles.exs` |
| A `var` argument whose variable is absent is OMITTED from the inputs (it is not sent as nil), and the dispatcher refuses only a missing REQUIRED input | `Letflow.Engine` `resolve_platform_call_inputs/4`; `Letflow.PlatformFunctions.Dispatcher` (the required-input check) |
| An edge condition that names an undefined variable is an evaluation ERROR. It does not count as false | `Letflow.Engine.Expr` (moduledoc of the variable lookup) |
| The step runner is OFF unless `LETFLOW_START_PLATFORM_STEP_RUNNER` is set | `docs/platform-steps.md`; `lib/letflow/supervisor/pollers.ex` |

## 1. Inputs (the start variables of v2)

Every name is a top-level string key of the instance variables (no dotted names, decision 0094 (b)). The type is a JSON
Schema string unless the table says otherwise. Only the two builders in `Letflow.PlatformProcesses` write these values
(section 6.3). No request body field reaches the variables under a name the builder did not choose.

| Variable | Type | Set by routes 1/2 (operator) | Set by routes 3/4 (system start) | Read by |
|---|---|---|---|---|
| `slug` | string | form value | `Request.slug(tenant_id)` = `"t-"` + 32 hex | `validate`, `create`, notify values |
| `name` | string | form value | `request.name` | `validate`, `create`, notify values |
| `requested_tenant_id` | string (uuid) | never | `request.tenant_id` (the caller's pre-allocated id, decision 0072 D3) | `create` |
| `tenant_type` | string, enum `test`/`production` | form value when sent (REQ-469) | never | `create` |
| `hostname` | string | form value when sent | `request.hostname` | `record_onboarding` |
| `realm_id` | string | form value when sent | `request.idp_realm_id` | `bind_realm` |
| `admin_email` | string | form value when sent | `request.email_key` (already normalised) | `grant_first_admins`, notify recipient |
| `notify_admin` | boolean | `true` ONLY when `admin_email` is supplied, `false` when it is absent (the notify step needs a recipient: `notify_recipient_missing` otherwise) | `false` | the gateway in front of `notify` |
| `tenant_id` | string (uuid) | (step output) | (step output) | written by `create`, read by every later step |
| `schema_name` | string | (step output) | (step output) | written by `provision` |

Not a variable, on purpose: `tier`, `language`, `expires_at`, `source_ip_key`, `email_domain_key`. They are written by
the front gate into the admission row (section 5) and read from there by `record_lifecycle` by tenant id. So no digest
and no expiry value travels through the instance variables, and no person can set them.

**Builder rule while v1 may still be active, and replay (the start contract is the ORIGINAL one).** v1 does not
declare `requested_tenant_id`, `tenant_type` or `notify_admin`. Both builders first ask the start ledger whether the
key `register_tenant_start_key(slug)` already has a start: `Letflow.Engine.IdempotentReplay.lookup/3` on the platform
prefix (the call `Engine.start_replay_check/3` makes).

- **A start exists (a replay).** The builder builds the variables as for a new start, then keeps ONLY the keys that
  the ORIGINAL VERSION's start contract declares: it reads the `variable_schemas` of the definition version the first
  instance runs (found from the start ledger's instance), the set `C`. It does NOT filter by the keys the first start
  happened to send: the builder omits an absent optional value, so a key-presence filter would drop a newly supplied
  `hostname` and let the changed request replay. With `C` as the filter: a key in `C` that was absent at the first start
  and is supplied now is kept, the variables differ and the engine answers 409 (absent -> present); a key in `C` that
  was sent first and is omitted now is missing from the variables and the engine answers 409 (present -> absent); a
  key not in `C` (a v2 key on a v1 first start) is dropped, so v1 -> v2 activation does not turn a replay into a 409.
  The values come from the request, so a changed value differs too. The ACTIVE definition is not read, so a v1 -> v2 activation, a rollback to v1 and a deprecation do not change what a replay sends. The engine's
  compare (`same_start_request?/4`) is by definition NAME, not by version, so the first instance is answered.
  The system builder does NOT run the v2-contract check of section 6.4 for a replay: the first start passed C1, and the
  engine answers a replay before the definition lookup and the permission gate.
- **No start exists (a new start).** The operator builder adds the three v2 keys ONLY when the active version declares
  them in its `variable_schemas` (one read of the active version before `Engine.create/2`). With v1 active, routes 1/2
  start exactly as T-2704 left them. The system builder refuses (section 6.4) when the active version does not declare
  all three keys.

## 2. Outputs

| Output | Where the caller sees it |
|---|---|
| `tenant_id` (variable, from `create`) | the instance's variables; route 3 knows it already (it is the caller's id) |
| `schema_name` (variable, from `provision`) | instance variables only; never in a route answer |
| the tenant row, the schema, the lifecycle row (routes 3/4 only), the onboarding record (when `hostname` is set), the realm bind (when `realm_id` is set), the pending grant (when `admin_email` is set), the default modules (routes 3/4 only), the notification (routes 1/2 only) | the step log of the instance (G6); `GET /admin/v1/tenants/:id` (section 9.3); `GET /api/v1/tenants/:slug` |
| the instance end state: `COMPLETED` or `ERROR` (+ DLQ entry of type `platform_step` / `notify_step`, G7) | the instance timeline; `GET /admin/v1/tenants/:id` `status` = `active` / `failed` |

## 3. The graph of v2

```
start -> validate -> create -> provision -> record_lifecycle -> record_onboarding -> bind_realm
      -> grant_first_admins -> install_default_modules -> notify_gate (EXCLUSIVE_GATEWAY)
             notify_gate --[notify_admin == true]--> notify -> end
             notify_gate --(default, no condition)--> end
```

- Every SERVICE_TASK is a `platform_call` node built by `call_node/3` of `Letflow.PlatformProcesses.Definition`. Its
  `reads`/`writes` come from the catalogue entry (G13), as in v1. The `notify` node is v1's node, unchanged.
- The order follows `TenantProvisioner.create/1` (tenant + lifecycle first, then provision, onboarding, grant, realm,
  modules). One difference: `bind_realm` comes before `grant_first_admins`, as in v1. The two steps are independent of
  each other, so the order is free, and v1's order keeps the step ids of the G19 Playwright test.
- The gateway follows the graph rules (CHK-13..17): the default edge carries no condition. `notify_admin` is ALWAYS set
  by both builders, because an undefined variable in a condition is an evaluation error (section 0). The operator
  builder (routes 1/2) sets it to `true` only when `admin_email` is supplied and to `false` when it is absent, so the
  gateway never selects `notify` without a recipient (`Dispatcher` returns `notify_recipient_missing` for an absent
  address, `lib/letflow/notification_steps/dispatcher.ex`); a registration without an address completes at `end`.
- There is no HUMAN_TASK, no SUB_PROCESS, no inline HTTP and no script node. So the foreign-source rule of 0094 (b)
  holds, and the system start's "no child" condition (section 6.2) holds.
- Start permission declared on the row: `TenantsManage` (as v1).
- `variable_schemas`: section 1 (`notify_admin` is `{"type": "boolean"}`, `tenant_type` is
  `{"type": "string", "enum": ["test", "production"]}`, the rest are strings).

## 4. The step table: what each step does, how it fails, and what a repeat does

"Repeat" covers three cases: the dispatcher's own retry after a crash or lease loss (same call key, same arguments:
the first result is returned and the body is not run again), the G7 retry of an ERRORed instance (the body runs again
and must change nothing it already did), and a second instance of the same registration. A second instance cannot
happen for one start key (section 7), but it can happen for an operator who registers the same slug again after the
first instance ended.

Every failure is a closed `{:error, code}` from the body's own vocabulary. Every body follows the INV-8 rule (it never
raises) and the SF-01 rule (byte bound first). The catalogue entries are `Letflow.PlatformFunctions.TenantFamily`. NEW
means a new entry; CHANGED means an existing entry gains an OPTIONAL input (it stays at version `"1"`; v1's nodes still
match it).

| # | Node / function | Inputs (source class) | Does | Fails with (instance -> ERROR after the dispatcher's retries) | A repeat |
|---|---|---|---|---|---|
| 1 | `validate` / `tenant.validate` (body from T-2704) | `slug`, `name` (start) | read-only: bounds, reserved slug, slug free or the same registration | `platform_call_arg_invalid`, `platform_call_duplicate_slug`, `platform_call_tenant_purged` | reads again, same answer; no write |
| 2 | `create` / `tenant.create` CHANGED | `slug`, `name` (start); NEW optional `requested_tenant_id` (start, uuid), NEW optional `tenant_type` (start) | WITHOUT `requested_tenant_id`: today's `Identity.create_tenant/1` (with `tenant_type` when sent). WITH it: `slug` must equal `Request.slug(requested_tenant_id)`, the row is written by `Identity.create_provisioned_tenant/1` with `id: requested_tenant_id` (which forces `tenant_type` to `test`), and a sent `tenant_type` is refused | `platform_call_arg_invalid` (bad uuid, slug not derived from the id, `tenant_type` together with `requested_tenant_id`, `tenant_type` not in the enum), `platform_call_duplicate_slug` (the slug or id belongs to a tenant with other values), `platform_call_tenant_purged`, `platform_call_tenant_create_failed` | ADOPTS the row: the same slug, the same display name and (when given) the same id answer the first `tenant_id` and write nothing. An existing row with the same slug and another name or id is refused. The idempotency key stays `["slug"]`; the slug is a function of the id, so the key is unique for both callers |
| 3 | `provision` / `tenant.provision` | `tenant_id` (step) | schema, migrations, roles, HMAC key, status `:active` | `platform_call_arg_invalid`, `platform_call_tenant_purged`, the provision failure kinds of the body | changes nothing (the migrator skips applied migrations, the seeding is an upsert, the HMAC key is kept) |
| 4 | `record_lifecycle` / `tenant.record_lifecycle` NEW (`write_tenant_registry`) | `tenant_id` (step), optional `requested_tenant_id` (start) | reads the ADMISSION row of `tenant_id` (section 5). No admission and no `requested_tenant_id` (routes 1/2): no-op, `{:ok, %{}}`, as today (operator tenants have no lifecycle row). Order: a lifecycle row exists -> ok, nothing written. Else with `requested_tenant_id` set and no admission -> `platform_call_lifecycle_failed` (fail closed, section 5). With an admission: inserts the `tenant_lifecycles` row from it (`lifecycle: "active"`, tier, language, expires_at, both key digests, `default_modules_state` = `pending`, or `done` when `Config.default_modules/0` is empty), in one transaction, and then runs the demo-alarm log of today (`alarm_if_reached/1`, counts only) | `platform_call_arg_invalid`, `platform_call_lifecycle_failed` | the row exists: nothing is written, `{:ok, %{}}` |
| 5 | `record_onboarding` / `tenant.record_onboarding` NEW (`write_tenant_registry`) | `tenant_id` (step), optional `hostname` (start) | no `hostname`: no-op. Otherwise it is the moved `ensure_onboarding/2` of `TenantProvisioner`: `Identity.create_onboarding(%{tenant_id, slug, hostname})`. The provisioner and the step then call ONE implementation (`Impl.TenantRecordOnboarding.ensure/2`), as G1b did for the other steps | `platform_call_arg_invalid` (hostname over 253 bytes or not a hostname), `platform_call_hostname_taken` (`:duplicate_hostname`), `platform_call_onboarding_failed` | a record for the tenant exists: the same hostname answers ok and writes nothing; ANOTHER hostname is `platform_call_hostname_mismatch` (the step never moves a tenant's host) |
| 6 | `bind_realm` / `tenant.bind_realm` CHANGED (`realm_id` becomes optional) | `tenant_id` (step), optional `realm_id` (start) | no `realm_id`: no-op (an operator tenant without a realm, as today's `POST /tenants`). Otherwise today's body: `RealmProbe.verify/1`, then `Identity.bind_provisioned_realm/3` | today's codes (`platform_call_realm_already_bound` for another realm, the probe's `not_found` / `unreachable` kinds) | the same realm: `{:unchanged, tenant}`, nothing written |
| 7 | `grant_first_admins` / `tenant.grant_first_admins` CHANGED (`admin_email` becomes optional) | `tenant_id` (step), optional `admin_email` (start) | no `admin_email`: no-op. Otherwise today's body (pending grant in the tenant schema through `PendingAdminGrants.create_provisioned/2`). It ALSO sets `tenant_lifecycles.owner_grant_stored = true` when a lifecycle row exists, so the old path's replay (`ensure_grant/4`) does not store it again after a setting flip | today's codes | the grant waits already: stores nothing (`:duplicate` counts as done) |
| 8 | `install_default_modules` / `tenant.install_default_modules` (body changed, entry unchanged) | `tenant_id` (step) | no lifecycle row, or `default_modules_state` `not_applicable` / `done`: no-op (operator tenants install nothing, as v1). `pending` / `failed`: the moved `ensure_default_modules/2` of `TenantProvisioner`, which records `done`, or `failed` + `"<module_id>:<code>"` | NEVER fails the instance on an install failure (today's rule, decision 0072 D8: a failed install never fails the create); it fails only with `platform_call_arg_invalid` | `already_installed` counts as done; a `failed` state is retried on the next run of the step (G7 retry, or a route-3 replay, section 9.2) |
| 9 | `notify_gate` (EXCLUSIVE_GATEWAY) | `notify_admin` | routes 1/2 -> `notify` only when `admin_email` was supplied (`notify_admin == true`), otherwise `end`; routes 3/4 -> `end` (the provisioner sends no mail today, and signup sends its own welcome mail after the create, `Signup.Provisioning.send_welcome/2`) | an undefined `notify_admin` is an evaluation error (instance ERROR); both builders always set it | evaluated again, same edge |
| 10 | `notify` (v1 node, `tenant_registered` to `admin_email`) | `admin_email`, `name`, `slug` | as v1; the G14 allow-list applies at dispatch | as v1 (`notify_recipient_missing`, the outbound refusals) | one delivery row per attempt (G4) |

New refusal codes join the closed failure-kind vocabulary in `docs/platform-steps.md` ("The closed vocabulary of the
failure kind"): `platform_call_lifecycle_failed`, `platform_call_onboarding_failed`, `platform_call_hostname_taken`,
`platform_call_hostname_mismatch`.

## 5. The front gate: the demo cap and the two daily budgets stay IN FRONT of the definition

PM rule: the cap and the budgets answer 409 BEFORE any instance starts. They cannot simply be checked and then left
behind. Today the count and the insert of the counted row share one transaction under
`pg_advisory_xact_lock(hashtextextended('letflow.provisioner.demo_cap', 0))`, so two concurrent creates cannot overshoot
the cap. In v2 the lifecycle row is written later, by step 4, and it cannot be written in front, because it needs the
tenant row (foreign key). So the front gate writes a RESERVATION under the same lock: the admission row.

**Table `tenant_admissions` (global schema, next to `tenant_lifecycles`; new migration in T-2727).** Columns:
`tenant_id uuid PRIMARY KEY` (no FK: the tenant does not exist yet), `tier text NOT NULL`, `language text NOT NULL`,
`expires_at utc_datetime_usec NOT NULL` (computed ONCE here, the default of now + 14 days included), `source_ip_key bytea`,
`email_domain_key bytea NOT NULL`, `request_fingerprint bytea NOT NULL` (section 7), `instance_id uuid` (set after
the start), `inserted_at`. No raw e-mail, no raw source value, no realm, no name. The table holds no personal value
that `tenant_lifecycles` does not already hold.

**The front gate, `Letflow.TenantProvisioner.Admit.admit/1` (new), in this order.** The whole call runs inside today's
per-tenant session lock (`TenantProvisioner.with_lock/2`), so two concurrent creates of one id are serialised:

1. an admission for `tenant_id` exists -> it is a REPLAY: compare `request_fingerprint`. Equal: go to the start (no
   cap and no budget check: a replay is never refused, as today). Different: `{:error, :conflict}` (409).
2. a tenant row or a lifecycle row for `tenant_id` exists WITHOUT an admission (made by the old path) -> hand the
   request to the OLD path's `do_create/3` (today's replay semantics for an old tenant). No second registration starts.
3. today's pre-write checks, unchanged and in today's order: `probe_realm/1` (400 `idp_realm_id`), `not_taken/1` (409
   for a taken hostname or a bound realm).
4. one transaction under the demo-cap xact lock: `check_budget/4` for both keys, then the demo count, then INSERT the
   admission. The counts change so that each counts the lifecycle rows AND the admissions that have no lifecycle row yet:
   - demo count = `tenant_lifecycles` with tier `demo` and lifecycle not `deleted` + `tenant_admissions` with tier
     `demo` that have no `tenant_lifecycles` row;
   - budget count (per key, last 24 h) = lifecycle rows by key + admissions by key that have no lifecycle row.

   The OLD path's `insert_tenant_and_lifecycle/2` uses the SAME two count functions. So the counts stay right while the
   setting is flipped and while instances are in flight. A refusal is `{:error, {:limit, which, language}}`, the 409 of
   today, byte for byte.
5. still INSIDE the per-tenant session lock (`with_lock/2`), call the system start (section 6) and then store
   `instance_id` on the admission. The demo-cap xact lock of step 4 is left before the start (the cap is already
   reserved by the admission), but the session lock is held to the end of step 5. Every writer or releaser of this
   admission (the Sweep, the old path's adoption below) takes the SAME session lock, so none can run between the
   start and the link.

**Durable linkage: the start ledger is the truth, `instance_id` is a cache.** The start (a committed instance) and the
link update are two commits, so a crash between them leaves an admission with a null `instance_id` and an instance that
exists. The start ledger (the idempotency key `register-tenant:<slug>`, written by `Engine.create/2` in the instance's
own transaction) cannot be lost with the instance, so the admission is never released from `instance_id` alone:

- **Reconcile before release.** The Sweep takes the session lock of the tenant id, then looks the key up in the ledger
  (`IdempotentReplay.lookup/3`). Found: it stores the `instance_id` (repair) and keeps the admission (the instance's own
  terminal state then decides, next bullet). Not found and the admission is older than 1 h: delete it. Because the
  start and the link run inside the same session lock (step 5), a start cannot commit between the Sweep's lookup and its
  delete.
- **Release by instance state.** Instance in `CANCELLED` (and no tenant row): delete. In `ERROR`: keep the cap slot until
  the platform admin retries (G7) or cancels it. In `COMPLETED`: the lifecycle row exists, so the admission no longer
  counts (the counts exclude an admission that has a lifecycle row), but the Sweep KEEPS it. It is the durable
  registration record: it holds the `request_fingerprint` (section 7: a replay with changed values stays a 409 after
  completion) and it is the marker that routes this tenant to the new replay and GET answers (section 9.3, `server_url`
  and `handover`). It holds only digests and the admitted tier/expiry, no personal value, so keeping it costs nothing.
  It is deleted only by the tenant purge, in the purge transaction of the same tenant id.
- **Fail closed in step 4 of the graph.** `record_lifecycle` takes the optional start input `requested_tenant_id`
  (present on routes 3/4 only). Order inside the step: a lifecycle row for `tenant_id` exists -> ok, write nothing.
  Else, if `requested_tenant_id` is set and no admission exists -> `platform_call_lifecycle_failed` (the instance goes
  to ERROR; never a silent no-op). Else, no `requested_tenant_id` and no admission (routes 1/2) -> no-op as today. So a
  lost admission can no longer let a system-started tenant exist without lifecycle and budget accounting.

**A start that fails after the admission committed** (no active v2, platform tenant missing, runner off): the route
answers (section 9.2) and the admission stays. A replay with the same body passes step 1 and starts again (the ledger
has no start, so it is a new start under the same session lock).

**Rollback: the old path adopts its own reservation.** Setting flipped OFF while an admission is pending. Today's
`do_create/3` sends an absent tenant to `insert_tenant_and_lifecycle/2`, whose cap check would count the tenant's OWN
admission and refuse at capacity. Rule, in `TenantProvisioner.create/2`'s old path, under the same `with_lock/2`:
look up the admission for the id first. If it exists, `insert_tenant_and_lifecycle/2` runs in ADOPT mode:

- no cap check and no budget check (the admission is already counted; a different tenant's admissions still count);
- the lifecycle row is built from the ADMISSION's values (tier, language, expires_at, both key digests), not from the
  request, so the digests and the 14-day expiry are the ones admitted;
- in the SAME transaction (under the demo-cap xact lock) the lifecycle row is inserted and the admission is KEPT (it no
  longer counts because a lifecycle row now exists), so the count never moves and never double-counts and the
  fingerprint survives;
- the running instance is not stopped. Its step 2 ADOPTS the tenant row (same slug, same name, same id) and its step 4
  finds the lifecycle row and writes nothing (section 4), so the two paths converge on one tenant. If the replay body
  differs from the admission's fingerprint, the old path answers 409 (the same compare as step 1) before adopting.
- the same adoption applies when the old path finds the tenant row WITHOUT a lifecycle row but WITH an admission (the
  instance created the tenant, then the setting flipped): today's `ensure_lifecycle` path adopts instead of inserting.

## 6. The system-authority start (the PM's five conditions)

### 6.1 Shape

- New module `Letflow.PlatformProcesses.SystemStart`: a struct `%SystemStart{definition_name, route}`. The ONLY
  constructor is `SystemStart.for_route(route)` with a closed route list `[:admin_v1_tenants_create,
  :signup_provisioning]`; any other value is `{:error, :unknown_route}`. There is no `from_map`, no cast and no
  `Jason.Decoder`, and no field comes from a request.
- New start function `Letflow.PlatformProcesses.start_register_tenant_system(variables, %SystemStart{}, opts)`. It calls
  `Engine.create/2` with:
  - `actor_id: Letflow.EventStore.platform_actor_id()`. The engine requires an actor, and
    `triggering_user_id/1` already stores this sentinel as NULL;
  - `auth_context: nil` and a NEW opt `system_start: %SystemStart{}`;
  - `idempotency_key: register_tenant_start_key(%{slug: slug})` (T-2704's function: one key rule for all four routes,
    section 7);
  - `prefix:` the platform prefix from `PlatformTenant.platform_prefix/0`, never from the caller.
- `Letflow.Definitions.StartPermission.check/4` (new arity; `check/3` keeps its meaning) receives the `system_start`
  opt from `Engine.gate_start_permission/2`. A `%SystemStart{}` opt in any other engine function is ignored: only the
  start gate reads it.

### 6.2 The five conditions, each as a rule and a test

| # | Condition (PM) | Rule in code | Test (T-2727, `test/letflow/platform_processes/system_start_test.exs` unless named) |
|---|---|---|---|
| C1 | bound to this ONE definition name | `StartPermission` admits a `%SystemStart{}` only when ALL of these hold: `definition.name == PlatformProcesses.register_tenant_definition_name()` (== `system_start.definition_name`); the start prefix is the platform prefix; the derived atoms are exactly `[:TenantsManage]` and the declared atom is `:TenantsManage`; the definition starts NO SUB_PROCESS child; the definition declares `requested_tenant_id`, `tenant_type` and `notify_admin` (the v2 contract, section 1). Anything else: the answer for an unknown definition (INV-5), and nothing is written | a system start of (a) another platform definition that calls `tenant.create`, (b) the same graph under another name, (c) a `platform.register_tenant` version that adds a SUB_PROCESS, (d) a version that adds a call of a function with another permission, (e) v1 (no v2 contract), (f) a company-tenant prefix: each is refused, and no instance, no event and no audit row exist |
| C2 | audit `actor_kind = system`, with the calling route | the `instance.create` audit row of a system start carries `actor_id: nil`, an EXPLICIT `actor_kind: "system"` (the sentinel is a UUID, so the default of `Audit.actor_kind_for/1` would say `user`) and `"started_via" => "admin_v1_tenants_create" \| "signup_provisioning"` in `after_state`. The INSTANCE_STARTED event's triggering user is NULL | read the audit row back for each route: `actor_kind == "system"`, `actor_id == nil`, `started_via` names the route; an operator start (route 1) keeps `actor_kind == "user"` with the person's id |
| C3 | no user-supplied value is trusted as identity or permission | the authority is the `%SystemStart{}` that the SERVER builds after its own authentication: `ProvisionerAuth`'s write-class credential (route 3), or the signup row's verified state, which is reached only by the server's own sweep (route 4). The variables come from the parsed `Request` only (section 1). No body key names an actor, a role, a tenant authority or a route. `admin_email` is DATA: the grant is PENDING and binds only at the first sign-in through the tenant's own realm. `requested_tenant_id` is data too (the new tenant's id), and step 2 refuses an id that already belongs to another tenant | a body with extra keys `actor_id`, `roles`, `route`, `tenant_type` answers 400 `body` (unknown key, `Request.parse/1`) and starts nothing; a read-class credential gets 403 before any body read (existing `class_gate`); `started_via` is the same whatever the body says |
| C4 | today's rate and abuse limits stay in front | order on route 3: `ProvisionerAuth` (credential + 429 limiter) -> `class_gate` -> the 16 KiB body cap -> `Request.parse/1` -> the front gate (realm probe, not taken, budgets, cap; section 5) -> the start. Route 4: the signup's own verify throttles -> the same front gate. NO instance is started before every limit has passed | with the cap reached, a new id answers 409 `limit: demo_cap_reached` and NO INSTANCE_STARTED of `platform.register_tenant` exists for it; the same for each budget; a replay of an admitted id at the cap is NOT refused |
| C5 | its own security + security_deep gate | every file the change touches is under a `[sensitive]` prefix of the team's `project/team.toml`: `lib/letflow/platform` (this prefix also covers `platform_processes/`), `lib/letflow/platform_functions`, `lib/letflow/definitions/start_permission.ex`, `lib/letflow/engine`, `lib/letflow/tenant_provisioner`, `lib/letflow/signup`, `lib/letflow/routers/admin_`, `priv/repo/migrations/`. No new prefix is needed. The T-2727 summary quotes the prefix match per file | the engine's sensitive-scope step lists the files and the security_deep gate runs |

A source-scan pin (new, `test/letflow/platform_processes/system_start_callers_test.exs`, in the form of
`credential_callers_test.exs`): `SystemStart.for_route/1` and `start_register_tenant_system/3` are called ONLY from
`lib/letflow/tenant_provisioner.ex` (or its new `tenant_provisioner/admit.ex`). Every form is caught: alias at module
and file scope, `Elixir.`-prefixed, capture, pipe. The pin has a rogue negative fixture that goes through the same
entry point (SF-10).

### 6.3 Where the two builders live

`Letflow.PlatformProcesses.register_tenant_variables/1` (operator, routes 1/2) and the new
`register_tenant_system_variables/1` (takes the map that `TenantProvisioner.Request.parse/1` returns). These two are the only places that name
start variables.

### 6.4 What the system start answers

`{:ok, create_result}` (a replay too: `replayed: true`), `{:error, :idempotency_key_reuse}` (it cannot be reached
through the front gate, which answers 409 first; the route maps it to 409 anyway), `{:error, :not_found}` (C1 refused,
or no active definition), `{:error, :platform_tenant_not_configured}`, and
`{:error, :register_tenant_v2_missing}` (the active version does not carry the v2 contract; it is checked before
`Engine.create/2` for a NEW start only. An existing start is answered from the ledger without it, section 1; the log line names the tag only).

## 7. The start key and replay

- ONE rule for all four routes: `register_tenant_start_key(form) = "register-tenant:" <> slug` (T-2704). For routes 3/4
  the slug is `"t-" <> hex(tenant_id)`, a one-to-one function of the pre-allocated id. So "slug alone" and "the
  pre-allocated tenant_id" are the same key.
- The same key with the same values is a replay. The engine answers the first instance (`start_replay_check/3`, BEFORE
  the definition lookup and the permission gate, so a replay still answers after v2 was edited or deprecated).
- The same key with OTHER values answers 409:
  - routes 1/2: the engine's `:idempotency_key_reuse` (T-2704);
  - routes 3/4: the front gate's fingerprint compare (section 5 step 1), BEFORE the engine. The engine never sees
    different variables for one key, because the variables are built from the request, which is bound to the
    admission by the fingerprint.
- `request_fingerprint` = SHA-256 over the canonical, sorted encoding of the parsed request AS SENT: `tenant_id`, `name`,
  `language`, `tier`, `email_key`, `hostname`, `idp_realm_id`, `expires_at` as sent (null when absent, NOT the computed
  default), `source_ip_key`. `Request.parse/2` today returns only the computed `expires_at`, so T-2727 changes it to also return `expires_at_sent` (the raw value or nil) and builds the fingerprint from that field, never from the computed one. A replay that again omits `expires_at` therefore matches. A replay that sends it explicitly
  differs, and gets 409.
- **Contract change, approved by the PM:** today a replay of a COMPLETE tenant "ignores every body field except
  `tenant_id`" (`TenantProvisioner` moduledoc, D3). With the setting ON, a replay with different values answers 409.
  With the setting OFF nothing changes.
- An operator (route 2) who picks the slug `t-<hex>` of a provisioner tenant meets the same key: an identical request is
  impossible (the variables differ), so the answer is 409. That is correct: the same registration was already started
  with other values.

## 8. Failure and repeat at the route level

| Situation | Route 3 answer (setting ON) | What a repeat (same body) does |
|---|---|---|
| validation (`Request.parse`) | 400 `invalid_request` (today) | the same |
| realm probe refuses | 400 `idp_realm_id` (today) | the same |
| hostname taken / realm bound | 409 `conflict` (today) | the same |
| cap / budget | 409 `conflict` + `limit` (today) | the same until a slot frees |
| no active v2, no platform tenant, v2 contract missing | 500 `internal_error` (the contract has no 503); one log line with the tag | the admission is kept, so the repeat starts once v2 is active |
| instance COMPLETED within the wait | 201 (this call created the admission) / 200 (replay), body EXACTLY today's `{tenant_id, status: "active", server_url, handover}` | 200, the same body |
| instance still running at the end of the wait | 202 `{tenant_id, status: "provisioning", poll: "/admin/v1/tenants/<id>"}` | 202 or 200, according to the current state |
| instance ERROR (a step gave up after the dispatcher's retries) | 202 `{tenant_id, status: "failed", reason, poll}`; `reason` from section 9.3 | the same answer; recovery is the platform admin's G7 retry. **Difference from today:** the old path's replay re-ran the missing steps itself; under v2 the dispatcher's own retries and the G7 retry do that, and a replay does not restart a failed instance |
| COMPLETED but `default_modules_state == "failed"` | 201/200 (today's rule: modules never fail the create) | the replay calls `TenantProvisioner.retry_default_modules/1` (the moved `ensure_default_modules/2`, under `with_lock/2`), as today's replay does. This is no tenant create, so the callers test is not touched |

Route 4 (`Signup.Provisioning.create_tenant/2`, in process, wait 0): `{:ok, :created | :existing, _}` (COMPLETED) ->
`send_welcome` as today. NEW `{:ok, :accepted, _}` (running) -> `{:retry, :tenant_pending, nil}`, and the sweep resumes
it. `failed` with reason `conflict` -> `{:permanent, :tenant_conflict}`; `failed` with reason `internal` ->
`{:retry, :tenant_internal, nil}`. The limit refusals keep today's permanent codes.

## 9. The consumer: the contract amendment (`project/contract-amendment-tenant-create-202.md`, PM 17:25)

### 9.1 The one setting, default OLD path

- `Letflow.TenantProvisioner.Config.create_via_process?/0`: Application env `Letflow.TenantProvisioner`
  `:create_via_process`, from env `LETFLOW_PROVISIONER_CREATE_VIA_PROCESS` (`true`/`false`, default `false`, any other
  value raises at boot, as the neighbouring settings do). It is read at REQUEST time in `TenantProvisioner.create/2`,
  the one switch point for BOTH route 3 and route 4.
- The new path ALSO needs the step runner. With the setting ON and `LETFLOW_START_PLATFORM_STEP_RUNNER` off, the call
  takes the OLD path and logs one warning per call (`provisioner: create_via_process is on but the platform step
  runner is off; old path used`). Otherwise every create would wait 30 s and never finish. The runner switch and its QA deploy check are described in
  `docs/runbooks/qa-platform-step-runner.md`. The "is the runner on" read uses the same config key that that runbook names.
- A row in the settings table of `docs/runbooks/production-readiness.md`. Switching it ON anywhere except QA/runner
  tenants is a production step and needs the owner's go after T-2610 is green twice (PM change 2).
- Setting OFF: `create/1` is today's code, byte for byte. A T-2727 test compares the OFF answers (201, 200, 409 + limit,
  400) with the pre-change fixtures. The admission counts in the old path count nothing while no admission exists.

### 9.2 The wait hint (default, compatible)

- `Config.create_wait_seconds/0`: `LETFLOW_PROVISIONER_CREATE_WAIT_SECONDS`, integer 0..55, default 30 (PM change 1).
  The route holds the request after the start and polls the instance status every 250 ms, at most
  `wait_seconds * 4` reads, one indexed read of the instance projection in the platform prefix each. The poll is
  bounded and runs OUTSIDE `with_lock/2` and outside any transaction. There is no message passing to the runner.
- `create/2` takes `wait_ms:`. The router passes the setting. Signup passes 0.
- Tests set the wait to 0 or 2 s and drive the runner with `PlatformStepRunner.run_due/2` (the runner is off in the test
  env), so no test sleeps on wall-clock time.

### 9.3 `GET /admin/v1/tenants/:id`

- A tenant WITHOUT an admission row: today's answer, byte for byte, whatever the setting says.
- A tenant WITH an admission row: `{tenant_id, status, tier, created_at, expires_at, purged_at}`, read from the
  lifecycle row when it exists and from the admission row before that (`created_at` = the admission's `inserted_at`,
  `purged_at` null). `status` is computed in this order:
  1. the lifecycle row exists and is not `active` (suspended, expired, deleted) -> the lifecycle value (today's);
  2. the instance is `ERROR` or `CANCELLED` -> `failed`, plus `reason` from a closed set: `conflict` (the failure kinds
     `platform_call_duplicate_slug`, `platform_call_hostname_taken`, `platform_call_hostname_mismatch`,
     `platform_call_realm_already_bound`), `invalid_request` (`platform_call_arg_invalid`, a realm probe `not_found`),
     `internal` (everything else). Never a message, never a secret;
  3. the instance is `COMPLETED` -> `active`, plus `server_url` and `handover: {login_url}` (today's create body
     fields);
  4. otherwise -> `provisioning`.

### 9.4 What T-2728 / the portfolio side still owns

The portfolio provisioner's own "handles 202 + poll" task (PM change 3, `project/portfolio-task-provisioner-202.md`) is
outside this repository. Until it is proven against QA, the wait hint keeps the fast case compatible.

## 10. The seed of v2

- `Letflow.PlatformProcesses.Definition` gains the v2 document (`attrs/1` per version; v1 stays as it is for the tests
  that read it). `Seed.seed/1` writes v2 under the existing three answers. v1 active (the seed's own) -> write v2 and
  activate it (`:created`). A version `"2"` already exists -> compare its graph with the document: equal ->
  `:already_present`; different -> NEW answer `:version_taken`, and nothing is written. A version newer than 2 ->
  `:newer_version_kept`.
- An administrator's own v2 (for example the pilot's item-6 draft) is therefore never mistaken for the shipped
  document. The system start's contract check (C1, `register_tenant_v2_missing`) refuses a version that lacks the v2
  variables. So a wrong active version fails CLOSED with a log line and never runs half the chain.
- Existing QA rows: v1 stays as a deprecated version. Instances that run on v1 finish on their snapshot (the engine
  versioning rule).

## 11. Tests T-2727 carries (one row per criterion of this design)

| ID | What | File (new unless noted) |
|---|---|---|
| V1 | v2 document: node order, gateway default edge without a condition, reads/writes derived from the catalogue, `variable_schemas`, start permission; activation passes the G2/G13/G14 fences in the platform tenant | `test/letflow/platform_processes/definition_v2_test.exs` |
| V2 | each NEW/CHANGED step: first run, repeat = no write, each failure code, optional input absent = no-op; `tenant.create` with `requested_tenant_id`: id and slug used, slug mismatch refused, `tenant_type` with id refused | one file per body under `test/letflow/platform_functions/impl/` |
| V3 | front gate: admit, replay with the same body (no cap check), replay with another body -> 409, the old-path tenant goes to the old path, the cap and both budgets count admissions without a lifecycle row, two concurrent admits at cap-1 -> exactly one admitted (auto-mode sandbox, committed rows, `on_exit` cleanup) | `test/letflow/tenant_provisioner/admit_test.exs` |
| V4 | C1..C4 of section 6.2 | `test/letflow/platform_processes/system_start_test.exs` |
| V5 | callers pin of `SystemStart` (with the rogue fixture) | `test/letflow/platform_processes/system_start_callers_test.exs` |
| V6 | route 3 setting ON: fast finish 201 / replay 200 with today's body; slow -> 202 + poll; ERROR -> `failed` + closed reason; 409 cap before any INSTANCE_STARTED; GET answers per 9.3; setting OFF byte-identical; setting ON + runner off -> old path + warning | `test/letflow/routers/admin_v1_process_test.exs` (T-2728 owns the route half; T-2727 may land 6.x and 9.1 first) |
| V7 | route 4: pending -> retry, completed -> welcome mail once, failed reasons mapped | `test/letflow/signup/provisioning_process_test.exs` |
| V8 | routes 1/2 on v2: `tenant_type` reaches the row, `hostname` gives the onboarding record, `notify_admin: true` sends the mail when `admin_email` is supplied (branch A); route 2 WITHOUT `admin_email` builds `notify_admin: false`, routes `notify_gate` to `end` and the instance COMPLETES, no `notify_recipient_missing`, no ERROR (branch B); on v1 active, the builder sends no v2 keys | extend `test/letflow/platform_processes/register_routes_test.exs` (T-2704's file) |
| V9 | INV-4 canary: the e-mail, realm and hostname do not appear in any audit row, event metadata, log line (captured at `:debug` with `LOG_LEVEL=debug`, the T-2704 C finding) or GET answer | `test/letflow/platform_processes/system_start_canary_test.exs` |
| V10 | Sweep releases a stale admission and keeps an ERRORed instance's slot | extend `test/letflow/tenant_provisioner/sweep_test.exs` |
| V12 | crash gap: start committed, link update lost (admission `instance_id` null, ledger has the start): the Sweep repairs the link and does NOT delete; with no ledger start and age over 1 h it deletes; the Sweep and a concurrent start of one id are serialised by the session lock; `record_lifecycle` with `requested_tenant_id` and no admission fails closed, without it is a no-op | extend `test/letflow/tenant_provisioner/sweep_test.exs`, `admit_test.exs` |
| V13 | rollback at the cap: demo count = cap - 1, admit A (no tenant row), flip the setting OFF, replay A on the old path: 201, the lifecycle row carries the ADMITTED expiry and digests, the admission stays but no longer counts, the count is cap (not cap + 1), a different new id is still refused; the running instance then adopts the tenant (step 2) and step 4 writes nothing | extend `test/letflow/tenant_provisioner/admit_test.exs` |
| V14 | replay across versions: (a) operator request started on v1, v2 activated, the same request replays: 200/202 with the first instance, no 409; (b) system registration started on v2, then rollback to v1 and, separately, v2 deprecated: the same request replays the first instance; a changed value in each case is 409; `expires_at` omitted twice matches, sent once and omitted once differs | extend `test/letflow/platform_processes/register_routes_test.exs`, `system_start_test.exs` |
| V15 | completed registration survives cleanup: route 3 (setting ON) completes, the Sweep runs, then (a) a replay with a changed `name`/`language`/`tier`/`hostname` answers 409 (not the old path's ignore-body replay), (b) the same body answers 200 with today's body, (c) `GET` answers `active` with `server_url` and `handover`; after the tenant purge the admission is gone and the old path answers | extend `admit_test.exs`, `sweep_test.exs`, `admin_v1_process_test.exs` |
| V16 | optional-field replay (extends V14): first start without `hostname`, replay with `hostname` -> 409 (absent -> present); first start with `hostname`, replay without -> 409 (present -> absent); same for `admin_email`/`idp_realm_id` on routes 1/2; first start on v1, v2 active, replay with v2 keys absent -> replay, with a v2 key present (e.g. `tenant_type` other than the default) -> 409 only if `C` of the first version declares it, else the key is dropped | extend `register_routes_test.exs`, `system_start_test.exs` |
| V11 | seed: `:created` over v1, `:already_present`, `:version_taken`, `:newer_version_kept` | extend `test/letflow/platform_processes/seed_test.exs` |

Pins that move and that `lf.sh test` does not map (grep before the first checks run):
`test/letflow/platform_functions/catalog_test.exs` (the compiled chain), the registry `names/0` pin,
`test/letflow/platform_functions/tenant_create_callers_test.exs` (`Impl.TenantCreate` becomes a caller of
`Identity.create_provisioned_tenant/1`; `TenantProvisioner.create/1` STAYS in the pinned bypass list while the old path
exists), `test/letflow/routers/platform_functions_test.exs` (the catalogue read body), the web designer picker fixtures
that list function names (`git grep -n "tenant.install_default_modules" web/src`), `docs/platform-steps.md` (the
registered-functions table and the failure-kind vocabulary), `@expected_tenant_tables` is NOT moved (it lists TENANT schema tables, and `tenant_admissions` is global; `git grep -n
'"tenant_lifecycles"' -- test` finds no global table-list pin on 2026-11-24), and `previous_pack_test.exs` is not
affected (no module pack changes).

Test hygiene: `tenant_admissions` has no FK, so a leftover row never blocks a tenant drop, but it DOES count toward the
demo cap and the budgets of every later test on the shared database. Every fixture that commits an admission deletes it
in an `on_exit` registered after the fixture, and the signup and provisioner helpers in
`test/support/signup_test_helpers.ex` that delete `tenant_lifecycles` rows delete the admissions of the same ids.

## 12. Not in this design

- Routes 1/2 keep T-2704's answer (202). They are not moved to the wait hint.
- The old synchronous path is removed only after T-2610 is green twice with the new path (contract amendment, Rollback).
- No production switch: the provisioner mount is QA only (decision 0072).
