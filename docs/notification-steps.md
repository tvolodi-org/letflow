# The notification step

A **notification step** is a step of a process definition that sends a registered
template to an address -- or, with the "file" channel, writes it into the
tenant's own file area. It is CONFIGURATION, never a script: the step says
which template, where to and what to put in it -- there is no code in it and
nothing to review but a template key and a set of variable names.

This page says what exists today (2026-11-23) and where each part lives. It is
the sibling of [`platform-steps.md`](platform-steps.md): that page is about the
step that calls Letflow's own code by NAME, this one is about the step that
sends a message.

Authority, rule by rule:

* the per-tenant send cap -- the G2 authority record of the "Register a tenant"
  pilot (option A (c), item 7: a send cap per tenant and CHANNEL, per hour and
  per day). The record lives in the pilot's own repository, next to the pilot
  design;
* the rule that a marked (labelled) variable never leaves the process --
  decision [`0062-restriction-carrying-variables.md`](migration/decisions/0062-restriction-carrying-variables.md)
  R12;
* the per-tenant channel and address allow-list -- decision
  [`0094-platform-call-authority.md`](migration/decisions/0094-platform-call-authority.md)
  (c), which DEFERS it to gap G14. It is NOT built here; see "The residual
  risk" below.

## The four parts

| Part | Module | What it is |
|---|---|---|
| The declaration | `Letflow.Definitions.NotifyCalls` | ONE parse of the step's `notify` attribute: the channel, the template key, the address's variable or the file's name, and the declared values. The activation fence and the dispatcher both read the declaration through it, so a step that passed activation cannot be read differently when it runs. |
| The graph rule | `Letflow.Definitions.Graph` | A SERVICE_TASK that carries a `notify` attribute is a FIFTH route (next to the HTTP endpoint, the catalogue service, the Lua script and the platform call): it needs no `endpoint`, and it may not carry another route beside it. |
| The runner | `Letflow.NotificationSteps.Dispatcher` | Resolves the address and the values from the variables of the running instance and hands the send to the notification module. |
| The send | `Letflow.Notifications` | The Notifier adapter, the tenant's send cap and the `notification_deliveries` log -- and, for the file channel, the tenant's file area. |

## The declaration

```json
"attributes": {
  "notify": {
    "template_key": "tenant_registered",
    "recipient": {"var": "admin_email"},
    "values": {
      "tenant_name": {"var": "tenant_name"},
      "tenant_slug": {"const": "acme"}
    }
  }
}
```

* the template key names a REGISTERED template (`Letflow.NotificationTemplates.Registry`).
  A tenant may override the text of a key in its own locale; it may not invent
  one. The pilot's key is `tenant_registered`;
* the RECIPIENT is a variable, never a constant: a constant address would sit
  in the stored definition of the tenant, and the address of a person is
  personal data the platform does not store (INV-4). The address is read from
  the instance variables when the step runs, and it is written nowhere: not in
  the definition, not in the delivery log;
* every value names a placeholder the template allows. A value the template does
  not know is refused, not silently dropped;
* a value or the recipient may not name a variable that a person may write (the
  T-2430 rule): the person who completes a task in the same graph may not decide
  where the message goes or what it says.

## The two refusals that hold the step in place

**The activation fence.** `Letflow.Definitions.check_notify_calls/2` runs on every
path that switches a version ON (activate, reactivate, version rollback,
promotion apply). A draft that carries an invalid declaration is refused by the
graph rule as well: the node type, the second route beside it, an unknown
template key and a variable a person may write are all refused when the
definition is STORED, not only when it is switched on. The scan that keeps every
definition-write path on the fence is
`test/letflow/definitions/platform_call_write_paths_scan_test.exs`.

**The completion refusal.** The variables the step READS -- the recipient's and
the values' -- are refused in a task completion body, exactly like the write
targets of a module handler (`Letflow.Engine.WriteTargets`). The person who
STARTED the process decides where the message goes; the person who completes a
task in it may not: `POST /tasks/:id/complete` with
`{"admin_email": "attacker@evil.com"}` is refused as a retryable 422
`output_refused` and nothing is merged. The engine half is
`Letflow.Engine.WriteTargets.write_read_keys/1`; the proof is
`test/letflow/engine/notify_write_targets_test.exs`.

## The send and the cap

The runner resolves the address, checks it (`Letflow.Notifications.Address`: a
byte bound first, then the ADAPTER's own allow-list -- one parse, shared with
the consumer, so the gate and the mail adapter can never disagree), refuses a
labelled variable (decision 0062 R12; the labels are REQUIRED, a step that
cannot see them refuses), refuses a missing or malformed trigger reference (the
delivery row carries it, and a step that cannot write its row cannot account
for its send), and hands the send to
`Letflow.Notifications.deliver_to_address/6`.

**The tenant of the row is derived.** The caller passes the `:prefix` the step
runs in; the tenant the delivery row claims to belong to comes from that
schema, never from a field of the caller (decision 0003's addendum, INV-1 (c)).
A prefix that names no tenant is a refusal: nothing is sent and no row is
written.

**The cap is RESERVED before the send.** The tenant's counter row
(`notification_outbound_counters`, one row per tenant, channel and window) is
incremented BEFORE the adapter is called
(`Letflow.Notifications.OutboundCap`): the increment is guarded by the cap
inside the statement itself (`send_count = send_count + 1 WHERE send_count <
cap`), so two sends of the same tenant at the same moment cannot both take the
last slot.

The counter is NOT the delivery log. Counting the log made an unwritable log
row an UNCOUNTED send: the mail had already left the platform, the log row
could not be written, and the tenant's ceiling never tripped -- the flooding
the cap exists to stop. The reservation is taken first, so a send is counted
whether or not the outcome row can be written afterwards.

The counter holds no address, so the cap is counted per tenant and per CHANNEL,
never per address and never per template key: a definition that rotates
template keys must not reach eight times the ceiling. A send the cap refused
costs nothing and must not keep the tenant blocked (the slot is taken only
after the address has been accepted). The caps are SETTINGS, not rules:
`notifications.outbound_cap_per_hour` (platform ceiling 60) and
`notifications.outbound_cap_per_day` (platform ceiling 500). A tenant may lower
its own cap (`PATCH /api/v1/tenant/settings`); it may not raise it above the
platform ceiling, and the write is refused if it tries.

Over the cap the delivery row records `skipped` / `rate_limited` and NOTHING is
sent. A cap that cannot be reserved at all (the database is unreachable) is
treated as a cap that is over: nothing is sent. The row holds no address, no
subject and no body (INV-4).

**The transaction boundary.** The reservation opens no transaction and never
rolls one back: an over-cap refusal is a typed result (the guarded `UPDATE`
matched no row), so a caller's transaction stays usable and the `rate_limited`
row is written. A reservation made inside a caller's transaction is part of it
and is lost if it rolls back, so the caller must call the runner OUTSIDE the
engine's own transaction -- exactly as the sibling platform-step dispatcher is
called from its poller. A cap that cannot be read is a `failed` row, not a
`rate_limited` one; a delivery row that cannot be written does not change what
the caller is told about the send.

## The file channel (T-2596, pilot gap G12)

The `notify` attribute carries a `channel`: `"email"` (the default, the address
of the recipient variable) or `"file"` (the tenant's own file area). The
channels are EXCLUSIVE -- the mail channel carries a recipient and no file
name, the file channel carries a file name and no recipient, because there is
no address a file is sent to.

```json
"attributes": {
  "notify": {
    "channel": "file",
    "template_key": "tenant_registered",
    "file_name": "registration-notice",
    "values": {"tenant_name": {"var": "tenant_name"}}
  }
}
```

**The file name is a plain name, never a variable and never a path.** A name
that carries a separator, a `..`, a drive letter, a home directory or a control
character is refused at ACTIVATION with the fixed code
`notify_file_name_invalid`, so a definition that names a path never reaches the
version that is switched on. The name is a constant, so it cannot be a variable
a person writes (the T-2430 rule).

**The file area is a table in the tenant's own schema**
(`notification_files`, `Letflow.Notifications.Files`). The BYTES live there, so
"the file channel never writes to an arbitrary server path" holds BY
CONSTRUCTION: there is no file-system path at all. The name the row is stored
under is generated by the SERVER -- a sanitised stem of the declared name plus a
fresh uuid -- so even a name that slipped past the fence cannot become a path.
The tenant of the row is derived from the schema the row is written into, never
from the caller (INV-1 (c)).

**The area enforces its own caps, on its own side of the fence.** The fence
refuses a path-like name at activation, and the AREA refuses it too: the
declared name is bounded (`Files.max_declared_name_bytes/0`, 255 bytes) and
checked for valid UTF-8 BEFORE the sanitiser walks its characters (SF-01: the
byte bound comes first); a name over the cap is refused with
`{:error, :file_name_invalid}` and nothing is written. The area is also the
place where a prefix is checked: every entry point (`write/2`, `list/1`,
`fetch/2`, `delete_expired/1`) resolves the tenant BEFORE it touches the
database, so a prefix that names no tenant is an error tuple
(`{:error, :invalid_schema_name}`, or `:error` for `fetch/2`) and never a
database error (INV-8).

**A refused step answers a typed 422 at the request surface.** The fence's
refusal reaches the caller as `422 notify_calls_invalid` with the fixed code of
the violation (`notify_file_name_invalid`) on every path that switches a version
on -- the activation, the reactivation, the version rollback, the promotion
apply and the review-free promotion -- and never as a 500. The write path
answers the same code through the graph rule's own violation
(`422 definition graph failed validation`), and it stores nothing. The proof is
`test/letflow/definitions/notify_calls_refused_activation_test.exs`.

**The cap holds the file channel too.** The send cap is counted per tenant and
per CHANNEL (the G2 record, option A (c) item 7), and the file channel has its
own counter rows: a tenant that sends a lot of mail may still write its files,
and a definition that writes files in a loop cannot fill the tenant's disk.
Over the cap the step answers `skipped` / `rate_limited` and NOTHING is
written.

**The retention.** Every file carries an `expires_at`
(`Letflow.Notifications.Files.retain_days/0` days after it was written), and
`Files.delete_expired/1` removes the files whose moment has passed. The sweep
that CALLS it is not part of this change.

**What is NOT built here:** the HTTP route that lists and downloads the files.
The area's context API is (`Files.list/1`, `Files.fetch/2`); the route is the
next slice.

## The typed mapping of the step (T-2594's rule)

The notification step declares no map of its own: its `notify` attribute says
which template to send, where to send it and what to put in it, so the typed
mapping is DERIVED from that declaration (the way
`Letflow.Definitions.PlatformCalls.mappings/1` derives the platform call's).
The reads are the recipient's variable and the variables of the values; the step
writes nothing. The type of a read is the type the DEFINITION declares for that
variable, so the G13 rule "a step may not touch a variable the definition does
not declare" binds the notification step too
(`Letflow.Definitions.NotifyCalls.mappings/2`).

## What is not built yet

* the ENGINE wiring: a SERVICE_TASK that carries a `notify` attribute is a valid
  node of a definition, but the node dispatch that RUNS it is not part of this
  change -- exactly as the platform-call step's engine wiring is not part of
  gap G1a. The runner is the piece a later step calls. That later step must
  pass the instance's variable labels, the instance's `:prefix` and the
  instance's `:trigger_ref`, or the step refuses itself, and it must call the
  runner OUTSIDE the engine's transaction (the reservation of the cap is
  committed on its own only when the caller holds no transaction);
* the per-tenant channel and address allow-list (gap G14, the `OutboundDestinationsManage`
  atom);
* the HTTP route that lists and downloads the files of the file channel (the
  area and its context API are built by gap G12, the route is the next slice);
* the designer fields (gap G5).

## The residual risk

The step may currently aim the platform's mail identity at ANY third-party
address that is a well-formed address: the gate is a shape check, and there is
no per-tenant destination allow-list yet. Gap G14 builds that list (with the
`OutboundDestinationsManage` atom, for TENANT_ADMIN and PLATFORM_ADMIN only),
and the decided rule says it is checked at ACTIVATION **and at DISPATCH** -- so
G14 must add the check inside the runner, not only inside the activation
fence. Until then, a definition of ANY tenant (the notify fence has no tenant condition) can send a message to
any address a tenant's instance variables hold.

## Extension point (owner decision D-180, not built here)

A tenant may later FORK a standard definition into its own copy (`custom`, `based_on`, and a
per-tenant binding of which definition runs). The notification step needs NO column and NO map
for that: the `notify` attribute travels with the definition document, so a forked copy carries
the same declaration in its own copy, and the delivery row references neither the definition nor
the address. Nothing in this change assumes that a definition is editable by whoever sees it, or
that a tenant has exactly one definition per key.

## The designer (T-2600, pilot gap G5b)

The step is edited in the process designer, without code: the step panel of the definition editor
(`web/src/components/diagram/NodeEditPanel.tsx`) offers the form
(`web/src/components/diagram/NotifyStepEditor.tsx`) for a SERVICE step that carries a `notify`
attribute.

* The **template picker** is fed by the COMPILED catalogue of registered keys:
  `GET /api/v1/notification-templates/catalogue` publishes the keys and the placeholder allow-list
  of each (`Letflow.NotificationTemplates.Registry`). The read is platform data -- a key and the
  NAMES of the placeholders -- and no tenant text: the tenant's own override of a key stays behind
  `GET /api/v1/notification-templates` (`:NotificationTemplatesManage`). The catalogue's permission
  is `:DefinitionsRead`: the reader of a definition is the person who may name a template in one.
* The **channel** is the server's closed set (`email`, `file`). The form is exclusive the way the
  server is: the mail channel asks for the recipient, the file channel for the file name, and
  switching drops what the other one carried.
* The **recipient is a VARIABLE of the process**, never a fixed address: a constant address would
  sit in the stored definition of the tenant, and the address of a person is personal data the
  platform does not store (INV-4). The server refuses a constant recipient with
  `notify_recipient_invalid`, so the form does not offer one. (The per-tenant allow-list of
  recipient domains of the guardrail G14 is not built; when it is, the form checks it.)
* Every **value** names a placeholder of the template's allow-list and is filled with a variable of
  the process or with a fixed value.
* The form applies the server's own rules before the graph is written: a variable name that is empty,
  dotted or in the reserved namespace, and a file name that carries a separator, a `..`, a drive
  letter or a home directory, are refused in the field and never reach the graph.

The rules the form enforces live in one pure module (`web/src/utils/canvas/notifyStep.ts`), the
graph edits in `web/src/utils/canvas/graphEdit.ts` (`setNotifyStep/2`, `removeNotifyStep/2`), and
the route kinds of a step stay exclusive: a node carries a notification OR a script OR a platform
call, never two (the server refuses a node that carries two).

The tests: `web/src/utils/canvas/__tests__/notifyStep.test.ts` (the pure rules),
`web/src/components/diagram/__tests__/NotifyStepEditor.test.tsx` (the form),
`web/src/components/diagram/__tests__/NodeEditPanel.notify.test.tsx` (the panel), and
`test/letflow/routers/notification_templates_catalogue_test.exs` (the catalogue route).

## The tests

* `test/letflow/notification_steps/dispatcher_test.exs` -- the send, the cap
  (`outbound_rate_cap_test`: the send over the cap is a `rate_limited` row and
  nothing is sent), the reservation taken before the send (N2d), the cap that
  holds when the delivery row cannot be written (N16), what the log does NOT
  hold, and the refusals (a missing or malformed trigger reference, a number
  too large to convert);
* `test/letflow/engine/notify_write_targets_test.exs` -- the completion refusal
  of the step's read keys;
* `test/letflow/engine/write_targets_test.exs` -- the refusal set (WTU-5);
* `test/letflow/definitions/notify_calls_test.exs` -- the one parse, the node
  rules, the graph validation and the derived typed mapping (D15..D22);
* `test/letflow/notifications/address_test.exs` -- the byte bound and the one
  parse the gate shares with the adapter (A9);
* `test/letflow/definitions/platform_call_write_paths_scan_test.exs` -- the
  scan that keeps every definition-write path on the notify fence;
* `test/letflow/notifications/delivery_test.exs` -- the closed reason set, now
  with `rate_limited` in it;
* `test/letflow/notification_steps/file_channel_test.exs` -- the FILE channel:
  the rendered file in the tenant's area, the server's name, the cap that holds
  the channel, the refusals (a labelled variable, a missing trigger reference,
  a prefix that names no tenant), no mail sent, and the cross-tenant negative
  (FC1..FC6);
* `test/letflow/notifications/files_test.exs` -- the AREA: the generated name
  holds no path whatever the declared name was, the row lives in the tenant's
  own schema, the byte cap, the list that never carries the bytes, the
  retention (FA1..FA5).
