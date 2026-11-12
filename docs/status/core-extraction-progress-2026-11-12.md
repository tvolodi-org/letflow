# Core extraction progress ledger (2026-11-12)

Docs only. Written for task T-1786 (batch 15 item 1) from `origin/main` at `94e956ca5`
(the S7f merge `7ceb16d9a` is on it). It changes no code. The plan is
`docs/design/core-extraction-design.md` (slices S1 to S9); the rows are those of
`docs/design/core-extraction-inventory.md` (rows 1 to 27). Both documents still read as plans;
this note is the state of the tree. Every "grep" below was run on this tree and the output is quoted
(trimmed to the file and line).

Merge commits of the slices (`git log origin/main --oneline --grep "CORE slice"`):

| slice | commit | PR |
|---|---|---|
| S1 document number label | `499bf704f` | #4288 |
| S2 xlsx cells | `138acdadf` | #4294 |
| S3 import row checks | `ec00b7867` | #4295 |
| S4 web helpers (saveBlob, documentStateTone) | `4e9581f31` | #4296 |
| S5 web locale resolver | `27985cb63` | #4297 |
| S6 web IntlProvider factory | `71fd4d6b6` | #4298 |
| S7a org router creates RouterKit | `3d4e45915` | #4299 |
| S7b locations router | `b2f4b4a4f` | #4300 |
| S7c catalog_items router | `25f825e1f` | #4301 |
| S7d codes router | `d28c82b58` | #4302 |
| S7e assets router (adds paging) | `a2cf56e90` | #4303 |
| S7f stock router (paging) | `7ceb16d9a` | #4304 |

S8 (module access guard) and S9 (backend test helpers) have no commit: see rows 5 and 27.

## The ledger

Status: **done** = the inventory's copy family is gone or reduced to a call of the core function;
**partial** = some copies remain, listed; **open** = no slice has touched it; **held** = needs the
decision record (inventory "HELD"); **n/a** = the inventory said already core or data only.

| # | What | Status | Slice / merge | Copies that remain (quoted grep) |
|---|---|---|---|---|
| 1 | Document number label | done | S1 `499bf704f` | None as a body. Core home `lib/letflow/documents.ex:839 def number_label(type, number, period)`. Three module wrappers remain and only fetch the type row, then call the core: `assets/documents.ex:731`, `stock/documents.ex:709`, `stock/document_numbers.ex:68` (all `Letflow.Documents.number_label(type, number, period)`). Grep `String.pad_leading(type.number_pad` in `lib/`: only `lib/letflow/documents.ex:840`. |
| 2 | Write-route plumbing (`with_request`, `check_keys`, `pop_key`, `invalid_key`, `elem_tag`) | partial | S7a `3d4e45915` to S7f `7ceb16d9a` | Core home `lib/letflow/modules/router_kit.ex:40 with_request/3`, `:54 check_keys`, `:69 pop_key`, `:87 elem_tag`. Org, locations, catalog_items, codes call `RouterKit.with_request` (grep `RouterKit.with_request`: 3 sites in catalog_items, 1 codes, 3 locations, 3 org). Remainder: `assets/router.ex:610 defp with_request(conn, fun)` (private, wraps `RouterKit.pop_key` at line 612, see "Classification" below). The stock router has no `with_request` and no `pop_key` caller (grep `RouterKit.` in `stock/router.ex`: only `page`, `optional_uint`, `elem_tag`). Each router still has its own `defp unprocessable/2-3` (`org/router.ex:195`, `locations/router.ex:173`, `catalog_items/router.ex:122`, `codes/router.ex:295`, `assets/router.ex:602,669`, `stock/router.ex:1326`). Domain-file `check_keys` copies are NOT in the inventory, see "Not in the inventory". |
| 3 | List paging and filter parsing (`limit`, `cursor`, `uint`) | done | S7e `a2cf56e90`, S7f `7ceb16d9a` | Core `router_kit.ex:101 limit`, `:115,:123 cursor`, `:132 uint`. Grep `defp? (limit\|cursor\|uint)\(` in `lib/letflow/modules/*/router.ex`: no router match; only `router_kit.ex`. Callers: `RouterKit.page` at `assets/router.ex:165,189` and `stock/router.ex:203,229`; `RouterKit.optional_uint` at `assets/router.ex:495,505,537,538` and `stock/router.ex:1199,1209,1241,1242`. Exam keeps its own cursor in `exam/grading.ex` on purpose (inventory: "exam differs"). |
| 4 | Error rendering (`render`, `refuse`) | open, by design | none | Inventory said: share the skeleton, keep the per-module reason table. Each router still defines `defp render/3` (org 151, locations 129, catalog_items 78, codes 243, assets 625, stock 1038; procurement `render/4` at 205) and `refuse/2` (assets 590 to 600, stock 1314 to 1324, the same seven clauses). No slice was planned for it; S7 moved only the plumbing. |
| 5 | Permission guard | open | S8 not built | `lib/letflow/api/module_guard.ex` does not exist (`ls lib/letflow/api \| grep -i guard` prints nothing). Two copies: `assets/access.ex:44 Authorization.role_allows?(&1, permission, principal.role_overlay)` and `stock/access.ex:33 Authorization.role_allows?(&1, permission)` (the arity-2 versus arity-3 gap the inventory noted). |
| 6 | Document context (save, issue, fetch, list) | held | none | `assets/documents.ex` 948 lines, `stock/documents.ex` 925 lines (`wc -l`). |
| 7 | Document kinds table | open | none | `assets/documents/kinds.ex` 303, `stock/documents/kinds.ex` 255 lines. |
| 8 | Document shape parsing | open | none | `lib/letflow/documents/shape.ex` does not exist (`ls`: "No such file"). `assets/documents/shape.ex` 365, `stock/documents/shape.ex` 375 lines. |
| 9 | Document and opening checks | held | none | `assets/documents/checks.ex` 358, `opening_checks.ex` 134; `stock/documents/checks.ex` 218, `opening_checks.ex` 81. |
| 10 | Posting and reversal | held | none | `assets/documents/posting.ex` 768, `stock/documents/posting.ex` 892. |
| 11 | Ledger policy declaration | held | none | `assets/ledger_policy/declare.ex` 231, `stock/ledger_policy/declare.ex` 236. |
| 12 | Write handlers | held | none | `assets/handlers.ex` 311, `stock/handlers.ex` 206. |
| 13 | Opening-balance import | held | none | `assets/documents/opening_import.ex` 198, `stock/documents/opening_import.ex` 168. |
| 14 | Master-data xlsx import checks | done except `find` | S3 `ec00b7867` | Core `lib/letflow/entities/import_row.ex:19 text?`, `:27 check_cells`, `:47 check_required`, `:59 transact`. Callers (grep `ImportRow\.`): assets/import.ex 2, catalog_items/lot_import.ex 3, locations/import.ex 3, org/import.ex 3. Remainder, held by the inventory: `defp find` in `catalog_items/lot_import.ex:72`, `locations/import.ex:92`, `org/import.ex:142` (reads a tenant schema). Thin local `defp check_cells/transact` wrappers that call `ImportRow` remain (for example `locations/import.ex:167`); they are delegations, not copies. Not part of this row: `codes/writes.ex:404` and `procurement/*:transact` are other functions of the same name. |
| 15 | Reference resolving by external ref | n/a | already core | `Letflow.Modules.ReadApi.lookup_by_external_ref/5`, unchanged. |
| 16 | Xlsx export cell helpers | partial | S2 `138acdadf` | Core `lib/letflow/documents/xlsx_style.ex:29 cell_text`, `:37 cell_scalar`, `:43 cell_json`. Both exports call them (`assets/xlsx_export.ex:91-93`, `stock/xlsx_export.ex:145-147`). Remainder: `quantity/1` and `number_or_text/2` are still defined twice with the same body (`assets/xlsx_export.ex:95,108`, `stock/xlsx_export.ex:149,162`); the S2 slice moved the three `cell_*` helpers only. `write/2` differs (assets 73, stock 126 with a sheet name). |
| 17 | Print / PDF | n/a | already core | no copy. |
| 18 | Views (`empty_to_nil`, `pad`, `slots`, `mismatch`) | open | none | `assets/views.ex:59,63,75,77` and `stock/views.ex:58,62,74,76` (identical bodies for `pad` and `empty_to_nil`). The inventory said "with row 2" but S7 did not take it. |
| 19 | Audit events | n/a | already core | `Audit.insert_entry(` appears once in each of 16 files under `lib/letflow/modules` (`git grep -c`), all through `Letflow.Audit`. |
| 20 | Notifications | n/a | already core | unchanged. |
| 21 | Web locale resolver | done for 5 of 6 | S5 `27985cb63` | Core `web/src/i18n/resolveLocale.ts:8 resolveLocale`. Module files keep a one-line `export function resolveUiLocale` that returns `resolveLocale(...)` (assets, catalog_items, codes, locations, org; checked on `orgMessages.ts:9`). Remainder, left on purpose: `web/src/modules/exam/examMessages.ts:36 resolveUiLocale` (own body; the exam module is closed and the file's header says it does not import the core). |
| 22 | Web per-module IntlProvider | done for 6 of 7 | S6 `71fd4d6b6` | Core `web/src/i18n/createModuleIntlProvider.tsx`. Used by assets, catalog_items, codes, locations, org, stock (grep `createModuleIntlProvider` finds one line in each of the six `*IntlProvider.tsx`). Remainder: `web/src/modules/exam/ExamIntlProvider.tsx` (not converted; exam is outside S6). |
| 23 | Web `saveBlob` | done | S4 `4e9581f31` | `git grep -nE 'function saveBlob' web/src` prints `web/src/lib/saveBlob.ts:2` and `web/src/modules/exam/ExamMyResultsPage.tsx:26` (left on purpose, closed module). The codes and stock copies are gone. |
| 24 | Web document state tone | done | S4 `4e9581f31` | `web/src/lib/documentStateTone.ts:4`; the four screens import it (`assets/documents/DocumentList.tsx:23`, `DocumentView.tsx:35`, `stock/documents/DocumentList.tsx:23`, `DocumentsWorkspace.tsx:55`). `ls web/src/modules/*/documents/stateTone.ts`: no such file. |
| 25 | Web document screens | open | none | Both families still exist side by side: `web/src/modules/assets/documents/` (19 files) and `web/src/modules/stock/documents/` (16 files; `ls`). Last in the order; needs the screenshot matrix per screen. |
| 26 | Web permission and query-key files | n/a | stays in the modules | data only. |
| 27 | Backend test helpers | open | S9 not built | `ls test/support/module_conn_case.ex`: no such file. `git grep -h -E '^\s*defp (strip\|json\|call\|tenant)\(' -- 'test/letflow/modules/**/*.exs' \| sort \| uniq -c`: `json` 21 identical; `strip` 17 + 9 + 1; `call` 21 in several shapes; `tenant` 14. |

Count: done 1, 3, 14 (but `find`), 23, 24; partial 2, 16, 21, 22; open 4, 5, 7, 8, 18, 25, 27; held 6, 9 to 13;
n/a 15, 17, 19, 20, 26.

## Classification of the assets `with_request/2` (asked by the batch 15 note)

`assets/router.ex:610` is `defp with_request(conn, fun)`. It does `Access.check(conn) |> access()`, then
`RouterKit.pop_key(conn.body_params)`, then `fun.(prefix, attrs, %{actor_id: actor, idempotency_key: key}, conn)`;
`render(conn, error, 200)` handles errors. The kit's `RouterKit.with_request(conn, render, fun)`
(`router_kit.ex:40`) takes the render function and calls a four-argument `fun`. The only visible difference
is the access step: the assets router authorizes through `Letflow.Modules.Assets.Access.check/1`
(permission by route), while the four master-data routers authorize through their own prelude. This is a
**remainder, not an intended design**: the assets moduledoc does not say it is kept on purpose (I did not find
such a sentence; `git grep -n "with_request" lib/letflow/modules/assets/router.ex` shows only the definition
and its callers), and the S7e commit is described as "adds paging". Whoever builds the pin of batch 15
candidate 3 should either let `with_request/3` accept an access step, or list assets `with_request` as an
explicit exception in `test/letflow/modules/router_kit_test.exs`. I did not decide which; this is a
recommendation, not a fact established from a decision record.

## Not in the inventory (found on the way)

* `check_keys` unknown-key bodies: `catalog_items/lots.ex:235`, `locations/tree.ex:150`,
  `org/masters.ex:472` (public), `assets/cards.ex:244`; different checks with the same name:
  `write_handler_spec.ex:67`, `stock/counts.ex:601`. Batch 15 candidate 2.
* `assets/views.ex` and `stock/views.ex`: see row 18.

## What S7f changed against the batch 15 note

The batch 15 note (`docs/uat/ba-decisions/T-1785.md`) was written at `a2cf56e90` and said S7f was not
done (`elem_tag/1`, `uint/1`, `cursor/2` at stock router lines 1075, 1237, 1332). On `94e956ca5` those
definitions are gone from the stock router (row 3 grep: no router defines `limit`, `cursor`, `uint`);
S7f is merged. So the next planned slices are S8 and S9 only; rows 4, 16 (`quantity`,
`number_or_text`) and 18 have no planned slice.

## Commands

```
git log origin/main --oneline --grep "CORE slice"
git grep -nE 'String.pad_leading\(' lib/ | grep -i "number_pad\|label"
git grep -nE 'defp? (with_request|check_keys|pop_key|invalid_key|unprocessable|elem_tag)\b' lib/letflow/modules
git grep -nE 'RouterKit\.' lib/letflow/modules/stock/router.ex lib/letflow/modules/assets/router.ex
git grep -nE 'defp? (limit|cursor|uint)\(' lib/letflow/modules/*/router.ex lib/letflow/modules/router_kit.ex
git grep -nE 'defp? (render|refuse)\(' lib/letflow/modules/*/router.ex
git grep -nE 'defp? (check_cells|check_required|text\?|transact|find)\(' lib/letflow/modules lib/letflow/entities/import_row.ex
git grep -nE 'defp? (text|number_or_text|scalar|json|quantity|write)\(' lib/letflow/modules/*/xlsx_export.ex lib/letflow/documents/xlsx_style.ex
git grep -nE 'defp? (empty_to_nil|pad|slots|mismatch)\(' lib/letflow/modules/*/views.ex
git grep -nE 'function saveBlob' web/src
git grep -n createModuleIntlProvider web/src
wc -l lib/letflow/modules/{assets,stock}/{documents,handlers}.ex lib/letflow/modules/{assets,stock}/documents/*.ex
```
