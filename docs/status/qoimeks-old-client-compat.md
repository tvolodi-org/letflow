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
- **Go gate "real old client compatibility": OPEN, failing.** It stays failing until REQ-907..909 are
  built and the count, scan and voice items the PM picks are built and re-run with the real client.

## 1. Sources (opened for this note)

| Source | What was read | Copy for the gate |
|---|---|---|
| Qoimeks repository at commit `01e8780` (2026-10-30 is the last change of `mobile/lib/api.dart`), `mobile/lib/api.dart` | every call (`_get`, `_post`, `_delete`, the multipart voice call, the pairing call), the headers, and the `fromJson` of every answer the app reads | `state/tasks/T-2374/sources/qoimeks-mobile-api.dart` |
| Qoimeks `server/internal/api/api.go` lines 145-165 | the route table of the old server: `GET /api/catalog`, `GET /api/balances`, `GET /api/movements`, `POST /api/movements`, `POST /api/movements/{id}/reverse`, `POST /api/parse`, `POST /api/voice`, `POST /api/feedback`, `GET /api/feedback`, `GET /api/feedback/export.md` (plus `codes.go`: `POST/GET /api/codes`, `GET /api/codes/lookup`, `DELETE /api/codes/{id}`; `pair.go`: `POST /pair/v1/exchange`) | `sources/qoimeks-api-routes.go.txt` |
| Qoimeks `server/internal/store/store.go` | the JSON field names of `SKU`, `Location`, `Catalog` (`skus`, `locations`), `Balance` (`sku_id, location_id, location_code, qty`), `Movement` (`id` UUID, `kind`, `sku_code`, `sku_name`, `unit`, `location_code`, `to_location_code`, `qty`, `operator`, `reverses`, `reversed_by`, `created_at`, `balances`). The catalog and the places are sorted by code; balances are the non-zero ones sorted by place code; the history list carries `balances: []`; post and reverse carry the balance after the movement at each place it touched; a reversal keeps the kind of the original and sets `reverses` | `sources/qoimeks-store-catalog.go.txt`, `sources/qoimeks-store-movement.go.txt` |
| Qoimeks `server/internal/store/import.go` line 281 | imported balances are written as kind `adjustment` | quoted here |
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
| C4 | `POST /movements`: kinds `receipt`, `issue`, `transfer` posted; `qty` accepted; client `id` required (201, 200 on a repeat, 409 with the old text); answer in the C3 shape | receipt 201, repeat 200, changed data 409, no id 400; the answer breaks the app | works for receipt, issue and transfer; answer shape different; `adjustment` missing (400 `invalid kind`) | none for the answer | answer in REQ-909; adjustment L | REQ-909; adjustment: section 5 item B1 (needs a rule) |
| C5 | `POST /movements/:id/reverse`: integer id; 201, 200 on a repeat, 409 `document_reversed`; answer as C3, no `reverses` | worked at `/movements/{int}/reverse` | works; answer shape different; the id the app passes comes from C3 | none for the answer | in REQ-909 | REQ-909 (the id is the text of the same integer, so the path keeps working) |
| C6 | not served (404); `voice_service.ex` exists for personal accounts with the same form keys `audio` and `lang`, answering Letflow's draft | not tested (404) | missing | unknown: the run must show the Draft shape and the `source` error field are read as in `api.dart` | M | section 5 item B3 |
| C7 | not served; `POST /codes/resolve` exists (permission `CodesRead`) | not tested (404) | missing | unknown: the run must show the scan finds an item and a place, and `code_not_found` gives "nothing found" | M | section 5 item B2 |
| C8-C10 | not served; codes assign and release exist (`CodesWrite`) | not tested (404) | missing | unknown | M (and the shared access gains a write permission: a decision 0091 amendment and a security review) | section 5 item C1 |
| C11 | not served; no feedback store in Letflow (readiness row G19) | not tested (404) | missing | a 404 is not shown as an error: the app keeps the report on the phone as "send later" (`feedback.dart` `submit`, kept up to its pending cap) and resends it after the next successful call, so reports pile up on the phone and never arrive | M | section 5 item C2 |
| C12 | not served | not tested | missing; not on production phones (0.1.2) | not needed for day 1 | — | none now; revisit only if 0.1.3 is rolled out |
| auth | `Authorization: Bearer <value>` accepted; 401 is a problem body (`status`, `type`, `title`, `detail`, `trace_id`) and never carries `error` | Bearer accepted; raw value, `X-Access-Token` and `X-Api-Key` give 401 | works as is | the app decides by status 401 ("wrong access code"), so the body shape does not matter | — | none |
| errors | refusals are `{"error": text}`; 422 for `location_not_linked` and `no_responsible_employee` | 400 `invalid quantity` in place of "quantity must be positive" | works, different text | the app shows 422 as the voice "silence" text: a misleading message for a place with no org unit | S | section 5 item D1 (setup check, not a code change: every place used by the phones has an org unit and the tenant has an employee) |
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
| Voice count phrase | C6 is not extended to count by voice (if B3 is built, a voice draft with kind `adjustment` is not offered) |
| Tokens screen | none (REQ-861 cancelled; the shared access is managed through the admin API) |

## 5. Prioritised batch of product tasks for the PM

Sizes: S is one small change with its tests. M is one change across two or three files in one sitting.
L is bigger than one change, or waits on a decision (split it before building).

| Order | Item | Size | Status | Go gate |
|---|---|---|---|---|
| A1 | **REQ-907**: serve the old calls under `/api` (`/qoimeks/:slug/api/catalog`, ...) | S | requirement written (this task) | blocks everything |
| A2 | **REQ-908**: catalog `{skus, locations}` and balances `location_code`, `qty` in the old shape | M | requirement written (this task), after REQ-907 | blocks everything |
| A3 | **REQ-909**: movement rows in the old shape for history, post and reverse (text id, old kind names, codes, unit, `qty`, `operator` text, `reverses` / `reversed_by`, `balances` after the movement) | M | requirement written (this task), after REQ-908 | blocks posting and history |
| A4 | Re-run of the real client against qoimeks-qa2 after A1-A3 (Qoimeks team; a `uat_design` task updates the scenario groups `qoimeks-token` and `qoimeks-retry`, whose expectations name Letflow's current fields) | S | to queue after A3 | evidence for the gate |
| B1 | **Count (`adjustment`) at the old address**: the app sends the counted quantity and the old server sets the balance at once. Letflow's count is the quick count (`POST /quick-counts`), and on the Qoimeks QA tenant four-eyes is ON for the quick count (tenant state as stated by the PM on 2026-11-19 in the BA role text; UAT assumption, to be confirmed by the process owner for production), so an administrator must approve it. Decision 0091 section 9 says the shared access cannot count, and A12 says it cannot approve. A rule is needed first: (a) the old address issues a quick count and the post waits for an administrator in My Tasks, so the app gets an answer saying "waiting" (a shape the app does not know: it must be tried with the real client); or (b) the shared access posts the count at once (needs the owner to amend 0091 A12 and four-eyes). | L (decision, then M) | NEEDS a rule from the PM or owner | storekeepers lose counting on day 1 without it |
| B2 | **Code lookup** `GET /api/codes/lookup` over `Codes` resolve (scan to find, scan in the operation form; `CodesRead` is read-only) | M | requirement after the PM picks it | storekeepers lose scanning on day 1 without it |
| B3 | **Voice** `POST /api/voice` over `VoiceService.draft_audio/2`, answering the old Draft shape and `source` on a speech or model failure; the letter names and zone words stay readiness row G15 (T-2035) | M | requirement after the PM picks it | voice is lost on day 1 without it |
| C1 | Code list, assign and remove (C8-C10): the shared access gains `CodesWrite`, which needs a decision 0091 amendment and a security review | M | requirement after the PM picks it | day 2 (scan to find works without it) |
| C2 | Feedback `POST /api/feedback`: a tenant store for reports (no Markdown export) | M | requirement after the PM picks it (readiness row G19, T-2038) | day 2 |
| D1 | Setup check: every place the phones use is linked to an org unit and the tenant has an active employee (otherwise a post gets 422, shown as "silence") | S | operator check before the cutover | day 1 |
| D2 | CORS, only if anyone uses the web build | S | question for the Qoimeks team | none for the APK |
| D3 | Which app version is on each phone (0.1.2 shared code, or 0.1.3 with pairing, C12) | — | infra check | needed before the cutover |

Not needed: `POST /api/parse` (the app never calls it), and pairing C12 while no production phone runs
0.1.3.

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
