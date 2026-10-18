# Rolling out the master `external_ref` (GH #2659 / REQ-505)

Scope: the PR-1 storage change (two tenant-scoped migrations on `entity_record_latest` and
`ENTITY_RECORD_CREATED` v2) and the rule for when the idempotent upsert-by-external-ref import
(PR-2 primitive, PR-3 route) may first be used. Design:
`lib/letflow/design/gh2659-external-ref-idempotent-import.md` (sections 2.1, 2.4, 5.5, 12);
decision 0057 D1/D12.

## What ships

| Piece | Detail |
|---|---|
| Migration (a) `20261019100001` | `external_system varchar(64) NULL`, `external_id varchar(255) NULL` on `entity_record_latest` (catalog-only `ADD COLUMN`, no rewrite, no backfill) and the CHECK `entity_record_latest_external_ref_pair_chk` (`(external_system IS NULL) = (external_id IS NULL)`). One ACCESS EXCLUSIVE window per tenant for one validation scan. |
| Migration (b) `20261019100002` | Partial unique index `entity_record_latest_external_ref_idx` on `(entity_type, external_system, external_id) WHERE external_id IS NOT NULL`. One SHARE lock (blocks writes, not reads) for one scan of an empty index. |
| `ENTITY_RECORD_CREATED` v2 | Replaced in place: optional `external_ref {system, id}`; UPDATED and DELETED stay v1. Registered in a fresh tenant at provisioning and in an existing tenant by the replay that follows the migrations. |
| Code | Writer-free in PR-1: nothing writes a ref yet. |

Both migrations start with `SET LOCAL lock_timeout = '5s'` (dies with the migration's own
transaction) and use guarded DDL (`ADD COLUMN IF NOT EXISTS`; the CHECK added only if
`pg_constraint` has no such name; `CREATE UNIQUE INDEX IF NOT EXISTS`).

## 1. Deploy order (must hold)

**migrations (a)(b) -> `ENTITY_RECORD_CREATED` v2 registered in every tenant -> code that writes
a ref.**

PR-1 ships the first two and no writer. PR-2 and PR-3 merge after it. Do not deploy PR-3 (the
`upsert_by` route) to an environment until step 3 below confirms every tenant is at v2: the
router answers a constant 503 `event_schema_outdated` for a tenant still below v2, but the
correct order makes that unreachable.

## 2. Never let old nodes write during the import cutover

An old node ignores the `upsert_by` request member and would run the create-only import, which
silently creates duplicates on every re-run. Therefore:

1. Finish the deploy on ALL nodes first (a rolling deploy must be complete, not in progress).
2. Only then run the one-time seed import (decision 0057 D12). It is an operator action, never a
   client-library default.
3. Verification before the seed, per environment:
   - every node reports the new release version;
   - for the seeding tenant, `Letflow.EventStore.Registry.max_schema_version("ENTITY_RECORD_CREATED", schema)`
     returns `2` (and `"ENTITY_RECORD_UPDATED"` / `"ENTITY_RECORD_DELETED"` return `1`).

Rollback of code after the migrations: the columns, the index and the v2 schema stay and are
inert (nullable; every v1-shaped payload is valid under v2). Records that already hold a ref keep
it; an old node simply never writes one.

## 3. A migration that failed on `lock_timeout`

If a tenant's `entity_record_latest` is busy, the lock cannot be taken within 5 seconds and the
statement fails with `lock_not_available`. The migration rolls back whole and records nothing
(the table is unchanged, `schema_migrations` has no row), and `replay_migrations/2` reports
`{:error, {:migration_failed, _}}` for that tenant only. Other tenants are unaffected.

- The migration is retried by the NEXT boot replay (it re-runs every unapplied manifest entry).
  A busy tenant is skipped, never blocked and never half-migrated.
- To retry sooner, call `Letflow.TenantProvisioning.replay_migrations(tenant_id)` for that tenant
  during a quiet period, with
  `bin/letflow rpc "IO.inspect(Letflow.TenantProvisioning.replay_migrations(\"<tenant_id>\"))"`.
- Confirm it applied for a tenant (replace `<schema>`):

  ```sql
  SELECT version FROM "<schema>".schema_migrations WHERE version IN (20261019100001, 20261019100002);
  SELECT column_name FROM information_schema.columns
   WHERE table_schema = '<schema>' AND table_name = 'entity_record_latest'
     AND column_name IN ('external_system', 'external_id');
  SELECT conname, convalidated FROM pg_constraint
   WHERE conname = 'entity_record_latest_external_ref_pair_chk'
     AND connamespace = '<schema>'::regnamespace;
  SELECT indexname FROM pg_indexes
   WHERE schemaname = '<schema>' AND indexname = 'entity_record_latest_external_ref_idx';
  SELECT indisvalid FROM pg_index
   WHERE indexrelid = '"<schema>".entity_record_latest_external_ref_idx'::regclass;
  ```

  Both versions present, two columns, the CHECK with `convalidated = t`, and the index with
  `indisvalid = t`. Migration (b) refuses (aborts) when an index of that name exists but is
  INVALID, so a failed concurrent build cannot be mistaken for a working guarantee.
- The v2 event schema is registered by the same replay, after the migrations succeed. A tenant
  whose migrations failed is still at CREATED v1; confirm with `max_schema_version/2` as above.

## 3a. Migration (b) aborted because the index is INVALID

Migration (b) raises `index entity_record_latest_external_ref_idx exists but is INVALID` when a
failed `CREATE UNIQUE INDEX CONCURRENTLY` left an invalid index under the name. The cause is
almost always duplicate refs: two rows with the same `(entity_type, external_system, external_id)`
made the unique build fail. (Rows can only hold a ref if something wrote one, so this normally
means the manual route was run after refs already existed.)

1. Diagnose (`indisvalid = f` confirms it):

   ```sql
   SELECT indisvalid FROM pg_index
    WHERE indexrelid = '"<schema>".entity_record_latest_external_ref_idx'::regclass;
   ```

2. Drop the invalid index:

   ```sql
   DROP INDEX CONCURRENTLY "<schema>".entity_record_latest_external_ref_idx;
   ```

3. Find and fix the duplicate rows that failed the build:

   ```sql
   SELECT entity_type, external_system, external_id, count(*)
     FROM "<schema>".entity_record_latest
    WHERE external_id IS NOT NULL
    GROUP BY 1, 2, 3 HAVING count(*) > 1;
   ```

4. Re-run the concurrent create from section 4 step 3 (the existing manual route), or call
   `replay_migrations/2` as in section 3 so migration (b) builds it. Then re-check `indisvalid = t`.

## 4. Large tenants: the manual route first

Prerequisite for every real environment: **infra produces a per-tenant row count of
`entity_record_latest` BEFORE the migrations are deployed there** (a deploy gate; record it in the
PR-1 description). The default migrations hold ACCESS EXCLUSIVE (a) and SHARE (b) for one scan
each; that is accepted for expected tenant sizes (seconds at most).

> Threshold: a tenant whose `entity_record_latest` holds more than **1,000,000 rows** takes the
> manual route below. Infra confirms or changes this number from the inventory; the migrations
> themselves are unaffected by it.

For such a tenant, prepare the objects by hand, in this order. **Manual preparation MUST finish
before the new release boots on that environment**: the boot replay is synchronous and runs
migration (a) itself (ACCESS EXCLUSIVE for the CHECK scan), so a release that boots first takes
the long lock this route exists to avoid. Every migration statement is guarded, so the migration then becomes a no-op for
that tenant.

1. Columns (catalog-only, fast):

   ```sql
   ALTER TABLE "<schema>".entity_record_latest
     ADD COLUMN IF NOT EXISTS external_system varchar(64),
     ADD COLUMN IF NOT EXISTS external_id varchar(255);
   ```

2. The CHECK as `NOT VALID` (no scan; new writes are checked immediately), then validate it
   separately (SHARE UPDATE EXCLUSIVE, does not block reads or writes):

   ```sql
   ALTER TABLE "<schema>".entity_record_latest
     ADD CONSTRAINT entity_record_latest_external_ref_pair_chk
     CHECK ((external_system IS NULL) = (external_id IS NULL)) NOT VALID;
   ALTER TABLE "<schema>".entity_record_latest
     VALIDATE CONSTRAINT entity_record_latest_external_ref_pair_chk;
   ```

   Forgetting the `VALIDATE` leaves the CHECK `NOT VALID` (new rows are checked, existing rows
   are not proven); the `convalidated` query in section 3 catches it (`f` means not validated).
   Migration (a) adds the CHECK only when `pg_constraint` has no constraint of that name, so it
   will not touch the one created here.

3. The index, concurrently, outside any transaction, under the SAME name:

   ```sql
   CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS entity_record_latest_external_ref_idx
     ON "<schema>".entity_record_latest (entity_type, external_system, external_id)
     WHERE external_id IS NOT NULL;
   ```

   Check it is valid (`SELECT indisvalid FROM pg_index WHERE indexrelid = '"<schema>".entity_record_latest_external_ref_idx'::regclass;`
   must be `t`; drop and recreate if not). Migration (b) uses `CREATE UNIQUE INDEX IF NOT EXISTS`
   and becomes a no-op.

Migration (a) has no concurrent route of its own: the columns are catalog-only and only the CHECK
validation scan is long, which step 2 replaces.

## 5. Not covered

Exposing `external_ref` in query/export rows, a client-supplied version per entry, and reviving a
soft-deleted reference are separate issues (design section 10, OQ-2/3/4).
