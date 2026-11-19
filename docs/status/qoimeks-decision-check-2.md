# Qoimeks scenarios against decisions: second pass

Task T-2293, 2026-11-19, main `116a6e81f`. Docs only: no code and no scenario was changed.

The first pass (T-2286..T-2292) read decisions 0079, 0081, 0090, 0091 and REQ-833..887. This pass reads what it
did not: decisions 0055..0078, 0080, 0082..0089, `docs/design/four-eyes-switch.md` and
`docs/runbooks/pilot-rollout.md`, and compares them with the expectations of all 12 Qoimeks groups in
`test/fixtures/uat/scenarios/qoimeks-*/` (count, defloc, export, import, ledger, mobile, move, negative, qa, retry,
token, voice; 67 scenario files).

Verdicts:

- **OK**: the decision and the scenario agree.
- **CONTRADICTION**: the decision says X, the code or the scenario does or expects Y.
- **INVENTED**: an expectation with no decision or REQ behind it.
- **n/a**: no decision in this range speaks to it.

Scenario line numbers are in the yaml file named in the first column (`count-6` is
`qoimeks-count/qoimeks-count-6-four-eyes-and-access-refusals.yaml`, and so on). Decision lines are in
`docs/migration/decisions/` unless a path is given.

## 1. What was read, and what it touches

| Source | Read how | Touches the scenarios? |
|---|---|---|
| 0057 | in full | yes: D2 idempotency key, D4 exact quantity, D5 ledger, D6 replaceable routes, D16 Kazakh wording |
| 0058 | in full | yes: (b) replays idempotent, (c)1 `client_op_id` on every command |
| 0060 | head and decision list | yes, quantity as exact string; the xlsx cell is a number (see section 3, row X2) |
| 0073 and its amendments | D1..D9 and the amendments REQ-764, 774, 853, 830, 829, 832, 0090 | yes: no-negative guard, zero quantity, `expected_on_hand`, reversal, master checks, freeze guard |
| 0076 | R7 visibility table | yes: tenant-wide versus scoped reads |
| 0077 | in full | yes: xlsx limits, first sheet, float cell, 20 000 row check |
| 0078 | D1..D7 | yes: time zone, reversal, cancel order |
| 0080 | head, Q1..Q3 | yes (precondition "definitions active") |
| 0082, 0084 (assets grant), 0086 | in full | 0086 yes (xlsx keeps ids); 0082 and 0084 no scenario |
| 0088 | D1..D8 | yes: access by permission, routing is addressing |
| 0056 | status machine, cancel, numbering | yes: cancel with a reason, numbers kept |
| 0055 | headings, D7 grants | only preconditions |
| four-eyes-switch.md | sections 0..6 | yes: ledger-4, count-6, import-5 |
| pilot-rollout.md | in full | yes: steps 6, "Old Qoimeks app address" |
| 0059, 0061..0071, 0072, 0074, 0075, 0083, 0084 (signup), 0085, 0087, 0089 | titles and grep for the scenario topics only | no scenario expectation touches them (see section 5) |

## 2. Table: group | scenario:step | expectation | decision | verdict | what must change

Only rows where a decision in this range speaks. A scenario or a step not listed has no decision here (n/a) or is
listed in section 5.

| Group | Scenario:step | Expectation (file:line) | Decision (file:line) | Verdict | What the product or the scenario must do |
|---|---|---|---|---|---|
| retry | retry-1 EO-001/EO-002 | The same client id sent twice gives two documents, 201 both, balance +10 (`retry-1` :198-:216) | 0057:14 "a client-generated idempotency key on every command"; 0058:13 "Replays are idempotent"; 0058:27 "Every command carries `client_op_id` (idempotency key)" | CONTRADICTION | Product: the old-app write honours the client `id`. The scenario documents `old_app_writes.ex:32-34` (see D1). |
| retry | retry-2 EO-001/EO-002 | Same for an issue: balance -6 for 2 x 3 (`retry-2` :216) | same as above | CONTRADICTION | same task (D1). An issue sent twice takes stock out twice. |
| retry | retry-3 EO-001/EO-002 | Same id, different data: both accepted, balance +25 (`retry-3` :181-:202) | 0058:13, 0058:27; 0073 "Amended by REQ-853": a retry with another value is `idempotency_key_reuse` | CONTRADICTION | Product: same id with other data answers 409 `idempotency_key_reuse` (the ledger already has the code). |
| retry | retry-4 EO-001, EO-009 | No token and a wrong token both give 401 with one body; a post with no token, wrong token, another tenant's address or a personal token is refused and nothing changes (`retry-4` :247) | pilot-rollout.md:95 ("refused (401) on every `/api/v1` route"); 0088 D1 (access by credential kind, not by name) | OK | none |
| retry | retry-1..4 EO-008/EO-007 | A storekeeper, who holds no right to manage tokens, is refused the shared-access routes | 0088 D4 (admin-only switches are permissions) | OK | none |
| token | token-1..5 | Create, status, revoke, no screen for it, storekeeper refused | pilot-rollout.md:90 ("There is no screen for it"), :95 | OK | none |
| token | token-3 EO-003 (`token-3` :116) | The old-app value is refused on the ordinary balances route | pilot-rollout.md:95 | OK | none |
| count | count-6 step 5, EO-003 (`count-6` :132) | The storekeeper cannot approve a count; "the approval task is routed to the administrator role" (header :3) | 0088:58-62 (D1: access never depends on a role name); 0088:91-96 (D5: routing is addressing, "never grants a permission"); 0057:18 (D6: the route is replaceable, the handler checks only the outcome); `generate_pack.exs:207-208` ("The role label is only a label ... the ledger authority step decides who may complete the task (StockPost / StockReverse)"); `stock.ex:312` (STOREKEEPER holds StockPost) | CONTRADICTION (soft) | The expectation is true today only because `tasks.ex:600` and `:690` compare `ref in scope.role_names`. The product's own authority check (StockPost) would let a storekeeper approve. See D2. |
| count | count-3 steps 3 and 5, count-7 | The administrator approves the count and completes the reversal task; the storekeeper starts them | same as the row above | CONTRADICTION (soft) | same task (D2): the scenarios state "the second person is the administrator" as a rule; the decisions say it is a delivery label. |
| ledger | ledger-2 (:57 and EO-002 :145) | The storekeeper issues a receipt, the administrator completes the posting task | four-eyes-switch.md:104 and :233: a receipt is "single-step (one person posts)" | CONTRADICTION (soft) | Same cause as D2: the post task is addressed to role TENANT_ADMIN (`generate_pack.exs:225`) although the storekeeper holds StockPost. A one-person company is covered only if that person is the administrator. |
| count | count-3 EO-002 | The balance becomes exactly B+1, written as one movement of +1 | 0073 "Amended by REQ-853": `expected_on_hand`, `balance_changed` 409 | OK | none |
| count | count-2 EO-003 | Count equal to book writes no movement | 0073: "quantity zero refused" | OK | none |
| count | count-7 EO-002 | Count 0 gives one movement of -B | 0073 REQ-853 (a leg of -B is a normal leg); 0079 first pass | OK | none |
| count | count-6 EO-001, ledger-4 | Same person cannot approve with four-eyes ON; with it OFF the self-approval is audited as "self-approved, four-eyes off" and the rule change as `approval_rule.changed` | four-eyes-switch.md:145-160 (section 3.3); pilot-rollout.md:30; code `engine.ex:9427-9432` | OK | none |
| ledger | ledger-4 EO-004 | With the rule ON the administrator cannot approve their own opening | four-eyes-switch.md:22-26 | OK | none |
| ledger | ledger-4 (:67) | "switches the rule to ON with a reason" | four-eyes-switch.md:39 (row 8: a reason is required when switching OFF) | OK (not verified) | The design does not say whether ON needs a reason; the scenario gives one anyway. |
| ledger | ledger-6 EO-002 | A storekeeper's list of approval rules is refused and tells nothing | four-eyes-switch.md:33 (`ApprovalRulesManage`, tenant admin only); 0088 D4 | OK | none |
| count / import | count-5 header, import-5 EO-003 | "Quick count approval four-eyes ON"; the roster has no independent approver, so approval is BLOCKED | four-eyes-switch.md:232-233 ("only one four-eyes approval exists, the stock opening") | CONTRADICTION (the document, not the scenario) | The scenario is right: `generate_pack.exs:339-346` has a second four-eyes step, `stock_quick_count`. The design note and the pilot runbook are stale (see D3). |
| ledger | ledger-3 EO-002 | The master check refuses an absent item before any posting | 0073 "Amended by REQ-832" (live master required; refusal is `validation_failed`, audit `handler_invalid_arguments`) | OK | none |
| ledger | ledger-3 EO-003 | Cancelling a refused issue keeps its history | 0078 D5, failure table row 1 ("cancel the document (nothing to reverse)") | OK | none |
| ledger | ledger-2 EO-005 (:222) | Reversal restores the balance and both entries stay | 0078 D4 (a reversal is a new entry); 0073 D5 | OK | none |
| count / mobile / import | count-6 step 4 and 6, mobile-3 EO-006, import-4 EO-004 | An issued but unposted count or load is cancelled with a reason; the number stays; stock is untouched | 0056:75 (cancelled numbers are not reused, kept with status `cancelled`); 0056:105 (cancel needs "a second principal or a mandatory reason at minimum", open point 12); 0078 D5 | OK (not verified) | The scenarios give a reason. 0056 open point 12 (second principal for cancel) is undecided, so the storekeeper cancelling alone is not a contradiction. |
| ledger | ledger-1, qa-2 | Posted journal and legs readable; filters by cause and document type | 0073 D-L5 (time basis), D-C (per-cause balancing) | OK | none |
| export | export-5 EO-003 | The report sheet states the time basis and the zone | 0073 D-L5; 0078 D2 (every report states `basis`, `cutoff_seq`, `as_of`, `timezone`) | OK | none |
| move | move-1:34, export-5 | The file date is "today in the tenant's time zone" | 0078:65-72 (D3: "No tenant time zone setting exists on `origin/main`") | CONTRADICTION (the decision is stale) | Code has `identity/tenant_timezone.ex:19` (default `Asia/Almaty`, `tenants.settings["timezone"]`). Update 0078 D3, not the scenario (see D5). |
| export | export-1 EO-004, move-1 EO-004 | Quantity is a number in the cell | 0077:171-172 (a decimal goes through a float; the exact value is in the JSON export); 0060 (exact string on the wire) | OK | `xlsx_style.ex:72-78` writes text above 15 significant digits, so a 9-decimal quantity stays exact only up to that size. Not a contradiction. |
| export | export-4 (:41) | The register's own columns "(item code, place, org unit ...)" | 0086:63-67 (D5: the xlsx keeps ids, names are an open owner question); `xlsx_export.ex:32` (`sku location org_unit ...`) | INVENTED (wording only) | The check itself (:135) names the headers `sku, location, ...` and passes. The description line 41 says "code"; the cells hold record ids (`views.ex:17-19`). Change the wording. |
| export | export-2 EO-002/EO-003, move-1 EO-005 | The Qoimeks workbook holds the whole stock, the page export keeps the screen filter | 0086 D4 (replay is an ordinary balances read); REQ-865/866 | OK | none |
| move / import | move-3, export-6, import-1..3, 7 | The check reads the whole-stock workbook (R data rows) | 0077:41-47 (200 data rows per file) and 0077:193-201 (the stock workbook check passes 20 000 rows) | OK (not verified) | The scenarios read R at run time. If R is above 20 000 the check answers `xlsx_too_large`; the scenarios do not say that. |
| import | import-1 EO-003 | A non-xlsx file is refused on the client | 0077:21-56 (limits are server side) | INVENTED | There is no decision for the client-side refusal; it rests on the screen's own code. Low risk. |
| import | import-3 | The check reads only the first sheet and says why a row is skipped | 0077:48 ("worksheets read: the first ... UAT assumption") | OK | none |
| import / count | import-6, count-6 (:3) | Storekeeper holds `StockQuickCount` but not `StockWorkbookApply` | 0088 D1, D4; `stock.ex:311-320`, `router.ex:473` | OK | none |
| import | import-6 (:22-23) | Description: "today the quick count right guards the load" | `router.ex:473` (`StockWorkbookApply`) and the scenario's own header (:1-3) | CONTRADICTION (the scenario contradicts itself) | Scenario text (see D4). |
| count | count-6 preconditions (:3 "TARGET state after T-2239 ... not merged on main") | The storekeeper may not yet hold `StockQuickCount` | `stock.ex:317-320` (0.22.0, D-161, merged) and `docs/roles.md:189` | CONTRADICTION (the scenario is stale) | Scenario text (see D4). |
| defloc | defloc-1..3 | Usual place read by all; storekeeper cannot change it | 0076 R7 table (`catalog_item`, `location_node` tenant-wide); REQ-841..845 | OK | none |
| defloc | defloc-3 EO-003 | Storekeeper opening the platform company list is refused | 0088 D3 (platform admin row honoured only in the platform tenant) | OK | none |
| negative | negative-1..4 | Three negative rows, per-tenant switch, warning on issue | 0090 (first pass); 0073 amendment "Amended by 0090" | OK | none |
| qa | qa-1 EO-003 | A tenant administrator cannot open the platform tenant list | 0088 D3 (INV-10) | OK | none |
| mobile | mobile-1..5 | Company code entry, install hint, sign-in, reload, APK release record | none in this range (0042, 0044 and 0012 are outside it) | n/a | not verified here |
| mobile | mobile-3, mobile-4 | Quick count on phone width, in ru and kk | 0057:65 (D16: "No Kazakh text and no translation catalog are drafted") | CONTRADICTION (the decision is stale) | The design-system rule 4 and checklist item 11 (all texts in ru, kk, en) came later. Mark D16 superseded. See D5. |
| mobile | mobile-1 EO-005, mobile-2 EO-005 | No update banner; a reload asks for sign-in again | 0058:7-9 (offline is later scope) | OK | none |
| voice | voice-1..8 | Voice draft routes: transcript, validated draft, nothing stored, refusals | no decision in the range; REQ-862 (REQ-856 cancelled) | n/a (REQ behind it) | none |
| voice | voice-5, -6 | Quantity "zero is kept only for the kind count" | 0073 (quantity zero refused in a leg); 0057 D4 (exact decimal string) | OK | none |
| all | stock-using scenarios | "All stock process definitions active" (`count-*` header :4) | pilot-rollout.md:93 (409 `definition_not_active` until each kind is issued once); 0080 Q2 (an upgrade creates drafts, activates nothing) | OK | The runner reads the state, as the scenarios say. |
| all | stock-using scenarios | Posting is allowed for a storekeeper tenant-wide | 0073 REQ-830 (scoped principal posts only inside its units); 0076 R7 | OK (not verified) | The scenarios do not state whether the QA storekeeper holds a scoped grant. |

## 3. Notes on rows that are not plain OK

- **X1 (retry).** First pass knew the deferral to T-2029 (decision 0091 section 9). This pass adds that the
  expectation also contradicts 0057 D2 and 0058, which were decided earlier (2026-10-16) and do not defer it.
- **X2 (export).** Float in the xlsx cell is the documented trade-off of 0077:171; no action.
- **X3 (0056 open point 12).** Whether cancel of a document that has a pending task needs a second person is not
  decided. The scenarios assume it does not.

## 4. Contradictions as defect-task titles, warehouse order

Order: wrong stock first, then data loss, then security, then pilot-blocking documents, then wording.

**D1. Wrong stock: the old Qoimeks app address posts twice when the phone retries.**
Title: "fix: old-app POST /movements honours the client id: same id and same data returns the first movement, same id
and other data answers 409 idempotency_key_reuse".
- Side 1 (decision): 0057:14, 0058:13, 0058:27; 0073 amendment REQ-853 (`idempotency_key_reuse` for a retry with
  another value).
- Side 2 (code and scenario): `lib/letflow/modules/stock/old_app_writes.ex:32-34` (retry with the same client id
  "answers as Letflow does today", that is, posts a second document);
  `qoimeks-retry-1` EO-001/EO-002 (:198-:216), `qoimeks-retry-2` EO-001/EO-002 (:216), `qoimeks-retry-3` EO-001/EO-002
  (:181-:202).
- On the warehouse floor a phone with a poor signal sends a receipt or issue twice and stock moves twice. The three
  scenarios must be retired or rewritten when it lands. Check first whether T-2029 (first pass) already is this task.

**D2. Security: who may approve is decided by a role-name label, not by a permission.**
Title: "fix: stock approve and post tasks name their approver by the label TENANT_ADMIN while StockPost is held by
STOREKEEPER; decide the guard (permission or documented addressing) and say it in the scenarios".
- Side 1 (decision): 0088:58-62 (D1: "would renaming the role change an access answer? If yes ... must be replaced");
  0088:91-96 (D5: routing is addressing and never grants or refuses); 0057:18 (D6); `generate_pack.exs:207-208`
  (the label "is only a label ... the ledger authority step decides").
- Side 2: `qoimeks-count-6` header :3 and EO-003 (:132) ("the approval task is routed to the administrator role");
  `qoimeks-count-3` steps 3 and 5; `qoimeks-count-7`; `qoimeks-ledger-2` :57 and EO-002 (:145);
  `lib/letflow/tasks.ex:600` and `:690` (`ref in scope.role_names`); `stock.ex:312` (STOREKEEPER holds StockPost).
- Today the storekeeper is kept out only because the task is addressed to the administrator role. 0088 D5 allows that
  comparison to stay as data, so this is a soft contradiction: the scenario says "cannot approve" as a rule of
  authority, the decisions say it is a fact about addressing. If an administrator reassigns the task (checked: only
  `TasksReassignRouted`, administrators), or a tenant renames or replaces the role, the answer changes. The
  architect must say which it is.

**D3. Pilot-blocking documents: the four-eyes note and the pilot runbook say only the stock opening has four eyes.**
Title: "docs: four-eyes-switch.md section 6 and pilot-rollout.md step 6 name stock_quick_count (and the Excel load
that creates one) as a second four-eyes step".
- Side 1: `docs/design/four-eyes-switch.md:232-233` ("only one four-eyes approval exists, the stock opening ... for a
  one-person Client 1, switching four eyes OFF for `stock_opening / approve` is the whole need");
  `docs/runbooks/pilot-rollout.md:30` ("the four-eyes rule of the opening approval").
- Side 2: `priv/modules/stock/generate_pack.exs:339-346` (`stock_quick_count`, `approve` kept apart by
  `distinct_from`); `qoimeks-import-5` (BLOCKED, "no independent approver"); `qoimeks-count-5` header.
- A one-person Qoimeks client who follows the runbook can issue openings alone and still cannot confirm a count
  alone. Check also that `GET /approval-rules` lists `stock_quick_count` (`approval_rules_corpus_test.exs` should).

**D4. Scenario text out of date (no product change).**
Title: "uat: refresh stale text in qoimeks-count-* headers and qoimeks-import-6 description after stock 0.22.0".
- `qoimeks-count-6` :3 and its precondition "TARGET state after T-2239 (#4764, not merged on main)" against
  `stock.ex:317-320` and `docs/roles.md:189` (merged, 0.22.0). The same sentence is in the other count scenarios.
- `qoimeks-import-6` :22-23 ("today the quick count right guards the load") against its own header :1-3 and
  `router.ex:473` (`StockWorkbookApply`).
- `qoimeks-export-4` :41 ("item code, place") against `xlsx_export.ex:32` and 0086:63-67 (the cells are ids).

**D5. Decisions out of date (no product change).**
Title: "docs: mark 0078 D3 (no tenant time zone) and 0057 D16 (no Kazakh text) as superseded".
- 0078:65-72 against `identity/tenant_timezone.ex:19`; 0057:65 against checklist item 11 and rule 4 of the design
  system skill.

## 5. Not covered, and why

- Decisions with no scenario expectation: 0059, 0061, 0062, 0064, 0065, 0066 (both), 0067 (three), 0068, 0069, 0070,
  0071, 0072, 0074, 0075, 0082, 0083, 0084 (both), 0085, 0087, 0089. They are about definitions, scripts, hooks,
  print forms, provisioning, signup, MES and assets. No Qoimeks group prints an official form, purges a document,
  edits a tenant definition or uses assets. This is a coverage gap of the scenario set (print forms 0068, 0089 and
  numbering 0056/0075 have no Qoimeks scenario), not a contradiction.
- Pilot gate: pilot-rollout.md:17-18 says the stock module is not enabled for a customer until slices L6 and L7 are
  done. 0073 "Amended by REQ-832" says L7 part 2 (`expected_document_version`, typed `master_inactive`) is still owed.
  The scenario ledger-3 tests only part 1. Whether the gate is met is a question for the owner.

## 6. What I could not verify

- Decisions 0055, 0056, 0063, 0072, 0080 and 0089 were read by headings, grep for the scenario topics and selected
  paragraphs, not line by line. A contradiction in a paragraph I did not open is possible. Decisions 0059, 0061, 0062,
  0064..0071, 0074, 0075, 0082..0085 and 0087 were not read beyond title and grep.
- The scenarios were read through their `description` and `expected_outcomes`, not step by step. Step text (the
  exact wording of messages, buttons, refusals) was not compared with decisions.
- Nothing was run. No scenario was walked, no test run, no QA tenant opened. The statements about code
  (`old_app_writes.ex`, `tasks.ex`, `generate_pack.exs`, `xlsx_export.ex`, `tenant_timezone.ex`) come from reading
  the file on this branch.
- D2: I read `tasks.ex` lines 600 and 690 only as a role-name comparison; I did not run a completion by a
  storekeeper of a role-addressed task, so I do not know the exact refusal.
- Whether `approval_rules_corpus_test.exs` already lists `stock_quick_count` (D3) was not checked.
- Whether the storekeeper of the QA tenant holds a scoped grant (0073 REQ-830, 0076 R7) was not checked; the
  scenarios read the state at run time.
- Whether D1 is the same defect as T-2029 or one of T-2286..T-2292 was not checked: the first pass report is not on
  main.
- Voice, PWA sign-in, company code and APK release scenarios: no decision in the range covers them.
- The 0056 open point 12 (second person for cancel) and the reason rule for switching four eyes ON are undecided in
  the text I read.
