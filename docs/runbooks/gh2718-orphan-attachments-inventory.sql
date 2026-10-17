-- GH #2718: read-only inventory of legacy orphan instance attachments.
--
-- Purpose: size the rows the missing instance-existence check allowed, i.e.
-- instance_attachments rows whose parent is (a) an UNKNOWN instance (no
-- instance_projections row) or (b) a SYNTHETIC entity-type instance
-- (entity_type_instances row), plus the bytes they hold against the tenant
-- storage quota (get_storage_usage = sum(byte_size) over every row).
--
-- Output: one row per tenant schema, ordered by tenant_slug. Counts and byte
-- sums only; no attachment ids, file names, instance ids or other values:
--   tenant_slug, schema_name, total_rows, total_bytes,
--   missing_parent_rows, missing_parent_bytes,
--   synthetic_parent_rows, synthetic_parent_bytes
-- Classes are mutually exclusive, SYNTHETIC FIRST (a registry row with no
-- projection counts once, as synthetic). Rows with a visible parent appear
-- only in total_*.
--
-- Column/table names verified against the migrations on this branch:
--   public.tenants.slug                       (20260816000001_create_tenants)
--   public.tenant_schemas.tenant_id, schema_name, migrations_applied_at
--                                             (20260816090045_create_tenant_schemas)
--   <schema>.instance_attachments.instance_id, byte_size
--                                             (20260901000002_create_instance_attachments)
--   <schema>.instance_projections.instance_id (20260816120003_create_instance_projections)
--   <schema>.entity_type_instances.instance_id
--                                             (20260906010002_create_entity_type_instances)
--
-- Run with psql (needs \gexec), against a QA database first:
--   psql "$DATABASE_URL" -f docs/runbooks/gh2718-orphan-attachments-inventory.sql
-- With zero eligible tenant schemas \gexec runs nothing. The schema name
-- comes from tenant_schemas.schema_name and is quoted with %I, never from
-- input.

SET default_transaction_read_only = on;
BEGIN READ ONLY;

SELECT
  'SELECT * FROM (' ||
  string_agg(
    format(
      'SELECT %L::text AS tenant_slug, %L::text AS schema_name, '
      'COUNT(*) AS total_rows, '
      'COALESCE(SUM(a.byte_size), 0)::bigint AS total_bytes, '
      'COUNT(*) FILTER (WHERE NOT s.is_synthetic AND NOT EXISTS ('
      'SELECT 1 FROM %I.instance_projections p WHERE p.instance_id = a.instance_id)) AS missing_parent_rows, '
      'COALESCE(SUM(a.byte_size) FILTER (WHERE NOT s.is_synthetic AND NOT EXISTS ('
      'SELECT 1 FROM %I.instance_projections p WHERE p.instance_id = a.instance_id)), 0)::bigint AS missing_parent_bytes, '
      'COUNT(*) FILTER (WHERE s.is_synthetic) AS synthetic_parent_rows, '
      'COALESCE(SUM(a.byte_size) FILTER (WHERE s.is_synthetic), 0)::bigint AS synthetic_parent_bytes '
      'FROM %I.instance_attachments a '
      'CROSS JOIN LATERAL (SELECT EXISTS ('
      'SELECT 1 FROM %I.entity_type_instances e WHERE e.instance_id = a.instance_id) AS is_synthetic) s',
      t.slug, ts.schema_name,
      ts.schema_name, ts.schema_name, ts.schema_name, ts.schema_name
    ),
    ' UNION ALL '
  ) ||
  ') inventory ORDER BY tenant_slug'
FROM public.tenant_schemas ts
JOIN public.tenants t ON t.id = ts.tenant_id
WHERE ts.migrations_applied_at IS NOT NULL
  AND to_regclass(format('%I.instance_attachments', ts.schema_name)) IS NOT NULL
  AND to_regclass(format('%I.instance_projections', ts.schema_name)) IS NOT NULL
  AND to_regclass(format('%I.entity_type_instances', ts.schema_name)) IS NOT NULL
HAVING COUNT(*) > 0
\gexec

ROLLBACK;
