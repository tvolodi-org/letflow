# Platform steps: the catalogue, the registry and the dispatcher

A **platform step** is a step of a process definition that calls Letflow's own code by NAME
instead of an HTTP endpoint or a Lua script. This page says what exists today (2026-11-22) and
where each part lives.

The sibling step -- the one that sends a registered template to an address -- is the
[notification step](notification-steps.md).

Authority: the decision record
[`0094-platform-call-authority.md`](migration/decisions/0094-platform-call-authority.md) (the
authority rule of a platform step: who may switch one on, where it may run, what it may read)
and the "Register a tenant" pilot. The catalogue and the authority rule are gap G2; the registry
and the dispatcher are gap G1a (T-2589).

## The three parts

| Part | Module | What it is |
|---|---|---|
| The catalogue | `Letflow.PlatformFunctions.Catalog` | WHAT a platform function IS: its name, its typed inputs with a source class (`:start`, `:step`, `:person`), its typed outputs, the permission the activator and the starter must hold, its side effects, its idempotency key and the platform-tenant flag. It is COMPILED into the build: there is no write route and no run-time registration, so who may add an entry is whoever may merge code. |
| The registry | `Letflow.PlatformFunctions.Registry` | WHICH CODE runs a name. Closed twice over: a name the catalogue does not know has no body (`:platform_function_unknown`), and a name the catalogue declares but that has no body yet is refused (`:platform_function_not_implemented`). A body whose name is not in the catalogue is a COMPILE error. |
| The dispatcher | `Letflow.PlatformFunctions.Dispatcher` | RUNS a step: arm the durable row, claim it, check the authority, run the body, write the result. |

## The registered functions

| Name | Body | What it does |
|---|---|---|
| `platform.validate_registration` | `Impl.ValidateRegistration` | Checks the slug, the display name and the e-mail of a registration and returns `normalized_slug` and `email_domain`. NO side effect: it reads nothing, writes nothing and sends nothing out. It proves the whole path of a platform step (catalogue entry, closed registry, durable dispatcher, authority fence, per-step result row). |
| `tenant.validate` | `Impl.TenantValidate` | Read-only: checks the slug and the display name (byte bound, reserved slug) and that the slug is free or the same registration. Writes nothing. |
| `tenant.create` | `Impl.TenantCreate` | Writes the tenant row of the global registry. A repeat of the same call returns the first result (it adopts the tenant that carries the slug); a slug that belongs to ANOTHER tenant is refused, and so is a tenant that was purged. |
| `tenant.provision` | `Impl.TenantProvision` | Creates the tenant's schema, replays its migrations, seeds its roles and its HMAC key, and activates the tenant. A repeat changes nothing. A tenant that was purged is refused before the first write. |
| `tenant.provision_realm_and_invite` | `Impl.TenantProvisionRealmAndInvite` | (T-3153, design rows P1-P3) Asks the tenant provisioner (the sign-up client `Signup.RealmProvisioner` and its `LETFLOW_SIGNUP_PROVISIONER_URL` / `_TOKEN` / `_HOSTNAME_DOMAIN` config) for the realm and the first administrator, mails the invitation once, and returns the output `realm_id`; `tenant.bind_realm` binds it as the next step. The key is the tenant id (the provisioner's own idempotency key): a retry after a failed create asks again with the same key; a retry after a failed mail is a provisioner replay and repeats the invite as the "Forgot password" hint. The temporary password lives in one local variable, never in an input, output, row or log. Config absent: `platform_call_provisioner_not_configured`, no call. Codes: `platform_call_idp_unreachable` (identity side unreachable: transport, timeout, TLS, 502/503/504, 429; retryable, row P2), `platform_call_realm_create_failed` (the provisioner's own refusal), `platform_call_invite_failed`, `platform_call_invalid_slug`. |
| `tenant.record_lifecycle` | `Impl.TenantRecordLifecycle` | (v2, T-2727) Writes the tenant's `tenant_lifecycles` row from its admission row (`tenant_admissions`). A repeat writes nothing; no admission and no `requested_tenant_id` is a no-op; `requested_tenant_id` without an admission fails closed (`platform_call_lifecycle_failed`). |
| `tenant.record_onboarding` | `Impl.TenantRecordOnboarding` | (v2, T-2727) Writes the onboarding record (the hostname). No hostname is a no-op; the same hostname is a repeat; another hostname for the tenant is `platform_call_hostname_mismatch`; a taken one `platform_call_hostname_taken`. |
| `tenant.bind_realm` | `Impl.TenantBindRealm` | Binds the identity provider's realm to the tenant. A repeat binds nothing a second time; a different realm for a bound tenant is refused. |
| `tenant.grant_first_admins` | `Impl.TenantGrantFirstAdmins` | Stores the pending grant of the tenant's first administrator in the tenant's own schema. A repeat stores nothing a second time. |
| `tenant.install_default_modules` | `Impl.TenantInstallDefaultModules` | Installs the tenant's default modules. A repeat installs nothing a second time (the installer answers `:already_installed`). |
| `tenant.notify_admin` | `Impl.TenantNotifyAdmin` | Sends the `tenant_registered` notice to `admin_email` through the notification dispatcher (the G14 allow-list at dispatch, the send cap, one delivery row with no address). A repeat after a sent notice sends nothing (the delivery log is asked first). T-2727 V8. |
| `tenant.set_script_policy` | `Impl.TenantSetScriptPolicy` | Sets one platform-owned script policy of a tenant by id: `setting` `kill_switch` or `solo_audited`, a boolean `value`, a `reason`. Calls the same two `Letflow.Scripts.Policy` setters as the `PUT /tenants/:slug/script-policy/*` routes, so it writes the tenant-chain audit row with NO operator id and the platform-chain row with the STARTER's id (read from the instance's own `INSTANCE_STARTED` event, credential class `:platform_process`, accepted by those two setters only). A repeat writes nothing. The platform tenant itself and an unknown tenant are refused; failure code `platform_call_script_policy_failed` (policy row missing, audit failed). |

`tenant.validate` has a body since T-2704 (`Impl.TenantValidate`): the read-only first step of the
chain. It checks the byte bound, the reserved slugs and that the slug is free or belongs to the same
registration, with the same refusal codes as `tenant.create`, and writes nothing. Before it, the shipped
`platform.register_tenant` definition could not be started: the dispatcher refused the first node with
`:platform_function_not_implemented`.

A name that is DECLARED in the catalogue but has no body is refused with
`:platform_function_not_implemented` instead of pretending it ran (no entry is in that state today).

## The code of the routes now sits behind the bodies

The code that creates a tenant, provisions it, binds its realm, grants its first administrator
and installs its default modules used to sit in the routes (`POST /tenants`,
`POST /onboarding`, `POST /onboarding/:id/bind-realm`) and in the provisioner
(`POST /admin/v1/tenants`). Since T-2590 (gap G1b) that code lives in the modules above, and
the routes call THOSE modules: the route and the platform step run ONE implementation, and the
route's answers (a 409 for a duplicate slug, a 409 for a realm that is already bound, a 404 for
an unknown tenant) do not change. The pilot's later steps (gap G17) will make the routes START
the definition instead of calling the code directly; until then the routes work as they always
did.

A step runs outside any person's request, so it has no operator to name: the bodies that write
an audited row use the SYSTEM path of the product (`bind_provisioned_realm`,
`create_provisioned`). Those rows carry NO actor (`actor_id` is nil) and the marker that says
"a system wrote this" is in the entry itself: `actor_class: "provisioner"` in the tenant chain
of a realm bind, `created_via: "provisioning"` in the chain of a pending grant. The person who
switched a version on is recorded where it belongs, in the definition version's signed
`activated_by` document.

## The no-bypass rule: who may create a tenant (gap G17)

The pilot's rule is that a business function is a PROCESS and not a code path: every path that
creates a tenant must START the definition, so there is exactly one way to register a tenant and
the process is what the audit shows. The functions that write a tenant row
(`Letflow.Identity.create_tenant/1`, `Letflow.Identity.create_provisioned_tenant/1`) and the
functions that write a tenant schema (`Letflow.TenantOnboarding.provision_and_migrate/1` and its
AC9 recovery twin `Letflow.TenantOnboarding.recover_provisioning/1`, a second public name for the
same write) have therefore a CLOSED set of callers: the catalogue body of the step
(`tenant.create`, `tenant.provision`), the module they delegate to
(`Letflow.TenantProvisioner`) and the seed task (`mix letflow.seed`, which creates the platform
tenant before any definition can exist).

`test/letflow/platform_functions/tenant_create_callers_test.exs` is the scan that pins it: a
pure AST scan over `lib/**/*.ex`, in the shape of the sibling caller scans
(`credential_callers_test.exs`, `handler_writes_callers_test.exs`). The scan resolves a literal reference to a guarded module in these
forms: the plain, renamed (`as: I`), multi and `Elixir.`-prefixed alias; the fully qualified call
(with or without `Elixir.`); `apply/3`, `Kernel.apply/3` and `:erlang.apply/3` with a literal
function name; the capture `&Module.fun/1`; `import` (also `only:`/`except:`) with a local call;
a module attribute that holds the module; `defdelegate ..., to: Module`; and an atom that spells
the module. It FAILS CLOSED: a reference to a guarded module that none of those forms places (a
variable bound to the module, the module passed as an argument, `apply/3` with a computed function
name, `use`, a struct) is reported as unresolved, and the real-tree test pins the unresolved
references exactly (today: config keys and one catalogue tuple, each with its reason). The forms the
scan does NOT see are its "Accepted limits", each with a test that shows it is silent: a module name
built at run time (`Module.concat/1`, `String.to_atom/1`), `Code.eval_*`, a macro defined elsewhere
that expands into the call, and an `alias`/`import`/`use` written through a macro.

The scan also pins, EXACTLY, the
callers of the catalogue body's public wrappers (`TenantCreate.create_tenant/1`,
`TenantProvision.provision_and_migrate/1`) and of the provisioner chain
(`Letflow.TenantProvisioner.create/1`): the four ROUTES that create a tenant today
(`POST /tenants`, `POST /onboarding`, `POST /admin/v1/tenants` and the self-service signup).
That list is the REMAINING BYPASS, and it may only shrink: when the routes start the definition
instead of calling the code, the scan names the file that changed.

### Gap G17 is PARTIAL

What this change delivers:

* the CLOSED caller set of the four tenant-writing functions: a new caller of any of them
  anywhere in `lib/` fails the scan when it names the module literally (forms and limits above);
* the EXACT pin of the four remaining bypass routes: the pinned set may only SHRINK, so the
  rewiring removes an entry and the scan names the file that changed.

What is NOT delivered (the remainder of gap G17):

* the routes do NOT start the definition yet -- they still call the code, so the old direct
  registration path is still a way around the process;
* the "every route starts an instance" test does not exist yet.

The engine slice that RUNS a platform step now exists (T-2703; see "What is not built yet" below);
the rewiring is the remaining work (T-2704). It stays a separate step because the runner must be
switched on (`LETFLOW_START_PLATFORM_STEP_RUNNER`) wherever a route starts the definition. The rewiring task removes the four route entries from the scan's pinned list and THEN adds
the "every route starts an instance" test.

The "Register tenant" path of the screen (gap G3, T-2591) is not one of the four: it starts an
instance through `Letflow.PlatformProcesses.start_register_tenant/2` and that seam writes no
tenant, so the scan finds no caller of the write in it.

## What the chain does to a tenant that already exists

The operator's notes of the chain, in the operator's words. `tenant.create` is keyed on the
SLUG, and a repeat of the same call changes NOTHING:

* the tenant with that slug exists and carries the same name -- the step **ADOPTS** it: it
  answers that tenant's id and writes no row. The tenant may be one the step created, or one
  that already existed. An existing tenant that is not `:active` is then **activated** by the
  chain's `tenant.provision` step: the same activation `POST /tenants/:slug/reactivate`
  performs, and the operator's own authority (`:TenantsManage` in the platform tenant) covers
  it. The ROUTE refuses the same slug with a 409 -- on purpose: a route answers the conflict,
  a step must be able to repeat itself;
* the slug belongs to a DIFFERENT tenant (a different name) -- refused
  (`platform_call_duplicate_slug`). The step never takes over a tenant it was not asked about;
* the tenant with that slug was **PURGED** -- refused (`platform_call_tenant_purged`). A purge
  is final: the purge dropped the schema and the registration row, and marked the lifecycle
  row with `purged_at` (never cleared). The step refuses a purged tenant BEFORE it writes
  anything -- the very first act of a provisioning is `CREATE SCHEMA IF NOT EXISTS`, so a check
  placed later would leave a resurrected schema behind. The route path refuses the same tenant
  (`Identity.reactivate_tenant/1` answers `:tenant_purged`), and the check sits in the shared
  sequence (`Letflow.TenantOnboarding.provision_and_migrate/1`), so the route, the provisioner,
  the recovery path and the step all carry it.

## The personal datum in the dispatch row

The dispatch row stores the RESOLVED ARGUMENTS of the call it runs (`inputs`). For the tenant
family that is the slug, the name, the tenant id, the realm and the first administrator's
address. The row lives in the platform tenant's schema, so the administrator's address is a
personal datum in the platform's own database -- never in an audit entry, never in a log, never
in a screen (INV-4), but in that column. Gap G6 (the step log) reads that row, so the pilot's
threat model names the column.

## The closed vocabulary of the failure kind

`last_failure_kind` carries a code of the dispatcher's own CLOSED vocabulary
(`Dispatcher.failure_codes/0`). The vocabulary is not a hand list that may drift: the registered
bodies' own declared vocabularies (each body's `@type refusal`) are checked against it, so a
body cannot answer a code the row would refuse to carry, and a code nobody can enumerate is
reduced to the generic code `platform_step_failed`.

## The authority fence

Every dispatch calls `Letflow.PlatformFunctions.Guard.authorize_dispatch/1` BEFORE the body runs:
the call must be in the platform tenant (INV-10), the function must be in the compiled catalogue,
the stored graph must carry no foreign source beside the call, the `activated_by` document must
still verify against the tenant's signing key, and the activator must still hold the entry's
permission (a permission lost since the activation marks the definition `needs_reactivation`, so
the existing reactivation path heals it). A refused call never reaches the body.

## What the call is, not only who may run it

The fence proves WHO may run a call. The dispatcher proves WHAT the call is: the row is bound to
the node of the definition it names. Before the body runs, the node is read out of the STORED
graph and the row must agree with it -- the node must exist, it must declare a platform call, and
that call must be the row's function with the row's arguments (an argument the node declares as a
constant must carry exactly the declared value; an argument the node reads from a variable is the
instance's own value, which the engine resolves). A row that names a function or arguments no
definition declares is refused (`platform_call_node_missing`,
`platform_call_node_not_declared`, `platform_call_function_mismatch`,
`platform_call_arg_mismatch`) and never reaches the body.

## The durable row

`platform_step_dispatches` (one row per platform step, in the tenant's own schema):

* `call_key` -- the IDEMPOTENCY KEY of the call, composed by the dispatcher from the catalogue
  entry's declared key inputs (the slug for a registration). It carries a DIGEST of those inputs,
  never the raw value: the key inputs are tenant-controlled (a start variable), and a digest
  cannot overflow the key column (`varchar(255)` under a unique index) whatever a caller passes.
  It is unique per tenant schema.
* `input_fingerprint` -- the fingerprint of the whole argument set.
* `tenant_id` -- the tenant the row belongs to, DERIVED from the schema the row is written into
  (never taken from the caller): the row physically sits in that tenant's schema, so that is the
  tenant it claims to belong to.
* `status` -- `pending` (armed), `running` (claimed; the lease is `next_attempt_at`),
  `advanced` (the body returned its outputs), `given_up` (the call failed).
* `outputs`, `attempt_index`, `last_failure_kind`, `dispatched_at` -- the per-step RESULT.

So: the same key with the SAME arguments is the SAME call (the first result is returned, the body
does not run again), and the same key with DIFFERENT arguments is refused with
`idempotency_key_reuse`. A crash between the claim and the result loses nothing: the row stays
`running` and its lease expires, so the next claim takes it over.

The arming is INSERT-FIRST: the row is written with `ON CONFLICT (call_key) DO NOTHING`, so a
double click, a retry or a poller restart can never raise on the unique index -- the row that
carries the key is read back and the first result wins.

### The prefix of a call

Every public function of the dispatcher takes a prefix, and every one of them asks the same
question first: does this prefix name a live tenant schema that CARRIES the dispatch table? A
schema that is gone (the tenant was purged) or that never had the table (a tenant provisioned
before this migration) cannot hold a dispatch row, so it is refused with `invalid_schema_name`.
In the arming path a MALFORMED name is refused before any I/O (the derivation is pure) and a
WELL-FORMED name that names no live schema before the row is written (the dispatcher asks
Postgres, with a bound parameter, never with SQL text built from the caller's value); on the
dispatch paths the same question is asked by the same read.

The question is asked on EVERY path -- the arming, the dispatch (`attempt_dispatch/2`), the due
query (`due_dispatch_ids/2`), the poller cycle (`run_due/2`) and the outcome write
(`record_outcome/3`) -- because the alternative is a raw database error out of a public function:
a prefix that names no live schema makes the query fail with `42P01` (the relation does not
exist), where the module promises an error tuple. The arming path was guarded first and the
dispatch paths were not; a fix that covers one variant of the class leaves the next one live.
`run_due/2` and `due_dispatch_ids/2` answer `{:error, :invalid_schema_name}` for such a prefix
instead of a list of ids or a count map.

## The lease and the claim token: the body runs once

A platform step is the ONE place where a second run of the same body is expensive: the pilot's
chain creates a tenant, provisions a schema, binds a realm. So the dispatcher holds two things.

**The lease.** While a row is `running`, its `next_attempt_at` is the lease
(`Dispatcher.lease_ms/0`, five minutes -- it must outlast the slowest body). A dispatcher that
finds a `running` row whose lease has NOT expired must not take it over: the run that holds the
row is still in flight. Such a dispatch is refused with `platform_step_in_flight` and the body does
not run a second time. Only an EXPIRED lease (the run that held it was killed) may be taken over.

**The claim token.** The attempt that holds the row holds the row's `attempt_index` with it. The
result of an attempt is written only while the row still carries THAT number and is still
`running`. An attempt whose lease expired and whose row a later attempt took over therefore cannot
overwrite the result of the attempt that owns the row now: its outcome is dropped
(`platform_step_lease_lost`) and the newer attempt's result stands.

## The bounds of the arguments

Every declared input is bounded BEFORE the dispatcher does anything with it: a value over 4096
bytes is refused with `platform_call_arg_invalid` and nothing is written. The node id is bounded
the same way (255 bytes): it is a caller-supplied string that goes into a `varchar(255)` column,
and it is not one of the declared inputs, so it carries its own cap. The bodies bound their
own values too, in bytes, before the trim, the length check and the regex walk them: the slug is
at most 64 bytes, the display name at most 800 (four times its 200-character rule -- a safety
bound, not a tighter rule) and the e-mail at most 254 (the RFC's limit is in octets).

`arm/1` also refuses an option it does not read (`platform_call_arg_unknown`) instead of dropping
it in silence: a caller must not believe that, say, `:tenant_id` is honoured.

## The typed step mapping: what the step reads and what it writes

A step that maps variables DECLARES it (gap G13, T-2594). The `platform_call` attribute carries
two more keys beside the function and its arguments:

```json
"platform_call": {
  "function": "platform.validate_registration",
  "args": {"slug": {"var": "slug"}, "display_name": {"const": "Acme Ltd"}},
  "reads": {"slug": "string"},
  "writes": {"normalized_slug": "string", "email_domain": "string"}
}
```

`reads` and `writes` are maps of a variable name to its JSON-Schema type name (`string`, `number`,
`integer`, `boolean`, `object`, `array`). The names are flat: the instance variables are one flat
namespace.

The catalogue publishes its OWN type names -- a uuid is published as "uuid" -- and a declaration always
carries the JSON-Schema name: a uuid is declared as a string. The table is the server's own
(`Letflow.Definitions.StepMapping`'s `contract_family/1`, the same one the canonical platform-call
fixture uses), so the catalogue's name is never copied into a declaration. The designer writes that
name: nobody types a type by hand.

The declaration is checked against the definition's own `variable_schemas`
(`Letflow.Definitions.StepMapping`), at ACTIVATION and in the DESIGNER
(`POST /api/v1/definitions/:id/validate`):

| Rule | Code |
|---|---|
| the declaration is there | `step_mapping_declaration_missing` |
| it is a map of a name to a known type name | `step_mapping_declaration_malformed` |
| the name is not in the reserved engine namespace (`_sys`) | `step_mapping_reserved_refused` |
| the name is among the definition's variable schemas | `step_mapping_variable_undeclared` |
| the declared type agrees with the schema's type | `step_mapping_type_mismatch` |
| the declared type agrees with the catalogue entry's type | `step_mapping_entry_type_mismatch` |
| the write is not a variable a human task may write | `step_mapping_write_refused` |
| the write is an output the function produces | `step_mapping_write_not_declared` |
| every variable the step reads is declared | `step_mapping_read_undeclared` |

The fence runs on every path that switches a version on: activate, reactivate, version rollback and
promotion apply. A company tenant never sees these findings: it may not carry a platform call at
all, and the ONE fixed code (`:platform_call_not_allowed`) is the whole answer -- a catalogue's
type must not tell a stranger that the catalogue holds that entry.

At RUN time the declaration is a rule too: the dispatcher writes ONLY the outputs the step
declares. An output the function returned but the step did not declare is not written, and a step
that declares no writes at all is refused before the body runs
(`platform_call_mapping_not_declared`).

## The failure kind is a code, never a text

`last_failure_kind` carries a STABLE CODE: the row is read by the step log (gap G6) and must not
carry anything a tenant typed. A reason that is an atom names a code of the dispatcher's own
vocabulary; a reason that is a BINARY is caller-supplied text and is reduced to a code of the
closed vocabulary, and to the generic code `platform_step_failed` when it is none of them.
Nothing is ever inspected -- an inspected reason would carry the customer's text into the row,
and it can be longer than the column that holds it. The outcome is bounded before the write as
well: outputs that JSON cannot carry are refused with `platform_step_bad_result` and nothing is
written, and a failure of the database itself is `platform_step_outcome_failed`. The public
writer never raises.

## The attempt cap

A run killed uncatchably (the VM dies, the node is killed) leaves the row `running` with an
expired lease, so the next claim takes it over. The number of such take-overs is capped
(`Letflow.PlatformFunctions.Dispatcher.max_attempts/0`): a call that reaches the cap is
DEAD-LETTERED -- the row leaves the queue for good and keeps the failure kind
`platform_step_max_attempts`. The step log that shows it to a person is gap G6's job.

## The retry of a failed step (gap G7)

A failed step is visible (gap G6's step log) AND retryable (gap G7).
`Letflow.PlatformFunctions.Dispatcher.retry_failed_step/2` is the MANUAL retry of one call: an
operator asks for one more try, and the call runs once more.

It differs from the automatic claim in exactly two ways:

* the ATTEMPT CAP does not stop it. The cap bounds how often the lease of a CRASHED run may be
  taken over; an operator's deliberate retry gets exactly ONE attempt, and the attempt count
  keeps growing -- the step log shows the whole history of the step;
* the LEASE still stops it. A row that is `running` with a lease that has NOT expired is a body
  in flight: the retry is refused with `platform_step_in_flight` and the body does not run a
  second time.

The IDEMPOTENCY of the call is untouched: a row that already ran (its status is `advanced`) is
NOT run again -- the stored outputs come back and the answer is `already_final`. A retry of a
step that already did its work changes NOTHING. The AUTHORITY fence still runs before the body,
so a manual retry buys no extra authority.

`Letflow.Instances.StepRetry` is the module that finds the failed step of an instance and runs
it again:

| Part | What it does |
|---|---|
| `failed_step/2` | the failed step of an instance: the platform step whose row carries the failure (`given_up`), or the node of the instance's last `EXECUTION_ERROR` when that node is a notification step |
| `retry_step/2` | runs that step again, once |
| `retry_entry/2` | the DLQ wiring: an entry of type `platform_step` names the instance and the node, and its retry re-dispatches that step |

### The DLQ retry is wired to it

`Letflow.Dlq.retry/2` still owns the row's own state transition (design §3.4). For an entry of
type `platform_step` or `notify_step` it ALSO re-dispatches the step, after the row's
transaction has committed (a platform body may run DDL, so it must not run inside a transaction
the DLQ holds). The answer of the row then says what happened:

* the step ran again and succeeded -- the row is `resolved` and the last attempt of its history
  carries the outcome `resolved`;
* the step could not be run again -- the row stays `retrying` and the last attempt carries the
  outcome `failed` with the CODE of the refusal (a code of a closed vocabulary, never a text --
  INV-4).

An entry of any other type keeps the old behaviour: the row's own state transition and nothing
else. The route adds one check on top: the retry of a STEP entry is a platform act, so the
caller must be in the platform tenant AND hold `PLATFORM_ADMIN` there. The route's own
`:DlqOperate` permission is wider (it is held by `:PROCESS_OPERATOR` too), so that check is
what keeps a process operator from running a platform function.

### The engine runs a platform step (T-2703, gap G1 remainder)

A SERVICE_TASK node that carries a `platform_call` is run by the engine:

1. **Arm.** When a token enters the node, the engine resolves the step's arguments from the
   instance variables (`{"var": name}` or `{"const": value}`; a variable that carries a label
   never goes into the row) and calls `Dispatcher.arm/1` INSIDE its own transaction
   (`Letflow.Engine`, `build_service_task_dispatch_multi/5`, the same place every hop chain arms
   an HTTP or script step). The instance waits on the node. The call key is the catalogue
   entry's idempotency key, so a re-entry of the same node is the same call; a key that belongs
   to ANOTHER instance's call is refused and the start writes nothing. A LOOP back to a node that
   already ran is a new visit: the engine passes the count of earlier visits (`visit:`) and the call key
   of a later visit carries a `|v<n>` suffix, so it is a call of its own and never the first visit's replay.
   A node that declares `entity_writes` / `module_writes` is refused at activation and at entry
   (the platform route plans no entity writes); see the state table below.
2. **Run.** `Letflow.Engine.PlatformStepRunner` (ticked by `PlatformStepRunner.Poller`, config
   key `:start_platform_step_runner`, default off in every environment; switched on only by the env variable `LETFLOW_START_PLATFORM_STEP_RUNNER`, exactly `true`, dev included) runs the due rows of the PLATFORM tenant's
   schema only, OUTSIDE every transaction, through `Dispatcher.attempt_dispatch/2`: the lease
   and the claim token, and the authority fence of decision 0094 at EVERY attempt.
3. **Continue.** A row that advanced is handed to `Letflow.Engine.apply_platform_step_result/3`:
   the declared outputs are merged into the instance variables and the instance continues off
   the node. The completion key is the dispatch id, so a second apply moves nothing; a result
   that was written but never applied (a crash between the two commits) is applied by the
   runner's sweep, whatever the row's age. A result the engine REFUSES to apply is landed as a
   failure (ERROR + EXECUTION_ERROR + DLQ entry), never left parked. The sweep also lands the failure of a `given_up` row whose instance is still
   active (a death between the dispatcher's give-up commit and the engine's landing).
4. **Fail.** A row that gave up (a refusal of the body or of the fence, or the attempt cap after
   crashes) goes through `Letflow.Engine.fail_platform_step/2`: the instance is in ERROR with an
   EXECUTION_ERROR event (no variable is copied into it) and a DLQ entry of type
   `Letflow.Instances.StepRetry.platform_step_entry_type/0` whose `reference_id` is the node.
5. **Retry.** The DLQ retry (G7) re-runs the step; when it succeeds the engine applies the
   outputs, lifts the ERROR and continues the instance exactly once.

The dispatcher gives a call up on its first refusal; what is retried by itself is a CRASH (a
`running` row whose lease expired is taken over, up to the attempt cap).

#### The switch that starts the runner: `LETFLOW_START_PLATFORM_STEP_RUNNER`

The runner is OFF in every environment by default (a new flag defaults off). Its only
switch is the environment variable `LETFLOW_START_PLATFORM_STEP_RUNNER`, read once at boot
by `config/runtime.exs`: **exactly `true`** turns the runner on; unset, empty or any other
word leaves it off. `config/test.exs` keeps it off explicitly; everywhere else (dev
included) the variable alone decides.

**The trap.** With the runner off, a definition that reaches a `platform_call` node STARTS
and NEVER RUNS: the engine arms the dispatch row inside its own transaction (the row is
`pending`) and no worker claims it. The instance waits at the node for ever -- no error,
no retry, no DLQ entry, nothing in the log that says why. No screen fails; the instance
simply never leaves the step. A pilot that waits like this looks like a stuck process, not
like a missing setting.

So the variable belongs to the DEPLOYMENT, not to the build:

| Where | What |
|---|---|
| QA host | `LETFLOW_START_PLATFORM_STEP_RUNNER=true` in BOTH host-local files: `$APP_DIR/qa.env` (the file `deploy/redeploy-qa.sh` sources) and `$APP_DIR/deploy/.env` (the compose `env_file` of `deploy/docker-compose.qa.yml`, the file the app container boots with). `qa.env` alone does not reach the container. `deploy/redeploy-qa.sh` refuses to deploy when either file does not carry it exactly `true`; the runbook is `docs/runbooks/qa-platform-step-runner.md`. |
| Production | Unset means off, and the row in `docs/runbooks/production-readiness.md` §Settings says so, so an install that forgot it does not start with the runner off unnoticed. Turning it on in production is the owner's decision. |

### The engine runs a notification step (T-2810)

A SERVICE_TASK that carries a `notify` attribute (and nothing else that routes it) is route
`:notify`. Before T-2810 entering such a node fell to the HTTP branch, failed to parse and ended
the instance in ERROR. Now the engine arms the SAME durable row as a platform step
(`platform_step_dispatches`, `function_name` = `notify.send`, `inputs` empty) and
`Letflow.Engine.NotifyStepRunner` runs it on the same ticker, in EVERY tenant schema (a
notification step is a tenant step, unlike a platform call). The advance, the failure landing and
the DLQ retry are the platform step's own (`apply_platform_step_result/3`, `fail_platform_step/2`,
`Letflow.Instances.StepRetry`); the DLQ entry type is `notify_step`. The poller is the one gated by
`LETFLOW_START_PLATFORM_STEP_RUNNER`.

| path | trigger | effect | replay | logged / stored |
|---|---|---|---|---|
| success, mail | the row is due | the template is sent, the delivery row is written, the instance continues by the edges | the delivery log is asked FIRST (`already_done`): nothing is sent twice | row `advanced`; delivery row: key, locale, status, trigger (no address, no body) |
| success, file | the row is due | the rendered template is written into the tenant's area, the instance continues | same: a written file for this template and instance is not written again | row `advanced`; the file row |
| recipient variable absent or not an address | the row is due | refused with `notify_recipient_missing` / `notify_recipient_invalid`: ERROR + EXECUTION_ERROR + `notify_step` DLQ entry | the DLQ retry runs the step once more | row `given_up`, `last_failure_kind` = the code |
| template unknown | the row is due | refused (`notify_template_unknown`), same landing | retryable | same |
| destination off the allow-list | the row is due | refused at DISPATCH (`notify_destination_not_allowed`): the list is read at every attempt | retryable once the list allows it | same |
| send failure | the adapter fails | `notify_failed`: ERROR + DLQ | the retry sends (the log has no `sent` row yet) | same |
| the tenant's send cap | over the cap | nothing is sent (`notify_skipped`): ERROR + DLQ | retryable later | same |
| worker dies after the send, before its result | the lease (5 min) expires | the next claim takes the row over (attempt cap 5) | `already_done`: nothing is sent a second time | attempt count grows |
| retry from the DLQ | an operator | runs the row once (the cap does not stop it), lifts the ERROR and resumes the instance exactly once | a second retry answers `already_done` | the same row |

No address, name or body is written to a log, an audit row, the step row, a DLQ row or an answer
(INV-4): the recipient and the values are read from the instance's variables at run time. Open
point: the delivery log is keyed by template + instance, so two steps of the SAME template in one
instance count as one delivery; give them different templates. T-2727's `tenant.notify_admin`
platform function is untouched; a later version of the registration definition may use this
generic step instead.

### What is not built yet

The engine now arms and runs a platform step (T-2703). What remains is the rewiring: the routes
(`POST /onboarding` and the other four) still call the tenant code directly until gap G17
(T-2704) makes them START the definition (see "Gap G17 is PARTIAL" above).

### The state machine of a platform_call dispatch (T-2703)

The row's states are the dispatcher's (`pending`, `running`, `advanced`, `given_up`); LANDED is
the instance's side: an `advanced` row is landed when its completion key
(`platform_step_dispatch:<row id>`) exists, a `given_up` row when the instance went to ERROR for
it. A row that is not landed while its instance is ACTIVE and still holds a token on the node is
OUTSTANDING; the runner's sweeps recover outstanding rows of ANY age (there is no time window),
oldest first, in keyset pages of the cycle's limit (at most `@sweep_pages` pages per cycle), so a
row that keeps failing cannot starve the rows behind it. A `platform_call` node may not declare
`entity_writes` / `module_writes` (the platform route plans no lines): the node is refused at
activation (`conflicting_platform_call_routes`) and, for a graph that was activated before that
fence, when the token enters the node (`:conflicting_routes`, nothing is armed or run).

| State \ event | What happens next | What the instance sees | Test |
|---|---|---|---|
| (none) + token enters the node | `pending` (armed INSIDE the engine's transaction) | waits on the node | R1/R2 |
| (none) + node declares `entity_writes`/`module_writes` | refused at activation; at entry `:conflicting_routes`, no row | nothing starts (the start is refused) | R10, R8 |
| `pending` / `running` / `advanced` not yet applied + duplicate arm (the same visit armed again) | same row: the visit is the number of APPLIED earlier visits, so the key is the same and `ON CONFLICT DO NOTHING` replays it; no second row, no second run | waits on the node | R14a (pending), R14b (running), R14c (advanced not applied): sequential and two concurrent transactions on separate connections; the function body's calls are traced and counted |
| `given_up` + duplicate arm (the same visit armed again) | same row, left `given_up` (the engine does not re-arm it; only the DLQ retry runs a failed step again) | stays ERROR / the landing runs once | R14d (a real function error, then sequential and concurrent arms) |
| `pending` + another instance's key | refused (`platform_call_key_in_use`), nothing written | the start/advance is refused | R7 |
| `pending` + runner claims | `running` (lease + claim token) | waits | R1 |
| `running` + success | `advanced`, then the apply: LANDED | continues off the node with the declared outputs | R1 |
| `running` + function or authority-fence refusal | `given_up`, then the landing: LANDED | ERROR + EXECUTION_ERROR + DLQ entry (`platform_step`) | R3 |
| `advanced` + apply refusal (`:not_planned` lines, a variable merge refusal, a reserved engine variable in the outputs, a hop chain with NO MATCHING EDGE, a downstream node that cannot arm, a graph that cannot be read) | stays `advanced`; the apply rolls back (no SERVICE_TASK_COMPLETED, no completion key) and the refusal is LANDED as the platform failure | ERROR + EXECUTION_ERROR (`failure_kind: apply_refused`, `apply_refusal: <code>`) + DLQ entry (`platform_step`) | R13, R15 |
| `advanced` + an output names a reserved engine variable, at activation | refused (`step_mapping_reserved_refused`); a graph that slipped past it is the apply refusal above (`reserved_variable_key`) | nothing starts | step_mapping_activation_test.exs |
| `running` + runner crash BEFORE the result commit | `running` until the lease expires, then taken over (up to the attempt cap, then `given_up`) | waits | R5 |
| `advanced` + runner crash AFTER the commit, before the apply | outstanding: the sweep applies it, once | continues | R5 (sweep) |
| `given_up` + runner crash AFTER the commit, before the landing | outstanding: the sweep lands it, once | ERROR + EXECUTION_ERROR + DLQ entry | R9 |
| outstanding row + runner resumed after ANY age (days) | applied / landed like a fresh one | continues / ERROR + DLQ | R12 |
| `given_up` (landed) + DLQ retry (G7) | `pending` -> run -> `advanced`, applied with `resume: true` | ERROR lifted, continues exactly once; a second retry moves nothing | R4 |
| `advanced` with a landed apply refusal + DLQ retry | not run again (`already_final`); the apply is refused again | stays in ERROR; the retry answers a typed code | R13, R15 |
| `advanced` (applied) + loop back to the node | a NEW row (`visit: n`, n = the applied visits, key suffix `\|v<n>`) | runs again, continues | R11, R14e (the first arm of the new visit from two concurrent transactions: one new row) |
| `advanced` being applied + loop STRAIGHT back to the node in the same apply (call -> gateway -> call) | a NEW row: the row whose apply arms the next visit is counted as applied (its completion key is written later in the same transaction), so the next arm gets the next visit | continues on the node: the new visit runs in the next cycle, once | R17 |
| `pending` / `running` (any lease) + instance cancelled | `given_up` with `platform_step_instance_cancelled`, in the cancel's own transaction (dispatch rows before the projection, the order of the apply and the claim) | cancelled; the function never runs; no EXECUTION_ERROR, no DLQ entry | R16a, R16b |
| any open row + claim (automatic or the DLQ retry) after the instance ended (cancelled or completed) | `given_up` with `platform_step_instance_cancelled` at the claim; the function is not run | unchanged | R16c, R14e |
| `running` with a body in flight + instance cancelled | the body cannot be stopped; the row is closed by the cancel, so its outcome write finds it no longer `running` (claim token) and is dropped | cancelled | (the claim-token contract: dispatcher S8) |
| any + foreign (company) tenant or unlisted function | never runs (`run_due/2` refuses the prefix; unknown function refused at arm) | the company tenant cannot hold the call | R6 |
| outstanding row + instance no longer active (cancelled, terminated) | left as is: no sweep reads it | unchanged | R13 |

## Why the body runs outside the engine's transaction

A platform function may run DDL -- `tenant.provision` creates a tenant schema and replays its
migrations -- and DDL does not belong inside the engine's transaction, which holds the instance's
own rows for the whole step. The dispatcher therefore splits the work: the claim transaction
commits BEFORE the body starts, and the result transaction opens only AFTER the body returned.
No engine transaction and no dispatcher transaction is open while the body runs.

## Extension point (owner decision D-180, not built here)

A tenant may later FORK a standard definition into its own copy (`custom`, `based_on`, and a
per-tenant binding of which definition runs). The dispatch row needs NO column for that: it
references the definition row by `definition_id`, and a forked copy is a different definition row.
Nothing in this change assumes that a definition is editable by whoever sees it, or that a tenant
has exactly one definition per key.

## The step log: what a step did, in one row (gap G6)

`GET /api/v1/instances/:id/timeline` carries the STEP LOG next to its event page: one row per node
visit -- who ran it, when it started, when it ended, how it ended, how long it took, how many
attempts it took and the failure kind of the last attempt. `Letflow.Instances.StepLog` derives it
from what the engine already writes: the instance's own events (the `NODE_ENTERED` event that
opened the visit and the event that closed it) and the dispatch rows of the three automatic step
kinds (`service_task_dispatches`, `script_task_dispatches`, `platform_step_dispatches`). There is
NO step-log table and NO second write path.

A step row names the node, the function (or the script) the node ran and the OUTCOME. It never
carries a value: no input, no output, no request body, no response body, no URL, no header. The
dispatch row above DOES hold the resolved arguments (the realm, the first administrator's
address); the log reads that row for the attempt count and the failure kind and copies nothing
else. An HTTP service task's row carries no name at all, because its URL and its
`config_snapshot` can carry a secret.

The DLQ row of an exhausted step follows the same rule: it keeps the METHOD and the ORIGIN of
the destination and drops the body, the headers, the path and the query, so a bearer credential,
a mail body or a token in a query string cannot reach the dead-letter table (INV-4).

A visit is closed by the first event that closes it, and every one of those rules reads the node
the way the WRITER of the event writes it: a completion event (`TASK_COMPLETED`,
`SERVICE_TASK_COMPLETED`, `SCRIPT_TASK_COMPLETED`, `SUB_PROCESS_COMPLETED`, `TIMER_FIRED`) names
the node in its own `node_id`, and an `EXECUTION_ERROR` names the affected resource under
`affected` (`{"kind": "node", "node_id": ...}`) -- so an error closes the visit of the node it
happened on, even when another visit is open at the same time, and only an error that names NO
node (a field error) falls back to the oldest open visit. The `SUB_PROCESS_COMPLETED` event
writes the parent's own node since pilot gap G6, so a sub-process visit ends with a result and a
duration instead of running for the rest of the instance's life.

The log is a screen, not an export: the event read is capped at the most recent 5 000 events, the
answer holds at most the most recent 200 visits, and the event query projects the few payload
fields the log needs (`node_id`, `node_type`, `affected`) in the database -- a payload body (an
output, a decoded HTTP body, a variable map) is never loaded into the process.

## The tests

* `test/letflow/platform_functions/dispatcher_test.exs` -- the dispatcher, the authority fence,
  the refusals, the structural proof that the body runs outside every transaction the
  dispatcher owns, and the security properties: the repeated arming does not raise, the row's
  tenant is derived from the schema, a bad prefix is refused, the row is bound to the
  definition's node, another tenant's row is never touched, and the attempt cap dead-letters a
  call. The last block of the file covers the mutual exclusion: a row whose lease has not expired
  is not re-claimed, two dispatchers of one row run the body once, an id that is not an id
  answers the uniform refusal, a value over the byte cap is refused before anything is written,
  an option the dispatcher does not read is refused, and a stale attempt cannot overwrite the
  result of the attempt that owns the row. It ends with the bounds of the write side: a node id
  over the byte cap is refused before anything is written, a well-formed prefix that names no
  live schema is refused as such, the failure kind is a stable code and never a customer text,
  and an outcome the row cannot carry is refused and leaves the row unchanged. The last two
  tests cover the CLASS of the prefix refusal (the same answer on every public path that takes
  a prefix) and the INV-10 negative test of the new path (a row armed in a company tenant is
  refused, the function never runs, the company row carries no outputs).
* `test/letflow/platform_functions/platform_call_idempotent_replay_test.exs` -- S8: the replay of a
  call (one call, one result, one row) and the key reuse.
* `test/letflow/definitions/platform_call_activator_signature_test.exs` -- S9: the signature and
  the revoked activator, through the guard and through the dispatcher.
* `test/letflow/platform_functions/registry_test.exs` and
  `test/letflow/platform_functions/impl/validate_registration_test.exs` -- the closed registry and
  the harmless body.
* `test/letflow/platform_functions/impl/tenant_create_test.exs`,
  `tenant_provision_test.exs`, `tenant_bind_realm_test.exs`,
  `tenant_grant_first_admins_test.exs`, `tenant_install_default_modules_test.exs` and
  `system_caller_test.exs` -- the bodies of the tenant family (gap G1b): each one is
  registered, each one is IDEMPOTENT (a second run changes nothing and answers the same), and
  each one refuses a value over its byte cap, an unknown tenant and a value that is not a UUID.
  The create test also pins the ADOPTION (the step answers the id of the tenant that carries
  the slug and writes nothing) and the refusal of a PURGED tenant; the provision test proves
  that a purged tenant is refused before anything is written (the product's own purge empties
  it); the bind and the grant tests read the audit rows back (no actor, the explicit marker,
  no address in the entry). The registry test also scans the routes and the provisioner: the
  direct calls are gone, the implementation modules carry them.
* `test/letflow/platform_functions/tenant_create_callers_test.exs` -- the NO BYPASS scan of gap
  G17: the CLOSED set of callers of the four functions that write a tenant row or a tenant
  schema (the catalogue body's public wrappers, the module they delegate to and the seed task),
  the EXACT pin of the four routes that still reach the write (a set that may only shrink), and
  the non-vacuity of the scan itself (a rogue caller is flagged in every call form -- the plain
  alias, the renamed alias `as: I`, the multi alias, the fully qualified call, `apply/3`, the
  capture and the import; an alias to a module of the same last name is not, a doc mention and a
  definition are not call sites).
* `test/letflow/platform_functions/failure_vocabulary_test.exs` -- the CLOSED vocabulary of
  the row's failure kind: the set is derived from the tree (every module under
  `lib/letflow/platform_functions/impl/` and its own `@type refusal`), a code nobody can
  enumerate is reduced to the generic code through `Dispatcher.record_outcome/3`, and every
  body of the tree is a registered one. Tagged `:security_probe`, so it runs in the checks
  step for every backend change.
* `test/letflow/instances/step_log_test.exs` -- the derivation of the step log: a human task visit
  is one step with its actor, its times, its result, its duration and its attempts; a pass-through
  node is closed by the next node visit; an `EXECUTION_ERROR` closes the step it names; a
  cancelled instance closes every open step; a platform step names the function it ran and takes
  its attempts and its failure kind from its own dispatch row.
* `test/letflow/platform_functions/dispatcher_retry_test.exs` -- the MANUAL retry of a call
  (gap G7): the attempt cap does not stop it, the lease still does (a body in flight is not run
  a second time), a call that already ran is not run again, and a row of another tenant is
  invisible.
* `test/letflow/instances/step_log_secret_test.exs` -- the NO-SECRET proof (owner items 4 and 7):
  a step whose dispatch row holds a realm credential, a token and a mail body puts none of them
  into the step log or into the timeline answer, and the DLQ payload of an exhausted step keeps
  the method and the origin and drops the body, the headers and the query.
