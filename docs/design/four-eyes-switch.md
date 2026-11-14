# Four-eyes switch: approval by a different person, configurable per tenant

Recommendation to the owner, not a decision. Task T-1944 (no issue number). Docs only: no code, nothing on QA.
The main rule was decided by the owner and relayed by the PM on 2026-11-14 (quoted in section 0); this note answers
where the rule lives today, what the switch touches and how to build it. The UAT record is
`docs/uat/ba-decisions/T-1944.md`.

Legend: **V** = verified by reading the file on this branch (origin/main `7a6b8fd1d`, commands in section 9).
**G** = architect's judgement. **O** = for the owner.

## Plain summary

Today there is **one** real "a different person must approve" rule in the product's own processes, and it is generic:
a process step may name earlier steps in `distinct_from`, and the engine refuses that step to the person who completed
one of them (`Letflow.Engine.SeparationOfDuties`, V). Two shipped processes use it: **asset opening** and **stock
opening** (step `approve`, kept apart from step `submit`, which the issuer completes at issue, V). Everything else that
looks similar is a different rule: count commission signatures, "only the chair may" checks, the chair-not-member rule,
the self-approval ban on definition promotions and the script publisher rule (which already has its own switch). The
procurement self-decision ban is a real four-eyes rule but on its own code path, in a module that is held; it gets a
later slice.

So the switch is small: one place in the engine decides it, and every approval step that uses `distinct_from` gets the
switch for free. It is a new tenant setting per process and step (no row = ON, so nothing changes on upgrade), one new
permission held by the tenant admin only, one audit line "self-approved, four-eyes off" each time one person approves
their own document, and one admin screen. No module version bump is needed for the core slice or the asset-opening
slice, because no process definition changes.

## Owner table

| # | Question | Recommendation | Owner |
|---|---|---|---|
| 1 | Name of the new permission | `ApprovalRulesManage` (tenant scope), working name | O |
| 2 | Who holds it | Tenant admin only (the computed `all_tenant_scope` rule); not the platform admin in the platform tenant (explicit `false`, as ruling 2 does for `TenantSecurityManage`) | decided in principle (task text: "by permission"); the platform-admin exclusion is O |
| 3 | May a tenant's own role hold it (corporate role editor)? | No: non-assignable (0088 D4), because it lowers a control | O |
| 4 | Granularity | Per tenant, per process and step (the step that names `distinct_from`); shown on screen as document type + step | decided (task text) |
| 5 | Default | ON (four eyes); no stored row means ON | decided (task text) |
| 6 | Which setting counts for an approval that is already waiting | The setting at the moment the approval is completed (live), not when the document was issued | G, also the UAT decision |
| 7 | Service users (API tokens, service principals) | Four eyes stays ON for them even when the tenant switched it off: only a person signed in interactively may approve their own document | O (touches access) |
| 8 | Reason when switching off | Required free text, kept in the audit record (as `scripts.sod` does, 0053 D6) | O |
| 9 | Refuse "off" when the tenant has two or more people who could approve? | No refusal; the screen shows how many users hold the approve permission as a hint | O |
| 10 | Which rules get the switch | Only real four-eyes approvals (section 2, class A). Promotion self-approval, the script publisher rule and procurement keep their own rules | O |
| 11 | Edition | Open base, not a closed feature | decided (task text) |

## 0. The decision this note builds on (quoted from the task text, PM relay of 2026-11-14)

> the four-eyes rule must be configurable in the process; one-person companies (our small clients; Qoimeks Client 1 may
> need it off) reduce it to two eyes: the same person issues and approves. Decided details: setting PER TENANT and per
> document type or process step where the approval exists (asset opening first, then every other approval step that
> has the same rule); default stays ON (four eyes); the tenant admin switches it off BY PERMISSION (a new permission
> atom, never a role name: D-129/D-131/D-132 roles-as-data model); when one person approves their own document the
> audit log records 'self-approved, four-eyes off'. Open build: the switch is part of the open base, not a closed
> feature.

The D-129, D-131 and D-132 records are in the portfolio and were not opened; their content as recorded in this
repository is decision `docs/migration/decisions/0088-permission-only-access-tenant-defined-roles.md` (D1 to D5) and
`docs/design/roles-architect-verdict.md` ("Owner choices").

## 1. Does it touch the roles and permission model?

Yes, by one permission atom and nothing else. No role name is read, no role is added.

- **New atom** `ApprovalRulesManage` (working name, not on main: `git grep -n "FourEyes\|four_eyes\|ApprovalRules"
  origin/main -- lib web/src priv` prints nothing). Tenant scope. Route-level on the two planned routes (section 3.4).
- **Who holds it.** TENANT_ADMIN through the derived rule `core_role_allows?(:TENANT_ADMIN, permission)` ->
  `permission_scope(permission) == :tenant` (`lib/letflow/api/authorization.ex`, V). PLATFORM_ADMIN would get it from its
  catch-all `core_role_allows?(:PLATFORM_ADMIN, _permission), do: true` (V); recommended: add an explicit `false` clause
  above the catch-all, as for `:TenantSecurityManage` and `:TasksReassignRouted` (ruling 2 of
  `docs/design/roles-stage0-security-rulings.md`: a platform admin in the platform tenant stays out of tenant switches
  that lower a control). No other built-in role holds it.
- **Non-assignable** (0088 D4): not in `grantable/0` (today `%{STOREKEEPER: [:AssetsRead, :AssetsPost]}`, V), and in
  stage 2 flagged `assignable: false`. Reason: it removes a control, like the two admin-only switches 0088 D4 already
  names. Modules cannot grant it (it is a core atom; `role_grants` cover module atoms only).
- **Tenant-wide only.** Checked tenant-wide, like `TenantSecurityManage`: a scoped grant (org unit) does not count,
  because the setting is per tenant, not per unit.
- **Roles stage 0 rules kept.** Condition 1 (names identify, never decide): the approve step's routing role
  (`TENANT_ADMIN` in `attributes.role`) stays addressing (0088 D5) and the switch never reads it. Condition 3: the atom
  is non-assignable. Condition 4: the four-eyes check compares **user ids** (`completed_by`), never roles (moduledoc of
  `SeparationOfDuties`: "Identity is the USER ID (`actor_id`), never a role. No role is exempt.", V). The switch keeps
  that: it changes *whether* the comparison refuses, not *who* is compared.
- **Pins that move** (implement step): the permission matrix golden (`mix letflow.permission_matrix --write`), the core
  permission count in `authorization_test.exs`, the tenant-auditor refused-set literal, `docs/roles.md` (a new
  sentence in the TENANT_ADMIN permission list, as for `CurrenciesManage`).

## 2. Every "different person" rule in the code and in the process definitions

Class **A** = a real four-eyes approval (the same document must be approved by another person than the one who
prepared it). Class **B** = another rule (who may act, signatures, composition, change control).

| # | Where (file, symbol) | Rule | Who may | Class | Switch? |
|---|---|---|---|---|---|
| 1 | `lib/letflow/engine/separation_of_duties.ex` `check/5` (completion, under the task and instance locks), `check_for_claim/3` (claim, fail-open early answer); called from `Letflow.Engine` `existing_completion_guards/6` | A HUMAN_TASK listing node ids in `distinct_from` is refused to the user who last completed one of those nodes in the same instance. Refusal `{:error, :separation_of_duties}`, HTTP 403 `Response.separation_of_duties/1`, body detail `separation of duties`, web code `SEPARATION_OF_DUTIES` (`web/src/api/client.ts`); audit of the refusal via `record_completion_refusal_audit/6` | any user other than the earlier completer | A (the mechanism) | **Yes: the one place the switch acts** |
| 2 | `priv/modules/assets/generate_pack.exs` `opening_definition` -> `pack.json`, process `assets_opening` | `approve` (`role` TENANT_ADMIN, `distinct_from ["submit"]`, posts `post_document`); `submit` is completed by the issuer at issue (0083 D5) | a second holder of `AssetsPost` (today TENANT_ADMIN, PLATFORM_ADMIN; STOREKEEPER by overlay) | A | Yes, slice 2 (first) |
| 3 | `priv/modules/stock/generate_pack.exs` `two_step_definition` -> `pack.json`, process `stock_opening` | same shape: `approve` `distinct_from ["submit"]`, posts the opening (REQ-726, 0079 opening D4) | a second user who may post stock | A | Yes, slice 3 |
| 4 | QA fixtures `test/fixtures/qa/{vortex_production_order_release,meridian_loan_origination,meridian_regulatory_compliance_review,swiftroute}_process_definition.json` | tenant-authored definitions with `distinct_from` on approval nodes (e.g. Swiftroute `ceo-approval` apart from `ops-review`; Meridian `disburse-loan` apart from eleven review nodes; Meridian committee votes apart from each other) | per definition | A (tenant processes) | Yes, automatically (generic); no slice needed |
| 5 | `lib/letflow/definitions/role_binding.ex` `single_member_pairs/1`, `format_single_member_warning/2` (REQ-464 check 4) | publish-time warning `distinct_from_single_member_role: ...` when both sides of a `distinct_from` pair route to a role with one member | (warning, refuses nothing) | A (advisory) | Should stay silent for a step whose four eyes are OFF (slice 1) |
| 6 | `lib/letflow/definitions/graph.ex` CHK-26, CHK-27 (`check_distinct_from/1`, `check_distinct_from_position/1`) | shape of `distinct_from` (no self reference, known HUMAN_TASK nodes, not downstream only) | (definition check) | B (validation) | No |
| 7 | `web/src/pages/tasks/TaskDetail.tsx` (`issuedByMe && kind === 'approve'`), texts in `web/src/pages/tasks/taskMessages.ts` `sod` / `sodHint` ("You issued this document; a different person must approve it.", also post, reverse, other) | UI hint and refusal text of row 1 | (display) | A (display) | Yes: hide the hint when OFF (slice 2) |
| 8 | `lib/letflow/modules/assets/counts.ex` `chair_not_member/2` (`field_invalid member_employee_ids`), and the stock twin in `lib/letflow/modules/stock/counts.ex` | the chair is not also a member of the commission | order author | B (composition) | No |
| 9 | `lib/letflow/modules/assets/counts.ex` `chair?/3`, `count_sheet.ex` `:not_chair`; stock `count_sheet.ex` `chair/3`, `count_posting.ex` `issue_posting_record/3` via `CountDifferences.chair/3` | only the chair cancels, opens, closes the count, marks the sheet signed, issues the count posting | the chair (one person) | B (who may act) | No |
| 10 | assets `count_sheet.ex` `mark_sheet_signed/4` (`:signers_incomplete`, `:not_commission_member`), stock `count_sheet.ex` (`:not_commission_member`) | the exact set of commission members and the signer role sign the sheet; only members record | chair and members | B (signatures of commission members are **not** four-eyes) | No |
| 11 | `lib/letflow/definitions/promotion_review_store.ex` `approve_review/4` (`:self_approval_forbidden`), `lib/letflow/routers/promotions.ex` `render_approve/2`; web `NonSkippableApprovalGate.tsx` | the requester of a definition promotion cannot approve it | another reviewer | B (change control of process definitions, not a business document) | No (recommended, O row 10) |
| 12 | `priv/repo/migrations/20261014000003_add_script_sod.exs`, `lib/letflow/routers/script_policy.ex` `PUT /sod`, decision 0053 D6 | script author vs publisher; tenant policy `strict` (default) or `solo_audited`, every self-published version flagged and audited | a non-contributor admin, or the author under `solo_audited` | B (already has its own switch) | No; it is the precedent this design copies |
| 13 | `lib/letflow/modules/procurement/decisions.ex` `not_requester/3` (`:self_decision`, 403 via `procurement/router.ex`) | the requester never decides their own purchase request | another holder of the decide permission | A (but its own code path, not `distinct_from`) | Later, own slice; procurement is held (project goal, 2026-10-31) |
| 14 | single-step processes: assets `assets_commission`, `assets_change`, `assets_reversal`, ...; stock `stock_receipt`, `stock_issue`, `stock_writeoff`, `stock_reversal`, `stock_transfer`, `stock_handover`, `stock_return`, `stock_count_posting` | one `post`/`reverse` task, no `distinct_from` | the poster | none | No (nothing to switch) |
| 15 | `lib/letflow/row_approval.ex`, `Letflow.ParallelApproval` | two approvals by approver kind (`:finance`, `:ops`), not by person; no router mounts them | (prototype) | B | No |

"Reverse" four-eyes: the `sodHint.reverse` text exists, but no reversal process names `distinct_from` today (row 14), so
there is no reverse four-eyes rule to switch.

## 3. The design

### 3.1 Where the setting is stored

A new core tenant table (tenant schema, INV-1, no `tenant_id` column per 0006 D2), working name
`approval_rule_settings`:

| column | meaning |
|---|---|
| `definition_name` | the process key, e.g. `assets_opening` (the name the instance snapshot carries in `definition_name`) |
| `node_id` | the step that names `distinct_from`, e.g. `approve` |
| `four_eyes` | boolean; only `false` is ever written by the switch-off; switching back on deletes the row or writes `true` (pick one at design: **writes `true`**, so the history row stays) |
| `changed_by`, `changed_at`, `reason` | who, when, why (row 8 of the owner table) |

Unique on (`definition_name`, `node_id`). **No row = ON.** Why a table and not a settings key: `tenants.settings` is a
global column with a closed five-key vocabulary (`20260908000001_add_settings_to_tenants.exs`, V) and
`tenant_modules.settings` belongs to one module, while `distinct_from` is a core engine rule that also applies to
tenant-authored processes (section 2 row 4). Keyed by process key and step, not by definition version, so a new version
of the same process keeps the setting.

### 3.2 Read path (how a process step reads it)

Inside `SeparationOfDuties.run_check` **only after** the existing comparison finds a blocking node (the same user
completed a listed step). So:
- a step without `distinct_from` still runs zero queries (moduledoc "Default off ... ZERO queries", V);
- a step whose approver is a different person runs no extra query;
- only a would-be refusal reads one row by the unique key, inside the completion transaction, under the task and
  instance locks already held.

No cache: one indexed read per would-be refusal is cheap, and a cache would let a switch back to ON lag behind.
**Fails closed**: a missing row, an unreadable row or a read error means ON (refuse). The claim-time check
(`check_for_claim/3`) applies the same setting; it stays fail-open as today because completion re-checks.
The definition name comes from the instance snapshot (`InstanceDefinitionSnapshot.definition_name`, V); `check/5`
gets it as an argument (its signature changes: grep `check(` callers in `test/` at implement time).

### 3.3 The audit record

When the check would refuse but the setting is OFF, the completion goes on and one extra audit entry is appended in
the same Multi as `task.complete` (`Audit.append_multi/4`, so both commit or neither):

| audit field | value |
|---|---|
| `action` | `task.self_approved` |
| `resource_type`, `resource_id` | `task`, the task id |
| `actor_id` | the approving user |
| `after_state` | `%{"note" => "self-approved, four-eyes off", "four_eyes" => "off", "definition_name" => ..., "node_id" => ..., "same_person_as" => [blocking node ids], "setting_changed_at" => ...}` |

The text "self-approved, four-eyes off" is the stored value, as the owner asked; the audit screen
(`web/src/pages/admin/AuditLogPage.tsx`) shows the action and the note. A failed audit write fails the completion
(`Audit` raises on a database failure; INV-8 handled as for `task.complete`). The switch itself is audited too:
`approval_rule.changed` with before and after value and the reason.

### 3.4 How the admin switches it (screen and routes)

Two planned routes (working paths, checked against the router at design time): a list
`GET /approval-rules` (every step of an active definition that names `distinct_from`, with its current value) and
`PUT /approval-rules/:definition_name/:node_id` with body `{"four_eyes": false, "reason": "..."}`. Both
`ApprovalRulesManage`, tenant-wide, interactive session only (like `require_interactive_tenant_admin/1`). A PUT for a
step that does not name `distinct_from` in the active definition is 422 (`not_a_four_eyes_step`, working name). The
PUT takes the whole value (one boolean and a reason); nothing else is stored.

Screen: Administration -> "Approval rules": a list with document type (process label), step label, "Four eyes: On /
Off", a toggle that asks for the reason and shows a warning ("one person will be able to issue and approve; every
such approval is recorded in the audit log"). The task screen hides the "You issued this document" hint when the step
is OFF.

### 3.5 Migration and upgrade chain

- One tenant-scoped migration creating the table (the `if prefix() do` guard and registration in
  `Letflow.TenantProvisioning`'s tenant-scoped manifest). Existing tenants get it through the boot-time replay. **No
  data change**: no rows, so every step stays ON. Auto-CD deploys it to QA unchanged in behaviour.
- Pins that move: `@expected_tenant_tables` (`test/support/tenant_fixture.ex`) and its count, the
  `Enum.at(tenant_scoped_migrations(), -N)` pins.
- **No module version bump** for slices 1 to 3: the process definitions (`pack.json`) do not change; `distinct_from`
  stays in them and the switch is read outside the pack. The guard rule (a pack change needs a version bump and an
  end-to-end upgrade test such as `test/letflow/modules/assets/upgrade_from_090_test.exs` and
  `test/letflow/module_upgrade/previous_pack_test.exs`) applies only to a later slice that **adds** `distinct_from` to
  a process (a new approval step): that slice bumps the module version and carries the upgrade test.
- Seeds: none. A tenant that wants it off switches it on the screen.

## 4. Implementation slices (in order)

| # | Slice | Contents | Effort |
|---|---|---|---|
| 1 | Core: permission, setting, check, audit | atom `ApprovalRulesManage` (+ PLATFORM_ADMIN `false` clause, non-assignable), table and migration, read in `SeparationOfDuties` (fails closed), `task.self_approved` audit in the completion Multi, the two routes and `approval_rule.changed` audit, REQ-464 warning silent for OFF steps; tests: ON refuses (unchanged), OFF allows and audits, read error refuses, other tenant's row never read (INV-1), scoped admin refused, platform admin refused, service principal still refused (if owner row 7 holds), claim path. Security review (tenant data path, a control that can be lowered) | M |
| 2 | Asset opening (first) | nothing in the pack; the opening flow end to end with OFF: issue completes `submit`, the same admin completes `approve`, the opening posts, the audit row exists; task screen hint hidden when OFF; UAT scenario for a one-person tenant | S |
| 3 | Stock opening | same as 2 for `stock_opening` (Qoimeks Client 1 path) | S |
| 4 | Admin screen "Approval rules" | list, toggle with reason, warning, en/ru/kk texts, screenshot matrix | M |
| 5 | Procurement self-decision (later; procurement is held) | read the same setting in `Decisions.not_requester/3` for the decide step, same audit text | S |
| 6 | Tests across the corpus | a scan test: every step that names `distinct_from` in a shipped pack is listed by `GET /approval-rules`, so a new approval step cannot escape the switch | S |

Slices 2 and 3 need slice 1 merged; slice 4 needs slice 1; 2, 3, 4 can run in any order after 1.

## 5. Risks

- **A one-person company turns it off.** That is the purpose; the control becomes the audit: every self-approval is
  one `task.self_approved` row with the note text, and the switch itself is audited with who, when and why. Default ON
  and fail-closed reads keep every other tenant unchanged.
- **The setting is turned off "for one approval" and forgotten.** The screen shows the date and the person who switched
  it off; a later report could list self-approvals per month (not in these slices).
- **Scoped users.** A scoped TENANT_ADMIN grant (one org unit) does not count for the switch (tenant-wide only), so a
  unit manager cannot lower the rule for the whole tenant. The approve step itself keeps its own permission check
  (`AssetsPost`, scoped as today); the switch changes only the same-person comparison.
- **Service users.** With the switch OFF, a script or integration acting under one service principal could issue and
  approve with no human. Recommended (O row 7): the OFF setting does not apply to a service principal actor; four
  eyes stays ON for it. The flag exists (`PUT /users/:id/service-principal`); the check reads it only on a would-be
  refusal.
- **Platform admin.** Kept out of the switch (row 2); in a customer tenant the platform admin has no business role
  (`docs/roles.md`: platform authority stays in the platform tenant, INV-10).
- **Multi-step approvals (Meridian committee).** The setting is per step; turning off one vote does not turn off
  another. Each OFF is its own row and its own audit.
- **Silent widening.** None: no grant changes, no role gains a permission it did not have except the new atom on the
  tenant admin (0088 D7 "No silent widening" holds).

## 6. Pilot note: Qoimeks Client 1 (stock only)

Approvals in the stock module (section 2, rows 3 and 14, V): **only one four-eyes approval exists, the stock opening
(`stock_opening`, step `approve` apart from `submit`).** Receipt, issue, write-off, transfer, handover, return,
reversal and count posting are single-step (one person posts). The count has a chair and commission signatures
(rows 9 and 10), which are not four-eyes and are not switched. So for a one-person Client 1, switching four eyes OFF
for `stock_opening / approve` (slices 1 and 3) is the whole need. The count still needs a chair, and the chair cannot
also be a member (row 8); but the member list of a stock count order may be empty
(`lib/letflow/modules/stock/counts.ex`: `uuid_list(input, "member_employee_ids", true)`, the `true` is "may be
empty", V), so one person can run a stock count as chair alone. Whether the paper form of a count accepts a
one-person commission is a legal question outside this switch (finding for the owner).

## 7. Not decided here

- Owner rows 1, 2 (platform admin part), 3, 7, 8, 9, 10.
- Whether reversals should gain a four-eyes step (no reversal has one today).
- A requirement entry: none is written here; the planner writes one per slice.

## 8. Sources opened

`lib/letflow/engine/separation_of_duties.ex`; `lib/letflow/engine.ex` (`existing_completion_guards/6`,
`interpret_complete_result` for `:separation_of_duties`, `record_task_complete_audit/4`); `lib/letflow/api/response.ex`
`separation_of_duties/1`; `lib/letflow/routers/tasks.ex` `handle_complete_result/2`, `handle_claim_result/3`;
`priv/modules/assets/generate_pack.exs`; `priv/modules/stock/generate_pack.exs`; `lib/letflow/definitions/role_binding.ex`;
`lib/letflow/definitions/graph.ex`; `lib/letflow/modules/assets/counts.ex`, `count_sheet.ex`, `documents.ex`,
`settings.ex`; `lib/letflow/modules/stock/counts.ex`, `count_sheet.ex`, `count_posting.ex`;
`lib/letflow/definitions/promotion_review_store.ex`; `lib/letflow/modules/procurement/decisions.ex`;
`priv/repo/migrations/20261014000003_add_script_sod.exs`; `priv/repo/migrations/20260908000001_add_settings_to_tenants.exs`;
`lib/letflow/api/authorization.ex` (`core_role_allows?/2`, `grantable/0`); `lib/letflow/row_approval.ex`;
`web/src/api/client.ts`; `web/src/pages/tasks/taskMessages.ts`; `web/src/pages/tasks/TaskDetail.tsx`;
`docs/migration/decisions/0083-asset-opening-document.md` (D5, Q2), `0079-opening-balances-and-ledger-xlsx.md` (Q2),
`0079-counts-inventory-taking.md`, `0053-tenant-scripted-rules.md` (D6), `0088-permission-only-access-tenant-defined-roles.md`
(D4, D5, OP-A); `docs/design/roles-architect-verdict.md`; `docs/design/roles-stage0-security-rulings.md` (ruling 2);
`docs/roles.md`; the four QA fixtures of section 2 row 4. Not opened: the portfolio records D-129, D-131, D-132.

## 9. Commands behind the facts (base `7a6b8fd1d`)

- `grep -rln '"distinct_from"' priv/ lib/ test/fixtures` -> `priv/modules/assets/pack.json`, `priv/modules/stock/pack.json`,
  both `generate_pack.exs`, `graph.ex`, `engine.ex`, `role_binding.ex`, `separation_of_duties.ex`, the four QA fixtures,
  two previous-pack fixtures, one design file.
- `grep -n 'two_step_definition\|opening_definition' priv/modules/*/generate_pack.exs` -> one use each:
  `stock_opening` and `assets_opening`.
- `grep -rniE "self_approv|self_decision|separation_of_duties" lib/` -> rows 1, 11, 13.
- `grep -nE "error, :[a-z_]+" lib/letflow/modules/{assets,stock}/count*.ex` -> rows 8 to 10 (`not_chair`,
  `not_commission_member`, `signers_incomplete`).
- `git grep -n "FourEyes\|four_eyes\|ApprovalRules" origin/main -- lib web/src priv` -> no output.
