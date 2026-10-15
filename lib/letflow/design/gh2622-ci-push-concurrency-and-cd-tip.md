# GH #2622: per-sha CI concurrency for main pushes + CD "tip rule" + job timeouts

Author: CODE-DESIGNER. Branch `fix/GH-2622-ci-push-concurrency` (off `06bd6b34`). Rev 2: after validator FAIL (B1-B6) and supervisor rulings (OQ-1, OQ-3 = (b), OQ-4 folded in).
No required check, job name, or ruleset changes (`docs/merge-queue.md:6-10`; aggregator name `ci.yml:46-50`).

**REQ-367's CD path gate is superseded: CD deploys the tested main tip whenever QA differs.** This replaces
`lib/letflow/design/req367-cd-qa-deploy.md` §2 "How the gate reuses `ci.yml`'s `changes` job" (:221) and §3 (:313).

## 0. Verified facts (2026-10-15)

| # | Fact | Source |
|---|---|---|
| F1 | One concurrency group for all pushes to `refs/heads/main`; cancel-in-progress only on `pull_request`. A third arrival cancels the PENDING run regardless. | `ci.yml:162-171`; issue #2622 |
| F2 | Today's trigger: run 38665714603 (`9974a3a4`, push) has `Backend shard 2/3` `in_progress` since 01:35:48Z (other jobs done by 01:45:48Z). It holds the slot; `fe06bdd9`, `048a4253` were cancelled while pending; `a1033b8e` has no push run. No job sets `timeout-minutes` (grep: 0 hits), so the 360-min default applies. | `gh run view 38665714603 --json jobs`; `gh run list --workflow CI --branch main` |
| F3 | The deploy cannot be pinned to a sha: the key is a forced command (`cd.yml:65-70`), the script deploys whatever `git pull` yields (`deploy/redeploy-qa.sh:41-43`). Pinning would mean parsing `SSH_ORIGINAL_COMMAND` (OpenSSH exports it for `command=` keys) or an infra change; both widen the restricted key and are rejected (§8). | as cited |
| F4 | The current CD gate is effectively always true on push: the `changes` job writes `backend=true`/`frontend=true` for every `push` (`ci.yml:210-215`), so `should_deploy` (`cd.yml:48-56`) is true for every push run. Dropping it changes no behaviour except cancellation handling. | as cited |
| F5 | `https://qa.bizdala.com/health` is public; returned `{"status":"ok","sha":"0f1a7fa1…"}` while `main` = `06bd6b34`. Host already hard-coded at `redeploy-qa.sh:143`; no secret needed. Body is status+sha only (`lib/letflow/router.ex:111-113`); `sha` is 7-40 lowercase hex or JSON null (`lib/letflow/build_info.ex:14-21`). | `curl`, as cited |
| F6 | In a `workflow_run` run, `github.sha` is main's tip at trigger time, not the triggering commit (CD run 22:45:51Z fired by `b65f7378`'s CI reports headSha `90e5f2be`). Run sha = `github.event.workflow_run.head_sha`; tip = explicit API read. | `gh run list --workflow "CD (QA)"` |
| F7 | Public repo, default token `read`, fork-PR approval `first_time_contributors`. `branches: [main]` (`cd.yml:25-28`) matches `head_branch`, so a fork PR from a branch named `main` fires CD, which then `source`s that fork run's artifact (`cd.yml:41-51`): fork-controlled shell in a privileged context. **Confirmed real and pre-existing; fixed inside #2622** (§3 job `if`, artifact removed §2). | `gh api` repo, workflow permissions, fork approval |
| F8 | Every main commit passed the required checks on a merge_group run of its exact squash tree; no bypass actors. | `docs/merge-queue.md:6-18`; `ci.yml:154-160` |
| F9 | `scripts/uat_preflight.sh` treats a `/health` sha != `origin/main` as GAP and exits 1 (`:51-52`, `:103`, `:435-438`, `:758`); a path-gated QA would block UAT after every docs-only merge. Reason for option (b). | as cited |

## 1. CI: per-sha group for main pushes (`ci.yml:162-171`)

`group: ${{ github.workflow }}-${{ github.event.pull_request.number || (github.event_name == 'push' && format('{0}-{1}', github.ref, github.sha)) || github.ref }}`;
`cancel-in-progress` unchanged. `pull_request`: same group and cancelling as today; `push`: one group per commit, never
queued behind or cancelled by another push; `merge_group`: `github.ref` as today. The ISS-0840 comment (:164-170) gains a
GH #2622 line; the comment at `ci.yml:157-159` is updated to say CD fires only for same-repo `push` runs on `main` (§3).

**Cost.** Push-run wall time over the last 11 successful push runs: 7.8-13.0 min. Runner minutes per push run (run
38665714603): changes 0.2 + static 3.3 + shards 10.0/8.9/~10 + mobile 4.7 + frontend 2.0 + aggregator ~0.2 = ~39. A burst
of N merges ran at most 2 push runs (1 running + the last pending); now N. Extra = (N-2) x ~39 runner-min, e.g. ~80 for the
4-commit burst `fe06bdd9..06bd6b34`. Public repo, standard runners: the cost is queueing, not money; 3 overlapping push runs
hold 18 of the 20 concurrent jobs (`ci.yml:69-72`), so PR/merge_group jobs may wait during a burst. Accepted.

## 2. CI: path rules in `scripts/ci_changed_paths.sh` (new; CI is its only consumer)

Under `scripts/` because `scripts/.*\.sh$` is in `BACKEND_PATHS_RE` (`ci.yml:270`); `.github/scripts/` is not. Contract:
- Reads ALL of stdin into a variable first (no early-exiting reader on a pipe, so no SIGPIPE under `pipefail`), then matches
  with `grep -qE "$X" <<<"$CHANGED"` (Q-1110, `ci.yml:271-274`). No arguments, no environment reads.
- Holds `BACKEND_PATHS_RE='…'`, `FRONTEND_PATHS_RE='…'`, `MOBILE_PATHS_RE='…'`, each one single-quoted line, moved verbatim
  from `ci.yml:270,281,287`; frontend and mobile gain `|scripts/ci_changed_paths\.sh$`, so editing the rules runs every gate.
- Output: exactly three lines `backend=true|false`, `frontend=true|false`, `mobile=true|false`; exit 0. Error: non-zero.
- Caller contract in "Compute changed paths" (`ci.yml:193-291`): capture stdout into a variable; require exit 0 AND exactly three
  lines, each matching `^(backend|frontend|mobile)=(true|false)$`, each key once; only then append to `$GITHUB_OUTPUT`;
  otherwise `exit 1`, so the step's `continue-on-error` (:195) hands over to the fail-safe step (:293-300, unchanged: all true).
  Event SHAs move from `${{ }}` inside `run:` (:210-229) to step `env:`. Steps "Write path-filter outputs for cd.yml" and
  "Upload path-filter outputs" (:302-321) are deleted: CD no longer reads them (removes the F7 artifact vector).
- Supervisor condition (2) holds trivially: CD has no path rules. The script joins the WF-02 trust-boundary list
  (`WF-02_requirement_implementation.md:276-285`): a PR runs its own copy, as for `ci.yml`.

## 3. CD: the tip rule (`cd.yml`, rewritten)

Trigger unchanged (`cd.yml:24-28`). No workflow-level concurrency. Two jobs:

**Job `deploy`** (name "Deploy to QA" kept). `if:` = `github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push' && github.event.workflow_run.head_repository.full_name == github.repository`.
`permissions: { contents: read, actions: read }`. Job-level `concurrency: { group: cd-qa, cancel-in-progress: false }`: a running
deploy is never cut off; a queued one superseded by a newer arrival is harmless because every run decides from the CURRENT tip
and QA sha, so the newest run reaches the same or a fresher decision (idempotent; a duplicate hits "QA already at tip").
`timeout-minutes: 20`. `env:` `QA_URL: https://qa.bizdala.com`, `RUN_SHA: ${{ github.event.workflow_run.head_sha }}`,
`GH_TOKEN: ${{ github.token }}`. In `run:` the repo is `$GITHUB_REPOSITORY`, never `${{ }}`.
1. `actions/checkout@v4`, `ref: main`, `fetch-depth: 0`, `persist-credentials: false` (trusted merged code only).
2. `inputs`: `TIP` = `gh api "repos/$GITHUB_REPOSITORY/commits/main" --jq .sha` (empty on error). `git fetch origin main`
   (always, before any ancestry check); `TIP_GIT` = `git rev-parse origin/main`. If `TIP != TIP_GIT`, re-read both once.
   `TIP_RUN` = the CI `push` run on `main` for `head_sha=$TIP` with the latest `created_at` (`gh api
   "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs?head_sha=…&event=push&branch=main"`): its `conclusion` if completed,
   else its `status`; `none` if no run; `error` if the call failed. Skipped (not needed) when `RUN_SHA == TIP`.
   `QA_HEALTH` = body of `curl -sf -m 10 "$QA_URL/health"`, empty on any failure. All passed to step 3 via `env:` only.
3. `decide`: runs `scripts/cd_qa_decide.sh` (new) with env `RUN_SHA TIP TIP_GIT TIP_RUN QA_HEALTH`. It reads only those and the
   local repo; prints exactly `deploy=true|false` and `reason=cd-qa: <text>`. The step applies the §2 caller contract (exit 0,
   exactly those two well-formed lines), then appends to `$GITHUB_OUTPUT` and echoes the reason to the log and
   `$GITHUB_STEP_SUMMARY`. Script error or malformed output: step red, `cd-qa: decide error`; deploy never runs. First match
   wins; rows 1-4 are the tip/run checks; only the HEALTH signal fails toward deploying (supervisor condition 1):

| # | Condition | Result | `reason` (fixed text; `X`,`Y` = validated 40-hex, `Q` = validated 7-40 hex) |
|---|---|---|---|
| 1 | `RUN_SHA` not 40 lowercase hex | red | `invalid run sha` |
| 2 | `TIP` empty / not 40-hex, or `TIP != TIP_GIT` after the retry | red | `tip unreadable` / `tip unstable (api Y, git Z)` |
| 3 | `RUN_SHA != TIP` and `TIP_RUN == error` | red | `tip run unreadable (tip Y)` |
| 4 | `RUN_SHA != TIP` and `TIP_RUN != success` | skip | `not tip (run sha X, tip Y); tip run <conclusion-or-status>` |
| 5 | `QA_HEALTH` empty / not JSON / `sha` null / not 7-40 lowercase hex | deploy | `QA sha unknown (unreachable|not-json|null|not-hex), deploying tip Y` |
| 6 | `git rev-parse --verify --quiet "Q^{commit}"` fails or is ambiguous (short sha) | deploy | `QA sha Q unresolvable, deploying tip Y` |
| 7 | resolved QA sha == `TIP` | skip | `QA already at tip Y` |
| 8 | `git merge-base --is-ancestor QA TIP` fails | deploy | `QA sha Q not an ancestor of tip Y, deploying tip` |
| 9 | otherwise (QA behind tip) | deploy | `QA sha Q behind tip Y, deploying tip` |

   Short shas: `/health` may report 7-39 hex (`build_info.ex:21`); it is only resolved against the fetched repo (row 6), never
   compared by string prefix. `<conclusion-or-status>` is one of GitHub's enum words, checked against a fixed list (else `other`).
   Raw `/health` text never reaches `$GITHUB_OUTPUT` or the log. Rows 1-4 are checked BEFORE 5-9 on purpose: a reachable or
   unreachable QA must never turn a non-green or unknown tip into a deploy. Row 4 deviates from "skip unless run sha == tip":
   queued CD runs cancel each other like F1, so if the tip's CD is pending and an older run's CD arrives, the tip's CD is
   cancelled; with row 4 the older run deploys the tip whenever the tip's own push run is green. Invariant: the last CI push run
   to complete fires the last CD event, which is never cancelled; at that point every push run is complete, so it deploys the
   tip iff the tip's run is green and QA differs.
4. SSH deploy: `if: steps.decide.outputs.deploy == 'true'` (string equality; a missing output never deploys, and a failed
   decide step stops the job). Inputs byte-identical to `cd.yml:58-70`: same 3 secrets, same `script`. No sha or argument
   is sent over SSH; the forced command still deploys main's tip only; the key's restricted command is not widened.
5. `verify`, `if:` step 4 ran: read `/health` (10 x 6 s); run `git fetch origin main`, resolve Q with `git rev-parse --verify
   --quiet "Q^{commit}"`, then `git merge-base --is-ancestor TIP Q`; log `cd-qa: deployed Q`. Q descendant of `TIP` but != `TIP`: log
   `cd-qa: main moved during deploy (verified Y, deployed Q)`, green (§3 race). Unreachable or not a descendant: red.

**Job `skip-log`.** `if: ${{ !(<the deploy job's if, verbatim>) }}` (the `${{ }}` wrapper is REQUIRED: a bare `if:` value starting
with `!` is a YAML tag, and cd.yml is never run by PR CI, so a broken file would silently stop CD; T4 asserts the wrapper), so it runs exactly when `deploy` is skipped by its job `if`.
No secrets, `permissions: {}`, no concurrency group, no checkout, `timeout-minutes: 5`. `env:` `CONCLUSION`, `EVENT`, `HEAD_REPO`
(from `github.event.workflow_run.*`) and the run uses `$GITHUB_REPOSITORY`; it computes `same-repo=true|false` in shell and prints
`cd-qa: skipped (conclusion=$CONCLUSION, event=$EVENT, same-repo=…)` with `printf '%s'`. It never prints `HEAD_REPO`.

**(iv)** A non-success CI run never deploys: the job `if` precedes every step (CD for cancelled `048a4253`/`06bd6b34`: `skipped`).

**(v) Race between step 2 and `git pull` (`redeploy-qa.sh:42`).** Main may move from Y to Z, so Z is deployed while its own
push run may still be running. **Accepted ruling (OQ-1): for this git-pull race only, "passed the merge queue" is the reading of
"never deploys red/cancelled/missing".** Z reached `main` only via the merge queue, which ran `Backend gate (mix
letflow.check)` and `Frontend gate (npm run check)` green on Z's exact tree with no bypass (F8), so the deployed tree is never
untested. If Z's push run is later red (flake, or a gate the merge_group path filter skipped, `ci.yml:221-229`), QA carries Z
until the next green tip; Z's CD is skipped by the job `if`. The forced command is not widened to close this. Stated in the PR and runbook.

## 4. Timeouts on every CI and CD job (separate commit, OQ-4 folded in)

Measured: last 30 successful CI runs (all events) via `gh run view --json jobs`, whole minutes (floor), skipped jobs show 0;
last 30 successful CD runs. Values give >= 4x headroom over the observed max and cover cold caches.

| Job | Observed (min, max) | p95 approx | timeout-minutes |
|---|---|---|---|
| `backend_shard` (90 legs) | 5, 11 | 10-11 | 45 |
| `backend_static` | 2, 3 | 3 | 30 (cold `_build/dev` permission-matrix compile, `ci.yml:61-66`) |
| `backend` aggregator | 0, 0 | 0 | 15 |
| `frontend` | 0, 2 | 2 | 30 (cold `npm ci`) |
| `mobile` | 0, 6 | 5-6 | 45 (cold Flutter build) |
| `changes` | 0, 0 | 0 | 10 |
| CD `deploy` | 94 s, 183 s | ~173 s | 20 (remote docker build + node:22 `npm ci`) |
| CD `skip-log` | n/a (new) | n/a | 5 |

A timeout ends the job non-success; it never becomes a skip: static/shards feed the aggregator's fail-closed rule (any result
other than `success`/expected `skipped` is red, `ci.yml:55-60`); `frontend`, `mobile` and the aggregator are their own contexts;
a non-success run fails CD's job `if`. OQ-A answered (validator round 2): a timed-out job's conclusion is `cancelled` (GitHub cancels it); non-success either way.
`appleboy/ssh-action`'s own `command_timeout` (default 10m, to be confirmed against the action's docs) fires before the 20-min
job timeout; deploys take at most 183 s today.

## 5. Runbook: `docs/runbooks/qa-lag.md` (new)

Starts with the verbatim line "REQ-367's CD path gate is superseded: CD deploys the tested main tip whenever QA differs".
Sections: (1) symptom: `curl https://qa.bizdala.com/health` sha != `gh api repos/:owner/:repo/commits/main --jq .sha`;
(2) `gh run list --workflow CI --branch main --event push` and `--workflow "CD (QA)"`: conclusion per sha; (3) cancel vs
failure: after #2622 a cancelled push run means a TIMEOUT or a MANUAL cancel (`timeout-minutes` cancels the job, so its conclusion
is `cancelled`; the job log says "exceeded the maximum execution time" for a timeout); either way it is non-success, CD does not
deploy it and the aggregator turns a cancelled shard into `failure`; `failure` is real red; a
cancelled CD run is a superseded queued run, harmless; (4) read the reason: `gh run view <cd id> --log | grep 'cd-qa:'`, with the
table rows of §3, including "TIP unreadable → red" (rows 2-3: GitHub API or fetch trouble; rerun the CD run); (5) green merge_group
run for that PR (`gh run list --workflow CI --event merge_group`) means not a code failure; (6) the race ruling of §3 (v);
(7) action: rerun the tip's push run (`gh run rerun <id>`), which fires CD; never deploy manually around a red tip.

## 6. Tests (TEST-DESIGNER; ExUnit, precedent `test/letflow/ci_backend_path_filter_test.exs`, `test/scripts/prune_web_dist_backups_test.exs`)

- T0 retarget `ci_backend_path_filter_test.exs`: `@ci_yml` (:35) regex extraction now reads `scripts/ci_changed_paths.sh`; the
  here-string and pipe-into-`grep -q` guards (:288-310) scan all four files, with per-file expectations (exactly 3 here-strings in
  `scripts/ci_changed_paths.sh`, 0 in the other three) (`ci.yml`, `cd.yml`, `scripts/ci_changed_paths.sh`,
  `scripts/cd_qa_decide.sh`); `@decision_table` adds `{"scripts/ci_changed_paths.sh", true, true}` and
  `{"scripts/cd_qa_decide.sh", true, false}`.
- T1 single source: `ci.yml` is the only file that invokes `scripts/ci_changed_paths.sh`; no `_PATHS_RE=` assignment and no
  `grep -…E '^(` literal in `.github/workflows/*.yml` or `scripts/cd_qa_decide.sh`; the script has one assignment line per regex.
- T2 `ci_changed_paths.sh` via `System.cmd("bash", …)`: empty, docs-only, `lib/x.ex`, `web/a.tsx`, itself, > 64 KiB list: exit 0, 3 lines.
- T3 `cd_qa_decide.sh` rows 1-9 in a temp git repo (linear A-B-C plus an unrelated root; a 7-hex short sha; an ambiguous one),
  asserting exit, `deploy=`, the reason prefix, and that a junk `QA_HEALTH` string never appears in stdout.
- T4 static `cd.yml`: deploy `if` has the three clauses; `skip-log` `if` is exactly `${{ !(` + deploy `if` + `) }}`; the verify step fetches before its ancestry check; `cd-qa` group, cancel
  false, on the job; permissions as §3; no `${{ github.` inside any `run:`; SSH step `with:` keys/secret names unchanged; no
  `download-artifact`; every job has `timeout-minutes`.
- T5 static `ci.yml`: §1 group expression verbatim; cancel expression unchanged; no `path-filter-outputs`; every job's
  `timeout-minutes` equals §4.

## 7. Security notes (SECURITY-REVIEWER mandatory: `ci.yml`/`cd.yml`, WF-02:276-285)

- Secrets: same three, same step, same forced command (`cd.yml:58-70`); no new secret; QA URL is public (F5); no sha over SSH;
  the CD key's restricted command is not widened. `GITHUB_TOKEN` read-only; `skip-log` has no permissions.
- Privilege: `pull_request` (untrusted) gets no secrets and produces nothing CD consumes (artifact removed). `workflow_run`
  (privileged) runs only `main` code and only for same-repo `push` runs: this fixes the pre-existing fork-branch-`main` hole (F7).
- Injection: event fields reach shells only via `env:`; `head_sha` is hex-validated; `head_branch`, `display_title`,
  `head_commit.message` are never read; `head_repository.full_name` is compared, never printed. `/health` is untrusted: parsed
  with `jq`, hex-validated before any git call, never echoed. Reasons use a fixed vocabulary.
- INV-4 holds; INV-1/2/5-7/9/10 not touched (no app code). New trust-boundary file: §2.

## 8. Alternatives rejected

- One CI group, deploy the tip on any green run: a hung run (F2) starves the group; middle commits lose ISS-0840's backstop (`ci.yml:199-209`).
- Pin the sha via `SSH_ORIGINAL_COMMAND`: network input into the forced-command key; breaks manual `git pull` deploys (T-0111).
- Path-gated CD (REQ-367 shape): `/health` != tip after docs-only merges = UAT GAP (F9). Cron CD: more lag, same logic.

## 9. AC -> verification

| AC (#2622) | Element | Verification |
|---|---|---|
| One fix, reason + cost | §1 + §3 | PR body quotes §1 cost |
| Never deploy red/cancelled/missing | deploy `if`, rows 1-4, §3 (v) ruling | T3, T4; skipped CD runs for cancelled 048a4253/06bd6b34 |
| Burst of 3+ ends with /health = tip | §1 + §3 | evidence plan below, in the PR body |
| Runbook | §5 | file exists with the verbatim line |
| No required-check/ruleset change | §1, §4 keep names | `gh api repos/:owner/:repo/rulesets/<id>` before/after identical, in PR |
| Supervisor (1)-(4) | rows 5-9; §2; reason column + `skip-log`; §1 | T1-T4 |
| Timeouts (OQ-4) | §4 | T4, T5 |

**Evidence plan (post-merge, ORCH).** This PR's merge itself deploys (row 9, from QA `0f1a7fa1`). After the next burst of >= 3
queue merges (or 3 small enqueued PRs), once the last CD completes, ORCH captures `gh run list --workflow CI --branch main --event
push -L 6`, `gh run list --workflow "CD (QA)" -L 6`, each CD's `cd-qa:` line, `gh api repos/:owner/:repo/commits/main --jq .sha`
and `curl -s https://qa.bizdala.com/health`, and quotes them in the PR body (edit) and an issue comment. Pass: health sha == tip.

## 10. Open questions

OQ-A: ANSWERED, a timed-out job is `cancelled` (§4, runbook §5(3)). OQ-B: a job skipped by `if:` is
assumed not to enter its job-level group; if it does, row 4 self-heals on the next CD event. OQ-B is the only one left to check live, on the first burst.
