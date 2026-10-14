# GH 2531: module `on_install/3` activates and promotes, with an installer-supplied rationale

Decision: `docs/migration/decisions/0052-pack-install-activation.md` (Option B, D1-D7).
This note records only the implementation choices the decision left open; it does not
re-decide anything.

## 1. D7 go/no-go: GO

`test/letflow/modules/install_activation_test.exs` installs a two-entity FK test pack
(`priv/module_fixtures/fk_pair.json`: `fkp_parent` <- `fkp_child`, a foreign key and a
unique constraint each) through `Installs.install/3`:

* (a) after commit both `entity_fkp_*` tables exist, `entity_fkp_child` carries the
  `REFERENCES` constraint to `entity_fkp_parent`, both have unique constraints, both
  definitions are `:active`, no promotion row is `pending`/`ddl_failed`;
* (b) a fixture that activates and promotes, THEN fails, leaves no table, constraint,
  definition, `entity_column_promotions` row or `tenant_modules` row.

`activate_definition/4`'s own transactions and `run_column_promotion/1`'s DDL run nested in
the install transaction on the same connection and roll back with it, so D2 holds and
Alternative C is not needed.

## 2. Platform change (0052 D3)

| Touch point | Change |
|---|---|
| `Letflow.Modules.Module` | optional `on_install/3 (prefix, settings, ctx)`, `@type install_ctx`; `@optional_callbacks ... on_install: 3` |
| `Installs.install/3` | `opts[:rationale]` REQUIRED; `fetch_rationale/1` (public, shared): missing / non-string / blank after trim -> `{:error, :rationale_required}` before any write; the value is passed VERBATIM (not trimmed) in `ctx`. `on_install/3` preferred; if both arities are exported only `/3` runs |
| `Solutions.install/3` | checks the rationale first (nothing read or written without one); the same `opts` (one rationale) reach every `Installs.install/3` |
| `POST /tenant/modules`, `POST /tenant/solutions` | body `rationale` passed through unchanged; `:rationale_required` -> 422 `rationale is required`; never synthesised. BREAKING for callers that omit it (SPA: none) |
| `mix letflow.seed.exam_fixtures` | fixed reviewed constant `@install_rationale "seed: exam fixtures (mix letflow.seed.exam_fixtures)"` |
| guide `adding-an-application-module.md` | `on_install/3`, the required rationale, new section 5a |

## 3. Shared helper (0052 "a shared helper under `Letflow.Modules` is allowed")

`Letflow.Modules.EntityActivation.activate_and_promote(prefix, ctx, names)`, `names` in the
pack's FK-DAG order as stated by the module (the order is pack content; not computed). Per
name: D6 check, activate (or skip if already active), promote every `DDL.promoted_columns/1`
column without a promotion row (`register_column_promotion/4` + `run_column_promotion/1`,
same column spec as `Entities.Definitions.ensure_column_promotions/2`); then the D5 check
over ALL `entity_column_promotions` rows of this tenant for these types.

**D6 rule as implemented.** Entity definitions record no origin (no pack/module field;
verified), and the pack inserts its rows inside the same install transaction just before
`on_install/3`. So "this module's own inactive definition" = the tenant holds exactly ONE
row of that name. Zero rows -> `{:entity_definition_missing, name}`; more than one row (a
tenant-created or earlier definition of the same name, active or not) ->
`{:entity_name_conflict, name}`; one `:active` row -> skip activation. Verified by test: a
tenant-created active `fkp_parent` makes the install return exactly
`{:error, {:on_install_failed, {:entity_name_conflict, "fkp_parent"}}}`, the tenant's
definition untouched.

Errors: `{:entity_definition_missing, n}`, `{:entity_name_conflict, n}`,
`{:activation_failed, n, reason}`, `{:promotion_failed, n, attr, reason}`,
`{:promotion_incomplete, [{type, attr, status}]}`, `:invalid_schema_name`; all surface as
`{:on_install_failed, reason}` from `Installs.install/3` and roll back.

## 4. Test fixtures

* `priv/module_fixtures/fk_pair.json` (+ README): a test-only pack under `priv/` because
  `Installs` reads packs from the app's `priv` dir; precedent `priv/wasm_fixtures`.
* `priv/solutions/fixture-activation-bundle.json`: precedent `priv/solutions/fixture-bundle.json`.
* `test/support/modules/fixture_fk_pack/fixture_fk_pack.ex`: `FixtureFkPack` (both arities;
  `/2` only records that it ran), `FixtureFkPackFailing` (activates + promotes, then fails),
  `FixtureCtxRecorder` (records `ctx`). Registered only in `config/test.exs`.

## 5. Out of scope (0052)

The real org/catalog/procurement packs; process-definition activation (D4); entity
definition upgrade via pack update; any change to `solution_pack.ex`, the pack schema or
exam (exam keeps `on_install/2`, now installed with a rationale like every module).
