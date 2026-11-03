# EntityCrudPage — real-click renderer-freeze fix (ISS-0662)

Design record for a MAJOR-severity fix inside WF-03's `issue/ISS-0662-20260914`
run. No `requirements.yaml` entry exists for this fix on its own — it is a
production defect (confirmed genuine renderer freeze for real users, not a
Playwright artifact) diagnosed by ISSUE-FIXER and designed here per WF-03 Step
2. **No implementation code appears in this document** — every change below is
described by call-site location and prose description of the change,
per CODE-DESIGNER's mandate (signatures/prose only).

Follows `docs/frontend/exam-session-localized-fields-fix.md`'s precedent: a
pure frontend bug-fix design note lives in `docs/frontend/` (kebab-case topic
file), not `lib/letflow/design/` (the backend Ecto/gen_statem convention,
which has no fit here).

## 0. ISSUE-FIXER's diagnosis, and this step's job

ISSUE-FIXER (`issue/ISS-0662-20260914`) established, with direct reproduction:

- ANY real (UA-trusted) click or keyboard activation of ANY state-changing
  action button on `EntityCrudPage` (create, edit, delete) freezes the
  browser tab's main thread — confirmed genuine (an unrelated CDP call issued
  on a separate channel during the freeze also hung, ruling out a
  Playwright-input-dispatch-only artifact).
- Ruled out: native form submission, mouse hit-testing, a JS
  infinite/recursive-setState loop reachable via the handler's own logic, a
  global document/window listener, an explicit `isTrusted` check, the shared
  `Button` component generally.
- Leading, **unconfirmed** hypothesis handed to this step: `EntitiesIntlProvider`
  (the app's only real `<IntlProvider>`) was structurally implicated.

This document's Step A (below) independently re-verified the repro, then
empirically tested and **falsified** that hypothesis, along with three other
plausible candidates, before isolating the real mechanism. All of this was
done live against the running dev stack (`mix run --no-halt` backend already
up, Vite dev server on `127.0.0.1:4173`), using a throwaway, uncommitted
Playwright script — never committed, and the working tree was returned to a
clean state (`git status --porcelain web/` empty) after each experiment and
at the end of this session.

## 1. Empirical trail (every hypothesis tested, with real pass/fail evidence)

All tests below use a real trusted gesture: `locator.hover()` +
`page.mouse.down()` + `page.mouse.up({ timeout: 8000 })` against
`/admin/bilimbaga/category` (`entity-crud-page`, `data-entity-type="category"`).
"Hangs" = `mouse.up()` exceeds an 8s/30-40s test timeout with zero console
activity in between (main thread genuinely idle-blocked, matching ISSUE-FIXER's
finding). "Resolves" = `mouse.up()` returns in ~1-2s and the expected UI state
(modal visible / sort indicator visible) is asserted true immediately after.

| # | What was tested | Change made (reverted after) | Result |
|---|---|---|---|
| 1 | Baseline repro, `entity-create-action` | none | **Hangs** (30s timeout) — matches ISSUE-FIXER |
| 2 | `EntitiesIntlProvider` hypothesis, `entity-create-action` | `EntityCrudPage`'s `useIntl` import replaced with a no-op stub returning `{locale:'en', formatMessage: (d) => d.id}`; `<EntitiesIntlProvider>` wrapper removed entirely | Resolves in 7.3s — but `entity-form-modal` never became visible: `EntityRecordForm.tsx`'s own **real** `useIntl()` call threw `[React Intl] Could not find required intl object`, caught by `ErrorBoundary`. **Inconclusive by itself** — the fast resolution could be explained by the render crashing early, before whatever the real expensive/blocking step is, rather than by removing `EntitiesIntlProvider` per se. |
| 3 | Same hypothesis, cleaner variant: replace declarative `<IntlProvider>` with `RawIntlProvider` + a module-scope, pre-warmed `createIntl()`/`createIntlCache()` (stable identity, never recomputed) in `EntitiesIntlProvider.tsx`, `EntityRecordForm` untouched (real intl still available, no crash) | `EntitiesIntlProvider.tsx` only | **Still hangs** (30s+ timeout) — same as baseline |
| 4 | Bypass only `EntityCrudPage`'s own `intl.formatMessage()` calls in the create-click render path (button label, modal title, submit/cancel labels replaced with a plain `entitiesMessages[locale][id]` lookup), real `<IntlProvider>` + real `EntityRecordForm` untouched | `EntityCrudPage.tsx` only | **Still hangs** (30s+ timeout) |
| 5 | Delete path (`entity-delete-*`) on an **existing** row — this path never mounts `EntityRecordForm` and its `ConfirmDialog` counterpart carries no `useIntl()` call at all | none (baseline delete repro) | **Hangs** (40s timeout) — proves the freeze is NOT specific to `EntityRecordForm` mounting, and is NOT `entity-create-action`-specific |
| 6 | Delete path with `EntitiesIntlProvider` fully removed **and** `EntityCrudPage`'s own `useIntl()` stubbed to a no-op (no react-intl code reachable anywhere in this click's render path — `ConfirmDialog` needs no intl) | `EntityCrudPage.tsx` only | **Still hangs** (40s timeout) — **falsifies the `EntitiesIntlProvider` hypothesis conclusively**: the freeze reproduces identically with zero react-intl involvement anywhere in the triggered render |
| 7 | Delete path with `ConfirmDialog`'s imperative `confirmRef.current?.focus()` effect (the only `.focus()` call anywhere in this page's dependency tree) commented out | `ConfirmDialog.tsx` only | **Still hangs** (40s timeout) — falsifies the focus-management hypothesis |
| 8 | Sanity check: a real trusted click with **no `onClick` handler at all**, on the same page (`datatable-header-actions`, a non-sortable `<th>`) | none | **Resolves in 1.8s** — proves the freeze requires an `onClick`-triggered React state update; it is not "this page/route is generally stuck" |
| 9 | Sanity check: a real trusted click on an unrelated route's own modal-opening button (`f2-definition-list.e2e.spec.ts`'s `btn-new-definition`, using the project's own existing, already-passing test) | none | **Passes in 1.9s** (pre-existing suite) — confirms this is not an environment-wide or Playwright-wide defect |
| 10 | A **structurally trivial** state-changing click on the SAME page, unrelated to entities/EntityRecordForm/i18n entirely: `DataTable`'s own local sort-header click (`datatable-header-name`, `setSortState` — a tiny local `useState` with no async work, no query invalidation, no modal) | none | **Hangs** (40s timeout) — the freeze is not domain-specific to entity CRUD's own state/mutations; it reproduces for the most trivial possible `setState` on this page |
| 11 | Same sort-header click, with `DataTable`'s `overflowY:auto` scroll container and `thead`'s `position: sticky` removed (in case sticky-position recompute under a real gesture was the trigger) | `DataTable.tsx` only | **Still hangs** (40s timeout) — falsifies the sticky/scroll-container hypothesis |
| 12 | Same sort-header click, with `handleHeaderClick`'s `setSortState(...)` call wrapped in `setTimeout(() => { ...same call... }, 0)` — deferring the state update out of the synchronous native-event-dispatch turn, everything else unchanged | `DataTable.tsx` only | **Resolves in 1.6s**, sort indicator correctly visible — **fix confirmed** |
| 13 | Same deferral pattern applied to `entity-create-action`'s `openCreate()` (`setFormError`/`setModal` wrapped in the same `setTimeout(..., 0)`) | `EntityCrudPage.tsx` only | **Resolves in 1.7s**, `entity-form-modal` correctly visible — confirms the fix generalizes beyond `DataTable` |

## 2. Confirmed root-cause mechanism

**Not** `EntitiesIntlProvider`, **not** `EntityRecordForm`'s mount cost,
**not** `ConfirmDialog`'s focus management, **not** `DataTable`'s
sticky/scrolling layout. Every one of those was the most structurally
plausible candidate in turn and each was individually falsified (tests 3, 6,
7, 11 above) by reproducing the freeze with that candidate entirely absent.

What tests 8, 10, 12, and 13 jointly establish: the freeze occurs precisely
when a React `setState` call runs **synchronously inside the same native
browser event-dispatch turn** that a real, UA-trusted click's `mousedown` →
`mouseup` → (native, browser-synthesized) `click` sequence drives — on this
specific page/route (`/admin/bilimbaga/:entityType` via `EntityCrudPage`), for
*any* click handler that calls `setState`, however trivial. Deferring the
exact same state update by one macrotask (`setTimeout(fn, 0)`) — with no
other change — makes the freeze disappear every time it was tried (tests 12,
13), while leaving the resulting UI state (sort applied / modal opened)
correct.

**What is honestly still open** (flagged per this role's "don't silently
resolve an open question by guessing" mandate, not glossed over): *why* a
synchronous discrete-priority commit specifically on this route deadlocks
Chromium's real (not script-dispatched) input-dispatch/compositor
acknowledgment, while the exact same commit shape works fine on other routes
(test 9) and while a handler-less click on this same route is fine (test 8),
was not pinned down to a specific Chromium/React internal call stack in this
session — `Profiler.stop` itself hangs during the freeze (per ISSUE-FIXER),
so getting the real native/JS call stack needs a Chrome DevTools Performance
trace captured through a real (non-headless, non-CDP-Profiler) Chrome window,
which is outside this environment's tooling. That deeper "why" does not block
this fix: the fix targets the *confirmed, reproducible trigger condition*
(synchronous setState inside a real click's native dispatch turn, on this
route) directly and is independently verified (tests 12-13) to both eliminate
the freeze and preserve correct behavior. It is called out here so a future
investigation isn't blocked re-guessing at already-falsified causes.

## 3. The fix

Defer every `setState` call that a **user-initiated click handler** on
`EntityCrudPage`'s render tree performs, by one macrotask, so the state
update — and the React commit/DOM mutation it causes — never executes inside
the same synchronous native-event-dispatch turn the trusted click arrived on.
This is the mechanism independently validated in tests 12 and 13 above, with
no other code path changed.

### 3.1 Files and call sites to change

**`web/src/pages/entities/EntityCrudPage.tsx`** — wrap the body of every
click-triggered handler that calls one or more `setState` setters, in a
`setTimeout(() => { ...unchanged body... }, 0)`:

- `openCreate()` (sets `formError`, `modal`)
- `openEdit(record)` (sets `formError`, `modal`)
- `closeModal()` (sets `modal`, `formError`) — called from
  `EntityRecordForm`'s Cancel button, one of the two originally-filed
  freezing paths
- The inline `onClick={() => setDeleteTarget(row)}` on each row's Delete
  button (`entity-delete-*`) — extract to a named handler
  (`openDeleteConfirm(row)`) that defers the same way, for symmetry and
  testability
- `confirmDelete()` (calls `deleteMutation.mutate(...)`, which itself
  triggers state via its `onSuccess`/`onError` callbacks) — the mutate call
  itself should also be deferred, since it is the thing a real trusted click
  on `ConfirmDialog`'s own confirm button invokes synchronously
- `ConfirmDialog`'s `onCancel={() => setDeleteTarget(null)}` — same
  treatment

Handlers that do NOT need this treatment (do not change): `goNext`/`goPrev`
(pagination — not part of the originally-filed freeze, but apply the same
pattern preemptively if `TEST-DESIGNER`'s coverage shows they reproduce it
too; not verified either way in this session since the filed scope was
create/edit/delete/cancel) — **flagged as an open scope question**, see §5.

**`web/src/components/ui/DataTable.tsx`** — `handleHeaderClick`'s
`setSortState(...)` call, same deferral. (This one was not in ISSUE-FIXER's
`affected_files` list, since it is a generic design-system primitive, not an
entities-specific file — but test 10 proves it carries the identical defect
whenever it is rendered inside `EntityCrudPage`'s tree. Whether `DataTable`
itself should own this fix — protecting every page that embeds it, including
ones not yet known to be affected — or whether only `EntityCrudPage`'s own
handlers should be patched, leaving `DataTable` as shipped, is this design's
one real open question: see §5, OQ-1.)

**`web/src/components/ui/ConfirmDialog.tsx`** — not required to change for
the fix itself (its two `useEffect`s were falsified as the cause in test 7),
but since `onConfirm`/`onCancel` are supplied by the parent
(`EntityCrudPage`), no change is needed here as long as the parent defers
before calling `deleteMutation.mutate`/`setDeleteTarget`.

### 3.2 Shape of the change (prose, no implementation code)

Each affected handler's existing body is unchanged in content — only its
execution is moved one macrotask later. A shared, tiny helper is the cleanest
way to express this without repeating `setTimeout(fn, 0)` at every call site;
CODE-DESIGNER specifies its signature only, ELIXIR-DEV/FRONTEND-DEV supplies
the body:

```
// web/src/utils/deferClickState.ts (new file)
export function deferClickState(fn: () => void): void
```

- Input: a zero-argument callback containing exactly the state-setting logic
  a click handler used to run synchronously.
- Output: none (fire-and-forget); the callback is scheduled to run after the
  current native-event-dispatch turn completes (macrotask boundary — a plain
  `setTimeout(fn, 0)` satisfies this per tests 12-13; a microtask
  (`queueMicrotask`) was NOT tested and should not be assumed equivalent —
  see §5, OQ-2).
- Every call site listed in §3.1 wraps its existing body in
  `deferClickState(() => { /* unchanged existing statements */ })`.
- No signature of any exported component (`EntityCrudPage`, `DataTable`,
  `ConfirmDialog`, `EntityRecordForm`) changes — this is purely an
  internal-implementation change to *when* existing state setters run, not
  *what* they do or what any prop/return shape looks like.

### 3.3 Why this resolves a real user-facing freeze, not just Playwright's

ISSUE-FIXER independently confirmed the freeze is genuine (an unrelated CDP
call also hung), and this design's own tests 12-13 confirm removing the
freeze via deferral while using the exact same real trusted-click gesture
Playwright drives — i.e., this is not "making the synthetic-click workaround
unnecessary," it is removing the actual synchronous-commit-inside-a-real-
click's-dispatch-turn condition that was shown to cause the hang regardless
of which component or which state was involved (tests 6, 7, 10, 11 already
rule out every component-specific explanation, leaving only the
"synchronous vs. deferred" axis, which tests 12/13 show is dispositive).

## 4. Regression test TEST-DESIGNER should write

A Playwright e2e test, using a REAL trusted click (`locator.hover()` +
`page.mouse.down()` + `page.mouse.up()`, exactly as this design's
reproduction did — NOT `dispatchEvent('click')`, which never exhibited the
freeze and would not catch a regression), against
`/admin/bilimbaga/category` (or any BilimBaga entity type):

- **Must fail against current `main`** (before this fix lands): assert
  `page.mouse.up()` resolves within a bounded timeout (e.g. 5s — generous
  above the ~1.5-2s this design measured post-fix, tight enough that the
  original ~30-40s freeze reliably trips it) when clicking
  `entity-create-action`, and separately for an existing row's
  `entity-delete-*` button. Use `test.step` or two separate `test()` blocks
  for the two action types (create, delete) since both were independently
  confirmed to freeze and both must be covered — the original filing's
  narrower "create + cancel only" framing under-covers what ISSUE-FIXER
  found.
- **After the fix**, in addition to the bounded-time assertion, assert the
  expected resulting UI state actually appears: `entity-form-modal` visible
  for create, and (for delete) either `confirm-dialog` visible after the
  delete-button click, or — if the test also drives the confirm click through
  to completion — the row disappearing from `data-table` after confirming.
  This guards against a regression where the fix silently swallows the state
  update (deferred forever, never actually applied) rather than merely
  deferring it by one tick.
- Also worth one assertion for the Cancel path (`entity-form-modal`'s Cancel
  button, real click) and one for the DataTable sort-header real click
  (`datatable-header-<field>`), since both were independently shown to freeze
  in this design's tests and are trivial to add once the harness exists.
- Existing specs (`categories.e2e.spec.ts`, `tags.e2e.spec.ts`,
  `question-bank.e2e.spec.ts`, `exam-lifecycle.e2e.spec.ts`) that currently
  use `dispatchEvent('click')` as the documented workaround should be
  revisited once the fix lands — TEST-DESIGNER's call whether to switch them
  to real `.click()` (proving the fix generally, at the cost of the extra
  ~1-2s per click) or leave the workaround in place with its comment updated
  to point at this fix's regression test instead of an unresolved defect.
  This is this design's second open question — see §5, OQ-3.

## 5. Open questions (explicitly unresolved, not guessed)

- **OQ-1**: Should the deferral live inside `DataTable.tsx` itself (protecting
  every current/future page that embeds this shared primitive, since test 10
  proves the defect is reachable through it whenever it renders inside
  `EntityCrudPage`'s tree — but this repo has not verified whether the same
  freeze reproduces for `DataTable` embedded in *other* routes, only that it
  does not on `f2-definition-list`'s specific button, which doesn't use
  `DataTable`'s sortable-header click at all), or only inside
  `EntityCrudPage.tsx`'s own handlers (narrower blast radius, but leaves
  `DataTable`'s sort-header click freezing on any *other* page that happens
  to share whatever route-level trait makes this page susceptible)? This
  design recommends fixing `DataTable.tsx` directly, since test 10's evidence
  is that the defect lives in the generic component's own handler, not in
  anything `EntityCrudPage`-specific — but ELIXIR-DEV/FRONTEND-DEV or
  REVIEWER should confirm this doesn't conflict with `DataTable`'s
  `web/src/components/ui/DataTable.tsx` contract (old `docs/frontend/design-system.md` §7.2, retired; see `docs/design-system/`) before implementing.
- **OQ-2**: `setTimeout(fn, 0)` was the only deferral mechanism tested (twice,
  successfully). `queueMicrotask`, `Promise.resolve().then(fn)`, and React's
  own `startTransition`/`flushSync`-avoidance APIs were NOT tested and must
  not be assumed to behave identically — a microtask still runs before the
  browser's next paint/compositor step and may not break the same
  synchronous chain a macrotask does. Implementation should use exactly the
  macrotask form validated here unless a follow-up explicitly re-tests an
  alternative.
- **OQ-3**: whether to keep or remove the `dispatchEvent('click')` workaround
  in the four already-ported e2e spec files — deferred to TEST-DESIGNER per
  §4.
- **OQ-4 (not investigated, out of this fix's scope)**: the true underlying
  Chromium/React mechanism (why synchronous commits specifically on this
  route deadlock native click dispatch) remains unknown — see §2's closing
  paragraph. If a future regression on a *different* route surfaces the same
  symptom, re-open this question rather than assuming `EntityCrudPage`- or
  `DataTable`-specific patching is a complete, page-independent fix for
  "any synchronous setState inside a real click on any route" — this design
  only proves the deferral pattern works for the specific handlers patched,
  not that it is the only route in the app capable of exhibiting this.

## 6. Acceptance-criteria mapping

| Requirement (from ISS-0662's diagnosis) | Design element covering it |
|---|---|
| Real click on `entity-create-action` must not freeze | §3.1 `openCreate()` deferral |
| Real click on edit action must not freeze | §3.1 `openEdit()` deferral |
| Real click on `EntityRecordForm`'s Cancel button must not freeze | §3.1 `closeModal()` deferral |
| Real click on a row's Delete action must not freeze (confirmed to never touch `EntityRecordForm`) | §3.1 `openDeleteConfirm`/`confirmDelete`/`ConfirmDialog onCancel` deferral |
| Keyboard (Tab+Enter/Space) activation must not freeze | Same handlers fire regardless of activation method (click event, not mouse-specific) — no separate code path exists to patch; covered by the same deferral |
| Fix must address a real user-facing freeze, not merely a Playwright workaround | §3.3, backed by tests 12-13's real-trusted-click verification |
| Regression test must fail pre-fix, pass post-fix, real click only | §4 |
