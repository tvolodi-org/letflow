# 0018 — Branch protection posture: required checks, admin-bypassable

Status: decided (2026-09-04). Owner: ELIXIR-DEV (the `gh api` configuration call and
its live verification) / ORCH (the doc corrections this record requires elsewhere).

## Question

ISS-0441: `gh api repos/tvolodi/letflow/branches/main/protection` returns 404
(`{"message":"Branch not protected"}`). `main` has no branch protection at all — no
required status checks, no required reviews, nothing. Every "hard gate" this pipeline
claims (SECURITY-REVIEWER, REVIEWER, TEST-DESIGN-VALIDATOR, and CI's own backend/frontend
jobs) is enforced only by the merging agent choosing to honor it, never structurally.
PR #848 is a live demonstration: it merged with one Backend gate run FAILURE and one
SUCCESS, via `--admin`, because the failure was the known `wasm_hang` flake
(ISS-0352/ISS-0418) and the identical commit passed in the parallel run. The merge was
correct. Nothing except the merging agent's own judgement made it so.

Four questions, none prescribed by the issue:

(a) Should `main` require the Backend and Frontend gate status checks before merge?
(b) If so — the hard part — how does an agent merge past a *known*-flaky,
    structurally-unrelated failure (the wasm_hang class, 7+ recurrences this session)
    without either blocking indefinitely or keeping a blanket bypass that defeats the
    point?
(c) Does requiring checks break the humanless pipeline's ability to self-merge, given
    the merging identity is the repo owner/admin?
(d) Is `enforce_admins: true` appropriate, given there is no human available to unblock
    a genuinely stuck merge?

## Decision

**(a) Yes.** `main` gets required status checks: `Backend gate (mix letflow.check)` and
`Frontend gate (npm run check)` — the exact job `name:` strings from `.github/workflows/ci.yml`
(confirmed below to be the literal GitHub check-run names; GitHub uses a workflow job's
`name:` as its check-run name when the job has one, and both jobs here do). No required
PR reviews (`required_pull_request_reviews: null`) — there is no human reviewer role in
this pipeline per `0004-humanless-pipeline.md`, and SECURITY-REVIEWER/REVIEWER/
TEST-DESIGN-VALIDATOR are agent workflow steps, not GitHub PR reviews; inventing a
GitHub-review requirement here would just create a second, redundant, harder-to-satisfy
gate for the same thing WF-02/WF-03 already gate procedurally. No push/merge
`restrictions` (`restrictions: null`) — restricting who can push would have no effect
here (one identity does all the pushing) and would only add a maintenance surface.

**(b) The hard part — required checks with `enforce_admins: false`, no other posture.**
This is the actual design decision, not a menu of options:

`enforce_admins: false` on a repo where the merging identity is itself a repo admin does
**not** collapse to "no protection," and it is worth stating precisely why, because the
naive reading (an admin can always bypass, so what did protection buy you?) is wrong:

- With protection configured this way, the *default*, *unqualified* merge command this
  pipeline already uses — `gh pr merge --squash --delete-branch` (GIT_MERGE.md step 8,
  unchanged by this record) — is **rejected by GitHub** while either required check is
  red or still pending. The agent gets a real, mechanical failure back, not a green
  light it chose not to look at.
- Passing a red/pending required gate now requires a **second, different, explicit**
  command — `gh pr merge --squash --delete-branch --admin` — that does not appear
  anywhere in the normal path. An agent cannot bypass by doing what it was already going
  to do; it has to affirmatively reach for a different flag, which is exactly the point
  where a structural check turns an implicit judgement call into a visible, logged act.
- That act is auditable after the fact in a way "the agent decided the failure was
  attributable elsewhere" currently is not: `gh pr view <n> --json mergedBy,mergeCommit`
  plus the PR's own timeline shows an admin-override merge occurred, distinct from an
  ordinary merge. Nothing today distinguishes "merged because everything was actually
  green" from "merged over a red gate because an agent judged it unrelated" — both look
  identical in `git log`. This record makes them look different.
- It still fully blocks the case that matters: a **genuinely broken change** whose CI
  failure is real. `--admin` is a deliberate act an agent must choose to type per merge;
  it is not ambient permission the way "no protection" is. An agent following
  `core-directives.md`'s "Never Call a Red Pipeline OK Without a Source" and
  `GIT_MERGE.md`'s failure-attribution requirement (see below) has no attribution to cite
  for a genuine break, and reaching for `--admin` without one is precisely the
  bypass-without-justification this record exists to prevent recording as normal.

**The bypass condition is not new — it is already written down and already required.**
`GIT_MERGE.md`'s Step Final and `core-directives.md`'s "Failure Attribution Is Structural,
Never By Count-Matching" already forbid merging over a failure the agent cannot
structurally attribute away from the branch being merged. This record does not invent a
new justification test; it makes the existing one load-bearing at the one point it
previously had no teeth. Concretely:

- **Normal path (no override needed):** both required checks report `SUCCESS`. Plain
  `gh pr merge --squash --delete-branch` succeeds. Nothing about this record changes
  that path.
- **Override path (the wasm_hang/ISS-0352/ISS-0418 class):** a required check reports
  `FAILURE`, the agent has already performed the structural attribution
  `core-directives.md` requires (named failure class, cited evidence the branch doesn't
  touch the failing path, and/or a parallel green run of the identical commit — the
  PR #848 pattern), and the PR body already carries that attribution per `GIT_MERGE.md`
  step 7's "mix test line" requirement. Only then: `gh pr merge --squash --delete-branch
  --admin`. The PR body's existing attribution text is the per-merge justification this
  record requires — no new field, no new document, just making the existing requirement
  the actual precondition for the actual override command.
- **No-attribution path:** a required check reports `FAILURE` or is still `PENDING` and
  the agent has no structural attribution to cite. The agent does not use `--admin`. It
  waits (if `PENDING`) or routes to ISSUE-FIXER (if `FAILURE`, per the existing
  `GIT_MERGE.md` step 5d routing). This is the case required checks are *for* — today
  nothing stops an agent from merging here anyway if it misjudges the failure as
  unrelated; after this record, misjudging it means either waiting it out or making the
  wrong call *visibly*, via `--admin`, rather than invisibly, via an unprotected
  `gh pr merge`.

This is the actual call: **required-but-admin-bypassable is not a compromise that waters
protection down to nothing — it converts an invisible, ambient discretion into a visible,
individually-logged one, while leaving the humanless pipeline's only actual escape hatch
(the merging identity's own admin rights) intact for the case where CI itself, not the
change, is broken.** A protection rule agents must routinely bypass with no distinguishing
mark would indeed be worse than none, per the issue's own framing — but that describes a
rule with no override discipline attached to it, which is why this record ties the
override to the attribution requirement that already exists rather than leaving it as
free-standing discretion.

**(c) No — with the qualification (b) already states.** Self-merge remains fully
possible: the merging identity is a repo admin, `enforce_admins: false`, and `--admin`
always succeeds regardless of check state for that identity. What changes is that the
*default* command no longer succeeds unconditionally — an agent must now positively
determine which of the three paths in (b) applies before choosing a command, rather than
running `gh pr merge --squash --delete-branch` and having it work regardless of CI state.
That determination is strictly more than the pipeline does today, not less.

**(d) No, `enforce_admins: true` is not appropriate — reject it.** This is not because
`enforce_admins: true` leaves no override path in any form — it does not. The same admin
credentials Step 2 uses to `PUT` this branch's protection with `enforce_admins: false`
remain valid under `enforce_admins: true` too: nothing about that setting revokes the
identity's API access, so a real override path always exists — call the branch-protection
API again (`gh api --method PUT .../branches/main/protection` with `enforce_admins:
false`, or delete the protection rule outright), merge, and optionally restore protection
afterward. The rejection rests on that path being a **meaningfully worse override
mechanism for an unattended pipeline**, not on no mechanism existing:

- **It is multi-step, not atomic.** `enforce_admins: false` + `--admin` is one command
  that either succeeds or fails, run in the same breath as the merge itself. The
  reconfigure-merge-reconfigure path is a *sequence* — disable protection, merge,
  optionally re-enable — any one of which can be skipped, run out of order, or interrupted
  by a crash between steps. A run that dies after "disable" but before "re-enable" leaves
  `main` completely unprotected for every subsequent run on every host until something
  notices, silently reintroducing the exact zero-enforcement state ISS-0441 reports.
  `--admin` has no equivalent partial-completion state: either the merge happened with the
  override flag or it didn't.
- **It changes a repo-wide setting to make what is really a per-merge judgement call.**
  Flipping `enforce_admins` off is not a decision about *this* merge; it is a decision
  about every merge attempted by any agent on any host until it is flipped back. Using a
  repo-wide toggle to pass one PR conflates "this specific red check is attributable
  elsewhere" (a real, scoped judgement `core-directives.md` requires) with "no required
  check should block anyone until further notice" (a much bigger claim nothing in this
  record licenses).
- **It is not naturally audited per merge.** `--admin` shows up in
  `gh pr view <n> --json mergedBy,mergeCommit` as a property of the merge that happened,
  cheap to check after the fact. A protection-toggle-and-restore leaves no equivalent
  record tying the toggle to the one PR it was for — reconstructing "was protection off
  for a legitimate override, or because someone forgot to restore it" requires correlating
  separate `PUT`/`DELETE` calls against the settings API with merge timestamps, which nothing
  in this pipeline currently logs or checks.

So `enforce_admins: true` does not create a genuinely stuck, unrecoverable pipeline — the
admin credentials can always reconfigure their way out. What it does is force every
override, including the routine known-flake case in (b), through a heavier, state-mutating,
multi-step, harder-to-audit path instead of a single flagged merge command. `enforce_admins:
false` is preferred because it keeps the override at the granularity (one merge) and
auditability (one logged flag) this record is actually trying to achieve, not because
`enforce_admins: true` would leave the pipeline with literally no way forward.

## Configuration to apply (exact commands)

Owner of running these: ELIXIR-DEV (or whichever agent implements this record — this is
repo administration, not `lib/letflow/` code, but it is not this design step's job to run
it; see Forbidden in `.claude/agents/code-designer.md`).

**Step 1 — confirm the literal check-run names before configuring anything.** Do not
assume the job `name:` string in `ci.yml` is guaranteed to be the exact wire-level
check-run name GitHub reports (it is, for a non-matrix job with no reusable-workflow
indirection — both `backend` and `frontend` jobs in `ci.yml` are plain, non-matrix jobs —
but confirm rather than assume, since a required-status-check `context` that is even one
character off from the real check-run name will silently never be satisfied, leaving
`main` permanently blocked):

```
gh api repos/tvolodi/letflow/commits/$(git rev-parse origin/main)/check-runs \
  --jq '.check_runs[].name'
```

Expected output (two lines, exact strings — these are the `contexts`/`checks` values used
in Step 2):

```
Backend gate (mix letflow.check)
Frontend gate (npm run check)
```

If the output differs from the above, use the actual reported strings in Step 2 instead
— do not hand-edit `ci.yml`'s `name:` fields to match this record; fix this record's
`contexts` to match reality.

**Step 2 — configure branch protection on `main`:**

```
cat <<'EOF' | gh api --method PUT repos/tvolodi/letflow/branches/main/protection \
  -H "Accept: application/vnd.github+json" --input -
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Backend gate (mix letflow.check)",
      "Frontend gate (npm run check)"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

`strict: true` (branch must be up to date with `main` before a check is considered
satisfied) is intentional and already matches `GIT_MERGE.md`'s existing step 4-6
rebase-before-merge sequence — nothing about this record requires changing that
sequence. `allow_force_pushes: false` / `allow_deletions: false` close the two obvious
ways this same protection could be defeated without ever touching `/protection` again
(force-pushing over `main` directly, or deleting and recreating it) — both already
contradict `GIT_MERGE.md`/`ORCHESTRATOR.md` §7.1's existing prohibition on forcing
pushes to `main`, so this is making an already-stated rule structural, the same move
this whole record makes for required checks.

**Step 3 — verify the configuration landed (static check):**

```
gh api repos/tvolodi/letflow/branches/main/protection
```

Expected: **200**, not 404, with a JSON body whose
`required_status_checks.contexts` array contains exactly the two strings from Step 1,
`enforce_admins.enabled: false`, and no `required_pull_request_reviews` key (or `null`).
A 404 here means the PUT did not take — do not proceed to report this record's
configuration as done.

**Step 4 — verify live (AC3's actual requirement: prove it functions, not just that the
API accepts the config).** Use a real, disposable, low-stakes PR — do not fabricate a
red check; force a genuinely observable one:

```
# 4a. Create a trivial, safe scratch branch/PR (a no-op comment addition to this very
#     file is sufficient and honest — it does not misrepresent anything).
git checkout -b chore/verify-branch-protection-0018 origin/main
# make a one-line, clearly-scratch edit, e.g. append a verification-log line to this
# file's own "Verification log" section below, then:
git add docs/migration/decisions/0018-branch-protection-posture.md
git commit -m "chore: scratch commit to verify branch protection (0018)"
git push origin chore/verify-branch-protection-0018
gh pr create --title "chore: verify branch protection (0018)" \
  --body "Scratch PR to live-verify 0018's required-status-checks configuration. Not intended to ship a feature." \
  --base main --head chore/verify-branch-protection-0018

# 4b. Immediately, BEFORE CI finishes (checks PENDING), attempt the normal merge path:
gh pr merge <PR-number> --squash --delete-branch
# EXPECTED: non-zero exit, and gh's own rejection text naming the required checks as
# unsatisfied/pending — quote the ACTUAL output verbatim in the implementing agent's
# handoff, do not paraphrase it. (gh's exact wording varies by version; what must be
# quoted is whatever real rejection message this specific `gh` build produces — the
# proof is that it rejected, not that it used any particular sentence.)

# 4c. Wait for both required checks to report their real conclusion (gh pr checks
#     <PR-number> or gh run watch). If both are SUCCESS, retry the plain merge from 4b
#     — it must now succeed, proving the required-check gate is not a permanent block
#     when checks are actually green.

# 4d. If (b)'s override path needs its own live proof rather than being taken on faith:
#     on a SEPARATE scratch PR, intentionally introduce a real Backend-gate failure
#     unrelated to the change under test class this record is about (e.g., a scratch
#     commit that only touches this same decision doc could instead be paired with a
#     known-flaky path if one is currently reproducible), confirm `gh pr merge` without
#     `--admin` is rejected while it is FAILURE (not just PENDING, per 4b), then confirm
#     `gh pr merge --squash --delete-branch --admin` succeeds despite the FAILURE.
#     This step is optional if 4b/4c already demonstrate the PENDING-rejection path
#     convincingly and a real recent wasm_hang-class PR (e.g. #848, already merged) is
#     accepted as the historical proof of the FAILURE-rejection/--admin-override path
#     rather than re-manufacturing one — implementer's call, but state which was done.

# 4e. Clean up: close/merge the scratch PR and delete its branch either way; do not
#     leave a dangling scratch PR open against main.
```

Whichever of 4b-4d were actually run, and their real quoted output, must be recorded in
the implementing agent's handoff `result` under a field naming this verification
explicitly (e.g. `result.live_verification`) — a claim of "verified" with no quoted
command output does not satisfy AC3, per this project's "Never Call a Red Pipeline OK
Without a Source" discipline applied to this record's own claim of success.

### Verification log

Live-verified 2026-09-04 on scratch PR #887 (`chore/verify-branch-protection-0018`), a
real PR against the actually-configured `main` protection (Steps 1-3 above, applied
2026-09-04):

- **Step 1** (`gh api repos/tvolodi/letflow/commits/$(git rev-parse origin/main)/check-runs --jq '.check_runs[].name'`):
  returned exactly the two expected strings, `Backend gate (mix letflow.check)` and
  `Frontend gate (npm run check)` — no drift from `ci.yml`'s job names.
- **Step 2** (the `PUT .../branches/main/protection` call): applied cleanly, full JSON
  response echoed both contexts, `enforce_admins.enabled: false`.
- **Step 3** (`gh api repos/tvolodi/letflow/branches/main/protection`): `200 OK`,
  `required_status_checks.contexts` == the two Step 1 strings, `enforce_admins.enabled:
  false`, `required_pull_request_reviews` absent.
- **Step 4a-b, PENDING-rejection**: opened PR #887 and immediately ran
  `gh pr merge 887 --squash --delete-branch` before CI reported. Real rejection:
  `X Pull request #887 is not mergeable: the head branch is not up to date with the base
  branch.` (a `strict: true` consequence — the branch was in fact behind `main` by that
  point, a genuine sibling merge having landed in the interim, not a fabricated
  scenario).
- **Step 4c, BEHIND-then-real-FAILURE**: rebased the branch onto the new `main` HEAD and
  re-pushed. CI ran; one of two duplicate `Backend gate` runs hit the already-documented
  `wasm_hang` isolated-subprocess flake (ISS-0418/ISS-0352 class,
  `Letflow.Engine.Wasm.CallTimeoutTest`), leaving the PR's overall required-check state
  at FAILURE. `gh pr view 887 --json mergeable,mergeStateStatus` reported
  `mergeStateStatus: BLOCKED`. Re-ran `gh pr merge 887 --squash --delete-branch`: real
  rejection, `X Pull request #887 is not mergeable: the base branch policy prohibits the
  merge.` — a DIFFERENT, more specific rejection message than the earlier BEHIND case,
  confirming the required-status-check gate itself (not just staleness) is what's
  blocking.
- **Step 4d, override path proven live (not taken on the PR #848 historical precedent
  after all — a real, reproducible occurrence arrived during this very verification)**:
  ran `gh pr merge 887 --squash --delete-branch --admin` against that same FAILURE
  state. Succeeded — fast-forward merge to `main`, confirmed via the real `git log`
  fast-forward output naming the new `main` HEAD commit. This is the strongest form of
  the override-path proof: a live, unstaged wasm_hang recurrence, not a manufactured
  one.
- **Step 4e, cleanup**: PR #887 is merged (not left dangling open); `--delete-branch`
  removed `chore/verify-branch-protection-0018` on the remote, and the local copy was
  never created as a lingering branch beyond the verification session.
- **The "succeeds when green" half of Step 4c**, as it actually played out: this same
  ISS-0441 run's own real, non-scratch PR (#895) hit the `wasm_hang` flake TWICE running
  (first attempt, then a rerun) — both times main's own full suite passed clean and only
  the isolated `wasm_hang` subprocess stage flaked, on a PR whose diff touches zero WASM
  code. Rather than a clean "succeeds when green" demonstration, PR #895 became a SECOND
  real, unstaged instance of the FAILURE/`--admin`-override path: `gh pr merge --squash
  --delete-branch` was rejected (`the base branch policy prohibits the merge`) both
  times, and `gh pr merge --squash --delete-branch --admin` succeeded (fast-forward to
  `main`, commit `2967c3d9`) after the second occurrence was attributed the same way as
  PR #887's. This is honestly reported as NOT the originally-planned clean-green proof —
  the "succeeds when green, no override" path remains undemonstrated by a dedicated live
  run, though it is the simpler, unexercised branch of the same boolean gate whose
  PENDING/BLOCKED/override branches are now proven live twice over. The next ordinary PR
  in this pipeline that merges without hitting a flake stands as that proof in its own
  right, needing no special ceremony to demonstrate.

## Consequences — corrections required to other docs (AC4)

ISS-0441's own `affected_files` name three docs needing correction:
`docs/migration/decisions/0004-humanless-pipeline.md`, `.github/workflows/ci.yml`, and
`docs/agents/protocols/GIT_MERGE.md`.

Beyond those three, `grep -rniE --include="*.md" "hard gate|structurally impossible|Backend
gate|Frontend gate" docs/` was run to find every other place a CI or merge gate is
asserted, and the full real result is nine other files (re-run and re-checked for this
correction — the earlier version of this record claimed a four-file "complete set" that
omitted five real hits; every one of the nine below has actually been opened and read, not
assumed from the grep line alone). All nine need no change, but for different, specific
reasons rather than one blanket rationale:

- **`AGENT_SYSTEM.md`, `WF-02_requirement_implementation.md`,
  `WF-01_requirement_development.md`, `HANDOFF_PROTOCOL.md`,
  `0014-scripting-plugin-runtime-strategy.md`.** Each calls an *agent workflow step*
  (REQ-VALIDATOR, CODE-DESIGN-VALIDATOR, SECURITY-REVIEWER, TEST-DESIGN-VALIDATOR) a hard
  gate, meaning an agent cannot proceed to the next workflow step without it passing —
  that claim is true today and this record does not touch it. It is a different kind of
  "hard" than "structurally blocks a `git merge` to `main`," which is the only kind
  ISS-0441 is about.
- **`docs/agents/protocols/GIT_SETUP.md` (line 64).** "Structurally impossible" here
  describes `git checkout main` failing from a secondary worktree because git itself
  refuses to check out a branch already checked out elsewhere — a worktree-checkout
  limitation, unrelated to CI or merge enforcement.
- **`docs/anti-patterns.md` (five hits, across three distinct anti-pattern sections).**
  All are descriptive incident narration about past events, or a proposed future tooling
  idea, none asserting a current, general claim about `main`'s merge protection:
  - Line 1578, in the "top-level `status` field" anti-pattern section: "This was caught
    only at CI (PR #681's first `Backend gate` run failed on it)" — a specific `Backend
    gate` run failing during the PR #681 / `lint_handoffs` incident.
  - Line 1611, in that same section's later recurrence write-up: "...instead make it
    structurally impossible (e.g. ORCH greps every handoff...)" — a proposed future
    ORCH-side check, not a description of any existing enforcement.
  - Line 1689, in the separate "`mix format --check-formatted`" anti-pattern section:
    "REQ-167's PR #688 failed CI's backend gate on the very first run" — a distinct
    incident from line 1578, about a formatter line-length failure, not the status-enum
    mistake.
  - Line 1910, in the separate "dead default argument" anti-pattern section's REQ-195
    recurrence: "...the same narrow ISS-0069-focused task CI's backend gate runs" — a
    third distinct incident, about a compiler warning only surfacing under a specific
    mix task.
  - Line 1920, in that same section's later REQ-203 recurrence: "...past FIVE separate
    hard gates that each ran a real `mix compile`/`mix test` pass on this exact file" —
    a different occurrence of the same dead-default-argument anti-pattern, still
    describing what got past review gates, not `main`'s git-merge protection.

  None of the five lines asserts a current, general claim about `main`'s merge
  protection; they recount what happened in past CI/review runs or propose unrelated
  future tooling.
- **`docs/migration/decisions/0011-frontend-ownership.md` (line 118).** "A frontend gate
  equivalent to `mix letflow.check`" refers to a not-yet-built CI job scoped as future S8
  requirement work, not a claim about `main`'s current branch-protection enforcement.
- **`docs/migration/decisions/0017-task-queue-selection-model.md` (line 201).**
  "Structurally impossible" here describes a task-queue locking mistake this record's own
  API redesign prevents — a claim about task-queue semantics, unrelated to CI or git-merge
  enforcement.

- **`docs/migration/decisions/0004-humanless-pipeline.md`, principle 2 ("Fully humanless
  operation").** Currently reads: "...commit → push → merge → CI → local-repo-update,
  all performed by agents **at their own discretion**, with no human approval gate
  anywhere in the chain." This is no longer fully accurate once this record's
  configuration is applied: merge is still performed by an agent with no human approval
  gate (unchanged — `enforce_admins: false` means no human is ever consulted), but it is
  no longer purely "at their own discretion" in the sense of "an unqualified `gh pr
  merge` always works regardless of CI state." Add a clause: "...with no human approval
  gate anywhere in the chain. Merge itself is bounded, not unconditional, by
  `main`'s required-status-checks branch protection (0018): the ordinary merge command
  succeeds only when both CI gates are green, and bypassing a red or pending gate
  requires the same agent to take a second, distinct, individually-logged action
  (`--admin`) rather than being available by default — see 0018 for the full mechanism.
  This does not reintroduce a human checkpoint; it makes the agent's own judgement call
  visible in the merge history instead of invisible in an unprotected one." Also add a
  forward-reference in `0004`'s Consequences list, alongside the existing bullet about
  git-setup/git-merge wrapping: "As of 0018, that merge is also gated by GitHub branch
  protection on `main`, not left to the wrapper's own discipline alone."

- **`docs/agents/protocols/GIT_MERGE.md`, Step 8.** Currently a single unconditional line:
  `gh pr merge --squash --delete-branch`, with only the parenthetical "(all gates already
  passed; see Precondition above...)" — nothing here today accounts for a *rejected*
  merge, because nothing before this record could reject it. Replace step 8 with the
  three-path procedure from this record's (b): attempt the plain command first; on
  rejection, check whether both required checks are `SUCCESS`/`PENDING`/`FAILURE` via
  `gh pr checks <PR>`; if `PENDING`, wait and retry the plain command (no `--admin`); if
  `FAILURE` **and** the branch already carries a structural attribution in its PR body
  (per this same file's existing step 7 requirement), use `gh pr merge --squash
  --delete-branch --admin` and note the override explicitly in
  `result.git_evidence`; if `FAILURE` with no attribution, do not override — route to
  ISSUE-FIXER per the existing step 5d path instead of merging. Also update this file's
  Precondition section, which currently says CI existing/green matters only so that "PR
  checks... mean anything" — after 0018 they also gate the actual merge call, not only
  the meaning of "green" the agent chooses to trust.

- **`.github/workflows/ci.yml`.** No functional change needed — its job `name:` strings
  are the contract this record depends on (Step 1 above verifies them). Add one comment
  line near the top of each of the `backend`/`frontend` job blocks noting that the job's
  `name:` string is now a required-status-check `context` referenced by
  `docs/migration/decisions/0018-branch-protection-posture.md`, so it must not be
  renamed without updating that record's `contexts` list and re-running Step 1/2 above —
  this is the one file where a silent rename would silently re-open the exact hole
  ISS-0441 reports, by making the configured `context` string stop matching any real
  check-run name (GitHub would then report the required check as perpetually missing,
  which behaves as a permanent block, not a silent pass-through — worth naming as the
  failure mode this comment prevents).

No change is needed to any of the nine other files listed above under "Consequences" —
each was checked individually and none asserts "structurally blocks a git merge to
`main`" in the sense this record is about. Conflating agent-workflow-sequencing gates (or
unrelated uses of "structurally impossible"/"hard gate"/historical narration) with that
specific claim was ISS-0441's own point of confusion to resolve, not a defect in those
other docs' wording.

## A real gap found live, after this record's own configuration (not anticipated by Step 4)

Discovered 2026-09-04, immediately after ISS-0441's own real PR (#895) merged: a plain
`git push origin main` (not a PR merge — a direct push of a doc-only follow-up commit)
succeeded, but the remote printed `remote: Bypassed rule violations for refs/heads/main:
2 of 2 required status checks are expected.` This is a DIFFERENT, more permissive path
than anything Step 4 tested. `gh pr merge` without `--admin` genuinely refuses outright
when a required check is unsatisfied — that path is proven. But a direct `git push` to
`main` by the same admin identity does NOT refuse; it silently bypasses the rule with
only a server-side informational line, no distinct flag, no separate confirmation, and
easily missed in a `git push` command's ordinary output. This is exactly the invisible-
discretion failure mode this whole record exists to close, reappearing on a path Step 4
never exercised because this pipeline's own `GIT_MERGE.md` procedure always merges via
`gh pr merge` on a PR, never a direct push to `main`.

**Why this does not invalidate the decision already made**: every merge this pipeline
performs goes through `GIT_MERGE.md`'s PR-based procedure, which this record's
protection genuinely gates as designed. A direct push to `main` is already, separately,
against this project's own established discipline (`GIT_MERGE.md`/`ORCHESTRATOR.md`
§7.1 prohibit force-pushing `main`, and the whole pipeline's git-setup/git-merge wrapper
model assumes a PR, never a bare push) — this gap is only reachable by an agent already
deviating from the documented workflow, as this record's own author did here for a
trivial doc-only fix.

**Follow-up, not re-opening this decision**: file a new issue recommending GitHub's
separate "restrict who can push to matching branches" setting (`restrictions`, left
`null` in this record's own Step 2 configuration) be revisited, or that `GIT_MERGE.md`
add an explicit line prohibiting direct pushes to `main` even for a trivial fix (route
everything, including one-line doc corrections, through the same PR path this record
protects) — closing the gap by removing the alternate path entirely rather than trying
to make direct pushes themselves refuse the same way `gh pr merge` does.

## ISS-0467 resolution: direct-push prohibition (2026-09-05)

**Option chosen: Option 2 — documented prohibition, not `restrictions`.** ISS-0467 (filed
to resolve the follow-up named above) is now designed and applied. The reasoning:
GitHub's `restrictions` field gates *who* may push, not *why* or *under what check
state* — and every push and every merge this pipeline makes authenticates as the same
single admin identity (`tvolodi`, `admin: true`, live-confirmed by ISSUE-FIXER's
diagnosis in `handoffs/WF03-ISS0467-20260904/step-01-issue-fixer.json`). An allowlist
naming that one identity would accept the exact bypass it would need to reject, and no
distinguishing mechanism (deploy key, bot account, differently-scoped PAT) currently
exists in this project's auth setup — manufacturing one purely to make `restrictions`
non-degenerate would be a larger piece of infrastructure than this MINOR-severity issue
justifies. Option 2 — removing the alternate path entirely rather than trying to make it
discriminate — is the only one of the two candidates named above that actually closes
the gap.

This resolution made two textual changes, applied verbatim as designed: a new
prohibition paragraph in `docs/agents/protocols/GIT_MERGE.md`'s `## Precondition`
section (no direct `git push origin main`, ever, for any change including a one-line doc
fix), and a new closing paragraph in `docs/agents/ORCHESTRATOR.md`'s `## 10. Sizing
rule` section clarifying that the sizing-rule exception licenses skipping the
producer/validator review chain, not skipping `GIT_MERGE.md`'s branch-and-PR procedure.
Full reasoning, the exact verbatim text, and the acceptance-criteria mapping are in
`lib/letflow/design/iss-0467-direct-push-prohibition.md`.

## What this record does not decide

- Whether other branches (`feature/*`) get any protection. Out of scope — this pipeline's
  own branch-lifecycle model (`GIT_SETUP.md`/`GIT_MERGE.md`) already deletes feature
  branches immediately on merge; protecting a branch that lives for one run's duration
  and is never merged into by anything but its own run has no clear benefit and is not
  addressed here.
- Whether a third required check (e.g. a future security-scan job) should be added later.
  Any future CI job added as `required` follows Step 1/2 of this record's own procedure;
  this record does not pre-authorize or block that, it only sets the process.
- Automating the override decision itself (e.g. a script that inspects `statusCheckRollup`
  and auto-attributes failures). Explicitly out of scope — `core-directives.md`'s
  failure-attribution discipline is deliberately a judgement call an agent makes and
  states its reasoning for, not a mechanical count/pattern match; automating it would
  reintroduce exactly the count-matching failure mode that discipline was written to
  forbid.

**GH #2412 addendum (2026-10-21).** The required contexts are unchanged. `frontend` is now
skipped at job level on docs-only PRs (a job skipped by its own `if:` reports as passing under
the same name); the older "never a job-level path-filter `if:`" rule is superseded for
job-level `if:` only. See `lib/letflow/design/iss0591-iss0592-ci-dedup-path-filter.md`
(addendum at the top) and the `.github/workflows/ci.yml` header. Merge-queue acceptance of a
skipped "Frontend gate" is still to be shown by a docs-only PR run.
