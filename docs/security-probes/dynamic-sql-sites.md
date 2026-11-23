# Dynamic SQL sites (T-2689)

Scan: `test/letflow/entities/managed_types/stamp_opener_scan_test.exs`, "T-11 real tree 2": non-literal
`Repo.query` / `SQL.query` text is allowed only in the files of `@dynamic_sql_files`. The scan logic, its
threshold and `@dynamic_sql_files` are unchanged by this task.

| file:line | introduced by | why non-literal | how safe | decision |
|---|---|---|---|---|
| lib/letflow/instances/step_log.ex:253 | ad9567025 PILOT G6 (#5037), pilot: yes | fixed information_schema SELECT kept in a local variable | now a string literal in the call; schema bound as `$1`, module-constant table list bound as `$2`; no interpolation | FIXED |

The 22 older files predate the pilot; per-site rows and one safety reason per `@dynamic_sql_files` entry: follow-up task.
