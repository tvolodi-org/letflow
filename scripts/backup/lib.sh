#!/usr/bin/env bash
# T-1568 -- shared helpers for scripts/backup/*.sh (sourced, never run). See README.md.
#
# Conventions: no `set -x` anywhere (a trace would print connection strings), umask 077,
# passwords only through libpq's PGPASSFILE / PGPASSWORD environment (never argv, never output),
# every script writes one status file ($BACKUP_ROOT/status/<job>.json) from an EXIT trap.

set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PG_EXEC is a command prefix (e.g. "docker exec -i letflow-postgres") that reaches the
# PostgreSQL client tools; empty means the tools are on PATH. It is split on purpose.
PG_EXEC="${PG_EXEC:-}"

STATUS_JOB=""
STATUS_DETAIL=""
STATUS_HOOK=""
STATUS_RC=0

log() { printf '%s\n' "$*" >&2; }

# die <exit code> <detail token> <message>
die() {
  local code="$1" detail="$2"
  shift 2
  STATUS_DETAIL="$detail"
  log "$STATUS_JOB: $*"
  exit "$code"
}

# pgc <tool> args...: run a client tool through the prefix.
pgc() {
  # shellcheck disable=SC2086
  $PG_EXEC "$@"
}

# Keep only lines that cannot carry a password (libpq echoes a conninfo in some errors).
filter_secrets() { grep -viE 'password|PGPASSWORD' || true; }

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die 2 "missing_tool_$1" "required tool not found: $1"
}

# Validate the common environment. Sets BACKUP_ROOT and the database list.
common_env() {
  [[ -n "${BACKUP_ENV:-}" ]] || die 2 "backup_env_unset" "BACKUP_ENV is required (demo, qa, prod)"
  [[ "$BACKUP_ENV" =~ ^[a-z0-9_-]{1,32}$ ]] || die 2 "backup_env_invalid" "BACKUP_ENV must match [a-z0-9_-]{1,32}"
  BACKUP_ROOT="${BACKUP_ROOT:-/opt/backups/$BACKUP_ENV}"
  [[ "$BACKUP_ROOT" == /* ]] || die 2 "backup_root_relative" "BACKUP_ROOT must be an absolute path"
  [[ -n "${BACKUP_DATABASES:-}" ]] || die 2 "databases_unset" "BACKUP_DATABASES is required"
  local d
  for d in $BACKUP_DATABASES; do
    [[ "$d" =~ ^[A-Za-z0-9_]{1,63}$ ]] || die 2 "database_name_invalid" "database name must match [A-Za-z0-9_]{1,63}"
  done
  # shellcheck disable=SC2086
  set -- $BACKUP_DATABASES
  LETFLOW_DATABASE="${LETFLOW_DATABASE:-$1}"
  [[ "$LETFLOW_DATABASE" =~ ^[A-Za-z0-9_]{1,63}$ ]] || die 2 "database_name_invalid" "LETFLOW_DATABASE has an invalid name"
  BACKUP_ENCRYPT="${BACKUP_ENCRYPT:-none}"
  case "$BACKUP_ENCRYPT" in
    none) ;;
    gpg)
      [[ -n "${BACKUP_GPG_RECIPIENT:-}" ]] || die 2 "gpg_recipient_unset" "BACKUP_GPG_RECIPIENT is required when BACKUP_ENCRYPT=gpg"
      [[ "$BACKUP_GPG_RECIPIENT" =~ ^[A-Za-z0-9@._=+-]{1,128}$ ]] || die 2 "gpg_recipient_invalid" "BACKUP_GPG_RECIPIENT has unexpected characters"
      ;;
    *) die 2 "encrypt_invalid" "BACKUP_ENCRYPT must be none or gpg" ;;
  esac
  mkdir -p -m 0700 "$BACKUP_ROOT" "$BACKUP_ROOT/status"
  BACKUP_ROOT="$(cd "$BACKUP_ROOT" && pwd -P)"
}

# Lock the whole root so two timers cannot overlap. Exit 3 when busy.
take_lock() {
  need_tool flock
  exec 9>"$BACKUP_ROOT/.lock-$1"
  flock -n 9 || die 3 "busy" "another $1 run holds the lock"
}

# status_begin <job> [hook]: arm the EXIT trap that writes the status file with the real exit code.
status_begin() {
  STATUS_JOB="$1"
  STATUS_HOOK="${2:-}"
  trap '_status_finish $?' EXIT
}

_status_finish() {
  local rc="$1"
  trap - EXIT
  set +e
  STATUS_RC="$rc"
  [[ -z "$STATUS_HOOK" ]] || "$STATUS_HOOK"
  if [[ -n "${BACKUP_ROOT:-}" && -d "$BACKUP_ROOT/status" ]]; then
    local detail ok ts tmp
    detail="$(printf '%s' "$STATUS_DETAIL" | tr -c 'A-Za-z0-9 =._:-' '_' | cut -c1-300)"
    ok=false
    [[ "$rc" -eq 0 ]] && ok=true
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$BACKUP_ROOT/status/.${STATUS_JOB}.json.$$"
    printf '{"job":"%s","env":"%s","ts":"%s","exit":%d,"ok":%s,"detail":"%s"}\n' \
      "$STATUS_JOB" "${BACKUP_ENV:-unknown}" "$ts" "$rc" "$ok" "$detail" >"$tmp" &&
      chmod 0640 "$tmp" && mv -f "$tmp" "$BACKUP_ROOT/status/${STATUS_JOB}.json"
    rm -f "$tmp"
  fi
  exit "$rc"
}

utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }

# stamp -> epoch seconds (UTC)
stamp_epoch() {
  local s="$1"
  date -u -d "${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}:${s:13:2}" +%s
}

STAMP_RE='^[0-9]{8}T[0-9]{6}Z$'

# Load KEY=<digits> lines from the retention policy file. The file is parsed, never sourced.
load_retention() {
  local file="${RETENTION_FILE:-$SCRIPT_DIR/retention.conf}" line key val
  DUMP_KEEP_DAYS=14 DUMP_KEEP_MIN=7 BASE_KEEP=2 WAL_KEEP_DAYS=14
  [[ -f "$file" ]] || die 2 "retention_file_missing" "retention file not found"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ "$line" =~ ^([A-Z_]+)=([0-9]{1,5})$ ]]; then
      key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
      case "$key" in
        DUMP_KEEP_DAYS | DUMP_KEEP_MIN | BASE_KEEP | WAL_KEEP_DAYS) printf -v "$key" '%s' "$val" ;;
        *) die 2 "retention_key_unknown" "retention file: unknown key" ;;
      esac
    else
      die 2 "retention_line_invalid" "retention file: only KEY=number lines are allowed"
    fi
  done <"$file"
}
