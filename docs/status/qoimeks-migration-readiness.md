# Qoimeks pilot client (Client 1): readiness to move onto Letflow

Readiness note and recommendation to the owner, not a decision. Written by the business analyst on 2026-11-13 (task T-1907, owner statement D-143). Rewritten the same day from the Qoimeks inventory of Client 1.

## Summary in plain words

- **The first move is stock only.** Client 1 uses Qoimeks for stock: an Excel import and reading the stock are confirmed. It has no assets, no money and no printing. So the move needs the stock module, codes, import, voice and an answer for the old shared token. Assets and fixed-asset counts are not part of this move.
- **Letflow is not ready to take Client 1 yet.** The biggest block is in the product. The stock module may not be switched on for a real company until two ledger parts (slices L6 and L7 of decision 0073) are built. Neither is on main, and no open issue builds them.
- **Three Qoimeks habits do not fit Letflow as it is:**
  - the shared token, which Letflow stock does not accept;
  - negative balances, which Letflow refuses;
  - a count that simply replaces a balance, where Letflow has a formal count process instead.
  Each needs an owner decision (section 1.2, rows G4, G5, G13).
- **Production is not ready either.** Production is not approved and the server is not bought. The DNS token and the backup key holder are not agreed with infra. The production sign-in path is not chosen.
- **The data is small:** 666 items, 134 places, 600 balances, 600 movements, 3 imports, 11 MB (all as of 2026-10-29). The converter and a count compare exist (T-1616). A quantity compare is still missing. The Qoimeks rule "no real data leaves production" changes how we rehearse (section 2.3).
- **Recommended order:** build L6 and L7. Get the owner's answers on token, minus balances, counts and history. Rehearse twice on QA with same-shape test data. Get the production "go". Then plan a short move outside Client 1's working hours. Qoimeks stays read-only for 30 days after the move.

## Status and limits

- Docs only. This note creates no tenant, account, server or DNS name. It spends no money, touches no secret and contacts no one. It asks for no production access: the PM already holds the ten read-only production counts of the inventory (section 1.3). The owner or the PM talks to the client (`docs/uat/ba-decisions/T-1569.md`, section 5).
- **Source of the task:** owner statement D-143 (PM, 2026-11-13), quoted from the task text: "the first production action is migrating the Qoimeks pilot client (Client 1) onto Letflow; it moves when the Letflow applications are ready (D-115)". The PM update of the same day sets the scope: "STOCK-ONLY pilot: assets and fixed asset count NOT needed for the first migration; needed: stock module, codes/barcodes, import, voice, a way to keep the old token working". The portfolio `DECISIONS.md` is not in this repository. Decisions named only by the inventory (D-042, D-045, D-050) are quoted from it.
- Production is **not approved** (`docs/runbooks/pilot-rollout.md`, "Status"; `docs/uat/ba-decisions/T-1600.md`, header). Every production step below is a proposal.
- Marks used:
  - **[INV §n]** = fact from the Qoimeks inventory of Client 1, section n;
  - **[A]** = UAT assumption, to be confirmed by the process owner;
  - **[count n]** = confirmed by read-only production count n, which the PM holds (inventory §4, list 1–10).

## Sources opened

The inventory, outside this repository (read-only, not edited). It is copied to the task folder because the gate sees only this worktree:
- `Qoimeks-team/project/client1-inventory.md`, written 2026-11-13 by the Qoimeks operator from files only. Copy: `state/tasks/T-1907/sources/client1-inventory.md`. It is the main source of section 1. Its marks: "**confirmed** = a file says Client 1 uses it; **available** = live on production, use not confirmed; **unknown** / **guess** as written".
- Also copied there and still used, for what Qoimeks can do: `Qoimeks-team/project/retirement-criteria.md` (a draft for the PM) and `features-to-port.md`.

In this repository (origin/main a7f2410ba):
- Runbooks and earlier decisions:
  - `docs/runbooks/pilot-rollout.md` and `docs/runbooks/qoimeks-rehearsal.md` (whole files);
  - `docs/runbooks/pilot-first-month.md` (Week 1, Interim sign-in path, Exit criteria);
  - `docs/runbooks/stock-counts.md` (whole file, including "Posting a count" and "The freeze locations mode (REQ-765 … Owner decision D-094)");
  - `docs/runbooks/stock-voice.md` (Rules, Routes);
  - `docs/uat/ba-decisions/T-1569.md` (section 5), `docs/uat/ba-decisions/T-1600.md` (sections 1, 3, 4);
  - `docs/status/owner-questions-2026-11.md`;
  - decisions `0073-domain-neutral-ledger-primitive.md` (PILOT GATE, L6, L7, D6 "OQ-R4 stays owed") and `0079-opening-balances-and-ledger-xlsx.md`.
- T-1616 tooling: `scripts/pilot/qoimeks_convert.py` (`MAX_ROWS = 200`, `MAX_LINES = 100`, drop reasons `quantity_comma_decimal`, `quantity_invalid`, `quantity_not_positive`) and `scripts/pilot/qoimeks_compare.sh`.
- Four-eyes switch (section 1.4, added 2026-11-14, task T-1945): `docs/design/four-eyes-switch.md` (Plain summary, Owner table, sections 0 to 3.3, 4, 6) and `docs/uat/ba-decisions/T-1944.md`; `priv/modules/stock/generate_pack.exs` (`two_step_definition` used once, for `stock_opening`; every other stock process is one `post` or `reverse` task).
- Code:
  - `lib/letflow/ledger.ex`: `authorize/3` accepts only `:read | :reconcile`. Its Reversal section has `posting_is_reversal` and `posting_already_reversed`, and its idempotency section has `idempotency_key_reuse`.
  - `lib/letflow/ledger/codes.ex`: these codes answer 409.
  - `lib/letflow/ledger/validate.ex`: `quantity_scale` refuses more than 9 decimals.
  - `priv/repo/migrations/20261031200001_create_ledger_triggers.exs`: the trigger `ledger_entry_guard_update` BEFORE UPDATE calls `ledger_refuse()`.
  - `lib/letflow/modules/stock/access.ex`: an interactive OIDC user only, "an API token is a different kind". Also "not built (L6)".
  - `lib/letflow/modules/stock/router.ex`: "an API token or a scoped principal gets the same 404". Voice draft takes "m4a or WebM", `lang` `ru` or `kk`.
  - `lib/letflow/modules/stock/stock.ex`: STOREKEEPER holds `StockRead`, `StockPost`, `StockReverse`, `StockCountOrder` and `StockCountRecord`. A balance below zero is refused (`insufficient_stock`). "A line has no price or value".
  - `lib/letflow/modules/stock/documents.ex`: `idempotency_key: Ecto.UUID.generate()`, a fresh server key per write.
  - `lib/letflow/modules/stock/voice_prompt.ex`, moduledoc: "Out of scope (open owner questions 4 and 5): … the letter-name table and the zone words of Qoimeks".
  - `lib/letflow/modules/stock/voice_service.ex`: it detects `audio/mp4` and `audio/webm`.

Searches behind "not found" claims (run on this worktree):
- `grep -rln ACCESS_TOKEN_TENANT lib docs web apps`: no hit. Letflow has no shared tenant token.
- `grep -rniE "second_place|second place|default_location|usual" priv/modules/catalog_items/ lib/letflow/modules/catalog_items/`: no hit. Letflow items have no "usual place" or "second place" field.
- GitHub search `repo:tvolodi-org/letflow is:open` for `L6`, `L7`, `negative balance`, `code_assignment import`, `Qoimeks` (first attempt of this task): no open issue.
- `grep -rli feedback apps/mobile/lib`: no hit. `grep -rn -i "apk\|play store\|signed release" docs/mobile/*.md docs/runbooks/*.md`: no hit (no Android release runbook).

## 1. Fit and gap

### 1.1 What Client 1 uses today [INV]

- **Where:** Qoimeks production, release `e5fa19f`, migrations 001–009. Since 2026-10-29 Client 1's data is in its own tenant `ddee98f0-…`. The old default-schema copy is kept 30 days after the checks [INV §0].
- **Data:** 666 SKUs, 134 places, 600 movements, 600 balance rows, 3 imports, 0 feedback rows. Database 11 MB. All numbers are from 2026-10-29 or older. Anything later is unknown [INV §4].
- **Confirmed use:** the Excel import ("3 imports on production") and reading the stock (the owner's read check after the tenant move was "same as before") [INV §1].
- **Unknown use:** hand entry of movements, voice, typed phrases, reversal, stock export, setup QR, the APK self-update. The guess is that the 600 movements came mostly or all from the 3 imports [INV §1].
- **Not used on production:** codes and scanning, phone pairing, the offline queue. These are on QA only. But `skus.barcode` can be filled from the «Штрихкод» Excel column [INV §0, §1].
- **No money, no printing.** No price, cost or currency. No print, PDF or label code. Exports are the stock .xlsx and the feedback Markdown only [INV §2, §7].
- **Quantities and unit:** `numeric(14,3)`, so decimals are possible. Unit default `шт`, and the guess is that all 666 are `шт` [INV §7].
- **No accounts, no roles.** One shared token maps to Client 1's tenant through `ACCESS_TOKEN_TENANT`. The operator name is free text. The kinds of people are operators on Android, bookkeepers and the manager in a browser, and the warehouse master on an iPhone. How many people: unknown [INV §3].
- **Integrations:** ElevenLabs (speech) and xAI Grok (model). Excel in the browser. Nothing else [INV §5].
- **Languages:** ru and kk UI and voice. Excel headers are Russian only [INV §6].
- **The bookkeepers' weekly Excel workbook is the authority on balances.** Its content is never stored on the server [INV §2].

### 1.2 Fit and gap table (stock-only scope)

"Fit" means Letflow already covers it on main. "Gap" means something must be built or decided. "§8.n" is item n of the inventory's "Peculiarities a replacement must keep". The last column names the PM-held count that confirms how much the row matters.

**Out of scope for this move** (PM update, 2026-11-13): assets, fixed-asset counts, asset printed forms and asset currency. They are not requirements here. Qoimeks has no asset concept [INV §4].

| # | Area | Client 1 in Qoimeks [INV] | Letflow on main | Fit? | Gap, and the task that closes it | Confirmed by |
|---|---|---|---|---|---|---|
| G1 | Stock module on a real company | n/a | Built: receipt, issue, write-off, transfer, opening, reversal, counts (`stock.ex`, `stock-counts.md`). **Blocked by the PILOT GATE of decision 0073:** not enabled for a customer tenant until L6 (posting scope) and L7 (master checks) are done. `Ledger.authorize/3` has no posting purpose; `stock/access.ex` says "not built (L6)". L7 depends on the OQ-R4 read facade (0073 D6) | **No** | **No task: propose one per slice:** one `requirement` task for L6 and one for L7, plus OQ-R4 first if L7 needs it. This is the critical path. | — |
| G2 | Items, unit, decimals | 666 SKUs, unit `шт`, quantities up to 3 decimals [§7] | `catalog_item`, `catalog_uom` with xlsx import. The ledger accepts up to 9 decimals (`validate.ex`, `quantity_scale`). The converter builds units from the distinct unit texts; it drops a decimal comma (`quantity_comma_decimal`), so the extract must use a dot | Fit | none | count 6 (units) |
| G3 | Place codes and the second place (§8.1) | Code = zone letter + rack letter + shelf number, e.g. `RI2`, name «Справа I 2». A SKU has a usual place and a **second place** (Excel column G) | `location_node` with a free-text code and an optional parent: the code scheme fits as text. **No item field for a usual or second place** (search above). The converter writes neither | Fit for codes; **Gap** for the second place | If count 6 shows SKUs with a second place: **no task: propose one** (an item field or a note column, and the converter extension). Otherwise none. Count 7 shows codes that break the scheme (also the `?` place) | counts 6, 7 |
| G4 | **Negative balances** (§8.3) | Allowed, with the warning «Остаток станет отрицательным» | **Refused.** An issue below the balance is `insufficient_stock` (`stock.ex`; ledger code `insufficient_balance`, 409, `ledger/codes.ex`). The converter drops balance rows ≤ 0 (`quantity_not_positive`) | **No: the rule differs** | Owner decision. Recommendation R-2/R-3 (section 2.2): fix minus balances in Qoimeks before the freeze; after the move an issue above the balance is refused (training). No task, unless the owner wants minus balances in Letflow; that changes the ledger rule and needs a decision record | count 8 (negative and zero rows) |
| G5 | **Counts that REPLACE the balance** (§8.4) | A count (`adjustment`) is one line that sets the balance to the counted number; qty 0 allowed only for a count | **No one-line "set balance".** Only the formal count order: order, open, count sheet, sign, differences, sign, post task (`stock-counts.md`). It posts the **difference** (counted minus book at the cut-off), not "counted = balance". In the default mode nothing stops movements during counting, so the balance ends at "balance now plus difference" ("Known gaps" 1 and 3). **D-094 freeze mode** (`freeze_locations`, REQ-765) refuses every posting in the frozen places with `409 location_frozen` until the count is posted, cancelled or the limit (default 120 min) runs out. Then the difference equals counted minus current, so the count does replace the balance. A count needs an org unit, a chair with a linked user and signers; STOREKEEPER holds `StockCountOrder` and `StockCountRecord` (`stock.ex`) | **Gap (process), decision** | Owner decision. Recommendation [A]: use the formal count with `freeze_locations` on for Client 1, and train it. If the owner wants the one-line count: **no task: propose a requirement** for a "single-line count" document. The weekly-file path of G9 is another one-line count source | count 2 (movements per kind: adjustment) |
| G6 | Append-only ledger, one reversal (§8.5) | DB triggers refuse UPDATE/DELETE/TRUNCATE. A mistake is reversed by a new movement, once; a reversal cannot be reversed | Same rules. Trigger `ledger_entry_guard_update` → `ledger_refuse()` (migration `20261031200001`). A reversal is a new posting; `posting_already_reversed` and `posting_is_reversal`, both 409 (`ledger.ex`, Reversal) | Fit | none | count 2 (reversals per month) |
| G7 | Idempotent posting (§8.6) | Same client UUID + same data = same result; different data = 409 | The ledger core has it: `idempotency_key_reuse`, 409 (`ledger.ex`). But the stock document routes make a **fresh server key per write** (`documents.ex`), so a phone that retries a create makes a second draft. Posting one document twice is refused (`document_posted`, `posting_pending`) | Partly | The Qoimeks APK has no offline queue [§1], so a retry is a rare user tap. **No task now [A]**; propose one only if the rehearsal or the first month shows double drafts | — |
| G8 | Excel "check, then load" (§8.7) | The preview changes nothing; apply needs the SHA-256 of the previewed file; «Записать остатки из файла» turns differences into count adjustments; an import can be cancelled; Cyrillic look-alikes and decimal commas are normalised | For the move: `dry_run=true` then `atomic=true` on masters and opening lines (`qoimeks-rehearsal.md`). The SHA binding, the "balances from the file as adjustments" and import cancel **do not exist**. The converter does the normalising once, at the move | Fit for the move; **Gap** for repeated use | See G9 | count 4 (imports per month, cancelled) |
| G9 | The bookkeepers' weekly workbook | The authority on balances [§2]; confirmed use is only 3 imports in total [§4] | Only the one-time opening-lines import for stock. No path to apply a later workbook as adjustments | **No**, if they still import | If count 4 or client question 3 shows repeated imports: **no task: propose a requirement** (apply a workbook as count differences, with preview). If not: none | count 4 |
| G10 | Reading stock (confirmed use) | Balances by SKU or by place on web; a balance hint on the phone | `GET /balances` and movements, with `format=xlsx` (`router.ex`, REQ-728); stock screens in web and mobile | Fit | none | count 10 (which clients read) |
| G11 | Stock export (§2a) | .xlsx in the import layout: Артикул, Номенклатура, Конечный остаток, Зона, Стеллаж, Полка, Второе место, Место, Ед. изм., «Коды / Codes» | The balances xlsx export has its own columns (`xlsx_export.ex`) | Partly | Use unknown [§1]. Ask client question 4. **No task now [A]**; propose one only if someone uses that layout | — |
| G12 | Codes and barcodes | Not used on production (QA only). `skus.barcode` may be filled from the «Штрихкод» column | `codes` module and scanning (count scan, `POST /counts/:id/scan`). `code_tag` and `code_assignment` have **no file import** (`pilot-rollout.md` rows 11–12). The converter does not carry codes | Partly | If count 6 shows filled barcodes: **no task: propose one** (a code-assignment import or a converter extension). Otherwise codes start empty and are assigned in Letflow | count 6 (barcodes) |
| G13 | **Old token must keep working** (§8.8) | One shared token, no accounts. "Old token must keep working (`ACCESS_TOKEN_TENANT`, decided 'indefinitely', portfolio-manager 2026-10-27); no setting change on phones" | **Not possible as built.** Letflow stock accepts only a signed-in person: "an API token or a scoped principal gets the same 404" (`stock/router.ex`, `stock/access.ex`). Letflow has no shared tenant token (search above). Letflow is also a different app and address, so phones change in any case | **No: conflict** | **Owner decision.** The 2026-10-27 rule was made for Client 1 staying on Qoimeks. Recommendation: at the move, every person (or every shared device) gets a Letflow account. The old token keeps working on Qoimeks during the read-only 30 days. A shared Letflow device login is a security and access change: no task, and it would need a decision record first | count 5 (how many operator names) |
| G14 | Operator name, roles | Free-text name; all users have full access (D-045 as quoted) [§3] | The signed-in user is recorded. Roles TENANT_ADMIN, STOREKEEPER, TENANT_AUDITOR (`pilot-rollout.md`, Onboarding 4). Interim sign-in path (a): accounts are made by hand (`pilot-first-month.md`) | Fit by a different design | Depends on G13. Each person needs an account and a sign-in. Production sign-in is not chosen (C11) | count 5 |
| G15 | Voice ru/kk (§8.2) | Articles spoken letter by letter with Russian letter names («а A, бэ B … зэт Z»); zone words слева/сол жақ, справа/оң жақ, прямо/тура; voice never posts by itself; ElevenLabs + xAI Grok | Built: ru and kk; m4a or WebM (`router.ex`, `voice_service.ex`); a draft the person confirms (`stock-voice.md`). **The letter-name table and the Qoimeks zone words are out of scope** (`voice_prompt.ex` moduledoc, owner questions 4 and 5). Provider keys are unset by default; providers and who pays are the owner's (`stock-voice.md`, Rules) | Partly | Use unknown [§1]. If count 3 or client question 2 shows voice use: **no task: propose a requirement** for the letter-name table and the zone words. Owner: provider keys and money | count 3 (voice vs keyboard) |
| G16 | Phones and iPhone web (§8.9, §8.11) | Android APK 0.1.2; iPhone uses `/web/` as a PWA; the voice encoder is picked at run time (Opus/WebM, AAC/M4A on Safari); the phone keeps address, token and name | Flutter `apps/mobile` and the PWA (`docs/mobile/pwa-parity.md`); ru/kk/en language switch remembered on the device (#4416). The voice route takes both m4a and WebM. **No Android release or distribution runbook** (search above). Android or PWA for Client 1 is open (owner-questions D8) | Partly | Owner decision D8. If Android: **no task: propose** an APK release and distribution requirement. The iPhone check is not done (client question 10) | count 10 (user-agent families) |
| G17 | Hosting notes (§8.9) | Cloudflare in front: scripted clients need their own User-Agent; web cached up to 4 h, entry file versioned `?v=` | Letflow production hosting is not chosen (C7, C8) | n/a yet | Hand to infra with C8. No product task | — |
| G18 | Movement history (600) | Kept in Qoimeks | The rehearsal moves opening balances only ("Deliberately not here: … movement history", `qoimeks-rehearsal.md`). No backdating (0079 D1) | **No, by design** | Recommendation R-1: history stays in Qoimeks (read-only), plus one archived export [A] | count 2 |
| G19 | Feedback | «Сообщить о проблеме», Markdown export; 0 rows at 2026-10-29 | No in-app feedback (search above); problems go to the operator (`pilot-rollout.md`, "Support") | No | Not needed for the first move [A]. Propose one only if count 9 shows real use | count 9 |
| G20 | Languages | ru, kk; Excel headers Russian | ru, kk, en in web and mobile (#4416) | Fit | none | — |
| G21 | Money and printing | none [§2, §7] | Stock lines have "no price or value" (`stock.ex`); Letflow's printed forms are not needed | Fit | none | — |
| G22 | **Four eyes on the stock opening** (added T-1945) | No approval step: one operator loads the stock | The stock opening has two steps: `submit` (done by the issuer) and `approve`, which must be done by a **different person** (`distinct_from`, `stock_opening` in `priv/modules/stock/generate_pack.exs`). It is the only four-eyes approval in the stock module; receipt, issue, write-off, transfer, handover, return, reversal and count posting are one step. **The switch to "two eyes" is not on main** (design `docs/design/four-eyes-switch.md`, slices 1 and 3) | Fit if Client 1 has two people who may post stock; **Gap** if one person does everything | Section 1.4. If count 5 shows one operator: build slices 1 and 3 of the design, then the tenant admin switches `stock_opening / approve` off. **No task: propose one per slice** | count 5 (how many operator names) |

The rules of a move (§8.10) shape section 2 and are not a fit/gap row.

### 1.3 What is still unknown

The inventory answers the facts that files can show. Two kinds of unknown are left. Neither needs new production access.

**A. Read-only production counts the PM already holds** (inventory §4, list 1–10; tenant schema only, numbers only). The note asks for nothing new. When the PM shares them, each one settles these rows:

| Count | What it counts | Settles |
|---|---|---|
| 1 | Rows per table; active vs inactive SKUs | size of the move, activity since 2026-10-29 |
| 2 | Movements per month and per kind; reversals per month | G5 (how often they count), G6, G18 (history value), real use beyond the 3 imports |
| 3 | Movements by source (keyboard / voice), with or without an import number | G15 voice, hand entry |
| 4 | Imports per month; cancelled imports | G8, G9 (weekly workbook) |
| 5 | Distinct operator names (count only) | G13, G14 (accounts needed) |
| 6 | SKUs per unit; SKUs with a barcode; SKUs with a second place | G2, G3, G12 |
| 7 | Places that break the zone + rack + shelf scheme (also `?`) | G3 |
| 8 | Balance rows negative; zero | G4, R-2 |
| 9 | Feedback rows by kind | G19 |
| 10 | User-Agent families and requests per day (from nginx logs) | G10, G16 (Android / web / iPhone) |

**B. Questions for the client** (inventory §9). The owner decides whether and when anyone asks; nothing here suggests asking now:
1. How many operators, bookkeepers and devices; does one person need to be told apart from another (accounts)? (G13, G14)
2. Is voice used at all, and in which language; would they miss it? (G15)
3. Daily entries, or mainly the weekly Excel import plus reading stock? (G9)
4. Is the stock export used, and by whom; any report or form made from it? (G11)
5. Does their workbook have a «Штрихкод» column; do they want barcodes or labels? (G12)
6. Is the zone + rack + shelf scheme the same everywhere, and will it change? (G3)
7. Units other than `шт`, decimals, or money in a future product? (G2, G21)
8. Is Client 1 a paying customer, and is a pause allowed for a later move? (owner item, C14)
9. Working hours, and who on their side checks after a change. (section 2.5)
10. Has the iPhone `/web/` test been done? (G16)
11. May their data stay in Germany (Hetzner) after a move? (owner item, C7; T-1569 §6)

Also unknown from the inventory: the activity since 2026-10-29 (count 1, 2), whether the LLM changed after 2026-10-08 [INV §5], and how many phones run the APK [INV §1].

### 1.4 The four-eyes rule: a second person approves the stock opening (added 2026-11-14, task T-1945)

Source: the PM relay of the owner decision of 2026-11-14, quoted in `docs/design/four-eyes-switch.md`, section 0 ("Qoimeks Client 1 may need it off"), and that design. **The switch is planned, not on main**; the permission name below is the design's working name.

- **The rule today.** A step may say that a different person must do it. In the stock module only one step does: the stock opening `approve` step, kept apart from `submit`, which the issuer completes at issue. So the person who issues the opening cannot approve it. In a company where one person does everything, the opening can never be posted.
- **Which approvals exist in the stock module.** Only that one (design, section 2 rows 3 and 14; section 6). Receipt, issue, write-off, transfer, handover, return, reversal and count posting are one step: one person posts. Count signatures and "only the chair" checks are not four-eyes and are not switched; a count can run with the chair alone, because the member list may be empty (design, section 6).
- **The switch.** Per company, per process and step; default ON (four eyes); no stored setting means ON (design, section 3.1). Only the company administrator switches it, through one new permission (working name `ApprovalRulesManage`, tenant scope, checked tenant-wide; held by TENANT_ADMIN through the tenant-scope rule; the design recommends that the platform admin is kept out by an explicit rule (O-2) and that the permission is not assignable in the role editor (O-3); design, section 1). A reason is asked for when switching off (owner question O-8 of the design).
- **The audit line.** Each time one person approves their own document, the audit log gets one entry `task.self_approved` with the note **"self-approved, four-eyes off"**, in the same transaction as the approval; the switch itself is logged as `approval_rule.changed` with who, when and the reason (design, section 3.3).
- **What Client 1 needs.** Only if count 5 shows one operator name (or only one person who may post stock): slices 1 (core) and 3 (stock opening) of the design built and merged, then the Client 1 administrator switches `stock_opening / approve` off before the opening lines are loaded. With two or more such people: nothing, the default stays.
- **Readiness check** (condition C17): in a QA rehearsal with one administrator, switch off, issue and approve one opening alone, and see exactly one "self-approved, four-eyes off" entry for it and one switch entry with the reason; switch back on and see the next self-approval refused.
- Open for the owner, from the design: whether a service user (API token) stays under four eyes when it is off (O-7), and the permission name and the platform admin exclusion (O-1, O-2). They do not block the decision for Client 1, only the build.

## 2. Data migration path and rehearsal plan

### 2.1 What moves, and in which file

| Data | Moves? | File (T-1616 converter output) | Letflow importer | Notes |
|---|---|---|---|---|
| Places (134) | yes | `01-locations-NN.xlsx`, ≤ 200 rows each (1 file) | `Locations.Import` | code kept as text (G3) |
| Units | yes | `02-uoms.xlsx` | `CatalogItems.Import` | probably one unit, `шт` (count 6) |
| Items (666) | yes | `03-items-NN.xlsx`, ≤ 200 rows each (4 files) | `CatalogItems.Import` | the second place is not carried (G3) |
| Opening balances (600 rows, positive ones only) | yes | `04-opening-lines-NN.xlsx`, ≤ 100 lines per opening document (6 files), plus `headers/QOI-HDR-NN.json` | `Stock.Documents.OpeningImport` | posted at posting time (0079 D1); needs G1 |
| Org unit, responsible employee | created by hand | `--org-unit-ext`, `--responsible-ext` | `org` module | "Qoimeks has no such notion" (`qoimeks-rehearsal.md`) |
| Barcodes | only if count 6 > 0 and G12 has a path | none yet | none (no file import) | G12 |
| Movement history (600) | **no** | none | none | G18, R-1 |
| Users | from a list the client gives, not from Qoimeks (it has none) | users xlsx (REQ-791, ≤ 200 rows) | Users import | G13, G14 |
| Feedback, provider keys, the shared token | no | none | none | not business data [A]; keys are set fresh by the owner |

Every import runs with `dry_run=true` first (the check-only run), then `atomic=true` (`qoimeks-rehearsal.md`, steps 3–5). All rows carry external ids under one `--system`.

### 2.2 Rules recommended for the move [A]

These are for the owner to confirm. They are not product rules.
- **R-1 Opening balance, not history.** Client 1 starts with one opening balance per item and place. The history stays in Qoimeks, read-only, with one archived movement export kept outside git. Reason: Letflow refuses backdated postings (0079 D1), and replaying 600 movements adds risk for little use.
- **R-2 Minus balances are fixed before the freeze.** The client counts each negative row (count 8) and fixes it in Qoimeks. A zero balance moves as no row. Reason: Letflow refuses a balance below zero, and the converter drops such rows, so the totals would not match.
- **R-3 After the move, an issue above the balance is refused.** Post the receipt first. This is a change of daily habit and goes into the training (G4).
- **R-4 Counts use the formal count with `freeze_locations` on** (D-094), so a count replaces the balance in the frozen places (G5).
- **R-5 Accounts, not the shared token** (G13), if the owner agrees. The old token keeps working on Qoimeks during the 30 read-only days.

### 2.3 Rehearsal plan

The inventory's move rules [INV §8.10] are kept:
- the move is a **copy** (the source is untouched);
- a **check-only run** comes first;
- **counts and current balances** must be equal;
- the write freeze is short;
- it happens **outside Client 1's working hours**;
- rollback is simple;
- the old copy is kept 30 days;
- "**no real data leaves production (D-050)**".

Because of D-050, the QA rehearsal does **not** use Client 1's real data [A]. It uses a test set of the same shape, built by the team from the inventory facts and the PM-held counts:
- 666 items with letter-and-digit articles, all `шт`, some with 3 decimals;
- 134 places in the `RI2` scheme plus one `?` place;
- 600 positive balances;
- a few negative and zero rows, to prove the drops;
- barcodes only if count 6 shows them.

The real extract is converted and loaded only at the move, onto the Letflow production tenant, with the check-only run first. Whether moving the extract from Qoimeks production to Letflow production fits D-050 is an owner item (C6).

| Step | What | Done when |
|---|---|---|
| RH-0 | Preconditions: G1 tasks merged and on QA; an empty QA tenant with `org`, `catalog_items`, `codes`, `locations`, `stock` (`pilot-rollout.md` order); org unit and responsible employee created | the tenant shows the modules active and no records |
| RH-1 | Build the same-shape test set as `locations.csv`, `items.csv`, `balances.csv`, outside the repository | three files; the row counts match the inventory |
| RH-2 | Convert (`qoimeks_convert.py convert`) | `report.txt` lists only the planned drops (negative, zero) |
| RH-3 | Check-only run: every import with `dry_run=true` | nothing refused |
| RH-4 | Load: masters, then headers, then lines, with `atomic=true` | nothing refused |
| RH-5 | Record-count check (`qoimeks_compare.sh`) | exit 0 |
| RH-6 | Post the opening documents (a person's task, `StockPost`) | every opening document posted |
| RH-7 | **Quantity check per item and place** (balances xlsx export against `balances.csv`), plus one hash of the sorted list (item, place, quantity) on both sides. This is the cross-system form of the Qoimeks "md5 per table" [A] | no difference. **No tool yet: propose a task** for a compare script next to `qoimeks_compare.sh` |
| RH-8 | Repeat RH-4 with the same files | every row `unchanged` (runbook, "Repeating") |
| RH-9 | Time RH-3 to RH-7 | the time is written down; it sizes the window |
| RH-10 | A count with `freeze_locations` on one place, and an issue above the balance | the count replaces the balance (R-4); the issue is refused (R-3) |
| RH-11 | A second rehearsal on a fresh tenant | the same result |

### 2.4 Reconciliation checks (all must pass, at rehearsal and at the move)

1. Record counts: places, units, items and opening lines equal `expected_counts.txt` (`qoimeks_compare.sh` exit 0).
2. Quantity per (item, place) equals the frozen Qoimeks balance. The R-2 drops are listed and agreed.
3. The hash of the sorted (item, place, quantity) list is equal on both sides [A].
4. Totals per item are equal. The client's bookkeeper confirms them against the weekly workbook (retirement criterion 10; `pilot-first-month.md` M1/M2).
5. Barcodes: the count per type is equal (only if G12 applies).
6. Spot check by the client: 20 items they choose, checked on the phone [A: number proposed, not sourced].

### 2.5 Cut-over window (proposal)

1. The Letflow tenant and accounts exist days before. Each person has signed in once (M5 of `pilot-first-month.md`).
2. Outside Client 1's working hours (client question 9), Qoimeks writes are frozen. Qoimeks has a `MAINTENANCE_MODE` that answers writes with 503 (`features-to-port.md` section 9); the Qoimeks team picks the switch. Their own tenant move needed "about 40 s" [INV §8.10]. The Letflow load is longer because of imports and posting tasks, and RH-9 gives the real time.
3. Extract a copy (the source stays untouched), convert, run the check-only run, load, post.
4. Run checks 1–6. If all pass, users switch to Letflow. If one fails and cannot be explained in the window, roll back.
5. The length of the window is RH-9 plus a margin. The owner sets it with the client.

### 2.6 Rollback, and what the client does in parallel

- **Rollback:** lift the Qoimeks freeze. The Qoimeks data was never changed (copy rule), and the phones still have the Qoimeks app, address and old token [INV §8.11]. So users go back with no setting change. Anything entered in Letflow after the switch is exported (stock movements xlsx) and typed into Qoimeks by hand. The Letflow tenant is kept for analysis and is not deleted without the owner.
- **Keep the Qoimeks app on the phones for the 30 days** [A], so a rollback needs no reinstall.
- **Point of no return** [A]: the first full business day on Letflow without rollback.
- **Parallel run:** Qoimeks stays read-only for 30 days (T-1569 step 6), for history lookups (R-1). One full weekly check against the bookkeepers' workbook follows (retirement criterion 10). The client does not post in both systems [A], because double entry makes the counts drift.
- **Who tells the users:** the owner or the PM, in ru and kk, a week before and on the day (T-1569 section 5). The team writes the text and contacts no one.

## 3. Readiness conditions, in order

Each one waits for the one before it, except where "parallel" is said.

| # | Condition | State today | Blocks on |
|---|---|---|---|
| C1 | The Qoimeks inventory is read (section 1.1) | **done**, 2026-11-13 | — |
| C2 | The PM shares the ten read-only counts (section 1.3 A) | the PM holds them | PM |
| C3 | Ledger slices L6 and L7 built and merged, with OQ-R4 first if needed (G1). Parallel with C2 | no task | team (tasks to propose); the owner's WMS order |
| C4 | Owner decisions: the old token vs accounts (G13, R-5); minus balances (G4, R-2/R-3); counts (G5, R-4); history (G18, R-1); Android or PWA (G16, D8) | open | owner, after C2 |
| C5 | Builds that C2 and C4 ask for: quantity compare tool (RH-7); and only if the counts show use, the second place (G3), barcode import (G12), weekly workbook (G9), letter names and zone words for voice (G15) | no tasks | team |
| C6 | **Production go**: owner approval (D-086; `pilot-rollout.md`, "Before the pilot starts" 1), including whether the real extract may go from Qoimeks production to Letflow production (D-050) | not approved | owner |
| C7 | **VPS**: option A chosen (T-1600 row a); the purchase waits for the PM's money step. Whether data may stay in Germany is open (client question 11) | prepared, not bought | owner, PM, infra |
| C8 | **DNS**: wildcard `*.letflow.ai-dala.com` accepted (T-1600 row b); the DNS-edit token model is still to agree. Cloudflare notes of G17 go to infra here | open | infra, owner |
| C9 | **Backups**: off-site copy wanted (T-1600 row f). Who holds the gpg private key, and `LETFLOW_SECRETS_MASTER_KEY` kept apart from the data (T-1600 sections 3, 4.6); a restore drill passed | open | owner, infra |
| C10 | **Monitoring**: alert log and runbooks for the AI on-call (T-1600 section 4) | not built | infra, team |
| C11 | **Sign-in**: the production sign-in path is chosen (owner-questions A7, A15, A18); an account for every Client 1 person; each seen signing in once (M5) | QA only | owner, infra |
| C12 | Voice keys and money, if voice is used (G15) | unset | owner |
| C13 | Two clean rehearsals on QA (section 2.3) | not started | C3, C5 |
| C14 | Phase F gate of the owner (`pilot-rollout.md`, "Before the pilot starts" 4); whether Client 1 pays and may pause (client question 8) | open | owner |
| C15 | Training in ru and kk (counts, no minus balance, sign-in) and the user notice a week before | open | owner, PM |
| C16 | Window agreed with the client, outside working hours (section 2.5) | open | owner, PM, client |
| C17 | **Four eyes** (G22, section 1.4): if Client 1 has only one person who may post stock, the switch (slices 1 and 3 of `docs/design/four-eyes-switch.md`) is built and merged, the Client 1 admin switches `stock_opening / approve` off with a reason, and the audit check of section 1.4 passes in a QA rehearsal. With two such people: nothing to do (default ON) | not built; need unknown until count 5 | team (tasks to propose), owner (open rows of the design) |

**Owner items that block the move** (from C4, C6, C7, C8, C9, C11, C12, C14, C15, C16):
- the old token vs accounts;
- minus balances;
- counts;
- history;
- Android or PWA;
- the production "go", including D-050 for the real extract;
- the VPS money and the Germany data location;
- the DNS token model;
- the backup key holder and the off-site target;
- production sign-in;
- voice keys;
- whether Client 1 pays;
- who trains;
- the window.

## 4. One table for the owner

| What | Ready? | What is missing | Who |
|---|---|---|---|
| What moves | Clear | Stock only. No assets, no money, no printing | — |
| Stock in Letflow for a real company | No | Two ledger parts (L6, L7) | Team |
| Old shared token | No | Letflow needs a login per person. Your choice | You |
| Minus balances | No | Your yes: fix them before the move | You |
| Count sets the balance | Other way | Your yes: formal count with places locked | You |
| Four eyes (a second person approves the opening) | Not built | Only if one person does everything: build the switch, then the company admin turns it off | Team; you (open design questions) |
| Old history | Plan | Your yes: keep it in Qoimeks, read-only | You |
| Items, places, balances | Half | Quantity check tool | Team |
| Barcodes, second place, voice words | Maybe | Only if the counts show they are used | PM (counts), team |
| Phone app | Half | Your choice: Android or web app | You |
| Voice | Built | Keys and money, if used | You |
| People sign in | QA only | Your choice for production | You, infra |
| Server | Chosen, not bought | Money step; may data stay in Germany? | You, PM |
| Domain name | Chosen | DNS token with infra | Infra |
| Backups | Planned | Who keeps the key; off-site place; one test restore | You, infra |
| Alerts | Not built | Alert list and runbooks | Infra, team |
| Does Client 1 pay? | Unknown | Your answer | You |
| Production "go" | No | Your yes | You |
| Practice move on QA | Not started | Needs the lines above | Team |
| Tell the users | Not started | Who and when | You, PM |

## Assumptions (all UAT assumptions, to be confirmed by the process owner)

- R-1 to R-5 in section 2.2.
- The QA rehearsal uses same-shape test data, not real data, because of D-050 as quoted by the inventory.
- The hash of the sorted (item, place, quantity) list as the cross-system form of "md5 per table".
- No task now for the stock export layout (G11), double drafts on retry (G7) and in-app feedback (G19), unless the counts show use.
- Keep the Qoimeks app on the phones for 30 days. The point of no return is the first full business day. No double entry. The 20-item spot check is a proposed number, not sourced.
