# GH #2622: per-sha CI concurrency for main pushes + CD "tip rule"

Author: CODE-DESIGNER. Branch `fix/GH-2622-ci-push-concurrency` (off `06bd6b34`). Supersedes the CD gate in
`lib/letflow/design/req367-cd-qa-deploy.md` §2 "How the gate reuses `ci.yml`'s `changes` job" (:221) and §3 (:313).
No required check, job name, or ruleset changes (`docs/merge-queue.md:6-10`; aggregator names `ci.yml:46-50`).

## 0. Verified facts (2026-10-15)

| # | Fact | Source |
|---|---|---|
| F1 | One concurrency group for every push to `refs/heads/main`; cancel-in-progress only on `pull_request`. A third arrival cancels the PENDING run regardless. | `ci.yml:162-171`; issue #2622 |
| F2 | Trigger of today's burst: run 38665714603 (`9974a3a4`, push) has `Backend shard 2/3` `in_progress` since 01:35:48Z (all other jobs done by 01:45:48Z). It holds the single slot; `fe06bdd9` and `048a4253` were cancelled while pending; `a1033b8e` has no push run in the list. No job in `ci.yml` sets `timeout-minutes` (grep: 0 hits), so the 360-min default applies. | `gh run view 38665714603`; `gh run list --workflow CI --branch main` |
| F3 | The deploy cannot be pinned to a sha from CD: the key is a forced command (`cd.yml:65-70`) and the script deploys whatever `git pull` yields (`deploy/redeploy-qa.sh:41-43`). Pinning would need the script to parse `SSH_ORIGINAL_COMMAND` (OpenSSH exports it for `command=` keys) or an infra change to the key; both widen the restricted key's input surface and are rejected (§7). The tip is the only deployable target. | as cited |
| F4 | The orchestrator's "docs-only B hides A" case cannot happen today: on `push` the `changes` job always writes `backend=true`/`frontend=true` (`ci.yml:210-215`), so `should_deploy` (`cd.yml:48-56`) is always true for a push run. The real loss is cancellation (F1/F2). The new gate (§3) diffs against QA's deployed sha, so a per-commit view is never used again. | as cited |
| F5 | `https://qa.bizdala.com/health` is public and unauthenticated; returned `{"status":"ok","sha":"0f1a7fa1…"}` while `main` = `06bd6b34`. Host is already hard-coded in `redeploy-qa.sh:143`; no secret needed. Body is only status+sha (`lib/letflow/router.ex:111-113`, `lib/letflow/build_info.ex:14-18`); `sha` may be JSON null (`build_info.ex:16`). | `curl`, as cited |
| F6 | In a `workflow_run` run, `github.sha` is main's tip at trigger time, NOT the triggering commit: the CD run started 22:45:51Z by `b65f7378`'s CI reports headSha `90e5f2be`. Use `github.event.workflow_run.head_sha` for the run sha and an explicit API read for the tip. | `gh run list --workflow "CD (QA)"` |
| F7 | Repo is public, default token permission `read`, fork PRs need approval for first-time contributors only. `workflow_run.branches: [main]` (`cd.yml:25-28`) filters on `head_branch`, so a fork PR whose branch is named `main` also fires CD; today's CD then `source`s that run's artifact (`cd.yml:41-51`): fork-controlled shell in a privileged context. | `gh api …/actions/permissions/workflow`, `…/fork-pr-contributor-approval`, `gh api repos/:owner/:repo` |
| F8 | Every main commit passed the required checks on a `gh-readonly-queue` merge_group run of the exact squash tree; no bypass actors. | `docs/merge-queue.md:6-18`; `ci.yml:154-160` |

## 1. CI change: per-sha group for main pushes (`ci.yml:162-171`)

`concurrency.group` becomes `${{ github.workflow }}-${{ github.event.pull_request.number || (github.event_name == 'push' && format('{0}-{1}', github.ref, github.sha)) || github.ref }}`.
`cancel-in-progress` is unchanged (`== 'pull_request'`). Effects: `pull_request` = same group as today (per PR number, cancels);
`push` = one group per commit, so no push run is ever queued behind or cancelled by another; `merge_group` = `github.ref`
(the per-entry `gh-readonly-queue/main/...` ref) exactly as today. The ISS-0840 comment block (:164-170) gets one added line citing GH #2622.

**Cost.** Push-run wall time over the last 11 successful runs: 7.8-13.0 min. Runner minutes per push run (job durations of
run 38665714603): changes 0.2 + static 3.3 + shards 10.0/8.9/~10 + mobile 4.7 + frontend 2.0 + aggregator ~0.2 = ~39.
Today a burst of N merges runs at most 2 push runs (1 running + the last pending); after: N. Extra = (N-2) x ~39 runner-min,
e.g. the 4-commit burst `fe06bdd9..06bd6b34` = ~80 extra. Public repo on standard runners (F7), so the cost is queueing,
not money: each push run holds 6 long jobs, 3 overlapping = 18 of the 20 concurrent jobs (`ci.yml:69-72`), so PR and
merge_group jobs may wait during a burst. Accepted; the same load occurred before ISS-0840 in steady state.

## 2. Single source for path rules: `scripts/ci_changed_paths.sh` (new)

Placed under `scripts/` because `scripts/.*\.sh$` is already in `BACKEND_PATHS_RE` (`ci.yml:270`); `.github/scripts/`
is not, so a change there would skip the backend gate. Contract (no code here, shape only):
- Input: newline-separated repo paths on stdin (may be empty). No arguments, no environment reads.
- Output: exactly three lines on stdout, `backend=true|false`, `frontend=true|false`, `mobile=true|false`; exit 0.
  Any internal error: exit non-zero, nothing guaranteed on stdout (callers fail open to "all true").
- Holds the three regexes as single-quoted assignment lines `BACKEND_PATHS_RE='…'`, `FRONTEND_PATHS_RE='…'`,
  `MOBILE_PATHS_RE='…'`, moved verbatim from `ci.yml:270,281,287`, matched with `grep -qE "$X" <<<"$CHANGED"` (Q-1110
  here-string rule, `ci.yml:271-274`). Frontend and mobile regexes gain `|scripts/ci_changed_paths\.sh$` beside
  `\.github/workflows/ci\.yml`, so editing the shared rules runs every gate.
- `ci.yml` "Compute changed paths" (:193-291) keeps its event/SHA/fail-safe branching, but takes the shas from step
  `env:` instead of `${{ }}` inside `run:` (:210-229), and replaces lines 270-291 with one call appending the script's stdout
  to `$GITHUB_OUTPUT`. The fallback step (:293-300) is unchanged. Steps "Write path-filter outputs for cd.yml" and "Upload
  path-filter outputs" (:302-321) are deleted: nothing consumes the artifact any more (§3), which also removes the F7 vector.
- `test/letflow/ci_backend_path_filter_test.exs` `@ci_yml` (:35) and the here-string assertions (:288-310) are retargeted to
  the script; layers 2-3 unchanged. Add `scripts/ci_changed_paths.sh` to the WF-02 trust-boundary list
  (`WF-02_requirement_implementation.md:276-285`), since a PR runs its own copy of it exactly as of `ci.yml`.

## 3. CD change: the tip rule (`cd.yml`, rewritten)

**Trigger** unchanged (`cd.yml:24-28`). **Job `deploy`:**
- `if:` `workflow_run.conclusion == 'success'` (kept, `cd.yml:39`) AND `workflow_run.event == 'push'` AND
  `workflow_run.head_repository.full_name == github.repository` (closes F7).
- `permissions: { contents: read, actions: read }`. Job-level `concurrency: { group: cd-qa, cancel-in-progress: false }`
  (job level, so a CD run whose job is skipped by `if:` never enters the group and cannot cancel a pending real deploy; see OQ-2).
- `env:` `QA_URL: https://qa.bizdala.com` (constant), `RUN_SHA: ${{ github.event.workflow_run.head_sha }}`, `GH_TOKEN: ${{ github.token }}`.

**Steps:**
1. `actions/checkout@v4`, `ref: main`, `fetch-depth: 0`, `persist-credentials: false` (trusted merged code only).
2. `inputs` (id): `TIP` = `gh api repos/${{ github.repository }}/commits/main --jq .sha`; `git fetch origin main` and
   require `TIP == git rev-parse origin/main` (else re-read once; still unequal: `deploy=true`, reason "tip unstable").
   `TIP_RUN` = conclusion of the CI `push` run for `head_sha=TIP` on `main` (`gh api …/actions/workflows/ci.yml/runs`),
   or `none`. `QA_HEALTH` = body of `curl -sf -m 10 "$QA_URL/health"`, or empty on any failure.
3. `decide` (id): runs `scripts/cd_qa_decide.sh` (new) with env `RUN_SHA TIP TIP_RUN QA_HEALTH`. Contract: reads only
   those env vars and the local git repo; prints `deploy=true|false` and `reason=<one line>` to stdout (appended to
   `$GITHUB_OUTPUT` and `$GITHUB_STEP_SUMMARY`), each reason prefixed `cd-qa:`; exit non-zero on an internal error, which the
   step maps to `deploy=true` (fail toward deploying the tested tip). Decision table, first match wins:

| # | Condition | deploy | reason (logged) |
|---|---|---|---|
| D1 | `RUN_SHA` or `TIP` not 40 lowercase hex | false | `invalid sha input (run X, tip Y)` (step fails red) |
| D2 | `RUN_SHA != TIP` and `TIP_RUN != success` | false | `not tip (run sha X, tip Y); tip run is <TIP_RUN>, its own CD will decide` |
| D3 | `QA_HEALTH` empty / not JSON / `sha` null / not 7-40 lowercase hex | true | `QA sha unknown (<why>), deploying tip Y` |
| D4 | QA sha not resolvable or `git merge-base --is-ancestor QA TIP` fails | true | `QA sha X not an ancestor of tip Y, deploying tip` |
| D5 | QA sha == TIP (prefix match of the reported length) | false | `QA already at tip Y` |
| D6 | `git diff --name-only QA TIP` piped to `scripts/ci_changed_paths.sh`: backend or frontend true (or script non-zero) | true | `deploy-relevant paths since QA sha X (tip Y)` |
| D7 | otherwise | false | `no deploy-relevant paths since QA sha X (tip Y)` |

   Why D2 deviates from a plain "skip unless run sha == tip": CD runs queue in one group, and a third arrival cancels the
   PENDING one (F1 applies to CD too). If the tip's CD is pending and an older run's CD arrives, the tip's CD is cancelled and
   the older one would skip, so QA never gets the tip. With D2 the older run deploys the tip when the tip's own push run is
   already green. Invariant: the last CI push run to complete fires the last CD event, which is never cancelled; when it runs,
   every push run is complete, so it deploys the tip iff the tip's run is green. Duplicate deploys are impossible: the second
   run hits D5.
4. SSH deploy, `if: steps.decide.outputs.deploy == 'true'`: inputs byte-identical to `cd.yml:58-70` (same 3 secrets, same
   `script`). Nothing passed over SSH changes; the forced command still deploys main's tip only.
5. `verify`, `if:` step 4 ran: read `/health` (retry 10 x 6 s); log `cd-qa: deployed <sha>`. If it differs from `TIP` and
   `TIP` is an ancestor of it, log `cd-qa: main moved during deploy (verified Y, deployed Z); Z passed merge_group, its own CD
   will re-check` (warning, green). Unreachable or not a descendant of `TIP`: fail the step red.

**(iv)** A non-success CI run never deploys: the job `if:` is evaluated before any step (kept from `cd.yml:39`).
Evidence it holds today: CD for cancelled `048a4253` and `06bd6b34` show `skipped`.

**(v) Race between step 2 and `git pull` (`redeploy-qa.sh:42`).** Main may move from Y to Z. The script deploys Z, whose own
push run may still be running. Guarantee: Z reached `main` only through the merge queue, which ran the required checks
(`Backend gate (mix letflow.check)`, `Frontend gate (npm run check)`) green on the squash tree, with no bypass (F8). So the
deployed tree is never untested; it may lack its own green PUSH run at deploy time. If Z's push run is later red (flake, or
the merge_group path filter skipped a gate `ci.yml:221-229`, which the push run backstops), QA carries Z until the next green
tip deploys; Z's CD is skipped by the job `if:` and the runbook shows how to see this. This is a narrowing of the AC wording
"never deploys a commit whose CI run is … missing" (OQ-1); it is unavoidable without pinning the sha (F3).

## 4. Runbook: `docs/runbooks/qa-lag.md` (new; matches `BACKEND_PATHS_RE` `docs/runbooks/`)

Sections: (1) symptom: `curl https://qa.bizdala.com/health` sha != `gh api repos/:owner/:repo/commits/main --jq .sha`;
(2) `gh run list --workflow CI --branch main --event push` and `gh run list --workflow "CD (QA)"`: read conclusion per sha;
(3) cancel vs failure: `cancelled` push run (should no longer occur after #2622, except manual), `failure` (real red),
`in_progress` for > 20 min (hung, F2: `gh run view <id>` shows the stuck job; cancel it, rerun); a `cancelled` CD run is a
superseded pending run and is harmless; (4) read the reason: `gh run view <cd id> --log | grep 'cd-qa:'`; (5) the
merge_group run for that PR is green (`gh run list --workflow CI --event merge_group`) means not a code failure; (6) what to
do: rerun the tip's push run (`gh run rerun <id>`), which fires CD; never deploy manually around a red tip.

## 5. Tests (TEST-DESIGNER; ExUnit, the repo's precedent for workflow/script checks: `ci_backend_path_filter_test.exs`,
`test/scripts/prune_web_dist_backups_test.exs`)

- T1 single source (`test/letflow/ci_path_rules_single_source_test.exs`): `ci.yml` and `scripts/cd_qa_decide.sh` each invoke
  `scripts/ci_changed_paths.sh`; no `_PATHS_RE=` assignment and no `grep -[a-zA-Z]*E '^(` literal in `.github/workflows/*.yml`
  or `scripts/cd_qa_decide.sh`; the script holds exactly one assignment line per regex.
- T2 `ci_changed_paths.sh` table: run via `System.cmd("bash", …)` with stdin cases (empty, docs-only, `lib/x.ex`, `web/a.tsx`,
  the script itself, > 64 KiB list for the SIGPIPE case) and assert the three output lines.
- T3 `cd_qa_decide.sh` table D1-D7 in a temp git repo (linear A-B-C plus an unrelated root), asserting `deploy=` and the reason prefix.
- T4 static `cd.yml`: job `if` holds all three clauses; job-level concurrency `cd-qa`, cancel false; permissions exactly
  `contents: read, actions: read`; no `${{ github.event.` inside any `run:` value; SSH step `with:` keys and secret names unchanged;
  no `download-artifact`.
- T5 static `ci.yml`: the concurrency expression of §1 verbatim; `cancel-in-progress` expression unchanged; no `path-filter-outputs`.

## 6. Security notes (SECURITY-REVIEWER mandatory: `ci.yml`/`cd.yml`, WF-02:276-285)

- Secrets: same three secrets, same step, same forced command (`cd.yml:58-70`); no new secret; QA URL is public (F5). The
  restricted key is not widened; no sha or argument is sent over SSH. `GITHUB_TOKEN` scoped read-only (§3).
- Privilege: `pull_request` runs (untrusted code) get no secrets and produce nothing CD consumes now (artifact removed, §2).
  `workflow_run` (privileged) only runs trusted `main` code (`ref: main`) and only for same-repo `push` runs (F7 fix).
- Injection: every event field reaches shells through `env:`, never `${{ }}` in `run:`; only `head_sha` is used and it is
  hex-validated (D1). `head_branch`, `display_title`, `head_commit.message` are never read. QA `/health` body is untrusted
  input: parsed as JSON, sha hex-validated before any git call (D3).
- INV-4 (secrets by reference) holds; INV-1/2/5-7/9/10 not touched (no app code). New trust-boundary file: §2 last bullet.

## 7. Alternatives rejected

- Option (b) alone (keep one CI group, CD deploys the tip whenever any green run lands): a hung run (F2) still starves the
  group for hours and middle commits never get a push run, losing ISS-0840's backstop (`ci.yml:199-209`).
- Pin the deployed sha via `SSH_ORIGINAL_COMMAND` in `redeploy-qa.sh`: network input into the forced-command key; detached
  HEAD on the host breaks manual `git pull` deploys; the key contract is owned by ai-dala-infra (T-0111).
- Cron-triggered CD: adds lag and still needs the same tip/health logic.

## 8. AC -> verification

| AC (#2622) | Element | Verification |
|---|---|---|
| Choose one fix, reason + cost | §1 (option a) + §3 | PR body quotes §1 cost |
| Never deploy red/cancelled/missing | job `if` (§3 iv), D2, race §3 v | T4; existing skipped CD runs for cancelled runs; dry run T3; OQ-1 |
| Burst of 3+ ends with /health = tip | §1 + D2-D7 | Post-merge evidence plan below |
| Runbook | §4 | file exists; reviewer reads |
| No required-check/ruleset change | §1 keeps job names | `gh api repos/:owner/:repo/rulesets` before/after identical, quoted in PR |
| Supervisor (1)-(3) | D3/D4, §2+T1, reason column | T1, T3 |

**Evidence plan (post-merge, ORCH).** This PR touches `.github/workflows/` (matches `BACKEND_PATHS_RE`), so its own merge
deploys via D4/D6 from QA `0f1a7fa1`. Then on the next burst of >= 3 queue merges (or 3 small enqueued PRs whose last
touches a deploy-relevant path such as `docs/status/`), after the last CD completes ORCH records in an issue comment:
`gh run list --workflow CI --branch main --event push -L 6`, `gh run list --workflow "CD (QA)" -L 6`, the `cd-qa:` line of
each CD log, `gh api repos/:owner/:repo/commits/main --jq .sha`, and `curl -s https://qa.bizdala.com/health`. Pass: health sha == tip.

## 9. Open questions

- OQ-1: §3 (v) means a deployed commit may have a pending (rarely later red) push run. Accept as "merge_group-green" or not?
- OQ-2: Job-level concurrency on a job skipped by `if:` is assumed not to enter the group. Verify on the first live burst
  (a skipped CD run must not show the deploy job as cancelled); fallback: keep the gate, accept it, D2 still self-heals on the next event.
- OQ-3: D7 leaves `/health` != tip when the tip only changed non-deploy paths; the AC says "/health reports the main tip". The
  evidence plan picks a deploy-relevant last commit. Alternatively drop D6/D7 and always deploy when QA != tip (as today, F4).
- OQ-4 (out of scope, follow-up issue): no `timeout-minutes` on any CI job (F2); a hung shard holds a runner up to 6 h.
