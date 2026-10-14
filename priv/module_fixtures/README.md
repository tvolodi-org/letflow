# priv/module_fixtures

Test-only pack documents read by test-only fixture modules (registered only in
`config/test.exs`). They live under `priv/` because `Letflow.Modules.Installs`
reads a module's pack from the application's `priv` directory; nothing outside
the `:test` environment references them (same arrangement as `priv/wasm_fixtures`).

* `fk_pair.json` -- GH 2531 / decision 0052 D7: two entity definitions,
  `fkp_parent` and `fkp_child`, the child holding a foreign key to the parent and
  each a unique constraint. Used by `Letflow.Modules.FixtureFkPack` and
  `Letflow.Modules.FixtureFkPackFailing`.
