# 0090 -- Negative balances as a per-tenant setting of a ledger registration

Status: PROPOSED (T-2059, 2026-11-16; REQ-833, issue #4548; part 1 of the Qoimeks parity item G4). QA only; production is
not approved by this record. Documents only: no code, no migration, no route and no permission change in this part. The
later parts build on the names fixed here: REQ-834 (core guard, storage), REQ-835 (route and permission), REQ-836 (module
stock opts in), REQ-837 (converter and runbook), REQ-838 (web warning), REQ-839 (web admin page), REQ-840 (mobile warning).
Every flag introduced by those parts defaults to refuse (OFF).

The number 0090 was the next free one on origin/main at T-2059 (0089 is the highest in `docs/migration/decisions/`).

**Amends** [0073](0073-domain-neutral-ledger-primitive.md) D5 ("non-negative balance" among the mechanical invariants core
enforces) and touches [0057](0057-wms-customer-draft-reconciliation.md) D5 (stock may not go below zero); each of the two
gets one "Amended by 0090" paragraph at its end and no earlier line of either is edited.

Marking: a rule that does not come from the owner decision (O), a Qoimeks source (Q) or an existing decision record (R) is
marked **assumption, owner may change** and is listed in the owner table (section 8).

## Sources (checked)

Owner decision, 2026-11-16, relayed by the PM: "Do whatever needed to support old Qoimeks functionality, not less but
possible more"; parity for negative balances, with a per-tenant setting whose default stays refuse (O).

Qoimeks behaviour (read only, outside this repository; copied extracts are in `state/tasks/T-2027/sources/`):

- `Qoimeks-team/project/client1-inventory.md` section 4 count 8 (balance rows with a negative quantity, and with zero),
  section 8.3 ("Negative balances allowed (warning «Остаток станет отрицательным»)"), section 8.4 (a count replaces the
  balance; other kinds shift it), section 8.5 (a movement is reversed once, a reversal cannot be reversed).
- `Qoimeks/server/internal/api/api_test.go` around line 119: the comment "Issuing more than is there is allowed; the
  balance simply goes negative." (b1 holds 18, issue 25, answer 201, balance -7).
- `Qoimeks/server/internal/store/store.go`, `func reverse`: appends `-leg.Delta` for each leg of the original with no
  balance check (reversing a receipt whose stock was already issued also goes negative).
- `Qoimeks/mobile/lib/operation_screen.dart` lines 652 and 689-692: `goesNegative = here != null && q != null &&
  (_kind == 'issue' || _kind == 'transfer') && q > here`; the warning banner (`StatusKind.warning`) is shown before
  posting and does not block it.
- `Qoimeks/mobile/lib/l10n.dart` line 23 (ru) `'will_be_negative': 'Остаток станет отрицательным'`, line 153 (kk)
  `'will_be_negative': 'Қалдық теріс болады'`.

Letflow files (all checked on origin/main at T-2059 with
`git ls-tree origin/main lib/letflow/ledger.ex lib/letflow/ledger/codes.ex lib/letflow/ledger/read.ex lib/letflow/ledger/reconcile.ex lib/letflow/modules/ledger_registration.ex lib/letflow/modules/assets/assets.ex lib/letflow/modules/stock/stock.ex lib/letflow/modules/stock/count_posting.ex lib/letflow/modules/stock/documents/shape.ex lib/letflow/modules/stock/documents/opening_shape.ex lib/letflow/approval_rules.ex lib/letflow/routers/approval_rules.ex lib/letflow/api/authorization.ex priv/repo/migrations/20261104200001_create_ledger_partitioned_tables.exs priv/repo/migrations/20261115200001_create_approval_rule_settings.exs docs/design/four-eyes-switch.md scripts/pilot/qoimeks_convert.py docs/status/qoimeks-migration-readiness.md`,
all 18 paths listed, none missing):

- `lib/letflow/ledger.ex`: `refusal_for/5` answers `insufficient_balance` when the new on-hand of any locked key is below
  zero, and `balance_bound_exceeded` through `over_bound?/2` at `@limit` (1.0E+21) or above or over `max_on_hand`.
- `lib/letflow/ledger/codes.ex`: `insufficient_balance` is 409; the stock registration aliases it to `insufficient_stock`
  (`error_aliases` in `lib/letflow/modules/stock/stock.ex`).
- `priv/repo/migrations/20261104200001_create_ledger_partitioned_tables.exs`, `balance_sql/1`: `ledger_balance` carries
  CHECK `ledger_balance_on_hand_check` (`on_hand >= 0` and `on_hand <= max_on_hand`) on `on_hand numeric(30,9)`.

## 1. The rule change

1. Decision 0073 D5 changes from "core enforces a non-negative balance" to: core enforces **the registration's negative
   balance mode**. The mode is declared by the registration, in one optional registration key of
   `Letflow.Modules.LedgerRegistration` named `negative_balance` with the values `:refuse` and `:tenant_setting`
   (names fixed here; REQ-834 uses them unchanged). (R/O)
2. A registration that does not declare the key means `:refuse`: the assets ledger (`lib/letflow/modules/assets/assets.ex`)
   and every test registration refuse below zero exactly as today. Any other value of the key fails validation with its
   own closed reason `invalid_negative_balance`, appended to the reason order in the `LedgerRegistration` moduledoc.
3. A registration that declares `:tenant_setting` follows the tenant's setting (section 5): **no stored setting means
   refuse**. The default of every tenant is therefore unchanged by this decision. (O: "default stays refuse")
4. The setting never touches the ledger rules of another registration of the same tenant.

## 2. The refuse-mode rule

Under refuse a posting is refused `insufficient_balance` **only when a balance key it lowers ends below zero**. A key a
posting does not lower (a leg with quantity zero or above on that key, summed per key) is not judged, even if its
on-hand is already negative. This rule gives the same answer as today on every ledger that has never held a negative
balance, so no existing test or tenant changes (assumption, owner may change: no owner text covers a key that is already
negative; the alternative "refuse while any touched key is negative" would block the receipt that repairs it).

Worked cases:

| Case | Setting | On-hand | Posting | Answer |
|---|---|---|---|---|
| A | refuse | 5 | issue 7 | refused `insufficient_balance` (the key would end at -2) |
| B | refuse | -2 (left by an earlier allow period) | receipt 3 | accepted, the key reads 1 (the posting raises the key) |
| C | allow | 5 | issue 7 | accepted, the key reads -2 |

The refusal details (REQ-686 `available` disclosure, reversal `leg_nos` and `count`) are unchanged.

## 3. The database bound

1. CHECK `ledger_balance_on_hand_check` (`on_hand >= 0`) is **dropped** by one tenant migration (REQ-834). The
   separate CHECK on `max_on_hand` (`on_hand <= max_on_hand`, migration `balance_sql/1`) stays untouched; the guard
   keeps refusing `balance_bound_exceeded` over `max_on_hand` as today.
2. The column type `numeric(30,9)` is the database lower bound: Postgres refuses an absolute value of 10^21 or more as
   `numeric_value_out_of_range` (SQLSTATE 22003), so a CHECK at -1.0E+21 could never fire and none is added.
3. The guard refuses `balance_bound_exceeded` when a key would end at **-1.0E+21 or below**, mirroring the upper `@limit`
   (details as for the upper bound: the `leg_no` list). This applies under allow; under refuse the key already fails at
   zero.

## 4. What each other ledger rule does with a negative balance

| Rule | Row |
|---|---|
| `max_on_hand` and `key_bounds` | Unchanged. An upper bound only; a negative on-hand is below any upper bound. The stock registration has `key_bounds: []`. |
| Unit pin | Unchanged. A negative key keeps its `unit_ref`; a leg in another unit is `unit_mismatch` first (the first branch of `refusal_for/5`). |
| Append-only storage | Unchanged. Entries and legs are never updated or deleted; a negative balance is a derived value. |
| Zero-sum per cause | Unchanged. Transfer, hand over and return stay zero sum per slot 1; only the balance judgement changes. |
| Gap-free counter | Unchanged. A refused posting writes nothing and does not take a number, as today. |
| Idempotency | Unchanged. A replay returns the first answer; it is not re-judged under the setting current at replay time. |
| Reconcile | Unchanged code. It re-derives on-hand from the legs; a negative on-hand is derived like any other and reports no mismatch (REQ-834 tests it). |
| Read | Unchanged. The `nonzero` filter of `lib/letflow/ledger/read.ex` is `on_hand != 0`, so negative keys show; zero keys stay hidden. |
| Reversal | Follows the same setting: under allow a reversal that takes a key below zero is accepted (Qoimeks `reverse` has no check, Q); under refuse it is `insufficient_balance` with only `leg_nos` and `count`. Once and never twice stays: a second reversal is `posting_already_reversed`, a reversal of a reversal is `posting_is_reversal` (Qoimeks 8.5). |
| Count | The posted difference is counted minus book also when the book is negative (book -2, counted 3 posts +5). The advisory `shortage_exceeds_balance` check of `count_posting.ex` and the completion refusal do not apply on an allow tenant. The counted quantity stays zero or more (a counted stock cannot be negative; assumption, owner may change). |
| Freeze guard | Unchanged. `FreezeGuard` (`posting_guard`) judges the hold, not the balance. |
| Opening balance | ONE mechanism: a **new cause `opening_negative`** with sign rule `negative` is added to the stock registration (REQ-836); the cause `opening` keeps sign rule `positive`. **One opening document does not mix signs**: all its lines are positive (posted as `opening`) or all are negative (posted as `opening_negative`); a mixed document is refused `quantity_invalid` on save. A negative opening line is accepted only on an allow tenant (the document shape in `opening_shape.ex` reads the setting); a line with quantity 0 stays `quantity_invalid`. (assumption, owner may change; the cause is chosen over sign rule `any` so that the ledger itself keeps refusing a wrong sign) |
| Switching back to refuse | Negative keys present stay as they are; nothing is rewritten. Only postings that lower a key to below zero are refused (section 2). A receipt into a negative key is accepted. |

## 5. The setting

1. **Storage.** A new tenant table `ledger_balance_settings`, one row per registration name, in the tenant schema without
   `tenant_id` (0006 D2; placement per-tenant as `approval_rule_settings`). Columns: `id uuid PRIMARY KEY`,
   `registration_name text NOT NULL CHECK (char_length(registration_name) BETWEEN 1 AND 255)` with a unique index, `allow_negative boolean
   NOT NULL`, `changed_by uuid NOT NULL`, `changed_at timestamptz NOT NULL`, `reason text NOT NULL`,
   `inserted_at timestamptz NOT NULL`, `updated_at timestamptz NOT NULL`. No row means refuse. The migration is tenant
   scoped (the `if prefix() do` guard, registered in the `Letflow.TenantProvisioning` manifest, no interpolation except
   the quoted schema name).
2. **Route.** One core router mounted in `lib/letflow/plugs/api_pipeline.ex` at `/ledger-settings`, tenant-wide
   (`Scope.require_tenant_wide/2`):
   - `GET /ledger-settings`: lists every ledger registration of the tenant's installed modules that declares
     `:tenant_setting`, each with `registration`, `allow_negative` (false when no row), `changed_by`, `changed_by_name`,
     `changed_at`, `reason`.
   - `PUT /ledger-settings/:registration`: a body of exactly `{"allow_negative": <boolean>, "reason": <text>}`. A value
     equal to the current one writes nothing. Otherwise the row and the audit entry are written in one transaction.
   - 422 reason codes: `invalid_body` (an extra key or a non-boolean `allow_negative`), `invalid_reason` (missing or
     blank), `not_switchable` (a registration that is not installed or does not declare the key, assets included).
     Validation order: body, reason, registration.
3. **Permission.** A new core permission atom `:LedgerSettingsManage`, route-level on both routes (an
   `endpoint_policy_key` clause per route), **held by TENANT_ADMIN only; an explicit false clause keeps PLATFORM_ADMIN
   out** (`core_role_allows?(:PLATFORM_ADMIN, :LedgerSettingsManage)` is false, as for `:ApprovalRulesManage` in
   `lib/letflow/api/authorization.ex`); not grantable (0088 D4: `Letflow.Api.Authorization.grantable/0` does not contain
   it). Access is by permission atom, never by role name. (O: the permission model of D-144; the choice of TENANT_ADMIN as
   the only holder is an assumption, owner may change.)
4. **Audit.** One entry of kind `ledger_setting.changed` per changed value, with the registration name, the old and the new
   value and the reason, written in the transaction of the row (as `approval_rule.changed`).
5. **Reason.** Required, non-blank text on every change in both directions (assumption, owner may change: a reason for
   switching back to refuse is also required).
6. **Which value a posting obeys.** The value committed when the posting's guard step reads it, inside the lock step before
   the guard, with the capability's prefix only. A switch committed after that read does not change a posting already past
   it; a posting started after the commit obeys the new value. No cache is kept across requests.
7. Four-eyes precedent: `docs/design/four-eyes-switch.md` and decision D-144 (the per-tenant switch, `:ApprovalRulesManage`).
   The switch itself is not a four-eyes step (assumption, owner may change; a small company with one administrator can
   use it, owner checklist item 10).

## 6. The warning

1. The web and mobile stock document forms show the warning **before a document is saved**, for the kinds that have a
   lowering side: issue, write off, transfer, hand over, return. Receipt, opening and count do not warn.
2. Only on an allow tenant and only to a user who may read balances (`StockRead`); a user without it sees no warning and
   no balance (the answer cannot leak a balance, INV-5).
3. Condition, taken from Qoimeks `goesNegative`: the entered quantity is greater than the on-hand at the line's key (a
   key with no balance reads zero). Qoimeks warns for issue and transfer only; Letflow adds the other lowering kinds
   (extra, tagged). The warning does not block saving or posting.
4. A voice draft fills the mobile form (REQ-747), so it gets the same warning there as a typed draft.
5. Texts: ru «Остаток станет отрицательным» and kk «Қалдық теріс болады» (both from Qoimeks `mobile/lib/l10n.dart`), en
   "The balance will become negative" (assumption, owner may change: Qoimeks has no English text; UAT assumption).
6. The form learns whether the tenant allows negative balances from the module's own read route (REQ-836
   `GET /api/v1/modules/stock/posting-rules`), not from the core settings route, which needs the admin permission.

## 7. Migration rows

1. A negative Qoimeks balance row (inventory section 4 count 8) moves **as it is**, with its negative quantity, as an
   opening line on a tenant switched to allow **before** the load; no rounding and no sign change. All such lines go in
   opening documents of their own (one document does not mix signs, section 4).
2. A zero row is **not loaded** (an absent key reads as zero) and is not a drop; the converter
   (`scripts/pilot/qoimeks_convert.py`, `quantity_not_positive`) stops counting it as a dropped row (REQ-837).
3. The rehearsal runbook switches the tenant first (route and permission of section 5, with a reason) and checks after
   the load that the negative keys read as in the extract.
4. Readiness note `docs/status/qoimeks-migration-readiness.md` row G4 points at this record; R-2 and R-3 stay withdrawn.

## 8. Owner table (choices the owner may change)

| # | Choice | Taken here | Alternative |
|---|---|---|---|
| 1 | Who holds the permission | `:LedgerSettingsManage`, TENANT_ADMIN only, PLATFORM_ADMIN refused, not grantable | A grantable permission, or a second holder |
| 2 | Default | Refuse when no row (O) | None; the owner decided |
| 3 | English warning text | "The balance will become negative" | Another wording |
| 4 | Refuse-mode rule | Refused only when a lowered key ends below zero (section 2) | Refuse while any touched key is negative |
| 5 | Lower bound | Column type only, guard refuses at -1.0E+21 (section 3) | A database check at a smaller negative floor |
| 6 | Counted quantity | Stays zero or more | Allow a negative counted quantity |
| 7 | Opening mechanism | New cause `opening_negative`, no mixed-sign document | Sign rule `any` on `opening` |
| 8 | Reason on switch back | Required both directions | Required only for allow |
| 9 | Switch is a four-eyes step | No | Yes, by the four-eyes switch |
| 10 | Warning kinds | Issue, write off, transfer, hand over, return (EXTRA: write off, hand over, return) | Qoimeks only: issue and transfer |
| 11 | EXTRA ideas, not built here | A per-item or per-place allow list; a report of all negative keys for the chief storekeeper | Not planned |

## Consequences

- Existing tenants and the assets ledger behave as before; the only stored change on rollout is the dropped CHECK and an
  empty settings table.
- The pin tests that move are named by the later parts (REQ-834 to REQ-836): tenant migration position pins, the tenant
  table list, the permission matrix golden, route-count pins, the stock registration and `previous_pack` pins.
- Changes to this record's names (permission, table, routes, audit kind, registration key) go through a new record.
