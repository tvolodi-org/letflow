# 0092 — ACCEPTED (option C, D-163): who owns equipment state and downtime: `maintenance` or `mes_core`

Status: **ACCEPTED** (2026-11-19, D-163, decided by the team (PM); architecture is the team's decision under the owner's rule, so the owner question was not sent). Option C, built lazily. Originally drafted in T-2281 (2026-11-19; owner request D-162 via the PM; the architect's written answer to open point Q8 of `docs/cmms/scope-draft.md`). Docs only: no code, no schema, no migration, no requirement entry, no manifest change. The number 0092 was the next free one on origin/main at T-2281 (0091 is the highest, and no open `origin/team/*` branch carries a 0092 file).

Sources (read, not changed): `docs/cmms/scope-draft.md` (summary item 4, section 9 Q7 and Q8); `docs/design/mes/01-domain-and-fit-gap.md`
(rows 6 "Equipment and its state" and 11 "OEE and downtime"); `docs/design/mes/05-platform-options.md` (section 4.1 `mes_core` with
`depends_on` `catalog_items, codes, locations, org, stock, assets`; section 4.3 record types `equipment`, `equipment_state_change`,
`downtime`, `work_order`; events `equipment.state_changed`, `downtime.started`); `docs/design/mes/11-readings-import-P3.md` (readings keyed by
an equipment code); decisions 0076 (assets master-data layer, consumers depend on master data, never the reverse), 0082 (cross-module posting
lines: allowed only towards a module in the stamp's own `depends_on`), 0087 (`mes_core` posting without a third copy), 0050 (foundation modules,
reference through `depends_on`); `lib/letflow/modules/mes_core/mes_core.ex` (an empty shell today); `ls lib/letflow/modules` shows no
`maintenance` directory.

## The problem in plain words

Two planned modules both want to keep, for one machine, "is it running or down, since when, and why".

* The new **`maintenance`** module (CMMS) needs it to know when a machine broke, how long it was down, and to report downtime and backlog.
* The planned production module **`mes_core`** needs it to say which tank or line is running, idle, down or being cleaned, and to compute OEE
  (the share of time a machine really produces).

If both build their own records, one machine gets two "down" histories that disagree, two people key the same stoppage twice, and a later
merge of the two is a data migration on tenants that already run. Nothing of either is built yet, so deciding now costs a few paragraphs;
deciding after both ship costs a migration on every installed tenant.

Two words clash and must stay apart in the UI: the **production work order** of `mes_core` ("make 5 t of product by Friday") and the
**maintenance order** of `maintenance` ("repair the pump"). They are different records under any option below.

## What is not in question

* The machine itself is the **asset card** of the `assets` module (REQ-642 line, decision 0076): code, name, location, responsible person.
  `mes_core` already links `equipment` to it (05, section 4.1) and CMMS says "equipment is the existing asset card" (scope draft item 4).
  No option below creates a second machine master.
* Spare parts stay in `stock`.
* Dependencies run only one way: a consumer depends on the master data and never the reverse (0076); a cross-module posting or write line needs
  the other module in the stamp module's own `depends_on` (0082 a), and two modules that depend on each other would break that rule. So every
  option is judged first by its arrow.

## Options

For each: dependency direction, what moves, migration risk, effect on `assets`.

### A. `maintenance` owns equipment state and downtime; `mes_core` reads it

* **Arrow:** `mes_core` depends on `maintenance` (new line in `mes_core`'s `depends_on`, next to `assets`). `maintenance` depends on `assets`,
  `locations`, `org` (and later `stock`) as in the scope draft Q7. `maintenance` does not know `mes_core`.
* **What moves:** the records `equipment_state_change` and `downtime` (and the state field) are written by `maintenance`. MES rows 6 and 11
  shrink to "read the state and downtime, compute OEE on top". OEE and shift logs stay in `mes_core`.
* **Migration risk:** cheap now (the `mes_core` data model of 05 s4.3 is a sketch; change two lines of it). Expensive later only if MES
  ships first with its own records. The real cost is a **product** cost: a tenant that wants production tracking must install a maintenance
  module it may not need (a plant with no maintenance team), and a plain "machine is running/idle/cleaning" production state is not a
  maintenance fact. Production states (running, cleaning, changeover) are the MES owner's vocabulary; forcing them into the CMMS module bends both.
* **Effect on `assets`:** none.

### B. `mes_core` owns equipment state and downtime; `maintenance` reads it

* **Arrow:** `maintenance` depends on `mes_core`. That makes every CMMS customer (buildings, vehicles, utilities, small workshops) install a
  production module, and ties CMMS slice 3 to an unbuilt module whose first usable phase is months away (`mes_core.ex` is an empty shell).
* **What moves:** `equipment`, `equipment_state_change`, `downtime` are built in `mes_core`; CMMS slice 5 (downtime and KPIs) waits for it.
* **Migration risk:** cheap on paper, but it blocks CMMS and the first maintenance customer may not be a manufacturer (scope draft Q1). Not
  recommended: the dependency arrow points from the more general module to the more specific one, against 0076's spirit.
* **Effect on `assets`:** none.

### C. A small shared module for equipment master data and state; both depend on it

* **Arrow:** `maintenance -> equipment_base <- mes_core`, and `equipment_base -> assets, locations`. It follows 0076 exactly: both consumers depend
  on the base and the base depends on neither.
* **What moves:** a new third module (working name `equipment`) holds the equipment extension of the asset card (criticality, meters, hierarchy
  if needed), the state, the state-change history and the downtime record. `maintenance` adds orders, plans and checklists on top; `mes_core`
  adds recipes, batches, production work orders and OEE on top. Both write state through the one module (a posting or write line towards it is
  allowed by 0082 because it is in each one's `depends_on`).
* **Migration risk:** cheapest in data terms, since nothing exists, and the cleanest long-term. The cost is one more module to build, version,
  register and test (every module costs a manifest, permissions, matrix and a pack, roughly size M for the base before CMMS slice 1 can use
  it) and a sequence problem: CMMS slice 1 (work request and order on an asset card) does not need state at all, so the base can be built when
  slice 3 or 5 needs it, but the **decision** must be made now.
* **Effect on `assets`:** the asset card stays the master; the equipment extension lives beside it, not inside it. `assets` is not changed.

### D. The asset card stays the equipment master; each module adds its own records

* **Arrow:** both depend on `assets` only; no arrow between them.
* **What moves:** nothing is shared beyond the card. `maintenance` keeps its downtime; `mes_core` keeps its `equipment_state_change` and
  `downtime`.
* **Migration risk:** cheapest to build today (no coordination), **most expensive later**: one machine gets two state histories, two downtime
  numbers and two "down" reasons. Reconciling them after both are live means a migration, a rule for which wins, and a reporting fix for the
  tenants that installed both. It would also split the "downtime and OEE" story the customer expects to see as one number.
* **Effect on `assets`:** none, but `assets` stays the only link, so any shared fact (criticality, current state) drifts.

## Comparison

| | Who writes state and downtime | Arrow | New module | Cost now | Cost if wrong, later | Blocks CMMS slice 3 |
|---|---|---|---|---|---|---|
| A | `maintenance` | `mes_core -> maintenance` | no | S | M (MES states bent into CMMS) | no |
| B | `mes_core` | `maintenance -> mes_core` | no | S | L (CMMS tied to production) | **yes** |
| C | shared `equipment` module | both -> `equipment` -> `assets` | **yes** | M (+1 module) | S | no (slice 1 to 2 do not need it) |
| D | both, separately | both -> `assets` | no | XS | **L** (merge of two histories on live tenants) | no |

Sizes: XS under a day, S about a day or two, M a few days, L a week or more of team work; proposals, not commitments.

## Recommendation: option C, built lazily

1. **Decide C now, build it when first needed.** Write the rule today: *equipment state, state history and downtime have one owner, a small shared
   module, and neither `maintenance` nor `mes_core` creates its own copy.* The module itself is built only when the first consumer needs it:
   for CMMS that is slice 5 (downtime and KPIs); slices 1 to 4 (requests, orders, assignment, checklists, parts) do not use equipment state and are
   not blocked. So slice 3 does not stall: it needs no state.
2. **Why C and not A:** A is almost as cheap, but it forces every MES customer to install CMMS and puts production vocabulary (running, cleaning,
   changeover) into the maintenance module. C keeps each module's own words and lets either be installed alone.
3. **Why not D:** D is the only option whose cost grows with time. It saves one module now and pays it back as a two-history migration later.
4. **Why not B:** the first CMMS customer may not run production (scope draft Q1), and `mes_core` does not exist yet.
5. **Fallback if the owner will not fund a third module yet:** option A, on the condition that its state record is built in the neutral form of C (no
   CMMS words in it) so it can be lifted out into the shared module later at the price of a module split, not a data migration.
6. **Keep apart in the UI and in code:** "maintenance order" (CMMS) versus "production work order" (`mes_core`); no shared `work_order` record.
7. **What changes in the other documents when the owner agrees** (a follow-up, not done here): the scope draft Q7/Q8 text; rows 6 and 11 of
   `01-domain-and-fit-gap.md` and the record list in `05-platform-options.md` s4.3 (`equipment`, `equipment_state_change`, `downtime` move out of
   `mes_core`); one requirement entry for the shared module written by the BA when slice 5 is planned.

## Open questions this record does not close

* The working name and the exact record list of the shared module (`equipment` collides with MES wording; a name is for the requirement).
* Whether meters and criticality also belong in the shared module or stay in `maintenance` (scope draft Q10, Q13): they are maintenance facts and
  stay in `maintenance` unless MES asks for them.
* Open core or closed package (scope draft Q6, decision 0088 split): which edition the shared module ships in.
* Whether `assets` itself should gain a "current state" column (rejected here: it would put a state history into the master data layer 0076
  keeps small).

## Decided

**D-163 (2026-11-19, decided by the team (PM)): option C.** Equipment state, state history and downtime have ONE owner: a small shared module that both
`maintenance` and the future `mes_core` depend on. It is built only when CMMS slice 5 (downtime and KPIs) needs it; neither `maintenance` nor `mes_core`
creates its own copy. The module NAME is chosen by the architect when slice 5 starts. Meters and criticality STAY in `maintenance` (unless MES asks for them).
Option A is no longer the fallback of record; the recommendation above is the decision.

## Follow-ups (TODO, not done here; those files are not edited by this record)

- [ ] `docs/cmms/scope-draft.md`: rewrite the Q7 and Q8 text to state this decision.
- [ ] `docs/design/mes/01-domain-and-fit-gap.md`: rows 6 ("Equipment and its state") and 11 ("OEE and downtime"): equipment, state and downtime come from the shared module; OEE and shift logs stay in `mes_core`.
- [ ] `docs/design/mes/05-platform-options.md` s4.3: move the records `equipment`, `equipment_state_change`, `downtime` out of `mes_core`; add the shared module to `mes_core`'s `depends_on` (s4.1).
- [ ] One requirement entry for the shared module, written by the BA when CMMS slice 5 is planned (module name chosen then by the architect).
