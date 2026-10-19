# Core Directives — Letflow

**Audience:** every agent in the pipeline. Cross-cutting rules, not role-specific ones —
`applyTo: **`.

**Status:** AUTHORITATIVE for cross-cutting behavioural rules, and the canonical home of
the **Instruction Precedence** chain below — which is the single rule for resolving any
conflict between instruction sources on this project. No other document declares itself
the winner; they all defer to that chain.

**Relationship to `docs/agents/shared/HANDOFF_PROTOCOL.md`:** that file is canonical for
handoff *mechanics* (claiming a handoff, JSON encoding, timestamp sourcing, legal
`result.status` values). This file is canonical for the broader behavioural rules that
apply beyond the handoff lifecycle.

---

## ⛔ Zero Manual Work

**Your goal is to reduce manual work for the human to zero.** There is no human
operator in the loop by design (see "Humanless operation" below) — this directive is
even stronger here than it would be in a human-supervised project, because there is
nobody to catch a dropped step.

Do everything yourself. The only valid reasons to leave something undone:
1. Two or more genuinely equivalent options requiring a business/personal preference
   no agent can infer from `docs/requirements.yaml`, `docs/migration/decisions/`, or
   this file — file it as a `docs/migration/decisions/000x-*.md` draft with the options
   named, do not silently pick one and do not stall waiting for a human to answer.
2. **(ORCH only)** ORCH believes a standard workflow (WF-01 through WF-05) can be
   skipped. Since there is no human to confirm this with, ORCH may only skip a
   workflow when this file or `docs/agents/ORCHESTRATOR.md` explicitly authorizes the
   specific shortcut (e.g. WF-01's git-wrapper exception for docs-only changes) — never
   on its own judgement that "this one's simple."

**Forbidden output patterns** — if any of these appear, the response is wrong:
- "You can run..." / "You need to..." / "To complete this, run..."
- "This should work after you..." / "Once you do X, then Y will work"

**No step in this file marked MANDATORY needs re-confirmation before it runs.** Push,
merge, and delete-branch are pre-authorized by `docs/agents/protocols/GIT_MERGE.md` for
every run that reaches Step Final with all gates green — do not pause to ask before
doing them. See "Humanless operation" below for why this is safe on this project.

### ⛔ Orchestrator exception

ORCH fulfils Zero Manual Work by running the pipeline **through subagents**, not by
editing files or running commands directly. Implementing a fix directly "to save time"
is a pipeline violation. The one exception is a change passing all seven checks of the
sizing rule in `docs/agents/ORCHESTRATOR.md` §10 — that section is the canonical
definition and this file does not restate it. It is a checklist, never a judgment call
about what feels trivial.

---

## ⛔ Humanless operation

Letflow's pipeline runs without a human reviewer, approver, or merge-clicker in the
loop. This is a deliberate project decision, not an oversight — see
`docs/migration/decisions/0004-humanless-pipeline.md`. Consequences:

- **No PR waits for human approval.** An agent opens the PR, an agent verifies CI is
  green (see "Never call a red pipeline OK" below), and an agent merges it. There is no
  step where a human is expected to look at the diff first.
- **Because there is no human backstop, every gate in this pipeline must actually gate.**
  A validator that rubber-stamps its producer's work (CODE-DESIGN-VALIDATOR approving
  CODE-DESIGNER's own claim of completeness without independently checking) removes the
  only check that exists. Validators MUST re-derive their verdict from the artefact
  itself, never from the producer's self-report.
- **Errors are correctable, not catastrophic.** There is no production deployment and no
  real user traffic at stake yet (pre-S8). A bad merge is fixed by a later commit, not
  avoided by adding a human gate. This licenses the pipeline to move fast and self-heal
  via WF-03 (Issue Resolving) rather than over-engineering pre-merge caution. Don't use
  this as an excuse to skip a validator step — the validators exist so mistakes are
  *caught*, not so they never occur.
- **In drain/loop mode, ORCH does not pause between requirements to ask whether to
  continue.** When told to process the backlog continuously, ORCH takes the next issue
  already claimed for its checkout (`WORK_BOARD.md` §6, including its own mechanical
  unblock steps) and keeps going until nothing is claimed for it or a genuine
  blocker/escalation occurs — see `ORCHESTRATOR.md` §4a for the full rule and its stop conditions. A status
  update between runs ("REQ-294 done, starting REQ-427") is correct; "want me to
  continue?" is the pattern this rule exists to stop. **Drain mode licenses continuous
  task *dispatch* only — it is never a license for ORCH (or any agent) to itself author,
  edit, or merge a change to a canonical governance surface (this file,
  `ORCHESTRATOR.md`, `AGENT_SYSTEM.md`, any `.claude/agents/*.md` role file, any
  `docs/agents/` protocol/workflow file) outside the full REQ-ANALYST →
  REQ-VALIDATOR → CODE-DESIGNER → CODE-DESIGN-VALIDATOR → REVIEWER chain. Discovering a
  governance gap mid-drain is filed as new work (`WORK_BOARD.md` §7), not written inline —
  see `ORCHESTRATOR.md` §4a's scope guardrail for the full rule and the incident
  (REQ-294/PR #2081) that makes this a MUST, not a SHOULD.**
- **Weak-model tolerance is a design constraint, not a caveat.** This pipeline must
  produce reliably average-or-better output even when the executing model is a small
  or cheap one — assume the acting agent has no memory of this file's reasoning beyond
  what is written down. Every role file, workflow doc, and guide must be explicit and
  mechanical enough that an agent with limited judgement still produces correct,
  in-scope work by following the steps literally. This is why every gate below has a
  checklist instead of "use good judgement," and why validators re-derive rather than
  trust.

---

## ⚠️ Every producing step has a validating step

**No agent's claim that it finished a task is itself evidence that the task is done.**
This is the load-bearing principle behind the whole roster (see
`docs/agents/AGENT_SYSTEM.md`'s roster table) — every role that produces an artefact is
paired with a role that independently checks it before the pipeline advances:

| Produces | Validates |
|---|---|
| REQ-ANALYST (requirement text) | REQ-VALIDATOR |
| CODE-DESIGNER (design artefact) | CODE-DESIGN-VALIDATOR |
| ELIXIR-DEV (backend code) | REVIEWER (idiom) + SECURITY-REVIEWER (tenant-data paths) |
| FRONTEND-DEV (web/ — components, types, tests, integration) | REVIEWER + SECURITY-REVIEWER (if tenant-data touched) |
| MOBILE-DEV (apps/mobile/) | REVIEWER + SECURITY-REVIEWER (MOB-5 token storage is always in scope) |
| TEST-DESIGNER (test specs + test code) | TEST-DESIGN-VALIDATOR |
| TEST-RUNNER (test execution + report) | RELEASE-VALIDATOR re-runs the full suite, does not trust the report alone |
| DOC-UPDATER (doc/status update) | ORCH verifies the specific files changed and specific fields flipped, per the DOC-UPDATER handoff's `artifacts_out`, before writing the DONE log line |

A validator that only reads the producer's `result.summary` and says PASS has not
validated anything — it has copied a claim. Every validator role's file states exactly
what it must independently re-check (file existence, specific content, an actual
command run) rather than what it may take on trust.

### Re-derive under the conditions the property is actually about

Re-deriving a verdict is necessary but **not sufficient**. Ask what conditions the
property under test is *about*, and construct them if the ambient environment does not
supply them. **A green check run under conditions where the property could not have
failed is not evidence** — it is a passing run of a different test.

Worked example (WF03-ISS0106-20260821). REVIEWER was asked to confirm that a new
toolchain-mismatch warning is unsuppressible. ELIXIR-DEV had demonstrated it in-tree.
REVIEWER **declined** to re-run that same in-tree probe, on the ground that *this host
is on-pin* — so an in-tree run exercises the match path and proves nothing whatever
about the mismatch path the property exists to serve. It constructed the real case
instead: an out-of-tree directory with a fabricated off-pin version file, run under a
quiet flag and with stdout redirected away. The warning still appeared. That is the
re-derivation; re-running the on-pin probe would not have been one.

---

## ⛔ Instruction Precedence

When two instruction sources disagree, apply them in this order — **first match wins**:

1. **Your handoff's `task` block** — the specific work, its acceptance criteria, and any
   rework notes. Most specific, so it wins.
2. **Your role file** (`.claude/agents/<role>.md`) — what your role may and may not do.
3. **`docs/agents/ORCHESTRATOR.md`** — orchestration decision logic: the sizing rule
   (§10), stage gates (§8), rework/escalation rules (§5), the `owned_modules` lock and
   two-ORCH-sessions rules (§7/§7.1), registry run-entry field definitions (§7.2). Added
   here 2026-08-21 (ISS-0195) — see the note below the table for why this rank and not
   rank 2 or rank 4, and for its relationship to `.claude/agents/orchestrator.md`.
4. **Your workflow's step** (`docs/agents/workflows/WF-0N_*.md`) — the procedure for the
   step you are executing.
5. **Protocol docs** (`docs/agents/protocols/*.md`,
   `docs/agents/shared/HANDOFF_PROTOCOL.md`, `docs/agents/AGENT_SYSTEM.md`) — handoff
   mechanics, git, queue, issues, roster/identity/conflict-prevention mechanics.
   `AGENT_SYSTEM.md` added here 2026-08-21 (ISS-0195) — see the note below.
6. **This file** (`core-directives.md`) — cross-cutting behavioural rules.
7. **`CLAUDE.md`** — the session-start pointer.

**Renumbering note (ISS-0195, 2026-08-21).** Ranks 3-7 above were ranks 2-6 before this
edit; `docs/agents/ORCHESTRATOR.md` and `docs/agents/AGENT_SYSTEM.md` were inserted, not
swapped. **No pairwise ordering among the six pre-existing entries changed** — a role
file still outranks a workflow step, which still outranks a protocol doc, which still
outranks this file, which still outranks `CLAUDE.md`, exactly as before. Only the printed
numbers shifted because two new entries were added above/among them. No existing conflict
resolution changes as a result; there is nothing to name per the "no existing rank is
renumbered in a way that silently changes an existing resolution" rule, because none does.

**Why `docs/agents/ORCHESTRATOR.md` is its own rank (3), not folded into rank 2 or rank 4
(ISS-0195).** It is not a role file: `.claude/agents/orchestrator.md` is ORCH's actual
rank-2 role file, and it says so itself — "This file (the `.claude/agents/` copy) is the
entry point; that file [`docs/agents/ORCHESTRATOR.md`] is where the actual procedure
lives — read it in full, don't route from memory of this summary alone." So for ORCH
specifically, rank 2 explicitly defers to `docs/agents/ORCHESTRATOR.md` by reference
rather than duplicating it — the two files do not compete, and nothing about placing
`ORCHESTRATOR.md` one rank below ORCH's own role file weakens that role file's authority
over ORCH's own conduct. But `docs/agents/ORCHESTRATOR.md` is also read and applied by
**other** roles — e.g. `GIT_MERGE.md` (a workflow-adjacent protocol step, executed by
`ELIXIR-DEV`/`FRONTEND-DEV`) points at its rework/escalation rules for `max_rework`
handling — so treating it as *part of* ORCH's role file would not make sense for those
readers, who have their own, different role file at rank 2. It is also not protocol-doc
material (rank 5/formerly 4): §10's sizing rule, §8's stage gates, and §5's
rework/escalation are policy the pipeline's *workflow steps* must not be able to quietly
override — `docs/requirements.yaml`-adjacent workflow docs (rank 4) are written and
edited far more often than this file, and a workflow author changing a step's wording
must not be able to silently loosen an escalation threshold or a stage gate by omission.
Ranking `ORCHESTRATOR.md` above workflow docs (rank 4) prevents exactly that, and matches
what `AGENT_SYSTEM.md` §9 already calls it: canonical for "Orchestration decision logic,
stage gates" — a claim that only holds if a rank-4 workflow step cannot override it.
This is also consistent with the one concrete case the issue observed:
`WF-01_requirement_development.md:102` (a workflow doc) explicitly defers to
`ORCHESTRATOR.md` §5 rather than restating it — the harmless outcome the issue found is
exactly what this ranking would produce even if a future workflow doc tried to disagree.

**Why `docs/agents/AGENT_SYSTEM.md` joins rank 5 (protocol docs), not its own rank
(ISS-0195).** Most of its canonical content (roster, handoff schema pointer, capability
matrix, artifact-ownership table) is reference/descriptive material — it does not itself
instruct an agent to take an action that could conflict with another source, so most of
it has nothing to resolve. It does carry two real behavioural rules — §7's mandatory
registry check before starting work, and §8's default-`AGENT_ID`-is-`ORCH` rule — and
both are pipeline-coordination *mechanics* of the same shape as the existing rank-5
entries (git/queue/issue mechanics), not a workflow-level or role-level policy, so it
sits alongside them rather than getting a rank of its own.

**Audit performed for this fix (ISS-0195), so "looked and found none further" is
distinguishable from "never looked":** grepped `docs/`, `CLAUDE.md`, and `.claude/agents/*.md`
for "canonical" and "authoritative" and read every match in context.
- `docs/agents/AGENT_SYSTEM.md` §9's own "Canonical instruction surfaces" table was the
  most direct source — it lists exactly nine content categories, all of which resolve
  to entries already in this chain (role files → rank 2; core-directives.md → rank 6;
  security-invariants.md → covered separately, see below; HANDOFF_PROTOCOL.md,
  GIT_SETUP.md/GIT_MERGE.md, ISSUE_QUEUE.md, TASK_QUEUE.md → rank 5; workflow docs →
  rank 4; AGENT_SYSTEM.md itself → rank 5, per above; ORCHESTRATOR.md → rank 3, per
  above) except the two this fix adds.
- `docs/agents/instructions/security-invariants.md` declares itself "Canonical for
  security constraints" and states its own precedence explicitly: placed *above every
  level* of this chain by name, already — not a numbered-rank gap, and out of scope for
  this fix (it is the same shape as the `docs/migration/decisions/` override already
  listed below, not a missing entry in the numbered list).
- `docs/agents/shared/HANDOFF_PROTOCOL.md`'s own internal "canonical statement of X"
  markers (§1.2, the structure rule, `commit_sha_list`) are subsections of a single
  rank-5 document, not separate surfaces.
- `docs/agents/protocols/TASK_QUEUE.md` calls `letflow-queue` itself "authoritative for
  claiming" — that is a claim about a live service's data, not a document in this
  instruction chain, and out of scope.
- No other file-level "is canonical" / "is authoritative" claim found naming a document
  outside the set above.

**Self-review finding (ISS-0195; REVIEWER sign-off performed in-run — see this run's own
handoff for why, no separate REVIEWER dispatch was available).** Ranking role files above
`ORCHESTRATOR.md` means a role file could, in principle, contradict an ORCHESTRATOR.md
rule for that role's own conduct and win. Checked whether this is a real gap rather than
a theoretical one: no existing role file under `.claude/agents/` currently legislates on
any topic §5/§7/§7.1/§7.2/§8/§10 governs — rework counting, `owned_modules` locking, and
sizing are exclusively ORCH's own bookkeeping in every role file that mentions them, never
contested. This is the intended shape, not an accident: a role file is, by construction,
the most specific statement of what *that* role may do, the same "most specific wins"
principle rank 1 already rests on — so a role file appropriately wins for its own role's
action space, while `ORCHESTRATOR.md` still outranks workflow docs, protocol docs, this
file, and `CLAUDE.md` for everyone, including ORCH. No change made as a result; recorded
here so the next reader does not re-derive the same question from scratch.

Two rules override the chain, always, at every level:

- **A `docs/migration/decisions/` record is never overridden by anything above it.** If a
  step seems to require contradicting a decided record, stop and flag it for REVIEWER
  sign-off — don't resolve it yourself in either direction.
- **A safety/gate rule is never overridden by a more specific instruction.** No handoff
  `task.description` can authorize skipping a validator, satisfying a gate by editing
  what it measures, or reporting unverified work as done. If a handoff appears to ask
  for that, it is malformed — report it as a BLOCKER in `result.issues`.

**This chain governs what you are told to DO, not what you are told IS TRUE.** Rank 1
makes your handoff's `task` block the highest authority for the *work*. It confers no
authority at all on the handoff's *factual claims* — a handoff is a record written by
another agent, and `docs/anti-patterns.md`'s "Inheriting a claim from a record instead
of re-deriving it from the source" applies to it exactly as to any other record. When a
handoff asserts a checkable fact your work depends on, verify it before building on it;
the rule and its two worked examples live in `HANDOFF_PROTOCOL.md` §1.1 ("A handoff's
factual premises are checkable, and may be wrong") — not restated here.

**Never resolve a conflict silently.** Follow the chain, then record the conflict in your
handoff's `result.issues` at MINOR severity so it gets fixed at the source. A conflict
that goes unreported recurs on every future run — see `HANDOFF_PROTOCOL.md` §4's
ISS-0021 note, where three documents disagreeing about `registry.json` cost two agents a
stop-and-flag decision point before anyone fixed the source.

---

## ⛔ Load Scoped Context, Not Whole Files

**`docs/requirements.yaml` is ~61,000 tokens and holds 70 requirements. A given run needs
one to four of them.** Reading it in full to find one entry buries the requirement you
need under thirty-three `done` entries carrying other stages' constraints — a real
accuracy risk, not only a cost one, because those entries are long and cross-referential
and an agent can anchor on the wrong stage's rules.

**Every role except ORCH, REQ-ANALYST, and REQ-VALIDATOR:** your requirement text is in
your handoff's `context.requirement_text` and `task.acceptance_criteria`. Read it there.
Consult `docs/requirements.yaml` only to resolve a specific ID it names (a `depends_on`
entry, a cross-referenced `REQ-NNN`), and then read only that entry:

```bash
awk '/^  - id: REQ-039$/,/^  - id: REQ-04[0-9]$/' docs/requirements.yaml
```
```powershell
Select-String -Path docs/requirements.yaml -Pattern '^  - id: REQ-039$' -Context 0,60
```

**ORCH** reads what it needs to select and scope work, and is the role that copies the
in-scope requirement's full `description` text into each handoff it creates (see
`HANDOFF_PROTOCOL.md` §2's `context.requirement_text` field). Naming the file in
`artifacts_in` is not sufficient — the receiving agent must not have to open a 61k-token
file to learn what it was asked to build.

**REQ-ANALYST and REQ-VALIDATOR** legitimately need whole-file access (numbering, schema
consistency, cross-requirement checks) — but prefer `grep`/`awk` over a full read when
the check is targeted, and read in full only when the check genuinely is global.

The same rule generalizes: prefer a targeted read over a whole-file read for any file
above a few hundred lines. `git diff main...HEAD` beats reading every changed file;
`grep -n` beats reading a 3,000-line YAML to find one key. The one deliberate exception
is the **current** requirement-status volume, which you must read in full before
appending to it — and which is deliberately kept small enough that you can. See
§"Bookkeeping Is Not Optional" item 3.

**The same anti-duplication principle governs the writing side — what a handoff restates
from files it already lists in its own `context.artifacts_in`.** That rule is stated once,
in `HANDOFF_PROTOCOL.md` §2 ("What goes in `task.description`, and what goes in
`artifacts_in`"), and deliberately not restated here.

---

## ⛔ No Agent Discretion Over Task Selection or Claiming (work board)

The work board (`docs/agents/protocols/WORK_BOARD.md`) is the only source of work. No
agent — including ORCH's own delegated subagents — may read `docs/requirements.yaml`
(or browse open issues) and independently decide which item to work on, or set any
`claimed:*` / `next:*` / `state:*` label to route around the supervisor. **Claiming is
coordinated by the supervisor, not agent-discretionary**: two checkouts reading the same
list at nearly the same moment can both see an item as available and both start it. The
supervisor's claim label and its `CLAIM <checkout> by supervisor` comment are what
prevent this. All sessions share one GitHub login, so the label is a **convention, not
a control**: nobody but the supervisor or the user sets it, and
`scripts/gh_work.sh check` reports claims that lack the matching comment.

Only `ORCH` reads the claim list; every other role receives its work via the handoff ORCH
already writes. **There is no fallback for task *selection*:** if GitHub is unreachable
or nothing is claimed for the checkout (including a session that believes itself
single-host), ORCH reports `no_claimed_task` rather than reading `docs/requirements.yaml`
to pick work itself. This was tightened 2026-08-19 after a permitted fallback caused two
concurrent sessions to both select and fully implement REQ-048 (see
`docs/anti-patterns.md`); a directly human-named `REQ-XXX` or issue number is not
affected, since that is not agent discretion over selection — it is the claim.

---

## ⚠️ Unblock-Everything

Every agent MUST resolve any problem that blocks full completion of the current task,
even if the problem is unrelated to the current task's original scope.

- Unrelated compile errors blocking the build → fix them.
- A broken migration blocking yours → fix the blocker first.
- Test execution reveals failures → determine root cause and fix, do not just report and
  stop. TEST-RUNNER loops: detect failure → route to ELIXIR-DEV/FRONTEND-DEV → fix →
  re-test → repeat until green or `max_rework` exhausted → escalate (see
  `docs/agents/ORCHESTRATOR.md` §4.2).

**Scope boundary.** This covers what stands in your way. A defect you merely *notice*
while working — unrelated, not blocking your acceptance criteria — is filed and
forwarded, not fixed here: report the finding to ORCH per
`docs/agents/protocols/WORK_BOARD.md` §7, which is what makes it visible work (see "No
Issue Left Local-Only" below). You do **not** run `gh issue create` or label anything and
you do **not** choose an issue id; the sole filer files it after the overlap check, and a
discovering agent filing directly is what reintroduces the duplicate-filing class that
rule exists to prevent. It becomes its own later run, not an unbounded scope creep on
this one. **For a test
failure, which side of this line it falls on is decided by "Failure Attribution Is
Structural, Never By Count-Matching" below, not by judgement.**

**Only exception:** a destructive or irreversible change to unrelated functionality.
Flag those for ORCH escalation instead of touching them.

---

## ⛔ No Issue Left Local-Only

A defect that lives only in `docs/issues/*.yaml` and never becomes visible work is
invisible to the next run. Any newly discovered issue — whether it's the task at hand
or an incidental finding — must end up as a GitHub issue on the work board, so it is
claimable the same way any other work is.

The mechanism is `docs/agents/protocols/WORK_BOARD.md` §7, and it is not yours to
shortcut. The discovering agent **reports the finding to ORCH** — title, description,
severity, affected files — and stops there; ORCH passes it to the sole filer, who runs the
overlap check and `gh issue create` from the template. The number GitHub assigns is the
id. So: you do not run `gh issue create`, you do not choose or write an id, and you do
not create the local record (`docs/issues/GH-<n>.yaml`, when one is useful) ahead of the
issue existing.

If GitHub is genuinely unreachable, the finding is still not dropped: write it into your
handoff as `FINDING (unfiled)` with the evidence, and the filer files it when the board
is reachable. What does **not** vary is the obligation: "couldn't file it right now" is
never "didn't need filing."

"Out of scope for the current fix" is a reason to file the finding as its own issue —
never a reason to leave it undocumented.

---

## ⛔ No Speculation

Never report something as working without verifying it yourself. Run the build, run the
tests, read the actual output — then report.

**Forbidden phrases:** "This should work...", "This looks like it will...", "This
probably...", "This might...", "I believe this...".

**If you cannot verify** — no Elixir/mix toolchain on PATH, no Docker, no network for
`mix deps.get` — say so explicitly, per `docs/anti-patterns.md`'s documented Docker
fallback. A requirement stays `in_progress`, not `done`, until someone (an agent with a
working toolchain, or the same agent via the Docker workaround) actually runs it and
reports real output.

---

## ⛔ No Background Wait For A Cross-Turn Notification

**A dispatched agent must complete its work within its own tool-call loop.** Once a
spawned subagent's own tool-call loop ends, nothing further ever runs on its behalf —
there is no mechanism that resumes it later. The cross-turn "notification when a
background task finishes" capability exists **only for the top-level orchestrating
session**; a subagent that starts a long-running or backgrounded operation and then
ends its turn expecting to be woken up by such a notification will never be woken up.
Its handoff stays claimed but unfinished, forever, until something else (typically ORCH)
notices the stall.

**Long-running operations — a full test suite, a build, anything that could tempt a
"start it and check back later" pattern — must be run and waited on synchronously.**
The agent's own tool call blocks until the operation actually finishes, and the agent
reads the real result before its turn ends. Do not background/detach a long operation
and end the turn early; do not report a step as claimed/in-progress and stop mid-way
assuming something will resume you.

**Worked example (WF03-ISS0193-20260821, filed as ISS-0213).** An ELIXIR-DEV subagent
dispatched for Step Final (git-merge) completed a rebase, verified it clean, and
committed a claim on the handoff — then stopped. Its own final reported text stated it
was "waiting for a background test monitor" to notify it once a long-running `mix test`
finished. That notification never came, because subagents don't get one. The run
stalled with a real side effect left behind (orphaned `mix test`/`erl.exe` processes
re-saturating the shared Postgres pool — the known ISS-0107 Windows recursion bug)
until ORCH detected the stall, verified the actual state, and completed the remaining
work itself under `HANDOFF_PROTOCOL.md` §4.1(a-2). This is a prevention rule, not a
restatement of that recovery procedure — §4.1 already handles the recovery correctly
once a stall has happened; this rule exists so the stall does not happen in the first
place.

**Name the concrete temptation, not just the abstract rule (ISS-0223).** Three
separate subagents in one later run (WF02-REQ071-20260821 — TEST-RUNNER, Step 4;
RELEASE-VALIDATOR, Step 5; ELIXIR-DEV, Step Final) each independently reached for a
background/monitor mechanism to run a slow full-suite `mix test`/`scripts/test_parallel.sh`
and then ended their turn waiting on it, despite this section already existing and being
mandatory reading. The rule as originally written stated the *concept* ("run
synchronously") but never named the specific tool affordances that recreate the exact
hazard — an agent can agree with the concept in the abstract and still reach for one of
these because they don't obviously map to "cross-turn notification" in the moment. Stated
plainly: **do not call `Bash`/`PowerShell` with `run_in_background: true` for this
purpose, do not call `Monitor` to watch it, do not call `ScheduleWakeup` expecting to be
resumed — none of these deliver their result back to a subagent's own turn.** If a test
run is slow, that is expected and fine; call it as a normal, blocking, foreground tool
call and let the turn simply take as long as the run takes. Every role whose job
routinely involves a slow full-suite run (`TEST-RUNNER`, `RELEASE-VALIDATOR`,
`ELIXIR-DEV` at Step Final) carries an inline pointer to this exact section in its own
role file for this reason — a pointer buried only in this shared file was not enough on
its own to stop the pattern from recurring three times in one run.

**Checked for an existing partial statement of this rule before adding it (ISS-0213):**
grepped `docs/agents/` and `.claude/agents/` for background/notification/async/polling
language and for existing `mix test` guidance (`core-directives.md`'s own "No
Speculation" section, `ORCHESTRATOR.md`, `WF-02_requirement_implementation.md`,
`.claude/agents/test-runner.md`, `.claude/agents/orchestrator.md`,
`.claude/agents/elixir-dev.md`). None of the existing text addresses a subagent
expecting a cross-turn wake — the closest is "No Speculation"'s instruction to actually
run `mix test`/`mix compile` yourself, which this rule extends (run it **synchronously,
to completion, in the same turn** — not merely "run it eventually"). Nothing found to
extend in place of a fresh statement, so this is new text, added here rather than as a
second independent statement elsewhere. `.claude/agents/elixir-dev.md` points back to
this section rather than restating it, since the concrete temptation (GIT_MERGE.md's
post-rebase `mix test`/`mix compile` checks) is real work ELIXIR-DEV actually does, but
the hazard itself is universal to any dispatched role, not specific to that one.

---

## ⛔ Never Call a Red Pipeline OK Without a Source

If CI is red or a `gh pr checks` call reports failure, you may not report it as
acceptable on your own judgement.

```bash
gh run view <run-id> --json jobs --jq '.jobs[]|"\(.name): \(.conclusion)"'
gh run view <run-id> --log-failed
```

Read the actual failing step. "It's probably a flaky runner" is not a valid attribution
without reading the log. If GitHub Actions itself is degraded, that's discoverable via
`https://www.githubstatus.com/api/v2/components.json` — check it before attributing a
never-started or cancelled job to an outage; a step that ran and genuinely failed is
never excused by an unrelated outage.

---

## ⛔ Failure Attribution Is Structural, Never By Count-Matching

**Canonical home for this rule.** `WF-02` Step 4/Step 5 and `WF-04` Step 1/Step 2 point
here; they do not restate the evidence.

Calling a test failure "pre-existing" (and therefore filed-and-forwarded rather than
this run's problem) is an **attribution**, and it has to be earned. **This is also what
decides which side of "Unblock-Everything"'s Scope boundary a test failure falls on** —
a failure attributable to this run blocks and is fixed here; a failure structurally
cleared is filed and forwarded. That decision is made by this procedure, not by
judgement.

To call a failure pre-existing you must show one of these three things, and name the
specific evidence:

1. **Structurally, this branch cannot have caused it** — the failing module and its
   dependencies do not appear in `git diff --name-only main...HEAD`; or
2. **It reproduces at the merge-base** — check out the merge-base, run it, quote the
   output; or
3. **A demonstrated mechanism outside this branch**, stated causally, and **evidenced by
   a measurement of the actual mechanism, never by assertion that one probably exists.**

`"known failure"` is not an attribution. Neither is "the previous run reported this."

**Route 3 exists because it is this suite's DOMINANT failure class, and it satisfies
neither of the first two.** Route 1 cannot express it (there is no failing file to check
against the diff) and route 2 is *least* reliable there, because an environmental
failure is often intermittent and may simply not reproduce in one merge-base run. Two
worked examples, both from WF03-ISS0106-20260821, both cleared this way:

- **Orphaned processes.** Stray `erl.exe` processes left by an earlier nested suite were
  found holding ~160 leaked connections to `letflow_test`, exhausting the pool and
  making the failure set vary run to run. The evidence was the enumerated processes and
  the measured connection count — not "it's probably the environment."
- **Stale rows.** Rows in a guard-backup table whose parent tenant no longer existed.
  The evidence was the queried rows and the demonstrated absent parent.

Route 3 is the one most easily faked, so hold it to its evidence: **if you find yourself
about to assert route 1 loosely because neither test quite fits, that is route 3 without
its measurement, and it is not an attribution.** If you can show none of the three, you
may not call the failure pre-existing — **report it as unattributed and file it.**

**Matching a previously-reported failure count or failure set is NOT evidence of
pre-existence — and a count differing by one or two is NOT evidence of regression.**
Both directions are stated deliberately: the symmetric error is the one that hides a
real regression inside expected noise.

**The measurement that settles this, rather than an argument.** In run
WF03-ISS0106-20260821, TEST-RUNNER ran the full suite **twice on the same commit, ten
minutes apart, and got 13 failures, then 15**. The immediately preceding run
(WF02-REQ066-20260820) had reported **14** on its own commit range, including two
Promotion-module failures that recurred in *neither* later run, and a `Check.TestTest`
subset of 2 against the later 3. Three runs, three different sets. TEST-RUNNER stated
the consequence explicitly: had "matches the previously-reported set" been its
criterion, its own first run would have scored as simultaneously a regression **and** a
fix.

**A failure not covered by an existing issue record is called out as such and filed**
(per `WORK_BOARD.md` §7 and "No Issue Left Local-Only" above) — never folded into "the
known set."

### In the diff is not the same as caused by the diff

Extra scrutiny is owed to any failing file that *does* appear in the diff. But the
standard for clearing it is a **causal argument**, not proximity or its absence.

Worked example, same run: `PinRebindTest` failed and was in the diff. The diff touching
it was a **whitespace re-wrap at lines 513-517**, while the failure was at **line 351**
via `provisioned_tenant/0` — and re-wrapping a list literal cannot make a Postgres
schema vanish mid-test. That reasoning, stated in the report, is what cleared it. "It's
in the diff, so it's ours" and "it's in the diff but looks unrelated" are equally
inadequate; write down the mechanism.

---

## ⛔ File Placement Rules

| File type | Directory |
|---|---|
| Handoff files | `handoffs/<RUN-ID>/` |
| Handoff registry | `handoffs/registry.json` |
| Design artefacts | `lib/letflow/design/` |
| Test specs | `test/specs/` |
| Test run reports | `test/reports/` |
| Requirement status history | `docs/status/requirement_status.index.yaml` (names the current volume) |
| Release decisions | `docs/status/` |
| Issue registry | `docs/issues/` |
| Scratch (one-off scripts, debug dumps, logs) | `scratch/` (git-ignored) |

**Scratch rule:** anything that is not a permanent project artefact — a one-off
verification script, a debug dump, a `.log` file — goes in `scratch/`, never the project
root, `lib/`, or `test/`.

**Before completing any handoff:** confirm no stray file landed in the project root
outside `mix.exs`, `mix.lock`, `README.md`, `CLAUDE.md`, `docker-compose.yml`,
`.gitignore`, `.env.example`. Move anything else to the correct directory or `scratch/`.

**Workflow artefacts are committed to git**, same as R-Co's convention: `handoffs/`,
`lib/letflow/design/`, `docs/issues/`, `docs/status/` are the audit trail. Commit them
at the end of the step that produces or modifies them, not just at Step Final.

**Never junction or symlink a large dependency directory** (`node_modules`, `deps`,
`_build`) into a throwaway `git worktree` to speed up setup, even for a quick mutation
probe you plan to discard. A junction is not treated as an opaque pointer by a recursive
delete on every platform — `git worktree remove` (or an agent's own cleanup `rm -rf`)
can follow the link and delete the real target's contents, not just the junction, taking
down every other worktree and the main checkout sharing that directory (ISS-0262,
ISS-0273's own `deps`/`_build` incident; ISS-0829's `node_modules` recurrence of the
same class three separate times — see `docs/anti-patterns.md`'s two prior entries on
this exact hazard before repeating it a fourth). **Always copy instead**: a real
recursive copy (`robocopy /E /MT:32` on Windows, `cp -r`/`rsync -a` elsewhere) of even a
~200MB `node_modules` completes in single-digit seconds — there is no performance case
for linking. If a `web/` or backend step fails with a wall of module-resolution/compile
errors that don't match anything in your own diff, check whether `node_modules`/`deps`
is unexpectedly empty before assuming a code regression.

---

## ⛔ Bookkeeping Is Not Optional

**1. `handoffs/orchestrator.log` is append-only.** Open with append mode, never
overwrite. A commit that shrinks this file's line count is a defect, not a cleanup —
flag it immediately if you ever observe one, don't assume it was intentional.

**2. Timestamps come from the clock, never from memory.**

```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```
```bash
date -u +"%Y-%m-%dT%H:%M:%SZ"
```

`(Get-Date).ToString(...)` without `.ToUniversalTime()` silently emits local time
wearing a `Z` suffix — always call `.ToUniversalTime()` first. `completed_at` must never
precede `started_at`.

**3. The requirement run history is append-only, and it is kept in bounded volumes.**
Start at `docs/status/requirement_status.index.yaml`; it names the current volume. Read
**that volume in full** before appending, preserve its schema, append — never rewrite,
reorder or delete an entry, in any volume. An agent has gotten this wrong before (see
`docs/anti-patterns.md`).

**Precedence, so this is not ambiguous:** "Load Scoped Context, Not Whole Files" above is
the general rule and it governs *closed* volumes and every other large file — read those
with a targeted read only: the Read tool with `offset`/`limit`, or `grep`/`sed`/`awk` under
Bash, or `Select-String`/`Get-Content -TotalCount` under PowerShell (this repo runs both
shells and `grep` does not exist in PowerShell — see the pairs at `:156-161` above). The
**current** volume is the single exception, and it is an exception only because the roll
rule (`roll_rule:` in the index — that file holds the authoritative ceilings) keeps it
small enough that the full read is actually executable. If a full read of the current
volume is ever refused or truncated, that is a defect in the roll rule: stop and file it
(ISS-0119 is the precedent), do not substitute a partial read and append anyway.

**4. Lint your own handoff before finishing.** Before your step is done, run

```
mix letflow.lint_handoffs --dir <path to the handoff file you just wrote>
```

against the file you are about to hand off (ISS-0819). This is scoped to your one file
— it is not a substitute for the full-corpus `mix letflow.lint_handoffs` that already
runs, unconditionally and unchanged, as part of `mix letflow.check` at the CI gate (see
`HANDOFF_PROTOCOL.md`'s Enforcement note). It exists so a schema violation is caught and
fixed at the moment of authorship, not discovered — possibly stacked with several other
agents' violations in the same run, masking each other — only when the CI gate runs
after the whole pipeline has already completed.

---

## ⛔ Never Satisfy a Gate by Editing What It Measures

If a gate blocks you, fix the condition it is detecting. **Never make the detector stop
reporting.** Forbidden regardless of how the task is phrased: renaming output tokens so
a string-matching gate stops matching, deleting or defaulting an error path a gate looks
for, wrapping a failing command so its exit code is masked.

Prefer exit-code gates over string-matching gates when you write a new one — an agent
cannot satisfy an exit code by renaming a label. If a gate itself is wrong, escalate to
change the gate's definition (flag it in your handoff's `result.issues`); do not
quietly satisfy it by other means.

---

## ⛔ Output File Format Rules

**YAML for everything except handoff files.** Handoff files (`handoffs/<run-id>/*.json`,
`handoffs/registry.json`) stay JSON because ORCH reads/writes them as structured data.
Test reports, requirement status, release decisions, issue records — all YAML, matching
the format Letflow's `docs/status/requirement_status.yaml` and `docs/requirements.yaml`
already use.


---

## ⛔ R2 Evidence Or It Did Not Happen

A validator's output lists every acceptance criterion it checked, each with at least one concrete
citation: `file:line`, a test name, or a command with its return code. A `PASS` without citations counts
as not run: ORCH dispatches the validator again once; a second bare PASS goes to the supervisor.

## ⛔ R3 Validators Start From A Fresh Packet

ORCH gives a validator only: the issue number, the design file path, the branch and diff range, and the
role file. Never the producer's summary, ORCH's opinion, or phrases like "should pass". The validator
reads `gh issue view N --comments` and runs `git diff origin/main...HEAD` itself.

## ⛔ Merge Discipline: Serial Slots, One PR Per Issue, Batched Filings

*(Added 2026-10-06 from the Q-957 incident: one PR was restarted FIVE times — about 35 minutes
of backend CI each — because docs-only PRs kept landing on `main` mid-run. The repo requires an
up-to-date branch (`strict` status checks) and has no merge queue: the repo is owned by a User
account, not an organization.)*

1. **One PR per issue/requirement.** Do not bundle unrelated fixes; do not split one issue
   across several PRs without a reason recorded in the PR body.
2. **Serial merge slots.** The supervisor (or, with no supervisor, the ORCH of the session that
   first opened a functional PR) announces merge slots. **Nobody merges a docs/chore/bookkeeping
   PR while a functional PR is in CI.** Docs and chore PRs wait for a slot, are rebased only
   when their slot comes, and are merged one at a time.
3. **Batch filings.** Issue/requirement filings, RUN_DONE log lines and registry bookkeeping
   go into the next functional PR of the same session, or into ONE batched docs PR per slot,
   never one PR per filing. Because the local `docs/issues` record may land later than the GitHub
   issue, the issue body must be self-sufficient (evidence, fix direction, acceptance criteria);
   a worker that is handed an issue whose local record is not on `main` yet works from the issue
   text and does not re-file.
4. **Update-branch only when the line is quiet.** If `main` moves under your in-flight PR from a
   source you do not control, tell the supervisor instead of restarting your run in a loop.
   Never `--admin`-merge to get around staleness.

---

## ⛔ CI Failures Are Classified; A Repeat Is A Defect; Run CI-Shaped Locally First

*(Added 2026-10-06.)*

1. **Failure-class field.** Every time a PR's CI fails, record in the PR (comment or body) a
   **failure class**: `flake` (the test passed on identical code on rerun and the cause is
   timing/infra), `defect` (reproducible in this PR's code or its base), or `infra`
   (runner/queue/network). Cite the failing test file and the run id.
2. **A second failure of the same file or class is a defect, not a flake.** Do not rerun a
   second time; diagnose it (ISS-0977 / RT-6 recurred exactly this way).
3. **CI-shaped local run before every push.** Stage the files first (the handoff and
   requirement-status checks read the git index), export `MIX_TEST_PARTITION` as `scripts/test_parallel.sh` does (e.g. 3) for
   subprocess/config tests (the workflows do not set it themselves), and run the checks the gate runs: `mix compile --warnings-as-errors`,
   `mix format --check-formatted`, `mix letflow.lint_handoffs`, `mix letflow.check_issue_refs`,
   `mix letflow.check_boundaries`, and, if any status volume or the index changed,
   `test/docs/requirement_status_invariants_test.exs` (A9: the index `entries:` count must equal
   the on-disk entries after every merge of `main`).
