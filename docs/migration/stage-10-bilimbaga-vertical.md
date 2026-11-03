# Stage 10 — BilimBaga vertical

Status: P0–P5 complete. Depends on: S4, S6, S8. Requirements: `REQ-295`–`REQ-349`
filed (53 as of 2026-09-14, counting distinct `- id: REQ-NNN` entries whose own
`stage:` field is S10), all `done`. **P4 is built**: `REQ-335`, `REQ-336`,
`REQ-338`, `REQ-340`, `REQ-342` and `REQ-343` closed out S10 P4 — the `web/`
admin-CRUD engine (nine remaining entity types plus the `tag` pilot), the
hand-written candidate exam-taking UI, and the candidate-session route surface
that fronts it. `REQ-339` (this bookkeeping entry) is P4's own close-out
requirement, mirroring `REQ-334`'s role for P3. (337 and 341 were never used —
each was retired by `REQ-VALIDATOR` for bundling separable units and split in
two, per `REQ-340`'s and `REQ-342`'s own descriptions — so that span is
deliberately non-contiguous.) `web/src/pages/exam/` now holds four modules,
`ExamListPage.tsx`, `ExamSessionPage.tsx`, `ExamResultView.tsx` and
`ExamSessionResultPage.tsx` (the last two added by `REQ-351`, `REVIEWER`
rule-2 PASS 2026-09-15) — see the bucket-C
inventory below.
**P5 is met as of 2026-09-14**: expanded into `REQ-344`–`REQ-349` and closed the
same day — triage (`REQ-344`), the two-exam seeded fixture (`REQ-345`),
candidate-side, entity-CRUD-admin and result-side ports (`REQ-346`, `REQ-347`,
`REQ-349`), and `REQ-348`'s close-out with both independent re-verifications.
Seven ported spec files now live under `web/tests/e2e/`; 34 of `REQ-344`'s
corrected 168-test corpus are ported and passing, with the remaining 134
accounted for file by file — see the P5 phase row and the "P5 close-out"
section below. P6 (conditional importer) is not expanded. Certificate
issuance — P3's second half — is deliberately not expanded: it needs PDF+QR
rendering, `mix.exs` carries no such dependency, and gaps 4 and 5 have their
*mechanism* settled by decision 0027 but no owner.

Created 2026-09-09. See
[`decisions/0022-bilimbaga-vertical.md`](decisions/0022-bilimbaga-vertical.md)
for why this stage exists, why BilimBaga is a solution pack plus a bounded
runtime rather than a fork or a federated Go service, and for the **bucket rule**
(A = definitions, B = generic platform capability, C = exam-specific runtime)
that every requirement in this stage is gated against.

## Scope

Deliver BilimBaga — a corporate exam platform: multilingual question banks,
configurable timed sessions, auto-grading, certificates with QR verification,
analytics, tenant branding, AI-assisted authoring — as **one Letflow tenant, one
solution pack, and a bounded `lib/letflow/exam/` runtime**, with its screens in
`web/`.

The port source and reference implementation is `c:\Users\tvolo\dev\BilimBaga\`
(Go 1.25 / Chi / `sqlx` / PostgreSQL 16, React 19 SPA, 19 Playwright spec files
carrying 168 `test()` blocks). Its product specification is
`c:\Users\tvolo\dev\BilimBaga\corporate_exam_platform_roadmap.md`, which is
organised as `## Phase N` / `### N.M` sections and carries **no** requirement
identifiers of its own.

BilimBaga's requirement IDs are `FR-BB<phase><section>` — `FR-BB22` (question
model), `FR-BB35` (session creation), and so on — but they are **not defined in
the roadmap**. They appear only as citations: in migration headers
(`009_questions.up.sql`: "Migration 009: FR-BB22 — Question Model"), in Go
source, and in `.github/agents/`. 78 distinct IDs are in use, and the numbering
is not uniformly two-digit — `FR-BB001`, `FR-BB110`–`FR-BB114` and
`FR-BB310`–`FR-BB318` all occur.

So the citation rule is: **every S10 requirement that ports a BilimBaga
behaviour cites the `FR-BB` ID carried by the migration or package it ports
from**, the same way S1–S8 requirements cite an R-Co source path. Where no
`FR-BB` ID exists for a behaviour, cite the roadmap section (`§3.5`) instead.
Reconstructing a canonical `FR-BB` index is P0 work, not a precondition to it.

## This stage ports no R-Co source

Like S9, and unlike S1–S8, there is no R-Co directory behind this stage. It lives
in `docs/migration/` by naming convention only — the stage list, the `detail_file`
convention, and the decision-record directory all live here. This directory's
framing as a *historical build record* does not extend to S10 or S9.

Unlike S9, S10 does have a working implementation to port **from** — just not one
written in Elixir, and not one whose code transfers. What transfers is the domain
model, the requirement set, the UX, and the acceptance scenarios. The Go code
does not.

## The fourteen platform gaps

Verified against `lib/` and `web/` on 2026-09-09, and re-checked against `main`
at each rebase — the filed rows move quickly, so trust `docs/requirements.yaml`
over this column if they ever disagree. Gaps 10–12 were added by
`REVIEWER`'s sign-off on 0022 (see that record's amendment to reasoning §1).
**Every one of these is bucket B, and all of them close before any bucket-A pack
work begins** — a pack cannot be authored against a platform whose data-model
surface has no HTTP route, and no question bank can be authored against one with
no relations and no queryable localized fields.

| # | Gap | State on 2026-09-09 | Owner |
|---|---|---|---|
| 1 | **Entity-records HTTP surface.** `Letflow.Entities.{Definitions,Records}` and the query DSL exist (`REQ-225`–`REQ-231`); nothing routes to them. `lib/letflow/router.ex`'s deferred-routes table no longer lists `Letflow.Routers.Entities` — that row was retired once the router was mounted. | **Closed 2026-09-12** -- `REQ-308` `done` (design, `lib/letflow/design/req308-entity-http-surface.md`); `REQ-309`, `REQ-310`, `REQ-311` `done` (implementation: permission atoms, `lib/letflow/routers/entities.ex` with seventeen routes, mounted at `/entities` by `Letflow.Plugs.ApiPipeline`) | closed |
| 2 | **Aggregation / reporting queries.** `Letflow.Entities.Query.Compiler` compiles allowlisted filter/sort into an `Ecto.Query`; it has no `count`/`sum`/`group_by`. `/metrics` is Prometheus *ops* metrics (`REQ-194`), not a BI surface. BilimBaga's analytics dashboard has nothing to sit on. | **Closed 2026-09-11** -- `REQ-312` `done` (design, `lib/letflow/design/req312-query-aggregation.md`); `REQ-315` `done` (implementation, `POST /entities/query/aggregate`, PR #1276) | closed |
| 3 | **Attachments beyond instances.** `Letflow.Repository.Attachments` covers `instance_attachments` only. Question images and bulk import need attachments on an *entity record*. | **Closed 2026-09-12** -- `REQ-313` `done` (design, `lib/letflow/design/req313-entity-record-attachments.md`); `REQ-316` `done` (migration + context module, PR #1264) and `REQ-317` `done` (permission atoms + four routes, PR #1279) | closed |
| 4 | **Email.** No mailer, no SMTP dependency in `mix.exs` (still absent, re-verified 2026-09-12). Mechanism settled by [decision 0027](decisions/0027-solution-pack-service-catalog-install-policy.md): any needed `service_catalog` entry is provisioned out-of-band, via `POST /service-catalog` (gated `:AdminServicesManage`), not through a pack. The capability itself remains open and unowned. | **Open (capability).** Mechanism settled by 0027; still no mailer/SMTP dependency | to file |
| 5 | **PDF + QR rendering** for certificates. Absent (re-verified 2026-09-12: no PDF or QR dependency in `mix.exs`); same out-of-band mechanism as gap 4, settled by [decision 0027](decisions/0027-solution-pack-service-catalog-install-policy.md). The capability itself remains open and unowned. | **Open (capability).** Mechanism settled by 0027; still no PDF/QR dependency | to file |
| 6 | **A public, unauthenticated route pattern** for certificate verification. Only the `/api/tenant-config` precedent exists (mounted on `Letflow.Router`, ahead of the `/api/v1` forward, with its own disclosure boundary). Needs its own design and `SECURITY-REVIEWER` gate. | **Design closed 2026-09-12** -- `REQ-323` `done` (design, `lib/letflow/design/req323-unauthenticated-read-pattern.md`, plus [decision 0028](decisions/0028-unauthenticated-read-boundary.md): capability-handle resolution, no tenant-enumeration oracle). Implementation (a route built against this pattern) not yet filed | `REQ-323` |
| 7 | **`x-ui` widget vocabulary + `Expr` evaluators.** Without these, every admin CRUD screen is hand-written React instead of generated from an entity definition. | **Closed 2026-09-11** — `REQ-284` `done` (closed vocabulary + `fieldRegistry`); `REQ-291`, `REQ-292`, `REQ-293` (the `Expr` evaluators, definition-time / server-side / TypeScript) all `done`. The 2026-09-09 reading that three of them were still `pending` no longer holds | closed |
| 8 | **i18n in `web/`.** BilimBaga is trilingual (kk/ru/en). Non-negotiable. | **Closed 2026-09-09** — `REQ-285` `done` (react-intl, decision 0021) | closed |
| 9 | **Tenant branding**, and `form_schema` exposed on the task-detail response. | **Closed 2026-09-11** — `REQ-281`, `REQ-282` `done` (both tenant-config endpoints serve branding), `REQ-286` `done` (`form_schema` exposed), and `REQ-283` (SPA theming) `done`. The 2026-09-09 reading that `REQ-283` was still outstanding no longer holds | closed |
| 10 | **Relations between entity records.** `Letflow.Entities.Query.Compiler` has no `join`/`preload`; `fk_def`'s `references_entity` is validated for shape and self-reference only, with no referential enforcement. **Now a consequence of [decision 0023](decisions/0023-entity-storage-hybrid.md)**, not separate work — per-entity-type tables with promoted FK columns make joins expressible for the first time. | **Closed 2026-09-11** — `REQ-300` `done` (joins in `Letflow.Entities.Query.Compiler` over promoted FK columns). 0023's open question, which had blocked filing this at all, was answered by `REQ-295` (`done`) | closed |
| 11 | **Localized-text field type.** Re-scoped by 0023: entity-content localization is blob-stored (it follows its parent's lifecycle), and becomes searchable via generated columns per locale when `queried: true`. Not a relations problem and not an i18n-layer problem — gap 8 (`REQ-285`, client-side) is a different concern that this does not depend on. | **Closed 2026-09-11** — `REQ-301` `done` (blob-stored localized text, generated column per locale when `queried: true`) | closed |
| 12 | **Bulk import/export of entity *records*.** `Letflow.Definitions.ExportImport` moves definitions, not records. BilimBaga has `pg_trgm`-backed import/export (`011_pg_trgm_import_export`). | **Closed 2026-09-12** -- `REQ-314` `done` (design, `lib/letflow/design/req314-entity-record-bulk-export-import.md`); `REQ-318` `done` (permission atoms, PR #1277), `REQ-319` `done` (export route, `POST /entities/records/:entity_type/export`, PR #1281), `REQ-320` `done` (import route, `POST /entities/records/:entity_type/import`, PR #1282) | closed |
| 13 | **A pack format that can carry entity definitions.** `Letflow.Definitions.SolutionPack`'s `pack_document` has four content sections — `definitions` (process definitions only), `service_catalog_entries` (rejected), `variable_schemas`, and `manifest.required_roles` (read-only, creates no role). There is **no `entity_definitions` section**, and no form-schema section. Bucket A's own delivery vehicle cannot carry two of the four things bucket A consists of. | **Closed 2026-09-11** — the pack document now carries an `entity_definitions` section: `REQ-303` `done` (design record [`0026`](decisions/0026-solution-pack-entity-definitions-section.md), which also confirmed the form-schema half was already closed), `REQ-304` `done` (export), `REQ-305` `done` (install), `REQ-306` `done` (test coverage). `service_catalog_entries` is still rejected and still unowned — see "Open questions" | closed |
| 14 | **Self-referential entity relationships.** `Letflow.Entities.Definition.Validator`'s Rule 9 outright rejected any foreign key whose `references_entity` named the definition's own entity, ruling out a parent/child tree or a version-lineage pointer — both real, generic BPM patterns the design anticipated as follow-up work rather than ruled out for good (`lib/letflow/design/req225-entity-definition-schema-validation.md`'s numbered open item 4). Not in the original thirteen-gap survey; filed once REQ-324 was scoped against that anticipated-follow-up note. | **Closed 2026-09-13** -- `REQ-324` `done`: Rule 9 lifted (self-referential FK now accepted, siblings' rejections intact). Four empirical findings: (1) decision 0025 already covers ON DELETE for the self-edge unconditionally, no code change needed; (2) cycle prevention is not enforced anywhere in the platform — a stated, reasoned position, not an oversight; (3) the DDL generator already emitted a correct self-referencing `REFERENCES` clause, verified against a real Postgres; (4) `Query.Compiler`'s self-join path was genuinely broken (`ERROR 42702 ambiguous_column`) and fixed by qualifying `hop_on_dynamic/1`'s fragments to the binding alias, with a follow-on gap (filter/sort dynamics still unqualified for a self-join) correctly identified and left for a future requirement rather than silently folded in; the exam pack columns and write rules that use it shipped as REQ-586 part A (GH #3315): `parent_id` on `category` and `question`, `AuthoringRules` | closed |

Gaps 7–9 were already filed as 0020 follow-on work and were not S10's to re-file;
S10 depended on them and said so, and all three are now closed. Gaps 1–6 and
10–13 are new bucket-B requirements this stage must file first, and of those,
10, 11 and 13 — the three that make P2's exit condition reachable at all — are
closed as of 2026-09-11 (`REQ-300`, `REQ-301`, `REQ-303`–`REQ-306`). Gap 1 is
closed (`REQ-308`–`REQ-311`, all `done`). Gap 2 is now closed (`REQ-312`
design, `REQ-315` implementation, both `done`). Gap 3 is now closed
(`REQ-313` design, `REQ-316` migration/context module, `REQ-317`
permission atoms/routes, all `done`). Gap 12 is now closed
(`REQ-314` design, `REQ-318`/`REQ-319`/`REQ-320` implementation, all
`done`). Gaps 4 and 5 have their mechanism settled by decision 0027
(out-of-band provisioning via `POST /service-catalog`) but remain open as
capabilities, still unowned. **Gap 6 is now closed:** `REQ-323` filed the
design (`req323-unauthenticated-read-pattern.md`, decision `0028`),
`REQ-352` (`done`) built the platform machinery (the `/api/public` mount,
sub-router, registry and writer, rate limiter, refusal path), and
`REQ-357` (`done`) registered the first real public-read kind on top of
it — the certificate projection — closing the vertical half. See the
bucket-C inventory's `Letflow.Exam.CertificatePublicProjection` row and
the P3 phase row below for the full detail.

Gaps 10 and 11 are consequences of
[decision 0023](decisions/0023-entity-storage-hybrid.md), and as originally
written this file recorded that they could not be filed until that record's open
question — how a promotion's DDL is executed per tenant — was answered and gated.
**That question has since been answered:** `REQ-295` (`done`) produced
[`decisions/0024-entity-promotion-ddl-execution.md`](decisions/0024-entity-promotion-ddl-execution.md),
which settles the DDL mechanism, failure semantics, backfill and rollback. The
filing block it describes is lifted.

## Phases

Sized as milestones, not as requirements. Each is expanded into `REQ-xxx` entries
at the normal one-agent-turn sizing when it becomes the active phase.

| Phase | Deliverable | Bucket | Exit condition |
|---|---|---|---|
| **P0** | This stage file, decision 0022, an `FR-BB` index reconstructed from its actual citation sites, and the `FR-BB` → `REQ-xxx` translation with a bucket declared on each | — | every S10 requirement is filed and `REQ-VALIDATOR`-passed |
| **P1** | Close gaps 1–6 and 10–13; land 7–9 | B | `mix letflow.check` and `web/`'s `npm run check` green with all thirteen closed. As of 2026-09-12 gaps 1, 2, 3, 7, 8, 9, 10, 11, 12 and 13 are closed; gaps 4 and 5 have their mechanism settled by decision 0027 but remain open as capabilities (no mailer/SMTP, no PDF/QR dependency); **gap 6 is now closed** — `REQ-323`'s design (decision 0028), `REQ-352`'s platform machinery and `REQ-357`'s first real public-read kind (the certificate projection) are all `done`, see the "Gaps" section above and the bucket-C inventory below |
| **P2** | The pack: entity definitions, process definitions, role-registry seed, Lua grading rules | A | a tenant with a working question bank and exam configuration, and **zero exam-specific Elixir**. Reachable as of 2026-09-11: gaps 10, 11 and 13 are closed — see below |
| **P3** | `lib/letflow/exam/`: live session (deadline, autosave, per-question scoring, anti-cheat), certificate issuance | C | each module carries its `REVIEWER` bucket-C sign-off — met as of 2026-09-13 (see bucket-C inventory above). **This row's bucket (C) and deliverable list were a prediction, not the full outcome: P3 also produced bucket-A work (`REQ-329`, five session entity definitions) and bucket-B work (`REQ-331`, the deadline sweep on `Letflow.Scheduler.Poller`) — see "Bucket-C inventory" above. Certificate issuance was NOT delivered by P3: it needs PDF and QR rendering, `mix.exs` carries no such dependency, and gaps 4 and 5 (above) have their mechanism settled by decision `0027` but their capabilities remain open and unowned. A later reader should not read P3's completion as covering certificates. **Update, REQ-355:** the issuance HALF of certificates now exists (`Letflow.Exam.Certificate`, `priv/packs/bilimbaga/entity_definitions/certificate.json`) — eligibility guards, idempotent issue-or-fetch, and a branding snapshot captured at issuance. **Update, REQ-356 (still `status: pending` in `docs/requirements.yaml`, PENDING REVIEWER rule-2 sign-off — see the bucket-C inventory above):** PDF rendering now exists in this branch's own tree (`Letflow.Exam.CertificateDocument`, `mix.exs` gains `pdf`/`eqrcode` per decision `0033`) and is wired to an authenticated download route (`GET /exam-sessions/:id/certificate/download`). **Update, REQ-357 (`done`):** the QR/public-verification half is built and merged to `main` — `Letflow.Exam.CertificatePublicProjection` registers the certificate as decision 0028's first real public-read kind, together with `REQ-352` (the platform half: the `/api/public` mount, sub-router, registry, rate limiter and refusal path, already merged). A handle is minted through `REQ-352`'s writer at `REQ-355`'s authenticated issue path; no second issue path or registry write surface was added. See the bucket-C inventory above (`Letflow.Exam.CertificatePublicProjection` row) for the full rule-2 adjudication. With `REQ-356`'s code now present alongside `REQ-357`'s merged public-verification half, certificate delivery has PDF rendering, an authenticated download route, and QR/public verification via the public-read projection — but a later reader should still treat `REQ-356` as not fully closed out until its own REVIEWER sign-off and `docs/requirements.yaml` status flip land.** |
| **P4** | `web/`: admin CRUD generated from `x-ui`, plus the hand-written candidate exam-taking UI | C (client) | **Met, as of 2026-09-14.** `REQ-336`'s admin-CRUD engine composes `web/`'s own design-system components (`PageLayout`, `Button`, `DataTable`, `PaginationControls`, `ConfirmDialog`, `QueryStateBoundary`, per its own done-event close-out); `REQ-340`/`REQ-342` added widgets (enum, unique-composite error surfacing, localized_text, fk-reference) to that same registry with no BilimBaga file in their diffs (`git diff --name-only` scoped to `fieldRegistry.ts`/`widgets/` and their tests, per each requirement's own acceptance criterion); `REQ-343` wired all nine remaining entity types onto that engine and its own close-out states plainly "No file or component copied from `c:\Users\tvolo\dev\ai-dala\BilimBaga\frontend\` -- built entirely on `web/`'s own design-system components and REQ-336's/REQ-340's/REQ-342's engine and widgets"; `REQ-338`'s hand-written candidate UI (the two `web/src/pages/exam/` modules in the bucket-C inventory above) likewise names its own design-system components in its close-out and copies nothing from BilimBaga's frontend. Confirmed against all five close-outs (`REQ-336`/`REQ-340`/`REQ-342`/`REQ-343`/`REQ-338`), each independently stating which design-system components were used and that no BilimBaga file was copied — see their `done`-events in [`docs/status/requirement_status.v16.yaml`](../status/requirement_status.v16.yaml). `REQ-337`, the requirement originally filed for this scope, was retired by `REQ-VALIDATOR` for bundling four separable widget/wiring units and split into `REQ-340` (the two mechanically-driven widgets) and `REQ-341`; `REQ-VALIDATOR` then failed `REQ-341` too for the same class of bundling mistake (widget-type axis instead of widget-vs-wiring), and it was retired in turn and split into `REQ-342` (the two new widget shapes) and `REQ-343` (the actual screen/nav wiring for all nine remaining entity types) — see `REQ-342`'s and `REQ-343`'s own descriptions for the full history. |
| **P5** | Parity: BilimBaga's 19 Playwright spec files (**168** `test()` blocks — corrected 2026-09-14 by `REQ-344`; the **286** previously recorded here on 2026-09-13 was wrong and is not reproducible from the corpus by any of three independent grep methods, see `docs/testing/REQ-344-bilimbaga-parity-triage.md` §1) ported to the Letflow build. Not "re-pointed": the two corpora are disjoint (zero filename overlap with `web/tests/e2e/`'s 38 specs) and BilimBaga's selectors are `getByRole`/`getByText`-dominated (314/137/66/16 `getByRole`/`locator`/`getByText`/`getByLabel` uses vs **one** `data-testid`, re-measured 2026-09-14), so they bind to its rendered DOM and accessible names rather than to portable hooks. **No longer blocked as of 2026-09-14** — P4 is done and its screens exist. Expanded into `REQ-344`–`REQ-348` on 2026-09-14: triage (`REQ-344`, **done** — see `docs/testing/REQ-344-bilimbaga-parity-triage.md`; 90 of 168 tests classified NO-COUNTERPART against today's `web/`, 30 PORTABLE-NOW or PORTABLE-AFTER-\<named REQ\> outright, the remainder split per-test), seeded exam fixture (`REQ-345`), candidate-side port (`REQ-346`), entity-CRUD admin port (`REQ-347`), close-out (`REQ-348`). **Met, as of 2026-09-14 — see "P5 close-out" below for the measured parity figure, the full per-file accounting against `REQ-344`'s 168-test corpus, and both required independent re-verifications.** | — | `RELEASE-VALIDATOR` re-derives the pass, `UAT-RUNNER` runs them against a live instance — **both done, see below** |
| **P6** | *Conditional* — importer from BilimBaga's PostgreSQL into entity records | B | built only if a deployment holds real data; otherwise never built |

P2 is the stage's real test. If the question bank, exam configuration and
assignment lifecycle cannot be expressed as definitions, the premise of 0022
reasoning §1 is wrong, and that is a finding worth stopping on rather than
routing around by moving the work into bucket C.

**Part of that finding is already in, and it went deeper on a second pass.**
`REVIEWER`'s 2026-09-09 sign-off on 0022 established from the code — not from a
P2 attempt — that the question bank is not expressible as an entity definition
today: no relations (gap 10) and no queryable localized content (gap 11). Those
two rows are re-marked **B, then A** in 0022's §1 table.

A follow-on architecture review the same day found the cause underneath both,
and a third blocker that is more fundamental than either. **Both findings stand
as stated; both have since been closed.** They are kept here in full, because
the reasoning is what justifies the shape the platform now has:

- **The storage model itself.** *(Finding, 2026-09-09.)* Every entity record of
  every type shared one `entity_record_latest` table with its data in a JSONB
  blob and no index on it, so every definition-declared filter was an unindexed
  sequential scan, and there was no relational structure to join on. [Decision
  0023](decisions/0023-entity-storage-hybrid.md) resolved this to per-entity-type
  tables with a hybrid promoted-column/blob shape, and gaps 10 and 11 became
  consequences of it rather than separate work. *Closed:* its named open question
  — how a promotion's DDL is executed per tenant — was answered by `REQ-295`
  (`done`) in
  [`decisions/0024-entity-promotion-ddl-execution.md`](decisions/0024-entity-promotion-ddl-execution.md);
  gap 10 closed by `REQ-300` (joins over promoted FK columns) and gap 11 by
  `REQ-301` (localized text, generated column per locale when `queried: true`).
- **The delivery vehicle.** *(Finding, 2026-09-09.)* `SolutionPack` could not
  carry entity definitions or form schemas at all (gap 13). Bucket A is defined
  as definitions installed via `SolutionPack.install/3`; two of the four things
  bucket A consists of had no section in the pack document. *Closed:* `REQ-303`
  produced [decision
  0026](decisions/0026-solution-pack-entity-definitions-section.md), which
  designed an `entity_definitions` section and established that the form-schema
  half was already closed elsewhere; `REQ-304` landed export, `REQ-305` install,
  and `REQ-306` its test coverage — all `done`.

**Expanding P2 into bucket-A requirements was blocked until gaps 10, 11 and 13
closed; as of 2026-09-11 all three are closed and that block is lifted.** The
response chosen was to close the platform gaps rather than move the question
bank into bucket C, and that is what happened — no reclassification was needed
and none was made. The original standard still holds for what remains: if
closing a gap turns out to be disproportionate, *that* is the finding worth
stopping on, and it belongs in a new decision record rather than in a quiet
reclassification.

Also flagged there, for P3's scoping: `backend/internal/sessions/` carries
adaptive question selection (`SelectNextAdaptiveQuestion`, `026_adaptive_exam`)
and short-text autograding (`027_short_text_autograding`). Neither is expressible
as a static process definition; both should be assumed bucket C.

## Bucket-C inventory

The measured half of 0022's rule 3. Every module added under `lib/letflow/exam/`
or `web/src/pages/exam/` is listed here with its one-line justification and its
`REVIEWER` sign-off reference. Growth in this table is the stage's primary health
metric.

| Module | Why not A (a definition) | Why not B (generic) | REVIEWER sign-off |
|---|---|---|---|
| `Letflow.Exam.Session` | Orchestrates a stateful, multi-step write sequence (eligibility checks in a fixed order, seeded materialization, ownership-checked autosave/submit) with server-authoritative deadline comparison against wall-clock time — an entity definition has no execution semantics and cannot run a multi-step `with`-chain or compare against `DateTime.utc_now()`. | The eligibility rule set (assignment, exam-active/archived, availability window, attempt limits, one-open-session) and the ownership/deadline guards are all specific to this vertical's session-lifecycle vocabulary (0022 rule 1); nothing outside this vertical shares this exact rule set today. | PASS (REVIEWER, 2026-09-13, WF02-REQ332-20260913 @7a7216f1) |
| `Letflow.Exam.QuestionSetResolver` | Deterministically resolves a seeded, shuffled, truncated question subset from a pool against rule configuration — this requires threading a seeded PRNG (`:rand`) through pool selection, truncation, and two independent shuffle steps, which is executable logic, not declarative field structure. | The pool/rule/count/shuffle model is shaped by this vertical's exam-rule schema (pools, rule counts, `options_order`); no existing platform abstraction treats "resolve a reproducible seeded item subset from a configured pool" as a generic capability, and building one now would be speculative ahead of a second caller. | PASS (REVIEWER, 2026-09-13, WF02-REQ332-20260913 @7a7216f1) |
| `Letflow.Exam.Scoring` | Grading arithmetic (single/true-false as 1-or-0, multiple-choice partial credit clamped to [0,1], Likert weighted-polarity normalization, short-text as `pending_manual`) is executable per-question-type logic with an explicit unanswered-question-as-wrong rule and a no-correct-option error case — none of this is expressible as static field structure. | The five grading rules are specific to this vertical's question-type taxonomy (single/multiple/likert/short-text) and are, per decision `0030` Finding 1, not currently reachable via the platform's one generic scripting mechanism (`Letflow.Engine.Lua.Executor`, unwired for node dispatch) — there is no generic capability to route through today. | PASS (REVIEWER, 2026-09-13, WF02-REQ332-20260913 @7a7216f1) |
| `Letflow.Exam.AntiCheat` | Validates one of exactly three signal types, checks session ownership/in-progress/deadline state, derives `action_taken` from the exam's `on_tab_switch` config (never from caller input), applies a per-session write-rate debounce, and branches `log`/`warn`/`submit` — a live conditional with a side effect (in the `submit` branch, triggering `Letflow.Exam.Session.submit/3`), which an entity definition cannot express. | Stating this generically requires naming the signal vocabulary (`tab_switch`/`blur`/`fullscreen_exit`) and the terminal action (auto-submitting a session) — both vertical-specific per rule 1's own test; a generic "signal-triggered record transition" capability would be built for exactly one caller today, the speculative-generality failure mode `0022` exists to prevent. | PASS (REVIEWER, 2026-09-13, WF02-REQ333-20260913) |
| `Letflow.Exam.Certificate` | `REQ-355`. Runs a fixed-order eligibility guard pipeline (ownership, a `grading_pending` special case kept distinct from a passed-false refusal, submitted-status, exam `certificate_enabled`, session `passed`) then an idempotent issue-or-fetch write with a branding snapshot captured only on first issuance — a multi-step `with`-chain comparing live session/exam state and reading `Letflow.Routers.TenantConfig.branding_from_settings/1` once, which an entity definition cannot express. | A generic "issue-on-first-request record gated by other-entities'-field checks" capability is a plausible platform abstraction in the abstract, but it would be built for exactly one caller today (no second gated-issuance use case exists in this vertical or elsewhere) — the same speculative-generality failure mode `0022` exists to prevent, already the basis for `QuestionSetResolver`/`AntiCheat`/`REQ-345`'s seed task above. | **PASS** (REVIEWER, 2026-09-15, WF02-REQ355-20260915 — see this file's "REVIEWER sign-off" section for the full rule-2 adjudication) |
| `Letflow.Exam.CertificateDocument` | `REQ-356`. Renders a certificate's exam-specific content set (candidate name, exam title, score, issue date, a fixed signatory-block placeholder tied to the tenant's own branding) into a fixed-layout PDF page plus an embedded QR code encoding a verification URL — the exam-specific field set and layout are the substance of this module; the generic halves (turning positioned text/rectangles into PDF bytes, turning a string into a QR module matrix) are the `pdf`/`eqrcode` LIBRARIES decision `0033` chose, not code this module writes. | A generic "render a document from a field set plus a template" capability is a plausible platform abstraction (Letflow already has a form-schema/definition tradition) — this is the genuine bucket-A candidate REQ-356's own text flags for REVIEWER, not waved past here; see this file's "REVIEWER sign-off" section for the adjudication. | **PENDING** (REVIEWER rule-2 sign-off required before merge — see REQ-356's own requirements.yaml text for the exact A/B question to answer; REQ-356 is still `status: pending` in `docs/requirements.yaml` and carries no done-event in `docs/status/requirement_status.v17.yaml` as of this merge — DOC-UPDATER closes this out once the requirement is marked done) |
| `Letflow.Exam.CertificatePublicProjection` | `REQ-357`. Decision 0028's first real public-read kind: a hand-built, PURE field allowlist over one `Letflow.Entities.Record.Latest` record, including `to_float/1`'s three-clause dispatch over `score_pct`'s non-uniform stored representation (float/integer/`Decimal`) and a deliberate `"issued_at"`→`"issued_on"` rename disambiguating against the envelope's own top-level `"issued_at"` key — both real judgment calls over the record's stored shape, not mechanical field copying, which an entity definition/declarative allowlist cannot express. | The A/B question REQ-357 itself posed (why not a declarative field allowlist in config, given REQ-352's registration mechanism is explicitly generic) was answered on the merits, not waved past: the decisive point is `issue_handle/4`'s `resource_id` needing `record.record_id` rather than `record.id` (`Letflow.Entities.Record.Latest`'s own primary key is distinct from its `record_id` field) — a silent-404 hazard that is reasoning about `Repo.get/3` primary-key semantics, not data a config format could express or protect against. A declarative alternative would reopen decision 0028's already-settled behaviour-based projection contract on the strength of one kind's simple field set — the same failure mode already declined for `QuestionSetResolver`/`AntiCheat`/the certificate-issuance guard pipeline. | **PASS** (REVIEWER, 2026-09-15, WF02-REQ357-20260915 @`e092e6b6` — full rule-2 adjudication recorded in that commit's message, quoted in this requirement's `docs/status/requirement_status.v17.yaml` done-event) |
| `Letflow.Modules.Exam.Notifications` | `REQ-597` (GH #3363). The exam notification trigger glue: `result/3` is called by `Letflow.Modules.Exam.Session.submit/3` and `finalize_expired/3` only when that call scored the session (the `score_and_persist/3` branch, so a replayed submit and a `grading_pending` outcome send nothing), `assigned/2` takes an active `"user"` assignment record, and `send_reminders/2` filters assignments by a deadline window computed in code (the deadline is a stored-only field), skips assignees with a finished session and skips an assignment that already has an `exam_reminder` row. The flag reader `enabled?/0` (`:exam_notifications_enabled`, true only for the boolean `true`) and every exam-named function live here. A process definition on `Letflow.Engine` cannot do the result send: a process step cannot see whether `Session.submit/3` scored the session or only returned the stored outcome. | The delivery itself is generic and already bucket B: `Letflow.Notifications.start_delivery/5` (REQ-584) starts the supervised task, renders by template key and writes the `notification_deliveries` row, and `lib/letflow/notifications.ex` names no exam (`grep -n "exam" lib/letflow/notifications.ex` prints nothing, re-run for this row). What stays here is the exam vocabulary (the `exam_title` lookup in the localized `exam` record, `result_status`, `score_percent`, assignment `assignee_type`/`active`/`deadline`, the session statuses that suppress a reminder), which is rule 1 vertical-specific; a generic "notify on record event" capability would be built for one caller today. **The three keys in the platform registry (open question 5):** `"exam_assigned"`, `"exam_reminder"` and `"exam_result"` are entries in `@entries` of `Letflow.NotificationTemplates.Registry`, the only place template keys live (REQ-563), so exam-named data sits in a platform file. Rule-2 reading: the registry is a closed data table of key, placeholder allow-list and default text with no exam logic, the same shape as `task_assigned`; the alternative (a second, module-owned key table) would add a second place for keys and break REQ-563's "no other file defines keys" guard, a speculative registration mechanism for three entries. The keys are data, not code, so the departure from rule 1 is bounded to those three entries and their allow-lists (display values only, no secret/token/reference, pinned by the registry test). | **PASS** on the module as bucket C and **PASS** on the three registry keys as a bounded rule-1 exception (rule-2 verdict recorded by T-0917, subject to its REVIEWER gate). The exception is limited to these three keys and does not authorise further exam-named code in `Letflow.Notifications` or the platform registry. Delivered by PR #3497 (part A) and PR #3500 (part B), both `Refs #3363`. Not yet called from product code: `assigned/2` (no assignment write path) and `send_reminders/2` (no schedule) |
| `web/src/pages/exam/ExamListPage.tsx` | Renders the candidate's exam-discovery/eligibility-gated start screen, including the honest "which exams can I take" answer against `check_assigned/3`'s documented no-op (option (a): list every active exam with copy stating this is provisional pending an assignment decision record) — a live disclosure/copy decision tied to a specific runtime finding, not a declarative field structure a definition could express. | The eligibility-error vocabulary it surfaces (assignment/archived/active/availability-window/attempt-limit/one-open-session, REQ-332's six atoms) and the provisional-copy escape hatch are specific to this vertical's session lifecycle (rule 1); no generic platform capability treats "explain why a record isn't startable yet" as shared today. | PASS (REVIEWER, 2026-09-13/14, three passes across WF02-REQ338-20260914 — implementation, router.tsx/queryKeys.ts decoupling fix, post branch-collision recovery — plus RELEASE-VALIDATOR PASS; docs/status/requirement_status.v16.yaml, REQ-338 done-event) |
| `web/src/pages/exam/ExamSessionPage.tsx` | Orchestrates the in-progress/submit/result flow: per-answer autosave, a live countdown that ticks locally but is re-anchored to the server's `remaining_seconds` on every save response, submit/grading-pending/result state transitions, and three anti-cheat browser-event listeners (`visibilitychange`/`blur`/`fullscreenchange`) wired to `Letflow.Exam.AntiCheat`'s `log`/`warn`/`submit` branches with teardown on unmount — executable UI behaviour and client/server clock reconciliation, not field structure. | The countdown-reanchoring contract, the six eligibility-error messages, and the three anti-cheat signal types/branches are all specific to this vertical's session runtime (rule 1, same vocabulary `Letflow.Exam.Session`/`Letflow.Exam.AntiCheat` already justify); no generic capability treats "live countdown reanchored to a server tick" or "browser-event-to-signal mapping" as shared today. | PASS (REVIEWER, 2026-09-13/14, three passes across WF02-REQ338-20260914 — implementation, router.tsx/queryKeys.ts decoupling fix, post branch-collision recovery — plus RELEASE-VALIDATOR PASS; docs/status/requirement_status.v16.yaml, REQ-338 done-event) |
| `web/src/pages/exam/ExamResultView.tsx` | `REQ-351`. The result-phase rendering extracted out of `ExamSessionPage.tsx` (same three testids/one render guard) so a session's result can be rendered identically whether it came from the LIVE start-answer-submit flow's in-memory `ExamSubmissionOutcome` or from a session LOADED by id via `GET /exam-sessions/:id` — a reuse/sharing decision over executable rendering logic, not a declarative field structure. | Its branching (`grading_pending` vs. scored, `passed` boolean, the pending-vs-score message ids) is this vertical's own `ExamSubmissionOutcome` shape and scoring vocabulary (rule 1, same basis `ExamSessionPage.tsx`'s own row already argues); no generic capability renders "an exam-shaped outcome." | **PASS** (REVIEWER, 2026-09-15, WF02-REQ351-20260915 — bucket C confirmed, extraction reuse, no speculative plumbing; see this file's "REVIEWER sign-off" section) |
| `web/src/pages/exam/ExamSessionResultPage.tsx` | `REQ-351`. Opens an EXISTING exam session by id (`examApi.getSessionState` only, never `startSession`) and renders its result phase via `ExamResultView` — a distinct mount/data-loading behaviour (a session-state fetch plus a load/error/pending/score-unavailable state machine) from `ExamSessionPage.tsx`'s unconditional-start mount, not a declarative field structure. | The honest A/B question REVIEWER must answer, per REQ-351's own text: a "load a record by id and render it read-only" screen is close to a generic capability, so whether this is actually a bucket-B candidate (a generic entity-record detail view) rather than bucket C is a real question, not a formality. | **PASS** (REVIEWER, 2026-09-15, WF02-REQ351-20260915 — the domain-specific `ExamSubmissionOutcome`/session-status branching answers the A/B question C; see this file's "REVIEWER sign-off" section. Note: the requirement itself is **not** fully done — its scoreable-exam acceptance criterion is unmet for an unrelated backend-gap reason, `ISS-0674`) |

The first four rows are copied verbatim from
[`lib/letflow/design/req330-exam-live-session.md`](../../lib/letflow/design/req330-exam-live-session.md)
§7's rule-2 table — the module set REQ-332 and REQ-333 were authorised to
build, and the same table each module's moduledoc cites as its authorisation.
The REVIEWER sign-off column points at REQ-332's REVIEWER PASS (`Session`,
`QuestionSetResolver`, `Scoring`) and REQ-333's REVIEWER PASS (`AntiCheat`),
both recorded in the design doc's §7 table itself with dated PASS entries.
The two `web/src/pages/exam/` rows are P4's own addition (`REQ-338`, no
`CODE-DESIGNER` gate — matching `REQ-335`'s own precedent of skipping a design
pass over an already-settled interface), sourced from `REQ-338`'s close-out and
REVIEWER/RELEASE-VALIDATOR sign-off recorded in
[`docs/status/requirement_status.v16.yaml`](../status/requirement_status.v16.yaml)'s
`REQ-338` done-event, not from a design-doc §7 table (none exists for this
requirement). The last two `web/src/pages/exam/` rows (`ExamResultView.tsx`,
`ExamSessionResultPage.tsx`) are `REQ-351`'s own addition, likewise with no
`CODE-DESIGNER` gate (REQ-351's own text: the backend read it needs was
already routed and ownership-checked, so nothing required a new design pass)
— their `REVIEWER` rule-2 sign-off is **PASS**, recorded 2026-09-15 in this
file's own "REVIEWER sign-off" section below (bucket C confirmed for both
modules). That PASS is on rule 2/idiom/supervision/scope for the code itself
only; `REQ-351` as a whole is not fully done — its scoreable-exam acceptance
criterion is unmet for a code-verified backend-gap reason unrelated to rule 2,
filed as `ISS-0674` (see the sign-off section for the full adjudication).

**Measurement, run against this tree.** These figures are a snapshot, not a
standing guarantee — this table has already gone stale twice behind
concurrent sibling work (the header block corrected in `1897e84d`, and the
line counts corrected here in `ISS-0665`); re-run both blocks below at each
phase close rather than trusting the last-recorded numbers.

```
$ ls lib/letflow/exam/
anti_cheat.ex  certificate.ex  certificate_document.ex  certificate_public_projection.ex  question_set_resolver.ex  scoring.ex  session.ex
$ wc -l lib/letflow/exam/*.ex
  309 lib/letflow/exam/anti_cheat.ex
  390 lib/letflow/exam/certificate.ex
  451 lib/letflow/exam/certificate_document.ex
   77 lib/letflow/exam/certificate_public_projection.ex
  109 lib/letflow/exam/question_set_resolver.ex
  267 lib/letflow/exam/scoring.ex
 1223 lib/letflow/exam/session.ex
 2826 total
```

**7 modules, 2,826 total lines under `lib/letflow/exam/`, RE-measured
2026-09-15 on the merged tree (REQ-356 merged with `origin/main`'s
already-`done` REQ-357)** — this is the real combined figure after
`git merge origin/main` brought REQ-357's `certificate_public_projection.ex`
(77 lines) and `certificate.ex`'s 372→390 growth (+18 lines) onto this
branch's own REQ-356 work (`certificate_document.ex`, 451 lines), rather
than either side's stale partial total. It is NOT a concatenation of the
two branches' last-recorded totals (2,731 + 2,375, which double-counts the
five modules both branches shared) — it is `wc -l` re-run directly against
this merge commit's actual `lib/letflow/exam/*.ex` listing, matching
`anti_cheat.ex`/`question_set_resolver.ex`/`scoring.ex`/`session.ex`
byte-for-byte unchanged on both sides. The two branches' own
immediately-preceding measurements are kept below for history:

**6 modules, 2,731 total lines under `lib/letflow/exam/`, RE-measured
2026-09-15 (REQ-356, on this branch before the origin/main merge)** — this
corrects a stale inventory that still carried `certificate_document.ex` at
402 lines/2,682 total from REQ-356's initial commit; the security-fix
commit (`075c4053`, "escape backslash before parens in PDF text literals")
landed afterward and added the `escape_backslash/1` helper plus its
justifying comment, growing `certificate_document.ex` from 402 to 451
lines (+49), and this file's inventory was never re-run against that
commit until now. `anti_cheat.ex`, `question_set_resolver.ex`,
`scoring.ex`, `certificate.ex` and `session.ex` remain byte-for-byte
unchanged. Two requirements in a row growing this directory (REQ-355 then
REQ-356), per REQ-356's own requirements.yaml text, made visible here
rather than batched into a single later edit. Prior figures: 402
lines/2,682 total at REQ-356's initial (pre-security-fix) measurement; 5
modules/2,280 lines at the 2026-09-15 REQ-355 measurement; 4 modules/1,878
lines before that (`+certificate.ex` 372 new lines); 1,605 at the
2026-09-13 measurement (`scoring.ex` 246→267, `session.ex` 941→1193,
`anti_cheat.ex` and `question_set_resolver.ex` unchanged; see `ISS-0665`).

**6 modules, 2,375 total lines under `lib/letflow/exam/`, measured 2026-09-15
(REQ-357, on `main` before this branch's merge)** — the change against this
file's own immediately-preceding "5 modules, 2,280 lines" measurement above
is `+certificate_public_projection.ex` (77 new lines, REQ-357's own module,
decision 0028's first real public-read kind's projection) and
`certificate.ex` growing 372→390 (+18 lines, the `issue_or_fetch/4`
`is_duplicate`→`first_issuance` threading REVIEWER's sign-off on commit
`e092e6b6` names) — confirmed via `git diff --stat` on `main`: exactly
these two files under `lib/letflow/exam/` changed, `+107/-12` combined.
`anti_cheat.ex`, `question_set_resolver.ex`, `scoring.ex` and `session.ex`
are byte-for-byte unchanged. Re-measured from the real tree above, not
carried forward from the prior figure.

**5 modules, 2,280 total lines under `lib/letflow/exam/`, measured 2026-09-15
(REQ-355)** — the sole change against this file's own immediately-preceding
"4 modules, 1,878 lines" measurement above is `+certificate.ex` (372 new
lines, REQ-355's own module); `anti_cheat.ex`, `question_set_resolver.ex`
and `scoring.ex` are byte-for-byte unchanged. `session.ex` was NOT touched
by this requirement (`git diff --stat lib/letflow/exam/session.ex` against
this branch's base is empty) — its line count reads 1223 here, not the
1193 this file's own immediately-preceding block states, because that
block was ALREADY stale before this requirement started (confirmed: a
fresh `wc -l` at the very start of this requirement's own work, before any
file was touched, already read 1223). REQ-355's own `requirements.yaml`
entry explicitly warns of and pre-empts exactly this: its stated baseline
("session 1193") is acknowledged there as stale by 30 further lines,
filed as a separate, unrelated staleness issue, and an implementer is
explicitly told not to treat the discrepancy as this requirement's own
finding. Re-measured from the real tree above, not carried forward from
either prior figure. Prior to the 1,878-line measurement: 1,605 at the
2026-09-13 measurement (`scoring.ex` 246→267, `session.ex` 941→1193,
`anti_cheat.ex` and `question_set_resolver.ex` unchanged; see `ISS-0665`).

**`web/src/pages/exam/` and `web/src/api/exam.ts`, RE-measured 2026-09-15
(REQ-351):**

```
$ ls web/src/pages/exam/
ExamListPage.tsx
ExamResultView.tsx
ExamSessionPage.tsx
ExamSessionResultPage.tsx
__tests__/
$ wc -l web/src/pages/exam/*.tsx web/src/api/exam.ts
  139 web/src/pages/exam/ExamListPage.tsx
   59 web/src/pages/exam/ExamResultView.tsx
  441 web/src/pages/exam/ExamSessionPage.tsx
  173 web/src/pages/exam/ExamSessionResultPage.tsx
  124 web/src/api/exam.ts
  936 total
```

**4 screen modules (812 lines) under `web/src/pages/exam/`, plus the 124-line
API client `web/src/api/exam.ts`, 936 lines total, measured 2026-09-15
(REQ-351)** — up from 2 modules/603 lines (727 total with the API client) at
the prior same-day measurement: `ExamListPage.tsx` unchanged at 139;
`ExamSessionPage.tsx` 464→441 (REQ-351 EXTRACTED its result-phase render
block, :311-339 in the prior measurement, into the new `ExamResultView.tsx`
rather than adding to it — a net decrease, not new behaviour); plus two
wholly new modules, `ExamResultView.tsx` (59 lines, the shared result-phase
render extracted out of `ExamSessionPage.tsx`) and
`ExamSessionResultPage.tsx` (173 lines, REQ-351's own by-id result screen).
This does not count `web/src/pages/exam/__tests__/` (test files, not
modules, matching the convention the `lib/letflow/exam/` measurement above
already uses of counting only `.ex` implementation files) or REQ-338's/
REQ-351's other supporting files outside `web/src/pages/exam/`
(`web/src/types/exam.ts`, `web/src/utils/examErrors.ts`,
`web/src/hooks/useAntiCheatSignals.ts`, `web/src/i18n/examMessages.ts`,
`web/src/i18n/ExamIntlProvider.tsx`, `web/src/router.tsx`) — those are
supporting infrastructure, not bucket-C screen modules in their own right,
and are out of scope for this table per its own header ("every module added
under `lib/letflow/exam/` or `web/src/pages/exam/`").

**What left bucket C.** P3's phases-table row (below) predicts bucket C, but
P3 as executed also produced bucket-A and bucket-B work: REQ-330's
re-derivation moved the five session entities into bucket A as pack-content
entity definitions (`REQ-329`, `priv/packs/bilimbaga/entity_definitions/`),
and moved auto-submission of expired sessions into bucket B as a generic
deadline-driven sweep on the existing `Letflow.Scheduler.Poller`
(`REQ-331`, `lib/letflow/scheduler/record_deadline_sweep.ex`). Only the four
modules in the table above actually landed as bucket-C code. The phase label
is a prediction; it held for four of the six behaviours REQ-330 analyzed and
did not hold for two, which is recorded here rather than only in the
individual requirements' own close-outs.

**Overturned verdicts.** `lib/letflow/design/req330-exam-live-session.md` §6
states explicitly: "No verdict overturns a starting position into a DIFFERENT
bucket than REQ-ANALYST proposed" — every one of the five behaviours
REQ-330 re-derived landed in the same bucket the starting position named
(deadline enforcement split A/C, auto-submission B, autosave C, scoring C,
anti-cheat split A/C). None was reversed. That said, one confirmation was
reached on materially different grounds than the starting position assumed
and is worth naming here even though it is not a bucket reversal: decision
[0030](decisions/0030-exam-session-p3-bucket-verdicts.md)'s Finding 1 found
that decision `0022`'s own bucket table classifies "Lua grading rules ship in
the pack" as bucket A, but no node-dispatch path in
`lib/letflow/engine/transition.ex` reaches `Letflow.Engine.Lua.Executor`
today — that mechanism does not exist in the shipped platform, and never
existed in the BilimBaga reference implementation either (`grading.go` hard-codes
its five rules in Go). Per-question scoring's bucket-C confirmation therefore
rests on a newly-found reason (no generic mechanism to route through), not on
the starting position's original framing. This is a genuine gap between
`0022`'s text and the platform, filed in `0030`, not corrected in `0022`
itself (per decision `0030`'s "Consequences" section — "`0022`'s bucket
table is not edited by this record" — and `REVIEWER`'s 2026-09-13 sign-off
on it: "a disagreement with standing text becomes a decision-record
finding, not a quiet edit").

## Open questions, recorded rather than answered early

- **Anti-cheat scope — ANSWERED by decision
  [0030](decisions/0030-exam-session-p3-bucket-verdicts.md).** Signals are
  entity-record events (the `session_event` entity, REQ-329), written
  through `Letflow.Entities.Records`, not raw `Letflow.EventStore` events
  and not an aggregate counter — chosen to preserve per-event
  `occurred_at` and reuse REQ-329's existing storage rather than stranding
  it. The shared write-amplification exposure this and every other
  high-frequency entity write carries is mitigated by a per-session
  debounce inside `Letflow.Exam.AntiCheat`, not by a different storage
  shape. *(Original question, kept for record: "BilimBaga's roadmap
  includes tab-focus and timing signals. Whether these are entity-record
  events, `Letflow.EventStore` events, or neither is a P3 design question;
  deciding it now would pre-empt gap 1's route shape.")*
- **Where a pack's Lua grading rules are audited — still open, now
  explicitly conditioned.** Decision
  [0030](decisions/0030-exam-session-p3-bucket-verdicts.md) found that
  `0022`'s bucket table row classifying "Lua grading rules" as bucket A is
  not realizable today — no node-dispatch path in
  `lib/letflow/engine/transition.ex` reaches `Letflow.Engine.Lua.Executor`,
  and `Letflow.Engine.LuaScriptAudit.execute_script_for_audit/6` has no
  caller. P3 (`REQ-332`) scores exam questions with bucket-C Elixir
  arithmetic (`Letflow.Exam.Scoring`) instead of waiting on this gap. This
  audit-path question remains open and is moot until a future, unscheduled
  requirement wires a real `:SCRIPT`/`:LUA` node-dispatch path into
  `Letflow.Engine.Transition`. *(Original question, kept for record:
  "`Letflow.Engine.LuaScriptAudit` exists for service-task scripts. Whether
  pack-supplied grading scripts pass through the same audit path, or need
  their own, is a P2 design question with a `SECURITY-REVIEWER`
  interest.")*
- **Whether `service_catalog_entries` in a pack document unblocks here — and who
  now owns that policy. ANSWERED by
  [decision 0027](decisions/0027-solution-pack-service-catalog-install-policy.md).**
  `Letflow.Definitions.SolutionPack` still **rejects** a non-empty
  `service_catalog_entries` array
  (`lib/letflow/definitions/solution_pack.ex`'s `check_unsupported_sections/1` →
  `{:error, :unsupported_pack_section}`), and 0027 settles that rejection as
  PERMANENT, not merely interim. The module's moduledoc and its inline comment
  previously deferred the policy to `REQ-192` — but `REQ-192` was already `done`
  (S6, "Port services.zig's route surface onto the service catalog") without
  lifting the pack restriction, so that deferral was stale. 0027 closes the
  question outright: a solution-pack document may never carry
  `service_catalog_entries`; any such entry is provisioned out-of-band through
  the existing `POST /service-catalog` route (gated `:AdminServicesManage`,
  PLATFORM_ADMIN-only in the current role matrix).

  Gaps 4 and 5 both want a packed catalog entry; both now proceed via that
  out-of-band route rather than through the pack. Correcting the stale
  `REQ-192` pointer in `solution_pack.ex` to cite 0027 instead is this
  requirement's (REQ-322's) own work, not pending P1 work.
- **AI-assisted authoring (BilimBaga phase 7).** Deliberately not phased above. It
  is the least load-bearing feature in the product and the most likely to be
  redesigned; it gets a phase when parity (P5) is real.
- **No way to view a past exam result — ANSWERED by decision
  [0031](decisions/0031-candidate-results-list-scope.md).** No results-LIST
  surface is built: 9 of 168 corpus blocks (`my-results.spec.ts` 6 +
  `exam-result.spec.ts` 1 + `employee-portal.spec.ts` 2) are blocked
  specifically by the missing surface, a small enough fraction — and a
  usable list is not cleanly expressible against `session.json`'s current
  `queried:false` sort/filter fields without its own schema-migration or
  in-memory-sort sizing work — that "do not serve it, and record why" is the
  chosen verdict, not "serve it." `REQ-335`'s scope fence
  (`GetExamHistory`/`HandleGetMyResults`/`GetSessionResult` all excluded) is
  confirmed correct at the time, not a defect. The verdict is revisitable:
  see decision 0031's "Revisitability" section for the two named reopening
  triggers (the measured gap growing, or a second caller needing the same
  `queried:true` schema flip). The single-result-by-id half of this same gap
  is separately, already settled by `REQ-351` (frontend-only, no new backend
  route). *(Original question, kept for record: "A candidate can sit an exam
  and see the outcome, but only in the browser session that submitted it.
  There is no way to view a result afterwards, and no way to see a list of
  past results at all. The gap is in both tiers, and each half was found
  independently: Backend — `lib/letflow/routers/exam_sessions.ex`'s own
  scope fence deliberately does not route `GetExamHistory`/
  `HandleGetMyResults` (FR-BB41/FR-BB46), nor `GetSessionResult` — the last
  named explicitly as 'a sixth behaviour this requirement's own dependency
  chain (`REQ-330`'s five) never authorized.' That was a correct scope
  decision for `REQ-335`, not a defect. Frontend —
  `web/src/pages/exam/ExamSessionPage.tsx`'s mount effect calls
  `startSession` unconditionally (`:112-127`) with no branch that loads an
  existing session, and the result phase is set at exactly two sites, both
  inside the live flow (`:226` anti-cheat forced submit, `:253`
  `handleSubmit`). `examApi.getSessionState` exists
  (`web/src/api/exam.ts:96`) but no component calls it.
  `web/src/router.tsx:82-83` serves only `exam` and `exam/:examId/session` —
  no result-by-id route, no results-list. Consequence: a seeded submitted
  session is unreachable from every rendered screen, so it can be asserted
  on over raw HTTP and nowhere else. This is what makes BilimBaga's
  `my-results.spec.ts` and `exam-result.spec.ts` only partly portable —
  `REQ-349` classifies each of their blocks against what is actually
  reachable, and is explicitly forbidden from adding a route to make a spec
  pass. Compounding it, `Letflow.Exam.Scoring` forces `grading_pending` /
  `passed: nil` whenever a session contains any `short_text` question
  (`scoring.ex:255-257`), so a one-question-per-type fixture can never
  exercise the `exam-result-score` branch at all; `REQ-345` therefore seeds
  a second, short-text-free exam specifically to make that branch reachable.
  Deciding whether Letflow should route `GetSessionResult`, a results-list,
  or neither is a product-scope question that P5 must not settle by side
  effect. It needs its own requirement once `REQ-349` reports how much of
  the result-side corpus is actually unportable without it.")*
- **No `exam_assignment` entity/mechanism exists — a standing gap, now overdue
  for its own decision record.** What is missing: there is no entity type, no
  table, and no mechanism anywhere in the platform for recording which
  candidate (or department, or "everyone") is assigned to sit which exam.
  `REQ-327` deliberately did not author one when it authored the other five
  exam-pack entity types, for a stated reason: `assignee_id` is polymorphic
  across user/department/none, and no `fk_def` can express a reference whose
  target varies or reach the identity subsystem — this is not an oversight,
  it is a documented omission with no decision record behind it. This gap has
  now independently surfaced FOUR times across THREE requirements spanning
  P2, P3 and P4 — the same "twice-recurring" pattern that triggered `REQ-325`'s
  own decision-record requirement for pack sections:
  - **`REQ-327`** (P2) — declined to author the entity, for the polymorphic-fk
    reason above, recorded in its own close-out/README-constraints.md.
  - **`REQ-332`** (P3) — `lib/letflow/exam/session.ex`'s own moduledoc FINDING
    section confirms the runtime consequence: `check_assigned/3` is "a
    documented no-op -- every candidate is currently treated as assigned",
    and `:not_assigned` stays declared in `eligibility_error()` for
    interface-shape fidelity but is unreachable code.
  - **`REQ-343`** (P4) — could not build an admin screen for the entity
    because none exists; per its own description this is "not 'not yet
    wired', genuinely absent from the tenant's schema", so it added one
    visible, tested UI note pointing at `session.ex`'s FINDING section and
    `REQ-327`'s README-constraints.md instead of a screen or a client-side
    polyfill.
  - **`REQ-338`** (P4) — built the candidate-facing exam list against
    `check_assigned/3`'s no-op honestly (option (a): list every active exam,
    with copy stating this is provisional pending an assignment decision
    record), rather than silently assume a real assignment model exists.

  This is no longer a footnote inside any one of those four requirements: it
  now blocks two concrete, real things — `REQ-343`'s admin screen (there is
  nothing to author assignments against) and `REQ-338`'s candidate-facing exam
  list (there is nothing to filter "which exams can I take" against, so it
  lists everything active instead) — and both are shipped, in production
  shape, with that gap visibly disclosed rather than silently patched over.
  Four independent surfacings across three requirements and two phases is
  well past the point a recurring finding should still be living inside
  individual requirements' close-outs rather than its own decision record.
  **This requirement (`REQ-339`) does NOT resolve this gap.** It only records
  it as its own standing open question. Filing the decision-record requirement
  itself — designing how `exam_assignment` should be modelled given the
  polymorphic-target problem `REQ-327` identified — is a follow-on requirement,
  not this bookkeeping entry's job.

## Decisions

- [`decisions/0022-bilimbaga-vertical.md`](decisions/0022-bilimbaga-vertical.md) —
  the vertical shape, the bucket rule, what is discarded, and what this stage
  explicitly does not re-decide.
- **Not re-decided here:** the running-instance shape. `REQ-045` and
  `Letflow.Engine`'s "Process-vs-row decision" already settled it, and 0022 states
  why a timed exam session strengthens rather than reopens that conclusion.

## REVIEWER sign-off

**2026-09-09 — `REVIEWER`, on decision 0022 and this stage file's first
revision.** PASS on the vertical decision; recorded disagreement on 0022
reasoning §1's cost model. The full sign-off is in
[`decisions/0022-bilimbaga-vertical.md`](decisions/0022-bilimbaga-vertical.md);
its consequences for this file are gaps 10–12, P1's and P2's revised exit
conditions, and the block on expanding P2 before gaps 10 and 11 close — since
extended to gap 13, and refined by
[`decisions/0023-entity-storage-hybrid.md`](decisions/0023-entity-storage-hybrid.md),
which makes gaps 10 and 11 consequences of the storage model rather than
independent work.

Re-verified 2026-09-14. All three clauses this line originally carried are now
false — P0 through P4 are complete and only P5/P6 and certificate issuance
remain:

- **"No S10 requirement exists" — no longer true.** Forty-seven S10 requirements
  are filed (`REQ-295`–`REQ-343`, counting distinct `- id: REQ-NNN` entries
  whose own `stage:` field is S10 — 337 and 341 were retired and never filed as
  real entries, so the id span is non-contiguous), and all forty-seven are
  `done`.

  *Superseded later the same day, 2026-09-14, and left standing rather than
  rewritten so the sequence stays legible: P5 was expanded into `REQ-344`–`REQ-349`
  and closed within hours of this re-verification, so the figures above are a
  snapshot from earlier that day, not the current state. S10 now carries **53**
  requirements spanning `REQ-295`–`REQ-349` (same 337/341 gap), all `done`, and
  only P6 and certificate issuance remain outstanding — not P5. See this file's
  header and the "P5 close-out" section for the current reading.*
- **"No `lib/letflow/exam/` directory exists" — no longer true.** It holds four
  modules — `session.ex`, `question_set_resolver.ex`, `scoring.ex`,
  `anti_cheat.ex` — each carrying its rule-2 justifications and a `REVIEWER`
  bucket-C sign-off in the inventory above, which is correspondingly no longer
  empty. **`web/src/pages/exam/` is also no longer absent, as of 2026-09-14:**
  it holds two modules, `ExamListPage.tsx` and `ExamSessionPage.tsx` (`REQ-338`),
  also carrying their `REVIEWER`/`RELEASE-VALIDATOR` sign-off in the inventory
  above. P4 is now built, not merely expanded — see the phase table's P4 row.
- **"No pack document has been authored" — no longer true.**
  `priv/packs/bilimbaga/pack.json` exists and has been installed for real
  against a provisioned tenant (`REQ-328`), carrying the fifteen entity
  definition documents under `priv/packs/bilimbaga/entity_definitions/`.

**2026-09-14 — `REVIEWER`, rule-2 adjudication for P5 (`REQ-344`–`REQ-349`).**
Raised by `REQ-VALIDATOR` rather than failed over, correctly: the P5
requirements declare bucket C on rule 1's test (they cannot be stated without
naming exams) and none carried a rule-2 sign-off. *(This adjudication was
written against `REQ-344`–`REQ-348`, before `REQ-346`'s split created
`REQ-349`. `REQ-349` ships only Playwright specs and so falls under the same
non-reaching finding as `REQ-346`; the enumeration here is corrected
accordingly, and no other part of the adjudication is affected.)*

**Finding: rule 2 does not reach `REQ-344`, `REQ-346`, `REQ-347` or
`REQ-349`.** Rule 2 gates modules that had a real A/B alternative — its own
text asks why a *behaviour* is not expressible as a definition and not
generalisable as a platform capability, and every sign-off on record
(`req330-exam-live-session.md` §7's four modules, `REQ-338`'s two screens)
attaches to a module whose §7 entry authorises it to be built. A Playwright
spec and an inventory document were never candidates for A or B; the question
has no possible answer, so the gate has nothing to bite on. `REQ-306` is the
precedent on the other side — a `TEST-DESIGNER` requirement that took the
bucket of the thing under test with no separate sign-off. These four are C by
rule 1 and registerable as filed. A class-wide sign-off was considered and
**declined**: rule 2's force comes from per-thing justification, and signing
off a category would establish that categories can be waved through. Not
reaching them is the cleaner finding than reaching them with a weakened rule.

**Finding: rule 2 does reach `REQ-345`, which needs a per-entry sign-off and
has one here.** `REQ-345` ships executable code (a mix seed task writing exam
records through `Letflow.Entities`), and its A/B question has real answers,
which is the proof the gate applies. Its originally-filed bucket line was also
self-undermining — it justified C on rule 1 while describing the deliverable as
"pack/definition-driven seed data plus a mix task", putting the C-ness entirely
on the task half it did not justify. Sign-off, per rule 2's one-sentence-each
form:

- *Why not A:* the fixture's records are bucket-A-shaped (entity records
  against pack-defined definitions), but a definition has no execution
  semantics — it cannot perform the idempotent create-or-resolve convergence
  that re-running the seed requires, which is executable logic.
- *Why not B:* a generic "seed fixture records for a named entity set" mix task
  is a plausible platform capability and is the honest B candidate, but it
  would be built for exactly one caller today; generalising ahead of a second
  is the speculative-generality failure mode `0022` exists to prevent, and the
  same reason `QuestionSetResolver` and `AntiCheat` are C. Revisit if a second
  vertical needs a seeded fixture.

**PASS** on rule 2 for all five. `REQ-348` declares no bucket (stage
bookkeeping, matching `REQ-334` and `REQ-339`) and is unaffected.

**Rule 3 does not bite, verified against this file's own measurement text.**
The metric is directory-scoped — `ls`/`wc -l` over `lib/letflow/exam/*.ex` and
`web/src/pages/exam/*.tsx` — and this file already excludes
`web/src/pages/exam/__tests__/` as "test files, not modules." Specs under
`web/tests/e2e/`, a document under `docs/testing/`, and a mix task outside both
directories fall outside the metric, the last of these by directory rather than
by kind. **P5 adds no bucket-C inventory rows, and the inventory stays at four
modules under `lib/letflow/exam/` and two screen modules under
`web/src/pages/exam/`** (line counts drift between measurements per
`ISS-0665` — see the inventory table above for the current figures). *This
finding is as of P5's own close (2026-09-14); `REQ-351`, filed and
implemented the following day, adds two more `web/src/pages/exam/` modules
(`ExamResultView.tsx`, `ExamSessionResultPage.tsx`, `REVIEWER` rule-2 PASS
2026-09-15) — see the inventory table's 2026-09-15
re-measurement above for the current count. P5's own four-and-two figures are
left standing here as the accurate snapshot of that phase's own close, not
retroactively edited.* That is an honest reading, not a
loophole: an exam-specific acceptance corpus is not the failure mode rule 3
detects (the platform quietly becoming an exam engine) — per `0022` reasoning
§5 it is the independent evidence the generic platform hosts the vertical. A
reader must not read the unchanged inventory as P5 having added nothing
exam-specific; P5's exam-specific output is its ported spec corpus, measured by
`REQ-348`'s parity figure, not by this table.

**Consequence for `0022`.** Rule 2 does not state its own scope, which is why
this came up at all. An amendment stating it is to be filed as its own
requirement rather than edited into `0022` in place, following the precedent of
decision `0030`'s "Consequences" section and `REVIEWER`'s 2026-09-13 sign-off
on it ("a disagreement with standing text becomes a decision-record finding,
not a quiet edit"); until it lands, this entry is the governing precedent.

**2026-09-15 — `REVIEWER`, rule-2 adjudication for `REQ-351` (`ExamResultView.tsx`,
`ExamSessionResultPage.tsx`).** `REQ-351` itself flagged that it needed a
per-entry sign-off before registration and deliberately did not write one for
itself, per this file's own precedent for `REQ-338`'s two screens. Adjudicated
by reading the diff directly (`web/src/pages/exam/ExamResultView.tsx`,
`web/src/pages/exam/ExamSessionResultPage.tsx`, `web/src/router.tsx`,
`web/tests/e2e/exam-result-by-id.e2e.spec.ts`), not by trusting FRONTEND-DEV's
own report.

**Finding: bucket C, not B — the honest A/B question REQ-351 posed has a real
answer.** `ExamSessionResultPage.tsx` is, on its surface, "load a record by id
and render it read-only," which is close enough to a generic capability that
the question deserved asking rather than waving through. It fails rule 1's
generic-statement test anyway: the component's own state machine
(`loading`/`not_found`/`pending`/`score_unavailable`) and its terminal render
branch are keyed to `ExamSubmissionOutcome`'s exam-specific shape
(`status: grading_pending`, `passed`, the `scoring.ex:255-257` forcing rule)
and to `session.status`'s exam-specific vocabulary
(`in_progress`/`submitted`/`auto_submitted`/`grading_pending`) — the same
vocabulary `ExamSessionPage.tsx`'s and `ExamListPage.tsx`'s own rows above
already establish as C-justifying. A generic "entity-record detail view"
could render `session`'s raw field values, but could not know that
`grading_pending` means "show the pending message, never a score" or that a
short-text question forces that state platform-wide — that branching logic is
exam domain knowledge, not a declarative field structure. No second caller
wants this behaviour today; building a generic version now would be the
speculative-generality failure mode `0022` exists to prevent, the same basis
already used for `QuestionSetResolver`/`AntiCheat`/the P5 seed task above.

**Finding: rule 2 reaches both modules, and PASSES.** `ExamResultView.tsx` is
a pure extraction (identical testids/markup/message ids moved out of
`ExamSessionPage.tsx`, a net decrease in `ExamSessionPage.tsx`'s own line
count per the inventory re-measurement above) — reuse across two legitimate
callers, not new
abstraction reached for ahead of need; it does not smuggle in speculative
plumbing (no new props beyond `outcome`/`onBackToList`, no generic
"render-any-outcome-shaped-thing" indirection). `ExamSessionResultPage.tsx`'s
own A/B answer is above. Both **PASS**.

**Finding: no supervision or OTP-idiom concern — this is frontend-only.**
`git diff --name-only` confirms no file under `lib/letflow/` changed; nothing
here touches `Letflow.InstanceSupervisor` or any gen_statem/GenServer boundary.

**Finding: the required scoreable-exam acceptance criterion is genuinely
unmet, and that is correctly reported rather than papered over.** `REQ-351`'s
third acceptance-criterion bullet requires a spec proving `exam-result-page`
and `exam-result-score` render from a LOADED session for `REQ-345`'s
shorttext-free exam. No such scenario exists anywhere in the diff — not
attempted, not stubbed, not xfailed. This is not a partial implementation of
that criterion; it is the criterion's complete absence, and FRONTEND-DEV's own
PR body states so explicitly rather than claiming otherwise. The cause is
real and code-verified: `Letflow.Exam.Session`'s private `session_view/1`
(`lib/letflow/exam/session.ex:1151-1160`) maps only
`id/exam_id/candidate_id/status/seed/started_at/expires_at` out of the
session record into `GET /exam-sessions/:id`'s response, never `score_pct` or
`passed` — even though `submit_session`'s own `outcome_from_session/1`
helper (`session.ex:1087-1098`) proves both fields are already persisted on
the record by the time a session reaches `submitted`/`auto_submitted`.
Fabricating them client-side is correctly refused.

**Adjudication: extending `session_view/1` to also carry `score_pct`/`passed`
would cross `REQ-335`'s scope fence — this is Option B, not Option A.**
`lib/letflow/routers/exam_sessions.ex`'s own moduledoc, quoted verbatim: *"a
*result* view is a sixth behaviour this requirement's own dependency chain
(REQ-330's five) never authorized, not a subset of the *state* read this
module does implement."* That sentence draws its line precisely at the
distinction between a session's *operational* state (status, timing,
ownership — what `session_view/1` returns today) and its *outcome* (score,
pass/fail) — and it names the outcome half, specifically, as the thing
`REQ-335`'s authors declined to authorize. Adding `score_pct`/`passed` to
`session_view/1`'s response would deliver exactly that outcome data through
the existing route rather than through a new one, which is a difference in
mechanism, not in substance: the route stays the same, but the *behaviour*
the route now performs — "tell the candidate their result" — is the one the
moduledoc explicitly reserved. `REQ-351`'s own text anticipated only "this
route's own state read" being reused, not an expanded version of that read
carrying the very fields the fence names. Calling this "minor" because it is
same-route, additive, and already-persisted would let exactly the kind of
side-effect scope settlement this stage file's own P5 section already warns
against ("a product-scope question that P5 must not settle by side effect")
happen one field at a time. **Verdict: this needs a real decision — whether
`GET /exam-sessions/:id` should be widened to carry result data, or whether a
dedicated result read is the right shape once `REQ-350`'s results-list
question resolves — not a same-PR field addition.** Filed as `ISS-0674`
(`GH-1412`, `Q-674`); see that record for the full account. `REQ-350`'s own
results-list adjudication (decision `0031`) is the natural place this
question gets folded in, since both turn on the same "what does a result
surface look like" question, but that is a call for whoever picks up
`ISS-0674`, not asserted here.

**Overall: PASS on rule 2/idiom/supervision/scope for the code that was
built; the requirement is not fully done against its own acceptance
criteria.** 11 of `REQ-351`'s 12 acceptance-criterion bullets are met on
direct re-verification of the diff (route exists; `startSession` absent from
the by-id path, grep-confirmed; the mixed-exam pending scenario passes; the
not-owner scenario passes and matches `get_session_state_for_user/3`'s
`{:error, :not_owner}` path; `git diff --name-only` touches nothing under
`lib/letflow/`; the pre-existing exam-taking/exam-result specs re-run
unchanged per the PR's own quoted 15/15 combined run; no `test.skip`/
`test.fixme` in the diff, grep-confirmed; the 1-of-9-corpus-blocks framing is
stated correctly and does not overclaim; this rule-2 sign-off was correctly
requested rather than self-certified; the URL-PROVISIONAL statement is
present and names `REQ-350` by id; the bucket-C inventory re-measurement
above is accurate). The twelfth — the scoreable-exam `exam-result-score`
scenario — is not met, for the code-verified backend-gap reason above, and is
not fixable within this requirement's own scope fence (no `lib/letflow/`
changes permitted). Recorded as `REQ-351` status `blocked` rather than
`done`, pending `ISS-0674`; see `docs/status/requirement_status.index.yaml`
for the close-out event. Merging `web/src/pages/exam/ExamResultView.tsx` and
`ExamSessionResultPage.tsx` as-is is still correct despite the open
criterion: they are real, working, honestly-scoped improvements (they close 1
of the 9 results-surface-blocked corpus blocks) that regress nothing and do
not need to wait on `ISS-0674`'s resolution.

**2026-09-15 — `REVIEWER`, rule-2 adjudication for `REQ-355` (`Letflow.Exam.Certificate`).**
`REQ-355` itself flagged that it needed a per-entry rule-2 sign-off before
registration and deliberately did not write one for itself, per this file's
own established precedent for `REQ-338`/`REQ-345`/`REQ-351`. Adjudicated by
reading `lib/letflow/exam/certificate.ex` and
`test/letflow/exam/certificate_test.exs` directly (commit `9edf4ced`,
branch `req-355-certificate-issuance`), not by trusting ELIXIR-DEV's own
close-out narrative. `SECURITY-REVIEWER` has already PASSed this branch in
full (INV-1..INV-9, ownership/INV-5 indistinguishability, idempotency
atomicity, branding-snapshot isolation, no PII leakage, permission-scoping
exhaustiveness) — this sign-off covers only rule 2/idiom/supervision/scope,
not the security surface again.

**Finding: bucket C stands — the honest A/B question `REQ-355` posed has a
real answer, and it is not "this is just a record create."** The module's
own moduledoc offers a candidate answer and explicitly declines to
self-certify it; that candidate answer is correct, for reasons stronger
than the moduledoc states in one place, laid out here:

- *Why not A (a definition, plus the existing `Letflow.Entities.Records`
  write surface, with no code in between):* `Letflow.Entities.Definition`
  has no mechanism to express a cross-entity, ordered, multi-field
  eligibility check — its `constraint_def` vocabulary (checked directly
  against `lib/letflow/entities/definition.ex`) covers type/required/
  unique/fk constraints on the record being written, never a precondition
  computed by reading a *different* entity type's live field values first.
  `issue_or_get_for_user/3`'s guard pipeline reads `Letflow.Exam.Session`
  (status, passed) and a separately-fetched `exam` record
  (`certificate_enabled`) *before* any write is attempted, in a fixed
  order that matters for correctness (guard 2, `grading_pending`, must be
  checked and returned before the generic not-submitted guard, precisely
  so a session awaiting grading is never told "you failed" — see the
  moduledoc's own "grading_pending is not a passed: false refusal"
  section). A plain `Records.create_record/2` call, with no guard code in
  front of it, would create a certificate for *any* session regardless of
  status, exam configuration, or outcome — it validates field shape
  against the definition, not cross-entity business state. There is no
  slot in the definition format today to say "refuse this create unless a
  different record's field equals X," and building one now, to authorize
  exactly one caller, is the platform-generalization-ahead-of-need this
  stage's own rule 2 exists to catch — not a reason to call the check
  "declarative" by fiat.
- *Why not B (a generic "gate a create on another entity's field values"
  capability):* that capability doesn't exist today, and the honest
  question is whether this is the second or third caller that would
  justify building it, per `0022`'s own speculative-generality test. It
  isn't — `Letflow.Exam.Session`'s own eligibility pipeline (assignment,
  active/archived, availability window, attempt limits, one-open-session)
  is the closest precedent in this vertical, already justified C by this
  file's first inventory row on exactly this basis rather than
  generalized into shared platform machinery, and no second vertical
  exists yet to demand a shared abstraction. Building one now for a
  single caller is the same failure mode already declined for
  `QuestionSetResolver`, `AntiCheat`, and `REQ-345`'s seed task above.
- *The three-valued `passed` handling is a genuine judgment call requiring
  code, not a validation rule.* Treating `grading_pending` as its own
  refusal (`:grading_pending`) rather than folding it into
  `:session_not_passed` is not a data-shape decision a definition could
  express even in principle — it is a decision about what message a
  candidate is honestly owed, reached by reasoning about a queue that does
  not exist in this codebase (`lib/letflow/exam/scoring.ex:255-257`'s
  forcing rule, `lib/letflow/routers/exam_sessions.ex`'s own scope fence).
  That is application logic, not record structure, by construction — no
  amount of expressive constraint syntax turns "which of two honest
  refusal messages does this candidate deserve" into a field-level rule.
- *The idempotency-key derivation and the branding-snapshot's
  first-issuance-only capture are both executable, not declarative.*
  Computing `"certificate:issue:" <> session_id` and choosing to route it
  through `Letflow.EventStore`'s real unique index rather than the
  heavier automatic-column-promotion path (deliberately declined — see
  the moduledoc's own "Idempotency" section for why `constraints` was
  left off the entity definition on purpose) is a design decision with
  runtime consequences, and reading `TenantConfig.branding_from_settings/1`
  exactly once, only on the create branch, is control flow a definition
  has no vocabulary for at all.

**Verdict: this module correctly stays bucket C. It was not, and could not
have been, expressed as bucket A pack content plus a plain
`Letflow.Entities.Records.create_record/2` call** — not because the
*record shape* is complex (it isn't; the entity definition half is
correctly bucket A, per this file's inventory row and the same reasoning
`REQ-329`'s five session types already established), but because the
*issuance decision* requires reading two other live entities in a fixed
order, producing one of six distinct outcomes, and performing a
first-write-only side effect (the branding capture) — none of which the
platform's declarative surface can express today. **PASS on rule 2.**

**Rule 1 was already correctly self-assessed C by `REQ-355`'s own text**
(the eligibility rule set cannot be stated without naming exams/sessions)
and is not re-litigated here; rule 2 is the gate this sign-off exists for.

**Idiom/supervision: no concern.** `issue_or_get_for_user/3` is a plain
function in a context module, not a process — correctly so, since
`Letflow.Engine`'s "process-vs-row" decision (REQ-045) already settled
that this vertical's runtime unit is a row, not a supervised process, and
nothing here reaches for a `GenServer`/`spawn`/singleton to do a
one-shot guarded write. No `Letflow.InstanceSupervisor` interaction is
implicated; `git diff --name-only` against `main` confirms no
`lib/letflow/` file outside `lib/letflow/exam/certificate.ex`,
`lib/letflow/api/authorization.ex`, and `lib/letflow/routers/` changed in
a way that touches supervision.

**Scope creep: none found.** The module writes exactly one entity type
(`certificate`), reuses `Session.get_session_for_user/3` rather than
re-implementing ownership/not-found semantics (moduledoc's own "reused
here rather than re-implemented" note, verified against the actual
delegation in `issue_or_get_for_user/3`'s first `with` clause), reuses the
real `event_idempotency` unique index rather than inventing a new
idempotency mechanism, and declines to wire an unreachable admin bypass
parameter no caller today would ever set (moduledoc's own "admin bypass is
NOT wired" section) rather than speculatively future-proofing. No
behaviour, macro, or generic plumbing appears ahead of what this
requirement needs.

**Type-safety observation, filed rather than left only in this
narrative (per this role's own standing instruction not to let an
observation die in a summary nobody claims):** `issue_error` is a bare
atom union (`@type issue_error :: :session_not_found | :not_owner |
:grading_pending | :session_not_submitted | :exam_not_certifiable |
:session_not_passed`), and the router's own `render_issue_certificate/2`
has a catch-all clause (`{:error, reason} -> Logger.warning(...)`) that
would silently 500 on any atom typo introduced by a future edit rather
than fail at compile time. This does not block the PASS below — it is
the same class already accepted elsewhere in this vertical (`Session`'s
own error unions are shaped the same way) — but it is exactly the kind of
"only a runtime error or the property test catches this" gap `@type`
changes alone cannot close (Elixir's type system doesn't enforce
exhaustive atom-union handling at the call site). Per
`docs/agents/protocols/ISSUE_QUEUE.md` ("the discovering agent reports
the finding to ORCH ... it does not call `gh` or `letflow-queue`
itself"), this is reported here as a claimable finding, tagged
`type-safety`, for ORCH to register via `register_task` (task_type:
"issue") during this requirement's close-out — not written as a
docs/issues/ISS-NNNN.yaml record directly by REVIEWER, since that id is
only ever allocated by `register_task`'s response, never assigned
locally.

**Other acceptance criteria, independently re-verified against the diff
and by running the suite, not by trusting ELIXIR-DEV's report:**
idempotency is proven by a test that calls `issue_or_get_for_user/3`
twice and counts rows via a real query
(`test/letflow/exam/certificate_test.exs`'s "idempotency" describe block,
asserting `length(records) == 1`), not by inspecting the implementation;
ownership refusal (`:not_owner`) is asserted by a dedicated test and both
`:not_owner` and `:session_not_found` render `Response.not_found/1`
identically in `lib/letflow/routers/exam_sessions.ex`, satisfying INV-5;
`grading_pending` vs. `:session_not_passed` are asserted as literally
distinct error values by the same test
(`grading_pending_result != {:error, :session_not_passed}`), not merely
as two refusals; the branding-snapshot test mutates `Tenant.settings`
*after* issuance and re-reads through the idempotent-replay path,
asserting the stored snapshot is unchanged; `mix compile
--warnings-as-errors --force` is clean (`Compiling 230 files (.ex)`,
`Generated letflow app`, re-run directly by REVIEWER); `mix test` against
`test/letflow/exam/certificate_test.exs`,
`test/letflow/routers/exam_sessions_test.exs`, and
`test/letflow/api/authorization_test.exs` together passes 128/128, re-run
directly by REVIEWER rather than accepted from ELIXIR-DEV's report; `git
diff --name-only main...HEAD` touches no `mix.exs` and no PDF/QR-rendering
file, re-run directly by REVIEWER; the bucket-C inventory measurement was
re-run from the tree directly by REVIEWER (`ls lib/letflow/exam/`, `wc -l
lib/letflow/exam/*.ex`) and independently reproduces ELIXIR-DEV's own
reported 5 modules / 2,280 lines exactly.

**Overall: PASS.** Bucket C is correct for `Letflow.Exam.Certificate`; the
entity definition correctly stays bucket A; no idiom, supervision, or
scope-creep concern; all other acceptance criteria independently
re-verified. This sign-off satisfies `REQ-355`'s own required per-entry
rule-2 gate and its "sign-off obtained and recorded before merge"
acceptance criterion.

## P5 close-out — `REQ-348`, 2026-09-14

**Both required independent re-verifications performed. RELEASE-VALIDATOR
re-ran the ported suite itself (not citing `REQ-346`'s/`REQ-347`'s/`REQ-349`'s
own reported results); `UAT-RUNNER` separately drove the same suite against
the real running instance. Both quote real, verbatim evidence below.**

### Measured parity

**34 of 168** corpus `test()` blocks (`REQ-344`'s corrected count) are ported
and passing: **34 / 168 ≈ 20.2%.** The remainder (134) is fully accounted for
below, file by file, against `REQ-344`'s 19-file/168-test corpus
(`docs/testing/REQ-344-bilimbaga-parity-triage.md`) — no file and no test is
left unattributed.

### Full accounting, `REQ-344`'s 19 files → what actually shipped

| Source file | Source tests | Ported (file) | Ported test() count | Disposition of the rest |
|---|---:|---|---:|---|
| `categories.spec.ts` | 5 | `categories.e2e.spec.ts` | 5 | all 5 ported — PORTABLE-NOW |
| `tags.spec.ts` | 6 | `tags.e2e.spec.ts` | 5 | 1 dropped, NO-COUNTERPART (search-filter — `EntityCrudPage` has no search box) |
| `question-bank.spec.ts` | 7 | `question-bank.e2e.spec.ts` | 2 | 5 dropped, NO-COUNTERPART (editor-navigation, difficulty badges, search ×2, Import/AI-Generate) |
| `exam-lifecycle.spec.ts` | 8 | `exam-lifecycle.e2e.spec.ts` | 6 | 2 dropped, NO-COUNTERPART (edit-wizard navigation — `EntityCrudPage`'s edit action opens the same single-step modal as create, no wizard) |
| `employee-portal.spec.ts` | 8 | `employee-portal.e2e.spec.ts` | 3 | 5 dropped, NO-COUNTERPART (Start-modal open/cancel, Continue CTA, View-Result CTA, "My Results" page — none exist; `ExamListPage`'s Start button navigates directly, no modal) |
| `exam-taking.spec.ts` | 11 | `exam-taking.e2e.spec.ts` | 9 | 2 dropped, NO-COUNTERPART (flag/unflag — no flag control exists; submit-confirmation happy path — no confirm modal, folded into the direct-submit test) |
| `exam-result.spec.ts` | 5 | `exam-result.e2e.spec.ts` (shared with `my-results.spec.ts` below) | 4 | 1 dropped, NO-COUNTERPART (result-by-id deep link — `REQ-335`'s own scope fence excludes result-by-id/results-list views; no route exists) |
| `my-results.spec.ts` | 6 | *(same file)* | 0 | all 6 dropped, NO-COUNTERPART (cross-session results-LIST view — `REQ-335`'s scope fence excludes it; no `/portal`-equivalent route exists) |
| `auth.spec.ts` | 5 | — | 0 | NO-COUNTERPART, whole file — no in-app `/login` form; Keycloak-hosted login is out of this SPA's test surface. Letflow's own OIDC e2e coverage exists separately under `web/tests/e2e/` |
| `exam-wizard.spec.ts` | 9 | — | 0 | NO-COUNTERPART, whole file — no multi-step exam-authoring wizard exists or is planned under S10 |
| `admin-grading.spec.ts` | 7 | — | 0 | NO-COUNTERPART, whole file — no `/admin/grading` manual-grading queue UI exists |
| `grading/ai-grading.spec.ts` | 9 | — | 0 | NO-COUNTERPART, whole file — no grading-queue UI and no AI-authoring question-editor tier exists |
| `accessibility.spec.ts` | 7 | — | 0 | NO-COUNTERPART, whole file — `AppShell` has no skip-link/`#main-content` landmark at all; four of the seven target the nonexistent `/login` |
| `branding.spec.ts` | 4 | — | 0 | NO-COUNTERPART, whole file — branding is read-only (`REQ-283`), no admin settings editor screen exists |
| `question-editor.spec.ts` | 7 | — | 0 | NO-COUNTERPART, whole file — no dedicated type-conditional question-editor page; deliberately outside `REQ-347`'s entity-CRUD scope |
| `question-management.spec.ts` | 20 | — | 0 | NO-COUNTERPART, whole file — delete/archive/import/export/AI-generate tooling, none of which exists in the generic entity-CRUD engine |
| `user-management.spec.ts` | 18 | — | 0 | NO-COUNTERPART, whole file — `UsersPage` supports list/search/create only; edit/deactivate/reset-password/bulk-import are all real, unbuilt |
| `loyalty-narrative.spec.ts` | 4 | — | 0 | NO-COUNTERPART, whole file — no `/admin/users/:id/record` employee-record page or AI-narrative feature exists |
| `full-walkthrough.spec.ts` | 22 | — | 0 | NOT ported as its own file — its PORTABLE-NOW/PORTABLE-AFTER sub-tests (dashboard heading, users list, categories/tags pages, question-bank list, audit log render) are the same assertions already covered by the dedicated per-surface files above; its remaining sub-tests are NO-COUNTERPART for the same reasons as their dedicated files (wizard, grading, branding, departments, employee-record, change-password, exam-analytics, AI-insights card, nav aria-label). `REQ-346`/`REQ-347`/`REQ-349` did not name it as a target file — deferred, not silently dropped |
| **Total** | **168** | | **34** | **134 accounted for above: 90 whole-file NO-COUNTERPART (matching `REQ-344`'s own count) + 22 within-file NO-COUNTERPART drops from the 8 partially-ported files + 22 full-walkthrough (deferred, redundant with the above)** |

### 1. RELEASE-VALIDATOR's independent re-run (real `npx playwright test`, not citing `REQ-346`/`REQ-347`/`REQ-349`'s own reports)

Re-ran `web/tests/e2e/{categories,tags,question-bank,exam-lifecycle,employee-portal,exam-taking,exam-result}.e2e.spec.ts` directly, multiple times, against this checkout's own already-running instance (Letflow on `:4000`, Keycloak on `:8093`, Postgres on `:5462`). First attempts surfaced two of RELEASE-VALIDATOR's own environment mistakes, root-caused and corrected before treating any run as authoritative:

- Setting `VITE_API_BASE_URL` to an absolute cross-origin URL made the SPA bypass Vite's same-origin dev proxy, triggering a real browser CORS-preflight rejection on the `x-bpm-user-id` header (`Access to fetch ... has been blocked by CORS policy`) — an artifact of the invocation, not a product defect. Corrected by leaving `VITE_API_BASE_URL` unset (`web/.env.local`'s own default).
- `lib/letflow/exam/session.ex`'s `check_attempts_exhausted/2` counts ALL historical finished sessions for a (user, exam) pair, including soft-deleted ones (no `deleted:false` filter) — repeated local runs against this one persistent dev database exhausted `admin-user`'s attempts against both `REQ-345` fixture exams (the only test identity these specs can use — no `CANDIDATE` Keycloak user is provisioned). Restored via a real `PUT /api/v1/entities/records/exam/:id` (full `field_values`, `max_attempts` only) — not a database bypass. Confirmed via `.github/workflows/ci.yml` that a real CI run always starts from a fresh `ecto.create`/`ecto.migrate` database, so this is a local-repeated-validation artifact, not a CI-relevant defect.

A clean run once both were corrected:

```
Running 34 tests using 1 worker
...
  2 flaky
    [chromium] › exam-lifecycle.e2e.spec.ts:199:3 › ... "draft" status text
    [chromium] › exam-lifecycle.e2e.spec.ts:223:3 › ... all exam rows have an Edit action
  32 passed (36.6s)
PW_EXIT=0
```

GREEN, exit 0. The two flaky tests (failed attempt 1, passed on Playwright's own configured retry) were traced to a third, separate local artifact: `EntityCrudPage`'s records query has no `deleted:false` filter (confirmed by direct `POST /api/v1/entities/query` inspection — dozens of soft-deleted historical exam rows from today's own repeated runs dominate page 1 of the default 25-row page), occasionally pushing a freshly-created row off page 1 within the exam-lifecycle spec's own 10s lookup window. Filed as **`ISS-0663`** (`GH-1396`, `Q-663`) — real, but does not reproduce against a fresh database and is not a defect in the ported suite or in `REQ-347`'s work.

### 2. `REQ-345` fixture verified present via real HTTP before accepting any candidate-side pass

```
$ curl -s -X POST http://localhost:4000/api/v1/entities/query \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"entity_type":"exam"}'
{"items":[
  {"field_values":{"title":{"en":"REQ-345 E2E Mixed Exam"},"status":"active", ...},"record_id":"30615472-867a-435f-899e-c5438b3fab32"},
  {"field_values":{"title":{"en":"REQ-345 E2E Scoreable Exam"},"status":"active", ...},"record_id":"7d134561-7da3-404c-91c4-bb2e8c7eed89"}
],"next_cursor":null}
```

Both fixture exams present and active, in the bpm-default tenant, before any test run was accepted as evidence.

### 3. `UAT-RUNNER`'s independent pass against the live instance

Dispatched separately (not RELEASE-VALIDATOR reporting under a second hat). Its own real-HTTP liveness check and fixture confirmation matched the above independently. Its first run (before RELEASE-VALIDATOR's `max_attempts` diagnosis was shared with it) correctly reported RED for the reason then in effect (attempts exhaustion). Its second run, after the fix:

```
1 failed
  [chromium] › exam-lifecycle.e2e.spec.ts:211:3 › ... "archived" status text
1 flaky
  [chromium] › exam-lifecycle.e2e.spec.ts:223:3 › ... all exam rows have an Edit action
32 passed (47.8s)
```

Candidate flow (`employee-portal`/`exam-taking`/`exam-result`) passed cleanly with no retries, confirming the attempts fix. The one hard failure and one flake are the same `ISS-0663` page-1 lookup mechanism RELEASE-VALIDATOR had already diagnosed and shared with it in advance — attributed to that cause rather than treated as a new, unexplained defect, per core-directives.md's structural-attribution rule.

### Verdict

The ported parity suite passes on its own merits: every one of its 34 test() blocks has demonstrated a real pass under live conditions (Letflow + Keycloak + Postgres + the `REQ-345` fixture) across multiple independent runs by two independent roles. The only observed instability (`ISS-0663`) is proven, by direct API evidence, to be an artifact of this one persistent local development database having been exercised many times over the course of this same close-out's own verification work — not reproducible against the fresh database a real CI run always starts from, and not a defect in `REQ-346`/`REQ-347`/`REQ-349`'s ported work. No test was skipped, retried-until-green by narrowing scope, or deleted to force a pass.

## REQ-356 — flagged, PENDING REVIEWER rule-2 sign-off (not self-adjudicated here)

`Letflow.Exam.CertificateDocument` (this requirement) ships executable code
under `lib/letflow/exam/`, so per REVIEWER's 2026-09-14 rule-2 adjudication
above, it needs its own per-entry sign-off — deliberately not written by
ELIXIR-DEV. REQ-356's own `requirements.yaml` text states the honest A/B
question REVIEWER must answer: a certificate layout is close to a document
template, and Letflow has a form-schema/definition tradition, so "why is the
template not declarative pack content rendered by a generic renderer" is a
genuine bucket-A candidate that must be answered rather than waved past. The
bucket-C inventory row above records this module as **PENDING** until that
sign-off is recorded here.

**Also carried forward for REVIEWER's attention, not this file's own
adjudication:** `lib/letflow/exam/certificate_document.ex`'s own moduledoc
records a finding reopening decision `0033` — the chosen `pdf` library has
no Unicode/non-Latin-1 glyph rendering path (WinAnsi/Latin-1 only, via
bundled Type-1 AFM fonts), a gap that decision never evaluated because it
never considered glyph coverage as a criterion. This is material for a
Cyrillic-script vertical (`kk`/`ru` exam locales). The module degrades
gracefully (`encoding_replacement_character: "?"`) rather than crashing, so
REQ-356's own acceptance criteria are met for Latin/English content, but a
follow-up requirement must decide how (or whether) to address non-Latin
rendering before this vertical's Cyrillic-locale certificates are genuinely
legible. No substitute library was adopted in response to this finding, per
CLAUDE.md's prohibition on silently re-deciding a decision record.
