# GIT_MERGE Protocol

**Function:** `fn:git-merge`
**Read by:** `ELIXIR-DEV`, `FRONTEND-DEV`
**Used in:** WF-02 Step Final, WF-03 Step Final, WF-04 direct-routed fix Step Final

## Purpose

Rebases the feature branch onto current `main`, opens a PR, merges it, and cleans up —
unconditionally, with no human review step, because every pipeline gate (build, tests,
security review, release validation) has already passed before this step runs. Per
`docs/migration/decisions/0004-humanless-pipeline.md`, this is by design: there is no
human in the loop to wait for, and the merge itself is pre-authorized once all upstream
gates are green.

## Precondition

CI must exist and be green for this protocol's step 7-8 (PR checks) to mean anything.
**As of REQ-136 and REQ-138 (both landed), Letflow has a `.github/workflows/ci.yml`**
with a `backend` job (runs `mix letflow.check` against a `postgres:16` service) and a
`frontend` job (runs `npm ci && npm run check` in `web/`), both triggered on every
`push` and `pull_request`. Insert "wait for the GitHub Actions `backend` and
`frontend` jobs to report success on the PR" between steps 7 and 8, mirroring R-Co's
pattern — use `gh pr checks <PR>` or `gh run view <run-id> --json jobs` to confirm
both jobs' conclusions before proceeding to step 8's merge. **As of
`docs/migration/decisions/0018-branch-protection-posture.md`, these two jobs' names are
also required status checks on `main`'s branch protection — they gate the actual merge
call itself, not only the meaning of "green" the agent chooses to trust. A plain merge
attempt while either is red or pending is rejected by GitHub, not merely inadvisable.**

> **No direct push to `main`, ever — not even a one-line doc fix (added
> 2026-09-05, ISS-0467/0018 follow-up).** `main`'s required-status-checks branch
> protection (0018) genuinely gates every merge made through this protocol's own
> step 8 — but it does **not** gate a bare `git push origin main`. GitHub's
> `restrictions` setting (branch protection's separate "restrict who can push"
> control) cannot close that gap on this project: every push and every merge this
> pipeline makes authenticates as the same single admin identity, so an allowlist
> naming that identity would accept the exact bypass it would need to reject
> (live-confirmed, ISS-0467). The only closure available is removing the
> alternate path itself: **every change to `main`, with no exception for size,
> triviality, or file count — including a single-line correction to this very
> file — goes through this protocol's full branch-and-PR procedure (steps 1-9
> below), never a direct `git push origin main`.** This applies even when
> `ORCHESTRATOR.md` §10's sizing rule licenses skipping the producer/validator
> agent chain for a qualifying edit — §10 licenses skipping *review*, not
> skipping *this protocol*; see `ORCHESTRATOR.md` §10's own clarifying sentence
> (added by this same fix) for the canonical statement of that boundary. An
> agent that finds itself about to run `git push origin main` for any reason has
> misread this protocol; stop, create a branch, and proceed from step 1 instead.
>
> **Reaffirmed with zero exceptions (2026-09-15, ISS-0677) — "docs-only" is not
> an exception, and there never was a project precedent making it one.** Six
> commits landed via bare `git push origin main` on 2026-09-14/15 (`262b2a1e`,
> `40fb4b9f`, `83ef626d`, `37f837b0`, `f3f1b5f7`, `4793eed5` — REQ-350/353/354
> close-outs, ISS-0675 filing/resolution, and an ISS-0676 blocked-status
> bookkeeping entry), each justified in its own run-history note as "matching
> this session's/project's established precedent" for a docs-only change. **No
> such precedent was ever decided.** The reasoning above is unconditional on
> content: the gap this paragraph closes is that GitHub's push-allowlist
> cannot distinguish a legitimate push from a bypass because both come from the
> same admin identity — that argument does not weaken for a run-history append
> or a decision-record sign-off any more than for application code. A "narrow
> exception for append-only bookkeeping files" was considered and rejected for
> this same reason: nothing mechanically stops a future direct push from
> touching more than the claimed append-only file once the exception exists in
> prose, and a self-asserted "this one only touched bookkeeping" claim is
> exactly the unvalidated producer self-report `core-directives.md`'s
> producer/validator principle exists to refuse — see
> `docs/anti-patterns.md`'s "Citing a prior session's own bypass note as
> 'established precedent' instead of re-reading the actual rule (ISS-0677)"
> for the full incident and why each session inherited the excuse rather than
> the rule. The six commits above are not reverted or rewritten — they already
> merged and the run-history entries recording their (incorrect) justification
> are append-only historical fact, not errors to silently correct — but no
> further direct push to `main` is authorized for any reason, docs-only
> included. **Mechanical enforcement — as of 2026-09-26, ISS-0841:** This
> paragraph's enforcement is no longer prose-only. `tvolodi/letflow` now has a
> GitHub repository ruleset (`id: 24040748`, "main-protection", see decision
> 0034's Applied addendum) that enforces this rule at the git ref level. A bare
> `git push origin main` is rejected with `GH013: Changes must be made through a
> pull request` — not advisory, not bypassable by the pipeline identity for a
> bare push.

**What "reported green" means here.** This suite carries a standing set of pre-existing
failures (13-15 at the time of writing) and has for days, so "green" read as "zero
failures" would make this precondition unsatisfiable and is *not* what it means. **Green
means: no failure attributable to this branch.** Attribution is made structurally, per
`core-directives.md`'s "Failure Attribution Is Structural, Never By Count-Matching" —
read it there; it is not restated here. **Do not attribute by comparing counts with a
previous run.** A failure you have structurally cleared is filed and forwarded per
`ISSUE_QUEUE.md` and does not block this precondition; a failure you cannot clear does.

## Gates block (audit #2874 R1, R4: binding)

A PR that changes `lib/`, `web/`, `apps/`, `priv/` or `test/` carries this section in its body,
one line per gate, each the last verdict on the final code:

```
## Gates
Tier: FULL | SHORT | DIRECT | HIGH
- CODE-DESIGN-VALIDATOR: <verdict> — evidence: <file:line | test name | command + rc>[, ...]
- SECURITY-REVIEWER: <verdict> — evidence: ...
- REVIEWER: <verdict> — evidence: ...
- TEST-DESIGN-VALIDATOR: <verdict> — evidence: ...
- CI: <run URL> <conclusion>
- Outside review: <session> <verdict> — evidence: ...   (HIGH only)
```

`<verdict>` is exactly one of `PASS`, `PASS_WITH_FINDINGS`, `FAIL`, `N/A (<one-line reason>)`. Until
REQ-522 lands the tier is `FULL` unless `ORCHESTRATOR.md` §10 (DIRECT) applies. Every `fix` PR body also
carries two lines, found from `git log`/`git blame`, never guessed:

```
Introduced-by: #<PR> | <sha> | unknown
Missed-by: <gate role> | CI | none (not catchable before merge) | unknown
```

The supervisor checks the block (`scripts/check_pr_gates.sh <PR>`) before it grants a merge slot: a missing
block or a line without evidence gets no slot. The supervisor never waives or overrides a gate verdict
(`AGENT_SYSTEM.md` §10).

## Procedure

```
1. Verify current branch:
   git branch --show-current
   Must equal feature/<run-id>. If not: STOP; report FAIL to ORCH.

2. Stage any remaining uncommitted files (test specs, reports, changelogs, handoffs
   written by downstream agents since the implementing agent's own commit) by
   explicit filename — never `git add -A` (updated 2026-08-17, ISS-0023/GH#81:
   unsafe in a shared/worktree checkout, and contradicts this project's own
   established practice of staging by filename in every handoff commit):
   git status   # see what changed
   git add <file1> <file2> ...
   If `git status` shows a clean tree, skip to step 4.

   Same shared-checkout reason, second case: if another ORCH-role session is live in
   this same checkout, `git status` here may show ITS files and `git log` its commits —
   stage by explicit filename only (already required above) and push only your own
   commits; see `ORCHESTRATOR.md` §7.1.

3. Commit remaining artifacts:
   git commit -m "feat(<run-id>): finalize artifacts — test specs, reports, status

   Requirements: <comma-separated requirement IDs>
   Handoff: <run-id>"

   For WF-03 fix branches use prefix "fix" instead of "feat".

4. Sync with remote:
   git fetch origin main

5. Rebase onto origin/main:
   git rebase origin/main

   ── CONFLICT HANDLING ──────────────────────────────────────────────
   a. Count conflicted files:
      git diff --name-only --diff-filter=U | wc -l

      If count > 5 OR any conflicted file is under lib/letflow/process_instance.ex,
      lib/letflow/instance_supervisor.ex, or priv/repo/migrations/:
        git rebase --abort
        → complete-handoff(status: FAIL,
            issues: [{severity: BLOCKER,
                      description: "merge conflict too complex for inline resolution: <files>"}],
            next_action: "ORCH escalates to CODE-DESIGNER for conflict resolution")
        STOP

   b. For each conflicted file (≤5 files, not in the excluded paths above):
      - Read HEAD version and incoming version
      - Apply the correct resolution (preserve valid changes from both sides)
      - git add <file>

      ⚠️ `git checkout --ours`/`--theirs` is INVERTED during `git rebase`
      compared to `git merge` (added 2026-08-17, ISS-0039/GH#121 — this
      inversion caused a real silent overwrite of a resolved issue record on
      `main`, discovered only because a later run independently re-read the
      file instead of trusting the resolving run's own log). During `git
      rebase`, `--ours` = the commit you're rebasing ONTO (main), `--theirs` =
      your own commit being replayed — the opposite of `git merge`'s meaning.
      Don't use either flag from merge-trained habit during a rebase conflict;
      read the actual `<<<<<<<`/`=======`/`>>>>>>>` content (or `git show
      :2:<path>` / `git show :3:<path>`) and hand-resolve instead. After
      resolving, independently re-read the resulting file's content before
      writing a log/status entry claiming what was kept — see
      `docs/anti-patterns.md`'s matching entry for the full incident.

      ⚠️ IF THAT RE-READ INCLUDES A BYTE-IDENTITY CHECK (e.g. AC4-style span
      hashing to prove a rebase didn't clip protected content — added 2026-08-21,
      ISS-0210/GH#402): hash the git BLOB, never the checked-out working-tree file.
      `git show <sha>:<path>` or `git cat-file blob <sha>` — not a plain file read.
      This repo's `.gitattributes` forces LF only for `*.ex`/`*.exs`; `.md` and
      `.json` files are NOT covered, so on a host with `core.autocrlf=true` (verified
      present on this host: `git config --get core.autocrlf` → `true`) every
      checkout/rebase re-materialising a tracked `.md` or `.json` file rewrites it to
      CRLF — identical content then hashes differently before and after, by exactly
      +1 byte per line, with nothing actually wrong. `WF03-ISS0200-20260821` hit this
      live on this same host: all three AC4 spans hashed differently immediately
      after a rebase, purely from the CRLF rewrite, and were correctly re-measured
      against the committed blob instead.

      SEMANTIC conflicts (added 2026-08-17, ISS-0023/GH#81): a textual conflict
      marker means git couldn't merge two overlapping edits automatically. A
      semantic conflict is different in kind and easy to miss — both sides may
      have rewritten the SAME function in incompatible ways with no textual
      overlap at all (e.g. two concurrent requirements each changing the same
      function's return shape). Recognize it by asking, for every function
      changed on either side of the conflict: did the OTHER side also touch this
      function's body or contract, even without a textual marker there?

      If yes, neither "take ours" nor "take theirs" is presumptively correct —
      each may encode a real fix or a real feature the other side lacks. Resolve
      by composing both intents into one correct implementation (not by picking
      a side), then PROVE the composition mechanically rather than by inspection:
        - Diff already-shipped `@spec`s against origin/main after resolution —
          `git diff origin/main -- <file> | grep '@spec'` — a byte-level change
          to a signature that was NOT the point of either side's work is a signal
          the composition dropped or altered something unintended.
        - Exercise the merged result under the specific condition that would
          expose a wrong resolution (not just `mix test` against the ordinary
          suite) — e.g. a cold `mix run --no-start` VM with no Repo/DB started,
          if the conflict concerns code a warm test VM's already-loaded modules
          would silently paper over. Pick the condition from what's actually
          different about the two sides' changes, not a generic smoke test.
      Worked example this guidance is drawn from: REQ-023 and REQ-024 (merged
      concurrently from a different worktree) both rewrote
      `Letflow.TenantProvisioning.tenant_scoped_migrations/0` — REQ-024 with a
      bare `{version, module}` list, REQ-023 with a `{version, module, filename}`
      manifest fixing a module-loading defect. Taking either side alone would
      have silently dropped the other's migration from the registry or
      reintroduced the loading defect; the correct resolution composed both into
      one manifest, verified by diffing `@spec`s and by dumping the manifest from
      a cold `mix run --no-start` VM (exactly where the dropped/defective form
      would have raised).

   c. git rebase --continue

   d. Verify the build still passes:
      mix format --check-formatted
      If FAIL: mix format, git add <file>, git rebase --continue (added 2026-08-21,
      ISS-0177/GH#363 — three 2026-08-20 runs merged unformatted code to main; none of
      their own validation records mention running this check at all, and this step is
      the reason: until now, Step Final re-verified compile and tests after rebase but
      never format, so a producing step's own unreported/skipped format check had no
      second chance to be caught before merge. This closes that gap structurally, at
      the one point every run passes through regardless of what an earlier step did or
      didn't report.)
      mix compile --warnings-as-errors
      If FAIL: fix compile errors, git add <file>, git rebase --continue
      mix test

      ⚠️ This suite carries a standing set of pre-existing failures — a non-zero
      failure count here is NOT by itself a FAIL. Before reporting FAIL, ATTRIBUTE
      EACH failure structurally, per `core-directives.md`'s "Failure Attribution Is
      Structural, Never By Count-Matching" (canonical home; not restated here).
      "Green" at this step means NO FAILURE ATTRIBUTABLE TO THIS BRANCH, not zero
      failures. Do NOT attribute by comparing counts with a previous run — that
      method is what this rule forbids. A failure you have structurally cleared is
      filed and forwarded per `ISSUE_QUEUE.md` and does NOT block this step; a
      failure you cannot clear is unattributed, and unattributed blocks.

      If FAIL (i.e. at least one failure is attributable to this branch, or is
      unattributed):
        → complete-handoff(status: FAIL,
            issues: [{severity: BLOCKER, description: "format/build/tests failed after rebase"}])
        ORCH routes to ISSUE-FIXER; after PASS, return to step 5
   ────────────────────────────────────────────────────────────────────

6. Push branch to remote:
   git push origin feature/<run-id>

   ⚠️ NON-FAST-FORWARD IS THE NORMAL CASE HERE, NOT AN ERROR (added 2026-08-21,
   ISS-0210/GH#402). `GIT_SETUP.md` step 7 pushed this exact branch already, at Step 00,
   as the coordination signal. Step 5's rebase just rewrote every commit this run made
   since then. So whenever step 5 actually replayed at least one commit, the remote still
   holds the pre-rebase tip and a plain `git push` here is REJECTED as non-fast-forward —
   every time, not occasionally. (This is a structural consequence of the protocol text,
   not merely a hypothetical: `WF03-ISS0200-20260821`'s Step Final anticipated exactly
   this deadlock after its branch was rebased twice, and its dispatch was corrected
   mid-step to authorize `--force-with-lease` on its own branch — but the agent avoided
   ever needing the push by resetting to its published tip and merging `origin/main` in
   instead, so the rejection itself was never actually observed there. See that run's
   `step-final-git-merge.json`, `result.issues[0]`.)

   If step 5's rebase was a NO-OP (origin/main had no new commits since this branch's
   last push, so nothing was replayed): the plain `git push origin feature/<run-id>`
   above still works, ordinary fast-forward. Don't force pre-emptively — try the plain
   push first and only act on an actual rejection.

   If the push above IS rejected as non-fast-forward: republish with
   `git push --force-with-lease origin feature/<run-id>` — never bare `--force`.
   `--force-with-lease` refuses if the remote moved since your last fetch of it, which is
   exactly the check that matters if a concurrent session somehow pushed to this SAME
   feature branch (rare — one branch belongs to one run — but the lease is what makes the
   republish safe rather than merely convenient).

   **Scope of this authorization, stated exactly so it cannot be read broader than
   intended: this covers ONLY the run's own `feature/<run-id>` branch.** It never extends
   to `main`, and never to a commit authored by a different session — `ORCHESTRATOR.md`
   §7.1's prohibition on forcing those is UNCHANGED and unrelated; that section governs a
   different actor (ORCH itself) pushing shared registry/log commits to `main` from a
   checkout other sessions may also be writing, not a single run republishing its own
   already-rewritten branch. If a `--force-with-lease` push is itself rejected, report it
   in `result.issues` — do not escalate to bare `--force` and do not retry blindly; re-fetch
   and re-derive what changed on the remote first.

7. Create PR:
   gh pr create \
     --title "feat: <one-line summary> [<run-id>]" \
     --body "## Summary
<last-agent result.summary>

## Requirements
<comma-separated requirement IDs>

## Validation
- mix compile --warnings-as-errors: PASS
- mix test: <passed> passed, <N> failed, 0 attributable to this branch
  (attribution route <1|2|3>: <one clause naming the evidence>; recorded in
  handoffs/<run-id>/)
- SECURITY-REVIEWER: PASS | out of scope (<one clause: why no tenant-data path>)
- RELEASE-VALIDATOR: PASS

## Handoffs
handoffs/<run-id>/" \
     --base main \
     --head feature/<run-id>

   ⚠️ The `mix test` line MUST NOT be written as a bare verdict. "Green" here means
   no failure attributable to this branch (see the Precondition), NOT zero failures,
   so a bare `PASS` next to a non-zero failure count is a red pipeline labelled OK
   without its source — forbidden by `core-directives.md`'s "Never Call a Red
   Pipeline OK Without a Source". Fill in the real counts and the attribution route
   (`core-directives.md`, "Failure Attribution Is Structural, Never By
   Count-Matching") — you already have both from step 5d; copy them. If `<N>` is 0,
   write `0 failed` and drop the parenthetical. **The PR body is the one artefact a
   human reads without following a pointer, so the attribution must appear IN it,
   not only in the handoff it cites.** The `mix compile --warnings-as-errors` line
   needs no such treatment: that gate genuinely is zero-tolerance. The
   SECURITY-REVIEWER line carries a reason because "out of scope" is otherwise an
   unsourced judgement in exactly the same way.

   For WF-03 branches use --title "fix: <one-line summary> [<run-id>]"

   If `gh` is unavailable (no auth, no network): record
   git_evidence.pr_create_error, skip to step 9 with the branch left pushed but
   unmerged, and set result.status = PARTIAL — ORCH must not treat this as
   silent success. Note it explicitly for the next session to pick up.

8. Merge PR (all gates already passed; see Precondition above for what "all gates"
   means now that REQ-013's local gate and REQ-136/REQ-138's CI have landed). As of
   `docs/migration/decisions/0018-branch-protection-posture.md`, `main` has
   required-status-checks branch protection, so the merge is no longer unconditional —
   follow this three-path procedure:

   a. Attempt the plain merge first:
      gh pr merge --squash --delete-branch
      If it succeeds, proceed to step 9.

   b. If it is rejected, check both required checks' state:
      gh pr checks <PR>
      - If `PENDING` (or the rejection cites the branch being behind `main`, resolved
        by re-running steps 4-6's rebase), wait and retry the plain command from (a) —
        never `--admin` for a merely-pending or stale check.
      - If `FAILURE` **and** the branch's PR body already carries a structural failure
        attribution (per step 7's requirement above — the exact class, why it is
        unrelated to this branch, and the evidence), use:
          gh pr merge --squash --delete-branch --admin
        and record the override explicitly in `result.git_evidence` (which check
        failed, the attribution, and that `--admin` was used).
      - If `FAILURE` with no attribution yet established, do NOT override merge past
        it — route to ISSUE-FIXER per step 5d's existing path instead, get the
        attribution done first, then return to this step.

   ⚠️ The rebase in step 5 and the squash in step 8 both invalidate every commit sha
   this run already recorded in `result.git_evidence.commit_sha_list`. That is
   expected and is NOT a bookkeeping defect — do not go back and rewrite handoffs
   after the merge. `HANDOFF_PROTOCOL.md` §2's `commit_sha_list` subsection is the
   canonical statement of what that field covers; this line does not restate it.

9. Local cleanup — return to main (MANDATORY):
   git checkout main
   git pull --ff-only origin main
   git branch -d feature/<run-id>

   Verify:
   git branch --show-current   # must output: main
   git log --oneline -1        # must show the squash-merge commit from step 8
   git status                  # must show a clean working tree

   If any check fails: report as FAIL with details.

10. → complete-handoff(status: PASS,
      artifacts_out: ["branch: feature/<run-id> (squash-merged into main, branch deleted)"],
      next_action: "ORCH marks run COMPLETED and releases owned_modules lock")
```

## Acceptance criteria

- [ ] `gh pr merge` exited 0 (or PARTIAL was correctly reported if `gh` unavailable)
- [ ] `git branch --show-current` is `main`
- [ ] `git pull --ff-only` on main after merge exited 0
- [ ] `git log --oneline -1` shows the squash-merge commit
- [ ] `git status` shows a clean working tree

## Worktree variant

Added 2026-08-17 (ISS-0023/GH#81). **Applies whenever this checkout is a secondary
`git worktree` sharing one `.git` with a primary checkout that holds local `main`** —
`git worktree list` shows more than one entry. Steps 8-9 behave differently here.

**Step 8** (`gh pr merge --squash --delete-branch`) partially fails *by design* in
this setup: the GitHub-side merge succeeds via the API, then `gh`'s local side
effect of switching this checkout to `main` errors (`fatal: 'main' is already used
by worktree at ...`) — and because that step errors, `--delete-branch` never runs
either. **Reading only the error output, an agent would reasonably conclude the
merge failed when it had actually already succeeded — verify before treating this
as FAIL:**

```
gh pr view <n> --json state,mergedAt
```

If this shows `"state":"MERGED"`, the merge landed — ignore the local checkout
error and continue. Then delete both refs explicitly, since `--delete-branch` never
ran:

```
gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/feature/<run-id>   # remote
git branch -d feature/<run-id>                                          # local, once off it
```

**Step 9** (`git checkout main`) fails outright here for the same reason step 8's
local side effect does — git refuses to check out a branch already checked out in
the primary worktree. Replace step 9 with:

```
9w. git fetch origin main --prune
    git checkout --detach origin/main
```

Detached HEAD at the fetched remote tip — never checks out local `main`. The
"Acceptance criteria" section above doesn't transfer literally to this variant: `git branch
--show-current` outputs empty (not `main`) under a detached HEAD by design, and
`git status` reports "HEAD detached at ..." rather than being on a named branch.
Verify instead with:

```
git rev-parse HEAD                # must equal:
git rev-parse origin/main          # (i.e. HEAD is exactly at the fetched merge commit)
git log --oneline -1               # must show the squash-merge commit from step 8
git status                         # must show a clean working tree (detached HEAD is expected, not a failure)
```

## Conflict escalation

When this step FAILs due to a complex conflict (>5 files or the excluded paths), ORCH
routes to CODE-DESIGNER to produce the correct merged content for each conflicting
file, then ELIXIR-DEV/FRONTEND-DEV applies it and re-attempts from step 5.
`rework_count` applies; `max_rework = 3` before ESCALATED.
