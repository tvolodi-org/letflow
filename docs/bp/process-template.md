# How to turn a business function into a real process

The template of the "Register a tenant" pilot (decisions D-175/D-176; the worked example is the definition
`platform.register_tenant`). A "real process" is an ordinary, versioned definition that the BPM engine runs, that
a business user can edit in the designer, and that is the ONLY way to do the business function. Do the steps in
this order; each names what the pilot built. Where a part of the pilot is still being built, the step says so:
the page states what is on main, not what is planned.

Decision records this page rests on: `docs/migration/decisions/0094-platform-call-authority.md` (who may call
what from a definition), and the pilot design `docs/platform-register-tenant-v2.md`.

## The steps

1. **Name the business function and find every path that does it today.** Grep the row writers and list every
   route, job and task that calls them, with `file:line`. Decide for each path: it becomes a process start, it
   is removed, or it is kept with a stated reason. Pilot: five tenant-creating paths, listed in the
   `tenant_creating_paths` of `docs/bp/platform.json`; the seed task stays direct because it runs before any
   definition exists.
2. **Write the catalogue entries.** One entry per business-visible step: name, typed inputs and outputs, the
   permission atom that may run it, its side effects, its idempotency key and its fixed failure codes. The
   catalogue is COMPILED (`Letflow.PlatformFunctions.Catalog`, entries in
   `lib/letflow/platform_functions/*_family.ex`): there is no write route, adding an entry is a reviewed code
   change. Internal helpers stay out. An entry never raises (INV-8) and a second run with the same key changes
   nothing. Pilot: `tenant.validate`, `tenant.create`, `tenant.provision`, `tenant.bind_realm`,
   `tenant.grant_first_admins`, `platform.validate_registration`.
3. **Define the typed context.** The definition's variable schemas list every variable; each step reads and
   writes declared names only. A write-like step takes its arguments from the start form or from earlier
   function steps (`source_class` `:start` or `:step`), never from a variable a later human task's completer can
   set (SF-03). Pilot: `lib/letflow/platform_processes/definition.ex`.
4. **Draw the process from the step kinds.** Platform-call step (a catalogue function), human task,
   notification step (channel, recipient, template: configuration, not a script), Lua script step only for
   custom logic, timer, gateway, sub-process. Ship it as an ordinary editable definition in the tenant that owns
   it (pilot: the platform tenant), seeded as v1 and never overwriting a newer version
   (`lib/letflow/platform_processes/seed.ex`; boot seed and the QA deploy smoke check). Platform steps exist
   ONLY in the platform tenant; a company-tenant definition cannot carry one.
5. **Bind the start.** Every path from step 1 that stays calls the one start function
   (`Letflow.PlatformProcesses.start_register_tenant/2`), which starts the active version, checks the
   definition's start permission once and answers with the instance id. Add a callers test that limits the
   catalogue functions to the step dispatcher: a new direct caller fails CI (the no-bypass rule).
6. **Make it editable in the designer.** The function picker, argument mapping rows and notification fields are
   fed by the catalogue, so a new entry appears without screen code. Activation refuses an unknown
   function (`platform_call_function_unknown`) and the dispatch guard refuses it again at run time; the designer's
   validate refuses a bad typed mapping (a declared type that disagrees with the catalogue entry's contract, or a
   write the entry does not produce) and a platform step in a company tenant, but it does not refuse an unknown
   function. The outbound allow-list is deny by default (atom
   `OutboundDestinationsManage`, TENANT_ADMIN and PLATFORM_ADMIN only) and is checked in two places that see
   different things: at activation, a literal HTTP host and the channel of a notification step (the designer's
   validate does not run it); at dispatch, the recipient domain of a notification step, because the recipient
   comes from an instance variable and is known only then.
7. **Log every step.** The step log shows who, when, result, duration and attempts. A failed step lands in the
   dead-letter queue and can be retried. No secret appears in any event, DLQ row or answer (INV-4).
8. **Write the runner process file.** Readable JSON in `test/uat/processes/` (pilot:
   `BP-PLATFORM-01-register-tenant.json`), with actors for the process owner and for a refused user. Cover:
   start to end; edit through the designer API (add a notification step), start again and see the effect; roll
   back in one step; the refusals (uniform 404/403, cross-tenant); a forced failure and its retry. Run it twice
   in a row on one build with the residue check until both runs pass with no open high or medium finding.
   Throwaway tenants use the `uat-tmp-` prefix only.
9. **Add one Playwright test** of the designer edit for this process (pilot:
   `web/tests/e2e/pilot-register-tenant-page.e2e.spec.ts`). It must sit in a spec the CI e2e job lists.
10. **Update the map.** The process's row in `docs/bp/*.json` changes from "route code" (`executed_by: direct`)
    to `definition:<key>` once the engine runs it and the routes only start it, and links this page. Do not flip
    it earlier: the map says what is true today.

## Guardrails every converted process keeps

| Rule | Where |
|---|---|
| Authority comes from the step kind's own permission atom and a signed activator, not from the author's role | decision 0094 (b) |
| Per-definition start permission, checked by the one start function; everyone else gets the INV-5 answer (not found) | decision 0094 (e) |
| Actor on every lifecycle audit row; system callers are recorded with `actor_kind` system | decision 0094 (d) |
| An automatic test run before activation, and a rollback to the previous version in one step | pilot G16 |
| Send caps on notification steps | pilot G4/G14 |

## Residual risk (state it on the area page of every converted process)

A stolen PLATFORM_ADMIN session can do everything the administrator can, and now also through a definition. This
is visible through the audit (actor on every lifecycle row, the step log) but it is not prevented. The template
does not remove that risk; it makes it visible.

## Checklist for a reviewer

- Every path of step 1 is a start, removed, or listed with a reason.
- The catalogue entry has a permission, typed inputs, an idempotency key and a failure code per refusal.
- A test finds an `INSTANCE_STARTED` for each new result of the business function.
- The runner file passes twice in a row with the residue check.
- The `docs/bp` row says what is true on main, with the proof column naming a test or a runner step.
