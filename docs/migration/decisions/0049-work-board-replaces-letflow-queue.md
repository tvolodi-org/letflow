# 0049 — Work board on GitHub replaces letflow-queue: issues are the single store, the supervisor coordinates, labels carry state

Status: Accepted (decision source in the Sign-off section; no REVIEWER sign-off is claimed by
this record).
Supersedes: 0017 (task-queue selection model) in full.
Amends the mechanism text of: 0041 (drain mode loops `get_next_task`), 0047 (the remote
host "uses the queue and locks"). Their decisions stand; only the named mechanism changes.
Date: 2026-10-14. Drafted by `ORCH` for GH #2430 (ISS-1073). Owner: `ORCH`.

## The decision as given

Recorded from the issue that carries it (GH #2430, "ISS-1073: Work board on GitHub
replaces letflow-queue"), which says it is "ITEM 8 from the team audit, decided by the
user on 2026-10-13 and relayed by letflow-9a":

> The task queue is deleted; the supervisor coordinates; GitHub issues are the single
> store. It builds on the study in
> `handoffs/HANDOVER-letflow-2-20261008/reference/queue-replacement-study-2026-10-08.md`
> with three changes: no multi-day shadow phase, no second GitHub identity (labels
> instead of assignees), cutover right after the repo transfer.

The same issue carries two later corrections from letflow-9a and the supervisor, which
this record follows where they differ from the study:

* The claim label is a **convention, not a control**: every session uses one GitHub
  login. Only the supervisor (or the user) sets `claimed:<checkout>`.
* Labels are per **checkout** (`letflow`, `letflow-2`, `letflow-3`, `letflow-4`,
  `remote`), not per session name.
* Cutover is **not a calendar date and is not hard-wired to the repo transfer**: it is
  the day the PR that flips the cutover switch merges, after one CI-shaped dry run
  passed.

## Context

Decision 0017 settled that "the queue arbitrates claims, it does not choose the work" and
made `letflow-queue`'s atomic claim the only lock. That held as a locking design. The
study of 2026-10-08 (section 2) then recorded eleven failure classes seen in practice
that sit *around* the lock rather than in it, and that the queue's shape cannot fix:

| # | Failure class | Example |
|---|---|---|
| F1 | `release done` closes the GitHub issue whatever the real state | Q-996 / GH #2283 closed with half the work done |
| F2 | `depends_on` cannot be edited after registration | REQ-441 re-registered; REQ-464 missing its edge |
| F3 | four ids per item with independent numbering | `ISS-` vs `Q-` vs GH vs local file; 172 of 305 matched |
| F4 | lock release needs the identical `agent_id` string | supervisor force-releases |
| F5 | no lock expiry or heartbeat | dead sessions hold locks |
| F6 | a lock requires eligibility, so a task cannot be held back | Q-1027 |
| F7 | duplicate / crossed import between queue and GitHub | SmtpSink duplicate; GH #2259 closed then reopened |
| F8 | sync is best-effort and silent (PAT, 100-issue cap) | imports beyond 100 open issues never claimed |
| F9 | `blocked` is terminal-ish | work re-opened by re-registering |
| F10 | issue priority is fixed LIFO | a blocker needs a manual lock |
| F11 | every filing is register + overlap check against queue AND GitHub AND PRs AND main | overhead |

The user's decision removes the second system instead of patching around it.

## Decision

**A. A work item is a GitHub issue.** Its number is the only machine id. `REQ-NNN` stays
as a title prefix; `ISS-NNNN` files, `queue_ref` and `impl_order` fields stay as history.
New requirement entries carry `gh: <number>`; new local issue records are named
`GH-<n>.yaml`.

**B. The supervisor coordinates; labels carry state.** `state:`, `prio:`, `lane:`,
`claimed:<checkout>`, `next:<checkout>`, `type:`, `stage:S<n>` (definitions in
`.github/labels.yml`). Blocked-on is a body line, not a label. Dependencies are a
`Depends on: #A, #B` body line (editable at any time, answering F2).

**C. The invariant of 0017 §F is restated, not dropped.** 0017: *no agent works a task it
does not hold a lock on, and no lock is obtained anywhere but from the queue.* Now: **no
agent works an item that has not been claimed for its checkout by the supervisor or the
user, and no agent sets a claim.** Still forbidden: reading `docs/requirements.yaml` to
select work, and falling back to file-order selection when GitHub is unreachable (report
`no_claimed_task`). What changes is the mechanism: a human-readable claim label plus a
`CLAIM <checkout> by supervisor|user` comment, instead of an atomic SQL update.

**D. What the claim is not.** It is not atomic and not enforced by GitHub. Because every
session shares one login, the label cannot prove who set it. The compensating controls
are a protocol rule (only the supervisor sets it), a recorded claim comment, a heartbeat
(start, PR open, blocked, done, about every 2 hours on a long chain; stale after 4
hours) and a read-only checker (`scripts/gh_work.sh check`) that fails a claim label with
no matching claim comment. This is a deliberate trade of autonomy for simplicity, accepted
by the decision above.

**E. Closing is by merged PR only.** `Closes #N` only when the PR fully resolves the
issue; a partial PR says `Refs #N` and the residual is a new linked issue (answers F1).

**F. One filer.** The sole filer runs `gh issue create` from
`.github/ISSUE_TEMPLATE/work_item.md` after the overlap check (open issues, open PRs,
`main`). Everyone else reports findings to the filer (answers F7, F11).

**G. Gate checks.** `check_requirements_registration`, `check_deferral_staleness` and
`check_issue_refs` accept either legacy ids or `gh:` / `GH-<n>` while
`docs/status/work_board_cutover.yaml` says `cutover: false`. After the switch is flipped
to `true`, a non-terminal requirement needs `gh:` (R7), and a new `ISS-NNNN` above
`last_legacy_iss` is refused. `check_queue_reconciliation` was deleted, with its test, in the cutover PR (2026-10-14).

**H. Cutover order (not a date).** The board PR merges; the supervisor announces cutover;
infra stops the queue service and exports it, keeps a one-week rollback window, and deletes
it later. The PR that introduces this record does not stop or delete the service.
Cutover is the PR that flips the switch, after a CI-shaped dry run of one requirement
record and one issue record carrying only a GH number through
`mix letflow.check.static`.

## Consequences

* `TASK_QUEUE.md` and `ISSUE_QUEUE.md` become pointers with their old text kept under a
  History heading; `WORK_BOARD.md` is the live protocol.
* ORCHESTRATOR.md, core-directives.md, WF-01/02/03, AGENT_SYSTEM.md, CLAUDE.md and
  `.claude/agents/orchestrator.md` are rewritten to the board. 0017, 0041 and 0047 stay as
  written apart from a one-line "Superseded in part by 0049" pointer under their header;
  0044 stays as written (history).
* **Autonomy is now bounded by supervisor availability.** A worker with nothing claimed
  stops (`no_claimed_task`); there is no self-service pick, and nobody else can start work
  while the supervisor is away. This is a deliberate trade the user decided, not a defect to
  route around. Drain mode (0041) means "take the next issue already claimed for your
  checkout".
* **The claim is a convention, not a control.** Every session shares one GitHub login, so
  any session can set a `claimed:*` label and post a `CLAIM ... by supervisor` comment, and
  `scripts/gh_work.sh check` cannot tell that apart from the supervisor's. The check catches
  accidents and label/comment mismatches, not forgery.
* A GitHub outage is a work outage. The queue was also a single point of failure; local
  `docs/requirements.yaml` and `docs/issues/` remain the content authority.
* The repo-scoped `gh` token every worker host needs replaces the queue PAT and
  `QUEUE_AUTH_TOKEN`; hygiene is the same, one system instead of two.
* History links (`Q-N` in older handoffs) become unresolvable by service; the exported
  queue snapshot and `docs/migration/work-board-migration-note-20261014.md` map row ids
  to GH numbers.
* Rollback: until the service is deleted, reverting the switch to `false` and re-opening
  the queue for writes restores the previous procedure; GitHub-side changes since cutover
  are replayed from the issue numbers, which map 1:1 to rows.

## Transition facts, 2026-10-14

* The repository moved to `tvolodi-org/letflow` the same day; `main` is governed by the ruleset
  `main-queue` and a merge queue (`docs/merge-queue.md`), so a PR lands only through the queue.
* The queue-to-GitHub sync is DOWN (accepted by the user): a new queue task no longer creates a
  GitHub issue and a task going done no longer closes one. Until cutover the sole filer files
  issues directly with `gh` and closes them by hand after checking every acceptance-criterion
  comment. This makes the GitHub issue the de facto record before the formal cutover flip.

## Consistency with existing decision records

| Record | Relationship |
|---|---|
| 0017 | superseded (A-G above). Its E1/E2 findings (the atomicity lived in the UPDATE) are why the lock is not re-implemented; the claim here is a convention |
| 0041 | unchanged in substance (no governance self-authoring while draining; no multi-task pre-claiming). Its `get_next_task` wording is replaced by `WORK_BOARD.md` section 6 |
| 0044 | no change; its mention of queue task state is historical |
| 0047 | the remote host now takes only what is `claimed:remote` |
| 0004 | unchanged: commit/push/PR/merge stay pre-authorized. A human-paced *claim* is not a merge gate. REVIEWER should confirm that reading |

## Open points for REVIEWER (not reviewed; recorded as open)

1. Whether supervisor-paced claiming conflicts with 0004's "no human gate" wording (this
   record reads it as scoped to commit/push/merge).
2. The post-cutover rule R7 treats legacy `impl_order` as valid history only for terminal
   requirements; confirm that is the intended meaning of "existing lines stay history".
3. The 8 queue rows with no GitHub issue (REQ-101..108) are "superseded, not planned",
   not migrated, per the supervisor; confirm.

## Sign-off

Decided by the user 2026-10-14 (live, supervisor terminal); recorded by the supervisor, as relayed to the sole filer and not independently verified by the writer. Earlier statements: 2026-10-13 (supervisor terminal) and in the infra terminal ('Let delete queue. We have supervisor instead.').

REVIEWER sign-off: not performed.
