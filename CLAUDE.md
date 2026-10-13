# CLAUDE.md — Letflow

Read automatically by Claude Code at session start. Letflow (working
name during early development: RoCo) is a multi-tenant BPM platform in
its own right — this file stays short on purpose; it is a pointer, not
a rulebook.

## What this project is

An Elixir/OTP multi-tenant BPM platform. See `README.md` in full
before doing anything, especially "Migration status." Letflow began as
a staged rewrite of a predecessor system, R-Co
(`c:\Users\tvolo\dev\ai-dala\R-Co\`); that migration is effectively
complete (see `docs/migration/README.md`'s stage breakdown, S0–S9),
so `docs/migration/` is retained as the historical build record —
read the relevant stage file when its rationale still matters for a
change, but do not treat it as live instructions for how the project
should be shaped going forward.

Letflow is not backend-only. As of 2026-08-21 it also owns **`web/`**,
the React/TypeScript SPA migrated out of R-Co (spec in
`docs/frontend/`, stage S8), and the specification for a **Flutter
mobile tier** that does not exist yet (spec in `docs/mobile/`, stage
S9). See `docs/migration/decisions/0011-frontend-ownership.md` and
`0012-mobile-tier-stack.md`. Any text still saying `web/` is out of
scope to rewrite predates that and is stale. A few findings from
early development (idiomatic OTP usage among them) are folded
directly into the stage-2 and stage-3 migration docs where they're
still relevant, rather than tracked separately. One of those early
findings — running a supervised process per workflow instance — was
explicitly decided against: REQ-045 resolved the S3 running-instance
shape to a plain transactional context module (`Letflow.Engine.create/2`),
with concurrency arbitrated by Postgres row locks, not a supervised
process per instance. `Letflow.InstanceSupervisor` exists but is
deliberately empty (see its own moduledoc); `Letflow.Engine`'s
moduledoc ("Process-vs-row decision") has the full reasoning.

## Agent roster

This project runs a full agent-pipeline shape, not a trimmed subset —
every producing role is paired with an independent validating role,
the pipeline runs commit→push→merge→CI→local-repo-update with no
human gate, and every role/workflow/guide is written explicitly
enough for a weak or inexpensive model to execute reliably. The shape
originates from the same pipeline used to build R-Co
(`c:\Users\tvolo\dev\ai-dala\R-Co\`), kept here as provenance, not as
the reason to run it this way — see
`docs/migration/decisions/0004-humanless-pipeline.md` for the full
rationale on its own merits (this supersedes an earlier, smaller
4-agent framing this file used to describe). Full roster, capability
matrix, and artifact locations: [`docs/agents/AGENT_SYSTEM.md`](docs/agents/AGENT_SYSTEM.md).
Routing logic, gates, rework/escalation rules, stage-gate enforcement:
[`docs/agents/ORCHESTRATOR.md`](docs/agents/ORCHESTRATOR.md).

| `AGENT_ID` | Role | Canonical instructions |
|---|---|---|
| `ORCH` | Routes work, dispatches workflows (WF-01–WF-05), enforces gates, merges once green. Never writes application code itself. | [`.claude/agents/orchestrator.md`](.claude/agents/orchestrator.md) |
| `REQ-ANALYST` | Drafts requirements into `docs/requirements.yaml` | [`.claude/agents/req-analyst.md`](.claude/agents/req-analyst.md) |
| `REQ-VALIDATOR` | Validates requirements — hard gate on REQ-ANALYST | [`.claude/agents/req-validator.md`](.claude/agents/req-validator.md) |
| `CODE-DESIGNER` | Produces design artefacts in `lib/letflow/design/` before implementation | [`.claude/agents/code-designer.md`](.claude/agents/code-designer.md) |
| `CODE-DESIGN-VALIDATOR` | Hard gate on CODE-DESIGNER's design | [`.claude/agents/code-design-validator.md`](.claude/agents/code-design-validator.md) |
| `ELIXIR-DEV` | Implements/changes `lib/letflow/` and `priv/repo/migrations/` | [`.claude/agents/elixir-dev.md`](.claude/agents/elixir-dev.md) |
| `FRONTEND-DEV` | Builds and changes `web/` — Letflow's own React/TS SPA — and wires it to Letflow's API | [`.claude/agents/frontend-dev.md`](.claude/agents/frontend-dev.md) |
| `MOBILE-DEV` | Builds `apps/mobile/` (Flutter) per `docs/mobile/` | [`.claude/agents/mobile-dev.md`](.claude/agents/mobile-dev.md) |
| `SECURITY-REVIEWER` | Hard gate on tenant-data-path changes — `docs/agents/instructions/security-invariants.md` | [`.claude/agents/security-reviewer.md`](.claude/agents/security-reviewer.md) |
| `REVIEWER` | Hard gate — idiomatic OTP usage, supervision integrity, scope creep, decision-record consistency | [`.claude/agents/reviewer.md`](.claude/agents/reviewer.md) |
| `TEST-DESIGNER` | Writes test specs and test code | [`.claude/agents/test-designer.md`](.claude/agents/test-designer.md) |
| `TEST-DESIGN-VALIDATOR` | Hard gate on TEST-DESIGNER's coverage | [`.claude/agents/test-design-validator.md`](.claude/agents/test-design-validator.md) |
| `TEST-RUNNER` | Runs `mix test`, diagnoses failures, writes structured reports | [`.claude/agents/test-runner.md`](.claude/agents/test-runner.md) |
| `ISSUE-FIXER` | Root-cause diagnosis for a queued issue — does not implement the fix itself | [`.claude/agents/issue-fixer.md`](.claude/agents/issue-fixer.md) |
| `RELEASE-VALIDATOR` | Independently re-verifies acceptance criteria before a requirement/stage is marked done | [`.claude/agents/release-validator.md`](.claude/agents/release-validator.md) |
| `DOC-UPDATER` | Flips requirement status, appends status history, updates docs | [`.claude/agents/doc-updater.md`](.claude/agents/doc-updater.md) |
| `UAT-RUNNER` | Scenario-based acceptance checks against a real running instance (load-bearing from S7 on) | [`.claude/agents/uat-runner.md`](.claude/agents/uat-runner.md) |
| `PRODUCT-OWNER` | Reads every BA-<VERTICAL> sign-off for a UAT run and writes the platform's plain-language release recommendation ("should we ship?") — distinct from RELEASE-VALIDATOR's technical "is it safe to ship?" | [`.claude/agents/product-owner.md`](.claude/agents/product-owner.md) |
| `PROCESS-AUDITOR` | Read-only independent review of one scope's process design (definitions, forms, scenarios, roster, seed scripts) before it is run; a FAIL verdict blocks UAT for that scope only — never edits what it audits, never signs off run results | [`.claude/agents/process-auditor.md`](.claude/agents/process-auditor.md) |

**Default `AGENT_ID`:** if none is stated, default to `ORCH`. `ORCH`
may act directly instead of routing through the full chain only when a
change passes all seven checks of the sizing rule in
`docs/agents/ORCHESTRATOR.md` §10 — run that checklist rather than
judging by feel. Anything else goes through the full workflow; there is
no human backstop to catch a skipped validator.

## Where work comes from

`docs/requirements.yaml` is the content authority for work packages —
each is sized to one agent turn with an explicit `owner`,
`description`, and `acceptance_criteria`. **Task *selection* is the
GitHub work board's, not this file's:** a work item is a GitHub issue, its
number is the only machine id, labels carry state, and the supervisor
coordinates claims — see
[`docs/agents/protocols/WORK_BOARD.md`](docs/agents/protocols/WORK_BOARD.md).
ORCH works only an issue claimed for its checkout (`scripts/gh_work.sh
claims`); it never picks from this file, and never labels a claim. Each
requirement entry carries `gh: <issue number>`. When told to work on a
specific `REQ-XXX` or issue, read its entry in full before touching code,
same as always. (`TASK_QUEUE.md` and `ISSUE_QUEUE.md` are superseded
pointers; see decision 0049.)

Every requirement carries a `stage` (S0–S8, tie back to
`docs/migration/`). `docs/migration/stage-N-*.md` holds migration
design rationale and REVIEWER sign-off per stage. Only Stage 0 is
currently broken into requirements — if the next `pending` requirement
doesn't exist yet because its stage hasn't been expanded, that's
expected; expand the next stage's requirements (matching this file's
existing sizing/schema) rather than skipping ahead into an unscoped
stage.

After finishing a requirement: flip its `status` in
`docs/requirements.yaml`, and append one event to the current
run-history volume (find it via
`docs/status/requirement_status.index.yaml`) —
started/done/blocked/cancelled/revised/verified, with a real UTC
timestamp from the clock, not memory.

## Core rules (apply to every agent)

Full statement of these (and more) lives in
[`docs/agents/instructions/core-directives.md`](docs/agents/instructions/core-directives.md) —
summarized here:

- **No speculation.** Never report "this should work" or "tests
  should pass." Run it (`mix test`, `mix compile`) and quote the
  actual result. If you can't run it in this environment — no
  toolchain, or `mix deps.get` has no network access (see README
  Notes) — say so explicitly instead of guessing.
- **Zero manual work.** Don't tell the user to run a command you can
  run yourself. Apply migrations, run tests, start `docker compose`,
  commit, push, open the PR, and merge yourself — see "Humanless
  operation" below.
- **Every producing step has a validating step.** No agent's claim
  that it finished a task is itself evidence the task is done — a
  design is checked by a design validator, code by a security/idiom
  reviewer, tests by a test-design validator, a "done" status by
  RELEASE-VALIDATOR re-deriving it independently. This is the
  project's central redundancy principle, adopted specifically so the
  pipeline stays reliable even when the executing model is weak — see
  `docs/migration/decisions/0004-humanless-pipeline.md`.
- **Humanless operation.** There is no human reviewer, approver, or
  merge-clicker in this pipeline. Agents commit, push, open PRs, wait
  for CI, and merge to `main` at their own discretion once all gates
  are green — this is pre-authorized, not something to pause and ask
  about. Errors are correctable via a later fix run; there is no
  production deployment at stake yet.
- **Don't silently re-decide what a decision record already settled.**
  S0's decision records (`docs/migration/decisions/`) are load-bearing
  for every later stage — if a stage's requirement seems to need a
  framework/library choice that contradicts one already on record,
  flag it and get REVIEWER sign-off rather than quietly diverging.
- **Merge discipline** (`core-directives.md`): one PR per issue; no docs/chore merges while a functional PR is in CI;
  classify every CI failure (a repeat is a defect); run CI-shaped locally before pushing; overlap-check before filing.
- Check `docs/anti-patterns.md` before non-trivial changes, and add to
  it when you find a mistake worth not repeating.

## Mandatory reading at session start

- `README.md` (full)
- `docs/agents/AGENT_SYSTEM.md` — full roster and how work flows through it
- `docs/agents/instructions/core-directives.md` — cross-cutting rules binding every role
- `docs/requirements.yaml` — find or confirm the requirement in scope
- `docs/migration/README.md` — stage breakdown
- `docs/anti-patterns.md` (if it has entries)
