# 0062 -- Restriction-carrying process variables: labels as provenance, read-time redaction, and the D5 output rule

Status: Proposed: drafted from the T-0149 design (GH #2616, rev 4, design gate PASS 2026-10-22). Needs SECURITY-REVIEWER and REVIEWER sign-off (Q1-Q7 below). This record changes no code. The 0053 C10 interim limit stays in force until the implementing requirement (three parts, see "Implementing requirement") lands; it is not lifted by this record.

Date: 2026-10-22

Related: 0053 D5 "Input redaction" and D6 "7c rulings" C10 (both amended by this record, see "Amends"), 0054 (process steps write entities; `entity_writes`, `_sys` reservation, D1a engine-only fields), 0059 (record history with read-time redaction), REQ-231 (field restrictions and grants), GH #2534 (7c design `lib/letflow/design/gh2534-7c-script-handler.md`, C10 row), GH #2616.

## Problem
0053 D6 C10 refuses, at activation and at run time, any script whose manifest opts into RESTRICTED entity fields (`restricted_inputs`, or `reads[].restricted_fields`), "because process variables carry no field restrictions". The limit lifts "when variables can carry restrictions". Today a restricted value never enters an instance variable through a script: the 7c-2 port omits it (`lib/letflow/entities/script_reads.ex`) and no script can opt in. Once one can, the value can move on from the variable by paths that exist on main now: step entity writes (0054), handler writes, sub-process copying, SERVICE_TASK templates, form computed fields, every read surface and event history. Lifting C10 is safe only if all of them carry the restriction. This record states the rules for each.

## Decision

**R1. Scope.** The rules cover every path by which a value derived from a restricted field moves between a script, an instance variable, an entity field, a reader, a child instance or the outside: hook 1 (SERVICE_TASK script, 0053 D2); step entity writes and handler writes (R5); sub-process copying (R7b); form computed fields (R14); outbound templates (R12); readers (R8) and history (R8h); gateway conditions (R13, accepted residual). A value a human types is not derived from a restricted field and carries no labels (R9).

**R2. Labels are provenance, stored beside the value.** A variable's restriction is a set of labels `"entity_type.field_name"` naming the restricted fields its value was derived from. Labels live in a new column `variable_labels` (jsonb, default `{}`, a map variable name -> sorted label list) on `instance_projection` in the tenant schema, NOT inside `variables` and NOT under `_sys` (0054 reserves `_sys` and `_sys.*`). Labels are engine-computed only; no request, form, script or completer body can set them (as 0054 D1a). A label never holds a value.

**R3. Redaction is evaluated at read time.** A label is provenance, not a copied policy. Every read of a labelled variable is filtered by the CURRENT `entity_field_restrictions` rows and the CALLER's grants (the `FieldGrants` model, `FieldGrants.load_restrictions/3`, REQ-231). A restriction added after the value was stored applies to it; a restriction removed no longer does. Same rule as 0059.

**R4. Taint of a run's outputs.** Let T be the union of the labels of every restricted input a script run received: labelled variables delivered under R6, and every restricted field value delivered by an opted-in read (7c-2 `restricted_fields`). Every output key of that run inherits T (fail-closed). The manifest cannot narrow T: the host cannot verify a publisher's claim that an output is not derived from a restricted input. Narrowing is a later requirement. A run with no restricted input has T = {} and writes no labels (no change from today).

**R5. The 0053 D5 output refusal, for entity-field targets.** This is the "fewer restrictions" refusal, and it applies to entity writes now (0054 is on main).
* *Target restriction set.* For an entity field F `entity.field`, RS(F) = `{"entity.field"}` if any `entity_field_restrictions` row names F (for any subject), else `{}`. It reads the restriction rows, not a user's grants, so it is principal-independent.
* *Predicate.* A write of a value with taint L into F is accepted iff L ⊆ RS(F). Stated plainly: a labelled value may be written only into a field that is itself restricted and is the source of its label; every other entity-field target is refused (Q5).
* *R5a, activation (static).* A `var` line of a HUMAN_TASK or SERVICE_TASK `entity_writes` (`Letflow.Entities.StepWrites` `resolve_values`), and a handler write argument built from a variable (`Letflow.Entities.HandlerWrites`), whose `var` is the output of an opted-in script, has static taint U(P), the union of the `from` labels of that script's opted-in entries (R6). Activation refuses the binding when U(P) ⊄ RS(target): `script_output_restriction_widened`. A var with no opted-in producer has static taint {}.
* *R5b, run time (backstop).* At the write, `StepWrites` and `HandlerWrites` read each `var`'s labels from the transaction's merged `variable_labels` (R7). A line whose taint is not ⊆ RS(target) is refused like the existing `:field_restricted` per-line refusal, with `entity_write_restriction_widened`; the line writes nothing.
* *Principal.* The existing write-side check (`check_restrictions/3` in `StepWrites`, and its `HandlerWrites` counterpart) keeps applying to `ctx.subject_id` (the completer on HUMAN, the activator on SERVICE_TASK). R5 is in addition to it.
* A process-variable target is not a field: it has no restriction set and inherits the taint (R4, R7).

**R6. Opt-in, publish and run time (hook 1 scripts).**
* *Manifest shape.* `restricted_inputs` becomes a list of objects `{"name": <input variable>, "from": [{"entity_type": ..., "field": ...}, ...]}`. The string list is retired. No active version can carry it today (C10 refuses activation), so no stored active version changes meaning. Validation (`Letflow.Scripts.Validation`) checks that each `name` is in `input_schema` and each `from` pair is a field of an active definition (Q4).
* *Publish.* Unchanged: the publisher must hold `EntitiesRestrictionsManage` for any version with a non-empty opt-in (0053 OP2, AC11). This is the only publisher gate.
* *Run time* (`Letflow.Engine.ScriptInput.build/3`, called from the script-task dispatcher): a labelled input variable enters the script input iff the manifest entry names it AND every label of the variable is in that entry's `from` list. Otherwise it is OMITTED, like an undeclared variable (field-minimal, C9); if `input_schema` requires it, the run is rejected `input_invalid` (existing path).
* *Re-redaction.* A restriction ADDED after publish on a pair the publisher did not opt into is in no `from` list, so the value is omitted. A restriction REMOVED on a declared pair makes the value unrestricted; it enters under ordinary rules.
* *Opted-in reads (7c-2).* `reads[].restricted_fields` is honoured only for a pair listed in that read's own declaration; the port keeps omitting every other restricted field.

**R7. Storage, events and replay.**
* *R7a, the writer.* The apply event `SCRIPT_TASK_COMPLETED` (0053 C12) gains `output_labels` (variable -> label list) next to its output map, whose payload key is `"output"`. `Letflow.Engine.VariableMerge.merge/3` is the only writer of `variable_labels`: every key it writes gets the source's labels, and a key written by a source with no labels has its label entry REMOVED (an unrestricted source replaces the value). Reconstruction (`Letflow.Engine.Reconstruction`) and the snapshot writer carry `variable_labels`; without that a replay would drop labels and leak. Events carry label references, never values.
  * *EXECUTION_ERROR replay.* That branch replaces `state.variables` wholesale from the event's `variables` map; it therefore also replaces `state.variable_labels` with the event's own `labels` map (R8h), so replay and the live path agree.
  * *`_sys` writes* carry no labels; `drop_reserved/1` removes reserved keys from every label map.
* *R7b, sub-process.* Labels travel with copied keys in both directions. Parent to child (`build_child_initial_variables`, including the `nil` interface full copy): each copied key keeps the parent's labels; the child's INSTANCE_STARTED carries them as `initial_labels`. Child to parent (`build_parent_merge_variables`, including the `nil` branch): each merged key takes the child's label entry, or loses its entry (R7a). Reserved keys are dropped with their labels. Replay and snapshots of both instances carry `variable_labels`.

**R8. Read surfaces redact labelled keys for the caller.** One helper in `Letflow.Api.Response`, beside `public_variables/1`, takes `(variables, variable_labels, grants)` and replaces each labelled key the caller may not read with the existing redaction representation: the atom returned by `Letflow.Entities.Query.FieldGrants.redacted_sentinel/0` (`:__field_redacted__`), JSON-encoded the way the entity responses already encode it. No second sentinel and no second encoder. Applied at:
* the instance and task routers (`GET /instances/:id`, the instance list/variables reads, `GET /tasks/:id`) and the stored error snapshot (`Letflow.Engine.ExecutionError`);
* the platform Lua host (`Letflow.Engine.Lua.Platform` `fetch_instance_state` / `read_variable`): the platform principal holds no entity grants, so it sees the representation;
* the in-process plugin handler context (`Letflow.Engine.PluginInterface`): the redacted view for the platform principal; plugins can make network calls, so they never receive the value;
* platform WASM `read_variable` (`Letflow.Engine.Wasm.HostApi`): a labelled key the caller may not read returns the "not present" result (`-1`) the ABI defines; the ABI has no redaction representation and gets none;
* event history (R8h).
A key name is not a value and is never redacted.

**R8h. History: event-time labels, never current labels.** `GET /instances/:id/history` (the only router caller of `Response.public_event_payload/2`) sends stored payloads. Redacting an old event with the CURRENT projection labels leaks, because R7a removes a key's label when an unlabelled source overwrites it. So every persisted event that carries a variable value records the labels of that value in the same payload, and history redacts with those.
* *R8h-1, value-bearing fields and their label fields:*

| Event | Value-bearing field | Label field (same payload) | Label state recorded |
|---|---|---|---|
| `SCRIPT_TASK_COMPLETED` | `output` | `output_labels` | the run's output labels (R4) |
| `SERVICE_TASK_COMPLETED` | `decoded_body` | none | a service response carries no labels; absent means none |
| `TASK_COMPLETED` | `output_variables` | `output_labels` | after the write (`{}` for a human completer, R9) |
| `TASK_COMPLETED` | `merged_variable_events[]` `variable_overwritten` `old_value` / `new_value` | `old_labels` / `new_labels` on the entry | the key's labels before / after the write |
| `TASK_COMPLETED` | `merged_variable_events[]` `computed_field_disagreement` `server_value` / `submitted_value` | `server_labels` / `submitted_labels` | the computed field's labels (R14) / `[]` (completer input) |
| `TASK_COMPLETED` | `merged_variable_events[]` `visible_when_false_value_discarded` `discarded_value` | `discarded_labels` | the field's labels before the write |
| `SUB_PROCESS_COMPLETED` | `output_variables` | `output_labels` | the child's labels of the copied keys (R7b) |
| `SUB_PROCESS_COMPLETED` | `merged_variable_events[]` `variable_overwritten` `old_value` / `new_value` | `old_labels` / `new_labels` | the parent key's labels before / after the write |
| `INSTANCE_STARTED` (child) | `initial_variables` | `initial_labels` | the parent's labels of the copied keys |
| `EXECUTION_ERROR` (and the script-failure and no-matching-edge incidents that pass the current variables) | `variables` | `labels` | the full label map at the time of the error |

  The parallel-join merge events are in memory only and never persisted; `SCRIPT_RUN_RECORDED` holds no value (allowlist with `input_hmac` only).
* *R8h-2, source.* `VariableMerge.merge/3` returns the before and after labels with each `variable_overwritten` tuple, so the merge-event encoders (in `Letflow.Engine` and `Letflow.Engine.SubProcess`) add the label fields without a second lookup. Form re-evaluation entries get `server_labels` from R14 and `discarded_labels` from the labels before the write. Every entry label field is a sorted list of `"entity_type.field_name"`.
* *R8h-3, redaction.* `public_event_payload` takes the caller's grants and redacts each top-level map in `["variables", "output_variables", "initial_variables", "output"]` (`"output"` is new in that list) with its label map from the same payload, and each value-bearing field of each `merged_variable_events[]` entry whose label field names a restricted field the caller has no grant for. `key`, `field` and `event` stay. It never reads the projection's `variable_labels`. One function evaluates labels against current restriction rows and caller grants, called with the event's labels for history and with `variable_labels` for live reads (R3). New arities `public_variables/3` `(variables, variable_labels, grants)` and `public_event_payload/3` `(event_type, payload, grants)`; every router call site moves to them, and the router helper lint (`test/letflow/routers/routers_variables_helper_test.exs`) then accepts only the new arities in routers, because the old ones are the unredacted path. Whether /1 and /2 stay for non-router callers or are removed is decided and stated by the implementing requirement.
* *R8h-4, old events.* Pre-lift events carry no label field. C10 refused every labelled opt-in, so no pre-lift event holds a labelled value: a missing label field means "no labels" and is correct. No event is migrated (append-only). After the lift the engine always writes the label fields.
* *R8h-5, event-type schemas.* The new fields are declared optional (not in `required`) in the seeded payload schemas (`Letflow.TenantProvisioning` `@platform_event_type_seed_attrs`: INSTANCE_STARTED, TASK_COMPLETED, SUB_PROCESS_COMPLETED, EXECUTION_ERROR, SCRIPT_TASK_COMPLETED), each with a `schema_version` bump and description line, and an `@event_type_backfills` entry in `mix letflow.backfill_event_type_versions` per bump (as REQ-292 and REQ-391 did for TASK_COMPLETED). SCRIPT_TASK_COMPLETED reaches existing tenants through migration replay (its version is pinned by `test/letflow/tenant_provisioning_script_events_test.exs`), so its bump is a new migration plus the seed. The seeded schemas do not set `additionalProperties: false`; payloads validate either way, and the declaration follows convention.

**R9. Writes by principals without grants.** A principal without the grant may complete a task that overwrites a labelled variable (it hides nothing new from that principal); R7a removes the label, and R8 still hides the old value from them, including in history (R8h) (Q2).

**R10. Residual, stated plainly.** A restricted value is stored in clear in `instance_projection.variables`, in event payloads (`SCRIPT_TASK_COMPLETED.output`, `output_variables`, `merged_variable_events`), in SERVICE_TASK error contexts and in snapshots. D5 replay applies RECORDED results, so the copy cannot be avoided without a redesign. Protection is read-time redaction (R8, R8h), not encryption at rest: the same class of accepted residual as 0059 (Q1).

**R11. Out of scope.** Narrowing of T (R4); Lua platform scripts' own restriction model beyond R8. No export or webhook reads instance variables (grep of `lib/` at main 6e2a61bf1); the implementing requirement re-greps before its merge and adds any hit as a new rule here.

**R12. Outbound: a labelled value never leaves the platform through a SERVICE_TASK.** The URL and body templates render with the whole variables map; a labelled key named by a placeholder (`ServiceTask.template_variable_keys/1`) is never rendered.
* *Activation (static).* A SERVICE_TASK url or body placeholder whose key is in the static taint of any opted-in script output in the definition (U of R5a) is refused: `service_task_restricted_variable_reference` (in `Letflow.Definitions.ReservedReferences`).
* *Run time (backstop).* The render path checks each placeholder key's labels; a labelled key fails the arm with `service_task_restricted_variable_outbound` through the existing standalone error path. No request is sent. The error payload names the key, never the value.
* *Catalog URL.* The catalog `endpoint_url` renders with the same function and gets the same check; the I-13 placeholder grammar (GH #2623, #2638) is unchanged.
* No other SERVICE_TASK egress of the variables map exists; plugin handlers and WASM are R8.

**R13. Gateway conditions: accepted residual.** Edge conditions (`Letflow.Engine.Transition` `evaluate_conditioned_edges`, `Letflow.Engine.Expr`) may read labelled variables. Which edge was taken reveals one bit per gateway, and the node sequence is in history; the value itself is never written, returned or sent. Accepted as a residual of the R10 class (Q6). If rejected: a condition over a statically tainted key is refused at activation.

**R14. Form computed fields.** A computed field (`Letflow.Engine.FormExpressionReevaluation`) whose expression reads a labelled variable inherits the union of those labels (the R4 rule applied to form output), written through R7a. A submitted value for the key replaces the computed value and its labels (unlabelled source) (Q3).

## Amends
* **0053 D5 "Input redaction".** "The host refuses activation/publish if it maps to a target field with fewer restrictions" binds ENTITY-FIELD targets, with the predicate and the activation and run-time checks of R5. A process-variable target is not a field: it inherits the taint (R4, R7). 0053 carries a pointer to this record.
* **0053 D6 "7c rulings" C10.** Lifted by this record AT THE MERGE of the implementing requirement's part 3, not before. Until then the activation refusal (`script_restricted_opt_in_unsupported`) and the run-time backstop (`restricted_opt_in_unsupported`) stay, with their tests.

## Tests to replace when C10 is lifted
Grep (worktree at main 6e2a61bf1): `grep -rn "restricted_opt_in_unsupported\|script_restricted_opt_in_unsupported\|restricted_inputs\|restricted_fields\|C10" test --include=*.exs`, restricted/C10 hits:

```
test/letflow/definitions/script_bindings_activation_test.exs:4   ... 4.5, C8, C10, C11a
test/letflow/definitions/script_bindings_activation_test.exs:247  test "restricted opt-in", ...
test/letflow/definitions/script_bindings_activation_test.exs:249      manifest = Map.put(F.closed_manifest(), "restricted_inputs", ["amount"])
test/letflow/definitions/script_bindings_activation_test.exs:256        :script_restricted_opt_in_unsupported
test/letflow/definitions/script_bindings_activation_test.exs:268            "restricted_fields" => ["name"]
test/letflow/definitions/script_bindings_activation_test.exs:274      assert {{:error, {:script_binding_invalid, "svc", :script_restricted_opt_in_unsupported}}, ...
test/letflow/entities/script_reads_test.exs:384  test "a non-empty restricted_fields is refused by the port itself (no opt-in, C10)"
test/letflow/scripts/runtime_test.exs:6-8        moduledoc: AC26a ... restricted_opt_in_unsupported ... (C10: no opt-in path)
test/letflow/scripts/runtime_test.exs:82         test "opt-in backstop: restricted_fields inserted directly is rejected ..."
test/letflow/scripts/runtime_test.exs:88,94,105  manifest with restricted_fields; {:rejected, :restricted_opt_in_unsupported}; outcome_detail
test/letflow/scripts/runtime_test.exs:112-118    test "restricted_inputs is refused the same way" -> {:rejected, :restricted_opt_in_unsupported}
test/letflow/scripts/runtime_test.exs:199-205    step order: "3b restricted opt-in wins over 3c check_reads" asserts :restricted_opt_in_unsupported
test/letflow/scripts/policy_test.exs:424         "restricted_fields" => ["ssn"]  (check_reads opt-in = :ok; NOT C10, stays)
test/letflow/scripts/scripts_reads_and_kill_switch_test.exs:252-278  AC11: publish needs EntitiesRestrictionsManage -> {:error, :restricted_inputs_not_allowed} (NOT C10, stays)
```

Replace (the C10 pins):
* `test/letflow/scripts/runtime_test.exs:82` "opt-in backstop: restricted_fields inserted directly is rejected and the port is never called" -> SR-OPT-1, SR-OPT-3.
* `test/letflow/scripts/runtime_test.exs:112-118` "restricted_inputs is refused the same way" -> SR-OPT-1.
* `test/letflow/scripts/runtime_test.exs:199-205` "3b restricted opt-in wins over 3c check_reads": after the lift 3b no longer refuses and the same manifest is refused by 3c (`nope` is not a type), so the test asserts the 3c refusal and keeps its step-order intent. The moduledoc at `runtime_test.exs:6-9` changes with it.
* `test/letflow/definitions/script_bindings_activation_test.exs:247-274` "restricted opt-in" -> SR-OPT-4, SR-OPT-5.
* `test/letflow/entities/script_reads_test.exs:384` "a non-empty restricted_fields is refused by the port itself (no opt-in, C10)" -> SR-OPT-1 (an opted-in pair is delivered), SR-OPT-3 (a pair not opted in is omitted).

Keep (not C10): `policy_test.exs:424`, `scripts_reads_and_kill_switch_test.exs:252-278` (AC11 publish grant), `validation_reads_test.exs` (restricted subset rules). The implementing merge re-runs the grep above.

Tests that change with R8h (not C10 pins), grep `grep -rn "public_event_payload\|@variable_payload_keys" test`:

```
test/letflow/engine/module_write_audit_test.exs:318:        Letflow.Api.Response.public_event_payload(
test/letflow/engine/service_task_entity_writes_test.exs:917:      shaped = Response.public_event_payload(applied.event_type, payload(applied))
test/letflow/engine/service_task_entity_writes_test.exs:934:      assert Response.public_event_payload(sys.event_type, payload(sys)) == %{}
test/letflow/routers/routers_variables_helper_test.exs:5:  helper, `Letflow.Api.Response.public_variables/1` / `public_event_payload/2`.
test/letflow/routers/routers_variables_helper_test.exs:12:      `Response.public_event_payload/2` (or the platform-event shaper
test/letflow/routers/routers_variables_helper_test.exs:25:  the shaping function (`public_event_payload/2`) is an allowlist by event type and key. A new
test/letflow/routers/routers_variables_helper_test.exs:66:    if call_to?(value, :public_event_payload, 2) or
test/letflow/routers/routers_variables_helper_test.exs:141:        ~S|defp m(e), do: %{"payload" => Response.public_event_payload(e.event_type, e.payload)}|
test/letflow/routers/routers_variables_helper_test.exs:154:    r = scan_source(~S|defp m(e), do: Response.public_event_payload(e.event_type, e.payload)|)
test/letflow/routers/sys_variables_response_test.exs:423:  test "public_event_payload/2 tolerates a missing or malformed lines value" do
```

`routers_variables_helper_test.exs` (arity pins and synthetic snippets) moves to the /3 arities; the four direct callers keep passing if /2 stays and move to /3 if it is removed. Event-type version pins for R8h-5: `test/letflow/tenant_provisioning/backfill_test.exs` (TASK_COMPLETED `schema_version: 3`) and `test/letflow/tenant_provisioning_script_events_test.exs` (`{"SCRIPT_TASK_COMPLETED", 1}`); the implementer reads the other files returned by `grep -rln "schema_version" test/ | xargs grep -ln "TASK_COMPLETED\|EXECUTION_ERROR\|SUB_PROCESS_COMPLETED\|INSTANCE_STARTED\|SCRIPT_TASK_COMPLETED"` for further pins (`test/reports/` and `test/specs/` are history, not pins).

## Replacement tests (the implementing requirement delivers these IDs)
* **SR-OPT-1 opt in.** A publisher holding `EntitiesRestrictionsManage` publishes and activates a version whose `restricted_inputs` entry names a labelled variable and a declared pair; the run's input contains the value; outcome `ok`.
* **SR-OPT-2 re-redaction at run time.** After publish, a restriction is added on a pair the manifest does not declare; the next run omits the variable; a required input yields `input_invalid`.
* **SR-OPT-3 refusal for a principal without the grant.** (a) A user without the grant reads `GET /instances/:id` and `GET /tasks/:id`: the labelled key carries the redaction representation; (b) a script that does not opt in receives no labelled value.
* **SR-OPT-4 activation.** An opt-in whose publisher lacks the grant is refused at publish (existing); an opted-in version with the grant activates.
* **SR-OPT-5 D5 predicate (pure, R5).** U(P) = {customer.salary}: a target with RS = {} is refused, a target with RS = {customer.salary} is accepted, a variable target is accepted.
* **SR-OPT-6 taint and replay (R4, R7a).** Outputs of a run that took a labelled input carry `output_labels`; after `reconstruct_instance` `variable_labels` is identical; a later unrestricted merge removes the entry.
* **SR-OPT-7 form expression (R14).** A computed field reading a labelled variable inherits the label; a submitted value for the key removes it.
* **SR-OPT-8 platform hosts (R8).** `fetch_instance_state` returns the representation; WASM `read_variable` returns `-1`; the plugin handler context has no value for the key.
* **SR-OPT-9 step entity writes (R5a, R5b).** (a) Activation refuses a HUMAN_TASK `entity_writes` line whose `var` is a labelled output of an opted-in script and whose target is unrestricted; (b) run time refuses it with `entity_write_restriction_widened` when the labels arrive only at run time; (c) acceptance when RS(target) contains the label; (d) the same three for a `HandlerWrites` argument.
* **SR-OPT-10 sub-process (R7b).** A labelled parent variable copied to the child keeps its label; `GET /instances/:child` redacts it for a caller without the grant; a child output copied back carries its label; an unlabelled child key removes the parent entry; the `nil` interface carries all labels.
* **SR-OPT-11 outbound (R12).** (a) Activation refuses a URL or body placeholder naming a statically tainted key (`service_task_restricted_variable_reference`); (b) at run time a labelled placeholder fails with `service_task_restricted_variable_outbound`, the outbound client is not called, and the error payload has the key name and no value; (c) the same for the catalog `endpoint_url`.
* **SR-OPT-12 (negative).** `variable_schema` error details never echo a labelled value.
* **SR-OPT-13 history (R8h).** (a) Labelled `x` is written by `SCRIPT_TASK_COMPLETED`; a later `TASK_COMPLETED` by a principal without the grant overwrites it unlabelled. `GET /instances/:id/history` for a caller without the grant shows the earlier `output.x` as the representation, and in the overwriting event the `variable_overwritten` entry for `x` with `old_value` as the representation and `new_value` in clear, and `output_variables.x` in clear; live `GET /instances/:id` shows the later value. (b) An `EXECUTION_ERROR` that recorded labelled `x` shows it as the representation in history; after replay, `variable_labels` equals the event's `labels`. (c) With the grant, the old value is shown in `output.x` and `old_value`. (d) Sub-process: the child writes labelled `y` over the parent's unlabelled `y`; the `SUB_PROCESS_COMPLETED` entry shows `new_value` as the representation and `old_value` in clear (pins separate `old_labels`/`new_labels`).
* **SR-OPT-14 form re-evaluation entries.** A computed field reads a labelled variable and a completer without the grant submits a different value. In history, for a caller without the grant, the `computed_field_disagreement` entry has `server_value` as the representation and `submitted_value` in clear, and a `visible_when_false_value_discarded` entry for a field that held a labelled value has `discarded_value` as the representation. With the grant both are shown. (Task completion does not return these entries in its HTTP response; history is the surface.)
* **INV-10.** No new route takes a tenant id; the implementing requirement states this.

## Implementing requirement (filed from this record)
1. **Labels: storage, propagation, replay.** Migration, `VariableMerge`, apply event, reconstruction, snapshot, sub-process, and all R8h event label fields with the R8h-5 schema bumps (written by the same code path). Tests SR-OPT-6, SR-OPT-10.
2. **Read redaction and in-process/outbound paths** (R8, R8h-3, R9, R12, R14), including the helper arity change. Tests SR-OPT-3, -7, -8, -11, -13, -14.
3. **Opt-in, activation and step writes** (R5, R6): manifest shape, `ScriptInput`, the port, the R5 predicate in `StepWrites` and `HandlerWrites`, C10 removal and the test replacements above. Tests SR-OPT-1, -2, -4, -5, -9, -12. Part 3 must not land before parts 1 and 2.

### Part 2 landed (GH #2616, T-0187)

* **Route list correction to R8.** `GET /tasks/:id` and the instance list render no variables today. The task-side variable surface is the `POST /tasks/:id/complete` response. Redaction covers `GET /instances/:id`, reconstruct, history and that response.
* **Helper arity.** `Letflow.Api.Response.public_variables/3` and `public_event_payload/3` take the caller's grant-resolved hidden label set. The `/1` and `/2` arities are removed.
* **R14 deviation (Q3).** A computed field's server value always wins, as it did before. A submitted value is recorded only in the disagreement event, with `submitted_labels: []`. The stored label is the union of the labels of the computed field's inputs, taken in topological order.
* **Sentinel ruling (R8/R9).** A completion that submits the redaction placeholder for a labelled key the caller cannot read is refused with 422 `redacted_value_submitted` (key names only), before any write. A real value is accepted and removes the label. Omitting the key keeps the stored value.
* **Deferred.** SR-OPT-3(b) (script input omission) belongs to part 3, with the opt-in. No production path yields a label before then.

## Consequences
* Every surface that shows instance variables gains a grant check; a caller without the grant sees `:__field_redacted__` (or absence on WASM) where a script delivered a restricted value. Callers with the grant, and every instance without labelled variables, see no change.
* Event payloads grow optional label fields; old events stay valid and are read as unlabelled.
* An entity write of a labelled value into any field other than its restricted source is refused, at activation where it is static and at run time otherwise.
* The router helper lint tightens to the grant-taking arities.

## Open questions for the reviewers (recommendations given; the sign-off decides)
* **Q1 (SECURITY-REVIEWER)** R10: accept read-time redaction with values in clear at rest, or require encryption at rest. Recommendation: accept, as 0059.
* **Q2 (SECURITY-REVIEWER)** R9: may a principal without the grant overwrite a labelled variable? Recommendation: yes.
* **Q3 (SECURITY-REVIEWER)** R14: propagate labels through form computed fields, or refuse at publish. Recommendation: propagate, refusing only where the static U is known.
* **Q4 (REVIEWER)** R6: `restricted_inputs` as objects with `from` pairs, or strings plus a sibling `restricted_from` map. Recommendation: objects.
* **Q5 (SECURITY-REVIEWER)** R5: the narrow predicate (only into the restricted source field), or any restricted target covering the labels. Recommendation: narrow; it needs no per-subject reasoning.
* **Q6 (SECURITY-REVIEWER)** R13: accept the one-bit gateway residual, or refuse labelled conditions. Recommendation: accept and record.
* **Q7 (SECURITY-REVIEWER)** R8h: event-time labels per value-bearing field, or current labels (accepting that overwritten values become visible). Recommendation: event-time labels; current labels are the leak.

## Not decided here
Narrowing of the taint (R4). Encryption at rest (R10). Gateway-condition refusal (R13). Entity writes from script outputs beyond R5.

## Sign-off
* SECURITY-REVIEWER: pending.
* REVIEWER: pending.
