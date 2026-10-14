# 0052 -- Pack install and activation: handle entity-definition activation and FK promotion in each module's on_install for the org, catalog and procurement packs; do not make SolutionPack.install activate

Status: Accepted: ruled by the user's advisor session (letflow-ec) under the user's delegation, recorded by the supervisor; the user accepted the core changes in principle 2026-10-14. Acceptance of D2 is conditional on the D7 transaction test; otherwise Alternative C applies.
Rulings applied: OP1 (installer-supplied rationale; fixed reviewed constant only for internal non-HTTP callers) per advisor session letflow-ec, Q9, relayed by the supervisor 2026-10-14. Open points 1 and 4 are removed as resolved (4: rejected in text); remaining numbers are kept. Nothing here changes code or a prior record until implemented through the pipeline.

Date: 2026-10-14. Drafted by `ORCH` (docs only). Question relayed by the supervisor from the user's advisor, 2026-10-14.

Touches, by reference only (none is edited): `0026-solution-pack-entity-definitions-section.md` (section 2, install is `:inactive`-only), `0029-solution-pack-scripted-rules-and-role-seeding-scope.md` (pack section set closed), `0039-platform-module-solution-layering.md` (D5, module install), `0046-admin-scopes-and-role-charter.md` (`:ModulesManage` is tenant scope), and the sibling draft 0050 (entity-type prefix rule, D6).

## Context

The WMS draft slice (REQ-473..489, unregistered) needs three packs (org, catalog, procurement) whose entity types are writable straight after install, and whose unique constraints are real database constraints. The three packs declare NO foreign keys in slice 1 (0050 D3.6: references are declarative-only, so there is no `ON DELETE RESTRICT` backstop); FK promotion machinery is still described below for a later slice and for the D7 test. A packed entity definition installs `:inactive`, and `Records.create_record/2` returns `{:error, {:definition_not_found, entity_type}}` until a definition is `:active` (`priv/modules/exam/README.md:139-142`). The advisor asks: "install-activates first, or handled in on_install for these packs".

Facts verified in the tree:

1. `SolutionPack.install/3` makes no `activate_definition/4` call, by decision: `lib/letflow/definitions/solution_pack.ex:1587-1589`; rationale in 0026 section 2 (`0026-solution-pack-entity-definitions-section.md:205-222`): no other pack artefact type is auto-activated. Process definitions arrive as DRAFT (`lib/letflow/definitions.ex:45`, `:552`) and activate through `Definitions.activate/2` (`:750`), route `POST /definitions/:id/activate` under `:DefinitionsActivate` (`lib/letflow/routers/definitions.ex:259`; `lib/letflow/api/authorization.ex:668`).
2. What exam does today: nothing at install. Its `on_install/2` only seeds `entity_field_restrictions` (`lib/letflow/modules/exam/exam.ex:96-120`). Activation and promotion are documented as separate manual steps in DAG order (`priv/modules/exam/README.md:125-170`). No seed task calls `activate_definition`.
3. `Installs.install/3` runs pack install, `tenant_modules` insert and `on_install/2` in ONE `Repo.transaction/1`; any failure rolls back (`lib/letflow/modules/installs.ex:73-87`, moduledoc `:24-28`). `on_install` is called as `on_install(prefix, settings)` and receives NO actor (`installs.ex:238-241`), although `install/3` has `actor_id` (`:73`).
4. `activate_definition(name, activator_user_id, rationale, prefix)` needs a user id and a non-blank rationale (`lib/letflow/entities/definitions.ex:411`). Blank rationale is rejected by `ActivationGroup.changeset/2` and a DB `CHECK (rationale <> '')`; the router refuses to synthesise one because the rationale is REPO-10's free-text justification in an append-only trail (`lib/letflow/routers/entities.ex:672-690`).
5. **Activation does NOT create tables or FK constraints.** After promoting the target row and demoting siblings (`definitions.ex:376-393`, `:439-459`) it calls `ensure_column_promotions/2` (`:428`, `:482-518`), which promotes ONLY columns named in a `constraints` entry (the `constrained_field_names` filter) and ALWAYS returns `:ok`: a promotion left `pending` or `ddl_failed` is logged and recorded in `entity_column_promotions.status/last_error`, never failing activation (`:474-481`, `:575-590`). Exam README: "Activation alone creates no table" (`README.md:139-170`).
6. **FK promotion is a separate, third step**: `TenantProvisioning.register_column_promotion/4` (`lib/letflow/tenant_provisioning.ex:1419`) then `run_column_promotion/1` (`:1485`). This creates the per-entity-type table with real `REFERENCES` clauses. Its DAG order (FK targets before referrers) is a PROMOTION order; the wrong order fails with Postgres `42P01` (`README.md:146-170`). `{:ddl_failed, exception}` comes from `tenant_provisioning.ex:1531`; repair is `retry_failed_column_promotion/1` (`:1288-1289`).
7. Who may do what: install needs `:ModulesManage` (`lib/letflow/routers/tenant_modules.ex:40`), held by `PLATFORM_ADMIN` and `TENANT_ADMIN` only (`docs/roles.md:110`). Entity activation needs `:EntitiesDefinitionsWrite` (`routers/entities.ex:257`), held by `PLATFORM_ADMIN`, `PROCESS_DESIGNER` and `TENANT_ADMIN` (`docs/roles.md:98`). Holders of the first are a subset of holders of the second.
8. Pack update (3-way) does not cover entity definitions: `solution_pack.ex:1470`. An upgrade path: NOT FOUND.
9. The org, catalog and procurement packs: NOT FOUND (`priv/modules/` contains only `exam`).
10. `activate_definition/4` on a name that already has an active definition demotes it (`definitions.ex:376-393`); on tenant-created types of the same name this silently supersedes the tenant's definition (see 0050 D6).

## Decision

Option B, with one opt-in platform hook (additive in the Elixir behaviour; NOT additive for the HTTP contract, D3).

**D1. `SolutionPack.install/3` stays `:inactive`-only.** 0026 section 2 and 0029 are not reopened. This record adds no pack section and no "activate" flag (0053 proposes a pack section separately, under its own record).

**D2. Activation AND promotion are done by the module's reviewed `on_install`**, in the pack's FK-DAG order, inside the same install transaction (a failure rolls back the pack, `installs.ex:77-87`). For each entity type in DAG order it must (a) call `activate_definition/4`, then (b) register and run the column promotion (`register_column_promotion/4`, `run_column_promotion/1`) so the table and its constraints exist. In slice 1 the three packs have no FKs (0050 D3.6), so promotion is still needed for their unique constraints (fact 5: only constrained columns promote) and the FK-before-referrer ordering applies only once a later slice adds FKs. Activation alone is not enough (facts 5, 6). If a module chooses not to promote, the record of that module must say which constraints stay absent (0050 D3.2: no hard delete then rests on the `managed_by` lock and module code only). `on_install` is reviewed code, not pack content (`docs/guides/adding-an-application-module.md:389-390`, 0039).

**D3. The platform change, additive, with its full touch-point list.** `Installs` accepts an optional `on_install/3` `(prefix, settings, ctx)` with `ctx = %{actor_id: actor_id, rationale: text}`, preferred over `on_install/2` when exported; if both arities are exported ONLY `/3` runs (a test pins that both are never called). Touch points:
* `lib/letflow/modules/installs.ex:82` (the call site) and `:238-241` (`maybe_run_on_install`);
* `Installs.install/3` (`installs.ex:73`): today `install(module_id, actor_id, opts)` with only
  `:prefix` read from `opts`; it has no rationale parameter. The rationale is added as an
  `opts` key (e.g. `:rationale`) or a new argument and passed into `ctx`; the `@spec` changes;
* the install route and request body: `lib/letflow/routers/tenant_modules.ex:53-58`
  (`handle_install/1` matches only `%{"module_id" => module_id}` and calls
  `Installs.install(module_id, actor_id, prefix: prefix)`). It gains a `rationale` body field
  (non-blank string; a blank or missing value is a 4xx, never a synthesised default) plus API
  docs and tests. **This is a breaking HTTP contract change, not an additive one**: the field is REQUIRED on
  the install and solution-install routes for ALL modules, including ones that only have `on_install/2`
  (exam) and never use it, so every existing caller that omits it starts failing. The SPA has no caller
  (REVIEWER pass 3: no use of the install route under `web/src`); tests and any external clients do and
  must be updated;
* `lib/letflow/modules/module.ex:77-79` (`@callback`, and `@optional_callbacks` gains `on_install: 3`) and its moduledoc `:25-34`;
* `docs/guides/adding-an-application-module.md:54, 194-198, 389-390` (document the new arity);
* exam is unaffected: it exports only `on_install/2` (`exam.ex:96-120`) and the fallback keeps it working.

Actor and rationale (OP1 RULED: INSTALLER-SUPPLIED): the installer's id is used as `activator_user_id` (no system or nil actor).
* The install route (`POST` in `lib/letflow/routers/tenant_modules.ex:53-58`) AND the solution-install route
  (`lib/letflow/routers/tenant_solutions.ex:39`, which calls `Solutions.install/3`, which loops
  `Installs.install/3` over its modules, `lib/letflow/modules/solutions.ex:209-215`) REQUIRE a non-blank
  `rationale`. A blank or missing value is a 4xx. A solution install applies ONE rationale to EACH module it
  installs (so `Solutions.install` gains the same parameter and passes it into every `Installs.install` call).
* Internal non-HTTP callers pass a FIXED, code-reviewed constant that names the cause (for example
  "seed: exam fixtures"); found caller: `lib/mix/tasks/letflow.seed.exam_fixtures.ex:181`. Other non-HTTP
  callers: none found by `grep "Installs.install("` in `lib` outside design docs.
* The router NEVER synthesises a rationale. The append-only trail keeps a human justification
  (`routers/entities.ex:672-690` is the precedent).
* Added touch points: `lib/letflow/routers/tenant_solutions.ex:39`, `lib/letflow/modules/solutions.ex:211`
  (and `Solutions.install/3`'s spec), `lib/mix/tasks/letflow.seed.exam_fixtures.ex:181`.

**D4. Only entity definitions are activated here.** Process definitions stay DRAFT until a `:DefinitionsActivate` holder activates them; activation also runs graph and semantic validation that can reject, a design review step (`routers/definitions.ex:954-1000`, not independently confirmed). Revisit under its own record if a pack needs one.

**D5. Promotion failure is surfaced, not hidden.** `ensure_column_promotions/2` never fails (fact 5), and `run_column_promotion/1` failures are recorded, not raised. After activating and promoting, `on_install` MUST read `entity_column_promotions` for EVERY promotion it registered or ran (constraint columns today, FK columns once a later slice adds them) and return `{:error, ...}` if any row is not complete (`ddl_failed` or `pending`), so the install rolls back rather than leaving a writable-but-unconstrained type.

**D6. Preconditions and idempotency.**
* Install FAILS rather than activating over an existing same-name definition: before activating, `on_install` checks (`get_definition_by_name/2`, `definitions.ex:215`) that no definition of that name exists unless it is this module's own inactive one (verified: `get_definition_by_name/2` has no status filter; it returns the single newest row of that name by `inserted_at`, `id`, whatever its status, so the check must compare that row's status and origin), and returns `{:error, {:entity_name_conflict, name}}` otherwise. Together with the 0050 D6 prefix rule this keeps tenant-created types safe.
* `on_install` runs only on first install (`check_not_already_installed`, `installs.ex:76`). `activate_definition` on an already-active definition is not shown to be a no-op for the entity path, so module code checks status first and skips an active definition.
* Upgrade: no entity-definition upgrade path (fact 8); a later pack version that changes an entity definition needs its own record.

**D7. Transaction behaviour must be proven by a test (requirement).** `activate_definition/4` runs its own internal transaction and `run_column_promotion/1` executes DDL and locks, all nested inside the install transaction. Whether promotion sees uncommitted rows and whether DDL rolls back with the install is not shown anywhere. A test MUST install a two-entity FK TEST pack (a fixture; the three real packs have no FKs in slice 1) through `Installs.install/3` and assert (a) after commit the tables and `REFERENCES` constraints exist, and (b) after a forced failure in `on_install`, no table, constraint, definition or `tenant_modules` row remains. If either assertion fails, D2 is invalid and Alternative C (manual DAG order) is the fallback.

## Alternatives considered

**A. Install activates (platform change in `SolutionPack.install/3`).** For: one place, no per-module code. Against:
* Reverses 0026 section 2 for every pack including exam (`README.md:125-142`), changing the meaning of "pack installed" for one artefact type only.
* Blast radius is global: every tenant's every install of any pack would run activation and promotion DDL inside the shared install transaction, with no per-pack opt-out short of a new pack-document flag (reopens the closed section set, 0029).
* `SolutionPack.install/3` has an `actor_id` but no rationale source; it either synthesises one (rejected for the compliance trail, `routers/entities.ex:686-690`) or the pack carries tenant-supplied text into the audit trail.
* The FK-DAG order is pack content; the installer would need a topological sort of `foreign_keys`, logic that does not exist (NOT FOUND).
* (Not a factor: permission widening. `:ModulesManage` holders are a subset of `:EntitiesDefinitionsWrite` holders, fact 7.)

**B. (Chosen, conditional on D7) Module `on_install` activates and promotes, plus the optional `on_install/3` hook (D2, D3).**

**C. Status quo: a separate, manual activate-and-promote step.** Smallest code, what exam does. Rejected for these packs only because the WMS slice needs writable, constrained types right after install and the manual DAG order fails opaquely (`README.md:146-148`). It is also the fallback if D3 or D7 fails.

## Consequences

* Platform change: `installs.ex`, `module.ex` and the install route/request body in `tenant_modules.ex` (D3) plus the guide; additive for the Elixir behaviour (`on_install/3` is optional), but NOT additive for the HTTP contract: the new required `rationale` field breaks every caller of the install and solution-install routes that omits it (D3). No change to `solution_pack.ex`, to any decision's text, to the pack schema, or to exam.
* Each of the three modules repeats activate-promote-in-order and the promotion check; a shared helper under `Letflow.Modules` is allowed but is a design-step choice.
* The audit trail records the installer as activator with the installer-supplied rationale of D3; the solution-install route and the exam seed task change too.
* `on_install` runs DDL inside the install transaction; failure rolls back the whole module install, and a module that returns an error blocks install until the cause is fixed.
* No permission widening: `:ModulesManage` holders already hold `:EntitiesDefinitionsWrite` (fact 7).
* 0050 slice 0 depends on this mechanism for activated, promoted types.

## Consistency

* 0026 section 2 and 0029: unchanged; the pack path stays `:inactive`-only and section-closed.
* 0039: `on_install` as reviewed module code is the extension point it defines (D5 there).
* 0046: no new permission atom, no scope change.
* 0050: the D6 prefix rule is a precondition of D6 here. Slice 1 has no FKs (0050 D3.6), so no FK backstop depends on D2; D2 promotion serves unique constraints.
* 0004: no human gate introduced.

## Open points


2. Entity-definition upgrade through pack update: NOT FOUND; separate record.
3. Process-definition activation for the three packs (D4): not decided.
4. (Closed: reading the actor from `settings` instead of `on_install/3` is rejected, settings are tenant-writable via `PUT /tenant/modules/:module_id/settings`, `routers/tenant_modules.ex:44`. Number kept.)
5. Whether `activate_definition/4` on an already-active entity definition is a no-op or an error: not read; D6 assumes the worse case.
6. D7 test outcome decides D2 versus Alternative C (acceptance of D2 is conditional on it, see Status).

(Former open point on `:ModulesManage` vs `:EntitiesDefinitionsWrite` holders is closed by fact 7.)

## Sign-off

REVIEWER:
