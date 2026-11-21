# 0094: the authority rule for platform steps (T-2588, pilot gap G2)

Status: accepted. Implements the G2 gap of the "Register a tenant" pilot (the spike of 2026-11-21, decision record
`docs/decision-record-g2-authority-rule.md` of the team repository, PM ruling D-179 of 2026-11-21: option A of all five
decisions). The step library that RUNS a platform call (gap G1) is a later change; this record settles who may switch one on,
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
variables or earlier platform-step outputs, never a human task's completer.

*Option B (rejected).* A new atom per definition class (`PlatformDefinitionsWrite`) needed to EDIT any definition in the platform
tenant that contains a platform step. It blocks drawing and testing a draft and still needs the activation check.

**(c) The per-tenant channel and address allow-list.** Settled in a later change (the pilot's guardrail gap G14, with the new
`OutboundDestinationsManage` atom). Nothing of it is in this record, and nothing of it is in this change.

**(d) The audit actor.** The lifecycle audit row carries the caller: the HTTP paths pass the caller's user id into the lifecycle
functions, and a caller that is not a person (module code, a seed task) writes no actor. The reason REQ-195 gave for the `actor_id:
nil` disposition (its AC11 forbade touching the definitions router) has lapsed; the router now supplies the actor, and the disposition
survives for the non-HTTP callers only.

**(e) How a definition that calls a platform function is started.** The START PERMISSION of a definition is the catalogue permission of
the entries its steps call, and the ONE start function (`Letflow.Engine.create/2`) checks it: the start variables of such a definition
are trusted inputs, so the start needs the same authority the activation does. A caller without it, and every caller outside the
platform tenant, gets the answer for an UNKNOWN definition (INV-5) and starts nothing.

## Choice and reasons

Option A everywhere. The compiled catalogue keeps the "who may add a function" question inside code review; the signed activator
replaces the owner stamp without opening a hole, because the signature is verified at every call and a permission lost since the
activation flags the row `needs_reactivation` (REQ-515's existing path).

## What the code does

| Where | What |
|---|---|
| `lib/letflow/platform_functions/catalog.ex` | the compiled catalogue: `list/1` (only the entries the caller's tenant may use), `fetch/1`, `permission_atoms/0`, `entry_map/1`. A duplicate or malformed entry is a COMPILE error |
| `lib/letflow/platform_functions/entry.ex` | the entry shape: typed inputs with a source class, typed outputs, the permission, the side effects, the idempotency key, the platform-tenant flag |
| `lib/letflow/platform_functions/tenant_family.ex` | the platform family's declarations: `tenant.validate`, `tenant.create`, `tenant.provision`, `tenant.bind_realm`, `tenant.grant_first_admins`, `tenant.install_default_modules` |
| `lib/letflow/platform_functions/guard.ex` | the RUN-TIME fence: the tenant (INV-10), the catalogue entry, the signature, and the activator's CURRENT permission (a loss flags the row `needs_reactivation`) |
| `lib/letflow/definitions/platform_calls.ex` | the ACTIVATION fence: the platform tenant, the entry, the activator's permission, the argument shape, the input source classes |
| `lib/letflow/definitions/start_permission.ex` | the START permission of a definition, derived from its entries |
| `lib/letflow/routers/platform_functions.ex` | the read route `GET /api/v1/platform-functions` (`:TenantsManage`); the only route the catalogue has |
| `lib/letflow/engine/write_targets.ex` | the read keys of a catalogue call join the write-target keys: a completion body may not carry them (the T-2430 rule, extended) |

The `platform_call` step is a SERVICE_TASK attribute, the fourth route of that node kind next to the HTTP endpoint, the catalogue
service and the Lua script: `attributes["platform_call"] :: %{"function" => name, "args" => %{arg => %{"var" => v} | %{"const" => j}}}`.

## The one code a company tenant ever sees

A company tenant may not carry a `platform_call` step at all. Every path that touches such a definition -- the write path of a draft
(and therefore the import), the designer's validate route, the activation, the promotion -- answers `:platform_call_not_allowed`, the
same answer whether the function exists or not. A stranger may not learn which platform functions exist (INV-5).

## Tests

| # | Abuse case | Test |
|---|---|---|
| S1 | a `PROCESS_DESIGNER` of the platform tenant activates a version with a platform call | `test/letflow/definitions/platform_call_activation_authority_test.exs`: refused; `PLATFORM_ADMIN` activates; the rollback path runs the same check |
| S2 | a human task writes the key the platform call reads | `test/letflow/engine/platform_call_completer_refused_test.exs` (the completion is refused with the 422 `output_refused`) and `test/letflow/modules/write_target_sources_scan_test.exs` (the scan covers `platform_call`) |
| S3 | a company tenant carries a platform call | `test/letflow/definitions/platform_call_company_tenant_refused_test.exs` (validate, import, activation, promotion) and `test/letflow/engine/platform_dispatch_tenant_guard_test.exs` (a forged dispatch row in a company schema) |
| S4/S5 | a company user, or a platform user without the permission, starts the definition | `test/letflow/engine/platform_call_start_permission_test.exs`: the answer for an unknown definition |
| S9 | the `activated_by` document is edited, or the activator lost the permission | `test/letflow/definitions/platform_call_activator_signature_test.exs`: the tampered MAC is refused; a revoked role refuses the call and flags the row `needs_reactivation` |
| S13 | run-time catalogue tampering | `test/letflow/api/platform_catalogue_has_no_write_route_test.exs`: the route inventory holds one GET under the catalogue's mount and no write method |

## Residual risks, stated plainly

* A stolen `PLATFORM_ADMIN` session can do everything the platform admin can, now also through a definition. The audit actor and the
  signed activator make it VISIBLE; they do not prevent it.
* The `actor_kind` column of the audit table ("nobody" against "the system") is not part of this change: the table is tenant-scoped
  and immutable, and adding a column to it is a separate migration. Until then a `nil` actor means "no human caller".
* A `platform_call` step runs nowhere yet: the step library (gap G1) owns the dispatcher. A definition that carries one starts, and its
  instance stops at that step with the ordinary "no route" failure -- no platform code is reached.
* The start permission is DERIVED from the definition's catalogue calls. An explicit per-definition `start_permission` (a column) comes
  with the screen that starts the pilot's process (gap G3); until then the derived rule is the floor.
