#!/usr/bin/env bash
# demo_counts.sh -- "demo data survived" as counts (T-1473, O2). Read-only.
#
#   demo_counts.sh snapshot > before.txt      sorted `key value` lines
#   demo_counts.sh compare before.txt after.txt
#   demo_counts.sh --print-sql                the one SQL statement
#
# Run `snapshot` before a promote and again after it, then `compare`: every key of `before` must exist in `after`
# with a value >= the earlier one (a promote may add module data, it must never lose any). `compare` prints one
# `LOST key before after` line per violation and exits 1.
#
# Environment: PSQL, the command that runs psql against the demo database and reads the statement on stdin,
# default `psql "$DATABASE_URL" -X -A -t -F ' '`. Infra may set it to for example
# `docker exec -i <postgres> psql -U <user> -d <db> -X -A -t -F ' '`. No password is read or printed here.
# Keys (see docs/runbooks/demo-operator-inputs.md): tenants, tenant.<slug>.status.<status>, .modules_active, .module.<id>, .users,
# .users_active, .records.<entity_type>, .ledger_entries.<cause>, .ledger_legs, .documents.
# Exit codes: 0 ok, 1 data lost (compare) or psql failed, 2 bad input.
set -euo pipefail
set +x

# One read-only statement. Per-tenant schemas are reached through query_to_xml with format('%I'), the schema name
# derived from the tenant id exactly as TenantProvisioning.schema_name_for_tenant/1 does; only existing schemas.
read -r -d '' SQL <<'EOSQL' || true
WITH t AS (
  SELECT slug, status, 'tenant_' || replace(id::text, '-', '') AS sch
  FROM public.tenants
  WHERE EXISTS (SELECT 1 FROM information_schema.schemata s
                WHERE s.schema_name = 'tenant_' || replace(public.tenants.id::text, '-', ''))
),
m(tmpl) AS (VALUES
  ('SELECT ''modules_active '' || count(*) AS c FROM %I.tenant_modules WHERE status = ''active'''),
  ('SELECT string_agg(''module.'' || module_id || '' 1'', chr(10)) AS c FROM %I.tenant_modules WHERE status = ''active'''),
  ('SELECT ''users '' || count(*) AS c FROM %I.users'),
  ('SELECT ''users_active '' || count(*) AS c FROM %I.users WHERE status = ''active'''),
  ('SELECT string_agg(''records.'' || entity_type || '' '' || n, chr(10)) AS c FROM (SELECT entity_type, count(*) AS n FROM %I.entity_record_latest WHERE NOT deleted GROUP BY entity_type) g'),
  ('SELECT string_agg(''ledger_entries.'' || cause || '' '' || n, chr(10)) AS c FROM (SELECT cause, count(*) AS n FROM %I.ledger_entry GROUP BY cause) g'),
  ('SELECT ''ledger_legs '' || count(*) AS c FROM %I.ledger_leg'),
  ('SELECT ''documents '' || count(*) AS c FROM %I.documents')
),
lines AS (
  SELECT 'tenants ' || (SELECT count(*) FROM public.tenants) AS line
  UNION ALL
  SELECT 'tenant.' || t.slug || '.status.' || t.status || ' 1' FROM t
  UNION ALL
  SELECT 'tenant.' || t.slug || '.' || l
  FROM t CROSS JOIN m
  CROSS JOIN LATERAL (
    SELECT coalesce((xpath('/row/c/text()',
             query_to_xml(format(m.tmpl, t.sch), false, true, '')))[1]::text, '') AS body
  ) q
  CROSS JOIN LATERAL regexp_split_to_table(q.body, E'\n') AS l
  WHERE l <> ''
)
SELECT line FROM lines ORDER BY line COLLATE "C";
EOSQL

usage() { printf 'usage: demo_counts.sh snapshot | compare BEFORE AFTER | --print-sql\n' >&2; exit 2; }

case "${1:-}" in
  --print-sql)
    printf '%s\n' "$SQL"
    ;;
  snapshot)
    [ "$#" -eq 1 ] || usage
    if [ -z "${PSQL:-}" ]; then
      : "${DATABASE_URL:?set DATABASE_URL or PSQL}"
      PSQL='psql "$DATABASE_URL" -X -A -t -F " "'
    fi
    # PSQL is a command line chosen by the operator; the statement goes in on stdin, never on argv.
    out=$(printf '%s\n' "$SQL" | eval "$PSQL -v ON_ERROR_STOP=1") || { echo "snapshot: psql failed" >&2; exit 1; }
    [ -n "$out" ] || { echo "snapshot: psql returned nothing" >&2; exit 1; }
    printf '%s\n' "$out" | LC_ALL=C sort
    ;;
  compare)
    [ "$#" -eq 3 ] || usage
    before="$2" after="$3"
    [ -s "$before" ] || { echo "compare: before file is missing or empty" >&2; exit 2; }
    [ -s "$after" ] || { echo "compare: after file is missing or empty" >&2; exit 2; }
    lost=$(LC_ALL=C awk '
      FNR == NR { n = split($0, f, " "); if (n >= 2) b[f[1]] = f[2]; next }
      { n = split($0, f, " "); if (n >= 2) a[f[1]] = f[2] }
      END {
        for (k in b) {
          if (!(k in a)) printf "LOST %s %s missing\n", k, b[k]
          else if (a[k] + 0 < b[k] + 0) printf "LOST %s %s %s\n", k, b[k], a[k]
        }
      }' "$before" "$after" | LC_ALL=C sort)
    if [ -n "$lost" ]; then printf '%s\n' "$lost"; exit 1; fi
    echo "OK nothing lost"
    ;;
  *)
    usage
    ;;
esac
