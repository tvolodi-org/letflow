# PILOT-SUB-2: composite process "receive with inspection" (decision record)

> source note: the team repo copy of 27 Nov 2026
> filed whole: the record's own placement paragraph keeps the split its build task planned.
> paths under `project/` and `state/` live in the team repository, not in this one (marked "team repo").

Task T-2846, lane PILOT-SUB (owner order D-205, PM 26 Nov 12:25 / 13:55 / 14:20 / 14:50). Design only, no code.
All `file:line` refer to the product repository at `a3221d083` (origin/main on 2026-11-27).

**Where it lands.** This file stays in the team repository (`project/`). The part that goes to the product,
in the first build task of the lane (SUB-3 below), is section 4 (the definition and its interface) and
section 6 (compensation), as `docs/design/pilot-sub-receive-with-inspection.md`, plus a runbook line in the
stock runbook. Sections 9-11 (long-term, cross-module, lightweight step) and the owner questions stay here.

---

## 1. First answer: the `:420` and `:448` refusals (operator finding, 26 Nov 10:0x)

- `sub_process.ex:355` calls `refuse_module_only_child/4` (`:420-437`): a child whose graph has
  `module_writes` (`WriteTargets.module_writes?/1`, `write_targets.ex:75-82`) starts only under a parent
  whose definition row carries the SAME `owner_module` (`same_module_parent?/3`, `:427-435`, read from the
  parent's snapshot -> definition row). Otherwise `{:definition_not_found, :module_only_definition}`.
- `sub_process.ex:356` calls `refuse_platform_call_child/1` (`:448-456`): a child that declares a
  `platform_call` is refused. **Does not apply here**: no node of `stock_receipt` or `stock_writeoff`
  declares `platform_call` (pack.json: their only node attributes are `module_writes`, `required_permission`,
  `role`).
- Module-writes scan (re-run for this record, `python3 -I` over `priv/modules/*/pack.json`): stock 10/10
  definitions carry `module_writes`; assets 7/7 (`assets_commission`, `_reversal`, `_change`, `_handover`,
  `_writeoff`, `_kind_change`, `_opening`); maintenance 1/1 (two nodes, `maintenance_work` and
  `maintenance_close`). So every shipped module definition is a module-only child.
- **Decision (PM 13:55, option 1): the parent ships IN the stock pack**, stamped `owner_module = "stock"`
  by module install (`EnsureSeeds`, below). `:420` stays as it is; no change to that rule.

## 2. The real interface of the two children (pack.json, req032)

The task text assumes "stock_receipt (inputs item, qty, location)". **That is not the shipped contract.**

| definition | pack.json | nodes | variables read (all `var`, `module_writes` args) | outputs |
|---|---|---|---|---|
| `stock_receipt` 1.0.0 | `:4-66` (`process_key` `:64`) | start -> `post` (HUMAN_TASK, role TENANT_ADMIN, `required_permission` StockApprove) -> end | `document_id`, `document_type`, `mark`, `org_unit_id`, `posting`, `version_no` (`:28-45`), handler `stock.post_document` | none declared; the handler writes a ledger entry + a `stock_posting_mark` record |
| `stock_writeoff` 1.0.0 | `:130-192` (`process_key` `:190`) | the same shape | the same six names | none |

- A child definition declares NO interface of its own. The interface (`inputs`/`outputs`, each entry
  `name`, `json_schema`, `required`; `sub_process_interface.ex:190-192`) sits on the PARENT's SUB_PROCESS node
  (`get_in(node.attributes, ["interface"])`, `sub_process.ex:357-361`), checked at save by CHK-18
  (`graph.ex:74-78`, REQ-032).
- The six values are built by module code from an ISSUED document, never from a person:
  `Posting.start_post/5` (`posting.ex:199-233`) builds `posting` from the issued version's frozen content
  (`post_command/3`, `posting.ex:373-412`) and starts the instance with `module_start: true`
  (`posting.ex:332`). Item, quantity and location are inside `posting.lines`, not variables.
- What the handler checks at the post (so what a child can do with whatever it is given):
  `check_binding/4` (`handlers.ex:214-248`): the version must be issued and current, `client_op_id` = the
  version id, the legs equal the issued content's legs (`Legs`), a write-off's `reason_code` = the header's;
  `check_instance/4` (`handlers.ex:279-300`): every argument equals the child's OWN `INSTANCE_STARTED`
  variables (`HandlerWrites.read_instance_start/1`, `handler_writes.ex:1225-1241`).

Consequence: the composite starts AFTER a receipt document is issued. It replaces `stock_receipt` as the
definition the issue step starts for that document; it is not a form "item, qty, location".

**Filter (what passes to the child)** -- `build_child_initial_variables/2` (`sub_process.ex:147-160`) with
`filter_entries/2` (`:221-245`): with an interface, only the declared input names are copied (absent required
-> `:missing_required_input`, schema mismatch -> `:input_schema_violation`, both parent ERROR); reserved
engine keys are always dropped (`VariableMerge.drop_reserved/1`). With NO interface the whole parent map is
copied (EXT-05). Names are never renamed (`:199-206`).
**Output merge** -- `build_parent_merge_variables/2` (`:178-192`): only declared outputs merge back; with
no interface the child's whole map merges. The composite declares `outputs: []` on both nodes: the children
produce nothing the parent reads (the mark is a record, the entry id is read from the document).

## 3. Security gaps the composite opens (each its own p1 task on the pilot track, D-178)

These are real for ANY module parent that contains a human task or a start from outside module code; the
`:420` comment ("a tenant-made parent, whose completers or start variables could carry the targets") assumes
a module parent has neither. The receive-with-inspection parent has both.

- **G-SUB-1 (SF-03, start side).** `gate_module_only_start/2` (`engine.ex:913-922`) tests only the
  definition's OWN graph. The parent has no `module_writes`, so `POST /instances` of the stamped parent
  passes, and the caller's start variables reach the receipt child through the input filter. The child's
  `check_instance` compares with the CHILD's `INSTANCE_STARTED`, which IS the forged map, so the T-2431
  binding is defeated one level down. `check_binding` still bounds the forge to "an issued, unposted
  document of the tenant", and the post task still needs StockApprove, but the issue route's authority is
  bypassed and a second post instance of one document appears. **Fix:** module-only = own graph OR any
  transitive child (`SubProcess.child_definitions/2`, `sub_process.ex:466-502`), the same shape
  `gate_start_permission/2` already uses for platform calls (`engine.ex:936-952`). Test: public start of the
  parent answers 404 `definition_not_found`; module start passes.
- **G-SUB-2 (SF-03, completion side).** `WriteTargets.refused_keys/3` (`write_targets.ex:111-126`) reads
  `write_read_keys` of the instance's pinned graph only. The parent graph has no `module_writes`, so the
  `inspect` completer may send `document_id`/`posting`/... and they merge into the parent and flow into the
  write-off child's start. **Fix:** the refused set of a graph includes the write-read keys of its
  transitive children; `completer_inputs` of `inspect` = `["damaged_qty"]` only (`write_targets.ex:89-103`).
  Test: completing `inspect` with `posting` -> 422 `output_refused`, nothing merged.
- **G-SUB-3 (no rename in the interface).** Both children read the SAME six names. The parent cannot hold
  the receipt's and the write-off's `document_id` at once, and the filter never renames. Two options:
  (a) engine: an interface input entry `from` (source variable) so the node maps `writeoff_document_id ->
  document_id`; (b) module: the write-off preparation step (G-SUB-4) overwrites the six names after the
  receipt child completed (harmless to the receipt child, whose binding reads its own start event).
  **Recommendation: (b)**, no engine change; (a) is the general fix if a second composite needs it.
- **G-SUB-4 (no step creates the write-off document).** A write-off posts only an ISSUED write_off document
  (`kinds.ex:84-91`: `from` side org unit, location, responsible; header `reason_code`). No process step type
  creates and issues a stock document: `HandlerWrites` creates entity records and posts ledger commands, not
  `Letflow.Documents`. A catalogue platform function cannot do it in a company tenant (rule 1 of decision
  0094: platform tenant only, `platform_calls.ex:38-45`). **Recommendation:** a stock write handler
  `prepare_writeoff` as `module_writes` on the `inspect` node: it reads the receipt document of THIS
  instance (bound through the parent's own start event, like `check_instance`), creates a write_off document
  with the receipt's lines limited to `damaged_qty` and `reason_code` = a fixed code (owner question Q4),
  issues it, and writes the six variables for the next child in the same transaction. Needs a handler API
  for "create + issue a document" (`HandlerWrites`), an engine-adjacent change: own p1 task.
- **G-SUB-5 (lazy activation).** Install leaves stock definitions as stamped DRAFTS; `Posting.ensure_active/3`
  (`posting.ex:96-108`) activates on first use, for a CLOSED name list (`:97`). A child is resolved by
  `get_active_by_name` at the moment the node activates (`sub_process.ex:521-537`): a draft
  `stock_writeoff` makes the parent ERROR (`:definition_not_found`). **Fix (module):** add the parent name
  to the list and ensure the parent AND both children active before the parent starts.
- **G-SUB-6 (read side and cancel).** The document read side finds instances by definition name +
  `variables->>'document_id'` (`definition_ids/2` `posting.ex:348-356`, `pending_post_instance_ids/2`
  `:665-680`, `pending/2` `:728-751`, `pending_node_task/4` `:859-875`). A child `stock_receipt` instance is
  found (the document shows "post pending": good), but the parent is not, and a document cancel
  (`posting.ex:608-647`) cancels the CHILD only. A child cancelled directly leaves the parent token
  `:waiting` for ever (req062 design OQ-4, `lib/letflow/design/req062-sub-process-runtime.md:789-795`; no
  later code cascades it; parent cancel does not cascade down either, `:655-669`). **Fix (module):** a
  document cancel cancels the top parent; the engine cascade (OQ-4) is a separate engine task, not needed
  if the module always cancels from the top.

SUB-5 (the smoke) cannot be green before G-SUB-1, -2, -4, -5 are merged; -3 is covered by -4 (option b);
-6 is needed for the cancel step of the scenario.

## 4. The parent definition (ships in the stock pack)

Name `stock_receive_inspect`, version 1.0.0, in `priv/modules/stock/generate_pack.exs` -> `pack.json`,
module version bumped from `0.24.0` (`stock.ex:453`) to the next free number at build time.

```
start -> receipt (SUB_PROCESS definition_name stock_receipt,
                  interface inputs: document_id, document_type, version_no, org_unit_id, mark, posting
                  (all required), outputs: [])
      -> inspect (HUMAN_TASK, completer_inputs ["damaged_qty"], form damaged_qty integer >= 0,
                  module_writes stock.prepare_writeoff [G-SUB-4])
      -> gw_damage (EXCLUSIVE_GATEWAY)
           [damaged_qty > 0]          -> gw_size
           [is_default]               -> end
      gw_size (EXCLUSIVE_GATEWAY)
           [damaged_qty > THRESHOLD]  -> approve (HUMAN_TASK, role TENANT_ADMIN, required_permission
                                          StockApprove, distinct_from ["inspect"]) -> writeoff
           [is_default]               -> writeoff
      writeoff (SUB_PROCESS definition_name stock_writeoff, the same six inputs, outputs: [])
      -> end
```

- Every EXCLUSIVE_GATEWAY with outgoing edges has an `is_default` edge (CHK-24, `graph.ex:65-67`); conditions
  are CEL (`check_cel_syntax/1`, `graph.ex:104`, `:547`).
- Because `inspect` carries `module_writes`, the parent is module-only by its own graph too (belt and braces
  with G-SUB-1). `prepare_writeoff` runs only when `damaged_qty > 0` would be wrong: it runs at every
  `inspect` completion, and with `damaged_qty = 0` it writes nothing (Q5 if the owner wants the draft kept).
- **Second condition, four-eyes.** The T-2843 record does not exist (its task folder has no design file and no
  run), so this follows the pattern already shipped: `distinct_from` on the approving HUMAN_TASK
  (`stock_opening`/`stock_quick_count` `approve`, pack.json `:482`, `:560`), checked per instance
  (`SeparationOfDuties.run_check/6` and `blocking_nodes/6`, `separation_of_duties.ex:241-275`), switchable per
  (definition name, node id) by `approval_rule_settings` (`approval_rule_setting.ex:1-10`; a new tenant
  defaults OFF, T-2391). ASSUMPTION: the threshold applies to `damaged_qty` (it approves the loss, not the
  receipt) and is a literal in the graph per pack version (Q2, Q3).
- Four-eyes across parent and child is NOT possible: `distinct_from` reads tasks of the same instance only,
  so the person who posts the receipt (child task) may also inspect. Q6.

**Start.** Module code only: the issue route of a receipt document flagged `inspection: true` starts
`stock_receive_inspect` instead of `stock_receipt` (`Posting.start/8`, `posting.ex:314-345`, with the same six
variables and `module_start: true`). No route starts it (G-SUB-1).

## 5. Permissions: parent vs children

| who | parent | receipt child | write-off child |
|---|---|---|---|
| start | module code at issue (document issue route's own permission); public start 404 after G-SUB-1 | parent activation; `:420` passes (same `owner_module`) | the same |
| human tasks | `inspect`: the role that receives goods (Q1); `approve`: TENANT_ADMIN + StockApprove + distinct_from inspect | `post`: TENANT_ADMIN + StockApprove (pack.json `:51-52`) | the same |
| start permission fence | `gate_start_permission/2` (`engine.ex:936-952`) also reads the children: no platform call, so no extra permission | - | - |

## 6. Compensation: the receipt posted, the write-off fails

| failure | what the engine does today | outcome |
|---|---|---|
| write-off post refused by the handler (409 `record_version_conflict`, 409 `master_inactive`, 422) | completion refused, nothing written, task stays pending (`handlers.ex:154-170`) | child ACTIVE, parent WAITING; fix the cause, complete again. No ERROR, no DLQ |
| write-off child cannot start (draft / `needs_reactivation` / missing input) | parent ERROR through `ExecutionError.append_multi/3` (`sub_process.ex:263-305`, `execution_error.ex:228-250`), a DLQ `event` row | `Dlq.retry/2` moves the row only; it does not resume an ERRORed instance (`dlq.ex:1-20`); operator cancels the parent and writes off by hand |
| write-off document cancelled | child cancelled; parent waits for ever (OQ-4) until G-SUB-6 | operator cancels the parent |

**Decision: no automatic reversal of the receipt.** The receipt and the damage are two true facts; the
ledger is append-only and a reversal is its own process with a person and a reason (`start_reversal/5`,
`posting.ex:270-312`). Until the write-off posts, the damaged goods are on hand, which is what happened.
A "plain failed parent with DLQ" is the model; the parent's ERROR is visible on the instance page. Q7 asks
whether the owner ever wants the reversal instead.

## 7. Version pinning of children

- The parent is pinned at its own start (snapshot). A child is LATE-bound: the active version of
  `definition_name` at the moment its node activates (`sub_process.ex:521-537`), snapshotted then
  (`create_child_snapshot/3`, `:540-545`); its pins resolve fresh (`resolve_child_pins/3`, `:504-512`).
- In-flight upgrade: an upgrade between the receipt and the write-off starts the NEW `stock_writeoff`.
  Parent and children ship in one pack version and `EnsureSeeds` activates every pristine draft together
  (`ensure_seeds.ex:15-25`), so a mix happens only across an upgrade in flight; acceptable.
- Early binding (R-Co's `child_definition_id`, req062 OQ-1, `sub_process.ex:36-55`) would be an engine
  change: Q8.

## 8. How the pack reaches QA and the fixture tenant

- Build: `generate_pack.exs` -> `pack.json`, stock version bump, permission matrix and pins as the domain
  skill lists. Merge to main -> auto-CD deploys QA (`cd.yml`).
- Tenants that already have stock: the module upgrade route (`authz_post "/:module_id/upgrade"`, module id `stock`,
  `tenant_modules.ex:83`, ModulesManage) runs `EnsureSeeds`: `stock_receive_inspect` has no row, so a stamped
  draft is created (`ensure_process_drafts/6`, `ensure_seeds.ex:189-215`) and activated by the system actor
  (no row ever activated, `:19-22`); the 10 existing definitions are untouched, running instances stay on
  their versions. New tenants: draft at install, activated lazily by G-SUB-5.
- Fixture tenant: `sss-rehearsal2` (the BP-01 dry-run tenant, `test/uat/processes/BP-01-receive-goods.json`
  `dry_run`, with its item/place/org unit/responsible ids), one of the smoke tenants
  (`project/scripts/uat_smoke.sh:65`, team repo: `qoimeks-qa2 sss-rehearsal2`). The upgrade on QA is an operator
  step after the deploy (never an in-change criterion).

## 9. SUB-5: the runner scenario (red first, 0 not run)

File `test/uat/processes/BP-SUB-01-receive-with-inspection.json`, shaped like BP-01. Expected values are
taken from the REAL BP-01 smoke run `state/uat-runs/smoke-T-2946-sss-rehearsal2/run.jsonl` (team repo)
(run `20261126T182620Z-bb928d`, build `cd43da9e`): `s1` 201 `state: draft`, `s2` 200 `state: issued`, `s3`
`POST /api/v1/tasks/<id>/complete` 200 after 1 poll, `s5` 200 `state: posted` with `entry_id`; cleanup
`/reverse` 200 then the reversal task 200. New values (inspect, write-off) have NO real source yet: the first
run is the red run whose `run.jsonl` sets them; until then they are written as `exists`/status only.

| step | actor | request | expect |
|---|---|---|---|
| s0 | storekeeper | GET balances (item, place, org unit, responsible) | 200, save `balance_before` |
| s1 | storekeeper | POST /modules/stock/documents `kind: receipt`, `inspection: true`, qty 5 | 201 `state: draft` |
| s2 | storekeeper | POST .../issue | 200 `state: issued` |
| s3 | admin | wait_task for_document, step `post` (receipt child), complete `{}` | 200 |
| s4 | admin | GET balances | quantity = balance_before + 5 |
| s5 | storekeeper | wait_task step `inspect`, complete `{"damaged_qty": 2}` | 200 |
| s5n | storekeeper | complete `inspect` of a second run with `{"damaged_qty": 1, "posting": {...}}` | 422 `output_refused` (G-SUB-2) |
| s6 | admin | wait_task step `post` of the write-off child, complete `{}` | 200 |
| s7 | admin | GET balances | quantity = balance_before + 5 - 2 |
| s8 | admin | POST /api/v1/instances `definition_name: stock_receive_inspect` with forged variables | 404 (G-SUB-1) |
| s9 | admin | threshold branch: a run with `damaged_qty` > THRESHOLD; `approve` by the inspector | 409/422 separation of duties; by a second admin 200 |
| cleanup | admin | reverse the write-off, then the receipt (BP-01 c1/c2 pattern) | 200 each, balance = balance_before |

The red run is the first run on a build WITHOUT the gap fixes: s8 and s5n must be red there (proof that
the scenario sees the gap). No step carries `blocked_by`; a step that cannot run is a failure, so "0 not
run" holds on the green run.

## 10. Long-term (owner's question, PM 13:55): does `:420` still have to hold after D-204?

After the D-204 conversion a module action is a catalogue function with a permission and the G2 rules
(decision 0094: the activator holds the permission, the start fence, the typed mapping of `reads`/`writes`,
the targets from start variables or an earlier step's output). Then the reason for `:420` (the targets come
from variables someone else set) is answered per call by the function's own checks. **Answer:** `:420` can
go for definitions that call functions, provided its replacement holds: (1) the function binds its target
to engine-owned data (the document id from the instance's own start event, as `check_instance` does), (2)
the start fence and the activation fence include the children's function permissions (`engine.ex:936-952`,
`definitions.ex:2014-2032`, already so for platform calls), (3) rule 1 of 0094 is widened from "platform
tenant" to "the module's tenant" for module functions. `:420` stays for definitions that keep
`module_writes`. No engine change before the owner's word.

## 11. (A) Cross-module composition (cmms parent -> assets child)

Today refused at `sub_process.ex:420` (different `owner_module`).

| option | what it needs | risk |
|---|---|---|
| (1) catalogue function `assets.commission` called by a `platform_call` step | D-204 conversion of commissioning; 0094 rule 1 widened; target bound to the work order's own start data | lowest: one write, one permission, checked by G2 |
| (2) sub-process with a replacement check for `:420` (the caller's authority covers the child's write targets) | a check that the parent module is allowed to write the child module's targets (a module-to-module grant table) + G-SUB-1/-2 for cross-module | broad: every assets target reachable from a cmms task form |
| (3) inline | - | **inlining postponed, D-207** |

**Recommendation: (1)** for atomic actions, (2) only if commissioning needs its own four-eyes inside the call
(see the table below).

## 12. (B) Inlining

inlining postponed, D-207

## 13. (C) The lightweight step: what becomes a function, what stays a sub-process

| action type | example | form | why |
|---|---|---|---|
| atomic post of an already issued document, no person inside | stock receipt / issue / write-off / transfer post; assets handover post | catalogue function (D-204) | one write, target = the issued document |
| create + issue a document from process data | `prepare_writeoff` (G-SUB-4) | catalogue function (or a module handler until D-204) | one transaction, target = this instance's own document |
| action with a person inside (approval, four-eyes, counting) | stock opening / quick count (`submit` + `approve`), assets commissioning with approval | sub-process | the human task and `distinct_from` live per instance |
| reversal | stock / assets reversal | sub-process | a person gives the reason; its own audit and cancel |
| maintenance work order | `maintenance_work` + `maintenance_close` | sub-process | two persons, own lifecycle |
| (any of the above as inline) | - | inlining postponed, D-207 | - |

## 14. Build tasks of the lane (for the PM to queue, in order)

1. G-SUB-1 + G-SUB-2 (engine, one task, security review): transitive module-only start and refused keys.
2. G-SUB-4 + G-SUB-3(b) (stock handler `prepare_writeoff` + the `HandlerWrites` create-and-issue API).
3. SUB-3: the parent in the stock pack, G-SUB-5 lazy activation, G-SUB-6 cancel from the top, issue flag
   `inspection`, version bump; the product design doc (section "Where it lands").
4. SUB-5: the scenario of section 9, red run then green run on `sss-rehearsal2` after the deploy and upgrade.

## 15. Owner questions (one line each)

- Q1: Which role completes `inspect`: the storekeeper who received, or a separate inspector role?
- Q2: Does the approval threshold apply to the damaged quantity (assumed) or to the received quantity?
- Q3: Is the threshold one value per pack version, or a tenant setting?
- Q4: Which `reason_code` does the automatic write-off carry (a new code "damaged on receipt", or the inspector picks one)?
- Q5: With `damaged_qty = 0`, is any record kept (an inspection note), or nothing?
- Q6: May the person who posts the receipt also inspect it (four-eyes across parent and child is not possible today)?
- Q7: When the write-off cannot post, is a failed parent the right end, or do you want the receipt reversed automatically?
- Q8: Should children be pinned to the version at parent start (an engine change), or keep the late binding?
- Q9: After D-204, may a tenant-made parent compose module functions under the checks of section 10?
- Q10: Cross-module (cmms -> assets): catalogue function (recommended) or a module-to-module grant for sub-processes?
