# Proposal: retire the task queue, GitHub as the single source of work (study, no changes made)

Author: BA/ORCH lane (letflow-2), 2026-10-08. Read-only study requested by the supervisor after the user's remark that
the queue is "an excessive entity" and the supervisor should coordinate locks. Nothing in the queue, docs, repos or
hosts was changed. Facts below come from the code and docs (inventory by a read-only agent, file:line in section 1) and
from what happened in this team's work; items marked **VERIFY** are facts I could not confirm from here.

## 0. Recommendation in five lines

1. Yes, retire `letflow-queue`: its two jobs (hand out work, hold locks) can be done by GitHub issues plus the
   supervisor, with fewer ids, no sync and no second database.
2. Issue = task. **Assignee = the claim, set only by the supervisor** (workers never self-assign). Native
   "blocked by" relations (fallback: a `Depends on #N` list) = dependencies. Labels = state. `REQ-NNN` / `ISS-NNNN`
   stay as title prefixes (human names); the only mechanical id becomes the GitHub issue number.
3. An issue is closed only by a merged PR that says so (`Closes #N`) or by ORCH after RELEASE-VALIDATOR; a partial PR
   says `Refs #N`. This removes the early-close trap (ISS-1014) by construction.
4. Keep a thin script (`scripts/gh_work.sh`: list-ready, claim-check, release, graph) so the protocol stays executable
   by weak models, and so the supervisor can reconcile in one command.
5. Cut over after the repo transfer, in 4 phases (~6-8 agent turns of docs/script work + 1 supervised week of parallel
   running); rollback = the queue keeps running read-only with a frozen snapshot until the decommission phase.

## 1. Inventory (what uses the queue today)

**Callers.** Only ORCH calls the queue (TASK_QUEUE.md:667-677); 0 of 20 agent files under `.claude/agents` call it;
0 CI workflows call it. The supervisor calls `GET /tasks`, `set_lock`, `release` (force) to reconcile
(letflow-supervisor CLAUDE.md, scripts/status.py:125-135, audit_metrics.py). The remote host `ai-dala-orch` is just an
`agent_id` string; there is no cron/loop, workers are interactive ORCH sessions prompted with "what's next"
(queue-triage-2026-09-30.md:18). infra only documents the service (landscape/services.md, secrets-inventory.md,
hosts/hetzner-prod.md, shared/app-registry.md, cloudflare.md, domains.md).

**Endpoints and fields used** (service: Phoenix + SQLite, `letflow-queue/lib/letflow_queue/tasks.ex`, router.ex:184-214):
`POST /tasks` (register: title, description, acceptance_criteria, depends_on[int ids], stage, task_type,
github_issue_number), `GET /tasks/next?agent_id=` (claim, atomic; issues highest-id first, requirements lowest-id
first), `POST /tasks/:id/lock`, `POST /tasks/:id/release` (status open|done|blocked, force), `GET /tasks`
(status/task_type/stage/eligible filters, adds `eligible` and `blocked_by`). Row: id (= impl_order), status
(open|done|blocked), locked_by, locked_at, github_issue_number (unique), issue_ref. Auth: shared bearer token or
per-client keys; Cloudflare in front (blocks default Python user-agent).

**GitHub sync inside the queue** (github.ex): register creates (or adopts) a GH issue; every `get_next_task` first
imports up to 100 open GH issues (no pagination) as `issue` tasks without dependencies; `release done` closes the GH
issue. Comments, labels, assignees, projects and `blocked` are never synced. PAT: fine-grained, repo-scoped,
Issues read/write, **expires 2026-11-13** (infra landscape/services.md:19). Best-effort: a missing/expired token
silently stops importing and closing.

**Where it is written down.** docs/agents: 9 files (TASK_QUEUE.md, ISSUE_QUEUE.md, ORCHESTRATOR.md,
core-directives.md, WF-01..WF-05, AGENT_SYSTEM.md); CLAUDE.md:89-93; `.claude/agents/orchestrator.md:34-40` (already
stale: still says the requirements file is the queue); 4 decision records (0017, 0041, 0044, 0047); anti-patterns.md
(148 matches, history). **Code:** 4 mix tasks (`check_requirements_registration`, `check_deferral_staleness`,
`check_issue_refs`, `check_queue_reconciliation`) + 4 tests + `mix.exs:151,162,186`; `scripts/fix_registry.py`
(one-off). **Data:** `docs/requirements.yaml` 435 REQs / 437 `impl_order` lines / 5 `UNREGISTERED`;
`docs/issues/` 626 files (401 with `queue_ref`, 503 with `github_ref`); `docs/status` 32 files; `handoffs/` ~2.8k
files mention Q-N (history).

## 2. Failures we actually saw (evidence, this team, 2026-10)

| # | Failure | Where it bit |
|---|---|---|
| F1 | **Early-close trap (ISS-1014 class):** `release done` closes the GitHub issue whatever the real state. Partial work closed the issue. | Q-996 closed GH #2283 with only the scenario side done (follow-up ISS-1028); Q-974 (REQ-457) released done with the TENANT_AUDITOR step outstanding (needed residual Q-1036) |
| F2 | **`depends_on` not editable** (no update endpoint). A wrong edge means re-register. | REQ-441 mis-mapped (Q-955/956/947 blocked, re-registered as Q-957/958/959); REQ-464 (Q-1027) registered without its REQ-461 edge, cannot be fixed, needs a manual lock |
| F3 | **Four ids per item** (REQ/ISS, Q-N, GH #, local file) with independent numbering; `issue_ref` collides with local ISS files; only 172 of 305 matched on 2026-09-09. | `queue_ref` vs `ISS-` renames, GH titles re-labelled, "identify by Q-N + GH #" rule |
| F4 | **Integer ids and `agent_id` strings:** a lock can only be released by the identical string; mismatches need `force`. | supervisor force-releases, session-name conventions (`tvolo-win11-orch-uat`) |
| F5 | **No lock expiry / heartbeat** (known gap, supervisor CLAUDE.md:322). | dead sessions hold locks until a human notices |
| F6 | **Lock requires eligibility** (409 if dependencies unmet) so a task cannot be pre-locked. | could not lock Q-1027 to hold it back |
| F7 | **Import duplicates / crossed state:** GH issue and queue task created twice for the same finding, closed/reopened by crossed instructions. | SmtpSink duplicate Q-977/Q-978; GH #2259 closed then reopened |
| F8 | **Sync is best-effort and silent:** expired PAT, 100-issue cap, lost close. | PAT expires 2026-11-13; imports beyond 100 open issues are never claimed |
| F9 | **`blocked` is terminal-ish:** no `blocked -> open` transition; work re-opened by re-registering. | Q-1016/Q-1021 blocked then superseded by new REQs |
| F10 | **Priority is fixed LIFO for issues** and cannot be changed. | a blocker must be picked by `GET /tasks` + manual lock |
| F11 | Overhead: every filing = register + overlap check against queue AND GH AND PRs AND main; every REQ = `impl_order` written back by hand. | all of the above |

## 3. Design: GitHub is the single source

### 3.1 Model

| Today | GitHub-only |
|---|---|
| queue task | **GitHub issue** (one per REQ and one per ISS) |
| Q-N / impl_order | gone. The issue number is the machine id. In yaml: `gh: 2337` replaces `impl_order: 1022` and `queue_ref` |
| `REQ-459` / `ISS-1036` | stay as the **title prefix** (`REQ-459: ...`) and as a label (`req`, `iss`); local files keep them as human names |
| `task_type` | label `type:requirement` / `type:issue` |
| `stage` | label `stage:S3` (or Project field) |
| status open/done/blocked | labels `state:ready`, `state:in-progress`, `state:blocked`, `state:done`; **closed issue = done**. (VERIFY: Projects v2 "Status" field is the nicer view but needs GraphQL; labels work with plain `gh`) |
| `depends_on` (integers, immutable) | GitHub **issue dependencies** ("blocked by" / "blocking" relations), editable any time; fallback: a `Depends on: #A, #B` block in the issue body that the script parses (VERIFY availability on the destination plan/org) |
| `eligible` | computed by the script: open, label `state:ready`, no assignee, every blocker closed |
| lock (`locked_by`) | **assignee** (a GitHub login) + a comment `claimed <agent_id> <UTC>` as the heartbeat record |
| `get_next_task` | `scripts/gh_work.sh next --for <agent>`: lists eligible items in the order the supervisor sets (label `prio:1..3`, default issues-first as today) and **does not claim**; the supervisor assigns |
| release done | the PR merge (`Closes #N`) or ORCH closes after RELEASE-VALIDATOR; `state:done` label |
| release blocked | label `state:blocked` + a comment with the reason; unblocking is just removing the label (fixes F9) |
| register_task | `gh issue create` with the template (title prefix, labels, AC checklist, blocked-by) |
| queue-side GH import / PAT | gone |

### 3.2 Claim = assignee, set by the supervisor (answers "the supervisor coordinates the locks")

- Workers never assign themselves. The supervisor (or the user) assigns an issue to the worker's identity, then tells
  the worker which issue to take. This is a serial human-in-the-loop step: it replaces the atomic SQL claim with
  something simpler and safer, at the cost of not being fully autonomous (this team already runs that way: the
  supervisor ping / slot discipline).
- Identity: one GitHub login per host is cleanest (VERIFY: a machine user or a GitHub App; creating an account is an
  internet action reserved to the user). Without extra logins: label `claimed:<agent_id>` set by the supervisor, plus the
  claim comment. The script checks both.
- Expiry: the supervisor reconciles with one command (`gh_work.sh claims`: every in-progress issue, assignee, claim
  timestamp, linked open PR, last activity). Anything with no PR and no activity for N hours is flagged; the
  supervisor unassigns. This is manual, but it is visible, which today's locks are not (F5).
- Two hosts cannot both claim because only the supervisor assigns; a second assignment of an already assigned issue
  is refused by the script.

### 3.3 Closing only when truly done (answers F1)

- **Issues (ISS):** closed by the merge of a PR whose body contains `Closes #N` **only when the PR fully resolves it**;
  a partial PR says `Refs #N`, the issue stays open, and the remainder is a new linked issue (the residual pattern we
  already use, now enforced by wording). A CI lint (cheap, in the existing mix check) fails a PR with `Closes #N` that
  also lists "residual"/"partial"/"follow-up" in its title (heuristic) is optional; the rule is in core-directives.
- **Requirements (REQ):** the issue closes when DOC-UPDATER flips `status: done` after RELEASE-VALIDATOR (same
  gate as today); a done-with-exception text goes in the issue and yaml, plus the residual issue linked as blocking
  the "full" close (the REQ-457 / Q-1036 case becomes: issue stays open until the residual closes).
- No tool closes an issue as a side effect of a lock release any more.

### 3.4 The remote autonomous host (`ai-dala-orch`)

It does not pull autonomously today (no cron); it is an interactive ORCH session. In the new model it asks the
supervisor or runs `gh_work.sh next --for ai-dala-orch` (read-only list) and takes **only what the supervisor
assigned to it** (assignee or `claimed:` label). If a truly autonomous pull is wanted later, the safe form is a label
`host:ai-dala-orch` set by the supervisor on items it should take; the worker takes the lowest-numbered eligible
item with that label and records its claim comment. No change to the worker's credentials beyond a `gh` token with
Issues read/write on the repo.

### 3.5 What disappears

- The queue service, its SQLite database, `queue-test.ai-dala.com` DNS/nginx/CD, the `letflow-queue` repo (archive).
- The sync (register-creates-issue, import-open-issues, release-closes-issue) and its PAT
  (**the PAT concern moves, it does not vanish**: every worker host needs a repo-scoped `gh` token with Issues
  write; same hygiene, but one system instead of two).
- Q-N ids, `impl_order`, `queue_ref`, `UNREGISTERED` markers, the stage-staleness "deferral" semantics tied to
  registration, the `issue_ref`/ISS collision rule, the three-way overlap check (queue + GH + PRs + main becomes
  GH + PRs + main).
- Four mix tasks change (not disappear): `check_requirements_registration` (every REQ has a `gh:` number),
  `check_issue_refs`, `check_deferral_staleness` (re-spec), `check_queue_reconciliation` (rewritten against `gh`).

### 3.6 What GitHub does NOT give us (design these explicitly)

1. Atomic claim: replaced by supervisor-only assignment (3.2).
2. Eligibility/ordering: the script computes it (blocked-by + labels); LIFO-for-issues becomes an explicit `prio` label.
3. Rate limits: ~5000 requests/h per token; a listing is 1-3 calls; fine, but the script must paginate (the queue's
   100-issue cap, F8, is not repeated).
4. GitHub outage = no work. The queue was also a single point of failure (a Hetzner host), now a bigger but
   external one; local `docs/requirements.yaml` and `docs/issues/` remain the content authority, so work in flight survives.
5. Free-text edits by people: labels/state can be changed by anyone with write; the script validates (one `state:`
   label, one assignee) and the supervisor's reconcile reports violations.

## 4. Impact list (what must change)

- **Docs (~17 files):** TASK_QUEUE.md (replace by `WORK_ITEMS.md`), ISSUE_QUEUE.md (numbering schema, step 2a, adoption
  path), ORCHESTRATOR.md (§2 selection, §4a drain loop, overlap check), core-directives.md (3 passages),
  WF-01 (Step 3), WF-02 (:513-522 release), WF-03 (:69, :217-235), WF-04/05 (pointers), AGENT_SYSTEM.md,
  CLAUDE.md:89-93, `.claude/agents/orchestrator.md` (stale already), reviewer/process-auditor/uat-runner pointers.
  History records (0017/0041/0044/0047, anti-patterns, handoffs) stay; a new decision record supersedes 0017.
- **Code:** 4 mix tasks + 4 tests + `mix.exs` wiring; new `scripts/gh_work.sh` (+ test with a stub `gh`).
- **Data (scripted, reviewed):** 437 `impl_order:` lines -> `gh:` (every queue task has a `github_issue_number`, so the
  mapping is mechanical: Q-N -> GH #); 401 issue yamls `queue_ref` kept as history field, `github_ref` becomes the key;
  open queue dependencies -> GitHub blocked-by edges via the GH numbers; labels set on all open items.
- **Other repos:** letflow-supervisor (CLAUDE.md, status.py, audit_metrics.py); ai-dala-infra (services.md,
  secrets-inventory.md, hetzner-prod.md, app-registry.md, cloudflare.md, domains.md + decommission task: a
  user-approved infra action).

## 5. Cutover plan (start AFTER the repo transfer)

Why after: the transfer changes the repo identity (issue numbers keep, URLs redirect; tokens, the PAT's repo scope,
`GITHUB_REPO` in the queue and every doc link are touched once, not twice). Open VERIFY: destination (user vs org),
plan features available there (issue dependencies, Projects).

| Phase | Work | Size | Exit test |
|---|---|---|---|
| P0 Prepare | labels (`type:*`, `state:*`, `stage:*`, `prio:*`, `claimed:*`), issue templates (REQ, ISS with AC + blocked-by), `scripts/gh_work.sh` + stub tests, new decision record + `WORK_ITEMS.md` (drafts, not yet binding) | M (3-4 turns, 1 PR for scripts, 1 for docs drafts) | script lists the same eligible set the queue lists, on a snapshot |
| P1 Shadow | one-time migration script labels all open items and creates blocked-by edges from the queue's `depends_on` via GH numbers; both systems live; the supervisor compares `gh_work.sh next` with `GET /tasks?eligible=true` daily | S (1 turn) + 3-5 days elapsed | zero diffs for 3 consecutive days; every open queue task has a GH issue with the right label/edges |
| P2 Cutover | supervisor announces the switch; queue made read-only by convention (nobody registers/locks; the final snapshot of `GET /tasks` is committed under docs/status); binding docs PRs: TASK_QUEUE/ISSUE_QUEUE/ORCHESTRATOR/WF/core-directives/CLAUDE.md/agents, mix tasks rewritten, `impl_order` -> `gh:` data migration; one worker host first (this one), then `ai-dala-orch` | M-L (4-6 turns across 3-4 PRs: docs, mix tasks, data) | full backend gate green; one full cycle (file -> assign -> PR -> merge -> close) per issue type; `gh_work.sh claims` shows no stray state |
| P3 Observe | two weeks of normal work; fix script gaps; the PAT on the queue is not renewed | S | no use of the queue API in the access log for 14 days |
| P4 Decommission | archive `letflow-queue`, remove nginx/DNS/CD/volume (backup the SQLite file first), delete queue PAT and `QUEUE_AUTH_TOKEN` from hosts, infra docs updated | S | infra task, **user-approved** |

**Risks:** (R1) supervisor becomes the bottleneck for claims: mitigated by the `host:` label for pre-approved
autonomous pulls; (R2) label drift: the reconcile command + a lint on the issue state; (R3) GitHub API/plan feature
gap (dependencies): fallback to the body `Depends on` block, parsed by the script; (R4) migration mapping mistakes
(the REQ-441 class): the P1 diff against the live queue catches them before cutover; (R5) a worker host missing the
`gh` token or the label rules: P2 starts with one host; (R6) PAT/token scope creep: one fine-grained token per host,
Issues + Pull requests only; (R7) history links (`Q-N` in 2.8k handoff files) become unresolvable: kept as history,
the snapshot file maps Q-N -> GH # forever.

**Rollback:** until P4 the queue and its database are untouched and running. Rollback during P2/P3 = revert the
docs/mix/data PRs (git), re-open the queue for writes, and replay GH-side changes since cutover with a small script
(GH numbers -> queue tasks are 1:1 because every task keeps its `github_issue_number`; new GH-only items are imported
by the queue's own GH import). After P4 the SQLite backup restores the queue; the cost is one day of re-registration.

## 6. Alternative considered: keep the queue, supervisor owns the locks

Cheaper (no migration): the supervisor calls `set_lock`/`release` for every worker. Rejected as the end state because it
fixes only F4/F5, not F1/F2/F3/F6-F11, keeps the sync and PAT, and keeps four ids. It is a valid stopgap until the
transfer, and is largely what happens now.

## 7. Facts (answered by the supervisor 2026-10-08; open ones marked)

1. Destination: `tvolodi-org/letflow` (name kept), public, squash merges (infra T-0165, user's defaults). Issue
   dependencies and Projects are GitHub features, not plan-limited on public repos, but **VERIFY on the transferred
   repo itself in P0; do not assume.**
2. Second GitHub identity for the remote host = account creation = the user's call. Design uses the **label-claim
   fallback**; the extra identity is an **optional upgrade** (user decision).
3. Priority: explicit `prio:` labels; issues-first LIFO only as the tie-break.
4. **OPEN (for the user):** other queue callers outside these repos, notably the remote host `ai-dala-orch` and its
   cron/pipeline, if any.
5. Freeze window not fixed (infra T-0165): supervisor's plan is a ~3 h drain and a 2 h window; P0 is scheduled
   outside it. Decision status: goes to the user as a decision item; **no cutover before the transfer; nothing changed now;
   do not start P0.**
