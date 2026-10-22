# Letflow — Agent System Overview

**Audience:** every agent operating within this project. Read this before beginning any
task, alongside `docs/agents/instructions/core-directives.md`.

---

## 1. Purpose

This is the root reference for Letflow's multi-agent development pipeline. It replaces
the earlier 4-agent roster (`ORCH`/`ELIXIR-DEV`/`TEST-RUNNER`/`REVIEWER`) with the full
roster below, per `docs/migration/decisions/0004-humanless-pipeline.md` — every
producing role is paired with a validating role, the pipeline runs commit-to-merge
without a human gate, and every role file is written explicitly enough for a
weak/inexpensive model to execute reliably.

## 2. Core principle

**The system is the documentation.** Agents don't hold state in memory between
sessions — state lives in `docs/requirements.yaml`, `docs/status/`, `handoffs/`, and
the codebase itself.

**Every producing step has a validating step.** See `core-directives.md`'s
producer/validator table — restated here as the roster's organizing shape.

---

## 3. Agent roster

| Agent ID | Role | Responsibility | May write to |
|---|---|---|---|
| `ORCH` | Orchestrator | Routes work, classifies requests, delegates, escalates. Does no implementation work itself. | `handoffs/`, `docs/status/`, `docs/requirements.yaml` (status field only) |
| `REQ-ANALYST` | Requirement Analyst | Drafts and structures requirements into `docs/requirements.yaml` | `docs/requirements.yaml`, `handoffs/` |
| `REQ-VALIDATOR` | Requirement Validator | Validates requirements for completeness, testability, consistency with existing requirements and decision records | `handoffs/` |
| `CODE-DESIGNER` | Code Designer | Produces module interfaces, `@spec`s, gen_statem/Ecto shape, and data-flow notes before any implementation code is written | `lib/letflow/design/`, `handoffs/` |
| `CODE-DESIGN-VALIDATOR` | Code Design Validator | Reviews CODE-DESIGNER's artefact — every acceptance criterion covered, no implementation code present, design is unambiguous enough for ELIXIR-DEV/FRONTEND-DEV to proceed. **Hard gate.** | `handoffs/` |
| `ELIXIR-DEV` | Elixir Developer | Implements `lib/letflow/` and `priv/repo/migrations/` per the design artefact | `lib/`, `priv/repo/migrations/`, `config/*.exs`, `handoffs/` |
| `FRONTEND-DEV` | Frontend Developer | Builds and changes `web/`, Letflow's own React/TS SPA, and wires it to Letflow's API. Full ownership as of 2026-08-21 — see `docs/migration/decisions/0011-frontend-ownership.md`; the earlier "config/integration only, not a rewrite" mandate is superseded | `web/`, `docs/frontend/`, `handoffs/` |
| `MOBILE-DEV` | Mobile Developer | Builds `apps/mobile/` (Flutter/Dart) per `docs/mobile/`. S9's three backend gaps (REQ-124..126) are closed; owns REQ-417..430, the mobile tier's build queue | `apps/mobile/`, `docs/mobile/`, `handoffs/`, the mobile job only in `.github/workflows/ci.yml`, `docs/migration/stage-9-mobile.md` (outside REVIEWER sign-off sections) |
| `REVIEWER` | Idiom & Scope Reviewer | Checks changes for idiomatic OTP usage (crutch vs. real behaviour), supervision integrity, scope creep, and consistency with `docs/migration/decisions/` records | `handoffs/`, `docs/migration/stage-N-*.md` (REVIEWER sign-off sections only) |
| `SECURITY-REVIEWER` | Security Reviewer | Gates any change touching a tenant-data path against `docs/agents/instructions/security-invariants.md`. **Hard gate for in-scope changes.** | `handoffs/` |
| `TEST-DESIGNER` | Test Designer | Produces test specs and test code (ExUnit, StreamData properties) | `test/specs/`, `test/`, `handoffs/` |
| `TEST-DESIGN-VALIDATOR` | Test Design Validator | Reviews TEST-DESIGNER's output — every MUST acceptance criterion has a runnable test, no skipped/deferred coverage, fixtures are isolated. **Hard gate.** | `handoffs/` |
| `TEST-RUNNER` | Test Runner | Executes `mix test`, diagnoses failures, produces a structured test report | `test/reports/`, `handoffs/` |
| `ISSUE-FIXER` | Issue Fixer | Root-cause diagnosis for a queued issue (WF-03 Step 0.5/1). Does not implement the fix itself — routes to ELIXIR-DEV/FRONTEND-DEV once CODE-DESIGNER has a fix design | `docs/issues/`, `handoffs/` |
| `RELEASE-VALIDATOR` | Release Validator | Validates a stage/requirement-batch meets all MUST acceptance criteria before it's marked RELEASED; re-runs the full suite rather than trusting TEST-RUNNER's report alone | `handoffs/`, `docs/status/` |
| `DOC-UPDATER` | Documentation Updater | Updates `docs/requirements.yaml` status, `docs/status/requirement_status*.yaml` (the index and all volumes), `README.md` where it documents current behavior, and any stage/decision doc a requirement's acceptance criteria named | `docs/`, `README.md`, `handoffs/` |
| `UAT-RUNNER` | UAT Runner | Executes scenario-based acceptance checks against a running Letflow instance once one exists to test against; role defined now, scenario corpus deferred to S7 (`docs/migration/stage-7-simulation-uat-parity.md`) | `test/uat-reports/`, `handoffs/` |
| `BA-<VERTICAL>` | Business Analyst (per tenant-vertical/solution-pack) | Authors UAT scenarios in tenant-vertical domain language and signs off on UAT-RUNNER's execution results for its scope, per `.claude/agents/ba-analyst.md` — one canonical role file, parameterized by vertical via `docs/agents/ba-personas/<vertical>.yaml`, not a closed per-company roster | `test/fixtures/uat/scenarios/<vertical>/`, `test/uat-reports/` (`ba-signoff-` prefix), `docs/agents/ba-personas/` (new-persona/reuse bookkeeping), `handoffs/` |
| `PRODUCT-OWNER` | Product Owner (platform-level business authority) | Reads every BA-<VERTICAL> sign-off for a UAT run, cross-checks MUST-severity acceptance-criteria coverage against `docs/requirements.yaml`, enforces the single-BLOCKER-blocks-release rule, arbitrates cross-vertical disagreements (routing to REQ-ANALYST if the underlying requirement is ambiguous), and writes the platform's plain-language release recommendation. Answers "should we ship?" — distinct from RELEASE-VALIDATOR's "is it safe to ship?" (`.claude/agents/product-owner.md`) | `test/uat-reports/` (`po-signoff-` prefix), `handoffs/` |
| `PROCESS-AUDITOR` | Process Auditor (independent design reviewer, per scope) | Reads one scope's process definitions and forms, scenarios, roster (`test/fixtures/uat/actors.yaml`), seed scripts and `docs/roles.md`, plus the definition validator output ORCH hands it, answers a closed checklist A-F (missing business paths, separation of duties, data on some paths only, consistency inside the scope, access, consistency across scopes) and writes a process-audit report with verdict PASS, PASS_WITH_FINDINGS or FAIL. Authors and edits nothing it audits; never signs off run results (`.claude/agents/process-auditor.md`). A FAIL blocks UAT-RUNNER for that scope only (`docs/agents/workflows/WF-05_uat_run.md`, Step 0b) | `test/uat-reports/` (`process-audit-` prefix only), `handoffs/` |

**Deliberately not reproduced from R-Co, historically — now fully actioned:**
R-Co's `BO-SWIFTROUTE`/`BO-VORTEX`/`BO-MERIDIAN` business-owner-persona layer was
actioned by REQ-359 as the `BA-<VERTICAL>` row above; R-Co's `PRODUCT-OWNER` role
is actioned by REQ-361 as the `PRODUCT-OWNER` row above. See
`docs/migration/decisions/0004-humanless-pipeline.md`'s original "What is
explicitly NOT reproduced" section and its 2026-09-16 and 2026-09-17 addenda for
the full history of this deferral and its closure.

### 3.1 Capability matrix

| Agent | Reads | Writes | Runs terminal commands | Spawns subagents |
|---|:---:|:---:|:---:|:---:|
| `ORCH` | ✓ | handoffs, status only | ✗ | ✓ |
| `REQ-ANALYST` | ✓ | ✓ | ✗ | ✗ |
| `REQ-VALIDATOR` | ✓ | handoffs | ✗ | ✗ |
| `CODE-DESIGNER` | ✓ | ✓ | ✗ | ✗ |
| `CODE-DESIGN-VALIDATOR` | ✓ | handoffs | ✗ | ✗ |
| `ELIXIR-DEV` | ✓ | ✓ | ✓ (mix, git, gh) | ✗ |
| `FRONTEND-DEV` | ✓ | ✓ | ✓ (npm, git, gh) | ✗ |
| `MOBILE-DEV` | ✓ | ✓ (`apps/mobile/`, `docs/mobile/`, `handoffs/`, mobile job in `ci.yml`) | ✓ (flutter, dart, git, gh) | ✗ |
| `REVIEWER` | ✓ | handoffs, stage sign-off | ✗ | ✗ |
| `SECURITY-REVIEWER` | ✓ | handoffs | ✓ (grep-based checks, mix test) | ✗ |
| `TEST-DESIGNER` | ✓ | ✓ | ✗ | ✗ |
| `TEST-DESIGN-VALIDATOR` | ✓ | handoffs | ✗ | ✗ |
| `TEST-RUNNER` | ✓ | reports | ✓ (mix test; `flutter analyze`/`flutter test` for `apps/mobile/`) | ✗ |
| `ISSUE-FIXER` | ✓ | docs/issues only | ✗ | ✗ |
| `RELEASE-VALIDATOR` | ✓ | status | ✓ (tests) | ✗ |
| `DOC-UPDATER` | ✓ | ✓ | ✗ | ✗ |
| `UAT-RUNNER` | ✓ | uat-reports | ✓ (HTTP calls against a running instance) | ✗ |
| `BA-<VERTICAL>` | ✓ | ✓ (scenario files, ba-signoff files, persona-data files) | ✗ | ✗ |
| `PRODUCT-OWNER` | ✓ | ✓ (`po-signoff-` files) | ✗ | ✗ |
| `PROCESS-AUDITOR` | ✓ | handoffs, test/uat-reports/process-audit-* only | ✗ (read-only search only) | ✗ |

**`handoffs` in the Writes column means the agent's own handoff file only** (updated
2026-08-17, ISS-0021/GH#78 — this table previously left `handoffs/registry.json`
ownership unresolved, contradicting `docs/agents/ORCHESTRATOR.md`'s explicit "ORCH
MUST... maintain `handoffs/registry.json`"). `handoffs/registry.json` itself is
ORCH-exclusive: ORCH updates it on every other agent's behalf when it processes that
agent's completed handoff, per `docs/agents/shared/HANDOFF_PROTOCOL.md` §4. No role
other than `ORCH` writes to `registry.json` directly, regardless of what this table's
`Writes` column otherwise says for that row.

---

## 4. Handoff system

Agents communicate through handoff files under `handoffs/<RUN-ID>/`. Full schema,
timestamp rules, and completion mechanics: `docs/agents/shared/HANDOFF_PROTOCOL.md`.

ORCH may act directly, without spawning a subagent or writing a handoff file, only when
a change passes all seven checks of `docs/agents/ORCHESTRATOR.md` §10's sizing rule — that
section is the canonical definition and this file does not restate the test. The
handoff-file machinery exists for multi-step work where independent validation actually
matters; forcing it onto a one-line typo fix would be ceremony without benefit.

**Risk tier:** which chain a change runs (FULL, SHORT, HIGH) is decided by `docs/agents/ORCHESTRATOR.md` §13; this file does not restate it.

---

## 5. Requirement status tracking

`docs/requirements.yaml`'s `status:` field is authoritative for a requirement's current
state (`pending | in_progress | done | blocked`) — this file's schema is **not**
replaced by the fuller pipeline, only routed through it. `docs/status/requirement_status.yaml`
remains the append-only event history (`started`/`done`/`blocked`/`cancelled`/`revised`/`verified`), kept in bounded volumes behind
`docs/status/requirement_status.index.yaml`.

The pipeline overlays a finer-grained status internal to a single WF-02 run (tracked in
that run's handoff files, not in `docs/requirements.yaml` itself):

```
pending → validated → designed → design-reviewed → implemented →
test-designed → test-design-reviewed → tested → released
```

Only `pending`, `in_progress`, `done`, `blocked` are ever written to
`docs/requirements.yaml` — the finer states above live in the run's own handoffs, so a
requirement's file-level status stays exactly as terse as it's always been.

---

## 6. Artifact locations

| Type | Location | Owner | Format |
|---|---|---|---|
| Elixir source | `lib/` | `ELIXIR-DEV` | `.ex` |
| Ecto migrations | `priv/repo/migrations/` | `ELIXIR-DEV` | `.exs` |
| Frontend source | `web/` | `FRONTEND-DEV` | `.ts`/`.tsx`/config |
| Frontend specification | `docs/frontend/` | `FRONTEND-DEV` | `.md` |
| Mobile source | `apps/mobile/` — created by `REQ-419` | `MOBILE-DEV` | `.dart` |
| Mobile specification | `docs/mobile/` | `MOBILE-DEV` | `.md` |
| Design artefacts | `lib/letflow/design/` | `CODE-DESIGNER` | `.md` |
| Test specs | `test/specs/` | `TEST-DESIGNER` | `.md` |
| Test source | `test/` | `TEST-DESIGNER` | `.exs` |
| Test reports | `test/reports/` | `TEST-RUNNER` | `.yaml` |
| UAT reports | `test/uat-reports/` | `UAT-RUNNER` | `.yaml` |
| BA sign-off reports | `test/uat-reports/` (`ba-signoff-` prefix) | `BA-<VERTICAL>` | `.yaml` |
| BA persona data | `docs/agents/ba-personas/` | `ORCH`/`REQ-ANALYST` (creation), `BA-<VERTICAL>` (own reads) | `.yaml` |
| PO sign-off reports | `test/uat-reports/` (`po-signoff-` prefix) | `PRODUCT-OWNER` | `.yaml` |
| Process audit reports | `test/uat-reports/` (`process-audit-` prefix) | `PROCESS-AUDITOR` | `.yaml` |
| UAT visual-regression baselines | `test/fixtures/uat/visual-baselines/` | `UAT-RUNNER` (accept/re-baseline actions) | `.png` (+ one `.yaml` sidecar per baseline — see `lib/letflow/design/req362-visual-regression-testing.md` §2.3) |
| Handoff files | `handoffs/` | all (via ORCH) | `.json` (exception) |
| Requirement queue | `docs/requirements.yaml` | `ORCH`/`DOC-UPDATER` (status field) | `.yaml` (pre-existing schema, unchanged) |
| Requirement event history | `docs/status/requirement_status*.yaml` (index + all volumes) | `DOC-UPDATER` | `.yaml` |
| Issue registry | `docs/issues/` | any agent (finding content); filed on the board by the sole filer per `WORK_BOARD.md` | `.yaml` (`ISS-NNNN.yaml` and `queue_ref` are history; new records are `GH-<n>.yaml`) |
| Release decisions | `docs/status/` | `RELEASE-VALIDATOR` | `.yaml` |
| Migration decision records | `docs/migration/decisions/` | any agent, REVIEWER sign-off | `.md` |
| Stage detail + REVIEWER sign-off | `docs/migration/stage-N-*.md` | `REVIEWER` | `.md` |
| Agent role files | `.claude/agents/*.md` | canonical, hand-maintained | `.md` |
| Cross-cutting instructions | `docs/agents/instructions/` | canonical, hand-maintained | `.md` |
| Protocols | `docs/agents/protocols/` | canonical, hand-maintained | `.md` |
| Workflows | `docs/agents/workflows/` | canonical, hand-maintained | `.md` |
| Developer guides | `docs/guides/` | canonical, hand-maintained | `.md` |
| Scratch | `scratch/` | any agent | any (git-ignored) |

**Output format rule:** YAML for everything except handoff files (JSON — machine-read
by ORCH as structured data). See `core-directives.md`.

---

## 7. Conflict prevention

An agent MUST check the registry (`handoffs/registry.json`) for a handoff already
`IN_PROGRESS` against the same artifact before starting. ORCH is responsible for
sequencing concurrent work to avoid collisions — see `docs/agents/ORCHESTRATOR.md`'s
`owned_modules` lock, same mechanism as R-Co's.

---

## 8. Agent identity contract

When an agent is invoked, it operates under a stated `AGENT_ID` from the roster above.
Default, if none is stated: `ORCH` — same default as the earlier 4-agent system, see
`CLAUDE.md`.

---

## 9. Canonical instruction surfaces

| Content | Canonical location |
|---|---|
| Per-`AGENT_ID` role instructions | `.claude/agents/*.md` |
| Cross-cutting rules binding every role | `docs/agents/instructions/core-directives.md` |
| Security invariants | `docs/agents/instructions/security-invariants.md` |
| Handoff lifecycle mechanics | `docs/agents/shared/HANDOFF_PROTOCOL.md` |
| Git branch/merge mechanics | `docs/agents/protocols/GIT_SETUP.md`, `GIT_MERGE.md` |
| Work coordination: issues as the work queue, labels, claims, filing, closing | `docs/agents/protocols/WORK_BOARD.md` |
| Superseded queue-era protocols (history; pointers to `WORK_BOARD.md`) | `docs/agents/protocols/ISSUE_QUEUE.md`, `docs/agents/protocols/TASK_QUEUE.md` |
| Standard workflow step chains | `docs/agents/workflows/WF-*.md` |
| Role charter: the eight built-in roles, their scopes, what each may and must not do | `docs/roles.md` (UAT actor-to-role mapping: `test/fixtures/uat/actors.yaml`) |
| Roster, handoff schema, capability matrix, artifact locations | this document |
| Orchestration decision logic, stage gates | `docs/agents/ORCHESTRATOR.md` |

`CLAUDE.md` stays a pointer file — it names the roster and links here, it does not
restate role instructions.

---

## 10. Layer charter (audit #2874 R7)

| Layer | Decides | Never |
|---|---|---|
| Supervisor | which issue, which checkout, merge order and holds, infra requests, rule adoption | judges code quality, waives or overrides a gate verdict, writes in a checkout |
| ORCH + inner roles | how well one change is built and checked | picks or reorders work, merges without the supervisor's slot |
| Advisory/architect sessions | decision records, R5 outside reviews, hard design questions | implement, or file directly (they go through the filer) |
| BA session (letflow-2) | sole filer; drafts business requirements | merges functional code |
| Infra | hosts, CD, secrets (by name only) | Letflow code |
| Auditor (#2849, #2874) | process rules across all layers, by the user's order | implements |

Conflict order: the user, then the auditor, then the supervisor for flow questions and the gates for quality
questions. Neither the supervisor nor the gates override the other in the other's column.
