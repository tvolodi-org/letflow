# SERVICE_TASK entity writes: a refusal lands the instance in ERROR

GH #2587 / REQ-499 PR C2 (decision `docs/migration/decisions/0054-process-step-writes-entity.md`;
design `lib/letflow/design/gh2587-req499-pr-c-service-task-writes.md` D-C.8, D-C.9, OQ-C3).

Audience: whoever supports a tenant whose process definition declares `entity_writes` on a
SERVICE_TASK node, and whoever reads the DLQ.

## Status

LIVE since PR C1 (GH #2587). The definition activation fence
(`Letflow.Definitions.check_entity_writes/3`) now accepts `entity_writes` on a SERVICE_TASK node on
all three activation paths (activate, version rollback, promotion apply), for both the HTTP route
and the script-bound route (`script_key`). The same activation codes as for a HUMAN_TASK node
apply, reported at the SERVICE node's id and the declared line index (a 422 `entity_writes_invalid`
body). A node type other than HUMAN_TASK and SERVICE_TASK still gets
`entity_writes_node_type_not_supported`. Since GH #2590 / REQ-501 PR R5 a SERVICE_TASK node (both
routes) may also declare `module_writes` (module write handler calls) on the same terms as a
HUMAN_TASK node; see "Module write handlers on a SERVICE_TASK node" below. The activating principal must hold `EntitiesRecordsWrite`; its
authority is recorded in `process_definitions.activated_by` and is what authorises the write at
run time (the platform actor is only the event actor).

Until C1 only a definition row that carried the attribute from BEFORE PR B1 (when it was silently
inert) could reach this behaviour; the C2 merge gate counted those rows and the result was zero.

## What is new

A SERVICE_TASK completion is not a request. There is no client to answer, no pending task that can
stay pending, and the external call (HTTP request or script run) has ALREADY happened and is never
repeated (at-most-once). So when the node's declared entity writes cannot be applied together with
the service result, the platform does not stall and does not retry the call. It:

1. rolls back everything the apply would have written (no record, no entity event, no
   `SERVICE_TASK_COMPLETED` / `SCRIPT_TASK_COMPLETED`, no `_sys` value, no projection change);
2. in a SECOND, later transaction puts the instance in **ERROR** and writes one DLQ entry and one
   `EXECUTION_ERROR` event, and (best effort) one tenant audit entry `entity_write.refused`.

This is NEW product behaviour: before PR C a service-task entity write did not exist, and a failure
of the apply left the instance ACTIVE with a lost token (ISS-0928 only made that loud).

## What an operator sees

| Where | Value |
|---|---|
| Instance status | `ERROR` |
| DLQ entry `reason` | `service task entity write refused: <code>` (HTTP route) or `script service task failed: the run was rejected` (script route) |
| DLQ entry `error_detail` (HTTP route) | exactly `{"line_index": <declared index>, "code": "<public code>", "dispatch_id": "<id>"}`; never a field name, field value, entity type or record id |
| DLQ entry `error_detail` (script route) | the script incident shape with `detail` = `entity_write_refused` or `entity_write_contention` |
| `EXECUTION_ERROR` event `variables` | the variables BEFORE the apply; the service response or script output is not stored anywhere |
| Dispatch row | HTTP: stays `advanced`; script: `failed`, `outcome` `script_rejected` |
| Tenant audit | `entity_write.refused` with the closed `detail` atom (for example `field_restricted`, `not_append_only`, `scoped`, `value_too_large`, `line_malformed`, and for a handler line the details of `docs/runbooks/module-write-handlers-manifest-hash.md`); no value. It is written in a THIRD, best-effort transaction AFTER the landing commits: if that write fails the incident (instance ERROR, DLQ entry, `EXECUTION_ERROR` event) still exists, only the audit entry is missing, and a warning is logged |

Public codes: `write_not_permitted`, `validation_failed`, `entity_append_only`,
`entity_type_inactive`, `entity_write_contention`, `entity_write_failed`,
`entity_write_needs_reactivation`.

## Contention is retried by the engine, bounded

Lock waits, statement timeouts, deadlocks, a lost connection and the 10 s guard are re-applied by
the engine itself (3 attempts, 100 ms and 300 ms apart, inside a 20 s budget; the script route
uses `min(20 s, lease remaining - 2 s)` and starts an attempt only with at least 15 s left). The
external call is never repeated. After the last attempt the instance lands in ERROR with public
code `entity_write_contention`.

Since GH #2648 this also covers an HTTP service apply that has NO entity-write lines but completes a sub-process child: its cascade takes the parent's locks, a deadlock or lock timeout is re-applied the same bounded way, and after the last attempt the instance lands in ERROR with `entity_write_contention` (before, such an apply silently stalled ACTIVE). An UNPLANNED script apply is not re-applied: a deadlock there lands the row `failed` (`script_rejected`/`apply_failed`).

## Lease margin (script route)

The script route starts an entity-write attempt only while at least 15 s of the budget `min(20 s, lease remaining - 2 s)` is left. With the default lease (`lease_margin_ms` 23 s, the script itself bounded by 5 s) that is always true. If `lease_margin_ms` is lowered so that roughly 17 s or less of the lease remains when the result is applied (the run time and any wait for a script slot count against it), EVERY script service task that declares `entity_writes` goes straight to the landing: the row is `failed` with `outcome_detail` `entity_write_contention` (the audit detail is `deadline`) and no record is written. Keep `lease_margin_ms` above roughly 8 s plus the longest script run plus 17 s, i.e. at or above the 23 s default.

The budget is also spent before the apply lands: the plan phase and `prepare/2` of the first attempt (up to about 8 s in the worst case) count against it, which is why a run that used most of its lease reports `entity_write_contention` rather than a refusal.

## Recovery

The result of the service call is not stored, so there is no automatic re-apply:

- `entity_write_needs_reactivation`: the definition's recorded activator is gone, deactivated or
  no longer holds `EntitiesRecordsWrite`. Cancel the instance and re-activate the definition with
  a current principal (rollback or promotion paths record a fresh activator).
- `validation_failed` / `write_not_permitted` / `entity_append_only` / `entity_type_inactive`: fix
  the entity type or the definition (a data-dependent refusal means the response did not provide a
  field the type requires), cancel the instance and start a new one. The external effect of the
  already-made call is NOT compensated by the platform.
- `entity_write_contention`: transient; cancel and restart after the contention clears.
- `entity_write_failed`: an internal fault; the engine log carries the failing step atom and the
  dispatch id only.

## Known residual

If the process crashes between the rollback and the commit of the ERROR landing (or the landing
itself exhausts its contention budget), the HTTP dispatch row stays `advanced` and the instance
`ACTIVE` with a lost token: the pre-existing silent-stall class of ISS-0928. The dispatcher logs
and writes a `service_task.advance_failed` audit entry. Closing it needs the stuck-`advanced`
sweeper listed as deferred in the design (section 16). The script route has no such window: its
lease sweep turns an expired `running` row into a `timeout` incident.

## Module write handlers on a SERVICE_TASK node (GH #2590 / REQ-501 PR R5)

A stamped definition (created by a module install, decision 0054 D6) may declare `module_writes`
on a SERVICE_TASK node, HTTP route or script-bound. The handler calls run in the SAME apply
transaction as the declared `entity_writes` (declarative lines first, then the handler calls in
declared order), with the platform actor as event actor and the recorded activator as the
field-restriction subject (`source.activator_id`). A script output is never a command: the module,
handler and arguments are fixed by the stamped definition; a script or an HTTP response can only
supply the value of a declared `var` argument, and the handler validates it.

What is NEW for an operator: every refusal that a completing human would have seen as a 403/422 is
here an instance in **ERROR** with one DLQ entry (the table above), with the DECLARED `line_index`
of the handler call (declarative lines come first) and the public code `write_not_permitted` (or
`validation_failed`, `entity_write_failed`, `entity_write_contention`). The closed detail atom
is in the `entity_write.refused` audit entry only: `stamp_missing`, `stamp_mismatch`,
`module_not_installed`, `handler_unknown`, `hash_mismatch` (before or inside the transaction),
`body_changed`, `arg_unknown`, `arg_missing`, `event_schema_outdated`, `handler_not_permitted`,
`handler_invalid_arguments`, `handler` (a handler fault), `field_restricted`,
`target_not_managed_by_module`, `value_too_large`.

Consequences to plan for:

* A deploy that changes a handler-bearing module's manifest surface (the strict manifest-hash pilot
  limit of `docs/runbooks/module-write-handlers-manifest-hash.md`) leaves HUMAN tasks pending. On
  a SERVICE node the external call has already happened, so each in-flight service completion lands
  in ERROR (`write_not_permitted`, detail `hash_mismatch`) instead of waiting. Coordinate such a
  deploy so no service call of an affected definition is in flight, or expect to re-drive those
  instances after the upgrade path (decision 0055) exists.
* A tenant that was never replayed to the `TASK_ENTITY_WRITES_APPLIED` v3 schema lands in ERROR
  with detail `event_schema_outdated`. Run `TenantProvisioning.replay_all_pending/0` for every
  tenant BEFORE the first handler-calling service definition is activated.
* A handler value larger than the service byte caps (64 KiB per value, 256 KiB per line, the same
  as declarative lines) is `validation_failed` with detail `value_too_large`.
* The combined 20-line cap and the 49 creates per handler call apply; the handler-call deadline
  guard counts inside the 20 s service budget (an exhausted budget is contention and is re-applied).
