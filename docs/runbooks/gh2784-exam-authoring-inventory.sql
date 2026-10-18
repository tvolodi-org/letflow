-- GH #2784: read-only inventory for the exam-authoring field-grant rollout.
--
-- Purpose: before PR A of #2784 deploys, find (1) which tenants have the exam
-- module installed, (2) which users can write or import records (the only
-- people PR A can lock out of authoring the exam types), (3) which field
-- restrictions and per-user field grants already exist on the exam authoring
-- types. The answer decides which authors need field grants afterwards.
--
-- Output: counts and usernames only. No password hash, email, display name,
-- token, answer text, answer key value, record id or any record content.
-- Three result sets, each ordered by tenant_slug:
--   1. exam_tenants:        tenant_slug, schema_name, module_version
--   2. record_writers:      tenant_slug, username, status, built_in_role
--   3. restrictions_grants: tenant_slug, entity_type, field_name, restricted,
--                           granted_usernames (comma separated, may be empty)
-- "record_writers" lists users who belong to a group carrying a built-in role
-- that holds EntitiesRecordsWrite or EntitiesRecordsImport in
-- priv/permission_matrix/effective.golden (PLATFORM_ADMIN, TENANT_ADMIN,
-- PROCESS_OPERATOR). It does NOT include roles gained through
-- role_scope_grants or API tokens; if the result is surprising, ask for those
-- as a second read-only request.
--
-- Entity types looked at (names from priv/modules/exam/pack.json): exam,
-- question, answer_option, session. Edit the IN lists in query 3 if the pack differs.
--
-- Column/table names verified against the migrations on this branch:
--   public.tenants.slug                       (20260816000001_create_tenants)
--   public.tenant_schemas.tenant_id, schema_name, migrations_applied_at
--                                             (20260816090045_create_tenant_schemas)
--   <schema>.tenant_modules.module_id, version (20260925000001_create_tenant_modules)
--   <schema>.users.id, username, status       (20260819000003_create_users_tenant_scoped)
--   <schema>.group_members.group_id, user_id  (20260822000102_create_group_members_tenant_scoped)
--   <schema>.tenant_role.name, group_id, kind (20260819000002 + 20260921000002)
--   <schema>.entity_field_restrictions.entity_type, field_name
--                                             (20260907010001_create_entity_field_restrictions)
--   <schema>.user_entity_grants.user_id, entity_type, field_name
--                                             (20260907010002_create_user_entity_grants)
--
-- Syntax and shape checked 2026-10-18 on a local dev database (read-only transaction, one tenant, 0 writers, 4 restrictions); NOT run on QA.
-- Run with psql (needs \gexec), against a QA database first:
--   psql "$DATABASE_URL" -f docs/runbooks/gh2784-exam-authoring-inventory.sql
-- With zero eligible tenant schemas \gexec runs nothing. Schema names come
-- from tenant_schemas.schema_name and are quoted with %I, never from input.

SET default_transaction_read_only = on;
BEGIN READ ONLY;

-- 1. exam_tenants
SELECT
  'SELECT * FROM (' ||
  string_agg(
    format(
      'SELECT %L::text AS tenant_slug, %L::text AS schema_name, m.version::text AS module_version '
      'FROM %I.tenant_modules m WHERE m.module_id = ''exam''',
      t.slug, ts.schema_name, ts.schema_name
    ),
    ' UNION ALL '
  ) ||
  ') q ORDER BY tenant_slug'
FROM public.tenant_schemas ts
JOIN public.tenants t ON t.id = ts.tenant_id
WHERE ts.migrations_applied_at IS NOT NULL
  AND to_regclass(format('%I.tenant_modules', ts.schema_name)) IS NOT NULL
HAVING COUNT(*) > 0
\gexec

-- 2. record_writers (only tenants that have the exam module installed)
SELECT
  'SELECT * FROM (' ||
  string_agg(
    format(
      'SELECT %L::text AS tenant_slug, u.username::text AS username, u.status::text AS status, '
      'r.name::text AS built_in_role '
      'FROM %I.tenant_role r '
      'JOIN %I.group_members gm ON gm.group_id = r.group_id '
      'JOIN %I.users u ON u.id = gm.user_id '
      'WHERE r.kind = ''platform_role'' '
      'AND r.name IN (''PLATFORM_ADMIN'', ''TENANT_ADMIN'', ''PROCESS_OPERATOR'') '
      'AND EXISTS (SELECT 1 FROM %I.tenant_modules m WHERE m.module_id = ''exam'')',
      t.slug, ts.schema_name, ts.schema_name, ts.schema_name, ts.schema_name
    ),
    ' UNION ALL '
  ) ||
  ') q ORDER BY tenant_slug, username, built_in_role'
FROM public.tenant_schemas ts
JOIN public.tenants t ON t.id = ts.tenant_id
WHERE ts.migrations_applied_at IS NOT NULL
  AND to_regclass(format('%I.tenant_modules', ts.schema_name)) IS NOT NULL
  AND to_regclass(format('%I.tenant_role', ts.schema_name)) IS NOT NULL
  AND to_regclass(format('%I.group_members', ts.schema_name)) IS NOT NULL
  AND to_regclass(format('%I.users', ts.schema_name)) IS NOT NULL
HAVING COUNT(*) > 0
\gexec

-- 3. restrictions_grants (restrictions on the four types, with who holds a grant)
SELECT
  'SELECT * FROM (' ||
  string_agg(
    format(
      'SELECT %L::text AS tenant_slug, f.entity_type::text AS entity_type, f.field_name::text AS field_name, '
      'true AS restricted, '
      'COALESCE((SELECT string_agg(u.username, '','' ORDER BY u.username) '
      'FROM %I.user_entity_grants g JOIN %I.users u ON u.id = g.user_id '
      'WHERE g.entity_type = f.entity_type AND g.field_name = f.field_name), '''')::text AS granted_usernames '
      'FROM %I.entity_field_restrictions f '
      'WHERE f.entity_type IN (''exam'', ''question'', ''answer_option'', ''session'')',
      t.slug, ts.schema_name, ts.schema_name, ts.schema_name
    ),
    ' UNION ALL '
  ) ||
  ') q ORDER BY tenant_slug, entity_type, field_name'
FROM public.tenant_schemas ts
JOIN public.tenants t ON t.id = ts.tenant_id
WHERE ts.migrations_applied_at IS NOT NULL
  AND to_regclass(format('%I.entity_field_restrictions', ts.schema_name)) IS NOT NULL
  AND to_regclass(format('%I.user_entity_grants', ts.schema_name)) IS NOT NULL
  AND to_regclass(format('%I.users', ts.schema_name)) IS NOT NULL
HAVING COUNT(*) > 0
\gexec

ROLLBACK;
