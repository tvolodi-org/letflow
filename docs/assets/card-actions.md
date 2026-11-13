# Asset card actions from the UI (T-1880, owner decision D-135)

Every operation on a fixed asset card starts from the UI, not from a typed address. This is part 1 of D-135:
the Actions menu on the card panel and on each card-list row, the button row on the card panel, the pre-filled
document form and the way back to the card. Multi-select (part 2) and "Documents of this card" (part 3, needs a new
`asset` filter on `GET /documents` with its own security review) are not delivered here.

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

With no `AssetsPost` the menu trigger and the button row are not rendered.

## 4. Pre-fill contract

Address: `/admin/assets/documents/new?kind=<kind>&asset=<card id>`. Part 1 sends one `asset`; part 2 repeats it (up to
100, repeats dropped). Kinds: `commission | change | handover | writeoff`. With `kind_change`, `asset` is ignored.

The form opens as a **draft that is not saved**: the card is a line; nothing is sent until Save, and issuing stays the
document view's action.

| Kind | Lines | Header |
|---|---|---|
| commission | the card, quantity 1 | `org_unit_id` of the card when it has one; the rest empty |
| change | the card; quantity 1 for fixed and intangible, else the holder row's quantity | From side = the single holder row; To empty |
| handover | as change | From side = the holder row; To unit and place copy From until touched |
| writeoff | as change | the one side = the holder row |

With more than one holder row the header stays empty and the form shows a banner; the line is still filled.
After Save from a one-card form the view opens as `/admin/assets/documents/<id>?card=<card id>` with **Back to card**
(`/admin/assets/cards?card=<card id>`).

**Change of kind is not a per-card action.** The document turns stock into a NEW card: the card is the server-set
output `asset_card_id`, so an existing card cannot be its line (`change-of-kind.md` section 1). It is a page button
"Change of kind (from stock)" on the card screen.

## 5. Extension (Opening, Count)

The actions are one table, `CARD_ACTIONS` in `cardActions.ts`: `id`, document `kind`, label id, permission atom and a
pure `rule(facts)`. The panel menu, the row menu and the button row render from it. Opening is one more entry plus its
row in `cardPrefill.ts`; Count (another module's document) is an entry with an `href` builder instead of a `kind`.

## 6. No-typed-URL audit (owner walk `project/walkthrough-gates-cde.md`)

| Walk step | Typed address today | Reachable after | Who |
|---|---|---|---|
| C2, C3 commission, change, hand over, write off | `/admin/assets/documents/new?kind=...` | Documents screen "New <kind>" (T-1875) and card Actions menu / buttons | T-1875 + this task |
| C4 change of kind | `.../documents/new?kind=kind_change` | Documents "New change of kind"; card screen button | T-1875 + this task |
| E2 saved report | `/entities/assets_card/reports` | left menu Reports | T-1874 |
| C7 groups switch | `/admin/groups` | menu Tenant administration, Groups | already |
| Back from a document to its card | none | "Back to card" | this task |
| Opening balances | opening screen | menu | T-1877 |
| Documents of a card | none | "Documents of this card" block | part 3 (follow-up) |

The runbooks (`docs/runbooks`, `docs/assets`) contain no typed `/admin/assets` address. Part 4 (audit fixes) has no
open item.
