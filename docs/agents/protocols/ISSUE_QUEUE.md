# ISSUE_QUEUE Protocol — SUPERSEDED by the work board

> **Do not follow this file's filing procedure.** Incidental findings are filed as GitHub
> issues by the sole filer, using `.github/ISSUE_TEMPLATE/work_item.md`, after the overlap
> check: [`WORK_BOARD.md`](WORK_BOARD.md) section 7. A bare number is still never an
> identifier, but the registries are now two: the **GH number** (machine id; new local
> records are `docs/issues/GH-<n>.yaml`) and the legacy `ISS-NNNN` / `Q-N` ids, which stay
> as history. `queue_ref` and `impl_order` lines are kept, not rewritten.
> Decision: `docs/migration/decisions/0049-work-board-replaces-letflow-queue.md`.
>
> What below still describes a **local issue record** (the status vocabulary, and the rule
> that closing needs evidence) remains the meaning of those yaml fields. Everything about
> the queue's registration call, its locks and queue ids is history.

## History (kept unedited; the queue-era procedure as it stood until cutover)

---


**Function:** `fn:enqueue-issue`
**Read by:** every agent
**Used in:** any step that discovers a defect outside its own current scope

## Purpose

A run does one job and does it completely: git-setup once, the run's own steps,
git-merge once. A defect discovered *incidentally* — not the thing the run was
dispatched to fix — is filed and forwarded to become its own later run, rather than
silently expanding the current run's scope or being dropped.

This is distinct from `core-directives.md`'s Unblock-Everything directive: that covers
defects that block *this run's own* acceptance criteria (fix them now, in this run).
This protocol covers defects that are merely adjacent — noticed, not blocking.

## Numbering schema — three registries, three prefixes (2026-09-09)

**A bare number is never an identifier.** Writing "issue 89" is ambiguous across three
registries that all number from 1 and are all live at once. Every reference carries its
registry's prefix, in prose and in yaml alike:

| Prefix | Registry | Authoritative for | Where it lives |
|---|---|---|---|
| `ISS-NNNN` | **local** | the full record — diagnosis, evidence, resolution | `docs/issues/ISS-NNNN.yaml` |
| `Q-N` | **letflow-queue** | *claiming* — who is working on it right now | the queue service |
| `GH-N` | **GitHub** | human-visible mirror, cross-machine discussion | github.com issues |

Read `GH-89` as "GitHub issue 89", `Q-76` as "queue task 76". Never `#89` and never a
bare `89`.

### The three numbers are independent. Do not compute one from another.

This section exists because the opposite was once true and is no longer. An earlier
version of this protocol stated that `ISS-NNNN` **is** the queue task id — "ISS-0187 is
queue task 187" — and invited deriving a `set_lock` target straight from a filename.

Measured against the corpus on 2026-09-09, that equality holds for **172 of 305** local
issue files. **27 contradict it outright** (`ISS-0030` is queue task `Q-76`;
`ISS-0109` is `Q-172`), and **104 predate the queue entirely** and have no queue id at
all. The rule was true for the window in which queue-allocated ids were the only source
of new issue numbers, and it silently stopped being true afterwards.

**So: never derive. Always read the explicit field.** A number's registry is part of the
number; the mapping between registries is data, not arithmetic.

### Field names

Exactly two cross-reference fields, both carrying a prefixed value:

```yaml
id: ISS-0030          # this record's own id, matching the filename
queue_ref: Q-76       # or null, with a comment saying why
github_ref: GH-89     # or null, with a comment saying why
```

`null` is a legitimate value and means "this issue is not in that registry" — a
local-only finding, or one filed before the queue existed. It must carry a comment
saying which. The superseded field names `github_issue`, `github_issue_number` and
`queue_task_id` were normalised to the two above across all 305 files in one pass;
do not reintroduce them. Prose fields such as `github_issue_note` are unaffected —
they are commentary, not identity.

### Enforced, not merely documented

`mix letflow.check_issue_refs` fails on a bare-number cross-reference, an unprefixed
field name, or a malformed ref, and is wired into `mix letflow.check`. The equality
rule this section replaces was *also* documented, and documentation alone did not keep
it true — which is this project's own producer/validator principle applied to its
own conventions.

## Filing step 0 — overlap check and next-free number (before `register_task`)

*(Added 2026-10-06: ISS-0994 duplicated ISS-0993 at filing time, ten minutes apart; and the
queue's `issue_ref` has repeatedly collided with an existing local `docs/issues/ISS-NNNN.yaml`.)*

Before ORCH calls `register_task` for a finding, it checks, and records the result in the
issue text, all four of:
1. **Queue:** an existing task with the same symptom (`GET /tasks`, read-only).
2. **GitHub:** an existing issue with the same symptom (`gh issue list --search ...`).
3. **Open PRs:** `gh pr list` plus each PR's changed files, since someone may already be
   fixing or filing it.
4. **`main`:** `docs/issues/` and the code (the defect may already be fixed).

If a duplicate or an in-flight fix exists, add a comment to it instead of filing.

**Local numbering.** The queue's `issue_ref` is NOT guaranteed to be a free local number.
Before writing `docs/issues/<issue_ref>.yaml`, check that the filename is free on `main`, on
every open PR (`gh pr view N --json files`) and on remote branches. If it is taken, pick the next
free `ISS-NNNN`, keep the queue's number in `queue_ref` with a comment (the ISS-0950 / ISS-0987
precedent), and always identify the work by **queue id + GH number**, never by an ISS number alone.

## Procedure

**Updated 2026-08-20 (ISS-0086/GH#303's own resolution run).** Steps 2-3 previously
had the discovering agent call `gh issue create` directly, with no `letflow-queue`
registration anywhere in this protocol. That was written before `letflow-queue`
existed and was never reconciled with `TASK_QUEUE.md` once it landed — the result was
that every issue filed this way (including ISS-0086 itself) entered the queue only
*opportunistically*, as a side effect of some later `get_next_task` call's GitHub-import
step, if at all. A WF-03 run resolving such an issue had no reliable way to find or lock
its queue task, meaning nothing actually prevented a second host from independently
claiming the same open GitHub issue and duplicating the fix — see
`docs/anti-patterns.md`'s matching entry. Steps 2-3 below now route through
`register_task` instead, per `TASK_QUEUE.md`'s "who calls what" division (only `ORCH`
calls the queue — the discovering agent reports the finding, it does not call `gh` or
the queue itself).

**Updated 2026-08-21 (ad-hoc run ADHOC-20260821-001).** Step 1 previously said to assign
the id by scanning `docs/issues/` for the highest existing `NNNN` and incrementing. **That
instruction is removed.** It was a read-then-write race with no lock between the halves,
and it collided eight times across concurrent sessions — see `docs/anti-patterns.md`'s two
`ISS-NNNN` collision entries and the update appended to the second of them. The id is now
allocated by `letflow-queue`, atomically, and returned as `issue_ref`. Do not scan, do not
increment, do not guess.

```
1. Do NOT derive the id. The discovering agent does not pick a number, and neither does
   ORCH. The id comes back from `register_task` in step 2a as the response field
   `issue_ref` (e.g. task id 187 -> "ISS-0187"), and the local record is written to
   docs/issues/<issue_ref>.yaml in step 3. Until step 2a has returned, this finding has
   no id — refer to it by title.

2. The discovering agent reports the finding to ORCH (title, description, severity,
   affected_files) — it does not call `gh` or letflow-queue itself. ORCH then:

   a. If letflow-queue is reachable ($QUEUE_AUTH_TOKEN via shell env or ./.env — see
      TASK_QUEUE.md's "Before concluding the token is unavailable" check; verify
      reachability with `GET /health`, never with `get_next_task` — see TASK_QUEUE.md's
      Reachability checks note):

      register_task(title, description, acceptance_criteria: ["See linked GitHub
        issue for full description"], task_type: "issue")

      The response carries `issue_ref` — "ISS-" plus the zero-padded task id (task 187
      -> "ISS-0187"). THAT IS THE ID. For issue-type tasks the service also rewrites the
      task title to carry that ref as a prefix, stripping and replacing any "ISS-NNNN:"
      the caller happened to supply; only a LEADING token is replaced, so an ISS-
      reference elsewhere in a title is treated as a genuine cross-reference and survives
      verbatim. (Verified live 2026-08-21: a call whose title deliberately began
      "ISS-0120:" came back as id 187, issue_ref "ISS-0187", title rewritten to
      "ISS-0187: ...".)

      This best-effort creates the mirrored GitHub Issue itself (per TASK_QUEUE.md's
      "GitHub Issues visibility" section's `register_task` bullet) — do NOT also call
      `gh issue create` separately, that would double-post. **That instruction still
      stands unchanged.** Record the response's `id` and `github_issue_number` into the
      yaml's `queue_ref` and `github_ref` fields, **prefixed** — id `76` is written
      `queue_ref: Q-76`, GitHub issue `89` is written `github_ref: GH-89`. Write the
      numbers the response actually returned; do not assume any of the three ids
      match each other (see "Numbering schema" above).

      **Adoption path — an issue that genuinely was filed on GitHub first** (e.g. by a
      human, or by an agent under the pre-2026-08-21 order): pass the existing issue's
      number as the optional `github_issue_number` request field. The service adopts that
      issue instead of creating a second one. A number already linked to another task is
      rejected ("github_issue_number: has already been taken") rather than re-pointed at
      the new task — verified live 2026-08-21 against an already-linked number. This is
      the only sanctioned way an issue's GitHub record precedes its `register_task` call;
      it is not a licence to go back to calling `gh issue create` first.

   b. If letflow-queue is unreachable (genuinely, both token locations checked): there is
      no allocator, and therefore **no id** — a locally-derived number is exactly the
      thing this protocol just removed. Do not scan-and-increment to fill the gap. File
      the finding in your handoff's `result.issues` (severity as discovered) and report
      it to ORCH, which registers it once the queue is reachable and writes the record
      then; the finding is not lost, it is just not yet numbered. If ORCH judges the
      finding must be visible on GitHub before then, per core-directives.md's "No Issue
      Left Local-Only", `gh issue create --title "<title>" --body "<description>

      Discovered by <AGENT_ID> during <run-id>.
      Local record: not yet allocated — letflow-queue unreachable at filing time."` is
      the interim step, and the resulting issue number is later adopted via the
      `github_issue_number` field in 2a so it never becomes a duplicate.

3. Write docs/issues/<issue_ref>.yaml — the filename comes from step 2a's `issue_ref`,
   not from anything on disk:
   id: <issue_ref>          # e.g. ISS-0187, matching the filename exactly
   title: <one-line summary>
   discovered_by: <AGENT_ID>
   discovered_in_run: <run-id>
   discovered_at: <UTC timestamp from the clock>
   severity: BLOCKER | MAJOR | MINOR
   description: >
     <what's wrong, where, and why it matters>
   affected_files:
     - <path>
   queue_ref: Q-<id>     # from register_task's response per step 2a, PREFIXED.
                         # Not derivable from this file's own id -- read the response.
                         # `null` (with a comment saying why) if never registered.
   github_ref: GH-<n>    # from the same response's github_issue_number, PREFIXED.
                         # `null` (with a comment saying why) if it has no GH mirror.
   status: open

4. Commit docs/issues/<issue_ref>.yaml as part of the current step's normal commit.

5. Do NOT extend the current run to fix it. Do NOT launch a nested workflow. The
   current step's own PASS/FAIL verdict is unaffected by an incidentally-discovered
   issue — only issues that ARE the current step's own failure drive that step's
   rework.
```

## Where the id comes from (2026-08-21) — and what this supersedes

**The id is allocated, not chosen.** `letflow-queue`'s task `id` is an autoincrement
primary key, so it is handed out atomically by the one service every host shares. No two
hosts can receive the same one, which is precisely what a directory scan could never
guarantee: a scan reads state, it does not reserve it. The eighth collision
(`WF03-ISS0106-20260821`, records now at `docs/issues/ISS-0118.yaml` and
`ISS-0119.yaml`) is the proof — that run scanned `docs/issues/` across *every remote
branch* before choosing, which is exactly the mitigation `docs/anti-patterns.md`
prescribed, and it collided anyway, because the numbers it collided with did not exist on
any branch at the moment it looked.

**Two consequences worth stating outright.**

**1. The old "local record first, GitHub issue second" advice is superseded.**
`docs/anti-patterns.md`'s first ISS-collision entry says: *"File the local record before
opening the GitHub issue, and put the id in the GH title. A GH issue whose body cites a
local file that has since been overwritten is the worst end state."* Under this protocol
the order is inverted — `register_task` creates the GitHub issue as part of allocating the
id, so the GitHub issue exists *before* `docs/issues/<issue_ref>.yaml` is written (step 2a
then step 3, same agent turn). That is now the safer order, for three reasons, and the old
advice is not merely overridden by fiat:

- **The overwrite hazard it guarded against was a consequence of guessed numbering, not of
  ordering.** The local file could be silently overwritten only because two agents could
  pick the same filename. They can't any more — the filename comes from an allocated id.
  Remove the collision and the "worst end state" it described cannot arise.
- **The id can no longer be wrong.** Writing the local record first was a way of pinning a
  number down before publishing it. The number is now pinned by the allocator, and the
  local record is written *from* it rather than the other way around.
- **The id lands in the GitHub title automatically.** The old advice depended on an agent
  remembering to type the id into the GH title; the service now rewrites an issue-type
  task's title to carry `issue_ref` as a prefix, so the two records agree by construction
  rather than by diligence.

The historical entries in `docs/anti-patterns.md` stay as written — they are the record of
how this was learned. Only the *forward instruction* in them is superseded, and that is
recorded in the update appended to the second entry.

**2. ~~`queue_task_id` and the issue id are the same integer.~~ SUPERSEDED 2026-09-09 —
see "Numbering schema" above.** This clause used to read: *"`ISS-0187` is queue task
`187`. A later WF-03 run can therefore derive the `set_lock` target straight from the
filename."*

That derivation is **now forbidden**, because the equality is false for 133 of 305 local
issue files: 27 contradict it outright and 104 predate the queue. It was true only for
the window in which queue-allocated ids were the sole source of new issue numbers, and
nothing re-checked it once that stopped being so.

What survives, and is now the only supported access path: **read `queue_ref` from the
yaml.** It is the explicit, machine-readable link, it is what pre-2026-08-21 records
always relied on, and it is correct for every record rather than for a majority of them.
A `null` there means the issue was never registered — handle that case rather than
computing a number that will lock the wrong task.

### Issue numbers are non-contiguous from here on — this is expected

The hand-numbered range ends at **ISS-0119**. Queue-allocated ids start in the **ISS-0186
and upward** range, so **there are no ISS-0120..ISS-0185 records and never were** — nothing
is lost or missing. Ids will stay non-contiguous thereafter, because the queue's id
sequence is shared with `task_type: "requirement"` tasks: every requirement registered
between two issues consumes a number that no `ISS-` file will ever carry. A gap in
`docs/issues/` is not evidence of a deleted or misplaced record. (Existing hand-numbered
records keep their numbers — nothing is retro-renumbered.)

## Issue status vocabulary

`docs/issues/ISS-NNNN.yaml`'s `status:` field. This is the canonical list — WF-03 and
every other reader point here rather than restating it.

- `open` — filed, not yet being worked.
- `in_progress` — a run has locked it and is working it.
- `resolved` — **a root cause was actually removed**, and a regression test proves it.
  Shipping useful, verified work is *not* the same thing. This registry is read by later
  runs as a factual record of what is and is not still broken, not as a progress report,
  so `resolved` on an issue whose defect still exists silently misinforms every run that
  cross-references it.
- `instrumented` — the run built and verified real improvements (typically diagnostic
  capability), and that run's own acceptance criteria were met, but the underlying
  defect's **root cause is not removed and the issue is not fixed**. An `instrumented`
  record MUST carry `superseded_by: ISS-NNNN` naming the successor issue that carries the
  remaining work, so it can never be a dead end; file that successor before transitioning
  the record. State plainly in the record what the shipped work does *not* close.
  Release the queue task with `release_lock(status: "blocked")`, not `"done"` and not
  no-status — see `TASK_QUEUE.md`'s release_lock section for why.

- `no_defect` — **the issue was investigated and measured, and there was no root cause
  there to remove.** Terminal, like `resolved`, but it asserts a different thing and must
  never be used in place of it: `resolved` says a defect existed and was removed, with a
  regression test proving it; `no_defect` says the investigation established that the
  defect the record alleged does not exist. Nothing here relaxes `resolved`'s bar by a
  hair — that definition stands exactly as written above, and this status exists so that a
  no-defect outcome stops being tempted to borrow it. `no_defect` is not "we found
  nothing"; it is a positive, falsifiable claim about reality — *checked, measured, not
  there* — and a `no_defect` record claimed without the measurement to back it misinforms
  every later run that cross-references this registry, exactly as a false `resolved` does.

  **The evidence bar is the same discipline as the other two, not a lower one.** A
  `no_defect` record MUST carry — in the issue file, citing the closing run's diagnosis
  handoff by path — all four of:

  1. the **first-hand measurement** that was run, with the producing code or command
     quoted and real figures given. Figures inherited from the issue's own filing, or from
     another run, do not count; `HANDOFF_PROTOCOL.md` §1.1 applies, and if the
     re-measurement disagrees with the filing, the measurement wins and the record says
     so.
  2. the **specific candidate mechanisms tested**, named individually, each with its
     result — *including* the ones the data did not support. A verdict that reports only
     what was checked, and not what was looked for and not found, is not this status.
  3. the **stated limitations of the method**, so a later reader can weigh the negative
     result instead of inheriting it as settled. A negative result that hides the weakness
     of the test that produced it is worth less than no record at all.
  4. the **run-id and timestamp** of the run that reached the verdict, recorded under the
     key pair `verdict_in_run:` / `verdict_at:` — **not** `resolved_in_run:` /
     `resolved_at:`, which assert a resolution that a `no_defect` record explicitly did
     not perform and would re-introduce the false claim this status exists to prevent, and
     **not** `closed_in_run:` / `closed_at:`, because `closed_at:` already carries a
     different meaning in this registry — the moment GitHub closed the mirrored issue
     (`ISS-0109.yaml`) — and one key name with two meanings distinguished only by nesting
     depth is not readable by the mechanical linter ISS-0191 specifies. `verdict_at:` is
     when the run reached its verdict, which is not the same event as the GitHub close.

  Release the queue task with `release_lock(status: "blocked")`, not `"done"` and not
  no-status — see `TASK_QUEUE.md`'s release_lock section for why.

  This is deliberately the hardest of the three to earn cheaply, because it is the one an
  uninvestigated issue would most like to take. An issue nobody investigated cannot reach
  `no_defect`: with nothing to quote under (1)–(3) there is nothing to write, and a record
  that says only "looked, seemed fine" has not reached a terminal status at all — it is
  still `open`.

  **WF-03 and this vocabulary now agree.** WF-03 Step 1 has always licensed a reasoned
  NO-CHANGE verdict as a legitimate outcome, and WF-03 Step 5 already points at this
  section as the canonical status list — but until now that list offered a NO-CHANGE run
  no legal terminal value: `resolved` would assert a removal that never happened, and
  `instrumented` would assert shipped work that does not exist. Both are false statements
  about a NO-CHANGE outcome, and a run forced to pick one of them corrupts the registry in
  order to close a ticket. That is the gap this closes.

Worked example: **ISS-0109** (`superseded_by: ISS-0116`). Run WF03-ISS0109-20260821 built
and verified real test instrumentation, but the design gate and REVIEWER independently
concluded the failure was instrumented, not fixed — the root cause remains unknown — so it
was transitioned to `instrumented` rather than `resolved`.

Worked example: **ISS-0200** (`status: no_defect`, run WF03-ISS0200-20260821) — the
precedent that forced this status into the vocabulary. The run asked whether
`result.summary` carries a redundancy defect distinct from justified length; it measured
605 handoff files across 60 runs first-hand, tested six candidate restatement mechanisms
and found none supported, recorded its own shingle method's under-power against paraphrase
as a stated limitation, and changed no rule. Nothing was removed, so `resolved` was false;
nothing shipped, so `instrumented` was false. The gap was found by that run's own
diagnosis and fixed in the same run rather than filed, because Step 5 could not legally
close the issue without a terminal status that told the truth.

**AMENDMENT (ISS-0870, 2026-09-27): six further terminal values, in live use across the
registry before this amendment named them.** `mix letflow.check_queue_reconciliation`'s
first several live runs (ISS-0848/ISS-0849/ISS-0870) kept flagging these as
`:unrecognized_yaml_status` even though each was already a real, deliberate terminal
disposition on multiple files — the vocabulary list above had simply never been updated
to match. Case-by-case review (ISS-0870) confirmed none is a typo for an existing value;
each names a genuinely distinct outcome `resolved`/`instrumented`/`no_defect` cannot
honestly stand in for:

- `done` — an issue-file synonym for `resolved` seen on several records this session
  (e.g. ISS-0836, ISS-0838..0844, ISS-0849..0851): a root cause was actually removed,
  same bar as `resolved`, just spelled the way `docs/requirements.yaml`'s own vocabulary
  spells it. Treated identically to `resolved` for queue-release purposes
  (`release_lock(status: "done")`).
- `resolved_via_duplicate` — the defect was genuinely fixed, but under a *different*
  issue's queue task/run, because a separate record was independently filed against the
  same root cause and got there first (or the sibling record's fix happens to cover this
  one too). MUST carry `superseded_by: ISS-NNNN` naming the record whose run actually did
  the work — same discipline as `instrumented`'s `superseded_by`, but here the successor
  is the one that's ALREADY resolved, not one still carrying open work. Release
  `"done"` — the underlying defect really is gone, just recorded under the other id.
- `closed_not_applicable` / `resolved_not_applicable` — investigated and found to be out
  of current scope (not "no defect exists," which is `no_defect`'s job, but "this
  shouldn't be attempted as scoped" — e.g. superseded by a different architectural
  direction, or the target the issue asks to change no longer exists). Release `"done"`
  or `"blocked"` depending on whether the record's own text asserts the concern is fully
  settled (`"done"`) or merely shelved pending a future re-scope (`"blocked"`).
- `declined` — considered and explicitly rejected as a change to make (a cost/benefit or
  policy call, not a defect-existence finding) — release `"done"` or `"blocked"` by the
  same rule as the row above.
- `reopened` — the mirror image of `open`: a prior terminal status (usually `resolved`)
  didn't hold, and this record was explicitly un-terminaled per this project's
  append-only-history convention (the earlier `resolved_at`/`resolved_in_run` fields stay
  on record, with `reopened_*` fields added alongside, not overwriting them). Behaves
  exactly like `open` for every purpose, including queue release (`"open"`, never
  `"done"`/`"blocked"`) — a `reopened` record asserts the defect is back, not settled.

`fixed` and `duplicate` remain unrecognized as of this amendment — neither was found on
any live record, so there is nothing yet to confirm a mapping against; the next agent to
find one should apply this same case-by-case process rather than guessing.

## Closing an issue's GitHub mirror — evidence is mandatory

`WF-03_issue_resolving.md` Step 5 owns the close procedure itself; this section states
the rule that procedure implements, so a reader who lands here first (e.g. via a
cross-reference from a filing) doesn't have to guess whether it's optional.

**A `gh issue close` on any issue this protocol tracks — and any local status flip to
a terminal value (`resolved` / `instrumented` / `no_defect`) — MUST carry either:**

1. a `--comment` on the GitHub issue citing the resolving evidence (the run-id, the
   `docs/issues/ISS-NNNN.yaml` record, and — for `resolved` only — the regression test
   path), or
2. a genuinely linked/merged PR with a `Closes`/`Fixes` reference recorded in the
   issue's own GitHub timeline (visible as a non-empty
   `closedByPullRequestsReferences` in `gh issue view --json`).

A closure carrying neither is **undocumented, not merely under-documented** — it
cannot be checked against its own reasoning after the fact, because it states none.
This is not a hypothetical: GH#324 and GH#326 were both closed 2026-08-20 this way,
and the gap went undetected until an unrelated reconciliation audit
(`WF03-ISS0278-20260822`) caught it by chance (see `docs/issues/ISS-0279.yaml` — filed
from that finding).

`mix letflow.audit_issue_closures` (`lib/mix/tasks/letflow.audit_issue_closures.ex`)
mechanically re-checks every closed, `github_issue`-linked entry in `docs/issues/` for
this rule. It is a **standalone, on-demand tool** — see its own `@moduledoc` for why it
is not wired into `mix letflow.check` — run it periodically (e.g. as part of a
reconciliation pass) rather than relying on Step 5's prose compliance alone.

## Picking up a queued issue later

As of `letflow-queue` going live, task **selection** happens through `get_next_task`
only — see `TASK_QUEUE.md`'s Hard Rule. This section now covers the two remaining
cases: a queue-selected pickup, and a human naming a specific `ISS-NNNN`/GitHub issue
directly (which bypasses selection but not locking).

**Queue-selected pickup (the normal case):** `get_next_task` returns the task; its `id`
is the `queue_task_id` — cross-reference against `docs/issues/*.yaml` by
`github_issue_number` to find the matching local record (or, for a task that predates
this field, by title). Set `status: in_progress` in the issue file and backfill
`queue_task_id` if it was previously null. On resolution, `status: resolved` plus the
resolving run-id and timestamp, then `release_lock(status: "done")`.

**A human names a specific issue/GH-issue-number directly:** this is not "agent
discretion over selection" (see `TASK_QUEUE.md`'s Hard Rule exception) and may proceed
without `get_next_task` choosing it — but the task must still be locked before work
starts and released when done, or nothing stops a second host's own `get_next_task`
call from independently claiming the same still-open item. **As of decision 0017,
`GET /tasks` replaces the old bounded claim-then-release lookup dance** — that dance (a
real `get_next_task` call spent purely to look something up, released back on a
mismatch) existed solely because there was no side-effect-free lookup; `GET /tasks`
is that lookup and performs no write of any kind. Concretely:

1. If the issue's `docs/issues/ISS-NNNN.yaml` already records a `queue_task_id`: call
   `set_lock` directly on that id. (It works on any currently-unlocked task you already
   know the id of, not only a task this same agent held before — see
   `TASK_QUEUE.md`'s `set_lock` section.)
2. If `queue_task_id` is null or the issue predates this field (filed under the
   pre-2026-08-20 version of this protocol, see "Updated" note above): call
   `GET /tasks` (optionally `?task_type=issue`) and find the row whose
   `github_issue_number` matches. If found, `set_lock` its id, then backfill
   `queue_task_id` into the yaml immediately, closing this gap for next time. If no row
   matches, state that plainly and do not chase further down the priority stack — a
   `GET /tasks` lookup never claims anything, so there is nothing to hand back on a
   mismatch, only a lookup that found no match.
3. On completion, `release_lock(status: "done")` the task actually locked in step 1/2.
   If step 2 never found a match, note explicitly that the queue's mirror stayed out of
   sync for this item; this is bounded (not indefinite) risk once the GitHub issue is
   closed, since `get_next_task`'s import only pulls **open** issues — see
   `TASK_QUEUE.md`'s "GitHub Issues visibility" section's `get_next_task` bullet.

Never delete an issue file — it is the audit trail of what was found and when it was
fixed, same append/never-rewrite spirit as `docs/status/requirement_status.yaml`.
