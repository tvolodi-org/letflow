# Platform steps: the catalogue, the registry and the dispatcher

A **platform step** is a step of a process definition that calls Letflow's own code by NAME
instead of an HTTP endpoint or a Lua script. This page says what exists today (2026-11-22) and
where each part lives.

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

## The one registered function

`platform.validate_registration` (family `:platform`, permission `:TenantsManage`, platform tenant
only): it checks the slug, the display name and the e-mail of a registration and returns
`normalized_slug` and `email_domain`. It has NO side effect -- it reads nothing, writes nothing
and sends nothing out. It exists to prove the whole path of a platform step (catalogue entry,
closed registry, durable dispatcher, authority fence, per-step result row) before a function
with real side effects is registered.

The tenant family of the pilot (`tenant.validate`, `tenant.create`, `tenant.provision`,
`tenant.bind_realm`, `tenant.grant_first_admins`, `tenant.install_default_modules`) is DECLARED
in the catalogue -- the authority rule of gap G2 needs the names -- but has no body yet, so the
dispatcher refuses it with `:platform_function_not_implemented` instead of pretending it ran.

## The authority fence

Every dispatch calls `Letflow.PlatformFunctions.Guard.authorize_dispatch/1` BEFORE the body runs:
the call must be in the platform tenant (INV-10), the function must be in the compiled catalogue,
the stored graph must carry no foreign source beside the call, the `activated_by` document must
still verify against the tenant's signing key, and the activator must still hold the entry's
permission (a permission lost since the activation marks the definition `needs_reactivation`, so
the existing reactivation path heals it). A refused call never reaches the body.

## The durable row

`platform_step_dispatches` (one row per platform step, in the tenant's own schema):

* `call_key` -- the IDEMPOTENCY KEY of the call, composed by the dispatcher from the catalogue
  entry's declared key inputs (the slug for a registration). It is unique per tenant schema.
* `input_fingerprint` -- the fingerprint of the whole argument set.
* `status` -- `pending` (armed), `running` (claimed; the lease is `next_attempt_at`),
  `advanced` (the body returned its outputs), `given_up` (the call failed).
* `outputs`, `attempt_index`, `last_failure_kind`, `dispatched_at` -- the per-step RESULT.

So: the same key with the SAME arguments is the SAME call (the first result is returned, the body
does not run again), and the same key with DIFFERENT arguments is refused with
`idempotency_key_reuse`. A crash between the claim and the result loses nothing: the row stays
`running` and its lease expires, so the next claim takes it over.

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

## The tests

* `test/letflow/platform_functions/dispatcher_test.exs` -- the dispatcher, the authority fence,
  the refusals, and the structural proof that the body runs outside every transaction the
  dispatcher owns.
* `test/letflow/platform_functions/platform_call_idempotent_replay_test.exs` -- S8: the replay of a
  call (one call, one result, one row) and the key reuse.
* `test/letflow/definitions/platform_call_activator_signature_test.exs` -- S9: the signature and
  the revoked activator, through the guard and through the dispatcher.
* `test/letflow/platform_functions/registry_test.exs` and
  `test/letflow/platform_functions/impl/validate_registration_test.exs` -- the closed registry and
  the harmless body.
