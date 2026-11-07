# Asset workflow documents: commission, change of responsible or user, hand over, write off

Status: specification, not built (REQ-690, GH #3721, assets phase C item C2). Docs only: no code, no
migration, no definition JSON, no template row, no route, no screen, no test, no seed. The module, its types,
its process definitions and its ledger registration are later requirements, written from this file after the
owner's word on phase C (D-063, D-085).

Sources: owner decisions D-061 (only workflows write to the registers; registers are read-only and corrected
by new entries), D-062 (documents fixed once signed; audit trail; no period close), D-065 (the responsible
person and the actual user hold employee ids), D-067 (assets and documents scoped by org unit) and D-085
(phase C specifications in parallel, specs only) in `ai-dala-portfolio/DECISIONS.md`;
`ai-dala-portfolio/architectures/assets.md`; decision 0073 (domain-neutral ledger primitive, with its section
"Amended (REQ-676, assets B1)") and decision 0076 (master data layer) in `docs/migration/decisions/`; the
requirement of item C1, **REQ-689** (asset register; its file `docs/assets/asset-register.md` is **not on
origin/main** at writing); REQ-584 (task_assigned notification); REQ-679 (pattern:
`docs/assets/stock-workflow-documents.md`); and the requirement entry REQ-690 in `docs/requirements.yaml`.

Marks used below: **proposal** = the business analyst's proposal, to be confirmed by the owner at GATE C;
**open design question** = left to the implementing requirement or to C1.

## 1. Common rules

### 1.1 Ledger rules applied (decision 0073 and its REQ-676 amendment)

* Each document posts to the asset ledger id only, one posting per transaction. The two-register transaction
  of 0073 A2 is for the change of kind (item C3), not for these documents.
* `event_time` of a posting is the document's event time field, refused beyond 96 hours back or 5 minutes
  ahead with `event_time_too_old` or `event_time_in_future` (0073 D-T).
* Sign rules per cause come from the closed set of `lib/letflow/design/gh2657-wms-stock-ledger-core.md`
  section 14.3: `positive`, `negative`, `zero_sum_by_slot_1`, `any`.
* The module policy `declare/2` reads no master data (0073 D-P); the ledger's master validation is slice L7
  (0073 D6). Master checks therefore run in the asset module's own write path (section 7).
* The posting runs on a user task node whose module write handler declares `posts_ledger`, never on a service
  task node (0073 D-L12).

### 1.2 Asset register slots

Dimensions: **OrgUnit, Location, MaterialResponsible, ActualUser, Asset** (assets.md, table "Asset register").
Slots are named by name, never by `k1..k8` position. The slot order and the registration are C1's. Facts this
file relies on from C1 (REQ-689 is on origin/main, its file is not): Asset is in slot position 1 so that
`zero_sum_by_slot_1` conserves the quantity per asset; if C1 does not put Asset in slot 1, conservation per
asset of the two-leg causes is an **open design question for C1**. The one-asset-per-row bound is a
registration `key_bounds` entry `%{when_slot_nonempty: ..., max_on_hand: "1"}` (note section 4.4); its exact
form is C1's.

* The Location slot is the empty string on every leg for an intangible asset (assets.md review finding 6).
* A fixed or intangible asset has quantity 1 on every leg; a low-value asset has a positive quantity (review
  finding 5).
* Marking a low-value asset off-balance is a field of the asset card (C1), not the write off document.

### 1.3 Plain tables

Each document is two module-managed record types of the asset module: a **header** and a **line**. Type names
(proposal): `asset_commission` / `asset_commission_line`, `asset_change` / `asset_change_line`,
`asset_handover` / `asset_handover_line`, `asset_writeoff` / `asset_writeoff_line`.

* The line-to-header reference `header_id` is a foreign key inside the pack. Every master reference is a
  declarative record id checked in code (decision 0076 R6), not a foreign key.
* Field types come from the closed list `@field_types` of `lib/letflow/entities/definition/validator.ex`:
  string, integer, decimal, boolean, date, datetime, enum, json, localized_text.
* The quantity field is a decimal field with `decimal_strict: true`.
* **No document carries a price or value field.** Price and value live on the asset card (assets.md review
  finding 4).

### 1.4 Header fields common to all four documents

| Field | Type | Req. | Master |
|---|---|---|---|
| `document_id` | string (id of the versioned document; number and state are read from it) | yes | none |
| `event_time` | datetime (ISO 8601 with offset, stored in UTC) | yes | none |
| `org_unit_id` | string (record id; the scope column, section 8) | yes | org_unit |
| `note` | string | no | none |

Common line fields: `id` (string, yes, none), `header_id` (string, FK in pack, yes, none), `line_no` (integer,
yes, none), `asset_id` (string, yes, asset card of C1), `quantity` (decimal strict, yes, greater than zero,
none).

**Built by C11 (GH #3889, REQ-753, module version 0.7.0).** The kinds `change`, `handover` and `writeoff` use the
record types `assets_change`, `assets_handover`, `assets_writeoff` (each with a `_line` type), not the proposed
`asset_*` names, and the prefixes ACH, AHO, AWO. The actual user fields are optional in every kind (a commission may
leave the user empty, and a later document must be able to match that balance row). `reason_invalid` and
`reason_required` of a write off are refused when the document is saved. The card `org_unit_id` is not yet updated
by a posted hand over (follow-up part 2).

## 2. Commission

**Meaning (proposal, to be confirmed by the owner at GATE C):** commission puts an asset into the asset
register at an org unit, a location (empty for an intangible asset), a material responsible employee and an
actual user employee.

Header fields (beyond 1.4):

| Field | Type | Req. | Master |
|---|---|---|---|
| `location_id` | string | no (empty for an intangible asset) | location_node |
| `material_responsible_id` | string | yes | org_employee |
| `actual_user_id` | string | yes | org_employee |

Line fields: common only.

| Cause | Sign rule | reason_required | Legs per line |
|---|---|---|---|
| `commission` | positive | false | 1 |

| Leg | OrgUnit | Location | MaterialResponsible | ActualUser | Asset |
|---|---|---|---|---|---|
| 1 (+quantity) | header `org_unit_id` | header `location_id` (empty for intangible) | header `material_responsible_id` | header `actual_user_id` | line `asset_id` |

## 3. Change of responsible or user

**Meaning (proposal, to be confirmed by the owner at GATE C):** change of responsible or user replaces the
material responsible or the actual user of an asset, or both, while its org unit and location stay.

Header fields (beyond 1.4; `org_unit_id` is the asset's unit, unchanged):

| Field | Type | Req. | Master |
|---|---|---|---|
| `location_id` | string | no (empty for an intangible asset) | location_node |
| `from_material_responsible_id` | string | yes | org_employee |
| `from_actual_user_id` | string | yes | org_employee |
| `to_material_responsible_id` | string | yes (equals the from value when only the user changes) | org_employee |
| `to_actual_user_id` | string | yes (equals the from value when only the responsible changes) | org_employee |

Line fields: common only.

| Cause | Sign rule | reason_required | Legs per line |
|---|---|---|---|
| `change` | zero_sum_by_slot_1 | false | 2 |

| Leg | OrgUnit | Location | MaterialResponsible | ActualUser | Asset |
|---|---|---|---|---|---|
| 1 (-quantity) | header `org_unit_id` | header `location_id` | `from_material_responsible_id` | `from_actual_user_id` | line `asset_id` |
| 2 (+quantity) | header `org_unit_id` | header `location_id` | `to_material_responsible_id` | `to_actual_user_id` | line `asset_id` |

## 4. Hand over

**Meaning (proposal, to be confirmed by the owner at GATE C):** hand over moves an asset to another org unit
or location, or both, with its material responsible and actual user stated for the new place.

Header fields (beyond 1.4; `org_unit_id` is the unit that hands over):

| Field | Type | Req. | Master |
|---|---|---|---|
| `from_location_id` | string | no (empty for an intangible asset) | location_node |
| `from_material_responsible_id` | string | yes | org_employee |
| `from_actual_user_id` | string | yes | org_employee |
| `to_org_unit_id` | string | yes (may equal `org_unit_id`) | org_unit |
| `to_location_id` | string | no (empty for an intangible asset) | location_node |
| `to_material_responsible_id` | string | yes | org_employee |
| `to_actual_user_id` | string | yes | org_employee |

Line fields: common only.

| Cause | Sign rule | reason_required | Legs per line |
|---|---|---|---|
| `handover` | zero_sum_by_slot_1 | false | 2 |

| Leg | OrgUnit | Location | MaterialResponsible | ActualUser | Asset |
|---|---|---|---|---|---|
| 1 (-quantity) | header `org_unit_id` | `from_location_id` | `from_material_responsible_id` | `from_actual_user_id` | line `asset_id` |
| 2 (+quantity) | `to_org_unit_id` | `to_location_id` | `to_material_responsible_id` | `to_actual_user_id` | line `asset_id` |

## 5. Write off

**Meaning (proposal, to be confirmed by the owner at GATE C):** write off removes an asset from the register
for good (disposed, lost, broken, expired), with a reason.

Header fields (beyond 1.4):

| Field | Type | Req. | Master |
|---|---|---|---|
| `location_id` | string | no (empty for an intangible asset) | location_node |
| `material_responsible_id` | string | yes | org_employee |
| `actual_user_id` | string | yes | org_employee |
| `reason_code` | enum (disposed, lost, broken, expired, other) | yes | none |
| `reason_text` | string | required when `reason_code` is other | none |

Line fields: common only.

| Cause | Sign rule | reason_required | Legs per line |
|---|---|---|---|
| `writeoff` | negative | **true** | 1 |

| Leg | OrgUnit | Location | MaterialResponsible | ActualUser | Asset |
|---|---|---|---|---|---|
| 1 (-quantity) | header `org_unit_id` | header `location_id` | header `material_responsible_id` | header `actual_user_id` | line `asset_id` |

The ledger reason is filled from `reason_code` and `reason_text`.

## 6. Conservation of the two-leg causes

Change and hand over post two legs with opposite signs, equal quantity and the same Asset per line. The sign
rule `zero_sum_by_slot_1` conserves the quantity per asset only when Asset is in slot position 1 of the
registration (section 1.2). That order is C1's; until C1 is on origin/main it is an open design question for
C1. Meanwhile the write path builds both legs from the same line (`asset_id`, `quantity`), so equality holds
by construction.

## 7. Master checks (asset module write path, before the posting)

A failed check posts nothing and leaves the document a draft. They run in the module's own write path because
`declare/2` reads no master data (0073 D-P) and the ledger's master validation is slice L7 (0073 D6).

| Check | Function (origin/main) | Commission | Change | Hand over | Write off |
|---|---|---|---|---|---|
| Org unit active | `Letflow.Modules.Org.active?/2` | yes | yes | both units | yes |
| Location active (skipped when the Location slot is empty) | `Letflow.Modules.Locations.active?/2` | yes | yes | both | yes |
| Org unit and location linked (skipped when the Location slot is empty) | `Letflow.Modules.Locations.linked?/3` | yes | yes | both legs | yes |
| Material responsible and actual user are active employees | `Letflow.Modules.Org.active_employee?/2` | yes | both legs | both legs | yes |
| Asset card active and of a kind the document allows | the C1 read function: not on origin/main | yes (not yet in the register) | yes (in the register) | yes (in the register) | yes (in the register) |

## 8. Life cycle, process shape and access

### 8.1 Life cycle

States: **draft, posted, reversed**.

* A draft may be edited and posts nothing.
* Posting is one transaction that commits the ledger posting and marks the document posted, or commits
  neither.
* After posting no field of the header or of any line changes, and the document is never deleted (D-062,
  D-061).
* A posted document is corrected only by a reversal under decision 0073; the reversal marks it reversed and
  keeps it. A correct replacement is a new document.
* The event time is the document's `event_time`, refused beyond 96 hours back or 5 minutes ahead
  (`event_time_too_old`, `event_time_in_future`, 0073 D-T).

### 8.2 Process shape

One process definition per document, with the posting on a user task node whose module write handler declares
`posts_ledger`, never on a service task node (0073 D-L12). Posting goes to the asset ledger id only (section
1.1).

### 8.3 Access

* Every header and line type has the scope declaration `{:column, "org_unit_id"}` (decision 0076 R7, row
  "Asset cards ... scoped by org unit"). For hand over the column holds the unit that hands over
  (`org_unit_id`); whether the receiving unit sees the document is an **open item**. Change and write off have
  one unit.
* No role is named. Post and reverse use the asset registration's permissions (`post` and `reverse` distinct).
  A scoped principal cannot post until slice L6 (0073 D9, OQ-21).

## 9. Expiry reminder of intangible assets

One shape, built later by the implementing requirement:

* **Template key** `asset_expiry_reminder`, a new entry in `Letflow.NotificationTemplates.Registry` (closed
  key list today: task_assigned, exam_assigned, exam_reminder, exam_result). Placeholders, non-secret display
  values only: `asset_name`, `asset_code`, `expiry_date`, `responsible_name`, `tenant_name`.
* **Reminder function** in the asset module, of the same shape as `Letflow.Modules.Exam.Notifications.send_reminders/2`:
  `send_reminders(prefix, now)`, a default-off flag, never raises (INV-8), one
  `Letflow.Notifications.start_delivery/5` call per due asset, `trigger_ref` the asset card id.
* **Caller:** a new per-tenant sweep of `Letflow.Scheduler.Poller`, in the shape of
  `Letflow.Scheduler.ScheduledJobSweep` and `Letflow.Scheduler.RecordDeadlineSweep` (the exam function has no
  caller today).
* **Due assets:** intangible, in the register (positive balance), an expiry date on the card within the lead
  time and not past.
* **Recipient:** the Letflow user named by `user_id` of the asset's material responsible employee
  (`org_employee.user_id`, optional text). An employee without `user_id` gets no delivery and no log row.
* **Dedupe:** a dedupe on `template_key` and `trigger_ref` alone allows one reminder per asset for ever, so a
  renewed expiry date needs a second reminder key. The choice of that key is an **open design question for the
  implementing requirement**.

**Built by C12** (`Letflow.Modules.Assets.Reminders`): the lead time is the module setting
`expiry_reminder_lead_days` (1..3650, no default; absent means no reminder); the flag is
`:asset_notifications_enabled` (default off); the `trigger_ref` is a UUID derived from the card id and its
`valid_until`, so a renewed date sends again; the call is the synchronous `Notifications.deliver/6` (the async
`start_delivery/5` could double send between ticks). The material responsible employee is read through
`Letflow.Modules.Assets.Responsible.employee_id/2`, which answers none until the asset register (C8, C10)
exists: nothing is sent in production until that function is wired, and the "positive balance" condition
moves there too.

## 10. Open owner questions

Each has a source and no answer of its own here.

1. The meaning of the four documents (sections 2 to 5). Source: REQ-690 criterion 2. To be confirmed at
   GATE C.
2. The lead time of the expiry reminder and whether a second reminder is sent; no number is given here.
   Source: REQ-690 open questions.
3. Whether the actual user or another role also gets the reminder. Source: REQ-690 open questions.
4. Whether any document needs an approval step before posting. Source: `assets.md` open question 6.
5. Whether the material responsible must belong to the asset's org unit. Source: REQ-690 criterion 8.
6. Whether a write off of a low-value asset with a quantity may take part of the quantity. Source: REQ-690
   criterion 8, `assets.md` review finding 5.

Out of scope: the asset card and the registration (C1), the change of kind (C3, 0073 A2), counts of assets,
printed hand-over paperwork, signatures and labels (phase E), xlsx import of documents, amortization
calculation (D-061: an info field), period close (D-062).
