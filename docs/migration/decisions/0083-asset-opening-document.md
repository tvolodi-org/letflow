# 0083 — Asset opening document: existing assets enter the books without backdating

Status: proposed (2026-11-08, REQ-782, assets gap G4 of the gate C walk). The owner accepts it at the gate of phase C
(D-063). Specification only: no code, no migration, no definition JSON, no route, no screen, no test, no seed. The
document is built by later requirements (section D9).
**REVIEWER sign-off: PENDING** (placeholder, the PR carries the verdict).

Bucket **B** (generic platform capability: any tenant that keeps assets and starts using the product brings assets it
already holds; nothing here names a customer).

Sources: the BA decision for UAT `docs/uat/ba-decisions/T-1486.md` (owner question of the gate C walk, 2026-11-08;
sections 2 and 3 and the gap table row G4); owner decisions D-061 (two read-only registers, corrections by new
entries; depreciation is an information field, imported, not calculated), D-062 (documents fixed once signed, no period
close) and D-097 (inventory number unique per tenant; old assets arrive by the xlsx import), as restated in
`docs/assets/asset-register.md` and `docs/assets/asset-workflow-documents.md`; decision 0073 (D-T, D-L12) and decision
0079 (D1 to D6, Q4) in `docs/migration/decisions/`; `docs/assets/asset-register.md` (sections 3, 4, 5, 7 and 8);
`docs/assets/asset-workflow-documents.md` (sections 1.1, 1.3, 1.4, 7 and 8); `docs/assets/asset-xlsx.md` (sections 4,
5 and 8); `docs/assets/stock-workflow-documents.md` section 4a. Code read on origin/main 7fe7a63e3:
`lib/letflow/modules/assets/assets.ex` (manifest: causes `commission`, `change`, `handover`, `writeoff`,
`kind_change_in`; `max_event_lateness_hours: 96`; permissions `AssetsPost`, `AssetsReverse` with no role grants),
`lib/letflow/modules/assets/documents/kinds.ex` (the closed kind table), `lib/letflow/modules/assets/documents/checks.ex`
(`masters/2`, reasons `card_not_active`, `duplicate_asset`, `quantity_invalid`, `org_unit_mismatch`,
`location_required`, `location_not_allowed`, `not_linked`, `asset_already_in_register`),
`lib/letflow/modules/assets/documents/shape.ex` and `lib/letflow/modules/assets/ledger_policy/declare.ex` (`@max_lines
100`), `lib/letflow/modules/assets/router.ex` (the `/documents` routes: save, replace, discard, issue, reverse, list,
fetch; no check and no cancel route), `lib/letflow/ledger.ex` (`stamp_event_times`: the event time is the client event
time or, without one, the posting time), `priv/modules/stock/generate_pack.exs` (the `stock_opening` process: `submit`,
then `approve` with `distinct_from ["submit"]`), `lib/letflow/engine/separation_of_duties.ex`.

Marks used below: **proposal** = the business analyst's proposal, to be confirmed by the owner at the gate of phase C.
**UAT assumption** = an assumption to be confirmed by the process owner.

## 0. Why

An enterprise that starts using the product holds assets bought years ago. Today an asset reaches the register only by
a commission document (or, for an item that was stock, by a change of kind). The commission's event time is its header
`event_time`, and the ledger refuses an event time more than 96 hours before the posting time (`event_time_too_old`;
0073 D-T: default 96, at most 720 by rule 12, no tenant or operator override and no runtime setting). So a commission
cannot carry the real acquisition date of an old asset. A commission dated today would be accepted, but it would show a
2019 asset as commissioned today in the movements report and mix real purchases with cut-over entries (T-1486
section 3). The stock register has the same problem and solved it with an opening document (0079 D1 to D6; built as
`stock_opening`, `docs/assets/stock-workflow-documents.md` section 4a). 0079 Q4 left open whether the asset register
reuses it. This record answers: yes, as a separate asset document kind with the same rules.

## D1. No backdating

- The opening posting carries no client event time: the posting command has no `client_event_time`, so the ledger
  stamps the event time equal to the posting time (`stamp_event_times` in `lib/letflow/ledger.ex`), as 0079 D1 does for
  stock. The opening header has no `event_time` field.
- The real acquisition date is the card field `acquisition_date` (asset-register.md section 3), which already exists
  for this reason. The opening line carries no date of its own.
- Consequence for reports: a balance as of an event time before the opening posting shows no quantity for the asset
  (0079 D1, same reasoning). The opening is visible from the day it is posted.

## D2. The card exists first; the opening places it

- **An opening line names an existing asset card** (`asset_id`, the `assets_card` record id), as the commission line
  does. It does not create a card. Cards of old assets come in by the card import of `docs/assets/asset-xlsx.md`
  (REQ-762, built, 200 rows per file, upsert by external ref) or are typed on the card form; this matches D-097 ("old
  assets arrive by the xlsx import").
- Reason (deviation from the proposal in T-1486 section 3, where the posting creates the card): the card import already
  carries every card field, depreciation included (asset-xlsx.md sections 2 and 5), so a line that created cards would
  repeat it. And with the card first, the opening line needs no price or value field, so the rule "No document carries
  a price or value field" (asset-workflow-documents.md section 1.3; assets.md review finding 4) holds without an
  exception. T-1486 listed that exception as an assumption; this record removes the need for it.
- Two steps for the user: import (or type) the cards, then import (or type) the opening lines that place them. An
  imported card has quantity 0 until it is placed (asset-xlsx.md section 4).

## D3. The document

A sixth kind `opening` of the asset documents (the closed table of `Letflow.Modules.Assets.Documents.Kinds`), on the
existing `/documents` routes of the assets module.

| Item | Value (proposal) |
|---|---|
| header record type | `assets_opening` |
| line record type | `assets_opening_line` |
| versioned document type | `assets_opening`, number prefix `AOP` |
| process definition | `assets_opening` (D5) |
| ledger cause | `opening`, sign rule `positive`, `reason_required` false; one `+quantity` leg per line |
| scope declaration | `{:column, "org_unit_id"}` on header and line (decision 0076 R7, D-067), the line carrying a copy of the header org unit as the other asset kinds do |

Header fields:

| Field | Type | Req. |
|---|---|---|
| `document_id` | string (the versioned document) | yes |
| `org_unit_id` | string (org_unit record id; the scope column) | yes |
| `note` | string | no |
| `external_ref_system`, `external_ref_id` | string, a pair | no (needed by the line import, D7) |

There is no `event_time`, no location and no responsible person on the header: an old enterprise keeps its assets in
many rooms under many people, so placement is per line (as on the stock opening line, 0079 D2).

Line fields:

| Field | Type | Req. |
|---|---|---|
| `id`, `header_id`, `line_no` | as asset-workflow-documents.md section 1.4 | yes |
| `asset_id` | string (assets_card record id) | yes |
| `location_id` | string (location_node record id) | required for kinds `fixed` and `low_value`, refused for `intangible` |
| `material_responsible_id` | string (org_employee record id) | yes |
| `actual_user_id` | string (org_employee record id) | no |
| `quantity` | decimal, `decimal_strict` | yes |
| `external_ref_system`, `external_ref_id` | string, a pair | no |

No price, value or date field (D1, D2). At most 100 lines per document: the asset policy `declare/2` and the document
`Shape` both refuse more than 100 lines (`@max_lines 100`); a larger set of assets is entered as several documents.

The leg of a line: asset = line `asset_id`; org_unit = header `org_unit_id`; location = line `location_id` (empty text
for an intangible asset); material_responsible = line `material_responsible_id`; actual_user = line `actual_user_id`
(empty text when absent); unit `pcs`; quantity = line `quantity`.

## D4. Line checks

The checks of the commission (`Checks.masters/2`) apply per line, with the placement taken from the line instead of the
header, and the same reason names:

| Check | Reason |
|---|---|
| the org unit is a live active org_unit | `org_unit_not_active` |
| the material responsible and, when given, the actual user are active employees | `employee_not_active` with the field |
| the card exists in this tenant and is active | `card_not_active` |
| the quantity is a whole number above zero, exactly 1 for a fixed or intangible card | `quantity_invalid` |
| the card's `org_unit_id` equals the header's | `org_unit_mismatch` |
| the location rule of the card kind | `location_required`, `location_not_allowed` |
| the location is active and linked to the org unit | `not_linked` |
| the asset enters the books once (below) | `asset_already_in_register` |
| the same asset is not on two lines with the same placement (below) | `duplicate_asset` |

**Once.** A line is refused `asset_already_in_register` when the asset, of any kind, already has a non-zero quantity in
the asset register, or is named on a commission, opening or change-of-kind document that is issued and not reversed.
This is wider than the commission's rule today (fixed and intangible only, commission documents only) because an
opening is for assets that are not yet in the books at all; a written-off asset is not opened again (it is named on a
posted commission or opening). **UAT assumption, to be confirmed by the process owner.** The commission's own check
gains opening documents in the same list, so that a commission cannot place an asset a pending opening already holds.

**Several lines of one low-value asset.** A low-value card may be split over several balance rows (asset-register.md
section 7.1: 150 chairs in a room, 50 with a user). On an opening the same low-value asset may therefore appear on
several lines when their placement (location, material responsible, actual user) differs; two lines with the same asset
and the same placement are refused `duplicate_asset`, as is any repeat of a fixed or intangible asset. All lines of one
document are in the header's org unit, so a split over several org units is not possible with one document and is
refused `org_unit_mismatch` on a second document (the card has one org unit). A hand over of part of a low-value quantity to
another org unit is not refused today (the hand over check runs no `org_unit_mismatch`), so the split can arise later.
That is open owner question 3 of asset-register.md section 8; this record does not answer it (Q3 below).

**Check of all lines.** As 0079 D4 step 3: a check route runs every check on every line and answers the result per
line (`line_no` and reason), writing nothing; the issue runs the same checks and stops at the first failing line, as
the other asset kinds do. The assets router has no check route today; the implementing requirement adds it (D9).

Master checks of the ledger itself are slice L7 (0073 D6); these are the module's own checks, as for every asset kind
(asset-workflow-documents.md section 7).

## D5. Two people post it

As 0079 D4 and the built `stock_opening` process:

1. A user drafts an opening document for one org unit and types or imports its lines (D7).
2. The check of all lines (D4) answers per line and posts nothing.
3. The issue (`POST /documents/:id/issue`, `AssetsPost`) runs the checks, issues the versioned document, starts one
   instance of the process `assets_opening` and completes its `submit` task as the issuing user, so the issuer is the
   preparer.
4. A second user completes the `approve` task (`distinct_from ["submit"]`; `Letflow.Engine.SeparationOfDuties` refuses
   the same user id); its module write posts the cause `opening` on that human task node (0073 D-L12: never a service
   task).

"The approver is not the user who issued the document" is a **UAT assumption, to be confirmed by the process owner**
(as in 0079 D4). The approver needs `AssetsPost`, which no role is granted today (docs/roles.md, module `assets`), so in
UAT both people are tenant administrators. Which role may issue and approve is open (Q1).

The commission is not changed: its process has one task (`post`). An opening moves many old assets into the books at
once, without the event time limit that bounds a commission, so a second person is asked for, as for stock (0079 Q2).

## D6. Corrections and repeats

As 0079 D6:

- A posted opening is never edited. A wrong opening is corrected by the reversal of its whole entry through the existing
  `POST /documents/:id/reverse` (`AssetsReverse`; the policy builds a reversal with no legs and the core negates the
  target's legs), and a new document.
- The posting of one document uses one `client_op_id` (the issued version id, as the other asset kinds bind it), so a
  repeated approval answers the first posting's result and posts nothing more.
- After a reversal the asset is free again for a new opening (the "once" rule of D4 counts only documents that are not
  reversed).
- There is no cancel of an issued, unposted opening: the assets router has no cancel route for any kind today. An
  issued opening that is never approved stays issued; this is the same gap as for the commission and is not closed here.

## D7. xlsx import of opening lines

As 0079 D5: lines are imported through the managed import path of decision 0077 D5 into a **draft** opening document,
upsert by external ref only, at most 200 data rows per file (0077 D2), cells holding external ids; an import never
posts. Template columns (built in G6, T-1493, assets 0.11.0): `header_id`, `asset_id`, `location_id`, `material_responsible_id`,
`actual_user_id`, `quantity`, `external_ref_system`, `external_ref_id` (an optional `org_unit_id`). They are the entity
field names, because the core reader maps header cells to entity fields; the proposal's `document` and `asset` are
`header_id` and `asset_id`. `header_id` names the opening header by its own external ref pair; the asset cell names the
card by its external ref (the card import writes that pair). The import writes drafts only and does not run the D4
checks (the check route shows them); a quantity must be above zero for an import. This is gap G6.

## D8. What the card shows

Nothing new on the card. The quantity and placement of a placed asset are read from the register (asset-register.md
sections 3 and 7.1; the card panel of REQ-757). The card's `org_unit_id` is not changed by the opening, since D4 refuses
a line whose card is in another org unit.

## D9. Later requirements

Each is written from this record after the owner accepts it:

1. **G5 part 1 (server, no posting):** kind `opening` in the kind table, the two record types and the document type, the
   pack and module version, drafts, the check route and the issue checks of D4 (the commission's "once" check extended
   to opening documents with it).
2. **G5 part 2 (posting):** the cause `opening` in the registration and in `declare/2`, the process definition
   `assets_opening` of D5, the posting with no client event time (D1), reversal (D6).
3. **G5 part 3 (web):** the opening document on the asset documents screen, with the per-line check results.
4. **G6:** the xlsx import of opening lines (D7) and its UAT scenarios. Built in T-1493 (assets 0.11.0): the pair on the
   header and line, `Documents.upsert_opening_line/4`, `Documents.OpeningImport`, two API-step scenarios under
   `test/fixtures/uat/scenarios/assets/`.

**Status of the build (T-1492, GH #4037, REQ-783).** Part 1 is built (assets 0.10.0); the status of this record stays
"proposed". Deviations from the list above: (a) the external reference pair of D3 is not built (it belongs to the line
import, G6, and has no check; G6 added the fields with one more pack bump, 0.10.0 > 0.11.0); (b) issue runs every check of D4 and then
answers 409 `posting_not_available` (nothing issued, no number), because without the process of part 2 an issued
opening could never post or be reversed; part 2 removes the refusal; (c) the register-balance half of the "once" rule
(a non-zero quantity in the register) needs the caller's ledger authorization and goes to part 2; part 1 counts issued,
non-reversed commission and opening documents.

**Status of the build, part 2 (T-1876, GH #4037).** Built in assets 0.18.0 (`min_upgradable_from` "0.1.0" kept; class A
only, the process `assets_opening` appears as a new draft). Issue starts the process `assets_opening`: the issuer
completes `submit`, a second person completes `approve`, which posts the ledger cause `opening` (positive, no client
event time) and the `assets_posting_mark`; the reversal is the generic `assets_reversal`. Deviations (b) and (c) above
are resolved: the 409 `posting_not_available` is gone; the register-balance half of "once" reads the caller's ledger
balance and fails closed: a caller without a tenant-wide `AssetsRead` (none, or scoped, REQ-693) gets 409
`register_unreadable` and nothing is issued. Spec check, decided without an owner question: (S1) no official form of
order No. 562 is an opening document; the inventory number, cost, accumulated depreciation and acquisition date belong
to the card (DA-2) and stay on it untouched, the posting carries only location, responsible and actual user; (S2)
compared with the stock opening (0079 D1..D6) event time, process, four-eyes, cause, idempotency, reversal and posting
check are the same; three differences are intended and were decided above: no price or value on the line (D2), an asset
is opened once where stock adds to a balance (D4), assets has no cancel or post-retry route (D6).

## Out of scope

Creating cards from an opening line (D2); depreciation calculation (D-061); import of historical movements; the card's
org unit derived from documents and the removal of the free org unit picker (gaps G1 and G2 of T-1486); the read-only
rules of the card after its first posting (gap G3); a cancel route for issued asset documents; period close (D-062).

## Open owner questions

Each has a default; the owner may change it at the gate of phase C.

- **Q1. Which role may issue and approve an opening?** Default: the holders of `AssetsPost`, today only TENANT_ADMIN
  and PLATFORM_ADMIN (no role grants).
- **Q2. Is a second person required to approve?** Default: yes (D5), a UAT assumption.
- **Q3. Which unit holds the card of a low-value asset whose quantity is split over several org units?** Not answered
  here: open question 3 of `docs/assets/asset-register.md` section 8, marked there for the owner. Until it is answered,
  an opening places all of an asset's quantity in its card's org unit.
- **Q4. Is an asset opened only once?** Default: yes (D4 "once"), a UAT assumption; a re-opening needs a reversal of
  the earlier document first.
- **Q5. Must the card carry an acquisition date before it is opened?** Default: no (the field is optional on the card,
  asset-register.md section 3), a UAT assumption.

Decision for UAT only where marked so; the process owner configures production.
