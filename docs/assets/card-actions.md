# Asset card actions from the UI (T-1880, T-1904, owner decision D-135)

Every operation on a fixed asset card starts from the UI, not from a typed address. Part 1 (T-1880) delivered
the Actions menu and the pre-filled document form (the card-panel button row was removed in T-1954; the Actions menu in the card header is the one panel entry). Part 2 (T-1904) delivered
multi-select with an action bar and the back link with the card number. "Documents of this card" (part 3, needs a
new `asset` filter on `GET /documents` with its own security review) is not delivered yet.

## 1. Card status and the facts it is read from

| Fact | Source (read) | Server rule it mirrors |
|---|---|---|
| active | card `field_values.active` | `card_not_active` (every kind) |
| kind | card `field_values.kind` | `asset_already_in_register` applies to fixed and intangible only |
| held | `GET /cards/:id/lock` field `held` (new, `Checks.held?/2`) | `asset_already_in_register` (commission) |
| holder rows | `GET /balances?asset=<id>` (non-zero rows) | the ledger balance at posting (change, hand over, write off) |

Statuses, derived in this order (`cardStatus` in `web/src/modules/assets/cardActions.ts`):

| Status | Condition |
|---|---|
| `retired` | `active` is false |
| `held_pending` | fixed or intangible, `held` true, no holder rows (issued commission, not posted yet) |
| `in_register` | at least one holder row (also when `held` is stale or missing) |
| `new` | none of the above (never commissioned, or the commission was reversed) |

## 2. Status x action

| Status \ action | Commission | Change responsible | Hand over | Write off |
|---|---|---|---|---|
| `retired` | disabled: retired | disabled: retired | disabled: retired | disabled: retired |
| `new` | allowed | disabled: not in register | disabled: not in register | disabled: not in register |
| `held_pending` | disabled: held | disabled: pending posting | disabled: pending posting | disabled: pending posting |
| `in_register`, fixed or intangible | disabled: held | allowed | allowed | allowed |
| `in_register`, low value | allowed (adds quantity) | allowed | allowed | allowed |
| AssetsRead missing | disabled: no read | disabled: no read | disabled: no read | disabled: no read |

- `held` is the server's own rule (`Checks.held?/2`, the source of `asset_already_in_register`), so the UI never offers
  a commission the server refuses for that reason.
- Change, hand over and write off have no issue-time balance check on the server; the posting is the arbiter. The UI
  rule reads the same ledger balance. A balance that changes between the read and the posting is refused at posting as
  today (this race stays).
- Refusals that depend on the header the user picks (`org_unit_mismatch`, location rules, `sides_equal`, inactive
  employees) are shown by the form next to the field; they do not disable a card action.
- Reverse is not a card action; it belongs to the posted document (`AssetsReverse`).
- A disabled action is shown greyed with its reason as tooltip and as text on touch.

## 3. Permission per action (atoms only; the web asks `can(atom)`)

| Action | Shown when | Server permission |
|---|---|---|
| Commission, Change responsible, Hand over, Write off | `can(AssetsPost)`, else hidden | `POST /documents` `AssetsPost` |
| Status facts | `can(AssetsRead)`, else every action disabled "no read" | `GET /cards/:id/lock`, `GET /balances` |
| Change of kind (from stock), page button | `can(AssetsPost)` | `POST /documents` `AssetsPost` |
| Edit, Retire (existing) | card route `AssetsCardWrite` | `PATCH /cards/:id`, `POST /cards/:id/retire` |
| Back to card | `can(AssetsCardWrite)` | none |

With no `AssetsPost` the menu trigger is not rendered.

## 4. Pre-fill contract

Address: `/admin/assets/documents/new?kind=<kind>&asset=<card id>`. Part 2 repeats `asset` for multi-select (up to
100, repeats dropped). Kinds: `commission | change | handover | writeoff`. With `kind_change`, `asset` is ignored.

The form opens as a **draft that is not saved**: the card is a line; nothing is sent until Save, and issuing stays the
document view's action.

Cards that are not found in the read (deleted, foreign id) are dropped; the form shows a notice for each missing card.
The found cards feed the line editor's catalog directly so the Asset cell shows the card before the picker list loads.

| Kind | Lines | Header |
|---|---|---|
| commission | each card, quantity 1 | `org_unit_id` of the card when ALL cards share one; the rest empty |
| change | each card; quantity 1 for fixed and intangible, else the holder row's quantity | From side = the single common holder row of all cards; if two cards have different holders, the header stays empty with a notice |
| handover | as change | From side = the common holder row; To unit and place copy From until touched |
| writeoff | as change | the one side = the common holder row |

With more than one holder row for one card the header stays empty and the form shows a banner; the lines are still
filled. When two or more cards have different holders, the form shows a "different holders" banner; the lines are filled.
After Save, the view opens as `/admin/assets/documents/<id>?card=<id1>&card=<id2>…` with a **Back to card** link
(single card: "Back to card `<number>`" → `/admin/assets/cards?card=<card id>`; multiple cards: "Back to asset cards"
→ `/admin/assets/cards`).

**Multi-select on the card list (T-1904):** a checkbox column (only with AssetsPost) lets the user tick up to 100 cards.
An action bar "N selected" shows four action buttons. An action is allowed only when it is allowed for every chosen
card; otherwise the first blocker's reason is shown with the card number. Opening the action sends all card ids as
`?asset=` params to the document form.

**Change of kind is not a per-card action.** The document turns stock into a NEW card: the card is the server-set
output `asset_card_id`, so an existing card cannot be its line (`change-of-kind.md` section 1). It is a page button
"Change of kind (from stock)" on the card screen.

## 5. Extension (Opening, Count)

The actions are one table, `CARD_ACTIONS` in `cardActions.ts`: `id`, document `kind`, label id, permission atom and a
pure `rule(facts)`. The panel menu and the row menu render from it. Opening is one more entry plus its
row in `cardPrefill.ts`; Count (another module's document) is an entry with an `href` builder instead of a `kind`.

## 6. No-typed-URL audit (owner walk `project/walkthrough-gates-cde.md`)

| Walk step | Typed address today | Reachable after | Who |
|---|---|---|---|
| C2, C3 commission, change, hand over, write off | `/admin/assets/documents/new?kind=...` | Documents screen "New <kind>" (T-1875) and card Actions menu | T-1875 + this task |
| C4 change of kind | `.../documents/new?kind=kind_change` | Documents "New change of kind"; card screen button | T-1875 + this task |
| E2 saved report | `/entities/assets_card/reports` | left menu Reports | T-1874 |
| C7 groups switch | `/admin/groups` | menu Tenant administration, Groups | already |
| Back from a document to its card | none | "Back to card" | this task |
| Opening balances | opening screen | menu | T-1877 |
| Documents of a card | none | "Documents of this card" block | part 3 (follow-up) |

The runbooks (`docs/runbooks`, `docs/assets`) contain no typed `/admin/assets` address. Part 4 (audit fixes) has no
open item.

## Card tabs (T-1954)

The card panel has two tabs under the header (`DetailTabs`, ids scoped per pane): **Main** (identity: number, name,
kind, then the Holder block with org unit, location, responsible, user, quantity) and **Accounting** (acquisition date,
currency, valid until, cost and depreciation fields, then the read-only depreciation block). A retired card shows the
same split as read-only facts. One form spans both tabs, so one Save sends one PATCH; a refused Save or a server error
on a field of the other tab switches to that tab and focuses the field. The chosen tab survives row clicks and Save and
resets to Main when the panel closes. The create form has no tabs. The Actions menu and Retire stay in the card header.

**Official form (T-1924).** The card header also holds the "Official form" menu (`AssetFormMenu`, the one of the document
screen) with the DA-2 / ҰМА-2 inventory card as .docx and PDF, shown with `AssetsRead` (atom, not role), for active and
retired cards. It calls `GET /cards/:id/print`; an error shows as a banner on that card only. Not in the row menu.

Documents of this card and History are not on the card yet: they need the part 3 backend reads (`asset` filter on
`GET /documents` and on `GET /movements`).
