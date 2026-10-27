# BilimBaga retirement criteria 1-6 and 9: status on main

Study T-0627, written 2026-10-25 for the portfolio (decision D-032,
`proposals/bilimbaga-retirement-criteria.md` in ai-dala-portfolio). Read-only: no behaviour
change, nothing in the BilimBaga repo or demo was touched. Criteria 7, 8 and 10-12 are out of
scope for this study.

Everything below was read from `main` at commit `39de1e7be`. Where a statement rests on a
document (stage 10, a decision record) rather than on code I opened, it says "per doc". Sizes
are rough: S = one task, M = 2-4 tasks, L = a requirement family of 5+ tasks.

**Important correction to older docs.** `docs/migration/stage-10-bilimbaga-vertical.md` still
names `lib/letflow/exam/`, `web/src/pages/exam/` and `priv/packs/bilimbaga/`. Those paths no
longer exist. REQ-410 moved the exam runtime into the module system:

| Old path (stage 10 text) | Path on main |
|---|---|
| `lib/letflow/exam/*.ex` | `lib/letflow/modules/exam/` (session, scoring, anti_cheat, certificate, certificate_document, certificate_public_projection, question_set_resolver, authoring, snapshot, router) |
| `web/src/pages/exam/` | `web/src/modules/exam/` |
| `priv/packs/bilimbaga/` | `priv/modules/exam/` (`pack.json`, 17 entity definitions) plus `priv/solutions/bilimbaga.json` |
| `POST /exam-sessions` | `/api/v1/modules/exam/exam-sessions` |

Tests live in `test/letflow/modules/exam/` (27 files) and `test/letflow/modules/bilimbaga_solution_e2e_test.exs`.

## Summary

| # | Criterion | State on main | Size of the remainder |
|---|---|---|---|
| 1 | Exam core | Mostly built. Missing: assignments, departments, a manual-grading queue, adaptive selection | M-L |
| 2 | Screens for five roles | Candidate screens and a generic admin CRUD exist. No role-specific screens, no role mapping defined | L |
| 3 | e2e parity | 34 of 168 ported (per doc); on main 8 BilimBaga-related spec files, 37 tests. 134 not ported | L |
| 4 | Certificates | Built: issue, PDF, QR, public verify route. Gaps are polish, plus a public verify page in `web/` | S-M |
| 5 | E-mail | Not built. SMTP exists for login discovery only | L |
| 6 | AI authoring and analytics | AI: absent. Analytics: aggregate query API exists, no exam analytics views | L (AI), M (analytics) |
| 9 | Provisioning and white-label | Branding colours, app name and logo URL exist. Provisioning routes not built (REQ-572 pending, one slice merged) | L |

## 1. Exam core

Criterion: question banks kk/ru/en, tags, categories, departments, exams, assignments, timed
sessions, auto-grading, anti-cheat.

**Exists (code on main).**
- Entity definitions in `priv/modules/exam/entity_definitions/`: `category`, `tag`, `question`,
  `answer_option`, `question_tag`, `exam`, `exam_section`, `exam_question_rule`,
  `exam_question_rule_tag`, `exam_manual_question`, `session`, `session_question`,
  `session_answer`, `session_question_score`, `session_event`, `certificate`. Question text is the
  `localized_text` type (blob-stored, per-locale generated column when `queried: true`).
  `question.json` declares `"locales": ["kk", "ru", "en"]` on its localized fields.
- Timed sessions: `Letflow.Modules.Exam.Session` (eligibility, seeded question materialisation via
  `QuestionSetResolver`, server-authoritative deadline, autosave, submit). The deadline sweep runs
  on `Letflow.Scheduler.Poller` (per doc, REQ-331). Sessions freeze an exam snapshot (answer key,
  threshold, digest) at start (`snapshot.ex`, GH #2682).
- Auto-grading: `Letflow.Modules.Exam.Scoring` (single, true-false, multiple partial credit,
  Likert, short-text marked `pending_manual`).
- Anti-cheat: `Letflow.Modules.Exam.AntiCheat` (tab_switch, blur, fullscreen_exit; log/warn/submit
  per exam config; write-rate debounce); client side `web/src/modules/exam/useAntiCheatSignals.ts`.
- Authoring writes: `POST/PUT/DELETE /authoring/:entity_type` (`ExamAuthoringWrite`).
- Routes: `lib/letflow/modules/exam/router.ex` (start, available, state, autosave, submit, events,
  certificate, authoring).
- Tests: `session_test`, `scoring_test`, `anti_cheat_test`, `question_set_resolver_test`,
  `exam_sessions_test`, `snapshot_*` and others in `test/letflow/modules/exam/`.

**Missing.**
1. **Assignments.** `Session.check_assigned/3` is a documented no-op (`session.ex`, `defp
   check_assigned(_candidate_id, _exam_id, _prefix), do: :ok`). No `exam_assignment` entity exists;
   BilimBaga's `013_exam_assignments` is only quoted in `README-constraints.md`. Every candidate can
   start every active exam. Needs a design decision (assignment to user, group or department) first.
   Size M.
2. **Departments.** No department entity in the pack. The org module (`priv/modules/org/`) may be
   the right home (org-scoped grants exist, decision 0051); not verified here whether it covers
   BilimBaga's department semantics. Needs a short design task. Size S-M.
3. **Manual grading of short text.** Scoring stores `pending_manual`; the router's moduledoc lists
   the grading queue as "deliberately NOT routed". No examiner screen or route. Size M.
4. **Adaptive question selection** and **results history / exam history** routes (BilimBaga
   FR-BB72, FR-BB41/46): named as unimplemented in the router moduledoc. Adaptive: size M and only
   if BilimBaga uses it in production (unverified).
5. **Category tree and question version lineage** (`parent_id`): REQ-586 part A (GH #3315) declares
   `parent_id` on `category.json` and `question.json` (string, queried, optional) with `fk_category_parent_id` /
   `fk_question_parent_id` and an index each; an install gives a nullable uuid self-FK `ON DELETE RESTRICT`; the
   authoring surface refuses `parent_cycle`, `parent_not_found` (422) and `category_has_children` /
   `question_has_children` (409) via `Letflow.Modules.Exam.AuthoringRules`. Remaining: question lineage rules,
   the session pool test, the tenant rollout and the web tree picker (REQ-586 parts B-D); `bilimbagaEntities.ts`
   still states the fields are not declared. T1c is in progress (part A done).
6. **Bulk question import/export** is available generically (`/entities/records/:type/import|export`);
   a BilimBaga-format importer (P6) is not built and is conditional on real data (per doc).
   Data migration is a separate retirement question, not covered by criteria 1-9.

**Proposed tasks.**
- T1a requirement + design: exam assignment model (user/group/department), then implementation
  replacing `check_assigned/3`.
- T1b requirement: examiner manual-grading queue (routes, permission, screen).
- T1c change: add `parent_id` to `category` and `question` and the tree picker.
- T1d study: does BilimBaga production use adaptive selection? (owner/portfolio question; if no, drop.)

## 2. Screens for the five roles mapped to Letflow roles

Criterion: five BilimBaga roles' screens, mapped to Letflow roles.

**Exists.**
- Candidate: `web/src/modules/exam/` (`ExamListPage`, `ExamSessionPage`, `ExamSessionResultPage`,
  `ExamResultView`), routes in `examRoutes.tsx`, own i18n provider (`ExamIntlProvider`,
  `examMessages.ts`). Letflow role `CANDIDATE` (`docs/roles.md`) with six exam permissions.
- Admin: `BilimBagaAdminPage` at `/admin/bilimbaga/:entityType` over the generic `EntityCrudPage`,
  covering the ten authoring entity types in `web/src/config/bilimbagaEntities.ts`.
- Tests: ten Vitest files in `web/src/modules/exam/__tests__/`, `AppShell.candidate-nav.test.tsx`,
  `AppShell.bilimbaga.test.tsx`.
- Other Letflow roles that can be used: `TENANT_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`,
  `TASK_WORKER`, `TENANT_AUDITOR`, `PLATFORM_ADMIN`.

**Missing.**
1. **The mapping itself.** I found no document that lists BilimBaga's five roles and maps each to
   a Letflow role. `docs/agents/ba-personas/bilimbaga.yaml` covers one persona (Head of Learning
   and Assessment) only. First task is a table, written with the portfolio (the roles live in the
   BilimBaga repo, which this study did not read). Size S.
2. **Examiner / grader screens** (depends on 1.3 above). **Manager / department-head screens**
   (results by department; depends on departments and analytics, criteria 1 and 6). **Reporting
   screens** for a compliance reader (`TENANT_AUDITOR` can read entity data, no screen).
3. Admin screens are generic CRUD, not workflow screens (no exam builder with sections and rules in
   one view, no assignment screen). Size M.
4. No `ExamAuthoringWrite`-scoped role below `TENANT_ADMIN`/`PROCESS_DESIGNER` was checked; whether
   an "exam author" role is needed is part of the mapping task.

**Proposed tasks.** T2a study/doc: role mapping table (with the portfolio). T2b-T2d changes: examiner
screen, exam builder screen, manager/department results screen (each after its backend criterion).

## 3. e2e parity

Criterion: 168 BilimBaga tests, 34 ported, 134 not.

**Exists.**
- Per `docs/testing/REQ-344-bilimbaga-parity-triage.md` and the stage 10 "P5 close-out": 34 of 168
  tests ported, 134 accounted for file by file. 90 were classified NO-COUNTERPART against `web/` at
  that time.
- On main, BilimBaga-related Playwright specs in `web/tests/e2e/`: `exam-lifecycle` (6),
  `exam-taking` (11), `exam-result` (4), `exam-result-by-id` (3), `question-bank` (2), `categories`
  (5), `tags` (5), `pipelines/bilimbaga-candidate-timed-exam` (1): 37 `test(` blocks counted by
  grep, which does not equal the 34 (some are shared helpers or counts differ; the doc figure
  should be re-measured, see task T3a).
- Backend e2e: `test/letflow/modules/bilimbaga_solution_e2e_test.exs`, plus the seed fixture task
  `mix letflow.seed.exam_fixtures`.

**Missing.**
1. 134 tests not ported, of which most target screens that do not exist (assignments, examiner
   grading, departments, analytics, e-mail, AI). They cannot be ported before their screens exist,
   so this criterion is gated by 1, 2, 4-6.
2. Playwright specs cannot run on this host (per project notes); parity needs UAT/QA runs.
3. The 168/34/134 figures are from 2026-09-14 and the exam module moved since (REQ-410); the
   port inventory has not been re-run.

**Proposed tasks.** T3a study: re-measure the corpus against main and re-classify the 134 into
PORTABLE-NOW / BLOCKED-BY-<criterion> / DROP. T3b change tasks: port the PORTABLE-NOW batch in
groups of about 10 tests. T3c: later batches, per screen delivered under 1, 2, 4-6. Size L overall,
but most of it is queued behind other criteria.

## 4. Certificates

Criterion: issue, PDF, QR verify.

**Exists.**
- Issue: `Letflow.Modules.Exam.Certificate` (`issue_or_get_for_user/3`, idempotent, branding snapshot
  at first issuance); route `POST /exam-sessions/:id/certificate`; `certificate.json` entity.
- PDF with embedded QR: `CertificateDocument.render/2` using `pdf` and `eqrcode` (`mix.exs`;
  decision 0033); route `GET /exam-sessions/:id/certificate/download`.
- Public verification: `CertificatePublicProjection` registered as a public-read kind on the
  `/api/public` mount (`lib/letflow/public_read*`, `lib/letflow/routers/public_read.ex`, decision
  0028; capability handle, rate limited).
- Tests: `certificate_test`, `certificate_document_test`, `certificate_public_projection_test`,
  `certificate_snapshot_test`.

**Missing / to check.**
1. No SPA page for the verification URL that the QR encodes. `web/src` has no certificate page
   (grep for "certificate" under `web/src` finds only an access fixture, an entity-label message and
   a config test: no page or component). A QR that opens raw JSON is not a retirement-grade verify.
   Size S-M.
2. Candidate-side "my certificates" list and download button: not found; the download route exists
   but I did not find the UI calling it. Size S.
3. Revocation / expiry of a certificate: not found. Needs owner input on whether BilimBaga has it.
4. Certificate layout per tenant branding: branding snapshot is stored; whether the PDF uses the
   logo is unverified.

**Proposed tasks.** T4a change: public certificate verify page in `web/` (no auth). T4b change:
"my certificates" list and download in the candidate UI. T4c study: BilimBaga certificate features
not yet matched (revocation, template).

## 5. E-mail (reminders, reset, welcome)

**Exists.**
- `gen_smtp` dependency (decision 0045), `Letflow.LoginDiscovery.Notifier.Smtp` with config from
  settings and credentials from the environment (`LETFLOW_SMTP_USERNAME` / `LETFLOW_SMTP_PASSWORD`).
  It is wired only to the login-discovery notifier port (sign-in mail for email-first login).
- A notification template store (`Letflow.NotificationTemplates`, routes in
  `routers/notification_templates.ex`, REQ-563) with exactly one registered key, `task_assigned`.
  Nothing sends it: callers of `NotificationTemplates.*` outside the module are only its router.
- A scheduler (`Letflow.Scheduler`, `ScheduledJobs`) that could drive reminders.
- Password reset and account welcome: identity is delegated to Keycloak/OIDC (decision 0044), so
  reset mail is a realm setting, not Letflow code. Not verified against the realm template.
- The pending first-admin grant (decision 0048) exists; it sends no welcome mail.

**Missing.**
1. A general outbound mail service: tenant-level sender, queue, retries, failure visibility,
   bounce handling (the SMTP adapter is deliberately fire-and-forget and classifies nothing). Size M.
2. Template keys for the exam: reminder before `available_until`, assignment notice, welcome,
   result/certificate. Size S each once the service exists.
3. Reminder scheduling over assignments (needs criterion 1 assignments). Size M.
4. Reset and welcome: decide whether Keycloak sends them (infra task: realm SMTP and templates in
   the realm template) or Letflow does. This is an owner/infra decision; flagged, not assumed.

**Proposed tasks.** T5a requirement + design: outbound notification delivery (from the template
store through the SMTP adapter), with a delivery log. T5b change: exam reminder, assignment and
result templates. T5c study: how BilimBaga sends reset/welcome today and whether the realm template
(REQ-572 item) covers them.

## 6. AI authoring and analytics (treat as REQUIRED until shown unused)

**AI authoring.** Nothing on main: no LLM client, no AI route, no pack entity for generated
questions (grep for `openai`, `anthropic`, `llm` in `lib/` and `priv/modules` finds only unrelated
design-doc mentions). It must be treated as required.
- Needed: a study of what BilimBaga's AI does (question generation from a text? translation? both?),
  then a requirement. Design issues: provider choice and key by reference (`Letflow.Secrets`,
  INV-4), tenant-controlled prompts and outbound URL validation (INV-9), cost limits, rate limiting
  (decision 0040), the output landing as draft questions through `Authoring`. Size L (study S, design
  S, backend M, screen M).
- Task: T6a study (usage in BilimBaga, with the portfolio: is it used at all); T6b requirement.

**Analytics.**
- Exists: a generic aggregation API, `POST /entities/query/aggregate`
  (`Letflow.Entities.Query.Compiler.run_aggregate/2`, REQ-312/315), usable over the session and
  score entities; `session_question_score` exists, so per-question statistics are computable.
  Also dashboards for platform operations (`web/src/pages/dashboard/`, tenant dashboard e2e).
- Missing: any exam analytics view: pass rate per exam, score distribution, per-question
  difficulty and discrimination, per-department results, time-to-complete, export. The page in
  `web/src/modules/exam/` list has none. Size M for a first set of three reports, plus saved views
  (decision 0066) as a possible vehicle. Access control: reads must honour field restrictions on
  `exam_snapshot` (answer key) and tenant scoping.
- Task: T6c requirement: exam analytics reports (list the BilimBaga reports first, T6d study).

## 9. Tenant provisioning and white-label branding

**Branding, exists.**
- `GET /api/tenant-config` and the mobile variant serve a `branding` block: `app_name`, `logo_url`,
  `brand_colors` (`routers/tenant_config.ex`; fields from the tenant's stored settings); write path
  `PATCH` tenant settings (`TenantSettingsManage`, REQ-382, `routers/tenant_settings.ex`).
- SPA: `web/src/theming/` applies the `primary` colour only (`BRAND_COLOR_CSS_PROPERTY` has one
  entry, `--color-brand-600`), app name via `BrandingContext`. Tests: `AppShell.branding.test.tsx`,
  `tenant-branding.pipeline.e2e.spec.ts`. Certificates take a branding snapshot.

**Branding, missing.**
1. Only one colour is themable (no secondary, background, font); the allowlist must move on the
   server first (per the file's own comment). Size S.
2. Per-tenant login page branding and e-mail branding (depends on criterion 5). Size S-M.
3. Per-tenant custom domain / subdomain: the e2e `oidcf2-subdomain` exists, but whether a tenant can
   own a custom domain is not verified. Treat as unknown.
4. Logo upload: `logo_url` is a URL string; there is no upload path in the branding flow (attachments
   exist for entity records). Size S.

**Provisioning, exists.**
- `POST /tenants` and `POST /onboarding` (with `admin_email`, optional `idp_realm_id`; pending
  first-admin grant, decision 0048), `bind-realm`, `deactivate` / `reactivate`, `PATCH /tenants/:slug`.
  All use `:TenantsManage`, i.e. a `PLATFORM_ADMIN` of the platform tenant.
- Merged slice of REQ-572 (PR #3270): a deactivated tenant stops its realm provider and leaves the
  tenant-config list. The amendment (PR #3272) added the realm template, lifecycle and settings
  criteria.

**Provisioning, missing (owned by REQ-572 / GH #3252, status pending).**
1. The narrow tenant-provisioner permission and credential; the six server-to-server routes (create,
   get, suspend, resume, expire, delete). I found no provisioner permission in `lib/`.
2. Expiry policy (demo cap, 14 days, 30 days retention) and purge job (deletion order per D-019).
3. A versioned tenant realm template in this repository for infra.
4. A design record for the above.
All of this is already queued under the "Identity and tenant provisioning" item of the team goal, so
no new task is proposed here beyond not duplicating it. For retirement, BilimBaga as a first tenant
needs only a manual `POST /onboarding` today, so provisioning automation is not a blocker for the
first cutover (judgement, not verified with the portfolio).

**Proposed tasks.** T9a change: extend the branding allowlist (secondary colour and logo upload).
T9b: no new work for provisioning beyond REQ-572's slices; track them as a dependency.

## Proposed task list (for the planner; nothing implemented here)

| Id | Criterion | Kind | Task | Size |
|---|---|---|---|---|
| T1a | 1 | requirement | Exam assignment model and enforcement (replace `check_assigned/3`) incl. departments | M |
| T1b | 1 | requirement | Examiner manual-grading queue for short text | M |
| T1c | 1 | change | `parent_id` on `category` and `question`, tree picker | S |
| T1d | 1 | study | Is adaptive selection used in BilimBaga production? | S |
| T2a | 2 | study | BilimBaga five roles mapped to Letflow roles (needs the BilimBaga repo) | S |
| T2b | 2 | change | Examiner, exam-builder and manager/department screens (after T1a/T1b) | L |
| T3a | 3 | study | Re-measure the 168-test corpus against main and classify the 134 | S |
| T3b | 3 | change | Port the PORTABLE-NOW batches | M per batch |
| T4a | 4 | change | Public certificate verify page in `web/` | S-M |
| T4b | 4 | change | Candidate "my certificates" list and download | S |
| T5a | 5 | requirement | Outbound notification delivery with delivery log | M |
| T5b | 5 | change | Exam reminder, assignment, welcome and result templates | S-M |
| T5c | 5 | study | Reset and welcome mail: Keycloak or Letflow | S |
| T6a | 6 | study | What BilimBaga's AI does and whether it is used | S |
| T6b | 6 | requirement | AI-assisted question authoring (after T6a) | L |
| T6c | 6 | requirement | Exam analytics reports (after T6d) | M |
| T6d | 6 | study | List BilimBaga's analytics reports | S |
| T9a | 9 | change | Wider branding allowlist and logo upload | S |

## Unverified points

- Did not read the BilimBaga repo (task rule); role, AI, analytics and certificate-revocation
  scope are therefore taken from this repo's docs only.
- Did not run any test or e2e spec; counts come from file listings and `grep -c "test("`.
- The PDF's use of the tenant logo was not opened.
