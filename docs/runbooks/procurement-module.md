# Procurement module: line events, derived status and cancel (GH #3188, REQ-558 parts 1 and 2)

Module `procurement` records, for one line of an **approved** purchase request, who handles it
(officer), which supplier was chosen and which PO or contract it is tied to. The code is
`Letflow.Modules.Procurement.LineEvents`; the routes are in `Letflow.Modules.Procurement.Router`
under `/api/v1/modules/procurement/purchase-requests/:id/lines/:line_no`.

## Operations

| Route | Permission | Event |
|---|---|---|
| `POST .../officer` | `ProcurementLineRecord` | `officer`: `officer_id` (an existing tenant user) |
| `POST .../supplier` | `ProcurementLineRecord` | `supplier`: `source_system`, `identifier`, `display_name` |
| `POST .../reference` | `ProcurementLineRecord` | `reference`: `source_system`, `identifier`, `kind` (`purchase_order` or `contract`) |
| `POST .../cancel` | `ProcurementLineRecord` | `cancel`: `reason` (required, at most 500 characters); marks the line cancelled |
| `GET ...` | `ProcurementRequestRead` | the line view (with `status`, `quantity`, `cancelled`) |

Every POST also takes `idempotency_key` (`A-Za-z0-9._:-`, 1-128 characters). The same key with the same
body returns the first result (HTTP 200, `replayed: true`); the same key with another body is 409
`idempotency_key_reused`. A reference may be recorded before any supplier.

`ProcurementLineRecord` is held by TENANT_ADMIN (via core) and PLATFORM_ADMIN (platform clause); the
manifest has no `role_grants`. The GET is open to the requester and to a holder of
`ProcurementRequestDecide` or `ProcurementLineRecord`; everyone else gets 404.

## Field bounds (validation error names every missing or invalid field; values are never echoed)

Text is trimmed and must not be empty. `source_system` at most 64 characters, `identifier` at most 128,
`display_name` at most 200. There is no supplier or purchase-order table: `identifier` is text and
`source_system` names the system it comes from, for a later mapping.

## Rules

- The newest non-discarded version must be issued and approved (`Decisions.approved?/3`); otherwise the
  operation is 409 `not_approved`. After a revision the new version is unapproved until it is decided;
  events already recorded stay readable with their `version_no`.
- A missing document, a malformed id or line number, a line the request does not have, and another
  tenant's document all answer with the same 404.
- A refusal writes no audit entry; it is counted on `[:letflow, :procurement, :refused]`. A request
  refused by the permission gate (403) is counted by the HTTP metric `[:letflow, :http, :request]`.
- The view shows `officer`, `supplier` and `procurement_document` as `null` when no event of that kind
  exists. The current value is the last event of the kind; `history` lists all of them in the order
  recorded.

## For later slices

- `procurement_lines` gets a row only on the first event of a line. A line without events has **no row**;
  the derived status reads a missing row as fulfilled quantity 0, not assume one row per line.
- `fulfilled_quantity` is initialised to 0 and only read here. Receipt-linked fulfilment (WM-01, WM-02),
  acceptance evidence for work and service lines and the payment-request link are later slices.
- Not built: supplier and PO master, IN-01 mapping, any writer of fulfilled quantity.

## Derived status and cancel (part 2)

Status is derived, never set by a caller (`Letflow.Modules.Procurement.Fulfilment`, exact decimals).
**These definitions are UAT assumptions until the process owner confirms them.**

- Line: fulfilled >= quantity is `fulfilled`; else fulfilled > 0 is `partial`; else a cancelled line is
  `cancelled`; else `open`. A line cancelled after a partial fulfilment stays `partial`; the `cancelled`
  field of the view still shows the mark. A request that is not approved has `status: null` on its lines.
- Request (`fulfilment_status` on `GET /purchase-requests/:id`, next to REQ-544's `state`): all lines
  cancelled is `cancelled`; every line fulfilled or cancelled is `closed`; any fulfilled quantity is
  `partial`; otherwise `null`, and `state` (`approved`) is the status. No approved version gives `null`.
- Cancel is an insert-only `cancel` event (a migration widens the kind CHECK; no table is added). The
  first cancel of a line wins: another cancel of the same line, under any key, returns it with
  `replayed: true`. The mark is keyed by `line_no` and survives a revision that keeps the line number.
- A Closed or Cancelled request refuses a new officer, supplier, reference or cancel with 409
  `request_closed`, the same body shape as `not_approved`. The cancel that closes the request succeeds.

## Attachments (REQ-626 part A, GH #3503)

Files on a purchase request. The bytes are stored once per hash in `repository_artifacts`; the link table
`procurement_attachments` is append-only (a trigger refuses UPDATE and DELETE) and holds one row per file per version.

| Route | Permission | Who |
|---|---|---|
| `POST /purchase-requests/:id/attachments` | `ProcurementRequestWrite` | requester, open draft only |
| `POST /purchase-requests/:id/attachments/:attachment_id/replace` | `ProcurementRequestWrite` | requester, open draft only (`:attachment_id` is the slot id) |
| `GET /purchase-requests/:id/attachments` | `ProcurementRequestRead` | requester or a holder of `ProcurementRequestDecide` (`?version_no=`) |
| `GET /purchase-requests/:id/attachments/:attachment_id/content` | `ProcurementRequestRead` | same |

- Body of the two POSTs: JSON `file_name`, `content_type`, `content_base64`. Refusals: type outside the allow-list 422
  `content_type_not_allowed`, infected 422 `infected`, scanner down 503, over 25 MiB 413, bad name or base64 422 `validation`.
- A request that is submitted has no open draft: attach and replace answer 409 `not_draft` until part B (new version).
- A replace adds a row (same slot and version, `replaces_id` set); the old row and bytes stay and remain downloadable.
  Two partial unique indexes keep each slot a single chain. The literal unique index on
  `(document_id, version_no, slot_id)` of the requirement was **not** used, because it contradicts criterion 5.
- **Known limit:** the JSON body parser caps a request at 2 MiB, so a real upload through these routes is about 1.5 MiB of file. The
  25 MiB rule is enforced in the context. A larger upload needs a body parser or multipart route (a follow-up that touches
  `api_pipeline.ex`).
- Procurement attachments are not counted in the storage usage and not refused by the storage allowance.
