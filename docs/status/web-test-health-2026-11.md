# Web test health pass, 2026-11 (B10#6, T-1720)

Source: `docs/uat/ba-decisions/T-1706.md` item 6. Scope: the web test files that exercise the
screens changed by B10#1 (Users, Users detail, Definitions list, Instances board). Item text:
grep for English literals in `getByText(` / `getByRole(..., {name:`, run the files three times
under `CI=true`, record flaky ones, fix only a proven race.

## Files covered (12)

The 9 files changed or reached by the B10#1 pages, plus three that import the new catalogues:

- `src/pages/admin/__tests__/UserDetailPage.locale.test.tsx`, `UserDetailPage.passwordReset.test.tsx`, `UsersPage.roles.test.tsx`
- `src/pages/admin/usersImport/__tests__/usersImportA11y.test.tsx`, `usersImportRoute.test.tsx`
- `src/pages/definitions/__tests__/DefinitionListPage.test.tsx`
- `src/pages/instances/__tests__/InstanceBoardPage.definitionColumn.test.tsx`, `...start-dialog-version-race.test.tsx`, `...tenant-isolation.test.tsx`
- `src/__tests__/uiTextWalk.test.tsx`, `src/__tests__/router.iss-0289.test.tsx`, `src/pages/help/__tests__/coreHelp.test.tsx`

## Run result

Command (three times, one after another): `CI=true bash scripts/weblock.sh npx vitest run <12 files>`.

| Run | Test files | Tests | Result |
|---|---|---|---|
| 1 | 12 passed | 119 passed | exit 0 |
| 2 | 12 passed | 119 passed | exit 0 |
| 3 | 12 passed | 119 passed | exit 0 |

No ICU `FORMAT_ERROR` or stderr flood in any run (`grep -c "ICU\|FORMAT_ERROR"` = 0 on all three logs).

**Flaky tests found: none.** No test was changed.

## English-label queries (grep result)

Pattern: `(getBy|findBy|queryBy|getAllBy)(Text|Role|LabelText|PlaceholderText)(` followed by a
capitalised English literal. 16 hits in 7 files. Classification:

| Where | Literal | Risk |
|---|---|---|
| `DefinitionListPage.test.tsx:168-182` | button names `Activate`, `Archive` | Tests run in the default `en` locale, so they pass. They would go blind (the negative `queryByRole` at 168-169 would pass for the wrong reason) if the locale default or the catalogue key changed. Not a race. |
| `usersImportRoute.test.tsx:55,60` | `Import from Excel` | Same: depends on `en`. |
| `UserDetailPage.locale.test.tsx:46-47` | `Role assignments`, `Save changes` | Intended: negative checks that English text is absent in ru/kk. Good pattern. |
| `InstanceBoardPage.definitionColumn.test.tsx:88-110` | `Order v3`, `Asset write-off` (fixture data), `Not yet refreshed` (UI text) | Fixture data is language-independent; `Not yet refreshed` is en-only text. Awaits go through `waitFor`, no race seen. |
| `InstanceBoardPage.start-dialog-version-race.test.tsx:175,226` | `Select a valid active definition name.` | en text, synchronous after the click. Stable in 3 runs. |
| `InstanceBoardPage.tenant-isolation.test.tsx:124` | `My Flow v1.0.0` | Fixture data. |
| `UsersPage.roles.test.tsx:46` | `Nov 6, 2026` | A formatted date; en locale format. Depends on locale and time zone, not on the clock. |
| `usersImportA11y.test.tsx:36` | `Go` | Test-local button, not a catalogue label. |

Conclusion: the English-literal queries are stable today because every file renders under `en`.
The DocumentForm race of #4205 (a helper that finds a button by its English label and
silently matches nothing in ru/kk) does not occur here: none of these files switches locale and
then looks up an English label, except the intended negative checks in `UserDetailPage.locale.test.tsx`.

## Follow-up (not done, no proven race)

- If a future task makes these files run under ru/kk, move the labels in the table's first two
  rows to the catalogue (`definitionsMessages.en`, `usersMessages.en`) so a key rename or a
  locale change fails loudly instead of passing a negative assertion.
