# 0086 — Saved stock balance report (slice 0, decision only)

Status: proposed (2026-11-11, REQ-790, GH #4140). Specification only: no code, no migration, no definition JSON, no
route, no screen, no test, no seed, no new permission. Decision 0066 and every other file are unchanged. Build
requirements follow this record (section "Later work"). **REVIEWER sign-off: PENDING.**

Sources: the BA decision `docs/uat/ba-decisions/T-1665.md` item 2; REQ-790 in `docs/requirements.yaml`;
`docs/assets/government-lists.md` sections 2, 6 and 7; decision 0066 (D1 to D7); `lib/letflow/modules/stock/router.ex`
(`@balance_keys`, `GET /balances`); `lib/letflow/modules/stock/views.ex` (`stock_balance/1`);
`lib/letflow/modules/stock/xlsx_export.ex` (`@balance_header`); `lib/letflow/ledger/read.ex`;
`web/src/modules/stock/register/BalancesPage.tsx`; `web/src/lib/references/useReferenceLabels.ts`; `docs/roles.md`
(module `stock` row, `EntitiesViewsManage` row).

## Problem

The stock balances screen answers one question at a time: the reader types the filter (one warehouse, one item over all
locations) every visit. An administrator wants to store such a filter once, under a name, and let every reader of the
tenant reopen it. The report builder cannot hold it: a saved view belongs to one entity type and is replayed through
`POST /entities/query` (0066 D2, D3), and a stock balance is a ledger row, not a record
(`docs/assets/government-lists.md` section 2); the builder accepts no join key. The shape of a saved report over the
ledger is therefore a decision not yet taken. It is the repeatable form of pilot measure M2 and a gate for the
government-list reports.

## Decisions

Each decision gives its source, or is marked ASSUMPTION for the process owner to confirm.

### D1. Scope: one saved report is a saved filter of the balances list

One saved report gives one row per balance row of `GET /api/v1/modules/stock/balances` on the latest basis, with the
columns of the `stock_balance` view: `sku`, `location`, `org_unit`, `responsible`, `lot`, `unit_ref`, `quantity`,
`last_posting_seq` (exactly the keys of `Letflow.Modules.Stock.Views.stock_balance/1` and the `@balance_header` of
`xlsx_export.ex`). `last_posting_seq` is a ledger sequence number, not a date. There is no price, value or date column:
the price of a balance is a money rule for the owner (`government-lists.md` section 7 question 3). This is not the
five-column government stock list of `government-lists.md` section 2.

### D2. Storage: a new table in the tenant schema, owned by the stock module

A saved stock report is stored in one new table of the tenant schema (schema-per-tenant `:prefix`, `tenant_id` kept in
the table, INV-1, INV-6): name unique per tenant, the stored filter keys (D3), actor and timestamps of creation and last
change. Reason: the existing `entity_views` table is typed by one entity type and its replay path is the entity query
(0066 D2, D3); putting a ledger filter there would need a fake entity type and weaken that invariant. Decision 0066 is
therefore unchanged. The stored row holds no balance value; it holds only the filter. The migration belongs to the
server build requirement, not to this record.

### D3. Stored keys: a closed list

A saved report stores the report name and a subset of exactly these filter keys: `sku`, `location`, `org_unit`,
`responsible`, `lot`, `scope_subtree` (the slot and subtree keys of `@balance_keys` in the stock router). `basis`,
`cutoff_seq`, `as_of`, `as_of_date`, `limit`, `cursor` and `format` are never stored: they are per-call choices, and a
stored cutoff would make the report stale. A stored key outside the list is refused at write time with `422` and the one
reason code `saved_report_key_not_allowed`, and nothing is written (no row, no audit entry).

### D4. Replay: an ordinary call of the balances read

A saved report is replayed by the client as an ordinary `GET /api/v1/modules/stock/balances` with the stored keys as
query parameters, under the caller's own authorization: `StockRead` and the scoped read of `Letflow.Ledger.Read` with
its coverage key (`lib/letflow/ledger/read.ex`). No saved-report route returns a balance row, so there is no second read
path. Replay may ask for `format=xlsx` (the existing `stock-balances.xlsx` file), as one choice: the file is the same
read, already gated by the same permission, and the pilot accountant needs the file. Decision: yes, xlsx is allowed and
unchanged.

### D5. Names: shown by the client, not joined by the server

The item and the location are shown as `code - title` by the shared reference label of the web client
(`web/src/lib/references/useReferenceLabels.ts`), as `BalancesPage.tsx` already does. The server adds no joined column.
The xlsx file keeps the ids of `@balance_header` unchanged; names in the xlsx are an open owner question.

### D6. Permissions: existing atoms only

- List saved reports: `StockRead` (every reader may reopen a report; a report gives no reader a balance row that
  `GET /balances` does not already give that reader).
- Create, rename, delete: `StockReconcile` (module `stock` row of `docs/roles.md`: held by TENANT_ADMIN and
  PLATFORM_ADMIN, not STOREKEEPER).

No new permission atom. The role choice is an ASSUMPTION for the process owner to confirm (see Open owner questions).

### D7. Isolation and audit

A saved report of another tenant, an absent id and a malformed id answer the identical `404` (INV-5). No saved-report
route takes a tenant identifier (INV-10); the tenant comes from the credential. Create, rename and delete write an audit
entry in the same transaction as the change; a refused write writes none (as 0066 D7).

## Tests the build requirements must carry

| # | Test | Proves |
|---|---|---|
| T1 | A TENANT_ADMIN of tenant B reads, renames and deletes a saved report that exists only in tenant A and gets the same `404` as for an absent id; the tenant A row is unchanged | D7, INV-5, INV-10 |
| T2 | A scoped reader replays a saved report and gets only the rows of its own units and the coverage key, exactly as the same filter typed by hand | D4, INV-2 |
| T3 | A write with a stored key outside the D3 list answers `422 saved_report_key_not_allowed` and writes no audit entry | D3, D7 |
| T4 | The stored row holds no balance value (only name, filter keys, actor, timestamps) | D2 |
| T5 | A reader without `StockReconcile` is refused create, rename and delete; a `StockRead` holder lists | D6 |
| T6 | Web: the list, the replay and the xlsx download show names as `code - title`; all states and languages (en, ru, kk) per the design-system matrix | D4, D5 |

## Later work

Build requirements to be registered after this record is accepted (no REQ ids yet):

1. Server part: the tenant table and migration, the list, create, rename and delete routes under the stock module with
   the D6 permissions, audit, route-scope pins, and tests T1 to T5.
2. Web part: a "saved reports" selector on the balances screen, a save and rename and delete dialog for administrators,
   and the screen state matrix, test T6.

## Open owner questions

No answer is given to any of them here.

1. Who may save a report: the D6 choice of `StockReconcile` (administrators only) or also the storekeeper?
2. Is a report as of a date wanted (`government-lists.md` section 6, the "list as of a date" row)? It would need a stored
   or per-call date and a decision on `as_of` basis.
3. The price and value of a balance (`government-lists.md` section 7 question 3).
4. Names instead of ids in the xlsx file.
