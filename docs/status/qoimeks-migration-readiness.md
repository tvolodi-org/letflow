# Qoimeks pilot client (Client 1): readiness to move onto Letflow

Readiness note, written by the business analyst on 2026-11-13 (task T-1907, owner statement D-143). Rewritten the same day from the Qoimeks inventory of Client 1. Updated 2026-11-16 (T-2025) with the PM plan and the final owner decision below. Production parts rewritten 2026-11-16 (T-2046, owner decision D-152, final). Host sign-in updated 2026-11-18 (T-1359): the owner selected the dedicated `ai-letflow.com` zone, with company URLs `<company>.ai-letflow.com`. Zone naming updated 2026-11-18 (T-2149, D-158): production zone is `ai-letflow.com`; first Qoimeks client slug `sss`, production URL `sss.ai-letflow.com` (a production tenant, not a QA tenant). DNS and certificate not yet configured (owner token O-016, infra). Four-eyes section updated 2026-11-20 (T-2388, owner decision D-164): the count rule for Client 1 is OFF; see section 1.4.

**Owner decision, 2026-11-16: stock-only scope stays; parity with Qoimeks is required** — "Do whatever needed to support old Qoimeks functionality, not less but possible more". Where Letflow rules conflict, the design says what changes and why. The earlier recommendations to drop Qoimeks behaviour are withdrawn. The parity tasks below are planned work, not built functionality; the migration has not been walked.

## Summary in plain words

- **The first move is stock only.** Client 1 uses Qoimeks for stock: an Excel import and reading the stock are confirmed. It has no assets, no money and no printing. So the move needs the stock module, codes, import, voice and an answer for the old shared token. Assets and fixed-asset counts are not part of this move.
- **Letflow is not ready to take Client 1 yet.** The biggest block is in the product. The stock module may not be switched on for a real company until two ledger parts (slices L6 and L7 of decision 0073) are built. Planned tasks: L6 T-2021, OQ-R4 T-2022, L7 T-2023 after T-2022. These ids do not mean the parts are built.
- **Three Qoimeks habits do not fit Letflow as it is:**
  - the shared token, which Letflow stock does not accept;
  - negative balances, which Letflow refuses;
  - a count that simply replaces a balance, where Letflow has a formal count process instead.
  The owner has decided parity; designs must resolve these conflicts (section 1.2, rows G4, G5, G13).
- **Production is not built.** It will run on the existing host next to QA (no new server, 0 new cost; D-152). The stack, DNS names, certificate, backups and off-site copies are planned, not built and not walked. Host-to-company sign-in configuration is implemented by T-1359 for `<company>.ai-letflow.com`, but its production DNS, Keycloak setup and real sign-in remain to be walked. The production go stays the owner's, announced before it runs.
- **The data is small:** 666 items, 134 places, 600 balances, 600 movements, 3 imports, 11 MB (all as of 2026-10-29). The converter and a count compare exist (T-1616). A quantity compare is still missing. The Qoimeks rule "no real data leaves production" changes how we rehearse (section 2.3).
- **Plan order:** build the ledger parts, quantity compare and parity gaps. Rehearse twice on QA with same-shape test data. Get the production "go", prepare production and train the client, then move outside Client 1's working hours. Qoimeks stays read-only for 30 days after the move. Section 2.7 gives phases P0–P9.

## Status and limits

- Docs only. This note creates no tenant, account, server or DNS name. It spends no money, touches no secret and contacts no one. It asks for no production access: the PM already holds the ten read-only production counts of the inventory (section 1.3). No question goes to the client (D-152): where a client answer would have been needed, this note writes the default the team takes.
- **Source of the task:** owner statement D-143 (PM, 2026-11-13), quoted from the task text: "the first production action is migrating the Qoimeks pilot client (Client 1) onto Letflow; it moves when the Letflow applications are ready (D-115)". The PM update of the same day sets the scope: "STOCK-ONLY pilot: assets and fixed asset count NOT needed for the first migration; needed: stock module, codes/barcodes, import, voice, a way to keep the old token working". The portfolio `DECISIONS.md` is not in this repository. Decisions named only by the inventory (D-042, D-045, D-050) are quoted from it.
- Production is **not approved** (`docs/runbooks/pilot-rollout.md`, "Status"; `docs/uat/ba-decisions/T-1600.md`, header). Every production step below is planned work; the go is the owner's and is announced before it runs.
- Marks used:
  - **[INV §n]** = fact from the Qoimeks inventory of Client 1, section n;
  - **[A]** = UAT assumption, to be confirmed by the process owner;
  - **[count n]** = confirmed by read-only production count n, which the PM holds (inventory §4, list 1–10).

## Sources opened

PM update: `ai-dala-portfolio/proposals/qoimeks-migration-plan.md`, read 2026-11-16 (sections 2 and 3, parity and phases); final owner decision and task ids from the T-2025 task text. The plan still contains earlier conditional wording; the final parity decision takes precedence (section 2.7).

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
- T-1616 tooling, with REQ-837 negative opening lines: `scripts/pilot/qoimeks_convert.py` (`MAX_ROWS = 200`, `MAX_LINES = 100`, drop reasons `quantity_comma_decimal`, `quantity_invalid`; zero rows are skipped as `quantity_zero`) and `scripts/pilot/qoimeks_compare.sh`.
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

Historical searches behind the original "not found" claims (2026-11-13, before the task ids below were assigned):
- `grep -rln ACCESS_TOKEN_TENANT lib docs web apps`: no hit. Letflow has no shared tenant token.
- `grep -rniE "second_place|second place|default_location|usual" priv/modules/catalog_items/ lib/letflow/modules/catalog_items/`: no hit. Letflow items have no "usual place" or "second place" field.
- GitHub search `repo:tvolodi-org/letflow is:open` for `L6`, `L7`, `negative balance`, `code_assignment import`, `Qoimeks` (first attempt of this task): no open issue.
- `grep -rli feedback apps/mobile/lib`: no hit. `grep -rn -i "apk\|play store\|signed release" docs/mobile/*.md docs/runbooks/*.md`: no hit (no Android release runbook).

## 1. Fit and gap

Qoimeks habits kept only if industry practice exists (owner 2026-11-16).

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

"Fit" means Letflow already covers it on main. "Gap" means something must be built or designed. "§8.n" is item n of the inventory's "Peculiarities a replacement must keep". The last column names the PM-held count that describes use; counts no longer decide whether parity is required. Assigned task ids are plans, not delivery evidence.

**Out of scope for this move** (PM update, 2026-11-13): assets, fixed-asset counts, asset printed forms and asset currency. They are not requirements here. Qoimeks has no asset concept [INV §4].

| # | Area | Client 1 in Qoimeks [INV] | Letflow on main | Fit? | Gap, and the task that closes it | Confirmed by |
|---|---|---|---|---|---|---|
| G1 | Stock module on a real company | n/a | Built: receipt, issue, write-off, transfer, opening, reversal, counts (`stock.ex`, `stock-counts.md`). **Blocked by the PILOT GATE of decision 0073:** not enabled for a customer tenant until L6 (posting scope) and L7 (master checks) are done. `Ledger.authorize/3` has no posting purpose; `stock/access.ex` says "not built (L6)". L7 depends on the OQ-R4 read facade (0073 D6) | **No** | L6 = **T-2021** (about M); OQ-R4 = **T-2022** (about L); L7 = **T-2023**, after T-2022 (about L). Requirement tasks will set the real sizes; update when known. This is the critical path, not built yet. | — |
| G2 | Items, unit, decimals | 666 SKUs, unit `шт`, quantities up to 3 decimals [§7] | `catalog_item`, `catalog_uom` with xlsx import. The ledger accepts up to 9 decimals (`validate.ex`, `quantity_scale`). The converter builds units from the distinct unit texts; it drops a decimal comma (`quantity_comma_decimal`), so the extract must use a dot | Fit | none | count 6 (units) |
| G3 | Place codes and the second place (§8.1) | Code = zone letter + rack letter + shelf number, e.g. `RI2`, name «Справа I 2». A SKU has a usual place and a **second place** in Qoimeks (Excel column G); Letflow keeps a **single usual place** per item (REQ-841/843, owner rewrite 2026-11-16) | `location_node` with a free-text code and an optional parent: the code scheme fits as text. **No item field for a usual place** (search above). The converter writes none | Fit for codes; **Gap** for the single usual place | **T-2026**: one usual place (`default_location_id`), including the converter path (home_loc only; the second place is reported, not imported; single place per REQ-841/843, owner rewrite 2026-11-16). Required for parity, regardless of counts. | counts 6, 7 |
| G4 | **Negative balances** (§8.3) | Allowed, with the warning «Остаток станет отрицательным» | **Refused by default; REQ-834 to REQ-836 add the per-tenant allow setting.** Without it, an issue below the balance is `insufficient_stock` (`stock.ex`; ledger code `insufficient_balance`, 409, `ledger/codes.ex`). The REQ-837 converter moves negative rows unchanged into all-negative opening files and skips zero rows as `quantity_zero` | **No: the rule differs** | **T-2027**: negative balances with the warning, decided in [decision 0090](../migration/decisions/0090-negative-balances-per-tenant.md) (per-tenant setting, default refuse; parts REQ-834 to REQ-840). Required for parity; the design must explain the change to the Letflow ledger rule and converter. R-2/R-3 are withdrawn. | count 8 (negative and zero rows) |
| G5 | **Counts that REPLACE the balance** (§8.4) | A count (`adjustment`) is one line that sets the balance to the counted number; qty 0 allowed only for a count | **No one-line "set balance".** Only the formal count order: order, open, count sheet, sign, differences, sign, post task (`stock-counts.md`). It posts the **difference** (counted minus book at the cut-off), not "counted = balance". In the default mode nothing stops movements during counting, so the balance ends at "balance now plus difference" ("Known gaps" 1 and 3). **D-094 freeze mode** (`freeze_locations`, REQ-765) refuses every posting in the frozen places with `409 location_frozen` until the count is posted, cancelled or the limit (default 120 min) runs out. Then the difference equals counted minus current, so the count does replace the balance. A count needs an org unit, a chair with a linked user and signers; STOREKEEPER holds `StockCountOrder` and `StockCountRecord` (`stock.ex`) | **Gap (process)** | **T-2028**: a one-line count that sets the balance. Required for parity; R-4 is withdrawn. The design must explain how this fits or changes the formal count rules. | count 2 (movements per kind: adjustment) |
| G6 | Append-only ledger, one reversal (§8.5) | DB triggers refuse UPDATE/DELETE/TRUNCATE. A mistake is reversed by a new movement, once; a reversal cannot be reversed | Same rules. Trigger `ledger_entry_guard_update` → `ledger_refuse()` (migration `20261031200001`). A reversal is a new posting; `posting_already_reversed` and `posting_is_reversal`, both 409 (`ledger.ex`, Reversal) | Fit | none | count 2 (reversals per month) |
| G7 | Idempotent posting (§8.6) | Same client UUID + same data = same result; different data = 409 | The ledger core has it: `idempotency_key_reuse`, 409 (`ledger.ex`). But the stock document routes make a **fresh server key per write** (`documents.ex`), so a phone that retries a create makes a second draft. Posting one document twice is refused (`document_posted`, `posting_pending`) | Partly | **T-2029**: retry by client id, with the same result for the same data and a conflict for changed data. Required for parity. | — |
| G8 | Excel "check, then load" (§8.7) | The preview changes nothing; apply needs the SHA-256 of the previewed file; «Записать остатки из файла» turns differences into count adjustments; an import can be cancelled; Cyrillic look-alikes and decimal commas are normalised | For the move: `dry_run=true` then `atomic=true` on masters and opening lines (`qoimeks-rehearsal.md`). The SHA binding, the "balances from the file as adjustments" and import cancel **do not exist**. The converter does the normalising once, at the move | Fit for the move; **Gap** for repeated use | **T-2030**: Excel check-then-load with SHA, balances from the file as adjustments, and import cancel. Required for parity; G9 follows this task. | count 4 (imports per month, cancelled) |
| G9 | The bookkeepers' weekly workbook | The authority on balances [§2]; confirmed use is only 3 imports in total [§4] | Only the one-time opening-lines import for stock. No path to apply a later workbook as adjustments | **No: parity gap** | **T-2031**, after G8 (**T-2030**): weekly workbook. Required for parity, regardless of counts. | count 4 |
| G10 | Reading stock (confirmed use) | Balances by SKU or by place on web; a balance hint on the phone | `GET /balances` and movements, with `format=xlsx` (`router.ex`, REQ-728); stock screens in web and mobile | Fit | none | count 10 (which clients read) |
| G11 | Stock export (§2a) | .xlsx in the import layout: Артикул, Номенклатура, Конечный остаток, Зона, Стеллаж, Полка, Второе место, Место, Ед. изм., «Коды / Codes» | The balances xlsx export has its own columns (`xlsx_export.ex`) | Partly | **T-2032**, after G3 (**T-2026**): export in the import layout. Required for parity. | — |
| G12 | Codes and barcodes | Not used on production (QA only). `skus.barcode` may be filled from the «Штрихкод» column | `codes` module and scanning (count scan, `POST /counts/:id/scan`). `code_tag` and `code_assignment` have **no file import** (`pilot-rollout.md` rows 11–12). The converter does not carry codes | Partly | **T-2033**: barcodes import. Required for parity, regardless of counts. | count 6 (barcodes) |
| G13 | **Old token must keep working** (§8.8) | One shared token, no accounts. "Old token must keep working (`ACCESS_TOKEN_TENANT`, decided 'indefinitely', portfolio-manager 2026-10-27); no setting change on phones" | **Not possible as built.** Letflow stock accepts only a signed-in person: "an API token or a scoped principal gets the same 404" (`stock/router.ex`, `stock/access.ex`). Letflow has no shared tenant token (search above). Letflow is also a different app and address, so phones change in any case | **Decision 0091** | **T-2034** (REQ-857..REQ-860): per-tenant stock-only token at `/qoimeks/:slug/…`, revocable by admin, no time limit, no Tokens screen (REQ-861 cancelled). Design: [decision 0091](../migration/decisions/0091-shared-stock-access.md). Personal accounts keep working unchanged. R-5 is withdrawn. | count 5 (how many operator names) |
| G14 | Operator name, roles | Free-text name; all users have full access (D-045 as quoted) [§3] | The signed-in user is recorded. Roles TENANT_ADMIN, STOREKEEPER, TENANT_AUDITOR (`pilot-rollout.md`, Onboarding 4). Interim sign-in path (a): accounts are made by hand (`pilot-first-month.md`) | Fit by a different design | Accounts remain available alongside the required old-token path (G13). Production sign-in per company is planned in C11; the token design must address operator identity | count 5 |
| G15 | Voice ru/kk (§8.2) | Articles spoken letter by letter with Russian letter names («а A, бэ B … зэт Z»); zone words слева/сол жақ, справа/оң жақ, прямо/тура; voice never posts by itself; ElevenLabs + xAI Grok | Built: ru and kk; m4a or WebM (`router.ex`, `voice_service.ex`); a draft the person confirms (`stock-voice.md`). **The letter-name table and the Qoimeks zone words are out of scope** (`voice_prompt.ex` moduledoc, owner questions 4 and 5). Provider keys are unset by default (`stock-voice.md`, Rules); the Qoimeks keys are reused (C12) | Partly | **T-2035**: voice letter names and zone words in ru and kk. Required for parity. Qoimeks provider keys are reused (C12); ElevenLabs speech needs a new client, part of T-2035. | count 3 (voice vs keyboard) |
| G16 | Phones and iPhone web (§8.9, §8.11) | Android APK 0.1.2; iPhone uses `/web/` as a PWA; the voice encoder is picked at run time (Opus/WebM, AAC/M4A on Safari); the phone keeps address, token and name | Flutter `apps/mobile` and the PWA (`docs/mobile/pwa-parity.md`); ru/kk/en language switch remembered on the device (#4416). The voice route takes both m4a and WebM. **No Android release or distribution runbook** (search above). The earlier Android-or-PWA question (owner-questions D8) is superseded by the parity decision; delivery is still missing | Partly | **T-2036**: Android and iPhone web parity. PWA-only advice is withdrawn; the iPhone walk is not done. | count 10 (user-agent families) |
| G17 | Hosting notes (§8.9) | Cloudflare in front: scripted clients need their own User-Agent; web cached up to 4 h, entry file versioned `?v=` | Letflow production uses the existing host (C7) and the dedicated `*.ai-letflow.com` company zone (C8), not built | n/a yet | Hand to infra with C8. No product task | — |
| G18 | Movement history (600) | Kept in Qoimeks | The rehearsal moves opening balances only ("Deliberately not here: … movement history", `qoimeks-rehearsal.md`). No backdating (0079 D1) | **No, by design** | **T-2037**: movement history. Required for parity; the design must explain the conflict with the opening-only path and no-backdating rule. R-1 is withdrawn. | count 2 |
| G19 | Feedback | «Сообщить о проблеме», Markdown export; 0 rows at 2026-10-29 | No in-app feedback (search above); problems go to the operator (`pilot-rollout.md`, "Support") | No | **T-2038**: feedback. Required for parity, regardless of counts. | count 9 |
| G20 | Languages | ru, kk; Excel headers Russian | ru, kk, en in web and mobile (#4416) | Fit | none | — |
| G21 | Money and printing | none [§2, §7] | Stock lines have "no price or value" (`stock.ex`); Letflow's printed forms are not needed | Fit | none | — |
| G22 | **Four eyes on the stock opening and the count** (added T-1945) | No approval step: one operator loads the stock | The stock opening has two steps: `submit` (done by the issuer) and `approve`, which must be done by a **different person** when the tenant's rule for that step is on (`distinct_from`, `stock_opening` in `priv/modules/stock/generate_pack.exs`); the rule is OFF by default in a new tenant (owner decision D-165, 2026-11-20). The quick count has the same shape (`stock_quick_count / approve`, REQ-854); receipt, issue, write-off, transfer, handover, return, reversal and count posting are one step. **The switch is built** (T-1986–T-1990 merged; QA rehearsal not walked) | Fit; one-person rehearsal not walked | Section 1.4 and C17: one-administrator rehearsal planned on a fresh QA tenant after infra provides it. | count 5 (how many operator names) |

The inventory move rules (§8.10) are assigned to **T-2039**; section 2 describes the existing path and rehearsal plan. The quantity compare script (RH-7) is **T-2024** (size S). Neither task is delivered by this note.

### 1.3 Production counts and defaults the team takes

The inventory answers the facts that files can show. **Nothing is asked of the client (D-152).**

**A. Read-only production counts the PM already holds** (inventory §4, list 1–10; tenant schema only, numbers only). The note asks for nothing new. Under the parity decision these counts do not gate any build task; if shared, they describe use and sizing:

| Count | What it counts | Settles |
|---|---|---|
| 1 | Rows per table; active vs inactive SKUs | size of the move, activity since 2026-10-29 |
| 2 | Movements per month and per kind; reversals per month | G5, G6, G18, real use beyond the 3 imports |
| 3 | Movements by source (keyboard / voice), with or without an import number | G15 voice, hand entry |
| 4 | Imports per month; cancelled imports | G8, G9 (weekly workbook) |
| 5 | Distinct operator names (count only) | G13, G14 (accounts needed) |
| 6 | SKUs per unit; SKUs with a barcode; SKUs with a second place (reported only, not imported) | G2, G3, G12 |
| 7 | Places that break the zone + rack + shelf scheme (also `?`) | G3 |
| 8 | Balance rows negative; zero | G4 |
| 9 | Feedback rows by kind | G19 |
| 10 | User-Agent families and requests per day (from nginx logs) | G10, G16 |

**B. Defaults the team takes** (replacing the earlier list of questions for the client). The team decides; the parity tasks T-2026..T-2039 carry the build. Source: the inventory (`Qoimeks-team/project/client1-inventory.md`, read only).

| Earlier question (topic) | Default taken | Where |
|---|---|---|
| Operators, devices, telling people apart | Personal accounts next to the old shared token, T-2034 | G13, G14 |
| Voice used, language | Voice ru and kk is built in full parity, T-2035 | G15 |
| Daily entries or weekly Excel | Both are supported: the weekly workbook path, T-2030, T-2031 | G8, G9 |
| Stock export used | Export in the import layout, T-2032 | G11 |
| Barcode column, labels | Barcodes import, T-2033 | G12 |
| Zone + rack + shelf scheme | Kept as text; single usual place (second place reported, not imported), T-2026 | G3 |
| Units, decimals, money | Unit `шт`, decimals up to the ledger limit, no money | G2, G21 |
| Client pays, pause allowed | Not a team question: the move waits for the parity tasks and rehearsals, not for a client answer | C14 |
| Working hours, who checks | The move runs outside the Qoimeks working hours the inventory shows; the checks of section 2.4 are done by the team and the operator | section 2.5 |
| iPhone `/web/` test | The team walks it (T-2036) | G16 |
| Data in Germany | The host is in Nuremberg; accepted by the owner on 2026-11-10 (`docs/uat/ba-decisions/T-1600.md`, row c) | C7 |

Also unknown from the inventory: the activity since 2026-10-29 (count 1, 2), whether the LLM changed after 2026-10-08 [INV §5], and how many phones run the APK [INV §1]. These size the work; they do not block it.

### 1.4 The four-eyes rule: a second person approves the stock opening and the count (added 2026-11-14, task T-1945; count rule decided 2026-11-20, task T-2388, owner decision D-164)

Source: the PM relay of the owner decision of 2026-11-14, quoted in `docs/design/four-eyes-switch.md`, section 0 ("Qoimeks Client 1 may need it off"), and that design. **The four-eyes slices T-1986–T-1990 are merged**; `ApprovalRulesManage` is the implemented permission. The QA rehearsal is planned on a fresh QA tenant after infra provides it. **Not walked; date not yet recorded.** Record the actual date here when walked.

- **The rule today.** A step may say that a different person must do it. Two steps in the stock module do: the stock opening `approve` step and the quick count `approve` step, each kept apart from `submit`, which the issuer completes at issue. The rule of a tenant created after owner decision D-165 (2026-11-20) is OFF: the person who issues the document may approve it, and a company that wants a second person switches the rule ON for that step, with a reason. A tenant created before that decision keeps the old default (ON), where the person who issues the document cannot approve it.
- **Which approvals exist in the stock module.** Two: the stock opening (`stock_opening / approve`) and the quick count (`stock_quick_count / approve`, REQ-854); the Excel load that creates a count goes through the same count approval (design, section 2 rows 3 and 14; section 6). Receipt, issue, write-off, transfer, handover, return, reversal and count posting are one step: one person posts. Count signatures and "only the chair" checks are not four-eyes and are not switched; a count can run with the chair alone, because the member list may be empty (design, section 6).
- **The switch.** Per company, per process and step; the default of a new tenant is OFF (four eyes off) and no stored setting means OFF there (owner decision D-165, 2026-11-20; design, section 3.6); in a tenant created before that decision no stored setting means ON (design, section 3.1). Only the company administrator switches it, through one new permission (`ApprovalRulesManage`, tenant scope, checked tenant-wide; held by TENANT_ADMIN through the tenant-scope rule; the implementation keeps the platform admin out by an explicit rule and the permission is not assignable in the role editor; the design records these as O-2 and O-3; design, section 1). A reason is required when switching (the design records this as O-8).
- **The audit line.** Each time one person approves their own document, the audit log gets one entry `task.self_approved` with the note **"self-approved, four-eyes off"**, in the same transaction as the approval; the switch itself is logged as `approval_rule.changed` with who, when and the reason (design, section 3.3).
- **What Client 1 needs (decided 2026-11-20, owner decision D-164).** The count rule `stock_quick_count / approve` is **OFF** for Client 1: the storekeeper counts from the phone at the warehouse and the company has one administrator, so the count posts at once. The administrator switches that one rule off, before the first count, in the browser on Admin > Approval rules (the route takes only a person signed in interactively, not an API token), with the reason "Client 1, storekeeper counts from the phone, one administrator, owner decision D-164"; the switch is audited as `approval_rule.changed` and every count the same person approves is audited as "self-approved, four-eyes off". The **opening** rule `stock_opening / approve` is a separate choice: it is OFF by default in a new tenant (D-165), so with one administrator nothing is needed, and a company that wants a second person either gets a second administrator who approves the opening or switches the opening rule ON with its own reason. The procedure (route, reason text, audit entries, readiness check) is in `docs/runbooks/production-tenant-onboarding.md`, step 20.
- **Readiness check** (condition C17): in a QA rehearsal with one administrator, issue an opening, switch off and approve it alone, and see exactly one "self-approved, four-eyes off" entry for it and one switch entry with the reason; switch back on and see the next self-approval refused. For the count rule the same rehearsal reads the `four-eyes` line of the onboarding readiness report (an INFO line, not a gate).
- Open for the owner, from the design: whether a service user (API token) stays under four eyes when it is off (O-7), and the permission name and the platform admin exclusion (O-1, O-2). These remain owner questions in the design; the implemented defaults use `ApprovalRulesManage`, exclude the platform admin, and keep API tokens under four eyes.

## 2. Data migration path and rehearsal plan

### 2.1 What moves, and in which file

This is the **existing T-1616 converter path**, not a complete parity migration. It still drops non-positive balances and omits the usual place and history (the second place is reported, not imported: single place per REQ-841/843). T-2026, T-2027, T-2033, T-2034, T-2037, T-2038 and T-2039 must settle the missing paths before rehearsal; no completed migration is claimed.

| Data | Moves? | File (T-1616 converter output) | Letflow importer | Notes |
|---|---|---|---|---|
| Places (134) | yes | `01-locations-NN.xlsx`, ≤ 200 rows each (1 file) | `Locations.Import` | code kept as text (G3) |
| Units | yes | `02-uoms.xlsx` | `CatalogItems.Import` | probably one unit, `шт` (count 6) |
| Items (666) | yes | `03-items-NN.xlsx`, ≤ 200 rows each (4 files) | `CatalogItems.Import` | the usual place is not carried yet (G3); the second place is never imported (single place per REQ-841/843) |
| Opening balances (600 rows, positive ones only) | yes | `04-opening-lines-NN.xlsx`, ≤ 100 lines per opening document (6 files), plus `headers/QOI-HDR-NN.json` | `Stock.Documents.OpeningImport` | posted at posting time (0079 D1); needs G1 |
| Org unit, responsible employee | created by hand | `--org-unit-ext`, `--responsible-ext` | `org` module | "Qoimeks has no such notion" (`qoimeks-rehearsal.md`) |
| Barcodes | required for parity; path in design | none yet | none (no file import) | G12, T-2033 |
| Movement history (600) | required for parity; path in design | none yet | none in the existing rehearsal | G18, T-2037; R-1 withdrawn |
| Users | from a list the client gives, not from Qoimeks (it has none) | users xlsx (REQ-791, ≤ 200 rows) | Users import | G13, G14 |
| Feedback, shared token | required for parity; paths in design | none yet | none in the existing rehearsal | G19 T-2038; G13 T-2034 |
| Provider keys | the Qoimeks keys are reused as they are (C12), piped by infra, never printed | none | none | secrets are not migration files |

Every import runs with `dry_run=true` first (the check-only run), then `atomic=true` (`qoimeks-rehearsal.md`, steps 3–5). All rows carry external ids under one `--system`.

### 2.2 Earlier move rules — withdrawn

**R-1–R-5: withdrawn 2026-11-16 by owner decision, replaced by the parity tasks.** These are retained only as a record of the earlier advice, not instructions for rehearsal or cut-over.

| Rule | Earlier advice (withdrawn) | Replacement |
|---|---|---|
| R-1 | Opening balance only; history stays in Qoimeks plus an archived export | G18, T-2037: movement history parity |
| R-2 | Client fixes minus balances before the freeze; zero rows do not move | G4, T-2027: negative balances with the warning; migration handling in design |
| R-3 | Refuse an issue above the balance; train receipt first, then issue | G4, T-2027: negative balances with the warning |
| R-4 | Formal count with freeze instead of a one-line count | G5, T-2028: one-line count that sets the balance |
| R-5 | Accounts only; old token only on Qoimeks for 30 read-only days | G13, T-2034: old shared token next to personal accounts |

### 2.2a PM recommendations (2026-11-16) — withdrawn by the final owner decision

The earlier advice (accounts only, fix/refuse minus balances and train receipt first, formal count with freeze, history only in read-only Qoimeks plus an archive, PWA first and Android only if asked) is withdrawn. It is **not** treated as decided before rehearsal 1. Stock-only parity is required instead; G13, G4, G5, G18 and G16 name the replacement tasks. Four eyes remains a per-company switch.

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

The existing rehearsal below must be updated by the parity designs and T-2039 before it is walked; the old drop/refusal checks are not parity acceptance. Because of D-050, the QA rehearsal does **not** use Client 1's real data [A]. It uses a test set of the same shape, built by the team from the inventory facts and the PM-held counts:
- 666 items with letter-and-digit articles, all `шт`, some with 3 decimals;
- 134 places in the `RI2` scheme plus one `?` place;
- 600 positive balances;
- a few negative and zero rows, to verify the parity handling designed by T-2027;
- barcodes to verify G12 parity (T-2033), regardless of counts.

The real extract is converted and loaded only at the move, onto the Letflow production tenant, with the check-only run first. That one step is covered by the production go (C6), which the owner announces before it runs.

What the engine's QA runs have and have not shown so far (dates, build shas, durations, the six checks as "not run", the tasks still waiting): `docs/status/qoimeks-rehearsal-record.md`.

| Step | What | Done when |
|---|---|---|
| RH-0 | Preconditions: G1 tasks merged and on QA; an empty QA tenant with `org`, `catalog_items`, `codes`, `locations`, `stock` (`pilot-rollout.md` order); org unit and responsible employee created | the tenant shows the modules active and no records |
| RH-1 | Build the same-shape test set as `locations.csv`, `items.csv`, `balances.csv`, outside the repository | three files; the row counts match the inventory |
| RH-2 | Convert (`qoimeks_convert.py convert`) | `report.txt` is checked against T-2027 parity handling; the old negative/zero drops are not accepted as parity |
| RH-3 | Check-only run: every import with `dry_run=true` | nothing refused |
| RH-4 | Load: masters, then headers, then lines, with `atomic=true` | nothing refused |
| RH-5 | Record-count check (`qoimeks_compare.sh`) | exit 0 |
| RH-6 | Post the opening documents (a person's task, `StockPost`) | every opening document posted |
| RH-7 | **Quantity check per item and place** (balances xlsx export against `balances.csv`), plus one hash of the sorted list (item, place, quantity) on both sides. This is the cross-system form of the Qoimeks "md5 per table" [A] | no difference. **T-2024 (size S)**: quantity compare tool next to `qoimeks_compare.sh`; planned, not built |
| RH-8 | Repeat RH-4 with the same files | every row `unchanged` (runbook, "Repeating") |
| RH-9 | Time RH-3 to RH-7 | the time is written down; it sizes the window |
| RH-10 | A formal count with `freeze_locations` on one place, plus the parity count and an issue above the balance | formal freeze check passes; one-line count and negative-balance warning match T-2028 and T-2027 designs; withdrawn R-3/R-4 are not acceptance rules |
| RH-11 | A second rehearsal on a fresh tenant | the same result |

### 2.4 Reconciliation checks (all must pass, at rehearsal and at the move)

Fresh-tenant activation check (T-2253): before any administrator activates a process, post a receipt
and an issue through the shared stock token and a receipt as STOREKEEPER. Check created documents,
posted movements and one `definition.activate` audit entry per first activation; a second use adds no
activation entry. A tenant-created process version must stay untouched and be refused. The product
onboarding check must report all ten stock processes as `active` or `draft auto-activation`.
Automated regression coverage exists; this fresh-tenant QA walk remains **not ready until walked**.


1. Record counts: places, units, items and opening lines equal `expected_counts.txt` (`qoimeks_compare.sh` exit 0).
2. Quantity per (item, place) equals the frozen Qoimeks balance. Negative and zero rows follow the T-2027 design; withdrawn R-2 is not permission to drop them.
3. The hash of the sorted (item, place, quantity) list is equal on both sides [A].
4. Totals per item are equal. The client's bookkeeper confirms them against the weekly workbook (retirement criterion 10; `pilot-first-month.md` M1/M2).
5. Barcodes: the count per type is equal (G12 parity, T-2033).
6. Spot check by the client: 20 items they choose, checked on the phone [A: number proposed, not sourced].

### 2.5 Cut-over window (proposal)

1. The Letflow tenant and accounts exist days before. Each account user has signed in once (M5 of `pilot-first-month.md`); the old shared-token path must also be verified under G13's design, not replaced by an accounts-only rule.
2. Outside Client 1's working hours (the team's default, section 1.3 B), Qoimeks writes are frozen. Qoimeks has a `MAINTENANCE_MODE` that answers writes with 503 (`features-to-port.md` section 9); the Qoimeks team picks the switch. Their own tenant move needed "about 40 s" [INV §8.10]. The Letflow load is longer because of imports and posting tasks, and RH-9 gives the real time.
3. Extract a copy (the source stays untouched), convert, run the check-only run, load, post.
4. Run checks 1–6. If all pass, users switch to Letflow. If one fails and cannot be explained in the window, roll back.
5. The length of the window is RH-9 plus a margin. The team sets it; no one asks the client.

### 2.6 Rollback, and what the client does in parallel

- **Rollback:** lift the Qoimeks freeze. The Qoimeks data was never changed (copy rule), and the phones still have the Qoimeks app, address and old token [INV §8.11]. So users go back with no setting change. Anything entered in Letflow after the switch is exported (stock movements xlsx) and typed into Qoimeks by hand. The Letflow tenant is kept for analysis and is not deleted without the owner.
- **Keep the Qoimeks app on the phones for the 30 days** [A], so a rollback needs no reinstall.
- **Point of no return** [A]: the first full business day on Letflow without rollback.
- **Parallel run:** Qoimeks stays read-only for 30 days (T-1569 step 6), for fallback lookups; this does not replace movement history parity (G18, T-2037). One full weekly check against the bookkeepers' workbook follows (retirement criterion 10). The client does not post in both systems [A], because double entry makes the counts drift.
- **Who tells the users:** a notice in ru and kk, a week before and on the day. The team writes the text; it contacts no one itself.

### 2.7 PM phase order P0–P9 (2026-11-16)

Copied from the PM plan, section 3. **The final parity decision overrides P1's older "extras only if P0" wording:** the single usual place (not a second one, REQ-841/843), barcodes, weekly workbook and voice letter words are required, not conditional. P0 is dropped; its "everything is built" means everything must be built, not that it is delivered. P3's formal count with freeze remains a rehearsal check, not a substitute for one-line count parity. P5 sign-in per company follows from the production Keycloak plan (C11); T-1359 (F1b) delivers hostname-to-tenant login configuration, while production setup and the sign-in walk remain open. No phase is marked walked here.

| # | Phase | Who | Done when |
|---|---|---|---|
| P0 | (dropped, owner 2026-11-16) production counts: not needed, parity means everything is built | - | - |
| P1 | Product gaps: ledger slices L6 and L7 (the stock module is not allowed for a real company until both are done); quantity compare script; extras only if P0 says they are used (usual place, barcodes, weekly workbook, voice letter words; single place per REQ-841/843) | Letflow team | merged, on QA |
| P2 | Rehearsal 1 on QA with a test set of the same shape (no real data leaves production, D-050) | operator | all 6 reconciliation checks pass; time written down |
| P3 | Rehearsal 2 on a fresh QA tenant, with four-eyes off and a count with freeze | operator | same result |
| P4 | (no owner decision left here except the production go, C6; no money, D-152) | - | - |
| P5 | Production set-up on the existing bizdala.com host: separate stack, DNS and certificate, backups with a restore test, alerts, sign-in per company | infra, operator | restore drill passed |
| P6 | Client side: the team sets the window, writes the users list default and the ru and kk training and notice texts; no questions to the client | team | texts ready, window set |
| P7 | Move, outside the client's working hours: freeze Qoimeks writes, copy, check-only run, load, post, six checks, users switch | operator, infra, client | all checks pass, else roll back |
| P8 | 30 days parallel: Qoimeks read-only, no double entry; weekly check against the bookkeeper workbook | operator | first full business day without rollback = point of no return |
| P9 | Retire Qoimeks for Client 1 (retirement criteria) | owner | after the 30 days |

## 3. Readiness conditions, in order

Read these conditions alongside the phase order in section 2.7. Parity is decided; the earlier counts-first and conditional-build order is superseded.

| # | Condition | State today | Blocks on |
|---|---|---|---|
| C1 | The Qoimeks inventory is read (section 1.1) | **done**, 2026-11-13 | — |
| C2 | Read-only counts (section 1.3 A), formerly P0 | P0 dropped by owner 2026-11-16; PM-held counts may inform sizing, not scope | not a parity prerequisite |
| C3 | Ledger slices L6 and L7 built and merged, with OQ-R4 before L7 (G1) | L6 = T-2021 (about M); OQ-R4 = T-2022 (about L); L7 = T-2023 after T-2022 (about L). Requirement tasks set real sizes; update when known. Planned, not built | team; the owner's WMS order |
| C4 | Owner decisions on Qoimeks functionality | **decided by the owner 2026-11-16: parity** | designs explain changes where Letflow rules conflict |
| C5 | Quantity compare tool (RH-7) and all parity gaps in section 1.2, including inventory §8.10 move rules | quantity compare tool (RH-7) = T-2024 (size S); T-2026–T-2039 assigned to parity gaps, not built. The earlier PM hold on the usual place, barcodes, weekly workbook and voice letter words pending P0 counts is superseded by parity | team |
| C6 | **Production go**: the owner's go, **announced before it runs and never self-started** (D-152). It is the only item left for the owner in the production section | not given | owner |
| C7 | **Server**: the existing host `ubuntu-16gb-nbg1-1` next to QA, no new VPS, 0 new cost (D-152). Separate compose project, own Postgres and Keycloak, own systemd slice with a 3.84 GiB ceiling, loopback ports; QA is killed first under memory pressure. A pending reboot (uptime 141 days) would stop QA, demo and production together and is scheduled, not left to chance | planned, not built | infra, operator |
| C8 | **DNS**: the dedicated `ai-letflow.com` zone, `ai-letflow.com` and `*.ai-letflow.com` for company URLs (`<company>.ai-letflow.com`), `auth.ai-letflow.com` for Keycloak, `pwa.ai-letflow.com` for the PWA host. First Qoimeks client URL: `sss.ai-letflow.com`. Cloudflare notes of G17 go to infra here. No DNS or certificate work is performed by T-1359; not yet configured (owner token O-016, infra) | planned, not built | infra |
| C9 | **Backups**: dumps twice a day on the host, no WAL (D-116). The QA-host copy is the same machine and is **not** off-site. Real off-site: the agent host (pull twice a day) and the owner's PC (weekly push over the tunnel, best effort). The gpg key pair is made on the agent host; `LETFLOW_SECRETS_MASTER_KEY` stays apart from the data and from the gpg key. Key creation, the pull drill and the stage-1 dry run are announced before they run. A restore drill must pass | planned, not built | infra, operator |
| C10 | **Monitoring**: alert log and runbooks (T-1600 section 4); preparation only, no on-call for non-paying clients (D-116); alert when a backup status is red or older than 30 h, disk at 75% and 85%, reboot pending more than 7 days. Production mail (T-0245) is missing | not built | infra, team |
| C11 | Production sign-in per company follows from C7 to C8: a separate production Keycloak, one realm per company, the company found by its hostname `<company>.ai-letflow.com` (first Qoimeks client: `sss.ai-letflow.com`, a production tenant, not a QA tenant). T-1359 (F1b) implements the public hostname-to-tenant realm and branding lookup, with security review before it ships; personal accounts and old-token parity (G13); each account user seen signing in once (M5) | code delivered; production setup and UAT not walked | infra, team; T-1359, T-2034 design |
| C12 | Voice keys: the Qoimeks provider keys are **reused as they are** (D-152); infra pipes them host to host into a mode-600 file on the production host; a key is never printed. Env names: `LETFLOW_VOICE_STT_PROVIDER`/`_MODEL`/`_BASE_URL`/`_API_KEY` and `LETFLOW_VOICE_LLM_PROVIDER`/`_MODEL`/`_BASE_URL`/`_API_KEY` (`docs/runbooks/stock-voice.md`). **Build item T-2035:** Letflow knows only the provider kinds `openai_transcriptions` and `openai_chat`. Qoimeks uses xAI Grok (OpenAI-compatible chat: its key and base URL fit `openai_chat`) and ElevenLabs speech, which is not the OpenAI transcription API, so reusing that key needs a new client. Not built. Keys are shared with Qoimeks: one quota, one bill | not built | infra (keys), team (T-2035) |
| C13 | Two clean rehearsals on QA (section 2.3) | not started | C3, C5 |
| C14 | Phase F gate (`pilot-rollout.md`, "Before the pilot starts" 4): the manual gate after the parity rehearsals. Whether Client 1 pays is not a condition of the move | not reached | team, owner (go only, C6) |
| C15 | Training texts in ru and kk (parity counts, minus warning, token/accounts and sign-in) and user notice a week before | not written; follows parity designs | team |
| C16 | Window set by the team, outside the Qoimeks working hours (section 2.5); no one asks the client | not set | team |
| C17 | **Four eyes** (G22, section 1.4): one administrator issues an opening, switches stock_opening / approve off with a reason, approves alone; exactly one self-approved entry and one switch entry in the audit; switch back on and verify refusal | **T-1986–T-1990 merged**; rehearsal planned on a fresh QA tenant after infra provides it. **Not walked; date to be recorded when walked** | infra (fresh QA tenant), operator (rehearsal); owner (open design rows) |

**What really remains for the owner:** only the **production go, announced before it runs** (C6). Everything else in this section is team, infra or operator work, none of it built or walked yet.

## 4. One table for the owner

| What | Ready? | What is missing | Who |
|---|---|---|---|
| What moves | Clear | Stock only. No assets, no money, no printing | — |
| Stock in Letflow for a real company | No | Two ledger parts (L6, L7) | Team |
| Old shared token | In design | Parity required: old token next to accounts, T-2034 | Team |
| Minus balances | In design | Parity with warning, T-2027; no mandatory pre-move fix rule | Team |
| Count sets the balance | In design | One-line count parity, T-2028 | Team |
| Four eyes (a second person approves the opening) | Merged, not walked | T-1986–T-1990 merged; C17 rehearsal after infra provides a fresh QA tenant; date not yet recorded | Infra, operator; you (open design questions) |
| Old history | In design | Movement history parity, T-2037 | Team |
| Items, places, balances | Half | Quantity check tool RH-7, T-2024 (S); other parity gaps in section 1.2 | Team |
| Barcodes, single usual place (REQ-841/843), voice words | Planned | Required for parity: T-2033, T-2026, T-2035 | Team |
| Phone app | In design | Android and iPhone web parity, T-2036 | Team |
| Voice | Built for OpenAI-style providers | Qoimeks keys reused; ElevenLabs speech needs a new client, T-2035; not built | Team, infra |
| People sign in | Host lookup coded; production not walked | Production Keycloak per company (C11); T-1359 delivers host-to-company realm and branding selection; DNS, realm setup and each user's sign-in remain | Infra, team |
| Server | Chosen: the existing host, 0 new cost | Not built; reboot pending on the host | Infra |
| Domain name | Chosen: `*.ai-letflow.com` | Dedicated zone and certificate; not built (owner token O-016, infra) | Infra |
| Backups | Planned | Off-site: agent host and your PC (the QA-host copy is not off-site); keys apart; one test restore; not built | Infra, operator |
| Alerts | Not built | Alert list and runbooks | Infra, team |
| Production "go" | No | Your yes, announced before it runs; the only item left for you | You |
| Practice move on QA | Not started | Needs the lines above | Team |
| Tell the users | Not started | The team writes the ru and kk notice | Team |

## Assumptions (all UAT assumptions, to be confirmed by the process owner)

- R-1 to R-5 are withdrawn, not live assumptions (section 2.2). Parity is decided; the assigned tasks still need delivery and rehearsal.
- The QA rehearsal uses same-shape test data, not real data, because of D-050 as quoted by the inventory.
- The hash of the sorted (item, place, quantity) list as the cross-system form of "md5 per table".
- Stock export layout (G11, T-2032), retries (G7, T-2029) and feedback (G19, T-2038) are required parity work; the earlier conditional assumption is withdrawn.
- Keep the Qoimeks app on the phones for 30 days. The point of no return is the first full business day. No double entry. The 20-item spot check is a proposed number, not sourced.
