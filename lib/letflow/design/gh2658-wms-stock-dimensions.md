# GH #2658 / REQ-503 -- WMS stock ledger dimensions (2 of 4): lot, serial, expiry, inventory status, owner, custodian as registered slots k1..k8

Author: DESIGNER (team T-0146), 2026-10-22. Design only: registration shape, key and index lists, rule statements, test briefs. No function bodies.
Nothing here was run (docs only). Every claim about existing code carries a path re-read on `main` at `0ac728fd4`, or is marked NOT FOUND / NOT VERIFIED.

Sources: issue #2658 (body, comment 2026-10-16 offline-readiness, comment 2026-10-19 04:00 alignment request, comment 2026-10-19 04:47 clarification);
`lib/letflow/design/gh2657-wms-stock-ledger-core.md` (cited `gh2657...md`, ITS section numbers; on main); `lib/letflow/design/gh2660-wms-quantity.md` (`gh2660...md`, on main);
decisions 0057 D5/G3 (`docs/migration/decisions/0057-wms-customer-draft-reconciliation.md:17,22`), 0058 (c) (`0058-wms-offline-readiness.md:25-34`), 0060, 0061;
base document `docs/WMS/WMS_Procurement_Requirements_Draft.md` (stock dimensions :40, MD-04 :63, MD-06 :65, WM-02 :75, WM-04 :77, WM-06 :79, WM-07 :80, risk row :153);
requirement text `docs/requirements.yaml` REQ-503 (line 37588).

## 0. Verdicts in one screen

| # | Question | Verdict |
|---|---|---|
| V1 | Typed nullable columns (the issue's plan)? | **No.** Replaced, per the alignment comment (decision 0062 route R-N, as adopted in `gh2657...md` 3.3 and 4.5), by registered opaque slots. The `ledger_leg` already has `k1..k8 text NOT NULL DEFAULT ''` (`gh2657...md` 4.3); this note adds NO column, NO DDL and NO migration. "Nullable so a later addition never rewrites a row" is met stronger: an unused slot is `''` from the first migration. |
| V2 | Dimensions | Seven slots registered in order: `item`, `location`, `status`, `lot`, `serial`, `owner`, `custodian` (k1..k7). `k8` stays unregistered (reserve). Expiry is NOT a slot: leg `attrs` key `expiry`, authoritative on the lot master (section 3). |
| V3 | Balance key | All seven slots (the balance key is the full tuple `(ledger_id, k1..k8)`, `gh2657...md` 4.4). Slot order is the lock order, item then location first (0057 D5). |
| V4 | Serial rule | A registration `key_bounds` entry `%{when_slot_nonempty: "serial", max_on_hand: "1"}`, enforced under the key lock. It is **per balance key**, so it does NOT forbid the same serial at another location nor under another status: both gaps are named (section 5) and gated by OQ-23, which this note widens. |
| V5 | Status effect | A read-side filter on slot `status`: available-to-pick counts only `status = "available"` (section 6). No core change. |
| V6 | Owner / custodian | Two slots in the key, so one location reports physical stock by owner and by custodian separately (section 7). |
| V7 | Quantity / alternate unit | NOT here. No quantity or unit slot (comment 2026-10-19 04:47). The alternate-unit column of 0057 G3 is the REQ-504 triple (`gh2660...md` 9). |
| V8 | Needs a change to the #2657 design | Yes, three small ones, listed in section 9 (this note does not edit that file). |

## 1. State of the world (re-read on `main` `0ac728fd4`)

| Claim | Evidence |
|---|---|
| The ledger code does not exist yet | NOT FOUND: `ls lib/letflow \| grep -i ledger` returns nothing; no `priv/repo/migrations/*ledger*`. The only artefact is the #2657 note. |
| The #2657 note defines the slots, `key_bounds`, `attrs`, rule 12 | `gh2657...md` 4.3 (`k1..k8`, only `k1` non-empty by CHECK), 4.4 (`ledger_balance` PK `(ledger_id,k1..k8)`, `max_on_hand`), 4.5 (slot registration, `key_bounds`, comparator), 14.3 (rule 12 shape). |
| Decision 0062 | NOT FOUND in `docs/migration/decisions/` (files: 0057, 0058, 0059, 0060, 0061 are the latest). It is cited by #2657 as a planned L0 deliverable (`gh2657...md` 17, slice L0). This note relies on the rules as written in `gh2657...md`, not on a decision file. |
| Item, location, lot, serial, owner, custodian masters | NOT FOUND: `grep -rliE "catalog_lot\|serial_number" lib priv/repo/migrations` finds only the two design notes; `lib/letflow/modules/catalog_items/` exists (item catalog only). Masters #2661-#2664 are not on main. |
| Entity handler write surface | `lib/letflow/entities/handler_writes.ex` exists (the `post/3` of #2657 14.2 is its planned addition). |
| Tenant table oracle / provisioning | `test/support/tenant_fixture.ex`, `lib/letflow/tenant_provisioning.ex` exist (unchanged by this note: no tables). |
| Requirement text still says "nullable columns" | `docs/requirements.yaml:37588-37633` (REQ-503 description and criterion 1/2). Not edited (status/spec flips are phase 2); recorded as a finding. |

## 2. The slot registration (criterion 1)

The stock module's `ledger` registration (`gh2657...md` 14.3, rule 12) lists, in this APPEND-ONLY order:

| Slot | Name | Format | Required | In balance key | Value rule |
|---|---|---|---|---|---|
| k1 | `item` | `:uuid` | yes (core CHECK: `k1 <> ''`) | yes | item master id, lowercase canonical UUID |
| k2 | `location` | `:uuid` | yes | yes | location master id |
| k3 | `status` | `:token` | yes | yes | closed vocabulary `available`, `quarantine`, `blocked`, `reject` (checked in `declare/2`, pure, no master read) |
| k4 | `lot` | `:token` | no | yes | lot code `[a-z0-9._:-]`, at most 128 bytes; `''` = not lot-tracked |
| k5 | `serial` | `:token` | no | yes | serial `[a-z0-9._:-]`; `''` = not serial-tracked |
| k6 | `owner` | `:uuid` | no | yes | owner party id; `''` = unassigned (see D-3) |
| k7 | `custodian` | `:uuid` | no | yes | custodian party id; `''` = unassigned |
| k8 | (not registered) | n/a | n/a | n/a | free for the next dimension, e.g. a handling unit (a registration change, not DDL) |

Notes.
* **Format limits.** `:token` is `[a-z0-9._:-]`, so a serial or lot with upper case, spaces or other characters is NOT representable; the module's input layer must canonicalise (lower-case) or refuse. Recorded as OQ-3 (real GS1 serials are case-sensitive and may use more characters).
* **"Required" is static.** A registration says `required: true|false` per slot; "lot required for lot-tracked items, serial for serial-tracked items" is an ITEM POLICY, which needs the item master read. In L1-L4 there is no master read (`gh2657...md` 0 V9), so `lot`/`serial` are `required: false` and the policy (MD-04 "cannot be received or shipped without a serial", `WMS_Procurement_Requirements_Draft.md:63`) is NOT enforced until the master validation slice (L7, `gh2657...md` 17). The 'item cannot be received without a serial' behaviour is therefore out of this note's test plan and listed as DEFERRED (section 8).
* **Index.** No new index. The leg indexes of `gh2657...md` 4.3 `(ledger_id,k1,k2,posting_seq)` INCLUDE `quantity` and `(ledger_id,k2,k1,posting_seq)` serve item+location reads; `status` at k3 means "item, location, status" is a prefix of the first index. A filter by lot, serial, owner or custodian alone scans within the `(k1,k2)` range (the accepted pilot cost in `gh2657...md` 4.3); the balance table's secondary index `(ledger_id,k2,k1)` serves location listings (`gh2657...md` 4.4). If a by-serial lookup across the tenant is needed, that is the OQ-23 shadow key, not another leg index.
* **Why status at k3 and not later.** It makes "available stock of item X at location Y" a key-prefix range, the hot read of section 6, and keeps item and location first for the lock order.
* **Why owner and custodian are key slots, not `attrs`.** MD-06 requires the same location to report stock by owner and custodian without combining them (`WMS_Procurement_Requirements_Draft.md:65`); a balance row exists per owner/custodian, and a guard (no-negative) runs per owner. Cost: a transfer of ownership is a zero-sum posting between two keys (behaviour slice, out).
* **Append-only effect.** Adding a slot (a future k8 or a new meaning) appends a name to the list; reorder, rename, remove are refused by rule 12; a ninth slot needs DDL (recorded in `gh2657...md` 4.3). A NEW `required: true` slot applies to new postings only; old balance keys (the new slot `''`) can still be reduced by a posting that supplies `''`... which the new required rule refuses. Consequence: stock under old keys must be moved to new keys by a transfer before a new slot can be made required; therefore new slots are registered `required: false` first. Recorded as a rule for slot additions (D-4).

## 3. Expiry (alignment item 5)

Expiry is a property of the LOT, not a balance dimension: two receipts of one lot cannot have different expiry, and putting it in the key would split one lot's stock.

* Leg `attrs` key `expiry` (ISO 8601 date, `YYYY-MM-DD`) is written by `declare/2` when the receipt supplies it. `attrs` rules are those of `gh2657...md` 4.3 (at most 16 keys, depth 2, scalar values, key charset `[a-z0-9_]`, 4096 bytes). It is **evidence of what the receiver entered**, not authoritative.
* The authoritative expiry belongs on the lot master (`expiry_date`), NOT FOUND today; FEFO and the expiry alert (WM-07, `WMS_Procurement_Requirements_Draft.md:80`) join `lot` (k4) to that master at READ time. That read is DEPENDENT on the read facade (OQ-R4, `gh2657...md` 14.6) and out here.
* Not decided here: whether an expired lot is excluded from available-to-pick (the base document says it shall, :40). It needs the lot master join; section 6 states the interim.
* Receipt date (MD-04 mentions it, :63) is already `event_time`/`posting_time` on the header (`gh2657...md` 4.2); no slot.

## 4. Offline readiness (decision 0058 (c), issue comment 2026-10-16)

* The ledger has no client-mutable dimension record: legs, entries are immutable, balance and counter are platform-written (`gh2657...md` 9.4). So version/`expected_version` do not apply to a leg.
* The mutable records the slot VALUES refer to are the masters (lot, serial, owner, custodian parties, item, location). Their `version`/`expected_version` (typed 409) and tombstones (retire, never delete) belong to the master issues (#2661-#2664) and the entity base; this note requires of them only: a retired master is an `active=false` row, never deleted, so a posted slot value always resolves (0058 (c).7). A retired lot/owner blocking stock-ADDING legs only is `master_inactive`, DEPENDENT on the read facade (`gh2657...md` 9.5), not in L1-L4.
* Slot REGISTRATION is versioned by the module manifest `version` and covered by `ManifestHash` (`gh2657...md` 14.3): a device holding a stale registration (slot list) is refused by the existing manifest-hash check for in-flight handler tasks, not by new code here.
* No row is ever deleted; a dimension is "retired" by never being supplied again, not by removal (rule 12).
* NOT VERIFIED: how the entity base exposes `version`; the implementer of the masters re-reads it. The issue comment says exactly that.

## 5. Serial uniqueness (alignment item 3)

Rule (MD-04, `:63`): no duplicate active serial. Registration:

```
key_bounds: [%{when_slot_nonempty: "serial", max_on_hand: "1"}]
```

Mechanics, all existing (`gh2657...md` 4.4/4.5): the core pins `max_on_hand = 1` on the balance row when the key is first touched (minimum of matching bounds), the guard refuses a posting that takes `on_hand` above it with `balance_bound_exceeded` (stock wire alias `serial_already_active` via `error_aliases`, closed aliasable set per 12.2), under the same key lock, backed by `CHECK (on_hand <= max_on_hand)`. A serial-tracked item has base unit `ea`, scale 0, so `"1"` is an integer in the base unit (`gh2660...md` 9).

**What the rule does and does not guarantee (stated exactly).**
1. Guaranteed: for one `(item, location, status, lot, serial, owner, custodian)` tuple, at most one unit is on hand; two concurrent receipts of that tuple: exactly one posts.
2. NOT guaranteed (gap A): the same item+serial at a DIFFERENT location is a different key (this is OQ-23 of `gh2657...md` 20).
3. NOT guaranteed (gap B, new in this note): the same item+serial under a DIFFERENT status (or lot, owner, custodian) is a different key. A unit in `available` and a duplicate receipt booked straight into `quarantine` both pass. Because `status`, `owner` and `custodian` are balance-key slots, "active" cannot be decided per key alone.
4. Both gaps close with the `unique_over` shadow key of OQ-23 (a registered subset, here `[item, serial]`, with its own balance row locked in the same ascending order), which this note REQUESTS be the chosen mechanism and be scoped to `[item, serial]` rather than `[item, serial, location]`. Until then `gh2657...md` 17's pilot gate already keeps serial-tracked goods out of the pilot; this note adds gap B to its rationale.
5. A serial that leaves stock (issue to zero) frees the key: "active" means `on_hand = 1`; a re-receipt after an issue is legitimate (a returned unit). A serial scrapped or rejected is `reject`-status stock, still counted as present until a `scrap` or `adjustment` posting (D-5) removes it. Those two causes are the only ones that may take `quarantine`, `blocked` or `reject` stock out directly, so such stock never has to pass through `available` (where it would briefly be pickable) to leave.

## 6. Inventory status and available-to-pick (alignment item 6)

* **Status values** are a CLOSED set in the module (`available`, `quarantine`, `blocked`, `reject`), checked in `declare/2` (`gh2657...md` 14.4: pure, no I/O). Core sees an opaque token.
* **A status change is a posting**, not an update: a zero-sum pair of legs on the same item/location/lot/serial with different `status` slots (cause e.g. `status_change`, sign rule `zero_sum_by_slot_1`, i.e. sums to zero per item, `gh2657...md` 4.2/5.3). The sign rule `zero_sum_by_slot_1` only checks that legs sum to zero per item, so the "only `status` differs" rule (same item, location, lot, serial, owner and custodian on every leg) is enforced by the module's `declare/2`, which refuses a `status_change` that differs in any other slot (`invalid_posting`, reason `status_change_slot_mismatch`). Its workflow (quarantine flows, release tasks) is out (issue scope).
* **Effect (the definition):** `available_to_pick(item, location?, lot?) = SUM(on_hand)` over balance rows with `status = "available"`. `quarantine`, `blocked`, `reject` are counted in physical on-hand but never in available-to-pick (WM-02/WM-04/WM-06, `:75,:77,:79`; "blocked stock cannot be allocated").
* **Where it lives:** the read path `Letflow.Ledger.balances/4` takes `filters :: map()` (`gh2657...md` 14.1, shape not specified there). This note specifies the filter vocabulary it needs (amendment A1, section 9): `slots: %{slot_name => [values]}` equality/IN on registered slot names, and `group_by: [slot_names]`. The stock module's read layer builds `available_to_pick` as `slots: %{"status" => ["available"]}`. Validation: unknown slot name -> `:invalid_filter`. The filter is applied on the balance table (current) or on the legs (`as-posted`/event-time basis), on the same basis rules as `gh2657...md` 8.
* **Interim exclusions NOT implemented:** expired lots (needs the lot master, section 3), allocated/reserved quantity (no reservation model exists; not in REQ-502..504), blocked LOCATION (location operational status is a master attribute; the base document's risk row :153 says status and location status are separate and both affect availability). Available-to-pick here is therefore an UPPER bound: the later slices subtract those three. Stated so nobody treats it as final.
* **No-negative guard is status-blind.** The guard works per full key, so `blocked` stock cannot be picked by a posting that names `status = "available"` (a different key with its own `on_hand`). Nothing extra is needed for "issue from quarantine is refused": a pick posting that supplies a non-`available` status is a module `declare/2` rule (cause `issue` requires `available`), listed as D-5.

## 7. Owner and custodian (MD-06)

* `owner` (k6) and `custodian` (k7) are independent key slots. The same item at the same location held by owner O1 in custody of C1, and owner O2 in custody of C1, are two balance rows.
* **Report:** `balances` with `filters.slots = %{"location" => [L]}` and `group_by: ["owner"]` gives stock by owner; `group_by: ["custodian"]` gives stock by custodian; the two reports are separate (they are not summed together and neither depends on the other). A combined `group_by: ["owner","custodian"]` is allowed. Rows with `''` appear as their own group, never merged into a party.
* "Third-party stock is visible but excluded from Customer-owned availability" (MD-06): available-to-pick takes an `owner` filter chosen by the module (the customer's own party id). Which party id is "the customer" is a tenant configuration (OQ-2), not a ledger concept.
* Financial valuation is explicitly not in the module (`:65`); no value column.
* Ownership/custody TRANSFER behaviour is out (issue scope): it is a zero-sum posting between keys, the mechanism of section 6.

## 8. Test plan (criterion 2; ExUnit, `async: false`, through the test registration of `gh2657...md` 13, plus the stock registration for names)

Slice: tests ship in L2a/L2b (core, with a TEST registration carrying the same slots) and L4 (stock registration); none runs before the ledger exists (NOT FOUND today).

| Id | File | Case |
|---|---|---|
| T-SER-1 | `ledger/dimension_serial_test.exs` | **Serial-tracked item cannot be received twice as active.** Registration with the bound of section 5: receive item I, location L, status `available`, serial S, quantity 1 -> posts, `on_hand 1`; the same tuple again -> refused `balance_bound_exceeded` (wire alias `serial_already_active`), counter unchanged, no leg written, balance still 1. Two concurrent receipts of the same tuple (forced overlap on the balance key, as T-AC2): exactly one posts. |
| T-SER-2 | same | After an issue to zero (`on_hand 0`), a new receipt of the same tuple posts (the key is free). |
| T-SER-3 | same | **Characterization of gaps A and B (pins today's behaviour so OQ-23 flips it deliberately):** the same serial at a different location posts; the same serial at the same location under `quarantine` posts. Both marked with the OQ-23 tag; when `unique_over` lands they must change to refusals. |
| T-ST-1 | `ledger/dimension_status_test.exs` | **A leg with status `quarantine` is excluded from available-to-pick.** Receive 10 `available` and 4 `quarantine` of one item/lot/location; physical on-hand = 14; `available_to_pick` (`slots: status in [available]`) = 10. |
| T-ST-2 | same | Each status value: `blocked` and `reject` are excluded; a `status_change` zero-sum posting moving 4 from `quarantine` to `available` makes `available_to_pick` = 14, physical unchanged, `reconcile` clean. |
| T-ST-3 | same | `declare/2` refuses a status outside the closed set (`invalid_posting`, reason `invalid_status`); an issue-cause leg with a non-`available` status is refused (D-5). |
| T-ST-4 | same | A `status_change` whose legs do not sum to zero per item -> `posting_not_balanced` before any lock. A `status_change` whose legs differ in lot, serial, location, owner or custodian (not only status) -> `invalid_posting`, reason `status_change_slot_mismatch`. |
| T-OC-1 | `ledger/dimension_owner_custodian_test.exs` | **Owner and custodian are reported separately for one location.** At location L: item I, 5 units owner O1/custodian C1, 3 units owner O2/custodian C1, 2 units owner O1/custodian C2. `group_by owner` = {O1: 7, O2: 3}; `group_by custodian` = {C1: 8, C2: 2}; `group_by [owner, custodian]` = three rows; total = 10 in every grouping; rows with `''` form their own group. |
| T-OC-2 | same | No-negative is per owner: removing 4 from O2's 3 -> `insufficient_balance` although the location holds 10. |
| T-REG-1 | `ledger/slot_registration_test.exs` | **Slot registration is append-only and a populated ledger is byte-identical after a registration change** (alignment item 4, replaces the byte-identity migration test). Seed a posting; record `SELECT md5(string_agg(row_to_json(l)::text, '' ORDER BY id))` over `ledger_leg` and `ledger_entry` plus every `entry_digest`/`chain_hash`, and the per-key sums; register a new slot name (k8) through a new manifest version; assert the same digests and sums, `reconcile/2` clean (`chain_check: :ok`), and that a new posting using the new slot posts while old keys are unchanged. |
| T-REG-2 | same | Rule 12 refuses: reordering two slots, renaming, removing one, a ninth slot, a duplicate name, an unknown format, a `key_bounds` entry naming an unknown slot. |
| T-REG-3 | same | A registered change to `key_bounds` does not alter an existing key's pinned `max_on_hand` (`gh2657...md` T-KB-1; here for the serial bound). |
| T-ATTR-1 | `ledger/dimension_expiry_test.exs` | `declare/2` stores `expiry` in `attrs` as an ISO date and refuses a non-date; two receipts of one lot with different `expiry` are two legs of ONE balance key (expiry is not in the key). |
| DEFERRED | | "serial-tracked item cannot be received without a serial", lot-required, expired-lot exclusion, retired lot/owner blocks stock-adding legs, and master validation: need the item/lot masters and the read facade (L7). Tests for slot value formats (uppercase serial, over-length) are core tests T-AC1/T-SEC in `gh2657...md` 13. |

Pins to update when the code lands (greps run on `main`): `grep -rn "k1\b" test` finds none today since the ledger does not exist (NOT FOUND); `grep -rn "expected_tenant_tables" test lib` lists only the oracle of `gh2657...md` 4.6, which this note does not change (no table). No route is added by this note (read routes are L4), so no route-inventory pin changes now; when L4 adds them, INV-10 applies only if a route takes a tenant identifier (none is planned: tenancy is the prefix).

## 9. Amendments this note needs in the #2657 note (not edited here)

* **A1 (read filters).** `balances/4` `filters` gets the documented vocabulary of section 6: `slots: %{name => [value]}` and `group_by: [name]`, names validated against the registration, unknown -> `:invalid_filter`; rows carry the slot NAMES (not `k1..`) in module read layers.
* **A2 (OQ-23).** Choose `unique_over` scoped to `[item, serial]` (section 5), widening OQ-23 from "across locations" to "across locations, statuses, lots, owners, custodians"; T-KB-1 keeps the per-key case.
* **A3 (required slots).** Add the rule D-4: a slot added after the first posting is registered `required: false`; making it required first needs a transfer of old stock.

## 10. Decisions and open questions

| Id | Decision / question | Default |
|---|---|---|
| D-1 | Seven slots in the order of section 2; status at k3 | as stated |
| D-2 | Expiry in `attrs`, authoritative on the lot master | as stated |
| D-3 | `owner`/`custodian` optional, `''` = unassigned, reported as its own group | pending OQ-2 |
| D-4 | New slots start `required: false` | as stated |
| D-5 | Issue causes require `status = "available"`; only `scrap` and `adjustment` may remove non-available stock; `status_change` legs differ in status only (module `declare/2` rules, not core) | as stated |
| OQ-1 | Does the supervisor confirm the requirement text change from "nullable columns" to "registered slots" (criterion 1 wording in `docs/requirements.yaml` and the issue)? | yes, per the alignment comment; the note meets the intent |
| OQ-2 | Which party id is "the customer's own" owner for the available-to-pick owner filter, and are owner/custodian required for some causes? | owner/custodian optional until the customer answers (MD-06 :65) |
| OQ-3 | `:token` charset forbids upper case in serials/lots: lower-case at the edge or widen the format? | lower-case at the edge; widen only with a #2657 change |
| OQ-4 | Interim available-to-pick is an upper bound (no expiry, reservation, location-status subtraction) | accepted until those slices |

## 11. Acceptance-criteria map

| Criterion | Where met |
|---|---|
| Lists each dimension (name, format, required) and states the balance key and lock order | section 2 (table), V3 |
| Serial uniqueness as a registration `key_bound`; effect of status on available-to-pick | sections 5 and 6 |
| Test plan: serial twice, quarantine excluded, owner/custodian separate, byte-identical after registration change | T-SER-1, T-ST-1, T-OC-1, T-REG-1 |
| Citations re-read on main or NOT FOUND | section 1 and inline |
| No quantity or alternate-unit slot; offline-readiness | V7, section 4 |

## 12. Risks for the validator to attack first

1. Gap B (section 5): the status-in-key choice weakens the serial rule; is requesting `unique_over` on `[item, serial]` the right fix, or should `status` leave the key (then quarantine needs another way to partition stock)?
2. `lot`/`serial` `required: false` means MD-04's "cannot be received without a serial" is unenforced until L7.
3. The owner/custodian `''` group and the OQ-2 customer answer.
4. Whether `balances` filters and `group_by` (A1) are acceptable as an addition to a note already on main.
