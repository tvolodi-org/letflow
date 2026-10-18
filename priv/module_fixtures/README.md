# priv/module_fixtures

Test-only pack documents read by test-only fixture modules (registered only in
`config/test.exs`). They live under `priv/` because `Letflow.Modules.Installs`
reads a module's pack from the application's `priv` directory; nothing outside
the `:test` environment references them (same arrangement as `priv/wasm_fixtures`).

* `fk_pair.json` -- GH 2531 / decision 0052 D7: two entity definitions,
  `fkp_parent` and `fkp_child`, the child holding a foreign key to the parent and
  each a unique constraint. Used by `Letflow.Modules.FixtureFkPack` and
  `Letflow.Modules.FixtureFkPackFailing`.
* `managed_foundation.json` -- REQ-496 / decision 0050 D7: eight entity definitions
  (the six 0050 foundation names, `fxm_ledger` with `append_only: true`, and the
  unmanaged control `fxm_free`), each with one `name` string field. Used by
  `Letflow.Modules.FixtureManaged`, whose manifest declares the first seven in
  `manages_entity_types`.
* `ledger_foundation.json` -- GH #2590 / REQ-501 R2: the two managed entity definitions of
  `Letflow.Modules.FixtureLedger` (`fxl_ledger`, append-only, and `fxl_balance`) and the
  process definitions `fxl_post` (START -> END, no `module_writes`), plus (R3) `fxl_post_module`,
  `fxl_post_mixed` and `fxl_task_plain` (HUMAN_TASK nodes with, with both, and without
  `module_writes`), so a module install
  creates a process definition version that is stamped with its owner.
* `ledger_rogue.json` -- GH #2590 / REQ-501 R4a: the one managed entity definition `fxr_thing` of
  `Letflow.Modules.FixtureLedgerRogue`, a module whose handlers misbehave on purpose (negative
  controls for `Letflow.Entities.HandlerWrites` and the handler-purity scan H4). `ledger_foundation.json`
  gained an optional `quantity` integer field on both entity types in R4a. R4b: `ledger_rogue.json` also ships one
  STAMPED process definition per rogue handler (`fxr_<handler>`, a single HUMAN_TASK `ht` with one
  `module_writes` line) so the engine tests can drive each misbehaviour; that file is GENERATED (keys
  sorted by the generator), not hand-edited, so regenerate it rather than patching the JSON.

* R5 (GH #2590): `ledger_foundation.json` also ships stamped SERVICE_TASK definitions `fxl_svc_module`, `fxl_svc_mixed`, `fxl_svc_mixed_first` and `fxl_svc_two_handlers` (node `svc`, an HTTP endpoint that is never called: the tests apply the result with `Engine.advance_after_service_task_outcome/4`), and `ledger_rogue.json` ships `fxr_svc_<handler>` for `throws`, `exits`, `drop_policy` and `denies`. No generator is committed for `ledger_rogue.json`: its entries are key-sorted, 2-space JSON; the R5 `fxr_svc_*` entries were produced by a one-off script in that same layout (existing bytes unchanged apart from the R5 entries). Edit it by hand in that layout.

* `scoped_foundation.json` -- REQ-518 / GH #2535: four entity definitions for `Letflow.Modules.FixtureScoped` (`scoped_item`, `scoped_child` with an fk to `scoped_item`, `scoped_master`, and the managed `scoped_managed_item`), each with a string `scope_node` column where the module declares one. The module is on the test-only `:scope_declaration_unmanaged_modules` allowlist.
