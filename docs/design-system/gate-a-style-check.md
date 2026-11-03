# Gate A style check: the six phase A screens (task T-1177, S-final)

Checked 2026-11-03 against the design repo `letflow-design` (`platform/NOTES.md` sections 2, 3, 4, 8,
`platform/README.md`, `platform/style-guide/` and `platform/examples/`), by the rules of the skill
`letflow-design-system`.

**Verdict: the screens are ready for the owner's look.** No blocking deviation is left: every screen uses the
shared components and tokens only, every screen edits a record in the MasterDetail panel, all three languages
render, and both themes render. The open items below are known gaps for the owner to weigh; none of them breaks
a screen.

## How it was checked

- Screenshots: `web/scripts/screenshot.sh --all <screen>` for each harness screen below, 12 files each
  (1440 and 390 wide, light and dark, en, ru, kk), named `<screen>-<lang if not en>-<theme>-<width>.png`. They are
  kept in the task folder (`shots/`), not in the repo. Russian and Kazakh are rendered through the harness `?lang=`
  parameter, which drives the platform language store of T-1180 (the same store the TopBar `LanguageSwitcher`
  writes); the screens switch language at once, no reload.
- Contrast: `python3 -I letflow-design/core/tools/contrast.py platform` ends with `FAILURES: 0`.
- Colours and inline styles: `grep -rnE "#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\("` and `grep -rn "style="` over
  `web/src/modules/org`, `web/src/modules/locations`, `web/src/modules/codes`, `web/src/modules/catalog_items`,
  `web/src/pages/admin/import`, `web/src/components/layout/AppShell.tsx`, `web/src/components/ui/TopBar.tsx` and
  `web/src/components/ui/MasterDetail.tsx` (tests excluded): no hit for either.

| Screen | Task | Harness screens shot |
|---|---|---|
| S1 legal companies, sites, org unit tree | REQ-669 | `org-legal`, `org-sites`, `org-units` |
| S2 positions, employees | REQ-670 | `org-positions`, `org-employees` |
| S3 location tree | REQ-671 | `locations` |
| S4 codes | REQ-672 | `codes-detail` |
| S5 lots | REQ-673 | `catalog-items-lots-edit` |
| S6 Excel import | REQ-675 | `master-data-import` |
| App shell (TopBar, language switch) | T-1180 | `topbar-language` |

## Fixed in this task

| What | Rule | Where | Screenshot |
|---|---|---|---|
| The design repo's new class `lf-btn-row--between` brought in by a refresh (`release.sh platform` for `web/src/styles/components.css`, `scripts/sync-design-system.sh` for `web/public/design-system/`); no hand edit | D-080/D-081 | `web/src/styles/components.css`, `web/public/design-system/` | — |
| The "Show retired" + count row now pushes the count to the right with `lf-btn-row--between` (org screens) | 1, reference `examples/org-units.html` | `web/src/modules/org/OrgScreen.tsx` | `org-units-light-1440.png` |
| The same row on the location tree: the count sat next to the label; now right-aligned like the reference | 1 | `web/src/modules/locations/LocationTreePage.tsx` | `locations-dark-1440.png` (before) |

Tests: `orgScreens.states.test.tsx` and `LocationTreePage.test.tsx` ("builds the Show retired row with
lf-btn-row--between and no inline style"), `tests/unit/designSystemCopy.test.ts` (the app's `components.css` equals
the released copy and has the class).

## Rule 2a: editing in the detail panel

| Screen | Edits in the MasterDetail panel | Panel stays open across rows, close button, Escape | Dialogs used for |
|---|---|---|---|
| S1 legal companies, sites, units | yes | yes (`orgScreens.states.test.tsx` "S1 panel") | Move (units), ConfirmDialog for Retire |
| S2 positions, employees | yes | yes (shared `OrgScreen`) | Transfer (employees), ConfirmDialog for Retire |
| S3 locations | yes | yes (`LocationTreePage`, Escape unless a dialog is open) | Move, ConfirmDialog for Retire |
| S4 codes | yes | yes (`CodesPage`, Escape closes) | Receive codes, Assign, ConfirmDialog for Retire |
| S5 lots | yes (create and edit) | yes (`LotsPage`) | ConfirmDialog for Retire only |
| S6 import | not a record editor (a four-step wizard) | — | — |

No screen edits a record in a modal.

## Checked (owner decisions of 2026-11-03, task T-1181)

- A new child org unit starts with the parent's legal company and the parent's site, both editable; a root starts
  empty; an existing unit shows its own values (`UnitsPage.test.tsx`: "pre-fills the parent company for a child,
  stays editable, saves the chosen value", "saves the pre-filled company unchanged", "starts empty for a root, and an
  existing unit shows its own company").
- Moving a unit sends only `parent_id`; it changes nothing about its company or site (`UnitsPage.test.tsx`: "edits in
  the panel, moves (also to the root) and retires").
- Language: the org module (and the other modules) follow the platform language store of T-1180 at once
  (`orgLanguageSwitch.test.tsx`, `locationsLanguageSwitch.test.tsx`); the S1 note that the org module read its
  language from the browser no longer holds.

## Open items (not fixed here; owner note on each)

| # | Item | Rule | Screenshot | Owner note |
|---|---|---|---|---|
| 1 | `ToastContainer` is mounted per screen (`OrgScreen`, `LocationsShell`, `CodesPage`, `MasterDataImportPage`, in its loading and its main branch) instead of once in the app shell | 3 | — | Move it into the shell in one follow-up task; a toast fired during a route change can be lost today. |
| 2 | `FetchError` and `SkeletonLayout` (`web/src/components/ui/`, reached through `QueryStateBoundary`) still use inline styles and legacy (bridged) tokens | 1 | — | Restyle with `Banner` and `Skeleton` before the legacy bridge is removed. |
| 3 | Reference features not built because the API has no data for them: tree search, per-unit counts, tabs in the unit panel, the external-id field | — | `org-units-light-1440.png` | Needs API work first; product decision on order. |
| 4 | Under 900 px the detail panel is shown below the list, not over the whole screen as rule 2a asks | 2a | `org-units-kk-dark-390.png`, `codes-detail-kk-dark-390.png` | `MasterDetail` change (one component, all screens); kept out of a style-check task. |
| 5 | Lots: the master table in the narrow left column cuts the status column (`Бел…`) with no sign it scrolls | 4 | `catalog-items-lots-edit-kk-light-1440.png` | Drop the status column when the panel is open, or let the table scroll visibly; the system is silent on column hiding. |
| 6 | Positions and employees: long names and codes truncate in the master list because the unit name (meta, mono by `components.css` `.lf-tree__meta`) takes the right side | 4 | `org-positions-kk-light-1440.png`, `org-employees-ru-light-1440.png` | The mono meta is the design repo's rule; whether a unit name (not a code) should be mono is a design-repo question. |
| 7 | Codes, 390 dark: a light vertical strip right of the code list (the table wrapper's scroll track) | 7 (dark theme) | `codes-detail-kk-dark-390.png` | Small; needs a look at the table wrapper overflow on narrow screens. |
| 8 | Codes, 390: the search placeholder is cut in Kazakh and Russian | 4 | `codes-detail-kk-dark-390.png` | A shorter placeholder text in the catalog, or the field full-width; translator's call. |
| 9 | Lots: the native date input shows the browser's own format (`11 / 20 / 2026`) whatever the language | 4 | `catalog-items-lots-edit-kk-light-1440.png` | The browser's date control follows the browser locale; a custom date field would be a new component. |
| 10 | The harness renders the screens without the sidebar of `AppShell`; the shell is checked through `topbar-language` only | 8 | `topbar-language-ru-light-1440.png` | Add an app-shell harness screen when the sidebar is restyled. |
