REQ-367's CD path gate is superseded: CD deploys the tested main tip whenever QA differs

# QA lag: cancel vs failure

GH #2622. How to tell why QA (`https://qa.bizdala.com`) is not serving `main`'s tip, and what
to do. Design: `lib/letflow/design/gh2622-ci-push-concurrency-and-cd-tip.md` (§3 tip rule,
§4 timeouts). Workflows: `.github/workflows/ci.yml`, `.github/workflows/cd.yml`.

## How it works now

- Every push to `main` gets its own CI concurrency group (ref + sha), so a burst of merges never
  cancels a pending push run any more.
- `CD (QA)` fires when a CI run on `main` completes. Its `deploy` job runs only when that run
  succeeded, was a `push` event and came from this repository. It then reads main's CURRENT tip
  and QA's `/health` sha and decides with `scripts/cd_qa_decide.sh`. It deploys the tip whenever
  QA differs and the tip's own push run is green (or is the run that fired CD). There is no path
  gate: a docs-only merge is deployed too, so `scripts/uat_preflight.sh` never sees a `/health`
  GAP just because a merge touched no code.

## 1. Symptom

```bash
curl -s https://qa.bizdala.com/health                       # {"status":"ok","sha":"<Q>"}
gh api repos/:owner/:repo/commits/main --jq .sha            # <TIP>
```

QA lags when `<Q>` is not `<TIP>` (a 7-39 character `<Q>` is a prefix: resolve it with
`git rev-parse <Q>` after `git fetch origin main`).

## 2. Read the runs

```bash
gh run list --workflow CI --branch main --event push -L 10      # conclusion per sha
gh run list --workflow "CD (QA)" -L 10                          # CD runs (skipped/success/failure)
```

## 3. Cancel vs failure

- **CI push run `cancelled`.** After #2622 a push run is no longer cancelled by a newer push. A
  cancelled push run now means a TIMEOUT or a MANUAL cancel. Every CI and CD job has a
  `timeout-minutes`; when it fires, GitHub cancels the job, so its conclusion is `cancelled`, not
  `failure`. The job log says "exceeded the maximum execution time" for a timeout. Either way it
  is non-success: CD does not deploy it, and the `Backend gate (mix letflow.check)` aggregator
  turns a cancelled shard into `failure`.
- **CI push run `failure`.** Real red. Read the failing job's log.
- **CD run `cancelled`.** A queued CD run superseded by a newer one (group `cd-qa`). Harmless:
  every CD run decides from the CURRENT tip and QA sha, so the newer run reaches the same or a
  fresher decision.
- **CD run `skipped` / the `Log why CD did not deploy` job ran.** The CI run was not a successful
  same-repo push run. Its log line reads
  `cd-qa: skipped (conclusion=<c>, event=<e>, same-repo=<true|false>)`.

## 4. Read the decision

```bash
gh run view <cd run id> --log | grep 'cd-qa:'
```

| Reason (`cd-qa: ...`) | Result | Meaning |
|---|---|---|
| `invalid run sha` | red | The triggering run's head sha is not 40 hex. Should never happen; report it. |
| `tip unreadable` / `tip unstable (api Y, git Z)` | red | GitHub API or `git fetch` trouble, or main moved twice during the read. Rerun the CD run. |
| `tip run unreadable (tip Y)` | red | The tip's CI run could not be listed. Rerun the CD run. |
| `not tip (run sha X, tip Y); tip run <status>` | skip | An older run fired CD while the tip's own push run is not green yet (or is red). The tip's run fires its own CD when it completes. |
| `QA sha unknown (unreachable / not-json / null / not-hex), deploying tip Y` | deploy | `/health` gave no usable sha; the tip is deployed anyway. |
| `QA sha Q unresolvable, deploying tip Y` | deploy | QA's sha is unknown to the repository (or an ambiguous short sha). |
| `QA already at tip Y` | skip | Nothing to do. |
| `QA sha Q not an ancestor of tip Y, deploying tip` | deploy | QA carries a commit not on main (manual deploy, rewritten history). |
| `QA sha Q behind tip Y, deploying tip` | deploy | The normal case. |
| `decide error` | red | `scripts/cd_qa_decide.sh` failed or printed malformed output. Read the step log; nothing was deployed. |
| `deployed Q` / `main moved during deploy (verified Y, deployed Q)` | green | Verify step: QA serves the verified tip, or a descendant of it. |
| `verify failed, ...` | red | QA did not come back with the tip or a descendant of it. |

## 5. Was it a code failure?

```bash
gh run list --workflow CI --event merge_group -L 20
```

A green `merge_group` run for the PR that produced the commit means the code passed the
required checks on its exact tree; a red or cancelled push run after it is then a flake, a
timeout or a manual cancel, not a code failure.

## 6. The git-pull race (ruling OQ-1, issue #2622 R6)

CD checks the tip, then the remote forced command runs `git pull` (`deploy/redeploy-qa.sh`).
If main moved in between, QA receives the newer commit Z, whose own push run may still be
running. Accepted: "CD never deploys a red, cancelled or missing run" is read, for this race
only, as "every deployed commit passed the merge queue's required checks", and Z reached `main`
only through the merge queue (`docs/merge-queue.md`). The verify step logs
`cd-qa: main moved during deploy (verified Y, deployed Z)`. If Z's push run later turns red,
QA carries Z until the next green tip; Z's own CD is skipped. The forced command is not widened
to pin a sha.

## 7. What to do

- Rerun the tip's push run: `gh run rerun <id>` (or `--failed`). Its completion fires CD.
- A red CD decision (`tip unreadable`, `tip run unreadable`, `decide error`): rerun the CD run
  (`gh run rerun <cd run id>`).
- Never deploy manually around a red tip.
