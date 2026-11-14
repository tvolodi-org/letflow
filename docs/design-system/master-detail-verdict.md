# Master-detail (list + detail) screens: audit and design verdict

Design verdict of the web designer/architect, delegated by the owner (PM D-136, task T-1885). It settles screen
layout only. It changes no data, no permission and no production setting. Docs only: no code changes in this task.
The operator queues the implementation slices in section 6.

## 1. Summary in plain words

The app has five ways to put a list next to a record. Two of them have a divider you can drag and collapse, one
has a divider with no collapse button, and the most common one has no divider at all. That is why the owner saw
different behaviour from screen to screen during the gate walk. The splitter itself is fixed: since T-1873 a collapsed
list can always be reopened, and the in-flight T-1884 keeps the reopen button on screen after a reload. What is still
wrong is that most screens do not use that splitter.

Decision: **one list + detail component, `ListDetail`, for every screen that shows a list with one record beside it.**
The document form and the movement journal keep their own shells, because they have a third pane or special phone
views. Both use the same divider rules. A source-scan guard makes the build fail when a screen builds its own
layout.

| Pattern | Where it is used today | Decision |
|---|---|---|
| `MasterDetail` (`lf-md`): list + record, **no divider** | Asset cards, stock counts, codes, lots, locations, org (5 screens), tasks, module rollouts | **Replace** with `ListDetail` (slices 2-5); delete `MasterDetail` at the end |
| `Registry` (`lf-reg`): list + record, divider, collapse | Catalog items | **Becomes `ListDetail`** (same markup and CSS; `Registry` is kept as a re-export until slice 6) |
| `Registry` without `screen` + the screen's own `useSplit` on it: list + side panel, divider, collapse | Asset balances, stock balances | **Move** to `ListDetail` (slice 1); same behaviour, less code |
| `DocLayout` (`lf-doc`): list + header + lines, divider, collapse | Asset documents, stock documents | **Keep** as the document shell; it follows the divider rules of section 4.3 and gets no new behaviour |
| `Journal` (`lf-jrn`): operations + legs, divider **without collapse** | Asset movements, stock movements | **Keep** the shell; the divider becomes collapsible like the others (slice 1b) |
| Detail below the table, fixed overlay drawer, list then a separate page | DLQ, print templates, webhooks; users, definitions, instances | **Out of this family for now**; late, optional slice 7 for the first three; the list-then-page screens stay as they are |

## 2. Sources

Read for this verdict (verified by reading the file on origin/main `589c2817b`, or the sibling repo at `25d2031`):

- `web/src/components/ui/MasterDetail.tsx`, `masterDetailBack.ts`, `DetailHeader.tsx`
- `web/src/components/ui/layout/Splitter.tsx`, `splitEngine.ts`, `ResetLayoutButton.tsx`, `layoutMessages.ts`, `isWideHost.ts`
- `web/src/components/ui/doc/DocLayout.tsx`, `web/src/components/ui/journal/Journal.tsx`, `journalLayouts.ts`,
  `web/src/components/ui/registry/Registry.tsx`, `registryLayouts.ts`
- `web/src/components/layout/AppShell.tsx` (global Reset layout button), `web/src/lib/layoutPrefs.ts`,
  `lib/letflow/user_preferences.ex` (screen-id rule and the 40-screen cap)
- the screens in the table of section 3, `web/src/router.tsx` and the module route files `web/src/modules/*/*Routes.tsx`
- `web/src/styles/components.css` (blocks `.lf-md`, `.lf-doc`, `.lf-reg`, `.lf-jrn`, `.lf-splitter`), `web/src/styles/base.css`
- `web/tests/guards/forbidlist.ts`, `meta-control.spec.ts`, `source-scan.spec.ts`, `no-role-literals.spec.ts`, `web/package.json` (`guards` script)
- sibling design repo `~/dev/ai-dala/letflow-design/platform/NOTES.md` (section 2 component table, "Layouts of the
  registry", "Narrow variants of the journal", "Resizable panes, columns and remembered layout", section 8 rules 2,
  11-14) and `platform/style-guide/index.html` (section titles 11, 19, 21, 22, 23)
- task records in the team database (outside the product repo; quoted in the appendix section A.3): T-1873 (merged as
  `7d6acf454`, #4404), T-1875 (merged as `cdc1b4855`, #4397), T-1884 (in flight, read from its worktree diff)

Not read: the exam screens (`web/src/modules/exam/`, held by the owner), `web/src/pages/admin/modules/ProcessModulesPage.tsx`
(not routed, see the comment in `router.tsx`), the e2e Playwright configuration. I did not open the screens in a real
browser. Phone-width behaviour in section 3 comes from the CSS rules, not from screenshots.

Marking: **[V]** = verified by reading code (command in the appendix); **[G]** = a guess or inference I did not run.

## 3. Part 1: audit

### 3.1 List + detail screens

Legend: Divider = a drag handle between list and detail; Collapse = a button that hides the list; Restore = the
always-visible reopen control of a collapsed pane (T-1873); Reset = a way to forget the saved layout. Since T-1873
the side nav has a global "Reset layout" button (`data-testid="reset-layout-all"`, `AppShell.tsx`) on every screen,
so the Reset column names only extra per-screen buttons.

| # | Screen | Route | Built with | Divider | Collapse | Restore | Per-screen Reset | Phone (<= 900 px) | Keyboard |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Asset documents | `/admin/assets/documents`, `/new`, `/:id` | `DocLayout` (`lf-doc`, screen `assets.documents`) | yes (list/header; header/lines from 1440) [V] | list pane [V] | yes [V] | yes (`DocumentsWorkspace.tsx`) [V] | record replaces list, back button (container query) [V] | splitter keys; Escape closes a viewed document [V stock] [G assets] |
| 2 | Stock documents | `/admin/stock/documents`, `/new`, `/:id` | `DocLayout` (`stock.documents`) | yes [V] | list pane [V] | yes [V] | yes [V] | same as 1 [V] | splitter keys; Escape closes [V] |
| 3 | Asset balances | `/admin/assets/balances` | `Registry` with no `screen` (its own splitter off) + the page's own `useSplit` through `gridRef` (`assets.balances`) | yes [V] | list pane [V] | yes [V] | no | detail replaces list (`lf-reg` rule) [V] | splitter keys; Escape closes (Registry `onClose`) [V] |
| 4 | Stock balances | `/admin/stock/balances` | same as 3 (`stock.balances`) | yes [V] | list pane [V] | yes [V] | no | same as 3 [V] | same as 3 |
| 5 | Asset movements | `/admin/assets/movements` | `Journal` (`lf-jrn`, `assets.journal`) | yes [V] | **no** [V] | n/a | no | narrow variant v1 by default: legs inline under the row (v2 sheet, v3 replace) [V] | splitter keys; Escape closes details [V] |
| 6 | Stock movements | `/admin/stock/movements` | `Journal` (`stock.journal`) | yes [V] | **no** [V] | n/a | no | same as 5 [V] | same as 5 |
| 7 | Catalog items | `/admin/catalog/items` | `Registry` (`lf-reg`, `stock.registry.items`) | yes [V] | list pane [V] | yes [V] | yes (`ResetLayoutButton`) [V] | record replaces list [V] | splitter keys; Escape closes [V] |
| 8 | Asset cards | `/admin/assets/cards` | `MasterDetail` wide (`lf-md`) | **no** [V] | no | n/a | no | record replaces list (viewport media query) [V] | Escape closes panel [V] |
| 9 | Stock counts | `/admin/stock/counts`, `/:id` | `MasterDetail` wide | **no** [V] | no | n/a | no | same as 8 [V] | Escape closes (moduledoc) [V] |
| 10 | Codes | `/admin/codes` | full table; `MasterDetail` **only while a code is selected** [V] | **no** | no | n/a | no | same as 8 | Escape closes [V] |
| 11 | Lots | `/admin/catalog/lots` | full table; `MasterDetail` only while a panel is open [V] | **no** | no | n/a | no | same as 8 | Escape [V] |
| 12 | Locations (tree) | `/admin/locations` | `MasterDetail` + `TreeView` | **no** [V] | no | n/a | no | same as 8 | tree arrow keys; Escape closes [V] |
| 13-17 | Org: legal entities, sites, units, positions, employees | `/admin/org/legal-entities`, `/sites`, `/units`, `/positions`, `/employees` | `OrgScreen` -> `MasterDetail` + `TreeView` | **no** [V] | no | n/a | no | same as 8 | tree keys; Escape closes [V] |
| 18 | Task inbox | `/tasks` | `MasterDetail` | **no** [V] | no | n/a | no | same as 8 | no Escape handler found [V] |
| 19 | Module rollouts (platform) | `/admin/module-rollouts` | `MasterDetail` wide | **no** [V] | no | n/a | no | same as 8 | Escape closes (document keydown listener in the page, `ModuleRolloutsPage.tsx`, active while a rollout is selected) [V] |

Totals: 19 screens, 6 shells. 12 screens (8-19) have no divider. 2 screens (5, 6) have a divider without a collapse
button. 5 screens (1-4, 7) have both. The owner's observation is confirmed.

### 3.2 Similar patterns that are not list + detail

| Pattern | Screens | Built with | Note |
|---|---|---|---|
| Detail card below the table | DLQ (`/dlq`), print templates (`/admin/print-templates`) | inline `style` section after the table [V] | Breaks design rule 12 ("details pane on the RIGHT, never below it on wide screens") |
| Fixed overlay drawer | Webhooks (`/webhooks`, `WebhookSubscriptionDetailPanel`, `role="dialog"`, `position: fixed`) [V] | own | Breaks rule 2a (no modal for viewing) |
| List, then a separate page | Users -> user detail, definitions -> editor, instances -> instance detail, exam builder [V routes] | route per record | Not master-detail. Keep: a full editor needs the whole width |
| Tree + detail | Locations, org (rows 12-17) | `MasterDetail` + `TreeView` | Covered by `ListDetail` with `kind="tree"` (`lf-reg--tree` exists in the design CSS) |
| Table + side panel | Balances (rows 3, 4) | own grid | Covered by `ListDetail` |
| Operations + legs | Movements (rows 5, 6) | `Journal` | Keeps its shell (narrow variants v1-v3) |
| List + form in the detail | Every `MasterDetail`/`Registry` create and edit | detail slot | The form sits inside the detail slot, never a modal |

### 3.3 Inconsistencies found in the code

1. Four shells repeat the same "record replaces list under 900 px" rule in four CSS blocks. `lf-md` uses a viewport
   `@media (max-width: 900px)`; `lf-reg`, `lf-doc` and `lf-jrn` use the `lfhost` container query. So a `MasterDetail`
   screen inside a narrow work area (side nav open on a 1024 px laptop) does not stack, and the others do [V CSS, G effect].
2. The design repo contradicts itself: NOTES section 8 rule 2 says "Hierarchies use `MasterDetail` + `TreeView`", and
   rule 12 says master data lists (items, org units, locations, employees, lots, codes) are a registry (`lf-reg`) with
   `lf-tree` for hierarchies. The screens followed rule 2. Rule 13 ("every list or detail pane that can be too narrow or
   too wide has a splitter") is broken by all 12 `MasterDetail` screens.
3. The balances screens switch the `Registry` splitter off (no `screen`) and attach their own `useSplit` with the same
   `.lf-reg__list` / `.lf-reg__details` selectors and other numbers (`min` 320, `defaults` 60), so the setup is copied by hand.
4. Codes and lots switch from a full-width table to a split view when a row is picked, so the list jumps.

## 4. Part 2: verdict

### 4.1 One family, three shells, one divider

- **`ListDetail`** is the only two-pane shell (list | one record). It is used for master data (table or tree), work
  lists (tasks, counts, rollouts) and table + side panel (balances).
- **`DocLayout`** stays the shell for documents with lines (three panes, registered layouts `row` / `tabs`, rule 11).
- **`Journal`** stays the shell for operations + legs (its narrow variants v1-v3 are a real difference).
- All three get their divider from one place: the `LIST_SPLIT` preset (section 4.2, behaviour 2) on top of `useSplit` /
  `splitEngine.ts`. No screen calls `useSplit` or writes a shell class itself.

Why not one component for all three: `DocLayout` has a third pane and tab layouts, and `Journal` has three phone
variants. Merging them would make a big component with many modes and no gain for the user. Users notice the
divider, collapse, restore and phone rules, so those are shared.

Why `ListDetail` is built on the `lf-reg` markup and not on `lf-md`: `lf-reg` already has the splitter, the
collapsible list, the tree variant (`lf-reg--tree`), the `split` / `tabs` layouts, the container-query breakpoints and
a design-repo preview (`platform/preview/registry.html`). `lf-md` has none of these. Picking `lf-reg` means no new CSS.

### 4.2 Component API

File: `web/src/components/ui/listDetail/ListDetail.tsx` (planned, not yet on main). `Registry.tsx` becomes a re-export
during the migration and is removed in slice 6.

```ts
export interface ListDetailProps {
  /** Layout screen id, required: the divider and its size are remembered per user under screens.<screen> (ui.layout).
   *  Pattern [a-z0-9.-]{1,48} (layoutPrefs.ts SCREEN_ID, UserPreferences @screen_id). */
  screen: string
  /** 'table' (default) or 'tree' (adds lf-reg--tree, list width from --master-width). */
  kind?: 'table' | 'tree'
  /** Registered registry layout: 'split' (default) or 'tabs' (registryLayouts.ts). */
  layout?: RegistryLayout
  /** Slots. */
  listHeader?: ReactNode   // title row + count + create action of the list pane (lf-reg__listhead)
  tools?: ReactNode        // filters, search, show-retired (lf-reg__tools)
  list: ReactNode          // DataTable (compact) or TreeView; lives in lf-reg__body
  listFooter?: ReactNode   // pager / truncation notice (lf-reg__foot)
  detail: ReactNode        // the record: DetailHeader + sections, or the create / edit form
  empty?: ReactNode        // detail pane when nothing is selected (wide screens); default: the generic empty state
  /** A record or a create form is open: under 900 px of work area it replaces the list. */
  detailOpen: boolean
  /** Back button (narrow) and Escape (any width): the screen clears its selection. */
  onClose: () => void
  /** Escape closes the record unless this is false (a dialog or an unsaved edit owns the key). */
  escapeCloses?: boolean
  /** Default list width in percent of the work area while nothing is stored (balances use 60). */
  listDefault?: number
  /** Smallest list width in px (default 260; balances 320). */
  listMin?: number
  /** Accessible name of the list pane and the divider, from the screen's own catalog (en/ru/kk). */
  listLabel: string
  sectionTabs?: RegistrySectionTab[]   // 'tabs' layout only, as Registry today
  defaultTab?: string
}
```

Behaviour (each line is a test in the component's test file):

1. **Two panes on wide screens, always.** The detail pane shows `empty` when nothing is selected. The list never jumps
   between a full table and a split view (fixes 3.3 item 4). A table hides its optional columns (`is-opt`) by the
   registry rule.
2. **Divider:** `useSplit` with `LIST_SPLIT` (id `list`, `sized: 'before'`, `unit: 'pct'`, `collapsible: [0]`,
   `clampStored: true`, `min: [listMin]`, `flexMin: 360`, `defaults: [listDefault]` when given), enabled only while
   the work area is over 900 px (`isWideHost`).
3. **Collapse and restore:** the list collapses with the divider button, Enter or double-click. The restore control is
   the engine's always-visible expander (T-1873), kept inside the viewport (T-1884). `ListDetail` adds no restore code
   of its own.
4. **Saved layout:** per screen id and per user through `useLayoutPrefs` (server `ui.layout`, then the localStorage copy).
   The global "Reset layout" in the side nav clears every screen. No per-screen Reset button is added; the existing
   ones (documents, items) stay.
5. **Narrow (work area <= 900 px):** no divider; the list alone, or the record alone with a back button
   (`lf-reg__backrow`, the existing `MasterDetailBackContext` / `DetailHeader` back handler, renamed
   `ListDetailBackContext`). Breakpoints come from the `lfhost` container query, not the viewport (fixes 3.3 item 1).
6. **Keyboard:** Tab order list -> divider -> detail. Splitter keys come from the engine (arrows, Shift+arrows, Home,
   End, Enter, double-click, Escape on the divider resets the layout). Escape inside the shell closes the record
   unless `escapeCloses === false` or the event was already handled (`defaultPrevented`). The list keeps its own keys
   (TreeView arrows, table row Enter).
7. **Labels:** the shell owns no words except those already in `layoutMessages.ts` (Resize / Collapse / Expand /
   Reset layout, en/ru/kk). The screen passes `listLabel` and the empty-state text from its own en/ru/kk catalog.
8. **Empty state default:** the generic `EmptyState` with "Select a record on the left", in en/ru/kk in
   `layoutMessages.ts`. The words in ru and kk are written by the implementer and checked in the kk screenshot.

Screen ids for the migrated screens (19 ids in all with the 7 existing ones, under the cap of 40 in `layoutPrefs.ts`
and `user_preferences.ex`): `assets.cards`, `stock.counts`, `codes`, `catalog.lots`, `locations.tree`,
`org.legal-entities`, `org.sites`, `org.units`, `org.positions`, `org.employees`, `tasks.inbox`,
`platform.module-rollouts`. The existing `assets.balances` and `stock.balances` keep their ids and split id `list`, so
saved sizes survive slice 1.

### 4.3 Divider rules (all three shells)

1. The divider between the list and the record collapses the **list**. A divider inside the record pane (document
   header | lines) only resizes.
2. Every collapse has the engine's always-visible restore control. A collapse with no visible control opens on load
   (the T-1873 fail-safe in `eff()` of `splitEngine.ts`).
3. Journal: today the details pane is sized (`sized: 'after'`, split id `details`) and the operations list is the
   flexible `1fr` column, so the engine cannot collapse the list. Slice 1b switches the journal to the balances setup:
   split id `list`, `sized: 'before'`, `collapsible: [0]`, `defaults: [60]`, `min: [360]`, `flexMin: 460`. That needs one
   CSS line in the design repo: `.lf-jrn { grid-template-columns: var(--lf-pane-1, 60%) minmax(0, 1fr); }` (today
   `minmax(0, 1fr) var(--lf-pane-1, var(--journal-details-width))`). A stored `screens.<id>.panes.details` value is then
   no longer read. `persist()` writes only its own split id (`setPanes(screen, id, ...)`) [V], so the old value stays in
   the document, unused, until the user's Reset layout. It is a layout preference, not data, so no migration is needed.
4. `DocLayout` already follows rules 1-2 (list collapsible; header | lines resize only) [V].

### 4.4 Registration in the design system

The catalog is in the sibling repo; this task does not edit it. Proposed text for
`~/dev/ai-dala/letflow-design/platform/NOTES.md`; the operator gives it to the design repo's owner:

a) Section 2, component table: replace the `MasterDetail` row and the `Registry` row with:

> | `ListDetail` (class `lf-reg`; replaces `MasterDetail` / `lf-md`) | `screen` (layout id, required), `kind` table/tree, `layout` split/tabs, slots `listHeader`, `tools`, `list`, `listFooter`, `detail`, `empty`, `detailOpen`, `onClose`, `escapeCloses`, `listDefault`, `listMin`, `listLabel` | wide: list left, record right, always two panes (empty state when nothing is selected); divider with collapsible list and an always-visible restore control in the viewport; sizes remembered per user and screen; work area <= 900 px: the record replaces the list, back button; Escape closes the record |

b) Section 8, rule 2: replace "Hierarchies use `MasterDetail` + `TreeView`." with "A list with one record beside it uses
`ListDetail`; hierarchies use `ListDetail kind=tree` + `TreeView`."

c) Section 8, new rule 16:

> 16. **List + detail.** When to use: any screen with a list and one selected record (master data, work lists, a table
> with a side panel). Use `ListDetail`; documents with lines use `DocLayout` (rule 11); the movement register uses
> `Journal`. Do not: write `lf-md`, `lf-reg`, `lf-doc` or `lf-jrn` on a screen's own element; call the splitter
> (`useSplit`, `SplitWrap`) from a screen; put the record below the list or in a modal on wide screens; make a divider
> without a collapsible list; add a per-screen restore button. Examples: catalog items (table), locations (tree), stock
> balances (table + side panel, `listDefault` 60). The product's guard `list-detail-own-shell` fails the build on a
> violation.

d) Style guide section 11 "Master-detail form" is renamed "List + detail" and shows the registry markup; section 21
stays as the full reference. The `.lf-md` block of `platform/style-guide/components.css` is removed once the product's slice 6
has landed (the product copies `components.css` from a release and never edits it, `docs/design-system/README.md`).

Product side: this file is the record. When slice 6 lands, `docs/design-system/README.md` gets one line pointing here.

### 4.5 How the guard is enforced

The guard uses the existing source-scan guard (`web/tests/guards/`), which already runs in CI's
`Frontend gate (npm run check)` through `npm run guards`:

- Three entries are added to `PATTERNS` in `web/tests/guards/forbidlist.ts`. Regexes may only be defined there
  (GRD-UI-01). All three are `appliesTo: 'source'`, so `source-scan.spec.ts` applies them to
  `web/src/**/*.{ts,tsx,css}` (tests included), rationale `T-1885`:
  1. `list-detail-own-shell`: a shell root or modifier class written on a screen's element.
     `regex: /className=(?:\{[^}]*)?["'`](?:[^"'`]*\s)?lf-(?:md|reg|doc|jrn)(?:--[a-z]+)?(?=[\s"'`])/`
     It matches `className="lf-md lf-md--wide"`, the ternary form in `MasterDetail.tsx` and `className="lf-reg"`. It does
     not match element classes such as `lf-reg__list` or `lf-doc__header`, which screens may use inside the slots.
  2. `list-detail-direct-split`: a screen attaching the splitter itself. `regex: /\buseSplit\s*\(|<SplitWrap\b/`
  3. `master-detail-import`: a new user of the old shell.
     `regex: /from\s+['"](?:[./@\w-]+\/)?(?:MasterDetail|masterDetailBack)['"]/` (any path prefix, so a deep
     relative import such as `../../components/ui/MasterDetail` is caught too; none exists today, every screen uses `@/`)
- `allowedPaths` (all three): `web/src/components/ui/listDetail/`, `web/src/components/ui/doc/`,
  `web/src/components/ui/journal/`, `web/src/components/ui/registry/` (until slice 6), `web/src/components/ui/layout/`,
  `web/src/components/layout/AppShell.tsx` (side-nav splitter), `web/src/dev/harness/fixtures/layoutBase.tsx`
  (reference harness), plus a **ratchet list** of the files not yet migrated.
- Initial ratchet list. I measured it by running the three regexes over `git ls-files 'web/src/**/*.{ts,tsx,css}'` with
  node (script `guardcheck.mjs` in the task folder, output in appendix A.4):
  `web/src/components/ui/MasterDetail.tsx`, `web/src/components/ui/DetailHeader.tsx`,
  `web/src/components/ui/__tests__/Layout.test.tsx`, `web/src/components/ui/__tests__/MasterDetail.narrow.test.tsx`,
  `web/src/modules/assets/register/BalancesPage.tsx`, `web/src/modules/stock/register/BalancesPage.tsx`,
  `web/src/modules/assets/AssetCardsPage.tsx`, `web/src/modules/catalog_items/LotsPage.tsx`,
  `web/src/modules/codes/CodesPage.tsx`, `web/src/modules/locations/LocationTreePage.tsx`,
  `web/src/modules/org/OrgScreen.tsx`, `web/src/modules/stock/counts/CountsPage.tsx`,
  `web/src/pages/admin/module-rollouts/ModuleRolloutsPage.tsx`, `web/src/pages/tasks/TaskInboxPage.tsx`.
  Each slice removes its own files. After slice 6 the list is empty and `MasterDetail.tsx` is deleted. Slice 1 re-runs
  the scan because main moves.
- `meta-control.spec.ts` requires an offender and a bystander fixture for each pattern
  (`web/tests/guards/fixtures/offender/<name>.txt`, `.../bystander/<name>.txt`). For example, the offender for
  `list-detail-own-shell` is `<div className="lf-md lf-md--wide">`; its bystander is `<div className="lf-reg__list">`
  plus `<ListDetail screen="codes" />`.
- Why a regex source scan and not an ESLint rule: the repo's UI guards are already in this harness, with fixtures and a
  report. An ESLint rule would be a second mechanism for the same job. The rule-12 check "record below the list" cannot
  be scanned; it stays a gui_review item.

### 4.6 What T-1873, T-1875 and T-1884 already settled (not redone)

- **T-1873 (merged, `7d6acf454`):** always-visible restore control of a collapsed pane (`.lf-splitter.is-collapsed` in
  `base.css`); double-click toggles a collapsible pane; Escape on a divider resets every saved layout; the global
  "Reset layout" button in the side nav (`store.resetAll()`, server and browser copy); the fail-safe that shows a
  collapsed pane open when its control is not rendered; the stale-tab ordering in `layoutStore.ts`. `ListDetail`
  inherits all of it through `useSplit`.
- **T-1875 (merged, `cdc1b4855`):** the `.lf-doc` list card height fix (base.css grid rows) and `clampStored` (a saved
  size never makes the list narrower than its minimum). `LIST_SPLIT` turns `clampStored` on for every list.
- **T-1884 (in flight; branch `team/T-1884`, implement step):** the expand button of a collapsed pane is kept inside the
  viewport (`expanderTop()` and `placeExpander()` in `splitEngine.ts`, `position: fixed` in base.css) and the collapsed
  strip is as tall as the work area. Slices 1-6 start **after T-1884 merges**, so all shells get this from the engine.
  No slice changes `splitEngine.ts` except slice 1b's journal options, which are props, not engine code.

## 5. Out of scope

Data, queries, permissions (`can(...)` checks, `RequirePermission`, module guards), routes and URL parameters stay
exactly as they are in every slice. Only the layout shell changes. There are no feature flags. Nothing runs on QA,
demo or production from this task.

## 6. Migration order and slices

The gate C-E screens go first. Each slice is one `change` task (web only), with `after` = the previous slice
(they all edit `forbidlist.ts` and the harness registry). Every slice:

- removes the screen's own Escape key handler for closing the record (today in asset cards, counts, codes, lots,
  locations, `OrgScreen` and module rollouts; verified by `git grep -n "'Escape'"`), since `ListDetail` owns Escape
  (section 4.2 behaviour 6) and two handlers would close twice; Escape handling inside the record (dialogs, editors) stays;
- keeps data, permission and route behaviour unchanged (the screen's existing tests stay green unmodified, apart from
  selectors that named `master-detail*` test ids, which move to `registry*` / `list-detail*`);
- adds a Playwright check at **1920, 1440, 1280, 1024 and 390 px** width: list and record visible; divider present above
  900 px of work area and absent at 390; collapse, reload, restore control inside the viewport; at 390 the record replaces
  the list and Back returns. The model is the T-1875 spec `web/tests/e2e/doc-list-layout.e2e.spec.ts`;
- takes the screenshot matrix of the web rules (1440 and 390, light and dark, en, ru and kk);
- removes its files from the guard's ratchet list.

| Slice | Content | Screens | Gate |
|---|---|---|---|
| 1 | Add `ListDetail` + `LIST_SPLIT` + the component tests (section 4.2 lines 1-8); add the three guard patterns of section 4.5 (`list-detail-own-shell`, `list-detail-direct-split`, `master-detail-import`) with offender and bystander fixtures and a ratchet list of every current offender; move the balances screens to it | asset balances, stock balances | C-E |
| 1b | Journal: collapsible list divider (section 4.3 item 3), CSS line copied from the design repo after it is released there | asset movements, stock movements | C-E |
| 2 | Asset cards and stock counts to `ListDetail` (`listDefault` replaces `masterWidth="wide"`) | asset cards, stock counts | C-E |
| 3 | Codes and lots to `ListDetail` (two panes always, empty state) | codes, lots | C-E |
| 4 | Tree screens: `ListDetail kind="tree"`; `OrgScreen` uses it, so the five org pages change at once | locations, org (5) | C-E |
| 5 | Work lists; the module rollouts page's own document-level Escape listener is removed, since `ListDetail` owns Escape (section 4.2 behaviour 6) | task inbox, module rollouts | after C-E |
| 6 | `Registry` re-export removed (catalog items imports `ListDetail`); `MasterDetail.tsx` and `masterDetailBack.ts` are deleted, and so are the hand-written `lf-md` rules in `base.css` (the generated `components.css` is never edited; its `lf-md` block goes when the design repo drops it, section 4.4 d); ratchet list empty; README pointer | catalog items | after C-E |
| 7 (optional) | Detail below the table or in a drawer moved to `ListDetail` | DLQ, print templates, webhooks | operator's call |

Documents (asset and stock) need no slice: they already have divider, collapse, restore and clamp.

## 7. Assumptions and open points

- The design repo has to take the catalog text in section 4.4 and the journal CSS line (slice 1b). If its owner
  refuses, slice 1b is dropped and the journal keeps a resize-only divider. The verdict stays otherwise.
- Codes and lots will show two panes even when nothing is selected. That is a visible layout change on purpose. The
  owner will see it in gate C-E.
- The ru/kk wording of the new empty-state line is left to the implementer, who checks it in the screenshot matrix.

## 8. Slice 7 outcome (T-1893, judged screen by screen)

Each of the six screens was judged with the criteria of section 4 (list + one record beside it, divider, collapse,
restore, saved layout, phone stacking) and with section 5 (no change to data, permission or route behaviour).

| Screen | Decision | Reason |
|---|---|---|
| DLQ (`/dlq`) | **Converted** to `ListDetail` (`screen="dlq.items"`, `listDefault` 60, `listMin` 320) | The detail card sat below the table (rule 12) and pushed off-screen on a long page. Selection is local state, so nothing in data, permission or route changes. Retry / Discard stay in the list rows; the confirm dialog is a short single answer and stays a dialog. |
| Webhooks (`/webhooks`) | **Converted** (`screen="dlq.webhooks"`) | The fixed overlay drawer was a modal for viewing (rule 2a). The `subscription` URL parameter still selects the record, so deep links keep working; Escape and the phone Back button now come from `ListDetail`. Create stays the inline form above the list (a short single-purpose form). |
| Print templates (`/admin/print-templates`) | **Exception** | The layout editor is also the create form (a new draft), so it must be reachable with no record chosen. `ListDetail` shows only the list on a phone until a record is open, which would hide create. Fixing that needs a new "New override" action and state, i.e. a behaviour change this slice may not make. Revisit together with moving the page to the message catalog. |
| Users (`/admin/users` -> user detail) | **Exception** | List, then a separate route per user. The URL per record is a contract (links, permission-gated `RequirePermission` routes), and the user page is a full form with tabs that needs the whole width. Changing it changes route behaviour. |
| Definitions (list -> editor) | **Exception** | The editor is a full-width process designer (diagram canvas, versions); beside a list it would be unusable. Route per record stays. |
| Instances (list -> instance detail) | **Exception** | The instance detail is a full-width page (diagram, history, variables) reached by URL from tasks, DLQ and notifications. Route per record stays. |

The exceptions are recorded in `web/tests/guards/forbidlist.ts` next to the `list-detail-*` patterns (they match no
pattern, so no allowed path is needed; the comment names each screen and the reason).

Exact text for the design repo catalog (`platform/NOTES.md`, section 8, rule 16, "Do not" sentence; read-only for this
task, to be given to the design repo's owner): append

> Exceptions: a screen whose record is a full-width editor or board reached by its own URL (users, process
> definitions, instances) stays list-then-page; a screen whose detail is also its create form (print templates) stays
> as is until it has an explicit "New" action. Each exception is named with its reason in the product's guard file.

## Appendix: commands

All commands ran in the T-1885 worktree at origin/main `589c2817b`.

A.1 Inventory

```
git grep -nE "Splitter|LFSplit|lf-doc|DocLayout|MasterDetail|lf-registry|lf-journal|ListDetail" -- web/src | grep -v '\.test\.' | awk -F: '{print $1}' | sort | uniq -c | sort -rn
git grep -nE "useSplit\(|<SplitWrap" -- web/src | grep -v test
  -> AppShell.tsx, DocLayout.tsx, Journal.tsx, Registry.tsx, layoutBase.tsx (harness),
     modules/assets/register/BalancesPage.tsx, modules/stock/register/BalancesPage.tsx
git grep -nlE "<MasterDetail\b" -- web/src | grep -v test
  -> AssetCardsPage, LotsPage, CodesPage, LocationTreePage, OrgScreen, CountsPage, ModuleRolloutsPage, TaskInboxPage
git grep -nlE "<DocLayout\b" -- web/src | grep -v test     -> assets and stock DocumentsWorkspace.tsx
git grep -nlE "<(Journal|Registry)\b" -- web/src | grep -v test
  -> assets/stock BalancesPage (`<Registry ... gridRef={gridRef}>` without screen), assets/stock MovementsPage (Journal),
     catalog_items/items/ItemsPage (Registry screen=stock.registry.items)
git grep -nE "OrgScreen" -- web/src/modules/org/*.tsx | grep import   -> 5 org pages
grep -nE "path:|path=" web/src/router.tsx ; git grep -nE "path: ['\"]" -- 'web/src/modules/**/*.ts*'
```

A.2 Behaviour checks

```
git grep -nE "screen=['\"{]" -- web/src | grep -E "<(Registry|DocLayout)" ; git grep -n "layoutScreen=" -- web/src
git grep -n "ResetLayoutButton\|resetScreen\|resetAll\|resetLayout" -- web/src | grep -v test
git grep -nE "Escape" -- <the eight MasterDetail screens>     (no hit in TaskInboxPage)
grep -n "collapsible\|sized\|enabled" web/src/components/ui/journal/Journal.tsx    (no collapsible)
grep -n "lf-md\|lf-reg\[data-detail\|lf-jrn\[data-variant" web/src/styles/components.css
awk '... /@media|@container/ ...' web/src/styles/components.css   (lf-md: @media 1100/900/640; lf-doc, lf-reg, lf-jrn: @container lfhost)
grep -n "lf-splitter" web/src/styles/components.css ; grep -n "is-collapsed" web/src/styles/base.css
grep -nE "SCREEN_ID|keys\(screens, 40\)" web/src/lib/layoutPrefs.ts ; grep -n "@screen_id\|first_keys(screens, 40)" lib/letflow/user_preferences.ex
sed -n 1,40p web/tests/guards/meta-control.spec.ts ; grep -n "name: '" web/tests/guards/forbidlist.ts ; grep -n guards web/package.json
grep -nE "MasterDetail|lf-md|Registry|lf-reg|Journal|lf-jrn|DocLayout|lf-doc|Split|collapse" ~/dev/ai-dala/letflow-design/platform/NOTES.md
git show --stat cdc1b4855 ; git show --stat 7d6acf454 ; git -C ../T-1884 diff origin/main -- web/src/components/ui/layout/splitEngine.ts
```

A.3 Task text relied on (from `state/team.db`, outside the product repo)

- T-1873 (done): "DO: (1) a visible, ALWAYS-PRESENT control to reopen a collapsed panel ... (2) double-click on the
  splitter toggles collapse/expand, (3) Escape ... and a global 'Reset layout' entry ... clear ALL saved panel layout ...
  (4) a collapsed panel can never persist as unrecoverable ... (7) AUDIT every other splitter".
- T-1875 (done): "the document LIST CARD is laid out about 16 px tall ... Cause: the .lf-doc grid ... ONE fix for every
  .lf-doc screen ... Also handle a saved pane value like panes.row=[16.4,null]: a saved size must never make the list
  card smaller than a usable minimum (clamp)."
- T-1884 (running, implement): "the expand control of a collapsed pane must be inside the viewport after reload ... Do
  it in the Splitter component ... for every splitter in the app".

A.4 Guard dry run (regexes 1 and 2 of section 4.5 over every tracked web/src ts/tsx/css file; regex 3 by the grep below)

```
node state/tasks/T-1885/guardcheck.mjs
  direct-split web/src/components/layout/AppShell.tsx                      (allowed)
  own-shell web/src/components/ui/MasterDetail.tsx                         (ratchet)
  own-shell,direct-split web/src/components/ui/doc/DocLayout.tsx           (allowed)
  own-shell,direct-split web/src/components/ui/journal/Journal.tsx         (allowed)
  own-shell,direct-split web/src/components/ui/layout/Splitter.tsx         (allowed; doc comment)
  direct-split web/src/components/ui/layout/__tests__/Splitter.test.tsx    (allowed)
  own-shell,direct-split web/src/components/ui/registry/Registry.tsx       (allowed until slice 6)
  own-shell web/src/components/ui/registry/__tests__/RegistryLayout.test.tsx (allowed until slice 6)
  own-shell,direct-split web/src/dev/harness/fixtures/layoutBase.tsx       (allowed)
  direct-split web/src/modules/assets/register/BalancesPage.tsx            (ratchet, slice 1)
  direct-split web/src/modules/stock/register/BalancesPage.tsx             (ratchet, slice 1)
git grep -nE "from ['\"]@/components/ui/(MasterDetail|masterDetailBack)['\"]|from ['\"]\.\.?/(ui/)?(MasterDetail|masterDetailBack)['\"]" -- web/src
  -> DetailHeader.tsx, MasterDetail.tsx, __tests__/Layout.test.tsx, __tests__/MasterDetail.narrow.test.tsx and the eight screens of 3.1 rows 8-19
```
