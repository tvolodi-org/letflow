# Phone flows: counts and movements in the generic mobile client

Status: specification, not built (REQ-733, GH #3806, assets phase D item D3). Docs only: no code, no Dart, no
migration, no route, no screen, no test, no dependency, no seed. Nothing here is implemented before GATE D (owner
decisions D-063, D-085); the phone screens are later requirements written from this file.

Sources: owner decisions D-058, D-061, D-063, D-085 and D-086 in `ai-dala-portfolio/DECISIONS.md`;
`ai-dala-portfolio/architectures/assets.md`; `letflow-team/project/assets-gap-analysis.md`;
`Qoimeks-team/project/features-to-port.md` sections 1, 2 and 4; `docs/mobile/requirements.md` MOB-8;
`docs/mobile/architecture.md` sections 4 and 6; `docs/migration/decisions/0079-counts-inventory-taking.md`
sections 5 and 6; `docs/assets/stock-workflow-documents.md`; `docs/assets/voice-port-design.md`; and the entries
REQ-700, REQ-701, REQ-712, REQ-714, REQ-715, REQ-716, REQ-721, REQ-730, REQ-731, REQ-732 and REQ-733 in
`docs/requirements.yaml`.

**The Qoimeks app code is not reused (D-061).** The Qoimeks phone app is the model of the behaviour, not of the
code.

Marks: **assumption, owner may change at the phase D gate** (D-086) = a proposal of this file. **GAP** = a step
for which none of the cited route lists names a route; it is left for a later entry and is not given an invented
route.

## 1. Where it lives

1. The phone screens are one feature folder `apps/mobile/lib/features/stock/`, declared in
   `apps/mobile/lib/features/module_manifest.json` with `depends_on: ["codes"]`. Assumption, owner may change at
   the phase D gate.
2. The feature is shown only when `GET /api/v1/me/modules` lists both `stock` and `codes`
   (`docs/mobile/architecture.md` section 6, rule 2 of the import boundary).
3. It reuses the scan source and the typed-code fallback of REQ-732 (`scan_source.dart`, `scan_controller.dart`
   and `scan_screen.dart` of the codes feature), not a second camera package. Camera denied: typing still works
   (features-to-port.md section 4).
4. The phone calls only routes that phase B, REQ-730 and REQ-731 name and adds no route of its own. Assumption,
   owner may change at the phase D gate.
5. The language hint of a voice phrase is the app language when it is `ru` or `kk`; with the app in English the
   user picks `ru` or `kk` on the voice button (REQ-731 criterion 3 refuses any other hint). Assumption, owner may
   change at the phase D gate.

## 2. Count flow

All routes are under `/api/v1/modules/stock`. Permissions as in the route lists of REQ-700 criterion 7 and
REQ-701 criterion 8 (StockRead, StockCountRecord).

| # | Step | Route | Notes |
|---|------|-------|-------|
| 1 | Pick a count from the list | `GET /counts` with query `status` counting or ordered | StockRead. Closed query set (status, org_unit_id, limit, cursor). |
| 2 | Open the count (chair only) | `POST /counts/:id/open` | StockCountRecord. |
| 3 | Set the current place by scanning a location code | `POST /api/v1/modules/codes/resolve` (REQ-730), then the place id is kept on the screen | See the note below. |
| 4 | Scan an item or lot code | `POST /counts/:id/scan`, body exactly `scanned_text` (unchanged), `location_id`, `scan_id` | StockCountRecord. Adds one unit to the one line found (REQ-716 criterion 4). |
| 5 | Type a counted quantity on a line | `PUT /counts/:id/lines/:line_no/count`, body exactly `counted_quantity` | A typed number replaces the value (0079 section 6). |
| 6 | Add a surplus line | `POST /counts/:id/surplus-lines` | StockCountRecord. Reached from `scan_no_line`. |
| 7 | Read the lines | `GET /counts/:id/lines` (limit, cursor) | StockRead. Rows in `line_no` order. |
| 8 | Read the entry log | `GET /counts/:id/entries` (limit, cursor) | StockRead. `entered_at` order. |
| 9 | Close counting (chair only) | `POST /counts/:id/close` | StockCountRecord. |
| 10 | Choose a count by org unit name | GAP: later entry | The list takes an `org_unit_id`, no route resolves a name. |
| 11 | Choose a place by name instead of by code | GAP: later entry | No route on the source lists. |

Note on step 3. REQ-716 criterion 3 makes the location answer of the scan route record nothing, but criterion 7
fixes the scan body as exactly `scanned_text`, `location_id` and `scan_id`; that body has no way to say "no
current place yet". A location code is therefore resolved with the resolve route of REQ-730, which answers
`target_type` and `target_id` for an assigned code, and the place id then goes in `location_id` of the later
scans. Whether the scan route should also take a bare location scan is a GAP: later entry. A location code that is
not in the count scope is refused by the scan route as `location_not_in_count` on the first item scan.

## 3. One scan, one unit

- One camera detection sends one scan request (as REQ-732 criterion 3). Further detections before Scan again send
  nothing.
- The phone makes the `scan_id` once per detection. After a network failure it sends the same `scan_id` again;
  the server answers the retry with `duplicate: true`, the same line and quantity, and adds nothing (REQ-716
  criterion 5).
- The `scan_id` is kept in memory only while the screen is open and is never written to the device.
- Each 422 refusal reason of the scan route (`extensions.reason`, REQ-716 criterion 7) has its own message key:

| Reason | Source | What the phone does |
|--------|--------|---------------------|
| `code_retired` | REQ-716 criterion 2 | Message; nothing recorded. |
| `code_assignment_conflict` | REQ-716 criterion 2 | Message; nothing recorded. |
| `code_not_assigned` | REQ-716 criterion 2 | Message; nothing recorded. |
| `code_not_countable` | REQ-716 criterion 2 | Message (the code is assigned to something that is not a place, item or lot). |
| `scan_no_line` | REQ-716 criterion 4 | Message and leads to the surplus line step (row 6). |
| `scan_ambiguous` | REQ-716 criterion 4 | Message and leads to typing the quantity on the line (row 5). |
| `location_not_in_count` | REQ-716 criterion 4 | Message; the user scans another place. |
| `not_commission_member` | REQ-716 criterion 4 | Message. |
| `count_state_invalid` | REQ-716 criterion 4 | Message (the count is not in counting). |
| `scan_id_conflict` | REQ-716 criterion 5 | Message; nothing recorded. |

- A 404 on `POST /counts/:id/scan` has no reason text of its own and shows the one not-found-or-not-available
  message of section 6. REQ-716 criterion 7 renders an unknown code, an out-of-scope location target and an
  unknown count id with the same 404 body (decision 0076 R7 ruling 2), so the unknown-code case gets no message of
  its own and does not appear in the table above.

## 4. Movement flow

Routes under `/api/v1/modules/stock`: save `POST /documents` (StockPost), change `PUT /documents/:id`, discard
`DELETE /documents/:id` (REQ-712 criterion 3), issue `POST /documents/:id/issue` (REQ-712 criterion 5, extended by
REQ-715 criterion 2 and REQ-721 criterion 2), read `GET /documents` and `GET /documents/:id` (REQ-712 criterion
4). The wire kinds are `receipt`, `issue`, `write_off`, `transfer`, `hand_over`, `return` (REQ-721 criterion 2).
`PUT` replaces the whole draft: the phone sends the full header and every loaded line back, because a line left
out is deleted.

| Kind | Fields the phone fills | Fields a scan may fill | Kind-specific refusals |
|------|------------------------|------------------------|------------------------|
| receipt (stock-workflow-documents.md section 2) | `event_time`, `org_unit_id`, `location_id`, `responsible_id`, optional `counterparty_id`, `note`, `supplier_document_ref`, `received_on`; lines: `line_no`, `catalog_item_id`, `catalog_uom_id`, optional `catalog_lot_id`, `quantity`, optional `unit_price`, `line_value` (REQ-712 criteria 2 and 3, REQ-714 criterion 1) | `location_id`; line item and lot | `price_invalid` with `line_no` (REQ-714 criterion 2) |
| issue (section 3) | common fields, `location_id`, `responsible_id`, optional `reason_text`; lines as receipt, no price (REQ-715 criterion 1) | `location_id`; line item and lot | `field_not_allowed` for a price key (REQ-715 criterion 2) |
| write off (section 7.2) | as issue plus `reason_code` (lost, damaged, used_up, other) and `reason_text`, required when `reason_code` is other | `location_id`; line item and lot | `reason_invalid`, `field_not_allowed` (REQ-715 criterion 2) |
| transfer (section 5) | common fields; from side `from_location_id`, `from_responsible_id`; to side `to_org_unit_id`, `to_location_id`, `to_responsible_id` (REQ-721 criterion 1) | both locations; line item and lot | `sides_equal`, `field_not_allowed` (REQ-721 criterion 2); issue checks answer the extra key `side` (REQ-721 criterion 3) |
| hand over (section 6) | as transfer | both locations; line item and lot | as transfer |
| return (section 7.1) | common fields; `from_org_unit_id`, `from_location_id`, `from_responsible_id`, `to_location_id`, `to_responsible_id` | both locations; line item and lot | as transfer |

- A scan fills a location, an item or a lot through `POST /api/v1/modules/codes/resolve` (REQ-730). A code whose
  target is of another kind is refused on the phone with a message and fills nothing.
- Header values with no phone route (org unit, responsible employee, counterparty, the choice of unit of measure
  for a line): GAP: later entry. The phone does not invent a route for them.
- The phone never posts. Posting is the human task of REQ-713, completed through the existing task renderer of
  REQ-428; the phone adds no screen for it.
- Issue refusals (`not_linked`, `employee_not_active`, `counterparty_not_active`, `unit_not_valid`,
  `lot_not_valid`) each have a message; a line check names the `line_no`.

## 5. Voice

- Voice is one more way to fill the count line or the movement draft. It never saves, issues or posts by itself
  (features-to-port.md section 2, "Reliability: app rules").
- The phone records AAC in `.m4a` and sends it with the language hint of section 1 to the audio route proposed by
  REQ-731 criterion 2 (a proposal of that entry, not built). The typed-phrase route of the same entry takes text.
- The answered draft fills the form for the user to check.
- When the draft lists more than one item, the save button stays disabled until the user picks one.
- A draft of kind count fills only the counted quantity of a line found by the place and item; the user confirms
  it as a typed entry (row 5 of section 2).
- With the voice step off or failing (REQ-731 criterion 8, the source `speech` or `llm`), the phone says which
  part is down; typing and scanning keep working.

## 6. Online only and failures

- Every flow is online only (MOB-8, `docs/mobile/architecture.md` section 4). Nothing is queued while offline;
  no document draft, scan, quantity or audio is stored on the device.
- Offline is the fetch-failure state of `RendererStateView`
  (`apps/mobile/lib/renderers/renderer_state_view.dart`) with a retry.
- A 403 is shown as the permission-denied state and a 429 as the retry-after countdown, as in REQ-732 criterion 5.
- A 404 on a stock route is shown as one not-found-or-not-available message, since the ApiClient raises
  `ModuleNotAvailableError` for a 404 on a module path (the 404 branch of `apps/mobile/lib/api/api_error.dart`;
  REQ-732 description item (4)), and an unknown count, an unknown document and a tenant without the module all
  answer 404 (REQ-700, REQ-712 criterion 8).
- In phase B the stock permissions are held by TENANT_ADMIN and PLATFORM_ADMIN only, and a scoped principal gets
  404 (REQ-687, REQ-712 criterion 8, REQ-701 criterion 9). A scoped principal sees the module-not-available state
  and a user without the stock permissions sees the permission-denied state.

## 7. Languages and texts

- Every text the flows show is an ARB message in `apps/mobile/lib/i18n/l10n/app_en.arb`, `app_ru.arb` and
  `app_kk.arb` (D-062).
- A quantity is shown as the decimal text the route answers and sent as a decimal string (REQ-701 criterion 8: a
  quantity is a JSON string, never a number).
- Scanned and typed codes are sent unchanged: no trimming and no case change (D-058 point 8).

## 8. Split plan

Rows are proposals (assumption, owner may change at the phase D gate).

| Part | Content | Routes | Waits for |
|------|---------|--------|-----------|
| 0 (optional) | `features/stock` skeleton and manifest entry | `GET /api/v1/me/modules` | REQ-732 |
| a | Count screens with scan and typing (section 2, 3) | counts, open, lines, count, surplus-lines, entries, close, scan, `codes/resolve` | REQ-700, REQ-701, REQ-716, REQ-730, REQ-732 |
| b | Movement draft screens with scan and typing (section 4) | documents save, change, discard, issue, read; `codes/resolve` | REQ-712, REQ-714, REQ-715, REQ-721, REQ-730, REQ-732 |
| c | Voice on both (section 5) | the audio and text routes of REQ-731 | REQ-731 implemented, and parts a and b |

## 9. Open owner questions (no answer given here)

1. Offline counting and an offline queue of scans and documents. Source: MOB-8; `assets-gap-analysis.md` risk 6.
2. Which tenant role does counts and movements on the phone, since phase B grants the stock permissions to no
   role. Source: REQ-687, REQ-712.
3. Inventory Object lines on the phone. Source: 0079 section 5 (line shape 2).
4. Assigning an unknown code from the phone. Source: D-058 point 4 for Qoimeks, left out by REQ-732.
5. The voice kinds write off, hand over and return. Source: REQ-731 criterion 10.

## 10. Not in this file

A dedicated client app (D-061), RFID reader hardware (D-058 point 7), signatures and paperwork of a count
(REQ-717, REQ-719: web), a posting screen, and any new route.
