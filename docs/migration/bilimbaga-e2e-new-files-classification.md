# BilimBaga e2e corpus: classification of the ten new files (study T3d)

**Measured:** 2026-10-26, Letflow `main` (worktree of T-0679).
**Source:** `c:\Users\tvolo\dev\ai-dala\BilimBaga\frontend\e2e\`. Continues
`docs/migration/bilimbaga-e2e-remeasure.md` (T3a), whose section 5 left these 47 tests unclassified.
**Scope:** read-only. No spec was run (Playwright cannot run on this host), no code changed. Classification is by
reading spec titles and comparing them with `web/src/` (`router.tsx`, `modules/exam/`, `pages/`), as in T3a. It is
a planning input for T3b/T3c, not a pass/fail result.

Criteria numbers refer to `docs/migration/bilimbaga-retirement-status.md`: 1 exam core (assignments, departments),
2 screens per role, 3 e2e parity, 4 certificates, 5 e-mail, 6 AI authoring and analytics.

## 1. Corpus count after fetch

```
$ cd BilimBaga && git fetch
$ git status -sb | head -1
## main...origin/main [behind 170]
$ cd frontend/e2e
$ find . -name '*.spec.ts' | wc -l
29
$ grep -rE '^\s*test\(' . --include='*.spec.ts' | wc -l
216
$ git ls-tree -r --name-only origin/main frontend/e2e | grep -c 'spec.ts$'
35
$ # sum of grep -cE '^\s*test\(' over `git show origin/main:<file>` for those files
246
```

The fetch ran; the checkout is still on `main` at `445216d` (2026-10-09) and 170 commits behind `origin/main`
(`2dd4254`, 2026-10-13). It was not pulled (read-only). On disk: 216 `test(` blocks, as in T3a. (T3a counted 30 spec
files with `find`; today `find` prints 29 here. The block count is unchanged, so the difference is in the file
listing, not in tests, and was not chased.) On `origin/main` the corpus is 35 files and 246 blocks.

The ten new files, 47 tests on disk, 51 on `origin/main`: `employee-record` is 7 there (6 on disk: one more
certificate-download failure case split in two) and `tab-switch` is 7 there (5 on disk, two new cases (a) and (b)
under the submit policy). The other eight files have the same count in both. Four of `dept-admin-scoping`,
`employee-record`, `locale-switcher` and `tab-switch` also differ in content. The 47 on-disk tests are classified
below; section 3 lists the 4 extra `origin/main` tests so T3b has them.

## 2. Classification of the 47

| File | Test (title) | Class | Reason |
|---|---|---|---|
| `account-recovery` | lock -> admin unlock -> login succeeds without waiting for expiry | DROP | password login and lockout are Keycloak's; `/login` is email-first, no password |
| `account-recovery` | forgot password -> email link -> reset -> login with the new password | DROP | no `/forgot-password` or `/reset-password` route; Keycloak hosted (criterion 5 open item 4) |
| `account-recovery` | forgot-password answers identically for an unknown email | DROP | same: no route, the IdP owns it |
| `ai-assist` | requires a category before generating (no API call) | BLOCKED-BY-6 | no AI generation control; no question editor (`/admin/questions` absent) |
| `ai-assist` | generates drafts, lets the user pick some, and confirms | BLOCKED-BY-6 | same |
| `ai-assist` | shows the rate-limit message on AI_RATE_LIMITED | BLOCKED-BY-6 | same |
| `ai-assist` | shows the unavailable message when the AI service fails | BLOCKED-BY-6 | same |
| `certificates` | unknown / malformed code renders "not found or invalid" | PORTABLE-NOW | `/verify/:handle` is `VerifyCertificatePage`; adapt route param and API mock |
| `certificates` | is public: sends no Authorization header and no token refresh | PORTABLE-NOW | route is outside `ProtectedRoute` |
| `certificates` | valid certificate shows holder, exam, score and issue date | PORTABLE-NOW | page exists; confirm field set against the DOM |
| `certificates` | adds a robots noindex meta tag while mounted | BLOCKED-BY-4 | grep for `noindex` over `web/src` finds nothing |
| `certificates` | transient failure shows "unavailable" and Retry recovers | BLOCKED-BY-4 | no Retry control found in `VerifyCertificatePage.tsx` |
| `certificates` | locale switcher on the verification page translates the result | BLOCKED-BY-4 | no locale switcher anywhere in `web/src` (see `locale-switcher`) |
| `certificates` | passed certifiable exam: result page offers a PDF whose code verifies | BLOCKED-BY-4 | no candidate-side certificate download (status doc, criterion 4 gap 2) |
| `dept-admin-scoping` | employee record, progress and CSV: own/descendant department OK, other 404 | BLOCKED-BY-1 | no department entity, no `department_admin` role in `web/src` |
| `dept-admin-scoping` | exam analytics aggregate only the department subtree | BLOCKED-BY-1 | departments, and analytics (6) |
| `dept-admin-scoping` | exam results CSV lists only the department subtree | BLOCKED-BY-1 | departments |
| `dept-admin-scoping` | dashboard lists and aggregates only the department subtree | BLOCKED-BY-1 | departments |
| `dept-admin-scoping` | dashboard PDF export still succeeds for a department_admin | BLOCKED-BY-1 | departments |
| `downloads-bearer` | dashboard PDF export carries a Bearer token | BLOCKED-BY-6 | no `/admin/reports` page, no analytics export |
| `downloads-bearer` | exam results CSV export carries a Bearer token | BLOCKED-BY-6 | same |
| `downloads-bearer` | API rejects the export endpoint without a token (sanity check) | DROP | API-level check, no UI; belongs in the backend suite, not the SPA corpus |
| `employee-record` | renders info header, session history and track progress sections | BLOCKED-BY-2 | no employee record page (`admin/users/:id/record` absent) |
| `employee-record` | "View Record" link in the users list opens the record page | BLOCKED-BY-2 | same |
| `employee-record` | Export CSV request carries a Bearer token | BLOCKED-BY-2 | same |
| `employee-record` | shows an error with a working Retry when progress fails to load | BLOCKED-BY-2 | same |
| `employee-record` | certificate download appears only for rows with a certificate, sends Bearer | BLOCKED-BY-2 | record page, and certificate download (4) |
| `employee-record` | certificate download failure shows an error alert | BLOCKED-BY-2 | same |
| `exam-start-failure` | refused start (422 EXAM_OUTSIDE_WINDOW) shows an alert, keeps the modal open | DROP | no Start modal: Start navigates directly (T3a, `employee-portal` rows) |
| `exam-start-failure` | gateway failure (502, non-JSON) shows the generic alert | BLOCKED-BY-1 | no start-error alert found in `ExamListPage.tsx`; confirm in T3b before porting |
| `exam-start-failure` | successful start navigates to the session page | PORTABLE-NOW | `exam-list-start-*` button navigates to `exam/:examId/session`; may duplicate `exam-taking.e2e.spec.ts`, read it first |
| `exam-start-failure` | Start is disabled with a reason when the availability window is closed | BLOCKED-BY-1 | availability window (assignments are enforced since REQ-582) |
| `locale-switcher` | AC1: switcher is visible in the portal header and offers kk/ru/en | BLOCKED-BY-2 | no locale switcher component; locale comes from `resolveUiLocale()` only |
| `locale-switcher` | AC2: selecting a locale changes visible strings without a reload | BLOCKED-BY-2 | same |
| `locale-switcher` | AC3: locale is retained when navigating between portal tabs | BLOCKED-BY-2 | same, and there are no portal tabs |
| `locale-switcher` | AC4: selection is stored in localStorage and survives a reload | BLOCKED-BY-2 | same |
| `locale-switcher` | AC6: switcher does not cause horizontal overflow at 375px | BLOCKED-BY-2 | same |
| `locale-switcher` | login screen has its own language selector and no portal switcher | DROP | `LoginIntlProvider` takes the resolved locale, no selector; login is email-first |
| `password-reset` | login page links to /forgot-password | DROP | no such link or route; Keycloak hosted |
| `password-reset` | forgot-password sends only the email, unauthenticated, neutral confirmation | DROP | no route |
| `password-reset` | reset-password with an invalid token shows an error and a link | DROP | no route |
| `password-reset` | reset-password without a token shows the invalid-link state | DROP | no route |
| `tab-switch` | tab hidden reports a tab_switch event and the endpoint contract holds | PORTABLE-NOW | `useAntiCheatSignals.ts` and `ExamSessionPage.tsx`; route is `exam/:examId/session` |
| `tab-switch` | window blur reports a blur event | PORTABLE-NOW | same |
| `tab-switch` | warn policy shows the warning modal, which can be dismissed | PORTABLE-NOW | `data-testid="exam-anticheat-warning"` exists; dismissal control to confirm |
| `tab-switch` | log policy (warn:false) does not interrupt the exam | PORTABLE-NOW | `action_taken` handling in `ExamSessionPage.tsx` |
| `tab-switch` | auto-submit policy navigates to the session result page | PORTABLE-NOW | `submit` branch navigates; result route `exam/sessions/:sessionId/result` exists |

Totals:

| Class | Tests |
|---|---:|
| PORTABLE-NOW | 9 |
| BLOCKED-BY-1 | 7 |
| BLOCKED-BY-2 | 11 |
| BLOCKED-BY-4 | 4 |
| BLOCKED-BY-6 | 6 |
| DROP | 10 |
| **Total** | **47** |

Check: 9 + 7 + 11 + 4 + 6 + 10 = 47. Per file: account-recovery 3 (3 DROP), ai-assist 4 (4 B6), certificates 7
(3 PN, 4 B4), dept-admin-scoping 5 (5 B1), downloads-bearer 3 (2 B6, 1 DROP), employee-record 6 (6 B2),
exam-start-failure 4 (1 PN, 2 B1, 1 DROP), locale-switcher 6 (5 B2, 1 DROP), password-reset 4 (4 DROP),
tab-switch 5 (5 PN).

## 3. Follow-ups

- **T3b batch:** the 9 PORTABLE-NOW tests (tab-switch 5, certificates 3, exam-start success 1) form one batch of the
  size T3b proposes. They need a live instance and cannot run on this host. Two overlap risks: read
  `exam-taking.e2e.spec.ts` before porting the start test, and `web/src/pages/__tests__/VerifyCertificatePage.test.tsx`
  (unit coverage) before the certificate ones.
- **Not seen in the 47 on disk, present on `origin/main`:** `tab-switch` (a) "a simulated tab switch under submit sends
  exactly one tab_switch and auto-submits" and (b) "a bare blur under submit sends one blur, warns with event_count 1
  and does not submit" (both look PORTABLE-NOW, same screen as the other five); `employee-record` "certificate
  download failure shows the exam-not-certifiable message" and "... unmapped error shows the generic message" (BLOCKED-BY-2,
  replacing the one failure case on disk). Pull the checkout and re-run the section 1 commands before T3b.
- **Decision for the owner:** account recovery, password reset and the lockout test are marked DROP because Keycloak
  hosts them. Criterion 5 item 4 (who sends reset and welcome mail) is still open; if the answer is "Letflow serves
  `/forgot-password`", these 7 tests become BLOCKED-BY-5.
- Rows are from titles and the `web/src` tree, no spec was executed. A T3b task confirms each row against the real DOM.
- Effect on T3a totals: the corpus is 30 files and 216 tests (on disk); T3a's 135 classified rows plus these 47 give 182
  classified. The remaining 34 are the ported ones (T3a section 1).

## 4. T3b batch 2: ported (T-0712)

Specs: `web/tests/e2e/tab-switch.e2e.spec.ts` (7 tests) and `web/tests/e2e/verify-certificate.e2e.spec.ts` (3).
Neither could be run on this host; the check is `cd web && npm run check`.

| Source test | Result |
|---|---|
| `tab-switch`: tab hidden, blur, log policy, auto-submit | ported (session start and events stubbed; auto-submit renders `exam-result-page` in place, no result URL) |
| `tab-switch`: warn policy modal | ported as the `exam-anticheat-warning` banner; it has no dismiss control, so "can be dismissed" is dropped |
| `tab-switch` (b) bare blur under submit | ported |
| `tab-switch` (a) tab switch under submit sends exactly one event | ported as `test.fixme`: `useAntiCheatSignals` has no blur window, a tab switch with a blur sends two events (gap, not a pass) |
| `certificates`: not-valid, public/no Authorization, valid fields | ported (overlap with `VerifyCertificatePage.test.tsx` noted in the spec header: real router and browser level) |
| `exam-start-failure`: successful start navigates | skipped, duplicate of `employee-portal.e2e.spec.ts` test 05 and `exam-taking.e2e.spec.ts` |

Ported 10 of the 11 (9 PORTABLE-NOW plus the 2 `origin/main` tab-switch tests); 1 skipped as a duplicate, 1 of the
10 is `fixme`. Remaining in the 47 + 4 set: 41 not portable now (BLOCKED or DROP, section 2 totals), unchanged.
