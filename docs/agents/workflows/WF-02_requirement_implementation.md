# WF-02 — Requirement Implementation

**Trigger:** one or more `pending` requirements in `docs/requirements.yaml` with all
`depends_on` satisfied, and (if produced by WF-01) validated.
**Owner:** `ORCH`

**Risk tier:** which chain a change runs (FULL, SHORT, HIGH) is decided by `docs/agents/ORCHESTRATOR.md` §13; this file does not restate it.

## Overview

```
[INPUT: pending requirement IDs — max 4 per run]
           │
           ▼
┌──────────────────────────┐
│  STEP 00: GIT SETUP      │ ← ELIXIR-DEV (backend/mixed) or FRONTEND-DEV (frontend-only)
│  pull → branch → push    │   docs/agents/protocols/GIT_SETUP.md
└──────────┬───────────────┘
           │ PASS — ORCH flips status: pending → in_progress, logs "started" event
           ▼
┌──────────────────────┐
│  STEP 1: DESIGN      │ ← CODE-DESIGNER
│  Module interfaces,  │
│  @specs, data shape  │
└──────────┬───────────┘
           │
      VALID?├── NO ──► REWORK (max 3)
           │
          YES
           ▼
┌──────────────────────┐
│  STEP 1b: DESIGN     │ ← CODE-DESIGN-VALIDATOR ⛔ HARD GATE
│  GATE                │
└──────────┬───────────┘
           │ PASS
           ▼
┌──────────────────────┐        ┌──────────────────────┐        ┌──────────────────────┐
│  STEP 2a: BACKEND    │        │  STEP 2b: FRONTEND   │        │ STEP 2b-mobile:      │
│  lib/ + migrations   │        │  web/ integration    │        │ MOBILE-DEV apps/     │
│                      │        │                      │        │ mobile/ change       │
└──────────┬───────────┘        └──────────┬───────────┘        └──────────┬───────────┘
     FAIL─► REWORK                    FAIL─► REWORK                   FAIL─► REWORK
           └────────────┬─────────────────┴─────────────────────────────────┘
                        ▼
           ┌──────────────────────┐
           │  STEP 2c: SECURITY   │ ← SECURITY-REVIEWER ⛔ HARD GATE (in-scope only)
           └──────────┬───────────┘
                      │ PASS
                      ▼
           ┌──────────────────────┐
           │  STEP 2d: IDIOM      │ ← REVIEWER ⛔ HARD GATE
           │  REVIEW              │   OTP idiom, supervision, scope creep,
           │                      │   decision-record consistency
           └──────────┬───────────┘
                      │ PASS
                      ▼
           ┌──────────────────────┐
           │  STEP 3: TEST DESIGN │ ← TEST-DESIGNER
           │  (scope test first — │   no executable surface (docs-only requirement)?
           │   skips 3b/4 if N/A) │   → skip straight to STEP 5
           └──────────┬───────────┘
                 VALID?├── NO ──► REWORK (max 3)
                      │
                     YES
                      ▼
           ┌──────────────────────┐
           │  STEP 3b: TEST GATE  │ ← TEST-DESIGN-VALIDATOR ⛔ HARD GATE
           └──────────┬───────────┘
                      │ PASS
                      ▼
           ┌──────────────────────┐
           │  STEP 4: TEST RUN    │ ← TEST-RUNNER
           └──────────┬───────────┘
                 PASS? ├── NO ──► rework responsible agent → back to STEP 4
                      │
                     YES
                      ▼
           ┌──────────────────────┐
           │  STEP 5: RELEASE     │ ← RELEASE-VALIDATOR
           │  VALIDATION          │   (re-runs the suite independently — does
           └──────────┬───────────┘   not trust Step 4's report alone)
                 PASS? ├── NO ──► route to blocking agent
                      │
                     YES
                      ▼
           ┌──────────────────────┐
           │  STEP 6: DOC UPDATE  │ ← DOC-UPDATER
           └──────────┬───────────┘
                      │ PASS — ORCH independently confirms the specific files/fields
                      │        DOC-UPDATER claims to have changed actually changed
                      ▼
┌──────────────────────────┐
│  STEP FINAL: GIT MERGE   │ ← same agent as Step 00
│  rebase → PR → merge     │   docs/agents/protocols/GIT_MERGE.md
└──────────┬───────────────┘
           │ PASS
           ▼
[OUTPUT: requirements' status = done in docs/requirements.yaml;
 feature/<run-id> squash-merged into main]
```

## Step 00 — Git setup

**Agent:** `ELIXIR-DEV` (backend/mixed runs) or `FRONTEND-DEV` (frontend-only runs)
**Protocol:** `docs/agents/protocols/GIT_SETUP.md`

ORCH supplies `context.branch_name = "feature/<run-id>"`. On PASS: ORCH flips the
requirement(s)' status to `in_progress` in `docs/requirements.yaml` and appends a
`started` event to the current run-history volume (via
`docs/status/requirement_status.index.yaml`) — append, do not rewrite prior entries
(real UTC timestamp).

**ORCH also extracts the requirement text once, here, for the whole run.** Copy each
in-scope requirement's full `description` from `docs/requirements.yaml` into
`context.requirement_text` on this and every subsequent handoff in the run. Steps 1
through 6 read the requirement from there and never open `docs/requirements.yaml`
themselves — see `core-directives.md`'s "Load Scoped Context, Not Whole Files."

## Step 1 — Code design

**Agent:** `CODE-DESIGNER`

```
1. Read the requirement(s) from your handoff's context.requirement_text and
   task.acceptance_criteria — not by opening docs/requirements.yaml (see
   core-directives.md's "Load Scoped Context, Not Whole Files").
2. Read docs/guides/backend_developer_guide.md and, if frontend-touching,
   docs/guides/frontend_developer_guide.md.
3. Read the relevant docs/migration/stage-N-*.md and any docs/migration/decisions/*.md
   the stage depends on.
4. For each affected module, write lib/letflow/design/<module>.md:
   - Public function signatures with @spec-style input/output types
   - Key data structures (Ecto schema fields, gen_statem state/data shape)
   - Invariants that must hold
   - DB tables/columns touched (name, type, constraints, indexes)
   - Cross-module dependencies
   - Open questions (not silently resolved by guessing)
5. Validate against requirements: every acceptance criterion maps to a concrete
   design element. No acceptance criterion left unaddressed.
6. Complete the handoff: artifacts_out: ["lib/letflow/design/<module>.md", ...],
   next_action: "Route to CODE-DESIGN-VALIDATOR".
```

### Acceptance criteria
- [ ] Every acceptance criterion maps to a concrete design element
- [ ] All new types/schemas are defined with field-level detail
- [ ] DB schema changes fully described (table, columns, indexes, constraints)
- [ ] Open questions listed explicitly, not silently resolved

## Step 1b — Design gate ⛔ HARD GATE

**Agent:** `CODE-DESIGN-VALIDATOR`

```
1. Read the design artefact(s) independently — do not read CODE-DESIGNER's
   result.summary as a substitute for reading the actual .md file.
2. For each MUST/acceptance criterion:
   a. Has a corresponding design element? No "TBD"/"to be implemented" deferrals?
   b. Function signatures fully specified (name, inputs, outputs, error cases)?
   c. Error handling shape stated ({:ok,_}|{:error,_} tags, not left implicit)?
   d. Cross-module dependencies listed?
   e. No implementation code present (no actual .ex/.exs code blocks — signatures
      and type shapes only, not bodies)?
3. FAIL immediately on any check failure — no partial credit.
4. Complete the handoff: PASS → "Route to ELIXIR-DEV (2a) and/or FRONTEND-DEV (2b)" |
   FAIL → "Rework CODE-DESIGNER", issues listing every failed check by requirement id.
```

## Step 2a — Backend implementation

**Agent:** `ELIXIR-DEV`

```
1. Verify branch: git branch --show-current must equal feature/<run-id>. If not: STOP,
   report FAIL before touching any file.
2. Read lib/letflow/design/<module>.md for this unit.
3. Implement lib/letflow/**/*.ex per the design.
4. Write priv/repo/migrations/*.exs per the design's DB spec.
5. mix compile --warnings-as-errors — if FAIL, fix and retry (counts as rework).
6. mix ecto.migrate against a real or Docker-provisioned test DB (see
   docs/anti-patterns.md's Docker fallback if no local toolchain) — if FAIL, fix
   migration SQL and retry.
7. mix format --check-formatted — fix formatting if it fails.
8. Self-review checklist:
   [ ] No string interpolation of tenant/user input into raw SQL (INV-7)
   [ ] No unresolved `{:ok, _} =` match on a path reachable from external I/O (INV-8)
   [ ] Every state transition still persisted via Letflow.Repo inside the transition
   [ ] One supervised process per workflow instance preserved, if this touches
       lib/letflow/process_instance.ex or instance_supervisor.ex
   [ ] New public functions have a one-line @doc
   [ ] If any function signature changed: all call sites still compile
9. Complete the handoff: artifacts_out: ["lib/...", "priv/repo/migrations/..."],
   next_action: "Route to SECURITY-REVIEWER (2c) once 2b also complete (or immediately
   if backend-only)".
```

### Acceptance criteria
- [ ] `mix compile --warnings-as-errors` exits 0
- [ ] All migrations apply cleanly against a fresh DB
- [ ] No SQL string interpolation of tenant/user data
- [ ] All callers of any changed function signature compile

## Step 2b — Frontend implementation

**Agent:** `FRONTEND-DEV`

```
1. Verify branch (same check as 2a).
2. Read lib/letflow/design/<module>.md for the API contract being integrated against.
3. Read docs/guides/frontend_developer_guide.md and web/README.md.
4. Make the change in web/. Letflow OWNS web/ as of 2026-08-21 -- components, types,
   and tests are in scope, not only config/CORS (decisions/0011-frontend-ownership.md;
   the "not rewriting web/'s own components" framing this step used to carry is
   superseded). Scope is still the requirement you were handed: implement that, not
   whatever else you noticed while in the file.
   A contract mismatch is closed on the LETFLOW side -- route it to CODE-DESIGNER/
   ELIXIR-DEV. Never add a shim inside web/ that normalises it.
5. Run the four gates from web/, quoting real output, not a claim:
      npm run type-check && npm run lint && npm test && npm run guards
   If any FAIL, fix and retry. Do NOT weaken a pattern in
   web/tests/guards/forbidlist.ts to make a change pass -- report it to ORCH for
   REVIEWER instead.
6. Self-review: no hardcoded API base URL (use the existing env-var pattern), no
   token stored in localStorage/sessionStorage beyond what web/'s existing pattern
   already does, no new state-management/routing/build tool introduced.
7. Complete the handoff: artifacts_out: ["web/..."],
   next_action: "Route to SECURITY-REVIEWER (2c) once 2a also complete".
```

### Acceptance criteria
- [ ] `type-check`, `lint`, `test`, and `guards` all pass, with real output quoted
- [ ] No guard pattern weakened or `allowedPaths`-exempted to make the change pass
- [ ] Token handling matches `web/`'s existing pattern; no new auth-storage mechanism
- [ ] Any contract mismatch found was routed to the backend, not shimmed inside `web/`

## Step 2b-mobile — Mobile implementation

**Agent:** `MOBILE-DEV`

```
1. Verify branch (same check as 2a).
2. Read lib/letflow/design/<module>.md for the API contract being integrated against,
   and docs/mobile/ (README.md, architecture.md, requirements.md, build-order.md).
3. Make the change in apps/mobile/ only. Do not touch web/ or lib/ -- a backend gap
   goes to ELIXIR-DEV via ORCH; a shared-contract question goes to CODE-DESIGNER.
4. Run, from apps/mobile/, quoting real output, not a claim:
      flutter analyze && flutter test
   If either FAILS, fix and retry.
5. Self-review against .claude/agents/mobile-dev.md's three tier constraints and
   Forbidden list (one tenant-agnostic build, no general scripting runtime on-device,
   online-first read-through cache only, tokens in OS-secure storage only).
6. Complete the handoff: artifacts_out: ["apps/mobile/..."],
   next_action: "Route to SECURITY-REVIEWER (2c) when the change touches auth, token
   storage, or transport (MOB-2, MOB-5, MOB-6); otherwise route to REVIEWER (2d) once
   2a/2b (if present) also complete".
```

### Acceptance criteria
- [ ] `flutter analyze` and `flutter test`, run from `apps/mobile/`, both pass with real output quoted
- [ ] No general scripting runtime (Lua/JS/WASM) introduced on-device
- [ ] No token stored anywhere but OS-secure storage
- [ ] Any contract mismatch found was routed to the backend, not shimmed inside `apps/mobile/`

## Step 2c — Security gate ⛔ HARD GATE (in-scope changes only)

**Agent:** `SECURITY-REVIEWER`

Runs after both 2a and 2b return PASS (or whichever applies), before Step 2d.

```
1. Read context.artifacts_in and the branch diff: git diff main...HEAD
2. Scope test: does this diff touch a tenant-data path per
   docs/agents/instructions/security-invariants.md's applicability notes? An
   apps/mobile/ diff touching auth, token storage, or transport (MOB-2, MOB-5,
   MOB-6) is IN SCOPE under security-reviewer.md's "anything resolving a ... token"
   clause; its checklist is MOB-5's acceptance criteria in
   docs/mobile/requirements.md, applied alongside INV-4/INV-5.
   - Permission-matrix trust boundary (GH #2586, decision 0055 D7): any change to
     .github/workflows/ci.yml or scripts/ci_changed_paths.sh (CI's path rules, GH #2622);
     to .github/workflows/cd.yml or scripts/cd_qa_decide.sh (GH #2622: cd.yml holds the
     QA deploy secrets and the forced-command deploy path; the decide script chooses
     whether it deploys); to mix.exs aliases (aliases/0, @check_static_steps,
     cli/0 preferred_envs) or elixirc_paths/1; to a `config :letflow, :modules`
     setting in any config/*.exs; to lib/mix/tasks/letflow.permission_matrix.ex or
     lib/letflow/api/permission_matrix.ex; to lib/letflow/api/authorization.ex; to lib/letflow/api/authorized_router.ex, any route_scope.ex or scope/enforce.ex under lib/letflow/ (supervisor approval 2026-10-17, RA-5 from the #2535 SEC design review; the last two exist since REQ-517 2b); to test/fixtures/route_scope/tenant_wide_default_routes.txt (the route snapshot) and test/support/route_inventory.ex (supervisor approval 2026-10-18, SEC F-2 from REQ-517 2b: a line added to the snapshot reclassifies a route as tenant-wide by default, so it is an authorization change); to
     lib/letflow/modules/catalog.ex; to anything under priv/permission_matrix/; and
     any run of `mix letflow.permission_matrix --check` whose report contains a core
     matrix change (`:core_change`, printed as CORE MATRIX CHANGE) is IN SCOPE. These
     paths (except the two CD files) are the trust boundary of the golden-file check;
     the pull request runs its own copy of them, so the CI check alone cannot stop a PR
     that edits them, and the review is the control. The CD files never run from a PR
     (only from main via workflow_run); they are triggers because of the deploy secrets
     and the deploy decision. A YES here forces "continue", never the
     out-of-scope PASS; read the PR's CI step output (the PERMISSION-MATRIX-REPORT
     line, and CORE MATRIX CHANGE when present). A permission-matrix run reporting
     `labels=bootstrap` after REQ-498 has merged is itself a mandatory
     SECURITY-REVIEWER trigger.
   NO  → PASS, summary: "out of scope — no tenant-data path touched",
         next_action: "Route to REVIEWER (2d)"
   YES → continue
3. For each of INV-1..INV-8, determine APPLIES or NOT-APPLICABLE against this diff.
4. For each APPLIES invariant, run its "How to verify" check.
5. FAIL immediately on any applicable invariant failing — all BLOCKER, no partial credit.
6. Complete the handoff: PASS → "Route to REVIEWER (2d)" |
   FAIL → "Rework ELIXIR-DEV/FRONTEND-DEV", issues listing failed invariants by number.
```

## Step 2d — Idiom review ⛔ HARD GATE

**Agent:** `REVIEWER`

Uses the existing REVIEWER procedure (`.claude/agents/reviewer.md`): idiomatic OTP vs.
crutch, supervision integrity, scope creep, consistency with
`docs/migration/decisions/`. This gate predates the fuller pipeline and is preserved
unchanged in substance — it now formally blocks TEST-DESIGNER rather than being an
optional "check before calling it done" step.

```
1. Read the diff.
2. Check against .claude/agents/reviewer.md's four questions (idiomatic vs. crutch,
   supervision, type-safety gaps, scope creep).
3. Check against docs/anti-patterns.md.
4. FAIL if a genuine crutch, broken supervision, or scope creep is found; otherwise
   PASS with any non-blocking notes recorded for the record (not blocking, but not
   silently dropped either).
5. Complete the handoff: PASS → "Route to TEST-DESIGNER (3)" | FAIL → "Rework
   ELIXIR-DEV/FRONTEND-DEV".
```

## Step 3 — Test design

**Agent:** `TEST-DESIGNER`

**Scope test (run first — added after REQ-010's WF02 run surfaced the gap):** does
Step 2a/2b/2b-mobile's `artifacts_out` contain any file with **application-executable
surface** — i.e. is there real Elixir/frontend/Dart logic this step could plausibly
write a test against? A requirement whose only artefacts are `.md` files (a decision
record, a stage-doc update) has nothing for ExUnit/StreamData to exercise. Dart tests
under `apps/mobile/test/` are written by `MOBILE-DEV` in the mobile step (2b-mobile),
same as `TEST-DESIGNER` writes ExUnit tests, and `TEST-DESIGN-VALIDATOR` still reviews
them against the acceptance criteria.

**File-extension is a starting heuristic, not the actual test — apply judgement, don't
pattern-match blindly (gap found during REQ-013's WF02 run: `mix.exs`/`.formatter.exs`/
similar `.exs` project-config files literally match a bare `.ex`/`.exs` extension check
while containing zero application logic — REVIEWER correctly flagged that a literal
reading would wrongly force this gate to continue).** The real question is: would a
test written against this artefact exercise real behavior, or would it just be
`grep`-ing a config file for a keyword (the exact manufactured-busywork anti-pattern
`core-directives.md` warns against)? Project/build configuration (`mix.exs`'s
`aliases`/`cli`/`deps` declarations, `.formatter.exs`, `config/*.exs` outside actual
business logic) is, for this scope test's purpose, in the same "nothing to unit-test"
category as decision-record prose — it's verified by actually running the command it
declares (quote real output, same as any other requirement's acceptance-criteria
demonstration), not by an ExUnit test asserting on its own declaration.
```
NO application-executable surface → complete the handoff: status: PASS, summary: "out
    of scope — no executable surface produced by this requirement (docs-only or
    build-config-only artifacts: <list them>, with a one-line note on why each is
    config/declaration rather than application logic if any has a .ex/.exs extension)",
    next_action: "Route directly to RELEASE-VALIDATOR (Step 5) — Steps 3b/4 skipped,
    RELEASE-VALIDATOR verifies acceptance criteria by reading the artefacts directly
    (including any quoted command-output demonstration from Step 2a) rather than by
    test result."
YES → continue to the full procedure below.
```
Do not invent busywork to satisfy this gate (e.g. a test that greps a markdown file for
a keyword) — a test with no real executable behavior to fail against is exactly the
"satisfy a gate without substance" anti-pattern `core-directives.md` warns against.
TEST-DESIGN-VALIDATOR and TEST-RUNNER are skipped entirely when this scope test says
NO, the same way SECURITY-REVIEWER's out-of-scope PASS skips straight past its own
invariant checklist.

```
1. Read the requirement(s) from your handoff's context.requirement_text and
   task.acceptance_criteria (not docs/requirements.yaml), plus
   lib/letflow/design/<module>.md.
2. For each requirement without adequate existing test coverage:
   a. Write test/specs/<REQ-ID>.md (requirement text, test cases, why each exists)
   b. Write test code under test/letflow/ (or test/letflow_web/ for API-layer tests),
      following the property-test convention already established for
      process_instance_test.exs where the change touches state-machine logic
3. Verify: every acceptance criterion has ≥1 test case that would fail if violated.
4. Complete the handoff: artifacts_out: ["test/specs/...", "test/letflow/..."],
   next_action: "Route to TEST-DESIGN-VALIDATOR".
```

### Acceptance criteria
- [ ] Every acceptance criterion has at least one test case
- [ ] Test specs written before/alongside test code, not as an afterthought
- [ ] No test depends on wall-clock time or unseeded randomness

## Step 3b — Test design gate ⛔ HARD GATE

**Agent:** `TEST-DESIGN-VALIDATOR`

```
1. Read test spec files and test source files independently.
2. For each acceptance criterion, verify:
   a. At least one runnable test targets it (not @tag :skip without a passing
      counterpart)
   b. No "TODO: implement test" left in the spec
   c. Test fixtures use per-test unique data (not shared hardcoded IDs) — matters
      once tenancy exists; for pre-tenancy code, at minimum no cross-test pollution
   d. Tests are self-sufficient — don't depend on other tests running first
   e. No hardcoded secrets/connection strings in test files
3. FAIL immediately on any check failure.
4. Complete the handoff: PASS → "Route to TEST-RUNNER (4)" | FAIL → "Rework
   TEST-DESIGNER".
```

## Step 4 — Test run

**Agent:** `TEST-RUNNER`

```
1. scripts/test_parallel.sh — full suite, not just the new tests (Unblock-Everything: a
   pre-existing failure masking your results must be fixed too, unless it's unrelated
   and is reported for filing per `WORK_BOARD.md` section 7). This runs the suite as N parallel
   `mix test --partitions N` processes (N from $TEST_PARALLEL_N if set, else
   nproc/getconf _NPROCESSORS_ONLN) and aggregates every partition's real ExUnit
   Result:/Failed: counts into one combined pass/fail total — exit 0 only if every
   partition's *parsed* count shows 0 failures (the parsed count is authoritative, not
   each partition's raw process exit code; exit 2 per partition is normal for "had
   failures" on this toolchain, not a crash).
2. If no local toolchain: use the Docker fallback documented in docs/anti-patterns.md.
   Report explicitly if neither is available — do not report PASS without having run
   it (No Speculation).
2b. When the diff touches apps/mobile/: additionally run, from apps/mobile/,
   `flutter analyze` and `flutter test`, and record their real output in the test
   report alongside the ExUnit results.
3. Write test/reports/report-<date>-<run-id>.yaml with the actual output, including the
   derived partition count N, its source (env override/nproc/getconf), and the combined
   pass/fail totals scripts/test_parallel.sh printed.
4. Complete the handoff: PASS/FAIL/PARTIAL, artifacts_out: ["test/reports/..."],
   next_action: PASS → "Route to RELEASE-VALIDATOR" |
                FAIL → "Rework responsible agent (ELIXIR-DEV/FRONTEND-DEV/TEST-DESIGNER)".
```

Failures caused by this run's own implementation are reworked on this branch. Failures
unrelated to this run's own acceptance criteria (pre-existing) are reported for filing
per `WORK_BOARD.md` section 7 — not fixed here, don't block this step's own PASS verdict.

**How "pre-existing" is established — structurally, never by count-matching.** This step
previously said the sentence above without saying how the attribution is made, and in
practice agents made it by observing that the failure set matched a previous run's. That
method is unsound. Rule and evidence: `core-directives.md`'s "Failure Attribution Is
Structural, Never By Count-Matching" — read it; the operative test here is:

```
1. To call a failure pre-existing, name the evidence, in one of THREE forms: (a) the
   failing module and its dependencies do not appear in  git diff --name-only
   main...HEAD ; (b) you reproduced it at the merge-base and quoted the output; or
   (c) you demonstrated a mechanism outside this branch, evidenced by a MEASUREMENT of
   that mechanism, not by assertion (orphaned erl.exe processes holding leaked
   connections, and stale rows whose parent tenant no longer exists, are the worked
   examples in core-directives.md). "Known failure" is not an attribution. If you can
   show none of the three, the failure is UNATTRIBUTED — report it as such, don't
   stretch (a) to fit.
2. Matching a previously-reported count/set is NOT evidence of pre-existence, and a
   count differing by one or two is NOT evidence of regression. Both directions.
   (Same commit, ten minutes apart, gave 13 then 15 in WF03-ISS0106-20260821 against a
   prior run's 14 — three runs, three sets. See core-directives.md for the measurement.)
3. A failure with no existing issue record is called out AS SUCH and REPORTED FOR
   FILING per `WORK_BOARD.md` section 7 — never folded into "the known set". You report the
   finding as `FINDING:` to the sole filer; you do NOT run  gh issue create  yourself
   and you do NOT call the queue service. There is no id allocation: the issue number
   comes from GitHub when the sole filer files.
4. A failing file that IS in the diff gets extra scrutiny, and is cleared only by a
   causal argument about mechanism, not by proximity (see the PinRebindTest worked
   example in core-directives.md).
```

## Step 5 — Release validation

**Agent:** `RELEASE-VALIDATOR`

```
1. Independently re-run: scripts/test_parallel.sh (do not trust TEST-RUNNER's report
   alone — see core-directives.md's "Every producing step has a validating step"). Same
   mechanism as Step 4: N parallel `mix test --partitions N` processes, aggregated
   Result:/Failed: counts, parsed-count-authoritative exit code — see
   scripts/test_parallel.sh's header comment for the full contract.
2. Confirm every requirement_id in scope has all its acceptance_criteria satisfied —
   check each one explicitly against the actual code/test, not against TEST-RUNNER's
   summary.
3. Check docs/status/requirement_status.yaml and docs/requirements.yaml for staleness
   relative to what actually shipped.
4. Complete the handoff: PASS → "Route to DOC-UPDATER" |
   FAIL → identify the blocking issue and name which agent it routes back to.
```

**Your re-run will not reproduce Step 4's failure set, and that is expected.** Do not
treat a differing count as either confirmation or regression, and do not accept Step 4's
pre-existence attributions on its say-so — re-derive each one structurally, per
`core-directives.md`'s "Failure Attribution Is Structural, Never By Count-Matching" (and
per the producer/validator rule that already forbids trusting TEST-RUNNER's report).

## Step 6 — Documentation update

**Agent:** `DOC-UPDATER`

```
1. For each requirement_id: flip status "pending"/"in_progress" → "done" in
   docs/requirements.yaml.
2. Append a "done" event to the current run-history volume (via
   docs/status/requirement_status.index.yaml) — append, do not rewrite prior entries
   (real UTC timestamp).
3. Update README.md if the change altered documented current behavior (e.g. the ASCII
   state diagram, the "Running it" section).
4. If the requirement named a docs/migration/stage-N-*.md or docs/migration/decisions/
   file in its acceptance criteria, confirm that file was actually updated.
5. Complete the handoff: artifacts_out: [every file actually touched, named
   explicitly — not just "docs updated"], next_action: "Route to ELIXIR-DEV/
   FRONTEND-DEV for Step Final".
```

**ORCH's independent check before advancing:** read DOC-UPDATER's `artifacts_out` and
confirm each named file actually contains the claimed change — grep for the flipped
status, the new event entry — before writing the DONE log line. This is the "no
hallucinated completion" check the humanless pipeline depends on (see
`core-directives.md`).

## Step Final — Git merge

**Agent:** same as Step 00.
**Protocol:** `docs/agents/protocols/GIT_MERGE.md`

ORCH supplies `context.branch_name` and `context.requirement_ids`. Use DOC-UPDATER's
`result.summary` as the commit/PR summary. List forwarded `ISS-NNNN` ids under a
"Forwarded, not fixed here" note if any exist.

**Immediately on PASS** (same turn, before writing the `RUN_DONE` log line or
considering the run finished): for every requirement this run just flipped to `done` in
Step 6, post the `done` heartbeat on its GitHub issue (the `gh:` number in its
`docs/requirements.yaml` entry) with the PR url and evidence — see
`docs/agents/protocols/WORK_BOARD.md` §6. The issue itself closes only through the merged
PR's `Closes #N` (§8); a PR that only partly resolves it says `Refs #N` and the residual
is filed as a new linked issue. This is not deferred bookkeeping; a requirement that is
`done` in the yaml but still open and claimed on the board is a stale entry the instant
Step Final returns PASS, and a stale entry is exactly what let two sessions both build
REQ-048 on 2026-08-19 (see `docs/anti-patterns.md`'s "Task-selection fallback duplicating
a run" entry) — do not let a new one accumulate between merge and some later
reconciliation pass. If GitHub is unreachable at this exact moment, state that
explicitly in the `RUN_DONE` log line and flag the issue number for the supervisor —
do not silently skip it.

## Parallel execution rule

Steps 2a and 2b MAY run in parallel when both are present, on the same branch from Step
00. ORCH waits for both PASS before routing to 2c. ORCH must not assign overlapping
`owned_modules` to two concurrent WF-02 runs (see `ORCHESTRATOR.md` §7).
