# The old Qoimeks app on Letflow's old address: what it calls, what works, what to build

Written 2026-11-20 by the business analyst for task T-2374 (sizing, no code). Scope: the cutover keeps
the OLD Qoimeks phone app and points it at Letflow's old address `https://<host>/qoimeks/<tenant-slug>`
with the shared code (decision 0091). Everything the app calls must work there, or the storekeepers
lose counting, scanning and voice on day 1. QA only; this note decides nothing for production.

## Plain words first

- **Today the old app does not work on Letflow at all.** The Qoimeks team ran the real app (web build
  0.1.2, the same version as the published production APK) against `qoimeks-qa2` on 2026-11-20. Its
  first call, `GET <base>/api/catalog`, got **404**. The app showed «Не удалось загрузить справочник» and
  no other screen could be reached.
- Cause 1: the app puts **`/api`** in front of every path (`/api/catalog`, `/api/movements`, ...).
  Letflow serves the same calls without `/api` (`/catalog`, `/movements`, ...). Decision 0091 section 6
  assumed the paths had no `/api`. That was wrong.
- Cause 2: even with the right path, **the answers have a different shape** from what the app reads.
  The catalog comes back as one flat list, but the app wants two lists, items and places. A quantity is
  `quantity`, but the app wants `qty`. A movement id is a number, but the app wants text. The movement
  also lacks the item code, the unit, the place code and the balances after the movement. The app's
  Dart code converts every field strictly, so **no screen tolerates the difference**: a post that
  Letflow accepted would still end in an app error. The PM's rule therefore applies: **the old app's
  shapes must be served**, and this overrides "we kept our shapes".
- What already works once the path and shapes are fixed: signing in with the shared code (`Bearer`), the
  post body with `qty`, retry safety by the client id (200 on a repeat, 409 on changed data, the same
  text as the old server), and the order of the history.
- Still missing after that: **count (adjustment)**, **code scan and lookup**, **voice**, code
  assign/remove, and **feedback**.
- Three requirement entries are written for the calls that are certain from the code and the run, and
  without which nothing works: REQ-907 (the `/api` paths), REQ-908 (catalog and balances in the old
  shape) and REQ-909 (movement rows in the old shape). Each of the rest needs a choice by the PM (and
  for count, a rule decision) before a requirement can be written: see section 5.
- **Honest total (section 5.4):** the day-1 set (the `/api` paths, the old shapes, the old refusal
  texts, count, scan lookup, voice, and the re-run) is about **25.5 hours of engine time, about 3.2
  engine days** (one engine day = 8 hours of one engine worker), about **4.1 days with a 30 % margin**
  for rework and CI rounds. Everything (plus code assign/remove and feedback) is about **35 hours, 4.4
  engine days, about 5.7 with the margin**. The tasks change the same three files, so they run one after
  another: calendar time is close to the sum. The biggest risks are the count rule (a decision is
  needed first) and the voice answer, whose tolerance nobody has tried (section 5.5).
- **Go gate "real old client compatibility": OPEN, failing.** It stays failing until REQ-907..909 are
  built, the count, scan lookup and voice tasks (section 5.3, K4-K10) are built, and the re-run with the
  real client (K15) passes.

## 1. Sources (opened for this note)

| Source | What was read | Copy for the gate |
|---|---|---|
| Qoimeks repository at commit `01e8780` (2026-10-30 is the last change of `mobile/lib/api.dart`), `mobile/lib/api.dart` | every call (`_get`, `_post`, `_delete`, the multipart voice call, the pairing call), the headers, and the `fromJson` of every answer the app reads | `state/tasks/T-2374/sources/qoimeks-mobile-api.dart` |
| Qoimeks `server/internal/api/api.go` lines 145-165 | the route table of the old server: `GET /api/catalog`, `GET /api/balances`, `GET /api/movements`, `POST /api/movements`, `POST /api/movements/{id}/reverse`, `POST /api/parse`, `POST /api/voice`, `POST /api/feedback`, `GET /api/feedback`, `GET /api/feedback/export.md` (plus `codes.go`: `POST/GET /api/codes`, `GET /api/codes/lookup`, `DELETE /api/codes/{id}`; `pair.go`: `POST /pair/v1/exchange`) | `sources/qoimeks-api-routes.go.txt` |
| Qoimeks `server/internal/store/store.go` | the JSON field names of `SKU`, `Location`, `Catalog` (`skus`, `locations`), `Balance` (`sku_id, location_id, location_code, qty`), `Movement` (`id` UUID, `kind`, `sku_code`, `sku_name`, `unit`, `location_code`, `to_location_code`, `qty`, `operator`, `reverses`, `reversed_by`, `created_at`, `balances`). The catalog and the places are sorted by code; balances are the non-zero ones sorted by place code; the history list carries `balances: []`; post and reverse carry the balance after the movement at each place it touched; a reversal keeps the kind of the original and sets `reverses` | `sources/qoimeks-store-catalog.go.txt`, `sources/qoimeks-store-movement.go.txt` |
| Qoimeks `server/internal/store/import.go` line 281 | imported balances are written as kind `adjustment` | quoted here |
| Qoimeks `server/internal/store/store.go` `Post` and `reverse`, `server/internal/api/api.go` `writeError` and the access check | the refusal texts: 400 "quantity must be positive", 400 "already reversed", 400 "a reversal cannot be reversed; post a new operation instead", 401 "access code is missing or wrong"; a count (`adjustment`) SETS the balance to the sent quantity, 0 allowed | `sources/qoimeks-store-post-reverse-errors.go.txt` |
| Qoimeks `mobile/lib/l10n.dart` `error()`, `mobile/lib/offline_queue.dart` `isTemporary`, `mobile/lib/operation_screen.dart` | how the app shows each status (401 "wrong access code", 409 "already posted", 422 "silence", other: generic text plus `error`) and which statuses the queue keeps for later | `sources/qoimeks-mobile-error-handling.dart.txt` |
| The team database `state/team.db` (outside the gate's view; numbers quoted in section 5.4) | wall-clock lead time of earlier old-address and similar build tasks, used for the engine-time estimates | quoted in section 5.4 |
| The real-client run, Qoimeks team (session qoimeks-team-6a), `Qoimeks-team/project/qa2-compat-report.md`, 2026-11-20, plus their message to this task the same day | the result per call (quoted in section 3, column "Run") | `state/tasks/T-2374/sources/qa2-compat-report.md` |
| `project/qoimeks-voice/old-qoimeks-voice-prompt.md` (lab repository) | the old voice prompt (for the voice item) | not copied: only its existence is used here |
| Letflow on main: `lib/letflow/router.ex` (`forward("/qoimeks/:tenant_slug", ...)`), `lib/letflow/routers/shared_stock_access.ex`, `lib/letflow/modules/stock/old_app_reads.ex`, `lib/letflow/modules/stock/old_app_writes.ex`, `docs/migration/decisions/0091-shared-stock-access.md` sections 6, 7, 9, 11a, 11b | what the old address serves and in which shape | in the repository |
| Letflow on main: `lib/letflow/modules/stock/voice_service.ex` (`draft_audio/2`, form keys `audio` and `lang`), `lib/letflow/modules/codes/router.ex` (`POST /resolve`, `/:id/assign`, `/:id/release`), `lib/letflow/modules/stock/router.ex` (`POST /quick-counts`, `POST /voice/draft`), `priv/modules/catalog_items/entity_definitions/catalog_item.json` (`default_location_id`), `priv/modules/locations/entity_definitions/location_node.json` (`code`, `name`) | what exists to build the missing calls on | in the repository |

The Qoimeks team's message (2026-11-20) confirms the call list read from `api.dart`, with all calls
under `/api`. Client 1's phones use the shared code (Bearer). Device keys from pairing exist only in the
0.1.3 QA APK and are not on production. The production APK is 0.1.2, but nobody has read what each
phone actually has installed (an infra check). The 0.1.3 APK itself was not run.

## 2. The full list of calls the old app makes

Headers on every call except pairing: `Authorization: Bearer <shared code>`. When known, the app also
sends `X-App-Version`, `X-Device` and `X-Operator`, each percent-encoded (`api.dart` `_requestHeaders`).
Every call times out after 90 s. The app reads an error from `status` and, if present, `error`,
`source` and `reason`. 401 shows "wrong access code", 409 "already posted" and 422 "silence" (the voice
text); any other code shows the generic text plus `error` (`l10n.dart` `error()`).

| # | Call | Request | Fields the app reads | Screen |
|---|---|---|---|---|
| C1 | `GET /api/catalog` | none | object `skus[]`: `id` (int), `code`, `name`, `unit` (non-null text), `location_id` (int, optional), `alt_location_id` (int, optional); `locations[]`: `id` (int), `code`, `name` | operation form (loaded first; every screen needs it) |
| C2 | `GET /api/balances?sku_id=<int>` | none | list of `location_id` (int), `location_code`, `qty` (number) | operation form (stock of the chosen item per place; "goes negative" warning) |
| C3 | `GET /api/movements?limit=100` | none | list of Movement: `id` (TEXT), `kind`, `sku_code`, `sku_name`, `unit`, `location_code`, `to_location_code` (optional), `qty` (number), `operator` (non-null text), `reverses` / `reversed_by` (presence only), `created_at` (ISO time), `balances` (list, required, may be empty) | history |
| C4 | `POST /api/movements` | JSON `id` (UUID made on the phone), `kind` (`receipt`, `issue`, `transfer`, `adjustment`), `sku_id`, `location_id`, `to_location_id` (int or null), `qty` (number; 0 allowed only for `adjustment` = the counted quantity), `operator`, `source`, `transcript` | one Movement as C3, with `balances` = the balance after the post at each place it touched (shown in the success message) | operation form; offline queue (0.1.3 only) |
| C5 | `POST /api/movements/{id}/reverse` | `{id}` is the movement `id` text from C3; JSON `id` (a new UUID), `operator` | one Movement | history ("cancel") |
| C6 | `POST /api/voice` | multipart: field `lang` (`ru` or `kk`), file `audio` | Draft: `transcript`, `kind`, `skus[]` (Sku as C1), `location` and `to_location` (Location as C1, or null), `qty`; errors carry `source` `speech` or `llm` | operation form (microphone) |
| C7 | `GET /api/codes/lookup?code=<text>` | none | `object_type` (`sku` or `location`), `object_id` (int), `object_code`, `object_name`, `code`; 404 with `reason: code_not_found` means "nothing found" | scan to find; unknown code in the operation form |
| C8 | `GET /api/codes?object_type=&object_id=` | none | `codes[]`: `id`, `object_type`, `object_id`, `object_code`, `object_name`, `code_type`, `code` | item and place codes list |
| C9 | `POST /api/codes` | JSON `id` (UUID), `object_type`, `object_id`, `code_type`, `code`, `operator` | one ItemCode as C8; 409 `reason: code_in_use` with `owner` | assign a code by scan or typing |
| C10 | `DELETE /api/codes/{id}?operator=` | none | nothing | remove a code |
| C11 | `POST /api/feedback` | JSON `text`, `voice_text`, `app_version`, `android_version`, `device`, `operator`, `screen`, `errors[]` (`time`, `screen`, `message`) | nothing (not observed; kept to send later when the server is unreachable) | "report a problem" |
| C12 | `POST /pair/v1/exchange` | JSON `code`, `device_label`, `operator`, `app_version`; no Authorization | `device_id`, `device_key`, `tenant`, `label` | settings, pairing (0.1.3 QA APK only) |

Not called by the app (checked with
`grep -n "_get(\|_post(\|_delete(\|Uri.parse" mobile/lib/*.dart`): `POST /api/parse`; the admin web
page calls `GET /api/stock`, `GET /api/stock/export`, `/api/import/*`, `GET /api/feedback`,
`GET /api/feedback/export.md` and `/api/settings/providers`. `update.dart` reads an update manifest from
its own URL, not from the server.

## 3. Gap table: each call against what Letflow serves today

"Run" is the result of the real-client run (section 1). "Tolerance" says whether the app accepts
Letflow's shape. The app's `fromJson` casts every field strictly (`final String id = j['id']`,
`(j['qty'] as num)`, `j['skus'] as List`), and the run confirmed that no screen survives a shape
difference.

| # | Letflow today | Run | Status | Tolerance | Size | Recommendation |
|---|---|---|---|---|---|---|
| C1 | `GET /qoimeks/:slug/catalog`: a flat list of `id, name, article, unit, barcode`; no places; `unit` may be null | 404 at `/api/catalog`; the flat list at `/catalog` | missing (path) and different shape | none: `j['skus']` on a list fails | path S, shape M | REQ-907 (path) and REQ-908 (shape) |
| C2 | `GET /balances`: `sku_id, location_id, quantity, sku_name, location_name` | 404 at `/api`; at `/balances` no `location_code`, `quantity` in place of `qty` | missing (path) and different shape | none: `(j['qty'] as num)` on a missing field fails | in REQ-908 | REQ-908 |
| C3 | `GET /movements`: `id` (int), `kind` (`stock_receipt`, `stock_issue`, `stock_transfer`, `reversal`), `sku_id`, `location_id`, `quantity`, `operator` (null for a personal account), `created_at` | at `/movements`: newest first, items as Letflow's shape | missing (path) and different shape | none: int `id` into a text field, missing `sku_code`, `qty` and `balances`, null `operator` | M | REQ-909 |
| C4 | `POST /movements`: kinds `receipt`, `issue`, `transfer` posted; `qty` accepted; client `id` required (201, 200 on a repeat, 409 with the old text); answer in the C3 shape | receipt 201, repeat 200, changed data 409, no id 400; the answer breaks the app | works for receipt, issue and transfer; answer shape different; `adjustment` missing (400 `invalid kind`) | none for the answer | answer in REQ-909; adjustment L, split | REQ-909; adjustment: section 5 tasks K4-K6 (needs a rule first) |
| C5 | `POST /movements/:id/reverse`: integer id; 201, 200 on a repeat; answer as C3, no `reverses` | worked at `/movements/{int}/reverse` | works; answer shape different; the id the app passes comes from C3 | none for the answer | in REQ-909 | REQ-909 (the id is the text of the same integer, so the path keeps working) |
| C5 refusals | a movement already reversed under another client id: 409 `{"error": "document_reversed"}`; reversing a reversal: 409 `{"error": "reversal_cannot_be_reversed"}` (`old_app_writes.ex` `refusal/1`, `not_a_reversal/1`) | run row 10: the old server answers 400 "already reversed"; Letflow 409 `document_reversed` | different status and text | none: the app shows EVERY 409 as "already posted" (`l10n.dart` `error()`), the wrong message for a cancel; a 400 shows the server's text | in REQ-909 | REQ-909 point (6): 400 `{"error": "already reversed"}` and 400 `{"error": "a reversal cannot be reversed; post a new operation instead"}`, the old server's texts (`store.go` `reverse`) |
| C6 | not served (404); `voice_service.ex` exists for personal accounts with the same form keys `audio` and `lang`, answering Letflow's draft | not tested (404) | missing | unknown: the run must show the Draft shape and the `source` error field are read as in `api.dart` | M | section 5 tasks K9-K10 |
| C7 | not served; `POST /codes/resolve` exists (permission `CodesRead`) | not tested (404) | missing | unknown: the run must show the scan finds an item and a place, and `code_not_found` gives "nothing found" | M | section 5 tasks K7-K8 |
| C8-C10 | not served; codes assign and release exist (`CodesWrite`) | not tested (404) | missing | unknown | M (and the shared access gains a write permission: a decision 0091 amendment and a security review) | section 5 tasks K11-K12 |
| C11 | not served; no feedback store in Letflow (readiness row G19) | not tested (404) | missing | a 404 is not shown as an error: the app keeps the report on the phone as "send later" (`feedback.dart` `submit`, kept up to its pending cap) and resends it after the next successful call, so reports pile up on the phone and never arrive | M | section 5 tasks K13-K14 |
| C12 | not served | not tested | missing; not on production phones (0.1.2) | not needed for day 1 | — | none now; revisit only if 0.1.3 is rolled out |
| auth | `Authorization: Bearer <value>` accepted; 401 is a problem body (`status`, `type`, `title`, `detail`, `trace_id`) and never carries `error`; the old server answers `{"error": "access code is missing or wrong"}` (`api.go`) | Bearer accepted; raw value, `X-Access-Token` and `X-Api-Key` give 401 | works as is (status); body different | proven from the code, not the run: the app decides by status 401 alone ("wrong access code", `l10n.dart` `error()`; the body is read only for `reason: device_revoked`, a pairing case) and the offline queue keeps a 401 item for later (`offline_queue.dart` `isTemporary`) | — (S if the PM wants the body too) | none recommended; PM decision: the old body could be served at the old address, but it is the uniform refusal body of INV-5 shared with `AuthPipeline`, so it would need a security review for no visible gain |
| errors (post) | refusals are `{"error": text}`; 400 `invalid quantity` for 0 or a negative quantity; 422 for `location_not_linked` and `no_responsible_employee` | run row 7: 400 `invalid quantity` in place of "quantity must be positive" | works, different text | a 400 shows the generic text plus the server's text, so the storekeeper sees a different sentence; a 422 shows as the voice "silence" text, a misleading message for a place with no org unit | in REQ-909 (text); S for D1 | REQ-909 point (6): 400 `{"error": "quantity must be positive"}`; and section 5 item D1 (setup check, not a code change: every place used by the phones has an org unit and the tenant has an employee) |
| CORS | not tested (the run's harness added the headers) | — | unknown | only the browser (web) build needs it; the phones run the APK | S if the web build is used | section 5 item D2 (ask whether anyone uses the web build) |

Shape rule (PM, task text): the real client breaks on the SHAPE, not only on the missing paths. So
REQ-908 and REQ-909 make Letflow answer in the old app's field names and types, and this replaces "kept
our shapes".

## 4. Not rebuilt: the owner's pruning D-150 (as relayed by the PM in the task text)

None of these is a task, and none is part of REQ-907..909:

| Pruned item | Where it would have shown up in the call list |
|---|---|
| Second place of an item | C1 `alt_location_id`: not served. REQ-908 sends only `location_id`, from the one usual place `default_location_id` (REQ-841) |
| SHA guard | not part of the phone calls; not rebuilt |
| Weekly workbook | admin page `GET /api/stock/export`: not served |
| Movement history import | the history (C3) shows only movements posted in Letflow; old Qoimeks movements are not imported |
| Update banner | `update.dart` manifest: not served |
| Markdown feedback export | `GET /api/feedback/export.md`: not served (even if C11 is built) |
| Voice count phrase | C6 is not extended to count by voice (if K10 is built, a voice draft with kind `adjustment` is not offered) |
| Tokens screen | none (REQ-861 cancelled; the shared access is managed through the admin API) |

## 5. Prioritised batch of product tasks for the PM

Target (PM, task text): the old app works UNCHANGED against Letflow for the Client 1 functions (D-150
parity). The old address speaks the old protocol exactly, and the shapes follow the old app's. This
overrides "kept our shapes", but only at the old address: Letflow's own API keeps its shapes.

Sizes: S is one small change with its tests. M is one change across two or three files in one
sitting. L is bigger than one change, or waits on a decision, so it is split below. Hours are hours of
engine time (wall-clock lead time of one task through the engine, from start to merge). They are taken
from measured earlier tasks of the same kind (section 5.4). One engine day is 8 hours of one engine
worker.

### 5.1 The ten rows (PM's numbering)

| PM row | What the old app needs (source) | Letflow today | Status | Size | Engine hours | Task |
|---|---|---|---|---|---|---|
| 1 Path prefix | every call under `/api` (`api.dart`; run row 1) | no `/api` segment: 404 | missing | S | 1.5 | K1 = REQ-907 |
| 2 Catalog shape | `{skus: [{id, code, name, unit, location_id, alt_location_id}], locations: [{id, code, name}]}` (`store.go` `Catalog`; run row 2). `alt_location_id` is the second place, which D-150 CANCELLED: the app reads it as an optional integer (`api.dart` `Sku.fromJson`), so leaving the key out is safe; the usual place `location_id` is served from `default_location_id` (REQ-841) | flat list, no `code`, no places, `unit` may be null | different shape | M (with row 6) | 3.0 (with row 6) | K2 = REQ-908 |
| 3 Movement shape | text `id`, old `kind`, `sku_code`, `sku_name`, `unit`, `location_code`, `to_location_code`, `qty`, `operator`, `reverses`, `reversed_by`, `created_at`, `balances[]` (`api.dart` `Movement.fromJson`; run rows 5, 8). The old app reads no `seq` field (`grep -n seq` finds none in `api.dart`), so none is served | integer `id`, `kind` `stock_*`, `quantity`, no codes, no unit, no balances; a transfer loses its destination | different shape | M (with row 4) | 3.5 (with row 4) | K3 = REQ-909 |
| 4 History, reverse and refusals | history newest first with `balances: []`; reverse answers a Movement with `reverses`; reversing a reversed movement is 400 "already reversed"; reversing a reversal is 400 "a reversal cannot be reversed; post a new operation instead"; 0 or a negative quantity is 400 "quantity must be positive"; every refusal is `{"error": text}` (`store.go`, `api.go` `writeError`; run rows 7, 10) | order right; refusals 409 `document_reversed`, 409 `reversal_cannot_be_reversed`, 400 `invalid quantity`; refusals already `{"error": text}`; 401 is a problem body | different shape and status | in K3 | in K3 | K3 = REQ-909 point (6). The 401 body: no change recommended (the app reads only the status; section 3 row "auth"); PM decision |
| 5 Count (`adjustment`) | `kind: "adjustment"`, `qty` = the counted quantity, which REPLACES the balance at once; 0 is allowed; the answer is a Movement whose `qty` is the counted quantity and whose `balances` shows the new balance (`store.go` `Post`: `appendBalance(..., 0, &in.Qty)`; run row 6) | 400 `invalid kind`; Letflow's count is the quick count, which on the Qoimeks QA tenant waits for an administrator (four-eyes ON; tenant state as stated by the PM on 2026-11-19 in the BA role text; UAT assumption, to be confirmed by the process owner); decision 0091 section 9 says the shared access cannot count and A12 that it cannot approve | missing, and blocked on a rule | L, split: decision + requirement + M build | 2.0 + 1.0 + 3.5 = 6.5 | K4, K5, K6 |
| 6 Balances | `[{location_id, location_code, qty}]` (the old rows also carry `sku_id`), non-zero only, sorted by place code (`store.go` `Balance`; run row 9) | `quantity`, `location_name`, no `location_code` | different shape | in K2 | in K2 | K2 = REQ-908 |
| 7 Codes and scan | `GET /api/codes/lookup?code=` (scan to find; 404 `code_not_found` means "nothing found"); list, assign and remove codes (C8-C10) (`api.dart`; G12, T-2033) | not served; `Codes` resolve (`CodesRead`) and assign/release (`CodesWrite`) exist for personal accounts | missing | lookup M; writes M | lookup 1.0 + 3.0 = 4.0; writes 1.0 + 3.5 = 4.5 | K7, K8 (lookup); K11, K12 (writes, day 2) |
| 8 Voice | `POST /api/voice` multipart `audio` and `lang`, answering the Draft `transcript, kind, skus[], location, to_location, qty`, and `source` `speech` or `llm` on a failure (`api.dart`; G15, T-2035; the old prompt `project/qoimeks-voice/old-qoimeks-voice-prompt.md` in the lab repository). No count by voice (D-150) | not served at the old address; `VoiceService.draft_audio/2` exists for personal accounts with the same form keys, answering Letflow's draft | missing; tolerance unknown | M | 1.0 + 3.5 = 4.5 | K9, K10 |
| 9 Feedback | `POST /api/feedback` with `text, voice_text, app_version, android_version, device, operator, screen, errors[]` (`api.dart`; G19, T-2038). The Markdown export is pruned (D-150) | not served; no feedback store | missing; today the reports pile up on the phone as "send later" (`feedback.dart`) | M (a new tenant table) | 1.0 + 4.0 = 5.0 | K13, K14 (day 2) |
| 10 Pairing `/pair/v1/exchange` | trades a one-time pairing code for a per-device key (`device_id`, `device_key`) so that a phone stops using the shared code (`api.dart` pairing call, `pair.go`). It exists only in the 0.1.3 QA APK; production phones run 0.1.2 with the shared code (Qoimeks team message, 2026-11-20) | not served | not needed for Client 1 on 0.1.2 | — | 0 | none; revisit only if 0.1.3 is rolled out (infra check D3) |

### 5.2 The thin compatibility layer (module and route layout)

The layer already exists and stays the only place that knows the old protocol:

- **Routes:** `Letflow.Routers.SharedStockAccess` (`lib/letflow/routers/shared_stock_access.ex`) is
  mounted only at `/qoimeks/:tenant_slug` (`lib/letflow/router.ex`, `forward("/qoimeks/:tenant_slug",
  ...)`), outside `/api/v1`, with its own authentication by the shared code. K1 adds the `/api` forms
  there. Every new old-protocol call (code lookup, voice, code writes, feedback) is a new route of this
  same router, never of a Letflow router.
- **Shapes and refusal texts:** built only in `Letflow.Modules.Stock.OldAppReads` (reads) and
  `Letflow.Modules.Stock.OldAppWrites` (writes and their refusal texts), reached through the
  `old_app_*` delegates of `Letflow.Modules.Catalog`. Checked: `grep -rln "OldAppReads\|OldAppWrites"
  lib/` lists only these two files, `catalog.ex`, `shared_stock_access.ex`, and a moduledoc mention in
  `stock/documents/posting.ex`. The `Catalog.old_app_*` delegates are called only from
  `shared_stock_access.ex`. A new call family gets one new builder file beside them. Its file name is
  set by that task's design under the boundary rule that only `catalog.ex` may reference
  module-subdirectory files.
- **What does not change:** Letflow's own routers and their answers: the `/api/v1` stock, codes and
  voice routes, `VoiceService`, the `Codes` router and the web SPA. The old-protocol builders call the
  existing context functions (`Ledger`, `Codes` resolve and assign, `VoiceService.draft_audio/2`) and
  translate their results; they do not change them. Every task in 5.3 carries the criterion "no test
  expectation outside the old-address router tests and the old-app builder tests changes".

### 5.3 Task split (each task is at most one agent day)

Order matters: K1-K3, K6, K8, K10, K12 and K14 all change `shared_stock_access.ex` and the old-app
builders, so each build task gets `after` set to the previous build task.

| Task | Workflow | What | Size | Hours | After | Go gate |
|---|---|---|---|---|---|---|
| K1 | change | Build REQ-907 (`/api` paths, decision 0091 section 11c) | S | 1.5 | — | day 1 |
| K2 | change | Build REQ-908 (catalog and balances in the old shape) | M | 3.0 | K1 | day 1 |
| K3 | change | Build REQ-909 (movement rows, history, post and reverse answers, old refusal texts) | M | 3.5 | K2 | day 1 |
| K4 | ba_question (owner or PM answer) | Count rule at the old address: (a) the post issues a quick count and waits for an administrator in My Tasks, so the app gets an answer it does not know (to be tried with the real client); or (b) the shared access sets the balance at once, as the old server did, which needs the owner to amend decision 0091 section 9 and A12 and to state how four-eyes applies. BA recommendation: (b), limited to the old address of a listed tenant, because (a) gives the storekeeper an unknown answer, so the count would not work unchanged | decision | 2.0 | — | day 1 |
| K5 | requirement | REQ entry for the count as K4 decides (kind `adjustment`, 0 allowed, the row's `qty` is the counted quantity; this amends REQ-909's "qty is a positive number" for count rows) | S | 1.0 | K4 | day 1 |
| K6 | change | Build the count | M | 3.5 | K3, K5 | day 1 |
| K7 | requirement | REQ entry for the code lookup `GET /api/codes/lookup` over `Codes` resolve (read only) | S | 1.0 | — | day 1 |
| K8 | change | Build the code lookup | M | 3.0 | K6, K7 | day 1 |
| K9 | requirement | REQ entry for voice `POST /api/voice` over `VoiceService.draft_audio/2`, answering the old Draft and `source` (no count phrase) | S | 1.0 | — | day 1 |
| K10 | change | Build voice | M | 3.5 | K8, K9 | day 1 |
| K15 | uat_design, then the Qoimeks team's re-run | Update the scenario groups `qoimeks-token` and `qoimeks-retry` to the old shapes; the Qoimeks team re-runs the real client against qoimeks-qa2 | S | 2.5 | K10 | the evidence that closes the gate |
| K11 | requirement | REQ entry for code list, assign and remove; the shared access gains `CodesWrite`, which needs a decision 0091 amendment and a security review | S | 1.0 | — | day 2 |
| K12 | change | Build the code writes | M | 3.5 | K10, K11 | day 2 |
| K13 | requirement | REQ entry for feedback (a tenant store of reports; no Markdown export) | S | 1.0 | — | day 2 |
| K14 | change | Build feedback | M | 4.0 | K12, K13 | day 2 |

K1-K3 are written (REQ-907, REQ-908, REQ-909, this task). K8 is built (REQ-910, the scan lookup
`GET /api/codes/lookup`, decision 0091 section 11d); C7 is served, the code list, assign and remove (C8-C10) are not. The requirement tasks K5, K7, K9, K11 and
K13 can run beside the build chain, since they change only `docs/requirements.yaml`.

Not in the batch, operator and infra checks before the cutover:

- D1 setup check: every place the phones use is linked to an org unit and the tenant has an active
  employee. Otherwise a post gets 422, which the app shows as "silence".
- D2 CORS: only if anyone uses the web build. A question for the Qoimeks team; the APK does not need it.
- D3: which app version is on each phone (0.1.2 with the shared code, or 0.1.3 with pairing).

Not needed: `POST /api/parse` (the app never calls it), and pairing while no production phone runs 0.1.3.

### 5.4 Totals

| Set | Tasks | Engine hours | Engine days (8 h) | With a 30 % margin |
|---|---|---|---|---|
| Day 1: rows 1-6, the code lookup of row 7, row 8, and the re-run | K1-K10, K15 | 1.5 + 3.0 + 3.5 + 2.0 + 1.0 + 3.5 + 1.0 + 3.0 + 1.0 + 3.5 + 2.5 = **25.5** | **3.2** | 33 h, **4.1 days** |
| Everything (adds the code writes and feedback) | K1-K15 | 25.5 + 1.0 + 3.5 + 1.0 + 4.0 = **35.0** | **4.4** | 45.5 h, **5.7 days** |

The 30 % margin covers rework and CI rounds; it is a judgment, not a measurement. The wait for the
owner's count answer (K4) and the Qoimeks team's re-run are not engine time and come on top. The build
tasks run one after another (5.3), so the calendar time is close to the sum, even with two engine
workers.

Where the hours come from: the wall-clock lead time (start to finish) of earlier tasks in the team
database `state/team.db`, read on 2026-11-20:

- S-sized change tasks: T-2188 (shared stock access value rules) 0.9 h, T-2303 0.9 h, T-2316 1.0 h.
- M-sized builds: T-2089 (build REQ-859, the old-address router) 2.7 h, T-2090 (build REQ-860, the
  old-address writes) 3.5 h, T-2282 (old-address retry by client id) 2.0 h, T-2296 (CMMS work request
  routes plus their pins) 3.5 h.
- Requirement tasks: T-2033 0.95 h, T-2035 0.74 h, T-2038 0.82 h.
- uat_design tasks: T-2161 1.1 h, T-2163 0.7 h, T-2283 1.4 h.
- A decision record: T-2087 (build REQ-857, decision 0091 itself) 9.5 h. K4 is only an amendment
  answered by the owner, so it is sized at 2 h. It is the least certain number in the table.

Read with `select started, finished from tasks where id = ?` (hours = (finished - started) / 3600).

### 5.5 Biggest risks

1. **The count rule (K4).** Without a decision, a count cannot be written. If the decision is "waits
   for an administrator", the app gets an answer it does not know, and counting does not work unchanged.
   This is the item most likely to push the total up, or to make the PM bring the owner the alternative
   (staff move to the Letflow web/PWA).
2. **Voice tolerance is unknown (K10).** Nobody has run the old app against Letflow's voice. The Draft
   has nested `skus` and places, and the recognition quality of Letflow's voice service against the old
   prompt (letter names, zone words: G15) may differ even when the shape is right.
3. **Shapes beyond the field list.** The run stopped at the first call, so the later screens were
   never reached with the right paths. Number formats (`qty` as a JSON number from Letflow's decimal
   text), time format and sort orders are checked only by the re-run (K15). Each finding there is
   another round of K2 or K3.
4. **Phone versions (D3).** If any phone runs 0.1.3, it needs pairing (row 10, not sized), and its
   offline queue may hold items with the OLD server's integer item and place ids, which mean
   different items in Letflow (run report, "Offline queue retry"). Before the cutover, the queue on
   each phone must be empty.
5. **CORS (D2).** It was not tested. It matters only for the web build.
6. **Code writes widen the shared access (K11, K12).** Assign and remove need `CodesWrite` on a shared
   credential, so they need a security review and an owner-level amendment of decision 0091. That is
   why they are day 2.

Go gate "real old client compatibility": OPEN, failing. It closes when K1-K10 are merged and the
re-run (K15) passes with the real 0.1.2 client.

## 6. Corrections to decision 0091 found on the way (finding for the PM)

Section "Sources" and sections 6-7 of decision 0091 describe the old app differently from its code:

1. The paths are written without `/api`, but every call has it (`api.dart`).
2. The `Authorization` header is described as "the raw value, not Bearer", but the app sends
   `Bearer <code>` (`api.dart` `ApiClient`), and the build accepts Bearer. The build is right and the
   text is wrong.
3. The catalog is described as a list of `id, name, article, unit, barcode`, but it is an object
   `{skus, locations}` with `code` (`store.go` `Catalog`).
4. The movement `id` is described as an integer, but it is a UUID on the old server and the app reads it
   as text; `quantity` is in fact `qty`.

REQ-907 records the as-built path and these corrections in a new amendment section 11c of decision
0091. REQ-908 and REQ-909 add their shape rules there.
