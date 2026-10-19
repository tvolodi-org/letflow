# WF-03 — Issue Resolving

**Trigger:** a queued `docs/issues/ISS-NNNN.yaml` entry (`status: open`), a test
regression, or a self-discovered/user-reported defect in existing behavior.
**Owner:** `ORCH`

WF-03 vs. WF-02: if the expected behavior is already specified (in
`docs/requirements.yaml` or an existing test), this is WF-03. If the feature itself
isn't specified yet, that's a new requirement — WF-01 then WF-02.

**Risk tier:** which chain a change runs (FULL, SHORT, HIGH) is decided by `docs/agents/ORCHESTRATOR.md` §13; this file does not restate it.

## Overview

```
[INPUT: ISS-NNNN or a described defect]
        │
        ▼
┌──────────────────────────┐
│  STEP 00: GIT SETUP      │ ← ELIXIR-DEV/FRONTEND-DEV, docs/agents/protocols/GIT_SETUP.md
└──────────┬───────────────┘
           │ PASS
           ▼
┌───────────────────────┐
│  STEP 0.5: REGISTRY   │ ← ISSUE-FIXER
│  LOOKUP               │   Has this exact issue been seen/fixed before? Check
│                        │   docs/issues/ for a resolved entry with matching symptoms.
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 1: DIAGNOSE     │ ← ISSUE-FIXER
│  Root cause, not      │   Does NOT implement the fix — produces a diagnosis for
│  symptom              │   CODE-DESIGNER to design a fix from.
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 2: FIX DESIGN   │ ← CODE-DESIGNER → CODE-DESIGN-VALIDATOR ⛔ (same as WF-02 1/1b)
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 3: IMPLEMENT    │ ← ELIXIR-DEV / FRONTEND-DEV (same procedure as WF-02 2a/2b)
│  → SECURITY-REVIEWER  │   → REVIEWER (same as WF-02 2c/2d)
│  → REVIEWER           │
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 4: REGRESSION   │ ← TEST-DESIGNER writes a test that reproduces the bug and
│  TEST                 │   FAILS against pre-fix code, then PASSES post-fix — this is
│                        │   the fail-first proof the fix actually fixes something.
│                        │   → TEST-DESIGN-VALIDATOR → TEST-RUNNER (same as WF-02 3/3b/4)
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 5: CLOSE ISSUE  │ ← ISSUE-FIXER sets docs/issues/ISS-NNNN.yaml status: resolved,
│                        │   resolving run-id, real UTC timestamp. If a GitHub issue
│                        │   exists (github_issue field), close it: gh issue close <n>
│                        │   --comment "Fixed in <run-id>, see docs/issues/ISS-NNNN.yaml"
└──────────┬─────────────┘
           ▼
┌──────────────────────────┐
│  STEP FINAL: GIT MERGE   │ ← same agent as Step 00
└──────────┬───────────────┘
           ▼
[OUTPUT: ISS-NNNN resolved; fix merged to main with a regression test]
```

## Step 0 — Overlap check (before any work)

Before ISSUE-FIXER (or anyone) starts, ORCH confirms the issue is not already being fixed:
`gh pr list` and each open PR's changed files, `main` (is it already fixed?), and sibling
sessions' branches. Identify the work by its **GH issue number** (the local `ISS-NNNN` may
be a renumbered alias and is history only). Duplicates have happened (Q-926 was fixed twice in
parallel; Q-935 was fixed by an unrelated PR), and a skipped check costs a whole pipeline run.
If an in-flight PR covers the acceptance criteria, do not implement: comment a `blocked`
heartbeat naming that PR so the supervisor releases the claim, and let the issue close
through that PR when it merges.

## Step 0.5 — Registry lookup

**Agent:** `ISSUE-FIXER`

```
1. Read docs/issues/*.yaml for entries with status: resolved whose description
   mentions similar symptoms/files.
2. If a clear match exists: cite it in this handoff's context, and check whether the
   same root cause has recurred (a fix that didn't actually fix the underlying issue —
   R-Co's own history shows this class of recurrence happens, see
   docs/agents/instructions/security-invariants.md's INV-1 reference for a concrete
   example of exactly this in that project). If it's recurring, flag severity as at
   least MAJOR regardless of the original severity.
3. Complete the handoff: summary notes whether a prior match was found.
```

## Step 1 — Diagnose

**Agent:** `ISSUE-FIXER`

```
1. Reproduce the issue directly — run the failing scenario, read actual output. Do not
   diagnose from the bug report's prose alone (No Speculation).
2. Trace to root cause: which function, which invariant broke, why the existing tests
   didn't catch it (if any existed).
3. Write the diagnosis into the handoff's result.summary: root cause (not just
   symptom), affected files, and what a fix needs to change.
4. Do NOT implement the fix. Complete the handoff: next_action: "Route to
   CODE-DESIGNER for fix design".
```

## Steps 2-4

Follow the same procedures as WF-02's Step 1/1b (design), 2a-2d (implement + gates),
3/3b/4 (test), with one addition: **Step 4's test must be shown to fail against the
pre-fix code and pass against the post-fix code** — TEST-DESIGNER states this
explicitly in the test spec (checked out the pre-fix commit, ran the new test, confirms
it failed; then confirms it passes on the fix branch). A test that only ever ran
against already-fixed code proves nothing about whether it actually covers the bug.

### When the pre-fix failure is "the code under test does not exist"

The fail-then-pass rule above is right for a fix to **existing** behaviour. It is
**trivially satisfiable** when the fix *adds* a module: the pre-fix failure is then
`UndefinedFunctionError` for every test in the file, which proves the module is new and
nothing whatever about whether the tests discriminate a **correct** implementation from
a **wrong** one. A suite can fail against a missing module and still be vacuous against
a broken one.

**So: where the pre-fix failure is non-existence, the fail-first requirement is
satisfied ONLY by additionally MUTATING the shipped logic and recording which tests fail
for each mutant.** The mutants must target the specific traps the fix exists to handle,
not arbitrary breakage.

**And TEST-DESIGN-VALIDATOR must independently APPLY at least one of the reported
mutants and run it** — accepting the reported pass counts is copying a claim, not
validating one (`core-directives.md`, "Every producing step has a validating step").

Worked example — WF03-ISS0106-20260821's TEST-DESIGNER mutated three ways and recorded
each: a naive full-string OTP comparison (**17/30 pass**), an unstripped version suffix
(**24/30**), warnings routed to stdout (**11/30**). The coverage was thereby
demonstrably *sensitive to each specific trap*, rather than merely present.
TEST-DESIGN-VALIDATOR on that run applied two of the three itself and reproduced both
counts exactly.

**Isolation technique worth copying from that run:** the pre-fix side was run as `main`
plus **only the new module** — nothing else from the branch. That proves the tests track
*that module* rather than anything else the branch happens to change.

**A mutant is a TEMPORARY PROBE. Leaving one in the tree is a step failure.** Both
TEST-DESIGNER and TEST-DESIGN-VALIDATOR are mutating `lib/` here, and a gate step is
otherwise bound by "no file outside `handoffs/` is modified by this step" — so the
mutation is licensed only for the duration of the run that measures it, and only if it
is reverted and the revert is *verified*. Use one of these two techniques:

- **Preferred — apply mutants in a throwaway `git worktree` of the branch**, so the
  working checkout is never mutated at all. Remove the worktree when done.
- **Or, if applied in place — revert with `git checkout -- <path>`, then VERIFY the
  revert before completing your handoff** by confirming both of the following and
  quoting both in `result.summary`:
  - `git status --porcelain lib/ test/` is **empty**; and
  - the test file **re-runs green** against the restored, unmutated code.

WF03-ISS0106-20260821 avoided this hazard only because its handoff carried an explicit
acceptance criterion to revert-and-verify; its TEST-DESIGN-VALIDATOR reverted via
`git checkout --`, re-checked the module's SHA1 against pristine, confirmed
`git status --porcelain lib/ test/` empty, and re-ran to 30 passed. That is the standard
— it is stated here so it no longer depends on a per-run handoff remembering to ask.

## Step 5 — Close the issue

**Agent:** `ISSUE-FIXER`

```
1. docs/issues/ISS-NNNN.yaml: status: <resolved | instrumented | no_defect>,
   plus THAT status's own key pair and its own required evidence.
   NOT every run ends in `resolved`. Each terminal value takes different keys:
   `resolved` uses resolved_in_run:/resolved_at:; `instrumented` uses
   resolved_in_run:/resolved_at: and a required superseded_by:; `no_defect` uses
   verdict_in_run:/verdict_at:, never resolved_*. Check which one this run's outcome
   actually supports against ISSUE_QUEUE.md BEFORE writing this line -- writing the
   wrong one asserts something about reality that did not happen.
2. **Evidence-on-close is a HARD requirement, not agent discretion.** If `github_issue`
   is set and `gh` is reachable: `gh issue close <n> --comment "<...>"`. **A GitHub
   issue close is only valid if it carries EITHER (i) a `--comment` citing the
   resolving evidence, OR (ii) a genuinely linked/merged PR with a `Closes`/`Fixes`
   reference in its own GitHub timeline (`closedByPullRequestsReferences` non-empty).**
   Closing without either is not a smaller version of this step done correctly -- it is
   this step **not done**, full stop, exactly as if `docs/issues/ISS-NNNN.yaml` had
   been left at `status: open`. `mix letflow.audit_issue_closures` (§2 below) is the
   mechanical check that catches a violation of this rule after the fact -- this step's
   own prose compliance is necessary but not sufficient; the audit tool is what makes
   it durable.

   The comment BRANCHES ON THE STATUS -- it is published to an external audience, so
   it must claim only what the run actually did:
     resolved     -> "Fixed in <run-id>. See docs/issues/ISS-NNNN.yaml and the
                      regression test at <test file path>."
     instrumented -> "Investigated in <run-id>; verified work shipped but the root
                      cause is NOT removed. See docs/issues/ISS-NNNN.yaml and the
                      successor issue <ISS-NNNN>."
     no_defect    -> "Investigated and measured in <run-id>; no defect found and
                      nothing was changed. No fix was made and there is no
                      regression test. See docs/issues/ISS-NNNN.yaml and the
                      diagnosis handoff at <handoff path>."
   Never claim a fix or cite a regression test on a non-`resolved` close. **Never close
   a GitHub issue with no `--comment` at all in the belief that a "self-evident" fix
   needs no explanation** -- GH#324/GH#326 (`ISS-0279`'s own filing evidence) are the
   concrete cost of that shortcut: a closure with no comment and no linked PR cannot
   even be checked against its own stated reasoning, because it has none.
3. Complete the handoff: PASS, next_action: "Route to Step Final".
```

`resolved` is the normal terminal state, but not the only legal one: it asserts that a
root cause was actually removed. A run that shipped verified work without removing the
root cause uses `instrumented` (with a required `superseded_by:` pointer) instead, and a
run whose Step 1 reached a reasoned NO-CHANGE verdict — investigated and measured, no root
cause there to remove — uses `no_defect`, which carries its own evidence bar and its own
`verdict_in_run:`/`verdict_at:` keys. The definitions and the conditions for each status
are in the "Issue status vocabulary" section of `docs/agents/protocols/ISSUE_QUEUE.md`
(still the meaning of those yaml fields; see its header); do not restate them here.

**ORCH, immediately on this step's PASS** (same turn, before writing the `RUN_DONE` log
line): post the `done` heartbeat on the issue's GitHub issue (`WORK_BOARD.md` §6). Then branch on the local
`docs/issues/ISS-NNNN.yaml` (or `GH-<n>.yaml`) status this step's §1 just wrote,
mirroring the GitHub close-comment branch above:

  resolved                -> the PR says `Closes #N`; the merge closes the issue
  instrumented / no_defect -> the PR says `Refs #N`; the issue stays open and the
                              heartbeat names the verdict, so the supervisor re-triages

`resolved` is the only outcome that may close the issue — `instrumented` and
`no_defect` reached a real terminal verdict but did not resolve the issue, so a
`Closes #N` would falsely claim resolution, and leaving the issue claimed with no
heartbeat would let it look re-claimable and produce a re-selection loop. Same rule as
WF-02 Step Final: an item that stays claimed on the board past this step's PASS is a
stale entry from the moment this step passes, not something to clean up in a later
reconciliation pass. If GitHub is unreachable, state that explicitly in the `RUN_DONE`
line and flag the issue number for the supervisor.

## Output

The issue's root cause is fixed, proven by a fail-then-pass regression test, merged to
`main`, and the issue record closed with a real resolution timestamp — not just marked
done on an agent's say-so.

A GitHub-side close that skips both evidence forms is a Step 5 failure even when the
local `docs/issues/ISS-NNNN.yaml` write is otherwise correct — the two halves of this
step are both mandatory, not the yaml write alone.
