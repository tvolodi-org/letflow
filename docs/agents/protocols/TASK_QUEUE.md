# TASK_QUEUE Protocol — SUPERSEDED by the work board

> **Do not follow this file's procedure.** Work coordination is the GitHub work board:
> [`WORK_BOARD.md`](WORK_BOARD.md). A work item is a GitHub issue, its number is the only
> machine id, labels carry state, and the supervisor coordinates claims. Workers never
> call the queue (its four operations -- register, claim-next, lock, release -- are retired).
> Decision: `docs/migration/decisions/0049-work-board-replaces-letflow-queue.md`
> (supersedes 0017). Tracking issue: GH #2430 (ISS-1073).
>
> Cutover state is the single switch `docs/status/work_board_cutover.yaml`. Until it says
> `cutover: true`, the supervisor still keeps the queue's rows and locks in step with the
> board; infra stops the queue service only after the supervisor announces cutover.

## History (kept unedited; the queue-era procedure as it stood until cutover)

---


**Service:** `letflow-queue` — a small standalone Elixir/Phoenix + SQLite service,
deployed independently of Letflow itself (own repo: `tvolodi/letflow-queue`). Deployed
and live at `https://queue-test.ai-dala.com` (test only — see "Deployment status"
below). A prod deployment at `queue.ai-dala.com` is not yet planned; every example in
this file uses the live test URL.

**Read by:** `ORCH` (all five operations), every other agent (read-only via `ORCH`'s
dispatch — see "Who calls what" below).

---

## Why this exists

Once Letflow development runs across multiple hosts simultaneously, a single
git-checkout's `docs/requirements.yaml` and local `handoffs/registry.json` stop being a
reliable shared source of truth — two hosts could both read `status: pending` on the
same requirement before either has pushed a claim, and both start work on it. The
`owned_modules` lock in `docs/agents/ORCHESTRATOR.md` §7 only coordinates runs that
share one host's registry; it does nothing across hosts.

`letflow-queue` is the fix: **one shared, authoritative queue**, reachable by every
host, that atomically hands out the next claimable work item and prevents two hosts
from claiming the same one. Per the project's own operating principle
(`docs/migration/decisions/0004-humanless-pipeline.md`), no agent gets direct
discretion over which task to pick or whether to lock it — that decision is made by the
service, not by an agent reading a file and choosing.

Removing GitHub Issues as a control path also removed the one place a human could
casually see queue state (open/claimed/done) without querying the service directly —
`letflow-queue` closes that gap itself, as a function of the app, by mirroring tasks to
GitHub Issues for **visibility only** (see "GitHub Issues visibility" below), rather
than reintroducing Issues as something an agent reads to decide what to do.

---

## Hard rule: no agent works a task it does not hold a lock on

**The governing invariant, stated once (decision 0017 §F, amending — not repealing —
this section's earlier framing):**

> No agent works a task it does not hold a lock on, and no lock is obtained anywhere but
> from the queue.

Everything below follows from that.

**Still forbidden:**
- Working any task without holding its lock, obtained from the queue (`set_lock` or
  `get_next_task`) — non-negotiable, unchanged by decision 0017.
- Reading `docs/requirements.yaml`, or any other file, to **select** work in place of the
  queue. No agent may read the yaml and decide "I'll work on REQ-N" on its own
  initiative. `docs/requirements.yaml` remains a **read-only mirror** for human/agent
  reference and cross-linking (e.g. citing `stage`, prior context) once a task's id is
  already known — never the dispatch mechanism. It is kept in sync by ORCH via
  `register_task` (see below), not edited freely by any producing agent.
- **Falling back to file-order selection when the queue is unreachable** (network down,
  not yet deployed, or `$QUEUE_AUTH_TOKEN` unavailable) — **including a session that
  believes itself to be single-host**. An unreachable queue remains a blocked state to
  report, because no lock can be obtained from it; it is never a trigger to degrade to
  reading the file yourself. A session cannot reliably know it is the only host running
  Letflow agents, and "single-host, no multi-host risk" was exactly the reasoning that
  failed on 2026-08-19: two concurrent runs both selected REQ-048 because one of them was
  in fallback mode and couldn't see the other's in-flight claim, producing a fully
  duplicated WF-02 run that had to be discovered and cancelled after the fact (see
  `docs/anti-patterns.md`). When the queue is unreachable, ORCH reports
  `no_eligible_task (queue unreachable)` and stops.
- No agent may hand-edit a task's status/lock state to route around the queue.

This does not block work that is *not* agent-selected: a specific `REQ-XXX` named
directly by the user, or another human-originated instruction, is not "agent discretion
over selection" and may still proceed without the queue for *selection* purposes — but
see "A human names a specific issue" below: skipping selection is not the same as
skipping the queue's claim/release entirely, and doing so leaves a real duplicate-work
window open to any other host running `get_next_task` against the same still-open item.

**Now permitted (decision 0017 §B/§C, added 2026-09-04):**
- **Reading full queue state via `GET /tasks` for any purpose** — a reachability check,
  a dashboard, deciding what to work on next, or plain curiosity. See "`GET /tasks` —
  list full queue state (read-only)" below. This is new: earlier drafts of this section
  asserted agents may not read queue state at all, which decision 0017 supersedes —
  reading was never the racy half (the claim's atomicity lives entirely in
  `get_next_task`'s/`set_lock`'s `UPDATE`, not in withholding the listing).
- **Choosing among eligible tasks seen that way**, provided the choice is realized
  through `set_lock` and the `409`/`:not_eligible` answers are obeyed (see `set_lock`
  below). Seeing a task is never itself a claim; `set_lock` is what actually arbitrates
  it, and a wrong pick is simply refused.

This rule binds **every agent**, not just ORCH — see
`docs/agents/instructions/core-directives.md`'s updated Zero Manual Work /
Humanless Operation sections.

### Reachability checks must not have side effects

Two side-effect-free ways exist to ask the service something without claiming anything:
**`GET /health`** (no auth required, touches nothing — the standard reachability probe)
and, as of decision 0017, **`GET /tasks`** (auth required, still a pure read — see
below, and it can answer richer questions than "is it up," such as "is there eligible
work"). **Never** probe with `get_next_task` used this way. `get_next_task` is not
read-only: it atomically claims and locks whatever it returns, and its GitHub-import
step can also mutate queue state (importing not-yet-tracked open issues as new tasks)
even when the claim itself is later released. A `get_next_task` call made "just to check
the service is up" with a disposable `agent_id` (e.g. `"probe"`) still produces a real
lock on a real task that a concurrent host could have been about to claim — release it
immediately if this happens by mistake, the same as any other hand-back (2026-08-20,
ISS-0086/GH#303's own resolution run — this happened for real, see
`docs/anti-patterns.md`).

**There is no `dry_run` mode, and none should be invented.** `get_next_task` accepts
exactly `agent_id` (required) and no other query parameter changes its claiming
behavior — critically, `letflow-queue` **silently ignores unknown query parameters
instead of rejecting them with 400**, so `GET /tasks/next?agent_id=...&dry_run=true`
does not error, does not skip the claim, and does not warn — it just claims normally,
as if `dry_run` had never been sent. This happened for real (2026-09-12, ISS-0616): an
ORCH session added `dry_run=true` under `agent_id=orch-probe` intending a read-only
availability check, and the service locked a real task to that throwaway id, which then
sat unclaimable by any host for 57 minutes until the same session tried to claim it for
real, got `409`, and had to work out from context which id held the lock. Recovery is
the same as any accidental probe-claim: `release_lock` under the id that actually holds
it, back to `open`, then claim properly. **`GET /tasks` (below) is now the read-only way
to ask "does the queue have eligible work"** — it shipped 2026-09-04 (decision 0017 §B);
do not simulate a dry-run with `get_next_task` and invented query parameters, since the
service's own silent-ignore behavior makes that indistinguishable from a real claim.

---

## `GET /tasks` — list full queue state (read-only)

Added 2026-09-04 (decision 0017 §B), as the fifth `letflow-queue` operation. Returns
every task's current state, with two computed fields no other endpoint exposes:
`blocked_by` (the subset of `depends_on` not yet `status: "done"` — `[]` means none) and
`eligible` (boolean, the exact predicate `get_next_task`/`set_lock` apply: `status ==
"open"` AND every `depends_on` id `"done"` AND unlocked). It performs **no write of any
kind** — no lock, no status transition — and it specifically does not run
`get_next_task`'s GitHub-import step.

```bash
curl "https://queue-test.ai-dala.com/tasks?status=open&eligible=true" \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN"
```

Filters, all optional and combinable (intersect, not union): `status`, `task_type`,
`stage` (each an exact-match string), `eligible` (`true`/`false`, accepts a real boolean
or the strings `"true"`/`"false"`).

Response (`200`) — the shape is `{"tasks": [...]}`, **not** the `{"data":, "error":}`
envelope every other endpoint uses (a listing has no single-resource success/error split
to represent):

```json
{
  "tasks": [
    {
      "id": 42,
      "impl_order": 42,
      "issue_ref": null,
      "title": "Implement REQ-042",
      "description": "Add the foo endpoint per docs/requirements.yaml",
      "acceptance_criteria": ["mix test passes"],
      "depends_on": [12, 13],
      "stage": "S2",
      "task_type": "requirement",
      "status": "open",
      "locked_by": null,
      "locked_at": null,
      "github_issue_number": null,
      "body": null,
      "blocked_by": [13],
      "eligible": false,
      "inserted_at": "2026-08-15T00:00:00Z",
      "updated_at": "2026-08-15T00:00:00Z"
    }
  ]
}
```

**Seeing a task here does not authorize working it.** This is exactly the call site
decision 0017's own Consequences section names as the risk it accepts ("a visible queue
is easier to select from without locking than an invisible one — an agent that can see
the board can rationalize acting on what it saw"), so the governing invariant is
restated here: **no agent works a task it does not hold a lock on, and no lock is
obtained anywhere but from the queue.** An `eligible: true` row is grounds to attempt
`set_lock` on that task's `id` — nothing more — and the attempt can still lose to a
concurrent `409`. See also `docs/anti-patterns.md`'s "Selecting from a visible queue
without locking" entry.

### A human names a specific issue/GH-issue-number directly

Selection is exempt from the Hard Rule (above), but **locking is not** — the task still
needs to be claimed before work starts and released when done, or nothing stops a second
host's own `get_next_task` from independently claiming the same still-open item mid-run.

**As of decision 0017, `GET /tasks` replaces the old bounded claim-then-release lookup
dance outright** — that dance (one real `get_next_task` call spent purely to look
something up, released back on a mismatch) existed solely because there was no
side-effect-free lookup (`docs/migration/decisions/0017-task-queue-selection-model.md`,
evidence E3). Procedure now:

1. **Look it up.** Known `queue_task_id`/`impl_order` already recorded (in the issue's
   yaml, or a requirement's `impl_order:` field)? Use it directly. Otherwise,
   `GET /tasks` (optionally `?task_type=issue`) and find the row whose
   `github_issue_number` matches.
2. `set_lock` the matched task's id.
3. Work it, then `release_lock(status: "done")`.

No release-back-to-`open` step exists anymore — a `GET /tasks` lookup never claims
anything, so there is nothing to hand back on a mismatch; a mismatch just means the
lookup found no match, report that and look again rather than chasing further down the
stack.

**Legacy note — recovering from a *pre-2026-08-19* fallback session.** This is a
separate, already-historical scenario from the claim-then-release dance just retired
above (it is about reconciling requirements completed *before* the Hard Rule existed at
all, not about looking up a known issue), and still stands on its own. Before the Hard
Rule existed, a requirement completed in fallback mode still had a real,
already-registered queue task sitting `open`/unlocked if it was registered before the
fallback session (check its `impl_order:` comment in `docs/requirements.yaml` — that's
the queue task id). This reconciliation path is retained only to clean up state from
before the rule changed — it is not a currently sanctioned way to work around the queue.
Do not leave the queue silently out of sync indefinitely: once `$QUEUE_AUTH_TOKEN`
becomes available again (a later session, a different host, a human supplying it),
reconcile by claiming and releasing each affected task —

```bash
# Claiming and immediately releasing (rather than a hypothetical direct-status-write
# endpoint) because letflow-queue deliberately exposes no generic update operation —
# see its README's "Design" section: the core invariant is not an operation count but
# exactly one mutating claim path (get_next_task's atomic UPDATE ... RETURNING), and
# there is still no way to bypass it, even now that GET /tasks exists as a read.
curl "https://queue-test.ai-dala.com/tasks/next?agent_id=orch-reconcile" \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN"
# confirm the returned id matches the REQ's impl_order before releasing
curl -X POST "https://queue-test.ai-dala.com/tasks/<id>/release" \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "orch-reconcile", "status": "done"}'
```

— one task at a time, lowest `impl_order` first, same as normal `get_next_task`
sequencing (this doubles as a live confirmation of *which* task id each REQ actually
mapped to, since `get_next_task` always returns the true lowest-open one — don't assume
`impl_order:`'s comment is correct without this check). This also re-closes each task's
linked GitHub Issue via `release_lock`'s sync (harmless no-op if already closed by
hand). Record the reconciliation in the current run-history volume (find it via
`docs/status/requirement_status.index.yaml`) as an entry with **`req: SCOPE-CHANGE`** and
a normal `event:` value (usually `done`), naming the reconciliation in `note:`. Note the
field: `SCOPE-CHANGE` is a **`req`** value, never an `event` value. An earlier version of
this line said "as a `SCOPE-CHANGE` event" and produced three malformed entries, now
recorded as known anomalies in the index.

---

## Identify a task by queue id AND GH number

*(Added 2026-10-06.)* Queue task ids, GitHub issue numbers and local `ISS-NNNN` numbers are three
independent registries. A message, PR title, branch or handoff that names a task states the **queue
id and the GH number** (`Q-955 / GH #2213`); an ISS or REQ number alone is not an identifier.
When a task is re-registered (stale `depends_on` cannot be edited), the old queue id is marked
blocked and the new id is announced explicitly; never reuse the old one.

`depends_on` cannot be edited after `register_task`. Before registering, read the requirement's
`depends_on` line in full in `docs/requirements.yaml` and map each REQ to its CURRENT queue id; a
wrong mapping forces a re-registration (Q-955/Q-956 and Q-947 each needed one).

## The four mutating functions

`GET /tasks` (above) is the fifth, read-only operation — the four below are the ones
that write. All calls are HTTP requests to the deployed `letflow-queue` instance, bearer-token
authenticated (`Authorization: Bearer $QUEUE_AUTH_TOKEN`, token supplied via
environment — never hardcoded, same convention as REQ-103's dev bootstrap token). This
env var name must match `letflow-queue`'s own `QUEUE_AUTH_TOKEN` exactly (see its
`README.md`'s "Auth" section and `deploy/.env.example`) — an earlier draft of this doc
called it `LETFLOW_QUEUE_TOKEN`, which doesn't match anything the service reads.

**Before concluding the token is unavailable, check both places it may live:**
1. `$QUEUE_AUTH_TOKEN` in the current shell environment.
2. A `QUEUE_AUTH_TOKEN=` line in a `.env` file at the repo root (`./.env`, gitignored,
   not tracked — `grep QUEUE_AUTH_TOKEN .env` if present).

**Both are legitimate sources — check `.env` before treating the queue as unreachable.**
On this workstation's checkout, `.env` carries a working `QUEUE_AUTH_TOKEN` (confirmed
2026-08-19 by a live `get_next_task` call succeeding with it), placed there deliberately
as a sanctioned local-dev convenience (confirmed with the project owner 2026-08-19) —
not a leak: `.env` has never been tracked in git (`.gitignore` covers both the exact
name and `.env.*`), and the token string does not appear anywhere in git history. Skip
this check only if you've confirmed `.env` genuinely doesn't exist or has no such line —
missing that check on 2026-08-19 caused an unnecessary trip into (the now-forbidden)
fallback mode when the queue was in fact reachable the whole time.

Only if **neither** source yields a token is this the genuine unreachable case covered
by the Hard Rule above (report blocked, do not select). Never guess or invent a
substitute value, and never hand-edit `.env` to add a token you don't already have from
one of these two sources.

The secrets-inventory claim below — that the real value is "deliberately not stored on
any developer workstation" per `ai-dala-infra`'s `landscape/secrets-inventory.md`
(entry `letflow-queue-test:QUEUE_AUTH_TOKEN`), living only in
`/opt/apps/letflow-queue-test/.env` on the service host — is now known to be **stale for
this workstation specifically**: a local `.env` copy is sanctioned here as a dev
convenience. Treat the secrets-inventory doc itself as the thing needing an update (out
of scope for this repo) rather than re-deriving policy from this contradiction each
session.

### 1. `register_task` — create a new claimable work item

**Who calls this:** `ORCH` only. Two triggers:
- WF-01 (Requirement Development) reaching its end: once REQ-VALIDATOR passes a new
  requirement, ORCH registers it in the queue (in addition to it already existing in
  `docs/requirements.yaml` — the queue is authoritative for *claiming*, the yaml file
  stays authoritative for full requirement *content* per the schema it already has).
- Any agent discovering new work mid-run (an incidental issue via
  `docs/agents/protocols/ISSUE_QUEUE.md`, a REQ-014-style follow-on) reports it to
  ORCH, which registers it — an individual agent never calls `register_task` directly.

```bash
curl -X POST https://queue-test.ai-dala.com/tasks \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "REQ-011: OIDC/Keycloak integration decision",
    "description": "<full requirement description, or a pointer to it>",
    "acceptance_criteria": ["...", "..."],
    "depends_on": [],
    "stage": "S0",
    "task_type": "requirement"
  }'
```

**`depends_on` takes integer queue task ids, not `REQ-` strings** (established
empirically 2026-08-23, during S5's REQ-148..REQ-175 registration). Every example in
this file happens to show `depends_on: []`, which left the element type unstated. Posting
`"depends_on": ["REQ-058"]` is rejected with `422` / `{"error":"depends_on: is
invalid"}`; `"depends_on": [103]` succeeds. So a batch registration has to resolve each
`docs/requirements.yaml` `depends_on` entry to the queue id of the already-registered
task — its `impl_order`/`id` — which in practice means **registering in dependency
order** and keeping a `REQ-xxx → task id` map as you go. A requirement whose dependency
is not yet registered cannot be registered either; that is a real ordering constraint,
not an incidental one. The failure is loud (422, nothing created), so a wrong format
cannot silently produce a task with a missing dependency edge.

**Cloudflare fronts this service, and it filters by user-agent.** A `POST` from Python's
default `urllib` user-agent returns `403` with Cloudflare `error code: 1010` — *not* a
`letflow-queue` auth failure, and not something a valid `$QUEUE_AUTH_TOKEN` fixes. The
same request via `curl` (or any client sending a normal UA) succeeds. If you get a `403`
whose body is Cloudflare HTML or a bare `error code: NNNN` rather than the service's own
`{"error": ...}` JSON, suspect the client, not the token. `GET /health` succeeding while
a `POST` 403s is the giveaway.

**Optional request field `github_issue_number`** (added 2026-08-21, `letflow-queue` PR #4,
deployed and verified live): when supplied, the service **adopts** that existing GitHub
issue instead of creating a second one. A number already linked to another task is
rejected — `github_issue_number: has already been taken` — rather than re-pointed at the
new task, so adoption can never silently steal another task's issue. Use it only for an
issue that genuinely was filed on GitHub first (a human opened it, or the queue was
unreachable when the finding was made); the default path remains "let `register_task`
create the issue", and `ISSUE_QUEUE.md` step 2a's "do NOT also call `gh issue create`
separately" is unchanged.

`task_type` is **required** — `"requirement"` for planned WF-01 output, `"issue"` for
an `ISSUE_QUEUE.md`-sourced incidental discovery. It drives `get_next_task`'s claim
priority (below); there is no reliable way for the service to infer it after the fact,
so ORCH must state it explicitly on every `register_task` call.

Returns the created task including its `impl_order` (the implementation sequence
number — this is what get_next_task sorts by within a `task_type`, and doubles as the
task `id` used by `set_lock`/`release_lock`).

**Response field `issue_ref`** (added 2026-08-21, same PR #4): `"ISS-"` plus the
zero-padded task id for `task_type: "issue"` — task 187 → `"ISS-0187"` — and `null` for
`task_type: "requirement"`. **This is the issue's id**: `ISSUE_QUEUE.md` no longer derives
issue numbers by scanning `docs/issues/`, because a scan cannot reserve a number and that
convention collided eight times. The queue's `id` is an autoincrement primary key, so it
is allocated atomically across every host. For issue-type tasks the service additionally
rewrites the task title to carry `issue_ref` as a prefix, stripping and replacing any
`ISS-NNNN:` token the caller supplied; only a **leading** token is replaced, so an `ISS-`
reference appearing elsewhere in a title is a genuine cross-reference and survives
verbatim. (Verified live 2026-08-21: a title deliberately prefixed `ISS-0120:` came back
as id 187, `issue_ref` `"ISS-0187"`, title rewritten to `"ISS-0187: ..."`,
`github_issue_number` 375.)

Record it back into the source record so a
human/agent reading the file can cross-reference which queue task it maps to:
- `task_type: "requirement"` → the requirement's entry in `docs/requirements.yaml` (a
  new `impl_order:` field, or a comment — see the migration note below).
- `task_type: "issue"` → **the response's `issue_ref` is the record's filename**:
  `docs/issues/<issue_ref>.yaml`, e.g. `docs/issues/ISS-0187.yaml`, with `id:` inside
  matching it. Its **`queue_ref:`** field carries that task id, prefixed — task `187` is
  written `queue_ref: Q-187`.

  **The id equality this bullet used to assert is SUPERSEDED (2026-09-09).** It read:
  *"carries the same integer — `ISS-0187` ↔ task `187`. That equality is what makes a
  later WF-03 run able to `set_lock` the exact task directly, derivable from the filename
  alone."* Measured across `docs/issues/`, that held for 172 of 305 records — 27
  contradict it (`ISS-0030` is task `Q-76`) and 104 predate the queue. **Never derive a
  `set_lock` target from a filename.** Read `queue_ref` from the yaml; it is correct for
  every record rather than a majority, and `null` there means the issue was never
  registered. Full statement, including the `Q-`/`GH-`/`ISS-` prefixes and the gate that
  enforces them: `ISSUE_QUEUE.md`'s "Numbering schema" section.

**A new issue discovered mid-run still gets a number** — this is the literal
requirement from the design brief. `register_task` is the only source of `impl_order`
values; nothing else assigns them. This applies uniformly whether the new work came
from WF-01 (a planned requirement, `task_type: "requirement"`) or `ISSUE_QUEUE.md` (an
incidental discovery, `task_type: "issue"`) — both funnel through the same
`register_task` call, tagged accordingly.

**An unregistered requirement carries no `impl_order` at all — never a guessed one.**
`impl_order`/`id` on the deployed service are the same integer, so a locally-derived
placeholder (file-max+1, or any other invented number) doubles as a working
`/tasks/<id>/...` URL that addresses whatever unrelated task actually holds that id on
the shared queue. This is not a hypothetical: REQ-109/110/111/112 shipped with
file-max+1 values commented `# letflow-queue task id`, and acting on one of them
(believing it was REQ-109's task) transitioned an unrelated open task to `done` and
closed the wrong GitHub issue (ISS-0092/GH#314). If a requirement has not yet been
through `register_task`, record the deferral as a comment line
`# impl_order: UNREGISTERED -- <rationale>` at the entry's own field indentation, rather
than filling it with a placeholder that reads as a real id. The marker and a non-empty
rationale after `UNREGISTERED` are **mandatory**: bare absence of any `impl_order` line is
an error condition, not a second legal form, and
`mix letflow.check_requirements_registration` fails on it (R1) — a deferral nobody
recorded a reason for is indistinguishable from an oversight, which is the condition
ISS-0221 was filed about.

**A deferral also goes stale, and staleness is now gated (ISS-0258).** Recording a reason
is necessary but not sufficient: a rationale that was true when written stays green
forever unless something re-checks it against the world, which is the ISS-0221 failure
mode one layer up. `mix letflow.check_deferral_staleness` supplies the missing invariant.

- **The rule.** A deferral is **stale** once its stage becomes active. A stage is
  *active* iff at least one requirement assigned to it — excluding the deferred entry
  itself — has `status` `done`, `in_progress`, or `blocked`. `pending` and `cancelled`
  confer no activity (abandonment is not activity), and a stage with no requirements is
  inactive. A stale deferral **fails the run**, naming the `REQ-NNN`, its stage, and the
  sibling ids whose status made the stage active. A deferral pending a not-yet-active
  stage stays green and is merely reported — the visible-debt principle is unchanged;
  only its never-expiring half is.
- **A deferred entry must carry a `stage:`.** Without one, its staleness is undecidable,
  and an undecidable deferral is a violation rather than the benefit of the doubt.
- **Scoping a deferral to a sibling requirement instead of a whole stage** uses a
  recognised prefix inside the same rationale — no new field:

      # impl_order: UNREGISTERED -- blocked-by: REQ-042 -- waiting on the token kernel

  The prefix must be **anchored at the start of the rationale**, the named id must exist
  in `docs/requirements.yaml`, it may not be the entry's own id, free-text rationale after
  it is still required, and `blocked-by:` references may not form a cycle. The scope
  **expires on its own**: once `REQ-042` is `done` or `cancelled`, the deferral is stale
  again. It is a machine-checkable assertion, not an exemption — there is no exception
  list, no grandfathering, and no allowlist of any kind.

**As of the `issue_ref` change this warning has a second reason:** for
`task_type: "issue"`, a guessed id is also a guessed *filename*. Inventing a number now
produces a `docs/issues/ISS-NNNN.yaml` that can collide with another host's record on the
exact path — the failure class documented twice in `docs/anti-patterns.md` — *and* a
`/tasks/<id>/...` URL addressing an unrelated task. Only `register_task`'s response
supplies either.

### 2. `get_next_task` — claim the next eligible task

**Who calls this:** `ORCH` only, when asked for unscoped work ("what's next," "keep
going") or before dispatching a workflow. This replaces the old "pick the first
`pending` requirement whose `depends_on` are all `done`, in file order" instruction —
the service now does that filtering, atomically, across every host.

```bash
curl -X GET "https://queue-test.ai-dala.com/tasks/next?agent_id=$HOSTNAME-orch" \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN"
```

Claim priority is **two-tier**, by `task_type`:
1. If any eligible (`open`, unlocked, `depends_on` satisfied) `task_type: "issue"` task
   exists, the **newest** one (highest `impl_order`) is claimed — issues jump the line,
   most recently discovered first.
2. Only once no eligible issue remains does it fall through to `task_type:
   "requirement"`, claimed in the original **lowest-`impl_order`** (oldest-first) order.

In other words: drain issues LIFO before touching the requirement backlog, then work
the requirement backlog FIFO exactly as before this priority split existed.

- `agent_id` should be stable per host (e.g. hostname or a configured identifier) so a
  lock is attributable and `set_lock`/`release_lock`'s re-lock-by-same-agent semantics
  work as intended across a host's own restarts.
- 200 with the task body → claimed, locked to this `agent_id`. Proceed to route it
  through the matching workflow (WF-02/03/04/05, per
  `docs/agents/ORCHESTRATOR.md` §3).
- 404 `no_eligible_task` → nothing claimable right now (either the queue is empty, or
  every open task's dependencies aren't done yet, or everything open is already
  locked). Report this plainly — it is not an error to work around.

**Drain/loop mode does not change this contract — see `ORCHESTRATOR.md` §4a for the
full continuous-processing rule.** Each loop iteration is exactly one fresh
`get_next_task` call claiming exactly one task, identical to a non-looped invocation;
decision 0017's eligibility/selection rules are evaluated fresh every time. **There is
no batch-claim mode, and none is to be invented:** an agent in drain mode MUST NOT
pre-claim or lock more than one task ahead of the one it is actively working, whether
via repeated `get_next_task` calls stacked before dispatching the first, via `GET
/tasks` + multiple `set_lock` calls, or by any other means. "So I don't have to ask
again" is not a reason to hold more than one lock at a time — drain mode's "don't pause
to ask" guarantee is delivered by looping the single-claim call, not by claiming ahead.

### 3. `set_lock` — lock a task you already know the id of

**Who calls this:** `ORCH` only. Three legitimate uses:
- **Recovery** — re-claiming a task this same host already held before a crash/restart,
  using the same `agent_id`. Not gated on eligibility at all (see check 1 below) — this
  branch always succeeds, even if the task's status has since changed to non-`"open"`.
- **Targeted claim of a known-id task named directly by a human** — see "A human names a
  specific issue" above. **This is not merely a recovery mechanism at the API level**:
  per `letflow-queue`'s own `README.md`, the service accepts any `agent_id` on an
  unlocked task, not only one that previously held it — "Unlocked, or already locked by
  the same `agent_id` → `200`... Locked by a *different* `agent_id` → `409 Conflict`."
  This corrects an earlier draft of this doc, which undersold `set_lock` as
  recovery-only and left no documented way to target-claim a specific already-known task
  id outside the `get_next_task` priority order (2026-08-20, ISS-0086/GH#303's own
  resolution run).
- **Targeted claim of a task chosen from `GET /tasks`** (decision 0017 §C, added
  2026-09-04) — an agent may select any eligible task it can see via `GET /tasks` and
  claim it here. Seeing the task is never itself authorization to work it; `set_lock` is
  what actually arbitrates the choice, by applying the eligibility check below.

```bash
curl -X POST https://queue-test.ai-dala.com/tasks/42/lock \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "'"$HOSTNAME"'-orch"}'
```

Checked, strictly in this order against the loaded task and the caller's `agent_id`
(`letflow-queue`'s own `set_lock/2`; decision 0017 §D added check 3):

1. **Same-agent recovery.** If the task is already locked by this same `agent_id`, the
   lock is set/refreshed and `200` is returned unconditionally — not gated on
   eligibility at all (e.g. reacquiring your own lock after a crash, even if the task's
   status has since changed to non-`"open"`).
2. **Locked by a different agent.** Else, if the task is locked by any other `agent_id`,
   `409 Conflict`: `{"data": null, "error": "task is locked by a different agent"}`.
   Checked *before* eligibility, so a task that is both locked-by-another and ineligible
   still reports this reason, not the eligibility one.
3. **Eligibility (decision 0017 §D, added 2026-09-04).** Else (the task is unlocked),
   the task must be `status: "open"` and have no unmet `depends_on` ids — the same
   predicate `get_next_task`/`GET /tasks`'s `eligible` field use. Acceptable when
   `get_next_task` was the only selector, because the predicate had already been applied
   before a task was ever handed out; once agents select for themselves via `GET /tasks`
   this becomes the load-bearing gate. If unmet, `409 Conflict`:
   ```json
   { "data": null, "error": "task is not eligible to be locked", "unmet_dependency_ids": [12, 14] }
   ```
   `unmet_dependency_ids` is `[]` when the sole cause of ineligibility is non-`"open"`
   status.

Unknown task id → `404`: `{"data": null, "error": "task not found"}`.

**A `409` from either check 2 or check 3 means pick a different task. It is NEVER routed
around with `release_lock`'s `force` override** (decision 0017 §E). `force` remains
scoped to its existing "unstick a task after a host died mid-work" purpose (see
`release_lock` below) — it was never about eligibility, and this is called out
specifically because free selection via `GET /tasks` makes forcing past a `409` more
tempting than it was when `get_next_task` was the only selector.

**This only works if the id is already known.** There is no lookup-by-title endpoint —
`GET /tasks` (above) is the read-only way to learn an id from `github_issue_number`,
`status`, `task_type`, or `stage`; the service's core invariant is not an operation count
but exactly one mutating claim path (`get_next_task`'s atomic `UPDATE ... RETURNING` —
see its own README's "Design" section), which `GET /tasks` does not weaken since it
performs no write at all. The id itself has to come from a prior `register_task`
response (now recorded as `queue_task_id` in `docs/issues/ISS-NNNN.yaml` or as
`impl_order` in `docs/requirements.yaml`, per `ISSUE_QUEUE.md`'s 2026-08-20 update), from
a `GET /tasks` listing, or from having seen it in a prior `get_next_task`/`set_lock`
response.

### 4. `release_lock` — release a claim, optionally transitioning status

**Who calls this:** `ORCH` only, at two points:
- **Normal completion:** after a workflow's Step Final (git-merge) returns PASS, release
  the lock with `status: "done"`.
- **Recovery/override (the "two last functions are for you, if something will go
  wrong" case from the design brief):** if a task is stuck locked by a dead/unreachable
  host (e.g. a run that crashed mid-work and never released), ORCH may release it with
  `force: true` — but only after confirming, as best it can, that the original run is
  genuinely dead (no active handoff, no recent activity) rather than just slow. State
  the reasoning in the handoff/log entry when using `force`.

**`status: "done"` means the issue/requirement is resolved, not that the run merely
finished cleanly.** This distinction matters because `status: "done"` best-effort
closes the linked GitHub Issue (see "GitHub Issues visibility" below) — closing it is a
claim that the underlying defect is fixed or the requirement is delivered, read by
every future run and by the human skimming closed-issue state. A WF-03 run that
completes its Step Final PASS gate by producing a *diagnosis*, a *triage/re-scoping*, or
an *attempted-and-reverted fix with recorded evidence* has finished cleanly as a run,
but has NOT resolved the issue — release it WITHOUT a `status` (leaving it `open`,
per the hand-back path below) so the GitHub mirror stays open too. Confusing "the run
finished" with "the issue is resolved" caused three issues (#360/#366/#367, ISS-0108/
ISS-0112/ISS-0113) to be auto-closed by a `status: "done"` release out from under a
closing comment that itself said "left open, not fixed" — see ISS-0277's resolution
for the full account. Before calling `release_lock(status: "done")`, confirm the
run's own final report describes a shipped fix or delivered requirement, not an
investigation, partial finding, or reverted attempt.

**`status: "blocked"` means the run reached a genuine, stable terminal stop that is NOT
a resolution — use it for a WF-03 Step 5 outcome recorded as `instrumented` or
`no_defect` (see `docs/agents/protocols/ISSUE_QUEUE.md`'s "Issue status vocabulary").**
Both of those statuses assert the run investigated the issue to completion and reached a
real, evidence-backed verdict, but neither asserts the underlying defect was fixed —
`instrumented` ships verified diagnostic work with the root cause still open (and a
required `superseded_by:` pointer); `no_defect` establishes there was no root cause to
remove. Releasing either outcome with `status: "done"` is wrong for the same reason bare
no-status release is wrong for a hand-back: it either falsely claims resolution
(`"done"`'s documented meaning, above) or leaves the task `open` and immediately
re-claimable by the very next `get_next_task` call — for `task_type: "issue"` tasks
specifically, `get_next_task`'s LIFO issue-priority claim order (see function 2, above)
means an `open`, already-fully-investigated issue-type task is re-claimed ahead of every
other open task, producing a re-selection loop for any automated session that doesn't
special-case it (this is exactly what happened live, 2026-09-04, to queue task
458/ISS-0458 — see that record's own account).

`status: "blocked"` avoids both failure modes: it excludes the task from every future
`get_next_task` eligibility check (the claim query filters `WHERE t.status = 'open'`
only — a `blocked` row can never match), so there is no re-selection loop, and it does
NOT best-effort-close the task's linked GitHub Issue (only a release whose resulting
status is literally `"done"` triggers that; `"blocked"` is a pure passthrough) —
appropriate, since an `instrumented`/`no_defect` outcome typically still wants the
GitHub issue's own Step 5 close-with-comment procedure to run on its own terms (see
`WF-03_issue_resolving.md` Step 5), not the queue's best-effort side-closure.

**What `status: "blocked"` does NOT assert:** despite the English word's ordinary sense
("stuck, waiting on something, needs action" — the same sense this doc itself uses at
"report blocked, do not select," above), a queue task released with `status: "blocked"`
under this convention is NOT necessarily stuck or actionable. It means "terminally
stopped, not resolved" — a deliberately reused existing enum value, not a new state
invented for this meaning. Do not read `status: "blocked"` in queue task listings as
"this needs attention" without also checking the linked `docs/issues/ISS-NNNN.yaml`
record's own `status:` field (`instrumented` or `no_defect`) for what it actually means;
the queue's bare three-value status field cannot distinguish a genuinely-stuck-and-
actionable task from a genuinely-terminal one on its own today.

```bash
# Releasing an instrumented/no_defect WF-03 outcome:
curl -X POST https://queue-test.ai-dala.com/tasks/42/release \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "'"$HOSTNAME"'-orch", "status": "blocked"}'
```

```bash
curl -X POST https://queue-test.ai-dala.com/tasks/42/release \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "'"$HOSTNAME"'-orch", "status": "done"}'
```

```bash
# Force-release a task stuck locked by a dead host:
curl -X POST https://queue-test.ai-dala.com/tasks/42/release \
  -H "Authorization: Bearer $QUEUE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"force": true}'
```

A task released without a `status` stays `open` and immediately becomes claimable
again by any host (used for a genuine hand-back, e.g. `PARTIAL` result that needs a
different approach — see `docs/agents/ORCHESTRATOR.md` §5's rework rules; rework still
happens within the same locked task/run in the common case, this release path is only
for a full hand-back to the pool).

---

## Who calls what — division of responsibility

| Role | Calls `letflow-queue` directly? |
|---|---|
| `ORCH` | Yes — all five operations (the four mutating functions plus `GET /tasks`), per the triggers above |
| Every other role (`ELIXIR-DEV`, `REVIEWER`, `TEST-RUNNER`, etc.) | **No.** They receive the task's content via the handoff ORCH writes (same as today — the handoff schema in `docs/agents/shared/HANDOFF_PROTOCOL.md` already carries `context.requirement_ids` and `task.description`). Producing/validating agents never call the queue API and never read `docs/requirements.yaml` to pick their own next task. |

This mirrors the design brief's framing directly: "AI agents manipulate files on their
discretion" is exactly the failure mode being closed. Only ORCH — the one role with no
implementation authority of its own (`docs/agents/AGENT_SYSTEM.md` §3: "Never writes
application code itself") — touches the queue.

---

## `docs/requirements.yaml`'s role going forward

Unchanged in schema (`id`/`title`/`owner`/`status`/`stage`/`description`/
`acceptance_criteria`/`depends_on`) but changed in authority: it is now a **mirror**,
kept in sync by ORCH/DOC-UPDATER, not a file any agent reads to decide what to do next.
Concretely:

- `register_task`'s response `impl_order` gets written back into the matching
  requirement's entry (new field, or a note — DOC-UPDATER's job, same append-discipline
  as everything else in `core-directives.md`).
- The requirement's `status` field is still flipped `pending → in_progress → done` by
  DOC-UPDATER as before (Step 6) — this reflects reality for humans reading the repo,
  but the queue's own `status` field (`open`/`done`/`blocked`) is the one that actually
  gates `get_next_task`.
- **Fallback selection is forbidden as of 2026-08-19** (see the Hard Rule section
  above) — even a single-host or deliberately-disconnected session must not read
  `docs/requirements.yaml` to pick unscoped work; the queue's unreachability is a
  blocked state to report, not a mode to switch into. Reading the file for *content*
  once a task id is already known (citing a REQ's description, acceptance criteria,
  `depends_on` for cross-linking) is unaffected — this rule is about selection only.

---

## Deployment status

`letflow-queue` is deployed and live at `https://queue-test.ai-dala.com` (`ai-dala-infra`'s
`T-0107`/`T-0108`, both `done` as of 2026-08-15). The S0/MVP-1 backlog (REQ-010..014,
REQ-101..108) is registered — see `docs/status/requirement_status.yaml`'s (volume 1,
closed) entries with `req: SCOPE-CHANGE` for the full REQ-ID ↔ queue-task-id mapping.
A prod deployment (`queue.ai-dala.com`) is not yet planned — test only, per T-0107's notes.

The `task_type` field and its two-tier `get_next_task` claim priority (issue-vs-
requirement, above) shipped 2026-08-17 (`letflow-queue` PR #1) and are live on
`queue-test.ai-dala.com`; every pre-existing row was backfilled by that migration
(`stage IS NOT NULL` → `"requirement"`, else `"issue"`).

## GitHub Issues visibility (not a control path)

`letflow-queue` mirrors tasks to GitHub Issues on `tvolodi/letflow` for human visibility
— **this is display-only, not a second control mechanism.** The "no agent discretion"
rule above still holds in full: an agent must never read or act on a GitHub Issue to
select or lock work.

- `register_task` best-effort creates a GitHub Issue (title = task title, body =
  description + acceptance criteria) and stores the returned issue number on the task.
  If GitHub is unreachable or `GITHUB_TOKEN`/`GITHUB_REPO` isn't configured on the
  service, task registration still succeeds — this never blocks the core function.
- `get_next_task` best-effort pulls open GitHub Issues first and imports any not yet
  tracked (by issue number) as new tasks, before running its claim query — so an issue
  opened directly on GitHub becomes claimable without anyone calling `register_task`
  by hand. Imported tasks get `depends_on: []` (GitHub issues have no queue-native way
  to express a dependency yet — a known limitation, not solved here), a generic
  single-item `acceptance_criteria` pointing at the issue body (no markdown parsing),
  and `task_type: "issue"` (a raw GitHub Issue is always incidental — it jumps ahead of
  the requirement backlog per `get_next_task`'s priority above).
- `release_lock` with `status: "done"` best-effort closes the linked GitHub Issue.

**As of this writing, nothing files issues directly against `tvolodi/letflow` for
`letflow-queue` to pull in** — the import direction exists and is tested, but the
project intentionally isn't using it yet ("let it appear when the system is more or
less ready," per the design conversation). Treat it as available, not yet exercised.

See `letflow-queue`'s own `README.md` for the exact request/response shapes.
