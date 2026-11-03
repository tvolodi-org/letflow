# 0079 -- Assets B5: counts (inventory taking): count order, commission, count sheet, differences sheet posted as ledger entries, signatures, low-value items by quantity

Status: PROPOSED by task T-1202 for REQ-680 / GH #3674, 2026-11-04. Not binding until REVIEWER or owner sign-off. Decision number check at implement time: 0077 is the highest on `origin/main`; 0078 is taken by the open branch of item B2 (operations accounting, time and integrity), so 0079 is used. Re-check the number at merge time; if the file name is taken, renumber.

Date: 2026-11-04

Related: REQ-680 (GH #3674), REQ-616, REQ-620, REQ-621, REQ-676, REQ-642, REQ-643, REQ-644, REQ-645, REQ-646, REQ-647, REQ-648, REQ-649; decisions 0056, 0073 (as amended by REQ-676), 0075, 0076; WM-12 and WM-13 of `docs/WMS/WMS_Procurement_Requirements_Draft.md`; items B2 (balance as of a date, audit trail), B4 (stock workflows) and B6 (scoped read of balances).

This record writes no code, migration, route, permission, seed, screen or test. It is a specification (D-073): the implementing requirements are written after GATE A from the split plan in section 13.

## Sources

- Owner decisions D-061, D-062, D-065, D-066, D-067 and D-073, `ai-dala-portfolio/DECISIONS.md`. D-062: count paperwork (order, commission, count sheet, differences sheet, signatures) is part of the first version; signed documents are fixed. D-065: an Inventory Object is its own record with its codes; the responsible person holds an employee id. D-066: storage of trees and master data. D-067: documents and balances are scoped by org unit; codes are visible tenant-wide and a scan still checks the target's scope. D-073: phase B specifications come before GATE A, no implementation.
- `ai-dala-portfolio/architectures/assets.md` (workflows, the gray zone, decisions of 2026-10-31, review findings 3 and 5, phase B row) and `letflow-team/project/assets-gap-analysis.md` (sections 3 and 6).
- WM-12 (a variance cannot change book stock before an authorized posting; an adjustment has a reason and a task reference) and WM-13 (no double counting and no unrecorded movement inside the count scope).
- Decision 0056 (versioned documents; D6 signatures is DIRECTION only), 0073 (domain-neutral ledger, D-C, D-T, D-L5, D-L12, D8 as replaced by A2 and A3), 0075 (signatures are not there), 0076 (master data layer, R6, R7).
- Requirement REQ-680 in `docs/requirements.yaml`.

## Assumptions of the owner (D-086, D-087, 2026-11-04)

Each is marked here and in the sections that use it. "Assumption, owner may change at GATE B":

- Volumes are those of the speed test of decision 0073 A7 to A9 (stock register 3,000,000 entries and 1,000,000 balance rows; asset register 100,000 entries and 50,000 balance rows; reads at p95 under 500 ms with 100 concurrent readers). 0073 A9 numbers win where it names them. This record adds no number of its own.
- The default tenant time zone is Asia/Almaty (UTC+5). Assumption, owner may change at GATE B.
- "Signed" means a paper signature on the printout of the document. Assumption, owner may change at GATE B. Consequence in section 9.
- The audit trail is scoped by org unit like the other scoped types (D-067). Assumption, owner may change at GATE B.
- Count paperwork in phase B is xlsx with signer lines; printed forms come in phase E. Assumption, owner may change at GATE B.
- Scoped posting (slice L6) is not part of phase B. Assumption, owner may change at GATE B.

## Problem

Decision 0073 lists "counts and variance" as out of scope. The only text on counts is WM-12 and WM-13. Signatures of documents are direction only (0056 D6; 0075 excludes them). The owner put count paperwork into the first version, and counts with typed or keyboard-scanner input on the web into phase B. Without a record, each implementing requirement would invent the count states, the freeze rule, the cause names and the signer list.

## 1. Place and shape

One record, this file. Four documents, each a versioned document issued through `Letflow.Documents.issue/2` (`lib/letflow/documents.ex`) with its own document type key (names are proposals, final names in the implementing requirement):

| Document | Type key | Content |
|---|---|---|
| Count order | `count.order` | org unit, location subtree or subtrees, count kind `full` or `selective`, planned start, the commission |
| Count sheet | `count.sheet` | the lines of section 5 with book quantity (frozen at the cut-off), counted quantity, unit |
| Differences sheet | `count.differences` | every line whose counted quantity differs from the book quantity, as a surplus or a shortage |
| Posting record | `count.posting` | the ledger entry ids and the posting time of the differences, for the audit |

Every issued version is immutable (0056 D4, a database trigger). A correction before posting is a new version of the document (0056 D4 supersedes the previous one); after posting it is a reversal (section 8). An issued document is never changed.

## 2. States of a count

A count is the chain of the four documents. Its state is the state of the furthest document.

| State | Who moves it to the next state | Document issued or signed | Read-only after |
|---|---|---|---|
| `draft` (order being written) | the clerk who creates the order | order issued | the order: its org unit, scope, kind, start, commission |
| `ordered` | the chair opens the count at the planned start (cut-off time taken from the server clock, section 4) | none; the freeze starts | the scope and the book quantities |
| `counting` | the commission records lines (section 5); the chair closes counting | count sheet issued, then signed (section 9) | the sheet |
| `counted` | the system builds the differences from the signed sheet; the chair issues them | differences sheet issued | the differences |
| `signed` | each required signer (section 9) | differences sheet signed | everything above |
| `posted` | a human posts in a user task (section 8) | posting record issued | everything; the freeze ends |
| `cancelled` | the chair, in `draft`, `ordered`, `counting` or `counted`; refused from `signed` on | none | everything; the freeze ends |

Cancel is allowed only before the differences sheet is signed. After `signed`, the only ways forward are to post, or to leave the signed sheet standing (a signed document is fixed, D-062) and order a new count. After `posted`, the only correction is one reversal of all its entries (section 8). Assumption, owner may change at GATE B: the paper signature (see Assumptions) is confirmed in Letflow by the chair's step "mark signed" with the signer names, because the signature slice of 0056 D6 is not built (section 9).

## 3. Commission

- The chair and every member are employee records (REQ-643, `org_employee`, D-065). The materially responsible person of each counted balance key is named on its sheet line (the `Responsible` slot of the balance key, section 5).
- A member whose employee record has no user link cannot record lines or sign in Letflow. Such a member is named on the printout and signs on paper; the chair confirms their signature in Letflow (section 9). A member with no user link cannot be given the "record counts" step.
- Minimum number of members, and whether the responsible person may be a member: not decided. They are open owner questions (section 12). This record states no number.

## 4. Count scope and movements during the count (WM-13)

- The count scope is a set of (org unit, location subtree) pairs. Each pair must be a linked pair under REQ-644 (D-065); an unlinked pair is refused at order issue. The location subtree is read with the subtree read of REQ-646 (location tree with a parent foreign key, no depth bound, REQ-645); the org unit scope uses the org tree path with depth bound 40 (REQ-649).
- The book quantity of every stock balance key inside the scope is its balance as of the count's cut-off time (item B2, balance as of a date from the movements, 0073 D-L5 event-time basis with a cut-off `posting_seq`). The cut-off time is the server time at which the chair opens the count. The time zone shown on the paperwork is the tenant time zone (default Asia/Almaty, assumption, owner may change at GATE B).
- **Freeze method (the proposal; default, owner may change at GATE B).** From the cut-off until the differences are posted or the count is cancelled, a stock posting whose balance key falls inside the scope of any open count is refused with one named reason code, `count_in_progress` (a stock-module code, slice-local name, 422). The check runs in the stock module (item B4), in its own write path before `HandlerWrites.post/3`, because the ledger core is domain-neutral and has no count vocabulary (0073 D2, Rule 7). The posting of the count's own differences (section 8) is exempt: it carries the count's `document_type` and `document_id`, which the check recognises. The check reads the open counts' scopes in the same transaction; it adds no ledger lock class.
- Snapshot method (movements continue and are recorded against the count): not adopted. It is listed as an open owner question (section 12).
- **Overlap.** Two open counts whose scopes overlap (same org unit and an overlapping location subtree, or the same balance key) are refused at order issue with `count_scope_overlaps`. Overlap is evaluated on the (org unit, location) pairs, including a subtree containing another.

## 5. Count sheet lines and input

Line shapes:

1. **Stock line**, one per balance key: the five slots `OrgUnit`, `Location`, `Responsible`, `SKU`, `Lot` of `architectures/assets.md`, with book quantity, counted quantity and unit. Quantities are decimal strings (`decimal_strict`).
2. **Inventory Object line** (D-065), one per Inventory Object in the scope: counted as `found` or `not found`.
3. **Surplus line**: a key found that is not on the book (no book row, book quantity zero), added by the commission with its counted quantity.

Input on the web is by typing or by a keyboard scanner. The scanner types the code text followed by Enter into the focused input. The server resolves that text with `Letflow.Modules.Codes.resolve/2` (resolves through the open assignment only, REQ-648) and then checks the scope of the target. An out-of-scope target is answered exactly as an unknown code (decision 0076 R7 ruling 2: same 404).

| Result of `resolve/2` | Outcome on the count sheet |
|---|---|
| `{:error, :not_found}` | refused as an unknown code; nothing recorded |
| `{:error, :code_retired}` | refused with the retired reason; nothing recorded |
| `{:error, :assignment_conflict}` | refused with the conflict reason; nothing recorded; the commission resolves the code in master data |
| `{:ok, ...}` with `nil` target (a not-assigned code) | refused as "code not assigned"; nothing recorded |
| `{:ok, ...}` with a target of a type the sheet does not count | refused as "not countable here"; nothing recorded |
| `{:ok, ...}` with a target outside the count scope | answered exactly as `:not_found` (0076); nothing recorded, no hint that the target exists |
| `{:ok, ...}` with a target inside the scope | recorded per section 6 |

## 6. No double counting (WM-13)

- A second scan of the same Inventory Object on the same count is not counted twice. Outcome: the line stays `found`, the second scan is answered "already counted" (not an error) and is stored in the entry log with its user and time but does not change the line.
- On a quantity line each scan adds one unit to the counted quantity. A typed number replaces the counted quantity of that line (the replaced value stays in the entry log).
- Every entry on the sheet is stored with the user who recorded it and the server time. The audit trail (item B2) therefore shows who counted what and when. The entry log is append-only; nothing in it is edited. The audit trail is scoped by org unit like the other scoped types (D-067; assumption, owner may change at GATE B).

## 7. Low-value items by quantity

- Stock lines are always counted by quantity. An Inventory Object is counted one by one.
- Rule for the asset register of phase C (review finding 5, 200 identical chairs): an asset record that carries a quantity is counted by quantity; an individual asset is counted as found or not found. Phase C implements the asset half. This record does not create the asset register.

## 8. Differences posted as entries (WM-12)

- The differences sheet lists every line whose counted quantity differs from the book quantity, as a surplus (counted greater) or a shortage (counted lower). An Inventory Object `not found` is a shortage of one; a surplus line is a surplus.
- **No difference changes a balance before the differences sheet carries all required signatures** (section 9).
- **Causes** (closed list of 0073 D-C; names are slice-local proposals): `count_surplus` with sign rule `positive`, and `count_shortage` with sign rule `negative`. Both have `reason_required` true; the reason is the text "count" plus the count's document id, and the task reference WM-12 asks for is the document id of the differences sheet. A shortage is subject to the no-negative guard like any issue; a shortage cannot exceed the book balance at posting time, because the freeze (section 4) kept the balance equal to the book quantity.
- **Number of postings.** One differences sheet makes ONE posting to the stock ledger id (one transaction, one entry, one leg per difference line). A posting carries at most 200 legs (`@max_legs` in `lib/letflow/ledger/validate.ex`). A count with more than 200 difference lines is split by the chair into several count orders (scope pieces) at order time. Default, owner may change at GATE B. This fits the limit of 0073 D8 as amended by A2 (at most two postings per transaction, different ledger ids, same `document_type` and `document_id`): the count posts to the stock ledger id only; the asset-register half is a phase C addition and would be the second posting of the same transaction.
- Every entry carries the differences sheet's `document_type` and `document_id`.
- **Event time.** The `event_time` of the posting is the signing time of the differences sheet (the time the chair marks it signed). If the signing is later than 96 hours after the cut-off, the posting is refused `event_time_too_old` (0073 D-T) and the count cannot be posted. Cancel is refused from `signed`, so the signed sheet stands, the count is closed unposted and a new count is ordered. The 96-hour limit is not raised for counts (no override, D-T). The window from the cut-off to the signed sheet is therefore the commission's working time; the planned duration is checked at order issue against 96 hours and refused if longer (`count_too_long`). Default, owner may change at GATE B.
- **Origin.** The posting is made by a human-started step (a user task whose module write handler declares `posts_ledger`), never by a SERVICE task (0073 D-L12).
- **Undo.** A posted count is undone only by ONE reversal of all its entries (0073 A4; the reversal stays inside the ledger id of the entry). A reversal of part of a count is refused. A reversal is itself subject to the 96-hour window of D-T.

## 9. Signatures and access

- The count paperwork uses the `internal_ack` method of 0056 D6, which is direction only and not built (0056 D6, 0075 exclude it). Until the signature slice is built, the product works as follows (assumption, owner may change at GATE B: "signed" is a paper signature on the printout): the chair marks the document "signed" in Letflow after the signer lines on the xlsx printout are signed on paper, naming the signers; this is an acknowledgement recorded in the audit trail, not an electronic signature. ЭЦП (NCALayer) stays out of scope.
- Signers: count order: the chair. Count sheet: the chair, each member and each responsible person named on a line. Differences sheet: the chair, each member and each responsible person whose lines carry a difference. Posting record: no signer (system record).
- The signature slice of 0056 D6 (`DocumentsSign`, `document.signed`, the `internal_ack` method) is a prerequisite requirement of the split plan (section 13).
- Count documents and their lines are scoped by the order's org unit (D-067, `{:column, "org_unit_id"}`, 0076 R7). A count outside the caller's scope reads as not found (INV-5), the same answer as for an unknown id.
- Proposed permissions (open owner question, section 12), with tenant roles of `docs/roles.md` that would hold them: create and issue an order (TENANT_ADMIN and a custom store-manager role); record counts (a custom commission role, scoped to the org unit); sign (the chair and members; the role-independent check is membership in the commission); post (TENANT_ADMIN or a custom role distinct from record counts; the stock registration's post permission, rule 12 requires post and reverse to be distinct). Every proposed holder is a tenant role. No step of a count needs PLATFORM_ADMIN (`docs/roles.md`: a tenant user is never granted PLATFORM_ADMIN). A scoped principal cannot post until slice L6 (0073 D9, OQ-21; L6 is not part of phase B, assumption, owner may change at GATE B), so in phase B the poster holds a tenant-wide grant.

## 10. Paperwork format

Count paperwork in phase B is xlsx with signer lines (assumption, owner may change at GATE B): the order, the sheet and the differences sheet are exported with `Letflow.Entities.XlsxExport` (decision 0077) and carry empty signer lines for chair, members and responsible persons. Printed forms in Russian and Kazakh come in phase E (print templates); the screens carry the three languages (en, ru, kk) from phase B.

## 11. Phase A dependencies

This record rests on the following; if the GATE A check changes one of them, this record is amended (D-073):

- Trees and storage, D-066: the org tree path in the scope table with depth bound 40 (REQ-649), the location tree with a parent foreign key and no depth bound and its subtree read (REQ-645, REQ-646), master data as real columns (REQ-642, decision 0076).
- Access and scope, D-067 and decision 0076: count documents and balances scoped by org unit; codes visible tenant-wide and a scan checks the target's scope.
- Employees, D-065 and REQ-643: commission members and the responsible person are employee records with an optional user link.
- Links, REQ-644: a count scope of an org unit and a location must be a linked pair.
- Codes, REQ-648: `Letflow.Modules.Codes.resolve/2` resolves a scanned text through the open assignment only.
- Lots, REQ-647.
- Ledger: decision 0073 (REQ-616), the tables (REQ-620), posting (REQ-621) and the B1 amendment (REQ-676).
- Phase B items used without a REQ id in this record: B2 (balance as of a date and the audit trail), B4 (stock workflows, the stock register registration and its causes; the cause names of section 8 follow its naming), B6 (the balances read slice for a scoped user).

## 12. Open owner questions

Not decided; defaults are marked "default, owner may change at GATE B".

1. Freeze or snapshot method for movements during a count (WM-13 allows either). Default, owner may change at GATE B: the freeze (section 4).
2. Minimum number of commission members, and whether the responsible person may be a member. No source gives them. Default, owner may change at GATE B: no minimum number is enforced by the system beyond one chair; the responsible person may be a member (the paper rules of the customer apply).
3. Which roles hold the count permissions (section 9). Default, owner may change at GATE B: the proposal of section 9.
4. Whether the GATE A check changes phase A (D-073). If it does, REQ-680 and this record are amended.
5. More than 200 difference lines in one count (section 8). Default, owner may change at GATE B: split into several count orders.
6. Signing later than 96 hours after the cut-off (section 8). Default, owner may change at GATE B: the count is closed unposted and a new count is ordered; no override.

## 13. Split plan: implementing requirements after GATE A

Each row is sized to one change. "Sig" is the signature slice of 0056 D6.

| # | Requirement to write | Content | Depends on |
|---|---|---|---|
| C1 | Signature slice | `internal_ack` method, `DocumentsSign`, `document.signed`; prerequisite of C5 | 0056 D6 (direction), 0075 |
| C2 | Document types and the count order | the four type keys registered, the count order record type and scope declaration `{:column, "org_unit_id"}`, order issue with the overlap and pair-link checks, state table | REQ-620, REQ-642, REQ-643, REQ-644, REQ-645, REQ-646, REQ-649, B4 |
| C3 | Cut-off book quantities and the count sheet with typed input | book quantity from the balance as of the cut-off, lines, typed quantities, entry log | C2, REQ-621, B2, B6 |
| C4 | Keyboard-scanner input | `Codes.resolve/2` path, outcome table of section 5, no double counting, scope-checked 404 | C3, REQ-648 |
| C5 | Differences sheet and its signing | differences from the signed sheet, signer lines, mark signed, xlsx export | C3, C1, decision 0077 |
| C6 | Posting of the differences | causes `count_surplus` and `count_shortage`, one posting, human-started step, reversal of all entries | C5, REQ-621, REQ-676, B4 |
| C7 | Freeze check in the stock module | `count_in_progress` refusal before `post/3`, exemption for the count's own posting | C2, B4 |
| C8 | Web screens in English, Russian and Kazakh | order, sheet with scanner input field, differences sheet, states, empty/error/loading states | C2 to C6 |

C1 is the only row that may start before GATE B; C2 to C8 wait for the owner's check of this record.

## Not decided here

Camera scan and offline counting on the phone (phase D); printed paperwork in Russian and Kazakh (phase E); the asset register itself (phase C); ЭЦП (NCALayer); export of differences to 1C; period close (D-062: not part of this product); scoped posting (L6).
