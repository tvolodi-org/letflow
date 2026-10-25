# 0067 -- Form-validation script hook (Record F, hook 3): a script verdict inside the locked complete_task transaction

Status: PROPOSED by the developer of GH #3184 (REQ-559 slice 0, task T-0505), 2026-10-25. Needs
SECURITY-REVIEWER and REVIEWER sign-off (see Sign-off). Changes no code: every implementation slice
is its own requirement (D9).

Date: 2026-10-25

Depends on: [0050](0050-foundation-modules-org-catalog-and-reference-contract.md) (F2);
[0051](0051-org-scoped-role-grants-and-enforcement.md) (T12, T13);
[0053](0053-tenant-scripted-rules.md) (hook 3, "Row-lock answer", D1, D5, D7, D8, T10);
[0054](0054-process-step-writes-entity.md) (D3 lock order);
[0061](0061-engine-lock-order-platform-invariant.md) (items 1 and 2);
[0062](0062-restriction-carrying-variables.md) (R4, R5, R6);
[0065](0065-entity-pre-write-script-hook.md) (Record E, REQ-539: D1, D2, D4, D6);
GH #2534 (tenant script runtime, merged).

## Map of REQ-559 description items

| REQ-559 item | Where |
|---|---|
| (1) where hook 3 runs, which transaction, time budget against the 50 ms rule | D1, D6 |
| (2) the pure-function contract, the script cannot change the output | D2 |
| (3) pinning, the closed pin-kind set | D3 |
| (4) principal and field restrictions | D4 |
| (5) failure mapping of every executor outcome, INV-8 | D5 |
| (6) refusal shape, INV-2, INV-5 | D8 |
| (7) slice list | D9 |
| INV-1, INV-3 | D7 |
| consistency, owner questions | Consistency with earlier records, Not decided here |

## Problem

Decision 0053 names "Record F, form-validation script hook" (hook 3, "runs in the locked `complete_task`
transaction") as direction only. Its "Row-lock answer" says: "the 50 ms rule does not constrain hook 1; it
binds hooks 3 (and 2 after REQ-484), which are direction here." Record E (0065) is the binding record
for hook 2 and rules the read transaction, the F13 atomicity rule and the pin kind for a hook that reads
data. This record decides hook 3 and reuses those rulings; it states an "Amends" line wherever hook 3
needs a different one. Today `Letflow.Engine.complete_task/3` has one caller in `lib/` (the
`Routers.Tasks` route), runs the completion guards in the same transaction that holds the task and
instance-projection locks, and has no script step.

## D1. Where hook 3 runs, and in which transaction

Hook 3 runs INSIDE the `complete_task` transaction (as 0053 and REQ-559 item 1 say), as a new Multi step
`:form_validation_hook` in `build_complete_task_multi`, placed AFTER `maybe_redacted_sentinel_check` (0062
R8) and BEFORE `:form_expression_reevaluation` and `:transition`.

Order of the existing steps up to the hook: `:task` (`fetch_and_lock_task`), `maybe_f1_scope`,
`:instance_projection` (`fetch_and_lock_instance_projection`), `:snapshot_and_state`, `:completion_guards`
(`check_completion_guards`), the sentinel check. Reasons for the position:

- every cheap pure refusal (`:completion_guards`, sentinel) happens first, so the sandbox is not started
  for a completion that is refused anyway;
- the hook sees the SUBMITTED output (the re-evaluation of form expressions comes later and is not shown
  to it);
- `:lock_ancestors`, the entity-type sequence rows and the audit chain row (0061 items 3 to 8) are taken
  after it, so while the script runs the transaction holds exactly the `tasks` row and the instance
  projection row.

**A script refusal is not a completion guard.** `check_completion_guards` is pure and runs without the
sandbox; it stays pure and unchanged. The hook is its own step with its own typed error,
`{:error, {:completion_refused, {:form_hook_refused, ...}}}`. A task whose node names no hook gets no new step:
its Multi is byte-identical to today.

**Reads and transaction.** Hook 3 has NO declared entity reads in this record. Its input is the submitted
output, the form definition version and the task facts, built by the host from rows the transaction has
already read (`:task`, `:snapshot_and_state`), with no extra query. So no read-transaction question arises.

Record E D1 reads: "a short READ COMMITTED read-only transaction on its own connection, released before the".
That separate read phase cannot be reused here: the two locks are already held when the script runs.

- **Amends 0065 D1, in this respect only:** hook 3 has no read phase and no separate connection. A hook 3
  with declared reads needs its own record, and 0053 D5's last bullet still holds (no dynamic data API is
  introduced).

**The sandbox task never opens its own connection** (0053 D5, T10). The sandbox task holds none; the one
connection of the transaction is the caller's, and no host function reaches `Repo`.

**F13 rule.** Record E D2 reads: "Mechanism: version check under the entity-type sequence locks, retry the whole hook, then a typed failure." It is
reused as the rule for any later hook with reads. It does not apply to hook 3 today: hook 3 stores no
derived value (its output is accept or refuse) and reads nothing outside the transaction's own rows.

**Process-step and automatic completions.** Today `Routers.Tasks` is the only completer of a task
(`complete_task(` has one caller in `lib/` outside `lib/letflow/design/`). Any future completer runs the hook
too and fails closed; a path may not skip it.

## D2. The pure-function contract

Hook 3 is a pure function `(input) -> accept | refuse`.

- **Input:** `output` (the submitted variables, filtered by D4); `form` (`definition_id`,
  `definition_version`, `node_id`, form schema version hash); `task` (`id`, `node_id`, assignee kind only,
  `ctx.now` = completion time, passed as data, since determinism is a 0053 D5 rule).
- **Output**, validated against the manifest output schema before use: `{"ok": true}` or
  `{"ok": false, "code": <one of the manifest `refusal_codes`>, "fields": [{"field": <name in the manifest
  `fields`>, "code": <manifest message code>}]}`. At most 64 KiB (0053 D7) and a maximum number of `fields`
  entries (the number is under Not decided here, and never above the D7 cap).
- **The script cannot change the submitted output.** The host passes a copy and discards everything but the
  verdict. Any extra key in the output is `output_invalid`.
- **Messages are manifest-declared codes** that the form renders, never free script text (0053 T12 on script
  text reaching a tenant surface).

## D3. Pinning

- Definition fields: HUMAN_TASK node attributes `validation_script_key` and `validation_script_version`
  (parallel to `script_key` and `script_version` of hook 1).
- Pin kind. Record E D4 reads: "The closed pin-kind set (`:catalog_entry | :variable_schema | :module | :script` in `pin_resolver.ex`) is".
  Here too the set is NOT extended. A task completion has an instance, so the existing instance pin of kind `:script` is reused,
  frozen at `INSTANCE_STARTED` with the sha256. `collect_script_bindings/1` today reads SERVICE_TASK nodes only; slice F-1
  extends it to read HUMAN_TASK nodes and keeps its `script_version_conflict` rule (two versions of one
  key in one definition are refused).
- **Amends 0065 D4:** Record E uses a tenant-schema binding table because "a record write has no instance".
  A task completion has one. The instance pin is correct here, and a binding table would let a running
  instance change behaviour mid-flight.
- The `hook_kind` value `form_validation`, reserved in 0053 D1, becomes accepted (as 0065 D4 does for
  `entity_write`). A script of another kind cannot be named. Activation of a definition refuses an
  unknown, unpublished or revoked key and a wrong kind.
- Run time: an attribute present but the pin missing, a sha256 mismatch, or a `revoked` version is
  `script_rejected`: fail closed. Completing without running the hook is never allowed. Instances started
  before the attribute existed carry neither the attribute nor a pin and are unchanged.

## D4. Principal and restrictions

- The script runs as the tenant-wide script principal without user grants (0053 D5). The invoking actor id
  is recorded for attribution only.
- Restricted or labelled submitted variables are omitted from `input` unless the manifest input schema
  names them AND the publisher held `EntitiesRestrictionsManage`, re-checked at run time. 0062 R6 (opt-in)
  extends to hook 3.
- A refusal never contains a value. `fields[].field` must be in the manifest-declared set.
- 0062 R4 (taint of a run's outputs) has no target here because hook 3 writes nothing; R5 is not
  applicable. This is stated, not skipped.

## D5. Failure mapping (INV-8)

Every executor outcome becomes a stable code and a stated effect. 0053 D7 reads: "Any future hook that runs in or beside a transaction must convert every executor outcome (including exit and crash) to a typed `{:error, code}` without raising."
For every refusal below the task stays pending, the instance is unchanged, and the transaction rolls back.

| outcome | tenant code | effect |
|---|---|---|
| script `refuse` verdict | `form_hook_refused` plus the manifest code and fields | completion refused (D8) |
| script error | `script_error` | refused |
| instruction budget | `budget_exceeded` | refused |
| memory limit | `memory_limit_exceeded` | refused |
| wall clock exceeded | `timeout` | refused (D6) |
| invalid output | `output_invalid` | refused |
| admission refused (`{:error, :capacity}`) | `script_busy` | transaction rolled back, locks released, short backoff outside the transaction, the whole completion re-run; at most 3 attempts in total, then refused as `script_busy` |
| sandbox task or watchdog crash or exit inside the locked transaction | `script_error` | refused. The Multi step catches the DOWN and returns `{:error, ...}`; it never raises. Ecto rolls back and the connection is returned |
| caller crash | none | the watchdog kills the worker (0053 D7), the transaction dies with the caller, nothing is committed |
| kill switch on | `script_rejected` | refused |
| pin missing, sha mismatch, revoked | `script_rejected` | refused |

0053 D7 also reads: "Only `script_busy` is retriable; the rest are not." That is kept. A `script_busy` retry
re-runs the pure hook before any effect is committed. No `Exception.format` or `inspect` text reaches a
tenant. The implementing slice (F-4) requires **one test per row of this table**, including a test that a
crash of the sandbox task inside the locked transaction leaves no open transaction (the next `Repo`
checkout on the same pool sees the task row unlocked and `pending`).

Every outcome appends an audit record (key, version, sha256, input HMAC, outcome class, duration,
instructions, heap words, actor id; no values): an accepted one inside the completion Multi, a rejected one
in its own short transaction after the rollback.

- **Amends 0065 D6:** Record E retries `script_busy` inside its total of 3 attempts around a hook that holds
  no lock. Hook 3 must not wait while holding the task and projection locks, so a retry is a rollback and a
  re-run of the whole completion, with the same total of 3 attempts.

## D6. Lock and time budget

Locks held while the hook runs: the `tasks` row (`fetch_and_lock_task`, FOR UPDATE) and the instance
projection row (`fetch_and_lock_instance_projection`, FOR UPDATE), and nothing from 0061 items 3 to 8. The
hook runs after the `:completion_guards` Multi step has passed, so the guards have already read their data.
No new lock class and no new position is introduced, so 0061 is unchanged. Waiters on the two rows are
bounded by the existing `Contention.lock_timeout_ms/0`.

**Wall clock.** The hook uses the 0053 D7 mechanism (watchdog, clamp). The 50 ms rule binds hook 3 (0053),
and the script is inside the locked window, so there is no script-free window to measure instead (compare
0065 D3). This record therefore rules: **the enforced wall clock of hook 3 is at most 50 ms; manifest values
are clamped to it, and no default above it ships.** Slice F-2 sets the shipped default at or below 50 ms,
after measuring sandbox creation plus spawn on the actual runtime. Any figure between 50 ms and the 0053 D7
maxima (default 1000 ms, maximum 5000 ms) and anything above those maxima is under Not decided here and
is not set silently.

**When exceeded:** the run ends as `timeout`, the completion is refused with that stable code, the locks are
released at rollback, and there is no partial write (every write of the completion comes after the hook
step).

## D7. INV-3 and INV-1

- **INV-3.** Hook 3 runs only under the existing sandbox allow-list, the mandatory heap cap and
  `ScriptAdmission` with caller monitoring (0053 D7, D8). The script has no network, file-system or
  other-tenant access, and no host function that touches `Repo`. Its output is validated against the manifest output
  schema before it is acted on.
- **INV-1.** The only data the hook sees is what the transaction already read under the tenant `:prefix`.
  A script key named by a form definition resolves only inside the tenant's `script_rules` under the
  run-context `:prefix`.
- **INV-10 test, required in the implementing slice:** tenant A's form definition names a script key;
  a caller of tenant B completes tenant A's task: the answer is byte-identical to the not-found answer for
  an unknown task id.

## D8. Refusal shape (INV-2, INV-5)

- A script refusal is HTTP 422 with the constant top-level `code` `form_hook_refused`, a sibling of
  `output_refused` (the `Error.output_refused/2` pattern). The body carries the manifest code and a
  `fields` list of `{field, code}`. It never carries script source, key, version, sha256 or a value. A form
  can show it as a field-level validation error, not a 500.
- Infrastructure outcomes (D5) carry their stable code only; the HTTP status of each is chosen in F-4, none is
  a 500 and none raises.
- `Tasks.authorize_completion/3` and the hidden-label check run in `Routers.Tasks` BEFORE
  `Engine.complete_task/3`. A caller who may not complete the task never reaches the hook and gets the
  answer it gets today for that task, so the hook adds no signal. A caller with no visibility of the task
  (another tenant, unknown id) gets the byte-identical not-found.
- **Deliberate deviation from REQ-559 criterion 7:** for a caller who has visibility but is the wrong
  assignee, the existing answer is 403 (ISS-0942), not the not-found answer. This record does not change it,
  because collapsing it to 404 would reverse a settled choice and its test pins in a decision-only slice.
  The question goes to the owner under Not decided here.

## D9. Slices

Each is one change. `[SECURITY-REVIEWER: mandatory]` marks a tenant-data slice.

- **F-1 pin and registry** `[SECURITY-REVIEWER: mandatory]`: accept the `form_validation` hook kind in
  `Scripts.Runtime`, the HUMAN_TASK attributes, the activation checks, the `collect_script_bindings`
  extension, and the INV-10 cross-tenant test. Depends on 0053 slice 7c (merged).
- **F-2 runtime and input builder** `[SECURITY-REVIEWER: mandatory]`: runner entry, manifest `refusal_codes`
  and `fields`, restriction filter, output validation, executor-outcome conversion, the measured default
  budget. No engine integration. After F-1.
- **F-3 completion integration** `[SECURITY-REVIEWER: mandatory]`: the `:form_validation_hook` step,
  rollback-and-rerun for `script_busy`, the 422 mapping, guard-order and sentinel-order tests, a lock-set
  test (only the `tasks` and projection rows are held). After F-2.
- **F-4 failure mapping and audit** `[SECURITY-REVIEWER: mandatory]`: one test per D5 row including a
  sandbox crash in the locked transaction, the audit rows, the kill switch. After F-3.
- **F-5 dry-run and UAT**: dry-run of a `form_validation` script against a draft payload (no write, no
  tenant-data read, so no SECURITY-REVIEWER marker), then `uat_design` scenarios. After F-4.

## Consistency with earlier records

- **0050 (F2)** reads: "0051 T12/T13 scope rules apply to the same paths." Not amended: hook 3 writes
  nothing, so the managed-type rule of F2 does not apply to it.
- **0051 (T12)**: the passage on write paths reads "and to 0053 hook 2:" and names the engine write path.
  Not amended: hook 3 is not a write path, so T12 and T13 do not apply.
- **0053** is clarified, with these lines amended or confirmed:
  - "Consequence: the 50 ms rule does not constrain hook 1; it binds hooks 3 (and 2 after REQ-484), which are direction here." AMENDED: hook 3 is now binding and the rule is applied as the 50 ms wall-clock cap of D6.
  - D1 reads "`entity_write | form_validation | entity_event` reserved for Records E/F/T": `form_validation` becomes accepted (D3).
  - D5, last bullet (dynamic data API for Records E/F): not used by hook 3 (D1).
  - D7 "Only `script_busy` is retriable; the rest are not." Kept (D5); the retry is a whole-completion re-run.
- **0054** reads: "hook 2 (Record E), after-commit triggers (Record T)" as not decided. Not amended: hook 3
  adds no `entity_writes` interaction and the D3 lock order is untouched.
- **0061**: rule 1 reads "Every engine transaction that takes several of these row classes takes them in this order, nothing is taken out of order, and a path takes a subsequence:". Not amended: the hook window holds items 1 and 2
  only and takes no new lock.
- **0062**: the heading "**R6. Opt-in, publish and run time (hook 1 scripts).**" is AMENDED to cover hook 3
  scripts (opt-in, D4). R5 is not applicable (D4).
- **0065 (Record E)**:
  - D1 reads "Hook 2 runs BEFORE the write transaction, outside every lock and every pool connection." Not the case for hook 3, which the requirement places in the locked transaction: AMENDED (D1, no read phase).
  - D1 also refuses the process-step path because of the sentence "wall clock would hold the instance mutex."
    Record F runs a script while holding that same lock, the instance projection row. It differs because its
    enforced cap is 50 ms or less (D6) and because REQ-559 and 0053 place hook 3 in the locked transaction.
    AMENDED in that respect only; Record E's refusal for hooks 2 stands.
  - D4 pin: AMENDED, instance `:script` pin instead of a binding table (D3).
  - D6 `script_busy`: AMENDED, whole-completion re-run (D5); the 3-attempt total is reused.
  - D2 (F13) and the failure-table style are reused unchanged.

## Not decided here

Owner-only or later-record questions:

- The exact wall-clock figure between 50 ms and the 0053 D7 maxima, and any figure above those maxima
  (a new ruling is needed).
- The maximum number of `fields` entries in a refusal.
- The HTTP status numbers of the infrastructure codes of D5.
- Whether the 403 for a wrong assignee (ISS-0942) collapses to the not-found answer.
- A hook 3 with entity reads (a new record), and a dynamic data API.
- The behaviour of any future automatic completer (timer, script handler) beyond the rule that it runs the
  hook and fails closed, including its lock-timeout behaviour (measured in F-3).

## Threat cases for SECURITY-REVIEWER

Cross-tenant key resolution; a refusal oracle for unauthorized callers; a restricted value in a refusal;
pool or lock exhaustion by slow scripts holding the task and projection rows (D6, admission cap); a sandbox
crash leaving the transaction open; skipping the hook (pin missing, revoked, kill switch).

## Sign-off

- SECURITY-REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
- REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
