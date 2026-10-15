# GH #2587 / REQ-499 PR A: prerequisites for process-step entity writes (decision 0054)

Author: CODE-DESIGNER, 2026-10-15. Branch `feat/GH-2587-req499-pr-a-prerequisites`, from
`origin/main` `fe06bdd9`. Scope: issue #2587 "Group A: prerequisites that must land first" ONLY.
Group B (HUMAN_TASK path) and Group C (SERVICE_TASK path) are PR B and PR C (section 14).

Design only. Signatures, types, step lists and test briefs; no function bodies.

## Changelog

### Revision 1a (2026-10-15): CDV R1 applied during A1 implementation (ELIXIR-DEV)

| Id | Change | Where |
|---|---|---|
| CDV R1 | Missing signatures added: `VariableMerge.sys_key?/1 :: (term()) -> boolean()` and `sys_value?/1 :: (term()) -> boolean()`, total (never raise). Replay's `INSTANCE_SYS_VARIABLES_SET` clause checks every key/value with them before any `put_sys/3` call, so a malformed event is `{:invalid_sys_variables_event, id}` and never a raise (INV-8); `put_sys/3` uses the same two predicates. Unit cases: `"_sys"` -> false, `"x"` -> false, `"_sys.r.seq"` -> true; values `%{}` and `-1` -> false. | 2.1, 2.5 |
| A1 note | "fail_code" in D-A1.11 / 2.2 / 8 / 11 names the value `script_failure/7` records: the run's `detail` (`outcome_detail` on the dispatch row, `"detail"` in `SCRIPT_RUN_RECORDED`), i.e. the field that already carried `variable_schema_rejected`; the type union at `script_task_dispatcher.ex:97` is `@type detail`. The SCRIPT_RUN_RECORDED `fail_code` key (the script's declared fail code) stays `null` for these runs. | D-A1.11 |
| A1 note | `Letflow.Engine.Expr` resolves `variables._sys.r.seq` as the NESTED path `_sys` -> `r` -> `seq`, so a gateway condition cannot read a flat `"_sys.r.seq"` key today. A1's replay test therefore proves the SYS fold precedes the completion fold and that the post-completion gateway takes the live edge (on an ordinary key); a gateway that reads a reserved key needs an `Expr` decision before PR B relies on one. | 11 A1 row, 15 |
| SEC F2 (A1 gate) | SERVICE_TASK HTTP body with a reserved key: was a rollback leaving the dispatch row `advanced` (silent stall); now a terminal instance ERROR `reserved_variable_key` (field affected, no value) in the open transaction, dispatch row stays `advanced`. | 2.2, 8 |
| SEC F1 / TDV F1-F4 / REVIEWER F2-F3 (A1 gate) | Static R3 also flags atom literals and `<>` chains with a literal prefix head; R4 scans `def` and `defp` heads; test controls added; "fail_code" wording replaced by `detail` (CDV-7, D-A1.11, 2.2, 8, 11, 13); PR B carry-overs recorded in 15. | 2.6, 11, 15 |

### Revision 1 (2026-10-15): CDV FAIL (2 blockers), SECURITY PASS_WITH_FINDINGS, supervisor rulings

| Id | Change | Where |
|---|---|---|
| CDV-1 | Lua no longer uses any literal: `emit_event` refuses every event type reconstruction folds, read from the new `Reconstruction.folded_event_types/0` (which holds the literals). The literal allow-list stays `variable_merge.ex`, `reconstruction.ex`, `tenant_provisioning.ex` in A1; A3 adds `entity_port.ex`. `platform.ex` is never on it. | D-A1.9, 2.5, 2.6, 2.7 |
| CDV-2 | The "replay invokes no EntityPort callback" case moved out of A1 to PR B (AC 15, Group B); A1's reconstruction test asserts only the `put_sys` fold and the no-state clause. | 11 A1 row, 15 |
| CDV-3 / SEC F1 | Sub-process OUTPUT with no interface: `build_parent_merge_variables(nil, _)` result goes through `drop_reserved/1`; ERROR only when an explicit interface `outputs` entry names a reserved key. Activation-time refusal of interface inputs AND outputs naming `_sys` added to follow-ups. | D-A1.5, D-A1.6, 2.2, 11, 15 |
| CDV-4 | Real recheck in PR A: step `{:line, i, :recheck_definition}` after the namespaced append steps (sequence lock held since `{:line, i, :assign_sequence}`), before `{:line, i, :upsert_record_latest}`; re-resolves the active definition, requires the same row id, repeats `check_write_authority/3`, returns the row for PR B. | D-A2.15, 3.3, 11 |
| CDV-5 / OQ-3 | Closed: adapter `EntityPortImpl` kept; AC reading for the A3 PR body stated. | D-A3.6, 16 |
| CDV-6 | A2 happy-path test pre-creates synthetic instances with `EntityTypeInstance.get_or_create/2` (`prepare/2` is A3). | 11 A2 row |
| CDV-7 | D-A1.11 corrected: the script rejection clause passes the merge reason through as the run's `detail` (`outcome_detail` on the dispatch row, `"detail"` in SCRIPT_RUN_RECORDED; revision 1a, REVIEWER F2), so a reserved key is recorded `output_invalid` / `reserved_variable_key` (`detail` is a free string in the SCRIPT_RUN_RECORDED schema; the ` detail` union in `script_task_dispatcher.ex:97` gains the atom; the event's `fail_code` key stays `null`). | D-A1.11, 2.2 |
| CDV-8 | PR B test note: `SET LOCAL` inside a sandbox savepoint persists for the rest of the test's outer transaction. | 4.3, 15 |
| SEC F2 | Step-key regex anchored `\A...\z`. | D-A2.3, 3.3 |
| SEC F3 | Structural: `EventStore.append/2`, `append_platform_event/2` and `append_multi/3` WITHOUT `:step_namespace` refuse a key starting `sys:step:` (`{:error, :reserved_idempotency_key}`); the caller test also allow-lists `step_namespace:` to `records.ex`. | D-A2.16, 3.1, 3.4, I-5 |
| SEC F4 | Adopted in A1: Lua refuses every reconstruction-folded type (existing Lua tests register their own `gh2550_evt*` / `evt` types, so none breaks). | D-A1.9, 2.7 |
| SEC F5 | Static test also flags binary literals starting `"_sys"` in `lib/**` outside `variable_merge.ex`. | 2.6 |
| SEC F6 | A4 PR body records a read-only count of definitions carrying `writable_by_process`; query given; must be zero. | 5.4 |
| SEC F7 | PR B filters line types through `ProcessWritable.writable?/1` before `prepare/2`. | 15 |
| SEC F8 | Static assertion: `script_task_dispatcher.ex` and `lib/letflow/scripts/**` call only `prefetch/3` on the port. | 4.4, 11 A3 row |
| OQ-1 | CLOSED: accepted; QA count = 0 for all 6 tenants (record `runs/2026-10-15-inv-sys-vars-count-001`), carried in A1's PR body; the same query (projections AND completion payloads, incl. `$ref` payloads) is a GATE re-run before PR B; any instance found is cancelled or repaired first. | 14, 15, 16 |
| OQ-2 | CLOSED (interim, fail closed): stable rule code whose message names the matched rule/pattern; list documented in the module guide; replaced by type classification under GH #2618. | D-A4.5, 5.2, 5.4, 9.2, 15, 16 |
| OQ-4 | CLOSED: 7c-2 owner is letflow-4. | 16 |
| OQ-5 | CLOSED: packs refuse the flag; an admin sets it after install under `:EntitiesDefinitionsWrite`; pack path tracked by GH #2619. | D-A4.6, 5.4, 15, 16 |

## 0. Sources and what this design was checked against

| Source | State used |
|---|---|
| Decision 0054 | `main` text at `fe06bdd9`. The D4 open-point-2 correction (option A) and its "Correction" paragraph ARE on `main` (commit `75724bbb`, PR #2591, "0054 open-point-2 ruling corrected to option A"); the D9 namespacing amendment is on `main` (`b65f7378`, #2598). Commit `93886350` named by the issue is NOT in this repository (`git cat-file -t 93886350` -> "Not a valid object name" in both the worktree and the main checkout; `git log --all` has no such id). This design is written against `main`'s 0054 text, which already carries the corrected D4 ruling the issue says 93886350 held, so the issue's gate "the D4 corrected ruling must be on main before PR A merges" is satisfied. |
| GH #2583 design `gh2583-records-managed-type-guard.md` section 8.2 | BINDING contract for `Records.command_multi/3`. #2583 is MERGED: `records.ex:272,348,405` call `check_write_authority/3`, defined `records.ex:1066-1073`. |
| GH #2550 | MERGED: `Letflow.Idempotency` (`lib/letflow/idempotency.ex`), `@reserved_prefixes ["sys:"]` at `:59`. Not re-implemented here. |
| GH #2534 7c-2 (#2607) | MERGED: `Letflow.Engine.ScriptReadPort` (`lib/letflow/engine/script_read_port.ex`), impl `Letflow.Entities.ScriptReads`, `config :letflow, :script_read_port` (`config/config.exs:116`), `check_boundaries` Rule 6 (`lib/mix/tasks/letflow.check_boundaries.ex:285-290`). |

### 0.1 Drift of the issue's file:line facts (issue verified on `f3b512d1`; re-verified on `fe06bdd9`)

| Issue claim | Now | Note |
|---|---|---|
| `Engine.complete_task/3` `engine.ex:2360` | `:2476` | moved |
| `run_complete_task/6` `:2411` | `:2527` | moved |
| completion `Repo.transaction()` `:2520`, blanket rescue `:2524-2525` | `:2636`, `:2641` | moved |
| service result merge `VariableMerge.merge(seed_state.variables, decoded_body, nil)` `:3691` | `:3811`, inside `advance_service_task_dispatch/4` (`:3798`) | moved |
| `advance_after_service_task_outcome/4` `:3653` | `:3773` | moved |
| `do_persist_service_task_advance/10` `:3914`, nested `repo.transaction(multi)` `:4043` | `:4100`, `:4228` | moved |
| form-output merge `engine.ex:4306` | `merge_output_variables/8` `:4664`, `apply_variable_merge/6` `:4779` | moved; REQ-460 now refuses schema rejections BEFORE merge (`:4598-4612`) |
| (not in issue) script output merge (7c, 0053 hook 1) | `apply_locked_script_result/5`, `VariableMerge.merge(..., output, validations)` `:4409` | NEW source since the record; covered, section 2.3 |
| `Records.create_record/2` `records.ex:233`, `update` `:294`, `delete` `:343` | `/3` heads `:263`, `:339`, `:400`; `/2` delegates `:258`, `:334`, `:395` | #2583 added `/3` |
| `run_command/2` `:374-392` | `:432-442`, Multi built in `append_command/4` `:455-472` | split |
| `interpret_result/3` `:723`, duplicate-as-success `:727-735` | `:797-825`, duplicate clause `:803-809` | moved |
| `expected_seq/1` `:473` | `:549-562` | moved |
| `EntityTypeInstance.get_or_create/2` `entity_type_instance.ex:93`, eager at `records.ex:375` | `:93` unchanged; eager at `records.ex:433` | |
| `EventStore.append_multi/3` `event_store.ex:308`, fixed names | `:308`; names fixed in `build_multi_composable/2` `:535-545`; steps read each other's results by FIXED key (`insert_event/3` `:703` reads `:assign_sequence`; `store_oversized_payload/3` `:744` reads `:insert_event`; `update_projection/3` `:766-771` reads `:assign_sequence` and `:active_instance_guard`) | design consequence, section 5.1 |
| `@payload_inline_max_bytes` `:123`, idempotency `conflict_target` `:664`, `platform_actor_id/0` `:891` | unchanged | |
| `PinResolver.validate_initial_variables/2` `pin_resolver.ex:504-514` | `:587-602`; the `nil`-schema clause `:593-595` returns `:ok` unconditionally | both clauses need the refusal |
| `PinRebind.rebind_pins/3` `:163` | not touched by PR A | |
| `reconstruction.ex:594,678` | merges at `:597` (TASK_COMPLETED), `:681` (SUB_PROCESS_COMPLETED), `:778` (shared SERVICE/SCRIPT_TASK_COMPLETED fold); unknown event type is an ERROR (`:767-769`) | a new instance event type MUST get a replay clause |
| `sub_process.ex` `merge/3` call | `:847`; `else` clause `:934-946` matches ONLY reason `:variable_schema_rejected` | must widen |
| exam callers `certificate.ex:335`, `anti_cheat.ex:258`, `session.ex:1064,1263,1328` | unchanged | not edited by PR A |
| EE-12 sentences `engine.ex:287-289, :324, :333, :348-353, :360-363` | unchanged lines | |

### 0.2 Facts established for open "NOT VERIFIED" items

* **Service-task `{:rejected, ...}` branch fails the advance (VERIFIED).** `engine.ex:3828-3829` returns
  `{:error, {:variable_merge_rejected, rejection}}`; `advance_after_service_task_outcome/4`
  `:3774-3779` calls `repo.rollback(reason)`; `ServiceTaskDispatcher` classifies it
  `:variable_merge_rejected` (`service_task_dispatcher.ex:654`), logs id/tag only and writes the
  best-effort advance-failure audit (`:631-644`). No variable is written, the token does not move,
  the dispatch row stays `advanced` (ISS-0928's documented at-most-once posture). The reserved-key
  rejection takes this same branch unchanged.
* **Admin variable-patch endpoint: NONE on `main`.** `git grep` over `lib/letflow/routers` and
  `lib/letflow/api` for any route path containing `variable`/`vars`: no hit. No direct writer of
  `instance_projections.variables` outside the engine merge/transition paths was found
  (`Map.merge`/`Map.put` on `variables` in `engine.ex`, `engine/`, `routers/`: only
  `form_expression_reevaluation.ex:224`, an evaluation-only view). Nothing to route through
  `merge/3`; the AC's conditional clause is vacuous and the test brief records the grep.
* **Lua `platform.emit_event/3` can append an ARBITRARY event type to an instance stream**
  (`lib/letflow/engine/lua/platform.ex:810-848`). The Lua executor is unwired for node dispatch
  today (`lib/letflow/modules/exam/scoring.ex:23`), so no tenant input reaches it, but replay applies
  the new `_sys` event kind through the engine-only writer, so the event type itself must be
  engine-only (D-A1.9).
* **Lua `write_variable/2`** stages into a process-dictionary buffer read only by
  `take_staged_writes/0`, which has NO caller in `lib/` (`platform.ex:171,431`). Not a source today;
  the first caller must go through `merge/3` (recorded as an invariant, section 12).
* **Sub-process child START variables do not pass `PinResolver`.** `SubProcess.build_child_initial_variables/2`
  (`sub_process.ex:130-134`) gives the child the WHOLE parent variable map when the node has no
  interface (`:132`). Parent `_sys.` values would otherwise be inherited (D-A1.6).

## 1. Decisions (one-line rationale each)

### Item 1-2: `_sys` namespace (PR A1)

* **D-A1.1** The reserved set is exactly the key `"_sys"` and every key beginning `"_sys."`, compared on the string form of a TOP-LEVEL key (atom keys via `Atom.to_string/1`); nested keys are never reserved. Rationale: 0054 D1a.1 flat namespace; atom keys appear in in-process maps and must not slip through.
* **D-A1.2** `VariableMerge.merge/3` checks reserved keys FIRST, before `variable_validations`, and returns `{:rejected, current_variables, [{:execution_error, key, nil, :reserved_variable_key, []}]}` for the first reserved key in sorted order. Rationale: 0054 D1a.2 central choke point; same shape as a schema rejection; `rejected_value` is `nil` so an attacker-supplied value is never recorded in an error event, detail or log (INV-2/INV-4 hygiene).
* **D-A1.3** HUMAN_TASK form output: `merge_output_variables/8` refuses a reserved key in the CORRECTED output as `{:error, {:completion_refused, {:output_refused, [], reserved_keys}}}` BEFORE the variable-schema read, so the completion is a retryable 422 with nothing written. Rationale: REQ-460's established caller-error posture; letting merge/3 reject it would put the instance into ERROR, a completer-triggered DoS. merge/3 still refuses as the backstop.
* **D-A1.4** Every caller that pattern-matches `merge/3`'s rejection on reason `:variable_schema_rejected` is widened to the new reason: `apply_variable_merge/6` (`engine.ex:4779`), `SubProcess` `else` (`sub_process.ex:934`), reconstruction folds (`:632`, `:698`, `:790`). Rationale: today those clauses would raise `CaseClauseError`/`WithClauseError` on the new reason (INV-8).
* **D-A1.5** Sub-process OUTPUT (revision 1, CDV-3 / SEC F1): with NO interface, `build_parent_merge_variables(nil, child_variables)` (`sub_process.ex:156`) returns `drop_reserved(child_variables)`, so a child's own engine-written `_sys.` values never reach the parent and a no-interface child never errors for them. With an explicit interface whose `outputs` names a reserved key, the mapped key reaches `merge/3`, which refuses it -> instance ERROR with `error_type: :reserved_variable_key`, `affected: {:field, key}`, `details: %{}` (no value). Rationale: the no-interface copy is not a designer choice and must not wedge every parent of a child that wrote entity lines; an explicit mapping onto `_sys` is a definition error, routed like other sub-process merge rejections (REQ-062); `ExecutionError.error_type()` is an open union.
* **D-A1.6** Sub-process child START variables: `build_child_initial_variables/2` drops every reserved key from its RESULT (both the no-interface copy and a mapped interface). Rationale: `_sys.` values are legitimate only for the instance that wrote them (0054 D1a.4 "same instance"); stripping, not refusing, because a parent that legitimately holds `_sys.` values must still be able to start children. (Asymmetry with D-A1.5 is deliberate: an input mapping onto `_sys` is stripped at run time because refusing would fail the PARENT's step; activation-time refusal of both directions is a follow-up, section 15.)
* **D-A1.7** Start variables: `PinResolver.validate_initial_variables/2` (BOTH clauses, including the `nil`-schema one) returns `{:error, {:variable_schema_violation, failures}}` with one `%ValidationFailure{field_path: "/" <> escaped_key, constraint: "reserved_variable_key", actual: nil}` per reserved key, sorted, before any schema check. Rationale: AC "same reason code and shape as a schema rejection"; the start route already renders that shape as 422 (`routers/instances.ex:637`).
* **D-A1.8** Engine-only writer `VariableMerge.put_sys/3` plus a static caller allow-list test; reconstruction is its only PR A caller. Rationale: 0054 D1a.3; a static allow-list is the project's established pattern (`managed_types_callers_test.exs`, `check_scope_node_paths_writers`).
* **D-A1.9** New engine event kind `INSTANCE_SYS_VARIABLES_SET`. Lua `emit_event` refuses, with its existing `"invalid_arguments"` error, EVERY event type that reconstruction folds (revision 1, SEC F4): the list is `Reconstruction.folded_event_types/0` (section 2.5), so Lua holds no literal (CDV-1). Rationale: replay applies these events as engine facts (and the SYS one through `put_sys/3`), so any of them appended by a script would forge state; the Lua path is unwired for node dispatch today and every existing emit_event test registers its own fixture type (`client_key_namespace_test.exs:285-300` `gh2550_evt*`, `platform_test.exs:1551ff` its own type, `'evt'`), so nothing breaks.
* **D-A1.10** Ordering rule for PR B/C (recorded now because replay depends on it): an `INSTANCE_SYS_VARIABLES_SET` event is appended in the SAME transaction and BEFORE the completion event of the step that produced it (`TASK_COMPLETED` / `SERVICE_TASK_COMPLETED`). Rationale: reconstruction folds events in sequence order and gateway evaluation inside the completion fold may read `_sys.` keys; output keys and `_sys.` keys are disjoint (D-A1.2/3), so applying `_sys.` first is equivalent to the live order.
* **D-A1.11** (revision 1, CDV-7) The 7c script output route (`engine.ex:4409`) is covered by D-A1.2. Today its reason-generic `{:rejected, _unchanged_variables, _events}` clause calls `script_failure(..., :output_invalid, :variable_schema_rejected, ...)`, which would MISLABEL a reserved key as a schema rejection. Change: the clause matches `{:rejected, _, [{:execution_error, _key, _value, reason, _failures}]}` and passes `reason` (`:variable_schema_rejected` or `:reserved_variable_key`) as the run's `detail` (the field that already carried `variable_schema_rejected`; revision 1a); the outcome stays `output_invalid` and the event's `fail_code` key stays `null`. `ScriptTaskDispatcher`'s ` detail` union (`script_task_dispatcher.ex:97`) gains `:reserved_variable_key`. Rationale: SCRIPT_RUN_RECORDED's `outcome` is a closed enum (unchanged) but `detail` is `["string", "null"]`, so the accurate code needs no schema change; the rejected value is still not recorded (C16).

### Item 3: `sys:step:` server key and `source` (PR A2)

* **D-A2.1** Mechanism for (a): the three single-command entry points (`create_record/2,3`, `update_record/2,3`, `delete_record/2,3`) REFUSE an `idempotency_key` whose exact bytes start with `"sys:step:"` with `{:error, :reserved_idempotency_key}`, before any query; `command_multi/3` is the ONLY Records path that accepts such a key, and a static test restricts `command_multi` callers to `lib/letflow/entities/step_writes.ex`. Rationale: no runtime capability token, no process-dictionary flag; the bypass is a separate function whose reachability is a reviewed, CI-enforced allow-list (same model as #2583 R1).
* **D-A2.2** Only the `sys:step:` prefix is refused; `certificate:issue:`, `entities-record-import:`, `req345-seed-` and every other raw server key keep working. Rationale: issue text "must refuse only the `sys:step:` prefix"; #2550 keeps `sys:` reserved for client keys at the entry points.
* **D-A2.3** `command_multi/3` REQUIRES its key to match `\Asys:step:[A-Za-z0-9:_.-]+\z` (anchored, exact bytes, at most 255 bytes; revision 1 SEC F2) and refuses anything else with `{:error, :invalid_step_key}`. Rationale: 0054 D9.2 closed charset for server step keys; makes `command_multi` useless for squatting any other server family.
* **D-A2.4** (b) `source`: the single-command entry points refuse attrs carrying a top-level `:source`, `"source"`, `:metadata` or `"metadata"` key with `{:error, :reserved_attribute}`, before any query. A record FIELD named `source` inside `field_values` is unaffected. Rationale: 0054 D10 "Records.* refuses any client-supplied source"; today no caller passes either key (grep of all 13 call sites), so nothing breaks.
* **D-A2.5** The process-step `source` travels as flat event-metadata keys `"source.kind"`, `"source.instance_id"`, `"source.task_id"` or `"source.dispatch_id"`, `"source.node_id"`, `"source.definition_id"`, `"source.definition_version"`, `"source.line_index"`, `"source.activator_id"`, set only by `command_multi/3`. Rationale: `EventStore.validate_metadata/1` (`event_store.ex:494-521`) accepts only a flat string->string map of at most 50 entries; flat keys need no EventStore change.
* **D-A2.6** `sys:step:` constant lives in `Records` (`step_key_prefix/0`), not in `Letflow.Idempotency`. Rationale: `Idempotency` already aliases `Records` (`idempotency.ex:44`); the reverse dependency would make a compile-time cycle.

### Item 4: `command_multi/3`, `interpret_in_multi/1`, `append_multi/3` namespace (PR A2)

* **D-A2.7** `EventStore.append_multi/3` gains the additive option `step_namespace: {:line, non_neg_integer()}`; when present every step it adds is named `{:line, i, step}` and each step reads its sibling results through a namespace-local view of `changes`; absent, the Multi is byte-identical to today. Rationale: 0054 D2.1; the steps read each other by fixed key (0.1), so renaming alone would break `insert_event`/`update_projection`.
* **D-A2.8** The option key is `:step_namespace`, not `:prefix`. Rationale: `:prefix` already means the tenant schema in `opts` (`event_store.ex:309`); reusing the word would invite a schema-prefix mix-up (INV-1).
* **D-A2.9** `command_multi(command, prefix, authority)`: authority LAST and positional, head guard `is_binary(prefix) and is_authority(authority)`, per-line `check_write_authority/3` right after `fetch_active_definition/2`, zero extra queries. Rationale: binding #2583 section 8.2 items 1-2.
* **D-A2.10** `command_multi/3` supports `kind: :create` only in PR A; `:update`/`:delete` return `{:error, {:command_kind_not_supported, kind}}` with no query. Rationale: 0054 D1a.4 ruling (MVP create-only on append-only types); lazy update/delete row reads under lock are not needed by any PR B/C line and would be untested surface.
* **D-A2.11** `command_multi/3` never calls `EntityTypeInstance.get_or_create/2`; it resolves the synthetic instance with a new READ-ONLY `EntityTypeInstance.fetch_instance_id/2` and refuses `{:error, {:entity_type_instance_missing, entity_type}}` when `prepare/2` did not run. Rationale: 0054 D2.3 (no eager insert under the instance locks) without trusting a caller-supplied stream id.
* **D-A2.12** `command_multi/3` returns a NEW Multi (it takes none); the caller composes it (`Multi.append/2`, or `Multi.merge/2` inside the completion transaction in PR B). Rationale: the AC's spec `{:ok, Multi.t()} | {:error, term()}`; composition is the caller's concern.
* **D-A2.13** `interpret_in_multi/1` maps `{:error, {:line, i, step}, reason, _}` to `{:entity_write_refused, i, code}` for refusals and `{:entity_write_failed, i, step}` for internal faults, `:not_a_line_failure` otherwise; it has no success clause at all. Rationale: 0054 D2.2/D9 (a duplicate is `idempotency_conflict`); internal faults stay out of D8's closed refusal-code set so no new public code is invented.
* **D-A2.15** (revision 1, CDV-4) Definition recheck under the type lock is REAL in PR A: `command_multi/3` adds `{:line, i, :recheck_definition}` after the namespaced `append_multi` steps (the type's `instance_sequences` row is locked from `{:line, i, :assign_sequence}` to commit) and before `{:line, i, :upsert_record_latest}`. It re-resolves the active definition (one query), refuses `{:definition_changed, entity_type}` when the row id differs from the build-time row, repeats `check_write_authority/3` on the re-read row, and returns `{:ok, EntityDefinition.t()}` so PR B's run-time `writable_by_process` check reads this same row. It cannot sit directly after `:assign_sequence` because `append_multi/3` emits its steps as one contiguous block; any later point still holds the lock. Rationale: #2583 section 8.2 item 2 ("if it re-reads under lock it calls the check again"). Stated limit: definition activation does not take the type sequence row, so the recheck NARROWS the build-to-commit window to the line's own lock span; it does not serialise against activation.
* **D-A2.16** (revision 1, SEC F3) Structural I-5: `EventStore.append/2`, `append_platform_event/2` and `append_multi/3` called WITHOUT `:step_namespace` refuse an `idempotency_key` starting `sys:step:` with `{:error, :reserved_idempotency_key}` before any query; only a namespaced `append_multi/3` accepts it, and the only `step_namespace:` user is `records.ex` (static, 3.4). Rationale: the reservation then holds for every EventStore writer, not only Records' entry points; no existing writer produces `sys:step:` (`Idempotency` moduledoc `:58`).
* **D-A2.14** One public pure mapper `Records.classify_step_error/1` (reason -> `{:refused, code} | :internal`) is shared by `interpret_in_multi/1` and by PR B's mapping of `command_multi/3` build errors; build errors surface inside a Multi under the reserved step name `{:line, i, :build}`. Rationale: one mapping table for INV-5 (`:entity_type_managed`, `{:record_not_found, _}` -> `write_not_permitted`).

### Item 5: pre-transaction `get_or_create` (PR A3)

* **D-A3.1** `Letflow.Entities.StepWrites.prepare/2` runs ONE short transaction for the distinct line types (sorted ascending by byte order), first statements `SET LOCAL lock_timeout = '2s'` and `SET LOCAL statement_timeout = '2s'`, then `get_or_create/2` per type with an ACTIVE definition; it is wrapped by a rescue of exactly the contention exceptions, mapped to `{:error, :entity_write_contention}`. Rationale: 0054 D3 step 0 and BA open-point-4 numbers; one transaction for all types keeps one bounded wait and a deterministic lock order.
* **D-A3.2** `prepare/2` skips (does not create) a type with no active definition. Rationale: no junk synthetic instances from a hand-edited snapshot; the line is refused later by `command_multi/3` (`entity_type_inactive`), keeping refusal mapping in one place.
* **D-A3.3** `prepare/2` refuses to run inside an open transaction (`Repo.in_transaction?/0` true) with `{:error, :prepare_inside_transaction}`. Rationale: a `SET LOCAL` inside a caller's transaction leaks into the rest of it (the reason `ScopeNodePaths` sets none, `scope_node_paths.ex` moduledoc "Lock waits").
* **D-A3.4** Where it lives in PR A: `StepWrites` exists in PR A as the port's write half with `prepare/2` complete and `multi/3`/`validate_lines/2` FAIL-CLOSED (any non-empty line list refused); nothing in the engine calls them until PR B. Rationale: issue's PR A list ("StepWrites skeleton with prepare/2"); fail-closed stubs cannot be reached into a write.

### Item 6: one `Letflow.Engine.EntityPort` (PR A3)

* **D-A3.5** `EntityPort` SUBSUMES `ScriptReadPort`: one behaviour with the read callback `prefetch/3` (contract moved verbatim) and the write callbacks `multi/3`, `validate_lines/2`, `prepare/2`; `ScriptReadPort` is deleted. Rationale: 0054 open point 8 RESOLVED "one behaviour ... one injected implementation, one config key, one check_boundaries allowance"; coexistence would be two ports and two config keys, the exact outcome the ruling rejected.
* **D-A3.6** One injected implementation `Letflow.Entities.EntityPortImpl` (`@behaviour Letflow.Engine.EntityPort`), delegating `prefetch/3` to `ScriptReads` and the write callbacks to `StepWrites`; one config key `:entity_port` replaces `:script_read_port`. Rationale: one injection point as ruled, while `ScriptReads` and `StepWrites` keep single responsibilities. OQ-3 CLOSED (revision 1, gates' preference). AC reading for the A3 PR body, verbatim: "The AC names `Letflow.Entities.StepWrites` as the one injected implementation. The injected module is `Letflow.Entities.EntityPortImpl`, a delegating adapter whose three write callbacks delegate to `StepWrites` and whose read callback delegates to `ScriptReads`; there is still exactly one behaviour, one injected module, one config key (`:entity_port`) and one boundary rule."
* **D-A3.7** `EntityPort.impl/0` is the single reader of `Application.fetch_env!(:letflow, :entity_port)`. Rationale: one config-read site, asserted by the existing check_boundaries test (`test/mix/tasks/letflow.check_boundaries_test.exs:381`).
* **D-A3.8** `check_boundaries` Rule 6 keeps its single row (direct edges, engine -> entities forbidden); only the reason text changes to name `Letflow.Engine.EntityPort`. Rationale: config injection is not a file edge, so no new allowance is needed; Rule 6 stays green by construction.
* **D-A3.9** EE-12 amendment ships in A3 (engine.ex diff = only the five sentences in A3). Rationale: AC "diff of engine.ex shows only those sentences" is checkable only in a PR whose other engine.ex edits are zero; A1 edits engine.ex code.

### Item 7: event types (PR A1)

* **D-A1.12** `INSTANCE_SYS_VARIABLES_SET` and `TASK_ENTITY_WRITES_APPLIED` are appended to `@platform_event_type_seed_attrs` (`tenant_provisioning.ex`), schema_version 1, `additionalProperties: false`, every key required; existing tenants get them at the next boot replay. Rationale: the 7c-1 precedent (`gh2534-7c-script-handler.md` sections 0.3, 6); no migration needed.
* **D-A1.13** Reconstruction gains a clause for each: `INSTANCE_SYS_VARIABLES_SET` applies its values through `put_sys/3`; `TASK_ENTITY_WRITES_APPLIED` changes no state. Rationale: `apply_event/4`'s catch-all returns `{:unrecognized_event_type, _, _}` (`reconstruction.ex:767-769`), so an unregistered replay clause would break every rebuild of an instance with entity writes; D11 replay never re-executes a write.

### Item 8: `writable_by_process` (PR A4)

* **D-A4.1** `writable_by_process` is an optional top-level boolean of the entity definition DOCUMENT (`definition_json`), validated like `append_only` (`:malformed` at `[:writable_by_process]` for a non-boolean). Rationale: AC "a boolean on the entity type definition"; the `append_only` precedent (GH #2529); no table change.
* **D-A4.2** It is part of the logical shape (`Shape.logical_shape_of/1` drops only `display_name`/`description`), so adopting it is a new version to activate, exactly like `append_only`. Rationale: consistency with the precedent; a policy flag that silently changes without a version would bypass activation review.
* **D-A4.3** Setting it to `true` is permitted only through `POST /entities/definitions` + `POST /entities/definitions/:name/activate`, both gated `:EntitiesDefinitionsWrite` (`routers/entities.ex:270,274`); the router's `build_definition_document/1` forwards the key. Rationale: AC; no new permission (INV-10 classification unchanged).
* **D-A4.4** The refusal lives in `Definitions.create_definition/3` (after `ManagedTypes.check_create/3` and `Validator.validate/1`), delegated to a new pure module `Letflow.Entities.ProcessWritable`, answering `{:error, {:validation, [violation]}}` (the router's existing 422). Rationale: AC "refusal lives in the type-definition write path, not the UI"; the existing error shape needs no router render change.
* **D-A4.5** Refused categories: (i) a managed type (the `check_create/3` stamp is non-nil); (ii) org types: name `org_*`; any type feeding `scope_node_paths` is written only by the org module (REQ-495, not built) whose types are managed, so (i) and (ii) cover it; (iii) user/role-adjacent and (iv) attachment-metadata types by a CLOSED name list (section 9.2). Rationale: no metadata classifies types today; a fail-closed name rule plus managed_by is the only enforceable form. Ruled (OQ-2): INTERIM, fail closed; the refusal is the stable rule `:writable_by_process_not_permitted` whose message NAMES the matched rule (managed, or the exact denied prefix/name), so a false positive such as `user_feedback` explains itself; the list is documented in the module guide (5.2); GH #2618 replaces the list with a type-classification mechanism, and the A4 PR body records that.
* **D-A4.6** Solution-pack installs (`POST /solution-packs/install`, `:DefinitionsCreate`) REFUSE an entity definition carrying `writable_by_process: true`. Rationale: the pack path is gated by a different permission, so allowing it would let a `:DefinitionsCreate`-only principal set the flag. Ruled (OQ-5): accepted; until GH #2619 builds a reviewed pack path to a process-writable unmanaged type, an admin sets the flag after install by creating and activating a new version under `:EntitiesDefinitionsWrite`.

### Item 9: EE-12 (PR A3): exact text in section 10.

## 2. PR A1: `_sys` namespace, `put_sys`, event kinds

### 2.1 `Letflow.Engine.VariableMerge` (`lib/letflow/engine/variable_merge.ex`)

Types (changed / new):

```
@type execution_error_event ::
        {:execution_error, key :: String.t(), rejected_value :: term(),
         reason :: :variable_schema_rejected, failures :: [ValidationFailure.t()]}
        | {:execution_error, key :: String.t(), rejected_value :: nil,
           reason :: :reserved_variable_key, failures :: []}

@type sys_key :: String.t()          # "_sys." <> name, name =~ ~r/\A[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*\z/, total <= 160 bytes
@type sys_value :: String.t() | non_neg_integer()
```

New / changed functions:

```
@spec reserved_key?(term()) :: boolean()
# true iff the string form of a binary or atom key is "_sys" or starts with "_sys."; false for any other term.

@spec reserved_keys(map()) :: [String.t()]
# the TOP-LEVEL reserved keys of the map, as strings, sorted ascending; [] when none. Pure.

@spec drop_reserved(map()) :: map()
# the map without its top-level reserved keys. Pure. Used by SubProcess (D-A1.6).

@spec merge(map(), map(), variable_validations() | nil) :: merge_result()
# NEW step 0: if reserved_keys(incoming) != [] -> {:rejected, current, [{:execution_error, k, nil, :reserved_variable_key, []}]}
# with k = first of reserved_keys(incoming); no validation outcome consulted; no key applied. Steps 1-5 unchanged.

@spec sys_key?(term()) :: boolean()
# (revision 1a, CDV R1) true iff a binary <= 160 bytes of "_sys." <> name matching the sys_key() pattern;
# the bare "_sys" is false. Total: never raises.

@spec sys_value?(term()) :: boolean()
# (revision 1a, CDV R1) true iff a binary or a non-negative integer. Total: never raises.

@spec put_sys(variables :: map(), key :: sys_key(), value :: sys_value()) :: map()
# the ONLY function that sets a reserved key. Raises FunctionClauseError when key is not a sys_key()
# (bare "_sys" included) or value is not a sys_value() (programmer error: callers are allow-listed, 2.6).

@spec sys_event_type() :: String.t()     # "INSTANCE_SYS_VARIABLES_SET"
```

Moduledoc: new section "Reserved `_sys` namespace (decision 0054 D1a, GH #2587)". Purity recipe unchanged
(no new forbidden call). `put_sys/3`'s `@doc` states it must never receive request, form, HTTP
response, start-input, message or script data.

### 2.2 Sources

| Source | Site | Behaviour |
|---|---|---|
| HUMAN_TASK form output | `Engine.merge_output_variables/8` (`engine.ex:4664`) | NEW first check on the corrected `output_variables`: `VariableMerge.reserved_keys/1` non-empty -> `{:error, {:completion_refused, {:output_refused, [], reserved}}}` before `VariableSchema.variable_validations/5`. Public result `{:error, {:output_refused, %{missing_keys: [], rejected_keys: reserved}}}` (existing member of `complete_error`, `engine.ex:2411`); existing `task.completion_refused` audit (key names only). |
| | `apply_variable_merge/6` (`:4779`) | `{:rejected, ...}` clause widened to both reasons; the reserved reason builds `error_args` with `error_type: :reserved_variable_key`, `details: %{}`. Unreachable from the form path (guard above); last-resort only. |
| SERVICE_TASK HTTP body | `advance_service_task_dispatch/4` (`:3811`) | (revision 1a, SECURITY F2) merge/3 rejects; a `:reserved_variable_key` rejection is a terminal instance ERROR (`error_type: :reserved_variable_key`, `affected: {:field, key}`, `details: %{}`, no value), written in the open transaction like `persist_service_task_no_matching_edge/7`; the dispatch row stays `advanced`, no `SERVICE_TASK_COMPLETED`. (A rollback would leave the instance silently stalled.) Other rejections keep `{:error, {:variable_merge_rejected, _}}` (unreachable today: the HTTP merge passes nil validations). |
| Script output (7c) | `apply_locked_script_result/5` (`:4409`) | Rejection clause passes the merge reason as the run's `detail` (D-A1.11): outcome `output_invalid`, detail `reserved_variable_key`. |
| Sub-process output, no interface | `build_parent_merge_variables(nil, _)` (`sub_process.ex:156`) | Result passed through `VariableMerge.drop_reserved/1` (D-A1.5); no error. |
| Sub-process output, explicit interface naming `_sys` | `SubProcess` `else` (`sub_process.ex:934`) | Clause added for reason `:reserved_variable_key` -> `{:error, error_args}` with `error_type: :reserved_variable_key`, `affected: {:field, key}`, `reason: "variable '<key>' is reserved"`, `details: %{}` (no value). |
| Sub-process child start | `build_child_initial_variables/2` (`sub_process.ex:130-140`) | Result passed through `VariableMerge.drop_reserved/1` on both clauses (D-A1.6). |
| Process start | `PinResolver.validate_initial_variables/2` (`pin_resolver.ex:587-602`) | Both clauses: reserved check first (D-A1.7). `field_path` is the RFC 6901 pointer of the key (`~` -> `~0`, `/` -> `~1`). |
| Replay | `reconstruction.ex:632,698,790` | Patterns widened to any reason: `{:execution_error, key, _value, _reason, _failures}` -> existing `{:error, {:variable_merge_rejected, event_id, key}}`. |
| No-op merge | `transition.ex:1367` | Unchanged (empty map). |
| Admin variable patch | none on `main` (0.2) | Nothing to route. |
| Lua `write_variable` | no consumer of `take_staged_writes/0` | Invariant I-4 (section 12). |

`Letflow.EventStore.Registry.ValidationFailure` moduledoc: the documented `constraint` literal set gains
`"reserved_variable_key"` (moduledoc text only; the struct is unchanged).

### 2.3 Event kind `INSTANCE_SYS_VARIABLES_SET`

Seed entry (`@platform_event_type_seed_attrs`):

| Key | Schema |
|---|---|
| `node_id` | string |
| `cause` | string, enum `["entity_writes"]` |
| `values` | object (keys and values constrained by the engine, below; the registry's JSON Schema subset has no `propertyNames`/`pattern`) |

`required: ["node_id", "cause", "values"]`, `additionalProperties: false`. Values: each key a `sys_key()`,
each value a `sys_value()`; at most 40 keys (20 lines x id + seq). No entity field value is ever
placed here (INV-2): only minted record ids and `event_global_seq` integers (0054 D1).

### 2.4 Event kind `TASK_ENTITY_WRITES_APPLIED` (registered now, appended by PR B/C)

| Key | Schema |
|---|---|
| `node_id` | string |
| `task_id` | `["string", "null"]` (HUMAN_TASK) |
| `dispatch_id` | `["string", "null"]` (SERVICE_TASK) |
| `lines_hash` | string (lowercase hex SHA-256 of the canonical JSON of the node's declared lines) |
| `lines` | array, items object `{line_index: integer minimum 0, entity_type: string, record_id: string, event_global_seq: integer minimum 0}`, each item `additionalProperties: false`, all four required |

`required` = all five, `additionalProperties: false`. Constant accessor
`Letflow.Engine.EntityPort.applied_event_type/0 :: String.t()` arrives in A3. In A1 the literal
appears only in `tenant_provisioning.ex` (seed) and `reconstruction.ex` (clause head and
`folded_event_types/0`), both on A1's literal allow-list (2.6). Lua uses no literal (2.7).

### 2.5 Reconstruction (`lib/letflow/engine/reconstruction.ex`)

New `apply_event/4` clauses placed before the catch-all (`:767`):

* `"INSTANCE_SYS_VARIABLES_SET"`: read `payload["values"]` (`fetch_map_field/2`); every key must satisfy
  `sys_key()` and every value `sys_value()` (checked with `VariableMerge.sys_key?/1` and
  `sys_value?/1`, revision 1a), else `{:error, {:invalid_sys_variables_event, event_id}}`
  (no raise, INV-8); fold with `VariableMerge.put_sys/3`; tokens unchanged.
* `"TASK_ENTITY_WRITES_APPLIED"`: `{:ok, state}` (records nothing to re-run, D11).

`reconstruction_error()` type gains `{:invalid_sys_variables_event, Ecto.UUID.t()}`. Moduledoc lists both.

New public function (revision 1, CDV-1 / SEC F4):

```
@spec folded_event_types() :: [String.t()]
# every event type that has its own apply_event/4 clause, sorted: "EXECUTION_ERROR",
# "INSTANCE_CANCELLED", "INSTANCE_STARTED", "INSTANCE_SYS_VARIABLES_SET", "SCRIPT_RUN_RECORDED",
# "SCRIPT_TASK_COMPLETED", "SERVICE_TASK_COMPLETED", "SUB_PROCESS_COMPLETED",
# "TASK_COMPLETED", "TASK_ENTITY_WRITES_APPLIED", "TIMER_FIRED".
```

A unit test asserts the list equals the set of string literals in the `event_type:` patterns of
`apply_event/4` clause heads (AST of `reconstruction.ex`), so a new fold clause cannot be added
without the Lua refusal following it.

### 2.6 Static boundary test for `put_sys` and the two event-type literals

`test/letflow/engine/put_sys_callers_test.exs` (AST over `lib/**/*.ex`, pure file reads, `async: true`):

* Calls named `put_sys` with ANY receiver (local, alias, atom; direct, piped, `&put_sys/3`,
  `&X.put_sys/3`, `Function.capture(_, :put_sys, 3)`, `apply(_, :put_sys, _)`) occur only in
  `@put_sys_callers ["lib/letflow/engine/variable_merge.ex", "lib/letflow/engine/reconstruction.ex"]`.
  PR B adds `lib/letflow/engine.ex` (the step) in a reviewed diff.
* The string literals `"INSTANCE_SYS_VARIABLES_SET"` and `"TASK_ENTITY_WRITES_APPLIED"` occur only in
  `@event_literal_files`: in A1 `["lib/letflow/engine/variable_merge.ex",
  "lib/letflow/engine/reconstruction.ex", "lib/letflow/tenant_provisioning.ex"]`; A3 adds
  `"lib/letflow/engine/entity_port.ex"`. `lib/letflow/engine/lua/platform.ex` is never on it (CDV-1).
* (Revision 1, SEC F5) Every binary literal in the AST of `lib/**/*.ex` that starts with `"_sys"`
  (including `@doc`/`@moduledoc` strings and interpolation segments) occurs only in
  `lib/letflow/engine/variable_merge.ex`. Every other module reaches the namespace through
  `VariableMerge.reserved_key?/1`, `reserved_keys/1`, `drop_reserved/1` or `put_sys/3`.
* The reconstruction call's value argument is read from the event payload map only (asserted by a
  runtime test, 3.x, not by the AST scan).
* Non-vacuity: each rule's expected set is non-empty.

### 2.7 Lua `emit_event` (`lib/letflow/engine/lua/platform.ex`)

`do_emit_event/3`: when `event_type in Reconstruction.folded_event_types()` ->
`encode_error(lua, "invalid_arguments")` before the key is namespaced or any database access
(revision 1, SEC F4 / CDV-1; no literal in this file, nothing for A3 to swap). Moduledoc updated.

## 3. PR A2: Records and EventStore

### 3.1 `Letflow.EventStore.append_multi/3` (`lib/letflow/event_store.ex`)

```
@type step_namespace :: {:line, non_neg_integer()}

@spec append_multi(Ecto.Multi.t(), append_attrs(), [prefix: String.t(), step_namespace: step_namespace()]) ::
        {:ok, Ecto.Multi.t()} | append_error() | {:error, :invalid_step_namespace}
```

* Absent `:step_namespace`: identical Multi (names `:active_instance_guard`, `:assign_sequence`,
  `:idempotency`, `:insert_event`, optional `:store_oversized_payload`, `:update_projection`).
* Present and valid: names `{:line, i, :active_instance_guard}` ... `{:line, i, :update_projection}`.
  Each step closure receives a LOCAL view of `changes` (only this namespace's entries, keys stripped
  to the bare atom), so `insert_event/3`, `store_oversized_payload/3`, `update_projection/3` keep
  their current heads unchanged.
* Present and not `{:line, i}` with `is_integer(i) and i >= 0`: `{:error, :invalid_step_namespace}`
  before any validation step and with the input Multi untouched.
* (Revision 1, SEC F3) `append/2`, `append_platform_event/2`, and `append_multi/3` WITHOUT
  `:step_namespace`: a binary `idempotency_key` starting `"sys:step:"` -> `{:error,
  :reserved_idempotency_key}`, checked right after `fetch_idempotency_key/1` (no query, Multi
  untouched). `append_error()` gains that member. With a valid `:step_namespace` the key is accepted.
* `interpret_transaction_result/1`: unchanged.
* Private signature change: `build_multi_composable(multi, ctx, step_namespace | nil)`;
  `build_multi/1` passes `nil`.

### 3.2 `Letflow.Entities.EntityTypeInstance` (`lib/letflow/entities/entity_type_instance.ex`)

```
@spec fetch_instance_id(entity_type :: String.t(), prefix :: String.t()) ::
        {:ok, Ecto.UUID.t()} | {:error, :not_found}
# one read of entity_type_instances by primary key; never inserts.
```

### 3.3 `Letflow.Entities.Records` (`lib/letflow/entities/records.ex`)

Types:

```
@type step_source :: %{
        required(:kind) => String.t(),                  # "process_step" only
        required(:instance_id) => Ecto.UUID.t(),
        optional(:task_id) => Ecto.UUID.t(),            # exactly one of task_id / dispatch_id
        optional(:dispatch_id) => Ecto.UUID.t(),
        required(:node_id) => String.t(),               # 1..1024 bytes
        required(:definition_id) => Ecto.UUID.t(),
        required(:definition_version) => pos_integer(),
        required(:line_index) => non_neg_integer(),     # must equal :line_key
        required(:activator_id) => Ecto.UUID.t()
      }

@type step_command :: %{
        required(:kind) => :create | :update | :delete,   # only :create accepted (D-A2.10)
        required(:line_key) => non_neg_integer(),
        required(:entity_type) => String.t(),
        required(:field_values) => Validator.field_values(),
        required(:actor_id) => Ecto.UUID.t(),
        required(:idempotency_key) => String.t(),          # \Asys:step:[A-Za-z0-9:_.-]+\z, <= 255 bytes
        required(:source) => step_source()
      }

@type step_refusal_code ::
        :record_version_conflict | :entity_append_only | :write_not_permitted
        | :validation_failed | :idempotency_conflict | :entity_type_inactive

@type command_multi_error ::
        {:error, {:command_kind_not_supported, atom()}}
        | {:error, :invalid_step_key}
        | {:error, :invalid_step_source}
        | {:error, {:definition_not_found, String.t()}}
        | {:error, :entity_type_managed}
        | {:error, {:record_payload_invalid, Validator.violations() | [Violation.t()]}}
        | {:error, {:entity_type_instance_missing, String.t()}}
        | {:error, :invalid_schema_name}
        | EventStore.append_error()

# in-transaction step failure only (never a build error):
#   {:line, i, :recheck_definition} -> {:definition_changed, String.t()} | :entity_type_managed
#                                      | {:definition_not_found, String.t()}

# command_error/0 gains: {:error, :reserved_idempotency_key} | {:error, :reserved_attribute}
```

Public functions:

```
@spec step_key_prefix() :: String.t()    # "sys:step:"

@spec command_multi(step_command(), prefix :: String.t(), ManagedTypes.owner()) ::
        {:ok, Ecto.Multi.t()} | command_multi_error()
# head guard: when is_binary(prefix) and is_authority(authority)   (bad authority -> FunctionClauseError)

@spec interpret_in_multi({:error, Ecto.Multi.name(), term(), map()}) ::
        {:entity_write_refused, non_neg_integer(), step_refusal_code()}
        | {:entity_write_failed, non_neg_integer(), atom()}
        | :not_a_line_failure

@spec classify_step_error(term()) :: {:refused, step_refusal_code()} | :internal
```

`command_multi/3` step order (build phase; no write; queries only where marked):

1. Shape (no query): `kind == :create` else `{:command_kind_not_supported, kind}`; `line_key`
   non-negative integer and `source.line_index == line_key`, else `:invalid_step_source`; key matches
   D-A2.3 else `:invalid_step_key`; `source` matches `step_source()` (string values <= 1024 bytes,
   exactly one of `task_id`/`dispatch_id`, `kind == "process_step"`) else `:invalid_step_source`.
2. `fetch_active_definition/2` (query) -> `check_write_authority/3` (same private function as the
   single-command path, no query) -> `validate_field_values/2` (no query).
3. `EntityTypeInstance.fetch_instance_id/2` (query) -> `{:entity_type_instance_missing, type}` on miss.
4. Mint `record_id`; build event attrs as `build_event_attrs/3` does, plus `metadata` = the flat
   `source.*` keys of D-A2.5 (integers rendered as decimal strings).
5. `EventStore.append_multi(Multi.new(), attrs, prefix: prefix, step_namespace: {:line, line_key})`
   (registry read).
6. (Revision 1, CDV-4) Append `{:line, i, :recheck_definition}` (D-A2.15): re-run
   `fetch_active_definition/2`; a different row id -> `{:error, {:definition_changed, entity_type}}`;
   then `check_write_authority/3` on the re-read row; returns `{:ok, EntityDefinition.t()}`.
7. Append `{:line, i, :upsert_record_latest}` and `{:line, i, :dual_write_promoted_columns}`, running
   the existing private step functions on the namespace-local view of `changes`. No
   `:check_record_version` step for `:create` (it is added only for a non-nil expectation, as today).

Full step order of one line: `{:line, i, :active_instance_guard}`, `:assign_sequence`, `:idempotency`,
`:insert_event`, optional `:store_oversized_payload`, `:update_projection`, `:recheck_definition`,
`:upsert_record_latest`, `:dual_write_promoted_columns` (all `{:line, i, _}`).

Single-command path (D12): `run_command/2`, `append_command/4`, step names and `interpret_result/3`
UNCHANGED in behaviour. The private step helpers gain a `step_namespace | nil` parameter; `nil`
reproduces today's names.

Single-command entry points (`create_record/3`, `update_record/3`, `delete_record/3`): new FIRST two
steps of each `with` chain, before `fetch_active_definition/2` (zero queries on refusal):

1. `reject_reserved_attributes(attrs)` -> `{:error, :reserved_attribute}` if a top-level key in
   `[:source, "source", :metadata, "metadata"]` is present.
2. `reject_step_key(attrs)` -> `{:error, :reserved_idempotency_key}` if `idempotency_key` is a binary
   starting with `step_key_prefix()`.

(For `update_record/3` and `delete_record/3`, `expected_seq/1` keeps its current position at function
entry; the two new steps follow it. `idempotency_match/1` likewise for create.)

`interpret_in_multi/1` mapping:

| Failed step | Reason | Result |
|---|---|---|
| `{:line, i, :build}` | any `r` | `classify_step_error(r)`: `{:refused, c}` -> `{:entity_write_refused, i, c}`; `:internal` -> `{:entity_write_failed, i, :build}` |
| `{:line, i, :idempotency}` | `{:duplicate_idempotency_key, %Event{}}` | `{:entity_write_refused, i, :idempotency_conflict}` (never success) |
| `{:line, i, :check_record_version}` | `:record_version_conflict` | `{:entity_write_refused, i, :record_version_conflict}` |
| `{:line, i, :recheck_definition}` | any `r` | `classify_step_error(r)` as for `:build` |
| `{:line, i, :dual_write_promoted_columns}` | `{:record_payload_invalid, _}` | `{:entity_write_refused, i, :validation_failed}` |
| `{:line, i, s}` | anything else | `{:entity_write_failed, i, s}` |
| any other name | any | `:not_a_line_failure` |

`classify_step_error/1` table:

| Reason | Result |
|---|---|
| `{:definition_not_found, _}`, `{:definition_changed, _}` | `{:refused, :entity_type_inactive}` |
| `:entity_type_managed` | `{:refused, :write_not_permitted}` (detail logged/audited by the caller, INV-5) |
| `{:record_payload_invalid, _}` | `{:refused, :validation_failed}` |
| `{:entity_append_only, _}` | `{:refused, :entity_append_only}` |
| `:record_version_conflict` | `{:refused, :record_version_conflict}` |
| `{:record_not_found, _}`, `{:record_already_deleted, _}` | `{:refused, :write_not_permitted}` |
| `:idempotency_key_reuse`, `{:duplicate_idempotency_key, _}` | `{:refused, :idempotency_conflict}` |
| anything else (incl. `:invalid_step_key`, `:invalid_step_source`, `{:command_kind_not_supported, _}`, `{:entity_type_instance_missing, _}`, `:invalid_schema_name`, `{:invalid_metadata, _}`, `{:payload_validation_failed, _}`, changesets) | `:internal` |

Neither function returns a field value, a violation list or a field name (INV-2; D8 "no field names").

Moduledoc: new section "Process-step writes (decision 0054, GH #2587)" covering `command_multi/3`, the
namespace, the two refusals and that `command_multi/3` has one allow-listed caller.

### 3.4 Static caller test for `command_multi`

`test/letflow/entities/command_multi_callers_test.exs` (NEW file, deliberately not
`managed_types_callers_test.exs`, which #2596 edits concurrently): AST over `lib/**/*.ex` and
`test/support/**/*.ex`; any call or capture/apply of `command_multi` with a Records receiver
(`[:Records]`, `[:Entities, :Records]`, `[:Letflow, :Entities, :Records]`, or the atom
`:"Elixir.Letflow.Entities.Records"`; direct, piped, `&Records.command_multi/3`,
`Function.capture/3`, `apply/3` / `Kernel.apply/3` / `:erlang.apply/3`) outside
`@command_multi_callers ["lib/letflow/entities/step_writes.ex"]` and the definer is a violation.
Expected set in PR A: EMPTY (StepWrites does not call it until PR B), so non-vacuity is proven on
synthetic snippets (fake path `lib/letflow/fake.ex` -> violation; fake path
`lib/letflow/entities/step_writes.ex` -> none). #2583 R1 stays green: no shipped caller passes a
non-`:tenant` authority; `StepWrites` is NOT added to `@authority_callers` (section 8.2 item 3).

(Revision 1, SEC F3) Second rule in the same file: the keyword `step_namespace:` in any call to
`append_multi` (qualified `EventStore`/`Letflow.EventStore` receiver, direct or piped, or a keyword
list literal containing `:step_namespace` passed to it) occurs only in
`lib/letflow/entities/records.ex`. With D-A2.16 this makes I-5 structural: a raw `sys:step:` key is
refused by every EventStore entry point unless namespaced, and only Records namespaces.
Follow-up (section 14): share the AST helpers with `managed_types_callers_test.exs` after #2596 merges.

## 4. PR A3: `EntityPort`, `StepWrites`, EE-12

### 4.1 `Letflow.Engine.EntityPort` (`lib/letflow/engine/entity_port.ex`, replaces `script_read_port.ex`)

```
@type read_spec :: %{required(String.t()) => term()}           # moved from ScriptReadPort
@type row :: %{required(String.t()) => term()}                 # moved from ScriptReadPort
@type line :: %{required(String.t()) => term()}                # one declared entity_writes line (string-keyed, as pinned); PR B fixes its keys
@type line_violation :: %{index: non_neg_integer(), code: atom()}
@type prepare_ctx :: %{required(:prefix) => String.t()}
@type definition_ctx :: %{required(:prefix) => String.t(), optional(atom()) => term()}   # PR B extends
@type multi_ctx :: %{required(:prefix) => String.t(), optional(atom()) => term()}        # PR B extends

@callback prefetch(prefix :: String.t(), reads :: [read_spec()], input_vars :: map()) ::
            {:ok, %{optional(String.t()) => [row()]}} | {:error, :reads_not_allowed}
@callback prepare(lines :: [line()], prepare_ctx()) ::
            :ok | {:error, :entity_write_contention} | {:error, :prepare_inside_transaction}
            | {:error, {:entity_type_prepare_failed, String.t()}}
@callback validate_lines(lines :: [line()], definition_ctx()) :: :ok | {:error, [line_violation()]}
@callback multi(Ecto.Multi.t(), lines :: [line()], multi_ctx()) :: Ecto.Multi.t()

@spec impl() :: module()                         # Application.fetch_env!(:letflow, :entity_port)
@spec applied_event_type() :: String.t()         # "TASK_ENTITY_WRITES_APPLIED"
```

Moduledoc: the `ScriptReadPort` contract text verbatim under "Read half (0053 D5)", plus "Write half
(0054 D2)" and the ruling citation (0054 open point 8). The engine names no `Letflow.Entities` module.

`ScriptTaskDispatcher` (`script_task_dispatcher.ex:532`): `EntityPort.impl().prefetch(...)`; moduledoc
`:25` updated. `lib/letflow/scripts/runtime.ex:22` doc reference updated. `config/config.exs:113-116`:
`config :letflow, :entity_port, Letflow.Entities.EntityPortImpl` replaces `:script_read_port`.

### 4.2 `Letflow.Entities.EntityPortImpl` (`lib/letflow/entities/entity_port_impl.ex`)

`@behaviour Letflow.Engine.EntityPort`; `prefetch/3` delegates to `ScriptReads.prefetch/3`; `prepare/2`,
`validate_lines/2`, `multi/3` delegate to `StepWrites`. `ScriptReads` drops its `@behaviour`/`@impl`
lines (functions unchanged).

### 4.3 `Letflow.Entities.StepWrites` (`lib/letflow/entities/step_writes.ex`)

```
@spec prepare([EntityPort.line()], EntityPort.prepare_ctx()) ::
        :ok | {:error, :entity_write_contention} | {:error, :prepare_inside_transaction}
        | {:error, {:entity_type_prepare_failed, String.t()}}
@spec validate_lines([EntityPort.line()], EntityPort.definition_ctx()) :: :ok | {:error, [EntityPort.line_violation()]}
@spec multi(Ecto.Multi.t(), [EntityPort.line()], EntityPort.multi_ctx()) :: Ecto.Multi.t()
```

`prepare/2`:

1. `[]` lines -> `:ok`, no query, no transaction.
2. `Repo.in_transaction?()` -> `{:error, :prepare_inside_transaction}`.
3. Types = distinct `line["entity_type"]` binaries, sorted ascending (byte order). A non-binary or
   missing type is skipped (the line is refused later).
4. One `Repo.transaction/1`: statements 1-2 are the constant SQL `SET LOCAL lock_timeout = '2s'` and
   `SET LOCAL statement_timeout = '2s'` (no interpolation, INV-7); then per type:
   `Definitions.get_active_definition_by_name/2`; `{:error, :not_found}` -> skip (D-A3.2); found ->
   `EntityTypeInstance.get_or_create/2`; `{:error, _}` -> `Repo.rollback({:entity_type_prepare_failed, type})`.
5. The `Repo.transaction/1` call alone is wrapped in `try ... rescue`: `%Postgrex.Error{postgres:
   %{code: code}}` with `code in [:lock_not_available, :query_canceled, :deadlock_detected]`
   (`55P03`, `57014`, `40P01`) and `%DBConnection.ConnectionError{}` -> `{:error, :entity_write_contention}`;
   any other exception re-raises (never swallowed).
6. `{:ok, _}` -> `:ok`; `{:error, reason}` -> `{:error, reason}`.

The numbers are module attributes `@prepare_lock_timeout "2s"`, `@prepare_statement_timeout "2s"`
(0054 open point 4 BA default).

Test note (revision 1, CDV-8; binding for PR B's tests too): under the Ecto SQL sandbox a
`Repo.transaction/1` is a SAVEPOINT inside the test's outer transaction, so a `SET LOCAL` issued in
it persists for the REST of that outer transaction after the savepoint is released. In the default
`{:shared, _}` mode `prepare/2` would also see `Repo.in_transaction?()` as false. Therefore: the
prepare and contention tests run in `:auto` sandbox mode as `engine_concurrency_test.exs` does (real
transactions, explicit cleanup); and any PR B test that asserts "a completion WITHOUT lines issues no
`SET LOCAL`" or measures timeouts must not run after a with-lines completion in the same sandboxed
test transaction (assert on the statement log captured per call, or use `:auto` mode).

`validate_lines/2` (PR A, fail-closed): `[]` -> `:ok`; otherwise `{:error, [%{index: i, code:
:entity_writes_not_enabled} | ...]}` for every declared index. `multi/3` (PR A, fail-closed): `[]` -> the
input Multi unchanged; otherwise the input Multi plus `Multi.error({:line, 0, :build},
:entity_writes_not_enabled)`. PR B replaces both bodies.

### 4.4 `check_boundaries` and its test

`lib/mix/tasks/letflow.check_boundaries.ex`: Rule 6 row reason ->
`"engine -> entities only via Letflow.Engine.EntityPort (0053 F10, 0054 D2)"`; moduledoc `:26-35`
names `EntityPort` and `:entity_port`. `test/mix/tasks/letflow.check_boundaries_test.exs:285,298,
365-381`: `ScriptReadPort` -> `EntityPort`, `:script_read_port` -> `:entity_port`,
`ScriptReads` -> `EntityPortImpl` in the "implementation selected only through config" test. Test
fixtures implementing the old behaviour (`test/support/script_task_fixture.ex:418-438`
`RecordingReadPort`, `test/letflow/entities/script_reads_test.exs:430-452` `ClearFlagThenReadPort`)
switch to `@behaviour Letflow.Engine.EntityPort`, keep their `prefetch/3`, and delegate the three write
callbacks to `Letflow.Entities.EntityPortImpl`; env keys `:script_read_port` /
`:script_read_port_test_pid` become `:entity_port` / `:entity_port_test_pid`. Message tags
(`:script_read_port_called`) stay. `test/letflow/engine/script_task_replay_test.exs:93` forbidden-name
list gains `"EntityPort"` and `"StepWrites"` (D11: replay names neither).

(Revision 1, SEC F8) Static assertion in `test/letflow/engine/entity_port_boundary_test.exs`: in
`lib/letflow/engine/script_task_dispatcher.ex` and every `lib/letflow/scripts/**/*.ex`, no remote call
named `prepare`, `validate_lines` or `multi` has a NON-alias receiver (a variable, `EntityPort.impl()`
or any call result), and no call names `EntityPort.impl()` other than as the receiver of `prefetch`.
Alias-receiver calls such as `Multi.new()` are not matched. Today: one port call,
`port.prefetch(...)` (`script_task_dispatcher.ex:532-533`), so the rule is non-vacuous on a synthetic
negative (`port.multi(m, l, c)` under a fake `lib/letflow/scripts/fake.ex` path -> violation).

### 4.5 EE-12: section 10.

## 5. PR A4: `writable_by_process`

### 5.1 Document and validator

* `Letflow.Entities.Definition.t()` gains `optional(:writable_by_process) => boolean()`; moduledoc
  section "`writable_by_process` (GH #2587, decision 0054 D4a.2)": absent means not writable by a
  process step; part of the logical shape; who may set it; where it is refused; that PR B re-reads it
  from the CURRENT active definition at run time.
* `Letflow.Entities.Definition.Validator.malformed_violations/1`:
  `check_optional_boolean(definition, :writable_by_process)` (existing helper).
* `routers/entities.ex` `build_definition_document/1` (`:543-556`):
  `maybe_put_optional(:writable_by_process, body, "writable_by_process")`.

### 5.2 `Letflow.Entities.ProcessWritable` (`lib/letflow/entities/process_writable.ex`, pure)

```
@spec declared?(definition :: map()) :: boolean()
# true iff :writable_by_process or "writable_by_process" is literally true.

@spec denied_name?(name :: String.t()) :: boolean()
# true iff String.downcase(name) is in @denied_exact or starts with one of @denied_prefixes (section 9.2).

@spec check_settable(definition :: map(), managed_stamp :: String.t() | nil) ::
        :ok | {:error, {:validation, [Violation.t()]}}
# :ok when not declared?/1; else refused when managed_stamp is non-nil or matched_rule(name) != nil:
# [%Violation{rule: :writable_by_process_not_permitted, path: [:writable_by_process], message: m}]
# m (revision 1, OQ-2 ruling) names the matched rule, from a closed template set:
#   managed:          "writable_by_process cannot be set: the entity type is managed by a module"
#   denied prefix p:  "writable_by_process cannot be set: the name matches the denied prefix \"<p>\""
#   denied name n:    "writable_by_process cannot be set: the name \"<n>\" is denied"
# The rule code is stable; only the message varies. The caller is an :EntitiesDefinitionsWrite
# admin naming its own type, so the matched rule leaks nothing (not an INV-5 surface).

@spec matched_rule(name :: String.t()) :: {:prefix, String.t()} | {:exact, String.t()} | nil
# the first matching denied prefix (list order) or exact name; nil when none.

@spec writable?(EntityDefinition.t()) :: boolean()
# run-time check for PR B: definition_json["writable_by_process"] == true and managed_by == nil
# and not denied_name?(name). Unused in PR A (tested directly).
```

`Violation` is `Letflow.Entities.Definition.Validator.Violation`; `rule` gains the atom
`:writable_by_process_not_permitted` (closed-set addition, section 13).

### 5.3 Write paths

* `Definitions.do_create_definition/4` (`definitions.ex:147`): after `validate_definition/1`, before
  the shape hash: `:ok <- ProcessWritable.check_settable(definition, stamp)`. The `with` already
  rolls back on `{:error, _}`; the router renders `{:error, {:validation, violations}}` as the existing
  422 (`routers/entities.ex:679`).
* `SolutionPack.create_packed_entity_definitions/4` (`solution_pack.ex:1650`): before each
  `create_definition/3` call, `ProcessWritable.declared?(packed.definition_json)` true ->
  `{:halt, {:error, {:validation, [the same violation]}}}` (D-A4.6), flowing into the existing
  all-or-nothing rollback.
* Activation (`Definitions.activate_definition/4`): unchanged; the version it activates was already
  checked at creation.

### 5.4 Documentation and PR-body records (revision 1)

* Module guide: `docs/guides/adding-an-application-module.md` gains a short section
  "Process-writable entity types (`writable_by_process`)": who may set it, that module-managed types
  never carry it, the full denied-name list of 9.2 verbatim, that the list is an interim fail-closed
  rule replaced by type classification under GH #2618, and that a solution pack cannot carry the flag
  (GH #2619; until then an admin sets it after install under `:EntitiesDefinitionsWrite`).
  `ProcessWritable`'s moduledoc points to that section.
* SEC F6: A4's PR body records the result of this read-only count over every provisioned tenant
  schema (schema names taken from the platform `tenant_schemas` registry by the operator, one
  statement per schema, quoted identifier), and it must be ZERO before A4 merges (a pack may have
  stored the key verbatim before A4, since the validator ignored unknown top-level keys):
  `SELECT count(*) FROM "<schema>".entity_definitions WHERE definition_json ? 'writable_by_process';`
  A non-zero result blocks A4 until each such row is reviewed (ORCH decides repair).
* A4's PR body states that the name list is interim and cites GH #2618 and GH #2619.

## 6. Dependencies (cross-module)

| From | To | Edge | New? |
|---|---|---|---|
| `Engine` (`engine.ex`), `SubProcess`, `PinResolver`, `Reconstruction`, `Lua.Platform` | `VariableMerge` | function calls | existing module, new functions |
| `ScriptTaskDispatcher` | `EntityPort` | `impl/0` | changed (was `:script_read_port`) |
| `EntityPortImpl` | `ScriptReads`, `StepWrites` | delegation | new, entities-internal |
| `StepWrites` | `EntityTypeInstance`, `Definitions`, `Repo` | calls | new |
| `Records` | `EventStore` (`:step_namespace`), `EntityTypeInstance.fetch_instance_id/2`, `ManagedTypes` | calls | additive |
| `Definitions`, `SolutionPack` | `ProcessWritable` | calls | new |
| engine -> entities | config `:entity_port` | NOT a file edge; Rule 6 green | REVIEWER F10 sign-off (one) |
| config | `EntityPortImpl` | config value | changed |

No file under `lib/letflow/engine*` names a `Letflow.Entities` module (verified empty grep today;
asserted by test 11.A3-2).

## 7. Database

No migration, no new table, column or index. `writable_by_process` lives in the existing
`entity_definitions.definition_json` jsonb. The two event types are rows in the existing tenant
`event_type_registry`, seeded by `TenantProvisioning.replay_migrations/2` at provisioning and at boot
replay of existing tenants (`gh2534-7c-script-handler.md` 0.3). No `scope_node_paths` access.

## 8. Behaviour changes visible to a caller (all in PR A)

| Caller | Before | After |
|---|---|---|
| `POST /tasks/:id/complete` with an output key `_sys...` | merged | 422 `output_refused`, `rejected_keys: [key]`, nothing written |
| `POST /instances` with an initial key `_sys...` | started | 422 `variable_schema_violation`, constraint `reserved_variable_key` |
| HTTP SERVICE_TASK 2xx body with a top-level `_sys...` key | merged | instance ERROR `reserved_variable_key` (no value), dispatch row stays `advanced` (revision 1a, SECURITY F2) |
| Script output with a `_sys...` key | merged | `output_invalid` run, detail `reserved_variable_key` |
| Sub-process child output carrying `_sys...`, no interface | merged into parent | dropped; rest merged |
| Sub-process interface `outputs` naming `_sys...` | merged into parent | parent ERROR `reserved_variable_key` |
| Any `EventStore` append with raw key `sys:step:...` (not namespaced) | stored | `{:error, :reserved_idempotency_key}` |
| Lua `emit_event` with a reconstruction-folded type | appended | `invalid_arguments` |
| In-process `Records.*` with raw key `sys:step:...` | stored | `{:error, :reserved_idempotency_key}` |
| In-process `Records.*` with attrs `source`/`metadata` | ignored | `{:error, :reserved_attribute}` |
| `POST /entities/definitions` with `writable_by_process: true` | key dropped | stored, or 422 on a refused type |
| Pack install with `writable_by_process: true` | key carried | install refused (422 via existing pack error path) |
| `config :letflow, :script_read_port` | used | gone; `:entity_port` |

## 9. Constants

### 9.1 Numbers

`prepare/2`: `lock_timeout` 2 s, `statement_timeout` 2 s (0054 open point 4). Step key: at most 255
bytes (`event_store.ex:124`). `_sys` values: at most 40 keys per event.

### 9.2 `ProcessWritable` denied names (closed, INTERIM per the OQ-2 ruling; replaced by type classification under GH #2618; adding one is a reviewed diff; documented verbatim in the module guide, 5.4)

* `@denied_prefixes ["org_", "user_", "users_", "role_", "roles_", "permission_", "permissions_",
  "principal_", "principals_", "group_", "groups_", "membership_", "attachment_", "attachments_"]`
* `@denied_exact ["org", "orgs", "user", "users", "role", "roles", "permission", "permissions",
  "principal", "principals", "group", "groups", "membership", "memberships", "attachment",
  "attachments"]`

## 10. EE-12 amendment (`engine.ex` moduledoc; PR A3; nothing else in `engine.ex` changes in A3)

Replacement text, sentence by sentence (0054 D3 amendment list items 1-5):

1. `:287-289`, replace "Every `lock("FOR UPDATE")` acquired anywhere in ... is scoped to a single
   `instance_id`, never wider:" with: "Every `lock("FOR UPDATE")` the engine itself acquires in
   `create/2`, `complete_task/3`, and `cancel_instance/3` (this module) plus
   `Letflow.EventStore.append/2`'s own transitive lock on the instance's stream is scoped to a single
   `instance_id`, never wider. A completion whose node declares `entity_writes` (decision 0054)
   additionally takes, through `Letflow.Engine.EntityPort`, each written entity type's
   `instance_sequences` row and its synthetic per-type `instance_projections` row (PER TYPE, therefore
   shared with every writer of that type in the tenant, across instances), the record rows it reads
   `FOR UPDATE`, and, for org-tree and scoped types only, the `scope_node_paths` table lock:"
2. `:324`, replace "**No global or table-level lock is held anywhere in these write paths.**" with:
   "**No global or table-level lock is held anywhere in these write paths, except the
   `scope_node_paths` table lock (`Letflow.ScopeNodePaths.lock!/1`, decision 0054 D3 rule 3a), taken
   only by a completion whose `entity_writes` lines write an org-tree type or a scoped type.**"
3. `:333`, replace "a `LOCK TABLE`," with "a `LOCK TABLE` (other than `ScopeNodePaths.lock!/1`
   reached through `entity_writes`, see above),".
4. `:348-353`, append after "...not a cross-instance one.": "A completion whose node declares
   `entity_writes` extends this with the cross-instance order of decision 0054 D3, after the two
   locks above: (3) the instance's own `instance_sequences` row; (3a) the `scope_node_paths` table
   lock, only for org-tree or scoped types; (4) per line, in `(entity_type, declared index)` order,
   that type's `instance_sequences` row and synthetic projection row, then its record rows; (5)
   `:transition` and the tail. Entity-type locks are cross-instance and are taken only in this order,
   so two completions writing types (A, B) and (B, A) cannot deadlock on them."
5. `:360-363`, replace "Isolation instead rests entirely on the row-locking discipline documented
   above, verified under real concurrency by `test/letflow/engine_concurrency_test.exs` (REQ-055)."
   with: "Isolation instead rests entirely on the row-locking discipline documented above. Instance
   isolation is verified under real concurrency by `test/letflow/engine_concurrency_test.exs`
   (REQ-055), which covers completions without `entity_writes` only; cross-instance entity-type
   contention is covered by the decision 0054 lock-order tests (AC 6). A completion with org-type
   lines serialises other org writers by design."

`test/letflow/engine_concurrency_test.exs` is not edited and must pass.

## 11. AC -> design -> test brief

Test files are the issue's names where it gives one. All new unless noted.

### A1

| AC | Design | Test file and cases |
|---|---|---|
| `_sys.` refusal in `merge/3` | 2.1 | `test/letflow/engine/variable_merge_sys_test.exs`: key `"_sys"` with a map value -> `{:rejected, current, [{:execution_error, "_sys", nil, :reserved_variable_key, []}]}` and `current` returned unchanged even when other keys are valid; `"_sys.x"` -> same shape; `%{"a" => %{"_sys.x" => 1}}` -> `{:ok, _, _}` merged; ordinary key unchanged behaviour; atom key `:"_sys.x"` refused; the reserved check precedes a `{:rejected, _}` validation outcome for an earlier-sorted key (reason is `:reserved_variable_key`); `reserved_keys/1`, `drop_reserved/1` unit cases; determinism (two calls equal). |
| every external source | 2.2 | `test/letflow/engine/sys_namespace_sources_test.exs`, one case per source: (1) form completion with `"_sys.x"` -> `{:error, {:output_refused, %{missing_keys: [], rejected_keys: ["_sys.x"]}}}`, task still `pending`, no `TASK_COMPLETED`, instance not in ERROR, one `task.completion_refused` audit row with key names only; (2) service-task body `%{"_sys.x" => 1}` -> `advance_after_service_task_outcome/4` returns `{:error, {:variable_merge_rejected, _}}`, token not advanced, variables unchanged, advance-failure audit row with tag `variable_merge_rejected`, the value never in the audit or log (capture_log); (3a) sub-process child with NO interface whose final variables hold `"_sys.x"` and `"y"` -> parent merges `"y"` only, no ERROR, parent variables lack `"_sys.x"`; (3b) child with an explicit interface whose `outputs` names `"_sys.x"` -> parent ERROR with `error_type` `"reserved_variable_key"`, payload carries no value; (4) child START: parent holding `"_sys.a"` starts a child (no interface and with an interface) -> child initial variables lack `"_sys.a"`; (5) `Engine.create/2` with initial `%{"_sys" => %{}}` and with a registered schema and with `nil` schema -> `{:error, {:variable_schema_violation, [%ValidationFailure{constraint: "reserved_variable_key", actual: nil}]}}`, no instance row; HTTP start -> 422; (6) script output `%{"_sys.x" => 1}` via the 7c route -> SCRIPT_RUN_RECORDED `outcome` `"output_invalid"`, `detail` `"reserved_variable_key"`, variables unchanged; a schema-rejected script output still records `detail` `"variable_schema_rejected"`; (7) recorded grep result: no admin variable-patch route (assert no router file declares a path containing `variable`). |
| engine-only writer + reconstruction | 2.1, 2.5, 2.6 | `test/letflow/engine/reconstruction_sys_test.exs`: an instance stream with `INSTANCE_SYS_VARIABLES_SET` (`values: %{"_sys.r" => uuid, "_sys.r.seq" => 7}`) before a `TASK_COMPLETED` rebuilds variables containing both keys; a gateway reading `_sys.r.seq` after the completion takes the same edge live-built and rebuilt; a malformed SYS event (key `"x"`, value `%{}`) -> `{:error, {:invalid_sys_variables_event, id}}`, no raise; `TASK_ENTITY_WRITES_APPLIED` changes no state. (Revision 1, CDV-2: the "replay invokes no `EntityPort` write callback" case is AC 15, Group B, and moves to PR B's `test/letflow/engine/entity_writes_replay_test.exs`; A1 needs nothing from A3.) `test/letflow/engine/put_sys_callers_test.exs` (2.6): put_sys callers, event literals, `"_sys"` binary literals (SEC F5), each with synthetic negatives under a fake `lib/letflow/fake.ex` path; `put_sys/3` raises `FunctionClauseError` on `"_sys"`, `"x"`, value `%{}`. `folded_event_types/0` equals the `apply_event/4` clause-head literals (2.5). Lua (existing `test/letflow/engine/lua/platform_test.exs`, new describe): `emit_event` with EACH of `Reconstruction.folded_event_types()` -> `[nil, %{"error" => "invalid_arguments"}]`, no event appended, no `event_idempotency` row; a fixture-registered type still appends (regression). |
| event types registered | 2.3, 2.4 | `test/letflow/event_store/registry_entity_writes_test.exs`: new tenant -> both rows at schema_version 1; rows deleted -> `Registry.validate_payload/3` -> `{:error, :unknown_event_type}`; after `replay_migrations/1` -> `:ok` for a valid payload; invalid payloads (extra key, missing key, `cause` not in enum, `lines` item extra key) -> `{:payload_validation_failed, _}`. Mirrors `tenant_provisioning_script_events_test.exs`. |

### A2

| AC | Design | Test file and cases |
|---|---|---|
| `sys:step:` (a), `source` (b), #2550 regression | 3.3, 3.4 | `test/letflow/entities/records_reserved_keys_test.exs`: (a) `create_record/2`, `update_record/2`, `delete_record/2` and the `/3` arities with raw `"sys:step:abc:0"` -> `{:error, :reserved_idempotency_key}`, zero events, zero `event_idempotency` rows, zero queries (Ecto telemetry count); raw `"certificate:issue:<uuid>"` and a bare UUID still create; `"SYS:STEP:x"` (other case) is accepted (exact bytes, D9.2); stand-in for StepWrites: `Records.command_multi/3` with `"sys:step:<task>:0"` commits in `Repo.transaction`; (b) attrs with `source: %{}`, `"source" => "x"`, `metadata: %{"source" => "y"}` -> `{:error, :reserved_attribute}` on all three commands, no event; a record whose `field_values` has a `"source"` FIELD writes normally; regression: HTTP POST and PUT with body key `"sys:step:abc:0"` stored as `client:rec:<actor>:sys:step:abc:0` (201/200); DELETE and import never store a key starting `sys:` (server-built keys). `test/letflow/entities/command_multi_callers_test.exs` (3.4). |
| `command_multi/3` | 3.1-3.3 | `test/letflow/entities/records_command_multi_test.exs` (setup, revision 1 CDV-6: synthetic instances for types A and B are pre-created with `EntityTypeInstance.get_or_create/2` directly, since `StepWrites.prepare/2` arrives in A3): three lines (keys 0, 1, 2; lines 0 and 2 on type A, line 1 on type B) built by `command_multi/3`, composed with `Multi.append/2`, one `Repo.transaction/1` -> commits, three records, three `ENTITY_RECORD_CREATED` events each carrying the `source.*` metadata keys and `actor_id`; `Multi.to_list/1` names all `{:line, i, _}`, no duplicate-name raise; a line with a >4096-byte payload adds `{:line, i, :store_oversized_payload}` and commits; `fetch_instance_id` miss -> `{:error, {:entity_type_instance_missing, _}}` and no row created; `:update`/`:delete` -> `{:error, {:command_kind_not_supported, _}}`; key `"certificate:issue:x"` and `"sys:step:a b"` -> `:invalid_step_key`; `line_index != line_key` -> `:invalid_step_source`; managed type with `:tenant` -> `{:error, :entity_type_managed}` with exactly the definition query (T-11 style count); `authority` `"x"` -> `FunctionClauseError`; `EventStore.append_multi/3` without `:step_namespace` -> `Multi.to_list/1` names equal the fixed list; with `step_namespace: {:line, -1}` / `:foo` -> `{:error, :invalid_step_namespace}`; (SEC F3) `EventStore.append/2`, `append_platform_event/2` and un-namespaced `append_multi/3` with key `"sys:step:t:0"` -> `{:error, :reserved_idempotency_key}`, nothing written, while namespaced `append_multi/3` accepts it; (CDV-4) recheck: between build and transaction, activate a new version of the type -> `{:error, {:line, 0, :recheck_definition}, {:definition_changed, _}, _}` -> `{:entity_write_refused, 0, :entity_type_inactive}`, nothing committed; with an unchanged definition the step result is the same `EntityDefinition` row id as the build; the per-line step order equals the list in 3.3; existing `test/letflow/entities/records_*_test.exs` and `test/letflow/event_store*` unchanged and green. |
| `interpret_in_multi/1` | 3.3 | same file: a committed line with key K, then a second transaction re-using K -> `{:error, {:line, 0, :idempotency}, {:duplicate_idempotency_key, _}, _}` -> `{:entity_write_refused, 0, :idempotency_conflict}` (never `{:ok, _}`, never `is_duplicate`); `{:line, 2, :build}` with `:entity_type_managed` -> `{:entity_write_refused, 2, :write_not_permitted}`; with `{:definition_not_found, "t"}` -> `entity_type_inactive`; `{:line, 1, :insert_event}` changeset -> `{:entity_write_failed, 1, :insert_event}`; a non-line name `:transition` -> `:not_a_line_failure`; property test (StreamData): for every generated reason the result never contains a map or list (no field values/names). |

### A3

| AC | Design | Test file and cases |
|---|---|---|
| pre-transaction `get_or_create` | 4.3 | `test/letflow/entities/step_writes_prepare_test.exs` (sandbox `:auto`, `async: false`, as `engine_concurrency_test.exs`): `[]` -> `:ok` with zero queries; two lines of type A and one of B -> both synthetic instances exist, committed (visible from another connection); type without an active definition -> no `entity_type_instances` row; called inside `Repo.transaction/1` -> `{:error, :prepare_inside_transaction}`, nothing written; contention: a separate connection holds an uncommitted insert of the same `entity_type_instances` key, `prepare/2` returns `{:error, :entity_write_contention}` within ~2 s (assert < 4 s, not a tight bound), no exception; the statement log (Ecto telemetry) shows the two `SET LOCAL` statements first inside the prepare transaction. |
| one `EntityPort` | 4.1-4.4 | `mix letflow.check_boundaries` run in the PR and its output quoted; `test/letflow/engine/entity_port_boundary_test.exs`: no file under `lib/letflow/engine.ex`/`lib/letflow/engine/` contains `Letflow.Entities` (regex `Letflow\.Entities\b`, docs included); `EntityPort.impl/0` is the only `:entity_port` env reader in `lib/`; `EntityPortImpl` declares `@behaviour Letflow.Engine.EntityPort` and exports all four callbacks; no module in `lib/` declares a behaviour other than `EntityPort` whose callbacks are implemented by an `Letflow.Entities.*` module for the engine (i.e. `ScriptReadPort` is gone: `Code.ensure_loaded?(Letflow.Engine.ScriptReadPort) == false`); `StepWrites.validate_lines/2` and `multi/3` fail closed on a non-empty list; (SEC F8) script paths call only `prefetch/3` on the port (4.4), with a synthetic negative. Existing 7c tests (`script_task_dispatcher_test.exs`, `script_reads_test.exs`, `runtime_test.exs`, `check_boundaries_test.exs`, `script_task_replay_test.exs`) green after the rename. |
| EE-12 | 10 | Verification, not a test: `git diff origin/main -- lib/letflow/engine.ex` in A3 shows only the five sentence edits; `test/letflow/engine_concurrency_test.exs` unedited and green. |

### A4

| AC | Design | Test file and cases |
|---|---|---|
| `writable_by_process` | 5 | `test/letflow/entities/writable_by_process_test.exs`: HTTP `POST /entities/definitions` with `writable_by_process: true` by a principal with only `:EntitiesRecordsWrite` -> 403; only `:DefinitionsWrite` -> 403; with `:EntitiesDefinitionsWrite` -> 201 and stored `true`; activation by the same principal -> 200 and the active definition carries it; non-boolean -> 422 `malformed` at `["writable_by_process"]`; name `org_unit`, `user_profile`, `role`, `attachment_meta` -> 422 rule `writable_by_process_not_permitted`, no row, and the message names the matched rule (`user_profile` -> `denied prefix "user_"`, `role` -> `name "role" is denied`; managed -> the managed template); a managed type created through `create_definition/3` with the fixture `Owner` and the flag -> `{:error, {:validation, [_]}}`, no row; the same names WITHOUT the flag still create; solution-pack install of a definition carrying the flag -> install refused, nothing installed; `ProcessWritable.writable?/1` truth table (flag absent/false/true x managed nil/non-nil x denied/allowed name); logical shape differs with the flag (new version). |

## 12. Invariants

* I-1 Only `VariableMerge.put_sys/3` sets a reserved key; its callers are allow-listed (2.6).
* I-2 Every external variable source refuses reserved keys before any write (2.2); nested keys are never reserved.
* I-3 Replay applies `_sys.` values only from `INSTANCE_SYS_VARIABLES_SET`, which only the engine appends (2.6, 2.7), and never calls an `EntityPort` write callback.
* I-4 Any future consumer of Lua `take_staged_writes/0` or any new variable-writing route merges through `merge/3`.
* I-5 A raw `sys:step:` key reaches `event_idempotency` only through a namespaced `EventStore.append_multi/3` (every un-namespaced EventStore entry refuses it, D-A2.16), the namespace is used only by `records.ex`, and within Records only `command_multi/3` passes it, callable only from `StepWrites` (3.4). Structural, not only Records-boundary.
* I-12 A definition used for a line's write is re-read and re-authority-checked after that type's sequence lock is taken (`{:line, i, :recheck_definition}`).
* I-6 The single-command Records path builds the same Multi (names and order) as before; `interpret_result/3` unchanged.
* I-7 `command_multi/3` performs no write before the caller's transaction and never inserts `entity_type_instances`.
* I-8 `interpret_in_multi/1` never returns success and never carries a field value or field name.
* I-9 `prepare/2` never runs inside a caller's transaction and never swallows a non-contention exception.
* I-10 No file under `lib/letflow/engine*` names a `Letflow.Entities` module; one config key `:entity_port`.
* I-11 `writable_by_process: true` exists on an active definition only if a `:EntitiesDefinitionsWrite` principal created and activated it, and never on a managed or denied-name type.

### 12.1 Security invariants (`docs/agents/instructions/security-invariants.md` numbering)

| INV | How PR A satisfies it |
|---|---|
| INV-1 tenant isolation | `prepare/2`, `command_multi/3`, `fetch_instance_id/2` take the tenant schema `prefix` from the caller's server context only; `:step_namespace` is a separate option so it can never be confused with `:prefix`; no line, command or event field selects a schema. |
| INV-2 server-side field authorisation | No field value enters an error, log, audit or the two new instance events: reserved-key rejections carry `nil`/no value; `interpret_in_multi/1` and `classify_step_error/1` return atoms only; `TASK_ENTITY_WRITES_APPLIED` carries ids and sequences only. Write-side field restrictions are PR B (D4c). |
| INV-3 sandboxing | Lua `emit_event` can no longer append any event type reconstruction folds (2.7); scripts still cannot write `_sys.` (script output refused, D-A1.11). |
| INV-4 secrets | No secret touched. Rescue clauses map to atoms; no exception text reaches a response or log line added by PR A. |
| INV-5 indistinguishability | `classify_step_error/1` maps managed, not-found and already-deleted to the one code `write_not_permitted`; the `writable_by_process` refusal names its matched rule (OQ-2 ruling), which is not an INV-5 surface: the caller is an `:EntitiesDefinitionsWrite` admin creating a definition of its own chosen name, and no record or other tenant's data is involved. |
| INV-6 new data-access paths | New paths: `command_multi/3` (scoped by `prefix`, authority-checked per line), `fetch_instance_id/2`, `prepare/2`. No new route. Stated here for SECURITY-REVIEWER. |
| INV-7 no SQL interpolation | `SET LOCAL` statements are constant strings; no identifier is interpolated; existing queries reused. |
| INV-8 no unhandled crashes | Widened rejection clauses (D-A1.4) remove a new `CaseClauseError`/`WithClauseError`; reconstruction validates SYS payloads instead of raising; `prepare/2` returns typed contention; `put_sys/3`'s raise is reachable only from allow-listed engine code with validated input. |
| INV-10 platform authority / permission classification | No new permission; `writable_by_process` uses the tenant-scope `:EntitiesDefinitionsWrite`; the pack path (`:DefinitionsCreate`) refuses the flag; effective-permission golden file (REQ-498) unaffected (no route change). |

Threats (0054 list): T-1 partly (flag refused on managed types now; run-time refusal is PR B); T-4
closed for in-process callers (I-5) and clients (#2550); T-9 forging `source` (D-A2.4) and replay
forging (I-3); T-2 per-type allow surface defined (A4).

## 13. Closed-set changes for REVIEWER sign-off

1. Instance event types `INSTANCE_SYS_VARIABLES_SET` and `TASK_ENTITY_WRITES_APPLIED` (seed list, replay clauses).
2. `VariableMerge` rejection reason `:reserved_variable_key`; `ValidationFailure.constraint` literal `"reserved_variable_key"`; `ExecutionError.error_type` value `:reserved_variable_key` (open union).
3. `Records.command_error` members `:reserved_idempotency_key`, `:reserved_attribute`; new public `command_multi/3`, `interpret_in_multi/1`, `classify_step_error/1`, `step_key_prefix/0`; event-metadata keys `source.*`; reserved Multi step names `{:line, i, :build}` and `{:line, i, :recheck_definition}`; step error `{:definition_changed, type}`.
4. `EventStore.append_multi/3` option `:step_namespace` and error `:invalid_step_namespace`; `append_error()` member `:reserved_idempotency_key` on all three append entry points.
4a. `Reconstruction.folded_event_types/0` (public); 7c script run `detail` value `reserved_variable_key`; SERVICE_TASK body reserved key -> instance ERROR (revision 1a).
5. Engine -> entities edge: behaviour `Letflow.Engine.EntityPort` replacing `ScriptReadPort`; config key `:entity_port` replacing `:script_read_port`; Rule 6 reason text (0053 F10 / 0054 D2: ONE sign-off for the one edge).
6. Entity definition key `writable_by_process`; `Violation.rule` `:writable_by_process_not_permitted`; the denied-name lists (9.2).
7. Permission use: `:EntitiesDefinitionsWrite` reused for the flag; no new permission atom.
8. Lua `emit_event` refusal of every reconstruction-folded event type.
9. EE-12 text (section 10).

## 14. Proposed split (Group A is too large for one agent turn)

Recorded reason for the split (core-directives "Merge Discipline" item 1): four independently
reviewable surfaces (variable namespace, Records/EventStore composition, the engine->entities port,
definition policy), each with its own validator focus; one combined diff would exceed one agent turn.

| PR | Contents | Touches | Depends on | Merge order |
|---|---|---|---|---|
| **A1** | sections 2.1-2.7: `_sys` refusal and all sources (incl. no-interface sub-process output strip, script run detail, SERVICE_TASK reserved-key ERROR), `put_sys/3`, both event types registered, reconstruction clauses and `folded_event_types/0`, static test (put_sys, event literals, `"_sys"` literals), Lua emit_event refusal of folded types | `variable_merge.ex`, `engine.ex` (code only), `sub_process.ex`, `pin_resolver.ex`, `reconstruction.ex`, `tenant_provisioning.ex`, `lua/platform.ex`, `script_task_dispatcher.ex` (fail-code type), `validation_failure.ex` (doc) | none | 1st |
| **A2** | sections 3.1-3.4: `append_multi` namespace, un-namespaced `sys:step:` refusal in EventStore, `fetch_instance_id/2`, `command_multi/3` with `:recheck_definition`, `interpret_in_multi/1`, `classify_step_error/1`, `sys:step:`/`source` refusals, caller tests | `event_store.ex`, `records.ex`, `entity_type_instance.ex` | merges after A1 | 2nd |
| **A3** | sections 4, 10: `EntityPort` (subsumes `ScriptReadPort`), `EntityPortImpl`, `StepWrites` (`prepare/2` complete, write callbacks fail-closed), config key, Rule 6 text, 7c test renames (same tests green), script-path prefetch-only assertion, EE-12 text; `entity_port.ex` added to the event-literal allow-list | `engine/entity_port.ex` (new), `engine/script_read_port.ex` (deleted), `engine/script_task_dispatcher.ex`, `engine.ex` (moduledoc only), `entities/*`, `config/config.exs`, `check_boundaries.ex`, 7c tests | merges after A2 (A1's allow-list file) | 3rd |
| **A4** | section 5: `writable_by_process`, module-guide section, F6 count | `entities/definition.ex`, `definition/validator.ex`, `definitions.ex`, `process_writable.ex` (new), `routers/entities.ex`, `definitions/solution_pack.ex`, `docs/guides/adding-an-application-module.md` | merges after A3 | 4th |

Supervisor ruling (revision 1): the split is ACCEPTED, SERIAL A1 -> A2 -> A3 -> A4; A3 subsuming 7c-2's
port is accepted as a refactor with the same 7c tests green.

A1 PR-body record (OQ-1, ruled and CLOSED): "Read-only `_sys` count, infra on QA (`letflow_qa`, record
`runs/2026-10-15-inv-sys-vars-count-001`, 2026-10-15): `instances_with_sys_vars = 0` for all 6
tenants (bilimbaga, bpm-default, meridian, req384-eo001-b-740d4d13, swiftroute, vortex). No
production application database exists." The same query is a GATE for PR B (16, OQ-1).

None of A1-A4 touches `lib/letflow/modules/exam/**`, `managed_types_callers_test.exs` or a module
manifest (#2596 coordination). A2 and #2583 do not conflict (#2583 merged). Each PR body cites
REQ-499 / GH #2587, this design, and the split reason.

## 15. Deferred to PR B / PR C / others (not in PR A)

* PR B: `entity_writes` node attribute, line shape, activation validation (`validate_lines/2` real
  body), `:entity_writes` step (`multi/3` real body, `Multi.merge` of `command_multi/3` per line in
  `(entity_type, index)` order), `put_sys/3` call after create lines and the SYS event before
  `TASK_COMPLETED`, `TASK_ENTITY_WRITES_APPLIED` append, `SET LOCAL` 2 s / 5 s and the 10 s guard,
  contention rescue around `Repo.transaction()` at `engine.ex:2636`, `complete_error` additions,
  bad-`expected` mapping, uniform `write_not_permitted` response, run-time `writable_by_process`
  recheck via `ProcessWritable.writable?/1`, write-side field restrictions (D4c), audit per line,
  `activated_by` / `needs_reactivation`, managed-type refusal at activation and run time (option A),
  scoped-type fail-closed refusal, rule 3a re-verification (open point 5), replay double test (AC 15),
  `lib/letflow/engine.ex` added to `@put_sys_callers` (the step that calls `put_sys/3` lives in the
  engine, not in `StepWrites`), `step_writes.ex` becomes the first real `command_multi/3` caller.
* PR B also (revision 1): the "replay invokes no `EntityPort` write callback" test (AC 15, moved
  from A1, CDV-2); line types filtered through `ProcessWritable.writable?/1` (on the CURRENT active
  definition) BEFORE `prepare/2`, so `prepare/2` never creates a synthetic instance for a type no
  line may write (SEC F7), and the run-time recheck reads the `{:line, i, :recheck_definition}` step
  result; the `SET LOCAL` sandbox note of 4.3 applies to its timeout and statement-log tests (CDV-8);
  GATE: before PR B opens, the OQ-1 count query (16) is re-run and must be zero, and any instance
  found is cancelled or repaired first.
* PR B carry-overs from the A1 gates (revision 1a):
  (a) Gateways cannot read a flat `_sys.` key today: `Letflow.Engine.Expr` splits a variable name on
  dots (`variables._sys.r.seq` resolves `_sys` -> `r` -> `seq`). The PR B design must decide
  between making `Expr` treat a name that starts with the reserved prefix as ONE flat key via
  `VariableMerge.reserved_key?/1` (REVIEWER's preference) and refusing at activation any
  expression that references `_sys`.
  (b) The A1 tests that seed `_sys.` values into a projection row directly (sources (3a), (3b),
  (4); the replay test's direct SYS append) are re-driven through the real engine writer in PR B.
  (c) Type safety: `sys_value()` is any binary and the event's `values` schema is
  `{"type": "object"}`; PR B narrows ids to UUIDs and seqs to non-negative integers (in
  `sys_key?/1`/`sys_value?/1` or a per-key shape) before it starts writing.
* PR C: sentinel-actor proof, SERVICE_TASK nested Multi, dispatch-keyed `sys:step:<dispatch_id>:<i>`,
  service-path contention mapping and `SET LOCAL` in the nested call, lock-order proof.
* REQ-501: module write handlers, `owner_module` stamp, manifest hash, PinRebind rule.
* Follow-ups: share AST scan helpers between `managed_types_callers_test.exs` and
  `command_multi_callers_test.exs` after #2596; a definition-activation refusal for a SUB_PROCESS
  interface whose `inputs` OR `outputs` name a `_sys.` key (today: inputs stripped at run time,
  D-A1.6; outputs refused at run time into parent ERROR, D-A1.5); GH #2618 (type classification
  replacing the 9.2 name list); GH #2619 (solution-pack path to a process-writable unmanaged type).

## 16. Open questions: all CLOSED by supervisor rulings (revision 1)

* **OQ-1 Legacy `_sys` keys. CLOSED.** Issue: an instance whose recorded variables or completion
  payload already holds a top-level `_sys` key (accepted before PR A) would fail replay with
  `{:variable_merge_rejected, event_id, key}` (0054 D1a.2 puts replay under the refusal). Ruling:
  accepted, no replay carve-out. Result (infra, QA `letflow_qa`, record
  `runs/2026-10-15-inv-sys-vars-count-001`, 2026-10-15): `instances_with_sys_vars = 0` for all 6
  tenants (bilimbaga, bpm-default, meridian, req384-eo001-b-740d4d13, swiftroute, vortex); no
  production application database exists. A1's PR body carries this record (section 14). Per
  SECURITY the same read-only query is a GATE for PR B: re-run before PR B opens; any instance found
  is cancelled or repaired first. The query, per tenant schema `"<s>"` (operator-run, read-only,
  quoted identifier from the `tenant_schemas` registry), counts DISTINCT instance ids over the union
  of:
  1. `"<s>".instance_projections` rows whose `variables` has a top-level key `= '_sys'` or
     `LIKE '\_sys.%'` (via `jsonb_object_keys(variables)`);
  2. `"<s>".events` rows with `event_type` and payload map: `INSTANCE_STARTED` ->
     `payload->'initial_variables'`, `TASK_COMPLETED` and `SUB_PROCESS_COMPLETED` ->
     `payload->'output_variables'`, `SERVICE_TASK_COMPLETED` -> `payload->'decoded_body'`,
     `SCRIPT_TASK_COMPLETED` -> `payload->'output'`, where that object has such a top-level key;
  3. the same five event types whose payload is a `$ref`, checked on
     `"<s>".event_payload_store.payload` joined by `event_id` with the same per-type map.
* **OQ-2 Denied-name lists (9.2). CLOSED, interim.** Accepted as interim, fail closed; stable rule
  code `:writable_by_process_not_permitted`, message names the matched rule (5.2); list documented
  in the module guide (5.4); GH #2618 replaces it with type classification.
* **OQ-3 Adapter vs `StepWrites` as the implementation. CLOSED.** Adapter `EntityPortImpl` kept;
  AC reading for the A3 PR body in D-A3.6.
* **OQ-4 Removing `ScriptReadPort`. CLOSED.** The 7c-2 owner is letflow-4 (this session's
  supervisor); A3 is a refactor with the same 7c tests green.
* **OQ-5 Pack refusal. CLOSED.** Packs refuse the flag; an admin sets it after install under
  `:EntitiesDefinitionsWrite`; GH #2619 tracks a reviewed pack path.
