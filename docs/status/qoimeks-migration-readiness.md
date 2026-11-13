# Qoimeks pilot client (Client 1): readiness to move onto Letflow

Readiness note and recommendation to the owner, not a decision. Written by the business analyst on 2026-11-13 (task T-1907, owner statement D-143).

## Summary in plain words

- **Letflow is not ready to take Client 1 yet.** The largest block is in the product: the stock module may not be switched on for a real company until two ledger parts (slices L6 and L7 of decision 0073) are built. Neither is on main, and no open issue builds them.
- **Production is not ready either.** Production is not approved, the server is not bought, the DNS token and the backup key holder are not agreed with infra, and the production sign-in path is not chosen.
- **The data move is half prepared.** A converter turns a Qoimeks extract into Letflow import files, and a script compares record counts (T-1616). Five things are still missing: comparing stock quantities per item and place, moving barcodes, a rule for negative balances, a rule for movement history, and the Qoimeks inventory itself.
- **We do not yet know what Client 1 uses.** The Qoimeks team sends a read-only inventory through the PM, and it is not here. Section 1.3 lists what to ask.
- **Recommended order:** build L6 and L7, decide four small product questions, rehearse twice on QA, get the owner's production "go", then plan a short cut-over window. Qoimeks stays read-only for 30 days after the move.

## Status and limits

- Docs only. This note creates no tenant, account, server or DNS name. It spends no money, touches no secret and contacts no one. The owner or the PM talks to the client (`docs/uat/ba-decisions/T-1569.md`, section 5).
- **Source of the task:** owner statement D-143 (PM, 2026-11-13), quoted from the task text: "the first production action is migrating the Qoimeks pilot client (Client 1) onto Letflow; it moves when the Letflow applications are ready (D-115)". The portfolio `DECISIONS.md` is not in this repository. Everything here rests on that quote and on the files listed below.
- Production is **not approved** (`docs/runbooks/pilot-rollout.md`, "Status"; `docs/uat/ba-decisions/T-1600.md`, header). Every production step below is a proposal.
- Marks used: **[Q]** = fact about Qoimeks taken from the Qoimeks team's own documents (copied below; they describe what Qoimeks *can* do, not what Client 1 *uses*); **[A]** = UAT assumption, to be confirmed by the process owner; **[INV]** = the inventory must confirm it.

## Sources opened

In this repository (origin/main at the time of writing):
- `docs/runbooks/pilot-rollout.md` (whole file), `docs/runbooks/qoimeks-rehearsal.md` (whole file), `docs/runbooks/pilot-first-month.md` (Status, Week 1, "must not rely on", Interim sign-in path, Exit criteria, Open owner questions).
- T-1616 tooling: `scripts/pilot/qoimeks_convert.py` (`MAX_ROWS = 200`, `MAX_LINES = 100`, the drop reasons), `scripts/pilot/qoimeks_compare.sh` (header).
- `docs/uat/ba-decisions/T-1569.md` (section 5, the Qoimeks facts marked [V]) and `docs/uat/ba-decisions/T-1600.md` (sections 1, 3, 4, 7; supersedes T-1569 where they differ).
- `docs/status/owner-questions-2026-11.md` (rows A1–A21, D3, D7, D8).
- `docs/migration/decisions/0073-domain-neutral-ledger-primitive.md` (Consequences table: rows PILOT GATE, L6, L7), `docs/migration/decisions/0079-opening-balances-and-ledger-xlsx.md` (the paragraph "the opening document, like the stock module, is not offered on a customer tenant before the PILOT GATE of 0073").
- Code: `lib/letflow/ledger.ex` (`authorize/3` accepts only `:read | :reconcile`; moduledoc: "The stock module is NOT enabled for a customer tenant until L6 AND L7 are done"), `lib/letflow/modules/stock/access.ex` ("not built (L6)"), `lib/letflow/modules/stock/count_posting.ex` and `handlers.ex` ("until slice L7"), `lib/letflow/modules/stock/stock.ex` (issue legs are negative and "the ledger refuses a posting below zero (`insufficient_stock`)"; "A line has no price or value"), `lib/letflow/modules/stock/xlsx_export.ex`.
- `docs/runbooks/wms-foundation.md` (stock module limits 1–4), `docs/runbooks/stock-counts.md` ("What exists"), `docs/runbooks/stock-voice.md` (Settings), `docs/assets/asset-xlsx.md` (currency rows), `docs/assets/phone-flows.md` and `docs/assets/voice-port-design.md` section 1, `docs/mobile/pwa-parity.md` (Status).

Outside this repository (copied, because the gate sees only this worktree):
- `Qoimeks-team/project/retirement-criteria.md` (draft, 2026-10-25, by the Qoimeks operator for the PM) and `Qoimeks-team/project/features-to-port.md` (2026-10-31, "written from the files only"). Both are already cited by `docs/assets/phone-flows.md`. Full copies are in the task folder (`state/tasks/T-1907/sources/`). The passages relied on are quoted in section 1.1 and marked [Q]. **These are not the client inventory.**
- Not opened: the Qoimeks product code and database, `Qoimeks-team/project/client1-*.md` beyond the first 15 lines of `client1-migration-plan.md` (quoted in section 1.1), the portfolio `DECISIONS.md`, the infra session.

Searches behind "not found" claims (run on this worktree, origin/main a7f2410ba):
- `grep -rn "scope_slot" lib/letflow/ledger.ex`: the hits concern `:read` only. `Ledger.authorize/3` has `when purpose in [:read, :reconcile]`, so there is no posting scope (L6).
- GitHub search `repo:tvolodi-org/letflow is:open` for `L6`, `L7`, `APK`, `negative balance`, `code_assignment import`, `Qoimeks`, `retirement`: no open issue. `opening posting` found #4409, #4058 and #4037, which are for assets, not stock.
- `grep -rli feedback apps/mobile/lib`: no hit (there is no "report a problem" feature in the phone app).
- `grep -rn -i "apk\|play store\|signed release" docs/mobile/*.md docs/runbooks/*.md`: no hit (there is no Android release or distribution runbook).

## 1. Fit and gap

### 1.1 What Qoimeks offers today [Q]

From `features-to-port.md` and `T-1569.md` section 5:
- Ledger: SKUs (code, name, unit, usual location, second place, barcode) and locations (code = zone + rack + shelf, for example `RI2`). One form with four kinds: receipt, issue, transfer and count ("adjustment"). A count *replaces* the balance. "Issuing more than the balance is allowed … balance goes negative." Movements are append-only, a reversal is a new movement, and posting is idempotent by operation id.
- Excel: import of the bookkeepers' weekly file (Russian headers starting «Артикул», decimal comma tolerated), checked first, then applied; "Записать остатки из файла" turns each differing balance into an adjustment; a whole import can be cancelled. Export in the same layout, including the codes.
- Codes: EAN-13/8, Code128, QR, manual; one active code per object; find by code and assign from the phone.
- Voice and typed entry in ru and kk. The phrase becomes a draft, which the operator checks and posts.
- Phone: Android app (APK, daily update check, setup by QR), an iPhone web build (PWA), and ru/kk UI.
- Access: "No user accounts". A shared access code per tenant; the operator name is only a label. Phone pairing gives device keys.
- Feedback from the app (text, device, last errors) and an error log on the server.
- Client 1 data size [V in T-1569]: about 600 movements, 600 balances, 666 SKUs, 134 locations, 3 imports; database 11 MB, 2 tenant schemas (Client 1 and the owner's test tenant), on hetzner-prod as `qoimeks-prod` + `qoimeks-db`. The Qoimeks plan `client1-migration-plan.md` (first lines read, 2026-10-27) says instead that production serves Client 1 "from the **default schema** (`public`)" and plans to move it into a tenant: which is true today is inventory question 15.
- Not in Qoimeks either: prices or money, roles, label printing (features-to-port.md section 9).
- Move-in criteria of the Qoimeks operator (`retirement-criteria.md`, a draft for the PM, not a decision). Criterion 7 is the data move: "the existing catalog, locations, ledger and balances can be carried over and checked". Its test: "Dry run on a copy of production data: balances per SKU and location identical before and after; the move is repeatable and can be rolled back". Criterion 10 is the parallel run: "Qoimeks stays live and read-only after the move for an agreed period; the owner of the warehouse signs off after one full weekly reconciliation against the bookkeepers' file".

### 1.2 Fit and gap table

"Fit" = Letflow already covers it on main. "Gap" = something must be built or decided. **Which rows matter depends on the inventory** [INV].

| # | Area | Qoimeks [Q] | Letflow on main | Fit? | Gap and the task that closes it |
|---|---|---|---|---|---|
| G1 | Stock module on a real company | n/a | Built: receipt, issue, write-off, transfer, opening, reversal (`stock.ex`; `wms-foundation.md` item 4). **Blocked by the PILOT GATE of decision 0073:** not enabled for a customer tenant until L6 (posting scope) and L7 (master checks) are done. L6 is not in `Ledger.authorize/3`; L7 is cited as missing in `count_posting.ex` and `handlers.ex`. | **No** | **No task: propose one per slice.** One `requirement` task for L6 and one for L7 (decision 0073 slice rows L6, L7). L7 "depends on the OQ-R4 read facade (owed at WMS slice 5)" (0073, row L7), so L7 may need a third task first. This is the critical path. |
| G2 | Serial-tracked goods | Not named in [Q] | Out of the pilot until OQ-23 (0073 PILOT GATE) | Fit if Client 1 has none [INV] | If the inventory shows serial numbers: no task, propose a decision on OQ-23 |
| G3 | Negative balances | Allowed (an issue may go below zero) | Refused: `insufficient_stock` (`stock.ex`); the converter drops balance rows ≤ 0 (`quantity_not_positive`) | **No** (a rule differs) | Product decision for the owner; see the recommendation in section 2.2 [A]. No task: propose a `ba_question` if the inventory shows negative balances |
| G4 | Count | "adjustment" kind that replaces the balance | Formal count: order, sheet, differences, posting, freeze mode, printed Inv forms (`stock-counts.md`) | Fit, heavier process | Training only: STOREKEEPER holds `StockCountOrder` and `StockCountRecord` (`stock.ex`, role grants). Confirm the client accepts a formal count instead of a one-line adjustment [INV] |
| G5 | Items and units | SKU code, name, free-text unit | `catalog_item`, `catalog_uom` with xlsx import (pilot-rollout.md rows 7–8). The converter builds the units from the distinct unit texts | Fit | "Usual location" and "second place" of a SKU are not written by the converter. No task: propose one only if the inventory says they are used |
| G6 | Locations | Flat code zone/rack/shelf | `location_node` with parent; the converter accepts an optional `loc_parent` | Fit | none |
| G7 | Codes (barcodes, QR) | One code per SKU or location, used by the phone scan | `codes` module exists; `code_tag` and `code_assignment` have **no file import** (pilot-rollout.md rows 11–12). The converter does not carry codes | **Partly** | **No task: propose one.** Either an xlsx import of code assignments or a converter extension plus a hand route. By hand, 666 SKUs is too slow [A] |
| G8 | Weekly Excel from the bookkeepers | Import the weekly file, adjust balances, cancel a whole import | Only the opening-lines import exists for stock ("Stock has no card import … one import of its own", qoimeks-rehearsal.md). No "apply the weekly file as adjustments" path | **No** | Depends on the inventory: does the client still run the weekly file? If yes, no task: propose a requirement. Retirement criterion 2 asks for it |
| G9 | Export and reports | Balances by SKU or by place, Excel export | Balances and movements xlsx export (`xlsx_export.ex`, REQ-728); saved reports in the left menu (#4405) | Fit, different layout | The export columns are not the Qoimeks layout. Confirm the bookkeepers accept it [INV] |
| G10 | Voice ru/kk | Speech to text, then a model draft | Built (`stock-voice.md`, REQ-740/741). All provider settings are **unset by default**. QA keys wait for the owner's line (owner-questions D1; owner-gate-review D2) | Fit when keys are set | Owner: keys and money. Production keys are not covered by any decision |
| G11 | Phone app | Android APK with self-update, iPhone PWA | Flutter `apps/mobile` with `codes` and `stock` features; PWA hosting runbook. Android vs PWA for the gaps is open (owner-questions D8). There is no Android release or distribution runbook (search above) | **Partly** | Owner decision D8. If Android: no task, propose an APK release and distribution requirement |
| G12 | Access and roles | Shared code, no accounts | One account per person; roles `TENANT_ADMIN`, `STOREKEEPER`, `TENANT_AUDITOR` (pilot-rollout.md, Onboarding 4). Created users get a sign-in by hand (interim path (a), D-118 (1)); option (b) is decided for QA only, flag OFF (pilot-first-month.md) | **Partly** | Every operator needs a real e-mail and an account (A10, A14). Accountant role open (A2). Production sign-in not chosen (production-readiness.md, "Sign-in per company"; owner-questions A15) |
| G13 | Printed forms | none [Q] | Z-, Inv-, DA- forms (pilot-rollout.md, "Printed forms") | Extra | none |
| G14 | Currency and prices | none | Stock lines have "no price or value" (`stock.ex`); assets use one currency per tenant (D-097, KZT by default; `asset-xlsx.md`) | Fit | none, unless the inventory shows prices [INV] |
| G15 | Movement history (about 600) | Kept forever in Qoimeks | The rehearsal moves opening balances only ("Deliberately not here: … movement history", qoimeks-rehearsal.md). Opening documents post at posting time, with no backdating (0079 D1) | **No** (by design) | Decision, section 2.2: history stays in Qoimeks (read-only) plus an archived export [A] |
| G16 | Feedback from the app | "Report a problem" in the app | Not found (search above). Problems go to the operator, who files a GitHub issue (pilot-rollout.md, "Support") | **No** | Channel is an owner question (pilot-rollout.md open question 4). No task: propose one only if the owner wants it in the app |
| G17 | Phone pairing and setup QR | Pairing code, device key | Not needed: the person signs in with their own account | Fit by a different design | Training |
| G18 | Opening balances in Letflow | n/a | `stock_opening_line` import plus opening documents; also behind the PILOT GATE (0079) | Blocked by G1 | Closed by the G1 tasks |

### 1.3 Questions for the Qoimeks inventory (send through the PM)

Each answer must be a count or a yes/no taken from Client 1's own data, read-only.
1. How many SKUs, locations, balance rows and movements does Client 1 have today? Are any balances **negative** or **zero**, and how many? (G3)
2. Are any quantities fractional, with a decimal comma or with more than 3 decimals? (The converter drops `quantity_comma_decimal` and `quantity_invalid`.)
3. Which unit texts are used, and how many distinct ones? (G5)
4. Do any SKU or location codes contain `:`, spaces, Cyrillic look-alike letters or a duplicate? (Converter drops; `bal_ref` design.)
5. Is the "usual location" or "second place" of a SKU used in daily work? (G5)
6. How many active codes (barcodes, QR) exist, and of which types, per SKU and per location? (G7)
7. Does the client still import the weekly Excel file? How often, who does it, and was any import cancelled? Please send one sample file with the data removed. (G8)
8. Which reports or exports do the bookkeepers take out of Qoimeks, and in which layout? (G9)
9. How many people post movements: by voice, by keyboard, by scan? On Android, iPhone or the web? (G10, G11)
10. How many people use the system, which roles do they need, and does each have their own e-mail address? (G12; owner-questions A10, A11)
11. Is any item serial-tracked or tracked by lot or expiry date? (G2; lots are not moved by the converter)
12. Are prices, values or a currency stored anywhere? (G14)
13. How far back does the client need to see movement history, and for what (audit, tax, disputes)? (G15)
14. When are the quiet hours of the warehouse (no postings)? How long a pause is acceptable? (Section 2.5)
15. Is Client 1's data in the `public` schema of `qoimeks-prod` or in a tenant schema? T-1569 and `client1-migration-plan.md` say different things (section 1.1).

## 2. Data migration path and rehearsal plan

### 2.1 What moves, and in which file

| Data | Moves? | File (T-1616 converter output) | Letflow importer | Notes |
|---|---|---|---|---|
| Locations | yes | `01-locations-NN.xlsx`, ≤ 200 rows each | `Locations.Import` | a parent must come earlier in the file |
| Units | yes | `02-uoms.xlsx` | `CatalogItems.Import` | built from the distinct unit texts |
| Items | yes | `03-items-NN.xlsx`, ≤ 200 rows each (about 4 files for 666 SKUs) | `CatalogItems.Import` | |
| Opening balances | yes, positive ones only | `04-opening-lines-NN.xlsx`, ≤ 100 lines per opening document (about 6 for 600 balances) plus `headers/QOI-HDR-NN.json` | `Stock.Documents.OpeningImport` | posted at posting time (0079 D1); needs G1 |
| Org unit, responsible employee | created by hand | `--org-unit-ext`, `--responsible-ext` | `org` module | "Qoimeks has no such notion" (qoimeks-rehearsal.md) |
| Codes | **not yet** | none | none (no file import) | G7 |
| Movement history | **no** | none | none | G15, section 2.2 |
| Users | from a list, not from Qoimeks (Qoimeks has none) | users xlsx (REQ-791, ≤ 200 rows) | Users import | sign-in path (a): accounts made by hand |
| Feedback, error log, provider keys, pairing codes | no | none | none | not business data [A] |

All files use external ids under one system name (`--system`); every import runs with `dry_run=true` first, then `atomic=true` (qoimeks-rehearsal.md, steps 3–5).

### 2.2 Rules recommended for the move [A]

These are for the owner to confirm. They are not product rules.
- **R-1 Opening balance, not history.** Client 1 starts in Letflow with one opening balance per item and place, as of the cut-over. The movement history stays in Qoimeks (read-only, section 2.6). One Qoimeks movement export (the Qoimeks xlsx export, features-to-port.md section 3) is archived outside git as the record. Reason: Letflow refuses backdated postings (0079 D1), and replaying 600 movements adds risk for little use.
- **R-2 Negative balances are settled before cut-over.** The client counts each negative balance and fixes it in Qoimeks before the freeze. A zero balance moves as no row. Reason: Letflow refuses a balance below zero (`insufficient_stock`), and the converter drops such rows, so the counts would not match.
- **R-3 After the move, an issue above the balance is refused.** Storekeepers must post the receipt first. This is a change of daily habit and must be in the training (G3).
- **R-4 Codes move with the masters** once G7 has a path. Until then the move does not start, if the inventory shows codes in daily use.

### 2.3 Rehearsal plan (QA only, on a frozen copy)

Each step uses `docs/runbooks/qoimeks-rehearsal.md`. Nothing touches `qoimeks-prod`.

| Step | What | Done when |
|---|---|---|
| RH-0 | Preconditions: G1 tasks merged and deployed to QA; an empty QA copy tenant with modules in the pilot-rollout.md order (`org`, `catalog_items`, `codes`, `locations`, `stock`); org unit and responsible employee created | the tenant snapshot shows the modules active and no records |
| RH-1 | Extract `locations.csv`, `items.csv` and `balances.csv` from a **copy** of the Qoimeks database (Qoimeks team, read-only); `map.json` if the column names differ | three files outside the repository |
| RH-2 | Convert (`qoimeks_convert.py convert`) | `report.txt` has no drop, or every drop is explained and agreed with the client contact |
| RH-3 | Upload the masters, then create the headers, then upload the lines (runbook steps 3–5) | nothing refused |
| RH-4 | Record-count check (`qoimeks_compare.sh`) | exit 0 |
| RH-5 | Post the opening documents (a human task, `StockPost`) | every opening document is posted |
| RH-6 | **Quantity check per item and place**: Letflow balances (stock balances xlsx export) against `balances.csv` | no difference. **No tool yet: propose a task** for a compare script like `qoimeks_compare.sh`. The runbook leaves this as "a manual follow-up" |
| RH-7 | Repeat RH-3 with the same files | every row `unchanged` (runbook, "Repeating") |
| RH-8 | Time the whole run | the time is written down; it sizes the cut-over window |
| RH-9 | A second rehearsal on a fresh copy, taken a week later | the same result, and drops only for known reasons |

### 2.4 Reconciliation checks (all must pass, at rehearsal and at cut-over)

1. Record counts: locations, units, items and opening lines equal `expected_counts.txt` (`qoimeks_compare.sh` exit 0).
2. Quantity per (item, place) equals the frozen Qoimeks balance. Rows dropped under R-2 are listed and agreed.
3. Totals per item (sum over places) equal. The client's bookkeeper confirms them, as in exit criterion M1/M2 of `pilot-first-month.md`.
4. Codes: count of active codes per type equal (after G7).
5. Spot check by the client: 20 items chosen by the client, checked on the phone [A: number proposed, not sourced].

### 2.5 Cut-over window (proposal, T-1569 section 5 steps 4–6)

1. The Letflow tenant, realm and accounts exist days before; each person has signed in once (M5 of `pilot-first-month.md`).
2. At the start of the agreed quiet hour, Qoimeks is put read-only. Qoimeks has a `MAINTENANCE_MODE` that makes writes answer 503 (features-to-port.md section 9). Which switch the Qoimeks team uses is for them to confirm.
3. Freeze extract, convert, load and post (RH-1 to RH-6 on the production tenant).
4. Run checks 1–5. If all pass, users switch to Letflow. If any fails and cannot be explained within the window, roll back.
5. The length of the window comes from RH-8, plus a margin. No number is given here: the owner decides it with the client (question 14).

### 2.6 Rollback, and what the client does in parallel

- **Rollback (T-1569 section 5):** re-enable writes in Qoimeks and point users back to it. Anything entered in Letflow after cut-over is exported (stock movements xlsx) and re-entered in Qoimeks by hand. The Letflow tenant is left as it is for analysis and is not deleted without the owner.
- **Point of no return** [A]: the first full business day on Letflow without rollback. After it, a rollback means re-entry by hand.
- **Parallel run:** Qoimeks stays read-only for 30 days (T-1569 step 6), so history (R-1) can be looked up. One full weekly check against the bookkeepers' Excel follows (retirement criterion 10 [Q]). The client does not post in both systems [A]: double entry makes the counts drift.
- **Who tells the users:** the owner or the PM, in ru/kk, a week before and on the day (T-1569 section 5). The team writes the text and contacts no one.

## 3. Readiness conditions, in order

Each one waits for the one before it, except where "parallel" is said.

| # | Condition | State today | Blocks on |
|---|---|---|---|
| C1 | The Qoimeks inventory has arrived and answers section 1.3 | not here | PM and the Qoimeks team |
| C2 | Ledger slices L6 and L7 are built and merged, with OQ-R4 first if needed (G1). Parallel with C1 | no task | team (tasks to propose); the WMS order of the owner |
| C3 | Product decisions: negative balances (R-2/R-3), history (R-1), codes path (G7), weekly Excel (G8), Android or PWA (D8) | open | owner, after C1 |
| C4 | Builds that C3 asks for (codes import, quantity compare tool RH-6, and whatever else C3 chooses) | no tasks | team |
| C5 | Two clean rehearsals on QA (section 2.3) | not started | C2, C4 |
| C6 | **Production go**: owner approval (D-086; pilot-rollout.md, "Before the pilot starts" 1) | not approved | owner |
| C7 | **VPS**: option A is chosen (T-1600 row a), but the purchase waits for the PM's money step with the owner | prepared, not bought | owner and PM; infra |
| C8 | **DNS**: wildcard `*.letflow.ai-dala.com` accepted (T-1600 row b). The DNS-edit token model still has to be agreed with infra | open | infra (T-0251), owner |
| C9 | **Backups**: off-site copy wanted (T-1600 row f). Still open: who holds the gpg private key, and `LETFLOW_SECRETS_MASTER_KEY` kept apart from the data (T-1600 sections 3 and 4.6). A restore drill has passed (T-1600 section 4.4: "before the first paying customer") | open | owner and infra |
| C10 | **Monitoring**: alert log and runbooks for the AI on-call (T-1600 section 4) | not built | infra and team |
| C11 | **Sign-in**: the production sign-in path is chosen (owner-questions A7, A15, A18). Accounts for every Client 1 user exist, and each user was seen signing in once (M5) | QA only; production open | owner, infra (Keycloak operator, A9) |
| C12 | Phase F gate of the owner (pilot-rollout.md, "Before the pilot starts" 4; D-063) | open | owner |
| C13 | Training in ru/kk, and the user notice a week before (who trains: owner-questions A3) | open | owner and PM |
| C14 | Cut-over window agreed with the client (section 2.5) | open | owner, PM and client |

**Owner items that block the move** (from C3, C6–C9, C11–C14): production go; VPS money; DNS token model; backup key holder and off-site target; production sign-in; Android or PWA; negative balance and history rules; who trains and who tells the users; the window.

## 4. One table for the owner

| What | Ready? | What is missing | Who |
|---|---|---|---|
| Stock in Letflow for a real company | No | Two ledger parts (L6, L7) | Team |
| Client's data (items, places, balances) | Half | Quantity check tool; barcodes; inventory | Team, Qoimeks team |
| Old history (movements) | Plan only | Your yes: keep it in old Qoimeks, read-only | You |
| Minus balances | Plan only | Your yes: fix them before the move | You |
| Phone app | Half | Your choice: Android or web app | You |
| Voice | Built | Keys and money | You |
| People sign in | QA only | Your choice for production | You, infra |
| Server | Chosen, not bought | Money step | You, PM |
| Domain name | Chosen | DNS token with infra | Infra |
| Backups | Planned | Who keeps the key; off-site place; one test restore | You, infra |
| Alerts | Not built | Alert list and runbooks | Infra, team |
| Production "go" | No | Your yes | You |
| Practice move on QA | Not started | Needs the lines above | Team |
| Tell the users | Not started | Who and when | You, PM |

## Assumptions (all UAT assumptions, to be confirmed by the process owner)

- The target of the move is the Letflow stock module plus codes, not assets (T-1569 section 5 says the same and marks it as an assumption).
- R-1 to R-4 in section 2.2, the point of no return in section 2.6, the 20-item spot check in section 2.4, and "no double entry" in section 2.6.
- What Client 1 *uses* equals what Qoimeks *offers* until the inventory says otherwise. Every [INV] row may become "not needed".
