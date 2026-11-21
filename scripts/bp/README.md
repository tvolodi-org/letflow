# The tools of the business-process map

Two tools live here, both Python 3 with the standard library only. The map itself, its schema and
its checks are described in `docs/bp/README.md`.

## The map in plain words (`bp_doc.py`, D-173)

`bp_doc.py` renders `docs/bp/<area>.json` into `docs/bp/<area>.md`: the processes of the area in a
table, then every process in plain words (who may do it, the numbered steps with the screen and the
call of each step, the refusals, the tests, the runner scenario, the status, the gaps), the orphans
and the gaps of the area. The render is deterministic (sorted, no timestamp, no model), so the
committed document must equal it -- `--check` is the gate, and the CI runs it.

| file | what it is |
|---|---|
| `bp_doc.py` | the tool (Python 3, standard library only) |
| `tests/test_bp_doc.py` | the tests (a fixture checkout, a fixture map, a fixture runner report; no network, no database) |

```
python3 scripts/bp/bp_doc.py stock           # write docs/bp/stock.md
python3 scripts/bp/bp_doc.py all             # write every area
python3 scripts/bp/bp_doc.py --check         # the CI gate: the committed .md must equal the render
python3 scripts/bp/bp_doc.py stock --proof /path/to/verdicts   # the Machine-proven column, never committed
python3 -B -m unittest -v scripts/bp/tests/test_bp_doc.py
```

## The dead-code inventory (D-172)

`dead_code.py` lists the public functions of `lib/letflow/` that nothing calls. It is the
function-level extension of the business-process map (`docs/bp/README.md`): `bp_inventory.py`
lists routes, screens, pack nodes, write handlers, scripts and rule files, and a dead context
function is invisible to it.

| file | what it is |
|---|---|
| `dead_code.py` | the tool (Python 3, standard library only) |
| `xref_calls.exs` | the `mix xref` dump of the runtime call graph (run by the tool through `mix run --no-start`) |
| `tests/test_dead_code.py` | the tests (a fixture project and a fixture xref dump; no network, no database) |

```
python3 scripts/bp/dead_code.py                # the report and the counts per area
python3 scripts/bp/dead_code.py --area stock   # one area of the shared table
python3 scripts/bp/dead_code.py --json         # the report as JSON on stdout
python3 scripts/bp/dead_code.py --check        # the CI gate: a NEW dead function fails
python3 -B -m unittest -v scripts/bp/tests/test_dead_code.py
```

The tool needs `mix` (for the call graph) and the three environment variables `config/runtime.exs`
asks for; it generates throwaway values for them when they are not set, and the application is
never started (no database, no secrets). The dump is cached under `_build/dead-code/` (never in the
repository); `--xref-cache` reads that cache instead of running `mix` again.

The report, the allow-list and the baseline are described in `docs/bp/README.md`.
