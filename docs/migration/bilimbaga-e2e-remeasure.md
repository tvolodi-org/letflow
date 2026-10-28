# BilimBaga e2e corpus: re-measurement against main (study T3a)

**Measured:** 2026-10-26, Letflow `main` at `7dd4dff60`.
**Source corpus:** `c:\Users\tvolo\dev\ai-dala\BilimBaga\frontend\e2e\`, local checkout on `main` at `445216d`
(commit date 2026-10-09). That checkout is 170 commits behind `origin/main` and was not fetched; the
counts below are for what is on disk.
**Scope:** read-only measurement. No spec was run (Playwright cannot run on this host), no code changed.
Classification is by reading spec titles and comparing them with what `web/src/` ships today
(`router.tsx`, `modules/exam/examRoutes.tsx`, `pages/admin/`). It is a planning input for T3b, not a pass/fail
result.

Prior figures: `docs/testing/REQ-344-bilimbaga-parity-triage.md` (168 tests in 19 files, 2026-09-14),
`docs/migration/stage-10-bilimbaga-vertical.md` "P5 close-out" (34 ported, 134 not),
`docs/migration/bilimbaga-retirement-status.md` section 3.

## 1. Counts and commands

```
$ cd BilimBaga/frontend/e2e
$ find . -name '*.spec.ts' | wc -l
30
$ grep -rE '^\s*test\(' . --include='*.spec.ts' | wc -l
216
$ grep -rE '^\s*(test|it)\.(only|skip|fixme)\(' . | wc -l
0
```

The corpus grew: 30 files / 216 `test(` blocks now, against 19 / 168 in REQ-344. Ten files were added since,
47 tests (`account-recovery` 3, `ai-assist` 4, `certificates` 7, `dept-admin-scoping` 5, `downloads-bearer` 3,
`employee-record` 6, `exam-start-failure` 4, `locale-switcher` 6, `password-reset` 4, `tab-switch` 5), and
`full-walkthrough.spec.ts` went from 22 to 23. The 19 original files hold 169 blocks today (168 + 1). The
ten new files are outside the 134 and are not classified here (see section 5).

Letflow side:

```
$ cd web/tests/e2e
$ for f in categories tags question-bank exam-lifecycle employee-portal exam-taking exam-result exam-result-by-id; do
    echo "$(grep -cE '^\s*test\(' $f.e2e.spec.ts) $f"; done
5 categories    5 tags    2 question-bank    6 exam-lifecycle
3 employee-portal    9 exam-taking    4 exam-result    3 exam-result-by-id
$ grep -cE '^\s*test\(' pipelines/bilimbaga-candidate-timed-exam.pipeline.e2e.spec.ts
1
```

The seven files that mirror the corpus hold 34 blocks, the same 34 as the P5 close-out. The figure of 37 in
`bilimbaga-retirement-status.md` is those 34 plus `exam-result-by-id` (3), which was added after the
close-out; the pipeline spec (1) is not a corpus port. So the ported count of 34 stands. Of the 134, one test
(`exam-result.spec.ts`, result by id) now has a counterpart (`exam-result-by-id.e2e.spec.ts`, route
`exam/sessions/:sessionId/result`), see section 3.

Reconciliation of the 134 (per-file counts from the `grep -cE` loop above, minus the ported counts):
90 whole-file + 22 within-file drops + 22 from `full-walkthrough` = 134. Today `full-walkthrough` has 23 blocks,
so the classification below covers 135 rows.

## 2. What has appeared in `web/` since 2026-09-14

- `/login` (`LoginPage`): email-first, no password field.
- `admin/users/:userId` (`UserDetailPage`): display-name edit, role assignment, `DeactivateUserDialog`. A page, not a drawer.
- `admin/appearance` (`AppearanceSettingsPage`): primary brand colour and a Save button. No app-name field.
- `exam/sessions/:sessionId/result` and `exam/:examId/session`; `admin/bilimbaga/:entityType`.
- `entities/:entityType` (`EntityListBrowserPage`, filter/sort/page size).

Still absent (no route, no page, grep over `web/src`): grading queue, exam-authoring wizard, dedicated
question editor, results list ("My Results"), employee record, departments, analytics, password reset or
import for users, skip-link / `#main-content` landmark (`AppShell` has `<main>` without an id).

## 3. Per-file classification of the 134

PORTABLE-NOW means the screen and the controls the test touches exist today, possibly after adapting the
selectors. BLOCKED-BY names the missing screen or control. DROP means the behaviour was removed or never
planned, or the same assertion is already covered by a dedicated Letflow spec.

| Source file | Rows | PORTABLE-NOW | BLOCKED-BY | DROP | Notes |
|---|---:|---:|---:|---:|---|
| `tags.spec.ts` | 1 | 0 | 1 | 0 | search filter: BLOCKED-BY search box on entity CRUD page |
| `question-bank.spec.ts` | 5 | 0 | 5 | 0 | PORTED (GH 3423 / REQ-612, `question-bank.e2e.spec.ts` tests 8 to 11): editor navigation, difficulty badges, search x2. Import/AI-Generate: split to REQ-600 (not built; counts above are the measurement before REQ-612) |
| `exam-lifecycle.spec.ts` | 2 | 0 | 0 | 2 | edit-wizard navigation; no wizard planned |
| `employee-portal.spec.ts` | 5 | 0 | 3 | 2 | Start modal open/cancel: DROP (Start navigates directly). Continue CTA, View Result CTA, My Results: BLOCKED-BY results list |
| `exam-taking.spec.ts` | 2 | 0 | 1 | 1 | flag/unflag: BLOCKED-BY flag control; submit-confirm modal: DROP |
| `exam-result.spec.ts` | 1 | 0 | 0 | 0 | result by id: ALREADY PORTED SINCE (`exam-result-by-id.e2e.spec.ts`), 1 row |
| `my-results.spec.ts` | 6 | 0 | 6 | 0 | BLOCKED-BY results list view |
| `auth.spec.ts` | 5 | 1 | 0 | 4 | "redirects to /login when unauthenticated" is portable; password form, invalid credentials and post-login redirect: DROP (email-first login, Keycloak hosted) |
| `exam-wizard.spec.ts` | 9 | 0 | 9 | 0 | BLOCKED-BY exam builder screen |
| `admin-grading.spec.ts` | 7 | 0 | 7 | 0 | BLOCKED-BY examiner grading screen |
| `grading/ai-grading.spec.ts` | 9 | 0 | 9 | 0 | BLOCKED-BY examiner grading screen |
| `accessibility.spec.ts` | 7 | 0 | 7 | 0 | BLOCKED-BY skip-link and `#main-content` landmark in `AppShell` |
| `branding.spec.ts` | 4 | 3 | 0 | 1 | form renders, primary colour field, Save: portable against `AppearanceSettingsPage`; "update app name": DROP (no such field) |
| `question-editor.spec.ts` | 7 | 0 | 7 | 0 | PORTED (GH 3423 / REQ-612, `question-editor.e2e.spec.ts` tests 1 to 7; test 4 follows assumption A1, no auto-grading section; counts above are the measurement before REQ-612) |
| `question-management.spec.ts` | 20 | 0 | 20 | 0 | BLOCKED-BY delete/archive/import/export/AI tooling |
| `user-management.spec.ts` | 18 | 6 | 10 | 2 | deactivate x4 and edit display name x2: portable against `UserDetailPage` (page, not drawer). Reset password x4, CSV import x6: BLOCKED-BY those controls. Drawer-required-fields and drawer-cancel: DROP |
| `loyalty-narrative.spec.ts` | 4 | 0 | 4 | 0 | BLOCKED-BY employee record page and AI narrative |
| `full-walkthrough.spec.ts` | 23 | 0 | 9 | 14 | DROP: tests 03, 04, 06, 07, 08, 10, 13, 14, 16, 21a (same assertions as dedicated specs) and 01, 02, 21b, 22 (password login, console-error sweep). BLOCKED: 05, 09, 11, 12, 15, 17, 18, 19, 20 (departments, editor, wizard, grading, AI card, create drawer, employee record, change password, analytics) |
| **Total** | **135** | **10** | **98** | **26** | plus 1 already ported; the 134 plus the one `full-walkthrough` test added since |

Check of the arithmetic: 10 + 98 + 26 + 1 = 135.

## 4. PORTABLE-NOW batches for T3b

One batch of 10 tests, sized as T3b proposes ("groups of about 10"):

| Batch | Tests | Target screen | Spec to create |
|---|---:|---|---|
| B1 users | 6: deactivate button visible, deactivate dialog opens, cancel keeps user, confirm deactivates; display name pre-populated, display name saved | `admin/users/:userId` | `admin-user-detail.e2e.spec.ts` (new) |
| B2 branding | 3: form renders, primary colour field, Save present | `admin/appearance` | `appearance-settings.e2e.spec.ts` (new) |
| B3 auth | 1: unauthenticated visitor lands on `/login` | `/login` | add to an existing OIDC spec |

The BilimBaga assertions on a row-level Deactivate button need adapting: in Letflow deactivation is on the
detail page. Existing `f5-admin-users.e2e.spec.ts` should be read first to avoid duplicating coverage. All 10
need a live instance with an admin session; they cannot be run on this host.

The remaining 98 BLOCKED rows are gated by screens tracked in `bilimbaga-retirement-status.md` criteria 1, 2
and 4 to 6 (examiner grading, exam builder and question editor, results list, employee record, user
reset-password and import). Port them per screen as each lands (T3c).

## 5. Limits and follow-ups

- Classification comes from titles and the current `web/src/` tree, no spec was executed. A T3b task confirms each
  row against the real DOM before porting.
- The 47 tests in the ten new corpus files are not classified. A follow-up study should do that
  (`password-reset`, `account-recovery`, `locale-switcher` and `tab-switch` look closest to existing screens).
- The BilimBaga checkout is behind `origin/main` by 170 commits. Re-run the section 1 commands after a fetch
  before T3b starts if the corpus count matters.
- `docs/migration/bilimbaga-retirement-status.md` section 3 still carries the 168 / 34 / 134 figures and the
  "should be re-measured" note; this file supersedes it for the measurement. Section 3 is left unedited.
