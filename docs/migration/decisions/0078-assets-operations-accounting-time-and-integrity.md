# 0078 -- Assets operations accounting: balance as of a date, documents fixed once issued, backdating limit, audit trail

Status: PROPOSED by the developer of T-1199 for REQ-681 / GH #3672 (assets phase B, item B2). Not binding until REVIEWER or owner sign-off. Three questions are marked "default, owner may change at GATE B" (see Open).

Date: 2026-11-04

Related: REQ-681 (GH #3672), REQ-676, REQ-677, REQ-679, REQ-680, REQ-682, REQ-620, REQ-621, REQ-637, REQ-686; decisions 0056, 0061, 0073 (and its section "Amended (REQ-676, assets B1)"), 0076.

Decision number check at implement time: highest on `origin/main` is 0077, so 0078 is free here. Sibling phase B tasks also write records; the number is re-taken at merge (rename the file if 0078 is taken).

This record writes no code, migration, test, seed or route, and edits no other record and no other requirement entry (D-073: specification only; the reads, screens and checks it describes are later requirements, written after GATE A).

## Sources

- Owner decisions D-061, D-062, D-063, D-065, D-066, D-067, D-073 (`ai-dala-portfolio/DECISIONS.md`); D-062: the product is real-time operations accounting, not a financial system.
- `ai-dala-portfolio/architectures/assets.md` (sections "The model", "Decisions of 2026-10-31", "Reports and import", "Access requirements")
- `letflow-team/project/assets-gap-analysis.md` (row "Opening balances, old dates"; sections 1, 4, 6)
- `docs/migration/decisions/0073-domain-neutral-ledger-primitive.md` (D-L5, D-T, D8, D-P, Consequences) and its section "Amended (REQ-676, assets B1)"
- `docs/migration/decisions/0056-versioned-documents.md` (D1, D4, D6, D9)
- `docs/migration/decisions/0061-engine-lock-order-platform-invariant.md` (item 6, the audit chain row)
- `docs/migration/decisions/0076-master-data-layer.md`
- `lib/letflow/design/gh2657-wms-stock-ledger-core.md` sections 8.1..8.4, 10, 14.1, OQ-22
- `lib/letflow/documents.ex` (`issue/2`, `cancel/3`), `lib/letflow/audit.ex`, `lib/letflow/routers/audit.ex`, `docs/roles.md`
- `priv/repo/migrations/20261031100001_create_ledger_tables.exs`
- REQ-676 and this entry REQ-681 in `docs/requirements.yaml`

## Phase A dependencies

This record rests on the phase A results below. If the GATE A check changes any of them, this record is amended (D-073).

| Dependency | Owner decision / requirement |
|---|---|
| Org tree path in the scope table, depth bound 40 | D-066, REQ-649 |
| Location tree with a parent foreign key | D-066, REQ-645, REQ-646 |
| Master data as real columns | D-066, REQ-642 (decision 0076) |
| Balances, movements, documents and employees scoped by org unit | D-067, decision 0076 (the scoped balances read is item B6, REQ-682, not this record) |
| Employees: the responsible person and the actual user hold employee ids | D-065, REQ-643 |
| Links: a movement whose org unit and location are not linked is refused | D-065, REQ-644 |
| Codes: a code record with its assignment history | D-065, REQ-648 |
| Lots | REQ-647 |
| xlsx import | REQ-650 |

Phase B dependency: the B1 amendment of 0073 (REQ-676: two postings in one transaction with the same `document_type` and `document_id`, and its reversal rule).

## Context

The parts of operations accounting exist in separate records and are not tied together for this application. 0073 D-L5 and the note (section 8.2) define two report bases; 0073 D-T caps `event_time`; 0056 D4 makes an issued document version immutable; the audit chain (REQ-195, REQ-196) is read through `GET /audit`. This record ties them and states what the assets application adds on top: nothing new in the engine, only rules of use and the open questions.

## Decision

### D1 No period close

The assets application has no period close, no closed-period flag, no stored period-end balance and no posting-period table (D-062). Period close belongs to the financial system (1C). The lateness cap of 0073 D-T is the ONLY bound on backdating. D-T's numbers, unchanged by this record: default `max_event_lateness_hours` = **96 hours**, at most **720 hours** (rule 12), skew **5 minutes** into the future, refusals `event_time_too_old` and `event_time_in_future` (422, nothing written), no tenant or operator override. The assets registrations use the default of 96 hours.

### D2 Balance as of a date

The balance of a register as of a date D is the sum of the legs whose `event_time` is before 00:00 of the day after D (in the time zone of D4), read with the as-of event-time basis of note section 8.2 together with a cutoff `posting_seq` N. Event time without N is not offered (note 8.2).

- It is computed from `ledger_leg` and `ledger_entry` on every read. `ledger_balance` holds only the current balance and is NOT used for a past date. A balance as of the current moment equals `ledger_balance`.
- Every as-of answer and printout states the report fields of note section 8.4: `basis`, `cutoff_seq`, `as_of`, `timezone`, `filters`, `ledger_seq`.
- The same (D, N) gives the same numbers on every later read. A later read with a larger N may differ by postings that arrived late within the cap.

### D3 Time zone of a date

No tenant time zone setting exists on `origin/main`. Command and output:

```
$ grep -rln "timezone" lib/ --exclude-dir=design
lib/letflow/definitions.ex
```

The only hit is a comment about clock skew in `lib/letflow/definitions.ex`, not a setting. The day boundary of D2 depends on a time zone, and note section 8.4 says every report states it. This record decides no time zone. The source of the time zone is an open owner question (Open Q1) with one proposed default.

### D4 Corrections and past dates

A correction never edits a posted movement. It is a reversal (note section 10, and the two-posting reversal rule of REQ-676). A reversal carries its own `event_time`, so a balance as of a date before the reversal still shows the original movement.

Worked example (as-of rule of D2): a receipt of 10 with `event_time` on day 1; its reversal with `event_time` on day 3. Balance as of day 1 = 10. Balance as of day 3 = 0. Balance as of day 2 = 10.

### D5 Documents fixed once issued

Every posting of the assets application carries the `document_type` and `document_id` of a versioned document (decision 0056) whose version was issued. No posting is made from a draft. After issue, the document's content (lines, quantities, dates, parties, employees, locations) is changed only by the 0056 D4 path: `Letflow.Documents.cancel/3` with a mandatory reason, together with the reversal of its postings, then a new document.

**Order of issue and posting, and how they are bound.** Two facts decide it:

1. `Letflow.Documents.issue/2` takes the document row, the `document_sequences` row and the audit chain in ONE transaction (`lib/letflow/documents.ex`, "One transaction; lock order document row, sequence row, audit chain").
2. 0073 D8 (class 5b): "A transaction that holds the audit chain row or any later class never takes a ledger row."

So issue and posting cannot share one transaction in the order issue-then-post. The order is: **issue the document first (transaction 1), post second (transaction 2)**, the posting carrying the issued document's `document_type` and `document_id`. In the other direction, cancel and reversal are separate transactions in the order **reversal first, cancel second**.

Binding is by workflow order and by detection, not by a ledger check: 0073 D-P gives the policy no reads in L1..L4, so the ledger cannot check that the document is issued (no `expected_document_version` check). The stock workflows (item B4, REQ-679) place the issue step before the posting step.

States after a single failure:

| Failure | State found | Detected by | Repair |
|---|---|---|---|
| Issue done, posting refused (e.g. `event_time_too_old`, `insufficient_balance`) | Issued document with no ledger entry | Query: issued movement documents with no `ledger_entry` of that `document_id` (index `ledger_entry_document_index`) | Retry the posting (idempotent per document and version), or cancel the document (nothing to reverse) |
| Posting done, issue refused | Impossible by the order: the posting step runs only after the issue step completed | A posting whose `document_id` has no issued version is a defect, found by the same join read the other way | Reverse the posting; report as a defect |
| Reversal done, cancel refused | Issued document whose postings are all reversed | Query: issued documents whose entries are fully reversed | Retry the cancel |
| Cancel done, reversal refused | Impossible by the order (reversal first) | n/a | n/a |

The detection queries are a later requirement (follow-up table).

### D6 Signed

0056 D6 signatures are direction only and not built:

```
$ grep -rln document_signatures lib priv
(no output)
```

The system fact "fixed" is the **issued version**. "Signed" in the first version means a paper signature on the printout of the issued version (count paperwork and hand-over documents, D-062). Electronic signatures and the NCALayer integration are out of scope. The meaning of "signed" is an open owner question (Open Q2), with this reading as the default.

### D7 Real receipt date

The date when goods or an asset were really received is a field of the receipt document or of the asset record (the field name is left to items B3, B4 and phase C), separate from `event_time`. It may be any past date and is not a date after the posting day. It is printed on the government lists (`architectures/assets.md`, "Reports and import") and is NEVER used as `event_time`. A balance as of a date before the opening balances are posted does not show goods received earlier; item B3 (REQ-677) covers that.

For a movement document whose operation time is within the cap, the module's policy declares `event_time` from the document's operation time (`declarative_posting` `event_time`, note section 14.1). An operation time older than the cap is refused with `event_time_too_old`, nothing written. OQ-22 of the note (a separate backdating permission) stays **no**.

### D8 Audit trail

One row per write action of the assets application. "Writer" is found on `origin/main` by grep at implement time; "not on origin/main" names the owner of the gap.

| Write action | Audit action name | Writer on origin/main |
|---|---|---|
| Org unit created, renamed, updated, moved, retired | `org_unit.created`, `org_unit.renamed`, `org_unit.updated`, `org_unit.moved`, `org_unit.retired` | `lib/letflow/modules/org/units.ex` (lines 44, 59, 73, 87, 126) |
| Site created, updated, retired | `org_site.created`, `org_site.updated`, `org_site.retired` | `lib/letflow/modules/org/masters.ex` via `Masters.run/7` and `audit/7` |
| Legal entity created, updated, retired | `org_legal_entity.created`, `.updated`, `.retired` | `lib/letflow/modules/org/masters.ex` |
| Position created, updated, retired | `org_position.created`, `.updated`, `.retired` | `lib/letflow/modules/org/people.ex` via `Masters.run/7` |
| Employee created, updated, retired | `org_employee.created`, `.updated`, `.retired` (entries omit `full_name`) | `lib/letflow/modules/org/people.ex` |
| Location created, updated, moved, retired | not found | `lib/letflow/modules/locations/tree.ex` calls `Records.create_record/3` and `Records.update_record/3` and no `Audit` function; no `location.*` audit action string exists in `lib/`. Not on origin/main as an audit entry: follow-up F6 |
| Link of org unit and location: created, reactivated, retired | `location_org_unit_link.created`, `.reactivated`, `.retired` | `lib/letflow/modules/locations/links.ex` (lines 132, 139, 151) |
| Code received, assigned, released, retired, value changed | `code.received`, `code.assigned`, `code.released`, `code.retired`, `code.value_changed` | `lib/letflow/modules/codes/writes.ex` (lines 168, 222, 275, 310, 390) |
| Catalog item created, updated, retired | not found | `lib/letflow/modules/catalog_items/catalog_items.ex` has no audit writer; the lot writer in `lots.ex` is not it. Follow-up F7 |
| Lot created, updated, retired | `catalog_lot.created`, `.updated`, `.retired` | `lib/letflow/modules/catalog_items/lots.ex` (lines 52, 69, 84; `audit/5` at 167) |
| xlsx import | not found | the module import files `org/import.ex` and `catalog_items/lot_import.ex` state that they call no `Records`, no `Audit`; `lib/letflow/entities/xlsx_import.ex` and `routers/entities/record_import.ex` contain no `Audit` call. Whether the per-row writes of an import are audited is follow-up F8 (item B3 / REQ-650 owner) |
| Document draft created | `document.draft_created` | `lib/letflow/documents.ex` (`audit!/7`, line 466) |
| Document issued | `document.issued` | `lib/letflow/documents.ex` (line 555) |
| Document cancelled | `document.cancelled` | `lib/letflow/documents.ex` (line 880) |
| Posting, reversal | `ledger.posted` | not on origin/main (`grep -rn "ledger.posted" lib --exclude-dir=design` finds no writer); owed by slice L3c (REQ-686), 0073 slice L3 |

The record does not presume that a gap exists beyond those the grep found: F6, F7, F8 and `ledger.posted` are rows with no writer found on this origin/main; a writer found later removes its follow-up.

### D9 Reading the audit trail

The audit trail is read through `GET /audit` with the permission `AuditRead` (`lib/letflow/routers/audit.ex`), filters `from`, `to`, `actor_id`, `resource_type`, `resource_id`. From the `docs/roles.md` matrix (columns PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, AGENT_RUNNER, CANDIDATE, TENANT_ADMIN, TENANT_AUDITOR, scope):

```
AuditRead                       yes            no               yes              no          no           no        yes          yes            tenant
```

So PLATFORM_ADMIN, PROCESS_OPERATOR, TENANT_ADMIN and TENANT_AUDITOR hold it at tenant scope. This record grants no new role and changes no permission. Whether a reader should see only the entries of the org units it can see is an open owner question (Open Q3); this record states no answer.

## Consequences

Follow-up work this record implies:

| # | Work | Owner (slice, item or requirement) |
|---|---|---|
| F1 | As-of balances read (D2): `balances/5` with the as-of basis | slice L2b (REQ-637) or item B6 (REQ-682) |
| F2 | As-of printout stating the 8.4 fields | phase E |
| F3 | Receipt date field (D7) | items B3 (REQ-677), B4 (REQ-679) and phase C |
| F4 | Issue-then-post binding and cancel-after-reversal order (D5) | item B4 (REQ-679) |
| F5 | Detection queries of D5 (issued without posting, posting without issued document, fully reversed but not cancelled) | item B4 / B5 (REQ-679, REQ-680), later requirement |
| F6 | Audit of location create, update, move, retire (D8) | phase A follow-up requirement, to be written |
| F7 | Audit of catalog item writes (D8) | phase A follow-up requirement, to be written |
| F8 | Audit of rows written by xlsx import (D8) | REQ-650 owner / item B3 (REQ-677) |
| F9 | `ledger.posted` audit entry | slice L3c (REQ-686) |
| F10 | Tenant time zone setting, if Open Q1 is accepted | later requirement after GATE B |

REQ-620, REQ-621 and REQ-676 are entries whose criteria a later change may amend; this change edits none of them.

## Open

Each default is "default, owner may change at GATE B".

1. **Q1 Time zone of "a date" (D3).** Default, owner may change at GATE B: one tenant time zone setting (an IANA name), whose initial value is `Asia/Almaty`; every as-of answer states it in the `timezone` field. No time zone is decided by this record.
2. **Q2 Meaning of "signed" (D6).** Default, owner may change at GATE B: a paper signature on the printout of the issued version; electronic signatures out of scope.
3. **Q3 Audit reading scope (D9).** Default, owner may change at GATE B: unchanged, `AuditRead` stays tenant-wide for its four roles; no per-org-unit filtering of the audit trail in the first version.
4. Whether the GATE A check changes phase A (D-073): if it does, this record is amended.
