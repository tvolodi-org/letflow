#!/usr/bin/env bash
# T-1568 -- restore_test.sh [--set DIR]: restore the latest dump set of LETFLOW_DATABASE into a
# THROWAWAY database and check it. Prints exactly one line on stdout; everything else goes to
# stderr. Interface and environment: scripts/backup/README.md.
#
#   restore_test PASS env=qa db=letflow_qa set=20261109T014500Z tenants=3 ledger_pairs=12 replay_diff=0 modules=ok smoke=ok seconds=41
#   restore_test FAIL step=<name> exit=<n> detail=<token>
#
# Exit codes: 0 pass; 1 a content check failed (manifest differs, ledger replay not balanced);
#             2 bad input / missing tool / server version mismatch; 3 no fresh backup (none, too
#             old, or incomplete); 4 checksum mismatch (the backup file is damaged); 5 restore failed;
#             6 smoke failed (or not configured and not explicitly allowed to be skipped).
# The source database is never a restore target and never dropped: only a scratch database this
# script created itself (name restore_test_<stamp>_<pid>) or the throwaway container is removed.
set -euo pipefail
set +x
# shellcheck source=scripts/backup/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SET_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --set)
      SET_DIR="${2:-}"
      shift 2 || true
      ;;
    *)
      log "usage: restore_test.sh [--set DIR]"
      exit 2
      ;;
  esac
done

STEP="init"
SET_NAME="-"
WORK=""
CID=""
SCRATCH=""
SCRATCH_CREATED=0
RX=""
REPORT_TENANTS="-"
REPORT_PAIRS="-"
REPORT_DIFF="-"
REPORT_MODULES="-"
REPORT_SMOKE="-"
SECONDS=0

# Runs on every exit: remove only what this run created, then print the one report line.
cleanup_and_report() {
  if [[ -n "$CID" ]]; then
    docker rm -f "$CID" >/dev/null 2>&1 || true
  elif [[ "$SCRATCH_CREATED" -eq 1 && "$SCRATCH" =~ ^restore_test_[0-9]{8}T[0-9]{6}Z_[0-9]+$ && "$SCRATCH" != "${LETFLOW_DATABASE:-}" ]]; then
    pgc psql -X -q -d postgres -c "DROP DATABASE IF EXISTS \"$SCRATCH\"" </dev/null >/dev/null 2>&1 || true
  fi
  [[ -z "$WORK" ]] || rm -rf -- "$WORK"
  local line
  if [[ "$STATUS_RC" -eq 0 ]]; then
    line="restore_test PASS env=${BACKUP_ENV:-unknown} db=${LETFLOW_DATABASE:-unknown} set=$SET_NAME tenants=$REPORT_TENANTS ledger_pairs=$REPORT_PAIRS replay_diff=$REPORT_DIFF modules=$REPORT_MODULES smoke=$REPORT_SMOKE seconds=$SECONDS"
  else
    line="restore_test FAIL step=$STEP exit=$STATUS_RC detail=${STATUS_DETAIL:-unknown}"
  fi
  STATUS_DETAIL="${line#restore_test }"
  printf '%s\n' "$line"
}

status_begin restore_test cleanup_and_report
common_env
need_tool sha256sum
take_lock restore
WORK="$(mktemp -d)"

# rx <tool> args...: run a client tool against the restore target.
rx() {
  # shellcheck disable=SC2086
  $RX "$@"
}

# sum_values <key suffix> <file>: sum of the numeric values of lines "<schema>.<key>=<n>" ("-" counts 0).
sum_values() {
  local total=0 v
  while IFS= read -r v; do
    [[ "$v" =~ ^[0-9]+$ ]] && total=$((total + v))
  done < <(sed -n "s/^.*\\.$1=//p" "$2")
  printf '%s' "$total"
}

# ---- 1. pick the set
STEP="select_set"
if [[ -z "$SET_DIR" ]]; then
  [[ -e "$BACKUP_ROOT/dump/$LETFLOW_DATABASE/LATEST" ]] || die 3 "no_backup" "no LATEST set for $LETFLOW_DATABASE"
  SET_DIR="$BACKUP_ROOT/dump/$LETFLOW_DATABASE/LATEST"
fi
SET_DIR="$(cd "$SET_DIR" 2>/dev/null && pwd -P)" || die 3 "no_backup" "backup set directory not found"
SET_NAME="$(basename "$SET_DIR")"
[[ "$SET_NAME" =~ $STAMP_RE ]] || die 3 "not_a_set" "directory name is not a backup stamp"
MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-30}"
[[ "$MAX_AGE_HOURS" =~ ^[0-9]{1,5}$ ]] || die 2 "max_age_invalid" "BACKUP_MAX_AGE_HOURS must be a number"
age_s=$(($(date -u +%s) - $(stamp_epoch "$SET_NAME")))
[[ "$age_s" -le $((MAX_AGE_HOURS * 3600)) ]] || die 3 "no_fresh_backup" "newest set is older than $MAX_AGE_HOURS hours"
DUMP_FILE="$LETFLOW_DATABASE.dump"
if [[ -f "$SET_DIR/$DUMP_FILE.gpg" ]]; then DUMP_FILE="$DUMP_FILE.gpg"; fi
for f in "$DUMP_FILE" "$DUMP_FILE.sha256" manifest.txt; do
  [[ -s "$SET_DIR/$f" ]] || die 3 "incomplete_set" "set is missing $f"
done

# ---- 2. checksum
STEP="checksum"
(cd "$SET_DIR" && sha256sum -c --quiet "$DUMP_FILE.sha256") >/dev/null 2>&1 || die 4 "checksum_mismatch" "sha256 check failed: the backup file is damaged"

# ---- 3. throwaway target
STEP="target"
# Extra `docker run` args of the throwaway container (RESTORE_DOCKER_ARGS, split on spaces). Unset
# gives the safe default limits; a set value REPLACES them (the operator then owns the limits).
# Only `--flag` or `--flag=value` tokens are accepted (write `--cpus=2`, not `--cpus 2`), and the
# flags that would reach the host are refused: privileged, volumes/mounts, host namespaces, devices.
DOCKER_ARGS=()
if [[ -n "${RESTORE_DOCKER_ARGS:-}" ]]; then
  read -r -a DOCKER_ARGS <<<"$RESTORE_DOCKER_ARGS"
  for tok in "${DOCKER_ARGS[@]}"; do
    [[ "$tok" =~ ^--[a-z][a-z0-9-]*(=[^[:space:]]*)?$ ]] ||
      die 2 "docker_args_invalid" "RESTORE_DOCKER_ARGS accepts only --flag or --flag=value tokens"
    case "$tok" in
      --privileged* | --volume* | --volumes-from* | --mount* | --device* | --cap-add* | --security-opt* | \
        --network=host | --net=host | --pid=host | --ipc=host | --uts=host | --userns=host)
        die 2 "docker_args_forbidden" "RESTORE_DOCKER_ARGS contains a forbidden flag: ${tok%%=*}"
        ;;
    esac
  done
else
  DOCKER_ARGS=(--cpus=1 --memory=1g --memory-swap=1g --pids-limit=512)
fi
SCRATCH="restore_test_${SET_NAME}_$$"
SMOKE_URL=""
case "${RESTORE_TARGET:-container}" in
  container)
    need_tool docker
    want_ver="$(sed -n 's/^pg_version=//p' "$SET_DIR/manifest.txt" | head -n1)"
    image="${RESTORE_PG_IMAGE:-postgres:${want_ver:-16}}"
    pw="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
    CID="$(docker run -d --rm "${DOCKER_ARGS[@]}" -e POSTGRES_PASSWORD="$pw" -p 127.0.0.1::5432 "$image" 2>/dev/null)" ||
      die 2 "container_start_failed" "cannot start the throwaway container"
    ready=0
    for _ in $(seq 1 90); do
      if docker exec "$CID" pg_isready -q -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    [[ "$ready" -eq 1 ]] || die 2 "container_not_ready" "throwaway container did not become ready"
    RX="docker exec -i -e PGUSER=postgres $CID"
    port="$(docker port "$CID" 5432/tcp | head -n1 | sed 's/.*://')"
    SMOKE_URL="ecto://postgres:$pw@127.0.0.1:$port/$SCRATCH"
    ;;
  existing)
    [[ "$SCRATCH" != "$LETFLOW_DATABASE" ]] || die 2 "target_is_source" "refusing to restore over the source database"
    RX="$PG_EXEC"
    [[ -z "${RESTORE_DATABASE_URL_BASE:-}" ]] || SMOKE_URL="${RESTORE_DATABASE_URL_BASE%/}/$SCRATCH"
    ;;
  *) die 2 "target_invalid" "RESTORE_TARGET must be container or existing" ;;
esac
rx psql -X -q -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$SCRATCH\"" </dev/null >/dev/null 2>"$WORK/err.log" ||
  die 5 "scratch_create_failed" "cannot create the scratch database"
SCRATCH_CREATED=1

have_ver="$(rx psql -X -At -d "$SCRATCH" -c 'SHOW server_version_num' </dev/null | cut -c1-2)"
want_ver="$(sed -n 's/^pg_version=//p' "$SET_DIR/manifest.txt" | head -n1)"
[[ -z "$want_ver" || "$have_ver" == "$want_ver" ]] || die 2 "pg_version_mismatch" "restore server is version $have_ver, the dump is from $want_ver"

# ---- 4. restore
STEP="restore"
rc=0
if [[ "$DUMP_FILE" == *.gpg ]]; then
  need_tool gpg
  [[ -z "${RESTORE_GPG_HOME:-}" ]] || export GNUPGHOME="$RESTORE_GPG_HOME"
  { gpg --batch --decrypt <"$SET_DIR/$DUMP_FILE" 2>/dev/null | rx pg_restore --exit-on-error --no-owner -d "$SCRATCH"; } 2>"$WORK/err.log" || rc=$?
else
  rx pg_restore --exit-on-error --no-owner -d "$SCRATCH" <"$SET_DIR/$DUMP_FILE" 2>"$WORK/err.log" || rc=$?
fi
if [[ "$rc" -ne 0 ]]; then
  filter_secrets <"$WORK/err.log" | head -n 5 >&2
  die 5 "pg_restore_failed" "pg_restore failed"
fi

# ---- 5. content checks: the manifest query on the restored copy against the one taken with the dump
STEP="content"
rx psql -X -At -d "$SCRATCH" -v ON_ERROR_STOP=1 -f - <"$SCRIPT_DIR/manifest.sql" >"$WORK/restored.txt" 2>"$WORK/err.log" ||
  die 5 "manifest_query_failed" "manifest query failed on the restored copy"
grep -vE '^(format|source_db|pg_version)=' "$SET_DIR/manifest.txt" | LC_ALL=C sort >"$WORK/expected.txt"
LC_ALL=C sort "$WORK/restored.txt" >"$WORK/got.txt"
if ! cmp -s "$WORK/expected.txt" "$WORK/got.txt"; then
  keys="$({ diff "$WORK/expected.txt" "$WORK/got.txt" || true; } | sed -n 's/^[<>] \([^=]*\)=.*/\1/p' | LC_ALL=C sort -u | head -n 3 | paste -sd: -)"
  die 1 "manifest_differs:$keys" "restored data differs from the manifest taken with the dump"
fi
REPORT_TENANTS="$(sed -n 's/^public\.tenants=//p' "$WORK/got.txt")"
REPORT_PAIRS="$(sum_values ledger_pairs "$WORK/got.txt")"
REPORT_DIFF="$(sum_values ledger_replay_diff "$WORK/got.txt")"
# The replay checksum is also checked absolutely: a backup of an already inconsistent ledger fails.
[[ "$REPORT_DIFF" -eq 0 ]] || die 1 "replay_diff_nonzero:$REPORT_DIFF" "ledger replay does not balance in the backup"
REPORT_MODULES=ok

# ---- 6. smoke through the app
STEP="smoke"
if [[ "${RESTORE_SMOKE:-run}" == skip ]]; then
  [[ "${RESTORE_ALLOW_NO_SMOKE:-0}" == 1 ]] || die 6 "smoke_skipped_not_allowed" "RESTORE_SMOKE=skip needs RESTORE_ALLOW_NO_SMOKE=1"
  REPORT_SMOKE=skipped
else
  if [[ -n "${RESTORE_SMOKE_CMD:-}" ]]; then
    smoke=(bash -c "$RESTORE_SMOKE_CMD")
  elif [[ -n "${RELEASE_BIN:-}" ]]; then
    smoke=("$RELEASE_BIN" eval "Letflow.Release.restore_smoke()")
  else
    die 6 "smoke_not_configured" "set RELEASE_BIN or RESTORE_SMOKE_CMD (or RESTORE_SMOKE=skip with RESTORE_ALLOW_NO_SMOKE=1)"
  fi
  [[ -n "$SMOKE_URL" ]] || [[ -n "${RESTORE_SMOKE_CMD:-}" ]] || die 6 "smoke_url_unset" "RESTORE_DATABASE_URL_BASE is required to run the release against the scratch database"
  rc=0
  DATABASE_URL="$SMOKE_URL" RESTORE_DB_NAME="$SCRATCH" "${smoke[@]}" </dev/null >"$WORK/smoke.log" 2>&1 || rc=$?
  filter_secrets <"$WORK/smoke.log" | tail -n 3 >&2
  [[ "$rc" -eq 0 ]] || die 6 "smoke_failed" "the smoke check failed"
  REPORT_SMOKE=ok
fi

# ---- 7. verified: prune.sh never deletes the newest verified set
date -u +%Y-%m-%dT%H:%M:%SZ >"$SET_DIR/VERIFIED" 2>/dev/null || true
STEP="done"
