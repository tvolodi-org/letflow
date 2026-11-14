# Fixed asset count (Inv-8, annex 39): specification

Status: specification; slices K1 (the count order, REQ-816, T-1927, assets 0.22.0), K5 (freeze, REQ-820, T-1929, assets 0.24.0) and K2 (open, book lines, typed input, entry log, close, sheet document, sheet marks, REQ-817, T-1928, assets 0.23.0) are built, K3, K4, K6 and K7 are not. K2 narrows one rule of section 3: a counted quantity of a low-value line is a whole number, not any decimal, because the asset ledger policy refuses fractional quantities (a fractional count could never post in K4). Requirement entries REQ-816 to REQ-822 in `docs/requirements.yaml` (planned, added
with this file) are the build slices. Written by the business analyst (task T-1844, 2026-11-13). Test tenant only;
behind a per-tenant flag that is off by default. Nothing here touches production, demo, secrets, DNS, money or the
MES work (`docs/design/mes`).

Marks: **[V]** verified in the named file on origin/main; **[D]** a decision of this spec, taken from the built stock
count design so no new owner question is needed; **[A]** UAT assumption, to be confirmed by the process owner.

## 0. Sources

- Owner decision D-128, `ai-dala-portfolio/DECISIONS.md` (2026-11-13), copied here because that file is outside this
  repository: "build the fixed asset count (official form Inv-8, annex 39) now ... "Who signs" = whoever is assigned
  the role `accountant` (or the role the tenant maps to that step) in the role-based access subsystem and in the
  business process configuration of the tenant; nothing hard-coded, no guessed role name (closes owner question A2:
  the signer is a configured role, not a fixed one) ... Limits unchanged (flags off, nothing on
  production/demo/secrets/money/DNS/public repo)."
- `docs/assets/kz-forms-mapping.md` section 3.6 (Inv-8 and Inv-16 rows), section 3.7 row 39 (`ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ
  ТҮГЕНДЕУ ТІЗІМДЕМЕСІ`), section 6 row 39 ("asset count (not built)"; signers M, C, "checked by (A)").
- `docs/assets/government-lists.md`, `docs/assets/asset-register.md`, `docs/assets/asset-workflow-documents.md`.
- Decision 0079 (`docs/migration/decisions/0079-counts-inventory-taking.md`) sections 2 to 9: the stock count design.
- Built stock count code [V]: `lib/letflow/modules/stock/counts.ex` (order, commission, scope, states
  `draft ordered counting counted signed posted cancelled`, 96-hour planned period, per-unit advisory lock at issue,
  `count_assigned` notification), `count_sheet.ex` (cut-off, book lines from `Ledger.balances/4` after
  `Ledger.hold_exclusive!/2`, typed and scanned entries, append-only entry log), `count_differences.ex` (chair marks
  the paper signatures of the exact signer set, differences built from the ISSUED sheet content, 200-line cap),
  `count_posting.ex`, `freeze_state.ex` and `freeze_guard.ex` (freeze of the counted locations, limit setting
  `count_freeze_limit_minutes`, default 120), `count_print.ex` (PDF in ru, kk, en), `form_count_inv10.ex` with
  `lib/letflow/documents/form_print.ex` (official forms, ru and kk only, `priv/print_forms/*.json`).
- Built asset code [V]: `lib/letflow/modules/assets/assets.ex` (version 0.25.0; ledger `assets` with the slots
  asset, org_unit, location, material_responsible, actual_user; causes commission, change, handover, writeoff,
  kind_change_in; permissions AssetsCardWrite, AssetsPost, AssetsReverse, AssetsRead, AssetsReconcile with no role
  grants; settings currency, expiry_reminder_lead_days, storekeeper_grants), `cards.ex` (the card has no location,
  quantity, responsible person or condition field), `documents.ex` and `documents/kinds.ex` (kinds commission ACM,
  change ACH, handover AHO, writeoff AWO, kind_change AKC, opening AOP), `documents/shape.ex` (write-off reasons
  `disposed lost broken expired other`), `access.ex` (only tenant-wide interactive users reach asset routes).
- Role routing today [V]: a HUMAN_TASK node carries `attributes.role`; `Letflow.Engine.TaskActivation.resolve_assignee/1`
  makes it a `ROLE` task whose `assignee_ref` is that name; `Letflow.Identity.TenantRole` rows of kind
  `process_routing_role` bind a role name to a group (`POST /roles`, `Letflow.Identity.RoleRegistry.upsert_role/4`,
  names up to 128 codepoints); `Letflow.Tasks.resolve_principal_scope/2` gives a user's `role_names` through their
  groups, and claim and reassign of a ROLE task check `ref in scope.role_names`. The QA tenant swiftroute already
  routes a finance task to the routing role `role-accountant` (`test/fixtures/uat/actors.yaml`, actor-swiftroute-hans).

## 1. Shape [D]

The asset count copies the built stock count flow, inside module `assets` (boundary Rule 4: `assets` does not call
`stock`; `Letflow.Modules.Assets.Documents` already copies the stock glue for the same reason). It reads and never
writes the asset ledger. Three versioned documents (`Letflow.Documents`):

| Document | Type key | Number prefix | Content |
|---|---|---|---|
| Count order | `assets_count.order` | ACO | one org unit, optional location subtrees, asset kinds, planned period, chair and members, freeze switch |
| Count sheet (Inv-8) | `assets_count.sheet` | ACS | the lines of section 3 with book data at the cut-off and the counted result |
| Count result | `assets_count.result` | ACR | the difference lines, the decision of each line, the documents it produced, the signer |

States of a count: `draft`, `ordered`, `counting`, `counted`, `sheet_signed`, `signed`, `cancelled`. Cancel is allowed
in `draft`, `ordered`, `counting`, `counted` and `sheet_signed`, refused from `signed` (as 0079 section 2).

## 2. Count order [D]

- One org unit per order (as stock). Scope: the org unit plus, optionally, location subtrees linked to it; empty
  location list means the whole org unit. Kinds: a non-empty subset of `fixed`, `low_value`, `intangible` (the card
  enum). Intangible assets have no location slot; they are counted in the org unit only.
- Commission: a chair and members, all `org_employee` records; the chair must be linked to a user (stock rule).
- Planned period at most 96 hours; overlapping open asset counts of one org unit are refused `count_scope_overlaps`.
- Two open counts never share a book key, so no double counting across orders (0079 section 6).

## 3. Count sheet: book data, typed and scanner input [D]

- **Open** (chair): the server time is the cut-off. Under `Ledger.hold_exclusive!(prefix, "assets")` the book lines are
  read with `Ledger.balances/4` of ledger `assets` at the cut-off, one line per balance key with quantity above zero
  inside the scope, with card data: inventory number, name, kind, acquisition date, acquisition cost, book value
  (stored values, never calculated).
- **Typed input**: a fixed or intangible line is `found` or `not_found` (counted 1 or 0); a low-value line takes a
  counted quantity (decimal text, strict). Each line can carry the observed location (a location of the scope), the
  observed material responsible and actual user (employees), and a condition from the closed list `in_use`,
  `not_in_use`, `damaged`. A typed value replaces the previous one; the old value stays in the entry log.
- **Scanner input** (keyboard wedge, text plus Enter): the text is first resolved with `Letflow.Modules.Codes.resolve/2`.
  A location code inside the scope sets the current location of the scanning user's following scans (answered with
  the location, nothing counted). A code with another target is "not countable here". A text no code knows is looked
  up as an exact `inventory_number` of an active card (unique per tenant, D-097). Codes cannot target an asset card
  today (`@targets` of `lib/letflow/modules/codes/writes.ex` is location_node, catalog_item, catalog_lot), so the asset
  label carries the inventory number; asset cards as code targets are out of scope.
  A second scan of a found fixed asset is answered "already counted" and logged, not counted twice; a scan on a
  low-value line adds one. A scanned asset whose card has no book key in the scope becomes a surplus line.
- **Surplus line**: an active card found in the scope with no book line, or an object with no card (free description
  only, up to 500 characters).
- Every entry is stored with user and server time in an append-only log. **Close** issues the sheet document from the
  line records; the chair then marks the paper signatures of the exact set: chair, every member, every material
  responsible person of a sheet line (stock rule, `count_differences.ex`).

## 4. Differences and what they do to the register [D]

Built from the CONTENT of the issued sheet, never from live lines. One result line per sheet line with a difference:

| Difference | When | Proposed decision | What signing produces |
|---|---|---|---|
| `shortage` | fixed or intangible not found; low-value counted below book | `writeoff` | a DRAFT write-off (reason `lost`, reason text "count" and the sheet number, from-side = the book key, quantity = book minus counted) |
| `location_mismatch` | found, observed location differs from the book location | `handover` | a DRAFT hand over from the book key to the observed location (same org unit and responsible unless they differ too) |
| `responsible_mismatch` | found, observed responsible or actual user differs, location equal | `change` | a DRAFT change of responsible or user |
| `surplus_registered_elsewhere` | surplus line of a card with a book key outside the scope | `handover` | a DRAFT hand over from that book key to the observed key |
| `surplus_unregistered` | surplus line of an active card with no book key anywhere; low-value counted above book | `commission` | a DRAFT commission of the found quantity to the observed key |
| `surplus_no_card` | surplus line without a card | `no_register_change` | nothing; the recorded decision text says what the accountant will do (create the card, then a commission) |
| `condition` | condition `damaged` or `not_in_use` | `no_register_change` | nothing, or a DRAFT write-off with reason `broken` if the signer chooses `writeoff` |

Rules:
- **No silent change.** The count never posts. Signing produces only DRAFT asset documents of the existing kinds (no
  number is taken until issue) or a recorded decision. Each draft is issued and posted later by an `AssetsPost` holder
  through its own existing flow and checks; the register changes only then. The result shows each line's draft id
  and its live state (draft, issued, posted, cancelled).
- The signer may change a line's decision to `no_register_change` with a reason text (1 to 500 characters); every
  other choice is limited to the table's alternatives for that difference.
- A draft's `event_time` is the signing time; it is a normal draft, so the issuer may replace it before issue if the
  96-hour window of 0073 D-T has passed.
- One signing makes all drafts and the result document in one transaction, or nothing. A result with more than 200
  lines is refused before any write (the stock cap).

## 5. Signed result and the signer [D]

- **Signer = a configured role.** Module setting `count_signer_role` of the tenant's `assets` install (a string of 1 to
  128 codepoints, the `RoleRegistry` name limit); absent means the default `"accountant"`. The tenant administrator
  sets it with the existing `PUT /tenant/modules/assets/settings` (`ModulesManage`). The tenant maps people to it in the
  role-based access subsystem as for any process step: a `process_routing_role` row with that name bound to a group
  (`POST /roles`), and users in that group. A tenant that uses the swiftroute naming sets `role-accountant`.
- **Who may sign**: an interactive user who reaches the asset routes (`AssetsRead`, tenant-wide, the existing guard) AND
  holds the configured role through a group (`Letflow.Tasks.resolve_principal_scope/2`, only rows of kind
  `process_routing_role` count). TENANT_ADMIN and PLATFORM_ADMIN get no bypass: an administrator who is not in the
  role's group is refused like anyone else.
- **No silent fallback**: if the tenant has no `process_routing_role` row with the configured name, the count screen
  shows "the signing role <name> is not set up in this company" and the sign action is refused
  `signer_role_not_configured`; a user outside the role gets `signer_role_not_held`. The count stays `sheet_signed`.
- The signature is recorded in Letflow as the signer's action with time (not ЭЦП; 0079 section 9).

## 6. Freeze reuse [D]

Order switch `freeze_locations` (default off), as stock: from the cut-off until the result is signed, the count is
cancelled or the limit runs out (setting `count_freeze_limit_minutes` of `assets`, 1 to 5760, default 120), issuing an
asset document whose side falls in the frozen scope (org unit and location subtree; org unit only for intangible lines)
is refused `count_in_progress`. The check runs in the asset module's issue checks. The asset ledger is separate from
the stock ledger; **no shared-ledger or stock-policy change is needed** (the ledger core has no count vocabulary, 0079
section 4).

Built (K5, T-1929, assets 0.24.0): `CountSheet.open/3` of a freeze order takes the asset issue lock between the
order lock and `Ledger.hold_exclusive!`, and stores `freeze_started_at` (the cut-off), `freeze_until` (cut-off plus
`count_freeze_limit_minutes`, fixed at open), `freeze_whole_unit` and `freeze_location_ids` (roots and all their
sub-locations at the cut-off; at most 5000, else `count_too_large`). `Documents.issue/4` then refuses, inside the
issue lock and before a number is taken, a document with a side in the frozen scope: `422 count_in_progress` with
`held_by` (the order number). Drafts are never refused. The freeze ends when the order is `cancelled` or `signed` or
the limit runs out. The order view shows `freeze_state`, `freeze_started_at`, `freeze_until`. The freeze does not read
`count_enabled`: switching the flag off does not end a running freeze, the limit does. Known gap: a document issued
before the cut-off whose posting completes during the freeze is not refused (it needs a posting guard on the ledger,
a ledger-policy change); the book read stays exact because the hold and `cutoff_seq` leave later postings out.

## 7. Print [D]

- Official Inv-8 / Түг-8 of the issued sheet in ru and kk, PDF and DOCX, through `Letflow.Documents.FormPrint` with a
  layout `priv/print_forms/inv8.json` (planned). English is not an official-form language of `FormPrint`; the plain
  count sheet print (the `count_print.ex` pattern) gives ru, kk and en.
- Filled: organisation and BIN, sheet number and date, order number and date, cut-off date, location (when the order
  names one), commission chair and members (name and position), material responsible persons, line number, name,
  inventory number, acquisition date, counted quantity, book quantity, book cost = the card's `book_value` as stored
  [A]. Blank, never invented: accounts, factory and passport numbers, release date, actual cost, actual start and end,
  sums in words, signatures, the checker (G5, G6, G10, G11, G12 of kz-forms-mapping).
- The Inv-16 comparison sheet is not part of this spec.

## 8. Audit, permissions, flag

- Every accepted write appends one audit entry in its transaction (`assets_count.created`, `updated`, `issued`, `opened`,
  `entry_recorded`, `closed`, `sheet_signed`, `result_signed`, `cancelled`), ids and states only, no quantity; a database
  failure of the entry rolls the write back (`audit_failed`).
- Permissions: `AssetsCountOrder` (create, edit, issue, cancel) and `AssetsCountRecord` (open, entries, close, sheet
  marks), new atoms with no role grants, so TENANT_ADMIN holds them, like every assets atom; reads use `AssetsRead`;
  signing uses `AssetsRead` plus the configured role (section 5). No step needs PLATFORM_ADMIN.
- Flag: module setting `count_enabled` (boolean) of `assets`; absent or false, every asset count route answers 404 as for
  a tenant without the module. Set to true in the test tenant only.
- Bell notification: out of scope (the closed kind list `task_assigned count_assigned` of
  `lib/letflow/user_notifications.ex` points `count_assigned` at the stock count screen).

## 9. Build slices

| Slice | Requirement | Content | Size | After |
|---|---|---|---|---|
| K1 | REQ-816 | order, scope, commission, settings (flag, signer role, freeze limit), routes, audit | M | - |
| K2 | REQ-817 | open, book lines, typed input, entry log, close, sheet document, sheet marks | L | K1 |
| K3 | REQ-818 | scanner input | M | K2 |
| K4 | REQ-819 | differences, decisions, signing by the configured role, drafts | L | K2 |
| K5 | REQ-820 | freeze | M | K2 |
| K6 | REQ-821 | Inv-8 print and plain sheet print | M | K2 |
| K7 | REQ-822 | web screens | L | K3, K4 |

Sizes: M = one sitting of a developer, L = one long sitting; a slice that grows past that is split by its designer.
