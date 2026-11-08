# Asset register: the asset card and the asset ledger registration

Status: specification, not built (REQ-689, GH #3723, assets phase C item C1). Docs only: no code, no
migration, no definition JSON, no pack, no test, no seed, no route, no screen. The module, its record type, its
ledger registration and its documents are later requirements, written from this file after the owner's gate of
phase B (D-063, D-085).

Sources: owner decisions D-061, D-062, D-063, D-065, D-067, D-085 and D-097 (2026-11-05) in `ai-dala-portfolio/DECISIONS.md`;
`ai-dala-portfolio/architectures/assets.md` (table under "The model", section "The gray zone", review findings 3
to 7); `letflow-team/project/assets-gap-analysis.md` (section 1); decisions 0050 (D6), 0051 (M4), 0073 (with its
section "Amended (REQ-676, assets B1)") and 0076 (R1, R4, R6, R7) in `docs/migration/decisions/`; the design note
`lib/letflow/design/gh2657-wms-stock-ledger-core.md` (sections 4.5 and 14.3 rule 12); and the requirement entry
REQ-689 in `docs/requirements.yaml`.

Marks used below: **proposal** = the business analyst's proposal for UAT, to be confirmed by the owner at the
gate of phase C. **UAT assumption** = an assumption to be confirmed by the process owner. **D-097** = a decision of the owner dated
2026-11-05, later than REQ-689; where REQ-689 leaves the currency or the uniqueness scope of `inventory_number`
open, D-097 supersedes that wording and is stated as decided below.

## 1. Module

The asset register belongs to a new module with module id `assets` (D-061: Asset Management is its own module,
not part of the stock module). Its manifest `depends_on` lists `org` and `locations` and no consumer module
(decision 0076 R1: consumers depend on master data, never the reverse; R4: master data is read through the owning
module's read API). Its one record type is `assets_card` (the module-id prefix rule of decision 0050 D6).

The module skeleton exists since REQ-748 (GH #3894): `lib/letflow/modules/assets/assets.ex`, the pack under
`priv/modules/assets/`, the record type `assets_card` and the `currency` setting. It has no ledger, no route and no
permission yet.

## 2. The three kinds

Each meaning below is a **proposal**, to be confirmed by the owner at the gate of phase C.

### 2.1 fixed

A fixed asset is one physical object kept on the balance. It has a location and a quantity of at most 1.
**Proposal**, to be confirmed by the owner at the gate of phase C.

### 2.2 low_value

A low-value asset is written off from the balance but still tracked (off-balance, assets.md "The gray zone"),
and may be counted by quantity (for example 200 identical chairs, review finding 5). Kind `low_value` is the
off-balance flag; there is no second flag field. **Proposal**, to be confirmed by the owner at the gate of phase C.

### 2.3 intangible

An intangible asset is a license or subscription, kept on the balance, with no location (review finding 6: the
location dimension is left empty). **Proposal**, to be confirmed by the owner at the gate of phase C.

### 2.4 Boundary to the stock register

One rule: an item counted one by one because it is valuable, while it is still stock, is an Inventory Object of
the stock register (D-065: its own record type, no entry yet); an item written off from the balance but still
tracked is a `low_value` asset card (assets.md review finding 3).

## 3. The asset card

Record type `assets_card`. Field types come from the closed list `@field_types` of
`lib/letflow/entities/definition/validator.ex` (string, integer, decimal, boolean, date, datetime, enum, json,
localized_text).

| Field | Type | Required | Refers to | Note |
|---|---|---|---|---|
| inventory_number | string | required | none | unique per tenant (decided, D-097) |
| name | string | required | none | |
| kind | enum | required | none | values `fixed`, `low_value`, `intangible` |
| org_unit_id | string | required | org_unit record (module org) | the org unit that holds the card; a cross-pack declarative id checked in write logic (decision 0076 R6 rule 5) |
| acquisition_date | date | optional | none | the real receipt date, kept as a field because the ledger refuses an event time older than 96 hours (0073 D-T) |
| currency | string | optional | none | one currency per tenant, KZT by default (D-097); see section 6. Empty means the tenant currency |
| acquisition_cost | decimal | optional | none | `decimal_strict` true; information only (section 6) |
| accumulated_depreciation | decimal | optional | none | `decimal_strict` true; information only |
| book_value | decimal | optional | none | `decimal_strict` true; information only |
| depreciation_as_of | date | optional | none | information only |
| valid_until | date | optional | none | allowed only when kind is `intangible` |
| active | boolean | required | none | false retires the card; there is no delete (REQ-748; asset-workflow-documents.md section 7 checks it before a posting) |
| external_ref_system | string | optional | none | unique as a pair with external_ref_id |
| external_ref_id | string | optional | none | unique as a pair with external_ref_system |

Every decimal field has `decimal_strict` true (`lib/letflow/design/gh2654-decimal-exact-strings.md`).

The card has no location, materially responsible person, actual user or quantity field. Those values live only in
the register (section 4), so the card and the register cannot disagree. The kind of a card does not change once
the card has a posting.

## 4. The register: ledger registration

| Item | Value |
|---|---|
| ledger_ids | `{:fixed, ["assets"]}` (0073 D-L3: one fixed ledger id per tenant) |
| slot 1 `asset` | format `:uuid`, required true (the assets_card record id) |
| slot 2 `org_unit` | format `:uuid`, required true |
| slot 3 `location` | format `:uuid`, required false |
| slot 4 `material_responsible` | format `:uuid`, required true |
| slot 5 `actual_user` | format `:uuid`, required false |
| scope_slot | `org_unit` |
| key_bounds | empty |
| units allowlist | the one token `pcs`, so every leg's unit_ref is `pcs` (UAT assumption, to be confirmed by the process owner); the quantity is a whole number checked by the module (section 5) |
| max_event_lateness_hours | 96 |
| error_aliases | empty |
| permission atoms | four distinct atoms `AssetsPost`, `AssetsReverse`, `AssetsRead`, `AssetsReconcile`, no role grants (as REQ-687 does for the stock atoms) |
| causes | not listed here; they are those of item C2 |

Reasons for the order of the slots:

- Slot 1 must be non-empty (CHECK `k1_present` in migration `20261031100001_create_ledger_tables.exs`; slots
  k1..k8 are text NOT NULL DEFAULT ''), and the asset is the one dimension every leg has.
- The sign rule `zero_sum_by_slot_1` then conserves the quantity per asset on a two-leg move.
- `org_unit` in slot 2 lets the existing (ledger_id, k2, k1) indexes of that migration serve the reads by org unit.
- The slot order is append-only and cannot change later (design note section 4.5 and rule 12 of section 14.3).

Terms (REQ-643 point 3, D-065): `material_responsible` and `actual_user` are both `org_employee` record ids,
never a Letflow user id. Unused slots are the empty string (note section 4.5).

## 5. Per-kind rules the register cannot express

A key bound applies to one balance key (note section 4.5), and a bound on the asset slot would also cap low-value
quantities, so there is no key bound. Instead the assets module's own write path checks the following before it
posts (0073 D-P: `declare/2` reads no master data). For every leg:

1. The asset card exists, and its kind is read.
2. The quantity is a whole number.
3. For kind `fixed` and `intangible`, the total quantity of the asset over all its balance rows after the posting
   is 0 or 1.
4. For kind `fixed` and `low_value`, the location slot is a location for which
   `Letflow.Modules.Locations.active?/2` is true, and `Letflow.Modules.Locations.linked?/3` is true for the leg's
   org unit (D-065: a movement whose org unit and location are not linked is refused).
5. For kind `intangible`, the location slot is the empty string and no link check runs.
6. The org unit is a live active org_unit: `Letflow.Modules.Org.lookup/2` answers entity_type `org_unit` and
   `Letflow.Modules.Org.active?/2` is true (`active?/2` alone is true for an active record of any of the six org
   types).
7. `Letflow.Modules.Org.active_employee?/2` is true for the materially responsible person and, when the slot is
   not empty, for the actual user.

A failed check posts nothing. These checks are run by the documents of item C2, which this file does not specify.

## 6. Depreciation and money

`acquisition_cost`, `accumulated_depreciation`, `book_value` and `depreciation_as_of` are information typed by a
user or imported (item C4), never calculated by the product in the first version (assets.md, D-061). They are
never a ledger slot, a leg column, a leg attrs key or a balance column (assets.md review finding 4). No process
definition, trigger or script of the assets module writes them. A change of these fields is a card update recorded
in the audit trail, not a posting. Currency (D-097, which supersedes the
REQ-689 criterion 7 wording that gives the currency no answer of its own): there is one currency per tenant, KZT by
default. The `currency` field of the card is kept. Reading chosen here: the tenant holds the one currency in a
setting with default KZT, the card field `currency` (string, optional) is kept for information and for the xlsx
import (item C4), and write logic refuses a value that differs from the tenant currency; empty means the tenant
currency. The product never converts between currencies. The money fields stay information only.

## 7. Quantity and access

*Opening document (decision 0083, G5 part 1 built, GH #4037): existing cards can be drafted and checked on an opening document (`kind: opening`); it does not post yet, so no asset enters the register through it until part 2.*

### 7.1 Quantity

The quantity of an asset is the sum of its balance rows in the register (`on_hand`), not a card field. A
`low_value` card counts many identical objects (review finding 5), and its quantity may be split over several
balance rows (for example 150 chairs in one room under one materially responsible person and 50 handed to an
actual user). A `fixed` or `intangible` card has at most quantity 1 in total (section 5). Zero is a written-off or
not yet commissioned asset whose card stays (D-061: registers are read-only and corrected by new entries).

### 7.2 Access

- `assets_card` has the scope declaration `{:column, "org_unit_id"}` (decision 0076 R7: asset cards scoped by org
  unit; D-067), immutable once set (decision 0051 M4).
- Balances and movements of the asset ledger are scoped by the scope slot `org_unit` (0076 R7). Their scoped read
  is item B6 (REQ-682).
- A scoped principal cannot post until slice L6 (0073 OQ-21).
- For a `fixed` or `intangible` asset the card's `org_unit_id` equals the `org_unit` slot of the asset's balance
  row with quantity 1, kept equal by the documents of item C2 in the same transaction as the posting.

## 8. Open owner questions

No answer is given here to any of them.

1. Decided by D-097: one currency per tenant, KZT by default, the `currency` field is kept (section 6). Only the
   reading in section 6 (tenant setting plus a card field that must match it) is left for the owner to confirm.
2. Whether the actual user may be empty. This file proposes optional (UAT assumption). Source: REQ-689 criterion 10.
3. Which unit holds the card of a low-value asset whose quantity is split over balance rows of several org units,
   and whether the other unit sees the card. Source: section 7.1 and 0076 R7. **Marked for the owner** (T-1486,
   2026-11-08): still unanswered. The commission refuses a card of another org unit (`org_unit_mismatch`), and the
   asset opening document of decision 0083 keeps that rule (its Q3); a hand over of part of a low-value quantity to
   another org unit is not refused today (`Letflow.Modules.Assets.Documents.Checks`: the hand over runs no
   `org_unit_mismatch`), so the split can already arise and the card then keeps its first org unit.
4. Whether an intangible card may carry more than one seat. This file proposes at most 1 per card (UAT
   assumption). Source: REQ-689 criterion 10.
5. Decided by D-097: `inventory_number` is unique per tenant (also with several BIN in one tenant, D-062). Old
   assets come in by the xlsx import (item C4).
6. The role grants of the four permission atoms (0073 OQ-11 decided no grants for the stock atoms in REQ-687).
7. The meanings of the three kinds and the Inventory Object boundary (sections 2.1 to 2.4), to be confirmed at the
   gate of phase C.

## 9. Out of scope

The asset documents and their causes (commissioning, change of responsible or user, hand over, write off, expiry
reminders: item C2); the change of kind from stock to asset in one transaction (item C3, under 0073 A2); xlsx
import and export of assets including depreciation (item C4); opening balances of old assets (item B3, REQ-677);
the scoped read of balances (item B6, REQ-682); the speed test (0073 A7); printed forms and government lists
(phase E); depreciation calculation (not in the first version); period close (D-062: not part of this product).
