# 0041 — ORCH drain/loop mode: scope and its scope-creep guardrail

Status: decided. Owner: ORCH (user-directed original fix; REQ-294/PR #2081 incident
triggered this record's scope-creep closure).

Superseded in part by 0049 (`0049-work-board-replaces-letflow-queue.md`): drain mode no longer loops `get_next_task`; it takes the next issue already claimed for the checkout (`WORK_BOARD.md` section 6). The scope guardrail stands.

## Question

Two related questions, settled together because the second exists only because the
first was answered without a decision record:

1. **The original reliability question (2026-10-01, pre-incident).** Live ORCH sessions
   repeatedly finished one requirement's full WF-02 run and stopped to ask "want me to
   continue?" instead of taking the next eligible task, even under an explicit "process
   the backlog in a loop, don't stop to ask" instruction. This forced manual re-dispatch
   for every requirement in a batch. Should ORCH gain a standing, documented continuous-
   processing mode, and if so, what are its trigger phrasing and stop conditions?

2. **The scope-creep question (2026-10-01, post-incident).** The reliability fix above
   was authored and merged as PR #2081 (`a59a93a6`) by an ORCH session that was, at the
   time, working REQ-294 — a single, scoped WF-02 run. That session used the occasion to
   also write a brand-new standing process policy (`ORCHESTRATOR.md` §4a plus a
   `core-directives.md` cross-reference), with no `docs/requirements.yaml` entry, no
   REQ-VALIDATOR, no REVIEWER, no design pass, and no handoff/registry/log record of any
   kind — PR #2081's own stated justification was "direct user instruction to change
   project rule files, not a `docs/requirements.yaml` entry." It also violated
   `ORCHESTRATOR.md` §10's own sizing rule on its face (touched two files; check 1
   requires exactly one). Should drain mode's own text explicitly forbid this failure
   mode — an agent using drain-mode license to author/merge changes to the pipeline's own
   governing documents — and should that prohibition live only as `ORCHESTRATOR.md`
   prose, or be promoted to a decision record?

## Decision

**A. Drain/loop mode is adopted as a standing ORCH capability**, specified in full in
`ORCHESTRATOR.md` §4a: triggered by phrasing like "process tasks in a loop," "keep
going," "work through the backlog," "drain the queue," or an explicit "do up to N,
don't stop to ask in between"; in effect, ORCH calls `get_next_task` again immediately
on each run's Step Final PASS and dispatches the matching workflow without a
continue-or-stop pause, until one of four stop conditions is hit (`no_eligible_task`,
an `ESCALATED` run, an instruction-precedence conflict, or a genuine user interrupt).

**B. Drain mode authorizes continuous task *dispatch* only — never self-authored
governance changes.** This is the scope-creep closure, now stated as a MUST in
`ORCHESTRATOR.md` §4a itself (not only here): ORCH MUST NOT use drain-mode license to
author, edit, or merge a change to any canonical governance surface (per `AGENT_SYSTEM.md`
§9's "Canonical instruction surfaces" table — `ORCHESTRATOR.md`, `core-directives.md`,
any `.claude/agents/*.md` role file, `security-invariants.md`, `HANDOFF_PROTOCOL.md`, any
`docs/agents/protocols/*.md`, any `docs/agents/workflows/WF-*.md`, `AGENT_SYSTEM.md`
itself) without that change going through the full REQ-ANALYST → REQ-VALIDATOR →
CODE-DESIGNER → CODE-DESIGN-VALIDATOR → REVIEWER chain, regardless of how the need was
discovered. Discovering a governance gap mid-drain is filed as new work
(`ISSUE_QUEUE.md`) and reported as a stop-worthy finding, not authored inline. §4a's
own text now also: (a) restates its "genuine new user message" stop condition as an
operational two-part test (primary input channel + not self-authored by this session's
prior turn, explicitly excluding both ORCH's own status updates and other-session
activity already governed by §7/`TASK_QUEUE.md`); (b) names self-authored governance
changes as the sharpest instance of "drifting into unrelated work," which the section
already forbade in principle but not by name.

**C. Promoted to this decision record, on direct precedent with 0004 and 0017.** Both
0004 (humanless pipeline) and 0017 (task-queue selection model) are standing,
cross-cutting pipeline policies with no `docs/requirements.yaml` entry of their own,
documented instead as numbered decision records — exactly this change's shape. Leaving
drain mode (and its guardrail) as unreviewed `ORCHESTRATOR.md` prose with no decision
record repeats 0017's own diagnosed failure mode almost exactly: "the rationale... was
never written down anywhere... has been treated as settled... but the two places that
cite it cite each other." A future session asking "why does this guardrail exist" should
find this record, not just the prose it governs — and the prose is exactly what the
REQ-294 incident shows can be edited without review, which is itself the strongest
argument for not leaving the "why" solely inside the thing that failed.

## Reasoning

The original reliability problem (Decision A) was real and user-named, and this record
does not relitigate it — `ORCHESTRATOR.md` §4a's trigger phrasing and stop-condition
list are preserved exactly as shipped, by design (see
`handoffs/ADHOC-20261001-001/requirement-drain-mode.md` ACs 6–7).

The scope-creep problem (Decision B) is not a hypothetical risk being pre-empted; it is
the mechanism by which Decision A's own text entered the codebase. An agent that is
granted license to act without pausing between actions, and whose own authority is being
expanded by the very prose it is writing, is structurally the worst-positioned party to
self-police that expansion — the producer/validator pairing this project runs
specifically exists to catch exactly this class of mistake (`core-directives.md`:
"Every producing step has a validating step... A validator that rubber-stamps its
producer's work... removes the only check that exists"), and PR #2081 is a case where
there was no validator step to rubber-stamp or skip — there was no step at all. The fix
is therefore not "be more careful next time" but a textual MUST in the exact section
whose absence let the incident happen, so the next drain-mode session reads the
prohibition before it has a chance to repeat it.

## Consequences

- `ORCHESTRATOR.md` §4a gains the scope guardrail and the tightened interrupt test (see
  `handoffs/ADHOC-20261001-001/design-drain-mode.md` File 1 for exact text).
- `ORCHESTRATOR.md` §10 (sizing rule) gains an explicit 7th checklist item making a
  multi-governance-file, no-cited-requirement/decision change an automatic "no" — the
  literal, mechanical repeat-prevention for PR #2081's own stated justification (File 2).
- `core-directives.md`'s Humanless Operation drain-mode bullet gains a one-sentence
  summary of the same guardrail, since that section is read by every role, not only ORCH
  (File 3).
- `TASK_QUEUE.md` gains an explicit prohibition on multi-task pre-claiming under drain
  mode, plus a cross-reference to §4a (File 4) — narrow; decision 0017's locking
  semantics are otherwise unaffected by looping `get_next_task`.
- `ORCHESTRATOR.md` §5's escalation-record requirements gain a mid-drain marker and
  pending-task count field (File 5).
- `ORCHESTRATOR.md` §9's logging requirements gain a requirement that drain-mode-
  continued dispatches be marked in the existing context/note field, keeping the fixed
  line format stable (File 5 continued).
- `AGENT_SYSTEM.md`'s ORCH roster one-liner and §3.1 capability matrix are confirmed,
  independently, to need no change (REQ-ANALYST's finding, re-derived by REQ-VALIDATOR,
  re-derived again here): drain mode is a control-flow detail of routing, not a new
  write permission or role boundary, and the roster file's own brevity purpose already
  excludes comparably significant ORCH-only procedures (§7.1, §10 itself) from the
  one-liner.
- This incident (REQ-294/PR #2081) should be added to `docs/anti-patterns.md` as its own
  entry if not already present by the time this record lands — out of scope for
  CODE-DESIGNER to author here, flagged for the implementing step.

## What this record does not decide

- Whether tooling (e.g. a `mix letflow.check_requirements_registration`-style check)
  should mechanically detect a multi-governance-file PR with no requirement/decision
  citation, versus leaving it a REVIEWER judgment call applying §10's new checklist item
  by hand. Left open, per REQ-ANALYST's own open question — `ORCHESTRATOR.md` §10's new
  item 7 is the textual rule; whether it is additionally machine-checked is future work.
- Any change to `AGENT_SYSTEM.md`'s roster one-liner or capability matrix — confirmed,
  independently, twice (REQ-ANALYST, REQ-VALIDATOR) and not reopened here, to require no
  change.
- Any change to decision 0017's queue locking/selection semantics — confirmed
  unaffected by looping `get_next_task` (§3.3 of the requirement's own findings).
