# WF-03 Fix Design -- ISS-0932 / Q-915 (Regulatory Compliance Review has no 21-day timer path to BaFin escalation)

Run-id: WF03-Q915-20261001
Type: fixture (definition JSON + YAML parity) + test fix. **`lib/` is unchanged.** No
decision record required (the engine contract is unchanged; the definition is brought into
conformance with it).
Issue: `docs/issues/ISS-0932.yaml` (queue Q-915, GH-2066). Diagnosis:
`handoffs/WF03-Q915-20261001/step-01-issue-fixer-diagnose.json`.
Design author: CODE-DESIGNER. Not self-reviewed; CODE-DESIGN-VALIDATOR gates this file.

## 0. Diagnosis claims re-verified against code (HANDOFF_PROTOCOL 1.1)

| Claim | Verified at | Result |
|---|---|---|
| `risk-evaluation` arms no timer; zero pending timers means advance-timer 404 | `transition.ex` `dispatch_human_task/3` (438-452) emits `{:escalation_timer_armed,...}` only if `escalation_timer_duration` is a non-empty binary; `scheduler.ex` `resolve_advance_target/3` (348-360): `[]` -> `:no_pending_timer` | confirmed |
| Edge `timeout-risk-evaluation` is dead | `transition.ex` `advance_off_completed_node/4` (538-557) and `dispatch_escalation_timer_fired/4` (699-718) both take `List.first` of the non-conditioned edges in declared order; `e3` is declared first | confirmed |
| Escalation fire follows the FIRST non-conditioned outgoing edge of the HUMAN_TASK to ANY target, skipping conditioned edges | `transition.ex` 705-717 (`really_conditioned?/1` split, conditioned edges ignored) | confirmed |
| Escalation fire into a SERVICE_TASK target creates its dispatch row | `engine.ex` `persist_escalation_timer_fired_advance/7` (2885+) calls `prepare_service_task_dispatch_abort_on_empty_url` and `build_service_task_dispatch_multi` | confirmed |
| `escalation_role` has no engine effect (no reader in the timer path) | CHK-21 (`graph.ex` ~1072-1122) validates it at definition time; `role_binding.ex` `task_roles/1` (line 37) reads it as an advisory routed role (`unbound_task_role` warning, `definitions.ex` ~1261); the engine does not read it at timer arm (`engine.ex` ~808, `transition.ex` ~443) or at timer fire (`transition.ex` ~699-718) | corrected (Q-1048 / GH #2390): it has readers, but none grants eligibility; the `role-ceo` choice to match the scenario's `ceo` actor stands |
| Undefined variable in a CEL condition evaluates to false, never raises | `expr.ex` `evaluate_condition/2` (1480-1488) + `resolve_var/3` | confirmed |

Corrections / additions to the diagnosis (all verified, see sections 2 and 3):

- C1: The diagnosis recommended making `e3` an OR-chain over the five severity values. That
  makes a normal completion of `risk-evaluation` WITHOUT `highest_severity` silently file a
  BaFin notice (fallback edge). Executed and measured (section 2). A better, zero-lib shape
  exists: condition `e3` on the constant `true`.
- C2: The diagnosis said a stale escalation timer fails with `unknown_token_id`. That is
  wrong for this graph. The token record is the same row across all hops of a sequential
  flow (`reconcile_token_records` updates `node_id` in place), `find_token_for_timer/2`
  (`engine.ex` 2609-2614) matches on `token_id` only, and nothing compares `timer.node_id`
  with the token's current node (grep of `lib/` for `timer.node_id`: no such check). See
  section 3 for the real consequence.
- C3: `body_template` is NOT rendered by the engine (section 4); only the URL is.

## 1. Chosen shape (least risky) and why

**Shape A' = diagnosis shape A, with `e3` conditioned on the constant `true` instead of an
OR-chain.** Escalation timer on the existing `risk-evaluation` HUMAN_TASK; the dead
`timeout-risk-evaluation` edge becomes its (only) non-conditioned fallback and is retargeted
to `regulatory-auto-escalation`; `e3` is demoted to a conditioned edge that always matches.

Why it is the least risky:

| Property | A' | A (OR-chain e3) | B fork+TIMER | C sequential TIMER |
|---|---|---|---|---|
| `lib/` change | none | none | yes (boundary node or END-cancels-siblings) | none |
| Normal completion behaviour vs today | identical for every variable set | differs when `highest_severity` unset (silent BaFin filing instead of today's error at `severity-routing`) | n/a | blocks flow 21 days |
| Timer path | `advance-timer` fires the only pending timer | same | parallel split without join errors at runtime (`dispatch_parallel_split`, `no_matching_join_found`) | n/a |
| Graph validation | clean (measured) | clean (measured) | clean statically, fails at runtime | clean |

Rejected: B (needs lib work + decision record), C (violates "normal path keeps working"),
D (edit the byte-identical scenario; contradicts the required outcome), A (see C1).

## 2. (a) Normal-path callers and the `e3` conditioning: verified

Callers/tests that complete `risk-evaluation` on the normal path, searched across `test/`,
`scripts/`, `web/`, `docs/` (excluding handoffs/issues/status history):

| Location | Completes `risk-evaluation`? | Sets `highest_severity`? | Affected? |
|---|---|---|---|
| `test/fixtures/uat/scenarios/meridian/regulatory-compliance-review-bafin.yaml` | no (step 2 completes only `evidence-collection`, step 3 advances the timer) | n/a | matches new shape as written (`advance_timer_node: risk-evaluation`) |
| `test/letflow/simulation/req208_meridian_test.exs` (`@simple_regulatory_review_graph`, lines 475-517) | no (stops at `risk-evaluation`, step 3 `:blocked` on ISS-0389) | n/a | **unaffected**: test-local graph, never reads the fixture JSON/YAML (grep confirmed) |
| `test/letflow/routers/tasks_test.exs` ~1883 | comment only | n/a | unaffected |
| `test/scripts/persona_actor_seed_drift_test.exs` | reads fixture, collects only map keys named exactly `"role"` with a `role-` value (`collect_roles/2`) | n/a | **unaffected**: new key is `escalation_role`, a different key; `role-ceo` is already in the meridian `ROLES` set via `ceo-override` |
| `test/letflow/scripts/qa_fixture_service_task_endpoints_test.exs` | globs `*_process_definition.json`, checks SERVICE_TASK nodes only | n/a | unaffected (no SERVICE_TASK node added or changed; one removed) |

No existing test or script completes `risk-evaluation` on the normal path, so no existing
caller sets or depends on `highest_severity` there. Production behaviour still must not
change, hence the constant condition. Measured with a scratch script (not committed) that
applied the shape to the real fixture and ran `Graph.validate_*` and `Transition.transition/3`:

| Variant of `e3` | `validate_graph` / node attrs / edge conds | `{:complete_task}` severity unset | `{:complete_task}` severity low / critical | `{:escalation_timer_fired}` (any vars) |
|---|---|---|---|---|
| `condition` = constant `true` (CHOSEN) | valid / valid / valid | -> `severity-routing` (then errors there exactly as today: no matching edge) | -> `severity-routing` | -> `regulatory-auto-escalation` |
| `condition` = OR-chain of all 5 values | valid / valid / valid | -> `regulatory-auto-escalation` (silent BaFin filing; REJECTED) | -> `severity-routing` | -> `regulatory-auto-escalation` |

Why the constant is safe: the escalation-fire path skips every "really conditioned" edge
(`really_conditioned?/1`: not `is_default` AND non-empty condition string), so `e3` is
skipped on the timer path regardless of its value; on task completion the conditioned list
is evaluated first and `true` always matches. CHK-17 accepts the literal (`expr.ex`
`identifier_token("true")` -> `{:lit, true}`; measured `evaluate_condition("true", %{}) == true`
and `validate_edge_conditions` valid). CHK-19 is satisfied because the retargeted
`timeout-risk-evaluation` is a non-conditioned fallback. Documenting intent: a JSON fixture
cannot carry comments, so the fixture `description` states it (section 5) and the contract
test asserts it by name (section 7).

## 3. (b) The pending escalation timer after normal completion: re-analysed

Facts (verified):

1. The only timer cancellation is `TaskActivation.cancel_pending_timers/5`, called when the
   instance becomes `:completed` (`engine.ex` 1965) and on cancel (`engine.ex` ~5014).
   Completing the HUMAN_TASK does not cancel its escalation timer.
2. So after a normal `risk-evaluation` completion the P21D timer stays `pending` until the
   instance ends (then cancelled cleanly with reason `instance_completed`) or until it
   fires at day 21 after arming.
3. If the instance is still `:active` at that moment (for example parked at
   `findings-sign-off` or `ceo-override`), the poller fires the stale timer. The token is the
   same row, so `find_token_for_timer/2` succeeds, and `advance_after_escalation_timer_fired/3`
   dispatches `{:escalation_timer_fired, token}` against the node the token is CURRENTLY at:
   - at a HUMAN_TASK (`findings-sign-off`, `ceo-override`): that task is cancelled and the
     first non-conditioned edge is followed (`timeout-findings-sign-off` ->
     `cro-sign-off-timeout`; or `fallback-ceo-override` -> `archive-review`, i.e. an
     unintended auto-archive);
   - at any other node type: `{:token_not_at_human_task_for_escalation, ...}`, the fire
     transaction rolls back and the poller retries until the timer is marked exhausted.

Classification: a latent **pre-existing engine defect** shared by every HUMAN_TASK that
carries `escalation_timer_duration` (swiftroute `ops-review` PT2H has the same exposure),
not introduced by this fix. It cannot be solved in the definition (the only definition-level
lever would be to remove the timer, which is the required behaviour). It does not affect the
normal path within the UAT/QA window (instances complete or are cancelled long before day 21,
and `advance-timer` is explicit).

**Decision: `lib/` stays unchanged in this fix.** Justification: the minimal engine guard
(skip/cancel an escalation timer whose `timer.node_id` differs from the token's current
node, or cancel the token's pending escalation timers on HUMAN_TASK completion) touches the
timer/instance transaction path used by every tenant, needs its own design, tests across all
escalation definitions, REVIEWER and probably SECURITY-REVIEWER review, and is independent
of this definition fix. **Follow-up (resolved here, not an open question):** ORCH files a
separate issue "stale HUMAN_TASK escalation timer fires against the token's current node"
with the three facts above as its evidence. This fix adds no test that pins the stale-timer
behaviour (to avoid cementing a defect); the engine test in section 7 asserts only the
fire-on-time path.

## 4. (c) `body_template` and reason `sla_breach_30_days`

Verified: `body_template` is read verbatim from node attributes
(`service_task.ex` `parse_config_from_node_attributes/1`, line 226), copied unrendered into
`config_snapshot["body_template"]` (`engine.ex` `config_snapshot_map/3`, line 1117), and sent
as the HTTP body (`service_task_dispatcher.ex` 719/741/800). The only renderer is
`render_service_task_url/2` (`engine.ex` 1152), which handles `{{variables.KEY}}` in the URL
and explicitly states that `body_template` rendering is out of scope (comment 1141-1147).
Therefore:

- a placeholder such as `{{variables.reason}}` in `body_template` would be sent literally;
- a literal `{"reason":"sla_breach_30_days"}` would be correct for the timer inbound path but
  WRONG for the other inbound edge `e10` (post-remediation-check, `remediation_status ==
  'unresolved'`), which would then misstate the regulatory reason to BaFin. A wrong reason
  on a regulatory filing is worse than a missing one.

**Decision: do NOT add `body_template` in this fix.** `regulatory-auto-escalation` keeps one
shared node and both inbound edges (`e10` and `timeout-risk-evaluation`). The fix's required
outcome (advance-timer succeeds, flow runs the service task, ends at `end-closed`, instance
COMPLETED = scenario EO-001 and EO-003) is met. Scenario EO-002 (payload contains reason
`sla_breach_30_days`) is NOT satisfiable without either per-path bodies or `body_template`
rendering; both are out of this fix's scope (new node ids would also change EO-001's audit
node name, and rendering is a lib feature). **Follow-up (resolved here):** ORCH files a
separate issue "SERVICE_TASK body_template is not rendered; BaFin notice cannot carry a
per-path reason (scenario EO-002)". UAT-RUNNER should expect EO-002 to remain open after this
fix; EO-001 and EO-003 are the acceptance signals for ISS-0932.

## 5. Exact definition changes

Target 1 (the real artifact): `test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json`.

Top-level:

| Field | Old | New |
|---|---|---|
| `version` | `"1.1"` | `"1.2"` (mandatory: `seed_meridian_definition.sh` replaces the ACTIVE definition only when the fixture version is strictly newer under `sort -V`; the same name+version returns 409) |
| `description` | `"Periodic BaFin-mandated compliance review. Compliance Officer collects evidence; Risk Manager evaluates. Critical findings spawn a remediation sub-process. Exercises: timer boundary event, conditional sub-process, DLQ path."` | `"Periodic BaFin-mandated compliance review. Compliance Officer collects evidence; Risk Manager evaluates within 21 days. If risk-evaluation is still open when its P21D escalation timer fires, the flow auto-escalates to a BaFin regulatory notice and closes. Critical findings spawn a remediation sub-process. Exercises: HUMAN_TASK escalation timer, conditional sub-process, DLQ path. Edge e3 carries the constant condition 'true' on purpose: it always wins on normal task completion but is skipped by the escalation-timer path, which follows the single non-conditioned edge timeout-risk-evaluation."` |

Nodes:

| Node | Change |
|---|---|
| `risk-evaluation` (HUMAN_TASK) | `attributes` becomes `{role: "role-risk-manager", escalation_timer_duration: "P21D", escalation_role: "role-ceo"}` (old: `{role}` only) |
| `risk-evaluation-timeout` (SERVICE_TASK) | **DELETE the node** (it would otherwise be isolated, CHK-04) |
| every other node | unchanged (including `regulatory-auto-escalation`: same endpoint `https://httpbin.org/anything/compliance/regulatory-notice`, method POST, timeout_ms 300000, no `body_template`) |

Edges:

| Edge id | Old | New |
|---|---|---|
| `e3` | `risk-evaluation` -> `severity-routing`, no condition | same source/target; add `"condition": "true"` |
| `timeout-risk-evaluation` | `risk-evaluation` -> `risk-evaluation-timeout`, no condition | `risk-evaluation` -> `regulatory-auto-escalation`, no condition, no `is_default` (it is now the ONLY non-conditioned outgoing edge of `risk-evaluation`) |
| `e4` | `risk-evaluation-timeout` -> `severity-routing` | **DELETE** |
| all others (`e0`,`e1`,`e2`,`e5`..`e17`, `timeout-evidence-collection`, `timeout-findings-sign-off`, `fallback-ceo-override`) | unchanged | unchanged |

Edge declaration order must keep `e3` before `timeout-risk-evaluation`? Not required: `e3`
is conditioned, so the partition ignores declaration order between them. The structural
test (section 7) asserts exactly-one non-conditioned outgoing edge, which is what makes
order irrelevant.

Resulting `risk-evaluation` outgoing edges: `e3` (conditioned `true`, -> `severity-routing`)
and `timeout-risk-evaluation` (fallback, -> `regulatory-auto-escalation`).

Runtime result (derived from the verified code paths in sections 0 to 3): when
`evidence-collection` completes, the token lands on `risk-evaluation`, one task row and one
`timers` row (`timer_type "escalation"`, `node_id "risk-evaluation"`, `fire_at` = arm time +
21 days) are created in the same transaction. `POST /instances/:id/advance-timer` without a
`timer_id` resolves that single pending timer, `Scheduler.fire_timer/2` cancels the task
(`task.cancel` audit), moves the token to `regulatory-auto-escalation`, creates a pending
`service_task_dispatches` row; after the dispatcher advances it, `e5` -> `end-closed`,
instance `:completed`.

Target 2 (parity; narrative source of truth named in `scripts/seed_meridian_definition.sh:39`):
`test/fixtures/simulation/meridian/process_policy_binding.yaml`. Apply the identical graph
changes: `risk-evaluation` attributes (YAML keys `escalation_timer_duration: P21D`,
`escalation_role: role-ceo`), delete node `risk-evaluation-timeout` and edge `e4`, `e3` gets
`condition: "true"`, `timeout-risk-evaluation` target `regulatory-auto-escalation`, replace
the comment `# on_timeout for risk-evaluation` with `# escalation timer (P21D) fallback for
risk-evaluation -> BaFin notice`, apply the same `description` change (YAML folded form).
Keep `version: "1.0"` and the relative `POST /...` endpoints (ISS-0930 precedent: the YAML
is narrative and intentionally diverges on those two items).

Target 3: `test/fixtures/uat/process-definition-aliases/proc-meridian-regulatory-compliance-review.yaml`
-- **no edit** (maps `process_id` to `definition_name` only; lookup is by name and survives a
version bump).

Target 4: `scripts/seed_meridian_definition.sh` header comment lines 5-6: change the
Regulatory Compliance Review label from `v1.1` to `v1.2` (comment only; the version used at
run time comes from `jq -r '.version'` on the fixture, so no logic changes). Optional for
correctness, listed so the comment does not drift.

QA re-seed (`scripts/seed_meridian_definition.sh`) is an ops step after merge, not a repo
change; no QA data or DB change is part of this fix.

## 6. (d) Version, description, parity: summary of rules

- JSON `version` 1.1 -> 1.2 is mandatory; YAML stays 1.0 by precedent.
- Both descriptions drop the phrase "timer boundary event" (the engine has no boundary-event
  concept; the wording caused the original mis-port).
- The scenario file `test/fixtures/uat/scenarios/meridian/regulatory-compliance-review-bafin.yaml`
  is a byte-identical R-Co port and MUST NOT be edited; its prose still says "timer boundary".

## 7. (e) Regression tests (exact specification)

Two new files. No existing test file is modified. Both fail on the current v1.1 fixture
(fail-first) and each assertion below names the old-shape defect it catches.

### 7.1 `test/letflow/scripts/regulatory_review_timer_path_fixture_test.exs`

Module `Letflow.Scripts.RegulatoryReviewTimerPathFixtureTest`, `use ExUnit.Case, async: true`,
`@moduletag :unit`. No DB, no HTTP. Models `seed_swiftroute_definition_test.exs`
(`File.read!` + `Jason.decode!`, `YamlElixir.read_from_file/1`). Loads the JSON fixture,
builds the graph via `Letflow.Definitions.Graph.from_map/1`, builds
`Letflow.Engine.InstanceState` with one `Letflow.Engine.Token` at `risk-evaluation`, and
drives `Letflow.Engine.Transition.transition/3` (pure).

| Test id | Assertion | Fails on old fixture because |
|---|---|---|
| T1 | `version == "1.2"` | old is "1.1" |
| T2 | `description` does not contain "timer boundary event" | old contains it |
| T3 | `Graph.validate_graph/1`, `validate_node_attributes/1`, `validate_edge_conditions/1` all `valid: true` with `violations: []` | (guards the deletion of `risk-evaluation-timeout`/`e4`: an orphan would yield `:isolated_node`; also guards CHK-19/CHK-21) |
| T4 | `risk-evaluation` attributes have `escalation_timer_duration == "P21D"`, `escalation_role == "role-ceo"`, `role == "role-risk-manager"` | old has role only |
| T5 | `risk-evaluation` has exactly ONE outgoing edge that is not "really conditioned" (blank/nil condition or `is_default`), its id is `timeout-risk-evaluation`, its target is `regulatory-auto-escalation` | old: fallback targets `risk-evaluation-timeout` and `e3` is also non-conditioned (two) |
| T6 | edge `e3` has `condition == "true"` and target `severity-routing` | old: no condition |
| T7 | no node `risk-evaluation-timeout` and no edge `e4` exist | old has both |
| T8 | `regulatory-auto-escalation` has exactly two inbound edges, `e10` and `timeout-risk-evaluation`, and one outbound edge `e5` -> `end-closed`; node has no `body_template` attribute (pins the section 4 decision so a literal reason is not added unreviewed) | old has one inbound |
| T9 | Transition `{:escalation_timer_fired, token}` with variables `%{}` -> token at `regulatory-auto-escalation`; same with `%{"highest_severity" => "low"}` | old -> `severity-routing` |
| T10 | Transition `{:complete_task, token}` with `%{"highest_severity" => "low"}` and with `"critical"` -> token at `severity-routing` | (normal-path guard; passes on old, kept to catch regressions of e3) |
| T11 | Transition `{:complete_task, token}` with variables `%{}` (severity unset) -> token at `severity-routing`, NOT `regulatory-auto-escalation` | catches the OR-chain variant (mutant M4); passes on old |
| T12 | Parity with `test/fixtures/simulation/meridian/process_policy_binding.yaml`: node-id set equal, edge-id set equal, `risk-evaluation` escalation attributes equal, `e3` condition equal, `timeout-risk-evaluation` target equal | YAML not yet updated on old |

### 7.2 `test/letflow/engine/regulatory_review_timer_path_test.exs`

Module `Letflow.Engine.RegulatoryReviewTimerPathTest`, `use Letflow.DataCase, async: false`
(real Postgres, provisioned tenant; same harness and `setup` Sandbox `:auto` as
`test/letflow/engine/human_task_escalation_test.exs` and
`test/letflow/engine_catalog_service_task_test.exs`). Loads the real fixture JSON
(`graph` key) and creates + activates it with `Definitions.create/2` + `Definitions.activate/2`
under a unique name and the fixture's own version. No new support modules.

Test E1 (the end-to-end required outcome), steps:
1. `Engine.create/2` with `initial_variables` `%{"review_id" => "sim-q915-001"}`; find the
   single pending `evidence-collection` task and `Engine.complete_task/3` it (empty
   `output_variables`, as in `engine_catalog_service_task_test.exs` helper `complete/2`).
2. Assert projection `:active`, `current_nodes` contains `risk-evaluation`; exactly one
   pending task at `risk-evaluation` assigned to `role-risk-manager`.
3. Assert `Scheduler.resolve_advance_target(instance_id, nil, schema)` returns
   `{:ok, %Timer{timer_type: "escalation", node_id: "risk-evaluation", status: "pending"}}`
   (this is exactly the resolver the `advance-timer` router calls; old fixture returns
   `{:error, :no_pending_timer}` = the 404 of ISS-0932). Assert `fire_at` is within one
   minute of `created_at` + 21 days.
4. `Scheduler.fire_timer(timer.id, schema)` returns `{:ok, :fired}` (the second call the
   router makes).
5. Assert the `risk-evaluation` task is `:cancelled`; projection `current_nodes ==
   ["regulatory-auto-escalation"]`; exactly one `service_task_dispatches` row with
   `node_id "regulatory-auto-escalation"`, `status "pending"`, `config_snapshot["rendered_url"]
   == "https://httpbin.org/anything/compliance/regulatory-notice"`; no event of type
   `EXECUTION_ERROR`.
6. Service task stub, per the existing pattern in `engine_catalog_service_task_test.exs`
   (no HTTP is made: the dispatcher poller is not run; the test performs the poller's
   re-entry itself): update the dispatch row to status `"advanced"` (helper identical to
   `mark_advanced!/2`) and call `Engine.advance_after_service_task_outcome(row.id,
   {:advance, %{}}, Repo, schema)`; expect `{:ok, :advanced}`.
7. Assert projection `status == :completed`; the instance's token record has `status
   :completed` and `node_id "end-closed"` (scenario EO-003); no `end-reopened`; no pending
   `service_task_dispatches`; no remaining `pending` timers for the instance.

Test E2 (normal path, no-dangling-trouble guard): same setup through step 2, then complete
the `risk-evaluation` task with `output_variables` `%{"highest_severity" => "low"}`. Assert
the result is `{:ok, ...}` with instance `:active`, `current_nodes == ["findings-sign-off"]`,
the `risk-evaluation` task `:completed` (not `:cancelled`), a pending task at
`findings-sign-off` assigned to `role-cro`, and no `service_task_dispatches` row. The test
stops there. (Deliberately no assertion about the still-pending escalation timer; see
section 3.)

If step 6/7 of E1 shows `advance_after_service_task_outcome/4` does not drive END to
`:completed` for a reason unrelated to the fixture, the tester records it as a finding
rather than weakening E1; the code path (`persist_service_task_advance` ->
`advance_until_stable` -> reconcile projection) was read and is expected to complete.

### 7.3 Fail-first and mutation targets

Fail-first: run both files against the CURRENT fixture before editing it. Expected: T1, T2,
T4, T5, T6, T7, T8, T9, T12 fail; T3, T10, T11 pass (they guard the new shape and the normal
path against regression); E1 fails at step 3 (`{:error, :no_pending_timer}`); E2 passes (it
is the normal-path regression guard). The mutation table below supplies the red result for
the tests that pass on the old shape.

Mutation targets (apply to an in-memory or temporary copy of the NEW fixture; each must turn
the named test(s) red, then be reverted):

| Id | Mutation (reintroduces the old shape or a near-miss) | Must fail |
|---|---|---|
| M1 | remove `escalation_timer_duration` and `escalation_role` from `risk-evaluation` | T4, E1 step 3 |
| M2 | retarget `timeout-risk-evaluation` to `risk-evaluation-timeout` and restore that node + `e4` | T5, T7, T9, T12, E1 |
| M3 | remove `e3`'s condition (two non-conditioned edges; `e3` declared first wins on fire) | T5, T6, T9, E1 |
| M4 | replace `e3` condition with the OR-chain over the five severities | T6, T11 |
| M5 | change `escalation_timer_duration` to `"P30D"` | T4, E1 step 3 fire_at window |
| M6 | restore `risk-evaluation-timeout` as an unconnected node (keep `e4` deleted) | T3, T7 |
| M7 | remove edge `e5` (`regulatory-auto-escalation` -> `end-closed`) | T8, E1 step 7 |
| M8 | remove `escalation_role` only (CHK-21 co-requirement) | T3, T4 |
| M9 | add a `body_template` with a literal reason to `regulatory-auto-escalation` | T8 |
| M10 | revert only the YAML (leave JSON new) | T12 |

## 8. Files

To edit:
1. `test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json` (section 5)
2. `test/fixtures/simulation/meridian/process_policy_binding.yaml` (section 5, parity)
3. `scripts/seed_meridian_definition.sh` (header comment lines 5-6 only)
4. NEW `test/letflow/scripts/regulatory_review_timer_path_fixture_test.exs`
5. NEW `test/letflow/engine/regulatory_review_timer_path_test.exs`
6. NEW `test/specs/ISS-0932.md` (TEST-DESIGNER's spec, per the ISS-0931 precedent)
7. `docs/issues/ISS-0932.yaml` (status/resolution on close, DOC-UPDATER)

Confirmed unaffected (read and reasoned above):
`lib/**` (including `engine/transition.ex`, `engine.ex`, `scheduler.ex`, `definitions/graph.ex`,
`routers/instances.ex`, `api/authorization.ex`),
`test/fixtures/uat/scenarios/meridian/regulatory-compliance-review-bafin.yaml` (byte-identical port),
`test/fixtures/simulation/meridian/scenarios/regulatory-compliance-review-bafin.yaml`,
`test/letflow/simulation/req208_meridian_test.exs`,
`test/fixtures/uat/process-definition-aliases/proc-meridian-regulatory-compliance-review.yaml`,
`test/scripts/persona_actor_seed_drift_test.exs` (re-run it; expected green),
`test/letflow/scripts/qa_fixture_service_task_endpoints_test.exs` (re-run; picks the edited fixture up through its glob, expected green),
`test/letflow/scripts/seed_swiftroute_definition_test.exs`, all other `test/fixtures/qa/*.json`.

## 9. `lib/` and authorization

`lib/` is unchanged. Authorization is unchanged: `POST /instances/:id/advance-timer` and the
`:InstancesAdvanceTimer` permission already exist (`routers/instances.ex` ~356,
`api/authorization.ex` ~564, 998, 1186) and `resolve_advance_target/3` selects the single
pending timer regardless of `timer_type`. Whether the UAT actor ("ceo", `actor-meridian-eva`)
holds `:InstancesAdvanceTimer` is a persona-grant matter outside this fix and was not
verified here. No tenant-data-path code changes, so SECURITY-REVIEWER is not triggered;
CODE-DESIGN-VALIDATOR and REVIEWER gates apply per WF-03.

## 10. Acceptance-criteria map

| Handoff criterion | Where |
|---|---|
| Least risky shape with justification, addresses (a)-(e) | sections 1, 2 (a), 3 (b), 4 (c), 5-6 (d), 7 (e) |
| Exact node/edge/attribute changes | section 5 |
| Tests with file names, fail-first, mutation targets | sections 7.1-7.3 |
| Files to edit / confirmed unaffected | section 8 |
| lib/ unchanged or justified | sections 3 and 9 |
| No implementation code | this document carries tables and prose only |

## 11. Open questions

None blocking. Two follow-up issues are decided here and are for ORCH to file (not decisions
awaiting sign-off): (1) stale HUMAN_TASK escalation timer fires against the token's current
node (section 3); (2) SERVICE_TASK `body_template` is not rendered, so scenario EO-002's
per-path reason cannot be met (section 4).
