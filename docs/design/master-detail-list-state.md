# Master-detail list state: Back returns to the list as it was left

Status: PART 1 of T-3163 (design note, docs only). PART 2 (the build) is NOT started: it is
queued by the PM after reading this note.

## Problem

Owner's walk, 28 Nov: open a process (instance or definition) from a list, press Back (or the
breadcrumb), and the list is back at its defaults: filters, search, page and scroll are lost.

## What exists today

Read from `web/src` on main (`git grep` of `useSearchParams`, `useState` in each page).

| List page | File | Filters / search | Paging | Sort | State lives in | What Back does |
|---|---|---|---|---|---|---|
| Instances | `pages/instances/InstanceBoardPage.tsx` | status (multi), `definitionName`, `definitionId` | cursor, `pageSize` | none | filters and `pageSize` in URL (`useSearchParams`); the cursor stack is `useState` | filters survive (they are in the URL, the browser Back restores them); page resets to 1; scroll lost |
| Definitions | `pages/definitions/DefinitionListPage.tsx` | `status`, `search` (`useState`), expanded version row (`useState`) | none (search page_size 20) | client-side column sort (DataTable internal state) | all `useState` | everything resets |
| Tasks | `pages/tasks/TaskInboxPage.tsx` | `filter`, `sort`, `search` | none (client-side) | `sort` | URL for filter/sort/search; the selected task is `useState` seeded from `?task=` but never written back | filter, sort, search survive; selection resets on Back unless `?task=` was set; scroll lost |
| DLQ | `pages/dlq/DlqPage.tsx` (`DlqItemsPage.tsx` for items) | `search`, `statusFilter`, `sourceTypeFilter`, `selectedId` | cursor stack, fixed 25 | none | all `useState` | everything resets; the row links to `/instances/:id`, so Back from there lands on a reset list |
| Solution packs | `pages/solution-packs/SolutionPackUpdateLauncherPage.tsx`, `SolutionPackOverridesPage.tsx`, `SolutionPackUpdateReviewPage.tsx` | no list filters: launcher form (`packId`, document), overrides form/retire dialog | none | none | `useState` | form drafts reset; there is no list state to lose beyond that |

Shared pieces in `web/src/components/ui`: `PaginationControls` (stateless, takes `page`,
`onPageChange`, `hasNextPage`), `listDetail/ListDetail.tsx` (+ `useListSelection`, local
`useState` selection, `ListDetailBackContext` for the panel close button), `DataTable`
(internal sort). Nothing restores scroll (`ScrollRestoration` is not used anywhere in `web/src`).
Instances and Tasks are half-way (filters in the URL); Definitions and DLQ are fully local.

Three different Back behaviours therefore exist: URL-backed (instances, tasks), local state
(definitions, DLQ), and none needed (solution packs).

## What to unify

One rule: **the list's view state is in the URL query string; the detail is a route or a `?selected=` param;
Back is the browser's Back.** State kept in the URL: filters, search text, sort, page (as a cursor
stack, see below), page size, selected id. Not in the URL: transient UI (dialogs, drafts, expanded
rows that are cheap to reopen).

### Why URL params and not a session store

| Concern | URL query params | Session store (memory / `sessionStorage`) |
|---|---|---|
| Deep link (send a colleague "failed DLQ items of webhook X") | works | impossible, the link carries nothing |
| Reload | state survives | memory store loses it; `sessionStorage` keeps it but per tab |
| Two tabs | each tab has its own state, independent | `sessionStorage` is per tab too; a shared `localStorage` makes tabs overwrite each other |
| Back / Forward | the browser history is the state history, for free | the store must be keyed by route and cleared on "fresh" navigation; a second mechanism to keep in step with history |
| Tests | render with `MemoryRouter initialEntries`, assert the query string | needs store reset between tests |
| Cost | URL length (fine: a few short params); cursors are opaque strings | none |

The one thing the URL does not give is scroll. Scroll is the only part that uses a session store
(`sessionStorage`, key = location key / path + search, value = `scrollTop` of the list container);
it is a convenience, not state, and losing it is harmless.

## Shape of the shared pieces

1. `useListUrlState(schema)` in `web/src/hooks/` (a hook, so a page keeps no `useQuery` of its own
   and the `missing-query-state-boundary` guard stays satisfied). `schema` declares each param:
   `{ key, default, parse, serialize }` for string, enum, multi-enum, int. Returns
   `{ values, set(patch), reset() }`. Rules: a default value is not written to the URL (clean URLs);
   changing a filter or search drops `cursor`/`page`; `set` uses `replace` for typing (search) and
   `push` for discrete changes (filter, page, selection) so Back steps through meaningful states;
   an unparsable value falls back to the default (INV-8 spirit: never throw on a hand-edited URL).
   Search text is debounced before it reaches the URL.
2. Cursor paging in the URL: the cursor stack becomes a `cursor` param holding the cursor of the
   current page plus a `page` number (display only). Previous is browser Back or an explicit
   stack kept as `cursors=a,b,c` (cursors are opaque and must be URL-encoded; if a cursor is long
   the stack is capped at 20 pages and "Previous" past the cap returns to page 1). Decision for
   slice 1 to confirm with the PM: use `cursors=` (the existing stack model, one-to-one with today's
   `cursorStack`).
3. `useRestoreScroll(containerRef, key)`: saves `scrollTop` on unmount / before navigation,
   restores after the first data render of the same key. A no-op when the key has no saved value.
4. Detail links keep the list's query: row links are built with `listLink(path)` which returns
   `{ pathname, state: { from: location.pathname + location.search } }`; a detail page's Back
   control uses `navigate(state.from)` when present, else `navigate(-1)` when history exists, else
   the list route without params. A plain browser Back works with no help because the list URL is
   already the history entry.
5. `ListDetail` stays the one shell (owner checklist items 1, 2, 4). Its selection becomes an
   optional controlled prop (`selectedId`, `onSelect`) so a screen can bind it to `?selected=`;
   uncontrolled use is unchanged, so no existing screen breaks.

ru/kk/en: no new user-facing string is needed (the back control reuses the existing label); the
catalog stays unchanged, and each slice's test asserts the catalog completeness guard still passes.

## Slices of the build (PART 2, one list per slice, smallest first)

| # | Slice | Why this order | Tests |
|---|---|---|---|
| 1 | `useListUrlState` + `useRestoreScroll` + `listLink`, and the **Tasks** inbox adopts them (already URL-backed; adds `?selected=` and scroll) | smallest; proves the hook on a page that already works | hook unit tests (default not serialised, bad value falls back, change resets cursor); Tasks component test below |
| 2 | **Instances** (move the cursor stack into the URL; `InstanceDetailPage` Back) | filters already in URL, only paging and scroll missing | instances component test below |
| 3 | **Definitions** (status, search, expanded row) | all local state; no paging | definitions component test below |
| 4 | **DLQ** (search, status, source type, cursor stack, selected) | most state, cursor stack | DLQ component test below |
| 5 | **Solution packs** (launcher/overrides: pack id in the URL, form drafts kept in `sessionStorage` per pack) | has no list, lowest value | pack test below |

Each slice is one PR touching one page, its tests and (slice 1) the shared hooks.

## Tests per slice

Component test (React Testing Library, `MemoryRouter` with the real routes of the page and its
detail), the same shape in every slice:

1. Render the list; set a filter, type a search, go to page 2 (where the list pages).
2. Click a row; assert the detail route is shown.
3. Press Back (`history` back via the router, or the detail's Back control).
4. Assert the filter control shows the chosen value, the search box the typed text, the page is 2,
   the same query-string is in `location.search`, and the query function was called with the same
   arguments.
5. Scroll: set `scrollTop` on the list container before opening the row; after Back assert it is
   restored (jsdom has no layout, so the test checks the hook writes and reads the saved value and
   sets `scrollTop` on the ref).
6. Reload case: render with the URL already carrying the params (`initialEntries`), assert the same
   state (deep link).
7. Negative: an invalid param (`?pageSize=abc`, unknown status) renders the defaults, no throw.
8. Two lists rendered in separate routers do not share state.

Slice 1 adds the hook unit tests; every slice runs the message-catalog completeness and
`navGuardParity` tests unchanged (no new route, no new string). Screenshots at 1440/390 are not
needed where markup does not change; a slice that adds a visible Back control takes the state matrix.

## Not decided here

- Whether the selected row of `ListDetail` is part of the URL on every screen or only on those
  that deep-link a record (this note recommends yes, `?selected=`).
- Cap and encoding of the cursor stack (see item 2).
- Scroll restore for virtualised lists (none exist in the five lists above).

## PR note

PART 2 is not started. The task parks at this note until the PM reads it and queues the slices.
