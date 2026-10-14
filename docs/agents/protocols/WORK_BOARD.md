# WORK_BOARD Protocol — GitHub issues are the work queue

Status: the work board is the source since 2026-10-14; the gate-check switch
`docs/status/work_board_cutover.yaml` says `cutover: false` again (the flip was reverted
after it broke main, re-flip pending). The queue service was stopped by infra after the supervisor's
announcement; its database is kept for one week as the rollback window. The worker rules
below are binding: a worker is told which item to work by the supervisor, and the board is
the only way. Still no worker calls the queue (none did before the flip either). Decision record:
`docs/migration/decisions/0049-work-board-replaces-letflow-queue.md` (supersedes 0017).
Tracking issue: GH #2430 (ISS-1073). Repository: `tvolodi-org/letflow` (since 2026-10-14).

This file is short on purpose. Follow it literally.

## 1. The model in six lines

1. A **work item is a GitHub issue**. Its number is the **only machine id**.
2. `REQ-NNN` stays as a **title prefix** (`REQ-459: ...`). Local `docs/issues/ISS-*.yaml`
   files and `queue_ref` / `impl_order` fields stay as **history**; do not rewrite them.
3. **Labels carry state** (section 3). **The supervisor coordinates**; no atomic lock exists.
4. **Workers never pick and never label a claim.** A worker works only the issue the
   supervisor (or the user) named, or that carries `claimed:<its checkout>`.
5. Closing is done **only by a merged PR with `Closes #N`** (section 8).
6. One filer creates items (section 7). Everyone else reports findings to the filer.

## 2. Who does what

| Role | May do | May NOT do |
|---|---|---|
| Supervisor (or the user) | set/remove `claimed:*`, `next:*`, `state:*`, `prio:*` at any time (the only one to change them after creation); post the `CLAIM` comment; triage blocked items; close an issue without a PR (section 8) | — |
| Worker (ORCH or any role in a checkout) | read issues; comment (`HEARTBEAT`, `BLOCKED`, `DONE`); open PRs | set or remove any label (`claimed:*`, `next:*`, `state:*`, `prio:*`); pick an unclaimed issue; close an issue by hand |
| Sole filer (the checkout the supervisor designates) | `gh issue create` from the template after the overlap check, setting `state:ready` or `state:blocked`, `prio:`, `type:`, `stage:` **at creation only** | claim anything; change any label afterwards |

All sessions share one GitHub login, so **who set a label cannot be read from GitHub**.
The claim label is a **convention, not a control**; `scripts/gh_work.sh check` reports
claims that have no matching `CLAIM` comment (section 5). That comment is itself
self-attested: any session on the shared login can post one, so `check` catches accidents
and label/comment mismatches, not forgery.

## 3. Labels (definitions: `.github/labels.yml`)

| Family | Values | Meaning |
|---|---|---|
| `state:` | `ready`, `in-progress`, `blocked` | exactly one on every open item; a closed issue is done. `state:in-progress` is always paired with `claimed:<checkout>` (and `claimed:*` always with `state:in-progress`); `check` reports either half alone |
| `prio:` | `1`, `2`, `3` | lower first; within one prio the **lower issue number goes first** |
| `lane:<name>` | free | optional grouping |
| `claimed:<checkout>` | `letflow`, `letflow-2`, `letflow-3`, `letflow-4`, `remote` | this checkout holds the item; supervisor/user only |
| `next:<checkout>` | same five | supervisor's pick for that checkout; not yet a claim |
| `type:` | `requirement`, `issue` | |
| `stage:S<n>` | `S0`..`S11` | when the item has a stage |

Values are per **checkout**, not per session name. `blocked-on` is **not** a label: it is a
line in the issue body (`blocked-on: #N` or one sentence) next to `state:blocked`.

## 4. Mapping from the queue's fields

| Queue / yaml field | On the board |
|---|---|
| `depends_on: [..]` | body line `Depends on: #A, #B` (issue numbers only) |
| `impl_order` | a `prio:` label; within one prio, lower issue number first |
| `acceptance_criteria` | a `- [ ]` checklist in the issue body |
| `task_type` | `type:requirement` / `type:issue` |
| `stage` | `stage:S<n>` label |
| `issue_ref: ISS-N` | gone. New records are named by GH number (section 9) |
| `queue_ref: Q-N`, `impl_order: N` in yaml | kept as history; new entries carry `gh: <number>` |

## 5. Claim record, heartbeat, stale

* **Claim record.** When the supervisor sets `claimed:<checkout>` it also sets
  `state:in-progress` (removing `state:ready`) and posts one comment
  whose first line is exactly: `CLAIM <checkout> by supervisor <UTC>` (or `by user`).
  A claim label without that comment for the same checkout is a violation.
* **Heartbeat.** The worker posts a comment on its issue at: start, PR open, blocked, done,
  and one line about every **2 hours** during a long local chain. Format:
  `HEARTBEAT <checkout> <UTC> <start|pr|blocked|done|working>: <one line>`.
* **Stale** = a claim with no open PR and no activity for **4 hours**. Only the supervisor
  releases a stale claim (removes the label, may re-label `state:ready`).

## 6. Worker procedure

1. Know your checkout name: the directory name of the repo checkout (`letflow`,
   `letflow-2`, ...; the autonomous remote host is `remote`).
2. Never call the queue service (before or after cutover). Find work: `scripts/gh_work.sh claims` and take an issue whose `claimed` column is your
   checkout. **If there is none, report `no_claimed_task` and stop.** Do not run
   `gh_work.sh ready` to pick for yourself; `ready` is the supervisor's view. If the user
   names an issue directly, that is the claim; say so in your start comment.
3. Read the whole issue with its comments: `gh issue view N --comments`. Every
   `Depends on: #X` must be closed **as completed** (an issue closed as `not planned`, a pull
   request number or a number that does not exist does not count); if not, comment `HEARTBEAT ... blocked:` and stop.
4. Comment `HEARTBEAT <checkout> <UTC> start: <plan in one line>`.
5. Do the work through the normal workflow (WF-01/02/03). When a PR opens, comment its
   number. The PR body says `Closes #N` or `Refs #N` (section 8).
6. On the merge, comment `HEARTBEAT <checkout> <UTC> done: <PR url>, <evidence>`.
   Do not remove labels; the supervisor does.
7. A blocker you cannot clear: comment `HEARTBEAT ... blocked: blocked-on: #X (reason)` and
   stop. The supervisor flips `state:blocked`.

**Drain mode** (ORCHESTRATOR.md section 4a) means: after a PASS, run step 2 again and take
the next issue **already claimed for your checkout**. It never means choosing one yourself.

**GitHub unreachable** (`gh api rate_limit` fails): report `no_claimed_task (github
unreachable)` and stop. No fallback selection from `docs/requirements.yaml`.

## 7. Filing

Only the sole filer files. Before filing, the overlap check: `gh issue list -R <repo>
--state open --search "<keywords>"`, `gh pr list --state open`, and `git grep` on `main`.
Then:

```
# body: .github/ISSUE_TEMPLATE/work_item.md without its front matter, filled in
gh issue create --title "REQ-NNN: <title>" --body-file <filled-body.md> \
  --label state:ready --label prio:2 --label type:requirement --label stage:S4
```

`--body-file` is the non-interactive form; `--template` is interactive-only and must not
be used from an agent shell.

Fill every template section; acceptance criteria are a checklist; dependencies are the
`Depends on:` line. The filer never sets `claimed:*`. A worker that finds a defect
mid-run comments `FINDING: <one paragraph + evidence>` on its own issue and tells the
filer; it is never left unfiled and never fixed inline unless the issue says so.

## 7a. Landing a change (merge queue)

The repository is `tvolodi-org/letflow` (moved 2026-10-14; the old `tvolodi/letflow` name
redirects). The ruleset `main-queue` is the only protection on `main`: a PR lands **only through
the merge queue** (squash, no bypass actors, a direct push to `main` is refused; required
checks `Backend gate (mix letflow.check)` and `Frontend gate (npm run check)`). See
`docs/merge-queue.md`. A worker reports the PR head sha when CI is green and waits for the
supervisor's go before enqueueing; there is no `--admin` and no ruleset change by a worker.

## 8. Closing

* **Only a merged PR whose body contains `Closes #N` closes an issue**, and only when the PR
  fully resolves it. Nothing is closed as a side effect of anything else.
* **While the queue-to-GitHub sync is down (from 2026-10-14, accepted by the user):** a queue
  row going `done` no longer closes its issue, and a new queue row no longer creates one. The
  sole filer therefore files with `gh issue create` directly, and **closes by hand**: after the
  merge, read every acceptance-criterion comment on the issue, and close it only if each one
  is satisfied (S10); otherwise comment what is missing and leave it open.
* **Exception, supervisor only:** the supervisor (or the user) may close an issue without a
  PR as `not planned`, `duplicate` or `no_defect`, with a one-line reason comment. A worker
  never does.
* A partial PR says `Refs #N`; the remainder is filed as a **new issue** linked from #N
  (`Depends on:` or a comment).
* A requirement's `status: done` in `docs/requirements.yaml` is flipped by DOC-UPDATER
  after RELEASE-VALIDATOR, exactly as before; the issue closes with the PR.

## 9. Requirements and issue records in the repo

* Requirement entry: add a field-level line `gh: <issue number>` (4-space indent).
  `# impl_order: UNREGISTERED -- <rationale>` stays the form for a documented deferral.
* Issue record (only when a local record is useful): `docs/issues/GH-<n>.yaml` with
  `id: GH-<n>` and `github_ref: GH-<n>`. Existing `ISS-NNNN.yaml` stay as they are.
* Gate checks: `check_requirements_registration`, `check_deferral_staleness`,
  `check_issue_refs` accept either legacy ids or `gh:` / `GH-<n>` until cutover.

## 10. Tools

```
scripts/gh_work.sh ready [--for <checkout>]   # supervisor view: ready, unclaimed, deps completed;
                                               # held-back items listed under blocked-on
scripts/gh_work.sh claims                      # who holds what, idle hours, linked PR
scripts/gh_work.sh stale [--hours N]           # claims idle >= N h (default 4) with no PR
scripts/gh_work.sh graph                       # Depends-on edges, cycles
scripts/gh_work.sh check                       # label violations; exit 1 on any
```

All five are read-only and paginated. `check` = label rules plus the `CLAIM` comment test;
`stale` = idle claims. They answer different questions.

## 11. Cutover

**2026-10-14.** The flip PR set `cutover: true` and `last_legacy_iss` 1120 and
deleted `letflow.check_queue_reconciliation` and its test. The queue service was STOPPED
(not deleted) by infra on 2026-10-14 at about 06:10Z and now answers 502; GitHub issues are the
source. THE SWITCH VALUE IS `cutover: false` AGAIN: the flip broke main (five hermetic registration tests read the real file) and was reverted; the re-flip follows once the readers are hermetic. Only infra restarts it, and only if a rollback is ever needed; deletion is a separate
approval after the one-week window. No worker calls the queue. The text below is the plan as it was written, kept for the record.

Cutover was **not a calendar date and is not tied to the repository transfer**. It was the
day the PR that flips `cutover: true` in `docs/status/work_board_cutover.yaml` merges,
after one CI-shaped dry run passed (a requirement record and an issue record that carry
only a GH number go through `mix letflow.check.static`). Order: the board PR merges; the
supervisor announces cutover; infra stops the queue service and exports it, keeps a
one-week rollback window, deletes it later. Nothing in this repo stops or deletes the
service. At cutover the cutover PR also deletes `letflow.check_queue_reconciliation` and
its test. The flip PR also sets `last_legacy_iss` to the highest `docs/issues/ISS-*.yaml`
number on `main` at that moment (never lower than the value in the file). The migration list is `docs/migration/work-board-migration-note-20261014.md`.

## 12. History

The queue-era procedure (the queue's register, claim-next, lock and release operations)
is preserved, unedited, under the History sections of `TASK_QUEUE.md` and `ISSUE_QUEUE.md`.
It is a record of how the project worked until cutover, not instructions.
