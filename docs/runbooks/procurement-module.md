# Procurement module: line events (GH #3188, REQ-558 part 1)

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
| `GET ...` | `ProcurementRequestRead` | the line view |

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

- `procurement_lines` gets a row only on the first event of a line. A line without events has **no row**:
  derived status (part 2) must read a missing row as fulfilled quantity 0, not assume one row per line.
- `fulfilled_quantity` is initialised to 0 and only read here. Receipt-linked fulfilment (WM-01, WM-02),
  acceptance evidence for work and service lines and the payment-request link are later slices.
- Not built: supplier and PO master, IN-01 mapping, derived line and request status and cancel (part 2).
