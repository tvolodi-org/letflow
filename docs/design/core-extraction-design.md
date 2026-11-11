# Core extraction design (CORE-2)

Written 2026-11-11, task T-1757, from `origin/main` at 6f08538c2 (the CORE-1 inventory merge). It is a
design note. It changes no code, no schema and no tenant data. It takes the inventory
`docs/design/core-extraction-inventory.md` (CORE-1, T-1756) as input and settles four things:

1. the rules every extraction slice keeps (section 1);
2. the boundaries: what may be in the core, and in which direction calls go (section 2);
3. how a slice fits the module manifest and the module upgrade chain U1-U4 (section 3);
4. how the stream fits the open/closed split of T-1521 (section 4);

then names the planned core API (section 5) and orders the slices (section 6). Row numbers ("row 5")
are the rows of the inventory table.

Authority for the stream: the owner allows the team to move functions that several applications use
into the core (portfolio manager order of 2026-11-11, under D-086, D-117, D-118 and D-119 in
`ai-dala-portfolio/DECISIONS.md`). The task's own limits apply to every slice: nothing on production,
money, DNS, secrets, demo promotion, public repo creation, deletions from the old tree, force-push or
`LICENSE`; no schema change outside the upgrade chain; anything that changes tenant data or migrations
is held for a decision record.

Sources I opened for this note: the inventory above; `docs/migration/decisions/0039-platform-module-solution-layering.md`
(D3); `lib/mix/tasks/letflow.check_boundaries.ex` (rules 0 to 9, ledger rules, policy allowlist);
`web/.eslintrc.json` (`no-restricted-imports`, top level and per module); `lib/letflow/modules/module.ex`,
`lib/letflow/modules/catalog.ex` (`entry_modules/0`, `all_manifests/0`), `lib/letflow/modules/manifest_hash.ex`;
`docs/migration/decisions/0055-module-upgrade-migration-uninstall.md` and `0080-module-upgrade-working-path.md`;
`docs/uat/ba-decisions/T-1521.md`; `ai-dala-portfolio/DECISIONS.md` D-116 to D-119; the copies themselves
(cited by file in sections 5 and 6); the tests named in section 1.

## 0. Short answer

- The stream moves copies **down** into the core, one copy family per pull request, in a fixed order. The
  first slices are pure functions (document number label, xlsx cells, import row checks, two web helpers,
  the web locale resolver); then the router request plumbing, one router at a time; then the module
  access guard (security review). The document/posting kernel of assets and stock (rows 6, 9 to 13,
  about 1000 shared lines) is **not** in the stream: it waits for a decision record (section 7).
- A slice is behaviour-neutral by construction: same reason atoms, status codes, response bodies and
  manifest hashes. It adds a **canary test** per moved function, with expected values taken from the old
  copy on `origin/main` before the move, and changes no other test except import paths and source scans
  that must follow the moved code (section 1, rule 6).
- No slice changes a module manifest's hashed surface. That keeps every installed tenant writing after
  the deploy without a run of the upgrade chain (section 3). A slice that would change a hash is out of
  the stream.
- The core stays inside the public (community) part of T-1521: every helper moved here comes from the
  generic modules; nothing is moved for exam or procurement alone (section 4).

## 1. Rules every slice keeps

1. **One copy family per pull request.** A slice moves one function family (one row, or one router of
   rows 2-4) into its core home and switches every copy to it. It does not tidy anything else.
2. **Behaviour-neutral.** Reason atoms, error tuples, HTTP status codes, problem `code` texts, response
   shapes, export bytes and labels stay the same. Where the copies differ, the core function takes the
   difference as an argument, or the module keeps its own extra clause in front of the call (the choice
   for each family is fixed in section 5).
3. **Tests first or unchanged.** The existing tests of every changed module run unchanged and pass. The
   slice changes a test only for (a) an import or `vi.mock` path of a moved web file, or (b) a source scan
   that must now also read the core file (rule 6). Each such change is listed in the pull request.
4. **A canary test per moved function.** One table-driven test per moved function, in the test file that
   mirrors the core home (`lib/a/b.ex` -> `test/a/b_test.exs`). Its expected values are produced by running
   the old copies on `origin/main` before the move and pasted as literals, as
   `test/letflow/modules/catalog_ledger_hash_test.exs` does with its golden hashes ("computed by the
   origin/main code before this change"). The canary covers every input class the copies treat
   differently (for example the `%Date{}` cell of row 16). Web canaries are vitest files next to the core
   file.
5. **Manifest hashes unchanged.** The pull request quotes `Letflow.Modules.ManifestHash.compute/1` of every
   entry module of `Letflow.Modules.Catalog.entry_modules/0`, before and after; the lists must be equal
   (section 3).
6. **Source scans follow the code.** Before moving code out of a file, `grep -rn 'File.read!("<file>")'` and
   `Path.wildcard(` over `test/`. A scan that asserts a property of the moved code (for example X-6b in
   `test/letflow/modules/stock/xlsx_export_test.exs`: "the module names no Repo or Ecto.Query", or T2 in
   `test/letflow/modules/codes/resolve_router_test.exs`) is extended to the core file, so it does not pass
   while checking nothing. The repo-wide scan in `test/letflow/idempotency_test.exs` ("caller key is read
   only in Idempotency", AC5) reads `lib/**/*.ex`: a moved key reader keeps the `~s(idempotency_key)`
   sigil form the org router uses today.
7. **Boundary checks green.** `mix letflow.check_boundaries` exits 0 and the web lint passes; the quoted
   output goes in the pull request.
8. **Sequenced, never parallel.** One slice is in flight at a time. Each slice lists the files it touches
   (section 6) so the operator can check the queue for other tasks on the same files before queuing it.
9. **No schema change, no migration, no tenant data.** A slice that reads or writes a tenant schema (Repo
   calls with a `prefix:`) is HELD (section 7). A plain `Repo.transaction` wrapper with no prefix of its
   own (row 14 `transact/1`) is not tenant data and is allowed.
10. **No version bump.** Module `version:` values stay as they are (section 3).

## 2. Boundaries

The core must not depend on modules. This is already enforced, and the stream relies on it:

- **Backend.** `mix letflow.check_boundaries` rule 5: a file outside every `lib/letflow/modules/<id>/`
  directory may not reference a file inside one; the one exception is `lib/letflow/modules/catalog.ex`
  (rule 1). Rule 4: a module may reference another module only if it is in its manifest `depends_on`.
  Decision 0039 D3 states the same and adds: core code never builds a module name at run time (xref
  cannot see it).
- **Web.** `web/.eslintrc.json`, top-level `no-restricted-imports`: no file may import `@/modules/**` except
  `@/modules/registry` and `@/modules/types`; the override that switches it off covers only
  `src/modules/registry.ts`, `src/dev/harness/**` and one completeness test. Each module's override also
  forbids importing a sibling module.

What follows for the design:

- **Down, never sideways.** A shared function moves into the core, never into a sibling module, even where
  `depends_on` would allow it (assets lists stock). The inventory's observation applies: a shared kernel
  inside stock would make stock a dependency of every future document module.
- **The core takes callbacks and data, never module names.** A core helper that needs per-module
  behaviour (a reason table, a render function, a permission atom) receives it as an argument from the
  module. It never names `Letflow.Modules.<Id>` and never builds one.
- **Entry rule.** A function enters the core only if it is used by two or more modules, or by the core and
  one module. A one-module function stays in that module.
- **Neutral names.** Core function names carry no module vocabulary (stock, item, location, lot and the rest
  of rule 7's denylist). Rule 7 itself scans only the ledger files; outside them the stream keeps the same
  discipline by review, since a core name with a module word is a hidden dependency.
- **Ledger and policy files are special.** A posting policy file (`lib/letflow/modules/<id>/ledger_policy/**`)
  may call only `Enum`, `Map`, `List`, `String`, `Integer`, `Keyword`, `MapSet`, `Tuple`, `Access`,
  `Decimal`, `Letflow.Ledger.Policy` and its own modules (the policy allowlist). So a shared policy
  helper can only live in `Letflow.Ledger.Policy`, or the allowlist changes; both are for the decision
  record (section 7). Rule 8 (single call site, no forgery) scans `lib/letflow/modules/<id>/**` and
  exempts `lib/letflow/ledger/**` by construction: posting code moved into the ledger directory would
  leave rule 8's coverage. That is a second reason rows 10 and 11 are HELD.
- **Handler files stay pure** (scan H4, noted in inventory row 12): handler extraction is HELD.

## 3. Fit with the module manifest and the upgrade chain U1-U4

The upgrade chain, as the operator's handoff names it: **U1** the dry-run plan route
`POST /tenant/modules/:module_id/upgrade/plan` (REQ-768, merged in 703d13ba8), **U2** the one-transaction
apply `POST /tenant/modules/:module_id/upgrade` (REQ-770, 79ee2d190), **U3** the 409 `upgrade_required`
refusal while a tenant is not upgraded (REQ-771, 943b839a0), **U4** the boot-time upgrade behind a flag
that defaults off (REQ-772, 0fdabe646). All four are on `origin/main`. Decision 0080 lists them as slices 1
and 3 to 5 of its split plan (slice 2, REQ-769, accepted earlier hashes, is the stamp check they use).

What a slice must know about it:

- `Letflow.Modules.ManifestHash` hashes `id`, `version`, `manages_entity_types`, `scope_declarations`,
  `reference_targets`, the whole `ledger` map (including the policy **module and function**, for example
  `policy: {Letflow.Modules.Stock.LedgerPolicy, :declare}` in `lib/letflow/modules/stock/stock.ex`) and, per
  write handler, `name`, `inspect(module)`, the function name, `targets`, `args` and `posts_ledger`. It does
  not hash permissions, routes, settings, pack content or handler code.
- So moving a function body out of a module file does not change the hash, **as long as** the handler
  module names, handler function names and the policy module and function stay where they are. Every
  slice in section 6 meets that: none touches a manifest, a `handlers.ex` or a `ledger_policy/` file.
- The moduledoc of `ManifestHash` sets the discipline "bump `:version` whenever handler code changes". No
  slice in the stream changes handler code, so no slice bumps a version (rule 10). A version bump would
  change the hash; on QA every installed tenant would then answer U3's 409 on module writes until an
  administrator runs U1 and U2 (U4 is off by default, and turning it on in production is the owner's
  decision, 0080 "Not decided here").
- Consequence: a future slice that must change a hashed key (moving handler code, renaming a policy
  module) is not behaviour-neutral for installed tenants. It leaves the stream and goes with the HELD
  kernel (section 7), with its upgrade plan written down (which change class U1 reports, what U2 applies).
- **Module manifest shape.** The stream adds no manifest key and no callback to `Letflow.Modules.Module`.
  The core helpers are plain modules a module calls; they are not part of the module contract. (If the
  kernel later needs a "document kind" behaviour, that is a callback set for the decision record, not for
  this stream.)
- **No schema change.** None of the rows in section 6 needs one. If a design finds it needs one, the slice
  stops and is re-planned with a migration and the upgrade chain, after a decision record.

## 4. Fit with the open/closed split (T-1521)

`docs/uat/ba-decisions/T-1521.md` section 1 puts the platform core and the generic modules (org,
locations, catalog_items, codes, stock, assets) in the public **community** part, and exam and
procurement in the closed part. Section 4 states the principle "the community edition never contains a call to closed
code; the corporate edition adds, it does not patch". The owner later chose the MIT licence for the
public repository (portfolio D-116, which answers T-1521's licence question for the public repo; the
licence file goes in only after the clean-up). This stream changes no licence and publishes nothing.

What the split asks of this stream:

- **Core = community.** Every function this stream puts in the core is used by generic (community)
  modules. Code that only exam or procurement use is not moved (the exam cursor of row 3 stays in
  `lib/letflow/modules/exam/grading.ex`). Closed modules may call the new core helpers: the dependency then
  runs closed -> open, which the split allows.
- **No enterprise feature enters the core through this stream.** The seams T-1521 section 4 lists (identity
  provider, extended audit, licence-key flags, package signatures) are its own stage 2, not this stream.
- **It helps the split.** Each slice removes a copy from the generic modules, which shrinks what a later
  public tree has to carry twice. It does not move any closed code, so it does not make the later scan of
  the public tree (T-1521 stage 2 gate) harder.
- **Sequencing with the assets phases.** T-1521 section 7 warns that moving code the assets phases still
  change causes conflicts. That is the reason for rule 8 and the file lists in section 6: before queuing a
  slice, the operator checks that no assets or stock task in the queue touches the same files.

## 5. The planned core API

All homes are planned, not yet on main, unless the row says "exists". Names are fixed here so the slice
designs do not re-decide them.

| Family (row) | Core home | Function (in words) | Replaces | How differences are kept |
|---|---|---|---|---|
| Document number label (1) | `Letflow.Documents` in `lib/letflow/documents.ex` (exists; the function is private today) | `number_label/3` made public: given a document type row (`number_prefix`, `number_pad`, `numbering_scope`), a number and a period, returns `PREFIX-000123` for scope `:none` and `PREFIX-<period>-000123` otherwise | `label/3` in `lib/letflow/modules/assets/documents.ex`, `label/2` in `lib/letflow/modules/stock/document_numbers.ex`, the two inline copies in `lib/letflow/modules/stock/documents.ex` | The copies are equal. The `Repo.get!` of the type row and the `number: nil -> nil` clause stay in the modules (tenant read, rule 9) |
| Xlsx cells (16) | `Letflow.Documents.XlsxStyle` in `lib/letflow/documents/xlsx_style.ex` (exists) | `cell_text/1` (nil, `DateTime` as ISO 8601, binary, atom or number as string, anything else JSON), `cell_scalar/1` (nil, integer as is, else `cell_text/1`), `cell_json/1` (nil, else JSON) | `text/1`, `scalar/1`, `json/1` in `lib/letflow/modules/{assets,stock}/xlsx_export.ex` | Assets' `text/1` has an extra `%Date{}` clause that stock lacks: assets keeps that one clause and calls `cell_text/1` for the rest. `quantity/1` and `number_or_text/2` exist only in assets and stay there (entry rule) |
| Import row checks (14, without `find`) | `Letflow.Entities.ImportRow` in `lib/letflow/entities/import_row.ex`, beside `Letflow.Entities.XlsxImport` (exists) | `text?/1` (a non-blank binary); `check_cells/4` (cells, importable headers, ignored headers, required headers) returning `{:error, {:field_not_allowed, "active"}}`, `{:error, :field_not_allowed}` or the result of `check_required/3`; `check_required/3` (cells, required headers, a one-argument function that builds the module's error term from the missing header); `transact/1` (run a function in `Repo.transaction`, roll back on `{:error, reason}`) | the same-named private functions in `lib/letflow/modules/{assets,locations,org}/import.ex` and `lib/letflow/modules/catalog_items/lot_import.ex` | The error term is the caller's function (assets `{:asset_field_required, h}`, locations and org `{:field_invalid, f}`). Org's extra `user_id` check stays in org after the call. `find/3-4` reads a tenant schema: HELD |
| Download a file (23) | `web/src/lib/saveBlob.ts` | `saveBlob(blob, filename)`, same body | `web/src/modules/codes/saveBlob.ts`, `web/src/modules/stock/register/saveBlob.ts` (the inventory's two), plus three copies the inventory missed: the private `saveBlob` in `web/src/pages/admin/import/MasterDataImportPage.tsx` and `web/src/pages/admin/usersImport/UsersImportPage.tsx` (core pages) and the exported one in `web/src/modules/stock/counts/PaperworkButtons.tsx` | Four bodies are byte-identical (md5 of the function); `PaperworkButtons.tsx` ends with `a.remove()` instead of `document.body.removeChild(a)`, the same effect on an appended anchor. The two module files are deleted in the slice and their importers switch. The exam copy (`web/src/modules/exam/ExamMyResultsPage.tsx`) is not touched (closed module, section 4) |
| Document state tone (24) | `web/src/lib/documentStateTone.ts` | `stateTone(state)` -> `{ tone, glyph }`, same switch | `web/src/modules/{assets,stock}/documents/stateTone.ts` | Identical after the name swap (`diff` checked) |
| Locale resolver (21) | `web/src/i18n/resolveLocale.ts` | `resolveLocaleFrom(candidates, supported, fallback)`: `undefined` -> `getUiLocale()`; else the first candidate whose base tag (before `-`, lower case) is in `supported`; else `fallback` | `resolveUiLocale` in `web/src/modules/{assets,catalog_items,codes,locations,org}/…Messages.ts` | Each module keeps its exported `resolveUiLocale` as a one-line call with its own locale list and `'en'`, so module types and callers do not change. The `navigator` branch of four copies is unreachable (it follows `if (candidates === undefined) return`), so dropping it is neutral; the canary proves it. Exam's own resolver is not touched (closed module, entry rule) |
| Module IntlProvider (22) | `web/src/i18n/createModuleIntlProvider.tsx` | a factory that takes a module's message catalog (locale -> messages) and returns a provider component with an optional `locale` prop: active locale = the prop, else `useUiLocale()`; `defaultLocale="en"` | the six non-exam `web/src/modules/*/…IntlProvider.tsx` (assets, catalog_items, codes, locations, org, stock) | Each module keeps its exported provider name and any extra export (org's `useOrgLocale`); only the body becomes the factory call. Providers without the `locale` prop today (assets, locations, org) gain an optional prop no caller passes, so rendering is unchanged. Exam is left as it is |
| Module router plumbing (2, 3, 4) | `Letflow.Modules.RouterKit` in `lib/letflow/modules/router_kit.ex`, a core mechanism file per 0039 D3 | `with_request/3` (conn, the module's render function, the action function), `check_keys/2`, `pop_key/1`, `elem_tag/1`; paging `limit/1`, `cursor/2` (`:text`, `:integer`), `uint/1`; a `render/3` skeleton that takes the module's reason table | the byte-identical private functions of `lib/letflow/modules/{org,locations,catalog_items,codes}/router.ex`; paging copies in `lib/letflow/modules/{assets,stock}/router.ex` | The reason table (which atoms answer 404, 409, 422) stays in each module and is passed in. Stock's statement-timeout option stays in stock's `reconcile_opts`. The prefix still comes from `conn.assigns.scoped_opts`, never from the request |
| Module access guard (5) | `Letflow.Api.ModuleGuard` in `lib/letflow/api/module_guard.ex`, beside `Letflow.Api.Scope` | `check(conn, permission)`: interactive OIDC user, a role allows the permission **with** the tenant overlay (`Authorization.role_allows?/3`), tenant-wide scope `{:ok, :all}`, actor uuid; `:error` otherwise, `ScopeSetError` rescued to `:error` | `check/2` in `lib/letflow/modules/{assets,stock}/access.ex` | Each module keeps `permission/1` (its own atoms) and calls the guard. Stock today uses `role_allows?/2`: equal to `/3` only because `Authorization.grantable/0` grants `[:AssetsRead, :AssetsPost]` and no Stock atom. The slice pins that fact in its canary; security review required |
| Backend test helpers (27) | `test/support/module_conn_case.ex` | `strip/1` (drop `trace_id`), `json/1`, `call/3-4`, `tenant/1` | the 27 + 21 + 17 + 14 private definitions under `test/letflow/modules/**` | Two bodies of `strip/1` and three shapes of `call/3-4` exist: the helper keeps each shape under its own name; no test assertion changes |

Rows not in the API, with the reason: 15, 17, 19, 20 are already core (inventory); 26 is data per module;
18 (views) shares only `pad/1` and `empty_to_nil/1`, about three neutral lines, while the slot maps are
module vocabulary built field by field as an INV-2 allowlist, so a core home would add a dependency for no
gain; 7 and 8 (kinds, shape) belong with the kernel design (section 7) because their reason atoms are part
of the document routes; 25 (web document screens) comes after the kernel (section 6, last).

## 6. Slice plan (in order; one at a time)

Value = copies removed and how often the code is read or changed; risk = tenant data, authorization,
rendering, conflict surface. Each slice is one pull request with the rules of section 1. "Tests" names
the canary (planned) and the existing tests that must stay green unchanged.

| # | Slice | Rows | Value / risk | Files touched | Tests | Extra gate |
|---|---|---|---|---|---|---|
| S1 | Document number label | 1 | 5 copies of the label on every document, print and export / pure | `lib/letflow/documents.ex`, `lib/letflow/modules/assets/documents.ex`, `lib/letflow/modules/stock/document_numbers.ex`, `lib/letflow/modules/stock/documents.ex` | canary `test/letflow/documents/number_label_test.exs` (scope `:none` and yearly, pad 1 and 6, a number wider than the pad); existing `test/letflow/documents/*`, `test/letflow/modules/{assets,stock}/**` document tests | none |
| S2 | Xlsx cells | 16 | 2 copies, every export / pure | `lib/letflow/documents/xlsx_style.ex`, `lib/letflow/modules/assets/xlsx_export.ex`, `lib/letflow/modules/stock/xlsx_export.ex`; X-6b in `test/letflow/modules/stock/xlsx_export_test.exs` extended to the core file | canary in `test/letflow/documents/xlsx_style_test.exs` (planned; nil, `DateTime`, `Date` through assets and through stock, binary, atom, integer, float, map); existing xlsx export tests of both modules | none |
| S3 | Import row checks | 14 (not `find`) | 4 files, every master-data import / pure plus a prefix-free transaction wrapper | `lib/letflow/entities/import_row.ex` (new), `lib/letflow/modules/{assets,locations,org}/import.ex`, `lib/letflow/modules/catalog_items/lot_import.ex` | canary `test/letflow/entities/import_row_test.exs` (planned; each reason shape of each module, the org `user_id` case through org); existing import tests of the four modules | none |
| S4 | Web helpers | 23, 24 | 5 + 2 copies / pure, no render change | `web/src/lib/saveBlob.ts`, `web/src/lib/documentStateTone.ts` (new); delete `web/src/modules/codes/saveBlob.ts`, `web/src/modules/stock/register/saveBlob.ts`, `web/src/modules/{assets,stock}/documents/stateTone.ts`; importers `web/src/modules/assets/documents/{DocumentList,DocumentView}.tsx`, `web/src/modules/stock/documents/{DocumentList,DocumentsWorkspace}.tsx`, `web/src/modules/stock/register/{BalancesPage,MovementsPage,usePdfDownload}.ts(x)`, `web/src/modules/codes/useLabelsPrint.ts`, `web/src/modules/stock/counts/PaperworkButtons.tsx`, `web/src/pages/admin/import/MasterDataImportPage.tsx`, `web/src/pages/admin/usersImport/UsersImportPage.tsx`; `vi.mock` paths in `web/src/modules/codes/__tests__/CodesPage.labels.test.tsx` and `web/src/modules/stock/__tests__/MovementsPage.test.tsx` | vitest canaries next to the two new files (every state of the switch; the download anchor is created, clicked, removed and the URL revoked) | none (deleting module files is a move inside the product, not a "deletion from the old tree") |
| S5 | Web locale resolver | 21 | 5 copies / pure | `web/src/i18n/resolveLocale.ts` (new), `web/src/modules/{assets/assetsMessages,catalog_items/catalogItemsMessages,codes/codesMessages,locations/locationsMessages,org/orgMessages}.ts` | vitest canary (`undefined`, `kk-KZ`, `RU`, an unsupported tag, an empty list); existing module message tests | none |
| S6 | Web IntlProvider factory | 22 | 6 copies / renders: provider body only | `web/src/i18n/createModuleIntlProvider.tsx` (new), `web/src/modules/{assets,catalog_items,codes,locations,org,stock}/*IntlProvider.tsx` | vitest canary (the provider renders a catalog string in en, ru, kk); existing screen tests unchanged | shots: one screen per module in en/ru/kk to show no change, if the engine's GUI review asks for them |
| S7a-S7f | Router plumbing, one router per slice: org (creates `RouterKit`), then locations, catalog_items, codes, assets (adds paging), stock (paging) | 2, 3, 4 | 6 routers, about 250 + 60 lines / request plumbing, no tenant read | `lib/letflow/modules/router_kit.ex`, then the one `lib/letflow/modules/<id>/router.ex` of the slice | canary `test/letflow/modules/router_kit_test.exs` (planned; created in S7a, extended per slice); the router's own `test/letflow/modules/<id>/router_test.exs`; `test/letflow/idempotency_test.exs` (AC5); for codes `resolve_router_test.exs` T2, extended to the kit; for stock `router_test.exs` ("no binary_to_term"), extended to the kit | none; one router at a time because every router file is a frequent conflict spot |
| S8 | Module access guard | 5 | 2 copies on an authorization path / medium | `lib/letflow/api/module_guard.ex` (new), `lib/letflow/modules/assets/access.ex`, `lib/letflow/modules/stock/access.ex` | canary `test/letflow/api/module_guard_test.exs` (planned; user vs API token, role with and without the permission, overlay grant, scoped principal, `ScopeSetError`, bad uuid; plus an assertion that `Authorization.grantable/0` holds no Stock atom); existing access and router tests of both modules, including their INV-10 other-company cases | **security review** (INV-1, INV-2, INV-5, INV-10) |
| S9 | Backend test helpers, one module family per slice | 27 | about 80 definitions / test-only, but touches many test files | `test/support/module_conn_case.ex` (new), then the test files of one module directory per slice | the moved helpers are the canary (each old test still passes unchanged) | none; placed after S1-S8 because it touches the test files those slices run |
| — | Kernel: document context, kinds, shape, checks, posting, ledger policy, handlers, opening import, row 14 `find` | 6-13, 14 `find` | about 1000 shared lines / **HELD** | not planned here | not planned here | decision record first (section 7) |
| last | Web document screens, one screen per slice | 25 | the largest web copy / renders | per screen, after the kernel | screenshot matrix per screen | GUI review |

The order puts pure backend first (S1-S3, no screen, no route), then pure web (S4-S5), then the one web
change that renders (S6), then request plumbing (S7, routes but no tenant read), then the one
authorization change (S8), then the wide but test-only S9. S1-S3 and S4-S5 do not share a file, but rule 8
still keeps them one at a time.

## 7. HELD: what the decision record must settle before the kernel

Rows 6 and 9 to 13 and `find` of row 14 read or write tenant data, the ledger, process instances or the
handler and policy surface that the manifest hash covers. They need a decision record (next free number
on main today: 0087; re-check at the time). This note does not take it. The record has to answer:

1. The kernel API: a document-kind behaviour in `lib/letflow/documents/` (callbacks for kinds, shape,
   checks) or plain functions with a kind table argument.
2. Where shared posting code lives without leaving rule 8's coverage, and the neutral names under
   `lib/letflow/ledger/` (rule 7).
3. Whether shared policy helpers go into `Letflow.Ledger.Policy` or the policy allowlist widens.
4. Whether handler code moves at all: moving it changes the handler module named in the manifest, hence
   the hash, hence a version bump and a U1/U2 run on every installed tenant (section 3).
5. The proof of neutrality: posting and reversal on both modules give the same ledger rows, document rows
   and audit entries before and after (a golden comparison through the real HTTP routes, D-098).
6. The security review of every tenant-data path it moves (INV-1, INV-6, INV-10).

## 8. Not decided here, and findings

- No REQ entry is written for this task: the task asks for this note, which is the deliverable (the
  workflow `requirement` does not match, as for CORE-1). Each slice of section 6 needs its own task; the
  operator queues them in order.
- The exact test file names marked "planned" may be adjusted by each slice's design, as long as they
  mirror the core home.
- The stale sentence noted by the inventory (assets "cannot call stock", while `assets.ex` lists stock in
  `depends_on`) is not fixed here. S1 edits that file (`lib/letflow/modules/assets/documents.ex`), so S1
  corrects the sentence in the same pull request (a moduledoc change, no behaviour).
- Inventory gap: row 23 lists 2 `saveBlob` copies; there are 6 (`git grep -n 'function saveBlob' web/src`):
  the two module files, two core admin pages, stock's `PaperworkButtons.tsx` and exam. S4 covers all but exam.
- Web: whether `src/dev/harness/**` fixtures that import modules need updating per slice is a check for
  each web slice (they are allowed to import modules by the lint override).

## Commands behind the facts

```
git grep -nE 'defp? (number_label|label)\(' lib/letflow/documents.ex lib/letflow/modules/assets/documents.ex lib/letflow/modules/stock/document_numbers.ex
git grep -nE 'String.pad_leading\(type.number_pad' lib/
grep -nE 'defp (text|scalar|json|quantity|number_or_text)\(' lib/letflow/modules/{assets,stock}/xlsx_export.ex
grep -nE 'defp? (check_cells|check_required|text\?|transact|find)\(' lib/letflow/modules/{assets,locations,org}/import.ex lib/letflow/modules/catalog_items/lot_import.ex
diff <(sed 's/Assets/X/g;s/Stock/X/g' web/src/modules/assets/documents/stateTone.ts) <(sed 's/Assets/X/g;s/Stock/X/g' web/src/modules/stock/documents/stateTone.ts)
git grep -nE "vi.mock\(.*(saveBlob|stateTone)" web/src
git grep -lE "saveBlob'|stateTone'" web/src
git grep -n 'function saveBlob' web/src
python3 -I -c "import json;d=json.load(open('web/.eslintrc.json'));print(d['rules']['no-restricted-imports'])"
grep -nE 'def (role_allows\?|grantable)\(' lib/letflow/api/authorization.ex
grep -nE 'policy: \{' lib/letflow/modules/stock/stock.ex
git grep -nE 'File.read!\("lib/letflow/modules/(assets|stock|org|locations|codes|catalog_items)/' test
git log origin/main --oneline | grep -E 'REQ-76[89]|REQ-77[0-3]'
git ls-tree --name-only origin/main docs/migration/decisions/ | tail -3
```
