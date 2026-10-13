# 0017 — Task-queue selection model: the queue arbitrates claims, it does not choose the work

Status: decided (2026-09-04). Owner: ORCH (the `letflow-queue` change and the matching
`TASK_QUEUE.md` rewrite execute it).

Superseded in part by 0049 (`0049-work-board-replaces-letflow-queue.md`): the queue and its selection model are replaced by the GitHub work board (in full).

## Question

`letflow-queue` is the only load-bearing piece of pipeline infrastructure in this
project with **no decision record**. Its shape — four operations, one of which both
selects and claims a single task — has been treated as settled since it was deployed
(`ai-dala-infra` T-0107/T-0108, 2026-08-15), and `TASK_QUEUE.md` has accumulated eleven
sections of procedure on top of it. But the rationale for that shape was never written
down anywhere, and the two places that cite it cite each other:

> "the service is deliberately four operations, per its own README's 'Design' section"
> — `docs/agents/protocols/TASK_QUEUE.md:386`

> "because letflow-queue deliberately exposes no generic update operation — see its
> README's 'Design' section, exactly four endpoints, on purpose."
> — `docs/agents/protocols/TASK_QUEUE.md:117-118`

And the README those point at asserts the count as a value, not a consequence:

> "The task queue itself has exactly **four** externally-callable operations. This is
> deliberate: an AI agent driving this service can register a task, claim the next
> eligible one, and lock/release — nothing else. There is no generic CRUD, no way to
> list/edit/delete tasks outside that lock protocol, and no way to bypass the
> atomic-claim semantics."
> — `letflow-queue/README.md`, "Design"

Three questions, settled here in one record because they are the same question:

1. Does the queue's correctness guarantee actually depend on `get_next_task` returning
   exactly one task, or is that cardinality incidental?
2. May an agent see the whole queue (all tasks, their `depends_on`, their lock state)?
3. May an agent *choose* which eligible task to claim, rather than being handed one?

## Evidence

### E1 — The atomicity lives in the UPDATE, not in the return cardinality

Verified directly against `letflow-queue/lib/letflow_queue/tasks.ex` on 2026-09-04
(`get_next_task/1`). The claim is one hand-written SQL statement:

```sql
UPDATE tasks
SET locked_by = ?1, locked_at = ?2, updated_at = ?2
WHERE id = COALESCE( (<newest eligible issue>), (<lowest-impl_order eligible requirement>) )
RETURNING ...
```

with the module's own comment stating the guarantee precisely:

> "The eligibility predicate (open, unlocked, all dependencies done) is evaluated inside
> the same UPDATE statement that performs the claim. … SQLite executes writers serially,
> and wrapping this in an explicit transaction ensures the SELECT-then-UPDATE the query
> planner performs internally can't interleave with another writer — so two concurrent
> callers can never both claim the same row."

The property that stops two hosts taking REQ-048 is **`WHERE id = …` resolving and
`SET locked_by` committing in one serialized write**. Nothing in that depends on how
many rows a *reader* is allowed to see. `LIMIT 1` appears inside the two subqueries
because the UPDATE needs a single scalar id to target — it is a consequence of writing
the claim as one statement, not an independent safety decision.

**Therefore: returning N tasks, unlocked, breaks nothing.** Reading was never the racy
half. This answers question 1 — the cardinality is incidental.

### E2 — Both real incidents were locking failures, not selection failures

The two queue incidents in `docs/anti-patterns.md` are routinely cited as evidence that
agent discretion over selection is dangerous. Re-read, neither one is that.

**2026-08-19, REQ-048 double-run** (`docs/anti-patterns.md`, "Task-selection fallback
duplicating a run"). Two ORCH sessions both ran a full WF-02 for REQ-048. The mechanism
was the then-permitted fallback: with `$QUEUE_AUTH_TOKEN` unavailable, ORCH read
`docs/requirements.yaml` and picked from it. Both sessions therefore worked **with no
lock of any kind** — the queue was never consulted. Had either called any locking
operation, the second would have been refused. This is a case *for* mandatory locking;
it says nothing about whether a locking agent may choose its own target.

**2026-08-20, ISS-0086/GH#303 resolution run** (`docs/anti-patterns.md`, "Working a
user-named GitHub issue without ever locking it"). Two compounding mistakes, and the
entry names them: (1) `get_next_task` used as a reachability probe, which claimed and
locked an unrelated task (#161/ISS-0075) because it "is not read-only, it atomically
claims whatever it returns"; (2) the exemption from *selection* being misread as an
exemption from *locking*, leaving a fix running for its full duration with nothing in
queue state reflecting it. The entry's own diagnosis of (2): "the exact failure mode
`TASK_QUEUE.md` was written to prevent, just via a different door than the one its Hard
Rule closes."

Mistake (1) is caused *by the missing read-only endpoint* — there was no side-effect-free
way to ask the service anything, so a mutation got used as a query. That is this record's
subject appearing as a live defect, not as a hypothetical.

### E3 — The missing `GET` has been patched around four separate times

Each of these exists in current, shipped procedure solely because the service cannot be
read without mutating it:

| Workaround | Where | What it substitutes for |
|---|---|---|
| "exactly **one** real `get_next_task` call … doesn't match → `release_lock` it back to `open` immediately" | `TASK_QUEUE.md`, "A human names a specific issue" | lookup-by-`github_issue_number` |
| "**Test reachability with `GET /health`** … **never** with `get_next_task` used as a probe" | `TASK_QUEUE.md`, own section + `anti-patterns.md` | a side-effect-free read |
| "registering in dependency order and keeping a `REQ-xxx → task id` map as you go" | `TASK_QUEUE.md`, `register_task` | asking what is already registered |
| GitHub Issue mirroring, added expressly because "removing GitHub Issues as a control path also removed the one place a human could casually see queue state (open/claimed/done) without querying the service directly" | `TASK_QUEUE.md`, "Why this exists" | a list endpoint |

Four patches, one absent `GET`. The fourth is the most telling: an entire bidirectional
GitHub sync subsystem was built to restore visibility the API declines to provide.

`set_lock` compounds it — `TASK_QUEUE.md` states "There is no lookup-by-`github_issue_number`
or lookup-by-title endpoint … the id has to come from a prior `register_task` response …
or from having seen it in a prior `get_next_task`/`set_lock` response. An issue with no
recorded id and no prior sighting **cannot be target-claimed at all**." A capability the
service has is unreachable purely for want of a way to learn an integer.

### E4 — Selection and claiming were coupled by accident

The design brief (quoted in `TASK_QUEUE.md`) asked for one thing: that "AI agents
manipulate files on their discretion" stop being the mechanism. That requires
**arbitration** — a single authority deciding who holds a task. It was implemented as
`get_next_task`, which arbitrates *and* chooses, because the only way to obtain a lock
is to let the service also pick the target. Selection was never separately requested; it
came along because it was in the same function.

Decision 0004's principle is often read as forbidding agent choice outright. What it
actually protects is that no *unvalidated* agent judgement becomes load-bearing. Under
an arbitrated model, a choice is not unvalidated: a wrong pick is refused by `409` or by
the eligibility predicate. The service still has the final say — it simply stops also
having the only say about what was worth asking for.

## Decision

**A. The queue arbitrates claims. It does not choose the work.** Locking remains
mandatory, exclusive, and the sole path to working a task — unchanged and non-negotiable.
Selection is decoupled from it.

**B. Add `GET /tasks` — a read-only listing operation.** Returns tasks with `id`/
`impl_order`, `title`, `stage`, `task_type`, `status`, `depends_on`, `locked_by`,
`locked_at`, `github_issue_number`, and a service-computed `blocked_by` (the subset of
`depends_on` not yet `done`) plus an `eligible` boolean applying the same predicate
`get_next_task` uses. Filterable by `status`, `task_type`, `stage`, `eligible`.

It **must not** claim, lock, or transition anything, and **must not** run the
GitHub-import step. Read-only means read-only; the whole point is a call that is safe to
make for any reason. This retires the claim-then-release lookup dance, makes `set_lock`
reachable for a known-issue-number task, and gives `GET /health` a companion that answers
"what is in there" without the ISS-0086 hazard.

**C. An agent may select any task it can see, and claims it with `set_lock`.**
`get_next_task` is retained unchanged as the default — "give me whatever is next" stays
the ordinary path and the two-tier issue-before-requirement priority is untouched.
`GET /tasks` + `set_lock(id)` becomes the sanctioned alternative when ORCH has a reason
to prefer a different eligible task.

The safety argument is E1 and E2: two hosts choosing the same task is not a duplicated
run, it is a `409` for the loser, who then chooses again. That is the transactional
guarantee doing exactly the job it was built for.

**D. `set_lock` must refuse an ineligible task.** Today `set_lock` checks only lock
state, not `status`/`depends_on` — acceptable when `get_next_task` was the only selector
and had already applied the predicate. Once agents select for themselves that becomes the
load-bearing gate, so `set_lock` must apply the same eligibility predicate and reject a
task whose dependencies are unmet or whose status is not `open`, with a distinct error
(`:not_eligible`, `409`) naming the unmet dependency ids. Without this, free selection
would let an agent start dependency-blocked work, which is a genuine regression the
current design prevents only as a side effect.

**E. `release_lock`'s `force` stays exceptional, and `409` is not routed around.** A
`409` from `set_lock` means "someone else has it" — the correct response is to pick
another task, never `force`. `force` remains what its README says: an override for
unsticking a task after a host died mid-work, used deliberately and with a stated reason.
This is called out because free selection makes forcing more tempting than it was when
targets were assigned.

**F. The Hard Rule is amended, not repealed.** `TASK_QUEUE.md`'s Hard Rule currently
conflates three prohibitions. Restated:

- **Still forbidden:** working any task without holding its lock; reading
  `docs/requirements.yaml` (or any file) to *select* work in place of the queue; falling
  back to file-order selection when the queue is unreachable — an unreachable queue is
  still a blocked state to report, because no lock can be obtained.
- **Now permitted:** reading full queue state via `GET /tasks` for any purpose, and
  choosing among eligible tasks, provided the choice is realized through `set_lock` and
  the `409`/`:not_eligible` answers are obeyed.

The invariant, stated once: **no agent works a task it does not hold a lock on, and no
lock is obtained anywhere but from the queue.** Everything above follows from that; the
file-reading and single-return prohibitions were proxies for it.

## Consequences

- `letflow-queue`'s "exactly four operations" framing retires. The replacement invariant
  is not a count but a rule: **exactly one mutating claim path.** A fifth, read-only,
  non-mutating operation does not weaken it. Its README's Design section must be rewritten
  to say so, since that text is what both `TASK_QUEUE.md` citations rest on.
- `TASK_QUEUE.md` needs its Hard Rule, `set_lock`, "A human names a specific issue," and
  reachability sections rewritten against §F. The bounded claim-then-release procedure is
  deleted, not amended — `GET /tasks` replaces it outright.
- `docs/anti-patterns.md`'s "Working a user-named GitHub issue without ever locking it"
  entry gains a note that its mistake (1) is now structurally impossible.
- `mix letflow.check_requirements_registration` and `mix letflow.check_deferral_staleness`
  currently reason about registration from `docs/requirements.yaml` alone; they *may* now
  verify against the live queue. Not required by this record, and deliberately not
  scoped here.
- A real risk this record accepts: a visible queue is easier to select from *without*
  locking than an invisible one — an agent that can see the board can rationalize acting
  on what it saw. §F's invariant is the mitigation, and it must be stated at the
  `GET /tasks` call site in `TASK_QUEUE.md`, not only in this record. A matching
  `anti-patterns.md` entry should be written when the endpoint ships, pre-emptively.
- `docs/requirements.yaml` remains a content mirror, not a selection source. Unchanged.

## What this record does not decide

- Whether `get_next_task` gains preference parameters (`?stage=`, `?task_type=`,
  `?exclude_stage=`). Under §C an agent can express any preference via `GET /tasks` +
  `set_lock`, so these are ergonomics, not capability. Left open.
- Any change to the two-tier claim priority, `issue_ref` allocation, GitHub sync, or the
  API-key surface. All out of scope.
- Whether other roles may call the queue. Unchanged: ORCH only
  (`TASK_QUEUE.md`, "Who calls what").
