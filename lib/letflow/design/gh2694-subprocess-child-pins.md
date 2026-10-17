# GH #2694 -- sub-process child INSTANCE_STARTED carries pinned_versions

Status: implemented with this note. Scope: `Letflow.Engine.SubProcess`
(`prepare_child_activation/4`, `append_start_multi/7`). No migration.

## 1. What `create/2` pins

`Engine.start_instance/6` calls `PinResolver.resolve(graph, definition, lookup, overrides)`:

* every SERVICE_TASK `service_id` -> a `:catalog_entry` pin (`resolved_id` = catalog version id);
* every SERVICE_TASK `script_key`/`script_version` -> a `:script` pin (published, `service_task`
  hook only; the script id and sha);
* every SUB_PROCESS `module_ref` -> a `:module` pin;
* exactly one `:variable_schema` pin.

The `lookup` is `PinLookup.build(tenant_id)` (catalog scoped to the tenant) with
`script_lookup = Scripts.Runtime.pin_lookup(prefix)`. The sorted list is embedded as
`INSTANCE_STARTED.pinned_versions`; `PinResolver.reconstruct_effective_pins/2` reads it (plus
`pins_rebound` events) and every pin consumer (`catalog_pins/1`, the script dispatch, rebind)
goes through that. A parent given by `attrs[:parent_instance_id]` additionally runs
`apply_inheritance/2` (non-script parent pins win over the child's own).

## 2. What the sub-process child needs

The child is built by `SubProcess`, not by `create/2`, and its event had no `pinned_versions`.
So `pin_for/3` found nothing and a script or catalog SERVICE_TASK in the child failed with
`script_task_pin_unresolved` / `:pins_unavailable`. The child needs the pins for the nodes of
ITS OWN definition.

## 3. Decision: resolve FRESH for the child's definition, same function as `create/2`

`SubProcess.prepare_child_activation/4` calls `PinResolver.resolve/4` with the child's graph and
definition and the same lookup `create/2` builds by default. Rationale:

* Pins are per definition. The child's script/catalog references are not in the parent's pins,
  and the parent's script pins may name a different version of the same key (tested). Copying
  the parent's set would leave the child's own references unpinned (the bug) or pin the wrong
  version.
* `apply_inheritance/2` is NOT applied. It needs the parent's effective pins, but on the
  `create/2` path the parent is not persisted yet, so they cannot be reconstructed. It also never
  carries `:script` pins across (C7), so it would not fix the reported failure. Inheritance for
  an externally supplied `parent_instance_id` on `create/2` is unchanged.
* `pin_conflicts: []` is written, the shape every child-with-parent `create/2` event has
  (a fresh resolution has nothing to conflict with).
* Not done: `validate_initial_variables/2` against the child's variable schema. The child's
  inputs are already filtered by the SUB_PROCESS `interface`; adding schema validation would be a
  behaviour change beyond this issue. The resolved schema is discarded.

## 4. Failure behaviour

A pin that cannot be resolved (retired/missing script version, retired/invisible catalog entry,
unresolved module ref, override failure) returns `{:error, {:pin_resolution_failed, reason}}`
from `prepare_child_activation/4`, BEFORE the child snapshot is created, so nothing is written:

* `create/2` path: `create/2` aborts with
  `{:activation_failed, {:subprocess_interface_violation, {:pin_resolution_failed, _}}}`
  (the existing wrapper for every child-preparation failure); no parent row exists.
* `complete_task/3` path: routed through `SubProcess.to_error_args/6` like the interface
  failures: the parent instance goes to ERROR, `error_type: :subprocess_interface_violation`,
  `details.code: "SUB_PROCESS_PIN_UNRESOLVED"`, no child, the gate task stays pending.

Pins are resolved for the WHOLE child graph, so an unresolvable pin anywhere in it (including a
branch that would never execute, and any SUB_PROCESS `module_ref` node, since the default
`module_lookup` always answers not-found) blocks the parent's start, exactly as for a top-level
instance of that definition under `create/2`. This matches `create/2`, which refuses to start an instance whose pins cannot be resolved.

## 5. Replay / reconstruction

The child's pins are an ordinary `pinned_versions` field on its own `INSTANCE_STARTED` event, so
`reconstruct_effective_pins/2` reads them exactly as for a top-level instance. The event is
written once and is append-only; replay never re-resolves. Test: the child's reconstructed pins
and raw `pinned_versions` equal those of a top-level instance of the same definition.

Children started before this fix have no `pinned_versions`. Replay reads them as `[]`, as
before. No backfill: the log is append-only, `pins_rebound` rebinds only pins present in
`INSTANCE_STARTED`, and the affected children (script/catalog node inside a child) already
failed and still fail with the same refusal. All other old children never consult pins. A
migration is not needed.

## 6. Security and locks

* Pins decide which script (id + sha) and which catalog version run, and which permission
  versions apply. Resolution uses ONLY the child's definition (read through the tenant prefix by
  name, as before) and the tenant id derived from the schema prefix
  (`TenantProvisioning.tenant_id_for_schema_name/1`, the INV-PD-7 derivation the completion path
  already uses). A prefix that yields no tenant id refuses the child
  (`{:pin_resolution_failed, :tenant_unresolved}`). Nothing comes from parent variables, the
  caller's attrs or user input, and no `:pin_lookup`/`:pin_overrides` is accepted here.
* Lookups are plain reads (catalog row, `script_rules` row): no `FOR UPDATE`/`FOR SHARE`, so the
  #2695 lock order (parent group first, then the child) is unchanged. Resolution runs inside
  `prepare_child_activation/4`, which is already documented as read-only in the lock-order
  statement-log test.
* TOCTOU: pins are read without a lock, as in `create/2`. Each run re-checks the version in
  `Scripts.Runtime.prepare_run/3` (not trusted from the pin alone): a version revoked after the
  pin was taken, or a sha256 / hook-kind mismatch, is refused; a version merely retired keeps
  running for instances already pinned to it (by design, the same as for top-level instances).
* A child can resolve a script/catalog entry the parent could not; that is correct (visibility is
  the tenant's, the same as a top-level start of that definition).
