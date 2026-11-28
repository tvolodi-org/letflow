#!/usr/bin/env bash
# T-1568 -- backup.sh dump | base. Interface and environment: scripts/backup/README.md.
#
#   backup.sh dump   daily: one set per database in BACKUP_DATABASES. A plain `pg_dump -Fc` for the
#                    others; for LETFLOW_DATABASE one `pg_dump -n <schema> -Fc` per registered tenant
#                    schema + public + `pg_dumpall --globals-only`, a sha256 per file and a manifest
#                    (T-3149: never a whole-database dump; fails when registry and schemas differ).
#   backup.sh base   weekly: `pg_basebackup` (needs archive_mode=on, otherwise it refuses).
#
# Exit codes: 0 ok; 2 bad input / missing tool; 3 a dump failed or another run holds the lock;
#             4 base backup refused or failed; 5 encryption failed; 6 prune failed (the backup is kept).
# Status file: $BACKUP_ROOT/status/<dump|base>.json
set -euo pipefail
set +x
# shellcheck source=scripts/backup/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MODE="${1:-}"
case "$MODE" in
  dump | base) ;;
  *)
    log "usage: backup.sh dump|base"
    exit 2
    ;;
esac

TMP_SET=""
cleanup() {
  # A half-written set never stays behind (it is hidden by the .tmp- prefix anyway).
  [[ -z "$TMP_SET" ]] || rm -rf -- "$TMP_SET"
}
status_begin "$MODE" cleanup
common_env
need_tool sha256sum
need_tool date
BACKUP_JOBS="${BACKUP_JOBS:-2}"
[[ "$BACKUP_JOBS" =~ ^[1-8]$ ]] || die 2 "jobs_invalid" "BACKUP_JOBS must be a number from 1 to 8"
take_lock backup
[[ "$BACKUP_ENCRYPT" != gpg ]] || {
  need_tool gpg
  gpg --list-keys -- "$BACKUP_GPG_RECIPIENT" >/dev/null 2>&1 ||
    die 5 "gpg_key_missing" "no public key for BACKUP_GPG_RECIPIENT in the keyring"
}

# encrypt_to <final file>: stdin -> file (plain) or stdin -> gpg -> file.gpg. Prints the final path.
sink() {
  local out="$1"
  if [[ "$BACKUP_ENCRYPT" == gpg ]]; then
    out="$out.gpg"
    gpg --batch --yes --encrypt --recipient "$BACKUP_GPG_RECIPIENT" --trust-model always -o "$out" 2>/dev/null ||
      return 5
  else
    cat >"$out"
  fi
}

final_name() { [[ "$BACKUP_ENCRYPT" == gpg ]] && printf '%s.gpg' "$1" || printf '%s' "$1"; }

dump_one() {
  local db="$1" stamp="$2" dir="$BACKUP_ROOT/dump/$1" file out rc=0
  mkdir -p -m 0700 "$dir"
  TMP_SET="$dir/.tmp-$stamp"
  mkdir -m 0700 "$TMP_SET"

  if [[ "$db" == "$LETFLOW_DATABASE" ]]; then
    dump_letflow "$db" "$TMP_SET"
  else
    file="$TMP_SET/$db.dump"
    out="$(final_name "$file")"
    { pgc pg_dump -Fc --no-owner --no-acl -d "$db" </dev/null | sink "$file"; } 2> >(filter_secrets >&2) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      [[ "$rc" -eq 5 ]] && die 5 "encrypt_failed" "encryption failed for $db"
      die 3 "dump_failed_$db" "pg_dump failed for $db"
    fi
    [[ -s "$out" ]] || die 3 "dump_empty_$db" "dump for $db is empty"
    (cd "$TMP_SET" && sha256sum "$(basename "$out")" >"$(basename "$out").sha256")
    DUMP_BYTES=$((DUMP_BYTES + $(stat -c %s "$out")))
  fi
  chmod 0600 "$TMP_SET"/*
  mv -T "$TMP_SET" "$dir/$stamp"
  TMP_SET=""
  ln -sfn "$stamp" "$dir/.LATEST.$$"
  mv -T "$dir/.LATEST.$$" "$dir/LATEST"
}

# --- the Letflow database: per schema (T-3149). Never a whole-database pg_dump: a whole dump takes
# one lock per table of every tenant in one transaction (out of shared memory at ~35k tables).
# Each schema is its own pg_dump -n call in its own transaction (about 650 locks).

# schema name as the registry may hold it: a plain identifier, never public / pg_* / information_schema
valid_schema_name() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ && "$1" != public && "$1" != pg_* && "$1" != information_schema ]]
}

# Fail loudly (exit 3, named list) unless the tenant registry and the real schemas agree.
check_registry() {
  local db="$1" work="$2" s bad="" missing extra
  pgc psql -X -At -d "$db" -v ON_ERROR_STOP=1 -c 'SELECT schema_name FROM public.tenant_schemas ORDER BY 1' </dev/null \
    2> >(filter_secrets >&2) | LC_ALL=C sort -u >"$work/registry.txt" ||
    die 3 "registry_unreadable" "cannot read public.tenant_schemas from $db"
  pgc psql -X -At -d "$db" -v ON_ERROR_STOP=1 -c "SELECT nspname FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' ORDER BY 1" </dev/null \
    2> >(filter_secrets >&2) | LC_ALL=C sort -u >"$work/actual.txt" ||
    die 3 "schemas_unreadable" "cannot list the schemas of $db"
  while IFS= read -r s; do
    valid_schema_name "$s" || bad="$bad $s"
  done <"$work/registry.txt"
  [[ -z "$bad" ]] || die 3 "registry_name_invalid" "registry holds a schema name that is not a plain tenant schema:${bad:0:200}"
  [[ -s "$work/registry.txt" ]] || die 3 "registry_empty" "public.tenant_schemas is empty: refusing a backup with no tenant"
  missing="$(comm -23 "$work/registry.txt" "$work/actual.txt" | paste -sd, -)"
  extra="$(comm -13 "$work/registry.txt" <(grep '^tenant_' "$work/actual.txt" || true) | paste -sd, -)"
  if [[ -n "$missing$extra" ]]; then
    log "registry mismatch: registered without a schema: [${missing:-none}]; tenant schema not in the registry: [${extra:-none}]"
    die 3 "registry_mismatch missing=${missing//,/:} extra=${extra//,/:}" "tenant registry and schema list differ"
  fi
}

# dump_schema <db> <schema> <set dir>: one pg_dump -n <schema> in its own snapshot, plus the manifest
# lines of that schema taken in the same snapshot. Runs in a background subshell: no die here.
dump_schema() {
  local db="$1" schema="$2" dir="$3" file="$3/$2.dump" snap line rc=0
  coproc SNAP { pgc psql -X -q -At -d "$db" -v ON_ERROR_STOP=1 -v "only=$schema" 2>/dev/null; }
  printf 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSELECT pg_export_snapshot();\n' >&"${SNAP[1]}"
  IFS= read -r snap <&"${SNAP[0]}" || return 3
  [[ "$snap" =~ ^[0-9A-Fa-f-]{1,64}$ ]] || return 3
  { pgc pg_dump -n "$schema" -Fc --no-owner --no-acl --snapshot="$snap" -d "$db" </dev/null | sink "$file"; } 2> >(filter_secrets >&2) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    kill "$SNAP_PID" 2>/dev/null || true
    return "$rc"
  fi
  cat "$SCRIPT_DIR/manifest.sql" >&"${SNAP[1]}"
  printf "SELECT '--END--';\nCOMMIT;\n\\\\q\n" >&"${SNAP[1]}"
  : >"$dir/.work/$schema.mf"
  while IFS= read -r line <&"${SNAP[0]}"; do
    [[ "$line" == "--END--" ]] && break
    printf '%s\n' "$line" >>"$dir/.work/$schema.mf"
  done
  wait "$SNAP_PID" 2>/dev/null || true
  [[ -s "$(final_name "$file")" ]] || return 3
}

# run_schema_jobs <db> <set dir> <schema>...: at most BACKUP_JOBS in parallel; a failed job leaves
# <schema>.failed with its exit code, and the run dies once with the named list.
run_schema_jobs() {
  local db="$1" dir="$2" s f rc="" failed=""
  shift 2
  for s in "$@"; do
    while [[ "$(jobs -rp | wc -l)" -ge "$BACKUP_JOBS" ]]; do wait -n 2>/dev/null || true; done
    (
      r=0
      dump_schema "$db" "$s" "$dir" || r=$?
      [[ "$r" -eq 0 ]] || echo "$r" >"$dir/.work/$s.failed"
    ) &
  done
  wait || true
  for f in "$dir"/.work/*.failed; do
    [[ -e "$f" ]] || continue
    s="$(basename "$f" .failed)"
    failed="$failed:$s"
    [[ "$(cat "$f")" != 5 ]] || rc=5
  done
  [[ -z "$rc" ]] || die 5 "encrypt_failed" "encryption failed for a schema dump"
  [[ -z "$failed" ]] || die 3 "dump_failed$failed" "pg_dump failed for: ${failed//:/ }"
}

# manifest row helper: write_row <schema> <file name> <format> <modules digest>
write_row() {
  local schema="$1" name="$2" fmt="$3" mods="$4" path="$TMP_SET/$2" sum
  sum="$(sha256sum "$path" | cut -d' ' -f1)"
  printf '%s  %s\n' "$sum" "$name" >"$path.sha256"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$schema" "$name" "$(stat -c %s "$path")" "$sum" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$fmt" "$PG_MAJOR" "$SCHEMA_VERSION" "$mods" >>"$TMP_SET/manifest.tsv"
  DUMP_BYTES=$((DUMP_BYTES + $(stat -c %s "$path")))
}

dump_letflow() {
  local db="$1" dir="$2" work="$2/.work" s rc=0 mods
  mkdir -m 0700 "$work"
  check_registry "$db" "$work"
  PG_MAJOR="$(pgc psql -X -At -d "$db" -c 'SHOW server_version_num' </dev/null | cut -c1-2)"
  SCHEMA_VERSION="-"
  if [[ "$(pgc psql -X -At -d "$db" -c "SELECT to_regclass('public.schema_migrations') IS NOT NULL" </dev/null)" == t ]]; then
    SCHEMA_VERSION="$(pgc psql -X -At -d "$db" -c 'SELECT coalesce(max(version)::text, '"'-'"') FROM public.schema_migrations' </dev/null)"
  fi

  # the cluster-wide roles (no -n: pg_dumpall has no per-schema mode; it takes no table locks)
  { pgc pg_dumpall --globals-only </dev/null | sink "$dir/globals.sql"; } 2> >(filter_secrets >&2) || rc=$?
  [[ "$rc" -ne 5 ]] || die 5 "encrypt_failed" "encryption failed for the globals dump"
  [[ "$rc" -eq 0 ]] || die 3 "dump_failed_globals" "pg_dumpall --globals-only failed"

  mapfile -t schemas <"$work/registry.txt"
  run_schema_jobs "$db" "$dir" public "${schemas[@]}"

  printf 'schema\tfile\tbytes\tsha256\ttimestamp\tformat\tpg_version\tschema_version\tmodules_digest\n' >"$dir/manifest.tsv"
  write_row globals "$(basename "$(final_name "$dir/globals.sql")")" sql -
  for s in public "${schemas[@]}"; do
    mods="$(sed -n "s/^$s\\.modules=//p" "$work/$s.mf")"
    write_row "$s" "$(basename "$(final_name "$dir/$s.dump")")" custom "${mods:--}"
  done
  {
    printf 'format=2\nsource_db=%s\npg_version=%s\n' "$db" "$PG_MAJOR"
    cat "$work"/*.mf
  } >"$dir/manifest.txt"
  grep -q '^public.tenants=' "$dir/manifest.txt" || die 3 "manifest_incomplete" "manifest has no public.tenants line"
  rm -rf -- "$work"
}

run_prune() {
  if [[ "${BACKUP_PRUNE:-1}" == 1 ]]; then
    "$SCRIPT_DIR/prune.sh" || die 6 "prune_failed" "prune failed; the new backup is kept"
  fi
}

case "$MODE" in
  dump)
    DUMP_BYTES=0
    stamp="$(utc_stamp)"
    sets=0
    for db in $BACKUP_DATABASES; do
      dump_one "$db" "$stamp"
      sets=$((sets + 1))
    done
    STATUS_DETAIL="sets=$sets bytes=$DUMP_BYTES stamp=$stamp"
    run_prune
    ;;
  base)
    need_tool tar
    mode="$(pgc psql -X -At -d "$LETFLOW_DATABASE" -c 'SHOW archive_mode' </dev/null 2>/dev/null || true)"
    [[ "$mode" == on || "$mode" == always ]] ||
      die 4 "archive_mode_off" "pg_basebackup refused: archive_mode is not on (a base backup without WAL is not point-in-time recoverable)"
    stamp="$(utc_stamp)"
    mkdir -p -m 0700 "$BACKUP_ROOT/base"
    TMP_SET="$BACKUP_ROOT/base/.tmp-$stamp"
    mkdir -m 0700 "$TMP_SET"
    # The redo segment read BEFORE the backup is not later than the backup's own start, so WAL
    # kept from here on is enough (prune.sh keeps WAL from the oldest kept base's start_wal).
    start_wal="$(pgc psql -X -At -d "$LETFLOW_DATABASE" -c 'SELECT pg_walfile_name(redo_lsn) FROM pg_control_checkpoint()' </dev/null)"
    [[ "$start_wal" =~ ^[0-9A-F]{24}$ ]] || die 4 "start_wal_unreadable" "cannot read the start WAL segment"
    rc=0
    { pgc pg_basebackup -D - -Ft -z -X none --checkpoint=fast </dev/null | sink "$TMP_SET/base.tar.gz"; } 2> >(filter_secrets >&2) || rc=$?
    [[ "$rc" -ne 5 ]] || die 5 "encrypt_failed" "encryption failed for the base backup"
    [[ "$rc" -eq 0 ]] || die 4 "basebackup_failed" "pg_basebackup failed"
    out="$(final_name "$TMP_SET/base.tar.gz")"
    printf 'start_wal=%s\nstamp=%s\n' "$start_wal" "$stamp" >"$TMP_SET/base.info"
    (cd "$TMP_SET" && sha256sum "$(basename "$out")" >"$(basename "$out").sha256")
    chmod 0600 "$TMP_SET"/*
    mv -T "$TMP_SET" "$BACKUP_ROOT/base/$stamp"
    TMP_SET=""
    STATUS_DETAIL="stamp=$stamp start_wal=$start_wal"
    run_prune
    ;;
esac
