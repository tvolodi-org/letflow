# 0004 — Full agent pipeline, humanless operation, redundant validation

Status: decided. Owner: ORCH (user-directed).

## Question

R-Co runs an 18-role agent pipeline with a producer/validator pair for nearly every
step, JSON handoff files, a mandatory git-setup/git-merge wrapper, and a human-free
commit→push→merge→CI loop. Letflow's `CLAUDE.md` originally described a deliberately
smaller 4-agent system ("keep it light... roster grows only when a stage actually needs
it"), reasoning that R-Co's ceremony was overhead a young, single-track migration
codebase didn't yet need.

The user overrode that framing directly: reproduce R-Co's full agent system in Letflow,
not a trimmed version, and apply the same principles both to Letflow's own development
(this VS Code / Claude Code environment) and — later, as its own migration-stage
capability, not built yet — to Letflow's runtime, where end-users' business processes
get designed, implemented, tested, and deployed by agents with no human in the loop
either.

## Decision

Adopt R-Co's full agent-pipeline shape for Letflow's own development, with three
non-negotiable principles carried forward exactly as stated by the user, not softened:

1. **Every producing agent has a paired validating agent.** Requirement drafting →
   requirement validation. Design → design validation. Backend/frontend implementation →
   idiom review + security review. Test design → test-design validation. Documentation
   update → an independent check that the update actually happened. No step's completion
   is accepted on the producer's own say-so.

2. **Fully humanless operation.** Requirement → design → implementation → test →
   validation → UAT → commit → push → merge → CI → local-repo-update, all performed by
   agents at their own discretion, with no human approval gate anywhere in the chain.
   Merge itself is bounded, not unconditional, by `main`'s required-status-checks branch
   protection (0018): the ordinary merge command succeeds only when both CI gates are
   green, and bypassing a red or pending gate requires the same agent to take a second,
   distinct, individually-logged action (`--admin`) rather than being available by
   default — see 0018 for the full mechanism. This does not reintroduce a human
   checkpoint; it makes the agent's own judgement call visible in the merge history
   instead of invisible in an unprotected one.
   There is no production deployment and no real user data at stake at this stage of the
   project — errors are correctable via a later WF-03 (Issue Resolving) run, not
   prevented by adding a human checkpoint. This explicitly rejects R-Co's own §11
   "Workflow Skip Gate" pattern of asking a human before skipping ceremony — there is no
   human to ask, so ORCH may only skip what this file or `core-directives.md` explicitly
   pre-authorizes, never on its own judgement call.

3. **Documentation and role definitions are sized for weak-model execution.** Every
   role file, workflow doc, and developer guide must be explicit and mechanical enough
   that a small or inexpensive model, with no memory of this decision's reasoning beyond
   what's written down, still produces reliable, in-scope, average-or-better-quality work
   by following the steps as written. This is the justification for keeping R-Co's
   verbose, checklist-heavy style rather than Letflow's earlier terse-file style —
   redundancy here is not waste, it is what makes weak-model execution safe.

**Scope of this decision:** the full roster applies to *how Letflow itself is built*
(this repository's own `lib/letflow/`, `test/`, `priv/repo/migrations/`) starting now.
It does **not** yet build the runtime-mode capability (Letflow's own BPM engine letting
*its* end-users' business processes be agent-designed/implemented/tested/deployed) — that
is a distinct future migration-stage requirement, tracked as a forward note in
`docs/migration/README.md`, using the same three principles once it starts. Building
runtime-mode now, before the engine that would run it exists, would be scope creep
against the stage that hasn't been reached yet.

**What is explicitly NOT reproduced from R-Co, because it targets a problem Letflow
doesn't have yet:** the BO-SWIFTROUTE/BO-VORTEX/BO-MERIDIAN business-owner personas and
PRODUCT-OWNER role (R-Co's UAT layer exists to represent three fictional tenant
companies' business interests during acceptance testing — Letflow has no tenant business
scenarios to represent yet; UAT-RUNNER is defined now but the BO-persona layer is
deferred to when S7 actually starts and there is a concrete scenario corpus to validate
against, per `docs/migration/stage-7-simulation-uat-parity.md`). The full Python tooling
R-Co built to enforce its protocols mechanically (`lint_handoffs.py`,
`check_github_status.py`, `verify_schema_baseline.py`, etc.) is also not reproduced yet —
those scripts encode lessons from specific R-Co incidents (timestamp corruption,
registry truncation) that Letflow hasn't hit. The protocols they enforce are written
down in full; the enforcement scripts are noted as follow-up work
(`docs/agents/protocols/HANDOFF_PROTOCOL.md`'s "Enforcement" section) rather than
blocking this pass.

## Reasoning

The user was explicit that recommending a lighter roster "because something somewhere
is recommended" was not useful — the actual requirement is redundancy sufficient for
mediocre-model reliability, not minimalism. R-Co's own history (documented across
`docs/agents/instructions/core-directives.md` and `HANDOFF_PROTOCOL.md`'s cited
incidents — 1963-handoff audit finding 44%→0.4% compliance drop on unenforced
bookkeeping rules, 1340 lines of audit log destroyed by an unreviewed squash-merge) is
direct evidence that a pipeline without independent validation at every step degrades
silently under exactly the conditions Letflow will now run under: agents operating
without a human catching drift.

## Consequences

- `CLAUDE.md`'s "Agent roster" section changes from a 4-role table to the full roster
  in `docs/agents/AGENT_SYSTEM.md`.
- Every workflow that touches `lib/`, `priv/repo/migrations/`, or `test/` is wrapped in
  a git-setup/git-merge pair per `docs/agents/protocols/GIT_SETUP.md` and `GIT_MERGE.md`,
  and merges to `main` without waiting for human review. As of 0018, that merge is also
  gated by GitHub branch protection on `main`, not left to the wrapper's own discipline
  alone.
- `docs/requirements.yaml`'s existing schema (id/owner/status/description/
  acceptance_criteria/depends_on) is preserved — the new pipeline routes work through it,
  it does not replace it with R-Co's separate functional-requirements document.

## Addendum (2026-09-16, REQ-359) — BO-*-equivalent deferral actioned

The "What is explicitly NOT reproduced from R-Co" section above deferred the
BO-SWIFTROUTE/BO-VORTEX/BO-MERIDIAN business-owner-persona layer until Letflow had a real
tenant-business scenario corpus (S7) to validate against. REQ-358 confirmed both
preconditions fired (S7 done; 29-scenario corpus exists) and REQ-359 actions the
deferral: a generic `BA-<VERTICAL>` role (`.claude/agents/ba-analyst.md`, parameterized
by `docs/agents/ba-personas/<vertical>.yaml`) replaces the closed three-persona pattern,
keyed on Letflow's open tenant-vertical/solution-pack set instead of R-Co's three
fictional companies — see `lib/letflow/design/req359-ba-role.md` for the full design and
`docs/agents/AGENT_SYSTEM.md` §3/§3.1/§6 for the resulting roster/capability/artifact-
location entries. This addendum does not revise the original "Decision"/"Reasoning"
sections above, which remain correct as stated for the period before S7's precondition
held. The `PRODUCT-OWNER`-equivalent half of the original deferral remains open,
tracked as REQ-361.

## Addendum (2026-09-17, REQ-361) — PRODUCT-OWNER-equivalent deferral actioned

The 2026-09-16 addendum above actioned the BO-*-equivalent half of the original
"What is explicitly NOT reproduced from R-Co" deferral (the BA-<VERTICAL> role)
and left "The `PRODUCT-OWNER`-equivalent half of the original deferral remains
open, tracked as REQ-361." REQ-361 actions that remaining half: a
`PRODUCT-OWNER` role (`.claude/agents/product-owner.md`) ports R-Co's rubric —
reads every BA-<VERTICAL> sign-off for a UAT run (never invoking a BA persona
directly), enforces a single-BLOCKER-blocks-release rule, cross-checks
MUST-severity acceptance-criteria coverage against `docs/requirements.yaml`,
arbitrates cross-vertical disagreements (routing to REQ-ANALYST when the
underlying requirement is ambiguous), and writes a plain-language release
recommendation (`test/uat-reports/po-signoff-<run_id>.yaml`) — see
`lib/letflow/design/product-owner-role.md` for the full design and
`docs/agents/AGENT_SYSTEM.md` §3/§3.1/§6 for the resulting roster/capability/
artifact-location entries. `docs/agents/workflows/WF-05_uat_run.md` gained a
Step 4 for this role, sequenced after every BA-<VERTICAL> sign-off and strictly
before `RELEASE-VALIDATOR`, matching R-Co's own WF-05 sequencing precedent ("it
never runs in parallel with a BO agent"). This addendum does not revise the
original "Decision"/"Reasoning" sections, nor the 2026-09-16 addendum, which
remain correct as stated for their own periods. With both halves of the
original R-Co-parity deferral now actioned, "What is explicitly NOT reproduced
from R-Co" no longer has an open item tracked against this decision record.

## Addendum (2026-10-19, REQ-521) — risk-tiered pipeline (SHORT and HIGH tiers)

This addendum does not revise the original "Decision"/"Reasoning" sections or the earlier
addenda. It records that the pipeline now has risk tiers, defined once in
`docs/agents/ORCHESTRATOR.md` section 13 (the path lists and the chains are there, not here).

**Approval, as relayed.** The letflow-9a audit of 2026-10-12 relayed the user approval; the user's
direct statement to the supervisor on 2026-10-19 (letflow-9a's audit decisions, and audit results
registered as issues, have absolute authority except the user's direct orders) was relayed by the
supervisor to letflow-2 (supervisor ruling 1, ADOPT). The user's statement reached this repository
only through the supervisor. Sources: the letflow-9a team audit relayed 2026-10-12, filed as
GH #2422; the supervisor's relay of 2026-10-19 on letflow-9a's priority. Nothing here is asserted
as said directly to this repository.

**Reasoning (the GH #2422 team audit).** 123 of 186 non-merge commits on `main` since 2026-10-01
touch nothing under `lib/`, `web/`, `apps/` or `priv/`. Approximate October rejection counts:
REVIEWER 0 of 45, SECURITY-REVIEWER 0 of 28, RELEASE-VALIDATOR 1 of 29, TEST-DESIGN-VALIDATOR 1 of
36, CODE-DESIGN-VALIDATOR 12 of 38. A full chain on a test-only or document-only change buys little.

**Principle 1 is unchanged.** "Every producing step has a validating step" still holds: the SHORT
chain keeps one validator.

**HIGH tier (auditor decision of 2026-10-19, audit #2874 R5, GH #2876).** The opposite end: a FULL
change that is large and touches security-sensitive areas gets one outside review in addition
to the full chain. Thresholds and paths are in ORCHESTRATOR.md section 13.
