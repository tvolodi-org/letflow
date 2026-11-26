# Dynamic SQL sites (T-2689, per-site table by T-2693)

Scan: `test/letflow/entities/managed_types/stamp_opener_scan_test.exs`, "T-11 real tree 2": non-literal
`Repo.query` / `SQL.query` text is allowed only in the files of `@dynamic_sql_files`. The scan logic, its
threshold and `@dynamic_sql_files` are unchanged by this task.

## How this table was produced (T-2693)

The scan's OWN helpers were run over the real tree: the enumeration script of the T-2693 task folder
(`state/tasks/T-2693/enumerate_sites.exs` in the team repository) reads the test module, evaluates it
(its `defp` helpers become callable) and calls `real_files/0`, `dynamic_sql_files/1` and
`dynamic_sql_violations/1` on the result.
The line numbers below are the lines of `origin/main` at `625e7d9a3` (the merge base this change was
built on); the table was re-derived on that tree after the merge of `origin/main`, and it is the
same 67 sites as before the merge. On that tree:

- `dynamic_sql_violations/1` returns `[]` — no dynamic-SQL site outside `@dynamic_sql_files`;
- `dynamic_sql_files/1` finds **22 files**, and the per-site walk finds **67 sites** in exactly those
  files (the two file sets are equal);
- the 23rd entry of `@dynamic_sql_files`, `lib/letflow/entities/managed_types/stamp.ex`, holds only
  literals and is therefore not found by the scan.

"introduced by" is the `git blame` of the site line (the commit that last wrote it); the pilot column
answers whether that commit is a pilot task. **No site below was introduced by a pilot task** (the
blamed commits of the 67 sites and the `PILOT` commits of the history do not intersect). The one
pilot-introduced site was `lib/letflow/instances/step_log.ex` (PILOT G6) — FIXED, see the last section.

### Legend

- **why non-literal** — why the SQL text is not a compile-time string literal.
- **how safe** — the mechanism that keeps the text free of user input.
  - **(M)** module-attribute constant only: the whole text comes from a module attribute whose value
    is a compile-time constant.
  - **(I)** quoted identifier: an identifier is interpolated inside `"..."`; its value is a
    server-derived name (tenant schema, table, partition, column, constraint), never request text.
  - **(B)** bound parameters: every value is passed as `$1`, `$2`, …
  - **(F)** Postgres `format('%I'/'%L')`: the statement text is produced by Postgres itself from
    bound values.
- **decision** — `LISTED` (the site stays in `@dynamic_sql_files`, with the reason below) or `FIXED`
  (the site was made a literal and is no longer listed).

## The sites

### lib/letflow/engine.ex (4 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/engine.ex:4143` | `53ad1cd9d` REQ-499 PR B2 (#2645) | no | the statement is held in the module attribute `@entity_write_set_lock_timeout` | (M) the attribute's value is the fixed literal `SET LOCAL lock_timeout = '2s'` (engine.ex:3744); nothing is interpolated | LISTED |
| `lib/letflow/engine.ex:4144` | `53ad1cd9d` REQ-499 PR B2 (#2645) | no | the same, `@entity_write_set_statement_timeout` | (M) the fixed literal `SET LOCAL statement_timeout = '5s'` (engine.ex:3745) | LISTED |
| `lib/letflow/engine.ex:6869` | `3d1579bb6` REQ-499 PR C2 (#2674) | no | the same attribute, read in the service-task dispatch path | (M) the same constant as :4143 | LISTED |
| `lib/letflow/engine.ex:6870` | `3d1579bb6` REQ-499 PR C2 (#2674) | no | the same attribute | (M) the same constant as :4144 | LISTED |

### lib/letflow/entities/record/live_projection.ex (1 site)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/entities/record/live_projection.ex:149` | `dbf90e388` phase B P22 (#3745) | no | the per-entity-type UPSERT is assembled by `build_upsert_sql/4` (column list + placeholders) | (I)+(B) the table name comes from `table_name_for_entity_type/1` and is checked by `DDL.valid_identifier?/1` (live_projection.ex:106-108); the column names are the registered structural and promoted columns, each quoted as `"..."`; every value is bound ($1…) in `all_values` | LISTED |

### lib/letflow/entities/record/projector.ex (2 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/entities/record/projector.ex:360` | `4e45baffa` REQ-297 (#1180) | no | the DELETE names the per-entity-type table | (I) `prefix` is the tenant schema, `table_name` is checked by `DDL.valid_identifier?/1` (projector.ex:356-358, raises otherwise); both quoted; no values | LISTED |
| `lib/letflow/entities/record/projector.ex:434` | `4e45baffa` REQ-297 (#1180) | no | the INSERT is assembled per entity type (column list + placeholders) | (I)+(B) the columns are the registered structural and promoted columns of the tenant's active definition, each quoted; every value is bound ($1…) | LISTED |

### lib/letflow/entities/step_writes.ex (2 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/entities/step_writes.ex:182` | `14c2f99cf` GH #2587 REQ-499 PR A3 (#2631) | no | the statement is held in the attribute `@set_lock_timeout` | (M) the attribute's value is `SET LOCAL lock_timeout = '#{@prepare_lock_timeout}'` and `@prepare_lock_timeout` is the constant `"2s"` (step_writes.ex:124-129) | LISTED |
| `lib/letflow/entities/step_writes.ex:183` | `14c2f99cf` GH #2587 REQ-499 PR A3 (#2631) | no | the same, `@set_statement_timeout` | (M) the same shape, `@prepare_statement_timeout` = `"2s"` (step_writes.ex:125) | LISTED |

### lib/letflow/event_store/partition_maintenance.ex (14 sites)

All fourteen were introduced by `b10d9dce5` REQ-376 (#1717), pilot: no.

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/event_store/partition_maintenance.ex:191` | `b10d9dce5` REQ-376 (#1717) | no | `CREATE TABLE … PARTITION OF … FOR VALUES FROM … TO …` | (I) a `FOR VALUES` clause cannot take bind parameters (the module's own note, lines 179-187), so the month bounds are inlined; they come from `month_bounds/2` over this module's own validated year/month integers; the schema, parent and partition names are quoted | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:531` | `b10d9dce5` REQ-376 (#1717) | no | `ALTER TABLE … DETACH PARTITION … CONCURRENTLY` | (I) the schema and the partition name (this module's own `events_<year>_<month>` name) are quoted; no values | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:547` | `b10d9dce5` REQ-376 (#1717) | no | `ALTER TABLE … DETACH PARTITION …` of the default partition | (M)+(I) the partition name is the module constant `@default_partition_name` ("events_default", line 540); the schema is quoted | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:566` | `b10d9dce5` REQ-376 (#1717) | no | `ALTER TABLE … ATTACH PARTITION … DEFAULT` | (M)+(I) the same constant and the same quoted schema | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:595` | `b10d9dce5` REQ-376 (#1717) | no | `ALTER TABLE … DETACH PARTITION … FINALIZE` | (I) the schema and the partition name are quoted; no values | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:614` | `b10d9dce5` REQ-376 (#1717) | no | `ALTER TABLE … ADD CONSTRAINT … CHECK (created_at >= … AND created_at < …) NOT VALID` | (I) a CHECK expression cannot be bound (the module's own note, lines 608-611), so the bounds are inlined; they are this module's own year/month integers, the constraint name is derived from the partition name; both quoted | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:619` | `b10d9dce5` REQ-376 (#1717) | no | `ALTER TABLE … VALIDATE CONSTRAINT` | (I) the schema, partition and constraint names are quoted; no values | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:674` | `b10d9dce5` REQ-376 (#1717) | no | `ALTER TABLE … ATTACH PARTITION … FOR VALUES FROM … TO …` | (I) the same shape as :191 — the bounds are this module's own year/month integers, the identifiers are quoted | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:685` | `b10d9dce5` REQ-376 (#1717) | no | `ALTER TABLE … ADD COLUMN archived_at … DEFAULT '…'` | (I)+(M) a column default cannot be bound; the value is the server's own clock snapshot formatted as a literal (never request text, the module's note at 662-670); the partition name is quoted | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:710` | `b10d9dce5` REQ-376 (#1717) | no | `ALTER TABLE … DROP CONSTRAINT` | (I) the schema, partition and constraint names are quoted; no values | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:749` | `b10d9dce5` REQ-376 (#1717) | no | the reconciliation SELECT is assembled per schema | (I)+(B) the schema and the table name are quoted; the two bounds and the batch size are bound ($1, $2, $3) | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:784` | `b10d9dce5` REQ-376 (#1717) | no | the relocation INSERT is assembled per schema | (I)+(B) the schema and both table names are quoted; the event ids and timestamps are bound ($1, $2) | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:789` | `b10d9dce5` REQ-376 (#1717) | no | the relocation DELETE is assembled per schema | (I)+(B) the same quoted identifiers; the event ids and timestamps are bound ($1, $2) | LISTED |
| `lib/letflow/event_store/partition_maintenance.ex:866` | `b10d9dce5` REQ-376 (#1717) | no | the protected-row count is assembled per schema | (I)+(B) the schema and the partition name are quoted; the event types are bound ($1) | LISTED |

### lib/letflow/event_store/retention_operations.ex (9 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/event_store/retention_operations.ex:396` | `2b2d966e9` ISS-0873 (#1920) | no | the SAVEPOINT name is a module attribute | (M) `@savepoint_name` is the constant "retention_count_protected_rows" (line 393) | LISTED |
| `lib/letflow/event_store/retention_operations.ex:399` | `5a80be400` REQ-377 (#1720) | no | the protected-row count is assembled per schema | (I)+(B) the schema is the provisioned tenant schema, the table is this module's own literal ("events" / "events_archive", the caller at lines 352-353); both quoted; the event types are bound ($1) | LISTED |
| `lib/letflow/event_store/retention_operations.ex:404` | `2b2d966e9` ISS-0873 (#1920) | no | the RELEASE SAVEPOINT name is a module attribute | (M) the same constant as :396 | LISTED |
| `lib/letflow/event_store/retention_operations.ex:410` | `2b2d966e9` ISS-0873 (#1920) | no | the ROLLBACK TO SAVEPOINT name is a module attribute | (M) the same constant as :396 | LISTED |
| `lib/letflow/event_store/retention_operations.ex:411` | `2b2d966e9` ISS-0873 (#1920) | no | the RELEASE SAVEPOINT name is a module attribute | (M) the same constant as :396 | LISTED |
| `lib/letflow/event_store/retention_operations.ex:447` | `2b2d966e9` ISS-0873 (#1920) | no | the SAVEPOINT name is a module attribute | (M) `@isolation_savepoint_name` is the constant "retention_summary_isolation" (line 444) | LISTED |
| `lib/letflow/event_store/retention_operations.ex:449` | `2b2d966e9` ISS-0873 (#1920) | no | the RELEASE SAVEPOINT name is a module attribute | (M) the same constant as :447 | LISTED |
| `lib/letflow/event_store/retention_operations.ex:455` | `2b2d966e9` ISS-0873 (#1920) | no | the ROLLBACK TO SAVEPOINT name is a module attribute | (M) the same constant as :447 | LISTED |
| `lib/letflow/event_store/retention_operations.ex:456` | `2b2d966e9` ISS-0873 (#1920) | no | the RELEASE SAVEPOINT name is a module attribute | (M) the same constant as :447 | LISTED |

### lib/letflow/identity.ex (1 site)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/identity.ex:1816` | `2a29b162f` GH #2547 (#2570) | no | the timeout value is interpolated into the statement | (M) `@sync_lock_timeout` is the constant `"2s"` (identity.ex:121); nothing else is interpolated | LISTED |

### lib/letflow/identity/pending_admin_grants.ex (1 site)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/identity/pending_admin_grants.ex:614` | `2fb6f1a4b` ISS-1030 PR2 (#2493) | no | the timeout value is interpolated into the statement | (M) `@lock_timeout` is the constant `"2s"` (pending_admin_grants.ex:56); nothing else is interpolated | LISTED |

### lib/letflow/ledger/storage/ddl.ex (1 site)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/ledger/storage/ddl.ex:99` | `58a723fd9` phase B P10 (#3760) | no | the DDL text is produced by Postgres `format()` and run as it comes back | (F) Postgres builds the statement from bound values with `%I` (quoted identifiers, ddl.ex:89-99); the Elixir side interpolates nothing | LISTED |

### lib/letflow/module_upgrade/apply.ex (2 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/module_upgrade/apply.ex:219` | `79ee2d190` REQ-770 (#3972) | no | the timeout value is interpolated into the statement | (M) `@lock_timeout` is the constant `"10s"` (apply.ex:56); nothing else is interpolated | LISTED |
| `lib/letflow/module_upgrade/apply.ex:220` | `79ee2d190` REQ-770 (#3972) | no | the same, for the statement timeout | (M) `@statement_timeout` is the constant `"120s"` (apply.ex:57) | LISTED |

### lib/letflow/module_upgrade/rollback.ex (2 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/module_upgrade/rollback.ex:181` | `80cd66654` RU-S5 (#4090) | no | the timeout value is interpolated into the statement | (M) `@lock_timeout` is the constant `"10s"` (rollback.ex:50); nothing else is interpolated | LISTED |
| `lib/letflow/module_upgrade/rollback.ex:182` | `80cd66654` RU-S5 (#4090) | no | the same, for the statement timeout | (M) `@statement_timeout` is the constant `"120s"` (rollback.ex:51) | LISTED |

### lib/letflow/modules/locations/tree.ex (2 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/modules/locations/tree.ex:513` | `a9b6d5ed2` GH #3588 REQ-646 (#3639) | no | the recursive subtree query is assembled by `subtree_sql/2` | (I)+(B) the prefix must match `@prefix_re` (`\A[a-z0-9_]+\z`, tree.ex:244, checked inside `subtree_sql/2`, line 540) and is quoted; the `extra` clause is a fixed literal of the caller; the node id is bound as $1 (dumped uuid) | LISTED |
| `lib/letflow/modules/locations/tree.ex:524` | `a9b6d5ed2` GH #3588 REQ-646 (#3639) | no | the same, with the fixed clause `AND l.field_values->>'active' = 'true'` | (I)+(B) the same quoted prefix and the same bound node id | LISTED |

### lib/letflow/ordering/metrics.ex (1 site)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/ordering/metrics.ex:50` | `0c9cfb158` REQ-199 (#761) | no | the lag query is assembled with the tenant prefix | (I) the prefix is the provisioned tenant schema the scheduler hands to the ordering cycle (`Keyword.fetch!(:prefix)`, metrics.ex:37) and is quoted; the table names are literals; no values | LISTED |

### lib/letflow/ordering/sweeper.ex (2 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/ordering/sweeper.ex:54` | `0c9cfb158` REQ-199 (#761) | no | the gap query is assembled with the tenant prefix | (I)+(B) the prefix is the provisioned tenant schema of the sweep and is quoted; the gap timeout is bound as $1 | LISTED |
| `lib/letflow/ordering/sweeper.ex:91` | `0c9cfb158` REQ-199 (#761) | no | the DEAD update is assembled with the tenant prefix | (I)+(B) the prefix is quoted; the correlation id is bound as $1 | LISTED |

### lib/letflow/sandbox_pool.ex (2 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/sandbox_pool.ex:959` | `b8ebfb0c4` WF03-ISS0224 (#463) | no | `CREATE SCHEMA` cannot take a bind parameter | (I) the name is minted by the pool itself (`"sandbox_"` <> a generated UUID, the module's own note at 953-958), never caller text; quoted | LISTED |
| `lib/letflow/sandbox_pool.ex:1026` | `85ca904fb` WF02-REQ039 (#97) | no | `DROP SCHEMA` cannot take a bind parameter | (I) the same pool-minted name, quoted | LISTED |

### lib/letflow/sandbox_pool/fixture_loader.ex (2 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/sandbox_pool/fixture_loader.ex:121` | `85ca904fb` WF02-REQ039 (#97) | no | the TRUNCATE names the sandbox schema and the fixture table | (I) the schema is the pool-minted sandbox schema, the table name passed `validate_table_names/1`'s allowlist (the module's own note at 109-111); both quoted | LISTED |
| `lib/letflow/sandbox_pool/fixture_loader.ex:161` | `85ca904fb` WF02-REQ039 (#97) | no | the INSERT is assembled per sandbox schema and table | (I)+(B) the schema and the table name are quoted; the row JSON is bound as $1 | LISTED |

### lib/letflow/scope_node_paths.ex (1 site)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/scope_node_paths.ex:330` | `4a911d40e` GH #2530 REQ-496 (#2568) | no | the LOCK TABLE names the tenant schema | (I) the prefix was accepted by `tenant_id_for_schema_name/1` before the write path (scope_node_paths.ex:124-126; the note at line 328) and is quoted; the table name is a literal | LISTED |

### lib/letflow/tenant_provisioning.ex (12 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/tenant_provisioning.ex:338` | `da73c154e` REQ-022 (#66) | no | `CREATE SCHEMA` cannot take a bind parameter | (I) the schema name is the output of `schema_name_for_tenant/1` — `"tenant_"` <> 32 hex (tenant_provisioning.ex:216-221, the module's own invariant at 326-337); quoted | LISTED |
| `lib/letflow/tenant_provisioning.ex:2033` | `4e45baffa` REQ-297 (#1180) | no | the statement text is held in a local variable | (B) the statement itself is a fixed literal; the schema and the table name are bound as $1/$2 | LISTED |
| `lib/letflow/tenant_provisioning.ex:2077` | `ca570ca195` REQ-300 (#1184) | no | the same | (B) schema, table and column bound as $1/$2/$3 | LISTED |
| `lib/letflow/tenant_provisioning.ex:2099` | `5c78f1af9` GH #3624 REQ-674 (#3631) | no | the same | (B) schema, table and column bound as $1/$2/$3 | LISTED |
| `lib/letflow/tenant_provisioning.ex:2434` | `4e45baffa` REQ-297 (#1180) | no | the CREATE TABLE text is generated per entity type | (I) the text comes from the DDL module out of the tenant's registered entity definition (table name, columns and types, each quoted); no values | LISTED |
| `lib/letflow/tenant_provisioning.ex:2460` | `8ad3228ee` ISS-0623 (#1314) | no | the CREATE INDEX text is generated and then schema-qualified | (I) the text comes from the DDL module out of the registered index definition; `qualify_index_create_sql/3` (line 2522-2526) quotes the schema and the table | LISTED |
| `lib/letflow/tenant_provisioning.ex:2607` | `4e45baffa` REQ-297 (#1180) | no | the statement text is held in a local variable | (B) schema, table and column bound as $1/$2/$3 | LISTED |
| `lib/letflow/tenant_provisioning.ex:2723` | `4e45baffa` REQ-297 (#1180) | no | the ALTER TABLE ADD COLUMN text is built per promotion | (I) the column name and the pg type come from the registered promotion and `DDL.valid_generated_as_expression?/1` refuses an invalid generated expression before it is interpolated (lines 2715-2719); the schema and the table are quoted | LISTED |
| `lib/letflow/tenant_provisioning.ex:2928` | `4e45baffa` REQ-297 (#1180) | no | the row-count query names the tenant table | (I) the schema is the tenant schema and the table name is checked by `DDL.valid_identifier?/1` (lines 2923-2925, raises otherwise); both quoted; no values | LISTED |
| `lib/letflow/tenant_provisioning.ex:3121` | `1a034ae63` REQ-298 (#1182) | no | the statement text is held in a local variable | (B) schema, table and the field list bound as $1/$2/$3 | LISTED |
| `lib/letflow/tenant_provisioning.ex:3137` | `1a034ae63` REQ-298 (#1182) | no | the same | (B) schema, table and constraint name bound as $1/$2/$3 | LISTED |
| `lib/letflow/tenant_provisioning.ex:3176` | `1a034ae63` REQ-298 (#1182) | no | the ALTER TABLE ADD CONSTRAINT text is built from the constraint clause | (I) the clause comes from `DDL.unique_constraint_clauses/1`, which validates the constraint name and its field names and returns an error instead of text when they are invalid (ddl.ex:434-447); the schema and the table are quoted | LISTED |

### lib/letflow/tenant_purge.ex (1 site)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/tenant_purge.ex:157` | `feb763df5` GH #3252 REQ-572 (#3332) | no | `DROP SCHEMA` cannot take a bind parameter | (I) the schema comes from `TenantProvisioning.schema_name_for_tenant/1` of the LOCKED row (tenant_purge.ex:153) — `"tenant_"` <> 32 hex; quoted | LISTED |

### priv/repo/migrations/20260926010001_backfill_exam_tenant_modules.exs (1 site)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `priv/repo/migrations/20260926010001_backfill_exam_tenant_modules.exs:57` | `64e763949` REQ-409 | no | the INSERT names the tenant schema | (I)+(B) the schema is the migration's own `prefix()` and is accepted by `tenant_id_for_schema_name/1` (`"tenant_"` <> 32 hex, migration lines 44-56); the tenant id is bound as $1; the version is the module constant `@exam_version` | LISTED |

### priv/repo/migrations/20261015025331_create_role_scope_grants.exs (3 sites)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `priv/repo/migrations/20261015025331_create_role_scope_grants.exs:136` | `c55baa4f5` GH #2533 REQ-497 PR 1a (#2592) | no | the binding count names the tenant schema | (I) the schema is the migration's own `prefix()` — the tenant schema the migration runs for; the migration's own header (line 25) says the only interpolation is that schema name; quoted | LISTED |
| `priv/repo/migrations/20261015025331_create_role_scope_grants.exs:146` | `c55baa4f5` GH #2533 REQ-497 PR 1a (#2592) | no | the backfill INSERT names the tenant schema | (I) the schema is quoted; the inserted values are produced by the statement itself (`gen_random_uuid()`, `now()`) or read from the same schema | LISTED |
| `priv/repo/migrations/20261015025331_create_role_scope_grants.exs:181` | `c55baa4f5` GH #2533 REQ-497 PR 1a (#2592) | no | the gap count names the tenant schema | (I) the schema is quoted; no values | LISTED |

### priv/repo/migrations/20261018100001_add_scope_node_fkey_to_role_scope_grants.exs (1 site)

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `priv/repo/migrations/20261018100001_add_scope_node_fkey_to_role_scope_grants.exs:71` | `c309227b2` REQ-517 2a (#2765) | no | the dangling-node count names the tenant schema | (I) the schema is the migration's own `prefix()`, quoted; no values | LISTED |

## The fixed site

| site | introduced by | pilot | why non-literal | how safe | decision |
|---|---|---|---|---|---|
| `lib/letflow/instances/step_log.ex:253` | `ad9567025` PILOT G6 (#5037) | **yes** | the fixed information_schema SELECT was kept in a local variable `query` | now a string literal in the call; the schema is bound as $1 and the module-constant table list as $2; nothing is interpolated | **FIXED** |

## One safety reason per `@dynamic_sql_files` entry

The same reason stands next to each entry in `test/letflow/entities/managed_types/stamp_opener_scan_test.exs`,
where the list itself lives. The scan logic, its threshold and the list are unchanged by T-2693.

| entry | reason |
|---|---|
| `lib/letflow/entities/managed_types/stamp.ex` | listed by the design; its own queries are literals, so the scan does not find it |
| `lib/letflow/engine.ex` | module-attribute constants only: the two `SET LOCAL` timeouts (M) |
| `lib/letflow/entities/record/live_projection.ex` | registered column names quoted as identifiers, every value bound (I+B) |
| `lib/letflow/entities/record/projector.ex` | tenant schema and `DDL.valid_identifier?`-checked table name quoted, values bound (I+B) |
| `lib/letflow/entities/step_writes.ex` | module-attribute constants only: the two `SET LOCAL` timeouts (M) |
| `lib/letflow/event_store/partition_maintenance.ex` | tenant schema and this module's own partition/constraint names quoted, values bound where DDL allows it (I+B) |
| `lib/letflow/event_store/retention_operations.ex` | module-attribute savepoint names and quoted schema/table names, event types bound (M+I+B) |
| `lib/letflow/identity.ex` | module-attribute constant only: the `SET LOCAL` lock timeout (M) |
| `lib/letflow/identity/pending_admin_grants.ex` | module-attribute constant only: the `SET LOCAL` lock timeout (M) |
| `lib/letflow/ledger/storage/ddl.ex` | the statement text is built by Postgres `format('%I')` from bound values (F) |
| `lib/letflow/modules/locations/tree.ex` | the prefix is checked against `@prefix_re` and quoted, the node id is bound (I+B) |
| `lib/letflow/module_upgrade/apply.ex` | module-attribute constants only: the two `SET LOCAL` timeouts (M) |
| `lib/letflow/module_upgrade/rollback.ex` | module-attribute constants only: the two `SET LOCAL` timeouts (M) |
| `lib/letflow/ordering/metrics.ex` | the tenant prefix is quoted, the table names are literals (I) |
| `lib/letflow/ordering/sweeper.ex` | the tenant prefix is quoted, the timeout and the correlation id are bound (I+B) |
| `lib/letflow/sandbox_pool.ex` | the pool's own minted sandbox schema name, quoted (I) |
| `lib/letflow/sandbox_pool/fixture_loader.ex` | the pool-minted sandbox schema and the allow-listed fixture table, quoted; the row JSON is bound (I+B) |
| `lib/letflow/scope_node_paths.ex` | the tenant schema accepted by `tenant_id_for_schema_name/1`, quoted; the table is a literal (I) |
| `lib/letflow/tenant_provisioning.ex` | tenant schema (`"tenant_"` <> 32 hex) and registered DDL names quoted; every value bound (I+B) |
| `lib/letflow/tenant_purge.ex` | the registered `"tenant_"` <> 32 hex schema name, quoted (I) |
| `priv/repo/migrations/20260926010001_backfill_exam_tenant_modules.exs` | the migration's own tenant schema, quoted; the tenant id is bound (I+B) |
| `priv/repo/migrations/20261015025331_create_role_scope_grants.exs` | the migration's own tenant schema, quoted; no values (I) |
| `priv/repo/migrations/20261018100001_add_scope_node_fkey_to_role_scope_grants.exs` | the migration's own tenant schema, quoted; no values (I) |

## How to refresh this table

A merge of `origin/main` that adds, removes or moves a dynamic-SQL site needs the same treatment, or
this table is stale on the tree the merge queue builds. The steps:

1. run the enumeration script of the task folder against the new tree — it calls the scan's own
   `dynamic_sql_files/1` and `dynamic_sql_violations/1`, so the file list it prints is the scan's own
   verdict, not a second detector;
2. add a row per new or moved site, and re-derive the "introduced by" column with `git blame`;
3. if a site appeared outside `@dynamic_sql_files`, the scan test is red on purpose: either make the
   statement a literal or add the file to the list with its reason.
