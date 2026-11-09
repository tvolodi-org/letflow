# UI text walk: empty lists, failed loads, refused saves (T-1553, BA batch 2 item B2#1)

What each main screen says when a list is empty, a load fails, or a save is refused, in English, Russian and
Kazakh, and whether it shows a technical code. **All Kazakh texts added here are machine drafts until the owner's
native check** (also listed in `docs/assets/i18n-gaps.md`).

The three core screens (Users, Instances, Definitions) are proven by `web/src/__tests__/uiTextWalk.test.tsx`: it reads the
text of the state element only (never the page), requires ru/kk to equal the catalogue value and to differ from
en, and requires that a server body such as `{message: "insufficient_stock 409"}` does not reach the element. The
other screens already had per-module catalogues and error tests; the walk read their catalogue keys and found no
gap there (table below). Texts come from the catalogue of each screen (`dashboardMessages`, `taskMessages`,
`assetsMessages`/`documentsMessages`, `stockMessages`/`countsMessages`, and the new `usersMessages`,
`instancesMessages`, `definitionsMessages`, `feedbackMessages`).

| Screen | Empty list (en / ru / kk) | Refused or failed save | Translated before | Fixed here | Test |
|---|---|---|---|---|---|
| Home | "No definitions yet." / "Определений пока нет." / "Анықтамалар әзірге жоқ." (`dashboardMessages.noDefinitions`) | n/a, no save on this screen | yes | no change | `catalog-completeness.test.ts` |
| My Tasks | "No pending tasks" / "Нет задач в ожидании" / "Күтіп тұрған тапсырма жоқ" (`taskMessages.emptyTitle`) | task actions through `taskErrorText` (server text never shown) | yes | no change | task error tests, `catalog-completeness.test.ts` |
| Asset registry and cards | "No balances yet" / "Остатков пока нет" / own kk key (`assets.balances.empty`) | `registerErrors` per reason | yes | no change | `modules/assets/__tests__/registerErrors.test.tsx` |
| Asset documents | "No asset documents yet" / "Документов по активам пока нет" / "Активтер құжаттары әлі жоқ", with a next step (`assets.doc.emptyFirst`) | per-reason text in `documentsMessages` | yes | no change | assets document tests, `catalog-completeness.test.ts` |
| Stock documents | "No stock documents found." / "Складских документов не найдено." / "Қойма құжаттары табылмады." | per-reason text, 404/403/503 busy | yes | no change | `modules/stock/__tests__/documentsErrors.test.tsx` |
| Counts | "No counts found." / "Инвентаризаций не найдено." / "Түгендеу табылмады." | `countsErrors` per reason | yes | no change | `modules/stock/__tests__/countsErrors.test.tsx` |
| Users | before: "No users found." in en only. Now "No users yet." + hint / "Пользователей пока нет." + hint / "Пайдаланушылар әзірге жоқ." + hint; with a search term: "No users match "{term}"." | create refused: before the raw server `message`; now `saveErrorText` by status class | no | yes | `uiTextWalk.test.tsx` (W1, W2, W3), `saveError.test.ts` |
| Instances | before: "No instances found." in en only. Now "No process instances yet." + "Start one from a process definition." (ru, kk as in `instancesMessages`) | start refused: before the raw server `message`; now `saveErrorText` | no | yes | `uiTextWalk.test.tsx` |
| Definitions | before: "No definitions found" / `No results found for "…"` in en only. Now ru/kk in `definitionsMessages`, with a next step for users who may create | create refused: before the raw server `message`; now `saveErrorText` | no | yes | `uiTextWalk.test.tsx` |
| Shared refusals (every screen using them) | 403: `PermissionDenied`; 409: `StaleVersionError`; 429: `RateLimitBackpressure` | n/a | no, en only | yes, `feedbackMessages` | `uiTextWalk.test.tsx` (P1), existing component tests |

Status classes of `saveErrorText` (`web/src/utils/saveError.ts`): 400 and 422 "check the fields", 401 and 403 "not
allowed", 404 "no longer exists", 409 "changed meanwhile, reload", 429 "wait N s" (or "try again in a minute" without
Retry-After), everything else and network errors "could not save, try again". The server's message, code and details
never reach the screen.

## Left open
- Users, Instances and Definitions stay English outside the state texts (headings, buttons, columns): whole-page
  translation of these three screens is a separate piece of work.
- At 390 px the Definitions header (title next to Import and New Definition) is cramped; not changed here.
- Users `UserDetailPage` save messages now use the same mapper; its "Saved" and "User deactivated" success texts are still English.
