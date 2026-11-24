# 0094: the authority rule for platform steps (T-2588, pilot gap G2)

Status: accepted. Implements the G2 gap of the "Register a tenant" pilot (the spike of 2026-11-21, decision record
`docs/decision-record-g2-authority-rule.md` of the team repository, PM ruling D-179 of 2026-11-21: option A of all five
decisions). The step library that RUNS a platform call (gap G1) landed later (T-2703, see the amendment of 2026-11-24 at the end of the residual risks); this record settles who may switch one on,
where it may run, what it may read and who may start the definition that carries it.

## Problem

Today the only path from a step of a definition to Letflow's own code is a `module_writes` line, and it needs the OWNER STAMP: the
definition must be an unedited copy of a version an installed module shipped, with a matching manifest hash and an unchanged body.
Any tenant-created, edited, imported, promoted or rolled-back copy has no stamp, so its handler lines are refused with
`:module_write_stamp_missing` (`lib/letflow/definitions/module_writes.ex:33-35`).

The pilot needs the opposite: a definition the platform tenant draws and edits must be able to call a platform function ("create a
tenant"), switched on by the person who holds the platform authority, not by code review of a shipped module.

## Options

**(a) Which functions a definition may call.**

*Option A (chosen).* A COMPILED catalogue of platform functions, next to `Letflow.Modules.Catalog` and in the same form: an entry is
declared in code (by the core, for the platform family) and exists only if it is in the build. An entry holds its name, family and
version, its typed inputs with a SOURCE CLASS (`:start`, `:step`, `:person`), its typed outputs, the permission the activator and the
starter must hold, its side effects in plain words plus a class, its idempotency key, and whether it may run only in the platform
tenant. There is NO write route and no run-time registration: who may add an entry is whoever may merge code.

*Option B (rejected).* A catalogue the platform administrator registers at run time (rows in a table: name, endpoint or script,
argument schema). More flexible, but a row is then code-by-configuration: a person, not a review, decides what a name does, and a
stolen admin session can add a function.

**(b) Who may add a step of which kind, and what replaces the owner stamp.**

*Option A (chosen).* The step kind carries its own atom, checked at activation against the SIGNED ACTIVATOR: a `platform_call` step
needs the catalogue entry's permission (`:TenantsManage` for the tenant family), the definition must live in the platform tenant, and
the activator's tenant must be the platform tenant (INV-10). Activation, version rollback and promotion all run the same check, because
all three sign the `activated_by` document. The signed activator REPLACES the owner stamp for catalogue calls: the rule is "switched on
by someone who holds the entry's permission, in the right tenant, with a signature checked at every call", not "unchanged since the
module shipped it". The T-2430 rule carries over by input source class: a write-like input of a catalogue call reads only start
variables or earlier platform-step outputs, never a human task's completer. A designer-fixed `%{"const" => json}` argument is a THIRD,
signed source beside those two variable sources: it is accepted for any declared input, is not person-writable, and sits inside the
signed graph hash, so the activator fixes its value at activation time rather than reading it at start time. A variable name is ONE
flat top-level key: a nested or dotted name such as `a.b` is malformed and is refused with `:platform_call_arg_source_invalid` at
activation; the G1 dispatcher must resolve names only as flat keys and must never add dotted-path resolution, which would bypass the
exact-match person-writable source comparison. No write-like input may
come from a FOREIGN SOURCE either: a graph that carries a write-like catalogue call carries no inline HTTP service task, no
script-bound one and no sub-process, because such a node merges its own output into the same instance variables and could overwrite
the value the call reads. The refusal is
`:platform_call_foreign_source_refused`, at activation AND at dispatch (the dispatch guard re-checks the graph it is about to run).
The step kinds are EXCLUSIVE: a node that declares `platform_call` may not also carry `endpoint`, `service_id` or `script_key`. Such a
node would otherwise be parsed by the runtime as the other route while the source rule exempted it as a closed catalogue call. Graph
validation, activation and dispatch all refuse it with `:conflicting_platform_call_routes`; a dual-route node also remains a foreign
source beside a write-like catalogue call.

*Option B (rejected).* A new atom per definition class (`PlatformDefinitionsWrite`) needed to EDIT any definition in the platform
tenant that contains a platform step. It blocks drawing and testing a draft and still needs the activation check.

**(c) The per-tenant channel and address allow-list.** Settled in a later change (the pilot's guardrail gap G14, with the new
`OutboundDestinationsManage` atom). Nothing of it is in this record, and nothing of it is in this change.

**(d) The audit actor.** The lifecycle audit row carries the caller: the HTTP paths pass the caller's user id into the lifecycle
functions, and a caller that is not a person (module code, a seed task) writes no actor. The reason REQ-195 gave for the `actor_id:
nil` disposition (its AC11 forbade touching the definitions router) has lapsed; the router now supplies the actor. The row ALSO carries
the KIND of the actor in the new tenant-scoped column `audit_entries.actor_kind` -- `user` or `system` -- so that "nobody" and "the
system" are told apart BY THE ROW and not only by a `nil` actor id (the column is not part of REQ-195's canonical hashed form: the
chain keeps its eleven fields, and the table's own immutability trigger keeps the kind from being edited afterwards).
`Audit.insert_entry/3` applies that default to EVERY audit row, not only to definition lifecycle rows: a valid user UUID means `user`;
a missing or non-person actor means `system`.

Every HTTP lifecycle path THAT WRITES a definition audit row carries the caller -- create, IMPORT, activate, reactivate, deactivate,
archive, and the DELETE route (which writes the deactivate and archive rows). The two activation rows carry the ACTIVATOR's user id --
the person who switched the version on -- and the other rows the caller's user id; both are the caller, and the row must say so. The
import path is the one that was easy to forget: it passes the caller as the separate `imported_by` argument (which reaches the
definition's `created_by` column) and had handed the context the prefix-only opts, so its `definition.create` row named nobody and
claimed the system did it. The opts and the `imported_by` argument are BOTH the caller, and the row must say so.

Two pre-existing exclusions are explicit: PUT/PATCH draft update and hard-delete write NO definition audit row, and version rollback
writes the `DEFINITION_VERSION_ROLLED_BACK` EVENT (with its actor) rather than a definition audit row. This change does not invent rows on those paths;
the actor invariant governs every lifecycle audit row that is written. Adding audit rows to draft update or hard-delete is a later slice,
not part of G2.

A SCAN TEST (`test/letflow/definitions/definition_audit_actor_paths_scan_test.exs`) keeps it that way. It derives, from the AST of the
definition context modules, every public function that writes a definition AUDIT row, reads where that function's audit actor comes
from (the `opts[:actor_id]` a caller passes, or the activator a caller passes), and requires every router path that calls such a
function to carry that actor. Nothing in it is a hand-written list of paths, so a new definition-writing route that forgets the actor
fails the scan.

**(e) How a definition that calls a platform function is started.** The START PERMISSION of a definition is the catalogue permission of
the entries its steps call, and the ONE start function (`Letflow.Engine.create/2`) checks it: the start variables of such a definition
are trusted inputs, so the start needs the same authority the activation does. A caller without it, and every caller outside the
platform tenant, gets the answer for an UNKNOWN definition (INV-5) and starts nothing. The SUB_PROCESS children a definition starts
count with it: a child inherits the parent's start variables, so a child that calls a platform function needs the same authority as a
direct start. Until the server-side caller is propagated to a child's own activation (gap G3/G17), a child that carries a platform call
is REFUSED at its activation -- fail closed, with the answer for an unknown definition.

## Choice and reasons

Option A everywhere. The compiled catalogue keeps the "who may add a function" question inside code review; the signed activator
replaces the owner stamp without opening a hole, because the signature is verified at every call and a permission lost since the
activation flags the row `needs_reactivation` (REQ-515's existing path).

## D-180 boundary: standard definitions and later forks

The pilot definition is a STANDARD definition in the platform tenant. Under owner decision D-180 a standard definition is LOCKED for
everyone inside a tenant, including `TENANT_ADMIN`; a tenant may later FORK a `custom` copy recording `based_on: <standard
key>@<version>`, with a per-tenant binding choosing which copy runs. That fork/binding mechanism is NOT built in this change.

G2 adds no definition field, column or table, so there is no schema migration to reserve for `based_on` or `custom`. The extension
point is the definition's existing versioned row and graph: the start permission is derived independently from EACH definition's own
graph, and nothing here assumes that a definition is editable by whoever can see it, or that a tenant has exactly one definition per
key. The later D-180 slice may add nullable lineage/binding data without changing the authority checks in this record.

## What the code does

| Where | What |
|---|---|
| `lib/letflow/platform_functions/catalog.ex` | the compiled catalogue: `list/1` (only the entries the caller's tenant may use), `fetch/1`, `permission_atoms/0`, `entry_map/1`. A duplicate or malformed entry is a COMPILE error |
| `lib/letflow/platform_functions/entry.ex` | the entry shape: typed inputs with a source class, typed outputs, the permission, the side effects, the idempotency key, the platform-tenant flag |
| `lib/letflow/platform_functions/tenant_family.ex` | the platform family's declarations: `tenant.validate`, `tenant.create`, `tenant.provision`, `tenant.bind_realm`, `tenant.grant_first_admins`, `tenant.install_default_modules` |
| `lib/letflow/platform_functions/guard.ex` | the RUN-TIME fence: the tenant (INV-10), the catalogue entry, exclusive step routes, foreign sources, the signature, and the activator's CURRENT permission (a loss flags the row `needs_reactivation`) |
| `lib/letflow/definitions/graph.ex` | graph validation refuses a `platform_call` node that also carries `endpoint`, `service_id` or `script_key` with `:conflicting_platform_call_routes` |
| `lib/letflow/definitions/platform_calls.ex` | the ACTIVATION fence: the platform tenant, exclusive step routes, the entry, the activator's permission, the argument shape, the input source classes (the human-task inputs AND the foreign sources) |
| `lib/letflow/definitions/start_permission.ex` | the START permission of a definition, derived from its entries and from the entries of the SUB_PROCESS children it starts |
| `lib/letflow/audit.ex`, `lib/letflow/audit/entry.ex` | the `actor_kind` of an audit row: `user` against `system` |
| `lib/letflow/routers/platform_functions.ex` | the read route `GET /api/v1/platform-functions` (`:TenantsManage`); the only route the catalogue has; the catch-all `authz_unmatched(:platform_prefix)` answers an unmatched sub-path (the uniform 403 for a non-operator, the zero-detail 404 for the platform tenant's operator) instead of raising |
| `lib/letflow/engine/write_targets.ex` | the read keys of a catalogue call join the write-target keys: a completion body may not carry them (the T-2430 rule, extended) |

The `platform_call` step is a SERVICE_TASK attribute, the fourth route of that node kind next to the HTTP endpoint, the catalogue
service and the Lua script: `attributes["platform_call"] :: %{"function" => name, "args" => %{arg => %{"var" => v} | %{"const" => j}}}`.
A `const` is the third, designer-fixed source described in (b): it is accepted for any declared input and is signed inside the graph,
fixing the value at activation time rather than start time. The routes are mutually exclusive on one node: a platform-call node carrying
any of `endpoint`, `service_id` or `script_key` is invalid.

The read route's body publishes an entry's key composition under `idempotency_inputs` -- the input names that make a repeat the same
call -- and never under the name of the CALLER's idempotency key: that key belongs to `Letflow.Idempotency` alone, and the AC5 guard of
`test/letflow/idempotency_test.exs` scans every source file for it.

## The one code a company tenant ever sees

A company tenant may not carry a `platform_call` step at all. Every path that touches such a definition -- the write path of a draft
(and therefore the import), the UPDATE path (PUT and PATCH), the designer's validate route, the activation, the promotion -- answers
`:platform_call_not_allowed`, the same answer whether the function exists or not, and the same 422 at the HTTP surface. A stranger may
not learn which platform functions exist (INV-5).

The rule is checked where the graph is written, and a SCAN TEST (`test/letflow/definitions/platform_call_write_paths_scan_test.exs`)
lists every entry point that writes a definition row and fails when a new one appears without the check -- so "one path forgotten" cannot
come back.

## Tests

| # | Abuse case | Test |
|---|---|---|
| S1 | a `PROCESS_DESIGNER` of the platform tenant activates a version with a platform call | `test/letflow/definitions/platform_call_activation_authority_test.exs`: refused; `PLATFORM_ADMIN` activates; the rollback path runs the same check |
| S2 | a human task writes the key the platform call reads | `test/letflow/engine/platform_call_completer_refused_test.exs` (the completion is refused with the 422 `output_refused`) and `test/letflow/modules/write_target_sources_scan_test.exs` (the scan covers `platform_call`) |
| S3 | a company tenant carries a platform call | `test/letflow/definitions/platform_call_company_tenant_refused_test.exs` (validate, import, activation, promotion) and `test/letflow/engine/platform_dispatch_tenant_guard_test.exs` (a forged dispatch row in a company schema) |
| S4/S5 | a company user, or a platform user without the permission, starts the definition | `test/letflow/engine/platform_call_start_permission_test.exs`: the answer for an unknown definition |
| S9 | the `activated_by` document is edited, or the activator lost the permission | `test/letflow/definitions/platform_call_activator_signature_test.exs`: the tampered MAC is refused; a revoked role refuses the call and flags the row `needs_reactivation` |
| S13 | run-time catalogue tampering | `test/letflow/api/platform_catalogue_has_no_write_route_test.exs`: the route inventory holds one GET under the catalogue's mount and no write method |
| S13 (read route) | a company tenant learns which platform functions exist | `test/letflow/routers/platform_functions_test.exs`: the platform admin of the platform tenant reads the catalogue; a company administrator and a company tenant whose stored token still carries `PLATFORM_ADMIN` are refused the uniform 403, and the refusal names no function |
| catalogue shape | an entry drifts from the contract the designer reads | `test/letflow/platform_functions/catalog_test.exs`: the compiled chain, the platform atom, the platform-tenant flag and the EXACT key set of the entry map; compile-time validation refuses a write-like entry with a `:person` input while allowing one on a read-only entry |
| S3 (the write paths) | a company tenant PUTs or PATCHes a platform call into a draft | `test/letflow/definitions/platform_call_write_path_refused_test.exs`: create, PUT and PATCH answer the one fixed code (422) and store nothing |
| S2 (the foreign sources and dual-route exploit) | an inline HTTP, script or sub-process node overwrites the value the catalogue call reads; one node declares both `platform_call` and another route | `test/letflow/definitions/platform_call_foreign_source_refused_test.exs`: graph validation, activation and dispatch refuse mixed routes with `:conflicting_platform_call_routes`; a dual-route node still triggers `:platform_call_foreign_source_refused` beside a write-like call |
| the start of a parent | a platform PROCESS_OPERATOR starts a parent whose sub-process child calls `tenant.create` | `test/letflow/engine/platform_call_subprocess_start_refused_test.exs`: the answer for an unknown definition, nothing written; the child's own activation fails closed |
| S11 (the audit actor) | a lifecycle row says nothing about who did it | `test/letflow/definitions/definition_audit_actor_test.exs`: a person's row says `user`, a non-HTTP caller's row says `system`; EVERY HTTP lifecycle route is driven through the real router and writes the caller's row -- create, IMPORT, activate, reactivate, deactivate, archive and DELETE (T-2598, the pilot's guardrail gap G15, completed the proof of the routes T-2588 had wired); a system caller (the reactivation marker) and a module install write `system`, and the module install's row names the module that shipped it |
| "one path forgotten" | a new definition write path skips the platform-call check | `test/letflow/definitions/platform_call_write_paths_scan_test.exs`: every entry point is classified and reaches the check its class demands; insert, changeset update (`update`/`update!`), update-all and delete writes are all derived |
| "one path forgotten" (the actor) | a new definition write path writes its audit row without the caller | `test/letflow/definitions/definition_audit_actor_paths_scan_test.exs`: the audit-writing context functions and the router paths that call them are derived from the AST, and every router path carries the actor its context function demands; a router path that reaches a writer which writes NO actor (the system class -- module code, a seed task, the reactivation marker) fails the scan, because a person made that request; the scanned ROOT may not shrink either -- every module of the definitions tree that writes a definition audit row is in it, or the scan says so |
| the start over the route | the caller's authority never reaches the start gate, and the pilot's process can never be started | `test/letflow/routers/platform_call_start_route_test.exs`: over the real `POST /api/v1/instances`, the platform tenant's PLATFORM_ADMIN starts the definition (201); a platform user without the entry's permission and a company tenant's administrator get the answer for an unknown definition, and nothing is written |

## Amendment 2026-11-24: the system-authority start (design T-2734, build T-2727)

Decision (e) refuses every start that has no person behind it (`StartPermission.check/3`: a nil `auth_context` gets the
answer for an unknown definition). Two of the four tenant-creating paths of gap G17 have no person behind them: the
provisioner mount `POST /admin/v1/tenants` (decision 0072, QA only) and the self-service signup. The PM ruled on
2026-11-24 that they start `platform.register_tenant` through a NARROW system authority, under five conditions:

1. it is bound to this ONE definition name (`platform.register_tenant`), in the platform tenant, and only to a version
   whose catalogue calls need exactly `:TenantsManage`, which starts no SUB_PROCESS child, and which carries the v2
   start contract. Any other definition, version or tenant gets the answer for an unknown definition, and nothing is
   written;
2. its `instance.create` audit row says `actor_kind: system`, with no actor id, and names the calling route
   (`started_via`);
3. no value from a request is trusted as identity or permission: the server builds the authority value after its own
   authentication (the provisioner credential class, or the signup's verified row), from a closed route list, and no
   request field can make one;
4. today's rate and abuse limits stay in front of it: the credential limiter, the body cap, the request validation,
   and the demo cap with the two daily budgets. The cap and the budgets answer 409 before any instance starts. They are
   kept race-safe by a reservation row (`tenant_admissions`) that is written under the existing cap lock;
5. the change runs the security and security_deep gates. Every file it touches is already under a sensitive path.

Decision (e) is otherwise unchanged: a PERSON still needs the entry's permission in the platform tenant. The system
authority is not a role, holds no permission atom, and cannot be reached from a route that has a user. A source-scan
pin keeps its constructor and its start function inside `Letflow.TenantProvisioner`. The design, with the step table
(failure and repeat per step), the start key and the 202 + poll consumer, is `docs/platform-register-tenant-v2.md`.

## Update 2026-11-25: the system-authority start is built (T-2727, gap G17c)

The five conditions of the amendment above are code now. This is an Update of the amendment, not a new decision.

* **C1 -- one definition.** `Letflow.PlatformProcesses.SystemStart` is a struct with ONE constructor, `for_route/1`, over the
  closed list `[:admin_v1_tenants_create, :signup_provisioning]`. `Letflow.Definitions.StartPermission.check/4` admits it only
  when ALL hold: the definition's name is `platform.register_tenant`; the start prefix is the platform prefix; the derived
  permission atoms are exactly `[:TenantsManage]` and so is the declared one; the definition starts no SUB_PROCESS child; the
  definition declares the v2 variables `requested_tenant_id`, `tenant_type` and `notify_admin`. Anything else, and any value
  that is not a `%SystemStart{}`, answers as an unknown definition and writes nothing.
* **C2 -- audit.** The `instance.create` audit row of a system start carries `actor_id: nil`, `actor_kind: "system"` and
  `started_via` (the route) in `after_state`. The engine start opt is `system_start:`; only the start gate and the audit row read it.
* **C3 -- no trusted value.** The start variables are chosen by `PlatformProcesses.register_tenant_system_variables/1`; no request key
  names an actor, a role or a route. `admin_email` is data (the grant stays pending until the first sign-in).
* **C4 -- limits in front.** The front gate (demo cap, both budgets, the `tenant_admissions` reservation) and the route rewire are the
  consumer half (T-2728, G17d); this change adds the table and the step that reads it, and rewires NO route.
* **C5 -- gates.** Every touched file is under a `[sensitive]` prefix.

This keeps today's behaviour behind the definition: **no new way to create a tenant.** The tenant row is still written in one place,
the body of `tenant.create`, reachable only through the dispatcher for a node of an active `platform.register_tenant` version in
the platform tenant. A source-scan pin (`system_start_callers_test.exs`) keeps `SystemStart` and `start_register_tenant_system/3`
inside the allowed files.

## Residual risks, stated plainly

* A stolen `PLATFORM_ADMIN` session can do everything the platform admin can, now also through a definition. The audit actor and the
  signed activator make it VISIBLE; they do not prevent it.
* A SUB_PROCESS child that calls a platform function is refused outright until the server-side caller is propagated to the child's own
  activation (gap G3/G17). The parent's start already refuses a caller without the entry's permission, so the child is unreachable for
  the wrong caller; what the refusal costs today is that a platform admin cannot use such a child either.
* A `platform_call` step ran nowhere when this record was written. Amendment 2026-11-24 (T-2703, gap G1): the engine now runs it. On
  entering the node the engine arms the `platform_step_dispatches` row inside its own transaction and parks the instance; a worker
  (default off, env `LETFLOW_START_PLATFORM_STEP_RUNNER`) runs the due rows of the platform schema OUTSIDE every transaction under the
  fence of this record, re-checked at every attempt; the outputs are cut to the node's declared writes; a failure after the retries
  puts the instance in ERROR with an EXECUTION_ERROR event and a DLQ entry of type `platform_step`, whose retry resumes it once.
  A result the engine refuses to apply is landed the same way, and the runner recovers outstanding rows of any age; every state and
  event of the dispatch is in the state table of `docs/platform-steps.md`. The decision above is unchanged. The residual risk that
  remains: the tenant-creating routes still call the code directly until gap G17 (T-2704) makes them start the definition.
* The start permission is DERIVED from the definition's catalogue calls. An explicit per-definition `start_permission` (a column) comes
  with the screen that starts the pilot's process (gap G3); until then the derived rule is the floor.
