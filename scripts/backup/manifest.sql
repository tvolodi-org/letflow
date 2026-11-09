-- T-1568 -- the backup manifest / restore-check query. Run with `psql -X -At -v ON_ERROR_STOP=1`.
--
-- One fixed, read-only SELECT. It prints sorted `key=value` lines: row counts and md5 digests only,
-- never a record value (INV-4). backup.sh runs it inside the exported snapshot the dump uses;
-- restore_test.sh runs it on the restored copy and diffs the two outputs.
--
-- Schema names come ONLY from public.tenant_schemas and are quoted with format('%I') (INV-1, INV-7);
-- nothing from outside the database is spliced into SQL. A table an older tenant does not have is `-`.
--
-- ledger_replay: md5 over the sorted rows "ledger_id|unit_ref|sum(legs)|sum(on_hand)". The ledger
-- invariant is that both sums are equal per (ledger_id, unit_ref); ledger_replay_diff counts the
-- pairs where they are not (0 for a healthy ledger), ledger_pairs counts all pairs.
WITH s AS (
  SELECT schema_name FROM public.tenant_schemas
),
counted AS (
  SELECT s.schema_name AS sn, t.name AS tn,
         CASE WHEN to_regclass(format('%I.%I', s.schema_name, t.name)) IS NULL THEN '-'
              ELSE (xpath('/row/c/text()', query_to_xml(
                     format('SELECT count(*) AS c FROM %I.%I', s.schema_name, t.name), false, true, '')))[1]::text
         END AS v
  FROM s CROSS JOIN (VALUES ('events'), ('events_archive'), ('ledger_entry'), ('ledger_leg'), ('ledger_balance')) AS t(name)
),
mods AS (
  SELECT s.schema_name AS sn,
         CASE WHEN to_regclass(format('%I.tenant_modules', s.schema_name)) IS NULL THEN '-'
              ELSE (xpath('/row/c/text()', query_to_xml(
                     format('SELECT coalesce(md5(string_agg(module_id || '':'' || version, '','' ORDER BY module_id, version)), ''-'') AS c FROM %I.tenant_modules',
                            s.schema_name), false, true, '')))[1]::text
         END AS v
  FROM s
),
replay_q AS (
  SELECT s.schema_name AS sn,
         to_regclass(format('%I.ledger_leg', s.schema_name)) IS NOT NULL
           AND to_regclass(format('%I.ledger_balance', s.schema_name)) IS NOT NULL AS has_ledger,
         format('SELECT coalesce(g.ledger_id, b.ledger_id) AS ledger_id, coalesce(g.unit_ref, b.unit_ref) AS unit_ref, '
                || 'coalesce(g.l, 0) AS l, coalesce(b.b, 0) AS b '
                || 'FROM (SELECT ledger_id, unit_ref, sum(quantity) AS l FROM %1$I.ledger_leg GROUP BY 1, 2) g '
                || 'FULL JOIN (SELECT ledger_id, unit_ref, sum(on_hand) AS b FROM %1$I.ledger_balance GROUP BY 1, 2) b '
                || 'ON g.ledger_id = b.ledger_id AND g.unit_ref = b.unit_ref', s.schema_name) AS q
  FROM s
),
replay AS (
  SELECT sn,
         CASE WHEN NOT has_ledger THEN '-' ELSE (xpath('/row/c/text()', query_to_xml(
              'SELECT coalesce(md5(string_agg(format(''%s|%s|%s|%s'', ledger_id, unit_ref, l, b), '';'' ORDER BY ledger_id COLLATE "C", unit_ref COLLATE "C")), ''-'') AS c FROM ('
              || q || ') x', false, true, '')))[1]::text END AS md5v,
         CASE WHEN NOT has_ledger THEN '-' ELSE (xpath('/row/c/text()', query_to_xml(
              'SELECT count(*) AS c FROM (' || q || ') x', false, true, '')))[1]::text END AS pairs,
         CASE WHEN NOT has_ledger THEN '-' ELSE (xpath('/row/c/text()', query_to_xml(
              'SELECT count(*) AS c FROM (' || q || ') x WHERE l <> b', false, true, '')))[1]::text END AS diff
  FROM replay_q
)
SELECT line FROM (
  SELECT 'public.tenants=' || (SELECT count(*) FROM public.tenants) AS line
  UNION ALL SELECT 'public.tenant_schemas=' || (SELECT count(*) FROM public.tenant_schemas)
  UNION ALL SELECT sn || '.' || tn || '=' || v FROM counted
  UNION ALL SELECT sn || '.modules=' || v FROM mods
  UNION ALL SELECT sn || '.ledger_replay=' || md5v FROM replay
  UNION ALL SELECT sn || '.ledger_pairs=' || pairs FROM replay
  UNION ALL SELECT sn || '.ledger_replay_diff=' || diff FROM replay
) m
ORDER BY line COLLATE "C";
