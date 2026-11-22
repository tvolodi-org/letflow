# The notification step

A **notification step** is a step of a process definition that sends a registered
template to an address. It is CONFIGURATION, never a script: the step says
which template, where to and what to put in it -- there is no code in it and
nothing to review but a template key and a set of variable names.

This page says what exists today (2026-11-23) and where each part lives. It is
the sibling of [`platform-steps.md`](platform-steps.md): that page is about the
step that calls Letflow's own code by NAME, this one is about the step that
sends a message.

Authority: the "Register a tenant" pilot (gap G4, T-2592) and the decision
record `docs/migration/decisions/0094-platform-call-authority.md` (decision (c):
the per-tenant send cap, and the rule that a marked variable never leaves the
process).

## The four parts

| Part | Module | What it is |
|---|---|---|
| The declaration | `Letflow.Definitions.NotifyCalls` | ONE parse of the step's `notify` attribute: the template key, the address's variable and the declared values. The activation fence and the dispatcher both read the declaration through it, so a step that passed activation cannot be read differently when it runs. |
| The graph rule | `Letflow.Definitions.Graph` | A SERVICE_TASK that carries a `notify` attribute is a FIFTH route (next to the HTTP endpoint, the catalogue service, the Lua script and the platform call): it needs no `endpoint`, and it may not carry another route beside it. |
| The runner | `Letflow.NotificationSteps.Dispatcher` | Resolves the address and the values from the variables of the running instance and hands the send to the notification module. |
| The send | `Letflow.Notifications` | The Notifier adapter, the tenant's send cap and the `notification_deliveries` log. |

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

## The send and the cap

The runner resolves the address, checks it (`Letflow.Notifications.Address`: a
byte bound first, then the shape of `local@domain`), and hands the send to
`Letflow.Notifications.deliver_to_address/7`.

**The cap.** The tenant's own delivery log is the counter -- the log holds no
address, so the cap is counted per tenant and per template key, never per
address. Only the attempts that reached the adapter count (`sent` and
`failed`): a send the cap refused costs nothing and must not keep the tenant
blocked. The caps are SETTINGS, not rules:
`notifications.outbound_cap_per_hour` (platform ceiling 60) and
`notifications.outbound_cap_per_day` (platform ceiling 500). A tenant may lower
its own cap; it may not raise it above the platform ceiling.

Over the cap the delivery row records `skipped` / `rate_limited` and NOTHING is
sent. The row holds no address, no subject and no body (INV-4).

## What is not built yet

* the ENGINE wiring: a SERVICE_TASK that carries a `notify` attribute is a valid
  node of a definition, but the node dispatch that RUNS it is not part of this
  change -- exactly as the platform-call step's engine wiring is not part of
  gap G1a. The runner is the piece a later step calls;
* the per-tenant channel and address allow-list (gap G14, the `OutboundDestinationsManage`
  atom) and the file channel (gap G12);
* the designer fields (gap G5).

## The tests

* `test/letflow/notification_steps/dispatcher_test.exs` -- the send, the cap
  (`outbound_rate_cap_test`: the send over the cap is a `rate_limited` row and
  nothing is sent), what the log does NOT hold, and the refusals;
* `test/letflow/definitions/notify_calls_test.exs` -- the one parse, the node
  rules and the graph validation;
* `test/letflow/notifications/delivery_test.exs` -- the closed reason set, now
  with `rate_limited` in it.
