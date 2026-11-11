# Accessibility beyond forms (T-1586)

Target: WCAG 2.1 AA. Forms are covered in [forms.md](forms.md). This note records what is measured, what is checked
automatically, and what is left. Every figure below comes from `web/tests/unit/contrastTokens.test.ts`.

## 1. Colour contrast (tokens, both themes)

Text pairs need 4.5:1, non-text pairs (borders of controls, focus ring, icons) 3:1.
`web/tests/unit/contrastTokens.test.ts` checks 28 text pairs and 7 non-text pairs in light and dark from
`web/src/styles/tokens.css`, and every `color` on `background` token pair of `components.css` and `base.css`
(100 pairs in light and dark; the test pins the number of unresolved pairs).

| Pair | Light | Dark | Verdict |
|---|---|---|---|
| `ink-faint` on `paper-sunken` | 4.39 | passes | **latent**: no rule uses it. Do not use it for text; the test pins it as the one exempt text pair |
| `line` on `paper` | below 3 | below 3 | decorative divider, exempt from 1.4.11. Control borders use `line-strong` (passes) |
| everything else in the test | passes | passes | no token value changed |

Failures per screen: none visible. Every screen is built from the component classes the scan covers, so no screen
needs its own fix. `tokens.css` and `components.css` are generated and unchanged.

Not measured: backgrounds over images or gradients; tenant brand colours (refused under 4.5:1 by `applyBranding`).
**Operator check (not in CI):** run the harness screens in a real browser with axe `color-contrast`
(`@axe-core/playwright` is not installed; `tests/a11y/a11yConfig.ts` keeps `color-contrast` enabled for that day).

## 2. Focus in dialogs

`web/src/components/ui/useModalFocus.ts` gives a dialog the rules of `Dialog.tsx`: focus in on open, Tab and
Shift+Tab wrap, Escape closes (not while busy), focus back to the opener. `web/tests/unit/dialogInventory.test.ts`
fails when a file with `role="dialog"` has neither the hook, `Dialog`/`ConfirmDialog`, nor a reviewed own Tab handler.

| Component | Before | After |
|---|---|---|
| `ui/Dialog.tsx` (and `ConfirmDialog`) | full | unchanged |
| `CancelInstanceDialog`, `RebindPinDialog` | full | unchanged |
| `DeactivateUserDialog` | none | hook |
| `HelpPanel`, `WebhookSubscriptionDetailPanel` | Escape and focus in | hook (adds Tab trap, focus back) |
| `ConflictResolver` (resolver, merge panel) | none | hook; the resolver has no Escape, the user must choose a way out |
| `TokensPage` (revoke, issued token) | none | hook; Escape on the one-time token is the same dismiss as its button |
| `GroupsPage` (members, delete), `TenantsPage`, `DlqPage`, `EntityCrudPage` | none | hook |
| `DateField` calendar | `aria-modal="true"` | popover, not modal: `aria-modal` removed |

Page-level dialogs are proven by the hook test, the inventory scan and `DeactivateUserDialog.focus.test.tsx`, not by
one behaviour test each (their pages need heavy fixtures). The old dialogs keep their English text.

## 3. Reduced motion

`components.css` ends with a `prefers-reduced-motion: reduce` rule that sets `transition` and `animation` to none
(covers skeletons, spinners, the history scrubber). JS-driven motion: `ProcessCanvas` `fitView` duration now asks
`prefersReducedMotion()` (`web/src/lib/motion.ts`). `motion.test.ts` fails when a `duration:` appears in `src`
without it. No smooth scrolling exists in `src`.

## 4. Headings and landmarks

`AppShell`: one `aside` (named "Sidebar") holding one `nav` (named "Main"), one `main#main-content`, a skip link; the
names come from `navMessages` in en, ru and kk. `AppShellLandmarks.test.tsx` checks one `main`, named and unique
`nav`/`aside`, one `h1`. `PageHeader` renders the single `h1`.

Route inventory: a text scan finds about 70 page files without `PageHeader` or a literal `<h1`; many take their title
from another shared component, so the scan is a candidate list, not a failure list. Fixing them is more than the ten
pages this change allows, so it is a follow-up: confirm each candidate in a browser (or a render test per route)
and move it to `PageHeader`.

## 5. Pass over the screens built since T-1586 (T-1690)

Screens: users import, instance replay, platform-operator rollouts, user page reset-password button. Checked by reading
the markup and styles; same method as sections 2 to 4.

| Finding | Screen | Verdict |
|---|---|---|
| Disabled "Import" button gave no reason to a screen reader | users import | fixed: the reason hint has an id and the button points to it (`Button` now forwards `aria-describedby`) |
| Check / import answer appeared without an announcement | users import | fixed: one polite `sr-only` status with the row counts (en, ru, kk) |
| Decorative em dash read aloud in the reason column | users import | fixed: `aria-hidden` |
| `lf-faint` (ink-faint, exempt in section 1) used for readable text | rollouts | fixed: `lf-muted` |
| `aria-label` on a plain `div` (ignored by assistive tech) | rollouts detail | fixed: `role="region"` |
| Reset-password answer was inserted together with its live region | user page | fixed: the live region is always rendered |
| Range, step list, mode switch: names, `aria-current`, `aria-live`, focus ring, 4.5:1 text | replay | no fault found |
| Escape on the rollouts page also fires from the module input and closes the detail | rollouts | left: behaviour, not a label or contrast fault; needs a product call |
| Real-browser axe run and kk wording check | all four | left: operator check, as in section 1 |
