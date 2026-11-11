# Core extraction inventory (CORE-1)

Written 2026-11-11, task T-1756, from `origin/main` at 25c74f925. Read-only: this file changes no code,
no schema and no tenant data. It lists logic that two or more modules (or the web and mobile tiers)
carry as copies, says how big and how risky each copy is, and names where a shared version could live
in the core. It is the input for later design tasks; it decides nothing.

Rules the proposals follow:

- Decision 0039 D3 (`docs/migration/decisions/0039-platform-module-solution-layering.md`): core code
  lives outside `lib/letflow/modules/<id>/`; a module may reference another module only if it is in its
  manifest `depends_on`; core may never reference a module file (except `lib/letflow/modules/catalog.ex`).
  On the web, `web/src/modules/<id>/` may not import another module, but may import core
  (`web/src/components`, `lib`, `hooks`, `utils`, `i18n`). So a shared helper must move DOWN into the
  core, never sideways into a sibling module.
- `mix letflow.check_boundaries` rule 7 (neutral vocabulary, no words such as stock, item, location,
  lot, inventory) applies to the ledger files. A shared posting or ledger-policy helper under
  `lib/letflow/ledger*` must use neutral names.
- The stream is behaviour-neutral: an extraction keeps every reason atom, status code and response
  shape. Where the copies differ (listed below), the shared version takes the difference as an argument.
- **HELD** = touches tenant data (reads or writes in a tenant schema) or a migration. Such a row is not
  extracted until a decision record (next free number on main: 0087; re-check at the time) settles it,
  as the task's limits require. Pure functions and request plumbing are not HELD.

## Facts used

Boundary check, run on this tree (`mix letflow.check_boundaries`, exit 0):

```
mix letflow.check_boundaries: OK -- 3061 edges checked, 0 violations
mix letflow.check_boundaries: ledger rules 7/7b OK -- 23 files; rule 8 -- 135 files; policy allowlist -- 2 files
```

Module dependencies (`depends_on:` in each `lib/letflow/modules/<id>/<id>.ex`):

| module | depends_on |
|---|---|
| assets | catalog_items, locations, org, stock |
| stock | catalog_items, codes, locations, org |
| procurement | org, catalog_items |
| locations | org |
| catalog_items, codes, exam, org | none |

Module size (backend, `find lib/letflow/modules/<id> -name '*.ex' | xargs cat | wc -l`): assets 6504
lines / 24 files, stock 12829 / 39, exam 8856 / 17, procurement 2918 / 12, org 1964 / 6, locations
1569 / 5, codes 1450 / 5, catalog_items 1133 / 5. Web (`web/src/modules/<id>`, non-test `.ts`/`.tsx`):
stock 8045 / 57, assets 5987 / 50, exam 5560 / 30, org 2951 / 17, catalog_items 1985 / 17, codes 1640 /
14, locations 1628 / 13. Mobile (`apps/mobile/lib/features`): stock 5355 / 44, codes 665 / 8. The PWA is
the web build of `apps/mobile/` (`apps/mobile/lib/auth/keep_signed_in.dart`, `device_unlock.dart`); it
has no separate source tree.

How "shared lines" is measured: both files with the module names replaced by one placeholder
(`sed -E 's/Assets|Stock/X/g;s/assets|stock/x/g'`), leading spaces removed, blank, comment and
bare `end`/`do`/`else`/`)` lines dropped, then `comm -12` of the sorted unique lines. It counts lines
that occur in both files; it is a lower bound of the copy, not a diff.

The source itself says several of these are copies: `lib/letflow/modules/assets/documents.ex`
moduledoc ("the glue is copied, not shared ... A shared extraction is a follow-up"),
`lib/letflow/modules/assets/access.ex` ("Same shape as `Letflow.Modules.Stock.Access`"),
the moduledocs of `locations/router.ex`, `catalog_items/router.ex` and `codes/router.ex` ("a copy of
`Letflow.Modules.Org.Router`"), `stock/router.ex` ("copied from `Letflow.Modules.Codes.Router`"),
`web/src/modules/*/…Messages.ts` ("Own copy of the locale resolver ... (0039 D3)"),
`web/src/modules/assets/documents/documentForm.ts` and `assetLinesCatalog.ts` ("a small copy of the
stock ... logic").

## The table

Risk: **low** = pure function or request plumbing, few call sites, no tenant data; **medium** = many
call sites or an authorization path (needs a security review); **HELD** = touches tenant data or a
migration.

| # | What | Where (copies) | Modules | Size (lines) | Risk | Proposed core home |
|---|---|---|---|---|---|---|
| 1 | Document number label (`PREFIX-[period-]000123`) | private `number_label/3` in `lib/letflow/documents.ex`; `label/3` in `modules/assets/documents.ex`; `label/2` in `modules/stock/document_numbers.ex`; two inline copies in `modules/stock/documents.ex` (`String.pad_leading(type.number_pad, "0")`) | core + assets + stock (5 copies) | 8 per copy, about 40 | low (pure) | make the core one public: `Letflow.Documents.number_label/3` |
| 2 | Write-route request plumbing of the master-data routers: `with_request/2`, `check_keys/2`, `pop_key/1`, `invalid_key/0`, `unprocessable/…`, `elem_tag/1` | `modules/{org,locations,catalog_items,codes}/router.ex` (byte-identical bodies, md5 checked per function); assets router "a copy of the Locations router's" | org, locations, catalog_items, codes, assets | about 50 per router (with_request 11, check_keys 12, unprocessable 8, elem_tag 2, pop_key clauses), about 250 total; router pairs share 57-80 lines | low (no tenant read; the prefix still comes from `conn.assigns.scoped_opts`) | `Letflow.Modules.RouterKit` (planned, not yet on main) at `lib/letflow/modules/router_kit.ex`, a core mechanism file per 0039 D3 |
| 3 | List paging and filter parsing: `limit/1` (regex), `cursor/2` (`:text` 1..4096 bytes, `:integer`), `uint/1` | `modules/assets/router.ex` and `modules/stock/router.ex` (same clauses; stock adds a statement-timeout option to `reconcile_opts`); exam has its own `encode_cursor`/`decode_cursor` in `modules/exam/grading.ex` | assets, stock (exam differs) | about 30 per copy; assets and stock routers share 232 lines in all | low | same core router helper as row 2 |
| 4 | Error rendering (`render/3`, `refuse/2`, problem mapping of reason atoms to 404/409/422) | each module router | 8 | `render` differs per module (4 distinct md5 in org, locations, catalog_items, codes) | low, but each reason table differs: share the skeleton, keep the per-module table | row 2 home, the table stays in the module |
| 5 | Permission guard: principal from conn, interactive user only, role allows the permission, tenant-wide scope `{:ok, :all}`, actor uuid; `permission/1` for `:read/:post/:reverse` | `modules/assets/access.ex` (55), `modules/stock/access.ex` (43) | assets, stock | about 30 each, 18 shared lines | medium: authorization path, security review. Difference: assets calls `Authorization.role_allows?/3` with `principal.role_overlay`, stock calls `role_allows?/2`. Equal today because `Authorization.grantable/0` only grants `AssetsRead`/`AssetsPost`; a shared guard must take the overlay | `Letflow.Api.ModuleGuard` (planned, not yet on main) beside `Letflow.Api.Scope` |
| 6 | Document context: save, replace, discard, issue, fetch, list of a versioned document over `Letflow.Documents` | `modules/assets/documents.ex` (954), `modules/stock/documents.ex` (937) | assets, stock | 369 shared lines | **HELD**: writes tenant records and the document tables | after a decision record: a document-kind behaviour in `lib/letflow/documents/` |
| 7 | Document kinds table (type keys, sides, header fields, view fields) | `modules/{assets,stock}/documents/kinds.ex` (303, 255); mobile copy of the stock key sets in `apps/mobile/lib/features/stock/documents/document_kinds.dart` (pinned by `document_model_test.dart`) | assets, stock, mobile | 60 shared lines | low for the lookup functions (pure data); the per-kind data stays in the module | behaviour callbacks in the row 6 home; the mobile copy stays (other tier, pinned) |
| 8 | Document shape parsing (header, lines, required, allowed, `max_lines`, `event_time`, uuid) | `modules/{assets,stock}/documents/shape.ex` (365, 375), `stock/documents/opening_shape.ex` (241) | assets, stock | 89 shared lines | low (pure validation) | `Letflow.Documents.Shape` (planned, not yet on main) |
| 9 | Document checks (masters, lateness, event time) and opening checks | `modules/{assets,stock}/documents/checks.ex` (358, 218), `opening_checks.ex` (134, 81) | assets, stock | 34 + 13 shared lines | **HELD**: reads tenant masters | after the decision record |
| 10 | Posting and reversal: build lines, legs, `post_command`, `start_post`, `start_reversal`, reversal consistency, state fields, about 45 functions of the same name | `modules/{assets,stock}/documents/posting.ex` (768, 892), `stock/documents/opening_posting.ex` (79) | assets, stock | 300 shared lines, the largest copy | **HELD**: writes ledger entries and process instances | after the decision record; a neutral-vocabulary helper under `lib/letflow/ledger/` (rule 7) |
| 11 | Ledger policy declaration (`declare`, legs, sides, quantity, reversal) | `modules/{assets,stock}/ledger_policy/declare.ex` (231, 236) | assets, stock | 71 shared lines | **HELD**: the ledger policy allowlist of `check_boundaries` counts these 2 files | after the decision record |
| 12 | Write handlers (`post_document`, `reverse_document`, `create_mark`, `valid_args?`) | `modules/{assets,stock}/handlers.ex` (311, 206) | assets, stock | 78 shared lines | **HELD** (tenant writes; handler files must stay pure, scan H4) | after the decision record |
| 13 | Opening-balance import (find header, resolve row, draft, same unit) | `modules/{assets,stock}/documents/opening_import.ex` (198, 168) | assets, stock | 75 shared lines | **HELD**: writes tenant drafts | after the decision record |
| 14 | Master-data xlsx import: `check_cells/1-2`, `check_required/1-2`, `text?/1`, `transact/1`, external-ref `find/3-4` (tenant id check + `Latest` join + live/deleted) | `modules/{assets,locations,org}/import.ex` (195, 193, 305), `catalog_items/import.ex` (207), `catalog_items/lot_import.ex` (153) | assets, locations, org, catalog_items | `check_cells` 14 and `check_required` 6 per copy (3 copies), `text?` 1 (4 copies), `transact` 8 (2 identical copies), `find` about 17 (2 copies) | `text?`, `transact`, `check_cells`: low. Reason atoms differ (assets `{:asset_field_required, h}`, locations and org `{:field_invalid, f}`), so the shared version takes the reason. `find`: **HELD** (reads a tenant schema) | `Letflow.Entities.ImportRow` (planned, not yet on main) next to `Letflow.Entities.XlsxImport`, which all of them already use for parsing |
| 15 | Reference resolving by external ref | `lookup_by_external_ref/4` in `catalog_items.ex`, `locations.ex`, `org.ex` delegate to core `Letflow.Modules.ReadApi.lookup_by_external_ref/5` | 3 | already core | none | already core; only row 14 `find` is a copy |
| 16 | Xlsx export cell helpers (`text`, `number_or_text`, `scalar`, `json`, `quantity`, `write`) | `modules/{assets,stock}/xlsx_export.ex` (125, 180); `stock/count_paperwork.ex` also styles sheets. All three already use core `Letflow.Documents.XlsxStyle` | assets, stock | 53 shared lines | low (pure; the sheet rows are passed in) | add the cell helpers to `Letflow.Documents.XlsxStyle` |
| 17 | Print / PDF | `Letflow.Documents.FormPrint` and `PrintLayout` are core (used by stock 6 and 4 times); `modules/codes/labels.ex` (175) has its own label PDF (Code128) | stock, codes | no copy found | none | already core |
| 18 | Views (`empty_to_nil`, `pad`, `slots`, `mismatch`) | `modules/{assets,stock}/views.ex` (79, 78) | assets, stock | 31 shared lines | low (pure) | a small core view helper, with row 2 |
| 19 | Audit events | 15 `Audit.insert_entry` calls in 15 module files (plus core `lib/letflow/modules/installs.ex`) (assets, catalog_items, codes, exam, locations, org, procurement, stock), all through core `Letflow.Audit` | 8 | already core | none | already core |
| 20 | Notifications / bell | assets `reminders.ex` and exam `notifications.ex` call core `Letflow.Notifications`; stock `counts.ex` calls `Letflow.UserNotifications.notify/6`; the web bell is one core hook `web/src/hooks/useNotifications.ts` | 3 | already core | none | already core |
| 21 | Web locale resolver `resolveUiLocale` | `web/src/modules/{assets,catalog_items,codes,locations,org}/…Messages.ts` (5 copies, 5 different bodies, up to 17 lines), exam a variant; core has `resolveUiLocale` in `web/src/i18n/entitiesMessages.ts` and `uiLocaleStore.ts` | 6 | about 15 per copy, about 90 | low | a generic `resolveUiLocale(candidates, supported)` in `web/src/i18n/` |
| 22 | Web per-module IntlProvider | `web/src/modules/*/…IntlProvider.tsx` | 7 | 14-22 each, about 120 | low | a generic provider factory in `web/src/i18n/`; message catalogs stay in the modules |
| 23 | Web `saveBlob` (download a fetched file) | `web/src/modules/codes/saveBlob.ts`, `web/src/modules/stock/register/saveBlob.ts` (identical except the comment) | 2 | 11 each | low | `web/src/lib/saveBlob.ts` |
| 24 | Web document state tone | `web/src/modules/{assets,stock}/documents/stateTone.ts` (identical after the name swap) | 2 | 13 each | low | `web/src/components/ui` or `web/src/lib` |
| 25 | Web document screens: list, form, actions, tabs, workspace, model, balances, movements | `web/src/modules/{assets,stock}/documents/*` and `register/*` | 2 | shared lines: DocumentList 111 of 164/160, DocumentForm 131 of 249/335, DocumentActions 88, MovementsPage 191 of 295/382, BalancesPage 123 of 218/303, DocumentTabs 16 of 18, three 11-line page shells; plus the time-zone and catalog copies in `assets/documents/documentForm.ts`, `assetLinesCatalog.ts` | medium: screen change, needs the full screenshot matrix per screen | a core document-workspace component set in `web/src/components/` (a later, per-screen task) |
| 26 | Web per-module permission and query-key files | `…Permissions.ts` (6, 2-9 lines), `…QueryKeys.ts` (6) | 6 | small, data only | none: data per module, not logic | stays in the modules |
| 27 | Backend test helpers | `test/letflow/modules/**`: `strip/1` (drop `trace_id`) 27 definitions (17 of one body, 9 of another), `json/1` 21 identical, `call/3-4` 17 in three shapes, `tenant/1` 14 | all modules | 1-10 lines each, about 150 | low (test only) | `test/support/module_conn_case.ex` (planned, not yet on main) |

Rows 15, 17, 19 and 20 were asked for and are already in the core; they are listed so the next task
does not look again.

## Suggested order (for the later design tasks, not decided here)

1. Pure, no tenant data, behaviour-neutral, one change each: row 1 (number label), row 23 and 24 (web
   helpers), row 21 and 22 (web i18n), row 16 (xlsx cells), row 27 (test helpers), row 14 without `find`.
2. Request plumbing: rows 2, 3, 4 and 18, one router at a time.
3. Security review: row 5 (keep the overlay argument).
4. HELD until a decision record: rows 6, 9, 10, 11, 12, 13 and `find` of row 14. Together they are the
   document/posting kernel of assets and stock (about 1000 shared lines); the record has to settle the
   behaviour API, the neutral names under `lib/letflow/ledger/`, and how the extraction is proven
   behaviour-neutral (posting and reversal on both modules give the same ledger rows before and after).
   No row here needs a schema change; if a design finds one, it waits for the upgrade chain U1-U4.
5. Row 25 last, per screen, after the backend kernel is settled.

## Observations found on the way (not fixed here)

- `lib/letflow/modules/assets/documents.ex` moduledoc says "module `assets` cannot call `stock`
  (boundary Rule 4, and a stock install must not become a precondition of the asset register)". The
  manifest in `lib/letflow/modules/assets/assets.ex` now lists `stock` in `depends_on` (added by
  6df6fc632, C15 part 2). The sentence is stale; the copies could now call stock directly, but row 6-13
  still propose the core, since a shared kernel inside a sibling module would make stock a dependency
  of every future document module.
- `Stock.Access` uses `role_allows?/2` while `Assets.Access` uses `role_allows?/3` with the tenant
  overlay (row 5). Same result today; it becomes a gap the day a Stock permission is added to
  `Authorization.grantable/0`.

## Commands behind the numbers

```
find lib/letflow/modules/<id> -name '*.ex' | xargs cat | wc -l
wc -l lib/letflow/modules/{assets,stock}/documents/*.ex
n(){ sed -E 's/Assets|Stock/X/g;s/assets|stock/x/g;s/^ *//' "$1" | grep -vE '^(#|$|end|\)|do|else|""")' | sort -u; }
comm -12 <(n lib/letflow/modules/assets/documents/posting.ex) <(n lib/letflow/modules/stock/documents/posting.ex) | wc -l
for m in catalog_items locations org codes; do awk '/defp with_request\(/,/^  end$/' lib/letflow/modules/$m/router.ex | md5sum; done
git grep -nE 'String.pad_leading\(type.number_pad' lib/
git grep -nE 'depends_on:' lib/letflow/modules/*/*.ex
git grep -nE 'Audit\.insert_entry\(' lib/letflow/modules
git grep -h -E '^\s*defp (strip|json|call|tenant)\(' -- 'test/letflow/modules/**/*.exs' | sort | uniq -c
mix letflow.check_boundaries
```
