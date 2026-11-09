#!/usr/bin/env bash
# T-1568 -- backup.sh dump | base. Interface and environment: scripts/backup/README.md.
#
#   backup.sh dump   daily: one `pg_dump -Fc` set per database in BACKUP_DATABASES, with a sha256
#                    and (for LETFLOW_DATABASE) a manifest taken in the same snapshot.
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
  if [[ -n "${SNAP_PID:-}" ]]; then
    kill "$SNAP_PID" 2>/dev/null || true
  fi
}
status_begin "$MODE" cleanup
common_env
need_tool sha256sum
need_tool date
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
  file="$TMP_SET/$db.dump"
  out="$(final_name "$file")"

  if [[ "$db" == "$LETFLOW_DATABASE" ]]; then
    dump_with_manifest "$db" "$file" "$TMP_SET" || rc=$?
  else
    { pgc pg_dump -Fc --no-owner --no-acl -d "$db" </dev/null | sink "$file"; } 2> >(filter_secrets >&2) || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    [[ "$rc" -eq 5 ]] && die 5 "encrypt_failed" "encryption failed for $db"
    die 3 "dump_failed_$db" "pg_dump failed for $db"
  fi
  [[ -s "$out" ]] || die 3 "dump_empty_$db" "dump for $db is empty"
  (cd "$TMP_SET" && sha256sum "$(basename "$out")" >"$(basename "$out").sha256")
  chmod 0600 "$TMP_SET"/*
  mv -T "$TMP_SET" "$dir/$stamp"
  TMP_SET=""
  ln -sfn "$stamp" "$dir/.LATEST.$$"
  mv -T "$dir/.LATEST.$$" "$dir/LATEST"
  DUMP_BYTES=$((DUMP_BYTES + $(stat -c %s "$dir/$stamp/$(basename "$out")")))
}

# The dump and the manifest describe the same instant: one REPEATABLE READ session exports a
# snapshot, pg_dump imports it, the manifest query runs in the same session, then it commits.
dump_with_manifest() {
  local db="$1" file="$2" set_dir="$3" snap line rc=0
  coproc SNAP { pgc psql -X -q -At -d "$db" -v ON_ERROR_STOP=1 2>/dev/null; }
  printf 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSELECT pg_export_snapshot();\n' >&"${SNAP[1]}"
  IFS= read -r snap <&"${SNAP[0]}" || return 3
  [[ "$snap" =~ ^[0-9A-Fa-f-]{1,64}$ ]] || return 3

  { pgc pg_dump -Fc --no-owner --no-acl --snapshot="$snap" -d "$db" </dev/null | sink "$file"; } 2> >(filter_secrets >&2) || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"

  {
    printf 'format=1\nsource_db=%s\n' "$db"
    printf 'pg_version=%s\n' "$(pgc psql -X -At -d "$db" -c 'SHOW server_version_num' </dev/null | cut -c1-2)"
  } >"$set_dir/manifest.txt"
  cat "$SCRIPT_DIR/manifest.sql" >&"${SNAP[1]}"
  printf "SELECT '--END--';\nCOMMIT;\n\\\\q\n" >&"${SNAP[1]}"
  while IFS= read -r line <&"${SNAP[0]}"; do
    [[ "$line" == "--END--" ]] && break
    printf '%s\n' "$line" >>"$set_dir/manifest.txt"
  done
  wait "$SNAP_PID" 2>/dev/null || true
  SNAP_PID=""
  grep -q '^public.tenants=' "$set_dir/manifest.txt" || return 3
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
