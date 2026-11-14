# Page header actions, filters and the "New" menu

Rule for every list, register, work-list and document screen of `web/` (T-1953, owner instruction via the PM,
2026-11-14). The inventory that led to it is `list-screen-layout-audit.md`. A screen that differs from this rule is
either fixed or named in that audit.

**R1. Page header.** The screen starts with the page header component (`PageHeader`; `PageLayout`'s header on screens
not yet moved to `PageHeader`): title on the left (eyebrow, title, one-sentence lede), the screen's actions on the
**right**. Order of actions from left to right: help link, ghost or secondary actions (reset layout, import, export, a
second creation entry such as "Change of kind" on asset cards), and the **primary action last** (right-most). At most
one primary action.

**R2. Creation lives in the header.** A screen-level creation action (create a record, start a new document) is a header
action. It is never placed in the list pane (`lf-reg__listhead`, `lf-reg__tools`, `lf-doc__tools`, the `ListDetail`
`listHeader` and `tools` slots, `RegistryList` `headAction`). Three exceptions, which are not screen-level and stay where
they are: an empty state may repeat the header's action as its one call to action; a record-scoped "add child" in the
detail panel (locations, org units); "add line" inside a document form.

**R3. Kinds.** One or two creation kinds: one button each (primary for the main one, secondary for the other). Three or
more kinds: **one** `NewMenu` (`web/src/components/ui/NewMenu.tsx`) in the header, labelled "New document" /
"Новый документ" / "Жаңа құжат" or the module's own label, listing the kinds by their kind name in the module's
canonical order. Choosing one opens that kind's create form (`.../new?kind=<kind>`). The create route falls back to the
default kind for an unknown `kind`, and the form keeps its kind select.

**R4. Filters** sit directly under the header. On a `ListDetail` or `DocLayout` screen that is the **list pane head**
(`tools` gives `lf-reg__tools`; `lf-doc__tools` on document screens), so the filters scroll and collapse with the
list. On a single-column page (`PageLayout`) it is a `FilterBar` right below the header.

**R5. Keyboard and accessibility** (kept from the existing menus). The trigger is a `button` with `aria-haspopup="menu"`
and `aria-expanded`. The list is `role="menu"` named by the trigger label; items are `role="menuitem"` links
(`href="#"`, default prevented). Enter, Space or a click on the trigger toggles it. ArrowDown/ArrowUp on the closed
trigger open the menu and focus the first/last item. Arrows move with wrap, Home/End jump, Enter/Space choose. Escape
closes and returns focus to the trigger; Tab closes; a mousedown outside closes. A disabled item shows its reason as
visible text and chooses nothing. Visible focus comes from the global `:focus-visible` outline. Labels come from the
caller's en/ru/kk catalog; the component has no text of its own.

**R6. Phone (up to 640 px).** Header actions take the full width (`components.css`); the `NewMenu` wrapper takes the same
width (`base.css`, `.lf-newmenu`) and its menu flips to start alignment when it would leave the screen.

**R7. Guard.** `create-in-list-pane` in `web/tests/guards/forbidlist.ts`: a file that draws a list pane class
(`lf-doc__list`, `lf-doc__tools`, `lf-reg__list`, `lf-reg__tools`, `lf-reg__listhead`) must not contain, after that
class, a `<Plus>` icon, a `<NewMenu>` or a `/new` route literal. The exception list (`allowedPaths`) is a ratchet: it
only shrinks, and each entry carries a reason. It is empty now. **Limitation:** a create button handed to `ListDetail`'s
`tools` or `listHeader` props from a file that does not name the pane classes is not caught; review covers it. Keep the
pane class names out of file comments above a `/new` literal (the scan is textual).

Legacy admin screens with hand-made header rows (Users, Groups, Tokens, Audit, Tenants, Instances board) already put
the action on the right; moving them to `PageHeader` and their English-only labels to the catalogs is a follow-up.
