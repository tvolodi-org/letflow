# SERVICE_TASK entity writes: a refusal lands the instance in ERROR

GH #2587 / REQ-499 PR C2 (decision `docs/migration/decisions/0054-process-step-writes-entity.md`;
design `lib/letflow/design/gh2587-req499-pr-c-service-task-writes.md` D-C.8, D-C.9, OQ-C3).

Audience: whoever supports a tenant whose process definition declares `entity_writes` on a
SERVICE_TASK node, and whoever reads the DLQ.

## Status

The composition is merged but DARK: the definition activation fence
(`Letflow.Definitions.check_entity_writes/3`) still refuses `entity_writes` on a SERVICE_TASK
node (C1 lifts it later). Until then only a definition row that carried the attribute from BEFORE
PR B1 (when it was silently inert) can reach this behaviour; the C2 merge gate counted those rows
and the result was required to be zero.

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
| Tenant audit | `entity_write.refused` with the closed `detail` atom (for example `field_restricted`, `not_append_only`, `scoped`, `value_too_large`, `module_writes`); no value. It is written in a THIRD, best-effort transaction AFTER the landing commits: if that write fails the incident (instance ERROR, DLQ entry, `EXECUTION_ERROR` event) still exists, only the audit entry is missing, and a warning is logged |

Public codes: `write_not_permitted`, `validation_failed`, `entity_append_only`,
`entity_type_inactive`, `entity_write_contention`, `entity_write_failed`,
`entity_write_needs_reactivation`.

## Contention is retried by the engine, bounded

Lock waits, statement timeouts, deadlocks, a lost connection and the 10 s guard are re-applied by
the engine itself (3 attempts, 100 ms and 300 ms apart, inside a 20 s budget; the script route
uses `min(20 s, lease remaining - 2 s)` and starts an attempt only with at least 15 s left). The
external call is never repeated. After the last attempt the instance lands in ERROR with public
code `entity_write_contention`.

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
