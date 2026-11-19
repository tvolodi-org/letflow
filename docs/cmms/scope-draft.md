# CMMS (maintenance management) on Letflow: draft scope

Status: **draft scope for the owner, not a decision and not an approval.** Task T-2271 (owner request D-162 via the PM,
2026-11-19). Docs only: no requirement entry, no code, no migration, no schema, no route, no screen, no seed, no QA
tenant. Requirement entries (`REQ-`) are written later, one per slice, after the owner has read this note.

## Summary (ten lines)

1. CMMS = keeping equipment working: people report faults, a planner turns them into work orders, technicians do them, the manager sees backlog, downtime and cost.
2. Letflow already has most of the parts: asset cards with location and responsible person, the process engine with tasks, approvals and escalation timers, scheduled jobs, numbering, photos, QR labels, the phone app and the stock module.
3. Spare parts stay in the stock module: a work order uses parts through the existing stock issue document. No second parts register.
4. Equipment is the existing asset card. CMMS adds maintenance data to it (criticality, meters), it does not copy the card.
5. The new work is one module (working name `maintenance`) with work requests, work orders, plans, checklists and downtime records.
6. Slice 1 (size M): a work request and a work order linked to one asset card, a short life (open, in work, done, closed) and a "my work orders" list on the web and the phone.
7. Then, smallest first: approval and assignment, checklists and photos, parts from stock, preventive plans by calendar, downtime and the first KPIs, meter-based plans, costs.
8. Not in scope now: IoT/live sensor feeds, ERP and accounting posting, purchasing, contractor portals, predictive maintenance, a new role editor.
9. The biggest open points: who the first customer is, its industry and scale, which roles it needs (the built-in roles have no "technician"), offline need on the phone, and the overlap with the planned MES equipment.
10. **Recommendation: approve slice 1 as the first requirement now, keep it on a flag that is off by default, and get one real maintenance team to answer the open points before slice 3.**

## 0. Sources and marks

Opened on origin/main `da225605d` (2026-11-19) for this note:

- Asset register and documents: `docs/assets/asset-register.md` (REQ-689), `docs/assets/asset-workflow-documents.md` (REQ-690),
  `docs/assets/card-actions.md`, `docs/assets/phone-flows.md` (REQ-733), `docs/assets/stock-workflow-documents.md` (REQ-679);
  code `lib/letflow/modules/assets/` (`cards.ex`, `documents.ex`, `card_photos.ex`, `reminders.ex`, `reports.ex`).
- Stock documents: `lib/letflow/modules/stock/documents/kinds.ex` (the closed table of stock document kinds, prefix `ISS`
  for an issue) and `lib/letflow/modules/stock/documents/shape.ex` (an issue may carry a free `reason_text`; there is no
  structured link to another record). REQ-715 (issue and write-off documents), REQ-721.
- Engine and scheduling: `lib/letflow/definitions/graph.ex` (TIMER node; HUMAN_TASK escalation and reminder timers, REQ-396);
  `lib/letflow/scheduled_jobs.ex` (REQ-561: a tenant job starts a published process on an interval; flag off by default);
  `lib/letflow/scheduler/record_deadline_sweep.ex` (REQ-331: a deadline field moves a record's status);
  `lib/letflow/engine/separation_of_duties.ex` and `lib/letflow/approval_rules.ex` (four-eyes per step, `distinct_from`).
- Records and reports: `lib/letflow/number_sequences.ex` (REQ-575, human numbers); decision 0066 (saved list views);
  `lib/letflow/entities/query/compiler.ex` `run_aggregate/3` (counts and sums over records); decision 0070 (tenant-owned record
  types); decision `0067-tenant-x-extension-layer-over-module-entity-types.md` (`x_` fields on module types).
- Notifications and files: `lib/letflow/notifications.ex` (REQ-584, the `task_assigned` mail), `lib/letflow/user_notifications.ex`
  (the bell), `lib/letflow/attachments.ex`, `docs/design/photos.md`, `lib/letflow/modules/codes/labels.ex` (REQ-779, QR and
  barcode label sheets).
- Org and places: `lib/letflow/modules/org/`, `lib/letflow/modules/locations/`; decisions 0050, 0051 (org-scoped grants), 0064
  (org-relative task assignment), 0076 (master data layer: consumers depend on master data, never the reverse).
- Cross-module posting: decision 0082 (a definition of module M may carry a posting line of module N when N is in M's
  `depends_on`); decision 0087 (how `mes_core` posts to stock without a third copy of the posting code); decision 0073 (ledger).
- Roles: `docs/roles.md` (nine built-in roles); decision 0088 (access by permissions only; ready-made roles are read-only
  template rows in the open build; a role editor is a closed feature).
- Phone: `docs/mobile/requirements.md` (MOB-1 generic definition-interpreter app, MOB-3 offline cache, MOB-4 renderers),
  `docs/mobile/pwa-parity.md`, `apps/mobile/lib/renderers/task/task.dart`, `apps/mobile/lib/features/codes/`,
  `apps/mobile/lib/offline/offline_queue.dart`.
- MES overlap: `docs/design/mes/01-domain-and-fit-gap.md` (rows 6 and 11: equipment state, downtime), `docs/design/mes/05-platform-options.md`
  (planned `mes_core` record types `equipment`, `equipment_state_change`, and "work orders" in the production sense),
  `docs/design/mes/11-readings-import-P3.md` (a reading record with a source and one file import, proven in test code only),
  `lib/letflow/modules/mes_core/mes_core.ex` (an empty module shell today).

Searches that found nothing: `grep -rniE 'maintenance|cmms|work order' docs/requirements.yaml docs/assets docs/roles.md` hits
only database partition maintenance, platform maintenance mode and a library's "maintenance status": there is no CMMS
requirement, record type or screen on main.

The portfolio files (`ai-dala-portfolio/architectures/assets.md`, `project/assets-gap-analysis.md`) are outside this repository;
this note does not rest on them. Where the asset docs above quote them, this note uses the repository docs only.

Marks: **[V]** read in the named file; **[P]** proposal of this note, owner may change; **[A]** UAT assumption, to be confirmed by
the process owner; **[Q]** open point (section 9).

## 1. What a maintenance team does, day to day

- Someone sees a problem (a pump leaks, a door does not close, a printer is dead) and **reports it**: which machine, what is
  wrong, how urgent, a photo.
- The maintenance planner or manager **looks at the request**: real or not, urgent or not, our job or a contractor's. A real one
  becomes a **work order**.
- The planner **plans** it: what to do, which skills, which parts, how long, when the machine can be stopped. Then **assigns** a
  technician or a team.
- The technician **does the work**: goes to the machine (finds it by the QR label), follows a checklist, notes the time spent and
  the parts used, takes photos, writes what was found (the failure cause) and what was done.
- The work order is **closed**, and the requester or the manager **verifies** the machine works.
- Besides the breakdowns, the team does **planned work**: every month, every 500 running hours, every 10 000 km, a fixed list of
  checks (oil, filters, belts, safety tests). These come from **preventive maintenance plans** and create work orders by
  themselves.
- The storekeeper **issues spare parts** against a work order and keeps the parts stock.
- The manager watches **the numbers**: how many open orders, how many late, how long a machine was down, how often it fails,
  how much a machine costs to keep.

## 2. Who does what (business actors)

These are people in the business, **not** roles in the product. The built-in roles in `docs/roles.md` [V] have no maintenance
role; decision 0088 [V] makes roles template rows chosen from the permissions modules declare. Which ready-made roles a CMMS
module ships is open point Q5. The right column is only the nearest built-in role, for orientation.

| Business actor | Does | Nearest built-in role today [V] |
|---|---|---|
| Requester / operator | Reports a fault; sees the state of own requests; confirms the fix | TASK_WORKER |
| Maintenance planner | Accepts or rejects requests, makes and plans work orders, assigns technicians, keeps the plans | PROCESS_OPERATOR (starts, assigns, watches) |
| Maintenance manager | Approves big or costly orders, sets priorities, reads reports and KPIs | PROCESS_OPERATOR or TENANT_AUDITOR for reading |
| Technician | Does assigned orders: checklist, time, parts used, photos, cause, close | TASK_WORKER |
| Storekeeper | Issues spare parts to a work order, keeps parts stock | STOREKEEPER (stock module) |
| Auditor | Reads orders, history and reports; changes nothing | TENANT_AUDITOR |
| Tenant administrator | Users, module settings, flags, numbering | TENANT_ADMIN |
| Contractor | Does an outsourced order | none; not in scope now (section 8) |

## 3. The objects

| Object | What it is | Reuse or new |
|---|---|---|
| Asset / equipment | The machine. Has a location, an org unit, a responsible person, a photo, a QR label | **Reuse** the asset card (`assets_card`, REQ-689) [V]. CMMS adds maintenance data in its own record linked to the card (criticality, meters, maintenance type) [P]; it does not copy the card |
| Asset tree | Site, building, line, machine, part | **Reuse** the location tree for places [V]; whether a machine can have sub-machines is Q9 |
| Criticality | How bad a stop of this machine is (for example A, B, C) | New field in the CMMS record [P]; the scale is Q10 |
| Meter | A counter on the machine: running hours, km, cycles; with dated readings | New [P]; manual reading first. The MES reading proof (`11-readings-import-P3.md`) [V] is the pattern for a later file import |
| Work request | A report of a problem by anyone | New record type, started as a process [P] |
| Work order | The job: type (corrective, preventive, inspection), priority, asset, assignee, planned and real dates, status | New record type and process [P] |
| Preventive plan | "Do checklist X on asset Y every N days / every N hours of meter Z" | New [P]; a calendar plan can be run by the scheduled jobs of REQ-561 [V] |
| Checklist / procedure | Ordered steps with a yes/no, a value or a note | New [P]; a work order form can carry the steps |
| Spare parts and consumables | Items held in stock | **Reuse** stock items and balances; parts leave stock by the stock **issue** document (REQ-715) [V] |
| Labour and time | Who worked, how many hours | New lines on the work order [P] |
| Downtime and failure cause | From when to when the machine was stopped; why (cause code), what was done | New [P]; cause list is a tenant list (Q11) |
| Vendor / contractor | Outside firm doing the job | Later; only a name field in early slices [P] |
| Cost | Parts (from the stock issue), labour (hours times a rate), outside services | Later slice; information only, no accounting posting [P] |
| Documents and photos | Photos of the fault and the fix, manuals, acts | **Reuse** the attachment service and photo gallery (`docs/design/photos.md`, `card_photos.ex`) [V] |

## 4. The life of a work order (in words)

```
  someone reports  ->  [REQUEST: new]
                          |  planner looks at it
                          +--> rejected (reason) -> requester is told        [end]
                          v
                       [ORDER: open]  <-- also made directly by a preventive plan
                          |  approve (only above a cost or for critical assets) [P]
                          v
                       [planned]  date, parts, skills, estimated hours
                          |  assign a technician or a team
                          v
                       [assigned] -> technician starts -> [in work]
                          |            (may be put [on hold]: waiting for parts or a stop window)
                          v
                       [done]  checklist filled, time, parts used, cause, photos
                          |  requester or planner checks the machine
                          +--> not fixed -> back to [in work]
                          v
                       [closed]  (verified; no more changes; history kept)
```

Rules [P]: each move is a task of the process, so the task list, assignment, escalation (a late task goes up to the manager,
HUMAN_TASK escalation timer, REQ-396 [V]) and four-eyes on approval (`distinct_from` [V]) come from the engine. A closed order is
not edited; a correction is a new order. Slice 1 uses only `open -> in work -> done -> closed`.

## 5. Reports and KPIs a maintenance manager wants

| Report | Plain meaning | Needs |
|---|---|---|
| Open orders | All orders not closed, by asset, by technician, by priority | Slice 1 list views (decision 0066) |
| Overdue orders | Planned date passed, not done | Planned date field; slice 2 |
| Backlog | Open work in hours, compared with team hours per week | Estimated hours; slice 2 |
| Planned vs unplanned | Share of preventive orders against breakdown orders | Order type; slice 4 |
| PM compliance | Preventive orders done on time, out of all due | Preventive plans; slice 5 |
| MTTR (mean time to repair) | Average time from the stop to the machine working again | Downtime start and end; slice 6 |
| MTBF (mean time between failures) | Average running time between two breakdowns of one asset | Downtime records over a period; slice 6 |
| Downtime by asset and cause | Hours stopped, which causes most | Cause codes; slice 6 |
| Parts consumption | Parts issued per asset and per order | Stock issue linked to the order; slice 4 |
| Cost per asset | Parts plus labour plus outside services per asset per period | Costs; slice 8 |

Counts, sums, minimum, maximum and averages per group over stored fields can use `run_aggregate/3` [V]. MTTR can be an
average once each order stores its downtime hours; MTBF needs the time between two breakdowns of the same asset, which is not a
stored field and no aggregate computes today [V]; a computed report is part of slice 6 (risk).

## 6. On the phone (technician)

- "My work orders": the list of orders assigned to me or my team, sorted by priority and date.
- Scan the asset QR label (the existing codes scanner, `apps/mobile/lib/features/codes/` [V]): opens the asset and its open orders;
  "report a problem" from the scan.
- Open an order: what to do, the checklist, the asset's photo and history.
- Fill the checklist, add photos (camera), the time spent, the parts used, the cause and what was done; close.
- Report a problem (requester) from the phone with a photo.

Reuse [V]: the phone app is a generic interpreter of process forms and tasks (MOB-1, MOB-4, `renderers/task/task.dart`); the PWA is
the web build of the same code (`docs/mobile/pwa-parity.md`). Offline: the app has an offline queue for stock documents
(`offline_queue.dart`); whether technicians work without network (basements, remote sites) is Q4.

## 7. Slice list, smallest first

Every slice is behind a per-tenant flag, off by default [P], and gets its own requirement, design, security review and UAT.
Sizes are rough guesses: S = one change, M = two to four changes, L = more.

| # | Slice | Who benefits | Reused from the platform | Size | Risks |
|---|---|---|---|---|---|
| 1 | **Asset-linked work requests and work orders, short life** (open, in work, done, closed), human number, "my work orders" list on web and phone, report a problem from an asset card | Requester, technician, planner | Asset card (read through the assets read API, decision 0076), process engine and tasks, number sequences, list views, generic phone task screen, `task_assigned` mail | M | Module id and permissions are new; the asset read must respect org-unit scope (decision 0051); naming clash with MES "work orders" (Q8) |
| 2 | **Planning and assignment**: priority, planned date, estimated hours, assign a person or team, overdue list, escalation of a late order to the manager | Planner, manager | HUMAN_TASK escalation and reminder timers (REQ-396), org-relative assignment (0064), deadline sweep (REQ-331) | S-M | Which org unit's manager gets the escalation (0064 open questions) |
| 3 | **Checklists and photos on the order**, failure cause and work done, verification step by the requester | Technician, manager | Attachment and photo service, form steps, four-eyes switch for verification | M | Checklist editor for the tenant may be large; start with a fixed list per order type [P] |
| 4 | **Spare parts from stock**: issue parts to a work order, see parts used per order and asset; corrective vs preventive type | Storekeeper, manager | Stock issue document (REQ-715) and its posting; cross-module line (0082) if the order posts the issue | M | Today an issue carries only free `reason_text`, no link to an order [V]: needs a stock change (a reference field) or a cross-module line; STOREKEEPER reads assets only where the tenant switches on the storekeeper asset grant (decision 0084, `docs/roles.md`) [V] |
| 5 | **Preventive plans by calendar**: "every N days do checklist X on asset Y", orders made by themselves, PM compliance list | Planner, manager | Scheduled jobs (REQ-561, flag off by default), number sequences | M | Scheduled jobs start a process with the creator's authority and are TENANT_ADMIN-managed [V]; a plan per asset may mean many jobs (scale, Q2) |
| 6 | **Downtime and first KPIs**: downtime start and end per order, cause codes, MTTR, MTBF, downtime by cause, open/overdue counts | Manager | Aggregates, saved views, reports pattern of assets | M-L | MTTR/MTBF need a computed report (section 5); must share one downtime model with MES (Q8) |
| 7 | **Meters and meter-based plans**: manual readings on the phone, "every 500 hours" plans | Planner, technician | MES reading proof as the pattern; scheduled sweep | M | Reading import from files or devices is later; wrong readings trigger wrong orders |
| 8 | **Labour, outside services and cost per asset** | Manager | Currency directory, xlsx export (0077) | M | Labour rates touch pay data (sensitive); information only, no accounting posting |
| 9 | **Contractors**: an outside firm as the assignee, its order list | Manager | Org and identity | L | Outside users in a tenant: access and licence questions |

Recommendation [P]: slice 1 first, then 2 and 3 (they make the module usable for a real team), then 4 and 5. Slices 6 to 9 wait for
the answers of a real maintenance team.

## 8. Not in scope (now)

- Live sensor or IoT feeds, SCADA or PLC links, condition monitoring, predictive maintenance.
- Posting costs to accounting, depreciation changes, invoices, payments; any money movement.
- Purchasing of parts (requisitions, purchase orders, suppliers' prices); the held procurement module is not resumed by this.
- A second parts register or a copy of the asset card: parts stay in stock, equipment stays the asset card.
- A contractor or customer portal; outside logins.
- Fleet-specific work (fuel, tyres, drivers), building-specific work (room booking, energy), calibration certificates as a regulated
  process; each could be a later pack.
- A tenant role editor (closed feature per decision 0088); new built-in roles are not created by this module.
- Mobile-only screens outside the generic interpreter, unless a slice proves one is needed.
- Any QA deploy, extra tenant or UAT run for this draft; nothing touches the Qoimeks migration or its walk files
  (`test/fixtures/uat/scenarios/qoimeks-*`).

## 9. Open points

For the owner:

- **Q1 First customer.** Who is the first user (a Qoimeks client, a BilimBaga site, a new prospect)? Which industry: factory,
  buildings, vehicles, utilities? This decides slices 6 to 9.
- **Q2 Scale.** How many assets, technicians and orders per month? Hundreds of assets with a few preventive plans each, or tens of
  thousands?
- **Q3 Languages.** ru, kk and en for all screens and prints from slice 1, like the assets module? [A] yes, all three.
- **Q4 Offline.** Must a technician close an order with no network? If yes, slice 1 grows (offline queue for work orders).
- **Q5 Roles.** Which ready-made roles does the module ship (for example planner, technician), given decision 0088? Until then UAT
  uses the nearest built-in roles of section 2 [A].
- **Q6 Edition.** Open build or closed package (decision 0088 split, `docs/design/open-core-sockets.md`)?
- **Q7 Module name and dependencies.** Working name `maintenance`; it depends on `assets`, `locations`, `org` and, from slice 4,
  `stock` (decision 0076 direction). Agree?
- **Q8 MES overlap.** MES plans its own `equipment` and `equipment_state_change` records and production "work orders"
  (`docs/design/mes/05-platform-options.md`). Proposal [P]: one equipment base (the asset card plus one maintenance/equipment
  record shared by both modules) and the word "maintenance order" in the UI to avoid the clash. Who owns the shared record?

For a real maintenance team:

- **Q9 Hierarchy.** Do machines have sub-machines (line, machine, motor)? How deep?
- **Q10 Criticality.** Which scale (A/B/C, 1 to 5)? Does it change the approval or the response time?
- **Q11 Causes.** A fixed list of failure causes, or free text first? Who keeps the list?
- **Q12 Approval.** Which orders need approval (by cost, by criticality, by type)?
- **Q13 Planned work.** Calendar only, or meters too from the start? Which meters (hours, km, cycles)?
- **Q14 Time and cost.** Do they record hours per technician? Is labour cost needed, or parts only?
- **Q15 Integrations.** Asset import from xlsx (exists for asset cards, `docs/assets/asset-xlsx.md`), ERP (1C or other), meter
  data from files or devices, e-mail or messenger notifications?
- **Q16 Paper.** Do they need a printed work order or act (form, signatures)? An official form?

## 10. How this note was kept within its limits

No requirement entry was written to `docs/requirements.yaml`; no code, migration, schema, route or seed; no QA tenant; no file
under `test/fixtures/uat/scenarios/qoimeks-*` was touched. Every reuse claim above names the file it was read in; sizes and slice
order are proposals.
