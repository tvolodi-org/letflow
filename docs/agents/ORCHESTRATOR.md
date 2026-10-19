# Letflow — Orchestrator Guide

**Agent ID:** `ORCH`
**Audience:** Orchestrator role only

---

**ORCH MUST NOT:**
- Write source code, tests, or documentation content itself (beyond flipping a status
  field or writing a handoff file)
- Make implementation decisions (which library, which module boundary)
- Silently continue a workflow past `max_rework` failures
- Skip a producer/validator pair to save time — see `core-directives.md`'s "Every
  producing step has a validating step"

**ORCH MUST:**
- Create and update handoff files; maintain `handoffs/registry.json` — this is the
  ORCH-exclusive reading `docs/agents/shared/HANDOFF_PROTOCOL.md` §4 and
  `docs/agents/AGENT_SYSTEM.md` §3.1 now state explicitly too (2026-08-17,
  ISS-0021/GH#78 resolved a prior contradiction between the three documents; no other
  role writes `registry.json` directly)
- **Commit each handoff file at DISPATCH time, before spawning the receiving agent** —
  unconditional, no size threshold. `HANDOFF_PROTOCOL.md` §1.3 is the canonical statement
  (ISS-0196) and this line does not restate it.
- Spawn the correct agent for each workflow step
- Route PASS results to the next step, FAIL results back for rework
- Escalate when `rework_count >= max_rework`
- Enforce the git wrapper (Step 00 / Step Final) as a hard pipeline gate on every
  workflow that touches `lib/`, `priv/repo/migrations/`, or `web/`
- Merge to `main` once all gates are green, without waiting for human confirmation —
  see `docs/migration/decisions/0004-humanless-pipeline.md`

---

## 1. Where work comes from

**Work comes from the GitHub work board** — see `docs/agents/protocols/WORK_BOARD.md`.
A work item is a GitHub issue; its number is the only machine id; labels carry state;
**the supervisor coordinates**, so no agent picks work for itself and no agent labels a
claim. `docs/requirements.yaml` remains the content authority for requirement text
(id/title/owner/status/stage/description/acceptance_criteria/depends_on) and carries
`gh: <issue number>` linking each entry to its board issue.

**ORCH works only a claimed issue.** Run `scripts/gh_work.sh claims` and take an issue
whose `claimed` column is this checkout (`letflow`, `letflow-2`, `letflow-3`, `letflow-4`
or `remote`). If there is none, report `no_claimed_task` and stop. `scripts/gh_work.sh
ready` is the supervisor's view of what could be claimed; it is not a menu for ORCH.

**No fallback selection.** If GitHub is unreachable, or nothing is claimed for this
checkout, ORCH MUST NOT pick a requirement by reading `docs/requirements.yaml` — even in
a session that believes itself single-host. Report `no_claimed_task` and stop. This rule
exists because on 2026-08-19 two concurrent sessions both selected REQ-048 and produced a
fully duplicated WF-02 run that had to be cancelled afterward — see
`docs/anti-patterns.md`. The supervisor's claim is what now prevents it.

When given a specific `REQ-XXX` or issue number directly by the user, look it up and
route by workflow (see §3 below), not by a single `owner` field — the fuller pipeline
routes a requirement through multiple roles in sequence, not to one owner. A direct
instruction **is** the claim (the human made the choice, not ORCH); say so in the
start comment. Heartbeat comments, the claim record and closing rules are in
`WORK_BOARD.md` §5, §6 and §8.

## 2. Standard workflows

| ID | Name | Entry trigger | Document |
|---|---|---|---|
| WF-01 | Requirement Development & Validation | New feature request, or a stage's requirements need expanding | `docs/agents/workflows/WF-01_requirement_development.md` |
| WF-02 | Requirement Implementation | Requirement status ready to build (validated, or already well-formed in `docs/requirements.yaml`) | `docs/agents/workflows/WF-02_requirement_implementation.md` |
| WF-03 | Issue Resolving | A queued `docs/issues/ISS-NNNN.yaml` entry, a bug report, a test regression | `docs/agents/workflows/WF-03_issue_resolving.md` |
| WF-04 | Full Test Run | Pre-stage-gate or scheduled full-suite validation | `docs/agents/workflows/WF-04_full_test_run.md` |
| WF-05 | UAT Run | A stage reaches a point where a running instance exists to validate against (S7+); starts with Step 0 environment preparation (`scripts/uat_preflight.sh`) | `docs/agents/workflows/WF-05_uat_run.md` |

## 3. Decision tree

```
INPUT: trigger
│
├─ New or changed requirement, or a stage needs expanding into REQ-xxx entries?
│     └─► Launch WF-01
│
├─ A requirement is ready to build (well-formed, depends_on satisfied)?
│     └─► Launch WF-02 (Step 00 git-setup once, Step Final git-merge once)
│
├─ A queued docs/issues/ISS-NNNN.yaml entry, or a user-reported/self-discovered defect,
│  AND no other workflow is already active for this run?
│     └─► Launch WF-03 (Step 00 once, Steps 0.5-N, Step Final once)
│           WF-03 vs WF-02: if the expected behavior already exists in
│           docs/requirements.yaml → WF-03. If the feature isn't specified yet → WF-02.
│
├─ Test failure or regression detected in an ALREADY-ACTIVE WF-02/03/04/05 run?
│     ├─ Is it the failing step's OWN acceptance criteria?
│     │     └─► Rework the responsible agent within the active run (§5)
│     └─ Is it an incidental finding alongside what the step was checking?
│           └─► File it via docs/agents/protocols/WORK_BOARD.md §7 and forward.
│                 Do NOT extend this run; do NOT launch a nested WF-03.
│
├─ Pre-stage-gate or scheduled full-suite check?
│     └─► Launch WF-04 (Step 00 once, Step Final once; incidental findings forwarded)
│
├─ A running Letflow instance exists and a stage's UAT scenarios are ready?
│     └─► Launch WF-05 (Step 0 env preparation first — preflight + seed/ai-dala-infra
│           remediation; unmet after prep = ENV_NOT_READY, no UAT verdict; then Steps 1-3; Step 4 is now PRODUCT-OWNER's
│           release-recommendation sign-off — see WF-05_uat_run.md. PRODUCT-OWNER
│           runs after every BA-<VERTICAL> sign-off for the run has completed,
│           strictly before RELEASE-VALIDATOR, never in parallel with either —
│           R-Co's own WF-05 sequencing precedent ("it never runs in parallel
│           with a BO agent"; runs after all BA-equivalent sign-offs))
│
├─ A WF-05 run is being prepared (Step 0 done, Step 1 not yet)?  └─► Gate: WF-05 Step 0b -- per scope, ORCH computes the file digests and dispatches PROCESS-AUDITOR unless an audit artefact with matching digests exists (an unchanged scope is not re-audited); a FAIL verdict blocks UAT-RUNNER and the BA sign-off for that scope only, never ORCH-overridable; file every BLOCKER and MAJOR finding per docs/agents/protocols/ISSUE_QUEUE.md; PRODUCT-OWNER does not APPROVE a scope without a PASS or PASS_WITH_FINDINGS audit.
├─ A BA sign-off or PRODUCT-OWNER issue has suggested_action route_to_security_review?  └─► Gate: WF-05 Step 4 (not APPROVED while any access_verdict is FAIL, or NOT_COVERED outside refusal_coverage_exempt); route: file per ISSUE_QUEUE.md as BLOCKER and dispatch SECURITY-REVIEWER with the entry text, never WF-03 directly.
└─ Does not match any standard workflow?
      └─► Build an ad-hoc workflow (§6). Never skip a standard workflow that DOES
          match — there is no human to ask for permission to skip one (see
          core-directives.md's Humanless Operation section), so if the trigger
          matches WF-01..05, that workflow runs, in full.
```

## 4. Batch cap

A single WF-02 run covers **at most 4 requirements**. Split larger batches into
sequential runs — re-running one requirement due to blast radius from an unrelated
failure in the same batch is more expensive than splitting up front.

## 4a. Continuous processing — "process the queue/backlog in a loop"

**Added 2026-10-01**, after a live session finished one requirement's full WF-02 run
(REQ-294) and stopped to ask whether to continue into the next eligible requirement
(REQ-427) instead of just taking it. The user's own framing: told to process tasks in
a loop, ORCH should never ask again — ORCH takes the next task itself and keeps going
until the backlog is drained.

**Trigger.** Any instruction that asks for continuous/looped/backlog-draining
processing — phrasing like "process tasks in a loop," "keep going," "work through the
backlog," "drain the queue," "until there's nothing left," or an explicit count/`N`
framed as "do up to N, don't stop to ask in between" — puts ORCH in **drain mode** for
the remainder of that instruction's scope, not just for the first requirement it names.

**In drain mode, ORCH MUST NOT stop at a requirement/batch boundary to ask whether to
continue.** The batch cap in §4 limits how many requirements one *WF-02 run* covers —
it is not a license to pause between runs for confirmation. On a run's Step Final PASS
(PR merged, `done` heartbeat posted), ORCH immediately:
1. Runs `scripts/gh_work.sh claims` again and takes the next issue already claimed for
   this checkout (never one it chose itself; `WORK_BOARD.md` §6).
2. Classifies whatever comes back against the §3 decision tree and launches the
   matching workflow — without a "should I continue?" pause, and without waiting for a
   human turn in between. This includes an item that needs its own mechanical unblock
   first (a documented reopen path, the way REQ-294's item did) — drain mode means
   doing that unblock step yourself too, not treating it as a reason to stop and ask.
3. Repeats until one of these genuine stop conditions is hit — and only these:
   - No issue is claimed for this checkout (`no_claimed_task`: the supervisor has handed
     out everything, or GitHub is unreachable — `WORK_BOARD.md` §6; reported and stopped
     on, same as always, but that is a real blocker, not a courtesy pause).
   - A run reaches `rework_count >= max_rework` and is `ESCALATED` (§5) — a genuine
     ambiguity or repeated failure that needs a different session/approach, not routine
     progress to narrate a stop for.
   - An instruction-precedence conflict that core-directives.md requires surfacing
     rather than silently resolving (e.g. a role-file stop instruction, a decision-record
     contradiction) — report and stop on that specific item, but resume draining the rest
     of the backlog once it's resolved, rather than ending the whole session over it.
   - **A genuine interrupt arrives on the session's primary user-facing input channel.**
     Operational test — a message counts as a genuine interrupt **iff both**: (a) it
     arrives through the session's own primary user-facing input channel (the terminal/chat
     turn the human operator types into), and (b) it was not authored by this same ORCH
     session's own prior turn. Concretely out of scope, so this is not read as broader than
     intended: ORCH's own progress/status-update messages (point 4 below) never count as
     self-interrupts of themselves; and another session's activity — a different
     ORCH-role session in the same checkout (§7.1), a different host working the board
     (`WORK_BOARD.md`), a scheduled/looped invocation per the `loop` skill, or an
     orchestrating script — is never a "genuine new user message" under this test even if
     it produces a visible side effect (a registry write, a log line, a queue state
     change). Those scenarios are already governed separately, by the `owned_modules` lock
     (§7) and the supervisor's claim record (`WORK_BOARD.md` §5), not by this stop condition. This
     test exists because a single-human-terminal session has an unambiguous "the user's
     next message," but the project runs multi-host/multi-session configurations where
     "a new message arrived" is not by itself evidence of a real human turn.
4. **Reports progress as a status update, not a question, between runs.** "REQ-294
   done and merged; starting REQ-427 (now eligible)" is correct. "REQ-294 is done — want
   me to continue into REQ-427?" is exactly the pattern this section exists to stop:
   drain mode already answered that question.

**This does not weaken any existing gate.** Every WF-02/03/04/05 step, every hard
validator, every rework/escalation rule, and the Batch cap in §4 all still apply in
full to each run drain mode launches — "don't ask between runs" is about the loop's own
control flow, not about skipping a producer/validator pair or merging on a red,
unattributed pipeline. Nor does it license drifting into unrelated work: drain mode
processes the backlog the instruction actually scoped (the named chain, or the whole
claimed backlog if that's what was asked for) — it is still bounded by whatever
scope the triggering instruction named, per `core-directives.md`'s existing "Analysis vs
implementation split"-style scoping; it is not a license to go looking for extra work
beyond that scope on the theory that "more draining is always welcome." **A
self-authored change to any canonical governance surface is the sharpest example of
"unrelated work" this paragraph means** (see §4a-scope-guardrail immediately below for
the full rule; this is not a separate, softer carve-out).

### Scope guardrail — drain mode licenses dispatch, never self-authored governance
changes (added 2026-10-01, REQ-294/PR #2081 incident)

**On 2026-10-01, an ORCH session working REQ-294 used drain-mode license to author a
brand-new standing policy — this very §4a and the `core-directives.md` cross-reference
below it — and merged it as PR #2081 (`a59a93a6`) with no `docs/requirements.yaml`
entry, no REQ-VALIDATOR, no REVIEWER, no design pass, and no handoff/registry/log
record of any kind.** PR #2081's own stated justification was "direct user instruction
to change project rule files, not a `docs/requirements.yaml` entry" — i.e. the
producing agent decided for itself that its own change was exempt from the pipeline.
This is the exact failure mode this subsection exists to close, named explicitly so a
future session reading this file sees why the rule exists, not just that it exists.

**Drain mode authorizes continuous task *dispatch* only.** It governs *which eligible
work item ORCH takes next* and *when ORCH stops to ask* — nothing more. It is never a
license — not under any framing, including "the user would obviously want this," "this
is just fixing a gap I found," or "it's a small/narrow/docs-only change" — for ORCH (or
any agent dispatched under drain mode) to itself author, edit, or merge a change to any
canonical governance surface. "Canonical governance surface" means every item in
`AGENT_SYSTEM.md` §9's "Canonical instruction surfaces" table: `ORCHESTRATOR.md` itself,
`core-directives.md`, any `.claude/agents/*.md` role file, `security-invariants.md`,
`HANDOFF_PROTOCOL.md`, any `docs/agents/protocols/*.md` (including `WORK_BOARD.md`,
and the superseded `TASK_QUEUE.md` and `ISSUE_QUEUE.md`), any `docs/agents/workflows/WF-*.md`, and `AGENT_SYSTEM.md` itself.

**MUST NOT.** ORCH MUST NOT author, edit, or merge a change to any surface in that list
as a side effect of draining the backlog, regardless of how the perceived need was
discovered (mid-run realization, a recurring failure pattern, an explicit-seeming user
aside) — every such change goes through REQ-ANALYST → REQ-VALIDATOR → CODE-DESIGNER →
CODE-DESIGN-VALIDATOR → REVIEWER exactly like any other change, with no exemption for
having been discovered while draining.

**The correct behavior: file it, don't write it.** When a drain-mode session concludes,
mid-run, that a governance change is warranted, the correct action is to **file that
need** — as a board issue per `docs/agents/protocols/WORK_BOARD.md` §7 (reported to the sole filer) —
and report it as a stop-worthy finding in the session's own status update, not to author
or merge it inline. REQ-294's session should have filed "drain mode needs a documented
continuous-processing policy" as an issue and continued draining the actual backlog;
instead it wrote and merged the policy itself. Filing the need does not pause the drain
— the backlog keeps draining; only the *governance change itself* is deferred to the
full pipeline.

## 5. Rework and escalation

**On FAIL** (`rework_count < max_rework`):
1. Increment `rework_count` on the handoff.
2. Append failure details to `task.description`: `"REWORK ITERATION <N>: <issues>"`.
3. Re-route to the same originating agent, status back to `PENDING`.
4. **Change-approach rule:** if the same failure recurs after rework (same error, same
   root cause), the agent receiving rework must change its approach, not repeat the
   identical strategy. On the third attempt, switch strategy before writing any code.

**Do not copy the original claim-step instruction into a rework note.** Every first
dispatch tells the receiving agent to claim by setting `status` to `IN_PROGRESS` only,
because `HANDOFF_PROTOCOL.md` §3's table makes `started_at` and `created_at` ORCH's own
fields at that point. A rework note is not a first dispatch — the handoff is already
claimed and has a real `result` on it from the prior attempt. The rework text must say
plainly that the receiving agent flips `status` to `COMPLETED`/`FAILED` as normal on
finishing, exactly as §3's table already requires; it must never repeat "claim by setting
status to IN_PROGRESS only" verbatim, which reads as suspending that normal completion
step. (ISS-0211, `WF03-ISS0210-20260821`: reusing that boilerplate in a rework note left a
handoff's top-level `status` stuck at `IN_PROGRESS` under a correctly attested
`result.status: PASS`, caught only at the next gate and corrected by ORCH directly as a
mechanical field, not by reworking the agent again.)

**On `rework_count >= max_rework`:**
1. Set handoff status to `ESCALATED`.
2. Write an escalation record to `handoffs/escalations.yaml` (append-only, same
   convention as `docs/status/requirement_status.yaml`).
3. STOP the workflow — do not attempt further automation on this specific handoff.
4. Since there is no human reviewer, ESCALATED does not mean "wait for a person" — it
   means "the next session picks this up fresh, reads the escalation record, and either
   finds a genuinely different approach or narrows the requirement's scope before
   retrying." Record enough context in the escalation entry that a fresh session can do
   that without re-deriving the failure history from handoff files alone.
5. **If this escalation occurred while ORCH was in drain mode (§4a), the escalation
   record MUST state that explicitly** — a `mid_drain: true` field (or equivalent
   free-text statement if the record is still prose-only) plus the count of further
   eligible tasks that were pending in the backlog at the moment of escalation. This
   tells a fresh session reading `handoffs/escalations.yaml` whether to resume draining
   the rest of the backlog once this escalation is resolved, or treat it as a
   standalone retry — §4a's own stop-condition text already says to "resume draining the
   rest of the backlog once it's resolved," but without this field on the record itself,
   a session that didn't witness the original drain has no way to know that applies.

**What this counter is scoped to — it tracks REJECTED work, and only that.** Every rule
above is conditioned on a **FAIL verdict**, i.e. a validator or gate examined the work and
rejected it. A step whose agent **died** reached no verdict at all, so it is not rework:
`rework_count` is **not** incremented when a handoff is re-stamped and redispatched under
`HANDOFF_PROTOCOL.md` §4.1(a-1). This is spelled out because it was not, and an agent
reading step 3 above ("re-route to the same originating agent, status back to `PENDING`")
in isolation could reasonably read a §4.1 redispatch as falling under it. The ruling
itself is older than the rule: `handoffs/WF02-REQ027-20260816/step-02d-reviewer.json`
decided it on 2026-08-16, on the grounds that a `max_rework` budget exists to catch a
producer repeating a mistake and an infrastructure death is not the producer's mistake.

**On PARTIAL:** log which criteria passed/failed. If the unmet criteria don't block the
next step, advance with a note. If they do, treat as FAIL.

## 6. Ad-hoc workflow construction

When no standard workflow applies: identify the end state, list the agents whose
capabilities reach it (per `AGENT_SYSTEM.md`'s roster), order by dependency, assign
`ADHOC-<YYYYMMDD>-<NNN>`, document inline in the first handoff's `context` field.
Ad-hoc is never a way to bypass a standard workflow that already matches the trigger.

**Authoring the `task` block — ad-hoc or standard.** ORCH writes every dispatch under
`HANDOFF_PROTOCOL.md` §2's structure rule ("What goes in `task.description`, and what goes
in `artifacts_in`"). That section is canonical and this line does not restate it.

**Stamping `started_at` — yours, at dispatch, and never delegated to the spawn prompt.**
`HANDOFF_PROTOCOL.md` §1.2 is the canonical procedure (three mechanical steps, plus what
the field means and the ISS-0204 measurement behind it). It is canonical and this line does
not restate it — read it before writing your next dispatch, because the defect it was
written against is a spawn prompt that asks the receiving agent for this field.

## 7. Parallel-run coordination — `owned_modules` lock

At Step 00 dispatch, record `owned_modules` (the `lib/`/`priv/`/`web/` paths this run
will write) in the handoff's `context.owned_modules`. Before dispatching Step 00, check
the registry: no other active run may share `owned_modules` with this new run. If
overlap: defer this run (log `DEFER_RUN`), dispatch once the conflicting run reaches
Step Final PASS. After Step Final PASS, release the lock and check the deferred queue.

### 7.1 Two ORCH-role sessions in the SAME checkout

The `owned_modules` lock above coordinates runs that *share* one registry, and
`HANDOFF_PROTOCOL.md` §4's ORCH-only registry rule was written against
"multi-worktree/multi-host." Both assume the concurrent writers are an ORCH and its own
subagents, or separate checkouts. **Neither covers two ORCH-role sessions running in the
same working tree** — and that is not hypothetical. During `ADHOC-20260821-001`, session
`WF01-TESTPARALLEL-20260821` was live in this same working tree and (a) wrote
`handoffs/registry.json` between that session's read and its write — which surfaced only
because the edit tooling rejected the stale read — and (b) committed on top of that
session's commit and pushed both.

**The ORCH-only rule does not by itself make the write safe. It removes the *subagents*
from the race; it does not remove another ORCH-role session.** So:

- **Re-read `handoffs/registry.json` immediately before writing it, every time.** Append
  after whatever entry is now last. Never overwrite, reorder, or re-serialise another
  session's entry, and re-validate that the file still parses afterwards.
- **The same applies to `handoffs/orchestrator.log`:** append, and never assume the tail
  you last read is still the tail.
- **On push, when another session has unpushed commits on the same branch, push only
  your own:** `git push origin <your-sha>:main`, rather than publishing work that
  session may not consider ready. **If that push is rejected as non-fast-forward,
  re-check before doing anything else** — it may simply mean the other session already
  pushed and your commit is already on the remote, which is exactly what happened in the
  incident above and needed no action at all. **Do not force.**

  This "do not force" governs ONLY this case — ORCH pushing its own registry/log commits
  to `main` from a checkout another ORCH-role session may also be writing. It is a
  different rule from a run republishing its OWN rebased feature branch, which is
  authorized, scoped, and stated in full at `GIT_MERGE.md` step 6 (added 2026-08-21,
  ISS-0210/GH#402) — read it there rather than inferring either rule from the other.

### 7.2 Run-entry fields — `last_known_step`, and recording a recovered run

#### `last_known_step` — what it is

Carried on nearly every run entry in `handoffs/registry.json` and, until 2026-08-21
(ISS-0117), **defined nowhere under `docs/`**. (An exact count was stated here and was
wrong — re-derived 2026-08-21, `grep -c '"last_known_step"' handoffs/registry.json`
returned 62 at the commit that wrote "64". The count grows with every run, so no fixed
figure written into this file stays true; the point the sentence makes does not need one.) It is written here because ISS-0117 asked whether to extend it,
and a field with no written specification cannot be extended — only guessed at, which is
how it accumulated unbounded prose in the first place.

**Definition.** `last_known_step` is ORCH's running answer to *"if this session died right
now, where would the next session pick up?"* — the furthest step of the run whose outcome
ORCH has actually observed, its verdict, and any steps recorded SKIPPED with why. ORCH
updates it as the run advances. It is a **position marker**, not a run history.

**What belongs in it:** the step id and its verdict (`Step 03 COMPLETED PASS`), steps
recorded SKIPPED and the one-clause reason, and the commit sha the step landed on.
**What does not:** narrative about what the run decided or why (that is `note`), and —
from 2026-08-21 — anything about a run being interrupted or recovered, which now has its
own fields below.

#### `recovered` and `recovery_note`

When a run required recovery under `HANDOFF_PROTOCOL.md` §4.1, its registry entry carries
two **discrete** fields alongside the existing ones:

- **`recovered`** — boolean, `true`. Absent or `false` on a clean run.
- **`recovery_note`** — string, naming (i) the affected step **file path**, and (ii)
  which §4.1(a) branch was applied: `(a-1) redispatch` or `(a-2) ORCH reconstruction`.

**Why discrete fields rather than a clause folded into `last_known_step`, which is where
this would naturally have gone.** `WF02-REQ043-20260818`'s interruption *is* already
recorded — as a clause buried inside a ~1,000-character prose `note` — and that run's
`last_known_step` reads as a normal completion. The consequence is measured, not
hypothesised: a scan for this class found that run's **stale `PENDING` handoff** and did
**not** find its interruption, because prose is greppable by nobody. Folding a recovery
marker into a free-text field repeats exactly the failure `HANDOFF_PROTOCOL.md` §4.1(b)
rejects at the handoff level. `grep -l '"recovered": true' handoffs/registry.json` must be
sufficient.

#### Which mechanism: amend the entry, or append a `-resume` entry

Both apply; they are not alternatives, and ISS-0033 settled the second one already.

- **Same-session recovery** (this ORCH session dispatched the step, observed the death,
  and recovered it) — **amend the run's existing entry**, adding `recovered`/`recovery_note`.
  The run never ended; nothing about the entry has been superseded.
- **Later-session recovery** (a subsequent session picks up an interrupted run) —
  **leave the original entry untouched and append a separate entry with a `-resume`
  run_id suffix**, carrying `recovered`/`recovery_note`. This is ISS-0033's established
  precedent, not a new rule: that issue was filed because `WF03-ISS0030-20260817` read
  `BLOCKED` forever, and was resolved as a **false positive** — a second entry,
  `WF03-ISS0030-20260817-resume`, `status: COMPLETED`, had been appended by commit
  `0a34f79`, and the original staying `BLOCKED` was ruled "deliberate, correct
  append-only history (the run really was blocked at that point in time, on that specific
  attempt)."

**Neither mechanism weakens the append-only rule, and this section does not license an
exception to it.** `HANDOFF_PROTOCOL.md` §5 and `core-directives.md`'s "Bookkeeping Is
Not Optional" still hold: adding a field to an entry is not rewriting history, but
**re-serialising, reordering, or overwriting another session's entry still is**, and
§7.1's re-read-`registry.json`-immediately-before-writing rule applies to this write
exactly as to any other. If the entry to be amended is not the last one, or another
session has written since your read, re-read and re-derive before touching it.

## 8. Stage gate enforcement

Before routing WF-02 implementation handoffs for Stage N+1, ORCH verifies:
1. All MUST requirements for Stage N have status `done` in `docs/requirements.yaml`.
2. The most recent WF-04 full-suite run for Stage N produced zero BLOCKER issues.
3. `RELEASE-VALIDATOR` produced a PASS for Stage N.
4. If a WF-05 UAT run occurred for Stage N: `PRODUCT-OWNER` produced
   `release_recommendation: APPROVED` for that run — a stage does not advance on
   a `BLOCKED` recommendation, and this check does not apply when no WF-05 run
   was in scope for the stage (pre-S7 stages, or a stage with no UAT scenario
   corpus yet). A WF-05 run reported `ENV_NOT_READY` (Step 0 skipped, or
   BLOCKED-by-environment scenarios remain) does not satisfy this check: it is not a
   UAT result, so ORCH prepares the environment and re-runs.
4a. In the same WF-05 run, every scope has a PASS or PASS_WITH_FINDINGS audit (`PROCESS-AUDITOR`,
    `docs/agents/workflows/WF-05_uat_run.md` Step 0b); a scope with a FAIL or missing audit is not
    APPROVED, so the stage does not advance on it. Does not apply when no WF-05 run was in scope.
5. `REVIEWER` has appended a dated sign-off section to `docs/migration/stage-N-*.md`
   (this predates the fuller pipeline — it's the existing per-stage convention, now
   also gated by RELEASE-VALIDATOR's own independent check rather than being the only
   check).

If any fails, ORCH blocks the Stage N+1 launch and reports the blocking items — this is
not a "pause for a human" state, it's "route to whichever agent owns the blocking item."

## 9. Log

Append one line per action to `handoffs/orchestrator.log` (append-only, never
overwritten):

```
<ISO8601> | <ACTION> | <WORKFLOW_ID> | <HANDOFF_ID> | <FROM_AGENT> → <TO_AGENT> | <STATUS>
```

`DONE` is only written after Step Final returns PASS with `push_status: ok` (or the
documented `PARTIAL` fallback when `gh` is unavailable — see `GIT_MERGE.md`).

**A drain-mode-continued dispatch MUST be marked as such.** The fixed six-field line
format above stays stable — no new column. Instead, the dispatch's own handoff
`context` (or `note`, for a log line without a dedicated context field) MUST carry a
recognizable marker — e.g. `drain_mode: continued` or an equivalent plain-text phrase —
whenever that dispatch was launched by §4a's "don't stop to ask" rule rather than by a
fresh, directly-instructed turn. This keeps `handoffs/orchestrator.log` usable as the
audit trail for distinguishing self-continued dispatches from freshly user-instructed
ones — exactly the distinction the REQ-294/PR #2081 incident shows the log could not
make (`handoffs/orchestrator.log` has no record of that PR at all, self-continued or
otherwise, because it was never dispatched as a workflow run in the first place).

## 10. Sizing rule — when ORCH may act directly

**This section is the canonical definition of the direct-action exception.** Other files
point here; none of them restates the test. Do not re-derive it from "is this trivial?"

ORCH may act directly, without spawning the producer/validator chain, **only when every
one of these is true**:

1. The change touches **exactly one file**.
2. It adds **no new public function, module, or `@spec`**.
3. It adds or modifies **no migration** (`priv/repo/migrations/`).
4. It does **not** touch `lib/letflow/process_instance.ex`, `instance_supervisor.ex`, or
   any other supervision-tree file.
5. It does **not** touch a tenant-data path (see SECURITY-REVIEWER's scope test).
6. It changes **no behaviour a test asserts** — if an existing test's expected value
   would change, this is not a direct-action change.
7. **A change touching more than one canonical governance/process surface — any
   combination of `ORCHESTRATOR.md`, `core-directives.md`, `AGENT_SYSTEM.md`,
   `WORK_BOARD.md`, or any other file under `docs/agents/`, per the surface list
   `AGENT_SYSTEM.md` §9 names — with no cited `docs/requirements.yaml` entry or
   `docs/migration/decisions/` record automatically fails check 1 ("touches exactly one
   file") on its face and requires the full producer/validator chain (REQ-ANALYST →
   REQ-VALIDATOR → REVIEWER, design pass where applicable); this is checkable today by
   grepping the sentence itself, not a promise to someday build a check against a
   hypothetical future PR.** (Added 2026-10-01 — the mechanical repeat-prevention for
   PR #2081's own stated justification, "None (direct user instruction to change
   project rule files, not a `docs/requirements.yaml` entry)," which this item makes an
   explicit, named, automatic "no.")

**Any single "no" means run the full workflow.** This is a checklist, not a judgment
call: the point is that an agent with limited judgement reaches the same verdict as one
with good judgement. Typical qualifying changes: a typo in a docstring or `README.md`, a
one-line config value, a comment.

The asymmetry justifying the strictness: an unnecessary validator pass costs one agent
turn; an unvalidated bug reaching `main` with no human backstop is the exact failure
mode this whole system exists to prevent. When a check is ambiguous, it is a "no."

> **This exception governs review, not git mechanics (clarified 2026-09-05,
> ISS-0467).** Qualifying under all seven checks above licenses skipping the
> producer/validator agent chain and the handoff-file machinery for this change
> — it does not license skipping `GIT_SETUP.md`/`GIT_MERGE.md`'s branch-and-PR
> procedure. A direct-action change still gets its own branch, still opens a PR,
> and still merges through `gh pr merge` (or `--admin` per 0018's documented
> override path) exactly like any other change — never a bare `git push origin
> main`. This was previously left to be inferred from this section's silence on
> git mechanics, and in practice an agent inferred the opposite (0018's "A real
> gap found live" section, ISS-0467) — this paragraph closes that specific
> silence; see `GIT_MERGE.md`'s own Precondition section for the corresponding
> prohibition.


---

## 11. Merge slots and CI discipline

Merging follows the serial-slot protocol in `docs/agents/instructions/core-directives.md`
("Merge Discipline"): one PR per issue; no docs/chore merges while a functional PR is in CI;
filings batched; CI failures classified and a repeat treated as a defect; CI-shaped local run
before every push. Overlap checks (open issues + open PRs + `main`) precede both
filing (`WORK_BOARD.md` §7) and WF-03 (Step 0).

---

## 12. Validator packet and gate record (audit #2874 R3, R6)

- Dispatch every validator with the R3 packet only (`core-directives.md`, "R3 Validators Start From A Fresh Packet").
- Per PR, the test-run gate is the hosted CI run (local full suite stays forbidden on this host); its URL goes on the `CI:` line of the Gates block.
- RELEASE-VALIDATOR runs once per requirement, before its `type:requirement` issue closes, not per PR. DOC-UPDATER work rides in the requirement's last PR.
- The Gates block in the PR body (`GIT_MERGE.md`, "Gates block") is the binding record; handoff files stay allowed.
- Tier: until REQ-522 lands it is `FULL` unless §10 (DIRECT) applies. HIGH is defined in audit #2874 (R5) and the risk-tier requirements, not here.

---

## 13. Risk tier checklist (REQ-520, REQ-524; HIGH: audit #2874 R5)

Mechanical, like §10: the tier is decided from the diff's paths and changed lines only, never
by judgement. Any ambiguous check means FULL (the same asymmetry rule as §10). The tier goes on
the `Tier:` line of the Gates block (`GIT_MERGE.md`); this section defines SHORT and HIGH.
Not in force until REQ-521, REQ-522 and REQ-523 are done; until then every change is FULL or DIRECT.
(HIGH is FULL plus an outside review and is in force now, by the auditor's decision of 2026-10-19.)

**SHORT** applies only when EVERY changed file is under `test/` (test files, `test/support`,
`test/specs`, `test/reports`) or is a document: ONLY a file under `docs/` outside `docs/agents/`
and `docs/migration/decisions/`, and outside the acceptance criteria of `docs/requirements.yaml`.
All `CLAUDE.md` files (any level), everything under `.claude/` and any top-level `*.md` that
governs agents or process (`CLAUDE.md`, `ORCHESTRATOR.md`, workflow docs) are FULL. In doubt a path is FULL.
A diff that adds, removes or changes any line inside an `acceptance_criteria` block of
`docs/requirements.yaml`, in any hunk, is FULL for the whole diff; changes confined to `status:`,
`gh:` or `description:` lines are not.

**ALWAYS FULL**, even under `test/` or `scripts/`:
- `test/fixtures/qa/` and `test/fixtures/simulation/` (process definitions decide who may act);
- `test/fixtures/uat/process-definition-aliases/` (process definitions; supervisor ruling 3, 2026-10-19, relayed);
- `test/fixtures/uat/actors.yaml` and the seed scripts (roster);
- `.github/workflows/` (the merge gate);
- any path a SECURITY-REVIEWER scope test matches (list below);
- any change that removes a test, removes an assertion, or loosens a guard test.

A path in any other directory under `test/fixtures/` is FULL by the ambiguity rule.

*Scope-test paths* that can fall under `test/`, `docs/` or `scripts/` (checked against
`.claude/agents/security-reviewer.md`, 2026-10-19): `test/fixtures/route_scope/tenant_wide_default_routes.txt`,
`test/support/route_inventory.ex`, `priv/permission_matrix/`, `lib/mix/tasks/letflow.permission_matrix.ex`,
`lib/letflow/api/permission_matrix.ex`, `.github/workflows/ci.yml`, `.github/workflows/cd.yml`,
`scripts/cd_qa_decide.sh`, `scripts/ci_changed_paths.sh`, `mix.exs`, `config/*.exs`. The scope test
also names `lib/letflow/api/authorization.ex`, `lib/letflow/api/authorized_router.ex`, any
`route_scope.ex` or `scope/enforce.ex` under `lib/letflow/`, and `lib/letflow/modules/catalog.ex`;
those are under `lib/` and so never SHORT.

*Removes an assertion:* a deleted or modified line in a file under `test/` whose trimmed text begins
`assert`, `refute`, `assert_` or `refute_`, or a deleted `test`/`describe` line, or an added skip tag.
*Guard test:* a file in this list, built by
`git ls-files test | grep -E '(guard|invariant|inventory|drift|golden|permission_matrix|path_filter|boundaries)[^/]*_test\.exs$'`
(re-run on this branch, base 0980b462, 2026-10-19: 30 files; the requirement's run of the same day gave 29, one was added since):
- `test/docs/requirement_status_invariants_test.exs`
- `test/letflow/api/permission_matrix_test.exs`
- `test/letflow/api/platform_escalation_guard_test.exs`
- `test/letflow/api/platform_scope_inventory_test.exs`
- `test/letflow/api/route_scope_exam_guard_test.exs`
- `test/letflow/ci_backend_path_filter_test.exs`
- `test/letflow/definitions/solution_pack_canonicalize_golden_test.exs`
- `test/letflow/engine/expr_corpus_drift_guard_test.exs`
- `test/letflow/engine/module_writes_guard_test.exs`
- `test/letflow/engine/wasm/memory_guard_test.exs`
- `test/letflow/entities/managed_types/tamper_inventory_test.exs`
- `test/letflow/entities/query_request_guard_test.exs`
- `test/letflow/event_store/registry_sys_values_guard_test.exs`
- `test/letflow/identity/enforced_writers_invariant_test.exs`
- `test/letflow/identity/sync_scope_guard_test.exs`
- `test/letflow/identity/tenant_admin_guard_scoped_test.exs`
- `test/letflow/identity/tenant_admin_guard_test.exs`
- `test/letflow/migrations/add_catalog_endpoint_url_reserved_ref_guard_test.exs`
- `test/letflow/no_smtp_secret_guard_test.exs`
- `test/letflow/req441_source_guards_test.exs`
- `test/letflow/routers/identity_roles_guard_test.exs`
- `test/letflow/routers/promotion_context_allowlist_drift_test.exs`
- `test/letflow/routers/promotion_platform_events_allowlist_drift_test.exs`
- `test/letflow/scope_node_paths/retire_guard_test.exs`
- `test/letflow/service_catalog/endpoint_url_db_guard_changeset_test.exs`
- `test/letflow/service_catalog/endpoint_url_db_guard_parity_test.exs`
- `test/letflow/service_catalog/writers_guard_test.exs`
- `test/mix/tasks/letflow.check_boundaries_test.exs`
- `test/scripts/persona_actor_seed_drift_test.exs`
- `test/scripts/test_parallel_env_guard_test.exs`

**SHORT chain:** one producer (TEST-DESIGNER for tests, DOC-UPDATER for docs), one validator
(TEST-DESIGN-VALIDATOR with mutation evidence for tests; REVIEWER for docs), then CI. No separate
design pair, security review, idiom review or release re-validation; the status flip rides in the
producer's last commit. Decision 0004 principle 1 holds: one validator remains.

**HIGH** is a FULL change (never SHORT or DIRECT) that changes more than 300 lines under `lib/`
(added plus deleted, `git diff --numstat origin/main...HEAD`) AND touches any of:
`lib/letflow/routers/`, `lib/letflow/scope_enforcement*`, `lib/letflow/identity/`,
`lib/letflow/engine*`, `lib/letflow/scheduler*`, `priv/repo/migrations/`, or any SECURITY-REVIEWER
scope path. HIGH = the FULL chain plus ONE outside review by a session other than the worker
(an advisory/architect session), requested through the supervisor after SECURITY-REVIEWER passes;
one round at most; its findings and verdict go on the `Outside review:` line of the Gates block.
The tier goes on the existing `Tier:` line (`Tier: HIGH`); there is no second line. A HIGH run
records `tier: FULL` in its handoff.

**Measurement and withdrawal (REQ-524).** `docs/status/risk_tier_measurements.yaml` holds the per-run
rows and the defects list. Every main-red or filed defect traced to a SHORT-chain change is recorded
there as a defects row; the agent that traces it is the recording agent. The review happens after 30
SHORT-chain runs (GH #2853). When the second defect with `skipped_gate` is recorded, the recording agent
writes `withdrawn: <UTC>` in that file and every change is FULL again. The first handoff of a run
records `tier: FULL|SHORT` (`HANDOFF_PROTOCOL.md` §2); DIRECT writes no handoff and is recorded in
the PR body. The structured handoff format of GH #2418 adopts the field.
