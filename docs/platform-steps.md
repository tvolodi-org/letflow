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
